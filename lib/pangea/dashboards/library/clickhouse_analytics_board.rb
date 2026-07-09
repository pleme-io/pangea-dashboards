# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/datasource'

module Pangea
  module Dashboards
    module Library
      # A whole ClickHouse analytics Types::Dashboard built from a typed list of
      # SQL panels. The Path-A typed-SQL mixin: each panel is authored as raw
      # ClickHouse SQL (not PromQL/LogsQL), pointed at a :sql-language datasource
      # (default 'clickhouse'), and rendered through Render::Grafana's rawSql
      # target arm. Analytics queries the metrics/logs pipelines can't express
      # (GROUP BY, window functions, joins over a ClickHouse table) live here.
      #
      #   dash = Pangea::Dashboards::Library::ClickHouseAnalyticsBoard.build(
      #     id: :tendril_analytics, datasource: 'clickhouse',
      #     panels: [
      #       { title: 'events / 5m',        sql: "SELECT toStartOfFiveMinute(ts) t, count() c FROM tendril.events GROUP BY t ORDER BY t", kind: :timeseries },
      #       { title: 'top namespaces',     sql: "SELECT namespace, count() c FROM tendril.events GROUP BY namespace ORDER BY c DESC LIMIT 20", kind: :table },
      #       { title: 'total (24h)',        sql: "SELECT count() FROM tendril.events WHERE ts > now() - INTERVAL 24 HOUR", kind: :stat },
      #     ])
      #
      # params:
      #   id:         (req) logical dashboard id (Symbol) — derives uid + title
      #   datasource: the :sql datasource uid (default 'clickhouse')
      #   panels:     Array of { title:, sql:, kind: } (kind ∈ table/timeseries/
      #               stat/gauge/pie; optional width:/height: overrides). String
      #               or Symbol keys both accepted (YAML → CRD hands string keys).
      #   title:      dashboard title override
      #   time_from:  initial time window (default now-6h)
      #   tags:       tag list override
      module ClickHouseAnalyticsBoard
        DEFAULT_DATASOURCE = 'clickhouse'
        DEFAULT_TAGS       = %w[pleme-io clickhouse analytics].freeze

        def self.build(id:, datasource: DEFAULT_DATASOURCE, panels: [], title: nil,
                       time_from: 'now-6h', tags: nil)
          validate!(id: id, datasource: datasource, panels: panels)
          specs = panels.each_with_index.map { |p, i| normalize(p, i) }

          b = DSL::DashboardBuilder.new(id: id)
          b.title(title || "#{id} · clickhouse analytics")
          b.tags(*(Array(tags).empty? ? DEFAULT_TAGS : tags))
          b.time(from: time_from, to: 'now')

          # One "Analytics" row holding every SQL panel; the grid tiler in
          # Render::Grafana wraps them across the 24-col grid by width.
          b.row('Analytics') do
            specs.each do |s|
              panel s[:pid], kind: s[:kind], width: s[:width], height: s[:height] do
                title s[:title]
                # :conditional — a per-query analytics series may be legitimately
                # empty (no rows in the window); the Health probe must not flag it.
                query 'A', s[:sql], datasource: datasource, presence: :conditional
              end
            end
          end

          b.build
        end

        # ── internals ──────────────────────────────────────────────────

        # Normalize one author panel hash (string OR symbol keys) into the typed
        # shape the DSL consumes, with role-based width/height defaults.
        def self.normalize(panel, idx)
          h = symbolize(panel)
          kind = (h[:kind] || :table).to_sym
          title = h[:title]
          sql   = h[:sql]
          raise ArgumentError, "ClickHouseAnalyticsBoard: panel #{idx} missing title:" if blank?(title)
          raise ArgumentError, "ClickHouseAnalyticsBoard: panel #{idx} (#{title}) missing sql:" if blank?(sql)
          {
            pid:    :"ch_panel_#{idx}",
            kind:   kind,
            title:  title.to_s,
            sql:    sql.to_s,
            width:  (h[:width]  || default_width(kind)),
            height: (h[:height] || default_height(kind))
          }
        end

        def self.default_width(kind)
          case kind
          when :stat, :gauge     then Pangea::Dashboards::Theme.third   # 8 — a few side by side
          when :timeseries, :pie then Pangea::Dashboards::Theme.half    # 12
          else                        Pangea::Dashboards::Theme.full    # 24 — tables full width
          end
        end

        def self.default_height(kind)
          case kind
          when :stat, :gauge     then Pangea::Dashboards::Theme::STAT_H  # 4
          when :timeseries, :pie then Pangea::Dashboards::Theme::TS_H    # 8
          else                        Pangea::Dashboards::Theme::TABLE_H # 9
          end
        end

        def self.symbolize(h)
          (h || {}).each_with_object({}) { |(k, v), o| o[k.to_sym] = v }
        end

        def self.validate!(id:, datasource:, panels:)
          raise ArgumentError, 'ClickHouseAnalyticsBoard: id: required' if blank?(id)
          raise ArgumentError, 'ClickHouseAnalyticsBoard: datasource: required' if blank?(datasource)
          raise ArgumentError, 'ClickHouseAnalyticsBoard: panels must be an Array' unless panels.is_a?(Array)
          raise ArgumentError, 'ClickHouseAnalyticsBoard: panels: must not be empty' if panels.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?

        private_class_method :normalize, :default_width, :default_height,
                             :symbolize, :validate!, :blank?
      end
    end
  end
end
