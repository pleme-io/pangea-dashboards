# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/security_posture_signals'
require 'pangea/dashboards/library/compliance_score_strip'
require 'pangea/dashboards/library/expiry_horizon_table'
require 'pangea/dashboards/library/age_vs_threshold_row'
require 'pangea/dashboards/library/top_n_table'

module Pangea
  module Dashboards
    module Library
      # The SECURITY-POSTURE board. Horizon/age-first, defects-first, the posture
      # story top-to-bottom:
      #
      #   Posture wall  →  SecurityPostureSignals defects (expiring-soon, stale,
      #                    past-rotation-SLA, open-violations) as a StatusOverview
      #   Compliance    →  ComplianceScoreStrip (passing/total %, failing, grace,
      #                    last-attestation-age — the provable-outcomes headline)
      #   Expiry        →  ExpiryHorizonTable (the renewal queue, soonest first)
      #   Age           →  AgeVsThresholdRow (each entity's age riding to its max-age)
      #   Violations    →  top-N open policy violations by category (TopNTable)
      #
      # Reads generic security-posture signal classes only:
      # *_expiry_timestamp_seconds, *_age_seconds, policy-violation counts,
      # compliance passing/total. A consumer supplies the metric names.
      #
      #   dash = Pangea::Dashboards::Library::SecurityPostureBoard.build(
      #     id: :security_posture, name: 'Posture', datasource: 'metrics',
      #     expiry_metric: 'cert_expiry_timestamp_seconds',
      #     age_metric: 'secret_age_seconds', max_age: 7_776_000,
      #     compliance: { passing: 'compliance_controls_passing', total: 'compliance_controls_total' },
      #     violations_metric: 'policy_violations_open')
      module SecurityPostureBoard
        # id/name:           dashboard id + human title
        # datasource:        (req) the metrics datasource uid
        # expiry_metric:     the *_expiry_timestamp_seconds gauge (expiry wall + table)
        # expiry_horizon:    "expiring within" defect horizon (default 168h = 7d)
        # age_metric:        the *_age_seconds gauge (stale wall + age row)
        # max_age:           the hard max-age ceiling (seconds OR duration)
        # rotation_sla:      the rotation SLA for the past-SLA defect (default = max_age)
        # compliance:        { passing:, total:, failing:, grace:, attestation_age: } metric names
        # violations_metric: the open-policy-violations count
        # violations_group_by: labels to rank the violations table by (default %w[category])
        def self.build(id:, datasource:, name: nil,
                       expiry_metric: nil, expiry_horizon: '168h',
                       age_metric: nil, max_age: nil, rotation_sla: nil,
                       compliance: nil, violations_metric: nil,
                       violations_group_by: %w[category], violations_severity: nil)
          validate!(id: id, datasource: datasource)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · security posture")
          b.tags('pleme-io', 'security-posture', 'security')

          # 1. Posture wall — the posture defects (expiring/stale/past-SLA/violations).
          signals = posture_signals(expiry_metric, expiry_horizon, age_metric, max_age,
                                     rotation_sla, violations_metric, violations_severity)
          b.row('Status — posture defects') do
            Library::StatusOverview.add(self, datasource: datasource, signals: signals)
          end

          # 2. Compliance — the provable-outcomes headline (optional).
          if compliance.is_a?(::Hash) && !blank?(compliance[:passing]) && !blank?(compliance[:total])
            c = compliance
            b.row('Compliance') do
              Library::ComplianceScoreStrip.add(self, datasource: datasource,
                                                passing_metric: c[:passing], total_metric: c[:total],
                                                failing_metric: c[:failing], grace_metric: c[:grace],
                                                attestation_age_metric: c[:attestation_age])
            end
          end

          # 3. Expiry horizon — the renewal queue (optional).
          unless blank?(expiry_metric)
            b.row('Expiry horizon') do
              Library::ExpiryHorizonTable.add(self, datasource: datasource, expiry_metric: expiry_metric)
            end
          end

          # 4. Age vs max-age — each entity riding to its hard ceiling (optional).
          if !blank?(age_metric) && !blank?(max_age)
            b.row('Age vs max-age') do
              Library::AgeVsThresholdRow.add(self, datasource: datasource, age_metric: age_metric, max_age: max_age)
            end
          end

          # 5. Open violations by category (optional).
          unless blank?(violations_metric)
            vsel = violations_severity ? { severity: violations_severity } : nil
            gb   = violations_group_by
            b.row('Open policy violations') do
              Library::TopNTable.add(self, datasource: datasource, metric: violations_metric,
                                     group_by: gb, agg: :sum, selector: vsel,
                                     title: 'Open violations by category')
            end
          end

          b.build
        end

        # Build whichever posture defects the metrics allow — always at least one
        # (so the wall is never empty); each present metric contributes its signal.
        def self.posture_signals(expiry_metric, expiry_horizon, age_metric, max_age,
                                 rotation_sla, violations_metric, violations_severity)
          sigs = []
          sigs << Library::SecurityPostureSignals.expiring_within(expiry_metric, expiry_horizon) \
            unless blank?(expiry_metric)
          if !blank?(age_metric) && !blank?(max_age)
            sigs << Library::SecurityPostureSignals.older_than(age_metric, max_age)
            sla = rotation_sla || max_age
            sigs << Library::SecurityPostureSignals.past_rotation_sla(age_metric, sla)
          end
          sigs << Library::SecurityPostureSignals.open_violations(violations_metric, severity: violations_severity) \
            unless blank?(violations_metric)
          # Guarantee a non-empty wall — StatusOverview requires ≥1 signal.
          if sigs.empty?
            raise ArgumentError,
                  'SecurityPostureBoard: at least one of expiry_metric / (age_metric+max_age) / ' \
                  'violations_metric is required to build the posture wall'
          end
          sigs
        end

        def self.validate!(id:, datasource:)
          raise ArgumentError, 'SecurityPostureBoard: id: required' if blank?(id)
          raise ArgumentError, 'SecurityPostureBoard: datasource: required' if blank?(datasource)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :posture_signals, :validate!, :blank?
      end
    end
  end
end
