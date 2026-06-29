# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/one_to_one_segmentation_table'
require 'pangea/dashboards/library/residency_compliance_strip'

module Pangea
  module Dashboards
    module Library
      # THE POSTURE / THEOREM board — blast-radius isolation as continuously
      # attested invariants. Multi-tenant isolation is a set of UNREPRESENTABILITY
      # claims ("a tenant maps to exactly one cluster / account / state-key /
      # secret-store; cross-tenant access is impossible") — this board renders
      # them as defects-that-must-be-ZERO, a 1:1 segmentation matrix (a green wall
      # of 1s), and a residency/compliance posture strip. The security analog of
      # the defects headline: the operator watches a wall that should never light.
      #
      # The triage STORY, top-to-bottom:
      #
      #   Isolation defects  →  invariants that MUST be zero (cross-tenant leaks)
      #   Segmentation       →  tenant × resource 1:1 matrix (every cell must be 1)
      #   Residency posture  →  per-group residency/compliance defect tiles
      #
      #   dash = Pangea::Dashboards::Library::BlastRadiusIsolationBoard.build(
      #     id: :blast_radius, name: 'Blast Radius', datasource: 'vm',
      #     tenant_label: 'tenant',
      #     isolation_invariants: [
      #       { name: 'Cross-tenant access', expr: 'count(cross_tenant_access_total)' },
      #     ],
      #     segments: [{ name: 'Clusters', metric: 'tenant_cluster_info', resource_label: 'cluster' }],
      #     residency: { posture_label: 'region', groups: %w[eu us],
      #                  violation_expr: 'count(tenant_residency_info{region="%{group}",compliant="false"})' })
      module BlastRadiusIsolationBoard
        # id/name:        dashboard id + human title
        # datasource:     (req) the metrics datasource uid
        # tenant_label:   the per-tenant key (default 'tenant')
        # isolation_invariants: Array of StatusOverview signal Hashes — each an
        #                 invariant whose healthy value is 0 (warn/crit default 1/1
        #                 so ANY nonzero is a defect). When omitted, a generic
        #                 cross-tenant-access invariant is synthesised.
        # segments:       (req) OneToOneSegmentationTable segment Hashes
        # residency:      optional { posture_label:, groups:, violation_expr:, warn:, crit: }
        def self.build(id:, datasource:, segments:, name: nil, tenant_label: 'tenant',
                       isolation_invariants: nil, residency: nil)
          validate!(id: id, datasource: datasource, tenant_label: tenant_label, segments: segments)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · blast radius")
          b.tags('pleme-io', 'blast-radius-isolation')

          # 1. Isolation invariants — defects that MUST be zero.
          invariants = isolation_invariants && !isolation_invariants.empty? ? isolation_invariants : [{
            name: 'Cross-tenant access',
            expr: 'count(cross_tenant_access_total)',
            warn: 1, crit: 1,
            desc: 'Observed cross-tenant access events — MUST be zero (the isolation theorem). Any red = a sealed boundary leaked.'
          }]
          b.row('Status — isolation invariants (must be zero)') do
            Library::StatusOverview.add(self, datasource: datasource, signals: invariants)
          end

          # 2. 1:1 segmentation matrix — every cell must be exactly 1.
          b.row('1:1 tenant↔resource segmentation') do
            Library::OneToOneSegmentationTable.add(self, datasource: datasource,
                                                   tenant_label: tenant_label, segments: segments)
          end

          # 3. Residency / compliance posture strip (optional).
          if residency
            r = residency.transform_keys(&:to_sym)
            b.row('Residency / compliance posture') do
              Library::ResidencyComplianceStrip.add(self, datasource: datasource,
                                                    posture_label: r.fetch(:posture_label),
                                                    groups: r.fetch(:groups),
                                                    violation_expr: r.fetch(:violation_expr),
                                                    warn: r.fetch(:warn, 1), crit: r.fetch(:crit, 1))
            end
          end

          b.build
        end

        def self.validate!(id:, datasource:, tenant_label:, segments:)
          raise ArgumentError, 'BlastRadiusIsolationBoard: id: required' if blank?(id)
          raise ArgumentError, 'BlastRadiusIsolationBoard: datasource: required' if blank?(datasource)
          raise ArgumentError, 'BlastRadiusIsolationBoard: tenant_label: required' if blank?(tenant_label)
          raise ArgumentError, 'BlastRadiusIsolationBoard: segments must be a non-empty Array' \
            unless segments.is_a?(::Array) && !segments.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
