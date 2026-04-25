# frozen_string_literal: true

require 'pangea/dashboards/types'

module Pangea
  module Dashboards
    # Authoring DSL — Ruby builder that produces Types::Dashboard ASTs.
    #
    # Used through Pangea::Resources::Dashboards#dashboard:
    #
    #   dash = synth.dashboard(:rio_lareira) do
    #     title 'rio · lareira'
    #     row 'overview' do
    #       panel :pods, kind: :stat do
    #         query 'A', 'count(kube_pod_info)', datasource: 'vm'
    #       end
    #     end
    #   end
    module DSL
      class DashboardBuilder
        def initialize(id:)
          @id          = id
          @title       = id.to_s.tr('_', ' ').capitalize
          @uid         = id.to_s.tr('_', '-')
          @description = nil
          @tags        = []
          @refresh     = '30s'
          @time        = Types::TimeRange.new
          @variables   = []
          @annotations = []
          @rows        = []
          @timezone    = 'utc'
          @editable    = true
        end

        def title(t);       @title = t; end
        def uid(u);         @uid = u; end
        def description(d); @description = d; end
        def tags(*t);       @tags = t.flatten.map(&:to_s); end
        def refresh(r);     @refresh = r; end
        def timezone(tz);   @timezone = tz; end
        def editable(b);    @editable = b; end

        def time(from:, to:)
          @time = Types::TimeRange.new(from: from, to: to)
        end

        def variable(name, kind:, **opts)
          @variables << Types::Variable.new(
            name: name, kind: kind, **opts
          )
        end

        def annotation(name, datasource_uid:, expr:, **opts)
          @annotations << Types::Annotation.new(
            name: name, datasource_uid: datasource_uid, expr: expr, **opts
          )
        end

        def row(title, collapsed: false, &block)
          row_b = RowBuilder.new(title, collapsed: collapsed)
          row_b.instance_eval(&block) if block
          @rows << row_b.build
        end

        def build
          Types::Dashboard.new(
            id: @id, title: @title, uid: @uid, description: @description,
            tags: @tags, refresh: @refresh, time: @time,
            variables: @variables, annotations: @annotations,
            rows: @rows, timezone: @timezone, editable: @editable
          )
        end
      end

      class RowBuilder
        def initialize(title, collapsed: false)
          @title     = title
          @collapsed = collapsed
          @panels    = []
        end

        def collapsed(c = true); @collapsed = c; end

        def panel(id, kind:, **opts, &block)
          panel_b = PanelBuilder.new(id: id, kind: kind, **opts)
          panel_b.instance_eval(&block) if block
          @panels << panel_b.build
        end

        def build
          Types::Row.new(title: @title, collapsed: @collapsed, panels: @panels)
        end
      end

      class PanelBuilder
        def initialize(id:, kind:, **opts)
          @id          = id
          @kind        = kind
          @title       = opts.fetch(:title, id.to_s.tr('_', ' ').capitalize)
          @description = opts[:description]
          @unit        = opts[:unit]
          @min         = opts[:min]
          @max         = opts[:max]
          @decimals    = opts[:decimals]
          @width       = opts.fetch(:width, default_width(kind))
          @height      = opts.fetch(:height, 8)
          @queries     = []
          @thresholds  = Types::ThresholdConfig.new
          @options     = opts.fetch(:options, {})
        end

        def title(t);       @title = t; end
        def description(d); @description = d; end
        def unit(u);        @unit = u; end
        def min(v);         @min = v; end
        def max(v);         @max = v; end
        def decimals(d);    @decimals = d; end
        def width(w);       @width = w; end
        def height(h);      @height = h; end
        def options(opts);  @options = @options.merge(opts); end

        def query(ref, expr, datasource: nil, datasource_uid: nil,
                  legend: nil, instant: false, dd_query: nil, hide: false)
          ds = datasource_uid || datasource
          raise ArgumentError, "panel #{@id.inspect} query #{ref.inspect}: datasource: or datasource_uid: required" unless ds
          @queries << Types::Query.new(
            ref: ref, expr: expr, datasource_uid: ds,
            legend_format: legend, instant: instant,
            dd_query: dd_query, hide: hide
          )
        end

        def threshold(mode: 'absolute', steps:)
          tsteps = steps.map do |s|
            Types::Threshold.new(color: s.fetch(:color), value: s[:value])
          end
          @thresholds = Types::ThresholdConfig.new(mode: mode, steps: tsteps)
        end

        def build
          Types::Panel.new(
            id: @id, kind: @kind, title: @title, description: @description,
            unit: @unit, min: @min, max: @max, decimals: @decimals,
            queries: @queries, thresholds: @thresholds,
            width: @width, height: @height, options: @options
          )
        end

        private

        def default_width(kind)
          case kind
          when :stat, :gauge then 6
          when :timeseries, :pie then 12
          when :table, :heatmap then 24
          when :text then 8
          else 12
          end
        end
      end
    end
  end
end
