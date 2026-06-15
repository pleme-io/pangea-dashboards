# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/floor_ceiling_envelope'
require 'pangea/dashboards/library/util_setpoint_band'
require 'pangea/dashboards/library/rate_with_zero_floor'

module Pangea
  module Dashboards
    module Library
      # The BREATHABILITY story for ONE breathe-managed target, as a reusable
      # composite row. Pairs the two questions an operator asks about a
      # homeostatic workload onto one canvas, both answered from breathe's OWN
      # exported metrics (no cadvisor / kube-state dependency — breathe IS the
      # observer, so this works for ANY band: a CNPG Cluster, a Deployment, or a
      # label-selected ephemeral pod group like a CI runner):
      #
      #   1. **Is breathe holding the REAL workload in its band?** — the extended
      #      FloorCeilingEnvelope with `usage_metric: breathe_band_used`: the
      #      observed working-set (U) riding inside [floor, current_limit, ceiling].
      #      Used hugging the limit ⇒ about to grow (OOM headroom shrinking); used
      #      near the floor ⇒ reclaimable over-provisioning. This is the panel that
      #      makes "breathe makes OOM impossible" legible — the carve tracking the
      #      real workload.
      #   2. **Is it in band?** — UtilSetpointBand: util_ratio vs the setpoint the
      #      controller carves toward.
      #   3. (default on) **What is it doing?** — carves/s + deferred-crossings/s
      #      overlaid (RateWithZeroFloor): a grow/shrink carve, or a deferred
      #      crossing the DisruptionPolicy refused (the safe "would shrink but
      #      won't restart-kill a running job" beat).
      #
      # Distilled from the per-dimension envelope+util panels hand-paired across
      # breathe.rb (memory/cpu bands) and the CI-runner dashboard — every
      # breathe target wants exactly this triple, folded over its band identity.
      # The author supplies only the band selector + the value unit; the
      # component owns the typed PromQL, the metric names (breathe defaults,
      # overridable), and the layout.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Runner memory breathability' do
      #     Pangea::Dashboards::Library::BreathabilityRow.add(
      #       self, datasource: 'vm',
      #       band: { name: 'arc-runner', dim: 'memory' }, unit: 'bytes',
      #       legend_labels: '{{name}}')
      #   end
      module BreathabilityRow
        # datasource:    (req) the metrics datasource uid
        # band:          (req) the breathe band selector folded into every series
        #                (typed Hash, e.g. { name: 'arc-runner', dim: 'memory' } —
        #                NOTE: select by `name`+`dim`; the band's target namespace
        #                lands in `exported_namespace` under honor_labels=false,
        #                while `namespace` is the breathe-controller pod's ns)
        # unit:          (req) the value unit for the envelope ('bytes' | 'short'
        #                for cpu millicores → use 'short', etc.)
        # legend_labels: per-series legend suffix (default '{{name}}')
        # show_activity: emit the carves/s + deferred/s panel (default true)
        # *_metric:      breathe metric names (overridable for a different observer)
        def self.add(row, datasource:, band:, unit: 'bytes', legend_labels: '{{name}}',
                     show_activity: true,
                     used_metric: 'breathe_band_used',
                     limit_metric: 'breathe_band_current_limit',
                     floor_metric: 'breathe_band_floor',
                     ceiling_metric: 'breathe_band_ceiling',
                     util_metric: 'breathe_band_util_ratio',
                     setpoint_metric: 'breathe_band_setpoint_ratio',
                     carves_metric: 'breathe_carves_total',
                     deferred_metric: 'breathe_deferred_total')
          validate!(datasource: datasource, band: band, unit: unit)

          # 1. the real workload riding inside its carved [floor, limit, ceiling].
          FloorCeilingEnvelope.add(row, datasource: datasource,
            limit_metric: limit_metric, floor_metric: floor_metric,
            ceiling_metric: ceiling_metric, usage_metric: used_metric,
            dim: band, legend_labels: legend_labels, unit: unit)

          # 2. util vs the setpoint the controller carves toward.
          UtilSetpointBand.add(row, datasource: datasource,
            util_metric: util_metric, setpoint_metric: setpoint_metric,
            dim: band, legend_labels: legend_labels)

          # 3. carve + deferred-crossing activity (one timeseries, two floored
          #    rates) — a grow/shrink, or a refused crossing (the safe deferral).
          return unless show_activity

          carves_expr   = Floor.zero(Promql.sum_rate(metric: carves_metric, window: '5m',
                                                      group_by: %w[dir], selector: band))
          deferred_expr = Floor.zero(Promql.sum_rate(metric: deferred_metric, window: '5m',
                                                      group_by: %w[class], selector: band))
          row.panel :breathe_activity, kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title 'carve + deferred activity'
            unit 'cps' # carves/deferrals per second
            graph :area
            query 'A', carves_expr,   datasource: datasource, presence: :event_driven, legend: 'carve {{dir}}'
            query 'B', deferred_expr, datasource: datasource, presence: :event_driven, legend: 'deferred {{class}}'
          end
        end

        def self.validate!(datasource:, band:, unit:)
          raise ArgumentError, 'BreathabilityRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'BreathabilityRow: band: required (the breathe band selector)' if blank?(band)
          raise ArgumentError, 'BreathabilityRow: unit: required' if blank?(unit)
        end

        def self.blank?(v)
          return true if v.nil?
          return v.empty? if v.is_a?(::Hash) || v.is_a?(::Array)

          v.to_s.strip.empty?
        end
        private_class_method :validate!, :blank?
      end
    end
  end
end
