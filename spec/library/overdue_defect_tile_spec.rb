# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/overdue_defect_tile'

# OverdueDefectTile — a StatusOverview SIGNAL builder (returns a typed Hash,
# NOT a panel). Asserts the emitted PromQL count-over-intersection + the typed
# signal shape + validation.
RSpec.describe Pangea::Dashboards::Library::OverdueDefectTile do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  describe '.signal — the typed StatusOverview hash' do
    let(:sig) do
      Lib::OverdueDefectTile.signal(
        elapsed_metric: 'rotation_seconds_since_last',
        interval_metric: 'rotation_configured_interval_seconds',
        name: 'Rotations overdue'
      )
    end

    it 'returns a Hash with name/expr/warn/crit/desc' do
      expect(sig).to be_a(Hash)
      expect(sig.keys).to include(:name, :expr, :warn, :crit, :desc)
      expect(sig[:name]).to eq('Rotations overdue')
    end

    it 'emits count((elapsed >= interval) and on(identity) interval)' do
      expect(sig[:expr]).to eq(
        'count((rotation_seconds_since_last >= rotation_configured_interval_seconds) ' \
        'and on (producer, namespace, name) rotation_configured_interval_seconds)'
      )
    end

    it 'defaults warn/crit to 1/3 (one overdue amber, three red)' do
      expect(sig[:warn]).to eq(1)
      expect(sig[:crit]).to eq(3)
    end

    it 'has a default description naming the per-entity deadline semantics' do
      expect(sig[:desc]).to match(/configured interval/)
    end
  end

  describe 'overrides' do
    it 'honours custom join_labels, name, desc, warn, crit' do
      sig = Lib::OverdueDefectTile.signal(
        elapsed_metric: 'cert_age_seconds', interval_metric: 'cert_ttl_seconds',
        join_labels: %w[issuer cn], name: 'Certs expiring', desc: 'custom', warn: 2, crit: 9
      )
      expect(sig[:expr]).to include('and on (issuer, cn)')
      expect(sig[:name]).to eq('Certs expiring')
      expect(sig[:desc]).to eq('custom')
      expect(sig[:warn]).to eq(2)
      expect(sig[:crit]).to eq(9)
    end

    it 'feeds straight into StatusOverview.add as a signal' do
      r = Pangea::Dashboards::DSL::RowBuilder.new('test')
      Lib::StatusOverview.add(r, datasource: 'vm', signals: [
        Lib::OverdueDefectTile.signal(elapsed_metric: 'a_elapsed', interval_metric: 'a_interval')
      ])
      built = r.build
      expect(built.panels.size).to eq(1)
      expect(built.panels.first.kind).to eq(:stat)
      expect(built.panels.first.queries.first.expr).to include('a_elapsed >= a_interval')
    end
  end

  describe 'validation' do
    it 'requires elapsed_metric' do
      expect { Lib::OverdueDefectTile.signal(elapsed_metric: '', interval_metric: 'b') }
        .to raise_error(ArgumentError, /elapsed_metric/)
    end

    it 'requires interval_metric' do
      expect { Lib::OverdueDefectTile.signal(elapsed_metric: 'a', interval_metric: nil) }
        .to raise_error(ArgumentError, /interval_metric/)
    end

    it 'requires non-empty join_labels' do
      expect { Lib::OverdueDefectTile.signal(elapsed_metric: 'a', interval_metric: 'b', join_labels: []) }
        .to raise_error(ArgumentError, /join_labels/)
    end
  end
end
