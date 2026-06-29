# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/rate_with_zero_floor'

module Pangea
  module Dashboards
    module Library
      # The BROKER STREAM row — the four questions an operator asks of any
      # message broker carrying the nervous system's traffic, on one canvas:
      #
      #   1. **How deep is the queue?**       — pending/backlog gauge (continuous)
      #   2. **How far behind are consumers?** — age-of-oldest / unacked lag (continuous)
      #   3. **Are messages flowing cleanly?** — ack/s vs redeliver/s (floored rates)
      #   4. **Are we dropping anything?**     — dropped/s (floored rate, the defect)
      #
      # Generic over NATS JetStream / Kafka / Redis Streams / SQS by METRIC
      # INJECTION — the operator passes each system's metric names; the row owns
      # the typed PromQL, the floor discipline, and the layout. Examples:
      #   • JetStream  depth = nats_consumer_num_pending, lag = …_ack_floor_age_seconds,
      #                ack = …_delivered_total, redeliver = …_redelivered_total
      #   • Kafka      depth = kafka_consumergroup_lag, lag = kafka_…_lag_seconds
      #   • SQS        depth = ApproximateNumberOfMessages, lag = ApproximateAgeOfOldestMessage
      #
      # ── Why depth + lag are :continuous (never floored) ───────────────────
      # Queue depth and consumer-lag-age are GAUGES that exist whenever the
      # broker is scraped — a genuine 0 depth (drained queue) is the healthy
      # reading, and a vanished broker SHOULD read "No data", not a floored 0.
      # The flow rates (ack/redeliver/dropped) ARE event-driven counters, so they
      # ARE floored: a quiet broker reads true 0s, never ambiguous no-data.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Broker' do
      #     Pangea::Dashboards::Library::BrokerStreamRow.add(
      #       self, datasource: 'vm',
      #       depth_metric: 'nats_consumer_num_pending',
      #       lag_metric: 'nats_consumer_ack_floor_age_seconds',
      #       ack_counter: 'nats_consumer_delivered_total',
      #       redeliver_counter: 'nats_consumer_num_redelivered_total',
      #       dropped_counter: 'nats_consumer_num_terminated_total',
      #       group_by: %w[stream consumer])
      #   end
      module BrokerStreamRow
        # datasource:        (req) the metrics datasource uid
        # depth_metric:      (req) queue depth / backlog gauge (pending messages)
        # lag_metric:        consumer lag gauge (age-of-oldest/unacked seconds) —
        #                    omit to skip the lag panel
        # ack_counter:       *_total of acked/delivered messages — the ack rate
        # redeliver_counter: *_total of redelivered messages — the redeliver rate
        # dropped_counter:   *_total of dropped/terminated/dead-lettered messages
        # selector:          typed Hash/String matcher applied to every series
        # group_by:          labels to sum-by (default %w[stream]) — per-stream
        # window:            rate window (default 5m)
        def self.add(row, datasource:, depth_metric:, lag_metric: nil,
                     ack_counter: nil, redeliver_counter: nil, dropped_counter: nil,
                     selector: nil, group_by: %w[stream], window: '5m')
          validate!(datasource: datasource, depth_metric: depth_metric)
          braces = Promql.braces(selector)
          gb     = Promql.by(group_by)
          legend = default_legend(group_by)

          # 1. Queue depth — the backlog (continuous gauge, never floored).
          add_depth(row, datasource: datasource, depth_metric: depth_metric,
                    braces: braces, gb: gb, legend: legend)

          # 2. Consumer lag — age-of-oldest / unacked (continuous gauge), optional.
          add_lag(row, datasource: datasource, lag_metric: lag_metric,
                  braces: braces, gb: gb, legend: legend) if lag_metric

          # 3. Ack vs redeliver — the clean-flow vs retry signal (floored rates).
          add_ack_redeliver(row, datasource: datasource, ack_counter: ack_counter,
                            redeliver_counter: redeliver_counter, selector: selector,
                            group_by: group_by, window: window) if ack_counter || redeliver_counter

          # 4. Dropped — the defect leg (floored rate), optional.
          RateWithZeroFloor.add(row, datasource: datasource, counter_metric: dropped_counter,
                                selector: selector, group_by: group_by, window: window,
                                unit: 'cps', width: Theme.half, title: 'dropped/s',
                                id: :"broker_dropped_#{slug(dropped_counter)}") if dropped_counter
        end

        # Queue depth — a continuous backlog timeseries (a drained queue is a
        # real, healthy 0; an absent broker is rightly "No data").
        def self.add_depth(row, datasource:, depth_metric:, braces:, gb:, legend:)
          expr = "sum#{gb}(#{depth_metric}#{braces})"
          row.panel :broker_depth, kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title 'queue depth (pending)'
            unit 'short'
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: :continuous, legend: legend
          end
        end

        # Consumer lag — age-of-oldest / unacked seconds (continuous gauge).
        def self.add_lag(row, datasource:, lag_metric:, braces:, gb:, legend:)
          expr = "max#{gb}(#{lag_metric}#{braces})"
          row.panel :broker_lag, kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title 'consumer lag (age of oldest)'
            unit 's'
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: :continuous, legend: legend
          end
        end

        # Ack vs redeliver — two floored event-driven rates on one timeseries: a
        # healthy broker acks steadily and rarely redelivers; a climbing
        # redeliver rate is consumers failing to process (poison messages).
        def self.add_ack_redeliver(row, datasource:, ack_counter:, redeliver_counter:, selector:, group_by:, window:)
          ack_expr = ack_counter ? Floor.zero(Promql.sum_rate(metric: ack_counter, window: window,
                                                              group_by: group_by, selector: selector)) : nil
          red_expr = redeliver_counter ? Floor.zero(Promql.sum_rate(metric: redeliver_counter, window: window,
                                                                    group_by: group_by, selector: selector)) : nil
          leg = default_legend(group_by)
          row.panel :broker_ack_redeliver, kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title 'ack/s vs redeliver/s'
            unit 'cps'
            min 0
            graph :area
            query 'A', ack_expr, datasource: datasource, presence: :event_driven, legend: "ack #{leg}" if ack_expr
            query 'B', red_expr, datasource: datasource, presence: :event_driven, legend: "redeliver #{leg}" if red_expr
          end
        end

        def self.default_legend(group_by)
          gb = Array(group_by).compact.map(&:to_s).reject(&:empty?)
          gb.empty? ? nil : gb.map { |l| "{{#{l}}}" }.join('/')
        end

        def self.validate!(datasource:, depth_metric:)
          raise ArgumentError, 'BrokerStreamRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'BrokerStreamRow: depth_metric: required' if blank?(depth_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_depth, :add_lag, :add_ack_redeliver, :default_legend, :validate!, :blank?, :slug
      end
    end
  end
end
