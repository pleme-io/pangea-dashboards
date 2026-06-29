# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/red_sli_gauge_strip'

module Pangea
  module Dashboards
    module Library
      # The trust-boundary OUTCOMES row for an auth surface. Pairs the two
      # questions an operator asks at the front door onto one canvas:
      #
      #   1. **What is the auth verdict mix over time?** — ONE stacked
      #      timeseries of allowed / denied / error counts (the outcome label
      #      partitions the total via the typed grafana stacking override the
      #      same way ByPhaseStrip partitions phases — the band heights ARE the
      #      per-outcome rates, the envelope is total auth attempts/s). A spike
      #      of denied/error riding up the stack is the trust-boundary alarm.
      #   2. **Which auth method is denying, and how badly?** — a strip of
      #      per-method denial-rate gauges (RedSliGaugeStrip over the outcome
      #      label: denied+error increase / total increase), green→amber→red.
      #
      # Generic over any `*_auth_total{method=…,outcome=…}` counter. The author
      # supplies the metric name, the method label, the outcome label, and which
      # outcome values count as a denial; the component owns the typed PromQL.
      #
      #   row 'Auth outcomes' do
      #     Pangea::Dashboards::Library::AuthOutcomesRow.add(
      #       self, datasource: 'vm',
      #       auth_metric: 'gateway_auth_total',
      #       method_label: 'method', outcome_label: 'outcome',
      #       denied_outcomes: %w[denied error],
      #       methods: %w[token oauth saml k8s])
      #   end
      module AuthOutcomesRow
        # datasource:      (req) the metrics datasource uid
        # auth_metric:     (req) the *_auth_total counter (carries method+outcome)
        # method_label:    the auth-method label (default 'method')
        # outcome_label:   the verdict label (default 'outcome')
        # denied_outcomes: outcome values that count as a denial for the gauges
        #                  (default %w[denied error])
        # methods:         (req) non-empty Array of method values → one denial
        #                  gauge per method
        # selector:        optional typed Hash/String matcher scoping the metric
        # window:          rate/increase window (default 5m for the trend, 15m
        #                  for the gauge ratio)
        # warn / crit:     denial-ratio thresholds for the gauges (default
        #                  0.05 / 0.20 — 5% / 20% denied)
        def self.add(row, datasource:, auth_metric:, methods:,
                     method_label: 'method', outcome_label: 'outcome',
                     denied_outcomes: %w[denied error], selector: nil,
                     window: '5m', gauge_window: '15m', warn: 0.05, crit: 0.20)
          validate!(datasource: datasource, auth_metric: auth_metric,
                    method_label: method_label, outcome_label: outcome_label, methods: methods)

          add_outcome_stack(row, datasource: datasource, auth_metric: auth_metric,
                            outcome_label: outcome_label, selector: selector, window: window)

          # Per-method denial-rate gauges. RedSliGaugeStrip computes
          # (error-subset increase / total increase) per subsystem; here a
          # "subsystem" is a method and the error subset is the denied outcomes.
          subsystems = Array(methods).map { |m| { name: m.to_s, extra_selector: { method_label.to_sym => m.to_s } } }
          RedSliGaugeStrip.add(row, datasource: datasource, metric: auth_metric,
                               error_label_match: { outcome_label.to_sym => Array(denied_outcomes) },
                               subsystems: subsystems, window: gauge_window, warn: warn, crit: crit,
                               title_suffix: "denied (#{gauge_window})")
        end

        # Stacked allowed/denied/error timeseries — outcome partitions total.
        def self.add_outcome_stack(row, datasource:, auth_metric:, outcome_label:, selector:, window:)
          expr = Floor.zero(Promql.sum_rate(metric: auth_metric, window: window,
                                            group_by: [outcome_label], selector: selector))
          row.panel :"auth_outcomes_#{slug(auth_metric)}", kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title 'Auth outcomes /s (allowed · denied · error)'
            unit 'ops'
            min 0
            graph :area
            # Stacked: outcomes partition the total auth attempts — typed
            # grafana override (same seam ByPhaseStrip uses), degrades cleanly.
            options(grafana: { 'fieldConfig' => { 'defaults' => { 'custom' => { 'stacking' => { 'mode' => 'normal', 'group' => 'A' } } } } })
            query 'A', expr, datasource: datasource, presence: :event_driven, legend: "{{#{outcome_label}}}"
          end
        end

        def self.validate!(datasource:, auth_metric:, method_label:, outcome_label:, methods:)
          raise ArgumentError, 'AuthOutcomesRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'AuthOutcomesRow: auth_metric: required' if blank?(auth_metric)
          raise ArgumentError, 'AuthOutcomesRow: method_label: required' if blank?(method_label)
          raise ArgumentError, 'AuthOutcomesRow: outcome_label: required' if blank?(outcome_label)
          raise ArgumentError, 'AuthOutcomesRow: methods must be a non-empty Array' \
            unless methods.is_a?(::Array) && !methods.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_outcome_stack, :validate!, :blank?, :slug
      end
    end
  end
end
