# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The COST-AT-REST row — the money side of scale-to-zero: what the fleet
      # ACTUALLY costs while it breathes (sleeping when idle) versus what it WOULD
      # cost pinned always-on, and the savings % that gap represents. Three reads
      # on one canvas:
      #
      #   1. **Footprint at rest vs always-on baseline** — one timeseries with two
      #      lines: actual `Σ replicas × unit_cost` (what we pay as it sleeps/wakes)
      #      and the always-on baseline `Σ enrolled × max_replicas × unit_cost`
      #      (what pinning every workload up would cost). The gap between them IS
      #      the realized scale-to-zero saving, drawn over time.
      #   2. **Savings %** — `1 - actual/baseline`, a liveness `:stat` (higher =
      #      more saved). A fleet that never sleeps reads amber (no savings).
      #
      # ── Why the cost is `replicas × unit_cost` (a derived rollup) ─────────
      # There is rarely a direct $ metric per workload; the generic, always-
      # available shape is replica-count × a per-replica unit cost the operator
      # supplies (a scalar, or a per-workload cost gauge metric). This is the same
      # "spend = capacity bought" framing CostSaturationBoard uses, scoped to the
      # scale-to-zero fleet.
      #
      # ── Why actual is :continuous, derived from a gauge ──────────────────
      # The replica gauge exists whenever the workloads exist — a genuine $0
      # (all asleep) is a real, excellent reading and an absent fleet is rightly
      # "No data". The cost is a continuous derivation of that gauge, never a
      # floored counter rate.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Cost at rest' do
      #     Pangea::Dashboards::Library::CostAtRestRow.add(
      #       self, datasource: 'vm',
      #       replica_metric: 'kube_deployment_status_replicas',
      #       max_replica_metric: 'kube_deployment_spec_replicas',
      #       unit_cost: 0.12, selector: { namespace: 'apps' }, currency: 'currencyUSD')
      #   end
      module CostAtRestRow
        # datasource:         (req) the metrics datasource uid
        # replica_metric:     (req) current replica-count gauge (0 ↔ N) per workload
        # max_replica_metric: per-workload max/desired replicas gauge for the
        #                     always-on baseline (omit → baseline = enrolled count
        #                     × 1 replica each)
        # unit_cost:          per-replica unit cost — a numeric scalar (default 1)
        #                     multiplied into both legs
        # selector:           typed Hash/String matcher scoping the fleet
        # currency:           Grafana unit for the cost legs (default 'currencyUSD')
        def self.add(row, datasource:, replica_metric:, max_replica_metric: nil,
                     unit_cost: 1, selector: nil, currency: 'currencyUSD')
          validate!(datasource: datasource, replica_metric: replica_metric, unit_cost: unit_cost)
          braces = Promql.braces(selector)
          uc     = unit_cost
          actual_expr   = "sum(#{replica_metric}#{braces}) * #{uc}"
          baseline_expr = if blank?(max_replica_metric)
                            "count(#{replica_metric}#{braces}) * #{uc}"
                          else
                            "sum(#{max_replica_metric}#{braces}) * #{uc}"
                          end

          # 1. Footprint at rest vs always-on baseline — the gap is the saving.
          row.panel :cost_at_rest, kind: :timeseries, width: Theme.two_thirds, height: Theme::TS_H do
            title 'footprint at rest vs always-on baseline'
            unit currency
            min 0
            graph :area
            query 'A', actual_expr,   datasource: datasource, presence: :continuous, legend: 'actual (at rest)'
            query 'B', baseline_expr, datasource: datasource, presence: :continuous, legend: 'always-on baseline'
          end

          # 2. Savings % — 1 - actual/baseline (liveness: higher = more saved).
          savings_expr = "1 - ((#{actual_expr}) / clamp_min(#{baseline_expr}, 1))"
          row.panel :cost_savings_pct, kind: :stat, width: Theme.third, height: Theme::STAT_H do
            title 'savings vs always-on'
            unit 'percentunit'
            min 0
            max 1
            description 'Realized scale-to-zero saving — the fraction of always-on cost avoided by sleeping when idle. Higher = better.'
            display :value
            graph :area
            query 'A', savings_expr, datasource: datasource, presence: :continuous
            threshold steps: Theme.liveness_steps(ok: 0.25)
          end
        end

        def self.validate!(datasource:, replica_metric:, unit_cost:)
          raise ArgumentError, 'CostAtRestRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'CostAtRestRow: replica_metric: required' if blank?(replica_metric)
          raise ArgumentError, 'CostAtRestRow: unit_cost: must be a positive number' \
            unless unit_cost.is_a?(::Numeric) && unit_cost.positive?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
