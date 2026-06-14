# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # A StatusOverview SIGNAL builder (NOT a panel) for the "this workload is
      # at its ceiling and the next allocation OOM-kills it" defect. It returns
      # the typed { name:, expr:, warn:, crit:, desc: } Hash that slots straight
      # into StatusOverview.add(signals: [...]) — the component decides the
      # PromQL, the headline strip decides the colour-flooded tile.
      #
      # ── What it absorbs ─────────────────────────────────────────────────
      # The "At ceiling — OOM risk" tile was hand-written twice: once in
      # breathe.rb (the memory-band at-ceiling tile) and once in
      # storage_carving.rb (the storage at-ceiling signal). Both compose the
      # SAME shape — count the dimensions whose utilisation has crossed the
      # grow-above setpoint AND whose limit has reached the hard ceiling — so
      # it lifts to ONE typed signal builder (solve-once, per the prime
      # directive). breathe carves resource limits to hold a util band; a
      # dimension that is both hot (util ≥ grow_above) AND already pinned at
      # the ceiling (limit ≥ ceiling) has nowhere left to grow — the next
      # spike OOM-kills it. That count is the defect.
      #
      # ── Why `and on(join_labels)` ───────────────────────────────────────
      # util and limit are two separate series families that share an identity
      # (the band: dim/namespace/name). `a and on(dim,namespace,name) b` keeps
      # exactly the samples present on BOTH sides at the same identity, so the
      # count is "dimensions that are hot AND pinned", never a cartesian blur.
      #
      # ── Why no zero-floor ───────────────────────────────────────────────
      # This is a `count(...)` over an intersection: an empty intersection IS
      # the value 0 (count of nothing), so it is honest without `or vector(0)`.
      # The healthy state is "0 bands at ceiling", which Grafana renders green.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   StatusOverview.add(self, datasource: ds, signals: [
      #     Pangea::Dashboards::Library::AtCeilingDefectTile.signal(
      #       util_metric:       'breathe_band_util_ratio',
      #       grow_above_metric: 'breathe_band_grow_above_ratio',
      #       limit_metric:      'breathe_band_limit_bytes',
      #       ceiling_metric:    'breathe_band_ceiling_bytes'),
      #   ])
      module AtCeilingDefectTile
        DEFAULT_JOIN_LABELS = %w[dim namespace name].freeze
        DEFAULT_NAME = 'At ceiling — OOM risk'
        DEFAULT_DESC =
          'Bands whose utilisation is at/above the grow-above setpoint AND ' \
          'whose limit is already pinned at the ceiling — no headroom left, ' \
          'so the next spike OOM-kills the workload. RED ⇒ raise the ceiling ' \
          'or scale out.'

        # Build the typed StatusOverview signal Hash. Returns:
        #   { name:, expr:, warn:, crit:, desc: }
        #
        # util_metric:       (req) the per-band utilisation gauge
        # grow_above_metric: (req) the per-band grow-above setpoint gauge
        # limit_metric:      (req) the per-band current limit gauge
        # ceiling_metric:    (req) the per-band hard ceiling gauge
        # join_labels:       identity labels shared by both sides of the `and`
        #                    (default dim/namespace/name — the band identity)
        # warn / crit:       defect thresholds (default 1 / 2 — one band at
        #                    ceiling is amber, two is red)
        # name / desc:       tile title + description overrides
        def self.signal(util_metric:, grow_above_metric:, limit_metric:, ceiling_metric:,
                        join_labels: DEFAULT_JOIN_LABELS, warn: 1, crit: 2,
                        name: DEFAULT_NAME, desc: nil)
          validate!(util_metric: util_metric, grow_above_metric: grow_above_metric,
                    limit_metric: limit_metric, ceiling_metric: ceiling_metric,
                    join_labels: join_labels)
          {
            name: name,
            expr: build_expr(util_metric, grow_above_metric, limit_metric, ceiling_metric, join_labels),
            warn: warn,
            crit: crit,
            desc: desc || DEFAULT_DESC
          }
        end

        # count((util >= grow_above) and on(labels) (limit >= ceiling))
        def self.build_expr(util, grow_above, limit, ceiling, join_labels)
          hot    = "#{util} >= #{grow_above}"
          pinned = "#{limit} >= #{ceiling}"
          "count((#{hot}) and#{on(join_labels)} (#{pinned}))"
        end

        # ` on (a, b)` identity-matching clause for the `and` vector op — the
        # mirror of Promql.by for a binary on()-match. Reuses Promql.by's label
        # normalisation (compact, stringify, drop-empty) so the label list is
        # rendered ONE way fleet-wide, then swaps the `by` keyword for `on`.
        def self.on(labels)
          Promql.by(labels).sub('by (', 'on (') # " by (a, b)" → " on (a, b)"
        end

        def self.validate!(util_metric:, grow_above_metric:, limit_metric:, ceiling_metric:, join_labels:)
          {
            util_metric: util_metric, grow_above_metric: grow_above_metric,
            limit_metric: limit_metric, ceiling_metric: ceiling_metric
          }.each do |arg, val|
            raise ArgumentError, "AtCeilingDefectTile: #{arg}: required" if blank?(val)
          end
          labels = Array(join_labels).compact.map(&:to_s).reject(&:empty?)
          raise ArgumentError, 'AtCeilingDefectTile: join_labels: required (non-empty)' if labels.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :build_expr, :on, :validate!, :blank?, :slug
      end
    end
  end
end
