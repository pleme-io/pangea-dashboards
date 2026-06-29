# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/cost_attribution_row'
require 'pangea/dashboards/library/cost_efficiency_row'
require 'pangea/dashboards/library/capacity_headroom_stat'
require 'pangea/dashboards/library/savings_realized_strip'
require 'pangea/dashboards/library/top_n_table'

module Pangea
  module Dashboards
    module Library
      # The one-call FinOps board — cost as a first-class SATURATION axis (spend
      # is meaningless without the utilisation it bought). The story:
      #
      #   Budget headline (defects)  →  cost attribution by dimension  →
      #   cost-efficiency (provisioned vs used vs wasted)  →  fleet
      #   capacity-headroom gauges  →  realized savings  →  right-sizing offenders
      #
      # ── Why defects-first on a cost board ───────────────────────────────
      # The headline is over-budget defects (spend over the monthly budget,
      # forecast over budget, a cost anomaly) — the Viggy CostBudget promessa as
      # a colour-flooded strip. The operator lands on "are we over?" before any
      # attribution chart. Everything below is drill-down ("where, and how do we
      # fix it?").
      #
      #   dash = Pangea::Dashboards::Library::CostSaturationBoard.build(
      #     id: :fleet_cost, name: 'Fleet cost', datasource: 'vm',
      #     cost_metric: 'cost_used_dollars', attribution_label: 'tenant',
      #     provisioned_metric: 'cost_provisioned_dollars', used_metric: 'cost_used_dollars',
      #     savings: { 'Spot' => 'sum(savings_spot_dollars)' },
      #     headroom_gauges: [{ title: 'CPU headroom', expr: 'fleet_cpu_headroom_ratio',
      #                         unit: 'percentunit', floor: 0.1, ok: 0.3 }])
      module CostSaturationBoard
        # id/name:             dashboard id + human title
        # datasource:          (req) the metrics datasource uid
        # cost_metric:         (req) the $-spend rollup gauge
        # attribution_label:   (req) the label cost is partitioned + ranked by
        # selector:            typed Hash/String matcher scoping the rollup
        # signals:             extra over-budget StatusOverview defect signals
        #                      (merged after any built-in budget tile)
        # budget_expr/budget_limit: build a "spend over budget" defect tile when
        #                      both are given (expr = current spend, limit = $ cap)
        # provisioned_metric/used_metric: the cost-efficiency row (both needed)
        # headroom_gauges:     Array of { title:, expr:, unit:, floor:, warn:, ok: }
        #                      → fleet capacity-headroom stats (CapacityHeadroomStat)
        # savings:             Hash{ lever => $-saved expr } → realized-savings strip
        # interruption_metric: spot-interruption counter for the savings strip
        # rightsizing_metric:  a per-entity waste/over-provision metric → top-N
        #                      right-sizing offenders (optional)
        # currency_unit:       Grafana $ unit (default 'currencyUSD')
        # top_n:               attribution + offenders top-N (default 10)
        def self.build(id:, datasource:, cost_metric:, attribution_label:, name: nil, selector: nil,
                       signals: [], budget_expr: nil, budget_limit: nil,
                       provisioned_metric: nil, used_metric: nil,
                       headroom_gauges: [], savings: nil, interruption_metric: nil,
                       rightsizing_metric: nil, currency_unit: 'currencyUSD', top_n: 10)
          validate!(id: id, datasource: datasource, cost_metric: cost_metric,
                    attribution_label: attribution_label)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · cost & saturation")
          b.tags('pleme-io', 'cost-saturation')

          # 1. Budget headline — over-budget defects.
          budget_signal = if budget_expr && budget_limit
                            [{
                              name: 'Spend over budget',
                              expr: "count((#{budget_expr}) > #{budget_limit})",
                              warn: 1, crit: 1,
                              unit: 'short',
                              desc: "Cost rollups over the #{budget_limit} budget. RED ⇒ over budget."
                            }]
                          else
                            []
                          end
          all_signals = budget_signal + Array(signals)
          unless all_signals.empty?
            b.row('Budget — are we over?') do
              Library::StatusOverview.add(self, datasource: datasource, signals: all_signals)
            end
          end

          # 2. Cost attribution by dimension (+ top-N spenders).
          b.row("Attribution — spend by #{attribution_label}") do
            Library::CostAttributionRow.add(self, datasource: datasource, cost_metric: cost_metric,
                                            attribution_label: attribution_label, selector: selector,
                                            currency_unit: currency_unit, top_n: top_n)
          end

          # 3. Cost efficiency — provisioned vs used vs wasted (both metrics needed).
          if provisioned_metric && used_metric
            b.row('Efficiency — provisioned vs used vs wasted') do
              Library::CostEfficiencyRow.add(self, datasource: datasource,
                                             provisioned_metric: provisioned_metric, used_metric: used_metric,
                                             selector: selector, currency_unit: currency_unit)
            end
          end

          # 4. Fleet capacity-headroom gauges (optional list).
          unless Array(headroom_gauges).empty?
            b.row('Fleet capacity headroom') do
              Array(headroom_gauges).each do |g|
                h = g.transform_keys(&:to_sym)
                Library::CapacityHeadroomStat.add(self, datasource: datasource, expr: h.fetch(:expr),
                                                  unit: h.fetch(:unit, 'percentunit'), floor: h.fetch(:floor),
                                                  warn: h[:warn], ok: h.fetch(:ok), title: h.fetch(:title))
              end
            end
          end

          # 5. Realized savings (optional).
          if savings
            b.row('Realized savings') do
              Library::SavingsRealizedStrip.add(self, datasource: datasource, savings: savings,
                                                interruption_metric: interruption_metric, selector: selector,
                                                currency_unit: currency_unit)
            end
          end

          # 6. Right-sizing offenders (optional) — the worst over-provisioned
          # entities. agg: :sum (waste is a level to sum, not a counter to rate).
          if rightsizing_metric
            b.row('Right-sizing offenders') do
              Library::TopNTable.add(self, datasource: datasource, metric: rightsizing_metric,
                                     group_by: [attribution_label.to_s], agg: :sum, n: top_n.to_i,
                                     selector: selector, title: "Top #{top_n.to_i} right-sizing offenders")
            end
          end

          b.build
        end

        def self.validate!(id:, datasource:, cost_metric:, attribution_label:)
          raise ArgumentError, 'CostSaturationBoard: id: required' if blank?(id)
          raise ArgumentError, 'CostSaturationBoard: datasource: required' if blank?(datasource)
          raise ArgumentError, 'CostSaturationBoard: cost_metric: required' if blank?(cost_metric)
          raise ArgumentError, 'CostSaturationBoard: attribution_label: required' if blank?(attribution_label)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
