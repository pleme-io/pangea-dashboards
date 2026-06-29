# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # A StatusOverview SIGNAL builder (NOT a panel) for the "members of a fleet
      # are running an OLDER config/version than the newest one observed" defect.
      # Returns the typed { name:, expr:, warn:, crit:, desc: } Hash that slots
      # straight into StatusOverview.add(signals: [...]).
      #
      # ── What it generalises ─────────────────────────────────────────────
      # Any GitOps / gateway fleet exposes a per-member "applied version" gauge
      # (config generation, chart revision, gateway build number). The
      # convergence question is "how many members lag the newest version?" — a
      # universal config-skew signal. Per the prime directive this lifts to ONE
      # typed signal builder (solve-once), sibling of AtCeilingDefectTile +
      # OverdueDefectTile.
      #
      # ── Why `count(applied != max(applied))` ────────────────────────────
      # `scalar(max(applied_version))` is the newest version observed across the
      # whole fleet right now. A member whose applied_version != that scalar is
      # lagging (a fresh rollout that hasn't reached it, or a stuck sync). The
      # `!= bool` form would yield 1/0 per series; here we keep the FILTERING
      # comparison `applied != scalar(max)` (drops the equal members) and
      # `count()` the survivors — exactly "members not on the newest version".
      #
      # ── Why no zero-floor ───────────────────────────────────────────────
      # `count(...)` over a filtered set: when every member is on the newest
      # version the set is empty and count is 0 — honest without `or vector(0)`.
      # A converged fleet reads a green 0.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   StatusOverview.add(self, datasource: ds, signals: [
      #     Pangea::Dashboards::Library::VersionSkewDefectTile.signal(
      #       version_metric: 'gateway_applied_config_generation',
      #       selector: { service: 'gateway' }),
      #   ])
      module VersionSkewDefectTile
        DEFAULT_NAME = 'Version skew — members behind newest'
        DEFAULT_DESC =
          'Fleet members whose applied config/version lags the newest one ' \
          'observed (count(applied != max(applied))). A brief amber during a ' \
          'rollout is normal; persistent RED ⇒ a member is stuck not ' \
          'converging to the latest config.'

        # Build the typed StatusOverview signal Hash. Returns:
        #   { name:, expr:, warn:, crit:, desc: }
        #
        # version_metric: (req) per-member applied-version/generation gauge
        # selector:       optional typed Hash/String matcher scoping the fleet
        #                 (Promql rules)
        # warn / crit:    defect thresholds (default 1 / 3 — one lagging member
        #                 is amber, three is red)
        # name / desc:    tile title + description overrides
        def self.signal(version_metric:, selector: nil, warn: 1, crit: 3,
                        name: DEFAULT_NAME, desc: nil)
          validate!(version_metric: version_metric)
          {
            name: name,
            expr: build_expr(version_metric, selector),
            warn: warn,
            crit: crit,
            desc: desc || DEFAULT_DESC
          }
        end

        # count(applied{sel} != scalar(max(applied{sel})))
        # The comparison filters OUT the members equal to the fleet max (the
        # newest version); count() the survivors = members behind.
        def self.build_expr(version_metric, selector)
          braces = Promql.braces(selector)
          applied = "#{version_metric}#{braces}"
          "count(#{applied} != scalar(max(#{applied})))"
        end

        def self.validate!(version_metric:)
          raise ArgumentError, 'VersionSkewDefectTile: version_metric: required' if blank?(version_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :build_expr, :validate!, :blank?
      end
    end
  end
end
