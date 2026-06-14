# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/catalog'

# The CATALOG REFLECTION matrix test — the substrate self-describes, and drift
# between the catalog and the code is mechanically rejected.
RSpec.describe Pangea::Dashboards::Library::Catalog do
  Cat = Pangea::Dashboards::Library::Catalog unless defined?(Cat)

  it 'lists the full component set (33 components + helpers/primitives)' do
    expect(Cat.all.size).to be >= 38
  end

  it 'every catalog entry resolves to a loadable module responding to its entry method' do
    unresolved = Cat.all.reject(&:resolvable?)
    expect(unresolved).to be_empty,
      "catalog entries not loadable / wrong entry method:\n  - " +
      unresolved.map { |e| "#{e.name}##{e.entry}" }.join("\n  - ")
  end

  it 'declares only known layers and tiers' do
    bad_layer = Cat.all.reject { |e| Cat::LAYERS.include?(e.layer) }
    bad_tier  = Cat.all.reject { |e| Cat::TIERS.include?(e.tier) }
    expect(bad_layer).to be_empty, "unknown layers: #{bad_layer.map(&:name)}"
    expect(bad_tier).to be_empty, "unknown tiers: #{bad_tier.map(&:name)}"
  end

  it 'covers every authored panel LAYER (primitive → composite → overview → mixin)' do
    %i[primitive_panel composite_row overview_strip full_dashboard_mixin].each do |layer|
      expect(Cat.by_layer(layer)).not_to be_empty, "no component at layer #{layer}"
    end
  end

  it 'covers every absorbed TIER (infra/platform/app/data/business/saas/security)' do
    %w[infra platform app data business saas security].each do |tier|
      expect(Cat.by_tier(tier)).not_to be_empty, "no component at tier #{tier}"
    end
  end

  it 'every loaded Library component module is registered in the catalog (no orphans)' do
    # Modules that emit/build dashboard artifacts and SHOULD be cataloged.
    skip_consts = %i[Catalog] # the catalog itself + any non-component module
    registered = Cat.all.map(&:name)
    loaded = Pangea::Dashboards::Library.constants.reject { |c| skip_consts.include?(c) }
                                        .select { |c| Pangea::Dashboards::Library.const_get(c).is_a?(Module) }
                                        .map(&:to_s)
    # Every loaded component (that exposes a class-method entry) is in the catalog.
    entryish = loaded.select do |name|
      mod = Pangea::Dashboards::Library.const_get(name)
      %i[add add_all build signal compose zero selector_body derive_panels].any? { |m| mod.respond_to?(m) }
    end
    orphans = entryish - registered
    expect(orphans).to be_empty, "loaded components missing from the catalog: #{orphans.join(', ')}"
  end

  it 'exposes queryable views (by_tier / by_layer / coverage)' do
    expect(Cat.by_tier('data').map(&:name)).to include('ReplicationHealthRow', 'RedComponentThroughputRow')
    expect(Cat.by_layer(:full_dashboard_mixin).map(&:name)).to include('WorkloadOverview', 'ControllerRuntimeDashboard')
    expect(Cat.coverage.values.sum).to eq(Cat.all.size)
  end
end
