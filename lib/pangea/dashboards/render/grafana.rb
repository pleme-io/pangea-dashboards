# frozen_string_literal: true

require 'json'
require 'pangea/dashboards/types'

module Pangea
  module Dashboards
    module Render
      # AST → Grafana JSON model (schema v39, current as of 2026-04).
      #
      # Output is the dashboard JSON object (Hash). Caller serializes to
      # `grafana_dashboard.config_json` (a string field) via
      # JSON.generate.
      module Grafana
        SCHEMA_VERSION = 39

        # Returns the dashboard JSON as a Hash. Caller wraps in JSON.
        # Returns the dashboard JSON as a Hash. Caller serializes for
        # the Terraform `config_json` attribute.
        def self.render(dashboard)
          {
            'annotations'        => { 'list' => render_annotations(dashboard.annotations) },
            'description'        => dashboard.description.to_s,
            'editable'           => dashboard.editable,
            'fiscalYearStartMonth' => 0,
            'graphTooltip'       => 1,
            'id'                 => nil,
            'links'              => [],
            'panels'             => render_panels(dashboard.rows),
            'schemaVersion'      => SCHEMA_VERSION,
            'tags'               => dashboard.tags,
            'templating'         => { 'list' => render_variables(dashboard.variables) },
            'time'               => { 'from' => dashboard.time.from, 'to' => dashboard.time.to },
            'timepicker'         => {},
            'timezone'           => dashboard.timezone,
            'title'              => dashboard.title,
            'uid'                => dashboard.uid,
            'version'            => 1
          }
        end

        # Render to a JSON string suitable for grafana_dashboard.config_json.
        def self.render_json(dashboard, pretty: false)
          h = render(dashboard)
          pretty ? JSON.pretty_generate(h) : JSON.generate(h)
        end

        # ── internals ──────────────────────────────────────────────────

        def self.render_panels(rows)
          panels = []
          next_id = 1
          cursor_y = 0

          rows.each do |row|
            panels << {
              'id'        => next_id,
              'type'      => 'row',
              'title'     => row.title,
              'gridPos'   => { 'h' => 1, 'w' => 24, 'x' => 0, 'y' => cursor_y },
              'collapsed' => row.collapsed,
              'panels'    => []
            }
            next_id += 1
            cursor_y += 1

            col_x = 0
            row_max_h = 0
            row.panels.each do |panel|
              if col_x + panel.width > 24
                cursor_y += row_max_h
                col_x = 0
                row_max_h = 0
              end
              panels << render_panel(panel, id: next_id, x: col_x, y: cursor_y)
              next_id += 1
              col_x += panel.width
              row_max_h = panel.height if panel.height > row_max_h
            end
            cursor_y += row_max_h if row_max_h > 0
          end

          panels
        end

        def self.render_panel(panel, id:, x:, y:)
          h = {
            'id'         => id,
            'title'      => panel.title,
            'type'       => grafana_type(panel.kind),
            'gridPos'    => { 'h' => panel.height, 'w' => panel.width, 'x' => x, 'y' => y },
            'targets'    => panel.queries.map { |q| render_query(q) },
            'fieldConfig' => render_field_config(panel),
            'options'    => render_options(panel)
          }
          h['description'] = panel.description if panel.description && !panel.description.empty?
          # Backend-specific overrides (only the :grafana subkey).
          if panel.options.is_a?(Hash) && panel.options[:grafana].is_a?(Hash)
            h.merge!(stringify_keys(panel.options[:grafana]))
          end
          h
        end

        def self.grafana_type(kind)
          case kind
          when :stat       then 'stat'
          when :timeseries then 'timeseries'
          when :gauge      then 'gauge'
          when :table      then 'table'
          when :heatmap    then 'heatmap'
          when :text       then 'text'
          when :pie        then 'piechart'
          else
            raise UnsupportedBackendError, "Grafana renderer: unsupported panel kind #{kind.inspect}"
          end
        end

        def self.render_query(query)
          h = {
            'refId'    => query.ref,
            'expr'     => query.expr,
            'datasource' => { 'type' => 'prometheus', 'uid' => query.datasource_uid }
          }
          h['legendFormat'] = query.legend_format if query.legend_format
          h['instant']      = query.instant if query.instant
          h['hide']         = query.hide if query.hide
          h
        end

        def self.render_field_config(panel)
          defaults = {}
          defaults['unit']     = panel.unit if panel.unit
          defaults['min']      = panel.min if panel.min
          defaults['max']      = panel.max if panel.max
          defaults['decimals'] = panel.decimals if panel.decimals

          if panel.kind == :timeseries
            defaults['custom'] = { 'fillOpacity' => 10, 'lineWidth' => 2 }
          end

          unless panel.thresholds.steps.empty?
            defaults['thresholds'] = {
              'mode'  => panel.thresholds.mode,
              'steps' => panel.thresholds.steps.map do |t|
                { 'color' => t.color, 'value' => t.value }
              end
            }
          end

          { 'defaults' => defaults, 'overrides' => [] }
        end

        def self.render_options(panel)
          case panel.kind
          when :stat
            { 'reduceOptions' => { 'calcs' => ['lastNotNull'], 'fields' => '', 'values' => false }, 'textMode' => 'auto' }
          when :gauge
            { 'reduceOptions' => { 'calcs' => ['lastNotNull'], 'fields' => '', 'values' => false } }
          when :timeseries
            { 'tooltip' => { 'mode' => 'multi', 'sort' => 'none' }, 'legend' => { 'displayMode' => 'list', 'placement' => 'bottom' } }
          when :pie
            { 'reduceOptions' => { 'calcs' => ['lastNotNull'], 'fields' => '', 'values' => false }, 'legend' => { 'displayMode' => 'list' } }
          else
            {}
          end
        end

        def self.render_variables(variables)
          variables.map do |v|
            base = {
              'name'  => v.name.to_s,
              'label' => v.label || v.name.to_s.capitalize,
              'type'  => v.kind.to_s,
              'hide'  => v.hide
            }
            case v.kind
            when :datasource
              base.merge(
                'query'      => v.query.to_s,
                'refresh'    => 1,
                'multi'      => v.multi,
                'includeAll' => v.include_all
              )
            when :query
              {
                'datasource' => { 'type' => 'prometheus', 'uid' => v.datasource_uid },
                'query'      => v.query.to_s,
                'refresh'    => 2,
                'sort'       => 1,
                'multi'      => v.multi,
                'includeAll' => v.include_all
              }.merge(base)
            when :constant
              base.merge('query' => v.query.to_s, 'options' => [{ 'value' => v.query.to_s, 'text' => v.query.to_s, 'selected' => true }])
            when :custom
              opts = (v.options.empty? ? v.query.to_s.split(',') : v.options).map(&:strip)
              base.merge(
                'query'      => v.query.to_s,
                'options'    => opts.map { |o| { 'value' => o, 'text' => o, 'selected' => false } },
                'multi'      => v.multi,
                'includeAll' => v.include_all
              )
            when :textbox
              base.merge('query' => v.default.to_s)
            when :interval
              base.merge('query' => v.query.to_s, 'auto' => false)
            else
              base
            end
          end
        end

        def self.render_annotations(annotations)
          annotations.map do |a|
            {
              'name'       => a.name.to_s,
              'datasource' => { 'type' => 'prometheus', 'uid' => a.datasource_uid },
              'expr'       => a.expr,
              'iconColor'  => a.color,
              'enable'     => a.enable
            }
          end
        end

        def self.stringify_keys(h)
          h.is_a?(Hash) ? h.each_with_object({}) { |(k, v), o| o[k.to_s] = stringify_keys(v) } : h
        end
      end
    end
  end
end
