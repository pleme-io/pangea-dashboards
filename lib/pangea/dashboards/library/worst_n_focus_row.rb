# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/top_n_table'

module Pangea
  module Dashboards
    module Library
      # The WORST-N FOCUS row — the triage pair every fleet board needs: a
      # topk worst-members `:table` (NAME the offenders) beside a golden
      # small-multiples `:timeseries` of those same members over time (SEE their
      # shape). The table answers "which members are worst right now?"; the
      # companion chart answers "is it a spike or a sustained problem?" without
      # leaving the pane.
      #
      # Composes the shipped `TopNTable` for the ranking (so the worst-offenders
      # idiom is reused, never re-written) + one focus timeseries broken down
      # `by(<topology_label>)` so each member is its own line. The chart shows the
      # WHOLE population's lines coloured by member; the eye follows the worst few
      # the table just named (Gestalt: the table is the legend for the chart).
      #
      # ── Why one breakdown chart, not literal per-member small-multiples ──────
      # True per-member panel small-multiples want panel `repeat:` (catalog §9.4,
      # a renderer gap). The buildable-today form is ONE timeseries with a
      # `by(<topology_label>)` legend — every member is a line, which reads as the
      # same small-multiple comparison without N hand-listed panels.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Worst cells' do
      #     Pangea::Dashboards::Library::WorstNFocusRow.add(
      #       self, datasource: 'vm', topology_label: 'cell',
      #       rank_metric: 'http_requests_total', rank_agg: :rate,
      #       failure_results: %w[error],
      #       focus_expr: 'sum by(cell)(rate(http_requests_total{code=~"5.."}[5m]))',
      #       focus_unit: 'reqps', n: 5)
      #   end
      module WorstNFocusRow
        # datasource:      (req) the metrics datasource uid
        # topology_label:  (req) the member key (cell/tenant/region)
        # rank_metric:     (req) the counter the table ranks members by
        # focus_expr:      (req) a `... by(<topology_label>)(...)` timeseries expr
        #                  for the companion golden chart
        # rank_agg:        :increase (default) | :rate | :sum for the table
        # failure_results: optional result=~"a|b" selector merged into the rank
        # window:          range window for the table aggregation (default 5m)
        # n:               worst-N (default 5)
        # focus_unit:      companion chart unit (default 'short')
        # focus_title:     companion chart title
        def self.add(row, datasource:, topology_label:, rank_metric:, focus_expr:,
                     rank_agg: :increase, failure_results: nil, window: '5m', n: 5,
                     focus_unit: 'short', focus_title: nil)
          validate!(datasource: datasource, topology_label: topology_label,
                    rank_metric: rank_metric, focus_expr: focus_expr, n: n)

          # 1. NAME the offenders — topk worst members (reuse TopNTable).
          TopNTable.add(row, datasource: datasource, metric: rank_metric,
                        group_by: [topology_label], agg: rank_agg, n: n, window: window,
                        failure_results: failure_results,
                        title: "Worst #{n} #{topology_label} · #{rank_metric.to_s.tr('_', ' ')}")

          # 2. SEE their shape — golden breakdown over time, one line per member.
          row.panel :worst_n_focus, kind: :timeseries, width: Theme.full, height: Theme::TS_H do
            title focus_title || "Worst #{topology_label} · focus"
            unit focus_unit
            min 0
            graph :area
            query 'A', focus_expr, datasource: datasource, presence: :continuous,
                  legend: "{{#{topology_label}}}"
          end
        end

        def self.validate!(datasource:, topology_label:, rank_metric:, focus_expr:, n:)
          raise ArgumentError, 'WorstNFocusRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'WorstNFocusRow: topology_label: required' if blank?(topology_label)
          raise ArgumentError, 'WorstNFocusRow: rank_metric: required' if blank?(rank_metric)
          raise ArgumentError, 'WorstNFocusRow: focus_expr: required' if blank?(focus_expr)
          raise ArgumentError, "WorstNFocusRow: n must be a positive Integer (got #{n.inspect})" \
            unless n.is_a?(::Integer) && n.positive?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
