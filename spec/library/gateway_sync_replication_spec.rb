# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/gateway_sync_replication'

# GatewaySyncReplication — the fleet config-convergence board.
RSpec.describe Pangea::Dashboards::Library::GatewaySyncReplication do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  describe 'happy path' do
    let(:dash) do
      Lib::GatewaySyncReplication.build(
        id: :gw_sync, name: 'Gateway Sync', datasource: 'metrics', logs_datasource: 'logs',
        sync_lag_metric: 'gateway_sync_lag_seconds', synced_members_metric: 'gateway_synced_members',
        version_metric: 'gateway_applied_config_generation', version_label: 'applied_version',
        stream: '{namespace="gateway"}'
      )
    end

    it 'returns a Types::Dashboard tagged pleme-io + gateway-sync-replication' do
      expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
      expect(dash.tags).to include('pleme-io', 'gateway-sync-replication')
    end

    it 'rows are in story order: defects → sync health → per-version → cache → sync RED → logs' do
      expect(dash.rows.map(&:title)).to eq([
        'Status — config-convergence defects',
        'Config sync health',
        'Per-version posture',
        'Cache effectiveness',
        'Sync — RED',
        'Logs'
      ])
    end

    it 'the defect headline carries the sync-lag-breach count + a version-skew tile + cache-cold' do
      defects = dash.rows.find { |r| r.title == 'Status — config-convergence defects' }
      exprs = defects.panels.map { |p| p.queries.first.expr }.join("\n")
      expect(exprs).to include('gateway_sync_lag_seconds')
      expect(exprs).to include('>= 120')
      expect(exprs).to include('!= scalar(max(')
      expect(exprs).to include('< 90') # cold-cache count
    end

    it 'the per-version posture is a by-phase stacked strip over the version label' do
      pv = dash.rows.find { |r| r.title == 'Per-version posture' }
      p = pv.panels.first
      expect(p.queries.first.expr).to include('sum by (applied_version)(gateway_applied_config_generation')
    end

    it 'the sync-health row uses ReplicationHealthRow with the lag + synced-member metrics' do
      sh = dash.rows.find { |r| r.title == 'Config sync health' }
      exprs = sh.panels.flat_map { |p| p.queries.map(&:expr) }.join("\n")
      expect(exprs).to include('gateway_sync_lag_seconds')
      expect(exprs).to include('gateway_synced_members')
    end
  end

  describe 'optional cache row' do
    it 'omits the cache row + the cold-cache defect when no cache given' do
      d = Lib::GatewaySyncReplication.build(id: :x, datasource: 'vm',
        sync_lag_metric: 'l', synced_members_metric: 'm', version_metric: 'v', cache: nil)
      expect(d.rows.map(&:title)).not_to include('Cache effectiveness')
      defects = d.rows.find { |r| r.title == 'Status — config-convergence defects' }
      expect(defects.panels.size).to eq(2) # lag-breach + version-skew only
    end
  end

  describe 'validation' do
    it 'requires id + datasource + lag/member/version metrics' do
      expect { Lib::GatewaySyncReplication.build(id: :x, datasource: 'vm',
        sync_lag_metric: '', synced_members_metric: 'm', version_metric: 'v') }
        .to raise_error(ArgumentError, /sync_lag_metric/)
      expect { Lib::GatewaySyncReplication.build(id: :x, datasource: 'vm',
        sync_lag_metric: 'l', synced_members_metric: 'm', version_metric: nil) }
        .to raise_error(ArgumentError, /version_metric/)
    end
  end
end
