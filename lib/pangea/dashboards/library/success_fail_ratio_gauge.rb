# frozen_string_literal: true

require 'pangea/dashboards/theme'

module Pangea
  module Dashboards
    module Library
      # The FAILURE-RATIO gauge — ONE `:gauge` (percentunit, 0–1) reading the
      # share of events that failed:
      #
      #   failed / (success + failed)
      #
      # coloured green→amber→red by Theme.defect_steps (higher = worse). It is
      # the headline atom of a failed-auth / access-anomaly board: a calm green
      # needle = a healthy success mix; the needle climbing into red = a denial
      # spike. The companion of RedSliGaugeStrip (errors/total over metrics) for
      # a success/fail outcome split.
      #
      # ── Two input shapes (one typed gauge) ──────────────────────────────────
      # • LogsQL split (default): a `stats by (result)` over an audit stream,
      #   from which the success + failed counts are filtered by result value.
      #   The gauge expr is built as a LogsQL pipe so the failure ratio rides the
      #   same audit stream the rest of the board reads.
      # • metric pair: pass `success_metric:` + `failed_metric:` (PromQL) and the
      #   gauge reads `failed / (success + failed)` over those instead — the same
      #   ratio for a /metrics-exposed success/fail counter pair.
      #
      # ── Why a ratio, not a raw count ────────────────────────────────────────
      # A failure RATIO means the same thing regardless of traffic volume — 50%
      # failures is alarming at any rate — so the gauge reads a unit-less 0–1
      # that an operator interprets without knowing the absolute throughput.
      #
      # ── Why continuous (no floor) ───────────────────────────────────────────
      # A ratio is defined only when the denominator is non-zero; an idle window
      # reads no-data, which is the honest answer for a divide-by-zero (NOT a
      # floored 0 that would paint a falsely-healthy green). So presence is
      # :continuous and the expr is never `or vector(0)`-floored.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Auth health' do
      #     Pangea::Dashboards::Library::SuccessFailRatioGauge.add(
      #       self, datasource: 'logs', stream: '{stream="audit"}',
      #       result_field: 'result', success_values: %w[success allowed],
      #       failed_values: %w[denied failure error])
      #   end
      module SuccessFailRatioGauge
        DEFAULT_SUCCESS = %w[success allowed ok].freeze
        DEFAULT_FAILED  = %w[denied failure error fail].freeze

        # datasource:      (req) metrics OR logs datasource uid (matches the input shape)
        # LogsQL split (default):
        #   stream:        the audit-log stream selector, e.g. '{stream="audit"}'
        #   result_field:  the outcome field (default 'result')
        #   success_values / failed_values: result values counted as each class
        # metric pair (override):
        #   success_metric / failed_metric: PromQL counts of each class
        # warn / crit:     failure-ratio thresholds (default 0.05 / 0.2)
        # title:           cosmetic override
        # width:           tile width (default Theme.third)
        # id:              panel id override
        def self.add(row, datasource:, stream: nil, result_field: 'result',
                     success_values: DEFAULT_SUCCESS, failed_values: DEFAULT_FAILED,
                     success_metric: nil, failed_metric: nil,
                     warn: 0.05, crit: 0.2, title: nil, width: nil, id: nil)
          validate!(datasource: datasource, stream: stream,
                    success_metric: success_metric, failed_metric: failed_metric,
                    result_field: result_field)
          expr  = if metric_mode?(success_metric, failed_metric)
                    metric_expr(success_metric, failed_metric)
                  else
                    logsql_expr(stream, result_field, success_values, failed_values)
                  end
          steps = Theme.defect_steps(warn: warn, crit: crit)
          pid   = id || :success_fail_ratio
          w     = width || Theme.third
          row.panel pid, kind: :gauge, width: w, height: Theme::STAT_H do
            title title || 'Failure ratio'
            unit 'percentunit'   # unit-less 0–1 → rendered as a %
            min 0
            max 1
            description 'failed / (success + failed). Green = healthy mix; ' \
                        'red = failures dominate. No-data on an idle window is honest.'
            graph :none
            # continuous: a ratio is defined only with traffic; no floor.
            query 'A', expr, datasource: datasource, presence: :continuous
            threshold steps: steps
          end
        end

        # PromQL: failed / (success + failed) over the metric pair.
        def self.metric_expr(success_metric, failed_metric)
          f = failed_metric.to_s
          s = success_metric.to_s
          "(#{f}) / ((#{s}) + (#{f}))"
        end

        # LogsQL: count failed-class events / count all (success ∪ failed) events,
        # both filtered by result value off the same stream.
        def self.logsql_expr(stream, result_field, success_values, failed_values)
          failed  = Array(failed_values).map(&:to_s).reject(&:empty?)
          success = Array(success_values).map(&:to_s).reject(&:empty?)
          all     = (success + failed).uniq
          num = "#{stream} #{result_clause(result_field, failed)} | stats count() failed"
          den = "#{stream} #{result_clause(result_field, all)} | stats count() total"
          "(#{num}) / (#{den})"
        end

        # `field:("a" OR "b")` — a LogsQL value-set filter on the result field.
        def self.result_clause(field, values)
          quoted = values.map { |v| %("#{v}") }.join(' OR ')
          "#{field}:(#{quoted})"
        end

        def self.metric_mode?(success_metric, failed_metric)
          !blank?(success_metric) && !blank?(failed_metric)
        end

        def self.validate!(datasource:, stream:, success_metric:, failed_metric:, result_field:)
          raise ArgumentError, 'SuccessFailRatioGauge: datasource: required' if blank?(datasource)
          if metric_mode?(success_metric, failed_metric)
            return
          end
          # one-sided metric input is an incomplete ratio — make it loud.
          if !blank?(success_metric) ^ !blank?(failed_metric)
            raise ArgumentError, 'SuccessFailRatioGauge: success_metric and failed_metric must be given together'
          end
          raise ArgumentError, 'SuccessFailRatioGauge: result_field: required (LogsQL mode)' if blank?(result_field)
          raise ArgumentError, 'SuccessFailRatioGauge: stream: required (LogsQL mode)' if blank?(stream)
          unless stream.to_s.include?('{')
            raise ArgumentError,
                  'SuccessFailRatioGauge: stream must be a LogsQL stream selector like ' \
                  "{stream=\"audit\"}, got: #{stream.inspect}"
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :metric_expr, :logsql_expr, :result_clause, :validate!, :blank?
      end
    end
  end
end
