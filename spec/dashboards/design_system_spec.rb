# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Dashboards::Theme do
  describe '.tile_width — even grid tiling' do
    it 'splits the 24-col grid exactly for <=4 tiles' do
      expect(described_class.tile_width(1)).to eq(24)
      expect(described_class.tile_width(2)).to eq(12)
      expect(described_class.tile_width(3)).to eq(8)
      expect(described_class.tile_width(4)).to eq(6)
    end

    it 'uses a uniform width 4 (6 per row) for 5+ tiles' do
      expect(described_class.tile_width(5)).to eq(4)
      expect(described_class.tile_width(6)).to eq(4)
      expect(described_class.tile_width(9)).to eq(4)
    end
  end

  describe '.defect_steps — higher is worse' do
    it 'is green below warn, amber at warn, red at crit' do
      steps = described_class.defect_steps(warn: 1, crit: 5)
      expect(steps).to eq([
        { color: 'green', value: nil },
        { color: 'orange', value: 1.0 },
        { color: 'red', value: 5.0 }
      ])
    end

    it 'omits the red step when crit is nil (amber-only defect)' do
      steps = described_class.defect_steps(warn: 1, crit: nil)
      expect(steps.map { |s| s[:color] }).to eq(%w[green orange])
    end
  end

  describe '.liveness_steps — lower is worse' do
    it 'is red below ok, green at/above ok' do
      expect(described_class.liveness_steps(ok: 1)).to eq([
        { color: 'red', value: nil },
        { color: 'green', value: 1.0 }
      ])
    end
  end
end

RSpec.describe Pangea::Dashboards::Library::StatusOverview do
  def build_with(signals, datasource: 'vm')
    builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :t)
    mod = described_class
    builder.instance_eval do
      row 'Status' do
        mod.add(self, datasource: datasource, signals: signals)
      end
    end
    builder.build
  end

  let(:signals) do
    [
      { name: 'Bands not converging', expr: 'count(far_from_setpoint)', warn: 1, crit: 5, desc: 'd1' },
      { name: 'Conflicts /s', expr: 'sum(rate(conflicts[5m]))', warn: 0.01, unit: 'cps' }
    ]
  end

  it 'emits one stat tile per defect signal' do
    panels = build_with(signals).rows.first.panels
    expect(panels.size).to eq(2)
    expect(panels.map(&:kind).uniq).to eq([:stat])
    expect(panels.map(&:title)).to eq(['Bands not converging', 'Conflicts /s'])
  end

  it 'floods each tile with colour (display :background) for preattentive status' do
    panels = build_with(signals).rows.first.panels
    expect(panels.map(&:display_mode).uniq).to eq([:background])
  end

  it 'floors every signal with `or vector(0)` so healthy = green 0, not no-data' do
    panels = build_with(signals).rows.first.panels
    expect(panels.all? { |p| p.queries.first.expr.end_with?('or vector(0)') }).to be(true)
  end

  it 'does not double-wrap an expr that already has a vector fallback' do
    panels = build_with([{ name: 'X', expr: 'foo or vector(0)', warn: 1 }]).rows.first.panels
    expect(panels.first.queries.first.expr).to eq('foo or vector(0)')
  end

  it 'leaves an absent() expr unwrapped (it already yields a value)' do
    panels = build_with([{ name: 'Down', expr: 'absent(up{job="x"})', warn: 1 }]).rows.first.panels
    expect(panels.first.queries.first.expr).to eq('absent(up{job="x"})')
  end

  it 'applies defect thresholds (green/amber/red) from warn+crit' do
    panels = build_with(signals).rows.first.panels
    colors = panels.first.thresholds.steps.map(&:color)
    expect(colors).to eq(%w[green orange red])
  end

  it 'tiles uniformly to fill the grid (2 signals → width 12 each)' do
    panels = build_with(signals).rows.first.panels
    expect(panels.map(&:width).uniq).to eq([12])
    expect(panels.map(&:height).uniq).to eq([4]) # compact stat tiles
  end

  it 'marks tiles event_driven (a green 0 is healthy, not a broken metric)' do
    panels = build_with(signals).rows.first.panels
    expect(panels.map { |p| p.queries.first.presence }.uniq).to eq([:event_driven])
  end

  it 'rejects a signal missing :expr' do
    expect { build_with([{ name: 'X', warn: 1 }]) }
      .to raise_error(ArgumentError, /needs :expr/)
  end

  it 'rejects an empty signal list' do
    expect { build_with([]) }.to raise_error(ArgumentError, /non-empty Array/)
  end
end

RSpec.describe 'Grafana renderer — design-system styling' do
  Grafana = Pangea::Dashboards::Render::Grafana

  def render_panel(kind:, display: :auto, graph: :auto, instant: false)
    b = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :t)
    b.instance_eval do
      title 't'; uid 't'
      row 'r' do
        panel :p, kind: kind, display: display, graph: graph do
          title 'P'
          query 'A', 'some_metric', datasource: 'vm', instant: instant
          threshold steps: [{ color: 'green', value: nil }, { color: 'red', value: 1 }]
        end
      end
    end
    json = Grafana.render(b.build)
    json['panels'].find { |p| p['type'] == Grafana.grafana_type(kind) }
  end

  it 'stat display :background → colorMode background (the preattentive tile)' do
    p = render_panel(kind: :stat, display: :background)
    expect(p['options']['colorMode']).to eq('background')
  end

  it 'stat display :auto → colorMode value (calm, coloured number)' do
    p = render_panel(kind: :stat, display: :auto)
    expect(p['options']['colorMode']).to eq('value')
  end

  it 'stat graph :auto with a NON-instant query → an area sparkline' do
    p = render_panel(kind: :stat, instant: false)
    expect(p['options']['graphMode']).to eq('area')
  end

  it 'stat graph :auto with an INSTANT query → no sparkline (one point is noise)' do
    p = render_panel(kind: :stat, instant: true)
    expect(p['options']['graphMode']).to eq('none')
  end

  it 'timeseries legend is a table with last/max/mean (a legend should inform)' do
    p = render_panel(kind: :timeseries)
    expect(p['options']['legend']['displayMode']).to eq('table')
    expect(p['options']['legend']['calcs']).to eq(%w[lastNotNull max mean])
  end

  it 'timeseries gets a soft gradient fill (Tufte data-ink), not flat blocks' do
    p = render_panel(kind: :timeseries)
    expect(p['fieldConfig']['defaults']['custom']['gradientMode']).to eq('opacity')
    expect(p['fieldConfig']['defaults']['custom']['showPoints']).to eq('never')
  end

  it 'role heights: a stat is a compact 4-high tile, a timeseries is 8 high' do
    expect(render_panel(kind: :stat)['gridPos']['h']).to eq(4)
    expect(render_panel(kind: :timeseries)['gridPos']['h']).to eq(8)
  end
end
