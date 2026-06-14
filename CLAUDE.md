# pangea-dashboards

Backend-agnostic typed dashboard AST + Grafana / Datadog renderers.

## What this gem is

The dashboard-authoring half of pleme-io's observability stack. Pairs
with `pangea-grafana` (which exposes the underlying
`grafana_dashboard` / `grafana_folder` / `grafana_data_source` Terraform
resources) and `pangea-datadog` (which exposes `datadog_dashboard`).
This gem sits **above** both and provides the typed AST + renderers
that translate one author-time declaration into either backend.

## Architecture

```
                  Author
                    │
                    ▼
           Pangea::Dashboards::DSL
                    │
                    ▼
    Pangea::Dashboards::Types::Dashboard  (AST)
            │            │
            ▼            ▼
   Render::Grafana   Render::Datadog
            │            │
            ▼            ▼
  grafana_dashboard   datadog_dashboard
  (config_json)       (widget definitions)
            │            │
            ▼            ▼
  Terraform         Terraform
```

## File layout

```
lib/
├── pangea-dashboards.rb              entry: requires every other lib path
├── pangea-dashboards/version.rb      VERSION constant
└── pangea/
    ├── dashboards.rb                 Pangea::Dashboards module
    ├── dashboards/
    │   ├── types.rb                  every AST Dry::Struct
    │   ├── dsl.rb                    DashboardBuilder + RowBuilder + PanelBuilder
    │   └── render/
    │       ├── grafana.rb            AST → Grafana JSON
    │       └── datadog.rb            AST → Datadog widget hash
    └── resources/
        └── dashboards.rb             Pangea::Resources::Dashboards mixin
                                      → adds .dashboard / .render_dashboard to synth
```

## The component library — compose, don't re-author

`lib/pangea/dashboards/library/` is the comprehensive, type-strict, reusable
component set (`Pangea::Dashboards::Library::*`), absorbed from every recurring
dashboard shape across pleme-io + akeylesslabs + akeyless-community. **Authoring
a dashboard is configuring components, never re-assembling panels.** Full
catalog (two axes: `layer` × `tier`, 31 components), interfaces, and the
consume-from-a-`monitor`-block pattern: **[`docs/COMPONENT-LIBRARY.md`](./docs/COMPONENT-LIBRARY.md)**.

- `WorkloadOverview.build(…)` / `.compose(builder, …)` — THE KEYSTONE: a whole
  service dashboard (presence→status→golden→resources→logs) in one call.
- `GoldenSignalsRow` (RED) · `SaturationRow` (USE) · `ControllerRuntimeRow` /
  `ControllerRuntimeDashboard` (kubebuilder) · `SloBurnRateRow` (SLO burn) ·
  `LogExplorerDashboard` · plus the homeostasis/attribution/liveness/strip atoms.
- Shared primitives every component consumes: `Theme` (widths/heights/thresholds),
  `Library::Floor.zero` (`or vector(0)`), `Library::Promql` (typed PromQL).
- `Library::Catalog` is the **self-describing index** — `Catalog.by_tier('data')`,
  `Catalog.by_layer(:composite_row)`, `Catalog.coverage`. `spec/library/catalog_spec.rb`
  fails if a component isn't registered or a `(layer, tier)` cell is uncovered.

**Adding a component:** drop `lib/pangea/dashboards/library/<snake>.rb` (a
class-method module taking a RowBuilder + typed kwargs, consuming Theme/Promql/
Floor, with `validate!`), `require` it in `library.rb`, add a `Catalog::ENTRY`,
and a `spec/library/<snake>_spec.rb` asserting the emitted PromQL + panel shape.

## Adding a new panel kind

1. Add the kind to `Pangea::Dashboards::Types::PanelKind` enum (lib/pangea/dashboards/types.rb).
2. Implement the rendering in both `Render::Grafana#emit_panel` and `Render::Datadog#emit_panel`.
3. Snapshot test against canonical JSON in `spec/render/{grafana,datadog}_spec.rb`.

If a kind only makes sense on one backend, add a render-time guard
that raises `Pangea::Dashboards::UnsupportedBackendError` instead of
silently dropping.

## PromQL → Datadog query translation

Hard problem. Pragmatic approach:

- If a `Query` has `dd_query:` set explicitly, the Datadog renderer uses that.
- Otherwise, the Datadog renderer attempts a small pass-through: if `expr`
  contains no PromQL-only syntax (`histogram_quantile`, `rate(`, `irate(`,
  `sum by (` etc.) it's used as-is.
- If PromQL syntax is detected and no `dd_query:` is provided, the
  renderer raises `Pangea::Dashboards::UntranslatableQueryError` with a
  clear message. Authors can't ship broken Datadog dashboards by accident.

The intent is **explicit > clever**: rather than try to translate every
PromQL function to Datadog's query language and get it subtly wrong,
make the author state the Datadog query when the platforms diverge.

## Tests

```bash
bundle exec rake spec
```

Snapshot tests under `spec/render/{grafana,datadog}_spec.rb` capture
the canonical output of a representative dashboard against
`spec/fixtures/{grafana,datadog}_*.json`. Update fixtures intentionally
when changing the rendering shape.

## See also

- [pangea-grafana](../pangea-grafana) — Grafana Terraform resource layer
- [pangea-datadog](../pangea-datadog) — Datadog Terraform resource layer
- [pangea-kubernetes](../pangea-kubernetes) — sibling pattern (8 backends from one typed surface)
- [pleme-io/CLAUDE.md](../blackmatter-pleme/docs/pleme-io-CLAUDE.md) §"Official observability stack"
- [blackmatter-pleme/skills/observability/SKILL.md](../blackmatter-pleme/skills/observability/SKILL.md)
