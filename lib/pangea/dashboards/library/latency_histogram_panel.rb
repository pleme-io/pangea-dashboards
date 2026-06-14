# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The Duration leg of RED, as a reusable atom. ONE timeseries plotting
      # `histogram_quantile(q, …)` over a `*_seconds_bucket` histogram for an
      # array of quantiles (p50/p90/p99) grouped by a label set — the tail-
      # latency panel hand-written in pangea_operator (reconcile p95),
      # kubernetes_cluster (apiserver/dns p99), victoria_metrics_health (scrape
      # p99), and every controller-runtime / ARC / external-secrets dashboard
      # in the corpus. Consumed by GoldenSignalsRow + ControllerRuntimeRow.
      #
      #   row 'Reconcile' do
      #     Pangea::Dashboards::Library::LatencyHistogramPanel.add(
      #       self, datasource: 'vm',
      #       bucket_metric: 'controller_runtime_reconcile_time_seconds_bucket',
      #       group_by: %w[controller], quantiles: [0.5, 0.95, 0.99])
      #   end
      module LatencyHistogramPanel
        # bucket_metric: (req) the *_seconds_bucket histogram metric
        # group_by:      labels to preserve through the quantile (besides le)
        # quantiles:     array of quantiles in [0,1] (default p50/p95/p99)
        # window:        rate window over the buckets (default 5m)
        # unit:          Grafana unit (default 's')
        # selector:      typed Hash/String matcher
        # title/legend/id: cosmetic overrides. legend may use {{q}} for the
        #                  quantile token and {{label}} for grouped labels.
        def self.add(row, datasource:, bucket_metric:, group_by: [], quantiles: [0.5, 0.95, 0.99],
                     window: '5m', unit: 's', selector: nil, title: nil, legend: nil, id: nil, width: nil)
          validate!(datasource: datasource, bucket_metric: bucket_metric, quantiles: quantiles)
          pid = id || :"latency_#{slug(bucket_metric)}"
          ttl = title || default_title(bucket_metric)
          group_legend = Array(group_by).compact.map { |l| "{{#{l}}}" }.join('/')
          width ||= Theme.half
          row.panel pid, kind: :timeseries, width: width, height: Theme::TS_H do
            title ttl
            unit unit
            min 0
            graph :area
            quantiles.each_with_index do |q, i|
              ref  = ('A'.ord + i).chr
              pq   = "p#{(q * 100).round}"
              leg  = if legend
                       legend.gsub('{{q}}', pq)
                     else
                       group_legend.empty? ? pq : "#{pq} #{group_legend}"
                     end
              expr = Promql.histogram_quantile(quantile: q, bucket_metric: bucket_metric,
                                               window: window, group_by: group_by, selector: selector)
              query ref, expr, datasource: datasource, presence: :continuous, legend: leg
            end
          end
        end

        def self.default_title(bucket_metric)
          base = bucket_metric.to_s.sub(/_seconds_bucket\z/, '').sub(/_bucket\z/, '').tr('_', ' ')
          "#{base} latency"
        end

        def self.validate!(datasource:, bucket_metric:, quantiles:)
          raise ArgumentError, 'LatencyHistogramPanel: datasource: required' if blank?(datasource)
          raise ArgumentError, 'LatencyHistogramPanel: bucket_metric: required' if blank?(bucket_metric)
          raise ArgumentError, 'LatencyHistogramPanel: quantiles must be a non-empty Array' \
            unless quantiles.is_a?(Array) && !quantiles.empty?
          quantiles.each do |q|
            raise ArgumentError, "LatencyHistogramPanel: quantile #{q.inspect} must be in (0,1)" \
              unless q.is_a?(Numeric) && q > 0 && q < 1
          end
          raise ArgumentError, 'LatencyHistogramPanel: at most 8 quantiles (A–H queries)' if quantiles.length > 8
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :default_title, :validate!, :blank?, :slug
      end
    end
  end
end
