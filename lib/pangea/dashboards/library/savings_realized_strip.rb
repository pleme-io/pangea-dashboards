# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/stat_strip'
require 'pangea/dashboards/library/rate_with_zero_floor'

module Pangea
  module Dashboards
    module Library
      # The realized-SAVINGS strip — the "what did our cost discipline actually
      # save?" headline. A row of liveness-coloured `:stat` tiles, one per savings
      # lever (spot-vs-on-demand, scale-to-zero, commitment coverage), each a
      # dollar figure where HIGHER = healthier (more saved), plus one floored
      # spot-interruption-rate timeseries (the cost of the spot lever — too many
      # interruptions erode the saving). Savings are a liveness signal: a tile
      # collapsing toward 0 means a lever stopped working.
      #
      # ── Why liveness colouring on the tiles ─────────────────────────────
      # A savings figure inverts the usual defect sense: a BIG number is good. So
      # each tile uses Theme.liveness_steps (red below the expected floor, green
      # at/above) via StatStrip's `liveness: true` — the shipped strip atom owns
      # the threshold + colour-flood, this component owns the savings vocabulary.
      #
      # ── Why the interruption rate is floored (event-driven) ─────────────
      # Spot interruptions are events — a healthy window has zero, which must read
      # a lit 0 not "No data". RateWithZeroFloor owns that floor.
      #
      #   row 'Realized savings' do
      #     Pangea::Dashboards::Library::SavingsRealizedStrip.add(
      #       self, datasource: 'vm', selector: { tenant: '$tenant' },
      #       savings: {
      #         'Spot vs on-demand'   => 'sum(savings_spot_dollars)',
      #         'Scale-to-zero'       => 'sum(savings_scale_to_zero_dollars)',
      #         'Commitment coverage' => 'sum(savings_commitment_dollars)' },
      #       interruption_metric: 'spot_interruptions_total')
      #   end
      module SavingsRealizedStrip
        # datasource:          (req) the metrics datasource uid
        # savings:             (req) Hash{ lever title => PromQL $-saved expr } —
        #                      one liveness tile per entry, in declared order. The
        #                      exprs are already-complete PromQL (not a metric to
        #                      wrap), so the author keeps full control.
        # interruption_metric: optional spot-interruption *_total counter — a
        #                      floored rate timeseries (omit to skip)
        # selector:            typed Hash/String matcher applied to the
        #                      interruption rate (NOT the savings exprs, which are
        #                      whole)
        # currency_unit:       Grafana unit for the savings tiles (default 'currencyUSD')
        # ok:                  liveness floor — a tile reads green at/above this $
        #                      (default 0 — any positive saving is green)
        # window:              interruption rate window (default 1h)
        # title:               strip title prefix (default 'Savings')
        def self.add(row, datasource:, savings:, interruption_metric: nil, selector: nil,
                     currency_unit: 'currencyUSD', ok: 0, window: '1h', title: 'Savings')
          validate!(datasource: datasource, savings: savings)

          # Liveness tiles via the shipped StatStrip (it owns the colour-flood +
          # threshold; we only supply the savings vocabulary).
          tiles = savings.map do |lever, expr|
            { title: lever.to_s, expr: expr, unit: currency_unit,
              liveness: true, steps: Theme.liveness_steps(ok: ok), color_mode: :background }
          end
          StatStrip.add(row, datasource: datasource, tiles: tiles)

          # Spot-interruption rate (optional, floored — healthy = 0).
          RateWithZeroFloor.add(row, datasource: datasource, counter_metric: interruption_metric,
                                selector: selector, window: window, unit: 'short', width: Theme.full,
                                title: "#{title} · spot interruptions /s",
                                id: :savings_spot_interruptions) if interruption_metric
        end

        def self.validate!(datasource:, savings:)
          raise ArgumentError, 'SavingsRealizedStrip: datasource: required' if blank?(datasource)
          raise ArgumentError, 'SavingsRealizedStrip: savings must be a non-empty Hash' \
            unless savings.is_a?(::Hash) && !savings.empty?
          savings.each do |lever, expr|
            raise ArgumentError, "SavingsRealizedStrip: savings lever #{lever.inspect} needs a non-empty expr" \
              if blank?(expr)
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
