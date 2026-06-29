# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'

module Pangea
  module Dashboards
    module Library
      # The AGE-VS-THRESHOLD row — the rotation/staleness specialisation of the
      # FloorCeilingEnvelope idea, applied to "how old is each thing vs the max
      # age it's allowed to reach". Pairs two panels on one canvas:
      #
      #   1. The AGE envelope — each entity's *_age_seconds (A) riding from 0 up
      #      toward the hard max-age CEILING (C). A series hugging the ceiling is
      #      about to breach its rotation SLA; a flat-line near 0 just rotated.
      #      (Floor is the constant 0 baseline — age never goes negative.)
      #   2. A count-over-threshold DEFECT `:stat` — how many entities are at/over
      #      the max age right now (the over-threshold count), coloured by
      #      defect_steps. The number to act on.
      #
      # Where FloorCeilingEnvelope rides a value inside [floor, limit, ceiling],
      # this rides AGE up to a single max-age ceiling — the same "value vs its
      # bound, read on one axis" shape, specialised to rotation.
      #
      # ── Why continuous on the envelope, event_driven on the defect ──────────
      # Age + ceiling are gauges always present while the entity exists (a real 0
      # age is distinct from no-series) → :continuous, never floored. The defect
      # is a `count(...)` over a threshold whose empty match is a real 0, but it
      # is rendered event_driven + floored so a never-breached fleet reads a lit
      # green 0 rather than ambiguous no-data.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Secret age vs max-age' do
      #     Pangea::Dashboards::Library::AgeVsThresholdRow.add(
      #       self, datasource: 'metrics', age_metric: 'secret_age_seconds',
      #       max_age: 7_776_000)            # 90d
      #   end
      module AgeVsThresholdRow
        # datasource:      (req) the metrics datasource uid
        # age_metric:      (req) the per-entity *_age_seconds gauge (series A)
        # max_age:         the hard max-age ceiling (seconds OR PromQL duration)
        # max_age_metric:  a per-entity max-age gauge instead of a flat constant
        #                  (drawn as the ceiling series C, matched on identity)
        # selector:        typed Hash/String scoping the population
        # identity_labels: identity for the per-entity max_age_metric intersection
        # unit:            value unit for the envelope (default 's' — seconds)
        # legend_labels:   per-series legend suffix (default '{{name}}')
        # title:           cosmetic override on the envelope
        def self.add(row, datasource:, age_metric:, max_age: nil, max_age_metric: nil,
                     selector: nil, identity_labels: %w[name], unit: 's',
                     legend_labels: '{{name}}', title: nil)
          validate!(datasource: datasource, age_metric: age_metric,
                    max_age: max_age, max_age_metric: max_age_metric)
          braces  = Promql.braces(selector)
          age     = "#{age_metric}#{braces}"
          ll      = legend_labels.to_s.strip
          age_leg = ll.empty? ? 'age' : "age #{ll}"

          # the ceiling series + the over-threshold predicate, by mode.
          if !blank?(max_age_metric)
            ceiling_expr = "#{max_age_metric}#{braces}"
            ceiling_leg  = ll.empty? ? 'max-age' : "max-age #{ll}"
            over_expr    = "count((#{age} >=#{on(identity_labels)} #{max_age_metric}#{braces}))"
            ceiling_desc = 'per-entity max-age'
          else
            secs         = max_age.to_s
            ceiling_expr = "(#{age} * 0) + #{secs}"  # the flat max-age line, per series
            ceiling_leg  = 'max-age'
            over_expr    = "count(#{age} >= #{secs})"
            ceiling_desc = "max-age #{secs}s"
          end

          # 1. age riding from 0 toward the max-age ceiling.
          row.panel :"age_envelope_#{slug(age_metric)}", kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title title || 'Age vs max-age'
            unit unit
            min 0
            graph :area
            description "Each entity's age (A) riding up toward its #{ceiling_desc} ceiling (C). " \
                        'Hugging the ceiling ⇒ about to breach its rotation SLA.'
            query 'A', age, datasource: datasource, presence: :continuous, legend: age_leg
            query 'C', ceiling_expr, datasource: datasource, presence: :continuous, legend: ceiling_leg
          end

          # 2. how many are over the threshold right now.
          row.panel :"age_over_threshold_#{slug(age_metric)}", kind: :stat, width: Theme.third, height: Theme::STAT_H do
            title 'Over max-age'
            unit 'short'
            description 'Entities at/over the max age now. RED ⇒ overdue rotation.'
            display :background
            graph :area
            query 'A', Floor.zero(over_expr), datasource: datasource, presence: :event_driven
            threshold steps: Theme.defect_steps(warn: 1, crit: 5)
          end
        end

        # ` on (a, b)` clause for the per-entity max-age intersection.
        def self.on(labels)
          Promql.by(labels).sub('by (', 'on (')
        end

        def self.validate!(datasource:, age_metric:, max_age:, max_age_metric:)
          raise ArgumentError, 'AgeVsThresholdRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'AgeVsThresholdRow: age_metric: required' if blank?(age_metric)
          raise ArgumentError, 'AgeVsThresholdRow: max_age or max_age_metric required' \
            if blank?(max_age) && blank?(max_age_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :on, :validate!, :blank?, :slug
      end
    end
  end
end
