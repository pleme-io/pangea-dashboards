# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/cell_status_grid'
require 'pangea/dashboards/library/health_matrix_table'
require 'pangea/dashboards/library/worst_n_focus_row'

module Pangea
  module Dashboards
    module Library
      # THE FLEET MAP — the keystone of the tenant-&-fleet domain. The first
      # board whose unit of composition is a POPULATION partitioned by a topology
      # label (cell / region / cloud / tenant). It opens on a fleet-wide defects
      # headline, lays out a per-cell health grid (the preattentive map), rolls
      # the population up by each rollup dimension as a coloured matrix, and ends
      # with the worst-N cells + their focus shape — fleet to cell in one pane.
      # The single-entity boards (WorkloadOverview …) are the leaves this cascade
      # drills into.
      #
      # The triage STORY, top-to-bottom (Theme: Status → map → rollups → worst):
      #
      #   Fleet defects   →  "is any cell unhealthy right now?"
      #   Cell grid       →  per-member health tiles (the fleet map)
      #   Rollups         →  health matrix by cloud / region / tenant_class
      #   Worst-N         →  the offender cells + their golden focus shape
      #
      #   dash = Pangea::Dashboards::Library::FleetTopologyOverview.build(
      #     id: :fleet_topology, name: 'Fleet Topology', datasource: 'vm',
      #     topology_label: 'cell', members: %w[cell-a cell-b cell-c],
      #     rollup_labels: %w[cloud region tenant_class], worst_n: 8)
      module FleetTopologyOverview
        # id/name:         dashboard id + human title
        # datasource:      (req) the metrics datasource uid
        # topology_label:  the label that partitions the fleet (default 'cell')
        # members:         cell/member values for the health grid (hand-listed —
        #                  panel repeat: is a renderer gap, catalog §9.4)
        # rollup_labels:   labels to roll the fleet up by (default cloud/region/tenant_class)
        # up_metric:       the per-target up gauge the health score reads
        # unhealthy_expr:  PromQL template (`%{member}`) for a member's defect score
        #                  (default: count of down targets for that member)
        # rank_metric:     the counter worst-N ranks cells by (default up_metric == 0 count via error rate)
        # worst_n:         how many offender cells to focus (default 8)
        def self.build(id:, datasource:, name: nil,
                       topology_label: 'cell', members: [],
                       rollup_labels: %w[cloud region tenant_class],
                       up_metric: 'up',
                       unhealthy_expr: nil,
                       error_metric: 'http_requests_total',
                       worst_n: 8)
          validate!(id: id, datasource: datasource, topology_label: topology_label)
          score_expr = unhealthy_expr || "count(#{up_metric}{#{topology_label}=\"%{member}\"} == 0)"
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · fleet topology")
          b.tags('pleme-io', 'fleet-topology')

          # 1. Fleet defects headline — any unhealthy cell across the fleet.
          fleet_unhealthy = {
            name: 'Unhealthy cells',
            expr: "count(count#{Promql.by(topology_label)}(#{up_metric} == 0))",
            warn: 1, crit: 3,
            desc: 'Cells with at least one down target. Red ⇒ a cell needs attention.'
          }
          b.row('Status — unhealthy cells') do
            Library::StatusOverview.add(self, datasource: datasource, signals: [fleet_unhealthy])
          end

          # 2. Cell grid — the per-member health map (hand-listed members).
          unless Array(members).empty?
            b.row("#{topology_label} health grid") do
              Library::CellStatusGrid.add(self, datasource: datasource, topology_label: topology_label,
                                          members: members, score_expr: score_expr, warn: 1, crit: 3)
            end
          end

          # 3. Rollups — health matrix by each rollup dimension.
          Array(rollup_labels).each do |rl|
            cols = rollup_columns(rl, up_metric: up_metric, error_metric: error_metric)
            b.row("Rollup by #{rl}") do
              Library::HealthMatrixTable.add(self, datasource: datasource, topology_label: rl,
                                             columns: cols, title: "Health by #{rl}")
            end
          end

          # 4. Worst-N cells + their golden focus shape.
          focus = "sum#{Promql.by(topology_label)}(rate(#{error_metric}{code=~\"5..\"}[5m]))"
          b.row('Worst cells — name + shape') do
            Library::WorstNFocusRow.add(self, datasource: datasource, topology_label: topology_label,
                                        rank_metric: error_metric, rank_agg: :rate,
                                        failure_results: nil, focus_expr: focus,
                                        focus_unit: 'reqps', n: worst_n,
                                        focus_title: "Worst #{topology_label} · 5xx rate")
          end

          b.build
        end

        # The standard rollup columns: live-cell count + a down-target count, both
        # aggregated by the rollup label, the down count cell-coloured as a defect.
        def self.rollup_columns(label, up_metric:, error_metric:)
          [
            { name: 'Cells', unit: 'short',
              expr: "count#{Promql.by(label)}(count#{Promql.by([label, 'cell'])}(#{up_metric}))" },
            { name: 'Down targets', unit: 'short', warn: 1, crit: 3,
              expr: "count#{Promql.by(label)}(#{up_metric} == 0)" }
          ]
        end

        def self.validate!(id:, datasource:, topology_label:)
          raise ArgumentError, 'FleetTopologyOverview: id: required' if blank?(id)
          raise ArgumentError, 'FleetTopologyOverview: datasource: required' if blank?(datasource)
          raise ArgumentError, 'FleetTopologyOverview: topology_label: required' if blank?(topology_label)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :rollup_columns, :validate!, :blank?
      end
    end
  end
end
