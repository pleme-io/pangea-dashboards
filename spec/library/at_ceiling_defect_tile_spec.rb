# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/at_ceiling_defect_tile'

# AtCeilingDefectTile — a StatusOverview SIGNAL builder (returns a Hash, emits
# no panel). Asserts the returned { name:, expr:, warn:, crit:, desc: } shape
# and the emitted PromQL text, plus a typed-join-labels case + a validation
# rejection.
RSpec.describe Pangea::Dashboards::Library::AtCeilingDefectTile do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  let(:metrics) do
    {
      util_metric: 'breathe_band_util_ratio',
      grow_above_metric: 'breathe_band_grow_above_ratio',
      limit_metric: 'breathe_band_limit_bytes',
      ceiling_metric: 'breathe_band_ceiling_bytes'
    }
  end

  describe '.signal (happy path)' do
    subject(:sig) { Lib::AtCeilingDefectTile.signal(**metrics) }

    it 'returns exactly the StatusOverview signal Hash shape' do
      expect(sig).to be_a(Hash)
      expect(sig.keys).to contain_exactly(:name, :expr, :warn, :crit, :desc)
    end

    it 'builds the count(hot and on(identity) pinned) expr through Promql.by' do
      expect(sig[:expr]).to eq(
        'count((breathe_band_util_ratio >= breathe_band_grow_above_ratio) ' \
        'and on (dim, namespace, name) ' \
        '(breathe_band_limit_bytes >= breathe_band_ceiling_bytes))'
      )
    end

    it 'does NOT zero-floor (a count of an empty intersection IS 0)' do
      expect(sig[:expr]).not_to include('or vector(0)')
    end

    it 'defaults the name + defect thresholds (1 amber / 2 red) + a desc' do
      expect(sig[:name]).to eq('At ceiling — OOM risk')
      expect(sig[:warn]).to eq(1)
      expect(sig[:crit]).to eq(2)
      expect(sig[:desc]).to match(/OOM|headroom|ceiling/i)
    end

    it 'slots into StatusOverview.add as a defect tile' do
      r = Pangea::Dashboards::DSL::RowBuilder.new('test')
      Lib::StatusOverview.add(r, datasource: 'vm', signals: [Lib::AtCeilingDefectTile.signal(**metrics)])
      built = r.build
      tile = built.panels.first
      expect(tile.kind).to eq(:stat)
      expect(tile.display_mode).to eq(:background)
      expect(tile.title).to eq('At ceiling — OOM risk')
      # StatusOverview owns the rendered tile's zero-floor (a bare count(...)
      # gets `or vector(0)` appended at render time); the signal carries the
      # un-floored expr, so the rendered query starts with it.
      expect(tile.queries.first.expr).to start_with(sig[:expr])
    end
  end

  describe '.signal (typed join_labels + overrides)' do
    subject(:sig) do
      Lib::AtCeilingDefectTile.signal(
        **metrics,
        join_labels: %w[volume namespace],
        warn: 2, crit: 4,
        name: 'Storage at ceiling',
        desc: 'PVCs pinned at their max.'
      )
    end

    it 'renders the supplied identity labels in the on() clause' do
      expect(sig[:expr]).to include('and on (volume, namespace) ')
      expect(sig[:expr]).not_to include('dim')
    end

    it 'honours name / warn / crit / desc overrides' do
      expect(sig[:name]).to eq('Storage at ceiling')
      expect(sig[:warn]).to eq(2)
      expect(sig[:crit]).to eq(4)
      expect(sig[:desc]).to eq('PVCs pinned at their max.')
    end
  end

  describe '.signal (validation)' do
    it 'rejects a blank metric arg' do
      expect { Lib::AtCeilingDefectTile.signal(**metrics.merge(limit_metric: '')) }
        .to raise_error(ArgumentError, /limit_metric/)
    end

    it 'rejects a missing required metric arg' do
      expect { Lib::AtCeilingDefectTile.signal(**metrics.reject { |k, _| k == :util_metric }) }
        .to raise_error(ArgumentError)
    end

    it 'rejects empty join_labels' do
      expect { Lib::AtCeilingDefectTile.signal(**metrics, join_labels: []) }
        .to raise_error(ArgumentError, /join_labels/)
    end
  end
end
