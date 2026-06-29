# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/cache_effectiveness_row'

# CacheEffectivenessRow — hit-ratio % liveness + miss rate + eviction rate +
# a cold-cache defect stat.
RSpec.describe Pangea::Dashboards::Library::CacheEffectivenessRow do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'happy path — four panels with evictions' do
    let(:built) do
      row_with do |r|
        Lib::CacheEffectivenessRow.add(r, datasource: 'vm',
          hits_metric: 'cache_hits_total', misses_metric: 'cache_misses_total',
          evictions_metric: 'cache_evictions_total')
      end
    end

    it 'emits hit-ratio + miss + eviction + cold-defect (4 panels)' do
      expect(built.panels.size).to eq(4)
    end

    it 'hit-ratio is a continuous % timeseries of hits/(hits+misses)*100' do
      p = built.panels.first
      expect(p.kind).to eq(:timeseries)
      expect(p.unit).to eq('percent')
      expect(p.queries.first.presence).to eq(:continuous)
      expect(p.queries.first.expr).to include('100 *')
      expect(p.queries.first.expr).to include('rate(cache_hits_total[5m])')
      expect(p.queries.first.expr).to include('rate(cache_misses_total[5m])')
    end

    it 'the cold-cache defect is a colour-flooded event-driven stat' do
      cold = built.panels.last
      expect(cold.kind).to eq(:stat)
      expect(cold.display_mode).to eq(:background)
      expect(cold.queries.first.presence).to eq(:event_driven)
      expect(cold.queries.first.expr).to include('< 90')
      expect(cold.queries.first.expr).to end_with('or vector(0)')
    end

    it 'the miss + eviction rates are floored event-driven series' do
      miss = built.panels[1]
      expect(miss.queries.first.expr).to end_with('or vector(0)')
      expect(miss.queries.first.presence).to eq(:event_driven)
    end
  end

  describe 'without evictions' do
    it 'emits only hit-ratio + miss + cold-defect (3 panels)' do
      built = row_with do |r|
        Lib::CacheEffectivenessRow.add(r, datasource: 'vm',
          hits_metric: 'h', misses_metric: 'm')
      end
      expect(built.panels.size).to eq(3)
    end
  end

  describe 'validation' do
    it 'requires datasource + hits_metric + misses_metric' do
      expect { row_with { |r| Lib::CacheEffectivenessRow.add(r, datasource: nil,
        hits_metric: 'h', misses_metric: 'm') } }.to raise_error(ArgumentError, /datasource/)
      expect { row_with { |r| Lib::CacheEffectivenessRow.add(r, datasource: 'vm',
        hits_metric: '', misses_metric: 'm') } }.to raise_error(ArgumentError, /hits_metric/)
      expect { row_with { |r| Lib::CacheEffectivenessRow.add(r, datasource: 'vm',
        hits_metric: 'h', misses_metric: nil) } }.to raise_error(ArgumentError, /misses_metric/)
    end
  end
end
