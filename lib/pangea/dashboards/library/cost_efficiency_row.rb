# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The cost-EFFICIENCY row — the "am I paying for capacity I don't use?"
      # story. Three dollar series overlaid on one timeseries —
      #
      #   provisioned $  (what we're billed for)
      #   used $         (what the workload actually consumed)
      #   wasted $       (provisioned − used: the gap we're burning)
      #
      # — beside one allocation-efficiency `:gauge` (used / provisioned, a 0–1
      # liveness ratio: higher = healthier, more of the spend is doing work).
      # The wasted-$ band riding above the used-$ line IS the right-sizing
      # opportunity, read as a shape, not a number to compute.
      #
      # ── Why one timeseries (overlay), not three panels ──────────────────
      # The decision-relevant fact is the RELATIONSHIP between provisioned, used,
      # and the wasted gap — a relationship is read off one shared y-axis. Three
      # sibling panels force the eye to reconstruct the gap mentally. One overlay
      # is the data-ink-minimal rendering of "how much am I wasting?".
      #
      # ── Why :continuous (no floor) ──────────────────────────────────────
      # Provisioned/used/wasted are cost LEVELS (a derived rollup gauge), always
      # present once the workload exists — never event-driven counters. A genuine
      # $0 used is a real reading; an absent rollup should read "No data", not a
      # misleading floored 0. So no `or vector(0)`.
      #
      #   row 'Cost efficiency' do
      #     Pangea::Dashboards::Library::CostEfficiencyRow.add(
      #       self, datasource: 'vm', selector: { tenant: '$tenant' },
      #       provisioned_metric: 'cost_provisioned_dollars',
      #       used_metric: 'cost_used_dollars')
      #   end
      module CostEfficiencyRow
        # datasource:          (req) the metrics datasource uid
        # provisioned_metric:  (req) the provisioned-$ rollup gauge
        # used_metric:         (req) the used-$ rollup gauge
        # wasted_expr:         optional explicit wasted-$ expr (default
        #                      provisioned − used)
        # selector:            typed Hash/String matcher scoping the cost rollup
        # currency_unit:       Grafana unit for the $ series (default 'currencyUSD')
        # eff_warn / eff_crit: allocation-efficiency thresholds as RATIOS 0–1
        #                      (LOWER = worse; default 0.5 / 0.3 — below 50% amber,
        #                      below 30% red, since most of the spend is idle)
        # title_prefix:        optional per-panel title prefix
        def self.add(row, datasource:, provisioned_metric:, used_metric:, wasted_expr: nil,
                     selector: nil, currency_unit: 'currencyUSD', eff_warn: 0.5, eff_crit: 0.3,
                     title_prefix: nil)
          validate!(datasource: datasource, provisioned_metric: provisioned_metric, used_metric: used_metric)
          tp     = title_prefix ? "#{title_prefix} · " : ''
          braces = Promql.braces(selector)
          prov   = "sum(#{provisioned_metric}#{braces})"
          used   = "sum(#{used_metric}#{braces})"
          wasted = wasted_expr || "#{prov} - #{used}"

          add_overlay(row, datasource: datasource, prov: prov, used: used, wasted: wasted,
                      currency_unit: currency_unit, title: "#{tp}Provisioned vs used vs wasted $")
          add_efficiency_gauge(row, datasource: datasource, prov: prov, used: used,
                               eff_warn: eff_warn, eff_crit: eff_crit, title: "#{tp}Allocation efficiency")
        end

        # The three-$ overlay — provisioned / used / wasted on one shared axis.
        def self.add_overlay(row, datasource:, prov:, used:, wasted:, currency_unit:, title:)
          row.panel :cost_efficiency_overlay, kind: :timeseries, width: Theme.two_thirds, height: Theme::TS_H do
            title title
            unit currency_unit
            min 0
            graph :area
            description 'Provisioned (billed) vs used (consumed) vs wasted (the gap). ' \
                        'The wasted band above the used line is the right-sizing opportunity.'
            # cost LEVELS — always present, never event-driven; NOT floored.
            query 'A', prov,   datasource: datasource, presence: :continuous, legend: 'provisioned'
            query 'B', used,   datasource: datasource, presence: :continuous, legend: 'used'
            query 'C', wasted, datasource: datasource, presence: :continuous, legend: 'wasted'
          end
        end

        # used / provisioned — a 0–1 liveness ratio (higher = healthier; more of
        # the spend is doing work). LOWER = worse, so a red→amber→green ladder
        # built from the Theme palette (CRIT below crit, WARN below warn, OK above).
        def self.add_efficiency_gauge(row, datasource:, prov:, used:, eff_warn:, eff_crit:, title:)
          expr  = "(#{used}) / (#{prov})"
          steps = [
            { color: Theme::CRIT, value: nil },
            { color: Theme::WARN, value: eff_crit.to_f },
            { color: Theme::OK,   value: eff_warn.to_f }
          ]
          row.panel :cost_allocation_efficiency, kind: :gauge, width: Theme.third, height: Theme::STAT_H do
            title title
            unit 'percentunit'
            min 0
            max 1
            description 'Used / provisioned. Higher = healthier (more spend is doing work). ' \
                        'Red = most of what you pay for is idle.'
            query 'A', expr, datasource: datasource, presence: :continuous
            threshold steps: steps
          end
        end

        def self.validate!(datasource:, provisioned_metric:, used_metric:)
          raise ArgumentError, 'CostEfficiencyRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'CostEfficiencyRow: provisioned_metric: required' if blank?(provisioned_metric)
          raise ArgumentError, 'CostEfficiencyRow: used_metric: required' if blank?(used_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :add_overlay, :add_efficiency_gauge, :validate!, :blank?
      end
    end
  end
end
