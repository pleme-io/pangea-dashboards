# frozen_string_literal: true

require 'pangea/alerts/dsl'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      module Alerts
        # The per-workload ALERT baseline — the alerting twin of the dashboard
        # library's StatusOverview row. Where StatusOverview makes "is anything
        # wrong?" preattentive on a screen, WorkloadBaseline makes the same
        # defect set FIRE when no one is looking: it appends one AlertGroup of
        # the canonical home-services alert rules straight into the EXISTING
        # Pangea::Alerts AST (the same typed surface the Victoria / Prometheus /
        # Datadog renderers already consume), so the alerts ship through the
        # same render path as everything else — no second alerting DSL.
        #
        # ── What it emits (one AlertRule per common workload defect) ─────────
        #   PodDown            — Deployment has zero ready replicas for N min
        #   PodRestarting      — restart count over threshold in the last hour
        #   PodOOMKilled       — last terminated reason == OOMKilled
        #   PvcUsedHigh        — kubelet_volume_stats used/capacity over pvc_pct
        #   ResticBackupStale  — no successful backup CronJob in backup_stale_hours
        #   ResticBackupFailing— backup Job failed > 2× in the last 24h
        # (the two backup rules only when enable_backup: true)
        #
        # Each rule carries the routing contract the cluster Alertmanager keys
        # off: severity + ntfy-topic + chart + release labels.
        #
        # ── Why these exprs are NOT floored with `or vector(0)` ─────────────
        # An alert condition is the opposite of a status tile: the series is
        # PRESENT only while the defect holds, so the rule fires iff the vector
        # is non-empty. Flooring `== 0` / `> N` with `or vector(0)` would either
        # pin the alert permanently firing or never — the missing series IS the
        # "all clear". So WorkloadBaseline builds selectors through Library::Promql
        # (typed `=`/`=~` matchers, never hand-concatenated) but never reaches
        # for Floor — flooring belongs to the dashboard tile, not the alert rule.
        #
        # ── Absorbed from ──────────────────────────────────────────────────
        # helmworks pleme-lareira `_alerts-common.tpl` (PodDown / PodRestarting /
        # PodOOMKilled / PvcUsedHigh / Restic{Stale,Failing}) + the akeylesslabs
        # inline kube-prometheus alert groups. One typed Ruby surface replaces
        # the hand-templated Helm + the copy-pasted inline YAML.
        #
        # ── Usage ───────────────────────────────────────────────────────────
        #   alerts = synth.alerts(:rio_lareira) do
        #     namespace 'lareira'
        #     Pangea::Dashboards::Library::Alerts::WorkloadBaseline.add(
        #       self, namespace: 'lareira', ntfy_topic: 'rio-alerts',
        #       chart: 'lareira-immich', release: 'immich',
        #       pvc_pct: 90, enable_backup: true)
        #   end
        module WorkloadBaseline
          # alerts_builder:    (req) a Pangea::Alerts::DSL::AlertsBuilder
          # namespace:         (req) the workload's K8s namespace
          # ntfy_topic:        (req) Alertmanager → ntfy routing key
          # chart / release:   workload identity (default both from namespace);
          #                     `release` drives the deployment / pvc / pod match
          # restart_threshold: PodRestarting increase()-over-1h trigger (default 5)
          # pvc_pct:           PvcUsedHigh used/capacity %% trigger (default 85)
          # backup_stale_hours:ResticBackupStale staleness in hours (default 36)
          # enable_backup:     append the two Restic backup rules (default false)
          def self.add(alerts_builder, namespace:, ntfy_topic:, chart: nil, release: nil,
                       restart_threshold: 5, pvc_pct: 85, backup_stale_hours: 36,
                       enable_backup: false)
            validate!(alerts_builder: alerts_builder, namespace: namespace, ntfy_topic: ntfy_topic,
                      restart_threshold: restart_threshold, pvc_pct: pvc_pct,
                      backup_stale_hours: backup_stale_hours)

            chart   = blank?(chart)   ? namespace.to_s : chart.to_s
            release = blank?(release) ? namespace.to_s : release.to_s
            common  = base_labels(ntfy_topic: ntfy_topic, chart: chart, release: release)

            rules = workload_rules(namespace: namespace, release: release,
                                   restart_threshold: restart_threshold, pvc_pct: pvc_pct,
                                   common: common)
            rules.concat(backup_rules(namespace: namespace, release: release,
                                      backup_stale_hours: backup_stale_hours,
                                      common: common)) if enable_backup

            group_name = "#{slug(chart)}.workload"
            alerts_builder.group group_name, interval: '1m' do
              rules.each { |r| alert r.fetch(:name), **r.reject { |k, _| k == :name } }
            end
          end

          # The four always-on workload rules. Selectors are typed Hashes the
          # Promql helper renders — never a hand-written `{namespace="…"}`.
          def self.workload_rules(namespace:, release:, restart_threshold:, pvc_pct:, common:)
            deploy_sel  = { namespace: namespace, deployment: release }
            pod_sel     = { namespace: namespace, pod: /#{Regexp.escape(release)}-.*/ }
            oom_sel     = pod_sel.merge(reason: 'OOMKilled')
            pvc_sel     = { namespace: namespace, persistentvolumeclaim: release }

            [
              {
                name: :pod_down, severity: 'warning', for: '5m',
                expr: "kube_deployment_status_replicas_available#{Promql.braces(deploy_sel)} == 0",
                labels: common,
                summary: "#{release} deployment has no ready pods",
                description: "Deployment #{namespace}/#{release} has had zero ready pods for >5m."
              },
              {
                name: :pod_restarting, severity: 'warning', for: '5m',
                expr: "#{Promql.sum_increase(metric: 'kube_pod_container_status_restarts_total', window: '1h', selector: pod_sel)} > #{restart_threshold}",
                labels: common,
                summary: "#{release} pod is restarting frequently",
                description: "Pod #{release} restarted more than #{restart_threshold} times in the last hour."
              },
              {
                name: :pod_oom_killed, severity: 'critical', for: '1m',
                expr: "kube_pod_container_status_last_terminated_reason#{Promql.braces(oom_sel)} > 0",
                labels: common,
                summary: "#{release} pod was OOMKilled",
                description: "A pod for #{release} was terminated by the OOM killer; bump the memory limit or investigate a leak."
              },
              {
                name: :pvc_used_high, severity: 'warning', for: '15m',
                expr: "(kubelet_volume_stats_used_bytes#{Promql.braces(pvc_sel)} / kubelet_volume_stats_capacity_bytes#{Promql.braces(pvc_sel)}) * 100 > #{pvc_pct}",
                labels: common,
                summary: "#{release} PVC is filling up",
                description: "PVC #{release} in #{namespace} is more than #{pvc_pct}% full."
              }
            ]
          end

          # The two backup rules, appended only when enable_backup: true.
          def self.backup_rules(namespace:, release:, backup_stale_hours:, common:)
            cron_sel = { namespace: namespace, cronjob: "#{release}-backup" }
            job_sel  = { namespace: namespace, job_name: /#{Regexp.escape(release)}-backup-.*/ }
            stale_s  = backup_stale_hours.to_i * 3600

            [
              {
                name: :restic_backup_stale, severity: 'critical', for: '30m',
                expr: "time() - kube_cronjob_status_last_successful_time#{Promql.braces(cron_sel)} > #{stale_s}",
                labels: common,
                summary: "#{release} backup is stale",
                description: "Restic backup CronJob #{release}-backup has not succeeded in over #{backup_stale_hours}h."
              },
              {
                name: :restic_backup_failing, severity: 'critical', for: '15m',
                expr: "#{Promql.sum_increase(metric: 'kube_job_failed', window: '24h', selector: job_sel)} > 2",
                labels: common,
                summary: "#{release} backup is failing",
                description: "Restic backup for #{release} failed more than 2 times in the last 24 hours."
              }
            ]
          end

          # The routing label contract every rule carries.
          def self.base_labels(ntfy_topic:, chart:, release:)
            { 'ntfy-topic' => ntfy_topic.to_s, 'chart' => chart, 'release' => release }
          end

          def self.validate!(alerts_builder:, namespace:, ntfy_topic:, restart_threshold:, pvc_pct:, backup_stale_hours:)
            unless alerts_builder.respond_to?(:group)
              raise ArgumentError, 'WorkloadBaseline: alerts_builder must be a Pangea::Alerts::DSL::AlertsBuilder (responds to #group)'
            end
            raise ArgumentError, 'WorkloadBaseline: namespace: required' if blank?(namespace)
            raise ArgumentError, 'WorkloadBaseline: ntfy_topic: required' if blank?(ntfy_topic)
            raise ArgumentError, "WorkloadBaseline: restart_threshold must be a non-negative number (got #{restart_threshold.inspect})" \
              unless restart_threshold.is_a?(Numeric) && restart_threshold >= 0
            raise ArgumentError, "WorkloadBaseline: pvc_pct must be in 1..100 (got #{pvc_pct.inspect})" \
              unless pvc_pct.is_a?(Numeric) && pvc_pct.positive? && pvc_pct <= 100
            raise ArgumentError, "WorkloadBaseline: backup_stale_hours must be a positive number (got #{backup_stale_hours.inspect})" \
              unless backup_stale_hours.is_a?(Numeric) && backup_stale_hours.positive?
          end

          def self.blank?(v) = v.nil? || v.to_s.strip.empty?
          def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
          private_class_method :workload_rules, :backup_rules, :base_labels, :validate!, :blank?, :slug
        end
      end
    end
  end
end
