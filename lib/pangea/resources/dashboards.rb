# frozen_string_literal: true

require 'json'
require 'pangea/dashboards'
require 'pangea/dashboards/dsl'
require 'pangea/dashboards/render/grafana'
require 'pangea/dashboards/render/datadog'

module Pangea
  module Resources
    # Mixin that adds .dashboard and .render_dashboard to a Pangea
    # synthesizer.
    #
    # Usage in a workspace template:
    #
    #   synth.extend(Pangea::Resources::Grafana)
    #   synth.extend(Pangea::Resources::Dashboards)
    #
    #   dash = synth.dashboard(:rio_lareira) do
    #     title 'rio · lareira'
    #     row 'overview' do
    #       panel :pods, kind: :stat do
    #         query 'A', 'count(kube_pod_info)', datasource: 'vm'
    #       end
    #     end
    #   end
    #
    #   synth.render_dashboard(dash, backend: :grafana, folder: 'rio')
    #   # → emits a grafana_dashboard resource
    module Dashboards
      # Build a Pangea::Dashboards::Types::Dashboard via the DSL.
      def dashboard(id, &block)
        builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: id)
        builder.instance_eval(&block) if block
        builder.build
      end

      # Render a Dashboard AST to the chosen backend, emitting the
      # corresponding Pangea resource. Returns whatever the backend's
      # synth.<resource> method returns.
      #
      # Backends:
      #   :grafana — emits grafana_dashboard via pangea-grafana
      #   :datadog — emits datadog_dashboard via pangea-datadog
      def render_dashboard(dashboard, backend:, **opts)
        case backend
        when :grafana
          render_dashboard_grafana(dashboard, **opts)
        when :datadog
          render_dashboard_datadog(dashboard, **opts)
        else
          raise ArgumentError, "Unknown backend: #{backend.inspect}. " \
                               'Expected :grafana or :datadog.'
        end
      end

      # ── private dispatch ────────────────────────────────────────────

      private

      def render_dashboard_grafana(dashboard, folder: nil, overwrite: true,
                                   message: 'Pangea-managed dashboard',
                                   resource_id: nil)
        unless respond_to?(:grafana_dashboard)
          raise 'grafana_dashboard not on synth — extend Pangea::Resources::Grafana first'
        end

        config_json = Pangea::Dashboards::Render::Grafana.render_json(dashboard)
        rid = resource_id || dashboard.id
        attrs = {
          config_json: config_json,
          overwrite:   overwrite,
          message:     message
        }
        attrs[:folder] = folder if folder
        grafana_dashboard(rid, attrs)
      end

      def render_dashboard_datadog(dashboard, resource_id: nil, **extra)
        unless respond_to?(:datadog_dashboard)
          raise 'datadog_dashboard not on synth — extend Pangea::Resources::Datadog first'
        end

        rendered = Pangea::Dashboards::Render::Datadog.render(dashboard)
        rid = resource_id || dashboard.id
        datadog_dashboard(rid, rendered.merge(extra))
      end
    end
  end
end
