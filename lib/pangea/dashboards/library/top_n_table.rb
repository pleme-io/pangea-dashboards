# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The worst-offenders table, as a reusable atom. An instant `:table` over
      # `topk(N, agg by(labels)(<fn>(metric[window])))` — the triage panel that
      # answers "what is failing the MOST this window?" Hand-written in
      # kubernetes_cluster (top restarting pods), breathe (bands furthest from
      # setpoint), and the akeyless "Top Failing Jobs / Jobs by Repository"
      # dashboards. Generalises to per-tenant worst-offender ranking.
      #
      #   row 'Offenders' do
      #     Pangea::Dashboards::Library::TopNTable.add(
      #       self, datasource: 'vm', metric: 'kube_pod_container_status_restarts_total',
      #       agg: :increase, group_by: %w[namespace pod], n: 10, window: '1h')
      #   end
      module TopNTable
        AGGS = { increase: 'increase', rate: 'rate', sum: nil }.freeze

        # metric:          (req) the source metric
        # group_by:        (req) labels to aggregate + rank by
        # agg:             :increase (default) | :rate | :sum (no range fn)
        # n:               top-N (default 10)
        # window:          range window for increase/rate (default 1h)
        # selector:        typed Hash/String matcher
        # failure_results: convenience — a result=~"a|b" selector merged in
        #                  (e.g. %w[failed error] → result=~"failed|error")
        # title:           panel title
        def self.add(row, datasource:, metric:, group_by:, agg: :increase, n: 10,
                     window: '1h', selector: nil, failure_results: nil, legend_labels: nil, title: nil)
          validate!(datasource: datasource, metric: metric, group_by: group_by, agg: agg, n: n)
          sel = merge_failure_results(selector, failure_results)
          inner = case agg
                  when :sum then "sum#{Promql.by(group_by)}(#{metric}#{Promql.braces(sel)})"
                  else "sum#{Promql.by(group_by)}(#{AGGS.fetch(agg)}(#{metric}#{Promql.braces(sel)}[#{window}]))"
                  end
          expr = "topk(#{n}, #{inner})"
          pid  = :"top#{n}_#{slug(metric)}"
          ttl  = title || "Top #{n} · #{metric.to_s.tr('_', ' ')}"
          row.panel pid, kind: :table, width: Theme.full, height: Theme::TABLE_H do
            title ttl
            query 'A', expr, datasource: datasource, instant: true, presence: :continuous
          end
        end

        def self.merge_failure_results(selector, failure_results)
          return selector unless failure_results
          fr = { result: Array(failure_results) }
          case selector
          when nil then fr
          when ::Hash then selector.merge(fr)
          when ::String then "#{selector},result=~\"#{Array(failure_results).join('|')}\""
          else selector
          end
        end

        def self.validate!(datasource:, metric:, group_by:, agg:, n:)
          raise ArgumentError, 'TopNTable: datasource: required' if blank?(datasource)
          raise ArgumentError, 'TopNTable: metric: required' if blank?(metric)
          raise ArgumentError, 'TopNTable: group_by must be a non-empty Array' \
            unless group_by.is_a?(Array) && !group_by.empty?
          raise ArgumentError, "TopNTable: agg must be one of #{AGGS.keys} (got #{agg.inspect})" \
            unless AGGS.key?(agg)
          raise ArgumentError, "TopNTable: n must be a positive Integer (got #{n.inspect})" \
            unless n.is_a?(Integer) && n.positive?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :merge_failure_results, :validate!, :blank?, :slug
      end
    end
  end
end
