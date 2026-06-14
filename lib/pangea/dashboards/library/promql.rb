# frozen_string_literal: true

module Pangea
  module Dashboards
    module Library
      # The shared PromQL fragment builder. Every Library component that
      # composes a query (rate, sum-by, histogram_quantile, topk, …) builds it
      # through ONE place rather than ad-hoc string interpolation — the
      # typed-emission discipline at the query layer. A selector is authored as
      # a typed Hash; the helper decides `=` vs `=~` from the Ruby value type
      # (String → exact, Regexp/Array → regex), so an author never hand-writes
      # `label=~"a|b"` and never mis-escapes a matcher.
      module Promql
        module_function

        # Render a selector to the body inside `{...}` (no braces).
        #   nil                       → ""
        #   "code=~\"5..\""           → verbatim (escape hatch)
        #   { namespace: 'monitoring' } → namespace="monitoring"
        #   { code: /5../ }           → code=~"5.."
        #   { result: %w[error requeue] } → result=~"error|requeue"
        def selector_body(sel)
          case sel
          when nil then ''
          when ::String then sel
          when ::Hash
            sel.reject { |_, v| v.nil? }.map do |k, v|
              case v
              when ::Regexp then %(#{k}=~"#{v.source}")
              when ::Array  then %(#{k}=~"#{v.join('|')}")
              else %(#{k}="#{v}")
              end
            end.join(',')
          else
            raise ArgumentError, "Promql selector must be Hash, String, or nil (got #{sel.class})"
          end
        end

        # Selector wrapped in braces, or "" when empty.
        def braces(sel)
          body = selector_body(sel)
          body.empty? ? '' : "{#{body}}"
        end

        # ` by (a, b)` grouping clause, or "" when no labels.
        def by(labels)
          ls = Array(labels).compact.map(&:to_s).reject(&:empty?)
          ls.empty? ? '' : " by (#{ls.join(', ')})"
        end

        # sum by(group)(rate(metric{sel}[window]))
        def sum_rate(metric:, window:, group_by: [], selector: nil)
          "sum#{by(group_by)}(rate(#{metric}#{braces(selector)}[#{window}]))"
        end

        # sum by(group)(increase(metric{sel}[window]))
        def sum_increase(metric:, window:, group_by: [], selector: nil)
          "sum#{by(group_by)}(increase(#{metric}#{braces(selector)}[#{window}]))"
        end

        # histogram_quantile(q, sum by(group, le)(rate(bucket{sel}[window])))
        def histogram_quantile(quantile:, bucket_metric:, window:, group_by: [], selector: nil, le_label: 'le')
          inner_groups = (Array(group_by) + [le_label])
          "histogram_quantile(#{quantile}, sum#{by(inner_groups)}(rate(#{bucket_metric}#{braces(selector)}[#{window}])))"
        end
      end
    end
  end
end
