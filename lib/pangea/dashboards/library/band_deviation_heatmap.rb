# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The IN-BAND-NESS heatmap. ONE `:heatmap` panel plotting, across the whole
      # homeostasis band fleet over time, the absolute distance between each
      # band's observed utilisation and the setpoint it is being held to:
      #
      #   abs(util_ratio  -  on(identity) setpoint_ratio)
      #
      # A band sitting on its setpoint is a cool cell (≈0); a band the controller
      # cannot hold — drifting hot or cold — is a HOT cell. Read top-to-bottom,
      # the heatmap answers "is the controller converging the whole fleet?" in one
      # glance: a calm blue field = homeostasis; a persistent hot row = a band the
      # controller is fighting (under-provisioned ceiling, thrashing setpoint, a
      # workload the carve can't track).
      #
      # ── Why `abs(a - on(identity) b)` (not `a - b`) ─────────────────────────
      # util and setpoint are two separate gauge families that share a band
      # identity (dim/namespace/name). `a - on(dim,namespace,name) b` matches
      # exactly the samples present on BOTH sides at the same identity — never a
      # cartesian blur. `abs(...)` collapses over- and under-shoot into one
      # "distance from band" magnitude (the operator cares how far, not which
      # way; the signed direction lives in UtilSetpointBand). Mirrors the typed
      # `on()` clause AtCeilingDefectTile uses, rendered ONE way via Promql.by.
      #
      # ── Why :continuous (no zero-floor) ────────────────────────────────────
      # Both inputs are gauges always present while a band exists. A genuine 0
      # deviation is a real (excellent) reading; a vanished band SHOULD read "No
      # data", not a misleading floored 0. So the series is never floored.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'In-band deviation' do
      #     Pangea::Dashboards::Library::BandDeviationHeatmap.add(
      #       self, datasource: 'vm', dim: { dim: 'memory' })
      #   end
      module BandDeviationHeatmap
        DEFAULT_JOIN_LABELS = %w[dim namespace name].freeze

        # datasource:      (req) the metrics datasource uid
        # util_metric:     observed util_ratio gauge (default breathe's)
        # setpoint_metric: target setpoint_ratio gauge (default breathe's)
        # dim:             optional selector scoping the band population
        #                  (typed Hash/String/Regexp/Array per Promql rules);
        #                  nil → the whole fleet
        # join_labels:     identity labels shared by both gauge families
        #                  (default dim/namespace/name — the band identity)
        # legend_labels:   per-series legend template (default '{{name}}')
        # title:           cosmetic override
        def self.add(row, datasource:,
                     util_metric: 'breathe_band_util_ratio',
                     setpoint_metric: 'breathe_band_setpoint_ratio',
                     dim: nil, join_labels: DEFAULT_JOIN_LABELS,
                     legend_labels: '{{name}}', title: nil)
          validate!(datasource: datasource, util_metric: util_metric,
                    setpoint_metric: setpoint_metric, join_labels: join_labels)
          braces = Promql.braces(dim)
          expr = "abs(#{util_metric}#{braces} -#{on(join_labels)} #{setpoint_metric}#{braces})"
          row.panel :band_deviation_heatmap, kind: :heatmap, width: Theme.full, height: Theme::TABLE_H do
            title title || 'In-band deviation (|util − setpoint|) over time'
            unit 'percentunit'
            description 'Per-band distance from the carved setpoint. Cool ⇒ in band; ' \
                        'a persistent hot row ⇒ a band the controller cannot hold.'
            query 'A', expr, datasource: datasource, presence: :continuous, legend: legend_labels
          end
        end

        # ` on (a, b)` identity-match clause for the binary vector op — the mirror
        # of Promql.by, reusing its normalisation so the label list renders ONE
        # way fleet-wide (compact, stringify, drop-empty), then swaps `by`→`on`.
        def self.on(labels)
          Promql.by(labels).sub('by (', 'on (')
        end

        def self.validate!(datasource:, util_metric:, setpoint_metric:, join_labels:)
          raise ArgumentError, 'BandDeviationHeatmap: datasource: required' if blank?(datasource)
          raise ArgumentError, 'BandDeviationHeatmap: util_metric: required' if blank?(util_metric)
          raise ArgumentError, 'BandDeviationHeatmap: setpoint_metric: required' if blank?(setpoint_metric)
          labels = Array(join_labels).compact.map(&:to_s).reject(&:empty?)
          raise ArgumentError, 'BandDeviationHeatmap: join_labels: required (non-empty)' if labels.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :on, :validate!, :blank?
      end
    end
  end
end
