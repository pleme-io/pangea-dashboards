# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/new_entity_window_signal'
require 'pangea/dashboards/library/failed_auth_row'
require 'pangea/dashboards/library/time_of_day_heatmap'
require 'pangea/dashboards/library/log_facet_topn'

module Pangea
  module Dashboards
    module Library
      # The ACCESS-ANOMALY board. Defects-first, the access story top-to-bottom:
      #
      #   Anomaly wall  →  new-actor / new-source-IP defects (StatusOverview of
      #                    NewEntityWindowSignal hashes) — "who just appeared?"
      #   Failed auth   →  the FailedAuthRow RED triple (rate · ratio · distinct actors)
      #   Off-hours     →  TimeOfDayHeatmap — access bucketed by time-of-day
      #   Geo / source  →  top-N by source-IP / geo facets off the audit stream
      #   Brute force   →  top-N by actor among FAILED events (the offender table)
      #
      # Reads two generic signal classes: gateway/auth `/metrics` (the auth
      # counter, for the RED row + new-entity defects) and a cloud access / WAF
      # log stream (LogsQL, for the off-hours heatmap + geo/source/brute-force
      # facets). A consumer supplies the metric + the log stream; no specifics.
      #
      #   dash = Pangea::Dashboards::Library::AccessAnomalyBoard.build(
      #     id: :access_anomaly, name: 'Access', datasource: 'metrics',
      #     logs_datasource: 'logs', stream: '{stream="access"}',
      #     auth_metric: 'auth_attempts_total')
      module AccessAnomalyBoard
        # id/name:          dashboard id + human title
        # datasource:       (req) the METRICS datasource (auth RED + new-entity defects)
        # logs_datasource:  (req) the LogsQL datasource (heatmap + facets)
        # stream:           (req) the access/WAF log stream selector
        # auth_metric:      the auth-attempt *_total counter (default 'auth_attempts_total')
        # result_label:     auth outcome label (default 'result')
        # failure_results:  result values counted as a failure
        # actor_label / source_label / geo_label: facet/identity labels
        # actor_presence_metric / source_presence_metric: per-entity gauges whose
        #                   presence marks a new actor / source (new-entity signals)
        # prior_window:     look-back the new entity must have been absent across (default 1d)
        # facet_n:          rows per facet table (default 10)
        def self.build(id:, datasource:, logs_datasource:, stream:, name: nil,
                       auth_metric: 'auth_attempts_total', result_label: 'result',
                       failure_results: %w[denied failure error],
                       actor_label: 'actor', source_label: 'source_ip', geo_label: 'geo',
                       actor_presence_metric: nil, source_presence_metric: nil,
                       prior_window: '1d', facet_n: 10)
          validate!(id: id, datasource: datasource, logs_datasource: logs_datasource, stream: stream)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · access anomaly")
          b.tags('pleme-io', 'access-anomaly', 'security')

          # 1. Anomaly wall — new actor / new source-IP defects.
          signals = new_entity_signals(actor_presence_metric, source_presence_metric,
                                        auth_metric, actor_label, source_label, prior_window)
          b.row('Status — anomalies (who just appeared?)') do
            Library::StatusOverview.add(self, datasource: datasource, signals: signals)
          end

          # 2. Failed auth — the RED triple (rate · ratio · distinct actors).
          b.row('Failed auth') do
            Library::FailedAuthRow.add(self, datasource: datasource, auth_metric: auth_metric,
                                       result_label: result_label, failure_results: failure_results,
                                       actor_label: actor_label,
                                       logs_datasource: logs_datasource, stream: stream,
                                       result_field: result_label)
          end

          # 3. Off-hours — access bucketed by time-of-day.
          b.row('When — off-hours access') do
            Library::TimeOfDayHeatmap.add(self, datasource: logs_datasource, stream: stream)
          end

          # 4. Geo / source facets — the busiest sources + geos.
          b.row("Top #{source_label}") do
            Library::LogFacetTopN.add(self, datasource: logs_datasource, stream: stream,
                                      field: source_label, n: facet_n)
          end
          b.row("Top #{geo_label}") do
            Library::LogFacetTopN.add(self, datasource: logs_datasource, stream: stream,
                                      field: geo_label, n: facet_n)
          end

          # 5. Brute force — top actors among FAILED events (the offender table).
          fail_filter = "#{result_label}:(#{Array(failure_results).map { |r| %("#{r}") }.join(' OR ')})"
          b.row('Brute-force — top failing actors') do
            Library::LogFacetTopN.add(self, datasource: logs_datasource, stream: stream,
                                      field: actor_label, n: facet_n, filter: fail_filter,
                                      title: 'Top failing actors (brute-force)')
          end

          b.build
        end

        # Build the new-entity defect signals from whichever presence metrics are
        # given; fall back to the auth metric (its per-actor/source series mark
        # the entity as seen) so the wall is never empty.
        def self.new_entity_signals(actor_presence, source_presence, auth_metric,
                                    actor_label, source_label, prior_window)
          actor_m  = actor_presence || auth_metric
          source_m = source_presence || auth_metric
          [
            Library::NewEntityWindowSignal.signal(
              presence_metric: actor_m, identity_labels: [actor_label],
              prior_window: prior_window, name: "New actors (vs #{prior_window} ago)"),
            Library::NewEntityWindowSignal.signal(
              presence_metric: source_m, identity_labels: [source_label],
              prior_window: prior_window, name: "New sources (vs #{prior_window} ago)")
          ]
        end

        def self.validate!(id:, datasource:, logs_datasource:, stream:)
          raise ArgumentError, 'AccessAnomalyBoard: id: required' if blank?(id)
          raise ArgumentError, 'AccessAnomalyBoard: datasource: required' if blank?(datasource)
          raise ArgumentError, 'AccessAnomalyBoard: logs_datasource: required' if blank?(logs_datasource)
          raise ArgumentError, 'AccessAnomalyBoard: stream: required' if blank?(stream)
          unless stream.to_s.include?('{')
            raise ArgumentError,
                  'AccessAnomalyBoard: stream must be a LogsQL stream selector like ' \
                  "{stream=\"access\"}, got: #{stream.inspect}"
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :new_entity_signals, :validate!, :blank?
      end
    end
  end
end
