# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/replication_health_row'

# ReplicationHealthRow — the primary↔standby replication-health composite,
# absorbed from the cloud_native_pg PG panels (repl lag + streaming +
# connections-near-max + cache_hit). Builds a RowBuilder, runs .add, asserts
# on the EMITTED PromQL text, the panel kind/width/presence, and thresholds.
RSpec.describe Pangea::Dashboards::Library::ReplicationHealthRow do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'happy path — full PG replication row' do
    let(:built) do
      row_with do |r|
        Lib::ReplicationHealthRow.add(r, datasource: 'vm',
          lag_metric: 'cnpg_pg_replication_lag',
          streaming_metric: 'cnpg_pg_replication_streaming_replicas',
          connections_metric: 'cnpg_backends_total',
          max_connections_metric: 'cnpg_pg_settings_max_connections',
          cache_hit_expr: 'blks_hit / (blks_hit + blks_read)')
      end
    end

    it 'emits the lag timeseries + three liveness/defect stat tiles' do
      expect(built.panels.map(&:kind)).to eq(%i[timeseries stat stat stat])
      expect(built.panels.map(&:title)).to eq([
        'Replication · lag',
        'Replication · streaming replicas',
        'Replication · connections near max',
        'Replication · cache hit'
      ])
    end

    it 'renders the lag panel as a thresholded seconds timeseries (half-width)' do
      lag = built.panels.first
      expect(lag.kind).to eq(:timeseries)
      expect(lag.unit).to eq('s')
      expect(lag.width).to eq(Theme.half)
      expect(lag.queries.first.expr).to eq('max(cnpg_pg_replication_lag)')
      expect(lag.queries.first.presence).to eq(:continuous)
      # green → amber (lag_warn 5) → red (lag_crit 30)
      expect(lag.thresholds.steps.map(&:color)).to eq(%w[green orange red])
      expect(lag.thresholds.steps.map(&:value)).to eq([nil, 5.0, 30.0])
    end

    it 'renders streaming replicas as a liveness stat (lower = worse)' do
      s = built.panels.find { |p| p.title =~ /streaming replicas/ }
      expect(s.kind).to eq(:stat)
      expect(s.display_mode).to eq(:background)
      expect(s.queries.first.expr).to eq('max(cnpg_pg_replication_streaming_replicas)')
      # liveness: red below ok, green at/above
      expect(s.thresholds.steps.map(&:color)).to eq(%w[red green])
    end

    it 'computes connections-near-max as a 0–100 percent with defect thresholds' do
      c = built.panels.find { |p| p.title =~ /connections near max/ }
      expect(c.unit).to eq('percent')
      expect(c.max).to eq(100)
      expect(c.queries.first.expr)
        .to eq('100 * max(cnpg_backends_total) / max(cnpg_pg_settings_max_connections)')
      expect(c.thresholds.steps.map(&:value)).to eq([nil, 80.0, 95.0])
    end

    it 'scales the cache-hit ratio to a liveness percent' do
      ch = built.panels.find { |p| p.title =~ /cache hit/ }
      expect(ch.unit).to eq('percent')
      expect(ch.queries.first.expr).to eq('100 * (blks_hit / (blks_hit + blks_read))')
      expect(ch.thresholds.steps.map(&:color)).to eq(%w[red green])
    end

    it 'gives the stat tiles a uniform tile-strip width' do
      stats = built.panels.select { |p| p.kind == :stat }
      expect(stats.map(&:width)).to all(eq(Theme.tile_width(3)))
    end
  end

  describe 'typed-selector case — in_recovery_metric drives the lag selector' do
    it 'groups the lag onto the standby (in-recovery) members' do
      built = row_with do |r|
        Lib::ReplicationHealthRow.add(r, datasource: 'vm',
          lag_metric: 'pg_replication_lag',
          streaming_metric: 'pg_streaming_replicas',
          in_recovery_metric: 'pg_in_recovery')
      end
      lag = built.panels.first
      expect(lag.queries.first.expr).to eq('max(pg_replication_lag{pg_in_recovery="1"})')
    end

    it 'omits the optional tiles when their metrics are absent (lag + streaming only)' do
      built = row_with do |r|
        Lib::ReplicationHealthRow.add(r, datasource: 'vm',
          lag_metric: 'pg_replication_lag', streaming_metric: 'pg_streaming_replicas')
      end
      expect(built.panels.size).to eq(2)
      expect(built.panels.map(&:kind)).to eq(%i[timeseries stat])
      # one stat → it fills the whole tile strip
      expect(built.panels.last.width).to eq(Theme.tile_width(1))
    end

    it 'honours a custom title as the per-panel prefix and id slug' do
      built = row_with do |r|
        Lib::ReplicationHealthRow.add(r, datasource: 'vm',
          lag_metric: 'lag', streaming_metric: 'reps', title: 'PG cluster')
      end
      expect(built.panels.first.id).to eq(:repl_lag_pg_cluster)
      expect(built.panels.map(&:title)).to all(start_with('PG cluster · '))
    end
  end

  describe 'validation' do
    it 'requires a datasource' do
      expect { row_with { |r| Lib::ReplicationHealthRow.add(r, datasource: nil, lag_metric: 'l', streaming_metric: 's') } }
        .to raise_error(ArgumentError, /ReplicationHealthRow: datasource/)
    end

    it 'requires a lag_metric' do
      expect { row_with { |r| Lib::ReplicationHealthRow.add(r, datasource: 'vm', lag_metric: '', streaming_metric: 's') } }
        .to raise_error(ArgumentError, /lag_metric/)
    end

    it 'requires a streaming_metric' do
      expect { row_with { |r| Lib::ReplicationHealthRow.add(r, datasource: 'vm', lag_metric: 'l', streaming_metric: nil) } }
        .to raise_error(ArgumentError, /streaming_metric/)
    end
  end
end
