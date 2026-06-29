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
# ── Wave 6: enjulho catalog buildout (5 domains) ────────────────────────
require 'pangea/dashboards/library/secrets_platform_overview'
require 'pangea/dashboards/library/secret_ops_golden_signals'
require 'pangea/dashboards/library/auth_method_health'
require 'pangea/dashboards/library/rotation_lifecycle'
require 'pangea/dashboards/library/gateway_sync_replication'
require 'pangea/dashboards/library/secret_ops_golden_matrix_row'
require 'pangea/dashboards/library/auth_outcomes_row'
require 'pangea/dashboards/library/cache_effectiveness_row'
require 'pangea/dashboards/library/overdue_defect_tile'
require 'pangea/dashboards/library/version_skew_defect_tile'
require 'pangea/dashboards/library/audit_explorer'
require 'pangea/dashboards/library/access_anomaly_board'
require 'pangea/dashboards/library/security_posture_board'
require 'pangea/dashboards/library/log_facet_topn'
require 'pangea/dashboards/library/audit_event_row'
require 'pangea/dashboards/library/success_fail_ratio_gauge'
require 'pangea/dashboards/library/time_of_day_heatmap'
require 'pangea/dashboards/library/new_entity_window_signal'
require 'pangea/dashboards/library/failed_auth_row'
require 'pangea/dashboards/library/security_posture_signals'
require 'pangea/dashboards/library/expiry_horizon_table'
require 'pangea/dashboards/library/age_vs_threshold_row'
require 'pangea/dashboards/library/compliance_score_strip'
require 'pangea/dashboards/library/security_event_pipeline_health_row'
require 'pangea/dashboards/library/fleet_topology_overview'
require 'pangea/dashboards/library/tenant_health_matrix'
require 'pangea/dashboards/library/sla_availability_board'
require 'pangea/dashboards/library/blast_radius_isolation_board'
require 'pangea/dashboards/library/fleet_triage_drilldown_board'
require 'pangea/dashboards/library/cell_status_grid'
require 'pangea/dashboards/library/health_matrix_table'
require 'pangea/dashboards/library/error_budget_burn_strip'
require 'pangea/dashboards/library/burn_rate_matrix'
require 'pangea/dashboards/library/worst_n_focus_row'
require 'pangea/dashboards/library/fleet_drilldown_variables'
require 'pangea/dashboards/library/one_to_one_segmentation_table'
require 'pangea/dashboards/library/residency_compliance_strip'
require 'pangea/dashboards/library/tenant_class_split_row'
require 'pangea/dashboards/library/availability_heatmap'
require 'pangea/dashboards/library/pipeline_flow_overview'
require 'pangea/dashboards/library/scale_to_zero_efficiency_board'
require 'pangea/dashboards/library/pipeline_flow_strip'
require 'pangea/dashboards/library/broker_stream_row'
require 'pangea/dashboards/library/pipeline_lag_row'
require 'pangea/dashboards/library/wake_event_timeline'
require 'pangea/dashboards/library/sleep_wake_posture_row'
require 'pangea/dashboards/library/cost_at_rest_row'
require 'pangea/dashboards/library/managed_datastore_overview'
require 'pangea/dashboards/library/k8s_control_plane_board'
require 'pangea/dashboards/library/cost_saturation_board'
require 'pangea/dashboards/library/fleet_saturation_grid'
require 'pangea/dashboards/library/datastore_query_row'
require 'pangea/dashboards/library/etcd_health_row'
require 'pangea/dashboards/library/node_pressure_strip'
require 'pangea/dashboards/library/cost_efficiency_row'
require 'pangea/dashboards/library/savings_realized_strip'
require 'pangea/dashboards/library/cost_attribution_row'
require 'pangea/dashboards/library/saturation_grid_panel'

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
