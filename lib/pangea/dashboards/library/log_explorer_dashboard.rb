# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/log_windows'

module Pangea
  module Dashboards
    module Library
      # A whole self-service log-explorer Types::Dashboard: a free-text $search
      # box + cascading query template variables (root → app → container …)
      # that scope a live log stream, plus a log-volume-by-dimension chart and
      # the standard full + ERROR + error-rate windows. The akeylesslabs
      # templated-log-explorer (textbox search + cascading label_values + log
      # stream + log-volume bars), lifted onto the typed AST + Variable nodes.
      # LogsQL/VictoriaLogs-native (pleme-io), with the same shape working on a
      # Loki datasource.
      #
      #   dash = Pangea::Dashboards::Library::LogExplorerDashboard.build(
      #     id: :rio_logs, logs_datasource: 'vlogs',
      #     root_label: 'namespace', cascade: %w[app container])
      module LogExplorerDashboard
        # logs_datasource: (req) the LogsQL/Loki datasource uid
        # root_label:      the top scoping label (default 'namespace')
        # cascade:         labels that narrow within root (default app, container)
        # default_namespace: pre-select for the root var
        # error_regex:     LogsQL error filter for the ERROR window (passed to LogWindows)
        # time_from:       initial dashboard time window (default now-1h)
        def self.build(id:, logs_datasource:, root_label: 'namespace', cascade: %w[app container],
                       default_namespace: nil, error_regex: nil, time_from: 'now-1h', title: nil)
          validate!(id: id, logs_datasource: logs_datasource, root_label: root_label, cascade: cascade)
          b = DSL::DashboardBuilder.new(id: id)
          b.title(title || "#{id} · logs")
          b.tags('pleme-io', 'log-explorer')
          b.time(from: time_from, to: 'now')

          # Free-text search across the selected stream.
          b.variable(:search, kind: :textbox, label: 'search', default: '')

          # Root scope (e.g. namespace) — a query var over the datasource.
          b.variable(root_label.to_sym, kind: :query, datasource_uid: logs_datasource,
                     label: root_label, query: "label_values(#{root_label})",
                     include_all: true, multi: false,
                     **(default_namespace ? { default: default_namespace } : {}))

          # Cascading scopes — each narrows within root + the prior levels.
          prior = [root_label]
          Array(cascade).each do |level|
            filter = prior.map { |l| %(#{l}=~"$#{l}") }.join(',')
            b.variable(level.to_sym, kind: :query, datasource_uid: logs_datasource,
                       label: level, query: "label_values({#{filter}}, #{level})",
                       include_all: true, multi: false)
            prior << level
          end

          # The var-scoped stream selector (=~ so an "All" selection matches).
          all_labels = [root_label] + Array(cascade)
          stream = '{' + all_labels.map { |l| %(#{l}=~"$#{l}") }.join(',') + '}'

          # Log-volume by the deepest dimension — the "where is the noise?" bar.
          deepest = (Array(cascade).last || root_label)
          b.row('Volume') do
            panel :log_volume, kind: :timeseries, width: Pangea::Dashboards::Theme.full,
                  height: Pangea::Dashboards::Theme::TS_H do
              title "Log volume by #{deepest}"
              unit 'logs'
              graph :area
              options(grafana: { 'fieldConfig' => { 'defaults' => { 'custom' => { 'drawStyle' => 'bars', 'stacking' => { 'mode' => 'normal' } } } } })
              # VictoriaLogs stats-by-time; the datasource buckets by interval.
              query 'A', "#{stream} | stats by (#{deepest}) count() as logs",
                    datasource: logs_datasource, presence: :continuous, legend: "{{#{deepest}}}"
            end
          end

          # The standard windows over the scoped stream + $search — full log
          # table, the dedicated ERROR window, and the error-rate stat. LogsQL
          # appends the free-text $search filter to the stream selector.
          scoped = "#{stream} $search"
          b.row('Logs') do
            opts = error_regex ? { error_filter: error_regex } : {}
            Library::LogWindows.add_all(self, name: id.to_s, stream: scoped, datasource: logs_datasource, **opts)
          end

          b.build
        end

        def self.validate!(id:, logs_datasource:, root_label:, cascade:)
          raise ArgumentError, 'LogExplorerDashboard: id: required' if blank?(id)
          raise ArgumentError, 'LogExplorerDashboard: logs_datasource: required' if blank?(logs_datasource)
          raise ArgumentError, 'LogExplorerDashboard: root_label: required' if blank?(root_label)
          raise ArgumentError, 'LogExplorerDashboard: cascade must be an Array' unless cascade.is_a?(Array)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
