# frozen_string_literal: true

require 'yaml'
require 'pangea/alerts'
require 'pangea/alerts/dsl'
require 'pangea/alerts/render/victoria'
require 'pangea/alerts/render/prometheus'
require 'pangea/alerts/render/datadog'

module Pangea
  module Resources
    # Mixin: adds `.alerts(:n) do ... end` + `.render_alerts(ast, backend:, ...)`
    # to a Pangea synthesizer.
    #
    #   synth.extend(Pangea::Resources::Datadog)   # only needed for :datadog
    #   synth.extend(Pangea::Resources::Alerts)
    #
    #   alerts = synth.alerts(:secure_vpc_prod) do
    #     group 'secure-vpc' do
    #       alert :rejected_flows_high,
    #         expr: 'rate(aws_vpc_flow_log_rejects[5m]) > 100',
    #         for: '5m', severity: 'warning'
    #     end
    #   end
    #
    #   # Backends:
    #   synth.render_alerts(alerts, backend: :victoria)
    #     # → returns a VMRule manifest Hash; workspace serializes to YAML
    #
    #   synth.render_alerts(alerts, backend: :victoria, write_to: 'alerts.yaml')
    #     # → also writes the YAML to disk
    #
    #   synth.render_alerts(alerts, backend: :datadog)
    #     # → emits one datadog_monitor resource per AlertRule
    module Alerts
      def alerts(id, &block)
        builder = Pangea::Alerts::DSL::AlertsBuilder.new(id: id)
        builder.instance_eval(&block) if block
        builder.build
      end

      def render_alerts(alerts, backend:, **opts)
        case backend
        when :victoria   then render_alerts_manifest(alerts, Pangea::Alerts::Render::Victoria, **opts)
        when :prometheus then render_alerts_manifest(alerts, Pangea::Alerts::Render::Prometheus, **opts)
        when :datadog    then render_alerts_datadog(alerts, **opts)
        else
          raise ArgumentError, "Unknown alerts backend: #{backend.inspect}. Expected :victoria, :prometheus, or :datadog."
        end
      end

      private

      def render_alerts_manifest(alerts, renderer, write_to: nil, name_override: nil)
        manifest = renderer.render(alerts, name_override: name_override)
        if write_to
          dir = File.dirname(write_to)
          require 'fileutils'
          FileUtils.mkdir_p(dir) unless File.directory?(dir)
          File.write(write_to, "---\n#{YAML.dump(manifest).sub(/\A---\n/, '')}")
        end
        manifest
      end

      def render_alerts_datadog(alerts, **_opts)
        unless respond_to?(:datadog_monitor)
          raise 'datadog_monitor not on synth — extend Pangea::Resources::Datadog first'
        end
        rendered = Pangea::Alerts::Render::Datadog.render(alerts)
        rendered.map do |entry|
          datadog_monitor(entry[:resource_id], entry[:attrs])
        end
      end
    end
  end
end
