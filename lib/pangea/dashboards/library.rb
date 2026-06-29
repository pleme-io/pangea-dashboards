# frozen_string_literal: true

# ── shared primitives (consumed by the components below) ────────────────
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

# ── existing concrete helpers ───────────────────────────────────────────
require 'pangea/dashboards/library/kubernetes_pod_panels'
require 'pangea/dashboards/library/derive'
require 'pangea/dashboards/library/log_windows'
require 'pangea/dashboards/library/data_presence'
require 'pangea/dashboards/library/status_overview'

# ── Wave 0: foundation primitive panels (P0 atoms) ──────────────────────
require 'pangea/dashboards/library/rate_with_zero_floor'
require 'pangea/dashboards/library/latency_histogram_panel'
require 'pangea/dashboards/library/top_n_table'
require 'pangea/dashboards/library/failed_resources_table'

# ── Wave 1: canonical composite rows + the keystone mixin (P0) ───────────
require 'pangea/dashboards/library/golden_signals_row'
require 'pangea/dashboards/library/saturation_row'
require 'pangea/dashboards/library/controller_runtime_row'
require 'pangea/dashboards/library/workload_overview'

# ── Wave 2: homeostasis trio + attribution + liveness (P1/P2) ───────────
require 'pangea/dashboards/library/util_setpoint_band'
require 'pangea/dashboards/library/floor_ceiling_envelope'
require 'pangea/dashboards/library/at_ceiling_defect_tile'
require 'pangea/dashboards/library/per_namespace_breakdown_row'
require 'pangea/dashboards/library/build_info_liveness'
require 'pangea/dashboards/library/stat_strip'
require 'pangea/dashboards/library/red_sli_gauge_strip'
require 'pangea/dashboards/library/replication_health_row'
require 'pangea/dashboards/library/go_process_use_row'
require 'pangea/dashboards/library/by_phase_strip'
require 'pangea/dashboards/library/allocatable_vs_requested_panel'
require 'pangea/dashboards/library/capacity_headroom_stat'
require 'pangea/dashboards/library/shadow_live_posture_row'
require 'pangea/dashboards/library/breathability_row'

# ── Wave 3/4: greenfield gaps + long-tail + security tier (P1/P2) ───────
require 'pangea/dashboards/library/flux_reconcile_strip'
require 'pangea/dashboards/library/webhook_latency_heatmap'
require 'pangea/dashboards/library/red_component_throughput_row'
require 'pangea/dashboards/library/autoscaler_pool_strip'
require 'pangea/dashboards/library/slo_burn_rate_row'
require 'pangea/dashboards/library/quota_pct_samba_row'
require 'pangea/dashboards/library/alerts/workload_baseline'
require 'pangea/dashboards/library/alerts/gateway_log_forwarding_target'

# ── Wave 5: enjulho catalog — homeostasis/meta blocks (T-LIVE tier) ──────
require 'pangea/dashboards/library/band_deviation_heatmap'
require 'pangea/dashboards/library/deviation_rank_table'

# ── Wave 4 capstones: the full-dashboard mixins (compose the above) ──────
require 'pangea/dashboards/library/controller_runtime_dashboard'
require 'pangea/dashboards/library/log_explorer_dashboard'
require 'pangea/dashboards/library/homeostasis_control_board'

# ── the self-describing catalog (loaded last; sees every component) ──────
require 'pangea/dashboards/library/catalog'

module Pangea
  module Dashboards
    # Reusable panel collections that any architecture's `monitor` block
    # can `extend` to splat in canonical panels without re-authoring
    # them. Each module exposes class-level helpers that take a
    # PanelBuilder context (or are designed to be called inside a `row`
    # block on the DashboardBuilder).
    module Library
    end
  end
end
