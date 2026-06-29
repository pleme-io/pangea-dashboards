# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/success_fail_ratio_gauge'

module Pangea
  module Dashboards
    module Library
      # The FAILED-AUTH row — the access-anomaly board's golden-signal triple for
      # authentication failures, all off one audit stream:
      #
      #   1. Failed-auth RATE timeseries — error-class auth lines per second over
      #      time (a denial spike is a rising line). Floored to 0 (event_driven).
      #   2. SuccessFailRatioGauge — failed / (success + failed), the share that
      #      failed (composes the shipped gauge block).
      #   3. Distinct-failing-actors `:stat` — how many UNIQUE identities failed
      #      this window (one actor retrying ≠ a credential-stuffing fan-out).
      #
      # Together: "how fast are failures, what share are they, and is it one
      # actor or many?" — the brute-force / credential-stuffing read.
      #
      # ── Why a count of failure-rate lines, floored ──────────────────────────
      # The rate panel counts error-class auth events over a sliding window; an
      # event-driven counter has no series until the first failure, so a healthy
      # quiet window would read "No data" — Floor.zero makes it a true, lit 0.
      #
      # ── Why distinct-actors is a uniq count ─────────────────────────────────
      # The fan-out width (how many distinct identities are failing) separates a
      # single fat-fingered user from a distributed attack, so it reads
      # `count(count by (actor)(...))` — distinct failing actors, the canonical
      # PromQL distinct-count.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Failed auth' do
      #     Pangea::Dashboards::Library::FailedAuthRow.add(
      #       self, datasource: 'metrics', stream: '{stream="audit"}', logs_datasource: 'logs',
      #       auth_metric: 'auth_attempts_total', actor_label: 'actor',
      #       result_label: 'result', failure_results: %w[denied failure])
      #   end
      module FailedAuthRow
        DEFAULT_FAILURE_RESULTS = %w[denied failure error].freeze

        # datasource:       (req) the METRICS datasource (rate + distinct-actors)
        # auth_metric:      (req) the auth-attempt *_total counter carrying a result label
        # result_label:     the outcome label (default 'result')
        # failure_results:  result values that count as a failure
        # actor_label:      the identity label for the distinct-actors count (default 'actor')
        # selector:         typed Hash/String scoping the population
        # window:           rate/lookback window (default 5m)
        # logs_datasource + stream + result_field + success_values/failed_values:
        #                   feed the SuccessFailRatioGauge (LogsQL mode) when given;
        #                   omit ⇒ the gauge reads a metric pair off auth_metric.
        def self.add(row, datasource:, auth_metric:, result_label: 'result',
                     failure_results: DEFAULT_FAILURE_RESULTS, actor_label: 'actor',
                     selector: nil, window: '5m',
                     logs_datasource: nil, stream: nil, result_field: 'result',
                     success_values: nil, failed_values: nil)
          validate!(datasource: datasource, auth_metric: auth_metric,
                    result_label: result_label, actor_label: actor_label)
          fail_sel  = merge_result(selector, result_label, failure_results)
          rate_expr = Floor.zero(Promql.sum_rate(metric: auth_metric, window: window, selector: fail_sel))
          # distinct failing actors: count of the per-actor failure series.
          distinct  = "count(count#{Promql.by([actor_label])}(rate(#{auth_metric}#{Promql.braces(fail_sel)}[#{window}])))"
          distinct_expr = Floor.zero(distinct)

          # 1. failed-auth rate over time.
          row.panel :failed_auth_rate, kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title "Failed-auth rate (#{window})"
            unit 'reqps'
            min 0
            graph :area
            description 'Error-class authentication attempts per second. A rising line is a denial spike.'
            query 'A', rate_expr, datasource: datasource, presence: :event_driven, legend: 'failed/s'
          end

          # 2. the failure-ratio gauge (composes the shipped block).
          gauge_ds = logs_datasource || datasource
          if logs_datasource && stream
            opts = {}
            opts[:success_values] = success_values if success_values
            opts[:failed_values]  = failed_values if failed_values
            SuccessFailRatioGauge.add(row, datasource: gauge_ds, stream: stream,
                                      result_field: result_field, width: Theme.third,
                                      id: :failed_auth_ratio, title: 'Auth failure ratio', **opts)
          else
            total_expr = "sum(rate(#{auth_metric}#{Promql.braces(selector)}[#{window}]))"
            fail_expr  = "sum(rate(#{auth_metric}#{Promql.braces(fail_sel)}[#{window}]))"
            SuccessFailRatioGauge.add(row, datasource: datasource,
                                      success_metric: "#{total_expr} - #{fail_expr}",
                                      failed_metric: fail_expr, width: Theme.third,
                                      id: :failed_auth_ratio, title: 'Auth failure ratio')
          end

          # 3. distinct failing actors — fan-out width.
          row.panel :failed_auth_distinct_actors, kind: :stat, width: Theme.third, height: Theme::STAT_H do
            title 'Distinct failing actors'
            unit 'short'
            description 'Unique identities failing auth this window. Many distinct ' \
                        'actors ⇒ a fan-out (credential stuffing), not one user.'
            display :background
            graph :area
            query 'A', distinct_expr, datasource: datasource, presence: :event_driven
            threshold steps: Theme.defect_steps(warn: 1, crit: 5)
          end
        end

        # Merge the population selector with the failure-result matcher into ONE
        # typed selector (Hash → merge; String → append) so it is never hand-concatenated.
        def self.merge_result(selector, result_label, failure_results)
          fr = { result_label.to_sym => Array(failure_results) }
          case selector
          when nil then fr
          when ::Hash then selector.merge(fr)
          when ::String
            body = Promql.selector_body(fr)
            selector.empty? ? body : "#{selector},#{body}"
          else fr
          end
        end

        def self.validate!(datasource:, auth_metric:, result_label:, actor_label:)
          raise ArgumentError, 'FailedAuthRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'FailedAuthRow: auth_metric: required' if blank?(auth_metric)
          raise ArgumentError, 'FailedAuthRow: result_label: required' if blank?(result_label)
          raise ArgumentError, 'FailedAuthRow: actor_label: required' if blank?(actor_label)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :merge_result, :validate!, :blank?
      end
    end
  end
end
