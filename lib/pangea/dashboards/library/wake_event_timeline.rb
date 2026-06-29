# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The WAKE-EVENT timeline — the scale-to-zero breathing rhythm as a step
      # series. ONE timeseries per-workload replica count (`0 ↔ N`) drawn with
      # STEP interpolation (a replica count is a discrete level held until the
      # next scale event, NOT an interpolated slope), overlaid with a floored
      # wake-event rate so a tall step-up coincides with a wake spike. Read
      # left-to-right it IS the sleep/wake history: flat at 0 = asleep, a vertical
      # step to N = a wake, the plateau = serving, the step back to 0 = sleep.
      #
      # ── Why step interpolation via options(grafana:) ─────────────────────
      # Replica count is a piecewise-constant signal — Grafana's default linear
      # interpolation would draw a misleading diagonal RAMP between a sleep (0)
      # and a wake (N) where the truth is an instantaneous jump. `lineInterpolation:
      # 'stepAfter'` (set through the typed options(grafana:) fieldConfig escape
      # hatch — the same seam ByPhaseStrip uses) draws the honest staircase.
      # DEGRADED-FORM NOTE: the renderer has no first-class step-line attribute;
      # this rides the additive grafana fieldConfig override. A renderer that
      # ignores the key degrades gracefully to a (still-correct, if ramped) line.
      #
      # ── Why replicas are :continuous, wakes are :event_driven (floored) ──
      # Replica count is a gauge present whenever the workload object exists — a
      # genuine 0 (asleep) is the healthy idle reading, an absent workload is
      # rightly "No data". Wake events ARE a counter, so the wake-rate leg IS
      # floored (an idle period reads a true 0 wakes/s, never no-data).
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Wake history' do
      #     Pangea::Dashboards::Library::WakeEventTimeline.add(
      #       self, datasource: 'vm',
      #       replica_metric: 'kube_deployment_status_replicas',
      #       wake_counter: 'keda_scaledobject_activations_total',
      #       group_by: %w[deployment])
      #   end
      module WakeEventTimeline
        # datasource:     (req) the metrics datasource uid
        # replica_metric: (req) replica-count gauge (0 ↔ N) per workload
        # wake_counter:   *_total of wake/activation events — the overlaid rate
        #                 (omit to draw the step series alone)
        # selector:       typed Hash/String matcher applied to both series
        # group_by:       labels to break per-workload (default %w[deployment])
        # window:         wake-rate window (default 5m)
        def self.add(row, datasource:, replica_metric:, wake_counter: nil,
                     selector: nil, group_by: %w[deployment], window: '5m')
          validate!(datasource: datasource, replica_metric: replica_metric)
          braces = Promql.braces(selector)
          gb     = Promql.by(group_by)
          legend = default_legend(group_by)
          replicas_expr = "sum#{gb}(#{replica_metric}#{braces})"
          wake_expr = wake_counter ? Floor.zero(Promql.sum_rate(metric: wake_counter, window: window,
                                                               group_by: group_by, selector: selector)) : nil
          row.panel :wake_event_timeline, kind: :timeseries, width: Theme.full, height: Theme::TS_H do
            title 'replica count (0 ↔ N) + wake events'
            unit 'short'
            min 0
            graph :area
            # DEGRADED renderer gap: no first-class step-line attribute — the
            # honest piecewise-constant staircase rides the typed grafana
            # fieldConfig escape hatch; a renderer ignoring it degrades to a line.
            options(grafana: { fieldConfig: { defaults: { custom: { lineInterpolation: 'stepAfter' } } } })
            query 'A', replicas_expr, datasource: datasource, presence: :continuous, legend: legend
            query 'B', wake_expr, datasource: datasource, presence: :event_driven, legend: "wakes/s #{legend}" if wake_expr
          end
        end

        def self.default_legend(group_by)
          gb = Array(group_by).compact.map(&:to_s).reject(&:empty?)
          gb.empty? ? nil : gb.map { |l| "{{#{l}}}" }.join('/')
        end

        def self.validate!(datasource:, replica_metric:)
          raise ArgumentError, 'WakeEventTimeline: datasource: required' if blank?(datasource)
          raise ArgumentError, 'WakeEventTimeline: replica_metric: required' if blank?(replica_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :default_legend, :validate!, :blank?
      end
    end
  end
end
