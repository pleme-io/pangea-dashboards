# frozen_string_literal: true

require 'pangea/dashboards/theme'

module Pangea
  module Dashboards
    module Library
      # The WHO/WHAT/WHEN/RESULT audit row — the core read of any audit board.
      # Pairs two LogsQL panels on one canvas, both off the same audit stream
      # (scoped by the dashboard's template variables + a free-text $search):
      #
      #   1. The raw event TABLE — every audit line (who did what, where, with
      #      which result), for deep reading. The full append-only who/what/when.
      #   2. A `stats by (result)` STACKED-bars timeseries — the same events
      #      partitioned by outcome over time, so a spike of denials/errors is a
      #      shape (a growing red band), not a number to compute.
      #
      # The table answers "show me the events"; the result-breakdown answers "is
      # the mix of outcomes healthy?" — together they are the audit board's body.
      #
      # ── Why stacked (options grafana stacking) ──────────────────────────────
      # The result label partitions the events (each event has exactly one
      # outcome), so the per-result counts SUM to the total. A stacked bar is the
      # honest encoding of a partition-over-time (mirrors ByPhaseStrip); set via
      # the typed options(grafana:) escape hatch, degrading to plain multi-series
      # on any backend that ignores the override.
      #
      # ── Why event_driven, never floored ─────────────────────────────────────
      # Audit events are event-driven; a quiet window with no rows / no bars is
      # the honest healthy reading, NOT a broken panel. LogsQL `stats` is never
      # `or vector(0)`-floored (that is a PromQL idiom; an empty facet is real).
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Audit events' do
      #     Pangea::Dashboards::Library::AuditEventRow.add(
      #       self, datasource: 'logs', stream: '{stream="audit"}',
      #       result_field: 'result')
      #   end
      module AuditEventRow
        # datasource:    (req) the LogsQL/VictoriaLogs datasource uid
        # stream:        (req) the audit-log stream selector, e.g. '{stream="audit"}'
        # search:        optional free-text filter appended to the stream (a
        #                '$search' dashboard variable by default → no-op when empty)
        # result_field:  the outcome label the breakdown partitions on (default 'result')
        # name:          slug source + panel-title prefix (default 'audit')
        # count_alias:   stats count alias on the breakdown (default 'count')
        def self.add(row, datasource:, stream:, search: '$search',
                     result_field: 'result', name: 'audit', count_alias: 'count')
          validate!(datasource: datasource, stream: stream, result_field: result_field)
          sl     = slug(name)
          alias_ = count_alias.to_s.strip.empty? ? 'count' : count_alias.to_s
          scoped = blank?(search) ? stream.to_s : "#{stream} #{search}"
          breakdown = "#{scoped} | stats by (#{result_field}) count() #{alias_}"

          # 1. the raw who/what/when/result table — full context.
          row.panel :"#{sl}_events", kind: :table, width: Theme.half, height: Theme::TABLE_H do
            title "#{name} events (who · what · when · result)"
            description 'Append-only audit events for this window — full context, ' \
                        'scoped by the dashboard variables + $search.'
            query 'A', scoped, datasource: datasource, instant: true, presence: :event_driven
          end

          # 2. the result-partitioned stacked-bars timeseries — outcome mix over time.
          row.panel :"#{sl}_by_result", kind: :timeseries, width: Theme.half, height: Theme::TABLE_H do
            title "#{name} by #{result_field}"
            unit 'short'
            min 0
            graph :area
            # Result partitions the events ⇒ honest only when stacked-as-bars
            # (band heights ARE the per-result counts; the envelope is the total).
            # Typed options(grafana:) escape hatch — degrades to plain lines.
            options(grafana: { 'fieldConfig' => { 'defaults' => { 'custom' => { 'drawStyle' => 'bars', 'stacking' => { 'mode' => 'normal', 'group' => 'A' } } } } })
            query 'A', breakdown, datasource: datasource, presence: :event_driven, legend: "{{#{result_field}}}"
          end
        end

        def self.validate!(datasource:, stream:, result_field:)
          raise ArgumentError, 'AuditEventRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'AuditEventRow: result_field: required' if blank?(result_field)
          raise ArgumentError, 'AuditEventRow: stream: required' if blank?(stream)
          unless stream.to_s.include?('{')
            raise ArgumentError,
                  'AuditEventRow: stream must be a LogsQL stream selector like ' \
                  "{stream=\"audit\"}, got: #{stream.inspect}"
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :validate!, :blank?, :slug
      end
    end
  end
end
