# frozen_string_literal: true

module Pangea
  module Dashboards
    module Library
      # The fleet DRILL-DOWN VARIABLE cascade — the meta helper that declares the
      # chained `$cloud → $region → $tenant → $cell` template variables on a
      # DashboardBuilder, each scoped by its ancestors. Picking `$cloud=aws`
      # narrows `$region` to that cloud's regions; picking `$region` narrows
      # `$tenant`; and so on — the fleet→cell drill trunk every triage board
      # threads its headline/worst-N/golden/logs rows through.
      #
      # Each level is a `kind: :query` variable whose query is
      # `label_values({<ancestors as =~"$ancestor">}, <level>)` — exactly the
      # cascading-`label_values` idiom `LogExplorerDashboard` uses, lifted to a
      # metrics-fleet topology and made reusable so every fleet mixin declares the
      # SAME drill cascade one way (solve-once).
      #
      # Unlike a building BLOCK (which adds a panel to a RowBuilder), this is a
      # META helper: it takes the DashboardBuilder and calls `b.variable` for each
      # level. Mixins call it right after `b.title/tags`, before any row.
      #
      # ── Renderer gap (tier-honest) ──────────────────────────────────────────
      # The variable cascade is fully supported TODAY. Per-tile DATA-LINK
      # drill-down (click a cell → jump to the leaf board with the vars pre-filled)
      # additionally needs the additive panel `links:` field (catalog §9.1), a
      # renderer gap — until it lands, the cascade IS the drill mechanism
      # (re-scope the whole board by changing a variable).
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   b = DSL::DashboardBuilder.new(id: :triage)
      #   Pangea::Dashboards::Library::FleetDrilldownVariables.declare(
      #     b, datasource: 'vm', levels: %w[cloud region tenant cell],
      #     scope_metric: 'up')
      module FleetDrilldownVariables
        DEFAULT_LEVELS = %w[cloud region tenant cell].freeze

        # builder:      (req) the DashboardBuilder to declare variables on
        # datasource:   (req) the metrics datasource uid the label_values run against
        # levels:       drill levels outermost→innermost (default cloud/region/tenant/cell)
        # scope_metric: an optional metric to scope label_values to (e.g. 'up'),
        #               so only labels present on a real fleet series appear.
        #               nil → label_values over the whole label space.
        def self.declare(builder, datasource:, levels: DEFAULT_LEVELS, scope_metric: nil)
          validate!(builder: builder, datasource: datasource, levels: levels)
          ls = Array(levels).map(&:to_s)
          prior = []
          ls.each do |level|
            builder.variable(level.to_sym, kind: :query, datasource_uid: datasource,
                             label: level, query: level_query(level, prior, scope_metric),
                             include_all: true, multi: false)
            prior << level
          end
          builder
        end

        # `label_values({<scope_metric>, <ancestor=~"$ancestor">…}, level)` — the
        # ancestors filter the level's values; the optional scope_metric anchors
        # to real series. With no ancestors + no scope it is the bare
        # `label_values(level)` top of the cascade.
        def self.level_query(level, ancestors, scope_metric)
          filters = []
          filters << scope_metric.to_s unless blank?(scope_metric)
          ancestors.each { |a| filters << %(#{a}=~"$#{a}") }
          return "label_values(#{level})" if filters.empty?
          "label_values({#{filters.join(',')}}, #{level})"
        end

        def self.validate!(builder:, datasource:, levels:)
          raise ArgumentError, 'FleetDrilldownVariables: builder: required' if builder.nil?
          raise ArgumentError, 'FleetDrilldownVariables: builder must respond to #variable' \
            unless builder.respond_to?(:variable)
          raise ArgumentError, 'FleetDrilldownVariables: datasource: required' if blank?(datasource)
          raise ArgumentError, 'FleetDrilldownVariables: levels must be a non-empty Array' \
            unless levels.is_a?(::Array) && !levels.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :level_query, :validate!, :blank?
      end
    end
  end
end
