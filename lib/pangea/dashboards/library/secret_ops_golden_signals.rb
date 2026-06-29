# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/secret_ops_golden_matrix_row'
require 'pangea/dashboards/library/webhook_latency_heatmap'
require 'pangea/dashboards/library/slo_burn_rate_row'
require 'pangea/dashboards/library/quota_pct_samba_row'
require 'pangea/dashboards/library/top_n_table'
require 'pangea/dashboards/library/log_windows'

module Pangea
  module Dashboards
    module Library
      # The secret DATA-PLANE board for a Prometheus-annotated app/microservice
      # that fronts secret operations. RED-shaped, defects-first:
      #
      #   Status defects     →  error/denied rate + latency-budget breach
      #   Per-verb RED matrix →  ops/s + errors/s + p99 per operation kind
      #   Latency heatmap    →  the op-latency distribution (bimodal tail visible)
      #   SLO burn           →  multi-window error-budget burn + budget remaining
      #   Quota pressure     →  the samba rate-limited-consumer row
      #   Top failing        →  worst ops + worst callers offender tables
      #   Logs               →  full + ERROR window + error rate
      #
      #   dash = Pangea::Dashboards::Library::SecretOpsGoldenSignals.build(
      #     id: :secret_dataplane, name: 'Secret data plane', datasource: 'metrics',
      #     ops_metric: 'secret_operation_total', latency_metric: 'secret_op_seconds_bucket',
      #     verb_label: 'op', result_label: 'result', caller_label: 'caller')
      module SecretOpsGoldenSignals
        def self.build(id:, datasource:, name: nil, logs_datasource: nil,
                       selector: nil,
                       ops_metric: 'secret_operation_total',
                       latency_metric: 'secret_op_seconds_bucket',
                       verb_label: 'op', result_label: 'result',
                       error_results: %w[error denied], caller_label: 'caller',
                       objective: 0.999,
                       quota_metric: 'samba_quota_pct', rate_limit_metric: 'samba_rate_limit_derived',
                       backpressure_metric: 'samba_backpressure_total', ratelimited_counter: 'samba_ratelimited_total',
                       consumer_label: 'consumer',
                       worst_n: 10, stream: nil, window: '5m')
          validate!(id: id, datasource: datasource, ops_metric: ops_metric, latency_metric: latency_metric)
          lds = logs_datasource || datasource
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · secret data plane")
          b.tags('pleme-io', 'secret-ops-golden')

          # 1. Status defects — error/denied rate, latency tail.
          err_sel = error_selector(selector, result_label, error_results)
          err_expr = Floor.zero(Promql.sum_rate(metric: ops_metric, window: window, selector: err_sel))
          p99_expr = Promql.histogram_quantile(quantile: 0.99, bucket_metric: latency_metric,
                                                window: window, selector: selector)
          b.row('Status — what needs attention?') do
            Library::StatusOverview.add(self, datasource: datasource, signals: [
              { name: 'Failed ops /s', expr: err_expr, warn: 0.1, crit: 1, unit: 'ops',
                desc: 'Failed/denied secret operations per second. RED ⇒ the data plane is rejecting work.' },
              { name: 'p99 latency (s)', expr: "#{p99_expr} or vector(0)", warn: 0.5, crit: 1, unit: 's',
                desc: 'p99 secret-op latency. RED ⇒ the slow tail is breaching the latency budget.' }
            ])
          end

          # 2. Per-verb RED matrix.
          b.row('Secret ops — RED matrix') do
            Library::SecretOpsGoldenMatrixRow.add(self, datasource: datasource,
              ops_metric: ops_metric, latency_metric: latency_metric,
              verb_label: verb_label, result_label: result_label,
              error_results: error_results, selector: selector, window: window)
          end

          # 3. Latency distribution heatmap.
          b.row('Op latency distribution') do
            Library::WebhookLatencyHeatmap.add(self, datasource: datasource,
              histogram_metric: latency_metric, selector: selector, window: window,
              title: 'Secret-op latency')
          end

          # 4. SLO burn — good = non-error subset, total = all ops.
          good_metric = good_selector_expr(ops_metric, result_label, error_results)
          b.row('SLO / error budget') do
            Library::SloBurnRateRow.add(self, datasource: datasource,
              sli_good_metric: good_metric, sli_total_metric: ops_metric,
              objective: objective, selector: selector)
          end

          # 5. Quota pressure (samba).
          b.row('Rate-limited consumer (samba)') do
            Library::QuotaPctSambaRow.add(self, datasource: datasource, consumer_label: consumer_label,
              quota_metric: quota_metric, rate_limit_metric: rate_limit_metric,
              backpressure_metric: backpressure_metric, ratelimited_counter: ratelimited_counter,
              selector: selector, window: window)
          end

          # 6. Top failing ops + top failing callers.
          n = worst_n
          fr = Array(error_results)
          op_sel = selector
          call_label = caller_label
          vlabel = verb_label
          metric = ops_metric
          b.row('Top failing — ops + callers') do
            Library::TopNTable.add(self, datasource: datasource, metric: metric,
              group_by: [vlabel], agg: :increase, n: n, window: '1h',
              selector: op_sel, failure_results: fr, title: "Top #{n} failing ops")
            Library::TopNTable.add(self, datasource: datasource, metric: metric,
              group_by: [call_label], agg: :increase, n: n, window: '1h',
              selector: op_sel, failure_results: fr, title: "Top #{n} failing callers")
          end

          # 7. Logs.
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

        # Selector isolating the error/denied subset of the ops metric.
        def self.error_selector(selector, result_label, error_results)
          fr = { result_label.to_sym => Array(error_results) }
          case selector
          when ::Hash then selector.merge(fr)
          when nil then fr
          else
            body = [Promql.selector_body(selector), Promql.selector_body(fr)].reject { |x| x.nil? || x.empty? }
            body.join(',')
          end
        end

        # The GOOD-events expr: the ops metric with the error results NEGATED
        # (result!~"error|denied") — the SLI numerator, rendered through Promql.
        def self.good_selector_expr(ops_metric, result_label, error_results)
          neg = %(#{result_label}!~"#{Array(error_results).join('|')}")
          "#{ops_metric}{#{neg}}"
        end

        def self.validate!(id:, datasource:, ops_metric:, latency_metric:)
          raise ArgumentError, 'SecretOpsGoldenSignals: id: required' if blank?(id)
          raise ArgumentError, 'SecretOpsGoldenSignals: datasource: required' if blank?(datasource)
          raise ArgumentError, 'SecretOpsGoldenSignals: ops_metric: required' if blank?(ops_metric)
          raise ArgumentError, 'SecretOpsGoldenSignals: latency_metric: required' if blank?(latency_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :error_selector, :good_selector_expr, :validate!, :blank?
      end
    end
  end
end
