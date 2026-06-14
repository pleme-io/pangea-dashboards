# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The per-namespace (or per-tenant) resource breakdown row — CPU /
      # memory / restarts / pod-count, each `sum by(namespace)`, one
      # :timeseries per requested metric. Absorbed from the hand-written
      # cpu_by_ns / mem_by_ns / restarts_by_ns / pods_per_ns panels of
      # kubernetes_cluster.rb, which every rio/engenho cluster dashboard
      # re-wrote by hand. Generalises to per-TENANT ranking via
      # `namespace_label` (e.g. `:tenant`, `:team`).
      #
      # ── Why the cadvisor dedupe is BAKED IN (the load-bearing detail) ────
      # The container_* metrics (CPU, memory) come from cadvisor. rio scrapes
      # container metrics from BOTH the kubelet `/metrics/resource` endpoint
      # AND the kubelet `/metrics/cadvisor` endpoint — so every pod appears in
      # the TSDB as TWO series differing only by their `metrics_path` label. A
      # naive `sum by(namespace)(container_cpu_usage_seconds_total)` silently
      # DOUBLE-COUNTS. The fix is not a per-author footnote: when
      # `dedupe: :cadvisor` (the default), this component pins
      # `metrics_path="/metrics/cadvisor"` onto every container_* selector so
      # the sum is honest by construction. kube-state-metrics series (restarts,
      # count) are single-scrape, so they are NEVER pinned. Pass
      # `dedupe: nil` to opt out (single-scrape clusters).
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'By namespace' do
      #     Pangea::Dashboards::Library::PerNamespaceBreakdownRow.add(
      #       self, datasource: 'vm', metrics: %i[cpu memory restarts count])
      #   end
      #
      #   # Per-tenant, only CPU + memory, scoped to one cluster:
      #   row 'By tenant' do
      #     Pangea::Dashboards::Library::PerNamespaceBreakdownRow.add(
      #       self, datasource: 'vm', namespace_label: 'tenant',
      #       metrics: %i[cpu memory], selector: { cluster: 'rio' }, title: 'By tenant')
      #   end
      module PerNamespaceBreakdownRow
        # The metric catalogue. Each entry is the typed shape of one breakdown
        # panel: which series, how to aggregate it, its unit, whether it is a
        # cadvisor (dual-scrape) series, and how to title it.
        #   metric:   the source series name
        #   agg:      :rate (event-driven counter over [window]) | :gauge (instant value)
        #   unit:     Grafana unit
        #   cadvisor: true → pinned with metrics_path when dedupe: :cadvisor
        #   scale:    optional multiplier appended to the inner expr (CPU → cores)
        #   suffix:   short title suffix
        METRICS = {
          cpu: {
            metric: 'container_cpu_usage_seconds_total', agg: :rate,
            unit: 'short', cadvisor: true, suffix: 'CPU (cores)'
          },
          memory: {
            metric: 'container_memory_working_set_bytes', agg: :gauge,
            unit: 'bytes', cadvisor: true, suffix: 'memory'
          },
          restarts: {
            metric: 'kube_pod_container_status_restarts_total', agg: :rate,
            unit: 'short', cadvisor: false, suffix: 'restarts'
          },
          count: {
            metric: 'kube_pod_info', agg: :gauge,
            unit: 'short', cadvisor: false, suffix: 'pod count'
          }
        }.freeze

        # The label pinned onto every cadvisor container_* series so the
        # /metrics/resource duplicate is excluded from the sum.
        CADVISOR_PATH = '/metrics/cadvisor'

        # row:             the RowBuilder to emit into
        # datasource:      (req) metrics datasource uid
        # namespace_label: label to break down + group by (default 'namespace';
        #                  set 'tenant'/'team' to generalise to per-tenant)
        # dedupe:          :cadvisor (default) → pin metrics_path on container_*
        #                  selectors; nil → no dedupe (single-scrape cluster)
        # metrics:         ordered subset of %i[cpu memory restarts count]
        # selector:        typed Hash/String matcher applied to every series
        # window:          rate window for the counter metrics (default 5m)
        # title:           per-panel title prefix (default 'By namespace')
        def self.add(row, datasource:, namespace_label: 'namespace', dedupe: :cadvisor,
                     metrics: %i[cpu memory restarts count], selector: nil, title: 'By namespace',
                     window: '5m')
          validate!(datasource: datasource, namespace_label: namespace_label, dedupe: dedupe, metrics: metrics)
          width = Theme.tile_width(metrics.length).clamp(Theme.third, Theme.full)
          metrics.each do |key|
            add_metric(row, METRICS.fetch(key), key: key, datasource: datasource,
                       namespace_label: namespace_label, dedupe: dedupe, selector: selector,
                       window: window, title: title, width: width)
          end
        end

        def self.add_metric(row, spec, key:, datasource:, namespace_label:, dedupe:, selector:, window:, title:, width:)
          sel  = effective_selector(selector, cadvisor: spec[:cadvisor], dedupe: dedupe)
          gb   = [namespace_label]
          inner = case spec[:agg]
                  when :rate  then Promql.sum_rate(metric: spec[:metric], window: window, group_by: gb, selector: sel)
                  else "sum#{Promql.by(gb)}(#{spec[:metric]}#{Promql.braces(sel)})"
                  end
          # count is the cardinality of the series, not their value — count over
          # the grouped sum is the honest pod count.
          inner = "count#{Promql.by(gb)}(#{spec[:metric]}#{Promql.braces(sel)})" if key == :count
          # rate counters are event-driven → floor so a quiet namespace reads 0.
          expr  = spec[:agg] == :rate ? Floor.zero(inner) : inner
          presence = spec[:agg] == :rate ? :event_driven : :continuous
          pid   = :"by_#{slug(namespace_label)}_#{key}"
          row.panel pid, kind: :timeseries, width: width, height: Theme::TS_H do
            title "#{title} · #{spec[:suffix]}"
            unit spec[:unit]
            min 0
            graph :area
            query 'A', expr, datasource: datasource, presence: presence, legend: "{{#{namespace_label}}}"
          end
        end

        # Merge the author selector with the cadvisor dedupe pin. The pin only
        # applies to container_* (cadvisor) series and only when dedupe: :cadvisor.
        # A String selector is concatenated; a Hash gains the typed key.
        def self.effective_selector(selector, cadvisor:, dedupe:)
          return selector unless cadvisor && dedupe == :cadvisor
          pin = { metrics_path: CADVISOR_PATH }
          case selector
          when nil    then pin
          when ::Hash then selector.merge(pin)
          when ::String
            selector.strip.empty? ? %(metrics_path="#{CADVISOR_PATH}") : %(#{selector},metrics_path="#{CADVISOR_PATH}")
          else
            raise ArgumentError, "PerNamespaceBreakdownRow: selector must be Hash, String, or nil (got #{selector.class})"
          end
        end

        def self.validate!(datasource:, namespace_label:, dedupe:, metrics:)
          raise ArgumentError, 'PerNamespaceBreakdownRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'PerNamespaceBreakdownRow: namespace_label: required' if blank?(namespace_label)
          raise ArgumentError, "PerNamespaceBreakdownRow: dedupe must be :cadvisor or nil (got #{dedupe.inspect})" \
            unless dedupe.nil? || dedupe == :cadvisor
          raise ArgumentError, 'PerNamespaceBreakdownRow: metrics must be a non-empty Array' \
            unless metrics.is_a?(Array) && !metrics.empty?
          unknown = metrics.map(&:to_sym) - METRICS.keys
          raise ArgumentError, "PerNamespaceBreakdownRow: unknown metrics #{unknown.inspect} (allowed #{METRICS.keys})" \
            unless unknown.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_metric, :effective_selector, :validate!, :blank?, :slug
      end
    end
  end
end
