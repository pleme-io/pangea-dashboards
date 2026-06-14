# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The lifecycle DISTRIBUTION row — `sum by(phase)(entity_by_phase)` as a
      # STACKED timeseries that shows, at a glance, how a population of entities
      # is spread across the states of its FSM over time (Compiling / Planning /
      # Applying / Ready …, or Pending / Running / Succeeded / Failed for pods).
      # A stacked area reads as "the whole fleet, coloured by what it's doing" —
      # the band heights ARE the per-phase counts and the total is the envelope,
      # so a population draining into a terminal phase (or piling up in a stuck
      # one) is a shape, not a number to compute.
      #
      # Absorbed from the twin hand-written panels in the corpus:
      # pangea_operator.rb `templates_by_phase` + the companion `settled` stat,
      # and kubernetes_cluster.rb `pods_by_phase`. Both are the same shape — a
      # by-phase stacked series plus an optional "how many reached the good
      # terminal" liveness stat — generalised here so the next FSM dashboard is
      # one call, not a re-typed panel pair.
      #
      # ── Why stacked (options grafana stacking) ──────────────────────────
      # The phases of an FSM partition the population: every entity is in
      # exactly one phase, so the counts SUM to the total. A stacked area is
      # the honest encoding of a partition-over-time — unstacked lines would
      # imply the series are independent and hide the total. Stacking is set
      # through the typed `options(grafana:)` escape hatch (fieldConfig custom
      # stacking), never hardcoded into the renderer — it degrades to a normal
      # multi-series timeseries on any backend that ignores the override.
      #
      # ── Why the optional settled stat ───────────────────────────────────
      # The one phase the operator actually wants to be HIGH is the good
      # terminal (Settled / Ready / Running). That gets a liveness stat —
      # red below the expected count, green at/above — so "is the fleet
      # converged?" is answerable without reading the stack.
      #
      #   row 'Lifecycle' do
      #     Pangea::Dashboards::Library::ByPhaseStrip.add(
      #       self, datasource: 'vm', phase_metric: 'pangea_template_by_phase',
      #       settled_metric: 'pangea_template_settled', settled_threshold: 7)
      #   end
      module ByPhaseStrip
        # phase_metric:      (req) a gauge counting entities labelled by phase,
        #                    e.g. `pangea_template_by_phase{phase="Applying"}`.
        # settled_metric:    optional gauge of entities in the good terminal —
        #                    rendered as a liveness stat next to the strip.
        # settled_threshold: count the settled stat must reach to read green
        #                    (default 1; LOWER = worse, so liveness_steps).
        # phase_label:       the label the series is broken down by (default
        #                    'phase').
        # title:             the stacked strip's title (default 'By phase').
        # selector:          typed Hash/String matcher scoping the population.
        # settled_title / settled_unit: cosmetic overrides for the stat.
        def self.add(row, datasource:, phase_metric:, settled_metric: nil, settled_threshold: 1,
                     phase_label: 'phase', title: 'By phase', selector: nil,
                     settled_title: 'Settled', settled_unit: 'short')
          validate!(datasource: datasource, phase_metric: phase_metric, phase_label: phase_label)

          # The strip narrows to leave room for the stat when one is present, so
          # the pair sits on one row (Gestalt: proximity — distribution + the
          # one number you read it for, side by side).
          strip_width = settled_metric ? Theme.two_thirds : Theme.full
          add_strip(row, datasource: datasource, phase_metric: phase_metric,
                    phase_label: phase_label, title: title, selector: selector, width: strip_width)

          return if blank?(settled_metric)

          add_settled(row, datasource: datasource, settled_metric: settled_metric,
                      settled_threshold: settled_threshold, selector: selector,
                      title: settled_title, unit: settled_unit)
        end

        # The stacked by-phase distribution. `sum by(phase)(metric{sel})` — a
        # continuous gauge (a phase is always populated once the fleet exists),
        # so no zero-floor. Stacking is the typed grafana override.
        def self.add_strip(row, datasource:, phase_metric:, phase_label:, title:, selector:, width:)
          expr = "sum#{Promql.by(phase_label)}(#{phase_metric}#{Promql.braces(selector)})"
          pid  = :"by_#{slug(phase_label)}_#{slug(phase_metric)}"
          row.panel pid, kind: :timeseries, width: width, height: Theme::TS_H do
            title title
            unit 'short'
            min 0
            graph :area
            # The partition is honest only when stacked — the band heights ARE
            # the per-phase counts and the envelope IS the total. Set through
            # the typed options(grafana:) escape hatch (fieldConfig custom
            # stacking); ignored gracefully by non-stacking backends.
            options(grafana: { 'fieldConfig' => { 'defaults' => { 'custom' => { 'stacking' => { 'mode' => 'normal', 'group' => 'A' } } } } })
            # continuous: an FSM phase count is sampled, not event-driven —
            # there is always a value once the population exists.
            query 'A', expr, datasource: datasource, presence: :continuous, legend: "{{#{phase_label}}}"
          end
        end

        # The "did the fleet converge?" stat — the good-terminal count with
        # liveness thresholds (red below the expected count, green at/above).
        def self.add_settled(row, datasource:, settled_metric:, settled_threshold:, selector:, title:, unit:)
          expr  = "sum(#{settled_metric}#{Promql.braces(selector)})"
          pid   = :"settled_#{slug(settled_metric)}"
          steps = Theme.liveness_steps(ok: settled_threshold)
          row.panel pid, kind: :stat, width: Theme.third, height: Theme::STAT_H do
            title title
            unit unit
            description 'Entities that reached the good terminal phase. Green = converged.'
            display :background      # colour the tile — preattentive liveness
            graph :area              # trend sparkline behind the number (Tufte)
            # continuous: a settled count is a sampled gauge, not event-driven.
            query 'A', expr, datasource: datasource, presence: :continuous
            threshold steps: steps
          end
        end

        def self.validate!(datasource:, phase_metric:, phase_label:)
          raise ArgumentError, 'ByPhaseStrip: datasource: required' if blank?(datasource)
          raise ArgumentError, 'ByPhaseStrip: phase_metric: required' if blank?(phase_metric)
          raise ArgumentError, 'ByPhaseStrip: phase_label: required' if blank?(phase_label)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_strip, :add_settled, :validate!, :blank?, :slug
      end
    end
  end
end
