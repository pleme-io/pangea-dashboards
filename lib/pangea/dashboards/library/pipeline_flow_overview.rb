# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/pipeline_flow_strip'
require 'pangea/dashboards/library/broker_stream_row'
require 'pangea/dashboards/library/pipeline_lag_row'
require 'pangea/dashboards/library/red_component_throughput_row'
require 'pangea/dashboards/library/autoscaler_pool_strip'

module Pangea
  module Dashboards
    module Library
      # The one-call operator dashboard for the TAP NERVOUS SYSTEM end-to-end —
      # the N-stage data pipeline (tap → broker → consumer → store) read as one
      # flow. It is the meta-observability board: the observability plane pointed
      # at its OWN ingest path, so a silent gap in the pipeline is itself a
      # visible defect.
      #
      # The triage STORY, top-to-bottom (Theme: flow headline → broker → per-stage
      # throughput → consumer autoscale → lag):
      #
      #   Flow headline   →  "is every hop conserving, or is one leaking?" (the strip)
      #   Broker          →  depth · consumer-lag · ack-vs-redeliver · dropped
      #   Per-stage RED   →  received/s vs sent/s per stage (is what comes in coming out?)
      #   Consumer scale  →  the 0→N KEDA/autoscaler pool feeding the consumer stage
      #   Lag             →  per-hop lag + end-to-end freshness + ingest/egress
      #
      # Flow-first means the operator lands on "where is the leak?" before any
      # per-stage chart. Everything below is reuse — the only board-specific
      # composition is which shipped/new block renders each stage.
      #
      #   dash = Pangea::Dashboards::Library::PipelineFlowOverview.build(
      #     id: :tap_pipeline, name: 'Tap Pipeline', datasource: 'metrics',
      #     stages: [
      #       { name: 'tap',      in_counter: 'tap_received_total',      out_counter: 'tap_sent_total' },
      #       { name: 'broker',   in_counter: 'broker_received_total',   out_counter: 'broker_sent_total' },
      #       { name: 'consumer', in_counter: 'consumer_received_total', out_counter: 'consumer_sent_total' },
      #       { name: 'store',    in_counter: 'store_received_total',    out_counter: 'store_written_total' },
      #     ],
      #     broker: { depth: 'broker_pending', lag: 'broker_consumer_lag_seconds' })
      module PipelineFlowOverview
        # id/name:    dashboard id + human title
        # datasource: (req) the metrics datasource uid
        # stages:     (req) ordered Array of stage Hashes (name/in_counter/out_counter)
        #             — drives the flow strip AND the per-stage throughput rows
        # broker:     optional Hash of broker metric names (depth/lag/ack/redeliver/
        #             dropped/group_by) → a BrokerStreamRow
        # consumer_scale: optional Hash for the consumer autoscaler pool strip
        #             (pool_roles/max_metric/current_metric/error_metric/selector)
        # lag:        optional Hash (hop_lag_metric/hop_label/landing_timestamp_metric)
        #             → a PipelineLagRow; in/out counters default to the first/last stage
        # window:     fleet-wide rate window (default 5m)
        # leak_ok:    conservation ratio the flow strip treats as healthy (default 0.95)
        def self.build(id:, datasource:, stages:, name: nil, broker: nil,
                       consumer_scale: nil, lag: nil, window: '5m', leak_ok: 0.95)
          validate!(id: id, datasource: datasource, stages: stages)
          stage_list = stages.map { |s| s.transform_keys(&:to_sym) }
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · pipeline flow")
          b.tags('pleme-io', 'pipeline', 'nervous-system')

          # 1. Flow headline — the conservation strip, one tile per stage in order.
          b.row('Flow — is every hop conserving?') do
            Library::PipelineFlowStrip.add(self, datasource: datasource, stages: stage_list,
                                           window: window, leak_ok: leak_ok)
          end

          # 2. Broker — depth · lag · ack-vs-redeliver · dropped (optional).
          if broker && !broker.empty?
            bk = broker.transform_keys(&:to_sym)
            b.row('Broker — depth · lag · ack/redeliver · dropped') do
              Library::BrokerStreamRow.add(self, datasource: datasource,
                                           depth_metric: bk[:depth], lag_metric: bk[:lag],
                                           ack_counter: bk[:ack], redeliver_counter: bk[:redeliver],
                                           dropped_counter: bk[:dropped], selector: bk[:selector],
                                           group_by: bk[:group_by] || %w[stream], window: window)
            end
          end

          # 3. Per-stage throughput — received/s vs sent/s for each stage.
          stage_list.each do |stage|
            sname = stage.fetch(:name).to_s
            b.row("#{sname} — received/s vs sent/s") do
              Library::RedComponentThroughputRow.add(self, datasource: datasource,
                                                     in_counter: stage.fetch(:in_counter),
                                                     out_counter: stage.fetch(:out_counter),
                                                     component_label: stage[:component_label],
                                                     window: window, title: sname)
            end
          end

          # 4. Consumer autoscale — the 0→N pool feeding the consumer stage (optional).
          if consumer_scale && !consumer_scale.empty?
            cs = consumer_scale.transform_keys(&:to_sym)
            b.row('Consumer autoscale — 0 → N') do
              Library::AutoscalerPoolStrip.add(self, datasource: datasource,
                                               pool_roles: cs.fetch(:pool_roles),
                                               max_metric: cs[:max_metric], current_metric: cs[:current_metric],
                                               error_metric: cs[:error_metric], selector: cs[:selector])
            end
          end

          # 5. Lag — per-hop + end-to-end freshness + ingest/egress conservation (optional).
          if lag && !lag.empty?
            lg = lag.transform_keys(&:to_sym)
            in_counter  = lg[:in_counter] || stage_list.first&.fetch(:in_counter, nil)
            out_counter = lg[:out_counter] || stage_list.last&.fetch(:out_counter, nil)
            b.row('Lag — per-hop · end-to-end · conservation') do
              Library::PipelineLagRow.add(self, datasource: datasource,
                                          hop_lag_metric: lg.fetch(:hop_lag_metric),
                                          hop_label: lg[:hop_label] || 'stage',
                                          landing_timestamp_metric: lg[:landing_timestamp_metric],
                                          in_counter: in_counter, out_counter: out_counter,
                                          selector: lg[:selector], window: window)
            end
          end

          b.build
        end

        def self.validate!(id:, datasource:, stages:)
          raise ArgumentError, 'PipelineFlowOverview: id: required' if blank?(id)
          raise ArgumentError, 'PipelineFlowOverview: datasource: required' if blank?(datasource)
          raise ArgumentError, 'PipelineFlowOverview: stages must be a non-empty Array' \
            unless stages.is_a?(::Array) && !stages.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
