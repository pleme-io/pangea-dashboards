# frozen_string_literal: true

module Pangea
  module Dashboards
    module Library
      # Pre-cooked panels for any Kubernetes-pod-shaped workload.
      #
      # Mix in via Ruby's normal mechanism — the helpers are class-level
      # methods that accept a RowBuilder (so they can be invoked inside
      # `row 'pods' do ... end` blocks on a DashboardBuilder).
      #
      # Usage in an architecture's monitor template:
      #
      #   monitor do |result, opts|
      #     row 'pods' do
      #       Pangea::Dashboards::Library::KubernetesPodPanels.add_all(
      #         self,
      #         namespace: result[:namespace],
      #         deployment: result[:deployment_name],
      #         datasource: opts.fetch(:datasource_uid, 'vm')
      #       )
      #     end
      #   end
      #
      # Helpers default to the canonical PromQL queries against
      # `kube-state-metrics` + `cadvisor` exporters; override
      # `datasource:` per call if multiple metric stores are in play.
      # Every helper accepts a `dd_query:` kwarg too so the same library
      # call works against the Datadog renderer.
      module KubernetesPodPanels
        # Convenience: emit every canonical pod panel at once.
        def self.add_all(row, namespace:, deployment: nil, pod_regex: nil, datasource: 'vm')
          add_count(row, namespace: namespace, deployment: deployment, pod_regex: pod_regex, datasource: datasource)
          add_cpu(row, namespace: namespace, deployment: deployment, pod_regex: pod_regex, datasource: datasource)
          add_memory(row, namespace: namespace, deployment: deployment, pod_regex: pod_regex, datasource: datasource)
          add_restarts(row, namespace: namespace, deployment: deployment, pod_regex: pod_regex, datasource: datasource)
        end

        # Pod count — one stat panel.
        def self.add_count(row, namespace:, deployment: nil, pod_regex: nil, datasource: 'vm')
          selector = label_selector(namespace: namespace, deployment: deployment, pod_regex: pod_regex)
          dd_sel   = dd_selector(namespace: namespace, deployment: deployment)
          row.panel :pod_count, kind: :stat do
            title 'Pods'
            query 'A', %(count(kube_pod_info{#{selector}})), datasource: datasource,
                  dd_query: %(count_not_null(avg:kubernetes.pods.running{#{dd_sel}}))
          end
        end

        # Per-pod CPU usage — timeseries.
        def self.add_cpu(row, namespace:, deployment: nil, pod_regex: nil, datasource: 'vm')
          selector = label_selector(namespace: namespace, deployment: deployment, pod_regex: pod_regex)
          dd_sel   = dd_selector(namespace: namespace, deployment: deployment)
          row.panel :pod_cpu, kind: :timeseries do
            title 'Pod CPU'
            unit 'percent'
            query 'A',
                  %(sum by (pod) (rate(container_cpu_usage_seconds_total{#{selector}}[5m])) * 100),
                  datasource: datasource, legend: '{{pod}}',
                  dd_query: %(sum:kubernetes.cpu.usage.total{#{dd_sel}} by {pod_name})
          end
        end

        # Per-pod memory — timeseries.
        def self.add_memory(row, namespace:, deployment: nil, pod_regex: nil, datasource: 'vm')
          selector = label_selector(namespace: namespace, deployment: deployment, pod_regex: pod_regex)
          dd_sel   = dd_selector(namespace: namespace, deployment: deployment)
          row.panel :pod_memory, kind: :timeseries do
            title 'Pod memory'
            unit 'bytes'
            query 'A',
                  %(sum by (pod) (container_memory_working_set_bytes{#{selector}})),
                  datasource: datasource, legend: '{{pod}}',
                  dd_query: %(sum:kubernetes.memory.working_set{#{dd_sel}} by {pod_name})
          end
        end

        # Pod restart rate over the last hour — stat.
        def self.add_restarts(row, namespace:, deployment: nil, pod_regex: nil, datasource: 'vm')
          selector = label_selector(namespace: namespace, deployment: deployment, pod_regex: pod_regex)
          dd_sel   = dd_selector(namespace: namespace, deployment: deployment)
          row.panel :pod_restarts, kind: :stat do
            title 'Restarts (1h)'
            query 'A',
                  %(sum(increase(kube_pod_container_status_restarts_total{#{selector}}[1h]))),
                  datasource: datasource,
                  dd_query: %(sum:kubernetes.containers.restarts{#{dd_sel}}.as_count())
            threshold steps: [
              { color: 'green',  value: nil },
              { color: 'yellow', value: 3 },
              { color: 'red',    value: 10 }
            ]
          end
        end

        # ── selector helpers ────────────────────────────────────────────

        def self.label_selector(namespace:, deployment: nil, pod_regex: nil)
          parts = [%(namespace="#{namespace}")]
          parts << %(label_app_kubernetes_io_name="#{deployment}") if deployment
          parts << %(pod=~"#{pod_regex}") if pod_regex
          parts.join(',')
        end

        def self.dd_selector(namespace:, deployment: nil)
          parts = ["kube_namespace:#{namespace}"]
          parts << "kube_deployment:#{deployment}" if deployment
          parts.join(',')
        end
      end
    end
  end
end
