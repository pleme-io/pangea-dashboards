# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'

module Pangea
  module Dashboards
    module Library
      # The HEADLINE of a dashboard's story: a single row of colour-flooded
      # stat tiles, one per common DEFECT the workload can exhibit, each red
      # when firing and green when not. It answers "is anything wrong right
      # now?" in one preattentive glance — before the operator reads a single
      # number, the presence (or absence) of red tells them where to look.
      #
      # This is the "optimise the dashboard around the most common defects"
      # rule made concrete: the author enumerates the failure modes they watch
      # for (not-converging, stuck, failing, stale, throttled…) as typed
      # Signals; the component renders them as the first thing the eye lands
      # on. Everything below the overview is drill-down.
      #
      # ── Why colour-flooded tiles (display: :background) ─────────────────
      # Preattentive processing: hue + luminance are perceived in <200ms,
      # before reading. A red tile in a row of green is FOUND, not parsed.
      # Reserving colour for status (the rest of the dashboard stays neutral)
      # keeps that signal strong — a rainbow dashboard hides its own alarms.
      #
      # ── Why `or vector(0)` on every signal ──────────────────────────────
      # A defect counter has no series until the defect first occurs. Without
      # the fallback a healthy workload's tile reads "No data" — ambiguous
      # (broken? or fine?). `or vector(0)` makes healthy = a green 0, so the
      # overview is honest and always lit.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Status — is anything wrong?' do
      #     Pangea::Dashboards::Library::StatusOverview.add(
      #       self, datasource: ds, signals: [
      #         { name: 'Bands not converging', expr: 'count(...)', warn: 1, crit: 5,
      #           desc: 'Bands whose util is >20% off setpoint.' },
      #         { name: 'Conflicts /s', expr: 'sum(rate(...[5m]))', warn: 0.01, unit: 'cps' },
      #       ])
      #   end
      module StatusOverview
        # Emit the defect tiles into `row`. `signals` is an Array of Hashes:
        #   name:  (req) tile title — short, the defect not the metric
        #   expr:  (req) PromQL that evaluates to the defect's magnitude
        #   warn:  threshold to turn amber (default 1)
        #   crit:  threshold to turn red (default = warn; nil → amber only)
        #   unit:  Grafana unit (default 'short')
        #   desc:  panel description (the "what does red mean + do" note)
        #   datasource: per-signal override of the row default
        #   id:    panel id symbol (default derived from name)
        def self.add(row, signals:, datasource: nil)
          validate!(signals: signals, datasource: datasource)
          width = Theme.tile_width(signals.length)
          signals.each_with_index do |sig, idx|
            add_signal(row, sig.transform_keys(&:to_sym), default_ds: datasource, width: width, idx: idx)
          end
        end

        def self.add_signal(row, sig, default_ds:, width:, idx:)
          name = sig.fetch(:name)
          expr = sig.fetch(:expr)
          ds   = sig[:datasource] || default_ds
          warn = sig.fetch(:warn, 1)
          crit = sig.fetch(:crit, warn)
          unit = sig.fetch(:unit, 'short')
          desc = sig[:desc]
          pid  = sig[:id] || :"status_#{slug(name)}_#{idx}"
          q    = ensure_zero_floor(expr)
          steps = Theme.defect_steps(warn: warn, crit: crit)
          w = width
          row.panel pid, kind: :stat, width: w, height: Theme::STAT_H do
            title name
            unit unit
            description(desc) if desc
            display :background      # colour the whole tile — preattentive status
            graph :area              # trend sparkline behind the number (Tufte)
            # event_driven: a green 0 is healthy, NEVER "broken metric".
            query 'A', q, datasource: ds, presence: :event_driven
            threshold steps: steps
          end
        end

        # Append `or vector(0)` unless the expr already guarantees a value, so
        # a never-fired defect reads a green 0 instead of ambiguous no-data.
        # Delegates to the shared Library::Floor primitive (solve-once).
        def self.ensure_zero_floor(expr) = Floor.zero(expr)

        def self.validate!(signals:, datasource:)
          raise ArgumentError, 'StatusOverview: signals must be a non-empty Array' \
            unless signals.is_a?(Array) && !signals.empty?
          signals.each do |s|
            h = s.transform_keys(&:to_sym)
            raise ArgumentError, "StatusOverview: each signal needs :name (got #{s.inspect})" if blank?(h[:name])
            raise ArgumentError, "StatusOverview: signal #{h[:name].inspect} needs :expr" if blank?(h[:expr])
            raise ArgumentError, "StatusOverview: signal #{h[:name].inspect} needs a datasource" \
              if blank?(h[:datasource]) && blank?(datasource)
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_signal, :ensure_zero_floor, :blank?, :slug
      end
    end
  end
end
