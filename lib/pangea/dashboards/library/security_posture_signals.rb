# frozen_string_literal: true

require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # A FAMILY of StatusOverview SIGNAL builders (NOT panels) for the four
      # canonical security-posture defects. Each returns the typed
      # { name:, expr:, warn:, crit:, desc: } Hash that slots straight into
      # StatusOverview.add(signals: [...]) — siblings of AtCeilingDefectTile.signal
      # and NewEntityWindowSignal. The board enumerates the posture defects it
      # watches; these builders own the PromQL.
      #
      #   • expiring_within(metric, horizon) — certs/secrets/tokens whose
      #     *_expiry_timestamp_seconds is within `horizon` of now. The "about to
      #     expire" wall. `count(metric - time() <= horizon)`.
      #   • older_than(age_metric, max_age) — entities whose *_age_seconds exceeds
      #     a hard maximum. The "stale / overdue" wall. `count(age >= max_age)`.
      #   • past_rotation_sla(age_metric, sla, sla_metric:) — secrets/keys older
      #     than their rotation SLA. A specialisation of older_than against a
      #     per-entity SLA gauge (intersection) or a flat SLA constant.
      #   • open_violations(metric, severity:) — open policy violations, optionally
      #     filtered to a severity. `sum(metric{severity})`.
      #
      # ── Why count(...) is honest without a floor ────────────────────────────
      # Each builder is a `count(...)` / `sum(...)` over a comparison — an empty
      # match IS the value 0, so the healthy "0 expiring / 0 stale / 0 open"
      # reads green without `or vector(0)`.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   sigs = [
      #     Pangea::Dashboards::Library::SecurityPostureSignals.expiring_within(
      #       'cert_expiry_timestamp_seconds', '168h'),       # 7d
      #     Pangea::Dashboards::Library::SecurityPostureSignals.older_than(
      #       'secret_age_seconds', '7776000'),               # 90d
      #     Pangea::Dashboards::Library::SecurityPostureSignals.open_violations(
      #       'policy_violations_open', severity: 'high'),
      #   ]
      #   StatusOverview.add(self, datasource: ds, signals: sigs)
      module SecurityPostureSignals
        module_function

        # certs/secrets/tokens within `horizon` of expiry (an absolute
        # *_expiry_timestamp_seconds gauge). horizon is a PromQL duration ('168h')
        # or a number of seconds.
        def expiring_within(expiry_metric, horizon, selector: nil, warn: 1, crit: 5,
                            name: nil, desc: nil)
          raise ArgumentError, 'SecurityPostureSignals.expiring_within: expiry_metric required' if blank?(expiry_metric)
          raise ArgumentError, 'SecurityPostureSignals.expiring_within: horizon required' if blank?(horizon)
          braces = Promql.braces(selector)
          secs   = to_seconds(horizon)
          {
            name: name || "Expiring within #{horizon}",
            expr: "count((#{expiry_metric}#{braces} - time()) <= #{secs})",
            warn: warn, crit: crit,
            desc: desc || "Entities whose expiry is within #{horizon}. RED ⇒ rotate/renew before they lapse."
          }
        end

        # entities whose *_age_seconds gauge exceeds a hard maximum age.
        def older_than(age_metric, max_age, selector: nil, warn: 1, crit: 5,
                       name: nil, desc: nil)
          raise ArgumentError, 'SecurityPostureSignals.older_than: age_metric required' if blank?(age_metric)
          raise ArgumentError, 'SecurityPostureSignals.older_than: max_age required' if blank?(max_age)
          braces = Promql.braces(selector)
          secs   = to_seconds(max_age)
          {
            name: name || "Older than #{max_age}",
            expr: "count(#{age_metric}#{braces} >= #{secs})",
            warn: warn, crit: crit,
            desc: desc || "Entities older than #{max_age}. RED ⇒ overdue — replace/rotate."
          }
        end

        # secrets/keys past their rotation SLA. With `sla_metric:` the per-entity
        # SLA gauge is matched on identity (age >= its own SLA); otherwise a flat
        # `sla` constant applies fleet-wide.
        def past_rotation_sla(age_metric, sla = nil, sla_metric: nil, identity_labels: %w[name],
                              selector: nil, warn: 1, crit: 5, name: nil, desc: nil)
          raise ArgumentError, 'SecurityPostureSignals.past_rotation_sla: age_metric required' if blank?(age_metric)
          braces = Promql.braces(selector)
          age    = "#{age_metric}#{braces}"
          expr =
            if !blank?(sla_metric)
              "count((#{age} >=#{on(identity_labels)} #{sla_metric}#{braces}))"
            else
              raise ArgumentError, 'SecurityPostureSignals.past_rotation_sla: sla or sla_metric required' if blank?(sla)
              "count(#{age} >= #{to_seconds(sla)})"
            end
          {
            name: name || 'Past rotation SLA',
            expr: expr,
            warn: warn, crit: crit,
            desc: desc || 'Secrets/keys older than their rotation SLA. RED ⇒ rotation is overdue.'
          }
        end

        # open policy violations, optionally filtered to a severity.
        def open_violations(violations_metric, severity: nil, severity_label: 'severity',
                            selector: nil, warn: 1, crit: 10, name: nil, desc: nil)
          raise ArgumentError, 'SecurityPostureSignals.open_violations: violations_metric required' if blank?(violations_metric)
          sel = selector
          unless blank?(severity)
            sel = (selector.is_a?(::Hash) ? selector.dup : {}).merge(severity_label.to_sym => severity)
          end
          braces = Promql.braces(sel)
          label  = severity ? "Open #{severity} violations" : 'Open policy violations'
          {
            name: name || label,
            expr: "sum(#{violations_metric}#{braces})",
            warn: warn, crit: crit,
            desc: desc || 'Open policy violations. RED ⇒ a compliance posture is broken.'
          }
        end

        # ` on (a, b)` clause for the per-entity SLA intersection.
        def on(labels)
          Promql.by(labels).sub('by (', 'on (')
        end

        # Pass a PromQL duration ('168h', '90d') through verbatim; a bare number
        # is already seconds. Promql will see a literal either way.
        def to_seconds(v)
          v.to_s
        end

        def blank?(v) = v.nil? || v.to_s.strip.empty?
      end
    end
  end
end
