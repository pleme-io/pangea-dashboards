# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/datastore_query_row'

# DatastoreQueryRow — datastore-shaped golden signals: QPS + query latency
# (gauge OR histogram, by latency_is_histogram) + floored slow + floored error.
RSpec.describe Pangea::Dashboards::Library::DatastoreQueryRow do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'gauge-latency mode (cache style) — all four legs' do
    let(:built) do
      row_with do |r|
        Lib::DatastoreQueryRow.add(r, datasource: 'vm', selector: { db: 'cache' },
          qps_metric: 'redis_commands_total', latency_metric: 'redis_command_latency_seconds',
          latency_is_histogram: false, slow_metric: 'redis_slow_total', error_metric: 'redis_errors_total')
      end
    end

    it 'emits QPS, latency, slow, errors panels' do
      titles = built.panels.map(&:title)
      expect(titles).to include('QPS', 'Query latency', 'Slow queries', 'Query errors')
    end

    it 'floors the QPS rate with or vector(0) (event-driven)' do
      qps = built.panels.find { |p| p.title == 'QPS' }
      expect(qps.queries.first.expr).to eq('sum(rate(redis_commands_total{db="cache"}[5m])) or vector(0)')
      expect(qps.queries.first.presence).to eq(:event_driven)
    end

    it 'reads the latency gauge directly (no histogram_quantile) and stays continuous' do
      lat = built.panels.find { |p| p.title == 'Query latency' }
      expect(lat.queries.size).to eq(1)
      expect(lat.queries.first.expr).to eq('redis_command_latency_seconds{db="cache"}')
      expect(lat.queries.first.expr).not_to include('histogram_quantile')
      expect(lat.queries.first.presence).to eq(:continuous)
    end

    it 'floors the slow + error legs (event-driven)' do
      slow = built.panels.find { |p| p.title == 'Slow queries' }
      err  = built.panels.find { |p| p.title == 'Query errors' }
      expect(slow.queries.first.expr).to include('or vector(0)')
      expect(err.queries.first.expr).to include('or vector(0)')
      expect(slow.queries.first.presence).to eq(:event_driven)
      expect(err.queries.first.presence).to eq(:event_driven)
    end
  end

  describe 'histogram-latency mode (relational style)' do
    let(:built) do
      row_with do |r|
        Lib::DatastoreQueryRow.add(r, datasource: 'vm',
          qps_metric: 'pg_queries_total', latency_metric: 'pg_query_duration_seconds_bucket',
          latency_is_histogram: true, quantiles: [0.95, 0.99])
      end
    end

    it 'emits a histogram_quantile per quantile and stays continuous' do
      lat = built.panels.find { |p| p.title == 'Query latency' }
      expect(lat.queries.size).to eq(2)
      expect(lat.queries.map(&:expr)).to all(include('histogram_quantile'))
      expect(lat.queries.first.expr).to include('histogram_quantile(0.95')
      expect(lat.queries.map(&:presence)).to all(eq(:continuous))
    end

    it 'omits the slow/error panels when their metrics are not given' do
      expect(built.panels.map(&:title)).to eq(['QPS', 'Query latency'])
    end
  end

  describe 'validation' do
    it 'requires datasource, qps_metric, latency_metric' do
      expect { row_with { |r| Lib::DatastoreQueryRow.add(r, datasource: '', qps_metric: 'q', latency_metric: 'l') } }
        .to raise_error(ArgumentError, /datasource/)
      expect { row_with { |r| Lib::DatastoreQueryRow.add(r, datasource: 'vm', qps_metric: nil, latency_metric: 'l') } }
        .to raise_error(ArgumentError, /qps_metric/)
      expect { row_with { |r| Lib::DatastoreQueryRow.add(r, datasource: 'vm', qps_metric: 'q', latency_metric: '  ') } }
        .to raise_error(ArgumentError, /latency_metric/)
    end
  end
end
