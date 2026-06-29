# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/golden_signals_row'
require 'pangea/dashboards/library/etcd_health_row'
require 'pangea/dashboards/library/node_pressure_strip'
require 'pangea/dashboards/library/allocatable_vs_requested_panel'
require 'pangea/dashboards/library/autoscaler_pool_strip'
require 'pangea/dashboards/library/top_n_table'

module Pangea
  module Dashboards
    module Library
      # The one-call operator dashboard for a Kubernetes CONTROL PLANE +
      # node-fleet capacity. The lower-layer story under the workload layer:
      #
      #   Control-plane defects  →  apiserver RED  →  etcd health  →  scheduler
      #   →  node pressure & allocatable-vs-requested  →  warning-event offenders
      #   →  autoscaler activity
      #
      # ── Managed-control-plane honesty ───────────────────────────────────
      # On EKS/GKE/AKS the apiserver, etcd, and scheduler metrics are ABSENT (the
      # provider owns them). The board is built so those rows simply render "No
      # data" — which is itself a true read ("not yours to see") — never a build
      # failure. The node-pressure + allocatable-vs-requested rows (from
      # kube-state-metrics, which IS present on every cluster) carry the board on
      # a managed plane. Each control-plane row is opt-in via its metric kwargs;
      # passing them on a managed plane is harmless (the row renders empty).
      #
      #   dash = Pangea::Dashboards::Library::K8sControlPlaneBoard.build(
      #     id: :rio_control_plane, name: 'rio', datasource: 'vm',
      #     apiserver_rate_metric: 'apiserver_request_total',
      #     apiserver_latency_metric: 'apiserver_request_duration_seconds_bucket',
      #     etcd_db_size_metric: 'etcd_mvcc_db_total_size_in_bytes',
      #     etcd_db_quota_metric: 'etcd_server_quota_backend_bytes')
      module K8sControlPlaneBoard
        # id/name:                    dashboard id + human title
        # datasource:                 (req) the metrics datasource uid
        # signals:                    extra StatusOverview defect signals (the
        #                             headline; merged after any built-ins)
        # apiserver_rate_metric/apiserver_latency_metric: apiserver RED (both
        #                             needed to render the row; absent on managed)
        # apiserver_error_selector:   the apiserver error subset (default code 5xx)
        # etcd_db_size_metric/etcd_db_quota_metric + etcd_*: etcd health row
        #                             (size+quota needed; rest optional)
        # scheduler_latency_metric:   scheduling-latency histogram (optional)
        # node_condition_metric:      kube-state node-condition family (node
        #                             pressure strip — always rendered)
        # node_conditions:            the conditions to surface (default canonical)
        # selector:                   typed Hash matcher scoping nodes/cells
        # autoscaler_pool_roles:      Hash{role=>expr} for the autoscaler strip
        #                             (optional)
        # warning_event_metric:       kube-state warning-event counter → top-N
        #                             offenders (optional)
        def self.build(id:, datasource:, name: nil, signals: [],
                       apiserver_rate_metric: nil, apiserver_latency_metric: nil,
                       apiserver_error_selector: { code: '5..' }, apiserver_group_by: %w[verb],
                       etcd_db_size_metric: nil, etcd_db_quota_metric: nil,
                       etcd_fsync_bucket_metric: nil, etcd_leader_changes_metric: nil,
                       etcd_proposal_failures_metric: nil,
                       scheduler_latency_metric: nil,
                       node_condition_metric: 'kube_node_status_condition',
                       node_conditions: Library::NodePressureStrip::DEFAULT_CONDITIONS,
                       selector: nil, autoscaler_pool_roles: nil,
                       warning_event_metric: nil, window: '15m')
          validate!(id: id, datasource: datasource)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · control plane")
          b.tags('pleme-io', 'k8s-control-plane')

          # 1. Control-plane defects headline.
          unless Array(signals).empty?
            b.row('Status — control-plane defects') do
              Library::StatusOverview.add(self, datasource: datasource, signals: signals)
            end
          end

          # 2. apiserver RED (absent on managed → "No data").
          if apiserver_rate_metric && apiserver_latency_metric
            b.row('apiserver — golden signals') do
              Library::GoldenSignalsRow.add(self, datasource: datasource,
                                            rate_metric: apiserver_rate_metric,
                                            latency_metric: apiserver_latency_metric,
                                            error_selector: apiserver_error_selector,
                                            group_by: apiserver_group_by, window: '5m')
            end
          end

          # 3. etcd health (absent on managed → "No data").
          if etcd_db_size_metric && etcd_db_quota_metric
            b.row('etcd — control-plane datastore') do
              Library::EtcdHealthRow.add(self, datasource: datasource,
                                         db_size_metric: etcd_db_size_metric,
                                         db_quota_metric: etcd_db_quota_metric,
                                         fsync_bucket_metric: etcd_fsync_bucket_metric,
                                         leader_changes_metric: etcd_leader_changes_metric,
                                         proposal_failures_metric: etcd_proposal_failures_metric,
                                         selector: selector)
            end
          end

          # 4. scheduler latency (absent on managed → "No data").
          if scheduler_latency_metric
            sched_expr = Promql.histogram_quantile(quantile: 0.99, bucket_metric: scheduler_latency_metric,
                                                   window: '5m', selector: selector)
            b.row('scheduler — scheduling latency p99') do
              panel :scheduler_latency_p99, kind: :timeseries, width: Theme.full, height: Theme::TS_H do
                title 'scheduling latency p99'
                unit 's'
                min 0
                graph :area
                query 'A', sched_expr, datasource: datasource, presence: :continuous, legend: 'p99'
              end
            end
          end

          # 5. Node pressure (always — kube-state is present everywhere).
          b.row('Node pressure') do
            Library::NodePressureStrip.add(self, datasource: datasource,
                                           condition_metric: node_condition_metric,
                                           conditions: node_conditions, selector: selector)
          end

          # 6. Allocatable vs requested (always — schedulable headroom).
          b.row('Capacity — allocatable vs requested') do
            Library::AllocatableVsRequestedPanel.add(self, datasource: datasource, resource: :cpu)
            Library::AllocatableVsRequestedPanel.add(self, datasource: datasource, resource: :memory)
          end

          # 7. Warning-event offenders (optional).
          if warning_event_metric
            b.row('Warning events — top offenders') do
              Library::TopNTable.add(self, datasource: datasource, metric: warning_event_metric,
                                     group_by: %w[namespace reason], agg: :increase, n: 10,
                                     window: window, title: 'Top warning-event sources')
            end
          end

          # 8. Autoscaler activity (optional).
          if autoscaler_pool_roles
            b.row('Autoscaler — node/pod pool activity') do
              Library::AutoscalerPoolStrip.add(self, datasource: datasource, pool_roles: autoscaler_pool_roles)
            end
          end

          b.build
        end

        def self.validate!(id:, datasource:)
          raise ArgumentError, 'K8sControlPlaneBoard: id: required' if blank?(id)
          raise ArgumentError, 'K8sControlPlaneBoard: datasource: required' if blank?(datasource)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
