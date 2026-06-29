# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/band_deviation_heatmap'
require 'pangea/dashboards/library/deviation_rank_table'
require 'pangea/dashboards/library/homeostasis_control_board'

# Wave 5 — the enjulho HomeostasisControlBoard mixin + its two net-new
# deviation-analytics blocks. The board reads breathe's OWN exported metrics
# (T-LIVE: data flowing the day breathe is up), so its specs assert the typed
# dashboard shape + the deviation PromQL the blocks emit.
RSpec.describe 'Pangea::Dashboards::Library homeostasis (Wave 5)' do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe Pangea::Dashboards::Library::BandDeviationHeatmap do
    let(:built) do
      row_with { |r| Lib::BandDeviationHeatmap.add(r, datasource: 'metrics', dim: { dim: 'memory' }) }
    end

    it 'emits one :heatmap of |util − setpoint| matched on the band identity' do
      expect(built.panels.size).to eq(1)
      p = built.panels.first
      expect(p.kind).to eq(:heatmap)
      expect(p.width).to eq(Theme.full)
      q = p.queries.first
      expect(q.expr).to match(/abs\(breathe_band_util_ratio\{dim="memory"\} - on \(dim, namespace, name\) breathe_band_setpoint_ratio\{dim="memory"\}\)/)
      expect(q.presence).to eq(:continuous) # gauges — never floored
      expect(q.datasource_uid).to eq('metrics')
    end

    it 'requires datasource + both metrics' do
      expect { row_with { |r| Lib::BandDeviationHeatmap.add(r, datasource: '') } }
        .to raise_error(ArgumentError, /datasource/)
    end
  end

  describe Pangea::Dashboards::Library::DeviationRankTable do
    let(:built) do
      row_with { |r| Lib::DeviationRankTable.add(r, datasource: 'metrics', worst_n: 7) }
    end

    it 'emits an instant :table ranking the worst-N by distance from setpoint' do
      p = built.panels.first
      expect(p.kind).to eq(:table)
      q = p.queries.first
      expect(q.instant).to be(true)
      expect(q.expr).to start_with('topk(7, abs(')
      expect(q.expr).to include('on (dim, namespace, name)')
    end

    it 'rejects a non-positive worst_n' do
      expect { row_with { |r| Lib::DeviationRankTable.add(r, datasource: 'metrics', worst_n: 0) } }
        .to raise_error(ArgumentError, /worst_n/)
    end
  end

  describe Pangea::Dashboards::Library::HomeostasisControlBoard do
    let(:dash) do
      Lib::HomeostasisControlBoard.build(
        id: :tendril_homeostasis, name: 'tendril breathe', datasource: 'metrics'
      )
    end

    it 'builds a typed Types::Dashboard tagged for homeostasis' do
      expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
      expect(dash.tags).to include('pleme-io', 'homeostasis', 'breathe')
    end

    it 'tells the triage story top-to-bottom (status → posture → per-dim → deviation)' do
      titles = dash.rows.map(&:title)
      expect(titles).to eq([
        'Status — bands needing attention',
        'Fleet posture — shadow vs live',
        'memory breathability',
        'cpu breathability',
        'In-band deviation — is the controller converging the fleet?'
      ])
    end

    it 'opens with a defects headline carrying the OOM-risk + stale-band signals' do
      status = dash.rows.first
      # StatusOverview emits one colour-flooded :stat tile per signal.
      expect(status.panels.size).to eq(2)
      exprs = status.panels.flat_map { |p| p.queries.map(&:expr) }.join("\n")
      expect(exprs).to include('breathe_band_current_limit >= breathe_band_ceiling') # at-ceiling intersection
      expect(exprs).to include('breathe_band_staleness_seconds >= 300')             # stale
    end

    it 'gives each dimension a breathability row (envelope + util/setpoint + activity)' do
      mem = dash.rows.find { |r| r.title == 'memory breathability' }
      # BreathabilityRow = FloorCeilingEnvelope + UtilSetpointBand + activity = 3 panels.
      expect(mem.panels.size).to eq(3)
      expect(mem.panels.map(&:kind)).to all(eq(:timeseries))
    end

    it 'closes with the deviation heatmap + worst-N rank table' do
      dev = dash.rows.last
      expect(dev.panels.map(&:kind)).to eq(%i[heatmap table])
    end

    it 'honors a custom dimension list' do
      d = Lib::HomeostasisControlBoard.build(id: :h, datasource: 'metrics', dimensions: %w[storage])
      expect(d.rows.map(&:title)).to include('storage breathability')
      expect(d.rows.map(&:title)).not_to include('cpu breathability')
    end

    it 'requires id + datasource' do
      expect { Lib::HomeostasisControlBoard.build(id: :h, datasource: '') }
        .to raise_error(ArgumentError, /datasource/)
    end
  end
end
