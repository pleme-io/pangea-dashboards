# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/saturation_grid_panel'
require 'pangea/dashboards/library/capacity_headroom_stat'
require 'pangea/dashboards/library/top_n_table'

module Pangea
  module Dashboards
    module Library
      # The cross-cell SATURATION board — defects-first USE across the whole
      # fleet. Where ManagedDatastoreOverview / K8sControlPlaneBoard answer "is
      # THIS cell healthy?", this answers "WHICH cell is hot?" at fleet scale:
      #
      #   Saturation defects headline  →  one saturation grid per resource (rows
      #   = cells)  →  per-cell worst-headroom gauges  →  hottest-cells offenders
      #
      # ── Why defects-first, then the grids ───────────────────────────────
      # The headline counts cells over a saturation threshold per resource — the
      # operator lands on "is any cell saturated?" before scanning a grid. Each
      # resource then gets one SaturationGridPanel (the "which cell is hot?"
      # instant snapshot), the worst-headroom gauges name the tightest cells, and
      # the offenders table ranks the hottest cells to act on.
      #
      #   dash = Pangea::Dashboards::Library::FleetSaturationGrid.build(
      #     id: :fleet_saturation, name: 'Fleet saturation', datasource: 'vm',
      #     cell_label: 'cell', group_by: %w[cloud region],
      #     resources: {
      #       'cpu'    => 'max by(cell)(cell_cpu_saturation_ratio)',
      #       'memory' => 'max by(cell)(cell_mem_saturation_ratio)' },
      #     headroom_metric: 'cell_cpu_headroom_ratio',
      #     hottest_metric: 'cell_cpu_saturation_ratio')
      module FleetSaturationGrid
        # id/name:          dashboard id + human title
        # datasource:       (req) the metrics datasource uid
        # resources:        (req) Hash{ resource name => saturation-ratio expr,
        #                   already aggregated by the cell label } — one grid per
        #                   entry, in declared order
        # cell_label:       the topology label whose values are the grid rows
        #                   (default 'cell')
        # group_by:         extra grouping labels (cloud/region/tenant) clustered
        #                   in each grid's legend
        # signals:          extra StatusOverview defect signals (merged after the
        #                   built-in per-resource over-threshold tiles)
        # sat_warn/sat_crit: saturation defect thresholds (ratio scale, default
        #                   0.7 / 0.9)
        # grid_mode:        :table (default, snapshot) | :heatmap (over time)
        # unit:             saturation unit (default 'percentunit')
        # headroom_metric:  per-cell headroom-ratio gauge → a worst-cell headroom
        #                   stat (optional)
        # headroom_floor/headroom_ok: headroom thresholds (default 0.1 / 0.3)
        # hottest_metric:   a per-cell saturation metric → hottest-cells top-N
        #                   offenders table (optional)
        # top_n:            offenders top-N (default 8)
        def self.build(id:, datasource:, resources:, name: nil, cell_label: 'cell', group_by: [],
                       signals: [], sat_warn: 0.7, sat_crit: 0.9, grid_mode: :table, unit: 'percentunit',
                       headroom_metric: nil, headroom_floor: 0.1, headroom_ok: 0.3,
                       hottest_metric: nil, top_n: 8)
          validate!(id: id, datasource: datasource, resources: resources)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · fleet saturation")
          b.tags('pleme-io', 'fleet-saturation')

          # 1. Defects headline — count of cells over the saturation threshold,
          # one tile per resource. count((sat_expr) > crit) — the fleet's hot-cell
          # tally, lands the eye before any grid.
          built_signals = resources.map do |res, expr|
            {
              name: "#{res} saturated cells",
              expr: "count((#{expr}) > #{sat_crit})",
              warn: 1, crit: 1, unit: 'short',
              desc: "Cells whose #{res} saturation exceeds #{sat_crit}. RED ⇒ a cell is hot."
            }
          end
          all_signals = built_signals + Array(signals)
          b.row('Status — saturated cells across the fleet') do
            Library::StatusOverview.add(self, datasource: datasource, signals: all_signals)
          end

          # 2. One saturation grid per resource (rows = cells).
          resources.each do |res, expr|
            b.row("#{res} saturation — which cell is hot?") do
              Library::SaturationGridPanel.add(self, datasource: datasource, saturation_expr: expr,
                                               resource: res.to_s, cell_label: cell_label, group_by: group_by,
                                               mode: grid_mode, unit: unit, warn: sat_warn, crit: sat_crit)
            end
          end

          # 3. Per-cell worst-headroom gauge (optional). The headroom metric is
          # already keyed per cell; CapacityHeadroomStat's min reducer collapses
          # to the TIGHTEST cell — the honest fleet headroom.
          if headroom_metric
            b.row('Worst-cell headroom') do
              Library::CapacityHeadroomStat.add(self, datasource: datasource, expr: headroom_metric.to_s,
                                                reducer: :min, unit: unit, floor: headroom_floor,
                                                ok: headroom_ok, title: 'Worst-cell headroom')
            end
          end

          # 4. Hottest-cells offenders table (optional). agg: :sum over the
          # per-cell saturation metric, ranked by cell.
          if hottest_metric
            b.row('Hottest cells — offenders') do
              Library::TopNTable.add(self, datasource: datasource, metric: hottest_metric,
                                     group_by: ([cell_label] + Array(group_by)).map(&:to_s),
                                     agg: :sum, n: top_n.to_i, title: "Top #{top_n.to_i} hottest cells")
            end
          end

          b.build
        end

        def self.validate!(id:, datasource:, resources:)
          raise ArgumentError, 'FleetSaturationGrid: id: required' if blank?(id)
          raise ArgumentError, 'FleetSaturationGrid: datasource: required' if blank?(datasource)
          raise ArgumentError, 'FleetSaturationGrid: resources must be a non-empty Hash' \
            unless resources.is_a?(::Hash) && !resources.empty?
          resources.each do |res, expr|
            raise ArgumentError, "FleetSaturationGrid: resource #{res.inspect} needs a non-empty saturation expr" \
              if blank?(expr)
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
