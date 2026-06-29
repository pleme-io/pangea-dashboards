# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/scale_to_zero_efficiency_board'

# ScaleToZeroEfficiencyBoard — the breathing rhythm: defects → posture →
# wake history → cost at rest → autoscale.
RSpec.describe Pangea::Dashboards::Library::ScaleToZeroEfficiencyBoard do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  let(:dash) do
    Lib::ScaleToZeroEfficiencyBoard.build(
      id: :s2z, name: 'Scale-to-zero', datasource: 'metrics',
      replica_metric: 'kube_deployment_status_replicas',
      max_replica_metric: 'kube_deployment_spec_replicas',
      wake_counter: 'keda_scaledobject_activations_total',
      cold_start_metric: 'workload_cold_start_seconds', cold_start_budget: 30,
      unit_cost: 0.12, selector: { namespace: 'apps' })
  end

  it 'builds a Types::Dashboard tagged pleme-io + scale-to-zero' do
    expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
    expect(dash.tags).to include('pleme-io', 'scale-to-zero', 'breathe')
  end

  it 'opens defects-first then posture → wake history → cost → (no autoscale)' do
    titles = dash.rows.map(&:title)
    expect(titles.first).to match(/Status — is the breathing rhythm healthy/)
    expect(titles).to include('Sleep/wake posture', match(/Wake history/), match(/Cost at rest/))
    expect(titles).not_to include(match(/Autoscale/)) # not declared
  end

  it 'headline defect tiles count awake workloads + slow cold starts, colour-flooded' do
    status = dash.rows.first
    awake = status.panels.find { |p| p.title == 'Awake (not at rest)' }
    cold  = status.panels.find { |p| p.title == 'Slow cold starts' }
    expect(awake).not_to be_nil
    expect(awake.display_mode).to eq(:background)
    expect(awake.queries.first.expr).to include('kube_deployment_status_replicas{namespace="apps"} >= 1')
    expect(cold).not_to be_nil
    expect(cold.queries.first.expr).to include('workload_cold_start_seconds{namespace="apps"} > 30')
  end

  it 'wake history is a step series + wake-rate overlay' do
    wake = dash.rows.find { |r| r.title =~ /Wake history/ }.panels.first
    expect(wake.options.dig(:grafana, :fieldConfig, :defaults, :custom, :lineInterpolation)).to eq('stepAfter')
    expect(wake.queries.map(&:ref)).to eq(%w[A B])
  end

  it 'cost-at-rest threads the unit cost + max-replica baseline through' do
    cost = dash.rows.find { |r| r.title =~ /Cost at rest/ }.panels.first
    expect(cost.queries[0].expr).to include('* 0.12')
    expect(cost.queries[1].expr).to include('sum(kube_deployment_spec_replicas{namespace="apps"}) * 0.12')
  end

  it 'pulls in the autoscale row when consumer_scale is given' do
    d = Lib::ScaleToZeroEfficiencyBoard.build(
      id: :s2z2, datasource: 'vm', replica_metric: 'replicas',
      consumer_scale: { pool_roles: { desired: 'sum(desired)' } })
    expect(d.rows.map(&:title)).to include(match(/Autoscale/))
  end

  it 'works with no cold-start metric (one headline defect tile)' do
    d = Lib::ScaleToZeroEfficiencyBoard.build(id: :s, datasource: 'vm', replica_metric: 'replicas')
    expect(d.rows.first.panels.map(&:title)).to eq(['Awake (not at rest)'])
  end

  it 'requires id + datasource + replica_metric' do
    expect { Lib::ScaleToZeroEfficiencyBoard.build(id: :x, datasource: '', replica_metric: 'r') }
      .to raise_error(ArgumentError, /datasource/)
    expect { Lib::ScaleToZeroEfficiencyBoard.build(id: :x, datasource: 'vm', replica_metric: nil) }
      .to raise_error(ArgumentError, /replica_metric/)
  end
end
