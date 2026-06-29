# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'

module Pangea
  module Dashboards
    module Library
      # The AUDIT/SECURITY tap's OWN meta-health row — the nervous system pointed
      # at the security pipeline itself. A silent audit gap (the shipper wedged,
      # events dropped, ingestion stalled) is itself a security DEFECT: if the
      # audit stream stops, the boards above go blind and an attacker acts
      # unobserved. This row makes that gap visible:
      #
      #   1. Shipper QUEUE DEPTH / LAG — the audit shipper's backlog (a growing
      #      queue ⇒ ingestion can't keep up ⇒ events delayed). :continuous gauge.
      #   2. DROPPED-audit rate — audit events the pipeline DROPPED (the worst
      #      defect — a dropped audit line is a permanent blind spot). Floored.
      #   3. INGESTION rate — audit events accepted per second (the liveness pulse;
      #      a flat-zero ingestion on a live cluster is the pipeline gone dark).
      #
      # ── Generic by construction (reused by NervousSystemSelfHealthBoard) ────
      # Every metric is a PARAM — the security pipeline's exporter names are the
      # natural defaults, but the same `.add(row, datasource:, …)` shape reads any
      # tap pipeline's shipper/drop/ingest signals. The main thread's
      # NervousSystemSelfHealthBoard reuses this row for the audit subsystem's
      # self-health strip, so the API is kept generic (no security-only fields).
      #
      # ── Why floored drops + rate, continuous depth ──────────────────────────
      # Queue depth is a gauge always present while the shipper runs → :continuous.
      # Drops + ingestion are event-driven counters → floored to a lit 0 so a
      # healthy "0 dropped" reads green rather than ambiguous no-data.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Audit pipeline health' do
      #     Pangea::Dashboards::Library::SecurityEventPipelineHealthRow.add(
      #       self, datasource: 'metrics',
      #       queue_depth_metric: 'audit_shipper_queue_depth',
      #       dropped_metric: 'audit_events_dropped_total',
      #       ingest_metric: 'audit_events_ingested_total')
      #   end
      module SecurityEventPipelineHealthRow
        # datasource:          (req) the metrics datasource uid
        # queue_depth_metric:  the shipper backlog gauge (depth / lag)
        # dropped_metric:      the dropped-audit-events counter
        # ingest_metric:       the accepted-audit-events counter
        # selector:            typed Hash/String scoping the pipeline
        # group_by:            labels to break the series down by (default [] — fleet total)
        # window:              rate window (default 5m)
        # depth_unit:          unit for the queue-depth panel (default 'short')
        # drop_warn / drop_crit: dropped-rate thresholds (default 0.001 / 0.01)
        def self.add(row, datasource:, queue_depth_metric: 'audit_shipper_queue_depth',
                     dropped_metric: 'audit_events_dropped_total',
                     ingest_metric: 'audit_events_ingested_total',
                     selector: nil, group_by: [], window: '5m', depth_unit: 'short',
                     drop_warn: 0.001, drop_crit: 0.01)
          validate!(datasource: datasource, queue_depth_metric: queue_depth_metric,
                    dropped_metric: dropped_metric, ingest_metric: ingest_metric)
          braces = Promql.braces(selector)
          legend = group_by_legend(group_by)

          # 1. shipper queue depth / lag.
          depth_expr = "sum#{Promql.by(group_by)}(#{queue_depth_metric}#{braces})"
          row.panel :pipeline_queue_depth, kind: :timeseries, width: Theme.third, height: Theme::TS_H do
            title 'Shipper queue depth / lag'
            unit depth_unit
            min 0
            graph :area
            description 'Audit shipper backlog. A growing queue ⇒ ingestion is falling behind.'
            query 'A', depth_expr, datasource: datasource, presence: :continuous, legend: legend
          end

          # 2. dropped-audit rate (the worst defect — a permanent blind spot).
          dropped_expr = Floor.zero(Promql.sum_rate(metric: dropped_metric, window: window,
                                                     group_by: group_by, selector: selector))
          row.panel :pipeline_dropped_rate, kind: :timeseries, width: Theme.third, height: Theme::TS_H do
            title "Dropped audit events / s (#{window})"
            unit 'eps'
            min 0
            graph :area
            description 'Audit events the pipeline DROPPED — a dropped line is a permanent ' \
                        'blind spot. Any non-zero is a defect.'
            query 'A', dropped_expr, datasource: datasource, presence: :event_driven, legend: legend
            threshold steps: Theme.defect_steps(warn: drop_warn, crit: drop_crit)
          end

          # 3. ingestion rate (the liveness pulse).
          ingest_expr = Floor.zero(Promql.sum_rate(metric: ingest_metric, window: window,
                                                    group_by: group_by, selector: selector))
          row.panel :pipeline_ingest_rate, kind: :timeseries, width: Theme.third, height: Theme::TS_H do
            title "Audit ingestion / s (#{window})"
            unit 'eps'
            min 0
            graph :area
            description 'Audit events accepted per second — the pipeline pulse. ' \
                        'Flat-zero on a live cluster ⇒ the tap went dark.'
            query 'A', ingest_expr, datasource: datasource, presence: :event_driven, legend: legend
          end
        end

        def self.group_by_legend(group_by)
          labels = Array(group_by).compact.map(&:to_s).reject(&:empty?)
          return nil if labels.empty?
          labels.map { |l| "{{#{l}}}" }.join('/')
        end

        def self.validate!(datasource:, queue_depth_metric:, dropped_metric:, ingest_metric:)
          raise ArgumentError, 'SecurityEventPipelineHealthRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'SecurityEventPipelineHealthRow: queue_depth_metric: required' if blank?(queue_depth_metric)
          raise ArgumentError, 'SecurityEventPipelineHealthRow: dropped_metric: required' if blank?(dropped_metric)
          raise ArgumentError, 'SecurityEventPipelineHealthRow: ingest_metric: required' if blank?(ingest_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :group_by_legend, :validate!, :blank?
      end
    end
  end
end
