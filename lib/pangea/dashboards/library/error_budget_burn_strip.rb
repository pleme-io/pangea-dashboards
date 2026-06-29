# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The FLEET error-budget strip — one budget-remaining `:stat` tile per
      # member of a topology, each reading the SRE budget-remaining %
      #
      #   remaining = 100 * (1 - (1 - good/total) / (1 - objective))   over budget_window
      #
      # coloured by the LIVENESS palette (lower = worse — red as the fuel gauge
      # approaches empty). Where `SloBurnRateRow` tells ONE service's multi-window
      # burn story, this is its fleet generalisation: the whole population's fuel
      # gauges side by side, so the operator finds the member closest to breach
      # preattentively. A burn sparkline sits behind each number (Tufte) so the
      # trend (refilling vs draining) is legible without a second panel.
      #
      # Membership is the topology label aggregation — each tile sums good/total
      # for ONE member value substituted into the per-member selector. The strip
      # is HAND-LISTED today (`members:`) for the same renderer reason as
      # `CellStatusGrid` (no panel `repeat:` — catalog §9.4); the operator fills
      # members from a `$tenant`/`$cell` variable's values.
      #
      # ── Why budget-remaining (not burn rate) as the headline ────────────────
      # Burn rate is a velocity; remaining budget is the position. For a fleet
      # glance "who is closest to breach?" the position is the decision-relevant
      # number — 0% = SLO exactly met, <0% = BREACHED. The burn velocity lives in
      # the sparkline behind it.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Error budget' do
      #     Pangea::Dashboards::Library::ErrorBudgetBurnStrip.add(
      #       self, datasource: 'vm', topology_label: 'tenant',
      #       members: %w[tenant-a tenant-b],
      #       sli_good_metric: 'req_total{code!~"5.."}',
      #       sli_total_metric: 'req_total', objective: 0.999)
      #   end
      module ErrorBudgetBurnStrip
        # datasource:       (req) the metrics datasource uid
        # topology_label:   (req) the label that partitions the fleet
        # members:          (req) non-empty Array of member values — one tile each
        # sli_good_metric:  (req) GOOD-events *_total counter (already filtered)
        # sli_total_metric: (req) TOTAL-events *_total counter
        # objective:        SLO target in (0,1) (default 0.999)
        # budget_window:    window for budget-remaining (default 30d)
        def self.add(row, datasource:, topology_label:, members:,
                     sli_good_metric:, sli_total_metric:,
                     objective: 0.999, budget_window: '30d')
          validate!(datasource: datasource, topology_label: topology_label, members: members,
                    sli_good_metric: sli_good_metric, sli_total_metric: sli_total_metric,
                    objective: objective, budget_window: budget_window)
          width = Theme.tile_width(members.length)
          members.each_with_index do |member, idx|
            add_tile(row, member: member.to_s, datasource: datasource, topology_label: topology_label,
                     good: sli_good_metric, total: sli_total_metric, objective: objective,
                     budget_window: budget_window, width: width, idx: idx)
          end
        end

        def self.add_tile(row, member:, datasource:, topology_label:, good:, total:,
                          objective:, budget_window:, width:, idx:)
          sel       = { topology_label.to_sym => member }
          remaining = "100 * (1 - (#{burn_expr(good: good, total: total, objective: objective,
                                                window: budget_window, selector: sel)}))"
          pid = :"budget_#{slug(member)}_#{idx}"
          row.panel pid, kind: :stat, width: width, height: Theme::STAT_H do
            title member
            unit 'percent'
            decimals 1
            min(-100)
            max 100
            description "Error budget left for #{member} over #{budget_window}: " \
                        '100% = untouched, 0% = SLO exactly met, <0% = BREACHED. Lower is worse.'
            display :background      # colour the tile — preattentive fuel gauge
            graph :area              # burn trend sparkline behind the number (Tufte)
            query 'A', remaining, datasource: datasource, presence: :continuous, legend: member
            # liveness: LOWER = worse — red as it approaches empty.
            threshold steps: Theme.liveness_steps(ok: 0)
          end
        end

        # burn(window) = (1 - good/total) / (1 - objective), good/total summed
        # over the window with the per-member selector applied to both counters.
        def self.burn_expr(good:, total:, objective:, window:, selector:)
          budget = format('%g', (1.0 - objective))
          g = Promql.sum_rate(metric: good,  window: window, selector: selector)
          t = Promql.sum_rate(metric: total, window: window, selector: selector)
          "(1 - (#{g} / #{t})) / #{budget}"
        end

        def self.validate!(datasource:, topology_label:, members:, sli_good_metric:,
                           sli_total_metric:, objective:, budget_window:)
          raise ArgumentError, 'ErrorBudgetBurnStrip: datasource: required' if blank?(datasource)
          raise ArgumentError, 'ErrorBudgetBurnStrip: topology_label: required' if blank?(topology_label)
          raise ArgumentError, 'ErrorBudgetBurnStrip: members must be a non-empty Array' \
            unless members.is_a?(::Array) && !members.empty?
          raise ArgumentError, 'ErrorBudgetBurnStrip: sli_good_metric: required' if blank?(sli_good_metric)
          raise ArgumentError, 'ErrorBudgetBurnStrip: sli_total_metric: required' if blank?(sli_total_metric)
          raise ArgumentError, "ErrorBudgetBurnStrip: objective must be in (0,1) (got #{objective.inspect})" \
            unless objective.is_a?(Numeric) && objective > 0 && objective < 1
          raise ArgumentError, 'ErrorBudgetBurnStrip: budget_window: required' if blank?(budget_window)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_tile, :burn_expr, :validate!, :blank?, :slug
      end
    end
  end
end
