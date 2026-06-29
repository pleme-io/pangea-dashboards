# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/version_skew_defect_tile'

# VersionSkewDefectTile — a StatusOverview SIGNAL builder. Asserts the
# count(applied != scalar(max(applied))) shape + the typed signal + validation.
RSpec.describe Pangea::Dashboards::Library::VersionSkewDefectTile do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  describe '.signal — the typed StatusOverview hash' do
    let(:sig) do
      Lib::VersionSkewDefectTile.signal(version_metric: 'gateway_applied_config_generation')
    end

    it 'returns a Hash with name/expr/warn/crit/desc' do
      expect(sig).to be_a(Hash)
      expect(sig.keys).to include(:name, :expr, :warn, :crit, :desc)
    end

    it 'emits count(applied != scalar(max(applied))) with no selector' do
      expect(sig[:expr]).to eq(
        'count(gateway_applied_config_generation != scalar(max(gateway_applied_config_generation)))'
      )
    end

    it 'applies a typed Hash selector to BOTH the applied and the max() inner' do
      sig2 = Lib::VersionSkewDefectTile.signal(
        version_metric: 'gen', selector: { service: 'gateway' }
      )
      expect(sig2[:expr]).to eq(
        'count(gen{service="gateway"} != scalar(max(gen{service="gateway"})))'
      )
    end

    it 'defaults warn/crit to 1/3' do
      expect(sig[:warn]).to eq(1)
      expect(sig[:crit]).to eq(3)
    end

    it 'describes the rollout-vs-stuck skew semantics' do
      expect(sig[:desc]).to match(/newest/)
    end
  end

  describe 'overrides' do
    it 'honours name/desc/warn/crit' do
      sig = Lib::VersionSkewDefectTile.signal(version_metric: 'v', name: 'Skew', desc: 'd', warn: 2, crit: 8)
      expect(sig[:name]).to eq('Skew')
      expect(sig[:desc]).to eq('d')
      expect(sig[:warn]).to eq(2)
      expect(sig[:crit]).to eq(8)
    end
  end

  describe 'validation' do
    it 'requires version_metric' do
      expect { Lib::VersionSkewDefectTile.signal(version_metric: '') }
        .to raise_error(ArgumentError, /version_metric/)
    end
  end
end
