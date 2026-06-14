# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/rate_with_zero_floor'
require 'pangea/dashboards/library/latency_histogram_panel'

module Pangea
  module Dashboards
    module Library
      # The canonical RED row — Rate, Errors, Duration — for any
      # request/reconcile-shaped workload. The single most-repeated composite
      # in the absorbed corpus (pangea_operator reconcile RED, kubernetes_cluster
      # apiserver RED, vector component RED, burst_forge GW/webhook RED,
      # external-secrets controller-runtime RED). Composes the Wave-0 atoms:
      # RateWithZeroFloor (Rate), an Errors timeseries (filtered rate + the
      # error-ratio %), and LatencyHistogramPanel (Duration) — three panels
      # third-width so the whole golden-signals story sits on one row.
      #
      #   row 'Golden signals' do
      #     Pangea::Dashboards::Library::GoldenSignalsRow.add(
      #       self, datasource: 'vm',
      #       rate_metric: 'http_requests_total',
      #       latency_metric: 'http_request_duration_seconds_bucket',
      #       group_by: %w[route], error_selector: { code: '5..' })
      #   end
      module GoldenSignalsRow
        # rate_metric:    (req) the request/reconcile *_total counter
        # latency_metric: (req) the *_seconds_bucket histogram
        # error_selector: the matcher that selects the ERROR subset of
        #                 rate_metric — values are treated as REGEX (so
        #                 { code: '5..' } → code=~"5.."). Default { code: '5..' }.
        # group_by:       labels to break rate/errors down by
        # quantiles:      latency quantiles (default p95/p99)
        # show_error_ratio: also plot 100*errors/total as a % (default true)
        def self.add(row, datasource:, rate_metric:, latency_metric:,
                     error_selector: { code: '5..' }, group_by: [], quantiles: [0.95, 0.99],
                     window: '5m', rate_unit: 'reqps', show_error_ratio: true, title_prefix: nil)
          validate!(datasource: datasource, rate_metric: rate_metric, latency_metric: latency_metric)
          tp = title_prefix ? "#{title_prefix} · " : ''

          # ── Rate ──
          RateWithZeroFloor.add(row, datasource: datasource, counter_metric: rate_metric,
                                group_by: group_by, window: window, unit: rate_unit,
                                width: Theme.third, title: "#{tp}Rate", id: :"gs_rate_#{slug(rate_metric)}")

          # ── Errors (filtered rate + optional ratio %) ──
          add_errors(row, datasource: datasource, rate_metric: rate_metric,
                     error_selector: normalize_regex(error_selector), group_by: group_by,
                     window: window, show_ratio: show_error_ratio, title: "#{tp}Errors")

          # ── Duration ──
          LatencyHistogramPanel.add(row, datasource: datasource, bucket_metric: latency_metric,
                                    group_by: group_by, quantiles: quantiles, window: window,
                                    width: Theme.third, title: "#{tp}Latency")
        end

        def self.add_errors(row, datasource:, rate_metric:, error_selector:, group_by:, window:, show_ratio:, title:)
          err  = Floor.zero(Promql.sum_rate(metric: rate_metric, window: window,
                                            group_by: group_by, selector: error_selector))
          ratio = "100 * #{Promql.sum_rate(metric: rate_metric, window: window, selector: error_selector)} " \
                  "/ #{Promql.sum_rate(metric: rate_metric, window: window)}"
          pid  = :"gs_errors_#{slug(rate_metric)}"
          eleg = group_by.empty? ? 'errors/s' : Array(group_by).map { |l| "{{#{l}}}" }.join('/')
          row.panel pid, kind: :timeseries, width: Theme.third, height: Theme::TS_H do
            title title
            unit 'reqps'
            min 0
            graph :area
            query 'A', err, datasource: datasource, presence: :event_driven, legend: eleg
            query('B', "#{ratio} or vector(0)", datasource: datasource, presence: :event_driven, legend: 'error %') if show_ratio
          end
        end

        # Force every value of the error selector to a =~ match — the error
        # leg is intrinsically a pattern (5.., error|requeue), never an exact
        # literal. String → Regexp; an existing Regexp/Array passes through.
        def self.normalize_regex(sel)
          case sel
          when ::Hash then sel.transform_values { |v| v.is_a?(::Regexp) || v.is_a?(::Array) ? v : ::Regexp.new(v.to_s) }
          else sel
          end
        end

        def self.validate!(datasource:, rate_metric:, latency_metric:)
          raise ArgumentError, 'GoldenSignalsRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'GoldenSignalsRow: rate_metric: required' if blank?(rate_metric)
          raise ArgumentError, 'GoldenSignalsRow: latency_metric: required' if blank?(latency_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_errors, :normalize_regex, :validate!, :blank?, :slug
      end
    end
  end
end
