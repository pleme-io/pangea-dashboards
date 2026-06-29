# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The datastore-shaped GOLDEN-SIGNALS row — the RED story (Rate · Errors ·
      # Duration) for a managed datastore, NOT a request-shaped service. It is
      # the sibling of GoldenSignalsRow for stores that expose query latency as
      # a GAUGE (a Performance-Insights / vendor-exporter `*_query_latency_seconds`
      # gauge) rather than a `*_seconds_bucket` histogram. One typed flag —
      # `latency_is_histogram` — switches the Duration panel between a direct
      # gauge timeseries and a `histogram_quantile(...)` over buckets, so the
      # SAME row serves a relational DB exposing a histogram and a cache exposing
      # a single mean-latency gauge.
      #
      # ── The four panels (left → right) ──────────────────────────────────
      # • QPS — `sum by(group)(rate(<qps_metric>[w]))`, floored (an idle store
      #   reads a true 0, never ambiguous "No data").
      # • Query latency — gauge mode: `<latency_metric>{sel}` directly; histogram
      #   mode: `histogram_quantile(q, …)` over `<latency_metric>` buckets.
      #   A latency LEVEL is continuous (never floored) — an absent store should
      #   read "No data", not a misleading 0.
      # • Slow queries /s — `rate(<slow_metric>[w])`, floored (event-driven —
      #   a healthy store has zero slow queries, which must read a lit 0).
      # • Errors /s — `rate(<error_metric>[w])`, floored (event-driven, same).
      #
      #   row 'Query' do
      #     Pangea::Dashboards::Library::DatastoreQueryRow.add(
      #       self, datasource: 'vm', selector: { db: '$db' },
      #       qps_metric: 'db_queries_total',
      #       latency_metric: 'db_query_latency_seconds', latency_is_histogram: false,
      #       slow_metric: 'db_slow_queries_total', error_metric: 'db_query_errors_total')
      #   end
      module DatastoreQueryRow
        # datasource:           (req) the metrics datasource uid
        # qps_metric:           (req) the queries *_total counter
        # latency_metric:       (req) the latency gauge OR *_bucket histogram
        # latency_is_histogram: false (default) → gauge timeseries;
        #                       true → histogram_quantile over the buckets
        # slow_metric:          optional slow-query *_total counter (floored)
        # error_metric:         optional query-error *_total counter (floored)
        # selector:             typed Hash/String matcher scoping the store
        # group_by:             labels to break QPS down by (default none)
        # quantiles:            histogram-mode quantiles (default p95/p99)
        # window:               rate/quantile window (default 5m)
        # latency_unit:         Grafana unit for the latency panel (default 's')
        # title_prefix:         optional per-panel title prefix
        def self.add(row, datasource:, qps_metric:, latency_metric:,
                     latency_is_histogram: false, slow_metric: nil, error_metric: nil,
                     selector: nil, group_by: [], quantiles: [0.95, 0.99],
                     window: '5m', latency_unit: 's', title_prefix: nil)
          validate!(datasource: datasource, qps_metric: qps_metric, latency_metric: latency_metric)
          tp = title_prefix ? "#{title_prefix} · " : ''
          # Count the panels up front so each gets a clean uniform width.
          legs = 2 + (slow_metric ? 1 : 0) + (error_metric ? 1 : 0)
          width = legs >= 4 ? Theme.tile_width(4) : (legs == 3 ? Theme.third : Theme.half)

          add_qps(row, datasource: datasource, qps_metric: qps_metric, selector: selector,
                  group_by: group_by, window: window, width: width, title: "#{tp}QPS")
          add_latency(row, datasource: datasource, latency_metric: latency_metric,
                      latency_is_histogram: latency_is_histogram, selector: selector,
                      group_by: group_by, quantiles: quantiles, window: window,
                      unit: latency_unit, width: width, title: "#{tp}Query latency")
          add_floored(row, datasource: datasource, metric: slow_metric, selector: selector,
                      group_by: group_by, window: window, width: width, unit: 'qps',
                      title: "#{tp}Slow queries", pid: :datastore_slow_queries) if slow_metric
          add_floored(row, datasource: datasource, metric: error_metric, selector: selector,
                      group_by: group_by, window: window, width: width, unit: 'qps',
                      title: "#{tp}Query errors", pid: :datastore_query_errors) if error_metric
        end

        # QPS — floored event-driven rate (an idle store reads a lit 0).
        def self.add_qps(row, datasource:, qps_metric:, selector:, group_by:, window:, width:, title:)
          expr = Floor.zero(Promql.sum_rate(metric: qps_metric, window: window,
                                            group_by: group_by, selector: selector))
          leg  = Array(group_by).empty? ? 'qps' : Array(group_by).map { |l| "{{#{l}}}" }.join('/')
          row.panel :datastore_qps, kind: :timeseries, width: width, height: Theme::TS_H do
            title title
            unit 'qps'
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: :event_driven, legend: leg
          end
        end

        # Query latency — the typed gauge-vs-histogram switch. A latency LEVEL
        # is continuous (never floored); an absent store should read "No data".
        def self.add_latency(row, datasource:, latency_metric:, latency_is_histogram:, selector:,
                             group_by:, quantiles:, window:, unit:, width:, title:)
          row.panel :datastore_query_latency, kind: :timeseries, width: width, height: Theme::TS_H do
            title title
            unit unit
            min 0
            graph :area
            if latency_is_histogram
              quantiles.each_with_index do |q, i|
                ref  = ('A'.ord + i).chr
                pq   = "p#{(q * 100).round}"
                expr = Promql.histogram_quantile(quantile: q, bucket_metric: latency_metric,
                                                 window: window, group_by: group_by, selector: selector)
                query ref, expr, datasource: datasource, presence: :continuous, legend: pq
              end
            else
              expr = "#{latency_metric}#{Promql.braces(selector)}"
              query 'A', expr, datasource: datasource, presence: :continuous, legend: 'latency'
            end
          end
        end

        # A floored event-driven rate panel (slow queries / errors) — a healthy
        # store has zero, which must read a lit 0 not "No data".
        def self.add_floored(row, datasource:, metric:, selector:, group_by:, window:, width:, unit:, title:, pid:)
          expr = Floor.zero(Promql.sum_rate(metric: metric, window: window,
                                            group_by: group_by, selector: selector))
          row.panel pid, kind: :timeseries, width: width, height: Theme::TS_H do
            title title
            unit unit
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: :event_driven, legend: title
          end
        end

        def self.validate!(datasource:, qps_metric:, latency_metric:)
          raise ArgumentError, 'DatastoreQueryRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'DatastoreQueryRow: qps_metric: required' if blank?(qps_metric)
          raise ArgumentError, 'DatastoreQueryRow: latency_metric: required' if blank?(latency_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :add_qps, :add_latency, :add_floored, :validate!, :blank?
      end
    end
  end
end
