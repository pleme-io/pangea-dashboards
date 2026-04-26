# frozen_string_literal: true

require 'pangea/alerts/types'

module Pangea
  module Alerts
    # Authoring DSL — Ruby builders that produce Types::Alerts ASTs.
    #
    # Used through Pangea::Resources::Alerts#alerts:
    #
    #   alerts = synth.alerts(:secure_vpc_prod) do
    #     namespace 'monitoring'
    #     labels(team: 'platform', cluster: 'rio')
    #
    #     group 'secure-vpc' do
    #       alert :rejected_flows_high,
    #         expr: 'rate(aws_vpc_flow_log_rejects[5m]) > 100',
    #         for: '5m', severity: 'warning',
    #         summary: 'VPC rejecting flows',
    #         description: 'Sustained high reject rate'
    #     end
    #   end
    module DSL
      class AlertsBuilder
        def initialize(id:)
          @id        = id
          @namespace = 'monitoring'
          @labels    = {}
          @groups    = []
        end

        def namespace(ns); @namespace = ns; end
        def labels(**lbls); @labels = @labels.merge(lbls.transform_keys(&:to_s)); end

        def group(name, interval: '30s', &block)
          gb = AlertGroupBuilder.new(name: name, interval: interval)
          gb.instance_eval(&block) if block
          @groups << gb.build
        end

        def build
          Types::Alerts.new(
            id: @id, namespace: @namespace, labels: @labels, groups: @groups
          )
        end
      end

      class AlertGroupBuilder
        def initialize(name:, interval:)
          @name = name
          @interval = interval
          @rules = []
        end

        def interval(i); @interval = i; end

        # `for` is a Ruby keyword; the public method name is `alert` and
        # consumers pass `for:` as an option. Internally we map it to
        # `for_` on the Dry::Struct.
        def alert(name, expr:, severity:, **opts)
          for_value = opts.delete(:for) || opts.delete(:for_) || '5m'
          labels = opts.delete(:labels) || {}
          annotations = opts.delete(:annotations) || {}
          summary = opts.delete(:summary)
          description = opts.delete(:description)
          runbook_url = opts.delete(:runbook_url)
          dd_query = opts.delete(:dd_query)
          dd_monitor_type = opts.delete(:dd_monitor_type)
          unless opts.empty?
            raise ArgumentError, "alert #{name.inspect}: unknown options #{opts.keys.inspect}"
          end

          # Conventional annotations: roll summary/description/runbook
          # into the annotations map so renderers see one shape.
          annotations = annotations.transform_keys(&:to_s)
          annotations['summary'] ||= summary if summary
          annotations['description'] ||= description if description
          annotations['runbook_url'] ||= runbook_url if runbook_url

          @rules << Types::AlertRule.new(
            name: name, expr: expr, for_: for_value, severity: severity,
            summary: summary, description: description, runbook_url: runbook_url,
            labels: labels.transform_keys(&:to_s),
            annotations: annotations,
            dd_query: dd_query, dd_monitor_type: dd_monitor_type
          )
        end

        def build
          Types::AlertGroup.new(name: @name, interval: @interval, rules: @rules)
        end
      end
    end
  end
end
