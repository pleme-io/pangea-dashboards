# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/overdue_defect_tile'
require 'pangea/dashboards/library/golden_signals_row'
require 'pangea/dashboards/library/by_phase_strip'
require 'pangea/dashboards/library/webhook_latency_heatmap'
require 'pangea/dashboards/library/top_n_table'
require 'pangea/dashboards/library/log_windows'

module Pangea
  module Dashboards
    module Library
      # The dynamic-secret ROTATION-lifecycle board for a gateway's producers /
      # rotators. Defects-first, threaded overdue → rotation RED → producer
      # phase → staleness → offenders:
      #
      #   Status defects     →  rotations overdue + rotation-failure rate
      #   Rotation RED       →  rotations/s · failures · rotation latency
      #   Producer phase     →  by-phase distribution + active-producer count
      #   Staleness heatmap  →  the seconds-since-last-rotation distribution
      #   Top overdue        →  worst-N most-overdue producers offender table
      #   Logs               →  full + ERROR window + error rate
      #
      #   dash = Pangea::Dashboards::Library::RotationLifecycle.build(
      #     id: :rotation, name: 'Rotation Lifecycle', datasource: 'metrics',
      #     rotation_metric: 'rotation_total', rotation_latency_metric: 'rotation_seconds_bucket',
      #     producer_label: 'producer', phase_metric: 'producer_by_phase')
      module RotationLifecycle
        def self.build(id:, datasource:, name: nil, logs_datasource: nil,
                       selector: nil,
                       rotation_metric: 'rotation_total',
                       rotation_latency_metric: 'rotation_seconds_bucket',
                       result_label: 'result', error_results: %w[error failed],
                       producer_label: 'producer',
                       elapsed_metric: 'rotation_seconds_since_last',
                       interval_metric: 'rotation_configured_interval_seconds',
                       phase_metric: 'producer_by_phase', phase_label: 'phase',
                       active_metric: nil,
                       staleness_bucket_metric: 'rotation_staleness_seconds_bucket',
                       worst_n: 10, stream: nil, window: '5m')
          validate!(id: id, datasource: datasource, rotation_metric: rotation_metric,
                    rotation_latency_metric: rotation_latency_metric, elapsed_metric: elapsed_metric,
                    interval_metric: interval_metric)
          lds = logs_datasource || datasource
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · rotation lifecycle")
          b.tags('pleme-io', 'rotation-lifecycle')

          # 1. Status defects — overdue + failure rate.
          overdue_signal = Library::OverdueDefectTile.signal(
            elapsed_metric: elapsed_metric, interval_metric: interval_metric,
            name: 'Rotations overdue')
          fail_sel  = error_selector(selector, result_label, error_results)
          fail_expr = Floor.zero(Promql.sum_rate(metric: rotation_metric, window: window, selector: fail_sel))
          b.row('Status — rotation defects') do
            Library::StatusOverview.add(self, datasource: datasource, signals: [
              overdue_signal,
              { name: 'Rotation failures /s', expr: fail_expr, warn: 0.01, crit: 0.1, unit: 'ops',
                desc: 'Failed rotations per second. RED ⇒ a producer cannot rotate — the secret will go stale or expire.' }
            ])
          end

          # 2. Rotation RED — rate · failures · latency.
          b.row('Rotation — RED') do
            Library::GoldenSignalsRow.add(self, datasource: datasource,
              rate_metric: rotation_metric, latency_metric: rotation_latency_metric,
              error_selector: { result_label.to_sym => Array(error_results) },
              group_by: [producer_label])
          end

          # 3. Producer phase distribution.
          b.row('Producer phase distribution') do
            Library::ByPhaseStrip.add(self, datasource: datasource, phase_metric: phase_metric,
              phase_label: phase_label, settled_metric: active_metric, selector: selector,
              title: 'Producers by phase', settled_title: 'Active producers')
          end

          # 4. Staleness heatmap — seconds-since-last-rotation distribution.
          b.row('Rotation staleness distribution') do
            Library::WebhookLatencyHeatmap.add(self, datasource: datasource,
              histogram_metric: staleness_bucket_metric, selector: selector, window: window,
              title: 'Rotation staleness (seconds since last)')
          end

          # 5. Top overdue producers — rank by elapsed-since-last (the most stale).
          n = worst_n
          plabel = producer_label
          esel = selector
          emetric = elapsed_metric
          b.row('Top overdue producers') do
            Library::TopNTable.add(self, datasource: datasource, metric: emetric,
              group_by: [plabel], agg: :sum, n: n, selector: esel,
              title: "Top #{n} most-overdue producers")
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

        def self.validate!(id:, datasource:, rotation_metric:, rotation_latency_metric:, elapsed_metric:, interval_metric:)
          raise ArgumentError, 'RotationLifecycle: id: required' if blank?(id)
          raise ArgumentError, 'RotationLifecycle: datasource: required' if blank?(datasource)
          raise ArgumentError, 'RotationLifecycle: rotation_metric: required' if blank?(rotation_metric)
          raise ArgumentError, 'RotationLifecycle: rotation_latency_metric: required' if blank?(rotation_latency_metric)
          raise ArgumentError, 'RotationLifecycle: elapsed_metric: required' if blank?(elapsed_metric)
          raise ArgumentError, 'RotationLifecycle: interval_metric: required' if blank?(interval_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :error_selector, :validate!, :blank?
      end
    end
  end
end
