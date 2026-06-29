# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/version_skew_defect_tile'
require 'pangea/dashboards/library/replication_health_row'
require 'pangea/dashboards/library/by_phase_strip'
require 'pangea/dashboards/library/cache_effectiveness_row'
require 'pangea/dashboards/library/golden_signals_row'
require 'pangea/dashboards/library/log_windows'

module Pangea
  module Dashboards
    module Library
      # The fleet config-CONVERGENCE board for a gateway whose members sync a
      # shared config from a control plane. Defects-first, threaded sync-lag →
      # version posture → cache → sync RED:
      #
      #   Status defects     →  sync lag breach + version skew + cache cold
      #   Sync/replication   →  config-sync lag + synced-member count
      #   Per-version posture →  members grouped by applied version (the skew shape)
      #   Cache effectiveness →  hit-ratio / miss / eviction / cold defect
      #   Sync RED           →  sync attempts/s · failures · sync latency
      #   Logs               →  full + ERROR window + error rate
      #
      #   dash = Pangea::Dashboards::Library::GatewaySyncReplication.build(
      #     id: :gw_sync, name: 'Gateway Sync', datasource: 'metrics',
      #     sync_lag_metric: 'gateway_sync_lag_seconds',
      #     synced_members_metric: 'gateway_synced_members',
      #     version_metric: 'gateway_applied_config_generation')
      module GatewaySyncReplication
        def self.build(id:, datasource:, name: nil, logs_datasource: nil,
                       selector: nil,
                       sync_lag_metric: 'gateway_sync_lag_seconds',
                       synced_members_metric: 'gateway_synced_members',
                       version_metric: 'gateway_applied_config_generation',
                       version_label: 'applied_version',
                       sync_metric: 'gateway_sync_total',
                       sync_latency_metric: 'gateway_sync_seconds_bucket',
                       result_label: 'result', error_results: %w[error failed],
                       cache: { hits: 'cache_hits_total', misses: 'cache_misses_total', evictions: 'cache_evictions_total' },
                       lag_warn: 30, lag_crit: 120,
                       stream: nil, window: '5m')
          validate!(id: id, datasource: datasource, sync_lag_metric: sync_lag_metric,
                    synced_members_metric: synced_members_metric, version_metric: version_metric)
          lds = logs_datasource || datasource
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · gateway sync")
          b.tags('pleme-io', 'gateway-sync-replication')

          # 1. Status defects — sync lag breach + version skew + cache cold.
          lag_expr  = Floor.zero("count(#{sync_lag_metric}#{Promql.braces(selector)} >= #{lag_crit})")
          skew_signal = Library::VersionSkewDefectTile.signal(version_metric: version_metric, selector: selector)
          signals = [
            { name: "Members lagging > #{lag_crit}s", expr: lag_expr, warn: 1, crit: 3, unit: 'short',
              desc: "Members whose config-sync lag exceeds #{lag_crit}s. RED ⇒ the fleet is diverging from the control plane." },
            skew_signal
          ]
          if cache && cache[:hits] && cache[:misses]
            ch = Promql.sum_rate(metric: cache[:hits], window: window, selector: selector)
            cm = Promql.sum_rate(metric: cache[:misses], window: window, selector: selector)
            cache_ratio = "100 * (#{ch}) / ((#{ch}) + (#{cm}))"
            signals << { name: 'Cold cache (hit% < 90)', expr: Floor.zero("count(#{cache_ratio} < 90)"),
                         warn: 1, crit: 1, unit: 'short',
                         desc: 'Caches whose hit ratio dropped below 90%. RED ⇒ a cold member is re-fetching from the control plane.' }
          end
          b.row('Status — config-convergence defects') do
            Library::StatusOverview.add(self, datasource: datasource, signals: signals)
          end

          # 2. Sync / replication health — lag + synced-member count.
          b.row('Config sync health') do
            Library::ReplicationHealthRow.add(self, datasource: datasource,
              lag_metric: sync_lag_metric, streaming_metric: synced_members_metric,
              lag_warn: lag_warn, lag_crit: lag_crit, title: 'Config sync')
          end

          # 3. Per-version posture — members grouped by applied version.
          b.row('Per-version posture') do
            Library::ByPhaseStrip.add(self, datasource: datasource, phase_metric: version_metric,
              phase_label: version_label, selector: selector, title: 'Members by applied version')
          end

          # 4. Cache effectiveness.
          if cache && cache[:hits] && cache[:misses]
            cache_hits = cache[:hits]
            cache_misses = cache[:misses]
            cache_evictions = cache[:evictions]
            b.row('Cache effectiveness') do
              Library::CacheEffectivenessRow.add(self, datasource: datasource,
                hits_metric: cache_hits, misses_metric: cache_misses,
                evictions_metric: cache_evictions, selector: selector, window: window)
            end
          end

          # 5. Sync RED — attempts · failures · latency.
          b.row('Sync — RED') do
            Library::GoldenSignalsRow.add(self, datasource: datasource,
              rate_metric: sync_metric, latency_metric: sync_latency_metric,
              error_selector: { result_label.to_sym => Array(error_results) })
          end

          # 6. Logs.
          if stream
            stream_sel = stream
            ds_logs = lds
            nm = (name || id).to_s
            b.row('Logs') do
              Library::LogWindows.add_all(self, name: nm, stream: stream_sel, datasource: ds_logs)
            end
          end

          b.build
        end

        def self.validate!(id:, datasource:, sync_lag_metric:, synced_members_metric:, version_metric:)
          raise ArgumentError, 'GatewaySyncReplication: id: required' if blank?(id)
          raise ArgumentError, 'GatewaySyncReplication: datasource: required' if blank?(datasource)
          raise ArgumentError, 'GatewaySyncReplication: sync_lag_metric: required' if blank?(sync_lag_metric)
          raise ArgumentError, 'GatewaySyncReplication: synced_members_metric: required' if blank?(synced_members_metric)
          raise ArgumentError, 'GatewaySyncReplication: version_metric: required' if blank?(version_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
