# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/stat_strip'
require 'pangea/dashboards/library/pipeline_flow_strip'

module Pangea
  module Dashboards
    module Library
      # The single pane that proves the OBSERVABILITY PLANE ITSELF is alive — the
      # nervous system dashboards-itself. A tap/observability stack is only as
      # trustworthy as its own liveness: a silently-dead consumer or a draining
      # broker means every OTHER dashboard is lying (stale or empty). This board
      # answers "is the nervous system healthy end-to-end?" in one glance:
      #
      #   Subsystem liveness strip  →  one tile per plane subsystem (up / present)
      #   Pipeline flow (optional)  →  tap → broker → consumer → store conservation
      #   Forward-sink drops (opt)  →  the bounded fan-out's drop_newest counter
      #
      # The meta roll-up over the other domain-4 components — it reuses the
      # PipelineFlowStrip (the flow conservation read) and rolls each subsystem's
      # liveness into one StatStrip. Everything is a param (generic over any
      # observability plane): the author supplies the subsystem liveness exprs +
      # (optionally) the pipeline stages + the drop counter.
      #
      #   dash = Pangea::Dashboards::Library::NervousSystemSelfHealthBoard.build(
      #     id: :tendril_nss, name: 'tendril nervous system', datasource: 'metrics',
      #     subsystems: [
      #       { title: 'metrics store', expr: 'up{job="vmsingle"}' },
      #       { title: 'log store',     expr: 'up{job="victoria-logs"}' },
      #       { title: 'broker',        expr: 'up{job="pleme-nats"}' },
      #       { title: 'consumer',      expr: 'up{job="respiro"}' } ],
      #     stages: [ ... ], drop_metric: 'vector_buffer_discarded_events_total')
      module NervousSystemSelfHealthBoard
        # id/name:     dashboard id + human title
        # datasource:  (req) the metrics datasource uid
        # subsystems:  Array of { title:, expr: } liveness tiles (one per plane
        #              subsystem); empty ⇒ the liveness strip is omitted
        # stages:      optional pipeline stages for the PipelineFlowStrip (the
        #              tap→broker→consumer→store conservation read)
        # window:      rate window for flow + drops (default 5m)
        # drop_metric: optional forward-sink/buffer drop counter — a non-zero
        #              drop rate means the tap is shedding load (a real defect)
        def self.build(id:, datasource:, name: nil, subsystems: [], stages: nil,
                       window: '5m', drop_metric: nil, drop_legend: 'forward-sink drops')
          validate!(id: id, datasource: datasource)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · nervous-system self-health")
          b.tags('pleme-io', 'nervous-system', 'meta')

          # 1. Subsystem liveness — one tile per plane subsystem.
          subs = Array(subsystems).map do |s|
            s = s.transform_keys(&:to_sym) if s.is_a?(::Hash)
            { title: s[:title] || s[:name], expr: s[:expr], unit: 'short', liveness: 1 }
          end
          unless subs.empty?
            b.row('Subsystem liveness — is the plane alive?') do
              Library::StatStrip.add(self, datasource: datasource, tiles: subs)
            end
          end

          # 2. Pipeline flow conservation (optional).
          if stages
            stgs = stages
            b.row('Pipeline flow — tap → broker → consumer → store') do
              Library::PipelineFlowStrip.add(self, datasource: datasource, stages: stgs, window: window)
            end
          end

          # 3. Forward-sink drops — a shedding tap is a defect (optional).
          if drop_metric
            drop_expr = Floor.zero(Promql.sum_rate(metric: drop_metric, window: window))
            ds = datasource
            leg = drop_legend
            b.row('Forward-sink drops — is the tap shedding load?') do
              panel :nss_forward_drops, kind: :stat, width: Theme.tile_width(1), height: Theme::STAT_H do
                title leg
                unit 'cps'
                graph :area
                description 'Events dropped by the bounded fan-out buffer (when_full: drop_newest). ' \
                            'Non-zero ⇒ the tap is shedding load — investigate the downstream sink.'
                query 'A', drop_expr, datasource: ds, presence: :event_driven
                threshold steps: [{ color: Theme::OK, value: nil }, { color: Theme::WARN, value: 0.001 }]
              end
            end
          end

          b.build
        end

        def self.validate!(id:, datasource:)
          raise ArgumentError, 'NervousSystemSelfHealthBoard: id: required' if blank?(id)
          raise ArgumentError, 'NervousSystemSelfHealthBoard: datasource: required' if blank?(datasource)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
