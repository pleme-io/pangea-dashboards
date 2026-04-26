# frozen_string_literal: true

require 'pangea/dashboards/library/kubernetes_pod_panels'
require 'pangea/dashboards/library/derive'

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
