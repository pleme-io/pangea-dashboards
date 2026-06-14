# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/capacity_headroom_stat'

# CapacityHeadroomStat — the lower-is-worse headroom tile absorbed from
# victoria_metrics_health.rb (free_disk / active_series) + node_host.rb
# (mem_avail_pct). Builds a RowBuilder, runs .add, and asserts on the
# emitted PromQL text, the panel kind/width/presence, and the red→orange→green
# threshold ladder.
RSpec.describe Pangea::Dashboards::Library::CapacityHeadroomStat do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'the happy path' do
    let(:built) do
      row_with do |r|
        Lib::CapacityHeadroomStat.add(r, datasource: 'vm', title: 'Free disk space',
          expr: 'vm_free_disk_space_bytes', unit: 'bytes',
          floor: 5e9, warn: 1e10, ok: 2e10)
      end
    end

    it 'emits a min-reduced continuous stat tile with an area sparkline' do
      p = built.panels.first
      expect(p.kind).to eq(:stat)
      expect(p.unit).to eq('bytes')
      expect(p.display_mode).to eq(:background)
      expect(p.graph).to eq(:area)
      expect(p.height).to eq(Theme::STAT_H)
      expect(p.width).to eq(Theme.tile_width(4))
    end

    it 'wraps the expr in the default min() reducer' do
      expect(built.panels.first.queries.first.expr).to eq('min(vm_free_disk_space_bytes)')
    end

    it 'marks the series continuous and NEVER floors it with or vector(0)' do
      q = built.panels.first.queries.first
      expect(q.presence).to eq(:continuous)
      expect(q.expr).not_to include('vector(0)')
    end

    it 'runs the threshold ladder red→orange→green (lower = worse)' do
      steps = built.panels.first.thresholds.steps
      expect(steps.map(&:color)).to eq(%w[red orange green])
      expect(steps.map(&:value)).to eq([nil, 1e10, 2e10])
    end

    it 'derives a slugged panel id from the title' do
      expect(built.panels.first.id).to eq(:headroom_free_disk_space)
    end
  end

  describe 'reducers' do
    it 'wraps in max() when reducer: :max' do
      built = row_with do |r|
        Lib::CapacityHeadroomStat.add(r, datasource: 'vm', title: 'Peak series',
          expr: 'vm_cache_entries{type="storage/tsid"}', reducer: :max, unit: 'short',
          floor: 1, ok: 100)
      end
      expect(built.panels.first.queries.first.expr).to eq('max(vm_cache_entries{type="storage/tsid"})')
    end

    it 'wraps in avg() when reducer: :avg' do
      built = row_with do |r|
        Lib::CapacityHeadroomStat.add(r, datasource: 'vm', title: 'Mem available',
          expr: '100 * node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes',
          reducer: :avg, floor: 10, warn: 25, ok: 40)
      end
      expect(built.panels.first.queries.first.expr)
        .to eq('avg(100 * node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)')
    end
  end

  describe 'the two-stop ladder' do
    it 'collapses the orange shelf to floor when warn is nil (red→green at the floor)' do
      built = row_with do |r|
        Lib::CapacityHeadroomStat.add(r, datasource: 'vm', title: 'Quota left',
          expr: 'quota_remaining', unit: 'percent', floor: 20, ok: 50)
      end
      steps = built.panels.first.thresholds.steps
      # warn nil → middle (orange) shelf pinned at the floor; green at ok.
      expect(steps.map(&:color)).to eq(%w[red orange green])
      expect(steps.map(&:value)).to eq([nil, 20.0, 50.0])
    end
  end

  describe 'validation' do
    it 'rejects a missing datasource' do
      expect { row_with { |r| Lib::CapacityHeadroomStat.add(r, datasource: nil, title: 'x', expr: 'm', floor: 1, ok: 2) } }
        .to raise_error(ArgumentError, /datasource/)
    end

    it 'rejects a missing expr' do
      expect { row_with { |r| Lib::CapacityHeadroomStat.add(r, datasource: 'vm', title: 'x', expr: '', floor: 1, ok: 2) } }
        .to raise_error(ArgumentError, /expr/)
    end

    it 'rejects a missing title' do
      expect { row_with { |r| Lib::CapacityHeadroomStat.add(r, datasource: 'vm', title: '', expr: 'm', floor: 1, ok: 2) } }
        .to raise_error(ArgumentError, /title/)
    end

    it 'rejects an unknown reducer' do
      expect { row_with { |r| Lib::CapacityHeadroomStat.add(r, datasource: 'vm', title: 'x', expr: 'm', reducer: :sum, floor: 1, ok: 2) } }
        .to raise_error(ArgumentError, /reducer/)
    end

    it 'rejects a non-ascending threshold ladder (floor > ok)' do
      expect { row_with { |r| Lib::CapacityHeadroomStat.add(r, datasource: 'vm', title: 'x', expr: 'm', floor: 50, ok: 10) } }
        .to raise_error(ArgumentError, /ascend/)
    end

    it 'rejects warn outside the floor..ok band' do
      expect { row_with { |r| Lib::CapacityHeadroomStat.add(r, datasource: 'vm', title: 'x', expr: 'm', floor: 10, warn: 5, ok: 40) } }
        .to raise_error(ArgumentError, /ascend/)
    end
  end
end
