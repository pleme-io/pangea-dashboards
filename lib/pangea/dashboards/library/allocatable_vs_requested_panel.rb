# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The capacity-headroom panel: a single :timeseries plotting cluster
      # ALLOCATABLE against the sum of pod REQUESTS for one compute resource
      # (cpu | memory), so the gap between the two lines IS the schedulable
      # headroom. The eye reads "are we about to run out of room to schedule?"
      # at a glance — the requested line creeping toward allocatable is the
      # warning, no number-reading required.
      #
      #   A = sum(kube_node_status_allocatable{resource="<r>"})   (the ceiling)
      #   B = sum(kube_pod_container_resource_requests{resource="<r>"}) (the floor)
      #
      # Absorbed from kubernetes_cluster.rb's cpu_alloc_vs_req + mem_alloc_vs_req
      # — two near-identical hand-written panels collapsed into ONE typed,
      # resource-parameterised primitive (solve-once, per the prime directive).
      # Both series are :continuous (allocatable + requests are always-present
      # gauges, never event-driven counters) so no zero-floor is needed.
      #
      # ── Why unit defaults by resource ───────────────────────────────────
      # cpu allocatable/requests are core-counts → Grafana 'short'; memory is
      # bytes → 'bytes' (so 8589934592 renders as 8 GiB, not a wall of digits).
      # The author may override unit: for an exotic extended resource.
      module AllocatableVsRequestedPanel
        ALLOCATABLE_METRIC = 'kube_node_status_allocatable'
        REQUESTS_METRIC    = 'kube_pod_container_resource_requests'

        # The two resources the upstream kube-state-metrics labels expose with
        # the matching default unit. cpu → core-count (short); memory → bytes.
        RESOURCE_UNITS = { cpu: 'short', memory: 'bytes' }.freeze

        # resource: :cpu (default) | :memory — selects the `resource=` matcher
        #           AND the default unit.
        # unit:     Grafana unit override (default short(cpu)/bytes(memory)).
        # title:    panel title override (default "<resource> allocatable vs requested").
        def self.add(row, datasource:, resource: :cpu, unit: nil, title: nil)
          validate!(datasource: datasource, resource: resource)
          res   = resource.to_sym
          u     = unit || RESOURCE_UNITS.fetch(res)
          ttl   = title || "#{res} allocatable vs requested"
          sel   = { resource: res.to_s }
          alloc = "sum(#{ALLOCATABLE_METRIC}#{Promql.braces(sel)})"
          req   = "sum(#{REQUESTS_METRIC}#{Promql.braces(sel)})"
          row.panel :"alloc_vs_req_#{slug(res)}", kind: :timeseries,
                    width: Theme.half, height: Theme::TS_H do
            title ttl
            unit u
            min 0
            graph :area
            query 'A', alloc, datasource: datasource, presence: :continuous, legend: 'allocatable'
            query 'B', req,   datasource: datasource, presence: :continuous, legend: 'requested'
          end
        end

        def self.validate!(datasource:, resource:)
          raise ArgumentError, 'AllocatableVsRequestedPanel: datasource: required' if blank?(datasource)
          raise ArgumentError,
                "AllocatableVsRequestedPanel: resource must be :cpu or :memory (got #{resource.inspect})" \
            unless RESOURCE_UNITS.key?(resource.to_s.to_sym)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :validate!, :blank?, :slug
      end
    end
  end
end
