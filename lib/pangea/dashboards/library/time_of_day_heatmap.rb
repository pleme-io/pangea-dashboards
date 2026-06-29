# frozen_string_literal: true

require 'pangea/dashboards/theme'

module Pangea
  module Dashboards
    module Library
      # The OFF-HOURS heatmap — ONE `:heatmap` of audit-event count bucketed by
      # hour-of-day, so a cluster of access at 3am (when nobody should be acting)
      # lights up as a hot band the operator finds preattentively. The time
      # anomaly atom of an access-anomaly board: most attacks happen off-hours,
      # and a heatmap of when-did-things-happen makes the unusual hour a SHAPE,
      # not a row to scan.
      #
      # ── Buildable-today form ────────────────────────────────────────────────
      # A true hour-of-day × weekday matrix wants a date-part extraction the
      # LogsQL/Grafana heatmap renderer does not yet expose as a typed verb. The
      # buildable-today form is a `stats by (<time_field>)` count over the audit
      # stream rendered as a `:heatmap` — the datasource buckets by time
      # interval, so a recurring off-hours band is still visible as a hot row.
      # When a `bucket_field:` already carries the hour-of-day (e.g. a
      # vector-derived `hour` label), the stats group by it directly for the
      # canonical hour-of-day lane. (A first-class hour×weekday matrix is a
      # renderer gap — same family as the :geomap / :status_history gaps.)
      #
      # ── Why event_driven, never floored ─────────────────────────────────────
      # Audit events are event-driven; a quiet hour with no cell is the honest
      # healthy reading (nobody acted), NOT a broken panel. LogsQL `stats` is
      # never floored.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'When' do
      #     Pangea::Dashboards::Library::TimeOfDayHeatmap.add(
      #       self, datasource: 'logs', stream: '{stream="audit"}')
      #   end
      module TimeOfDayHeatmap
        # datasource:    (req) the LogsQL/VictoriaLogs datasource uid
        # stream:        (req) the audit-log stream selector
        # filter:        optional extra LogsQL predicate (e.g. 'result:denied')
        # bucket_field:  the field to bucket the heatmap on. Default '_time' (the
        #                datasource buckets by interval → an off-hours band). Pass
        #                an 'hour'/'hour_of_day' label when the pipeline derives it
        #                for a canonical hour-of-day lane.
        # count_alias:   stats count alias (default 'count')
        # title:         cosmetic override
        def self.add(row, datasource:, stream:, filter: nil,
                     bucket_field: '_time', count_alias: 'count', title: nil)
          validate!(datasource: datasource, stream: stream, bucket_field: bucket_field)
          alias_ = count_alias.to_s.strip.empty? ? 'count' : count_alias.to_s
          pre    = blank?(filter) ? stream.to_s : "#{stream} #{filter}"
          expr   = "#{pre} | stats by (#{bucket_field}) count() #{alias_}"
          pid    = :"time_of_day_#{slug(bucket_field)}"
          row.panel pid, kind: :heatmap, width: Theme.full, height: Theme::TABLE_H do
            title title || 'Events by time-of-day (off-hours anomaly)'
            unit 'short'
            description 'Audit-event count bucketed by time-of-day — a hot off-hours ' \
                        'band is a time anomaly. (hour×weekday matrix is a renderer gap.)'
            # event_driven: a quiet hour with no cell is healthy, not broken.
            query 'A', expr, datasource: datasource, presence: :event_driven, legend: "{{#{bucket_field}}}"
          end
        end

        def self.validate!(datasource:, stream:, bucket_field:)
          raise ArgumentError, 'TimeOfDayHeatmap: datasource: required' if blank?(datasource)
          raise ArgumentError, 'TimeOfDayHeatmap: bucket_field: required' if blank?(bucket_field)
          raise ArgumentError, 'TimeOfDayHeatmap: stream: required' if blank?(stream)
          unless stream.to_s.include?('{')
            raise ArgumentError,
                  'TimeOfDayHeatmap: stream must be a LogsQL stream selector like ' \
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
