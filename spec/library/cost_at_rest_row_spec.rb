# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/cost_at_rest_row'

# CostAtRestRow — actual footprint (Σ replicas × unit_cost) vs always-on baseline
# on one timeseries + a liveness savings %. Both legs are continuous gauge
# derivations (never floored counters).
RSpec.describe Pangea::Dashboards::Library::CostAtRestRow do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'with a max-replica baseline' do
    let(:built) do
      row_with do |r|
        Lib::CostAtRestRow.add(r, datasource: 'vm',
          replica_metric: 'kube_deployment_status_replicas',
          max_replica_metric: 'kube_deployment_spec_replicas',
          unit_cost: 0.12, selector: { namespace: 'apps' }, currency: 'currencyUSD')
      end
    end

    it 'emits a cost-vs-baseline timeseries + a savings % stat' do
      expect(built.panels.map(&:id)).to eq(%i[cost_at_rest cost_savings_pct])
      expect(built.panels.first.kind).to eq(:timeseries)
      expect(built.panels.last.kind).to eq(:stat)
    end

    it 'actual = Σ replicas × unit_cost; baseline = Σ max × unit_cost (continuous)' do
      cost = built.panels.first
      expect(cost.queries[0].expr).to eq('sum(kube_deployment_status_replicas{namespace="apps"}) * 0.12')
      expect(cost.queries[1].expr).to eq('sum(kube_deployment_spec_replicas{namespace="apps"}) * 0.12')
      expect(cost.queries.map(&:presence)).to all(eq(:continuous))
      expect(cost.queries.map(&:expr)).to all(satisfy { |e| !e.include?('vector(0)') })
      expect(cost.unit).to eq('currencyUSD')
    end

    it 'savings % = 1 - actual/baseline, liveness-coloured (higher = more saved)' do
      savings = built.panels.last
      expect(savings.unit).to eq('percentunit')
      expect(savings.queries.first.expr).to include('1 - ((sum(kube_deployment_status_replicas{namespace="apps"}) * 0.12)')
      expect(savings.queries.first.expr).to include('clamp_min(sum(kube_deployment_spec_replicas{namespace="apps"}) * 0.12, 1)')
      expect(savings.thresholds.steps.map(&:color)).to eq(%w[red green])
    end
  end

  describe 'without a max-replica baseline' do
    it 'falls back to count × unit_cost (one replica each) as the baseline' do
      built = row_with do |r|
        Lib::CostAtRestRow.add(r, datasource: 'vm', replica_metric: 'replicas', unit_cost: 2)
      end
      expect(built.panels.first.queries[1].expr).to eq('count(replicas) * 2')
    end
  end

  it 'requires datasource + replica_metric + a positive numeric unit_cost' do
    expect { row_with { |r| Lib::CostAtRestRow.add(r, datasource: '', replica_metric: 'r') } }
      .to raise_error(ArgumentError, /datasource/)
    expect { row_with { |r| Lib::CostAtRestRow.add(r, datasource: 'vm', replica_metric: nil) } }
      .to raise_error(ArgumentError, /replica_metric/)
    expect { row_with { |r| Lib::CostAtRestRow.add(r, datasource: 'vm', replica_metric: 'r', unit_cost: 0) } }
      .to raise_error(ArgumentError, /unit_cost/)
  end
end
