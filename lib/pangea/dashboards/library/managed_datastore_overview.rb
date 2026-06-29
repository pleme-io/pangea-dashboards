# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/saturation_row'
require 'pangea/dashboards/library/datastore_query_row'
require 'pangea/dashboards/library/replication_health_row'
require 'pangea/dashboards/library/capacity_headroom_stat'
require 'pangea/dashboards/library/log_windows'

module Pangea
  module Dashboards
    module Library
      # The one-call operator dashboard for a MANAGED DATASTORE — relational
      # (Postgres/MySQL/Aurora), cache (Redis/Memcached), or graph (Neo4j/Neptune).
      # The lower-layer story every cell tells once the workload layer is up:
      #
      #   Presence  →  Status (defects)  →  USE saturation  →  query RED  →
      #   [replication]  →  capacity headroom  →  slow-query logs
      #
      # ── The engine: switch ──────────────────────────────────────────────
      # `engine:` (:relational | :cache | :graph) tunes the story without forking
      # the mixin:
      #   • :relational — includes the ReplicationHealthRow (primary↔standby lag);
      #     query RED uses a histogram latency by default.
      #   • :cache — NO replication row (a cache standby is rarely the health
      #     signal); query RED uses a GAUGE latency (caches expose mean op-latency
      #     as a gauge, not a bucket histogram).
      #   • :graph — no replication row; histogram latency (graph traversals are
      #     usually bucketed).
      # Every per-engine choice is a DEFAULT the author may override (a cache WITH
      # replication, a relational store WITH a gauge latency) — the switch picks
      # the common shape, never locks it.
      #
      #   dash = Pangea::Dashboards::Library::ManagedDatastoreOverview.build(
      #     id: :orders_db, name: 'orders', datasource: 'vm', engine: :relational,
      #     selector: { db: 'orders' },
      #     up_metric: 'pg_up', qps_metric: 'pg_stat_queries_total',
      #     latency_metric: 'pg_query_duration_seconds_bucket',
      #     lag_metric: 'cnpg_pg_replication_lag', streaming_metric: 'cnpg_pg_replication_streaming_replicas')
      module ManagedDatastoreOverview
        ENGINES = %i[relational cache graph].freeze

        # id/name:           dashboard id + human title
        # datasource:        (req) the metrics datasource uid
        # engine:            :relational (default) | :cache | :graph
        # selector:          typed Hash/String matcher scoping the store
        # up_metric:         per-instance up/health gauge → DataPresence + a defect
        # signals:           extra StatusOverview defect signals (merged after the
        #                    built-in "instances down" tile)
        # util_expr/saturation_expr: the USE row (defaults derive from selector-
        #                    scoped generic connection/utilisation metrics)
        # qps_metric/latency_metric: the query RED (required to render the RED row)
        # latency_is_histogram: override the per-engine default
        # slow_metric/error_metric: optional query RED legs
        # lag_metric/streaming_metric: relational replication (auto-included for
        #                    :relational when both are given)
        # headroom_*:        the capacity-headroom stat (disk/connection budget)
        # logs_datasource/stream: optional slow-query log windows
        def self.build(id:, datasource:, name: nil, engine: :relational, selector: nil,
                       up_metric: nil, signals: [],
                       util_expr: nil, saturation_expr: nil, saturation_unit: 'short',
                       qps_metric: nil, latency_metric: nil, latency_is_histogram: nil,
                       slow_metric: nil, error_metric: nil, group_by: [],
                       lag_metric: nil, streaming_metric: nil,
                       headroom_expr: nil, headroom_unit: 'bytes', headroom_floor: nil,
                       headroom_warn: nil, headroom_ok: nil, headroom_title: 'Free capacity',
                       logs_datasource: nil, stream: nil)
          validate!(id: id, datasource: datasource, engine: engine)
          eng = engine.to_sym
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · #{eng} datastore")
          b.tags('pleme-io', 'managed-datastore', eng.to_s)

          # 1. Presence — is the store reporting at all? Generic managed stores
          # key on an `up`-style gauge (not a scrape job list), so this is a
          # direct liveness stat rather than DataPresence's per-job strip.
          if up_metric
            up_expr = "#{up_metric}#{Promql.braces(selector)}"
            b.row('Data presence — is the store reporting?') do
              panel :datastore_up, kind: :stat, width: Theme.full, height: Theme::STAT_H do
                title 'Instances up'
                unit 'short'
                display :background
                graph :area
                query 'A', "sum(#{up_expr})", datasource: datasource, presence: :continuous
                threshold steps: Pangea::Dashboards::Theme.liveness_steps(ok: 1)
              end
            end
          end

          # 2. Status — the defects-first headline.
          down_signal = up_metric ? [{
            name: 'Instances down',
            expr: "count(#{up_metric}#{Promql.braces(selector)} == 0)",
            warn: 1, crit: 1,
            desc: 'Datastore instances reporting down. RED ⇒ an instance is unreachable.'
          }] : []
          all_signals = down_signal + Array(signals)
          unless all_signals.empty?
            b.row('Status — what needs attention?') do
              Library::StatusOverview.add(self, datasource: datasource, signals: all_signals)
            end
          end

          # 3. USE saturation — utilisation + a backlog/connection measure.
          if util_expr && saturation_expr
            b.row('Saturation — USE') do
              Library::SaturationRow.add(self, datasource: datasource, title: eng.to_s,
                                         util_expr: util_expr, saturation_expr: saturation_expr,
                                         saturation_unit: saturation_unit)
            end
          end

          # 4. Query RED — gauge-vs-histogram latency selected per engine.
          if qps_metric && latency_metric
            is_hist = latency_is_histogram.nil? ? histogram_default(eng) : latency_is_histogram
            b.row('Query — golden signals') do
              Library::DatastoreQueryRow.add(self, datasource: datasource,
                                             qps_metric: qps_metric, latency_metric: latency_metric,
                                             latency_is_histogram: is_hist, slow_metric: slow_metric,
                                             error_metric: error_metric, selector: selector, group_by: group_by)
            end
          end

          # 5. Replication — relational primary↔standby (auto for :relational).
          if include_replication?(eng, lag_metric, streaming_metric)
            b.row('Replication — primary ↔ standby') do
              Library::ReplicationHealthRow.add(self, datasource: datasource,
                                                lag_metric: lag_metric, streaming_metric: streaming_metric)
            end
          end

          # 6. Capacity headroom — how much room is left before it fills.
          if headroom_expr && headroom_floor && headroom_ok
            b.row('Capacity headroom') do
              Library::CapacityHeadroomStat.add(self, datasource: datasource, expr: headroom_expr,
                                                unit: headroom_unit, floor: headroom_floor,
                                                warn: headroom_warn, ok: headroom_ok, title: headroom_title)
            end
          end

          # 7. Slow-query logs — full + ERROR window + error-rate.
          if stream && logs_datasource
            b.row('Slow-query logs') do
              Library::LogWindows.add_all(self, name: (name || id).to_s, stream: stream, datasource: logs_datasource)
            end
          end

          b.build
        end

        # Caches expose a mean op-latency GAUGE; relational + graph expose a
        # bucket histogram. The per-engine latency-mode default.
        def self.histogram_default(engine) = engine != :cache

        # The replication row is auto-included only for :relational, and only
        # when the author supplied both replication metrics.
        def self.include_replication?(engine, lag_metric, streaming_metric)
          engine == :relational && !blank?(lag_metric) && !blank?(streaming_metric)
        end

        def self.validate!(id:, datasource:, engine:)
          raise ArgumentError, 'ManagedDatastoreOverview: id: required' if blank?(id)
          raise ArgumentError, 'ManagedDatastoreOverview: datasource: required' if blank?(datasource)
          raise ArgumentError, "ManagedDatastoreOverview: engine must be one of #{ENGINES.inspect} (got #{engine.inspect})" \
            unless ENGINES.include?(engine.to_s.to_sym)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :histogram_default, :include_replication?, :validate!, :blank?
      end
    end
  end
end
