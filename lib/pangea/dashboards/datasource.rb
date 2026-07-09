# frozen_string_literal: true

require 'pangea/dashboards/types'

module Pangea
  module Dashboards
    # Typed datasource registry — the single source of truth for a datasource's
    # Grafana plugin `type` AND its query language. Modelling it here makes two
    # whole classes of rendered-dashboard bug UNREPRESENTABLE:
    #
    #   1. Wrong panel datasource `type`. The renderers no longer hardcode
    #      'prometheus' — they DERIVE the type from the datasource. A VictoriaLogs
    #      panel can never again render with type 'prometheus' (the bug that made
    #      the pangea-operator Logs panels query vlogs over the Prometheus path
    #      and error live).
    #   2. Query-language vs datasource mismatch. A LogsQL query pointed at a
    #      metrics (PromQL) datasource — or vice versa — raises at render time
    #      instead of shipping a panel that errors in the browser.
    #
    # Authors register their fleet datasources once; every renderer reads this.
    class Datasource < Dry::Struct
      attribute :uid,          Types::Strict::String
      attribute :grafana_type, Types::Strict::String           # Grafana datasource plugin type
      # :promql (metrics) / :logsql (VictoriaLogs) / :sql (ClickHouse & other
      # SQL-wire datasources — rendered through the rawSql target arm, not expr).
      attribute :query_lang,   Types::Strict::Symbol.enum(:promql, :logsql, :sql)
    end

    module Datasources
      module_function

      def registry
        @registry ||= {}
      end

      # Register (or override) a fleet datasource.
      def register(uid, grafana_type:, query_lang:)
        registry[uid] = Datasource.new(uid: uid, grafana_type: grafana_type, query_lang: query_lang)
      end

      def known?(uid) = registry.key?(uid)
      def [](uid)     = registry[uid]

      # The query language of a datasource (:promql / :logsql). :promql is the
      # conservative default for an unregistered uid (so the Health probe treats
      # an unknown datasource as a metric source unless told otherwise).
      def query_lang(uid) = registry[uid]&.query_lang || :promql

      # Template-variable datasource refs ("$datasource", "${ds}") are resolved
      # by Grafana at runtime — passed through untyped.
      def variable?(uid) = uid.to_s.start_with?('$')

      # The Grafana datasource ref { 'type' => …, 'uid' => … } for a query /
      # variable / annotation. Registered → the datasource's real plugin type.
      # Variable / unregistered concrete uid → 'prometheus' (backward-compatible;
      # register the datasource to type it correctly).
      def ref(uid)
        ds = registry[uid]
        { 'type' => (ds ? ds.grafana_type : 'prometheus'), 'uid' => uid }
      end

      LOGSQL_PIPE = /\|\s*(error|stats|filter|json|logfmt|unpack_|extract|fields|sort|limit|head|tail|uniq|count|drop|keep|rename|format|math|replace)/i
      LOGSQL_SELECTOR_PIPE = /\}\s*\|/
      PROMQL_FUNC = /\b(rate|irate|increase|histogram_quantile|sum\s+by|avg\s+by|max\s+by|min\s+by|count\s+by)\b|\bby\s*\(/

      # A `|` inside a quoted string is PromQL regex alternation — a label matcher
      # like outcome=~"denied|error" — NEVER a LogsQL pipe operator (LogsQL pipes
      # live OUTSIDE string literals). Blank out every quoted literal ("...", '...',
      # `...`) before classifying so a label-regex alternation can't masquerade as a
      # `| error` / `| stats` LogsQL pipe. Without this, AuthMethodHealth /
      # SecretsPlatformOverview — which emit outcome=~"denied|error" against the vm
      # PromQL datasource — false-tripped the LogsQL branch and raised at render.
      def strip_string_literals(expr)
        expr.gsub(/"[^"]*"/, '""').gsub(/'[^']*'/, "''").gsub(/`[^`]*`/, '``')
      end

      def logsql?(expr)
        stripped = strip_string_literals(expr)
        stripped.match?(LOGSQL_PIPE) || stripped.match?(LOGSQL_SELECTOR_PIPE)
      end

      def promql?(expr)
        strip_string_literals(expr).match?(PROMQL_FUNC)
      end

      # Raise if a query's language is incompatible with its (registered)
      # datasource. Only enforced for registered datasources (where the language
      # is known) and concrete (non-variable) uids.
      def validate_query!(expr, uid)
        return if variable?(uid)
        ds = registry[uid] or return
        # :sql datasources (ClickHouse …) carry a raw SQL string — the
        # PromQL/LogsQL classifier does not apply, so never mismatch-raise.
        return if ds.query_lang == :sql
        if ds.query_lang == :promql && logsql?(expr)
          raise DatasourceLanguageMismatchError,
                "query targets PromQL datasource #{uid.inspect} but the expr is LogsQL: #{expr.inspect}"
        end
        if ds.query_lang == :logsql && promql?(expr) && !logsql?(expr)
          raise DatasourceLanguageMismatchError,
                "query targets LogsQL datasource #{uid.inspect} but the expr is PromQL: #{expr.inspect}"
        end
      end
    end

    # The pleme-io fleet observability datasources (VictoriaMetrics + VictoriaLogs).
    # VictoriaMetrics IS Prometheus-wire-compatible → grafana type 'prometheus'.
    # VictoriaLogs is its own plugin → grafana type 'victoriametrics-logs-datasource' (LogsQL).
    Datasources.register('vm',    grafana_type: 'prometheus',   query_lang: :promql)
    Datasources.register('vlogs', grafana_type: 'victoriametrics-logs-datasource', query_lang: :logsql)
    # ClickHouse analytics datasource (Path-A typed SQL mixin). The Grafana
    # ClickHouse plugin takes a `rawSql` target (see Render::Grafana#render_query),
    # so this datasource's language is :sql — the PromQL/LogsQL classifier is
    # bypassed for it, and panels render their SQL string verbatim.
    Datasources.register('clickhouse', grafana_type: 'grafana-clickhouse-datasource', query_lang: :sql)
  end
end
