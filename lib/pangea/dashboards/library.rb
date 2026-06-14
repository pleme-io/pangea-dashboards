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
