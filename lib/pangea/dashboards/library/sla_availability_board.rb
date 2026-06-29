# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/error_budget_burn_strip'
require 'pangea/dashboards/library/burn_rate_matrix'
require 'pangea/dashboards/library/availability_heatmap'

module Pangea
  module Dashboards
    module Library
      # THE FLEET ERROR-BUDGET WALL — the business-tier SLA board. Per-member
      # budget-remaining gauges open it (the fuel-gauge headline: who is closest
      # to breach?), a per-member × multi-window burn matrix gives the SRE
      # diagnosis (fast spike vs slow leak per member), and a per-member
      # availability heatmap from synthetic probes shows uptime over time. The
      # whole fleet's SLA posture in one pane — the Viggy provable-outcomes
      # promise rendered as a continuously-attested headline.
      #
      # The triage STORY, top-to-bottom:
      #
      #   Budget remaining  →  per-member fuel gauges (closest-to-breach first)
      #   Burn matrix       →  per-member × 1h/6h/24h/72h burn (the SRE diagnosis)
      #   Availability      →  per-member uptime heatmap from synthetic probes
      #
      #   dash = Pangea::Dashboards::Library::SlaAvailabilityBoard.build(
      #     id: :fleet_sla, name: 'Fleet SLA', datasource: 'vm',
      #     topology_label: 'cell', members: %w[cell-a cell-b],
      #     sli_good_metric: 'http_requests_total{code!~"5.."}',
      #     sli_total_metric: 'http_requests_total',
      #     probe_up_metric: 'probe_success', objective: 0.999)
      module SlaAvailabilityBoard
        # id/name:          dashboard id + human title
        # datasource:       (req) the metrics datasource uid
        # topology_label:   the per-member label (default 'cell')
        # members:          member values for the budget strip (hand-listed —
        #                   panel repeat: is a renderer gap, catalog §9.4)
        # sli_good_metric:  (req) GOOD-events *_total counter (already filtered)
        # sli_total_metric: (req) TOTAL-events *_total counter
        # probe_up_metric:  the synthetic-probe up gauge for the availability heatmap
        # objective:        SLO target in (0,1) (default 0.999)
        # budget_window:    budget-remaining window (default 30d)
        # windows:          burn windows fast→slow (default 1h/6h/24h/72h)
        # probe_selector:   optional matcher scoping the probe population
        def self.build(id:, datasource:, sli_good_metric:, sli_total_metric:, name: nil,
                       topology_label: 'cell', members: [],
                       probe_up_metric: 'probe_success', objective: 0.999,
                       budget_window: '30d', windows: %w[1h 6h 24h 72h], probe_selector: nil)
          validate!(id: id, datasource: datasource, topology_label: topology_label,
                    sli_good_metric: sli_good_metric, sli_total_metric: sli_total_metric)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · SLA / availability")
          b.tags('pleme-io', 'sla-availability')

          # 1. Budget-remaining strip — per-member fuel gauges (worst first).
          unless Array(members).empty?
            b.row('Error budget remaining') do
              Library::ErrorBudgetBurnStrip.add(self, datasource: datasource, topology_label: topology_label,
                                                members: members, sli_good_metric: sli_good_metric,
                                                sli_total_metric: sli_total_metric, objective: objective,
                                                budget_window: budget_window)
            end
          end

          # 2. Burn matrix — per-member × multi-window burn (the SRE diagnosis).
          b.row('Burn rate matrix') do
            Library::BurnRateMatrix.add(self, datasource: datasource, topology_label: topology_label,
                                        sli_good_metric: sli_good_metric, sli_total_metric: sli_total_metric,
                                        objective: objective, windows: windows)
          end

          # 3. Availability heatmap — per-member uptime over time.
          b.row('Availability over time') do
            Library::AvailabilityHeatmap.add(self, datasource: datasource, topology_label: topology_label,
                                             probe_up_metric: probe_up_metric, selector: probe_selector)
          end

          b.build
        end

        def self.validate!(id:, datasource:, topology_label:, sli_good_metric:, sli_total_metric:)
          raise ArgumentError, 'SlaAvailabilityBoard: id: required' if blank?(id)
          raise ArgumentError, 'SlaAvailabilityBoard: datasource: required' if blank?(datasource)
          raise ArgumentError, 'SlaAvailabilityBoard: topology_label: required' if blank?(topology_label)
          raise ArgumentError, 'SlaAvailabilityBoard: sli_good_metric: required' if blank?(sli_good_metric)
          raise ArgumentError, 'SlaAvailabilityBoard: sli_total_metric: required' if blank?(sli_total_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
