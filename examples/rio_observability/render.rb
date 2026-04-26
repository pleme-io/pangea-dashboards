#!/usr/bin/env ruby
# frozen_string_literal: true

# rio observability — end-to-end pangea-dashboards example.
#
# Builds three canonical dashboards + one alert group for the rio
# cluster (Vector → VictoriaMetrics → Grafana stack) and renders them
# to:
#   * Grafana dashboard JSON (one file per dashboard)
#   * Datadog widget JSON (one file per dashboard, for migration parity)
#   * VMRule manifest YAML (alerts → vmalert)
#   * ConfigMap-wrapped Grafana JSON (FluxCD-deployable)
#
# Run:
#   ruby examples/rio_observability/render.rb
#
# Output lands at examples/rio_observability/output/ — gitignored.

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)

require 'pangea-dashboards'
require 'fileutils'
require 'json'
require 'yaml'

# ── shared synth ────────────────────────────────────────────────────────
class FleetSynth
  include Pangea::Resources::Dashboards
  include Pangea::Resources::Alerts

  def initialize
    @grafana = []
    @datadog = []
    @alert_manifests = []
    @alert_resources = []
  end

  attr_reader :grafana, :datadog, :alert_manifests, :alert_resources

  def grafana_dashboard(rid, attrs)
    @grafana << { rid: rid, attrs: attrs }
  end

  def datadog_dashboard(rid, attrs)
    @datadog << { rid: rid, attrs: attrs }
  end

  def kubernetes_manifest(rid, attrs)
    @alert_manifests << { rid: rid, attrs: attrs }
  end

  def datadog_monitor(rid, attrs)
    @alert_resources << { rid: rid, attrs: attrs }
  end
end

synth = FleetSynth.new

# ── 1. Cluster overview dashboard ───────────────────────────────────────
overview = synth.dashboard(:rio_cluster_overview) do
  title 'rio · cluster overview'
  uid   'rio-cluster-overview'
  tags  'rio', 'cluster', 'overview'
  refresh '30s'

  variable :namespace, kind: :query,
           datasource: 'vm',
           query: 'label_values(kube_pod_info, namespace)',
           multi: true, include_all: true

  row 'pods' do
    Pangea::Dashboards::Library::KubernetesPodPanels.add_all(self,
      namespace: '$namespace', datasource: 'vm')
  end

  row 'nodes' do
    panel :node_count, kind: :stat do
      title 'Nodes'
      query 'A', 'count(kube_node_info)', datasource: 'vm',
            dd_query: 'count_not_null(avg:kubernetes_state.node.count{*})'
    end

    panel :node_ready, kind: :stat do
      title 'Ready'
      query 'A',
            'count(kube_node_status_condition{condition="Ready",status="true"})',
            datasource: 'vm',
            dd_query: 'count_not_null(avg:kubernetes_state.node.ready{*})'
      threshold steps: [
        { color: 'red',   value: nil },
        { color: 'green', value: 1 }
      ]
    end
  end
end

# ── 2. Vector pipeline dashboard ────────────────────────────────────────
vector_pipeline = synth.dashboard(:rio_vector_pipeline) do
  title 'rio · vector pipeline'
  uid   'rio-vector-pipeline'
  tags  'rio', 'vector', 'ingest'

  row 'throughput' do
    panel :events_in, kind: :timeseries do
      title 'Events received (per source)'
      unit 'eps'
      query 'A',
            'sum by (component_id) (rate(vector_component_received_events_total[5m]))',
            datasource: 'vm', legend: '{{component_id}}',
            dd_query: 'sum:vector.component.received_events.total{*} by {component_id}.as_rate()'
    end

    panel :events_out, kind: :timeseries do
      title 'Events sent (per sink)'
      unit 'eps'
      query 'A',
            'sum by (component_id) (rate(vector_component_sent_events_total[5m]))',
            datasource: 'vm', legend: '{{component_id}}',
            dd_query: 'sum:vector.component.sent_events.total{*} by {component_id}.as_rate()'
    end
  end

  row 'errors' do
    panel :error_rate, kind: :timeseries do
      title 'Component errors'
      unit 'eps'
      query 'A',
            'sum by (component_id) (rate(vector_component_errors_total[5m]))',
            datasource: 'vm', legend: '{{component_id}}',
            dd_query: 'sum:vector.component.errors.total{*} by {component_id}.as_rate()'
    end

    panel :buffer_usage, kind: :timeseries do
      title 'Buffer usage (% of capacity)'
      unit 'percent'
      query 'A',
            '100 * (vector_buffer_byte_size / vector_buffer_max_byte_size)',
            datasource: 'vm', legend: '{{component_id}}',
            dd_query: '100 * (avg:vector.buffer.byte_size{*} by {component_id} / avg:vector.buffer.max_byte_size{*} by {component_id})'
    end
  end
end

# ── 3. VictoriaMetrics health dashboard ─────────────────────────────────
vm_health = synth.dashboard(:rio_vm_health) do
  title 'rio · victoria-metrics health'
  uid   'rio-vm-health'
  tags  'rio', 'victoria-metrics', 'storage'

  row 'ingestion' do
    panel :samples_in, kind: :timeseries do
      title 'Samples ingested per second'
      unit 'sps'
      query 'A',
            'sum(rate(vm_rows_inserted_total[5m]))',
            datasource: 'vm',
            dd_query: 'sum:victoriametrics.rows_inserted.total{*}.as_rate()'
    end

    panel :active_series, kind: :stat do
      title 'Active series'
      query 'A', 'sum(vm_cache_entries{type="storage/tsid"})',
            datasource: 'vm',
            dd_query: 'sum:victoriametrics.active_series{*}'
    end
  end

  row 'storage' do
    panel :disk_usage, kind: :stat do
      title 'Disk usage'
      unit 'bytes'
      query 'A',
            'vm_data_size_bytes',
            datasource: 'vm',
            dd_query: 'avg:victoriametrics.data.size_bytes{*}'
      threshold steps: [
        { color: 'green',  value: nil },
        { color: 'yellow', value: 25_000_000_000 }, # 25 GiB
        { color: 'red',    value: 28_000_000_000 }  # 28 GiB
      ]
    end

    panel :compaction, kind: :timeseries do
      title 'Compactions per minute'
      query 'A',
            'rate(vm_partial_merges_total[1m])',
            datasource: 'vm',
            dd_query: 'sum:victoriametrics.partial_merges.total{*}.as_rate()'
    end
  end
end

# ── 4. Alert rules — vmalert + ntfy via severity routing ────────────────
alerts = synth.alerts(:rio_observability_alerts) do
  namespace 'monitoring'
  labels(cluster: 'rio')

  group 'vector' do
    alert :vector_high_error_rate,
      expr: 'sum(rate(vector_component_errors_total[5m])) > 5',
      for: '5m', severity: 'warning',
      summary: 'Vector ingest pipeline errors elevated',
      description: 'Vector reporting >5 component errors/sec for 5m. Check vector pod logs.',
      runbook_url: 'https://runbooks.pleme.io/rio/vector-errors',
      dd_query: 'avg(last_5m):sum:vector.component.errors.total{*}.as_rate() > 5'
  end

  group 'storage' do
    alert :vm_disk_critical,
      expr: 'vm_data_size_bytes > 28 * 1024 * 1024 * 1024',  # 28 GiB
      for: '10m', severity: 'critical',
      summary: 'VictoriaMetrics disk near capacity',
      description: 'VMSingle data dir > 28 GiB (cap: 30 GiB). Retention may start dropping data.',
      runbook_url: 'https://runbooks.pleme.io/rio/vm-disk-full',
      dd_query: 'avg(last_10m):avg:victoriametrics.data.size_bytes{*} > 30064771072'
  end

  group 'cluster' do
    alert :pods_not_ready,
      expr: 'sum by (namespace) (kube_pod_status_ready{condition="false"}) > 0',
      for: '15m', severity: 'warning',
      summary: 'Pods not ready in {{ $labels.namespace }}',
      description: '{{ $value }} pods unready for 15m in {{ $labels.namespace }}.',
      runbook_url: 'https://runbooks.pleme.io/rio/pods-not-ready',
      dd_query: 'avg(last_15m):sum:kubernetes_state.pod.ready{condition:false} by {namespace} > 0'
  end
end

# ── render everything to disk ───────────────────────────────────────────
out_dir = File.expand_path('output', __dir__)
FileUtils.mkdir_p(File.join(out_dir, 'grafana'))
FileUtils.mkdir_p(File.join(out_dir, 'datadog'))
FileUtils.mkdir_p(File.join(out_dir, 'alerts'))
FileUtils.mkdir_p(File.join(out_dir, 'configmaps'))

[overview, vector_pipeline, vm_health].each do |dash|
  # Grafana JSON (raw)
  json = Pangea::Dashboards::Render::Grafana.render_json(dash)
  grafana_path = File.join(out_dir, 'grafana', "#{dash.uid}.json")
  File.write(grafana_path, JSON.pretty_generate(JSON.parse(json)))

  # Datadog widgets (raw)
  dd = Pangea::Dashboards::Render::Datadog.render(dash)
  datadog_path = File.join(out_dir, 'datadog', "#{dash.uid}.json")
  File.write(datadog_path, JSON.pretty_generate(dd))

  # ConfigMap wrapping the Grafana JSON — FluxCD-deployable
  cm = {
    'apiVersion' => 'v1',
    'kind' => 'ConfigMap',
    'metadata' => {
      'name' => "grafana-dashboard-#{dash.uid}",
      'namespace' => 'monitoring',
      'labels' => {
        'grafana_dashboard' => '1',
        'app.kubernetes.io/managed-by' => 'pangea-dashboards'
      }
    },
    'data' => {
      "#{dash.uid}.json" => json
    }
  }
  File.write(File.join(out_dir, 'configmaps', "#{dash.uid}.yaml"), cm.to_yaml)
end

# Alerts → VMRule manifest (rio uses the VictoriaMetrics operator)
vmrule = Pangea::Alerts::Render::Victoria.render(alerts)
File.write(File.join(out_dir, 'alerts', 'vmrule.yaml'), vmrule.to_yaml)

# Same alerts as PrometheusRule (for portability)
prom_rule = Pangea::Alerts::Render::Prometheus.render(alerts)
File.write(File.join(out_dir, 'alerts', 'prometheusrule.yaml'), prom_rule.to_yaml)

# ── summary ─────────────────────────────────────────────────────────────
puts "Rendered to #{out_dir}/:"
Dir.glob("#{out_dir}/**/*.{json,yaml}").sort.each do |f|
  size = File.size(f)
  puts "  #{f.sub("#{out_dir}/", '')}  (#{size} bytes)"
end
puts ""
puts "Dashboards: #{[overview, vector_pipeline, vm_health].size}"
puts "Alert groups: #{alerts.groups.size}"
puts "Alert rules: #{alerts.groups.sum { |g| g.rules.size }}"
