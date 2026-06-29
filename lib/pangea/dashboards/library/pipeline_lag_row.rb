# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The PIPELINE LAG row — the latency-and-conservation companion to
      # BrokerStreamRow's depth/throughput, answering the two timing questions an
      # operator asks of an N-hop data pipeline:
      #
      #   1. **Per-hop lag** — one line per hop's processing lag (seconds),
      #      from a single lag gauge summed `by(<hop label>)`. A hop whose line
      #      climbs is the slow stage.
      #   2. **End-to-end wall-clock lag** — ONE line: `time() - max(tap_timestamp)`
      #      (how stale is the freshest event the store has landed?). This is the
      #      number the SLA cares about — the whole pipeline's freshness, not a
      #      per-hop slice.
      #   3. **Ingest vs egress conservation** — total received/s vs total sent/s
      #      overlaid (floored); a persistent gap is the pipeline NOT conserving
      #      (backing up or dropping), the time-series twin of PipelineFlowStrip's
      #      per-hop conservation tiles.
      #
      # ── Why end-to-end lag is `time() - max(landing_timestamp)` ───────────
      # A landing-timestamp gauge (unix seconds of the freshest event the store
      # has) turned into "seconds behind now" by subtracting from `time()` is the
      # canonical freshness read — independent of any per-hop instrumentation,
      # it directly answers "how old is the newest data I can query?".
      #
      # ── Why the lag legs are :continuous ──────────────────────────────────
      # Lag gauges (per-hop seconds, landing timestamp) exist while the pipeline
      # runs; a genuine 0 lag is the healthy reading and an absent gauge should
      # read "No data". The ingest/egress rates ARE event-driven counters, so
      # those two legs ARE floored.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Lag' do
      #     Pangea::Dashboards::Library::PipelineLagRow.add(
      #       self, datasource: 'vm',
      #       hop_lag_metric: 'pipeline_hop_lag_seconds', hop_label: 'stage',
      #       landing_timestamp_metric: 'store_last_event_timestamp_seconds',
      #       in_counter: 'tap_received_total', out_counter: 'store_written_total')
      #   end
      module PipelineLagRow
        # datasource:               (req) the metrics datasource uid
        # hop_lag_metric:           (req) per-hop lag gauge (seconds)
        # hop_label:                label to break per-hop lag out by (default 'stage')
        # landing_timestamp_metric: store's freshest-event unix-timestamp gauge —
        #                           drives the end-to-end wall-clock lag (omit to skip)
        # in_counter / out_counter: pipeline-entry / pipeline-exit *_total counters
        #                           for the ingest-vs-egress conservation timeseries
        #                           (both needed; omit either to skip)
        # selector:                 typed Hash/String matcher applied to every series
        # window:                   rate window for the conservation legs (default 5m)
        def self.add(row, datasource:, hop_lag_metric:, hop_label: 'stage',
                     landing_timestamp_metric: nil, in_counter: nil, out_counter: nil,
                     selector: nil, window: '5m')
          validate!(datasource: datasource, hop_lag_metric: hop_lag_metric)
          braces = Promql.braces(selector)

          # 1. Per-hop lag — one line per hop.
          add_hop_lag(row, datasource: datasource, hop_lag_metric: hop_lag_metric,
                      hop_label: hop_label, braces: braces)

          # 2. End-to-end wall-clock lag — one freshness line (optional).
          add_end_to_end(row, datasource: datasource,
                         landing_timestamp_metric: landing_timestamp_metric,
                         braces: braces) if landing_timestamp_metric

          # 3. Ingest vs egress conservation — two floored rates (optional).
          add_conservation(row, datasource: datasource, in_counter: in_counter,
                           out_counter: out_counter, selector: selector,
                           window: window) if in_counter && out_counter
        end

        # Per-hop processing lag — `max by(hop)(lag_gauge)`, continuous.
        def self.add_hop_lag(row, datasource:, hop_lag_metric:, hop_label:, braces:)
          gb   = Promql.by([hop_label])
          expr = "max#{gb}(#{hop_lag_metric}#{braces})"
          row.panel :pipeline_hop_lag, kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title 'per-hop lag'
            unit 's'
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: :continuous, legend: "{{#{hop_label}}}"
          end
        end

        # End-to-end wall-clock lag — `time() - max(landing_timestamp)`: how
        # stale is the freshest event the store has landed (the SLA freshness).
        def self.add_end_to_end(row, datasource:, landing_timestamp_metric:, braces:)
          expr = "time() - max(#{landing_timestamp_metric}#{braces})"
          row.panel :pipeline_end_to_end_lag, kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title 'end-to-end lag (tap → store landing)'
            unit 's'
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: :continuous, legend: 'freshness'
          end
        end

        # Ingest vs egress — total received/s vs total sent/s; a persistent gap
        # is the pipeline failing to conserve (backing up or dropping).
        def self.add_conservation(row, datasource:, in_counter:, out_counter:, selector:, window:)
          in_expr  = Floor.zero(Promql.sum_rate(metric: in_counter, window: window, selector: selector))
          out_expr = Floor.zero(Promql.sum_rate(metric: out_counter, window: window, selector: selector))
          row.panel :pipeline_conservation, kind: :timeseries, width: Theme.full, height: Theme::TS_H do
            title 'ingest vs egress (conservation)'
            unit 'cps'
            min 0
            graph :area
            query 'A', in_expr,  datasource: datasource, presence: :event_driven, legend: 'ingest/s'
            query 'B', out_expr, datasource: datasource, presence: :event_driven, legend: 'egress/s'
          end
        end

        def self.validate!(datasource:, hop_lag_metric:)
          raise ArgumentError, 'PipelineLagRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'PipelineLagRow: hop_lag_metric: required' if blank?(hop_lag_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :add_hop_lag, :add_end_to_end, :add_conservation, :validate!, :blank?
      end
    end
  end
end
