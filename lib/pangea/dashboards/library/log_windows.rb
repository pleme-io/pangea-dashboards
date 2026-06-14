# frozen_string_literal: true

module Pangea
  module Dashboards
    module Library
      # The canonical VictoriaLogs (LogsQL) log section for any workload's
      # dashboard. Emits — in order — a full-context log table, a DEDICATED
      # **error-logs window** (error-class lines only, the fast-triage panel),
      # and an error-rate stat with traffic-light thresholds.
      #
      # ── Why the error-logs window is mandatory ──────────────────────────
      # A raw "all logs" table on a chatty workload (a reconcile loop emitting
      # an INFO line per object per tick) buries the 2 error lines that matter
      # in thousands of ShadowWouldApply/reconciled lines. The error window is
      # the same stream pre-filtered to error class, so "is anything wrong?"
      # is answerable in one glance — no scrolling, no manual LogsQL. Every
      # dashboard that has logs gets one.
      #
      # ── The error filter ────────────────────────────────────────────────
      # pleme-vector's `log_level_normalize` transform maps every error-class
      # input (err/error/fatal/critical) to the normalized field `level:error`,
      # so a `level`-based filter is both precise (no substring false-matches
      # like "no errors found") and complete. The default also matches the
      # raw fatal/critical/panic levels for streams that skip normalization.
      #
      # ── Usage (inside a monitor block) ──────────────────────────────────
      #   row 'Logs' do
      #     Pangea::Dashboards::Library::LogWindows.add_all(
      #       self,
      #       name: 'pangea-operator',
      #       stream: '{namespace="pangea-system",app="pangea-operator"}',
      #       datasource: logs
      #     )
      #   end
      #
      # Backend note: these are LogsQL (VictoriaLogs). The Grafana renderer
      # maps the vlogs datasource to the victoriametrics-logs-datasource
      # plugin; the panels are table/stat kinds the renderer already supports.
      module LogWindows
        # Precise, level-first error filter. `level:error` catches everything
        # `log_level_normalize` folded into the error class; the extra raw
        # levels cover un-normalized streams. Override `error_filter:` for a
        # workload with a bespoke severity convention.
        DEFAULT_ERROR_FILTER =
          'level:error OR level:fatal OR level:critical OR level:panic'

        # Emit the whole canonical log section into `row`.
        #
        # @param row [DSL::RowBuilder] the enclosing row
        # @param name [String] human label + panel-id slug source
        # @param stream [String] LogsQL stream selector, e.g. '{namespace="x",app="y"}'
        # @param datasource [String] logs datasource uid (vlogs)
        # @param error_filter [String] LogsQL error predicate (default above)
        # @param full_logs [Boolean] also emit the all-lines table (default true)
        def self.add_all(row, name:, stream:, datasource:,
                         error_filter: DEFAULT_ERROR_FILTER, full_logs: true)
          validate!(name: name, stream: stream, datasource: datasource, error_filter: error_filter)
          add_full_logs(row, name: name, stream: stream, datasource: datasource) if full_logs
          add_error_window(row, name: name, stream: stream, datasource: datasource, error_filter: error_filter)
          add_error_rate(row, name: name, stream: stream, datasource: datasource, error_filter: error_filter)
        end

        # The full-context log table — every line, for deep reading.
        def self.add_full_logs(row, name:, stream:, datasource:)
          slug = slug_for(name)
          row.panel :"#{slug}_logs", kind: :table do
            title "#{name} logs (last window)"
            description 'All log lines for this workload — full context. Use the ' \
                        'ERROR window below for fast triage.'
            query 'A', stream, datasource: datasource, instant: true
          end
        end

        # THE ERROR-LOGS WINDOW — error-class lines only, for fast parsing.
        def self.add_error_window(row, name:, stream:, datasource:, error_filter: DEFAULT_ERROR_FILTER)
          slug = slug_for(name)
          q = "#{stream} #{error_filter}"
          row.panel :"#{slug}_error_logs", kind: :table do
            title "#{name} — ERROR logs (last window)"
            description 'Error-class log lines only ' \
                        "(#{error_filter}) — the fast-triage window. Empty = no errors."
            # event_driven: an empty error window on a healthy workload is
            # GOOD (no errors), never broken — the Health probe must not flag it.
            query 'A', q, datasource: datasource, instant: true, presence: :event_driven
          end
        end

        # Error lines per second — a one-glance "is the error rate climbing?".
        def self.add_error_rate(row, name:, stream:, datasource:, error_filter: DEFAULT_ERROR_FILTER)
          slug = slug_for(name)
          q = "#{stream} #{error_filter} | stats count() errors"
          row.panel :"#{slug}_error_rate", kind: :stat do
            title "#{name} — error log lines / sec"
            unit 'logs/s'
            description 'Rate of error-class log lines. Green = none.'
            query 'A', q, datasource: datasource, presence: :event_driven
            threshold steps: [
              { color: 'green',  value: nil },
              { color: 'yellow', value: 1 },
              { color: 'red',    value: 5 }
            ]
          end
        end

        # ── typed input validation (fail loud at synth time) ───────────────
        def self.validate!(name:, stream:, datasource:, error_filter:)
          raise ArgumentError, 'LogWindows: name required' if blank?(name)
          raise ArgumentError, 'LogWindows: datasource uid required' if blank?(datasource)
          raise ArgumentError, 'LogWindows: error_filter required' if blank?(error_filter)
          raise ArgumentError, 'LogWindows: stream required' if blank?(stream)
          unless stream.to_s.include?('{')
            raise ArgumentError,
                  'LogWindows: stream must be a LogsQL stream selector like ' \
                  "{namespace=\"x\",app=\"y\"}, got: #{stream.inspect}"
          end
        end

        def self.blank?(value)
          value.nil? || value.to_s.strip.empty?
        end

        def self.slug_for(name)
          name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        end

        private_class_method :blank?, :slug_for
      end
    end
  end
end
