# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/health_matrix_table'
require 'pangea/dashboards/library/stat_strip'
require 'pangea/dashboards/library/tenant_class_split_row'

module Pangea
  module Dashboards
    module Library
      # THE TENANT HEALTH MATRIX — per-tenant golden signals laid out as one
      # N-row cell-coloured matrix (sortable by worst), beside a per-tenant
      # business-KPI strip and a shared-vs-dedicated class comparison. Where
      # FleetTopologyOverview maps cells, this maps TENANTS: the operator reads a
      # whole customer population's golden posture as a coloured grid, then the
      # KPI strip for the business read, then the structural shared/dedicated
      # contrast.
      #
      # The triage STORY, top-to-bottom:
      #
      #   Tenant defects  →  "is any tenant erroring right now?"
      #   Health matrix   →  per-tenant Rate · Error% · p99 (the golden grid)
      #   Business KPIs   →  per-tenant headline numbers (active / spend / SLA)
      #   Class split     →  shared pool vs dedicated cells, side by side
      #
      #   dash = Pangea::Dashboards::Library::TenantHealthMatrix.build(
      #     id: :tenant_health, name: 'Tenant Health', datasource: 'vm',
      #     tenant_label: 'tenant',
      #     rate_metric: 'http_requests_total',
      #     latency_metric: 'http_request_duration_seconds_bucket')
      module TenantHealthMatrix
        # id/name:         dashboard id + human title
        # datasource:      (req) the metrics datasource uid
        # tenant_label:    the per-tenant row key (default 'tenant')
        # rate_metric:     (req) the request *_total counter
        # latency_metric:  (req) the *_seconds_bucket histogram
        # error_code_regex: the error subset regex for rate_metric (default '5..')
        # window:          golden window (default 5m)
        # kpi_tiles:       optional Array of StatStrip tile Hashes (business KPIs)
        # class_label / shared_value / dedicated_value: the tenancy-class partition
        # include_class_split: emit the shared-vs-dedicated row (default true)
        def self.build(id:, datasource:, rate_metric:, latency_metric:, name: nil,
                       tenant_label: 'tenant', error_code_regex: '5..', window: '5m',
                       kpi_tiles: [], class_label: 'tenant_class',
                       shared_value: 'shared', dedicated_value: 'dedicated',
                       include_class_split: true)
          validate!(id: id, datasource: datasource, tenant_label: tenant_label,
                    rate_metric: rate_metric, latency_metric: latency_metric)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · tenant health")
          b.tags('pleme-io', 'tenant-health')

          # 1. Tenant defects headline.
          erroring = {
            name: 'Tenants erroring',
            expr: "count(sum#{Promql.by(tenant_label)}(rate(#{rate_metric}{code=~\"#{error_code_regex}\"}[#{window}])) > 0)",
            warn: 1, crit: 5,
            desc: 'Tenants with a nonzero error rate. Red ⇒ multiple customers affected.'
          }
          b.row('Status — tenants erroring') do
            Library::StatusOverview.add(self, datasource: datasource, signals: [erroring])
          end

          # 2. Health matrix — per-tenant golden signals as a coloured grid.
          cols = golden_columns(tenant_label: tenant_label, rate_metric: rate_metric,
                                latency_metric: latency_metric, error_code_regex: error_code_regex, window: window)
          b.row('Tenant golden-signals matrix') do
            Library::HealthMatrixTable.add(self, datasource: datasource, topology_label: tenant_label,
                                           columns: cols, title: "Golden signals by #{tenant_label}")
          end

          # 3. Business-KPI strip (optional, author-supplied).
          unless Array(kpi_tiles).empty?
            b.row('Business KPIs') do
              Library::StatStrip.add(self, datasource: datasource, tiles: kpi_tiles)
            end
          end

          # 4. Shared-vs-dedicated class comparison.
          if include_class_split
            split_expr = "sum(rate(#{rate_metric}{#{class_label}=\"%{class}\"}[#{window}]))"
            b.row('Shared vs dedicated') do
              Library::TenantClassSplitRow.add(self, datasource: datasource, class_label: class_label,
                                               shared_value: shared_value, dedicated_value: dedicated_value,
                                               measure_expr: split_expr, measure_unit: 'reqps',
                                               measure_title: 'Request rate', presence: :event_driven)
            end
          end

          b.build
        end

        # The canonical per-tenant golden columns: Rate · Error% · p99, each
        # aggregated by(tenant) and the error/latency columns cell-coloured.
        def self.golden_columns(tenant_label:, rate_metric:, latency_metric:, error_code_regex:, window:)
          total = "sum#{Promql.by(tenant_label)}(rate(#{rate_metric}[#{window}]))"
          errs  = "sum#{Promql.by(tenant_label)}(rate(#{rate_metric}{code=~\"#{error_code_regex}\"}[#{window}]))"
          p99   = "histogram_quantile(0.99, sum#{Promql.by([tenant_label, 'le'])}(rate(#{latency_metric}[#{window}])))"
          [
            { name: 'Rate',    unit: 'reqps', expr: total },
            { name: 'Error %', unit: 'percent', warn: 1, crit: 5, expr: "100 * #{errs} / #{total}" },
            { name: 'p99 (s)', unit: 's', warn: 0.5, crit: 1, expr: p99 }
          ]
        end

        def self.validate!(id:, datasource:, tenant_label:, rate_metric:, latency_metric:)
          raise ArgumentError, 'TenantHealthMatrix: id: required' if blank?(id)
          raise ArgumentError, 'TenantHealthMatrix: datasource: required' if blank?(datasource)
          raise ArgumentError, 'TenantHealthMatrix: tenant_label: required' if blank?(tenant_label)
          raise ArgumentError, 'TenantHealthMatrix: rate_metric: required' if blank?(rate_metric)
          raise ArgumentError, 'TenantHealthMatrix: latency_metric: required' if blank?(latency_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :golden_columns, :validate!, :blank?
      end
    end
  end
end
