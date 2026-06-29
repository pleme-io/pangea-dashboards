# frozen_string_literal: true

require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # A StatusOverview SIGNAL builder (NOT a panel) for the "an entity appeared
      # this window that was ABSENT the prior window" anomaly — the generic
      # new-actor / new-source-IP / new-geo atom. It returns the typed
      # { name:, expr:, warn:, crit:, desc: } Hash that slots straight into
      # StatusOverview.add(signals: [...]) — sibling of AtCeilingDefectTile.signal
      # and the SecurityPostureSignals builders.
      #
      # ── The set-difference shape ────────────────────────────────────────────
      # "present now AND absent before" is a vector set-difference: the count of
      # series that exist in the current window but whose value `offset
      # prior_window` is missing. PromQL expresses "B is absent at this identity"
      # as `unless on(<id>) (B offset W)` — keep A's series that have NO matching
      # B in the prior window:
      #
      #   count( present unless on(<id>) (present offset <prior_window>) )
      #
      # A brand-new actor (no series one window ago) survives the `unless`; a
      # returning actor is filtered out. The count is the number of newly-seen
      # entities — the anomaly magnitude.
      #
      # ── Why no zero-floor ───────────────────────────────────────────────────
      # This is a `count(...)` over a set-difference: an empty difference IS the
      # value 0 (count of nothing), honest without `or vector(0)`. The healthy
      # state "0 new entities" renders green.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   StatusOverview.add(self, datasource: ds, signals: [
      #     Pangea::Dashboards::Library::NewEntityWindowSignal.signal(
      #       presence_metric: 'audit_actor_seen', identity_labels: %w[actor],
      #       prior_window: '1d', name: 'New actors (vs yesterday)'),
      #   ])
      module NewEntityWindowSignal
        DEFAULT_NAME = 'New entities this window'
        DEFAULT_DESC =
          'Entities present in the current window that were ABSENT one ' \
          'prior_window ago — a new actor / source / geo. RED ⇒ investigate ' \
          'who just appeared.'

        # presence_metric: (req) a metric whose series exist per entity (a
        #                  per-entity gauge/counter — its mere presence marks the
        #                  entity as seen this window)
        # identity_labels: (req) the labels identifying an entity (e.g. %w[actor])
        # prior_window:    the look-back the entity must have been absent across
        #                  (default '1d')
        # selector:        optional typed Hash/String scoping the population
        # warn / crit:     defect thresholds (default 1 / 5)
        # name / desc:     tile title + description overrides
        def self.signal(presence_metric:, identity_labels:, prior_window: '1d',
                        selector: nil, warn: 1, crit: 5, name: DEFAULT_NAME, desc: nil)
          validate!(presence_metric: presence_metric, identity_labels: identity_labels,
                    prior_window: prior_window)
          {
            name: name,
            expr: build_expr(presence_metric, identity_labels, prior_window, selector),
            warn: warn,
            crit: crit,
            desc: desc || DEFAULT_DESC
          }
        end

        # count( present unless on(id) (present offset W) )
        def self.build_expr(metric, identity_labels, prior_window, selector)
          braces  = Promql.braces(selector)
          present = "#{metric}#{braces}"
          prior   = "#{metric}#{braces} offset #{prior_window}"
          "count(#{present} unless#{on(identity_labels)} (#{prior}))"
        end

        # ` on (a, b)` identity-matching clause — the mirror of Promql.by for the
        # `unless` vector op, reusing its normalisation so the label list renders
        # ONE way fleet-wide, then swaps `by`→`on`.
        def self.on(labels)
          Promql.by(labels).sub('by (', 'on (')
        end

        def self.validate!(presence_metric:, identity_labels:, prior_window:)
          raise ArgumentError, 'NewEntityWindowSignal: presence_metric: required' if blank?(presence_metric)
          raise ArgumentError, 'NewEntityWindowSignal: prior_window: required' if blank?(prior_window)
          labels = Array(identity_labels).compact.map(&:to_s).reject(&:empty?)
          raise ArgumentError, 'NewEntityWindowSignal: identity_labels: required (non-empty)' if labels.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :build_expr, :on, :validate!, :blank?
      end
    end
  end
end
