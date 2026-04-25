# frozen_string_literal: true

require 'pangea-dashboards'

RSpec.configure do |c|
  c.expect_with :rspec do |e|
    e.syntax = :expect
  end
end

# Build a small canonical dashboard reused across renderer specs.
def canonical_dashboard
  builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :canary)
  builder.instance_eval do
    title 'canary'
    uid   'canary'
    tags  'rio', 'test'
    refresh '30s'
    time from: 'now-1h', to: 'now'

    variable :namespace, kind: :query, datasource_uid: 'vm',
             query: 'label_values(kube_pod_info, namespace)',
             multi: true, include_all: true

    row 'overview' do
      panel :pod_count, kind: :stat do
        title 'Pods'
        query 'A', 'count(kube_pod_info{namespace=~"$namespace"})', datasource: 'vm'
        threshold steps: [
          { color: 'green',  value: nil },
          { color: 'yellow', value: 20 },
          { color: 'red',    value: 50 }
        ]
      end

      panel :restarts_1h, kind: :timeseries do
        title 'Restarts (1h)'
        query 'A',
              'rate(kube_pod_container_status_restarts_total[1h])',
              datasource: 'vm', legend: '{{pod}}',
              dd_query: 'avg:kubernetes.containers.restarts{*}.as_rate()'
      end
    end

    row 'storage' do
      panel :pvc_used, kind: :gauge do
        title 'PVC used'
        unit '%'
        max 100
        query 'A', 'kubelet_volume_stats_used_bytes', datasource: 'vm',
              dd_query: 'avg:kubernetes.kubelet.volume.stats.used_bytes{*}'
        threshold steps: [
          { color: 'green',  value: 0  },
          { color: 'yellow', value: 75 },
          { color: 'red',    value: 90 }
        ]
      end
    end
  end
  builder.build
end
