# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/stat_strip'

# StatStrip — the generic horizontal row of headline :stat tiles.
# Builds a RowBuilder, runs .add, asserts on the emitted PromQL + panel
# shape (kind/width/presence/display_mode/graph/threshold).
RSpec.describe Pangea::Dashboards::Library::StatStrip do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'happy path — a strip of three defect tiles' do
    let(:built) do
      row_with do |r|
        Lib::StatStrip.add(r, datasource: 'vm', tiles: [
          { title: 'Apps Synced', expr: 'count(argocd_app_info{sync_status="Synced"})' },
          { title: 'OutOfSync',   expr: 'count(argocd_app_info{sync_status="OutOfSync"})' },
          { title: 'Degraded',    expr: 'count(argocd_app_info{health_status="Degraded"})' }
        ])
      end
    end

    it 'emits one :stat tile per tile, all uniform tile-width on one row' do
      expect(built.panels.size).to eq(3)
      expect(built.panels.map(&:kind)).to all(eq(:stat))
      expect(built.panels.map(&:width)).to all(eq(Theme.tile_width(3)))
      expect(built.panels.map(&:height)).to all(eq(Theme::STAT_H))
    end

    it 'floors every tile with `or vector(0)` and marks it event_driven' do
      p = built.panels.first
      expect(p.queries.first.expr).to eq('count(argocd_app_info{sync_status="Synced"}) or vector(0)')
      expect(p.queries.first.presence).to eq(:event_driven)
    end

    it 'defaults to a colour-flooded tile with an area sparkline' do
      p = built.panels.first
      expect(p.display_mode).to eq(:background)
      expect(p.graph).to eq(:area)
    end

    it 'defaults each tile to defect_steps (higher = worse: green → amber)' do
      p = built.panels.find { |x| x.title == 'OutOfSync' }
      expect(p.thresholds.steps.map(&:color)).to eq(%w[green orange])
    end

    it 'titles the tiles and slugs the ids' do
      expect(built.panels.map(&:title)).to eq(['Apps Synced', 'OutOfSync', 'Degraded'])
      expect(built.panels.map(&:id)).to eq(%i[stat_apps_synced_0 stat_outofsync_1 stat_degraded_2])
    end
  end

  describe 'liveness tiles + per-tile overrides' do
    let(:built) do
      row_with do |r|
        Lib::StatStrip.add(r, datasource: 'vm', tiles: [
          { title: 'Success Rate', expr: '100 * sum(ci_runs{result="success"}) / sum(ci_runs)',
            unit: 'percent', liveness: true, color_mode: :value, sparkline: false },
          { title: 'Failed', expr: 'sum(increase(ci_runs_total{result="failed"}[1h]))',
            steps: [{ color: 'green', value: nil }, { color: 'red', value: 3 }],
            id: :ci_failed }
        ])
      end
    end

    it 'uses liveness_steps for a liveness tile (lower = worse: red → green)' do
      live = built.panels.find { |p| p.title == 'Success Rate' }
      expect(live.thresholds.steps.map(&:color)).to eq(%w[red green])
      expect(live.unit).to eq('percent')
    end

    it 'honours color_mode: :value and sparkline: false' do
      live = built.panels.find { |p| p.title == 'Success Rate' }
      expect(live.display_mode).to eq(:value)
      expect(live.graph).to eq(:none)
    end

    it 'lets an explicit steps: ladder and id: override the derived defaults' do
      failed = built.panels.find { |p| p.id == :ci_failed }
      expect(failed.thresholds.steps.map(&:color)).to eq(%w[green red])
      expect(failed.thresholds.steps.map(&:value)).to eq([nil, 3.0])
      # explicit steps wins even though liveness: defaulted false
      expect(failed.queries.first.expr).to end_with('or vector(0)')
    end

    it 'lets a per-tile datasource override the strip default' do
      built2 = row_with do |r|
        Lib::StatStrip.add(r, datasource: 'vm', tiles: [
          { title: 'Logs', expr: 'count(over_time)', datasource: 'vlogs' }
        ])
      end
      expect(built2.panels.first.queries.first.datasource_uid).to eq('vlogs')
    end
  end

  describe 'validation' do
    it 'rejects an empty tiles list' do
      expect { row_with { |r| Lib::StatStrip.add(r, datasource: 'vm', tiles: []) } }
        .to raise_error(ArgumentError, /StatStrip.*tiles/)
    end

    it 'rejects a tile missing :expr' do
      expect { row_with { |r| Lib::StatStrip.add(r, datasource: 'vm', tiles: [{ title: 'x' }]) } }
        .to raise_error(ArgumentError, /needs :expr/)
    end

    it 'rejects a tile with no datasource (strip default nil + no per-tile)' do
      expect { row_with { |r| Lib::StatStrip.add(r, datasource: nil, tiles: [{ title: 'x', expr: 'up' }]) } }
        .to raise_error(ArgumentError, /needs a datasource/)
    end
  end
end
