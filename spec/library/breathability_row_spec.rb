# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/breathability_row'

# BreathabilityRow — the "is breathe holding the REAL workload in its band"
# story for one target, from breathe's own exported metrics: the usage-overlay
# envelope + util-vs-setpoint + carve/deferred activity. Builds a RowBuilder,
# runs the component, asserts the composed panels + their PromQL.
RSpec.describe Pangea::Dashboards::Library::BreathabilityRow do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  let(:built) do
    row_with do |r|
      Lib::BreathabilityRow.add(r, datasource: 'vm',
        band: { name: 'arc-runner', dim: 'memory' }, unit: 'bytes',
        legend_labels: '{{name}}')
    end
  end

  describe 'happy path — the breathability triple' do
    it 'emits three panels: envelope(usage), util/setpoint, activity' do
      expect(built.panels.size).to eq(3)
      expect(built.panels.map(&:kind)).to all(eq(:timeseries))
      expect(built.panels.map(&:width)).to all(eq(Theme.half))
    end

    it 'panel 1 overlays the REAL workload (breathe_band_used U) inside [floor,limit,ceiling]' do
      env = built.panels[0]
      expect(env.queries.map(&:ref)).to eq(%w[U A B C])
      expect(env.queries[0].expr).to eq('breathe_band_used{name="arc-runner",dim="memory"}')
      expect(env.queries[1].expr).to eq('breathe_band_current_limit{name="arc-runner",dim="memory"}')
      expect(env.unit).to eq('bytes')
      # gauge state — never floored.
      expect(env.queries.map(&:presence)).to all(eq(:continuous))
    end

    it 'panel 2 plots util vs setpoint for the band' do
      util = built.panels[1]
      expect(util.queries[0].expr).to eq('breathe_band_util_ratio{name="arc-runner",dim="memory"}')
      expect(util.queries[1].expr).to eq('avg(breathe_band_setpoint_ratio{name="arc-runner",dim="memory"})')
      expect(util.unit).to eq('percentunit')
    end

    it 'panel 3 overlays carve/s (by dir) and deferred-crossing/s (by class), floored' do
      act = built.panels[2]
      expect(act.queries.map(&:ref)).to eq(%w[A B])
      expect(act.queries[0].expr).to include('breathe_carves_total{name="arc-runner",dim="memory"}')
      expect(act.queries[0].expr).to include('by (dir)')
      expect(act.queries[1].expr).to include('breathe_deferred_total{name="arc-runner",dim="memory"}')
      expect(act.queries[1].expr).to include('by (class)')
      # event-driven counters → zero-floored so they read 0, not "No data".
      expect(act.queries.map(&:expr)).to all(include('vector(0)'))
      expect(act.queries.map(&:legend_format)).to eq(['carve {{dir}}', 'deferred {{class}}'])
    end
  end

  describe 'show_activity: false — just the two breathability panels' do
    it 'drops the activity panel' do
      two = row_with do |r|
        Lib::BreathabilityRow.add(r, datasource: 'vm',
          band: { name: 'pangea-database', dim: 'cpu' }, unit: 'short', show_activity: false)
      end
      expect(two.panels.size).to eq(2)
      expect(two.panels.map(&:title)).not_to include('carve + deferred activity')
    end
  end

  describe 'validation' do
    it 'requires datasource, band, and unit' do
      expect { row_with { |r| Lib::BreathabilityRow.add(r, datasource: nil, band: { name: 'x' }, unit: 'bytes') } }
        .to raise_error(ArgumentError, /datasource/)
      expect { row_with { |r| Lib::BreathabilityRow.add(r, datasource: 'vm', band: {}, unit: 'bytes') } }
        .to raise_error(ArgumentError, /band/)
      expect { row_with { |r| Lib::BreathabilityRow.add(r, datasource: 'vm', band: { name: 'x' }, unit: '') } }
        .to raise_error(ArgumentError, /unit/)
    end
  end
end
