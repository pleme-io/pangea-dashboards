# frozen_string_literal: true

require 'pangea/dashboards/theme'

module Pangea
  module Dashboards
    module Library
      # The LogsQL cousin of TopNTable. ONE instant `:table` ranking the top-N
      # values of an audit/security log FIELD by event count over the window:
      #
      #   {stream} <filter?> | stats by (field) count() N | sort by (N) desc | limit n
      #
      # Where TopNTable ranks a metric series by a PromQL topk(), this ranks a
      # LogsQL FACET — "the loudest actors", "the most-denied operations", "the
      # busiest source IPs" — straight off the audit log stream. The two are the
      # same triage shape (who/what is doing the MOST?) over the two backends:
      # TopNTable for metrics, LogFacetTopN for logs.
      #
      # ── Why instant + event_driven ──────────────────────────────────────────
      # An instant table is a now-snapshot the datasource evaluates over the
      # dashboard window. The count is over an audit log stream that is
      # event-driven by nature (no events ⇒ no rows is the honest, healthy
      # answer for a quiet window — NOT a broken panel), so the query is marked
      # event_driven; LogsQL `stats` is never floored (an empty facet is a real,
      # good "nobody did this" reading).
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Top actors' do
      #     Pangea::Dashboards::Library::LogFacetTopN.add(
      #       self, datasource: 'logs', stream: '{stream="audit"}',
      #       field: 'actor', n: 10)
      #   end
      module LogFacetTopN
        # datasource:  (req) the LogsQL/VictoriaLogs datasource uid
        # stream:      (req) the LogsQL stream selector, e.g. '{stream="audit"}'
        # field:       (req) the log field to facet + rank by (actor/operation/…)
        # n:           how many rows to keep (default 10)
        # filter:      optional extra LogsQL predicate appended to the stream
        #              (e.g. 'result:denied' to rank only failures)
        # count_alias: the stats count alias (default 'count')
        # title:       cosmetic override
        def self.add(row, datasource:, stream:, field:, n: 10, filter: nil,
                     count_alias: 'count', title: nil)
          validate!(datasource: datasource, stream: stream, field: field, n: n)
          num   = n.to_i
          alias_ = count_alias.to_s.strip.empty? ? 'count' : count_alias.to_s
          pre   = blank?(filter) ? stream.to_s : "#{stream} #{filter}"
          expr  = "#{pre} | stats by (#{field}) count() #{alias_} | sort by (#{alias_}) desc | limit #{num}"
          pid   = :"log_facet_#{slug(field)}_top#{num}"
          ttl   = title || "Top #{num} by #{field}"
          row.panel pid, kind: :table, width: Theme.full, height: Theme::TABLE_H do
            title ttl
            description "Top #{num} #{field} values by audit-event count this window. " \
                        '(panel links: drill-down is a renderer gap — scope via dashboard variables.)'
            # event_driven: an empty facet on a quiet window is healthy, not broken.
            query 'A', expr, datasource: datasource, instant: true, presence: :event_driven
          end
        end

        def self.validate!(datasource:, stream:, field:, n:)
          raise ArgumentError, 'LogFacetTopN: datasource: required' if blank?(datasource)
          raise ArgumentError, 'LogFacetTopN: field: required' if blank?(field)
          raise ArgumentError, 'LogFacetTopN: stream: required' if blank?(stream)
          unless stream.to_s.include?('{')
            raise ArgumentError,
                  'LogFacetTopN: stream must be a LogsQL stream selector like ' \
                  "{stream=\"audit\"}, got: #{stream.inspect}"
          end
          raise ArgumentError, "LogFacetTopN: n must be a positive integer (got #{n.inspect})" \
            unless n.to_i.positive?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :validate!, :blank?, :slug
      end
    end
  end
end
