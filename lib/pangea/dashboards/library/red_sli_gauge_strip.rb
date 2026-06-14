# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # A horizontal STRIP of error-rate gauges, one tile per subsystem (or
      # object-kind / controller / queue), each reading the RED error-ratio
      #
      #   sum(increase(metric{error}[w])) / sum(increase(metric[w]))
      #
      # over a window baked into the title, coloured green→amber→red by the
      # shared defect thresholds. It answers "which subsystem is erroring, and
      # how badly?" in one preattentive glance — a red tile in a row of green
      # is FOUND, not read.
      #
      # Absorbed from the akeyless-community external-secrets dashboard's
      # per-object-kind RED-gauge-SLI strip (one gauge per ExternalSecret /
      # ClusterSecretStore / PushSecret object kind), generalised to any
      # `{ name:, extra_selector: }` subsystem partition over any counter that
      # carries an error/result label.
      #
      # ── Why the increase-ratio (not a raw rate) ─────────────────────────
      # An SLI is a FRACTION — errors as a share of total over the window — so
      # the gauge reads a unit-less ratio (percentunit 0–1) that means the same
      # thing regardless of traffic volume. `increase()` over a fixed window is
      # the count delta; the error count over the total count is the error
      # budget burn. Both legs go through Promql.sum_increase so the matcher
      # syntax is never hand-written.
      #
      # ── Why one fixed window baked into the title ───────────────────────
      # The denominator and numerator MUST share the window (else the ratio is
      # meaningless), so the window is one knob, and naming it in the title
      # ("errors (15m)") tells the operator exactly what the gauge measures
      # without a second look.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Error-rate SLI by object kind' do
      #     Pangea::Dashboards::Library::RedSliGaugeStrip.add(
      #       self, datasource: 'vm',
      #       metric: 'externalsecret_sync_calls_total',
      #       error_label_match: 'result=~"error|requeue"',
      #       subsystems: [
      #         { name: 'ExternalSecret',     extra_selector: { kind: 'ExternalSecret' } },
      #         { name: 'ClusterSecretStore', extra_selector: { kind: 'ClusterSecretStore' } },
      #         { name: 'PushSecret',         extra_selector: { kind: 'PushSecret' } },
      #       ])
      #   end
      module RedSliGaugeStrip
        # datasource:        (req) the metrics datasource
        # metric:            (req) the *_total counter carrying an error label
        # error_label_match: the matcher that isolates error results — a typed
        #                    Hash/String/Regexp/Array fed through Promql; the
        #                    default `result=~"error|requeue"` is the
        #                    external-secrets shape.
        # subsystems:        (req) non-empty Array of { name:, extra_selector: }
        #                    where extra_selector partitions the metric (typed
        #                    Hash preferred) — one gauge tile per entry.
        # window:            shared increase window for both legs (default 15m).
        # warn / crit:       error-ratio thresholds (default 0.01 / 0.05 — 1% /
        #                    5% error budget) driving Theme.defect_steps.
        # title_suffix:      optional cosmetic suffix on the panel title.
        def self.add(row, datasource:, metric:, subsystems:,
                     error_label_match: 'result=~"error|requeue"',
                     window: '15m', warn: 0.01, crit: 0.05, title_suffix: nil)
          validate!(datasource: datasource, metric: metric, subsystems: subsystems)
          width = Theme.tile_width(subsystems.length)
          steps = Theme.defect_steps(warn: warn, crit: crit)
          subsystems.each_with_index do |sub, idx|
            add_gauge(row, sub.transform_keys(&:to_sym),
                      datasource: datasource, metric: metric,
                      error_label_match: error_label_match, window: window,
                      steps: steps, width: width, title_suffix: title_suffix, idx: idx)
          end
        end

        def self.add_gauge(row, sub, datasource:, metric:, error_label_match:,
                           window:, steps:, width:, title_suffix:, idx:)
          name  = sub.fetch(:name)
          extra = sub[:extra_selector]
          # Numerator: increase of error-result events for THIS subsystem.
          err_sel   = merge_selectors(extra, error_label_match)
          numerator = Promql.sum_increase(metric: metric, window: window, selector: err_sel)
          # Denominator: increase of ALL events for THIS subsystem.
          total     = Promql.sum_increase(metric: metric, window: window, selector: extra)
          expr      = "#{numerator} / #{total}"
          ttl       = title_suffix ? "#{name} #{title_suffix}" : "#{name} errors (#{window})"
          pid       = :"red_sli_#{slug(name)}_#{idx}"
          w         = width
          row.panel pid, kind: :gauge, width: w, height: Theme::STAT_H do
            title ttl
            unit 'percentunit'  # unit-less ratio 0–1 → rendered as a %
            min 0
            max 1
            description "Error ratio over #{window} — errors / total for #{name}."
            graph :none
            # continuous: the ratio is defined whenever traffic exists; an
            # idle subsystem reads NaN/no-data, which is the honest answer for
            # a divide-by-zero denominator (NOT a floored 0).
            query 'A', expr, datasource: datasource, presence: :continuous
            threshold steps: steps
          end
        end

        # Combine the per-subsystem partition selector with the error-result
        # matcher into ONE typed selector. A Hash extra merges with a Hash
        # error match; a String/Regexp/Array error match (the default) is
        # AND-joined onto the rendered partition body via Promql.selector_body
        # so the matcher syntax is never hand-concatenated.
        def self.merge_selectors(extra, error_match)
          if extra.is_a?(::Hash) && error_match.is_a?(::Hash)
            return extra.merge(error_match)
          end

          parts = [Promql.selector_body(extra), Promql.selector_body(error_match)]
                  .reject { |b| b.nil? || b.empty? }
          parts.join(',')
        end

        def self.validate!(datasource:, metric:, subsystems:)
          raise ArgumentError, 'RedSliGaugeStrip: datasource: required' if blank?(datasource)
          raise ArgumentError, 'RedSliGaugeStrip: metric: required' if blank?(metric)
          raise ArgumentError, 'RedSliGaugeStrip: subsystems must be a non-empty Array' \
            unless subsystems.is_a?(::Array) && !subsystems.empty?
          subsystems.each do |s|
            raise ArgumentError, "RedSliGaugeStrip: each subsystem must be a Hash (got #{s.inspect})" \
              unless s.is_a?(::Hash)
            h = s.transform_keys(&:to_sym)
            raise ArgumentError, "RedSliGaugeStrip: each subsystem needs :name (got #{s.inspect})" \
              if blank?(h[:name])
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_gauge, :merge_selectors, :validate!, :blank?, :slug
      end
    end
  end
end
