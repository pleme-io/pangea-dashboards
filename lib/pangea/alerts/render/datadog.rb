# frozen_string_literal: true

require 'pangea/alerts/types'

module Pangea
  module Alerts
    module Render
      # AST → list of datadog_monitor Pangea resource specs.
      #
      # Datadog has no concept of "alert group" — every AlertRule
      # becomes its own datadog_monitor resource. The group name
      # becomes a tag for filtering in the UI.
      #
      # Returns a list of `{ resource_id:, attrs: }` Hashes. The
      # Pangea::Resources::Alerts mixin walks this list and emits
      # `synth.datadog_monitor(resource_id, attrs)` for each.
      module Datadog
        # Heuristic: same regex pangea-dashboards uses for
        # PromQL-only detection. Authors must override via dd_query.
        PROMQL_TOKENS = /\b(rate|irate|increase|histogram_quantile|sum\s+by|avg\s+by|max\s+by|min\s+by|count\s+by|topk|bottomk|stddev|stdvar|deriv|predict_linear|absent|changes|delta|idelta)\s*\(/.freeze

        def self.render(alerts)
          alerts.groups.flat_map do |group|
            group.rules.map { |rule| render_rule(alerts, group, rule) }
          end
        end

        def self.render_rule(alerts, group, rule)
          {
            resource_id: :"#{alerts.id}_#{rule.name}",
            attrs: {
              name:    monitor_name(alerts, rule),
              type:    rule.dd_monitor_type || infer_monitor_type(rule),
              query:   datadog_query(rule),
              message: monitor_message(rule),
              tags:    monitor_tags(alerts, group, rule),
              priority: severity_priority(rule.severity),
              evaluation_delay: 60
            }
          }
        end

        def self.monitor_name(alerts, rule)
          summary = rule.annotations['summary'] || rule.summary
          summary || "#{alerts.id}: #{rule.name}"
        end

        def self.monitor_message(rule)
          parts = []
          parts << rule.annotations['summary'] if rule.annotations['summary']
          parts << rule.annotations['description'] if rule.annotations['description']
          parts << "Runbook: #{rule.annotations['runbook_url']}" if rule.annotations['runbook_url']
          parts.compact.join("\n\n")
        end

        def self.monitor_tags(alerts, group, rule)
          tags = ["alert-group:#{group.name}", "severity:#{rule.severity}"]
          tags.concat(alerts.labels.map { |k, v| "#{k}:#{v}" })
          tags.concat(rule.labels.map { |k, v| "#{k}:#{v}" })
          tags
        end

        def self.severity_priority(severity)
          case severity
          when 'critical' then 1
          when 'warning'  then 3
          when 'info'     then 5
          else 5
          end
        end

        def self.datadog_query(rule)
          return rule.dd_query if rule.dd_query && !rule.dd_query.empty?
          if PROMQL_TOKENS.match?(rule.expr)
            raise UntranslatableExprError,
                  "AlertRule #{rule.name.inspect} expr contains PromQL-only syntax (#{rule.expr.inspect}). " \
                  'Datadog renderer cannot translate automatically. ' \
                  "Set `dd_query:` explicitly on this alert."
          end
          rule.expr
        end

        def self.infer_monitor_type(_rule)
          # Pragmatic default; the Datadog API accepts 'metric alert'
          # for the vast majority of expression shapes.
          'metric alert'
        end
      end
    end
  end
end
