# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The nervous-system FLOW STRIP — a horizontal strip of one `:stat` tile
      # per declared pipeline stage, IN ORDER (tap → broker → consumer → store),
      # each showing the stage's throughput AND a CONSERVATION RATIO (out/in) that
      # colours the tile: a stage where what-comes-out tracks what-comes-in is
      # green (≈1), a LEAKY hop where out < in lights up amber/red. Read
      # left-to-right, the strip answers "where in the pipeline are events being
      # dropped?" preattentively — the first non-green tile names the leaky hop.
      #
      # ── Why a conservation ratio (out/in), not raw throughput ─────────────
      # Raw per-stage rate tells you a stage is busy, not whether it is HEALTHY.
      # A pipeline is conservative when every hop forwards what it receives; the
      # ratio out/in is the per-stage conservation invariant. `liveness_steps`
      # colours it (lower = worse: a ratio < ok means the stage is leaking). The
      # tile's NUMBER is the stage throughput (the operator's units), the COLOUR
      # is the conservation health — two reads from one tile.
      #
      # ── Why floored (event_driven) ──────────────────────────────────────
      # Stage throughput is `sum(rate(*_total[w]))` over event-driven counters —
      # a quiet stage has no series until its first event. `Floor.zero` makes an
      # idle stage read a true 0 (lit, honest), never an ambiguous "No data".
      # The ratio's denominator is floored away from 0 with `clamp_min(…, 1)` so a
      # cold pipeline reads a defined ratio rather than a NaN.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Pipeline flow' do
      #     Pangea::Dashboards::Library::PipelineFlowStrip.add(
      #       self, datasource: 'vm',
      #       stages: [
      #         { name: 'tap',      in_counter: 'tap_received_total',      out_counter: 'tap_sent_total' },
      #         { name: 'broker',   in_counter: 'broker_received_total',   out_counter: 'broker_sent_total' },
      #         { name: 'consumer', in_counter: 'consumer_received_total', out_counter: 'consumer_sent_total' },
      #         { name: 'store',    in_counter: 'store_received_total',    out_counter: 'store_written_total' },
      #       ])
      #   end
      module PipelineFlowStrip
        # datasource:    (req) the metrics datasource uid
        # stages:        (req) ordered Array of stage Hashes, each:
        #                  name:        (req) stage label (tile title)
        #                  in_counter:  (req) *_total counter for items ENTERING
        #                  out_counter: (req) *_total counter for items LEAVING
        #                  selector:    optional Promql matcher scoping the stage
        # window:        rate window (default 5m)
        # unit:          throughput unit shown on each tile (default 'cps')
        # leak_ok:       conservation ratio at/above which a hop is healthy
        #                (default 0.95 — a hop forwarding ≥95% of input is green)
        # title:         strip title prefix (default 'Flow')
        def self.add(row, datasource:, stages:, window: '5m', unit: 'cps',
                     leak_ok: 0.95, title: 'Flow')
          validate!(datasource: datasource, stages: stages)
          width = Theme.tile_width(stages.length)
          stages.each_with_index do |stage, idx|
            add_stage_tile(row, stage.transform_keys(&:to_sym), datasource: datasource,
                           window: window, unit: unit, leak_ok: leak_ok,
                           width: width, idx: idx, title_prefix: title)
          end
        end

        # One stage tile — throughput number, conservation-coloured. The number
        # is the floored out-rate (what the stage forwards); the colour is the
        # out/in ratio against the liveness ladder (lower ratio = leakier = red).
        def self.add_stage_tile(row, stage, datasource:, window:, unit:, leak_ok:, width:, idx:, title_prefix:)
          name = stage.fetch(:name)
          sel  = stage[:selector]
          out_rate = Promql.sum_rate(metric: stage.fetch(:out_counter), window: window, selector: sel)
          in_rate  = Promql.sum_rate(metric: stage.fetch(:in_counter), window: window, selector: sel)
          # conservation = out / clamp_min(in, 1) — a cold pipeline reads a
          # defined ratio (out is ~0 too) instead of dividing by zero.
          ratio = "(#{out_rate}) / clamp_min(#{in_rate}, 1)"
          pid   = :"flow_#{slug(name)}_#{idx}"
          q     = Floor.zero(ratio)
          row.panel pid, kind: :stat, width: width, height: Theme::STAT_H do
            title "#{title_prefix} · #{name}"
            unit 'percentunit'
            description "Conservation ratio (out/in) for the #{name} hop. " \
                        'Green ⇒ the stage forwards what it receives; amber/red ⇒ a leaky hop dropping events.'
            display :background      # flood the tile — preattentive leak signal
            graph :area              # trend sparkline behind the ratio (Tufte)
            # event_driven: a cold stage reads a floored 0 ratio, never "No data".
            query 'A', q, datasource: datasource, presence: :event_driven, legend: name.to_s
            # liveness ladder: ratio BELOW leak_ok is the defect (lower = worse).
            threshold steps: Theme.liveness_steps(ok: leak_ok)
          end
        end

        def self.validate!(datasource:, stages:)
          raise ArgumentError, 'PipelineFlowStrip: datasource: required' if blank?(datasource)
          raise ArgumentError, 'PipelineFlowStrip: stages must be a non-empty Array' \
            unless stages.is_a?(::Array) && !stages.empty?
          stages.each do |s|
            h = s.transform_keys(&:to_sym)
            raise ArgumentError, "PipelineFlowStrip: each stage needs :name (got #{s.inspect})" if blank?(h[:name])
            raise ArgumentError, "PipelineFlowStrip: stage #{h[:name].inspect} needs :in_counter" if blank?(h[:in_counter])
            raise ArgumentError, "PipelineFlowStrip: stage #{h[:name].inspect} needs :out_counter" if blank?(h[:out_counter])
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_stage_tile, :validate!, :blank?, :slug
      end
    end
  end
end
