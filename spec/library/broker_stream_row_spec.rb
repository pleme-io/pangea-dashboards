# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/broker_stream_row'

# BrokerStreamRow — depth + lag (continuous gauges) + ack/redeliver + dropped
# (floored event-driven rates), generic over any broker by metric injection.
RSpec.describe Pangea::Dashboards::Library::BrokerStreamRow do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'full broker (NATS JetStream shape)' do
    let(:built) do
      row_with do |r|
        Lib::BrokerStreamRow.add(r, datasource: 'vm',
          depth_metric: 'nats_consumer_num_pending',
          lag_metric: 'nats_consumer_ack_floor_age_seconds',
          ack_counter: 'nats_consumer_delivered_total',
          redeliver_counter: 'nats_consumer_num_redelivered_total',
          dropped_counter: 'nats_consumer_num_terminated_total',
          group_by: %w[stream consumer])
      end
    end

    it 'emits depth + lag + ack/redeliver + dropped panels' do
      ids = built.panels.map(&:id)
      expect(ids).to include(:broker_depth, :broker_lag, :broker_ack_redeliver)
      expect(ids.any? { |i| i.to_s.start_with?('broker_dropped') }).to be(true)
    end

    it 'depth + lag are continuous gauges (NEVER floored), grouped by the labels' do
      depth = built.panels.find { |p| p.id == :broker_depth }
      lag   = built.panels.find { |p| p.id == :broker_lag }
      expect(depth.queries.first.presence).to eq(:continuous)
      expect(depth.queries.first.expr).to eq('sum by (stream, consumer)(nats_consumer_num_pending)')
      expect(depth.queries.first.expr).not_to include('vector(0)')
      expect(lag.queries.first.expr).to eq('max by (stream, consumer)(nats_consumer_ack_floor_age_seconds)')
      expect(lag.unit).to eq('s')
    end

    it 'ack vs redeliver are two floored event-driven rates on one panel' do
      ar = built.panels.find { |p| p.id == :broker_ack_redeliver }
      expect(ar.queries.map(&:ref)).to eq(%w[A B])
      expect(ar.queries.map(&:presence)).to all(eq(:event_driven))
      expect(ar.queries[0].expr).to include('rate(nats_consumer_delivered_total[5m])').and include('or vector(0)')
      expect(ar.queries[1].expr).to include('rate(nats_consumer_num_redelivered_total[5m])')
      expect(ar.queries.map(&:legend_format)).to eq(['ack {{stream}}/{{consumer}}', 'redeliver {{stream}}/{{consumer}}'])
    end

    it 'dropped is a floored RateWithZeroFloor leg' do
      dropped = built.panels.find { |p| p.id.to_s.start_with?('broker_dropped') }
      expect(dropped.queries.first.expr).to include('rate(nats_consumer_num_terminated_total[5m])').and include('or vector(0)')
      expect(dropped.queries.first.presence).to eq(:event_driven)
    end
  end

  describe 'minimal broker (depth only)' do
    it 'emits just the depth panel when only depth_metric is given' do
      built = row_with { |r| Lib::BrokerStreamRow.add(r, datasource: 'vm', depth_metric: 'kafka_consumergroup_lag') }
      expect(built.panels.map(&:id)).to eq([:broker_depth])
    end
  end

  it 'requires datasource + depth_metric' do
    expect { row_with { |r| Lib::BrokerStreamRow.add(r, datasource: nil, depth_metric: 'd') } }
      .to raise_error(ArgumentError, /datasource/)
    expect { row_with { |r| Lib::BrokerStreamRow.add(r, datasource: 'vm', depth_metric: '') } }
      .to raise_error(ArgumentError, /depth_metric/)
  end
end
