# frozen_string_literal: true

require 'pangea/dashboards/types'

module Pangea
  module Dashboards
    module Render
      # AST → Datadog dashboard widget format (compatible with the
      # `datadog_dashboard` Terraform resource).
      #
      # Returns a Hash with `title`, `layout_type`, `widget` (array),
      # `template_variable` (array), `description`, `tags`. Caller
      # passes that to `synth.datadog_dashboard(name, **rendered)`.
      module Datadog
        # Heuristic regex for "this expr is PromQL-only". If we see one
        # of these tokens and `dd_query:` is NOT set, the renderer
        # raises UntranslatableQueryError so the author has to be
        # explicit.
        PROMQL_TOKENS = /\b(rate|irate|increase|histogram_quantile|sum\s+by|avg\s+by|max\s+by|min\s+by|count\s+by|topk|bottomk|stddev|stdvar|deriv|predict_linear|absent|changes|delta|idelta)\s*\(/.freeze

        def self.render(dashboard)
          {
            title:             dashboard.title,
            description:       dashboard.description.to_s,
            layout_type:       'ordered',
            is_read_only:      false,
            template_variable: render_template_variables(dashboard.variables),
            widget:            render_widgets(dashboard.rows),
            reflow_type:       'auto',
            tags:              dashboard.tags
          }
        end

        # ── internals ──────────────────────────────────────────────────

        def self.render_widgets(rows)
          widgets = []

          rows.each do |row|
            widgets << {
              definition: {
                type:  'group',
                title: row.title,
                layout_type: 'ordered',
                widget: row.panels.map { |p| render_widget(p) }
              }
            }
          end

          widgets
        end

        def self.render_widget(panel)
          { definition: render_definition(panel) }
        end

        def self.render_definition(panel)
          case panel.kind
          when :stat       then render_query_value(panel)
          when :timeseries then render_timeseries(panel)
          when :gauge      then render_query_value(panel, type: 'query_value', style: :gauge)
          when :table      then render_query_table(panel)
          when :text       then render_note(panel)
          when :heatmap    then render_heatmap(panel)
          when :pie        then render_sunburst(panel)
          else
            raise UnsupportedBackendError, "Datadog renderer: unsupported panel kind #{panel.kind.inspect}"
          end
        end

        def self.render_query_value(panel, type: 'query_value', style: nil)
          d = {
            type: type,
            title: panel.title,
            requests: panel.queries.map { |q| { q: dd_query(q) } }
          }
          d[:precision] = panel.decimals if panel.decimals
          d[:custom_unit] = panel.unit if panel.unit
          d[:autoscale]  = true unless panel.unit
          if style == :gauge
            d[:requests].each { |r| r[:conditional_formats] = format_thresholds(panel.thresholds) }
          end
          d
        end

        def self.render_timeseries(panel)
          {
            type:  'timeseries',
            title: panel.title,
            requests: panel.queries.map do |q|
              {
                q: dd_query(q),
                display_type: 'line',
                style: { palette: 'dog_classic', line_type: 'solid', line_width: 'normal' }
              }
            end,
            yaxis: {
              scale: 'linear',
              min: panel.min&.to_s,
              max: panel.max&.to_s,
              include_zero: true
            }.compact
          }
        end

        def self.render_query_table(panel)
          {
            type: 'query_table',
            title: panel.title,
            requests: panel.queries.map do |q|
              {
                q: dd_query(q),
                aggregator: 'last',
                alias:      q.legend_format,
                conditional_formats: format_thresholds(panel.thresholds)
              }.compact
            end
          }
        end

        def self.render_note(panel)
          {
            type: 'note',
            content: panel.description || panel.title,
            background_color: 'white',
            font_size: '14',
            text_align: 'left',
            show_tick: false
          }
        end

        def self.render_heatmap(panel)
          {
            type: 'heatmap',
            title: panel.title,
            requests: panel.queries.map { |q| { q: dd_query(q) } }
          }
        end

        def self.render_sunburst(panel)
          {
            type: 'sunburst',
            title: panel.title,
            requests: panel.queries.map { |q| { q: dd_query(q) } }
          }
        end

        # Returns the Datadog query string for a Pangea Query node.
        # Uses dd_query: explicitly when set; otherwise pass-through if
        # the expr looks Datadog-compatible; otherwise raises.
        def self.dd_query(query)
          return query.dd_query if query.dd_query && !query.dd_query.empty?

          if PROMQL_TOKENS.match?(query.expr)
            raise UntranslatableQueryError,
                  "Query refId=#{query.ref.inspect} expr contains PromQL-only syntax (#{query.expr.inspect}). " \
                  'Datadog renderer cannot translate automatically. ' \
                  "Set `dd_query:` explicitly on this Query, e.g. dd_query: 'avg:my.metric{*}.as_rate()'."
          end

          # Pass-through: works when the expr is a simple metric reference
          # like `kube_pod_info` that Datadog also indexes natively, or
          # when the author already wrote Datadog query syntax in expr.
          query.expr
        end

        def self.format_thresholds(thresholds)
          thresholds.steps.reject { |s| s.value.nil? }.map.with_index do |step, _idx|
            comparator = case step.color
                          when 'red'    then '>'
                          when 'yellow' then '>'
                          else '>'
                          end
            {
              comparator: comparator,
              value:      step.value,
              palette:    palette_for(step.color)
            }
          end
        end

        def self.palette_for(color)
          case color
          when 'red'    then 'red_on_white'
          when 'yellow' then 'yellow_on_white'
          when 'green'  then 'green_on_white'
          when 'blue'   then 'blue_on_white'
          else 'white_on_gray'
          end
        end

        def self.render_template_variables(variables)
          variables.map do |v|
            tv = {
              name: v.name.to_s,
              prefix: v.label || v.name.to_s,
              available_values: v.options
            }
            tv[:default] = (v.default.is_a?(Array) ? v.default : [v.default || '*']).first
            tv
          end
        end
      end
    end
  end
end
