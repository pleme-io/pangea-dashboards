# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The canonical primary↔standby REPLICATION-HEALTH row for any
      # streaming-replication database (Postgres, MySQL, …). Generalises the
      # cloud_native_pg PG panels — replication lag, streaming-replica count,
      # connections-near-max %, and cache-hit ratio — into a typed any-primary/
      # standby row whose metric NAMES are injected, so the same composite
      # serves a CloudNativePG cluster, a bare Patroni pair, or a vendor exporter
      # with renamed series. The author supplies the metric names; the component
      # owns the consistent layout, the lag thresholds, and the near-max maths.
      #
      # ── The story this row tells (left → right) ─────────────────────────
      # • Replication lag vs threshold — the headline timeseries (seconds): how
      #   far behind the standby is, green under `lag_warn`, red at `lag_crit`.
      #   This is THE replication-health question — a growing lag is the first
      #   sign of a struggling standby or a saturated WAL pipe.
      # • Streaming replicas — a liveness stat: how many standbys are actually
      #   streaming. LOWER is worse (0 = no replica = no HA), so it reads red
      #   below the expected count and green at/above it (liveness_steps).
      # • Connections near max % (optional) — a defect stat: 100*conns/max_conns,
      #   amber/red as the pool fills, because a primary that hits max_connections
      #   refuses new clients exactly like an outage.
      # • Cache-hit ratio % (optional) — a liveness stat: higher is healthier; a
      #   collapsing buffer-cache hit ratio means the working set spilled to disk.
      #
      #   row 'Replication' do
      #     Pangea::Dashboards::Library::ReplicationHealthRow.add(
      #       self, datasource: 'vm',
      #       lag_metric: 'cnpg_pg_replication_lag',
      #       streaming_metric: 'cnpg_pg_replication_streaming_replicas',
      #       connections_metric: 'cnpg_backends_total',
      #       max_connections_metric: 'cnpg_pg_settings_max_connections',
      #       cache_hit_expr: 'cnpg_pg_stat_database_blks_hit / (cnpg_pg_stat_database_blks_hit + cnpg_pg_stat_database_blks_read)')
      #   end
      module ReplicationHealthRow
        # lag_metric:             (req) replication-lag gauge in SECONDS
        # streaming_metric:       (req) count of streaming standbys (liveness)
        # in_recovery_metric:     optional 1/0 is-standby gauge → selects the
        #                         standby members the lag is grouped by
        # connections_metric:     optional current-connections gauge
        # max_connections_metric: optional max_connections setting gauge
        #                         (both connections_* needed for the near-max %)
        # cache_hit_expr:         optional raw buffer-cache-hit RATIO expr (0–1);
        #                         rendered ×100 as a liveness %
        # lag_warn / lag_crit:    lag thresholds in seconds (default 5 / 30)
        # conn_warn / conn_crit:  near-max % thresholds (default 80 / 95)
        # title:                  row-name prefix on every panel (default 'Replication')
        def self.add(row, datasource:, lag_metric:, streaming_metric:,
                     in_recovery_metric: nil, connections_metric: nil, max_connections_metric: nil,
                     cache_hit_expr: nil, lag_warn: 5, lag_crit: 30, conn_warn: 80, conn_crit: 95,
                     title: 'Replication')
          validate!(datasource: datasource, lag_metric: lag_metric, streaming_metric: streaming_metric)

          # The optional stat tiles share one uniform-width strip; count them
          # up front so Theme.tile_width fills the row cleanly.
          show_conns = !blank?(connections_metric) && !blank?(max_connections_metric)
          show_cache = !blank?(cache_hit_expr)
          stat_count = 1 + (show_conns ? 1 : 0) + (show_cache ? 1 : 0)
          stat_w = Theme.tile_width(stat_count)

          add_lag(row, datasource: datasource, lag_metric: lag_metric,
                  in_recovery_metric: in_recovery_metric, lag_warn: lag_warn, lag_crit: lag_crit, title: title)

          add_streaming(row, datasource: datasource, streaming_metric: streaming_metric,
                        width: stat_w, title: title)

          add_connections(row, datasource: datasource, connections_metric: connections_metric,
                          max_connections_metric: max_connections_metric, conn_warn: conn_warn,
                          conn_crit: conn_crit, width: stat_w, title: title) if show_conns

          add_cache_hit(row, datasource: datasource, cache_hit_expr: cache_hit_expr,
                        width: stat_w, title: title) if show_cache
        end

        # The headline: replication lag vs threshold (seconds). A standby gauge
        # grouped to the in-recovery members when an is-standby selector is given.
        def self.add_lag(row, datasource:, lag_metric:, in_recovery_metric:, lag_warn:, lag_crit:, title:)
          expr = "max(#{lag_metric}#{Promql.braces(lag_selector(in_recovery_metric))})"
          steps = Theme.defect_steps(warn: lag_warn, crit: lag_crit)
          row.panel :"repl_lag_#{slug(title)}", kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title "#{title} · lag"
            unit 's'
            min 0
            graph :area
            description 'Standby replication lag in seconds. Amber/red as it crosses the warn/crit thresholds.'
            query 'A', expr, datasource: datasource, presence: :continuous, legend: 'lag'
            threshold steps: steps
          end
        end

        # Streaming standbys — liveness (LOWER = worse; 0 standbys = no HA).
        def self.add_streaming(row, datasource:, streaming_metric:, width:, title:)
          row.panel :"repl_streaming_#{slug(title)}", kind: :stat, width: width, height: Theme::STAT_H do
            title "#{title} · streaming replicas"
            unit 'short'
            display :background
            graph :area
            description 'Standbys actively streaming WAL. Red when none are streaming.'
            query 'A', "max(#{streaming_metric})", datasource: datasource, presence: :continuous
            threshold steps: Theme.liveness_steps(ok: 1)
          end
        end

        # Connections near max % — defect (HIGHER = worse; max_connections is a
        # hard wall a primary hits like an outage).
        def self.add_connections(row, datasource:, connections_metric:, max_connections_metric:,
                                 conn_warn:, conn_crit:, width:, title:)
          expr = "100 * max(#{connections_metric}) / max(#{max_connections_metric})"
          row.panel :"repl_conns_#{slug(title)}", kind: :stat, width: width, height: Theme::STAT_H do
            title "#{title} · connections near max"
            unit 'percent'
            min 0
            max 100
            display :background
            graph :area
            description 'Current connections as a % of max_connections. Red as the pool fills.'
            query 'A', expr, datasource: datasource, presence: :continuous
            threshold steps: Theme.defect_steps(warn: conn_warn, crit: conn_crit)
          end
        end

        # Cache-hit ratio % — liveness (HIGHER = healthier; a collapsing hit
        # ratio means the working set spilled to disk).
        def self.add_cache_hit(row, datasource:, cache_hit_expr:, width:, title:)
          expr = "100 * (#{cache_hit_expr})"
          row.panel :"repl_cache_hit_#{slug(title)}", kind: :stat, width: width, height: Theme::STAT_H do
            title "#{title} · cache hit"
            unit 'percent'
            min 0
            max 100
            display :background
            graph :area
            description 'Buffer-cache hit ratio. Red when the working set spills to disk.'
            query 'A', expr, datasource: datasource, presence: :continuous
            threshold steps: Theme.liveness_steps(ok: 99)
          end
        end

        # When an is-standby gauge is supplied, group the lag onto the standby
        # members (`{<metric>="1"}` selects the in-recovery rows).
        def self.lag_selector(in_recovery_metric)
          blank?(in_recovery_metric) ? nil : { in_recovery_metric.to_s => '1' }
        end

        def self.validate!(datasource:, lag_metric:, streaming_metric:)
          raise ArgumentError, 'ReplicationHealthRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'ReplicationHealthRow: lag_metric: required' if blank?(lag_metric)
          raise ArgumentError, 'ReplicationHealthRow: streaming_metric: required' if blank?(streaming_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_lag, :add_streaming, :add_connections, :add_cache_hit,
                             :lag_selector, :validate!, :blank?, :slug
      end
    end
  end
end
