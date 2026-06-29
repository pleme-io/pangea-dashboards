# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/pipeline_lag_row'

# PipelineLagRow — per-hop lag + end-to-end wall-clock lag (time() - max(ts)) +
# ingest-vs-egress conservation. Lag legs are continuous gauges; the conservation
# legs are floored event-driven rates.
RSpec.describe Pangea::Dashboards::Library::PipelineLagRow do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'full lag row' do
    let(:built) do
      row_with do |r|
        Lib::PipelineLagRow.add(r, datasource: 'vm',
          hop_lag_metric: 'pipeline_hop_lag_seconds', hop_label: 'stage',
          landing_timestamp_metric: 'store_last_event_timestamp_seconds',
          in_counter: 'tap_received_total', out_counter: 'store_written_total')
      end
    end

    it 'emits per-hop lag + end-to-end lag + conservation panels' do
      expect(built.panels.map(&:id)).to eq(%i[pipeline_hop_lag pipeline_end_to_end_lag pipeline_conservation])
    end

    it 'per-hop lag is a continuous max-by-hop gauge' do
      hop = built.panels.find { |p| p.id == :pipeline_hop_lag }
      expect(hop.queries.first.expr).to eq('max by (stage)(pipeline_hop_lag_seconds)')
      expect(hop.queries.first.presence).to eq(:continuous)
      expect(hop.queries.first.legend_format).to eq('{{stage}}')
      expect(hop.unit).to eq('s')
    end

    it 'end-to-end lag is time() minus the freshest landing timestamp' do
      e2e = built.panels.find { |p| p.id == :pipeline_end_to_end_lag }
      expect(e2e.queries.first.expr).to eq('time() - max(store_last_event_timestamp_seconds)')
      expect(e2e.queries.first.presence).to eq(:continuous)
    end

    it 'conservation overlays floored ingest/s vs egress/s' do
      cons = built.panels.find { |p| p.id == :pipeline_conservation }
      expect(cons.queries.map(&:ref)).to eq(%w[A B])
      expect(cons.queries.map(&:presence)).to all(eq(:event_driven))
      expect(cons.queries[0].expr).to include('rate(tap_received_total[5m])').and include('or vector(0)')
      expect(cons.queries[1].expr).to include('rate(store_written_total[5m])')
      expect(cons.queries.map(&:legend_format)).to eq(['ingest/s', 'egress/s'])
    end
  end

  describe 'minimal lag row (per-hop only)' do
    it 'emits just the per-hop panel when nothing else is given' do
      built = row_with { |r| Lib::PipelineLagRow.add(r, datasource: 'vm', hop_lag_metric: 'lag_s') }
      expect(built.panels.map(&:id)).to eq([:pipeline_hop_lag])
    end
  end

  it 'requires datasource + hop_lag_metric' do
    expect { row_with { |r| Lib::PipelineLagRow.add(r, datasource: '', hop_lag_metric: 'l') } }
      .to raise_error(ArgumentError, /datasource/)
    expect { row_with { |r| Lib::PipelineLagRow.add(r, datasource: 'vm', hop_lag_metric: nil) } }
      .to raise_error(ArgumentError, /hop_lag_metric/)
  end
end
