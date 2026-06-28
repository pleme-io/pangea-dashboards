# Enjulho Dashboard Pattern Catalog — Secrets-Platform · Audit/Security · Fleet · Pipeline · Infra/Cost

> GENERIC, reusable `pangea-dashboards` Library pattern catalog (the "borealis"
> dashboard-as-code line). Every name, metric, selector, and example param here
> is **generic** — applicable to any consumer of a secrets/gateway platform, a
> multi-cell SaaS fleet, an observability tap pipeline, or a managed-datastore /
> cost tier. No consumer-specific tenant, account, host, or metric names appear.
> A consumer fills concrete values into params via a `PangeaDashboard` CRD.

---

## 0. Pattern philosophy — enjulho dashboards

An **enjulho dashboard** is never hand-authored JSON. It is a `PangeaDashboard`
CRD whose `spec.source.inline.ruby` calls
`Pangea::Architectures::GrafanaDashboardWorkspace.render_json(architecture:, params:, folder:)`
against a `Pangea::Dashboards::Library::*` **full-dashboard mixin**. The
pangea-operator `DashboardController` compiles the inline Ruby → Grafana JSON →
a sidecar-labelled ConfigMap → the target Grafana. One values-list entry flows
end to end; drift between code and catalog is unrepresentable (every Library
component carries a `Catalog::ENTRY` + a `spec/library/*_spec.rb` row, gated by
the catalog matrix test).

Three design lenses, all encoded in `Theme`:

- **Defects-first.** Every board opens with a colour-flooded `StatusOverview` /
  `StatStrip` headline: "is anything wrong right now?" is answered
  *preattentively* — the operator finds the red tile, never parses a grid.
  Signal tiles are built from typed `{ name:, expr:, warn:, crit:, desc: }`
  hashes (the `AtCeilingDefectTile.signal` pattern); the strip decides the
  colour flood.
- **RED** (Rate · Errors · Duration) for request-shaped tiers — `GoldenSignalsRow`
  and its specialisations.
- **USE** (Utilization · Saturation · Errors) for resource-shaped tiers —
  `SaturationRow`, `SaturationGridPanel`, the homeostasis band components.

Composition order in nearly every mixin: **presence → defects headline →
golden/USE body → domain rows → logs**, i.e. `DataPresence` → `StatusOverview`
→ (RED/USE) → domain-specific rows → `LogWindows`.

### What already ships vs what this catalog adds (tier-honest)

| State | Components |
|---|---|
| **Shipped full-dashboard mixins** (in `KNOWN_ARCHITECTURES`) | `WorkloadOverview`, `ControllerRuntimeDashboard`, `LogExplorerDashboard` |
| **Shipped catalog mixins, not yet in KNOWN_ARCHITECTURES** | `Alerts::WorkloadBaseline`, `Alerts::GatewayLogForwardingTarget` |
| **Shipped building blocks** (reused, not reinvented) | `StatusOverview`, `StatStrip`, `DataPresence`, `GoldenSignalsRow`, `SaturationRow`, `ReplicationHealthRow`, `RedSliGaugeStrip`, `RedComponentThroughputRow`, `TopNTable`, `LogWindows`, `AtCeilingDefectTile`, `ByPhaseStrip`, `WebhookLatencyHeatmap`, `QuotaPctSambaRow`, `SloBurnRateRow`, `AutoscalerPoolStrip`, `CapacityHeadroomStat`, `AllocatableVsRequestedPanel`, `ShadowLivePostureRow`, `UtilSetpointBand`, `FloorCeilingEnvelope`, `BreathabilityRow`, `RateWithZeroFloor`, `LatencyHistogramPanel`, `LogFacetTopN`-N/A, `Floor`, `Promql`, `Theme` |
| **NEW full-dashboard mixins this catalog adds** | 22 (the five domains below) |
| **NEW building blocks this catalog adds** | 42 composite-rows / overview-strips / primitive-panels / signal builders / DSL verbs |
| **Renderer extensions (additive, tier-honest gaps)** | panel `links:` (drill-down), `:geomap` panel kind, `:status_history`/`:state_timeline` panel kind, panel `repeat:` |

The current `PanelKind` set is `stat · timeseries · gauge · table · heatmap ·
text · pie`. Everything below is buildable on that set **today** via the typed
`options(grafana:)` fieldConfig escape hatch (the same seam `ByPhaseStrip` uses
for stacking) — except four explicitly flagged renderer-side gaps.

---

## 1. Domain — Secrets-platform / gateway ops

The control-plane of any secrets-management / gateway product. Headline is
**security-defects-first** (denials, signing failures, overdue rotations,
config-version skew, cache-cold, throttle pressure); the golden path is a
**verb-partitioned secret-ops RED**; the story threads auth → crypto → rotation
→ cache → gateway-sync → rate-limit.

### Mixins

| Mixin | Tier | Generic signal class read | Story |
|---|---|---|---|
| `SecretsPlatformOverview` | security | secrets-platform gateway `/metrics` | **keystone**: presence → security-defects headline → secret-ops golden → auth SLI → cache → rate-limit → gateway-sync → logs |
| `SecretOpsGoldenSignals` | saas | Prometheus-annotated app/microservice `/metrics` | secret data-plane RED: defects → per-verb RED matrix → latency heatmap → SLO burn → quota pressure → top failing ops/callers → logs |
| `AuthMethodHealth` | security | gateway `/metrics` (auth-method usage) | trust boundary: denial defects → per-method failure SLI → allowed/denied/error outcomes → auth-latency tail → top denied identities → logs |
| `RotationLifecycle` | security | gateway `/metrics` (producers/rotators) | dynamic-secret lifecycle: overdue/failure defects → rotation RED → producer phase distribution → staleness heatmap → top-overdue producers → logs |
| `GatewaySyncReplication` | security | gateway `/metrics` + k8s control-plane reconcile | fleet config-convergence: sync-lag + version-skew + cache-cold defects → sync/replication health → per-version posture → cache effectiveness → sync RED → logs |

### Common params (all five)

`id:` (Symbol), `name:`, `datasource:` (Prometheus/VM uid), `selector:` (label
matcher hash, e.g. `{ service: "gateway", env: "$env" }`), `metric_names:`
(hash overriding generic defaults), `folder:`. Verb/op lists, auth-method label,
result label, producer label, cache hits/misses/evictions metric names are
per-mixin kwargs.

### New building blocks

- **`SecretOpsGoldenMatrixRow`** (composite_row, saas) — verb-partitioned RED
  matrix: per operation verb (`get`/`create`/`rotate`/`list`/…) emit per-verb
  rate (stacked, the `ByPhaseStrip` partition encoding), a denial/error leg
  filtered by the result label, and the shared p99 latency tail. Loops
  `RateWithZeroFloor` + `LatencyHistogramPanel`. Generic over any
  `*_operation_total{op=…,result=…}` + `*_op_seconds_bucket`. Generalises
  `GoldenSignalsRow` to "one RED column per operation kind".
- **`AuthOutcomesRow`** (composite_row, security) — trust-boundary row: stacked
  allowed/denied/error timeseries by auth method (outcomes partition the total
  via the typed grafana stacking override) + one per-method denial-rate gauge
  (`RedSliGaugeStrip` over the outcome label). Generic over
  `*_auth_total{method=…,outcome=…}`.
- **`CacheEffectivenessRow`** (composite_row, data) — cache USE: hit-ratio
  liveness % (`liveness_steps`, higher healthier) + miss-rate + eviction-rate
  (`RateWithZeroFloor`) + a cold-cache defect stat. Generic over any cache
  exposing hits/misses/evictions.
- **`OverdueDefectTile.signal`** (overview_strip signal builder, security) —
  sibling of `AtCeilingDefectTile.signal`: typed `StatusOverview` hash for
  `count((elapsed_since >= configured_interval))` via the `and on(identity)`
  intersection. RED ⇒ N entities past their own configured deadline. Reusable
  for rotation-overdue, cert-near-expiry, token-TTL-exceeded.
- **`VersionSkewDefectTile.signal`** (overview_strip signal builder, platform) —
  typed `StatusOverview` hash for `count(applied_version != max(applied_version))`
  across a fleet: how many members lag the newest config/version. Generic
  GitOps/gateway-fleet skew.

Reuse: `SecretsPlatformOverview`/`GatewaySyncReplication` reuse
`ReplicationHealthRow` for sync-lag (`lag_metric`=sync lag,
`streaming_metric`=synced-member count); `RotationLifecycle` reuses
`WebhookLatencyHeatmap` as a staleness `*_bucket` heatmap and `ByPhaseStrip` for
producer state; all reuse `StatusOverview`/`DataPresence`/`LogWindows`/
`QuotaPctSambaRow`/`SloBurnRateRow`/`TopNTable`.

---

## 2. Domain — Audit & security

Log-first (LogsQL facets) + horizon/age-first (time-to-expiry), opening on a
defect wall. Reads only generic signal classes: **audit-event object-store/log
signals** (append-only who/what/when/result, keyed by `actor`/`operation`/
`result`/`target`/`source_ip`/`tenant`), **gateway `/metrics`** (auth, signing,
rate-limit, producer), **cloud access/WAF logs + metric streams**,
**security-posture signals** (`*_expiry_timestamp_seconds`, `*_age_seconds`,
policy-violation counts, compliance pass/total), and **the tap layer's own
security-pipeline meta-health**.

### Mixins

| Mixin | Tier | Story |
|---|---|---|
| `AuditExplorer` | security | headline strip → result breakdown → who/what/where facets → who/what/when/result table → raw log windows |
| `AccessAnomalyBoard` | security | anomaly defect wall → failed-auth RED → off-hours heatmap → geo/source facets → brute-force table |
| `SecurityPostureBoard` | security | posture defect wall → compliance-score strip → expiry-horizon table → age-vs-max-age row → policy-violation breakdown |
| `SecuritySignalWall` | security | the **defect tile wall** — worst-of from all three boards + the audit-pipeline's own health; each tile drill-links to its specialised dashboard |

### New building blocks

- **`LogFacetTopN`** (primitive_panel, security) — LogsQL cousin of `TopNTable`:
  `{stream} | stats by (field) count() N | sort by (N) desc | limit n` → instant
  `:table`. Top-N by any audit log field.
- **`AuditEventRow`** (composite_row, security) — who/what/when/result audit
  `:table` (scoped by dashboard variables + `$search`) beside a
  `stats by (result)` stacked-bars timeseries.
- **`SuccessFailRatioGauge`** (overview_strip, security) — `:gauge`
  (`percentunit`, 0–1) reading `failed/(success+failed)` over a LogsQL
  `stats by (result)` split (or a metric pair); green→amber→red via
  `Theme.defect_steps`.
- **`TimeOfDayHeatmap`** (primitive_panel, security) — `:heatmap` of event count
  bucketed by hour-of-day × weekday → off-hours access (time anomaly).
- **`NewEntityWindowSignal`** (overview_strip signal builder, security) — typed
  `StatusOverview` hash for entities present this window but absent the prior
  window (set-difference: `count(present and ignoring() (… offset prior_window) == 0)`
  for metrics, or a two-window LogsQL diff). The generic new-actor / new-source /
  new-geo anomaly atom.
- **`FailedAuthRow`** (composite_row, security) — failed-auth rate timeseries +
  `SuccessFailRatioGauge` + a distinct-failing-actors `:stat`.
- **`SecurityPostureSignals`** (overview_strip signal builders, security) —
  `expiring_within(metric, horizon)`, `older_than(age_metric, max_age)`,
  `past_rotation_sla(...)`, `open_violations(metric, severity)` → typed
  `StatusOverview` hashes.
- **`ExpiryHorizonTable`** (primitive_panel, security) — instant `:table` over
  `sort(*_expiry_timestamp_seconds - time())` with horizon thresholds
  (red <7d, amber <30d) for certs/secrets/tokens.
- **`AgeVsThresholdRow`** (composite_row, security) — generalises
  `FloorCeilingEnvelope` to rotation: a series riding 0 → hard max-age ceiling +
  a count-over-threshold defect.
- **`ComplianceScoreStrip`** (overview_strip, business→security) —
  `controls_passing/controls_total` %, controls-failing, controls-in-grace,
  last-attestation-age (the Viggy provable-outcomes promise as a headline).
- **`SecurityEventPipelineHealthRow`** (composite_row, security) — the
  audit/security tap's own meta-health: shipper queue depth/lag, dropped-audit
  counters, ingestion rate (nervous-system-dashboards-itself, scoped to the
  security pipeline — a silent audit gap is itself a visible defect).
- **Panel drill-links** (additive DSL verb + Grafana renderer mapping) —
  `PanelBuilder` currently has no `links:` field; `SecuritySignalWall` tiles need
  a `link`/`links` verb to jump to a specialised board. **Renderer-side gap.**

---

## 3. Domain — Tenant & fleet health matrix

The first family whose unit of composition is a **population partitioned by a
topology label** (cell / region / cloud / tenant / environment / tenant-class).
Every mixin aggregates `by(<topology label>)`, renders one tile/row per member,
adds cross-member worst-N ranking, and a fleet→cell→workload→logs drill cascade.
The single-entity mixins (`WorkloadOverview` etc.) are the *leaves* of that
cascade.

### Mixins

| Mixin | Tier | Story |
|---|---|---|
| `FleetTopologyOverview` | platform | fleet map: per-cell health grid (membership from a topology label) + cloud/region/class rollups + worst-N cells, click-through to each cell's `WorkloadOverview` |
| `TenantHealthMatrix` | platform | per-tenant golden signals as an N-row cell-coloured matrix sortable by worst + per-tenant business-KPI strip + shared-vs-dedicated class comparison |
| `SlaAvailabilityBoard` | business | fleet error-budget wall: per-member budget-remaining strip + per-member × multi-window burn matrix + availability-over-time heatmap from synthetic probes |
| `BlastRadiusIsolationBoard` | security | posture/theorem board: sealed-isolation invariants as defects-that-must-be-zero + 1:1 tenant↔resource segmentation matrix + residency/compliance posture strip |
| `FleetTriageDrilldownBoard` | platform | drill-down trunk: `$cloud→$region→$tenant→$cell` variable cascade scoping headline → worst-N → golden → logs, fleet to workload in one pane |

### New building blocks

- **`CellStatusGrid`** (overview_strip) — grid of health-coloured `:stat` tiles,
  one per cell/member, membership derived from a topology label (hand-listed /
  `label_values`-partitioned today; `repeat:` form is a renderer gap; a true
  geo-map variant needs a `:geomap` panel kind). The grid-heatmap of fleet
  health.
- **`HealthMatrixTable`** (composite_row) — **category-defining**: multi-column
  per-entity `:table` (row = tenant/cell, column = golden signal) with
  per-column threshold cell-colouring + sort-by-worst, via the typed
  `options(grafana:)` fieldConfig seam. Generalises `TopNTable` from
  single-metric topk to an N-column health matrix.
- **`ErrorBudgetBurnStrip`** (overview_strip) — per-member error-budget-remaining
  gauges + a burn sparkline, worst-first; the fleet generalisation of
  `SloBurnRateRow`.
- **`BurnRateMatrix`** (composite_row) — per-member × multi-window (1h/6h/24h/72h)
  burn-rate colour-coded table; `HealthMatrixTable` specialised to burn windows
  with the canonical >1 amber / >14.4 red multi-burn thresholds.
- **`WorstNFocusRow`** (composite_row) — topk worst-members table + the worst
  members' golden small-multiples; composes `TopNTable` + a per-member golden
  mini.
- **`FleetDrilldownVariables`** (meta helper) — declares the cascading
  `$cloud→$region→$tenant→$cell` template variables via chained `label_values()`
  queries (supported today) + per-tile data-link drill-down (the data link needs
  the additive panel `links:` field).
- **`OneToOneSegmentationTable`** (composite_row) — tenant × resource
  distinct-count `:table` proving exactly-one cluster / account / IaC-state-key /
  secret-store per tenant; the sealed-isolation invariant as a green wall (any
  count ≠ 1 cell-colours red).
- **`ResidencyComplianceStrip`** (overview_strip) — cells/tenants grouped by a
  residency/compliance-posture label, posture-defect colour-coded.
- **`TenantClassSplitRow`** (composite_row) — two-class comparison: vendor-shared
  vs customer-dedicated golden signals / cell counts side by side.
- **`AvailabilityHeatmap`** (primitive_panel) — per-member availability over time
  as one coloured lane per member; wants a `:status_history`/`:state_timeline`
  panel kind (**renderer gap**); today approximated by `:heatmap` / stacked
  `:timeseries` via `options()`.

---

## 4. Domain — Tendril nervous-system + breathe homeostasis (meta-observability)

The dashboards the observability plane points **at itself**. Generic signal
classes: an N-stage data pipeline (tap → broker → consumer → store), a
resource-homeostasis controller holding a band fleet at a setpoint, and a
scale-to-zero workload fleet. Every metric name is a **param** (the generic
homeostasis primitive's own exported names are natural defaults).

### Mixins

| Mixin | Tier | Reads | One-line |
|---|---|---|---|
| `PipelineFlowOverview` | platform/data | pipeline stage throughput + broker depth/lag + autoscale + drops | the nervous system end-to-end: tap → broker → consumers → store |
| `HomeostasisControlBoard` | platform | homeostatic-controller band signals (util/setpoint/floor/ceiling/used; carve/defer; dry-run; staleness; capacity) | the whole band fleet across every dimension, in-band-ness as a heatmap |
| `ScaleToZeroEfficiencyBoard` | platform/business | scale-to-zero lifecycle (replica 0↔N, cold-start, time-at-rest, cost-at-rest) | the breathing rhythm — sleep when idle, wake fast, save money at rest |
| `NervousSystemSelfHealthBoard` | platform | meta roll-up (one headline strip per subsystem + forward-sink drops) | the single pane proving the observability plane is alive |

### New building blocks

- **`PipelineFlowStrip`** (overview_strip, infra) — horizontal strip, one tile
  per declared pipeline stage **in order**, each showing throughput with a
  **conservation ratio** (out/in) colouring — a leaky hop lights up. The
  nervous-system flow read left-to-right.
- **`BrokerStreamRow`** (composite_row, data) — queue depth + consumer lag
  (age-of-oldest/unacked) + ack-vs-redeliver + dropped, floored. Generalises
  NATS JetStream / Kafka / Redis Streams / SQS by metric injection.
- **`PipelineLagRow`** (composite_row, data) — per-hop lag + one end-to-end
  wall-clock lag (tap timestamp → store landing) + ingest-vs-egress conservation
  timeseries.
- **`BandDeviationHeatmap`** (primitive_panel, platform) — `:heatmap` of
  `abs(util - on(identity) setpoint)` across the band fleet over time; an
  out-of-band band is a hot row.
- **`DeviationRankTable`** (primitive_panel, platform) — `topk(N, abs(a - on(labels) b))`
  instant `:table`; the distance-ranking shape `TopNTable` cannot express
  (third-site extraction of the hand-written "furthest from setpoint" panel).
- **`WakeEventTimeline`** (composite_row, platform) — per-workload replica 0↔N
  step series + sleep/wake transition-rate overlay (step interpolation via the
  `options(grafana:)` escape hatch, degrades gracefully).
- **`SleepWakePostureRow`** (composite_row, platform) — asleep (`==0`) / awake
  (`>0`) / enrolled counts + time-at-rest %; the scale-to-zero analog of
  `ShadowLivePostureRow` (value-coloured posture, floored counts).
- **`CostAtRestRow`** (composite_row, business) — footprint at rest =
  `Σ replicas × unit_cost` vs an always-on baseline + a savings-% liveness stat.

Reuse: `HomeostasisControlBoard` reuses `UtilSetpointBand` / `FloorCeilingEnvelope`
/ `BreathabilityRow` / `ShadowLivePostureRow` / `AtCeilingDefectTile` per
dimension and `AutoscalerPoolStrip` / `CapacityHeadroomStat` /
`AllocatableVsRequestedPanel` for the node-pool stage; `PipelineFlowOverview`
reuses `RedComponentThroughputRow` per stage + `AutoscalerPoolStrip` for the
KEDA 0→N consumer scale; `NervousSystemSelfHealthBoard` reuses every other
mixin's overview strip.

---

## 5. Domain — Infra, datastore & cost/saturation

The lower-layer story every cell tells once the golden/workload layer is in
place: is the data tier healthy, is the control plane keeping up, where is
saturation, what is it all costing? Cost is a first-class saturation axis (spend
is meaningless without the utilisation it bought).

### Mixins

| Mixin | Tier | Story | Reads |
|---|---|---|---|
| `ManagedDatastoreOverview` | data | presence → status → USE saturation → query RED → replication → capacity headroom → slow-query logs, with an `engine:` switch (relational/cache/graph) | managed-datastore metrics (cloud-native channels or vendor exporter) |
| `K8sControlPlaneBoard` | infra | control-plane defects → apiserver RED → etcd health → scheduler → node pressure & allocatable-vs-requested → warning-event offenders → autoscaler activity | k8s control-plane + controller-runtime signals |
| `CostSaturationBoard` | business | budget headline → cost attribution by dimension → cost-efficiency (provisioned-$ vs used-$ vs wasted-$) → fleet capacity-headroom gauges → realized savings → right-sizing offenders | per-tenant business KPIs (derived cost rollups) |
| `FleetSaturationGrid` | infra | cross-cell defects-first USE grid: one saturation heatmap per resource (rows = cells) + per-cell worst-headroom gauges + hottest-cells offenders table | k8s control-plane + cloud-provider metric streams, per cell |

### New building blocks

- **`DatastoreQueryRow`** (composite_row, data) — datastore-shaped golden
  signals: QPS + query latency (gauge OR `histogram_quantile`, selected by a
  `latency_is_histogram` flag) + floored slow-query rate + floored error rate.
  The sibling of `GoldenSignalsRow` for stores exposing latency as a gauge
  (Performance-Insights style) not a `_bucket` histogram.
- **`EtcdHealthRow`** (composite_row, infra) — DB-size-vs-quota
  `FloorCeilingEnvelope` + fsync/commit-latency `:heatmap` + floored
  leader-change + proposal-failure rates.
- **`NodePressureStrip`** (overview_strip, infra) — per-condition node-count
  defect tiles (MemoryPressure / DiskPressure / PIDPressure / NotReady) from one
  condition metric + a condition list, coloured by `defect_steps`.
- **`CostEfficiencyRow`** (composite_row, business) — provisioned-$ vs used-$ vs
  wasted-$ overlaid on one timeseries + an allocation-efficiency `:gauge`
  (used/provisioned).
- **`SavingsRealizedStrip`** (overview_strip, business) — realized-savings tiles
  (spot vs on-demand-equivalent, scale-to-zero, commitment coverage) +
  spot-interruption rate; liveness-coloured.
- **`CostAttributionRow`** (composite_row, business) — stacked $-over-time by an
  attribution label (tenant/team/service) + a top-N spenders `:table` (delegates
  to `TopNTable`).
- **`SaturationGridPanel`** (primitive_panel, infra) — cross-cell `:table`/
  `:heatmap` of saturation per (cell, resource): rows = cells grouped by
  cloud/region/tenant, colour = saturation vs `defect_steps`. The fleet-scale
  "which cell is hot?" instant-snapshot counterpart of `SaturationRow`.

Reuse: `StatusOverview`/`StatStrip` (defects), `SaturationRow` (USE),
`ReplicationHealthRow` (relational standby), `CapacityHeadroomStat`,
`AllocatableVsRequestedPanel`, `AutoscalerPoolStrip`, `TopNTable`,
`GoldenSignalsRow` (apiserver RED), `LogWindows`, `AtCeilingDefectTile`.

---

## 6. KNOWN_ARCHITECTURES registration list

Add each new mixin's name → Library constant to
`pangea-architectures/lib/pangea/architectures/grafana_dashboard_workspace.rb`'s
`KNOWN_ARCHITECTURES` map (an architecture not in the map is rejected — a typo
can never silently render empty):

```ruby
KNOWN_ARCHITECTURES = {
  # shipped
  'WorkloadOverview'           => 'WorkloadOverview',
  'ControllerRuntimeDashboard' => 'ControllerRuntimeDashboard',
  'LogExplorerDashboard'       => 'LogExplorerDashboard',
  # domain 1 — secrets-platform / gateway ops
  'SecretsPlatformOverview'    => 'SecretsPlatformOverview',
  'SecretOpsGoldenSignals'     => 'SecretOpsGoldenSignals',
  'AuthMethodHealth'           => 'AuthMethodHealth',
  'RotationLifecycle'          => 'RotationLifecycle',
  'GatewaySyncReplication'     => 'GatewaySyncReplication',
  # domain 2 — audit & security
  'AuditExplorer'              => 'AuditExplorer',
  'AccessAnomalyBoard'         => 'AccessAnomalyBoard',
  'SecurityPostureBoard'       => 'SecurityPostureBoard',
  'SecuritySignalWall'         => 'SecuritySignalWall',
  # domain 3 — tenant & fleet health matrix
  'FleetTopologyOverview'      => 'FleetTopologyOverview',
  'TenantHealthMatrix'         => 'TenantHealthMatrix',
  'SlaAvailabilityBoard'       => 'SlaAvailabilityBoard',
  'BlastRadiusIsolationBoard'  => 'BlastRadiusIsolationBoard',
  'FleetTriageDrilldownBoard'  => 'FleetTriageDrilldownBoard',
  # domain 4 — tendril nervous-system + breathe homeostasis
  'PipelineFlowOverview'       => 'PipelineFlowOverview',
  'HomeostasisControlBoard'    => 'HomeostasisControlBoard',
  'ScaleToZeroEfficiencyBoard' => 'ScaleToZeroEfficiencyBoard',
  'NervousSystemSelfHealthBoard'=> 'NervousSystemSelfHealthBoard',
  # domain 5 — infra, datastore & cost/saturation
  'ManagedDatastoreOverview'   => 'ManagedDatastoreOverview',
  'K8sControlPlaneBoard'       => 'K8sControlPlaneBoard',
  'CostSaturationBoard'        => 'CostSaturationBoard',
  'FleetSaturationGrid'        => 'FleetSaturationGrid'
}.freeze
```

22 new full-dashboard mixins. Each also lands:
`lib/pangea/dashboards/library/<snake>.rb` (a module with
`self.build(id:, name:, datasource:, …) -> Types::Dashboard` + `validate!`), a
`require` in `library.rb`, a `Catalog::ENTRY` (`layer: :full_dashboard_mixin`,
its tier), and a `spec/library/<snake>_spec.rb` asserting emitted PromQL/LogsQL
+ panel shape. New composite-rows/strips/panels each get their own catalog entry
at the right `(layer, tier)` cell; the catalog matrix test fails if any is
registered without a loadable module.

---

## 7. Generic `PangeaDashboard` / lookouts.yaml declaration examples

A lookout chart (the central + per-cell observability portal pattern) ships the
pangea-dashboards subchart; each dashboard is one entry in a values list →
`PangeaDashboard` CRD → operator compile. Generic examples (placeholder values):

```yaml
# values.yaml of a lookout HelmRelease — generic, no consumer specifics
pangeaDashboards:
  dashboards:
    - name: secrets-platform-overview
      folder: "Platform"
      architecture: SecretsPlatformOverview
      params:
        id: cell_secrets_overview
        name: "Secrets Platform — <cell>"
        datasource: "victoriametrics"
        selector: { env: "$env", cell: "$cell" }
        verbs: ["get", "create", "rotate", "list", "delete"]
        result_label: "result"
        cache: { hits: "cache_hits_total", misses: "cache_misses_total", evictions: "cache_evictions_total" }

    - name: fleet-topology
      folder: "Fleet"
      architecture: FleetTopologyOverview
      params:
        id: fleet_topology
        name: "Fleet Topology"
        datasource: "victoriametrics"
        topology_label: "cell"
        rollup_labels: ["cloud", "region", "tenant_class"]
        worst_n: 8

    - name: audit-explorer
      folder: "Security"
      architecture: AuditExplorer
      params:
        id: audit_explorer
        name: "Audit Explorer — <cell>"
        datasource: "victorialogs"
        stream: '{stream="audit"}'
        facets: ["actor", "operation", "result", "target", "source_ip"]

    - name: pipeline-flow
      folder: "Meta"
      architecture: PipelineFlowOverview
      params:
        id: pipeline_flow
        name: "Tap Pipeline Flow"
        datasource: "victoriametrics"
        stages: ["tap", "broker", "consumer", "store"]
        broker: { depth: "broker_pending", lag: "broker_consumer_lag_seconds" }
```

The corresponding compiled CRD shape (operator-owned):

```yaml
apiVersion: pangea.pleme.io/v1alpha1
kind: PangeaDashboard
metadata: { name: secrets-platform-overview }
spec:
  folder: "Platform"
  source:
    inline:
      ruby: |
        require 'pangea-dashboards'
        require 'pangea/architectures/grafana_dashboard_workspace'
        Pangea::Architectures::GrafanaDashboardWorkspace.render_json(
          architecture: "SecretsPlatformOverview",
          params: { id: :cell_secrets_overview, name: "Secrets Platform", datasource: "victoriametrics", ... },
          folder: "Platform")
```

---

## 8. Tap-class → dashboard-pattern mapping

Generic tap classes (what a tap layer can ingest) → which mixin renders them:

| Generic tap class | Primary mixin(s) | Building blocks |
|---|---|---|
| In-cluster log shipper (container/pod logs) | `LogExplorerDashboard` (shipped), `AuditExplorer` | `LogWindows`, `LogFacetTopN`, `AuditEventRow` |
| Prometheus-annotated app/microservice `/metrics` | `SecretOpsGoldenSignals`, `WorkloadOverview` (shipped) | `SecretOpsGoldenMatrixRow`, `GoldenSignalsRow`, `LatencyHistogramPanel` |
| Secrets/gateway product `/metrics` (auth, signing, rotation, cache, sync) | `SecretsPlatformOverview`, `AuthMethodHealth`, `RotationLifecycle`, `GatewaySyncReplication` | `AuthOutcomesRow`, `CacheEffectivenessRow`, `OverdueDefectTile`, `VersionSkewDefectTile` |
| Audit-event object-store / log stream | `AuditExplorer`, `AccessAnomalyBoard` | `AuditEventRow`, `LogFacetTopN`, `TimeOfDayHeatmap`, `NewEntityWindowSignal`, `SuccessFailRatioGauge` |
| Cloud access / WAF logs + LB metric streams | `AccessAnomalyBoard` | `FailedAuthRow`, `LogFacetTopN`, `TimeOfDayHeatmap` |
| Security-posture signals (expiry/age/policy/compliance) | `SecurityPostureBoard`, `SecuritySignalWall` | `SecurityPostureSignals`, `ExpiryHorizonTable`, `AgeVsThresholdRow`, `ComplianceScoreStrip` |
| Managed datastore metrics (relational/cache/graph) | `ManagedDatastoreOverview` | `DatastoreQueryRow`, `ReplicationHealthRow`, `SaturationRow`, `CapacityHeadroomStat` |
| K8s control-plane + controller-runtime | `K8sControlPlaneBoard`, `ControllerRuntimeDashboard` (shipped) | `EtcdHealthRow`, `NodePressureStrip`, `AllocatableVsRequestedPanel`, `GoldenSignalsRow` |
| Multi-cell topology aggregate (cell/region/cloud/tenant) | `FleetTopologyOverview`, `TenantHealthMatrix`, `FleetTriageDrilldownBoard`, `FleetSaturationGrid` | `CellStatusGrid`, `HealthMatrixTable`, `WorstNFocusRow`, `SaturationGridPanel`, `FleetDrilldownVariables` |
| Synthetic uptime probe / SLA | `SlaAvailabilityBoard` | `ErrorBudgetBurnStrip`, `BurnRateMatrix`, `AvailabilityHeatmap` |
| Isolation / segmentation / residency posture | `BlastRadiusIsolationBoard` | `OneToOneSegmentationTable`, `ResidencyComplianceStrip`, `TenantClassSplitRow` |
| Per-tenant business KPI / cost rollups | `CostSaturationBoard`, `TenantHealthMatrix` | `CostEfficiencyRow`, `CostAttributionRow`, `SavingsRealizedStrip` |
| Broker (NATS/Kafka/Redis Streams/SQS) | `PipelineFlowOverview` | `BrokerStreamRow`, `PipelineLagRow`, `PipelineFlowStrip` |
| Homeostasis controller (band fleet) | `HomeostasisControlBoard` | `BandDeviationHeatmap`, `DeviationRankTable`, `UtilSetpointBand`, `BreathabilityRow` |
| Scale-to-zero workload fleet | `ScaleToZeroEfficiencyBoard` | `WakeEventTimeline`, `SleepWakePostureRow`, `CostAtRestRow`, `AutoscalerPoolStrip` |
| Tap pipeline's own meta-health | `NervousSystemSelfHealthBoard`, `SecuritySignalWall` | `SecurityEventPipelineHealthRow`, `PipelineFlowStrip` |

---

## 9. Renderer-side gaps (tier-honest, additive)

Each is additive to `PanelBuilder` / `Render::Grafana`, never blocking — the
buildable-today form ships first:

1. **Panel `links:`** — drill-down data links (needed by `SecuritySignalWall`,
   `CellStatusGrid` tiles, `FleetDrilldownVariables`). Today: template-variable
   cascade only.
2. **`:geomap` panel kind** — true geo map of cells (`CellStatusGrid` geo
   variant). Today: grid-heatmap form.
3. **`:status_history` / `:state_timeline` panel kind** — per-member availability
   lanes (`AvailabilityHeatmap`). Today: `:heatmap` / stacked `:timeseries`.
4. **Panel `repeat:`** — dynamic per-member tile grid. Today: hand-listed /
   `label_values`-partitioned tiles.

