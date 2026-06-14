# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/autoscaler_pool_strip'

# AutoscalerPoolStrip — the overview-strip atom that grids pool-cardinality
# gauges + an optional current-vs-max replica timeline + an optional floored
# scaler-error rate. Asserts the emitted PromQL, panel kind/width/presence,
# and validation rejection. Loads standalone (no library.rb wiring).
RSpec.describe Pangea::Dashboards::Library::AutoscalerPoolStrip do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  let(:pool_roles) do
    {
      desired: 'sum(github_runner_scale_set_desired_replicas)',
      idle:    'sum(github_runner_scale_set_idle_runners)',
      running: 'sum(github_runner_scale_set_running_jobs)'
    }
  end

  describe 'pool-cardinality gauge tiles (happy path)' do
    let(:built) do
      row_with { |r| Lib::AutoscalerPoolStrip.add(r, datasource: 'vm', pool_roles: pool_roles) }
    end

    it 'emits one :gauge tile per pool role, in declared order' do
      gauges = built.panels.select { |p| p.kind == :gauge }
      expect(gauges.size).to eq(3)
      expect(gauges.map(&:title)).to eq(%w[Desired Idle Running])
    end

    it 'tiles each gauge at the Theme.tile_width for the role count' do
      gauges = built.panels.select { |p| p.kind == :gauge }
      expect(gauges.map(&:width)).to all(eq(Theme.tile_width(3)))
      expect(gauges.map(&:height)).to all(eq(Theme::STAT_H))
    end

    it 'floors each gauge expr so an idle pool reads a true 0 (event_driven)' do
      desired = built.panels.first
      expect(desired.queries.first.expr).to eq('sum(github_runner_scale_set_desired_replicas) or vector(0)')
      expect(desired.queries.first.presence).to eq(:event_driven)
      expect(desired.min).to eq(0)
    end

    it 'omits the replica timeline + error rate when their metrics are absent' do
      expect(built.panels.map(&:kind)).to all(eq(:gauge))
    end
  end

  describe 'current-vs-max replica timeline + scaler errors with a typed selector' do
    let(:built) do
      row_with do |r|
        Lib::AutoscalerPoolStrip.add(r, datasource: 'vm', pool_roles: pool_roles,
          max_metric: 'kube_horizontalpodautoscaler_spec_max_replicas',
          current_metric: 'kube_horizontalpodautoscaler_status_current_replicas',
          error_metric: 'keda_scaler_errors_total',
          selector: { scaledobject: 'runners' })
      end
    end

    it 'draws current + max as two continuous series with the selector applied' do
      ts = built.panels.find { |p| p.id == :autoscaler_replicas }
      expect(ts.kind).to eq(:timeseries)
      expect(ts.width).to eq(Theme.two_thirds)
      expect(ts.queries.map(&:legend_format)).to eq(%w[current max])
      expect(ts.queries.map(&:presence)).to all(eq(:continuous))
      expect(ts.queries.first.expr)
        .to eq('sum(kube_horizontalpodautoscaler_status_current_replicas{scaledobject="runners"}) or vector(0)')
      expect(ts.queries.last.expr)
        .to eq('sum(kube_horizontalpodautoscaler_spec_max_replicas{scaledobject="runners"}) or vector(0)')
    end

    it 'floors the scaler-error rate through RateWithZeroFloor with the selector' do
      err = built.panels.find { |p| p.id == :autoscaler_errors_keda_scaler_errors_total }
      expect(err.kind).to eq(:timeseries)
      expect(err.queries.first.presence).to eq(:event_driven)
      expect(err.queries.first.expr)
        .to eq('sum(rate(keda_scaler_errors_total{scaledobject="runners"}[5m])) or vector(0)')
    end
  end

  describe 'validation' do
    it 'rejects an empty pool_roles Hash' do
      expect { row_with { |r| Lib::AutoscalerPoolStrip.add(r, datasource: 'vm', pool_roles: {}) } }
        .to raise_error(ArgumentError, /AutoscalerPoolStrip.*pool_roles/)
    end

    it 'rejects a missing datasource' do
      expect { row_with { |r| Lib::AutoscalerPoolStrip.add(r, datasource: nil, pool_roles: pool_roles) } }
        .to raise_error(ArgumentError, /AutoscalerPoolStrip.*datasource/)
    end

    it 'rejects a blank role expr' do
      expect { row_with { |r| Lib::AutoscalerPoolStrip.add(r, datasource: 'vm', pool_roles: { desired: '' }) } }
        .to raise_error(ArgumentError, /AutoscalerPoolStrip.*desired/)
    end
  end
end
