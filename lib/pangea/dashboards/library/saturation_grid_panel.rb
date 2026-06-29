# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The cross-cell SATURATION GRID — ONE panel answering "which cell is hot?"
      # across the whole fleet at a glance. A single `:table` (instant snapshot)
      # or `:heatmap` (over time) of a saturation ratio aggregated `by(<cell
      # label> + grouping labels)`, coloured against Theme.defect_steps so a
      # saturated cell lights up red. It is the fleet-scale counterpart of
      # SaturationRow: where SaturationRow shows ONE resource's USE over time,
      # this shows EVERY cell's saturation for one resource side by side, the
      # rows grouped by cloud/region/tenant so the heat clusters by topology.
      #
      # ── Why one panel, not a per-cell strip ─────────────────────────────
      # A fleet of N cells does not fit as N tiles — the eye cannot scan 40 stat
      # tiles for the red one. A grid keyed by the cell label collapses the whole
      # population into one preattentive surface: the table sorts/colours by
      # saturation, the heatmap shows the hot rows over time. This is the instant
      # "where is the fire?" read the fleet boards open on.
      #
      # ── :table (default, instant) vs :heatmap (over time) ───────────────
      # `mode: :table` → an instant topk-free `by(labels)` aggregation rendered
      # as a colour-coded table (now-snapshot). `mode: :heatmap` → the same
      # aggregation as a time-series heatmap (one lane per cell, hot = saturated)
      # — the per-cell-availability-over-time shape, on the panel kinds the
      # renderer supports today.
      #
      # ── Why :continuous (no floor) ──────────────────────────────────────
      # A saturation ratio is a LEVEL (utilisation), always present while the cell
      # exists. A genuine 0 saturation is a real (excellent) reading; an absent
      # cell should read "No data", not a misleading floored 0. So never floored.
      #
      #   row 'Saturation grid' do
      #     Pangea::Dashboards::Library::SaturationGridPanel.add(
      #       self, datasource: 'vm', resource: 'cpu',
      #       saturation_expr: 'max by(cell)(cell_cpu_saturation_ratio)',
      #       cell_label: 'cell', group_by: %w[cloud region])
      #   end
      module SaturationGridPanel
        MODES = %i[table heatmap].freeze

        # datasource:      (req) the metrics datasource uid
        # saturation_expr: (req) a complete saturation-ratio PromQL expr — already
        #                  aggregated by the cell label (the author owns the
        #                  aggregation; this panel owns layout + colour). 0–1 or
        #                  0–100 by `unit`.
        # resource:        (req) the resource the grid is for (cpu/memory/disk/…)
        #                  — names the panel
        # cell_label:      the topology label whose values are the grid rows
        #                  (default 'cell') — cosmetic legend only
        # group_by:        extra grouping labels (cloud/region/tenant) surfaced in
        #                  the legend so the heat clusters by topology
        # mode:            :table (default, instant snapshot) | :heatmap (over time)
        # unit:            'percentunit' (default, 0–1) | 'percent' (0–100)
        # warn / crit:     saturation defect thresholds (default 70 / 90 in the
        #                  unit's scale)
        # title:           cosmetic override
        def self.add(row, datasource:, saturation_expr:, resource:, cell_label: 'cell',
                     group_by: [], mode: :table, unit: 'percentunit', warn: nil, crit: nil, title: nil)
          validate!(datasource: datasource, saturation_expr: saturation_expr, resource: resource, mode: mode)
          m       = mode.to_sym
          dwarn   = warn || (unit == 'percent' ? 70 : 0.7)
          dcrit   = crit || (unit == 'percent' ? 90 : 0.9)
          steps   = Theme.defect_steps(warn: dwarn, crit: dcrit)
          legend  = ([cell_label] + Array(group_by)).map(&:to_s).reject(&:empty?).map { |l| "{{#{l}}}" }.join('/')
          pid     = :"saturation_grid_#{slug(resource)}_#{m}"
          ttl     = title || "#{resource} saturation by #{cell_label} (#{m})"
          instant = m == :table
          row.panel pid, kind: m, width: Theme.full, height: Theme::TABLE_H do
            title ttl
            unit unit
            description "Per-cell #{resource} saturation across the fleet. A hot row/cell ⇒ " \
                        'that cell is running out of headroom for this resource.'
            # saturation is a LEVEL (utilisation) — always present, never floored.
            query 'A', saturation_expr, datasource: datasource, presence: :continuous,
                  instant: instant, legend: legend
            threshold steps: steps
          end
        end

        def self.validate!(datasource:, saturation_expr:, resource:, mode:)
          raise ArgumentError, 'SaturationGridPanel: datasource: required' if blank?(datasource)
          raise ArgumentError, 'SaturationGridPanel: saturation_expr: required' if blank?(saturation_expr)
          raise ArgumentError, 'SaturationGridPanel: resource: required' if blank?(resource)
          raise ArgumentError, "SaturationGridPanel: mode must be one of #{MODES.inspect} (got #{mode.inspect})" \
            unless MODES.include?(mode.to_s.to_sym)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :validate!, :blank?, :slug
      end
    end
  end
end
