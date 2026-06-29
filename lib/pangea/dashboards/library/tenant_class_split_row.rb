# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The TWO-CLASS comparison row — vendor-SHARED vs customer-DEDICATED tenancy
      # side by side. A multi-tenant fleet has two structurally different tenant
      # classes (a shared pool many small tenants ride, and dedicated cells one
      # big customer each), and they want comparing, not averaging: the shared
      # class's noisy-neighbour blast radius vs the dedicated class's per-customer
      # isolation. This row renders the SAME measure for both classes on adjacent
      # half-width panels so the operator reads the contrast at a glance.
      #
      # The class partition is one label (`class_label`, default `tenant_class`)
      # with two values (`shared_value` / `dedicated_value`). Each side evaluates
      # the supplied measure expression with its class value substituted into a
      # `%{class}` template — the author writes the measure once, the row renders
      # it twice scoped to each class.
      #
      # ── Why side-by-side half panels (not one overlaid chart) ───────────────
      # Two tenancy classes have different magnitudes (a shared pool's aggregate
      # rate dwarfs one dedicated cell's), so overlaying them on one axis hides
      # the smaller. Adjacent panels with independent axes keep BOTH legible while
      # the proximity (Gestalt) still reads them as a pair.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Shared vs dedicated' do
      #     Pangea::Dashboards::Library::TenantClassSplitRow.add(
      #       self, datasource: 'vm', class_label: 'tenant_class',
      #       measure_expr: 'sum(rate(http_requests_total{tenant_class="%{class}"}[5m]))',
      #       measure_unit: 'reqps', measure_title: 'Request rate')
      #   end
      module TenantClassSplitRow
        # datasource:      (req) the metrics datasource uid
        # measure_expr:    (req) a PromQL template with `%{class}` substituted per side
        # class_label:     the partition label (default 'tenant_class')
        # shared_value:    the shared-class label value (default 'shared')
        # dedicated_value: the dedicated-class label value (default 'dedicated')
        # measure_unit:    panel unit (default 'short')
        # measure_title:   the measure name (titles both panels)
        # presence:        :continuous (default) | :event_driven for both legs
        def self.add(row, datasource:, measure_expr:, class_label: 'tenant_class',
                     shared_value: 'shared', dedicated_value: 'dedicated',
                     measure_unit: 'short', measure_title: 'Measure', presence: :continuous)
          validate!(datasource: datasource, measure_expr: measure_expr,
                    class_label: class_label, shared_value: shared_value, dedicated_value: dedicated_value)

          add_side(row, datasource: datasource, class_value: shared_value, measure_expr: measure_expr,
                   unit: measure_unit, title: "#{measure_title} · shared", pid: :tenant_class_shared, presence: presence)
          add_side(row, datasource: datasource, class_value: dedicated_value, measure_expr: measure_expr,
                   unit: measure_unit, title: "#{measure_title} · dedicated", pid: :tenant_class_dedicated, presence: presence)
        end

        def self.add_side(row, datasource:, class_value:, measure_expr:, unit:, title:, pid:, presence:)
          expr = format(measure_expr, class: class_value)
          row.panel pid, kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title title
            unit unit
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: presence, legend: class_value
          end
        end

        def self.validate!(datasource:, measure_expr:, class_label:, shared_value:, dedicated_value:)
          raise ArgumentError, 'TenantClassSplitRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'TenantClassSplitRow: measure_expr: required (a %{class} template)' if blank?(measure_expr)
          raise ArgumentError, 'TenantClassSplitRow: measure_expr must contain %{class}' \
            unless measure_expr.to_s.include?('%{class}')
          raise ArgumentError, 'TenantClassSplitRow: class_label: required' if blank?(class_label)
          raise ArgumentError, 'TenantClassSplitRow: shared_value: required' if blank?(shared_value)
          raise ArgumentError, 'TenantClassSplitRow: dedicated_value: required' if blank?(dedicated_value)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :add_side, :validate!, :blank?
      end
    end
  end
end
