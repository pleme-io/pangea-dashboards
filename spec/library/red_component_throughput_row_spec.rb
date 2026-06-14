# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/red_component_throughput_row'

# RedComponentThroughputRow — the ingest→egress pipeline RED throughput row.
# Builds a RowBuilder, runs .add, asserts on the emitted PromQL + panel shape
# (kind/width/presence) + the validation contract.
RSpec.describe Pangea::Dashboards::Library::RedComponentThroughputRow do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'the events-only happy path' do
    let(:built) do
      row_with do |r|
        Lib::RedComponentThroughputRow.add(r, datasource: 'vm',
          in_counter: 'vector_component_received_events_total',
          out_counter: 'vector_component_sent_events_total')
      end
    end

    it 'emits exactly two half-width received/s + sent/s timeseries' do
      expect(built.panels.size).to eq(2)
      expect(built.panels.map(&:kind)).to all(eq(:timeseries))
      expect(built.panels.map(&:width)).to all(eq(Theme.half))
      expect(built.panels.map(&:title)).to eq(['Throughput · received/s', 'Throughput · sent/s'])
    end

    it 'floors each leg as sum by(component_id)(rate(counter[5m])) or vector(0)' do
      received = built.panels.first
      sent     = built.panels.last
      expect(received.queries.first.expr)
        .to eq('sum by (component_id)(rate(vector_component_received_events_total[5m])) or vector(0)')
      expect(sent.queries.first.expr)
        .to eq('sum by (component_id)(rate(vector_component_sent_events_total[5m])) or vector(0)')
    end

    it 'marks each leg event_driven with a per-component legend' do
      expect(built.panels.map { |p| p.queries.first.presence }).to all(eq(:event_driven))
      expect(built.panels.map { |p| p.queries.first.legend_format }).to all(eq('{{component_id}}'))
    end
  end

  describe 'the four-leg variant with byte counters' do
    let(:built) do
      row_with do |r|
        Lib::RedComponentThroughputRow.add(r, datasource: 'vm',
          in_counter: 'dapr_in_total', out_counter: 'dapr_out_total',
          in_bytes_counter: 'dapr_in_bytes_total', out_bytes_counter: 'dapr_out_bytes_total',
          component_label: 'app_id', window: '1m', title: 'Pipeline')
      end
    end

    it 'emits four third-width legs so the whole story fits one row' do
      expect(built.panels.size).to eq(4)
      expect(built.panels.map(&:width)).to all(eq(Theme.tile_width(4)))
      expect(built.panels.map(&:title)).to eq([
        'Pipeline · received/s', 'Pipeline · sent/s',
        'Pipeline · received bytes/s', 'Pipeline · sent bytes/s'
      ])
    end

    it 'honours the typed component_label + window in every floored expr' do
      expect(built.panels.last.queries.first.expr)
        .to eq('sum by (app_id)(rate(dapr_out_bytes_total[1m])) or vector(0)')
      expect(built.panels.last.queries.first.legend_format).to eq('{{app_id}}')
    end

    it 'gives the byte legs a Bps unit and the event legs a cps unit' do
      expect(built.panels.map(&:unit)).to eq(%w[cps cps Bps Bps])
    end
  end

  describe 'validation' do
    it 'rejects a missing datasource' do
      expect { row_with { |r| Lib::RedComponentThroughputRow.add(r, datasource: nil,
        in_counter: 'a_total', out_counter: 'b_total') } }
        .to raise_error(ArgumentError, /RedComponentThroughputRow.*datasource/)
    end

    it 'rejects a blank in_counter / out_counter' do
      expect { row_with { |r| Lib::RedComponentThroughputRow.add(r, datasource: 'vm',
        in_counter: '', out_counter: 'b_total') } }
        .to raise_error(ArgumentError, /in_counter/)
      expect { row_with { |r| Lib::RedComponentThroughputRow.add(r, datasource: 'vm',
        in_counter: 'a_total', out_counter: nil) } }
        .to raise_error(ArgumentError, /out_counter/)
    end
  end
end
