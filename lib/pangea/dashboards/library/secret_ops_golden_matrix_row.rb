# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/rate_with_zero_floor'
require 'pangea/dashboards/library/latency_histogram_panel'

module Pangea
  module Dashboards
    module Library
      # The verb-partitioned RED MATRIX — GoldenSignalsRow generalised to "one
      # RED column per operation kind". Where GoldenSignalsRow tells the rate ·
      # errors · duration story for ONE request shape, a secret data-plane has
      # MANY verbs (get / create / rotate / list / delete) and the operator
      # wants each verb's volume + failure side by side. This composite emits:
      #
      #   • per-verb rate — ONE stacked timeseries, the verb partition encoded
      #     the way ByPhaseStrip encodes phases (the band heights ARE the
      #     per-verb rates, the envelope is total ops/s);
      #   • per-verb error/denial — ONE timeseries of the same verbs filtered to
      #     the error subset via the result label (a verb erroring lights up);
      #   • the shared p99 latency tail — LatencyHistogramPanel over the
      #     op-seconds histogram, grouped by the verb label.
      #
      # Generic over any `*_operation_total{op=…,result=…}` counter + an
      # `*_op_seconds_bucket` histogram. The author supplies the metric names,
      # the verb label, the result label, and the error-result values; the
      # component owns the typed PromQL, the stacking override, and the layout.
      #
      #   row 'Secret ops — RED matrix' do
      #     Pangea::Dashboards::Library::SecretOpsGoldenMatrixRow.add(
      #       self, datasource: 'vm',
      #       ops_metric: 'secret_operation_total',
      #       latency_metric: 'secret_op_seconds_bucket',
      #       verb_label: 'op', result_label: 'result',
      #       error_results: %w[error denied])
      #   end
      module SecretOpsGoldenMatrixRow
        # datasource:     (req) the metrics datasource uid
        # ops_metric:     (req) the per-op *_total counter (carries verb+result)
        # latency_metric: (req) the *_seconds_bucket op-latency histogram
        # verb_label:     the label partitioning operations (default 'op')
        # result_label:   the label carrying success/error (default 'result')
        # error_results:  values of result_label that count as failures
        #                 (default %w[error denied] → result=~"error|denied")
        # selector:       optional typed Hash/String matcher scoping the metric
        # quantiles:      latency quantiles (default p95/p99)
        # window:         rate/quantile window (default 5m)
        # title_prefix:   optional cosmetic prefix on every panel title
        def self.add(row, datasource:, ops_metric:, latency_metric:,
                     verb_label: 'op', result_label: 'result',
                     error_results: %w[error denied], selector: nil,
                     quantiles: [0.95, 0.99], window: '5m', title_prefix: nil)
          validate!(datasource: datasource, ops_metric: ops_metric,
                    latency_metric: latency_metric, verb_label: verb_label,
                    result_label: result_label)
          tp = title_prefix ? "#{title_prefix} · " : ''

          add_rate_matrix(row, datasource: datasource, ops_metric: ops_metric,
                          verb_label: verb_label, selector: selector, window: window, title: "#{tp}Ops/s by #{verb_label}")
          add_error_matrix(row, datasource: datasource, ops_metric: ops_metric,
                           verb_label: verb_label, result_label: result_label,
                           error_results: error_results, selector: selector, window: window,
                           title: "#{tp}Errors/s by #{verb_label}")
          LatencyHistogramPanel.add(row, datasource: datasource, bucket_metric: latency_metric,
                                    group_by: [verb_label], quantiles: quantiles, window: window,
                                    selector: selector, width: Theme.third, title: "#{tp}Latency p99",
                                    id: :"sogm_latency_#{slug(latency_metric)}")
        end

        # Per-verb rate as a stacked timeseries (the verb partition). Floored —
        # an idle verb reads a true 0, never no-data.
        def self.add_rate_matrix(row, datasource:, ops_metric:, verb_label:, selector:, window:, title:)
          expr = Floor.zero(Promql.sum_rate(metric: ops_metric, window: window,
                                            group_by: [verb_label], selector: selector))
          row.panel :"sogm_rate_#{slug(ops_metric)}", kind: :timeseries, width: Theme.third, height: Theme::TS_H do
            title title
            unit 'ops'
            min 0
            graph :area
            # Stacked: the verb partition is a population over total ops/s — the
            # band heights ARE the per-verb rates. Typed grafana override (same
            # seam ByPhaseStrip uses); degrades to plain multi-series.
            options(grafana: { 'fieldConfig' => { 'defaults' => { 'custom' => { 'stacking' => { 'mode' => 'normal', 'group' => 'A' } } } } })
            query 'A', expr, datasource: datasource, presence: :event_driven, legend: "{{#{verb_label}}}"
          end
        end

        # Per-verb error/denial leg — the same verbs filtered to the error
        # subset via the result label. Floored (healthy = 0).
        def self.add_error_matrix(row, datasource:, ops_metric:, verb_label:, result_label:,
                                  error_results:, selector:, window:, title:)
          err_sel = merge_error_results(selector, result_label, error_results)
          expr = Floor.zero(Promql.sum_rate(metric: ops_metric, window: window,
                                            group_by: [verb_label], selector: err_sel))
          row.panel :"sogm_errors_#{slug(ops_metric)}", kind: :timeseries, width: Theme.third, height: Theme::TS_H do
            title title
            unit 'ops'
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: :event_driven, legend: "{{#{verb_label}}}"
          end
        end

        # Merge the scope selector with the error-result matcher into ONE typed
        # selector — a Hash scope merges with the result Array (→ result=~"a|b"),
        # never hand-concatenated.
        def self.merge_error_results(selector, result_label, error_results)
          fr = { result_label.to_sym => Array(error_results) }
          case selector
          when nil then fr
          when ::Hash then selector.merge(fr)
          else
            body = [Promql.selector_body(selector), Promql.selector_body(fr)].reject { |b| b.nil? || b.empty? }
            body.join(',')
          end
        end

        def self.validate!(datasource:, ops_metric:, latency_metric:, verb_label:, result_label:)
          raise ArgumentError, 'SecretOpsGoldenMatrixRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'SecretOpsGoldenMatrixRow: ops_metric: required' if blank?(ops_metric)
          raise ArgumentError, 'SecretOpsGoldenMatrixRow: latency_metric: required' if blank?(latency_metric)
          raise ArgumentError, 'SecretOpsGoldenMatrixRow: verb_label: required' if blank?(verb_label)
          raise ArgumentError, 'SecretOpsGoldenMatrixRow: result_label: required' if blank?(result_label)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_rate_matrix, :add_error_matrix, :merge_error_results,
                             :validate!, :blank?, :slug
      end
    end
  end
end
