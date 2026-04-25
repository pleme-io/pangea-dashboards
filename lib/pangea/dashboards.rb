# frozen_string_literal: true

module Pangea
  # Backend-agnostic dashboard AST + Grafana / Datadog renderers.
  #
  # Authors define a Dashboard via typed Dry::Struct nodes, then dispatch
  # rendering through Render::Grafana (→ grafana_dashboard.config_json
  # via pangea-grafana) or Render::Datadog (→ datadog_dashboard via
  # pangea-datadog).
  #
  # Mixed in to the synthesizer via Pangea::Resources::Dashboards.
  module Dashboards
    # Raised when a panel kind isn't supported by the requested backend.
    class UnsupportedBackendError < StandardError; end

    # Raised by Render::Datadog when a Query has PromQL-only syntax and
    # no `dd_query:` override. Authors must state the Datadog query
    # explicitly rather than letting the renderer guess wrong.
    class UntranslatableQueryError < StandardError; end

    # Raised when the AST validation fails at render time (e.g. a panel
    # has zero queries, a variable references a non-existent datasource).
    class InvalidDashboardError < StandardError; end
  end
end
