# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The DISTANCE-RANK table. ONE instant `:table` ranking the band fleet by
      # how far each member sits from its setpoint RIGHT NOW:
      #
      #   topk(N, abs(util_ratio - on(identity) setpoint_ratio))
      #
      # Where BandDeviationHeatmap shows the WHOLE fleet's in-band-ness over time
      # (find the hot row), this names the worst N offenders at this instant (go
      # fix these). It is the triage companion: heatmap to SEE, table to ACT.
      #
      # ── Why a third-site extraction ─────────────────────────────────────────
      # "furthest-from-setpoint" / "most-deviated" panels were hand-written in
      # breathe.rb and the storage-carving dashboard as bespoke topk(abs(diff))
      # tables — a ranking by DISTANCE between two series, which TopNTable (single
      # metric topk) cannot express. Per the prime directive this lifts to one
      # typed primitive (solve-once): the generic "rank entities by |a − b|"
      # shape, reusable for any util/setpoint, used/limit, or applied/desired pair.
      #
      # ── Why instant + :continuous ───────────────────────────────────────────
      # An instant table is a now-snapshot (Grafana evaluates at the dashboard's
      # `to` time). util/setpoint are gauges; the deviation is a real magnitude —
      # no zero-floor (a genuine 0 distance is the healthy reading, an absent band
      # rightly drops out of the topk).
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Furthest from setpoint' do
      #     Pangea::Dashboards::Library::DeviationRankTable.add(
      #       self, datasource: 'vm', worst_n: 10, dim: { dim: 'memory' })
      #   end
      module DeviationRankTable
        DEFAULT_JOIN_LABELS = %w[dim namespace name].freeze

        # datasource:      (req) the metrics datasource uid
        # util_metric:     observed gauge A (default breathe's util_ratio)
        # setpoint_metric: target gauge B (default breathe's setpoint_ratio)
        # dim:             optional selector scoping the population (Promql rules)
        # join_labels:     identity labels shared by A and B (default band identity)
        # worst_n:         how many offenders to rank (default 10)
        # legend_labels:   per-row legend template (default '{{name}}')
        # title:           cosmetic override
        def self.add(row, datasource:,
                     util_metric: 'breathe_band_util_ratio',
                     setpoint_metric: 'breathe_band_setpoint_ratio',
                     dim: nil, join_labels: DEFAULT_JOIN_LABELS, worst_n: 10,
                     legend_labels: '{{name}}', title: nil)
          validate!(datasource: datasource, util_metric: util_metric,
                    setpoint_metric: setpoint_metric, join_labels: join_labels, worst_n: worst_n)
          braces = Promql.braces(dim)
          n = worst_n.to_i
          expr = "topk(#{n}, abs(#{util_metric}#{braces} -#{on(join_labels)} #{setpoint_metric}#{braces}))"
          row.panel :deviation_rank, kind: :table, width: Theme.full, height: Theme::TABLE_H do
            title title || "Furthest from setpoint (worst #{n})"
            unit 'percentunit'
            description 'Bands ranked by current distance from their carved setpoint. ' \
                        'The top rows are the bands the controller is fighting hardest.'
            query 'A', expr, datasource: datasource, presence: :continuous, instant: true, legend: legend_labels
          end
        end

        def self.on(labels)
          Promql.by(labels).sub('by (', 'on (')
        end

        def self.validate!(datasource:, util_metric:, setpoint_metric:, join_labels:, worst_n:)
          raise ArgumentError, 'DeviationRankTable: datasource: required' if blank?(datasource)
          raise ArgumentError, 'DeviationRankTable: util_metric: required' if blank?(util_metric)
          raise ArgumentError, 'DeviationRankTable: setpoint_metric: required' if blank?(setpoint_metric)
          labels = Array(join_labels).compact.map(&:to_s).reject(&:empty?)
          raise ArgumentError, 'DeviationRankTable: join_labels: required (non-empty)' if labels.empty?
          raise ArgumentError, 'DeviationRankTable: worst_n: must be a positive integer' unless worst_n.to_i.positive?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :on, :validate!, :blank?
      end
    end
  end
end
