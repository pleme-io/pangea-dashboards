# pangea-dashboards

> Backend-agnostic typed AST for observability dashboards. Author once,
> render to Grafana or Datadog.

Same pattern as `pangea-kubernetes` serving 8 cluster backends from one
typed Ruby surface — `pangea-dashboards` exposes typed AST nodes
(`Dashboard`, `Row`, `Panel`, `Query`, `Variable`, `Annotation`,
`Threshold`) that render to either Grafana (`grafana_dashboard.config_json`
via [pangea-grafana](../pangea-grafana)) or Datadog (`datadog_dashboard`
via [pangea-datadog](../pangea-datadog)).

## Why

| Problem | Solution |
|---|---|
| `grafana_dashboard.config_json` is a 5-10 KB minified JSON blob nobody can diff | Typed AST → readable Ruby DSL → renderer emits the JSON |
| Authoring a dashboard for both Grafana and Datadog means two parallel hand-written specs | Author once via the AST, render twice |
| Drift between `rio` (homelab → Grafana) and `plo` (SaaS → Datadog) dashboards | Shared dashboard library across clusters; the renderer handles backend differences |
| PromQL queries don't translate verbatim to Datadog | Explicit `dd_query:` override on `Query` nodes; renderer panics on un-translated PromQL → Datadog so authors can't ship broken |

## Usage

```ruby
require 'pangea-dashboards'

synth.extend(Pangea::Resources::Dashboards)

dash = synth.dashboard(:rio_lareira_services) do
  title 'rio · lareira services'
  uid   'rio-lareira-services'
  tags  %w[rio lareira homelab]
  refresh '30s'

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
        'sum by (pod) (rate(kube_pod_container_status_restarts_total[1h]))',
        datasource: 'vm', legend: '{{pod}}'
    end
  end

  row 'storage' do
    panel :pvc_used, kind: :gauge do
      title 'PVC used'
      unit '%'
      max 100
      query 'A',
        'kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes * 100',
        datasource: 'vm'
      threshold steps: [
        { color: 'green',  value: 0  },
        { color: 'yellow', value: 75 },
        { color: 'red',    value: 90 }
      ]
    end
  end
end

# Render to Grafana — emits a grafana_dashboard resource
synth.render_dashboard(dash, backend: :grafana, folder: 'rio')

# Render to Datadog — emits a datadog_dashboard resource
synth.render_dashboard(dash, backend: :datadog)
```

## AST shape

```
Dashboard
├── id, title, uid, description, tags, refresh, time, timezone
├── variables[]   Variable    (query | constant | custom | datasource | textbox | interval)
├── annotations[] Annotation
└── rows[]        Row
    ├── title, collapsed
    └── panels[]  Panel
        ├── id, kind, title, description, unit, min, max, decimals, width, height
        ├── queries[]   Query (ref, expr, datasource_uid, legend_format, instant, dd_query, hide)
        └── thresholds  ThresholdConfig (mode, steps[])
```

`Panel.kind` is one of `:stat`, `:timeseries`, `:gauge`, `:table`,
`:heatmap`, `:text`, `:pie`. Both renderers cover all kinds; the table
in [docs/panel-mapping.md](docs/panel-mapping.md) shows what each
becomes on each backend.

## Renderers

```
lib/pangea/dashboards/render/
├── grafana.rb    AST → Grafana JSON model (Schema v39, current as of 2026-04)
└── datadog.rb    AST → Datadog widgets[]  (compatible with datadog_dashboard)
```

Both produce a `Hash` that gets serialized to the respective Terraform
resource. The Grafana renderer reuses `Pangea::Grafana::DashboardBuilder`
where possible to share JSON-model knowledge with the parent gem.

## See also

- [pangea-grafana](../pangea-grafana) — Grafana Terraform resource layer (`grafana_dashboard`, `grafana_folder`, `grafana_data_source`)
- [pangea-datadog](../pangea-datadog) — Datadog Terraform resource layer
- [pleme-io/k8s/clusters/rio/OBSERVABILITY.md](../k8s/clusters/rio/OBSERVABILITY.md) — official pleme-io homelab observability stack
- [blackmatter-pleme/skills/observability/SKILL.md](../blackmatter-pleme/skills/observability/SKILL.md) — the authoritative pattern
