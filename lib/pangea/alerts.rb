# frozen_string_literal: true

module Pangea
  # Alert AST + multi-backend renderers.
  #
  # Sibling to Pangea::Dashboards: same authoring shape, same Monitorable
  # attachment pattern, different output. Renders to:
  #
  #   :victoria   → operator.victoriametrics.com/v1beta1 VMRule manifest
  #                 (Hash; serialize to YAML for FluxCD-managed clusters)
  #   :prometheus → monitoring.coreos.com/v1 PrometheusRule manifest
  #                 (Hash; same FluxCD shape, different CRD)
  #   :datadog    → datadog_monitor Terraform resource (one per AlertRule;
  #                 emitted via Pangea::Resources::Datadog)
  #
  # Mixed in to a synthesizer via Pangea::Resources::Alerts.
  module Alerts
    # Raised when a backend doesn't support a feature the AST asks for.
    class UnsupportedBackendError < StandardError; end

    # Raised when an alert expr can't be translated to the target
    # backend's query language. Same explicit-over-clever stance as
    # Pangea::Dashboards::Render::Datadog: Datadog requires `dd_query:`
    # on AlertRules with PromQL-only syntax.
    class UntranslatableExprError < StandardError; end
  end
end
