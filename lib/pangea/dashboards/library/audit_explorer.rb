# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/success_fail_ratio_gauge'
require 'pangea/dashboards/library/log_facet_topn'
require 'pangea/dashboards/library/audit_event_row'
require 'pangea/dashboards/library/log_windows'

module Pangea
  module Dashboards
    module Library
      # THE audit-board keystone. A whole self-service audit-log explorer
      # Types::Dashboard over a LogsQL/VictoriaLogs audit stream, telling the
      # canonical audit triage STORY top-to-bottom (Theme: Status → detail → raw):
      #
      #   Headline      →  failure-ratio gauge — "is the success/fail mix healthy?"
      #   Result mix    →  who/what/when/result table + by-result stacked bars
      #   Facets        →  top-N by each facet field (who, what, where) — the
      #                    loudest actors / operations / sources, one table per facet
      #   Raw logs      →  full + ERROR + error-rate windows over the scoped stream
      #
      # A free-text $search box + the facet fields scope the whole board, so the
      # operator narrows to "this actor, this operation" and reads the raw lines.
      # Reads ONLY a generic append-only audit stream keyed by who/what/when/
      # result — no consumer specifics; a consumer fills the stream + facet list.
      #
      #   dash = Pangea::Dashboards::Library::AuditExplorer.build(
      #     id: :audit_explorer, name: 'Audit', datasource: 'logs',
      #     stream: '{stream="audit"}',
      #     facets: %w[actor operation result target source_ip])
      module AuditExplorer
        DEFAULT_FACETS = %w[actor operation result target source_ip].freeze

        # id/name:       dashboard id + human title
        # datasource:    (req) the LogsQL/VictoriaLogs audit datasource uid
        # stream:        (req) the audit-log stream selector, e.g. '{stream="audit"}'
        # facets:        log fields to rank top-N by (who/what/where)
        # result_field:  the outcome field for the breakdown + ratio (default 'result')
        # facet_n:       how many rows each facet table keeps (default 10)
        # success_values / failed_values: result values for the headline gauge
        # time_from:     initial dashboard window (default now-6h)
        def self.build(id:, datasource:, stream:, name: nil, facets: DEFAULT_FACETS,
                       result_field: 'result', facet_n: 10,
                       success_values: nil, failed_values: nil, time_from: 'now-6h')
          validate!(id: id, datasource: datasource, stream: stream, facets: facets)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · audit")
          b.tags('pleme-io', 'audit', 'security')
          b.time(from: time_from, to: 'now')

          # free-text search across the audit stream (scopes the whole board).
          b.variable(:search, kind: :textbox, label: 'search', default: '')
          scoped = "#{stream} $search"

          # 1. Headline — the failure-ratio gauge (is the outcome mix healthy?).
          ratio_opts = {}
          ratio_opts[:success_values] = success_values if success_values
          ratio_opts[:failed_values]  = failed_values if failed_values
          b.row('Status — success / fail mix') do
            Library::SuccessFailRatioGauge.add(self, datasource: datasource, stream: scoped,
                                               result_field: result_field, width: Theme.full,
                                               title: 'Audit failure ratio', **ratio_opts)
          end

          # 2. Result mix — who/what/when/result table + by-result stacked bars.
          b.row('Audit events — who · what · when · result') do
            Library::AuditEventRow.add(self, datasource: datasource, stream: stream,
                                       search: '$search', result_field: result_field, name: (name || id).to_s)
          end

          # 3. Facets — top-N by each facet field (the loudest who/what/where).
          Array(facets).each do |field|
            f = field.to_s
            b.row("Top #{f}") do
              Library::LogFacetTopN.add(self, datasource: datasource, stream: scoped,
                                        field: f, n: facet_n)
            end
          end

          # 4. Raw logs — full + ERROR window + error-rate over the scoped stream.
          b.row('Logs') do
            Library::LogWindows.add_all(self, name: (name || id).to_s, stream: scoped, datasource: datasource)
          end

          b.build
        end

        def self.validate!(id:, datasource:, stream:, facets:)
          raise ArgumentError, 'AuditExplorer: id: required' if blank?(id)
          raise ArgumentError, 'AuditExplorer: datasource: required' if blank?(datasource)
          raise ArgumentError, 'AuditExplorer: stream: required' if blank?(stream)
          unless stream.to_s.include?('{')
            raise ArgumentError,
                  'AuditExplorer: stream must be a LogsQL stream selector like ' \
                  "{stream=\"audit\"}, got: #{stream.inspect}"
          end
          raise ArgumentError, 'AuditExplorer: facets must be a non-empty Array' \
            unless facets.is_a?(::Array) && !facets.empty?
        end

        def self.blank?(v)
          return true if v.nil?
          return v.empty? if v.is_a?(::Hash) || v.is_a?(::Array)

          v.to_s.strip.empty?
        end
        private_class_method :validate!, :blank?
      end
    end
  end
end
