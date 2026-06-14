# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The USE-style Go-runtime row for ANY Go process exposing the standard
      # `go_*` + `process_*` Prometheus metrics — every kubebuilder controller,
      # every dapr sidecar, every Go gateway emits this exact surface. Absorbed
      # from burst_forge_dashboard's "Gateway Internals" block (go_memstats_*,
      # go_goroutines, go_gc_duration_seconds) and the dapr Go-runtime block,
      # lifted into ONE typed component so a runtime row is one call over a
      # typed process selector instead of six near-identical hand-rolled panels.
      #
      # ── The USE mapping (Utilization / Saturation / Errors) per signal ──
      # • :cpu        — process_cpu_seconds_total rate: kernel+user CPU the
      #                 process burns (Utilization). event_driven counter → floored.
      # • :goroutines — go_goroutines: a runaway count is the canonical Go
      #                 SATURATION proxy (leaked goroutines pile up unbounded).
      # • :heap       — go_memstats_heap_inuse_bytes: live heap (Utilization of
      #                 the memory envelope); paired with process RSS/virtual.
      # • :gc         — rate(go_gc_duration_seconds_sum): GC time burned per
      #                 second — the runtime's stop-the-world tax (Saturation).
      # • :uptime     — time() - process_start_time_seconds: a liveness stat
      #                 that resets to ~0 on every crash/restart (lower = worse).
      #
      # ── Why one panel per requested signal in `show` ───────────────────
      # The author picks exactly the runtime facets that matter for their
      # process; unrequested signals emit nothing (no empty tiles). Order
      # follows `show` so the row reads in the author's intended priority.
      #
      # ── Usage ──────────────────────────────────────────────────────────
      #   row 'Go runtime' do
      #     Pangea::Dashboards::Library::GoProcessUseRow.add(
      #       self, datasource: 'vm', process_selector: { job: 'gateway' })
      #   end
      module GoProcessUseRow
        # The standard go_*/process_* metric surface (override via `metrics:`
        # if a vendor renames them — rare; these names are runtime-stable).
        DEFAULTS = {
          process_cpu:   'process_cpu_seconds_total',
          goroutines:    'go_goroutines',
          heap_inuse:    'go_memstats_heap_inuse_bytes',
          process_rss:   'process_resident_memory_bytes',
          process_vsize: 'process_virtual_memory_bytes',
          gc_sum:        'go_gc_duration_seconds_sum',
          start_time:    'process_start_time_seconds'
        }.freeze

        # The signals this row knows how to emit, in canonical order — used to
        # validate `show` and to render in a stable sequence.
        SIGNALS = %i[cpu goroutines heap gc uptime].freeze

        # process_selector: (req) typed Hash matcher identifying the process
        #                   (e.g. { job: 'gateway' } or { namespace: 'x', pod: /…/ })
        # show:             which runtime facets to render, in order
        #                   (default cpu/goroutines/heap/gc/uptime)
        # window:           rate window for CPU + GC counters (default 5m)
        # title:            the process name (prefixes every panel title)
        # metrics:          override any of DEFAULTS
        def self.add(row, datasource:, process_selector:, show: SIGNALS.dup,
                     window: '5m', title: 'Go runtime', metrics: {})
          validate!(datasource: datasource, process_selector: process_selector, show: show)
          m   = DEFAULTS.merge(metrics)
          sel = process_selector
          # Equal-width timeseries across the requested signals; uptime rides as
          # a compact liveness stat appended at the row's tail.
          ts  = show.reject { |s| s == :uptime }
          tsw = Theme.tile_width(ts.length).clamp(Theme.third, Theme.half)

          show.each do |signal|
            case signal
            when :cpu        then add_cpu(row, datasource: datasource, selector: sel, metric: m[:process_cpu], window: window, width: tsw, title: title)
            when :goroutines then add_goroutines(row, datasource: datasource, selector: sel, metric: m[:goroutines], width: tsw, title: title)
            when :heap       then add_heap(row, datasource: datasource, selector: sel, metrics: m, width: tsw, title: title)
            when :gc         then add_gc(row, datasource: datasource, selector: sel, metric: m[:gc_sum], window: window, width: tsw, title: title)
            when :uptime     then add_uptime(row, datasource: datasource, selector: sel, metric: m[:start_time], title: title)
            end
          end
        end

        # CPU — kernel+user seconds the process burns, as a per-second rate
        # (event_driven counter → floored so an idle process reads a true 0).
        def self.add_cpu(row, datasource:, selector:, metric:, window:, width:, title:)
          expr = Floor.zero(Promql.sum_rate(metric: metric, window: window, selector: selector))
          row.panel :go_cpu, kind: :timeseries, width: width, height: Theme::TS_H do
            title "#{title} · CPU"
            unit 'short'
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: :event_driven, legend: 'cpu cores'
          end
        end

        # Goroutines — the canonical Go saturation proxy (continuous gauge).
        def self.add_goroutines(row, datasource:, selector:, metric:, width:, title:)
          expr = "sum(#{metric}#{Promql.braces(selector)})"
          row.panel :go_goroutines, kind: :timeseries, width: width, height: Theme::TS_H do
            title "#{title} · goroutines"
            unit 'short'
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: :continuous, legend: 'goroutines'
          end
        end

        # Heap — live heap bytes plus the process RSS/virtual envelope it sits
        # inside (continuous gauges; a heap approaching RSS is memory pressure).
        def self.add_heap(row, datasource:, selector:, metrics:, width:, title:)
          braces = Promql.braces(selector)
          heap   = "sum(#{metrics[:heap_inuse]}#{braces})"
          rss    = "sum(#{metrics[:process_rss]}#{braces})"
          vsize  = "sum(#{metrics[:process_vsize]}#{braces})"
          row.panel :go_heap, kind: :timeseries, width: width, height: Theme::TS_H do
            title "#{title} · memory"
            unit 'bytes'
            min 0
            graph :area
            query 'A', heap,  datasource: datasource, presence: :continuous, legend: 'heap inuse'
            query 'B', rss,   datasource: datasource, presence: :continuous, legend: 'rss'
            query 'C', vsize, datasource: datasource, presence: :continuous, legend: 'virtual'
          end
        end

        # GC — stop-the-world time burned per second (event_driven counter sum
        # → floored). The runtime's pause tax; a climbing line is GC pressure.
        def self.add_gc(row, datasource:, selector:, metric:, window:, width:, title:)
          expr = Floor.zero(Promql.sum_rate(metric: metric, window: window, selector: selector))
          row.panel :go_gc, kind: :timeseries, width: width, height: Theme::TS_H do
            title "#{title} · GC time"
            unit 's'
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: :event_driven, legend: 'gc s/s'
          end
        end

        # Uptime — time since the process started; resets to ~0 on every
        # crash/restart, so it's a liveness stat (lower = worse).
        def self.add_uptime(row, datasource:, selector:, metric:, title:)
          expr  = "time() - max(#{metric}#{Promql.braces(selector)})"
          steps = Theme.liveness_steps(ok: 1)
          row.panel :go_uptime, kind: :stat, width: Theme.third, height: Theme::STAT_H do
            title "#{title} · uptime"
            unit 's'
            display :value
            graph :area
            query 'A', expr, datasource: datasource, presence: :continuous
            threshold steps: steps
          end
        end

        def self.validate!(datasource:, process_selector:, show:)
          raise ArgumentError, 'GoProcessUseRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'GoProcessUseRow: process_selector: required (Hash/String)' \
            if process_selector.nil? || (process_selector.respond_to?(:empty?) && process_selector.empty?)
          raise ArgumentError, 'GoProcessUseRow: show must be a non-empty Array' \
            unless show.is_a?(Array) && !show.empty?
          unknown = show.map(&:to_sym) - SIGNALS
          raise ArgumentError, "GoProcessUseRow: unknown show signal(s) #{unknown.inspect} (valid: #{SIGNALS.inspect})" \
            unless unknown.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :add_cpu, :add_goroutines, :add_heap, :add_gc, :add_uptime, :validate!, :blank?
      end
    end
  end
end
