# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/pipeline_flow_strip'

# PipelineFlowStrip — one conservation-coloured :stat tile per declared stage,
# in order. The number is the floored out/in ratio; the colour is the liveness
# ladder (a leaky hop reads amber/red).
RSpec.describe Pangea::Dashboards::Library::PipelineFlowStrip do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  let(:stages) do
    [
      { name: 'tap',    in_counter: 'tap_recv_total',    out_counter: 'tap_sent_total' },
      { name: 'broker', in_counter: 'broker_recv_total', out_counter: 'broker_sent_total' },
      { name: 'store',  in_counter: 'store_recv_total',  out_counter: 'store_written_total' }
    ]
  end

  let(:built) { row_with { |r| Lib::PipelineFlowStrip.add(r, datasource: 'vm', stages: stages) } }

  it 'emits one :stat tile per stage in declared order' do
    expect(built.panels.size).to eq(3)
    expect(built.panels.map(&:kind)).to all(eq(:stat))
    expect(built.panels.map(&:title)).to eq(['Flow · tap', 'Flow · broker', 'Flow · store'])
  end

  it 'computes a floored out/in conservation ratio (clamp_min on the denominator)' do
    tap = built.panels.first
    expr = tap.queries.first.expr
    expect(expr).to include('rate(tap_sent_total[5m])')
    expect(expr).to include('clamp_min(sum(rate(tap_recv_total[5m])), 1)')
    expect(expr).to include('or vector(0)') # floored
  end

  it 'colours each tile preattentively (background) with a liveness ladder' do
    tap = built.panels.first
    expect(tap.display_mode).to eq(:background)
    expect(tap.unit).to eq('percentunit')
    # liveness: green at/above leak_ok, red below — lower ratio = leakier
    expect(tap.thresholds.steps.map(&:color)).to eq(%w[red green])
    expect(tap.thresholds.steps.last.value).to eq(0.95)
  end

  it 'honours a custom leak_ok ratio + a per-stage selector' do
    b = row_with do |r|
      Lib::PipelineFlowStrip.add(r, datasource: 'vm', leak_ok: 0.8, stages: [
        { name: 'tap', in_counter: 'a_total', out_counter: 'b_total', selector: { node: 'n1' } }
      ])
    end
    p = b.panels.first
    expect(p.thresholds.steps.last.value).to eq(0.8)
    expect(p.queries.first.expr).to include('rate(b_total{node="n1"}[5m])')
  end

  it 'tiles use a uniform width that fills the grid' do
    expect(built.panels.map(&:width)).to all(eq(Theme.tile_width(3)))
  end

  it 'validates datasource + non-empty stages + per-stage required keys' do
    expect { row_with { |r| Lib::PipelineFlowStrip.add(r, datasource: '', stages: stages) } }
      .to raise_error(ArgumentError, /datasource/)
    expect { row_with { |r| Lib::PipelineFlowStrip.add(r, datasource: 'vm', stages: []) } }
      .to raise_error(ArgumentError, /non-empty Array/)
    expect { row_with { |r| Lib::PipelineFlowStrip.add(r, datasource: 'vm', stages: [{ name: 'x', in_counter: 'a' }]) } }
      .to raise_error(ArgumentError, /out_counter/)
  end
end
