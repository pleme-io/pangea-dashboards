# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The CATEGORY-DEFINING fleet primitive — a multi-column per-entity
      # `:table` where the ROW is an entity (tenant / cell / region, keyed by a
      # topology label) and each COLUMN is a golden signal aggregated `by(label)`.
      # Where `TopNTable` ranks ONE metric, this lays N signals side by side so
      # the operator reads a whole population's health as a coloured matrix:
      # scan down a column for the worst member on that signal, scan across a row
      # for one member's full posture. Per-column threshold cell-colouring turns
      # the table into a defects-first grid; sort-by-worst floats the offenders
      # to the top.
      #
      # Each emitted query is `agg by(<topology_label>)(<column expr>)`, instant
      # (a now-snapshot the table shows as one column), joined by Grafana on the
      # shared `<topology_label>` value — so column A's "rate" and column B's
      # "error %" land on the same tenant row.
      #
      # ── Why the typed options(grafana:) fieldConfig seam ────────────────────
      # Per-column units + per-column threshold colouring + the "instant table,
      # merge by label" layout are Grafana field overrides, not panel-AST
      # attributes. They go through the SAME typed `options(grafana:)` escape
      # hatch ByPhaseStrip uses for stacking — never a renderer change. The
      # override carries `fieldConfig.overrides` (one matcher per column, by the
      # column's value field name `Value #<ref>`) so a backend that ignores the
      # key degrades to a plain multi-column table.
      #
      # ── Why instant + :continuous ───────────────────────────────────────────
      # A health matrix is a now-snapshot (each cell evaluated at the dashboard's
      # `to` time). The columns are gauges/ratios — real magnitudes, never floored
      # (an absent member rightly drops out of the matrix rather than reading a
      # misleading 0).
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Tenant health' do
      #     Pangea::Dashboards::Library::HealthMatrixTable.add(
      #       self, datasource: 'vm', topology_label: 'tenant',
      #       columns: [
      #         { name: 'Rate',     expr: 'sum by(tenant)(rate(req_total[5m]))', unit: 'reqps' },
      #         { name: 'Error %',  expr: '100 * sum by(tenant)(rate(req_total{code=~"5.."}[5m])) / sum by(tenant)(rate(req_total[5m]))',
      #           unit: 'percent', warn: 1, crit: 5 },
      #         { name: 'p99 (s)',  expr: 'histogram_quantile(0.99, sum by(tenant,le)(rate(req_seconds_bucket[5m])))',
      #           unit: 's', warn: 0.5, crit: 1 },
      #       ])
      #   end
      module HealthMatrixTable
        # datasource:      (req) the metrics datasource uid
        # topology_label:  (req) the per-entity key column (tenant/cell/region)
        # columns:         (req) non-empty Array of column Hashes:
        #                    name: (req) column header,
        #                    expr: (req) `agg by(<topology_label>)(...)` PromQL,
        #                    unit: column unit (default 'short'),
        #                    warn:/crit: optional per-column defect thresholds
        #                                (cell-colour amber/red above them)
        # title:           panel title (default 'Health matrix')
        def self.add(row, datasource:, topology_label:, columns:, title: nil)
          validate!(datasource: datasource, topology_label: topology_label, columns: columns)
          overrides = column_overrides(columns)
          cols      = columns.map { |c| c.transform_keys(&:to_sym) }
          ttl       = title || "Health matrix by #{topology_label}"
          row.panel :health_matrix, kind: :table, width: Theme.full, height: Theme::TABLE_H do
            title ttl
            description "Per-#{topology_label} golden signals as one coloured matrix. " \
                        'Scan a column for the worst member, a row for one member’s posture.'
            # The typed grafana seam: instant-table merge-by-label + per-column
            # units + per-column threshold cell-colouring. Ignored gracefully by
            # any backend that doesn't know the key (degrades to a plain table).
            options(grafana: {
                      'transformations' => [
                        { 'id' => 'merge', 'options' => {} }
                      ],
                      'fieldConfig' => { 'defaults' => {}, 'overrides' => overrides }
                    })
            cols.each_with_index do |col, idx|
              ref = ('A'.ord + idx).chr
              query ref, col.fetch(:expr), datasource: datasource, instant: true,
                    presence: :continuous, legend: col.fetch(:name)
            end
          end
        end

        # One fieldConfig override per column, matched by Grafana's per-query
        # value field name (`Value #A`, `Value #B`, …), carrying the column's
        # display name, unit, and (when given) defect-threshold colour steps.
        def self.column_overrides(columns)
          columns.each_with_index.map do |c, idx|
            col = c.transform_keys(&:to_sym)
            ref = ('A'.ord + idx).chr
            props = [
              { 'id' => 'displayName', 'value' => col.fetch(:name) },
              { 'id' => 'unit',        'value' => col.fetch(:unit, 'short') }
            ]
            if col[:warn]
              props << { 'id' => 'thresholds',
                         'value' => { 'mode' => 'absolute',
                                      'steps' => threshold_steps(col[:warn], col[:crit]) } }
              props << { 'id' => 'custom.cellOptions', 'value' => { 'type' => 'color-background' } }
            end
            { 'matcher' => { 'id' => 'byName', 'options' => "Value ##{ref}" }, 'properties' => props }
          end
        end

        def self.threshold_steps(warn, crit)
          steps = [{ 'color' => Theme::OK, 'value' => nil },
                   { 'color' => Theme::WARN, 'value' => warn.to_f }]
          steps << { 'color' => Theme::CRIT, 'value' => crit.to_f } if crit
          steps
        end

        def self.validate!(datasource:, topology_label:, columns:)
          raise ArgumentError, 'HealthMatrixTable: datasource: required' if blank?(datasource)
          raise ArgumentError, 'HealthMatrixTable: topology_label: required' if blank?(topology_label)
          raise ArgumentError, 'HealthMatrixTable: columns must be a non-empty Array' \
            unless columns.is_a?(::Array) && !columns.empty?
          columns.each do |c|
            raise ArgumentError, "HealthMatrixTable: each column must be a Hash (got #{c.inspect})" \
              unless c.is_a?(::Hash)
            h = c.transform_keys(&:to_sym)
            raise ArgumentError, "HealthMatrixTable: each column needs :name (got #{c.inspect})" if blank?(h[:name])
            raise ArgumentError, "HealthMatrixTable: column #{h[:name].inspect} needs :expr" if blank?(h[:expr])
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :column_overrides, :threshold_steps, :validate!, :blank?
      end
    end
  end
end
