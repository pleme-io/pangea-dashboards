# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/rate_with_zero_floor'

module Pangea
  module Dashboards
    module Library
      # The samba rate-limited-consumer surface — the row that finally
      # RENDERS `quotaPct`. The rate-limited-consumer / samba doc names
      # quotaPct as "the single load-bearing knob" (the share of an external
      # API's published rate budget a consumer is allowed to spend), yet
      # NOTHING in the corpus draws it. This composite closes that named gap.
      #
      # Four panels, third-width so the consumer's whole story sits on one row
      # (the two optional event-driven legs widen to half when alone):
      #
      #   • quotaPct  :gauge  — the load-bearing knob. A 0–100 gauge over
      #     `quota_metric` coloured green→amber→red by the defect thresholds
      #     (HIGHER = closer to the cap = worse). Continuous: a running
      #     consumer always reports a quota, so a missing series is honestly
      #     "consumer down", NOT a floored 0.
      #   • derived rate :timeseries — the dynamic rate the consumer derives
      #     from the upstream `X-RateLimit-Limit` header (`rate_limit_metric`).
      #     The samba pattern recomputes this every response; plotting it shows
      #     the budget the leaky bucket is pacing against.
      #   • backpressure rate :timeseries (optional) — the leaky-bucket /
      #     Emergency back-pressure events the consumer emits when it nears the
      #     cap, floored through RateWithZeroFloor (a healthy consumer = 0).
      #   • 429 / secondary-rate-limit hits :timeseries (optional) — the
      #     upstream throttle responses the consumer DID hit, the failure the
      #     whole pattern exists to avoid, floored so healthy = a true 0.
      #
      #   row 'Rate-limited consumer' do
      #     Pangea::Dashboards::Library::QuotaPctSambaRow.add(
      #       self, datasource: 'vm', consumer_label: 'consumer',
      #       quota_metric: 'samba_quota_pct',
      #       rate_limit_metric: 'samba_rate_limit_derived',
      #       backpressure_metric: 'samba_backpressure_total',
      #       ratelimited_counter: 'samba_ratelimited_total')
      #   end
      module QuotaPctSambaRow
        # datasource:          (req) the metrics datasource
        # consumer_label:      (req) the label that identifies a consumer — the
        #                      grouping/legend dimension for every panel (so a
        #                      dashboard scoped to many consumers breaks down by
        #                      it). A typed selector may pin one consumer.
        # quota_metric:        (req) the 0–100 quotaPct gauge metric
        # rate_limit_metric:   (req) the derived-rate metric (from the upstream
        #                      X-RateLimit-Limit header)
        # backpressure_metric: optional *_total counter of leaky-bucket /
        #                      Emergency back-pressure events (floored)
        # ratelimited_counter: optional *_total counter of 429 / secondary
        #                      rate-limit responses hit (floored)
        # quota_warn/crit:     quotaPct thresholds (default 80 / 95 — amber as
        #                      the consumer approaches the cap, red at the edge)
        # selector:            typed Hash/String matcher pinning the consumer(s)
        # window:              rate window for the optional legs (default 5m)
        # title:               cosmetic prefix on the gauge title
        def self.add(row, datasource:, consumer_label:, quota_metric:, rate_limit_metric:,
                     backpressure_metric: nil, ratelimited_counter: nil,
                     quota_warn: 80, quota_crit: 95, selector: nil, window: '5m',
                     title: 'Rate-limited consumer')
          validate!(datasource: datasource, consumer_label: consumer_label,
                    quota_metric: quota_metric, rate_limit_metric: rate_limit_metric,
                    quota_warn: quota_warn, quota_crit: quota_crit)

          # The two optional event-driven legs decide the row's tiling: with
          # both, four panels split third+third+third (gauge + rate share the
          # remaining width as thirds too); with neither, the gauge + rate sit
          # half/half. Uniform widths keep the row aligned (Gestalt).
          optional = [backpressure_metric, ratelimited_counter].compact.length
          width    = (optional >= 1 ? Theme.third : Theme.half)

          add_quota_gauge(row, datasource: datasource, consumer_label: consumer_label,
                          quota_metric: quota_metric, selector: selector,
                          warn: quota_warn, crit: quota_crit, width: width, title: title)

          add_derived_rate(row, datasource: datasource, consumer_label: consumer_label,
                           rate_limit_metric: rate_limit_metric, selector: selector, width: width)

          if backpressure_metric
            RateWithZeroFloor.add(row, datasource: datasource, counter_metric: backpressure_metric,
                                  group_by: [consumer_label], selector: selector, window: window,
                                  unit: 'ops', width: width, title: 'Back-pressure',
                                  id: :"samba_backpressure_#{slug(backpressure_metric)}")
          end

          return unless ratelimited_counter

          RateWithZeroFloor.add(row, datasource: datasource, counter_metric: ratelimited_counter,
                                group_by: [consumer_label], selector: selector, window: window,
                                unit: 'ops', width: width, title: '429 / secondary rate-limit',
                                id: :"samba_ratelimited_#{slug(ratelimited_counter)}")
        end

        # quotaPct — the load-bearing gauge. HIGHER = closer to the cap = worse,
        # so the defect ladder (green→amber→red) is exactly right. Continuous:
        # a live consumer always emits a quotaPct, so a no-data tile means the
        # consumer is gone, not "healthy 0" — we do NOT floor it.
        def self.add_quota_gauge(row, datasource:, consumer_label:, quota_metric:, selector:, warn:, crit:, width:, title:)
          expr  = "max#{Promql.by([consumer_label])}(#{quota_metric}#{Promql.braces(selector)})"
          steps = Theme.defect_steps(warn: warn.to_f, crit: crit.to_f)
          row.panel :samba_quota_pct, kind: :gauge, width: width, height: Theme::STAT_H do
            title "#{title} · quotaPct"
            unit 'percent'   # 0–100 share of the upstream rate budget
            min 0
            max 100
            description 'The single load-bearing knob: share of the upstream ' \
                        'rate budget this consumer is allowed to spend. ' \
                        'Amber as it nears the cap, red at the edge.'
            graph :none
            query 'A', expr, datasource: datasource, presence: :continuous,
                  legend: "{{#{consumer_label}}}"
            threshold steps: steps
          end
        end

        # The derived rate the samba consumer recomputes from the upstream
        # X-RateLimit-Limit header on every response. Continuous (a running
        # consumer always has a current derived rate).
        def self.add_derived_rate(row, datasource:, consumer_label:, rate_limit_metric:, selector:, width:)
          expr = "max#{Promql.by([consumer_label])}(#{rate_limit_metric}#{Promql.braces(selector)})"
          row.panel :samba_derived_rate, kind: :timeseries, width: width, height: Theme::TS_H do
            title 'Derived rate (X-RateLimit-Limit)'
            unit 'reqps'
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: :continuous,
                  legend: "{{#{consumer_label}}}"
          end
        end

        def self.validate!(datasource:, consumer_label:, quota_metric:, rate_limit_metric:, quota_warn:, quota_crit:)
          raise ArgumentError, 'QuotaPctSambaRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'QuotaPctSambaRow: consumer_label: required' if blank?(consumer_label)
          raise ArgumentError, 'QuotaPctSambaRow: quota_metric: required' if blank?(quota_metric)
          raise ArgumentError, 'QuotaPctSambaRow: rate_limit_metric: required' if blank?(rate_limit_metric)
          raise ArgumentError, "QuotaPctSambaRow: quota_warn must be < quota_crit (got #{quota_warn} / #{quota_crit})" \
            unless quota_warn.is_a?(Numeric) && quota_crit.is_a?(Numeric) && quota_warn < quota_crit
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_quota_gauge, :add_derived_rate, :validate!, :blank?, :slug
      end
    end
  end
end
