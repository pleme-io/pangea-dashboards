# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # A StatusOverview SIGNAL builder (NOT a panel) for the "this entity is
      # past its OWN configured deadline" defect. It returns the typed
      # { name:, expr:, warn:, crit:, desc: } Hash that slots straight into
      # StatusOverview.add(signals: [...]) — the component decides the PromQL,
      # the headline strip decides the colour-flooded tile.
      #
      # ── What it generalises ─────────────────────────────────────────────
      # The "N entities past their own configured interval" shape recurs across
      # the secrets/gateway domain: dynamic-secret rotations overdue, certs near
      # expiry, tokens past their TTL. Each is the SAME maths — for every entity,
      # compare an elapsed-since gauge against that same entity's configured
      # interval gauge, count the ones over. Per the prime directive this lifts
      # to ONE typed signal builder (solve-once), sibling of AtCeilingDefectTile.
      #
      # ── Why `and on(join_labels)` (per-entity, not a global threshold) ──
      # elapsed_since and configured_interval are two gauge families sharing an
      # entity identity. `(elapsed >= interval)` is a per-series comparison that
      # keeps exactly the entities whose OWN elapsed has crossed their OWN
      # interval — never a single fleet-wide constant. The `and on(labels)`
      # intersection keeps only the rows present on both sides at the same
      # identity, so the count is "entities past their own deadline", never a
      # cartesian blur. Mirrors AtCeilingDefectTile's typed on()-match exactly.
      #
      # ── Why no zero-floor ───────────────────────────────────────────────
      # This is a `count(...)` over an intersection: an empty intersection IS
      # the value 0 (count of nothing), honest without `or vector(0)`. The
      # healthy state is "0 overdue", which Grafana renders green.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   StatusOverview.add(self, datasource: ds, signals: [
      #     Pangea::Dashboards::Library::OverdueDefectTile.signal(
      #       elapsed_metric:  'rotation_seconds_since_last',
      #       interval_metric: 'rotation_configured_interval_seconds',
      #       name: 'Rotations overdue'),
      #   ])
      module OverdueDefectTile
        DEFAULT_JOIN_LABELS = %w[producer namespace name].freeze
        DEFAULT_NAME = 'Overdue — past configured deadline'
        DEFAULT_DESC =
          'Entities whose elapsed-since exceeds their OWN configured interval ' \
          '(per-entity, not a fleet constant). RED ⇒ rotate / renew now — the ' \
          'entity has blown its own deadline.'

        # Build the typed StatusOverview signal Hash. Returns:
        #   { name:, expr:, warn:, crit:, desc: }
        #
        # elapsed_metric:  (req) per-entity elapsed-since gauge (seconds)
        # interval_metric: (req) per-entity configured-interval gauge (seconds)
        # join_labels:     identity labels shared by both sides of the `and`
        #                  (default producer/namespace/name)
        # warn / crit:     defect thresholds (default 1 / 3 — one overdue is
        #                  amber, three is red)
        # name / desc:     tile title + description overrides
        def self.signal(elapsed_metric:, interval_metric:,
                        join_labels: DEFAULT_JOIN_LABELS, warn: 1, crit: 3,
                        name: DEFAULT_NAME, desc: nil)
          validate!(elapsed_metric: elapsed_metric, interval_metric: interval_metric,
                    join_labels: join_labels)
          {
            name: name,
            expr: build_expr(elapsed_metric, interval_metric, join_labels),
            warn: warn,
            crit: crit,
            desc: desc || DEFAULT_DESC
          }
        end

        # count((elapsed >= interval)) — the per-series comparison already
        # keeps only the entities over their own interval (same labels on both
        # sides), so the `and on()` makes the identity-match explicit + safe.
        def self.build_expr(elapsed, interval, join_labels)
          overdue = "#{elapsed} >= #{interval}"
          # The bare comparison `a >= b` ALREADY matches on identical label
          # sets; wrapping it as `(a) and on(labels) (b)` is the explicit
          # typed identity-match (mirrors AtCeilingDefectTile), so a renamed
          # extra label on one side can never silently produce a fan-out.
          "count((#{overdue}) and#{on(join_labels)} #{interval})"
        end

        # ` on (a, b)` identity-matching clause for the `and` vector op — the
        # mirror of Promql.by for a binary on()-match. Reuses Promql.by's label
        # normalisation (compact, stringify, drop-empty), then swaps `by`→`on`.
        def self.on(labels)
          Promql.by(labels).sub('by (', 'on (')
        end

        def self.validate!(elapsed_metric:, interval_metric:, join_labels:)
          raise ArgumentError, 'OverdueDefectTile: elapsed_metric: required' if blank?(elapsed_metric)
          raise ArgumentError, 'OverdueDefectTile: interval_metric: required' if blank?(interval_metric)
          labels = Array(join_labels).compact.map(&:to_s).reject(&:empty?)
          raise ArgumentError, 'OverdueDefectTile: join_labels: required (non-empty)' if labels.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :build_expr, :on, :validate!, :blank?
      end
    end
  end
end
