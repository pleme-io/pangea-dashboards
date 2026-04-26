# rio observability — end-to-end example

Demonstrates pangea-dashboards driving the canonical pleme-io homelab
observability stack (Vector → VictoriaMetrics → Grafana, vmalert →
Alertmanager → ntfy) for the rio cluster.

## What's here

- `render.rb` — declares 3 dashboards + 1 alert group via the typed DSL,
  renders to Grafana JSON, Datadog widgets, ConfigMap YAML (FluxCD-deployable),
  VMRule YAML, and PrometheusRule YAML.
- `output/` — committed rendered artifacts so readers can see input + output
  side-by-side without having to run anything.

## Run it

```sh
bundle exec ruby examples/rio_observability/render.rb
```

Regenerates everything under `output/`.

## What gets emitted

```
output/
├── grafana/
│   ├── rio-cluster-overview.json    # Grafana dashboard model v39
│   ├── rio-vector-pipeline.json
│   └── rio-vm-health.json
├── datadog/
│   ├── rio-cluster-overview.json    # Datadog widget JSON (parity render)
│   ├── rio-vector-pipeline.json
│   └── rio-vm-health.json
├── configmaps/
│   ├── rio-cluster-overview.yaml    # ConfigMap wrapping Grafana JSON,
│   ├── rio-vector-pipeline.yaml     # FluxCD-deployable to rio cluster
│   └── rio-vm-health.yaml           # (label: grafana_dashboard=1)
└── alerts/
    ├── vmrule.yaml                   # VictoriaMetrics operator VMRule
    └── prometheusrule.yaml           # PrometheusRule (portable variant)
```

## How rio consumes this

The ConfigMap YAMLs land in the FluxCD tree at:

```
clusters/rio/infrastructure/grafana-dashboards/
├── kustomization.yaml
├── rio-cluster-overview.yaml         # (this file from output/configmaps/)
├── rio-vector-pipeline.yaml
└── rio-vm-health.yaml
```

The vm-k8s-stack Grafana picks them up via dashboard provider config
(static volume mount, NOT the sidecar — sidecar is disabled per the
official observability spec).

The VMRule lands at:

```
clusters/rio/infrastructure/alertmanager-ntfy/rio-observability.yaml
```

vmalert evaluates the rules and fires through the existing
VMAlertmanagerConfig → ntfy webhook routing tree (rio-critical /
rio-warning / rio-info topics).

## DSL surface used

| Feature | Where |
|---|---|
| `synth.dashboard(:id) do ... end` | All 3 dashboards |
| `Library::KubernetesPodPanels.add_all` | rio_cluster_overview |
| Variables (`variable :ns, kind: :query`) | rio_cluster_overview |
| Multi-row + multi-panel | All |
| Threshold steps | rio_cluster_overview, rio_vm_health |
| Explicit `dd_query:` overrides on PromQL | All queries (parity) |
| `synth.alerts(:id) do ... end` | rio_observability_alerts |
| Severity-based routing (critical/warning) | All 3 alert groups |

## Adding a new dashboard

1. Open `render.rb`, add a new `synth.dashboard(:new_id) do ... end` block.
2. Append it to the iteration list at the bottom.
3. Re-run the script.
4. Copy `output/configmaps/new_id.yaml` to
   `clusters/rio/infrastructure/grafana-dashboards/`.
5. Add the file to `kustomization.yaml`.
6. FluxCD reconciles and the dashboard appears in Grafana.
