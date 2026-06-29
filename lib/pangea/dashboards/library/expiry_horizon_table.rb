# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The EXPIRY-HORIZON table — ONE instant `:table` of every cert / secret /
      # token sorted by HOW LONG UNTIL IT EXPIRES, nearest first:
      #
      #   sort(*_expiry_timestamp_seconds - time())
      #
      # so the rows about to lapse sit at the top and the operator reads the
      # renewal queue in order. The value is seconds-to-expiry; a negative value
      # is already-expired (the worst rows). Threshold cell-colouring marks the
      # urgency horizons (red < red_horizon, amber < amber_horizon).
      #
      # ── Why instant + sort (not topk) ───────────────────────────────────────
      # The operator wants the WHOLE list ordered by urgency (a renewal queue),
      # not just the worst N — so it is `sort(...)` (ascending: most-negative /
      # soonest first), evaluated instant as a now-snapshot. The horizon
      # thresholds colour each row's seconds-to-expiry.
      #
      # ── Why continuous (no floor) ───────────────────────────────────────────
      # An expiry timestamp is a gauge that always has a value while the entity
      # exists; a vanished entity SHOULD drop out, not read a misleading floored
      # 0 (which would look like "expires now"). So presence is :continuous,
      # never floored.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Expiry horizon' do
      #     Pangea::Dashboards::Library::ExpiryHorizonTable.add(
      #       self, datasource: 'metrics',
      #       expiry_metric: 'cert_expiry_timestamp_seconds')
      #   end
      module ExpiryHorizonTable
        # datasource:    (req) the metrics datasource uid
        # expiry_metric: (req) the absolute *_expiry_timestamp_seconds gauge
        # selector:      typed Hash/String scoping the population
        # red_horizon:   seconds-to-expiry below which a row is red (default 7d)
        # amber_horizon: seconds-to-expiry below which a row is amber (default 30d)
        # legend_labels: per-row legend template (default '{{name}}')
        # title:         cosmetic override
        def self.add(row, datasource:, expiry_metric:, selector: nil,
                     red_horizon: 604_800, amber_horizon: 2_592_000,
                     legend_labels: '{{name}}', title: nil)
          validate!(datasource: datasource, expiry_metric: expiry_metric)
          braces = Promql.braces(selector)
          expr   = "sort(#{expiry_metric}#{braces} - time())"
          pid    = :"expiry_horizon_#{slug(expiry_metric)}"
          # LOWER seconds-to-expiry = worse, so the ladder is red→amber→green
          # from the bottom: red below red_horizon, amber below amber_horizon,
          # green above. Expressed as ascending threshold steps.
          steps = [
            { color: Theme::CRIT, value: nil },
            { color: Theme::WARN, value: red_horizon.to_f },
            { color: Theme::OK,   value: amber_horizon.to_f }
          ]
          row.panel pid, kind: :table, width: Theme.full, height: Theme::TABLE_H do
            title title || 'Expiry horizon (seconds to expiry, soonest first)'
            unit 's'
            description 'Certs/secrets/tokens ordered by time-to-expiry. Negative ⇒ ' \
                        "already expired. Red < #{red_horizon}s, amber < #{amber_horizon}s."
            # gauge state — always has a current value; NOT floored.
            query 'A', expr, datasource: datasource, instant: true, presence: :continuous, legend: legend_labels
            threshold steps: steps
          end
        end

        def self.validate!(datasource:, expiry_metric:)
          raise ArgumentError, 'ExpiryHorizonTable: datasource: required' if blank?(datasource)
          raise ArgumentError, 'ExpiryHorizonTable: expiry_metric: required' if blank?(expiry_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :validate!, :blank?, :slug
      end
    end
  end
end
