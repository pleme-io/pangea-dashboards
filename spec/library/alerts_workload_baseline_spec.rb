# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/alerts/workload_baseline'

# Pangea::Dashboards::Library::Alerts::WorkloadBaseline — the per-workload
# alert baseline, absorbed from helmworks pleme-lareira _alerts-common.tpl +
# akeylesslabs inline kube-prometheus groups. NOT a panel: it appends an
# AlertGroup of typed AlertRules into an existing Pangea::Alerts AST. The spec
# builds an AlertsBuilder, runs .add, then .build's the AST and asserts on the
# emitted AlertRule exprs (up==0, restarts, OOMKilled reason, kubelet_volume %),
# the routing labels (severity / ntfy-topic / chart / release), and validation.
RSpec.describe Pangea::Dashboards::Library::Alerts::WorkloadBaseline do
  WB = Pangea::Dashboards::Library::Alerts::WorkloadBaseline unless defined?(WB)

  # Build an AlertsBuilder, run .add into it, return the built Alerts AST.
  def alerts_with(**kwargs)
    b = Pangea::Alerts::DSL::AlertsBuilder.new(id: :test_workload)
    b.instance_eval { namespace 'lareira' }
    WB.add(b, **kwargs)
    b.build
  end

  # Pull the single emitted group's rules indexed by name.
  def rules_by_name(ast)
    ast.groups.first.rules.to_h { |r| [r.name, r] }
  end

  describe 'the happy path (backup disabled)' do
    let(:ast) do
      alerts_with(namespace: 'lareira', ntfy_topic: 'rio-alerts',
                  chart: 'lareira-immich', release: 'immich')
    end
    let(:rules) { rules_by_name(ast) }

    it 'appends exactly one workload group at a 1m interval' do
      expect(ast.groups.size).to eq(1)
      g = ast.groups.first
      expect(g.name).to eq('lareira_immich.workload')
      expect(g.interval).to eq('1m')
    end

    it 'emits the four always-on rules (no backup rules)' do
      expect(rules.keys).to eq(%i[pod_down pod_restarting pod_oom_killed pvc_used_high])
    end

    it 'PodDown checks zero available replicas via a typed deployment selector' do
      expect(rules[:pod_down].expr)
        .to eq('kube_deployment_status_replicas_available{namespace="lareira",deployment="immich"} == 0')
      expect(rules[:pod_down].severity).to eq('warning')
      expect(rules[:pod_down].for_).to eq('5m')
    end

    it 'PodRestarting wraps a sum_increase over 1h above the restart threshold' do
      expect(rules[:pod_restarting].expr)
        .to eq('sum(increase(kube_pod_container_status_restarts_total{namespace="lareira",pod=~"immich-.*"}[1h])) > 5')
    end

    it 'PodOOMKilled matches the OOMKilled last-terminated reason' do
      expect(rules[:pod_oom_killed].expr)
        .to eq('kube_pod_container_status_last_terminated_reason{namespace="lareira",pod=~"immich-.*",reason="OOMKilled"} > 0')
      expect(rules[:pod_oom_killed].severity).to eq('critical')
    end

    it 'PvcUsedHigh divides kubelet_volume used/capacity over the pvc_pct trigger' do
      expect(rules[:pvc_used_high].expr).to eq(
        '(kubelet_volume_stats_used_bytes{namespace="lareira",persistentvolumeclaim="immich"} / ' \
        'kubelet_volume_stats_capacity_bytes{namespace="lareira",persistentvolumeclaim="immich"}) * 100 > 85'
      )
    end

    it 'stamps the ntfy / chart / release routing labels on every rule' do
      rules.each_value do |r|
        expect(r.labels).to include('ntfy-topic' => 'rio-alerts', 'chart' => 'lareira-immich', 'release' => 'immich')
      end
    end

    it 'NEVER floors an alert expr with `or vector(0)` (missing series == all-clear)' do
      rules.each_value { |r| expect(r.expr).not_to include('vector(0)') }
    end
  end

  describe 'typed-selector + custom thresholds' do
    let(:rules) do
      rules_by_name(alerts_with(namespace: 'media', ntfy_topic: 't',
                                release: 'jellyfin', restart_threshold: 10, pvc_pct: 92))
    end

    it 'threads the release into the typed pod / pvc regex + exact selectors' do
      expect(rules[:pod_restarting].expr).to include('pod=~"jellyfin-.*"')
      expect(rules[:pvc_used_high].expr).to include('persistentvolumeclaim="jellyfin"')
    end

    it 'honours the custom restart_threshold + pvc_pct triggers' do
      expect(rules[:pod_restarting].expr).to end_with('[1h])) > 10')
      expect(rules[:pvc_used_high].expr).to end_with('* 100 > 92')
    end
  end

  describe 'backup rules (enable_backup: true)' do
    let(:rules) do
      rules_by_name(alerts_with(namespace: 'lareira', ntfy_topic: 'rio-alerts',
                                release: 'forgejo', enable_backup: true, backup_stale_hours: 24))
    end

    it 'appends the two Restic backup rules after the workload four' do
      expect(rules.keys).to eq(
        %i[pod_down pod_restarting pod_oom_killed pvc_used_high restic_backup_stale restic_backup_failing]
      )
    end

    it 'ResticBackupStale compares time() against last success past backup_stale_hours (in seconds)' do
      # 24h * 3600 = 86400
      expect(rules[:restic_backup_stale].expr)
        .to eq('time() - kube_cronjob_status_last_successful_time{namespace="lareira",cronjob="forgejo-backup"} > 86400')
      expect(rules[:restic_backup_stale].severity).to eq('critical')
    end

    it 'ResticBackupFailing sums failed Jobs over 24h above 2' do
      expect(rules[:restic_backup_failing].expr)
        .to eq('sum(increase(kube_job_failed{namespace="lareira",job_name=~"forgejo-backup-.*"}[24h])) > 2')
    end
  end

  describe 'chart/release defaulting' do
    it 'derives both chart and release from namespace when omitted' do
      ast = alerts_with(namespace: 'ntfy', ntfy_topic: 'rio-alerts')
      expect(ast.groups.first.name).to eq('ntfy.workload')
      expect(ast.groups.first.rules.first.labels)
        .to include('chart' => 'ntfy', 'release' => 'ntfy')
      expect(ast.groups.first.rules.first.expr).to include('deployment="ntfy"')
    end
  end

  describe 'validation' do
    def build(**kwargs)
      b = Pangea::Alerts::DSL::AlertsBuilder.new(id: :bad)
      WB.add(b, **kwargs)
    end

    it 'rejects a missing namespace' do
      expect { build(namespace: '', ntfy_topic: 't') }
        .to raise_error(ArgumentError, /WorkloadBaseline.*namespace/)
    end

    it 'rejects a missing ntfy_topic' do
      expect { build(namespace: 'ns', ntfy_topic: nil) }
        .to raise_error(ArgumentError, /WorkloadBaseline.*ntfy_topic/)
    end

    it 'rejects a pvc_pct outside 1..100' do
      expect { build(namespace: 'ns', ntfy_topic: 't', pvc_pct: 150) }
        .to raise_error(ArgumentError, /pvc_pct/)
    end

    it 'rejects a non-AlertsBuilder collaborator' do
      expect { WB.add(Object.new, namespace: 'ns', ntfy_topic: 't') }
        .to raise_error(ArgumentError, /AlertsBuilder/)
    end
  end
end
