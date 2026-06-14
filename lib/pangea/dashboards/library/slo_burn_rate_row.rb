# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The SLO / error-budget row — the Google-SRE multi-window multi-burn
      # shape, absorbed as a NAMED GAP (no SLO idiom exists in any org's
      # dashboards today; this designs it cleanly from first principles).
      #
      # An SLO is "good / total ≥ objective" (e.g. 99.9% of requests succeed).
      # The error budget is the slack the objective permits: 1 - objective
      # (e.g. 0.1%). The BURN RATE is how fast you are spending that budget,
      # normalised so 1.0 = "spending exactly at the rate that exhausts the
      # budget over the SLO window" and >1.0 = "spending faster than allowed":
      #
      #     burn(window) = (1 - good/total) / (1 - objective)
      #
      # ── Why MULTI-WINDOW (1h / 6h / 24h / 72h) ──────────────────────────
      # A single window forces a bad trade: short windows alert on transient
      # blips (noisy), long windows react too slowly (you've already burned
      # the month). The SRE workbook's answer is a row of windows side by side
      # so the operator sees a fast spike (1h) AND a slow leak (72h) at once —
      # the burn-rate shape over time IS the diagnosis.
      #
      # ── Why the multi-burn thresholds (>1 amber, >14.4 red) ─────────────
      # 14.4 is the canonical "fast-burn" multiplier: at 14.4× you exhaust a
      # 30-day budget in ~2 days, the page-now threshold. >1 (amber) is "you
      # are spending faster than sustainable" — watch. Below 1 (green) you are
      # within budget. These map straight onto Theme.defect_steps(warn:,crit:),
      # so burn tiles share the fleet traffic-light semantics (preattentive:
      # one red burn tile in a row of green is FOUND, not read).
      #
      # ── Why the budget-REMAINING stat (over budget_window, e.g. 30d) ────
      # Burn rate is a velocity; remaining budget is the fuel gauge. It answers
      # "how much slack is left this period?" as a percentage:
      #
      #     remaining = 1 - (1 - good/total) / (1 - objective)   over budget_window
      #
      # 100% = full budget untouched; 0% = SLO exactly met; <0% = SLO BREACHED
      # (more errors than the budget allowed). Higher = better, so it uses
      # Theme.liveness_steps (LOWER = worse) — red as it approaches empty.
      #
      # ── Why the SLI ratio timeseries ────────────────────────────────────
      # The trend of good/total itself, so a dip is visible as a shape, with
      # the objective as the floor the eye reads against.
      #
      # Builds the good/total ratio queries INLINE from the two counters, so it
      # works without pre-baked recording rules (an operator can drop it on any
      # pair of success/total *_total counters and get the whole SRE story).
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'SLO' do
      #     Pangea::Dashboards::Library::SloBurnRateRow.add(
      #       self, datasource: 'vm',
      #       sli_good_metric: 'http_requests_total{code!~"5.."}',
      #       sli_total_metric: 'http_requests_total',
      #       objective: 0.999, selector: { route: '/checkout' })
      #   end
      module SloBurnRateRow
        # datasource:       (req) the metrics datasource
        # sli_good_metric:  (req) the GOOD-events *_total counter (already
        #                   filtered to successes, e.g. code!~"5..")
        # sli_total_metric: (req) the TOTAL-events *_total counter
        # objective:        SLO target in (0,1) (default 0.999 → 99.9%)
        # windows:          burn-rate windows, fast→slow (default 1h/6h/24h/72h)
        # budget_window:    window for budget-remaining (default 30d)
        # selector:         typed Hash/String matcher applied to BOTH counters
        # title:            row stat-strip title prefix (cosmetic)
        def self.add(row, datasource:, sli_good_metric:, sli_total_metric:,
                     objective: 0.999, windows: %w[1h 6h 24h 72h], budget_window: '30d',
                     selector: nil, title: 'SLO / error budget')
          validate!(datasource: datasource, sli_good_metric: sli_good_metric,
                    sli_total_metric: sli_total_metric, objective: objective,
                    windows: windows, budget_window: budget_window)

          add_burn_tiles(row, datasource: datasource, good: sli_good_metric, total: sli_total_metric,
                         objective: objective, windows: windows, selector: selector, prefix: title)
          add_budget_remaining(row, datasource: datasource, good: sli_good_metric, total: sli_total_metric,
                               objective: objective, budget_window: budget_window, selector: selector, prefix: title)
          add_sli_timeseries(row, datasource: datasource, good: sli_good_metric, total: sli_total_metric,
                             objective: objective, budget_window: budget_window, selector: selector, prefix: title)
        end

        # ── Burn-rate stat tiles, one per window, multi-burn thresholds. ──
        # The fast window (first) gets the canonical >1 amber / >14.4 red
        # page-now thresholds; slower windows keep amber at >1 (a slow leak
        # is a watch, not a page) so colour stays meaningful per window.
        def self.add_burn_tiles(row, datasource:, good:, total:, objective:, windows:, selector:, prefix:)
          w = Theme.tile_width(windows.length)
          windows.each_with_index do |win, idx|
            expr  = Floor.zero(burn_expr(good: good, total: total, objective: objective, window: win, selector: selector))
            crit  = idx.zero? ? 14.4 : nil # only the fast window pages on >14.4
            steps = Theme.defect_steps(warn: 1, crit: crit)
            pid   = :"slo_burn_#{slug(win)}"
            row.panel pid, kind: :stat, width: w, height: Theme::STAT_H do
              title "burn · #{win}"
              unit 'short'
              decimals 2
              description "Error-budget burn rate over #{win}: (1 - good/total) / (1 - objective). " \
                          '>1 = spending faster than sustainable (amber); ' \
                          "#{idx.zero? ? '>14.4 = fast burn, page now (red).' : 'slow window — watch.'}"
              display :background     # colour the tile — preattentive burn status
              graph :area             # burn trend behind the number (Tufte)
              # event_driven: a healthy SLI has no errors → 0 burn, never no-data.
              query 'A', expr, datasource: datasource, presence: :event_driven, legend: "burn #{win}"
              threshold steps: steps
            end
          end
        end

        # ── Error-budget remaining %, over budget_window. liveness palette. ──
        def self.add_budget_remaining(row, datasource:, good:, total:, objective:, budget_window:, selector:, prefix:)
          remaining = "100 * (1 - (#{burn_expr(good: good, total: total, objective: objective, window: budget_window, selector: selector)}))"
          row.panel :slo_budget_remaining, kind: :stat, width: Theme.third, height: Theme::STAT_H do
            title "#{prefix} — budget left (#{budget_window})"
            unit 'percent'
            decimals 1
            min(-100)
            max 100
            description 'Error budget remaining this period: 100*(1 - burn over the budget window). ' \
                        '100% = untouched, 0% = SLO exactly met, <0% = BREACHED. Lower is worse.'
            display :background
            graph :area
            query 'A', remaining, datasource: datasource, presence: :continuous, legend: 'budget left'
            # liveness: LOWER = worse — red below the floor, green at/above it.
            threshold steps: Theme.liveness_steps(ok: 0)
          end
        end

        # ── SLI ratio trend + the objective floor it reads against. ──
        def self.add_sli_timeseries(row, datasource:, good:, total:, objective:, budget_window:, selector:, prefix:)
          ratio = "100 * (#{ratio_expr(good: good, total: total, window: budget_window, selector: selector)})"
          obj   = format('%g', (objective * 100))
          row.panel :slo_sli_ratio, kind: :timeseries, width: Theme.two_thirds, height: Theme::TS_H do
            title "#{prefix} — SLI (good/total)"
            unit 'percent'
            min 0
            max 100
            graph :area
            query 'A', ratio, datasource: datasource, presence: :continuous, legend: 'SLI %'
            # The objective drawn as a flat reference line — the floor the eye
            # measures the SLI dip against (a scalar broadcast over the range).
            query 'B', "#{obj} + (0 * vector(0))", datasource: datasource, presence: :continuous, legend: "objective #{obj}%"
          end
        end

        # burn(window) = (1 - good/total) / (1 - objective)
        def self.burn_expr(good:, total:, objective:, window:, selector:)
          budget = format('%g', (1.0 - objective))
          "(1 - (#{ratio_expr(good: good, total: total, window: window, selector: selector)})) / #{budget}"
        end

        # good/total over the window, as a ratio in [0,1]. Each counter is
        # rate()'d over the window and summed; the selector is applied to BOTH
        # through Promql so the matcher is typed (Hash → =, Regexp/Array → =~).
        def self.ratio_expr(good:, total:, window:, selector:)
          g = Promql.sum_rate(metric: good, window: window, selector: selector)
          t = Promql.sum_rate(metric: total, window: window, selector: selector)
          "#{g} / #{t}"
        end

        def self.validate!(datasource:, sli_good_metric:, sli_total_metric:, objective:, windows:, budget_window:)
          raise ArgumentError, 'SloBurnRateRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'SloBurnRateRow: sli_good_metric: required' if blank?(sli_good_metric)
          raise ArgumentError, 'SloBurnRateRow: sli_total_metric: required' if blank?(sli_total_metric)
          raise ArgumentError, "SloBurnRateRow: objective must be in (0,1) (got #{objective.inspect})" \
            unless objective.is_a?(Numeric) && objective > 0 && objective < 1
          raise ArgumentError, 'SloBurnRateRow: windows must be a non-empty Array' \
            unless windows.is_a?(Array) && !windows.empty?
          raise ArgumentError, 'SloBurnRateRow: budget_window: required' if blank?(budget_window)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_burn_tiles, :add_budget_remaining, :add_sli_timeseries,
                             :burn_expr, :ratio_expr, :validate!, :blank?, :slug
      end
    end
  end
end
