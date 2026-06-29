# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/health_matrix_table'

module Pangea
  module Dashboards
    module Library
      # The fleet × multi-window BURN MATRIX — `HealthMatrixTable` specialised to
      # error-budget burn windows. ROW = a member of the topology (tenant/cell);
      # COLUMN = a burn window (1h / 6h / 24h / 72h). Each cell is the SRE burn
      # rate for that member over that window
      #
      #   burn(window) = (1 - good/total) / (1 - objective)
      #
      # cell-coloured by the canonical MULTI-BURN thresholds: >1 amber (spending
      # faster than sustainable), >14.4 red (fast burn — page now). Read across a
      # row to see one member's fast-spike-vs-slow-leak shape; read down a column
      # to find every member burning hot at that horizon.
      #
      # The fast→slow window layout is the SRE-workbook diagnosis-at-a-glance:
      # a 1h spike with a calm 72h = a transient blip; a hot 72h = a sustained
      # leak already eating the month.
      #
      # Composes `HealthMatrixTable` (so the typed `options(grafana:)` per-column
      # threshold seam is reused, never re-implemented): one column per window,
      # each carrying warn: 1 / crit: 14.4.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Burn matrix' do
      #     Pangea::Dashboards::Library::BurnRateMatrix.add(
      #       self, datasource: 'vm', topology_label: 'tenant',
      #       sli_good_metric: 'req_total{code!~"5.."}',
      #       sli_total_metric: 'req_total', objective: 0.999,
      #       windows: %w[1h 6h 24h 72h])
      #   end
      module BurnRateMatrix
        FAST_BURN = 14.4 # canonical page-now multiplier (≈30d budget in ~2d)

        # datasource:       (req) the metrics datasource uid
        # topology_label:   (req) the per-member key column
        # sli_good_metric:  (req) GOOD-events *_total counter (already filtered)
        # sli_total_metric: (req) TOTAL-events *_total counter
        # objective:        SLO target in (0,1) (default 0.999)
        # windows:          burn windows fast→slow (default 1h/6h/24h/72h)
        # title:            panel title
        def self.add(row, datasource:, topology_label:, sli_good_metric:, sli_total_metric:,
                     objective: 0.999, windows: %w[1h 6h 24h 72h], title: nil)
          validate!(datasource: datasource, topology_label: topology_label,
                    sli_good_metric: sli_good_metric, sli_total_metric: sli_total_metric,
                    objective: objective, windows: windows)
          columns = windows.map do |win|
            { name: "burn · #{win}", unit: 'short', warn: 1, crit: FAST_BURN,
              expr: burn_by_member(good: sli_good_metric, total: sli_total_metric,
                                   objective: objective, window: win, label: topology_label) }
          end
          HealthMatrixTable.add(row, datasource: datasource, topology_label: topology_label,
                                columns: columns, title: title || "Burn rate by #{topology_label} × window")
        end

        # burn(window) per member = (1 - good/total) / (1 - objective), with both
        # counters summed `by(<topology_label>)` so the matrix joins on the member.
        def self.burn_by_member(good:, total:, objective:, window:, label:)
          budget = format('%g', (1.0 - objective))
          g = "sum#{Promql.by(label)}(rate(#{good}[#{window}]))"
          t = "sum#{Promql.by(label)}(rate(#{total}[#{window}]))"
          "(1 - (#{g} / #{t})) / #{budget}"
        end

        def self.validate!(datasource:, topology_label:, sli_good_metric:, sli_total_metric:, objective:, windows:)
          raise ArgumentError, 'BurnRateMatrix: datasource: required' if blank?(datasource)
          raise ArgumentError, 'BurnRateMatrix: topology_label: required' if blank?(topology_label)
          raise ArgumentError, 'BurnRateMatrix: sli_good_metric: required' if blank?(sli_good_metric)
          raise ArgumentError, 'BurnRateMatrix: sli_total_metric: required' if blank?(sli_total_metric)
          raise ArgumentError, "BurnRateMatrix: objective must be in (0,1) (got #{objective.inspect})" \
            unless objective.is_a?(Numeric) && objective > 0 && objective < 1
          raise ArgumentError, 'BurnRateMatrix: windows must be a non-empty Array' \
            unless windows.is_a?(::Array) && !windows.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :burn_by_member, :validate!, :blank?
      end
    end
  end
end
