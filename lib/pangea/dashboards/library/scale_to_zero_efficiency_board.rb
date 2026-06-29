# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/sleep_wake_posture_row'
require 'pangea/dashboards/library/wake_event_timeline'
require 'pangea/dashboards/library/cost_at_rest_row'
require 'pangea/dashboards/library/autoscaler_pool_strip'

module Pangea
  module Dashboards
    module Library
      # The one-call operator dashboard for a SCALE-TO-ZERO workload fleet — the
      # breathing rhythm: sleep when idle, wake fast, save money at rest. It reads
      # the replica-count gauge (0 ↔ N) plus wake/cold-start signals, so it works
      # the day a fleet is wired for KEDA-on-zero / Knative-style scale-down.
      #
      # The triage STORY, top-to-bottom (Theme: defects → posture → history →
      # cost → autoscale):
      #
      #   Defects headline →  "is anything stuck awake, or is a cold-start too slow?"
      #   Posture          →  enrolled · asleep · awake · time-at-rest %
      #   Wake history     →  the 0 ↔ N step series + wake-event rate
      #   Cost at rest     →  footprint vs always-on baseline + savings %
      #   Autoscale        →  the pool that wakes the fleet (optional)
      #
      # Defects-first means the operator lands on "is the rhythm healthy?" before
      # any line chart — a workload pinned awake (never sleeping) or a cold-start
      # blowing its budget is the first thing the eye finds.
      #
      #   dash = Pangea::Dashboards::Library::ScaleToZeroEfficiencyBoard.build(
      #     id: :s2z, name: 'Scale-to-zero', datasource: 'metrics',
      #     replica_metric: 'kube_deployment_status_replicas',
      #     wake_counter: 'keda_scaledobject_activations_total',
      #     unit_cost: 0.12)
      module ScaleToZeroEfficiencyBoard
        # id/name:            dashboard id + human title
        # datasource:         (req) the metrics datasource uid
        # replica_metric:     replica-count gauge (0 ↔ N) — the breathing signal
        #                     (default a generic kube deployment replicas gauge)
        # max_replica_metric: per-workload max/desired gauge for the cost baseline
        # wake_counter:       *_total of wake/activation events (history overlay)
        # cold_start_metric:  cold-start latency gauge/seconds → a defect tile when
        #                     it exceeds cold_start_budget (omit to skip)
        # cold_start_budget:  seconds a cold start may take before it is a defect (default 30)
        # stuck_awake_after:  a workload awake longer than this (seconds) with no
        #                     traffic is a defect candidate; counts replicas>0 (default 1 = any)
        # unit_cost:          per-replica unit cost for the cost-at-rest row (default 1)
        # selector:           typed Hash/String matcher scoping the fleet
        # rest_window:        time-at-rest averaging window (default 24h)
        # consumer_scale:     optional autoscaler pool strip Hash (pool_roles/…)
        # group_by:           per-workload labels for the wake timeline (default %w[deployment])
        # window:             fleet-wide rate window (default 5m)
        def self.build(id:, datasource:, name: nil,
                       replica_metric: 'kube_deployment_status_replicas',
                       max_replica_metric: nil, wake_counter: nil,
                       cold_start_metric: nil, cold_start_budget: 30,
                       stuck_awake_after: 1, unit_cost: 1, selector: nil,
                       rest_window: '24h', consumer_scale: nil,
                       group_by: %w[deployment], window: '5m')
          validate!(id: id, datasource: datasource, replica_metric: replica_metric)
          braces = Pangea::Dashboards::Library::Promql.braces(selector)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · scale-to-zero")
          b.tags('pleme-io', 'scale-to-zero', 'breathe')

          # 1. Defects headline — pinned-awake fleet + slow cold starts, colour-flooded.
          signals = [{
            name: 'Awake (not at rest)',
            expr: "count(#{replica_metric}#{braces} >= #{stuck_awake_after})",
            warn: 1, crit: nil, unit: 'short',
            desc: 'Workloads currently scaled up — expected during traffic, a defect if the fleet should be idle.'
          }]
          unless blank?(cold_start_metric)
            signals << {
              name: 'Slow cold starts',
              expr: "count(#{cold_start_metric}#{braces} > #{cold_start_budget})",
              warn: 1, crit: 3, unit: 'short',
              desc: "Wakes whose cold start exceeded #{cold_start_budget}s — the latency cost of sleeping is too high."
            }
          end
          b.row('Status — is the breathing rhythm healthy?') do
            Library::StatusOverview.add(self, datasource: datasource, signals: signals)
          end

          # 2. Posture — enrolled · asleep · awake · time-at-rest %.
          b.row('Sleep/wake posture') do
            Library::SleepWakePostureRow.add(self, datasource: datasource, replica_metric: replica_metric,
                                             selector: selector, rest_window: rest_window)
          end

          # 3. Wake history — the 0 ↔ N step series + wake-event rate overlay.
          b.row('Wake history — replica 0 ↔ N') do
            Library::WakeEventTimeline.add(self, datasource: datasource, replica_metric: replica_metric,
                                           wake_counter: wake_counter, selector: selector,
                                           group_by: group_by, window: window)
          end

          # 4. Cost at rest — footprint vs always-on baseline + savings %.
          b.row('Cost at rest — savings vs always-on') do
            Library::CostAtRestRow.add(self, datasource: datasource, replica_metric: replica_metric,
                                       max_replica_metric: max_replica_metric, unit_cost: unit_cost,
                                       selector: selector)
          end

          # 5. Autoscale — the pool that wakes the fleet (optional).
          if consumer_scale && !consumer_scale.empty?
            cs = consumer_scale.transform_keys(&:to_sym)
            b.row('Autoscale — the pool that wakes the fleet') do
              Library::AutoscalerPoolStrip.add(self, datasource: datasource,
                                               pool_roles: cs.fetch(:pool_roles),
                                               max_metric: cs[:max_metric], current_metric: cs[:current_metric],
                                               error_metric: cs[:error_metric], selector: cs[:selector])
            end
          end

          b.build
        end

        def self.validate!(id:, datasource:, replica_metric:)
          raise ArgumentError, 'ScaleToZeroEfficiencyBoard: id: required' if blank?(id)
          raise ArgumentError, 'ScaleToZeroEfficiencyBoard: datasource: required' if blank?(datasource)
          raise ArgumentError, 'ScaleToZeroEfficiencyBoard: replica_metric: required' if blank?(replica_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
