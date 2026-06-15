# frozen_string_literal: true

require 'pangea/dashboards/library'

module Pangea
  module Dashboards
    module Library
      # The self-describing catalog: every Library component declared as typed
      # data — its module, the method an author calls (entry), and its
      # (layer, tier) coordinate in the taxonomy. Tooling (docs, the matrix
      # test, a "what covers the data tier?" query) iterates this mechanically;
      # the catalog IS the documentation, and the matrix test fails if a
      # component is listed here without a loadable module (or responds to the
      # wrong entry) — drift between code and catalog is unrepresentable.
      #
      #   Pangea::Dashboards::Library::Catalog.by_tier('data')   # → [Entry, …]
      #   Pangea::Dashboards::Library::Catalog.by_layer(:composite_row)
      module Catalog
        Entry = Struct.new(:name, :entry, :layer, :tier, :priority, keyword_init: true) do
          # Resolve the actual module under Pangea::Dashboards::Library.
          def mod
            name.split('::').inject(Pangea::Dashboards::Library) { |m, c| m.const_get(c) }
          end

          def resolvable?
            mod.respond_to?(entry)
          rescue NameError
            false
          end
        end

        LAYERS = %i[primitive_helper primitive_panel composite_row overview_strip full_dashboard_mixin meta].freeze
        TIERS  = %w[cross infra platform app data business saas security any].freeze

        ENTRIES = [
          # ── existing helpers ──
          Entry.new(name: 'StatusOverview',      entry: :add,            layer: :overview_strip,       tier: 'platform', priority: 'P0'),
          Entry.new(name: 'DataPresence',        entry: :add_all,        layer: :composite_row,        tier: 'platform', priority: 'P0'),
          Entry.new(name: 'LogWindows',          entry: :add_all,        layer: :composite_row,        tier: 'platform', priority: 'P0'),
          Entry.new(name: 'KubernetesPodPanels', entry: :add_all,        layer: :composite_row,        tier: 'platform', priority: 'P0'),
          Entry.new(name: 'Derive',              entry: :derive_panels,  layer: :meta,                 tier: 'any',      priority: 'P1'),
          # ── shared primitives ──
          Entry.new(name: 'Floor',  entry: :zero,          layer: :primitive_helper, tier: 'cross', priority: 'P0'),
          Entry.new(name: 'Promql', entry: :selector_body, layer: :primitive_helper, tier: 'cross', priority: 'P0'),
          # ── Wave 0 ──
          Entry.new(name: 'RateWithZeroFloor',     entry: :add, layer: :primitive_panel, tier: 'platform', priority: 'P0'),
          Entry.new(name: 'LatencyHistogramPanel', entry: :add, layer: :primitive_panel, tier: 'platform', priority: 'P0'),
          Entry.new(name: 'TopNTable',             entry: :add, layer: :primitive_panel, tier: 'platform', priority: 'P0'),
          Entry.new(name: 'FailedResourcesTable',  entry: :add, layer: :primitive_panel, tier: 'platform', priority: 'P1'),
          # ── Wave 1 ──
          Entry.new(name: 'GoldenSignalsRow',     entry: :add,   layer: :composite_row,        tier: 'platform', priority: 'P0'),
          Entry.new(name: 'SaturationRow',        entry: :add,   layer: :composite_row,        tier: 'infra',    priority: 'P0'),
          Entry.new(name: 'ControllerRuntimeRow', entry: :add,   layer: :composite_row,        tier: 'platform', priority: 'P0'),
          Entry.new(name: 'WorkloadOverview',     entry: :build, layer: :full_dashboard_mixin, tier: 'platform', priority: 'P0'),
          # ── Wave 2 ──
          Entry.new(name: 'UtilSetpointBand',            entry: :add,    layer: :primitive_panel, tier: 'platform', priority: 'P1'),
          Entry.new(name: 'FloorCeilingEnvelope',        entry: :add,    layer: :primitive_panel, tier: 'platform', priority: 'P1'),
          Entry.new(name: 'AtCeilingDefectTile',         entry: :signal, layer: :overview_strip,  tier: 'platform', priority: 'P1'),
          Entry.new(name: 'PerNamespaceBreakdownRow',    entry: :add,    layer: :composite_row,   tier: 'platform', priority: 'P1'),
          Entry.new(name: 'BuildInfoLiveness',           entry: :add,    layer: :composite_row,   tier: 'platform', priority: 'P1'),
          Entry.new(name: 'StatStrip',                   entry: :add,    layer: :overview_strip,  tier: 'platform', priority: 'P1'),
          Entry.new(name: 'RedSliGaugeStrip',            entry: :add,    layer: :overview_strip,  tier: 'platform', priority: 'P1'),
          Entry.new(name: 'ReplicationHealthRow',        entry: :add,    layer: :composite_row,   tier: 'data',     priority: 'P1'),
          Entry.new(name: 'GoProcessUseRow',             entry: :add,    layer: :composite_row,   tier: 'app',      priority: 'P1'),
          Entry.new(name: 'ByPhaseStrip',                entry: :add,    layer: :composite_row,   tier: 'platform', priority: 'P2'),
          Entry.new(name: 'AllocatableVsRequestedPanel', entry: :add,    layer: :primitive_panel, tier: 'platform', priority: 'P2'),
          Entry.new(name: 'CapacityHeadroomStat',        entry: :add,    layer: :primitive_panel, tier: 'infra',    priority: 'P2'),
          Entry.new(name: 'ShadowLivePostureRow',        entry: :add,    layer: :composite_row,   tier: 'platform', priority: 'P2'),
          Entry.new(name: 'BreathabilityRow',            entry: :add,    layer: :composite_row,   tier: 'platform', priority: 'P1'),
          # ── Wave 3/4 ──
          Entry.new(name: 'FluxReconcileStrip',          entry: :add,   layer: :overview_strip,       tier: 'platform', priority: 'P2'),
          Entry.new(name: 'WebhookLatencyHeatmap',       entry: :add,   layer: :primitive_panel,      tier: 'platform', priority: 'P2'),
          Entry.new(name: 'RedComponentThroughputRow',   entry: :add,   layer: :composite_row,        tier: 'data',     priority: 'P2'),
          Entry.new(name: 'AutoscalerPoolStrip',         entry: :add,   layer: :overview_strip,       tier: 'platform', priority: 'P2'),
          Entry.new(name: 'SloBurnRateRow',              entry: :add,   layer: :composite_row,        tier: 'business', priority: 'P1'),
          Entry.new(name: 'QuotaPctSambaRow',            entry: :add,   layer: :composite_row,        tier: 'saas',     priority: 'P1'),
          Entry.new(name: 'ControllerRuntimeDashboard',  entry: :build, layer: :full_dashboard_mixin, tier: 'platform', priority: 'P1'),
          Entry.new(name: 'LogExplorerDashboard',        entry: :build, layer: :full_dashboard_mixin, tier: 'platform', priority: 'P2'),
          Entry.new(name: 'Alerts::WorkloadBaseline',            entry: :add,   layer: :full_dashboard_mixin, tier: 'platform', priority: 'P1'),
          Entry.new(name: 'Alerts::GatewayLogForwardingTarget', entry: :build, layer: :full_dashboard_mixin, tier: 'security', priority: 'P2')
        ].freeze

        module_function

        def all = ENTRIES
        def by_tier(tier)   = ENTRIES.select { |e| e.tier == tier.to_s }
        def by_layer(layer) = ENTRIES.select { |e| e.layer == layer.to_sym }
        def by_priority(p)  = ENTRIES.select { |e| e.priority == p.to_s }

        # (layer, tier) coverage histogram — { [layer, tier] => count }.
        def coverage
          ENTRIES.each_with_object(Hash.new(0)) { |e, h| h[[e.layer, e.tier]] += 1 }
        end
      end
    end
  end
end
