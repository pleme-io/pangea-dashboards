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
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Memory envelope' do
      #     Pangea::Dashboards::Library::FloorCeilingEnvelope.add(
      #       self, datasource: 'vm',
      #       limit_metric:   'breathe_band_current_limit_bytes',
      #       floor_metric:   'breathe_band_floor_bytes',
      #       ceiling_metric: 'breathe_band_ceiling_bytes',
      #       dim: { resource: 'memory' }, unit: 'bytes')
      #   end
      module FloorCeilingEnvelope
        # datasource:     (req) the metrics datasource
        # limit_metric:   (req) the current-value gauge metric (series A)
        # floor_metric:   (req) the lower-bound gauge metric (series B)
        # ceiling_metric: (req) the upper-bound gauge metric (series C)
        # dim:            typed selector (Hash preferred) applied to all three
        #                 series — the dimension the envelope is sliced on
        # legend_labels:  the per-series legend suffix ('{{namespace}}/{{name}}'
        #                 by default — the breathe band identity)
        # unit:           Grafana unit (default 'bytes')
        # title:          panel title (default derived from limit_metric)
        def self.add(row, datasource:, limit_metric:, floor_metric:, ceiling_metric:, dim:,
                     legend_labels: '{{namespace}}/{{name}}', unit: 'bytes', title: nil)
          validate!(datasource: datasource, limit_metric: limit_metric,
                    floor_metric: floor_metric, ceiling_metric: ceiling_metric)
          braces = Promql.braces(dim)
          pid    = :"envelope_#{slug(limit_metric)}"
          ttl    = title || default_title(limit_metric)
          # Resolve refs/exprs/legends OUTSIDE the panel block — the block is
          # instance_eval'd against the PanelBuilder, so module helpers
          # (legend_for) aren't in scope there.
          series = [
            ['A', limit_metric,   'limit'],
            ['B', floor_metric,   'floor'],
            ['C', ceiling_metric, 'ceiling']
          ].map do |ref, metric, label|
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
