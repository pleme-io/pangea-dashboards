# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/data_presence'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/overdue_defect_tile'
require 'pangea/dashboards/library/version_skew_defect_tile'
require 'pangea/dashboards/library/secret_ops_golden_matrix_row'
require 'pangea/dashboards/library/red_sli_gauge_strip'
require 'pangea/dashboards/library/cache_effectiveness_row'
require 'pangea/dashboards/library/quota_pct_samba_row'
require 'pangea/dashboards/library/replication_health_row'
require 'pangea/dashboards/library/log_windows'

module Pangea
  module Dashboards
    module Library
      # THE KEYSTONE of the secrets-platform / gateway-ops domain. The one-call
      # control-plane dashboard for any secrets-management / gateway product.
      # Security-defects-first headline; the golden path is a verb-partitioned
      # secret-ops RED; the story threads auth → crypto → rotation → cache →
      # gateway-sync → rate-limit → logs:
      #
      #   Presence            →  is the gateway reporting at all?
      #   Security defects    →  denials, signing failures, overdue rotations,
      #                          config-version skew — colour-flooded headline
      #   Secret-ops golden   →  per-verb RED matrix (the data plane)
      #   Auth SLI            →  per-method denial-rate gauges
      #   Cache               →  hit-ratio / miss / eviction / cold defect
      #   Rate-limit          →  quotaPct + derived rate + back-pressure (samba)
      #   Gateway sync        →  config replication lag + synced-member count
      #   Logs                →  full + ERROR window + error rate
      #
      # Defects-first: the operator (or an agent over MCP) lands on "is anything
      # wrong?" before any line chart. Almost every row is reuse — the net-new
      # blocks are this domain's five shared primitives folded over the gateway
      # identity.
      #
      #   dash = Pangea::Dashboards::Library::SecretsPlatformOverview.build(
      #     id: :cell_secrets_overview, name: 'Secrets Platform', datasource: 'metrics',
      #     selector: { service: 'gateway', env: '$env' })
      module SecretsPlatformOverview
        # id/name:           dashboard id + human title
        # datasource:        (req) the metrics datasource uid
        # logs_datasource:   the logs datasource (default = datasource)
        # selector:          the typed label matcher folded into every series
        # jobs:              Prometheus job labels for the presence row
        # ops_metric/latency_metric/verb_label/result_label/error_results:
        #                    the secret-ops RED matrix metrics
        # auth_metric/auth_methods/method_label/outcome_label:
        #                    the per-method auth SLI strip
        # signing_failures_metric: signing/crypto failure counter (a defect)
        # denials_metric:    auth-denial counter (a defect)
        # rotation_elapsed_metric/rotation_interval_metric: the overdue defect
        # version_metric:    per-member applied-version gauge (the skew defect)
        # cache:             { hits:, misses:, evictions: } metric names
        # quota_metric/rate_limit_metric: the samba rate-limit row
        # sync_lag_metric/synced_members_metric: the gateway-sync replication row
        # stream:            LogsQL stream selector for the log windows
        def self.build(id:, datasource:, name: nil, logs_datasource: nil,
                       selector: nil, jobs: nil,
                       ops_metric: 'secret_operation_total',
                       latency_metric: 'secret_op_seconds_bucket',
                       verb_label: 'op', result_label: 'result',
                       error_results: %w[error denied],
                       auth_metric: 'gateway_auth_total', auth_methods: %w[token oauth saml k8s],
                       method_label: 'method', outcome_label: 'outcome',
                       denied_outcomes: %w[denied error],
                       signing_failures_metric: 'gateway_signing_failures_total',
                       denials_metric: 'gateway_auth_denied_total',
                       rotation_elapsed_metric: 'rotation_seconds_since_last',
                       rotation_interval_metric: 'rotation_configured_interval_seconds',
                       version_metric: 'gateway_applied_config_generation',
                       cache: { hits: 'cache_hits_total', misses: 'cache_misses_total', evictions: 'cache_evictions_total' },
                       quota_metric: 'samba_quota_pct', rate_limit_metric: 'samba_rate_limit_derived',
                       backpressure_metric: 'samba_backpressure_total', ratelimited_counter: 'samba_ratelimited_total',
                       consumer_label: 'consumer',
                       sync_lag_metric: 'gateway_sync_lag_seconds', synced_members_metric: 'gateway_synced_members',
                       stream: nil, window: '5m')
          validate!(id: id, datasource: datasource)
          lds = logs_datasource || datasource
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · secrets platform")
          b.tags('pleme-io', 'secrets-platform')

          # 1. Presence — is the gateway reporting at all?
          if jobs && !Array(jobs).empty?
            jobs_list = Array(jobs)
            b.row('Data presence — is the gateway reporting?') do
              Library::DataPresence.add_all(self, jobs: jobs_list, datasource: datasource)
            end
          end

          # 2. Security defects headline — hoist every helper-computed expr into
          #    a local BEFORE the row block (self is the RowBuilder inside it).
          denials_expr = Floor.zero(Promql.sum_rate(metric: denials_metric, window: window, selector: selector))
          signing_expr = Floor.zero(Promql.sum_rate(metric: signing_failures_metric, window: window, selector: selector))
          overdue_signal = Library::OverdueDefectTile.signal(
            elapsed_metric: rotation_elapsed_metric, interval_metric: rotation_interval_metric,
            name: 'Rotations overdue')
          skew_signal = Library::VersionSkewDefectTile.signal(
            version_metric: version_metric, selector: selector)
          b.row('Status — security defects') do
            Library::StatusOverview.add(self, datasource: datasource, signals: [
              { name: 'Auth denials /s', expr: denials_expr, warn: 0.1, crit: 1, unit: 'ops',
                desc: 'Auth denials per second. A surge ⇒ a credential rollout broke, or an attack.' },
              { name: 'Signing failures /s', expr: signing_expr, warn: 0.01, crit: 0.1, unit: 'ops',
                desc: 'Cryptographic signing failures per second — secrets cannot be issued. Any sustained rate is a crypto-path outage.' },
              overdue_signal,
              skew_signal
            ])
          end

          # 3. Secret-ops golden — the verb-partitioned RED matrix (data plane).
          b.row('Secret ops — RED matrix') do
            Library::SecretOpsGoldenMatrixRow.add(self, datasource: datasource,
              ops_metric: ops_metric, latency_metric: latency_metric,
              verb_label: verb_label, result_label: result_label,
              error_results: error_results, selector: selector, window: window)
          end

          # 4. Auth SLI — per-method denial-rate gauges.
          auth_subsystems = Array(auth_methods).map do |m|
            { name: m.to_s, extra_selector: merge_method(selector, method_label, m) }
          end
          unless auth_subsystems.empty?
            denied_match = { outcome_label.to_sym => Array(denied_outcomes) }
            b.row('Auth SLI — denial rate per method') do
              Library::RedSliGaugeStrip.add(self, datasource: datasource, metric: auth_metric,
                error_label_match: denied_match, subsystems: auth_subsystems,
                title_suffix: 'denied (15m)')
            end
          end

          # 5. Cache effectiveness.
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

          # 6. Rate-limit — quotaPct + derived rate + back-pressure (samba).
          b.row('Rate-limited consumer (samba)') do
            Library::QuotaPctSambaRow.add(self, datasource: datasource, consumer_label: consumer_label,
              quota_metric: quota_metric, rate_limit_metric: rate_limit_metric,
              backpressure_metric: backpressure_metric, ratelimited_counter: ratelimited_counter,
              selector: selector, window: window)
          end

          # 7. Gateway sync — config replication lag + synced-member count.
          b.row('Gateway config sync') do
            Library::ReplicationHealthRow.add(self, datasource: datasource,
              lag_metric: sync_lag_metric, streaming_metric: synced_members_metric,
              title: 'Config sync')
          end

          # 8. Logs.
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

        # Merge the dashboard scope selector with the per-method label.
        def self.merge_method(selector, method_label, method)
          base = selector.is_a?(::Hash) ? selector.dup : {}
          base.merge(method_label.to_sym => method.to_s)
        end

        def self.validate!(id:, datasource:)
          raise ArgumentError, 'SecretsPlatformOverview: id: required' if blank?(id)
          raise ArgumentError, 'SecretsPlatformOverview: datasource: required' if blank?(datasource)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :merge_method, :validate!, :blank?
      end
    end
  end
end
