# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/top_n_table'

module Pangea
  module Dashboards
    module Library
      # The cost-ATTRIBUTION row — "where is the spend going, and who spends the
      # most?". A STACKED $-over-time timeseries broken down by an attribution
      # label (tenant / team / service) beside a top-N spenders `:table`
      # delegated to the shipped TopNTable atom. The stack shows the spend
      # COMPOSITION over time (whose share is growing); the table names the worst
      # spenders RIGHT NOW (whom to talk to).
      #
      # ── Why stacked (options grafana stacking) ──────────────────────────
      # The attribution label PARTITIONS the total — every dollar belongs to
      # exactly one tenant/team/service, so the per-label series SUM to the total.
      # A stacked area is the honest encoding of a partition-over-time: the band
      # heights ARE the per-label spend and the envelope IS the total bill.
      # Unstacked lines would imply the series are independent and hide the total.
      # Stacking is set through the typed options(grafana:) escape hatch
      # (fieldConfig custom stacking — the same seam ByPhaseStrip uses); it
      # degrades to a normal multi-series timeseries on any backend that ignores
      # the override.
      #
      # ── Why :continuous (no floor) ──────────────────────────────────────
      # Cost is a derived-rollup LEVEL, always present once the rollup exists —
      # never an event-driven counter. A genuine $0 for a label is real; an absent
      # rollup should read "No data". So no `or vector(0)`.
      #
      # ── Why delegate the table to TopNTable ─────────────────────────────
      # "Top-N spenders" IS the worst-offenders shape TopNTable already owns
      # (topk over an aggregated metric). Re-implementing it here would duplicate
      # the primitive (prime directive: solve-once). The row passes the cost
      # metric + attribution label through to TopNTable with agg: :sum (cost is a
      # level to sum, not a counter to rate).
      #
      #   row 'Cost attribution' do
      #     Pangea::Dashboards::Library::CostAttributionRow.add(
      #       self, datasource: 'vm', cost_metric: 'cost_used_dollars',
      #       attribution_label: 'tenant', selector: { env: '$env' }, top_n: 10)
      #   end
      module CostAttributionRow
        # datasource:        (req) the metrics datasource uid
        # cost_metric:       (req) the $-spend rollup gauge
        # attribution_label: (req) the label to partition + rank by
        #                    (tenant / team / service)
        # selector:          typed Hash/String matcher scoping the cost rollup
        # currency_unit:     Grafana unit for the $ series (default 'currencyUSD')
        # top_n:             how many spenders the table ranks (default 10)
        # title_prefix:      optional per-panel title prefix
        def self.add(row, datasource:, cost_metric:, attribution_label:, selector: nil,
                     currency_unit: 'currencyUSD', top_n: 10, title_prefix: nil)
          validate!(datasource: datasource, cost_metric: cost_metric, attribution_label: attribution_label, top_n: top_n)
          tp    = title_prefix ? "#{title_prefix} · " : ''
          label = attribution_label.to_s

          add_stack(row, datasource: datasource, cost_metric: cost_metric, label: label,
                    selector: selector, currency_unit: currency_unit,
                    title: "#{tp}Spend by #{label} (stacked)")

          # Top-N spenders — delegate to the shipped TopNTable (agg: :sum, since
          # cost is a level to sum, not a counter to rate).
          TopNTable.add(row, datasource: datasource, metric: cost_metric, group_by: [label],
                        agg: :sum, n: top_n.to_i, selector: selector,
                        title: "#{tp}Top #{top_n.to_i} spenders by #{label}")
        end

        # The stacked spend-by-label composition over time.
        def self.add_stack(row, datasource:, cost_metric:, label:, selector:, currency_unit:, title:)
          expr = "sum#{Promql.by([label])}(#{cost_metric}#{Promql.braces(selector)})"
          pid  = :"cost_by_#{slug(label)}"
          row.panel pid, kind: :timeseries, width: Theme.full, height: Theme::TS_H do
            title title
            unit currency_unit
            min 0
            graph :area
            description "Spend partitioned by #{label}, stacked. The band heights are the " \
                        'per-label spend; the envelope is the total bill.'
            # The partition is honest only when stacked — set via the typed
            # options(grafana:) escape hatch; ignored gracefully by non-stacking
            # backends (degrades to multi-series lines).
            options(grafana: { 'fieldConfig' => { 'defaults' => { 'custom' => { 'stacking' => { 'mode' => 'normal', 'group' => 'A' } } } } })
            # cost LEVEL — always present, never event-driven; NOT floored.
            query 'A', expr, datasource: datasource, presence: :continuous, legend: "{{#{label}}}"
          end
        end

        def self.validate!(datasource:, cost_metric:, attribution_label:, top_n:)
          raise ArgumentError, 'CostAttributionRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'CostAttributionRow: cost_metric: required' if blank?(cost_metric)
          raise ArgumentError, 'CostAttributionRow: attribution_label: required' if blank?(attribution_label)
          raise ArgumentError, 'CostAttributionRow: top_n: must be a positive integer' unless top_n.to_i.positive?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_stack, :validate!, :blank?, :slug
      end
    end
  end
end
