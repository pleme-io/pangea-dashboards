# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/red_sli_gauge_strip'
require 'pangea/dashboards/library/auth_outcomes_row'
require 'pangea/dashboards/library/latency_histogram_panel'
require 'pangea/dashboards/library/top_n_table'
require 'pangea/dashboards/library/log_windows'

module Pangea
  module Dashboards
    module Library
      # The trust-boundary board for a gateway's auth surface. Defects-first,
      # threaded denial → per-method failure → outcomes → latency → offenders:
      #
      #   Status defects     →  denial rate + error rate, colour-flooded
      #   Per-method SLI     →  one denial-rate gauge per auth method
      #   Auth outcomes      →  stacked allowed/denied/error + per-method gauges
      #   Auth latency tail  →  p99 auth-decision latency by method
      #   Top denied         →  worst-N denied identities offender table
      #   Logs               →  full + ERROR window + error rate
      #
      #   dash = Pangea::Dashboards::Library::AuthMethodHealth.build(
      #     id: :auth_health, name: 'Auth Method Health', datasource: 'metrics',
      #     auth_metric: 'gateway_auth_total', method_label: 'method',
      #     outcome_label: 'outcome', methods: %w[token oauth saml k8s])
      module AuthMethodHealth
        def self.build(id:, datasource:, name: nil, logs_datasource: nil,
                       selector: nil,
                       auth_metric: 'gateway_auth_total',
                       method_label: 'method', outcome_label: 'outcome',
                       methods: %w[token oauth saml k8s],
                       denied_outcomes: %w[denied error],
                       latency_metric: 'gateway_auth_decision_seconds_bucket',
                       identity_label: 'identity', worst_n: 10,
                       stream: nil, window: '5m')
          validate!(id: id, datasource: datasource, auth_metric: auth_metric,
                    method_label: method_label, outcome_label: outcome_label, methods: methods)
          lds = logs_datasource || datasource
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · auth method health")
          b.tags('pleme-io', 'auth-method-health')

          # 1. Status defects — denial + error rate.
          denied_match = denied_selector(selector, outcome_label, denied_outcomes)
          denied_expr  = Floor.zero(Promql.sum_rate(metric: auth_metric, window: window, selector: denied_match))
          total_expr   = Floor.zero(Promql.sum_rate(metric: auth_metric, window: window, selector: selector))
          b.row('Status — trust-boundary defects') do
            Library::StatusOverview.add(self, datasource: datasource, signals: [
              { name: 'Denials /s', expr: denied_expr, warn: 0.5, crit: 5, unit: 'ops',
                desc: 'Auth denials per second across all methods. A surge ⇒ a credential rollout broke or an attack is in progress.' },
              { name: 'Auth attempts /s', expr: total_expr, warn: 1_000_000, unit: 'ops',
                desc: 'Total auth attempts per second — context for the denial rate (no threshold; informational).' }
            ])
          end

          # 2. Per-method SLI — denial-rate gauges.
          subsystems = Array(methods).map { |m| { name: m.to_s, extra_selector: merge_method(selector, method_label, m) } }
          b.row('SLI — denial rate per method') do
            Library::RedSliGaugeStrip.add(self, datasource: datasource, metric: auth_metric,
              error_label_match: { outcome_label.to_sym => Array(denied_outcomes) },
              subsystems: subsystems, title_suffix: 'denied (15m)')
          end

          # 3. Auth outcomes — stacked + per-method gauges.
          b.row('Auth outcomes') do
            Library::AuthOutcomesRow.add(self, datasource: datasource, auth_metric: auth_metric,
              methods: methods, method_label: method_label, outcome_label: outcome_label,
              denied_outcomes: denied_outcomes, selector: selector, window: window)
          end

          # 4. Auth-decision latency tail by method.
          b.row('Auth decision latency') do
            Library::LatencyHistogramPanel.add(self, datasource: datasource,
              bucket_metric: latency_metric, group_by: [method_label], quantiles: [0.95, 0.99],
              window: window, selector: selector, width: Pangea::Dashboards::Theme.full,
              title: 'Auth decision latency p99 by method')
          end

          # 5. Top denied identities.
          n = worst_n
          ilabel = identity_label
          metric = auth_metric
          dsel = denied_match
          b.row('Top denied identities') do
            Library::TopNTable.add(self, datasource: datasource, metric: metric,
              group_by: [ilabel], agg: :increase, n: n, window: '1h',
              selector: dsel, title: "Top #{n} denied identities")
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

        def self.denied_selector(selector, outcome_label, denied_outcomes)
          fr = { outcome_label.to_sym => Array(denied_outcomes) }
          case selector
          when ::Hash then selector.merge(fr)
          when nil then fr
          else
            body = [Promql.selector_body(selector), Promql.selector_body(fr)].reject { |x| x.nil? || x.empty? }
            body.join(',')
          end
        end

        def self.merge_method(selector, method_label, method)
          base = selector.is_a?(::Hash) ? selector.dup : {}
          base.merge(method_label.to_sym => method.to_s)
        end

        def self.validate!(id:, datasource:, auth_metric:, method_label:, outcome_label:, methods:)
          raise ArgumentError, 'AuthMethodHealth: id: required' if blank?(id)
          raise ArgumentError, 'AuthMethodHealth: datasource: required' if blank?(datasource)
          raise ArgumentError, 'AuthMethodHealth: auth_metric: required' if blank?(auth_metric)
          raise ArgumentError, 'AuthMethodHealth: method_label: required' if blank?(method_label)
          raise ArgumentError, 'AuthMethodHealth: outcome_label: required' if blank?(outcome_label)
          raise ArgumentError, 'AuthMethodHealth: methods must be a non-empty Array' \
            unless methods.is_a?(::Array) && !methods.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :denied_selector, :merge_method, :validate!, :blank?
      end
    end
  end
end
