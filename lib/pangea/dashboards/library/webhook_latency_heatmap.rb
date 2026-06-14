# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The latency-DISTRIBUTION panel, as a reusable atom. ONE `:heatmap` over a
      # `*_latency_seconds_bucket` histogram — `sum by(le)(rate(metric{sel}[w]))`
      # — for admission / webhook latency. Where a p99 stat collapses the whole
      # distribution to a single number, the heatmap keeps the shape: a bimodal
      # tail (a fast path PLUS a slow timeout cohort) is visible as two bands,
      # exactly the failure mode a single quantile hides.
      #
      # Absorbed from the akeyless-community external-secrets
      # webhook-RED-and-latency-heatmap dashboard, where the admission webhook's
      # latency distribution is the load-bearing health signal.
      #
      #   row 'Webhook latency distribution' do
      #     Pangea::Dashboards::Library::WebhookLatencyHeatmap.add(
      #       self, datasource: 'vm',
      #       histogram_metric: 'apiserver_admission_webhook_admission_duration_seconds_bucket',
      #       selector: { name: 'external-secrets' })
      #   end
      module WebhookLatencyHeatmap
        # histogram_metric: (req) the *_latency_seconds_bucket histogram metric
        # selector:         typed Hash/String matcher (Promql.selector_body)
        # window:           rate window over the buckets (default 5m)
        # le_label:         the bucket-bound label (default 'le')
        # title:            panel title (default 'Webhook latency')
        def self.add(row, datasource:, histogram_metric:, selector: nil, window: '5m',
                     le_label: 'le', title: 'Webhook latency')
          validate!(datasource: datasource, histogram_metric: histogram_metric, window: window)
          # sum by(le)(rate(metric{sel}[w])) — the canonical heatmap series: the
          # per-bucket rate, grouped only by the bucket bound, lets Grafana lay
          # the distribution out over time. Built THROUGH Promql, never concat.
          expr = "sum#{Promql.by([le_label])}(rate(#{histogram_metric}#{Promql.braces(selector)}[#{window}]))"
          pid  = :"webhook_latency_heatmap_#{slug(histogram_metric)}"
          row.panel pid, kind: :heatmap, width: Theme.full, height: Theme::TABLE_H do
            title title
            unit 's'
            # A heatmap bucket series is continuous (rate over buckets is defined
            # everywhere the histogram reports), so NO zero-floor — the `le`
            # legend carries the bound, format the count over time.
            query 'A', expr, datasource: datasource, presence: :continuous,
                  legend: "{{#{le_label}}}"
          end
        end

        def self.validate!(datasource:, histogram_metric:, window:)
          raise ArgumentError, 'WebhookLatencyHeatmap: datasource: required' if blank?(datasource)
          raise ArgumentError, 'WebhookLatencyHeatmap: histogram_metric: required' if blank?(histogram_metric)
          raise ArgumentError, 'WebhookLatencyHeatmap: window: required' if blank?(window)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :validate!, :blank?, :slug
      end
    end
  end
end
