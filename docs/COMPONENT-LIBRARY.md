# The Pangea-Ruby dashboard component library

A comprehensive, type-strict, reusable set of `Pangea::Dashboards::Library::*`
components, absorbed from every recurring dashboard/observability shape across
**pleme-io**, **akeylesslabs**, and **akeyless-community**. Each component is a
class-method module that takes a `RowBuilder` (or `DashboardBuilder`) + typed
keyword args and emits typed panels — so authoring a dashboard is *configuring
components*, never re-assembling panels by hand.

> **One sentence:** every observability question the three codebases ask — RED,
> USE, SLO/burn-rate, latency tail, saturation, top-N, per-tenant breakdown,
> controller-runtime health, homeostatic carving bands, rate-limited quotas,
> log routing — maps to exactly one component (or an existing helper), at a
> named **(layer, tier)** coordinate.

## Two axes

**LAYER** (vertical composition, smallest → largest — the Theme.rb
Status→Presence→Golden→Detail→Logs story):

| Layer | Emits | Example |
|---|---|---|
| `primitive-panel` | ONE `Types::Panel` into a row | `LatencyHistogramPanel`, `UtilSetpointBand` |
| `composite-row` | a coherent ROW telling one sub-story | `GoldenSignalsRow` (RED), `SaturationRow` (USE) |
| `overview-strip` | the defects-first headline tiles / signals | `StatStrip`, `AtCeilingDefectTile` (signal) |
| `full-dashboard-mixin` | a whole `Types::Dashboard` in one call | `WorkloadOverview` (keystone), `ControllerRuntimeDashboard` |

**TIER** (the domain the component speaks to — an absorbed use-case bucket):
`infra` (host/disk/OS) · `platform` (k8s/controllers/GitOps/autoscalers — the
densest) · `app` (per-service RED, Go runtime) · `data` (db/replication/cache/
queue) · `business` (SLO/error-budget/cost — the promise layer) · `saas`
(rate-limited consumers, multi-tenant) · `security` (log routing/SIEM, posture).

## The shared substrate (consume, never hardcode)

Every component is *pure additive composition* over the already-shipped
substrate — no renderer change, no new panel kind:

- **`Theme`** — the design system: `tile_width(n)`, `defect_steps(warn:,crit:)`,
  `liveness_steps(ok:)`, `full/half/third/two_thirds`, `STAT_H/TS_H/TABLE_H`,
  palette `OK/WARN/CRIT/NEUTRAL/MUTED`. Widths, heights, thresholds come from here.
- **`Library::Floor.zero(expr)`** — the shared `or vector(0)` primitive (so an
  event-driven counter reads a true 0, not "No data"). Idempotent; skips `absent()`.
- **`Library::Promql`** — the typed PromQL fragment builder: a selector Hash
  picks `=` vs `=~` by Ruby value type (String→exact, Regexp/Array→regex);
  `by()`, `sum_rate`, `sum_increase`, `histogram_quantile`. Queries are built
  through here, not ad-hoc string concat (the typed-emission discipline).
- **`Health`** — the runtime publish gate; every query carries a `presence:`
  (`:continuous`/`:event_driven`/`:conditional`) so Health keeps gating.
- **`Datasource`** — the typed `uid → query_lang` registry; `datasource:` is
  threaded through so a PromQL-vs-LogsQL mismatch stays unrepresentable.

## How to consume

**Inside a Monitorable architecture** (the common case — `self` is the builder):

```ruby
module Pangea::Architectures::Payments
  extend Pangea::Architectures::Monitorable
  monitor do |result, opts|
    ds = opts.fetch(:datasource_uid, 'vm')
    Pangea::Dashboards::Library::WorkloadOverview.compose(self,
      name: 'payments', datasource: ds, logs_datasource: 'vlogs',
      jobs: %w[payments], namespace: 'payments', stream: '{namespace="payments"}',
      rate_metric: 'http_requests_total',
      latency_metric: 'http_request_duration_seconds_bucket',
      group_by: %w[route], error_selector: { code: '5..' },
      signals: [
        { name: 'Pods not ready', expr: 'count(kube_pod_status_ready{namespace="payments",condition="false"})', warn: 1, crit: 1 },
        { name: '5xx /s', expr: 'sum(rate(http_requests_total{namespace="payments",code=~"5.."}[5m]))', warn: 0.1 },
      ])
  end
end
```

**Standalone** (a workspace one-off): `WorkloadOverview.build(id:, name:, …)`
returns a complete `Types::Dashboard`. **A single row**: call any
`composite-row`/`overview-strip` component inside a `row '…' do … end` block.

## The catalog (31 components)

✅ = all 31 shipped (+ `Floor`/`Promql` shared primitives + a self-describing `Catalog`). Full interfaces + absorbed-from notes
live in each component's module-doc header.

| | Component | Layer | Tier | Pri | What it does |
|---|---|---|---|---|---|
| ✅ | `CapacityHeadroomStat` | primitive panel | infra | P2 | A :stat with area sparkline + liveness thresholds (red below floor→orange→g… |
| ✅ | `AllocatableVsRequestedPanel` | primitive panel | platform | P2 | A two-series allocatable-vs-requested capacity-headroom timeseries for cpu|… |
| ✅ | `FailedResourcesTable` | primitive panel | platform | P1 | An instant :table over `sum by(entity,ns)(failed_metric) > 0` with green/re… |
| ✅ | `FloorCeilingEnvelope` | primitive panel | platform | P1 | Emit ONE timeseries plotting current_limit riding inside [floor,ceiling] |
| ✅ | `LatencyHistogramPanel` | primitive panel | platform | P0 | Emit ONE timeseries of histogram_quantile over a *_seconds_bucket metric fo… |
| ✅ | `RateWithZeroFloor` | primitive panel | platform | P0 | A rate panel/tile that always renders (appends `or vector(0)` via the share… |
| ✅ | `TopNTable` | primitive panel | platform | P0 | An instant :table over `topk(N, agg by(labels)(<fn>(metric[window])))` |
| ✅ | `UtilSetpointBand` | primitive panel | platform | P1 | Emit ONE timeseries plotting a util_ratio series against an overlaid setpoi… |
| ✅ | `WebhookLatencyHeatmap` | primitive panel | platform | P2 | A :heatmap over a *_latency_seconds_bucket histogram for admission/webhook … |
| ✅ | `GoProcessUseRow` | composite row | app | P1 | USE-style Go-runtime resource row: CPU (kernel+user), go_goroutines (satura… |
| ✅ | `SloBurnRateRow` | composite row | business | P1 | GREENFIELD GAP-FILLER |
| ✅ | `RedComponentThroughputRow` | composite row | data | P2 | A pipeline RED row: received/s, sent/s, received-bytes/s, sent-bytes/s by c… |
| ✅ | `ReplicationHealthRow` | composite row | data | P1 | Replication-lag-vs-threshold + streaming-replicas + replicas-not-streaming … |
| ✅ | `SaturationRow` | composite row | infra | P0 | Emit a canonical USE row (Utilization-% timeseries min0/max100 + Saturation… |
| ✅ | `BuildInfoLiveness` | composite row | platform | P1 | A controller-up :stat (`max by(version)(build_info)`) + a matching absent()… |
| ✅ | `ByPhaseStrip` | composite row | platform | P2 | A `sum by(phase)(entity_by_phase)` stacked timeseries + a settled/ready :st… |
| ✅ | `ControllerRuntimeRow` | composite row | platform | P0 | Emit the full kubebuilder/controller-runtime golden-signals block (reconcil… |
| ✅ | `GoldenSignalsRow` | composite row | platform | P0 | Emit a canonical RED row (Rate-by-label timeseries + Errors timeseries as f… |
| ✅ | `PerNamespaceBreakdownRow` | composite row | platform | P1 | CPU/memory/restarts/pod-count by namespace with the cadvisor-path dedupe ba… |
| ✅ | `ShadowLivePostureRow` | composite row | platform | P2 | enrolled/live/shadow count :stats from a dry_run gauge |
| ✅ | `QuotaPctSambaRow` | composite row | saas | P1 | GREENFIELD GAP-FILLER |
| ✅ | `AtCeilingDefectTile` | overview strip | platform | P1 | A StatusOverview SIGNAL builder (not a panel) |
| ✅ | `AutoscalerPoolStrip` | overview strip | platform | P2 | A grid of pool-cardinality :gauge/:stat tiles (desired/idle/running/registe… |
| ✅ | `FluxReconcileStrip` | overview strip | platform | P2 | A gotk_reconcile_condition Ready-per-kind :stat strip + reconcile p99/rate … |
| ✅ | `RedSliGaugeStrip` | overview strip | platform | P1 | A horizontal row of error-rate :gauge tiles (one per labeled subsystem/obje… |
| ✅ | `StatStrip` | overview strip | platform | P1 | A general horizontal row of single-value :stat tiles each with threshold co… |
| ✅ | `Alerts::WorkloadBaseline` | full dashboard mixin | platform | P1 | Emit the 'every workload gets these' alert baseline through the EXISTING Al… |
| ✅ | `ControllerRuntimeDashboard` | full dashboard mixin | platform | P1 | Compose the full controller-runtime RED/SLI dashboard (RedSliGaugeStrip per… |
| ✅ | `LogExplorerDashboard` | full dashboard mixin | platform | P2 | A whole self-service log-explorer Types::Dashboard: a textbox $search varia… |
| ✅ | `WorkloadOverview` | full dashboard mixin | platform | P0 | THE KEYSTONE |
| ✅ | `Alerts::GatewayLogForwardingTarget` | full dashboard mixin | security | P2 | The one genuinely akeyless-authored observability primitive: a typed model … |

### Already-shipped helpers (not in the table — do not rebuild)

`StatusOverview` (defects-first tile row + the signal contract) · `DataPresence`
(scrape-health: up-table + targets-down + expected-present) · `LogWindows`
(full-log + ERROR window + error-rate over LogsQL) · `KubernetesPodPanels`
(count/cpu/memory/restarts) · `Derive` (metric-name introspection sweeps).

## Coverage — every absorbed use-case has a home

RED row → `GoldenSignalsRow`; USE row → `SaturationRow`; controller/operator
golden signals → `ControllerRuntimeRow` + `ControllerRuntimeDashboard`;
latency tail → `LatencyHistogramPanel` (+ `WebhookLatencyHeatmap` for bimodal);
top-N offenders → `TopNTable`; which-resource-is-broken → `FailedResourcesTable`;
per-tenant/namespace breakdown → `PerNamespaceBreakdownRow`; rate-with-floor →
`RateWithZeroFloor`; homeostatic carving bands (the breathe shape, generalized)
→ `UtilSetpointBand` + `FloorCeilingEnvelope` + `AtCeilingDefectTile`;
db/replication/cache → `ReplicationHealthRow`; Go-runtime internals →
`GoProcessUseRow`; pipeline throughput → `RedComponentThroughputRow`;
lifecycle/FSM phases → `ByPhaseStrip`; cluster capacity →
`AllocatableVsRequestedPanel` + `CapacityHeadroomStat`; shadow-vs-live rollout →
`ShadowLivePostureRow`; GitOps convergence → `FluxReconcileStrip`; autoscaler
pools (ARC/KEDA/Karpenter) → `AutoscalerPoolStrip`; liveness/version →
`BuildInfoLiveness`; per-subsystem SLI gauges → `RedSliGaugeStrip`; the generic
headline-numbers strip → `StatStrip`; self-service log exploration →
`LogExplorerDashboard`; default per-workload alerts → `Alerts::WorkloadBaseline`;
SIEM log routing → `Alerts::GatewayLogForwardingTarget`. **Two greenfield gaps**
(confirmed absent in all three orgs) filled: SLO/multi-window burn-rate →
`SloBurnRateRow`; samba/quotaPct rate-limited consumer → `QuotaPctSambaRow`.

## Build waves

- **Wave 0** (✅) — foundation primitives + shared `Floor`/`Promql`.
- **Wave 1** (✅) — canonical RED/USE composites + the `WorkloadOverview` keystone.
- **Wave 2** (✅) — homeostasis trio + attribution + liveness.
- **Wave 3** (✅) — the named greenfield gaps (`SloBurnRateRow`, `QuotaPctSambaRow`) + business/saas tiers.
- **Wave 4** (✅) — long-tail + security tier + the two capstone mixins
  (`ControllerRuntimeDashboard`, `LogExplorerDashboard`) + the self-describing
  `Catalog` and its matrix test (every `(layer, tier)` cell covered, every
  loaded component registered — drift unrepresentable). **Remaining:** the
  fleet-wide retrofit replacing the hand-written panels in the 8 Monitorable
  architectures with these library calls.

> Provenance: the catalog was synthesized by a parallel absorption sweep over
> pleme-io + akeylesslabs + akeyless-community (4 agents, 3 codebases). The
> taxonomy + per-component interfaces + this build plan are the synthesis output.
