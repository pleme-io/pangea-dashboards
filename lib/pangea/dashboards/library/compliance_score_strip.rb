# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'

module Pangea
  module Dashboards
    module Library
      # The COMPLIANCE-SCORE strip — the Viggy provable-outcomes promise rendered
      # as a headline. A horizontal strip of `:stat`/`:gauge` tiles answering "is
      # our compliance posture green RIGHT NOW?":
      #
      #   • Compliance score (gauge, percentunit) — controls_passing / controls_total.
      #     LIVENESS-coloured (lower = worse): green at/above the pass bar.
      #   • Controls failing (stat) — defect-coloured (higher = worse).
      #   • Controls in grace (stat) — neutral/amber count of grace-period controls.
      #   • Last attestation age (stat, seconds) — how fresh the proof is; a stale
      #     attestation is itself a posture defect (the chain stopped renewing).
      #
      # The "compliance is a continuously-attested theorem, not a quarterly
      # audit" stance as a one-glance read — an auditor sees the live score, not
      # a spreadsheet.
      #
      # ── Why a ratio gauge + count stats ─────────────────────────────────────
      # The SCORE is a fraction (passing/total) that means the same at any
      # control-set size → a percentunit gauge with liveness steps. The failing /
      # grace counts are absolute numbers → defect/neutral stats. Attestation age
      # is a freshness gauge → a stat with a defect ladder on staleness.
      #
      # ── Why continuous on the score, event_driven on counts ─────────────────
      # passing/total + attestation age are gauges always present while the
      # attestation chain runs → :continuous (a real 0 score is distinct from
      # no-data — a divide-by-zero on an absent control set reads no-data, honest).
      # The failing/grace counts are floored event_driven so a clean fleet reads a
      # lit green 0.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Compliance' do
      #     Pangea::Dashboards::Library::ComplianceScoreStrip.add(
      #       self, datasource: 'metrics',
      #       passing_metric: 'compliance_controls_passing',
      #       total_metric: 'compliance_controls_total',
      #       failing_metric: 'compliance_controls_failing',
      #       grace_metric: 'compliance_controls_in_grace',
      #       attestation_age_metric: 'compliance_last_attestation_age_seconds')
      #   end
      module ComplianceScoreStrip
        # datasource:             (req) the metrics datasource uid
        # passing_metric:         (req) count of passing controls
        # total_metric:           (req) count of total controls
        # failing_metric:         optional count of failing controls (defect stat)
        # grace_metric:           optional count of in-grace controls (neutral stat)
        # attestation_age_metric: optional last-attestation-age gauge (seconds)
        # selector:               typed Hash/String scoping the control set
        # pass_bar:               score at/above which the gauge reads green (default 0.95)
        # stale_after:            attestation age (s) that turns the freshness stat red (default 1d)
        def self.add(row, datasource:, passing_metric:, total_metric:,
                     failing_metric: nil, grace_metric: nil, attestation_age_metric: nil,
                     selector: nil, pass_bar: 0.95, stale_after: 86_400)
          validate!(datasource: datasource, passing_metric: passing_metric, total_metric: total_metric)
          braces  = Promql.braces(selector)
          tiles   = count_tiles(failing_metric, grace_metric, attestation_age_metric)
          width   = Theme.tile_width(tiles)
          score_expr = "sum(#{passing_metric}#{braces}) / sum(#{total_metric}#{braces})"

          # 1. the compliance SCORE gauge (liveness — green at/above the pass bar).
          row.panel :compliance_score, kind: :gauge, width: width, height: Theme::STAT_H do
            title 'Compliance score'
            unit 'percentunit'
            min 0
            max 1
            description 'Controls passing / total. Green at/above the pass bar; ' \
                        'the live provable-outcomes posture, not a quarterly audit.'
            graph :none
            query 'A', score_expr, datasource: datasource, presence: :continuous
            threshold steps: Theme.liveness_steps(ok: pass_bar)
          end

          # 2. controls failing (defect).
          unless blank?(failing_metric)
            row.panel :compliance_failing, kind: :stat, width: width, height: Theme::STAT_H do
              title 'Controls failing'
              unit 'short'
              description 'Controls currently failing. RED ⇒ a control is out of compliance.'
              display :background
              graph :area
              query 'A', Floor.zero("sum(#{failing_metric}#{braces})"), datasource: datasource, presence: :event_driven
              threshold steps: Theme.defect_steps(warn: 1, crit: 5)
            end
          end

          # 3. controls in grace (neutral count — amber-ish, value-coloured).
          unless blank?(grace_metric)
            row.panel :compliance_grace, kind: :stat, width: width, height: Theme::STAT_H do
              title 'Controls in grace'
              unit 'short'
              description 'Controls within a remediation grace window — watch, not yet failing.'
              display :value
              graph :area
              query 'A', Floor.zero("sum(#{grace_metric}#{braces})"), datasource: datasource, presence: :event_driven
              threshold steps: Theme.defect_steps(warn: 1)
            end
          end

          # 4. last attestation age (freshness — a stale proof is a defect).
          unless blank?(attestation_age_metric)
            row.panel :compliance_attestation_age, kind: :stat, width: width, height: Theme::STAT_H do
              title 'Last attestation age'
              unit 's'
              description 'Age of the freshest attestation. RED ⇒ the proof chain stopped renewing.'
              display :background
              graph :area
              query 'A', "max(#{attestation_age_metric}#{braces})", datasource: datasource, presence: :continuous
              threshold steps: Theme.defect_steps(warn: stale_after.to_f / 2, crit: stale_after.to_f)
            end
          end
        end

        def self.count_tiles(*optional_metrics)
          # the score gauge is always present; each optional metric adds one tile.
          1 + optional_metrics.count { |m| !blank?(m) }
        end

        def self.validate!(datasource:, passing_metric:, total_metric:)
          raise ArgumentError, 'ComplianceScoreStrip: datasource: required' if blank?(datasource)
          raise ArgumentError, 'ComplianceScoreStrip: passing_metric: required' if blank?(passing_metric)
          raise ArgumentError, 'ComplianceScoreStrip: total_metric: required' if blank?(total_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :count_tiles, :validate!, :blank?
      end
    end
  end
end
