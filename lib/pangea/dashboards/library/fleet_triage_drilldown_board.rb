# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/fleet_drilldown_variables'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/worst_n_focus_row'
require 'pangea/dashboards/library/golden_signals_row'
require 'pangea/dashboards/library/log_windows'

module Pangea
  module Dashboards
    module Library
      # THE DRILL-DOWN TRUNK — one board that re-scopes from the whole fleet down
      # to a single workload by changing template variables. The cascading
      # `$cloud → $region → $tenant → $cell` variables (FleetDrilldownVariables)
      # scope every row: the defects headline, the worst-N within the current
      # scope, the golden signals of the scoped slice, and the scoped logs. Fleet
      # to workload in one pane — the trunk the per-cell/per-workload leaf boards
      # branch off.
      #
      # The triage STORY, top-to-bottom:
      #
      #   $cloud→$region→$tenant→$cell cascade (template vars scope everything)
      #   Scoped defects   →  "is anything wrong in the current scope?"
      #   Worst-N          →  the worst members within the scope
      #   Golden signals   →  the scoped slice's RED
      #   Logs             →  the scoped slice's log windows
      #
      #   dash = Pangea::Dashboards::Library::FleetTriageDrilldownBoard.build(
      #     id: :fleet_triage, name: 'Fleet Triage', datasource: 'vm', logs_datasource: 'vlogs',
      #     levels: %w[cloud region tenant cell],
      #     rate_metric: 'http_requests_total',
      #     latency_metric: 'http_request_duration_seconds_bucket',
      #     stream: '{namespace=~"$tenant"}')
      module FleetTriageDrilldownBoard
        # id/name:         dashboard id + human title
        # datasource:      (req) the metrics datasource uid
        # rate_metric:     (req) the request *_total counter (golden + worst-N)
        # latency_metric:  (req) the *_seconds_bucket histogram (golden)
        # levels:          drill levels outermost→innermost (default cloud/region/tenant/cell)
        # scope_metric:    metric to anchor the cascade label_values (default 'up')
        # error_code_regex: error subset for golden errors (default '5..')
        # window:          golden window (default 5m)
        # worst_n:         worst-N within scope (default 5)
        # logs_datasource + stream: optional scoped log windows
        def self.build(id:, datasource:, rate_metric:, latency_metric:, name: nil,
                       levels: %w[cloud region tenant cell], scope_metric: 'up',
                       error_code_regex: '5..', window: '5m', worst_n: 5,
                       logs_datasource: nil, stream: nil)
          validate!(id: id, datasource: datasource, rate_metric: rate_metric,
                    latency_metric: latency_metric, levels: levels)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · fleet triage")
          b.tags('pleme-io', 'fleet-triage')

          # The $cloud→$region→$tenant→$cell cascade (scopes every row below).
          Library::FleetDrilldownVariables.declare(b, datasource: datasource,
                                                    levels: levels, scope_metric: scope_metric)

          # The selector that applies the current scope to every metric query.
          ls = Array(levels).map(&:to_s)
          innermost = ls.last
          scope_body = ls.map { |l| %(#{l}=~"$#{l}") }.join(',')
          scoped_total = "sum(rate(#{rate_metric}{#{scope_body}}[#{window}]))"

          # 1. Scoped defects headline.
          scoped_errors = {
            name: 'Errors /s (in scope)',
            expr: "sum(rate(#{rate_metric}{#{scope_body},code=~\"#{error_code_regex}\"}[#{window}]))",
            warn: 0.1, crit: 1,
            desc: 'Error rate within the current $cloud/$region/$tenant/$cell scope.'
          }
          b.row('Status — in scope') do
            Library::StatusOverview.add(self, datasource: datasource, signals: [scoped_errors])
          end

          # 2. Worst-N within the scope (by innermost level).
          focus = "sum#{Promql.by(innermost)}(rate(#{rate_metric}{#{scope_body},code=~\"#{error_code_regex}\"}[#{window}]))"
          b.row("Worst #{innermost} in scope") do
            Library::WorstNFocusRow.add(self, datasource: datasource, topology_label: innermost,
                                        rank_metric: rate_metric, rank_agg: :rate,
                                        focus_expr: focus, focus_unit: 'reqps', n: worst_n,
                                        focus_title: "Worst #{innermost} · error rate")
          end

          # 3. Golden signals of the scoped slice.
          b.row('Golden signals — scoped') do
            Library::GoldenSignalsRow.add(self, datasource: datasource, rate_metric: rate_metric,
                                          latency_metric: latency_metric, group_by: [innermost],
                                          error_selector: { code: error_code_regex }, window: window)
          end

          # 4. Scoped logs (optional).
          if stream && logs_datasource
            b.row('Logs — scoped') do
              Library::LogWindows.add_all(self, name: (name || id).to_s, stream: stream, datasource: logs_datasource)
            end
          end

          b.build
        end

        def self.validate!(id:, datasource:, rate_metric:, latency_metric:, levels:)
          raise ArgumentError, 'FleetTriageDrilldownBoard: id: required' if blank?(id)
          raise ArgumentError, 'FleetTriageDrilldownBoard: datasource: required' if blank?(datasource)
          raise ArgumentError, 'FleetTriageDrilldownBoard: rate_metric: required' if blank?(rate_metric)
          raise ArgumentError, 'FleetTriageDrilldownBoard: latency_metric: required' if blank?(latency_metric)
          raise ArgumentError, 'FleetTriageDrilldownBoard: levels must be a non-empty Array' \
            unless levels.is_a?(::Array) && !levels.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
