# frozen_string_literal: true

require 'set'
require 'pangea/dashboards/datasource'

module Pangea
  module Dashboards
    # The RUNTIME half of dashboard correctness — the definitive answer to the
    # question "is this panel's no-data because nothing is happening yet, or
    # because the panel is BROKEN?".
    #
    # The drift detector (spec-side) proves a metric NAME is valid in the source.
    # `Health` proves the metric is actually EMITTED at runtime: a series exists
    # in the TSDB. Together a panel cannot ship broken — its metric is a real
    # name (drift), it is emitted (health), and its datasource language matches
    # (Datasources.validate_query!).
    #
    # ── The one definitive distinguisher ────────────────────────────────────
    # "No data" has exactly three causes, and they ARE distinguishable:
    #   1. the query/datasource FAILS               → grafana "Error" (red)  → :error
    #   2. the metric is never emitted (not wired)  → count(metric) == 0     → :not_wired (BROKEN)
    #   3. the metric is wired but idle/filtered    → count(metric)  > 0     → :wired (legitimately empty)
    # So the runtime test is simply: does the metric's BASE series exist? If a
    # `:continuous` metric (one emitted whenever its component runs) has zero
    # series, the panel is broken. If the series exists but the filtered query is
    # empty, the panel is merely idle. The publish gate refuses (2) and (1).
    module Health
      # PromQL functions/keywords that look like identifiers but are NOT metrics.
      KEYWORDS = %w[
        sum max min avg count count_values group stddev stdvar topk bottomk quantile
        rate irate increase delta idelta deriv predict_linear changes resets
        histogram_quantile histogram_count histogram_sum
        abs ceil floor round exp ln log2 log10 sqrt sgn clamp clamp_max clamp_min
        absent absent_over_time present_over_time scalar vector time timestamp
        avg_over_time max_over_time min_over_time sum_over_time count_over_time
        quantile_over_time stddev_over_time stdvar_over_time last_over_time
        label_replace label_join sort sort_desc
        by without on ignoring group_left group_right le and or unless offset bool inf nan
      ].to_set

      # Presence classes — how to interpret a `:not_wired` result per metric:
      #   :continuous   — emitted whenever the component runs (up, reconciles,
      #                   setpoint). not_wired ⇒ BROKEN (the emitter never ran).
      #   :event_driven — emitted on activity (errors, carves). The series should
      #                   still exist (at 0) if the emitter ran; not_wired ⇒ broken.
      #   :conditional  — may legitimately be absent (a per-workload metric that
      #                   only exists when that workload runs). not_wired ⇒ allowed.
      PRESENCE_RANK = { continuous: 2, event_driven: 1, conditional: 0 }.freeze

      Result = Struct.new(:metric, :status, :presence, :panels, keyword_init: true)

      # The metric base names referenced by a dashboard's PROMETHEUS (PromQL)
      # queries, each with its strongest presence class + the panels it appears
      # in. LogsQL (vlogs) queries are skipped — log-stream presence is its own
      # probe (a stream selector, not a metric series).
      def self.metrics(dashboard)
        acc = {}
        dashboard.rows.each do |row|
          row.panels.each do |panel|
            panel.queries.each do |q|
              next if Datasources.query_lang(q.datasource_uid) == :logsql
              presence = q.respond_to?(:presence) && q.presence ? q.presence : :continuous
              metric_tokens(q.expr).each do |m|
                e = (acc[m] ||= { presence: :conditional, panels: Set.new })
                e[:presence] = stronger(e[:presence], presence)
                e[:panels] << panel.title
              end
            end
          end
        end
        acc
      end

      # Probe a dashboard against a live TSDB. `&series_count` is a callable
      # `metric_base -> Integer | :error` that runs `count(<metric_base>)`
      # against the target Prometheus (the caller wires the HTTP/MCP client, so
      # this module stays pure + unit-testable). Returns Array<Result>.
      def self.probe(dashboard, &series_count)
        metrics(dashboard).map do |metric, info|
          count =
            begin
              series_count.call(metric)
            rescue StandardError
              :error
            end
          status =
            if count == :error then :error
            elsif count.to_i.positive? then :wired
            else :not_wired
            end
          Result.new(metric: metric, status: status, presence: info[:presence], panels: info[:panels].to_a.sort)
        end
      end

      # The publish gate — the definitive "don't ship a broken dashboard" check.
      # HARD-FAILS only on:
      #   - a `:continuous` metric NOT_WIRED (it is emitted whenever its component
      #     runs, so a missing series means the panel/metric is genuinely broken), or
      #   - any metric ERROR (datasource/syntax failure).
      # `:event_driven` not_wired is a WARNING (the counter may be lazily created
      # on first event — possibly-broken, possibly-just-quiet); `:conditional`
      # not_wired is fine (a per-workload metric whose workload is off).
      # Returns { publishable:, broken:, warnings: }.
      def self.gate(results)
        broken = results.select do |r|
          r.status == :error || (r.status == :not_wired && r.presence == :continuous)
        end
        warnings = results.select { |r| r.status == :not_wired && r.presence == :event_driven }
        { publishable: broken.empty?, broken: broken, warnings: warnings }
      end

      # A human-readable report distinguishing BROKEN / warn / idle / healthy.
      def self.report(results)
        g = gate(results)
        lines = []
        g[:broken].each do |r|
          tag = r.status == :error ? 'ERROR ' : 'BROKEN'
          why = r.status == :error ? 'query/datasource failed' : "never emitted (#{r.presence})"
          lines << "  #{tag}  #{r.metric} — #{why}; panels: #{r.panels.join(', ')}"
        end
        g[:warnings].each { |r| lines << "  warn    #{r.metric} — event-driven series absent (lazy or broken); panels: #{r.panels.join(', ')}" }
        results.select { |r| r.status == :not_wired && r.presence == :conditional }.each do |r|
          lines << "  idle    #{r.metric} — conditional metric absent (workload off — not a bug); panels: #{r.panels.join(', ')}"
        end
        wired = results.count { |r| r.status == :wired }
        head = "#{wired} wired · #{g[:broken].size} BROKEN · #{g[:warnings].size} warn · " \
               "#{results.count { |r| r.status == :not_wired && r.presence == :conditional }} idle"
        ([head] + lines).join("\n")
      end

      def self.metric_tokens(expr)
        # Strip the things that contain identifiers which are NOT metric names:
        #   - aggregation modifier label lists: by(...) / without(...) / on(...) /
        #     ignoring(...) / group_left(...) / group_right(...)
        #   - series-selector label matchers: {...}
        # then keep identifiers NOT immediately followed by '(' (those are
        # functions) and not PromQL keywords. The count() probe is the final
        # arbiter — a stray non-metric token simply probes as not_wired, which is
        # why the modifier/selector stripping matters (else by-labels false-break).
        expr.gsub(/\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)/, ' ')
            .gsub(/\{[^}]*\}/, ' ')   # series-selector label matchers
            .gsub(/\[[^\]]*\]/, ' ')  # range/duration selectors ([5m] etc — else the 'm' leaks)
            .scan(/([a-zA-Z_:][a-zA-Z0-9_:]*)(\s*\()?/)
            .reject { |_id, paren| paren }
            .map(&:first)
            .reject { |t| KEYWORDS.include?(t) || t =~ /\A\d/ }
            .uniq
      end

      def self.stronger(a, b)
        PRESENCE_RANK[a].to_i >= PRESENCE_RANK[b].to_i ? a : b
      end
      private_class_method :metric_tokens, :stronger
    end
  end
end
