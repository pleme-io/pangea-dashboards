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
      attribute :query_lang,   Types::Strict::Symbol.enum(:promql, :logsql)
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

      def logsql?(expr)
        expr.match?(LOGSQL_PIPE) || expr.match?(LOGSQL_SELECTOR_PIPE)
      end

      def promql?(expr)
        expr.match?(PROMQL_FUNC)
      end

      # Raise if a query's language is incompatible with its (registered)
      # datasource. Only enforced for registered datasources (where the language
      # is known) and concrete (non-variable) uids.
      def validate_query!(expr, uid)
        return if variable?(uid)
        ds = registry[uid] or return
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
    # VictoriaLogs is its own plugin → grafana type 'VictoriaLogs' (LogsQL).
    Datasources.register('vm',    grafana_type: 'prometheus',   query_lang: :promql)
    Datasources.register('vlogs', grafana_type: 'VictoriaLogs', query_lang: :logsql)
  end
end
