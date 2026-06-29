# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/pipeline_flow_overview'

# PipelineFlowOverview — the tap nervous system end-to-end: flow headline →
# broker → per-stage throughput → consumer autoscale → lag.
RSpec.describe Pangea::Dashboards::Library::PipelineFlowOverview do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  let(:stages) do
    [
      { name: 'tap',      in_counter: 'tap_received_total',      out_counter: 'tap_sent_total' },
      { name: 'broker',   in_counter: 'broker_received_total',   out_counter: 'broker_sent_total' },
      { name: 'consumer', in_counter: 'consumer_received_total', out_counter: 'consumer_sent_total' },
      { name: 'store',    in_counter: 'store_received_total',    out_counter: 'store_written_total' }
    ]
  end

  let(:dash) do
    Lib::PipelineFlowOverview.build(
      id: :tap_pipeline, name: 'Tap Pipeline', datasource: 'metrics',
      stages: stages,
      broker: { depth: 'broker_pending', lag: 'broker_consumer_lag_seconds',
                ack: 'broker_ack_total', redeliver: 'broker_redeliver_total',
                dropped: 'broker_dropped_total', group_by: %w[stream] },
      consumer_scale: { pool_roles: { desired: 'sum(consumer_desired)' },
                        max_metric: 'consumer_max', current_metric: 'consumer_current',
                        error_metric: 'consumer_scaler_errors_total' },
      lag: { hop_lag_metric: 'pipeline_hop_lag_seconds', hop_label: 'stage',
             landing_timestamp_metric: 'store_last_event_timestamp_seconds' })
  end

  it 'builds a Types::Dashboard tagged pleme-io + nervous-system' do
    expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
    expect(dash.tags).to include('pleme-io', 'pipeline', 'nervous-system')
  end

  it 'tells the flow story top-to-bottom: flow → broker → per-stage → autoscale → lag' do
    titles = dash.rows.map(&:title)
    expect(titles.first).to match(/Flow — is every hop conserving/)
    expect(titles).to include(match(/Broker —/), 'tap — received/s vs sent/s',
                              'store — received/s vs sent/s', match(/Consumer autoscale/),
                              match(/Lag —/))
  end

  it 'emits one conservation flow tile per stage in order' do
    flow = dash.rows.first
    expect(flow.panels.map(&:title)).to eq([
      'Flow · tap', 'Flow · broker', 'Flow · consumer', 'Flow · store'
    ])
    # conservation ratio out/in, floored
    expect(flow.panels.first.queries.first.expr).to include('clamp_min(sum(rate(tap_received_total[5m])), 1)')
  end

  it 'emits a per-stage throughput row for each declared stage' do
    tap = dash.rows.find { |r| r.title == 'tap — received/s vs sent/s' }
    exprs = tap.panels.map { |p| p.queries.first.expr }
    expect(exprs.join).to include('rate(tap_received_total[5m])').and include('rate(tap_sent_total[5m])')
  end

  it 'lags default the conservation in/out counters to the first/last stage' do
    lag = dash.rows.find { |r| r.title =~ /Lag —/ }
    cons = lag.panels.find { |p| p.id == :pipeline_conservation }
    expect(cons.queries[0].expr).to include('rate(tap_received_total[5m])')      # first stage in
    expect(cons.queries[1].expr).to include('rate(store_written_total[5m])')     # last stage out
  end

  it 'omits broker / autoscale / lag rows when not declared (stages-only minimal)' do
    minimal = Lib::PipelineFlowOverview.build(id: :p, datasource: 'vm', stages: stages)
    titles = minimal.rows.map(&:title)
    expect(titles.first).to match(/Flow/)
    expect(titles).not_to include(match(/Broker/), match(/autoscale/i), match(/Lag/))
  end

  it 'requires id + datasource + non-empty stages' do
    expect { Lib::PipelineFlowOverview.build(id: :x, datasource: 'vm', stages: []) }
      .to raise_error(ArgumentError, /stages/)
    expect { Lib::PipelineFlowOverview.build(id: '', datasource: 'vm', stages: stages) }
      .to raise_error(ArgumentError, /id/)
  end
end
