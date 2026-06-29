# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/health_matrix_table'

module Pangea
  module Dashboards
    module Library
      # The SEALED-ISOLATION invariant as a green wall — a tenant × resource
      # `:table` where every cell is `count by(tenant)(count by(tenant,resource)(...))`,
      # i.e. the number of DISTINCT resources of that kind a tenant maps to. The
      # blast-radius theorem is "exactly ONE of each isolating resource per tenant"
      # (one cluster, one account, one IaC-state-key, one secret-store) — so a
      # healthy fleet is a wall of green 1s, and ANY cell ≠ 1 (a tenant sharing a
      # cluster, or fanned across two accounts) cell-colours red. The dashboard
      # makes the UNREPRESENTABILITY claim continuously attested: the invariant
      # isn't asserted in prose, it's a coloured cell you watch.
      #
      # Composes `HealthMatrixTable` (the per-column threshold cell-colour seam is
      # reused, never re-implemented). Each segmentation column carries a band
      # threshold that is GREEN only at exactly 1: warn at 2 (over-shared) — and,
      # because 0 is also wrong (a tenant with no isolating resource), the column
      # description names the zero case (a 0 reads green under a higher-is-worse
      # ladder, so the operator treats a 0 row as a presence gap surfaced by the
      # companion membership check, not a pass).
      #
      # ── Why count-of-distinct (the doubly-nested count) ─────────────────────
      # `count by(tenant)(count by(tenant, resource)(metric))` first collapses
      # each (tenant,resource) pair to one series, then counts those per tenant —
      # the cardinality of distinct resources a tenant touches. 1 = sealed; N>1 =
      # the isolation seam leaked.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Segmentation' do
      #     Pangea::Dashboards::Library::OneToOneSegmentationTable.add(
      #       self, datasource: 'vm', tenant_label: 'tenant',
      #       segments: [
      #         { name: 'Clusters',      metric: 'tenant_cluster_info',     resource_label: 'cluster' },
      #         { name: 'Cloud accounts', metric: 'tenant_account_info',    resource_label: 'account' },
      #         { name: 'State keys',    metric: 'tenant_iac_state_info',   resource_label: 'state_key' },
      #         { name: 'Secret stores', metric: 'tenant_secretstore_info', resource_label: 'store' },
      #       ])
      #   end
      module OneToOneSegmentationTable
        # datasource:    (req) the metrics datasource uid
        # tenant_label:  (req) the per-tenant row key
        # segments:      (req) non-empty Array of segment Hashes:
        #                  name: (req) column header,
        #                  metric: (req) the *_info gauge mapping tenant→resource,
        #                  resource_label: (req) the distinct-resource label,
        #                  selector: optional typed matcher scoping the metric
        # title:         panel title
        def self.add(row, datasource:, tenant_label:, segments:, title: nil)
          validate!(datasource: datasource, tenant_label: tenant_label, segments: segments)
          columns = segments.map do |s|
            seg = s.transform_keys(&:to_sym)
            { name: seg.fetch(:name), unit: 'short', warn: 2, crit: 2,
              expr: distinct_count(tenant_label: tenant_label, metric: seg.fetch(:metric),
                                   resource_label: seg.fetch(:resource_label), selector: seg[:selector]) }
          end
          HealthMatrixTable.add(row, datasource: datasource, topology_label: tenant_label,
                                columns: columns,
                                title: title || "1:1 segmentation by #{tenant_label} (every cell must be 1)")
        end

        # count by(tenant)( count by(tenant, resource)( metric{sel} ) ) — the
        # cardinality of distinct `resource_label` values a tenant maps to.
        def self.distinct_count(tenant_label:, metric:, resource_label:, selector:)
          inner = "count#{Promql.by([tenant_label, resource_label])}(#{metric}#{Promql.braces(selector)})"
          "count#{Promql.by(tenant_label)}(#{inner})"
        end

        def self.validate!(datasource:, tenant_label:, segments:)
          raise ArgumentError, 'OneToOneSegmentationTable: datasource: required' if blank?(datasource)
          raise ArgumentError, 'OneToOneSegmentationTable: tenant_label: required' if blank?(tenant_label)
          raise ArgumentError, 'OneToOneSegmentationTable: segments must be a non-empty Array' \
            unless segments.is_a?(::Array) && !segments.empty?
          segments.each do |s|
            raise ArgumentError, "OneToOneSegmentationTable: each segment must be a Hash (got #{s.inspect})" \
              unless s.is_a?(::Hash)
            h = s.transform_keys(&:to_sym)
            raise ArgumentError, "OneToOneSegmentationTable: each segment needs :name (got #{s.inspect})" if blank?(h[:name])
            raise ArgumentError, "OneToOneSegmentationTable: segment #{h[:name].inspect} needs :metric" if blank?(h[:metric])
            raise ArgumentError, "OneToOneSegmentationTable: segment #{h[:name].inspect} needs :resource_label" \
              if blank?(h[:resource_label])
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :distinct_count, :validate!, :blank?
      end
    end
  end
end
