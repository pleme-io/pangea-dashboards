# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The ENVELOPE panel: ONE timeseries showing a current value riding
      # inside the [floor, ceiling] band it is allowed to occupy. Three series
      # overlay on one chart — the current limit (A), the floor (B), and the
      # ceiling (C) — so the operator sees at a glance whether the carved limit
      # is pinned to its floor, pressed against its ceiling, or breathing
      # comfortably in between. The shape between two bounding lines is read
      # preattentively: a value hugging the ceiling is "about to be capped",
      # hugging the floor is "about to be starved".
      #
      # Absorbed from the hand-written limit_envelope_mem panel in breathe.rb
      # (the memory-band current_limit-vs-[floor,ceiling] chart) and the
      # storage_limit_envelope panel in storage_carving.rb (the PVC carved-size
      # envelope) — both were the same three-series-on-one-timeseries idiom with
      # bespoke legends, so they distil to ONE typed atom per the prime
      # directive (solve-once, in one place).
      #
      # ── Why three series, not three panels ──────────────────────────────
      # The decision-relevant fact is the RELATIONSHIP between the value and its
      # bounds, and a relationship is read from one shared y-axis — splitting
      # floor/ceiling into sibling panels forces the eye to reconstruct the band
      # mentally. One timeseries with a shared axis is the data-ink-minimal
      # rendering of "is it inside the envelope?".
      #
      # ── Why :continuous (no floor) ──────────────────────────────────────
      # Limits, floors, and ceilings are gauge-like state that always has a
      # current value once the workload exists — they are not event-driven
      # counters, so `or vector(0)` would be wrong (a real 0 floor is distinct
      # from "no series"). Hence presence: :continuous on every series.
      #
      # ── The breathability overlay (optional `usage_metric:`) ────────────
      # Pass `usage_metric:` (the workload's OBSERVED value gauge — e.g.
      # `breathe_band_used`, which breathe exports for every band) and a fourth
      # series U is drawn INSIDE the envelope: the real workload riding the band
      # the controller carves around it. This turns "the limit sits in [floor,
      # ceiling]" into the far more decision-relevant "breathe is holding the
      # ACTUAL workload in its band" — used hugging the limit = about to grow,
      # used near the floor = reclaimable headroom. The usage series shares the
      # band's `dim` selector (it is the same breathe band identity), so the
      # author supplies only the metric name. Omit it ⇒ the classic 3-series
      # envelope, byte-unchanged.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Memory envelope' do
      #     Pangea::Dashboards::Library::FloorCeilingEnvelope.add(
      #       self, datasource: 'vm',
      #       limit_metric:   'breathe_band_current_limit',
      #       floor_metric:   'breathe_band_floor',
      #       ceiling_metric: 'breathe_band_ceiling',
      #       usage_metric:   'breathe_band_used',          # ← overlay the real workload
      #       dim: { name: 'arc-runner', dim: 'memory' }, unit: 'bytes')
      #   end
      module FloorCeilingEnvelope
        # datasource:     (req) the metrics datasource
        # limit_metric:   (req) the current-value gauge metric (series A)
        # floor_metric:   (req) the lower-bound gauge metric (series B)
        # ceiling_metric: (req) the upper-bound gauge metric (series C)
        # usage_metric:   (opt) the OBSERVED-value gauge (series U, drawn first/
        #                 prominent) — the real workload riding inside the band
        # dim:            typed selector (Hash preferred) applied to ALL series
        #                 (incl. usage) — the dimension the envelope is sliced on
        # legend_labels:  the per-series legend suffix ('{{namespace}}/{{name}}'
        #                 by default — the breathe band identity)
        # usage_legend:   the usage series label (default 'used')
        # unit:           Grafana unit (default 'bytes')
        # title:          panel title (default derived from limit_metric)
        def self.add(row, datasource:, limit_metric:, floor_metric:, ceiling_metric:, dim:,
                     usage_metric: nil, usage_legend: 'used',
                     legend_labels: '{{namespace}}/{{name}}', unit: 'bytes', title: nil)
          validate!(datasource: datasource, limit_metric: limit_metric,
                    floor_metric: floor_metric, ceiling_metric: ceiling_metric)
          braces = Promql.braces(dim)
          pid    = :"envelope_#{slug(limit_metric)}"
          ttl    = title || default_title(limit_metric)
          # Resolve refs/exprs/legends OUTSIDE the panel block — the block is
          # instance_eval'd against the PanelBuilder, so module helpers
          # (legend_for) aren't in scope there. Usage (U) leads when present so
          # it reads as the foreground series riding inside the bounds.
          spec = []
          spec << ['U', usage_metric, usage_legend] unless blank?(usage_metric)
          spec += [
            ['A', limit_metric,   'limit'],
            ['B', floor_metric,   'floor'],
            ['C', ceiling_metric, 'ceiling']
          ]
          series = spec.map do |ref, metric, label|
            [ref, "#{metric}#{braces}", legend_for(label, legend_labels)]
          end
          row.panel pid, kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title ttl
            unit unit
            min 0
            graph :area
            series.each do |ref, expr, leg|
              # gauge-like state — always has a current value; NOT floored.
              query ref, expr, datasource: datasource, presence: :continuous, legend: leg
            end
          end
        end

        # "limit {{namespace}}/{{name}}" when labels present, else just "limit".
        def self.legend_for(label, legend_labels)
          ll = legend_labels.to_s.strip
          ll.empty? ? label : "#{label} #{ll}"
        end

        def self.default_title(limit_metric)
          base = limit_metric.to_s.sub(/_bytes\z/, '').sub(/_current_limit\z/, '')
                             .sub(/_limit\z/, '').tr('_', ' ').strip
          base.empty? ? 'envelope' : "#{base} envelope"
        end

        def self.validate!(datasource:, limit_metric:, floor_metric:, ceiling_metric:)
          raise ArgumentError, 'FloorCeilingEnvelope: datasource: required' if blank?(datasource)
          raise ArgumentError, 'FloorCeilingEnvelope: limit_metric: required' if blank?(limit_metric)
          raise ArgumentError, 'FloorCeilingEnvelope: floor_metric: required' if blank?(floor_metric)
          raise ArgumentError, 'FloorCeilingEnvelope: ceiling_metric: required' if blank?(ceiling_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :legend_for, :default_title, :validate!, :blank?, :slug
      end
    end
  end
end
