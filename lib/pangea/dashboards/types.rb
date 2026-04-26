# frozen_string_literal: true

require 'dry-types'
require 'dry-struct'

module Pangea
  module Dashboards
    # Typed AST nodes (Dry::Struct). Backend-agnostic: any concept that
    # only exists on one backend (Grafana plugins, Datadog notebook
    # widgets, …) belongs in `options:` (a free-form Hash) on the panel
    # rather than a top-level attribute.
    module Types
      include Dry.Types()

      # ── enums ────────────────────────────────────────────────────────
      PanelKind = Types::Strict::Symbol.enum(
        :stat,
        :timeseries,
        :gauge,
        :table,
        :heatmap,
        :text,
        :pie
      )

      VariableKind = Types::Strict::Symbol.enum(
        :query,
        :constant,
        :custom,
        :datasource,
        :textbox,
        :interval
      )

      ThresholdMode = Types::Strict::String.enum('absolute', 'percentage')

      # ── leaves ───────────────────────────────────────────────────────
      class Threshold < Dry::Struct
        # Color name ("green", "red", "#FF0000", or a Grafana semantic
        # name). Translated by each renderer.
        attribute :color, Types::Strict::String
        # nil = "below the lowest step" (the implicit base color band).
        # Otherwise the value at which this color band starts.
        attribute? :value, Types::Coercible::Float.optional
      end

      class ThresholdConfig < Dry::Struct
        attribute? :mode, ThresholdMode.default('absolute')
        attribute  :steps, Types::Strict::Array.of(Threshold).default([].freeze)
      end

      class Query < Dry::Struct
        # "A", "B", "C" — Grafana's query refId. Datadog ignores; we
        # propagate it for cross-renderer determinism.
        attribute :ref, Types::Strict::String
        # PromQL / LogQL / native source query.
        attribute :expr, Types::Strict::String
        # Grafana datasource uid. Datadog renderer maps this to
        # query.data_source via a per-uid lookup table the workspace
        # provides.
        attribute :datasource_uid, Types::Strict::String
        attribute? :legend_format, Types::Strict::String.optional
        attribute? :instant, Types::Strict::Bool.default(false)
        # Explicit Datadog query override. Use when PromQL doesn't
        # translate cleanly. The Datadog renderer raises
        # UntranslatableQueryError on PromQL-only expr without this.
        attribute? :dd_query, Types::Strict::String.optional
        attribute? :hide, Types::Strict::Bool.default(false)
      end

      class Panel < Dry::Struct
        attribute :id, Types::Strict::Symbol
        attribute :kind, PanelKind
        attribute :title, Types::Strict::String
        attribute? :description, Types::Strict::String.optional
        attribute? :unit, Types::Strict::String.optional
        attribute? :min, Types::Coercible::Float.optional
        attribute? :max, Types::Coercible::Float.optional
        attribute? :decimals, Types::Strict::Integer.optional
        attribute  :queries, Types::Strict::Array.of(Query).default([].freeze)
        attribute? :thresholds, ThresholdConfig.default { ThresholdConfig.new }
        attribute? :width, Types::Strict::Integer.default(12)
        attribute? :height, Types::Strict::Integer.default(8)
        # Backend-specific overrides. Renderers may consume keys they
        # know about (`grafana: { reduceOptions: ... }`,
        # `datadog: { precision: 2 }`) and ignore the rest.
        attribute? :options, Types::Strict::Hash.default({}.freeze)
      end

      class Row < Dry::Struct
        attribute :title, Types::Strict::String
        attribute? :collapsed, Types::Strict::Bool.default(false)
        attribute  :panels, Types::Strict::Array.of(Panel).default([].freeze)
      end

      class Variable < Dry::Struct
        attribute :name, Types::Strict::Symbol
        attribute :kind, VariableKind
        attribute? :label, Types::Strict::String.optional
        attribute? :datasource_uid, Types::Strict::String.optional
        # The query string for kind=:query (e.g. label_values(...)),
        # the comma-separated list for kind=:custom, the value for
        # kind=:constant, etc. Renderers interpret per-kind.
        attribute? :query, Types::Strict::String.optional
        attribute? :default, (Types::Strict::String | Types::Strict::Array.of(Types::Strict::String)).optional
        attribute? :options, Types::Strict::Array.of(Types::Strict::String).default([].freeze)
        attribute? :multi, Types::Strict::Bool.default(false)
        attribute? :include_all, Types::Strict::Bool.default(false)
        # Grafana hide: 0=show, 1=hide-label, 2=hide-everything.
        # Datadog has no equivalent; the field is ignored there.
        attribute? :hide, Types::Strict::Integer.default(0)
      end

      class Annotation < Dry::Struct
        attribute :name, Types::Strict::Symbol
        attribute :datasource_uid, Types::Strict::String
        attribute :expr, Types::Strict::String
        attribute? :color, Types::Strict::String.default('blue'.freeze)
        attribute? :icon, Types::Strict::String.optional
        attribute? :enable, Types::Strict::Bool.default(true)
      end

      class TimeRange < Dry::Struct
        attribute? :from, Types::Strict::String.default('now-1h'.freeze)
        attribute? :to, Types::Strict::String.default('now'.freeze)
      end

      class Dashboard < Dry::Struct
        # Logical id (`:rio_lareira_services`). The DSL builder uses this
        # to derive sensible defaults for `uid` and the Pangea resource
        # name when emit_resource is called.
        attribute :id, Types::Strict::Symbol
        attribute :title, Types::Strict::String
        attribute :uid, Types::Strict::String
        attribute? :description, Types::Strict::String.optional
        attribute? :tags, Types::Strict::Array.of(Types::Strict::String).default([].freeze)
        attribute? :refresh, Types::Strict::String.default('30s'.freeze)
        attribute? :time, TimeRange.default { TimeRange.new }
        attribute? :variables, Types::Strict::Array.of(Variable).default([].freeze)
        attribute? :annotations, Types::Strict::Array.of(Annotation).default([].freeze)
        attribute  :rows, Types::Strict::Array.of(Row).default([].freeze)
        attribute? :timezone, Types::Strict::String.default('utc'.freeze)
        attribute? :editable, Types::Strict::Bool.default(true)

        # ── Immutable transformations (AST splice) ───────────────────
        # Dashboards are Dry::Structs — they don't mutate. These helpers
        # return new Dashboard instances with the requested change so
        # workspaces can splice their own panels into a base
        # architecture's canonical dashboard.

        # Replace the rows list (or rebuild via a block).
        def with_rows(new_rows = nil, &block)
          rows_value = block ? yield(rows) : new_rows
          self.class.new(attributes.merge(rows: rows_value))
        end

        # Append one row to the end. Returns a new Dashboard.
        def append_row(row)
          self.class.new(attributes.merge(rows: rows + [row]))
        end

        # Prepend one row to the start.
        def prepend_row(row)
          self.class.new(attributes.merge(rows: [row] + rows))
        end

        # Insert at a specific index. `at:` is a 0-based row index OR a
        # row title (matched against existing rows).
        def insert_row(row, at:)
          idx = if at.is_a?(Integer)
                  at
                else
                  found = rows.index { |r| r.title == at.to_s }
                  raise ArgumentError, "no row titled #{at.inspect}; titles: #{rows.map(&:title)}" unless found
                  found
                end
          new_rows = rows.dup
          new_rows.insert(idx, row)
          self.class.new(attributes.merge(rows: new_rows))
        end

        # Replace the row at the given title (or index) with the new row.
        def replace_row(row, at:)
          idx = at.is_a?(Integer) ? at : rows.index { |r| r.title == at.to_s }
          raise ArgumentError, "no row at #{at.inspect}" unless idx
          new_rows = rows.dup
          new_rows[idx] = row
          self.class.new(attributes.merge(rows: new_rows))
        end

        # Splice `other_dashboard.rows` into this dashboard at the given
        # position. `position` is :before, :after, or :replace; `target`
        # is the row title (or 0-based index) to splice around.
        def splice(other, position: :after, target: nil)
          unless %i[before after replace append prepend].include?(position)
            raise ArgumentError, "position must be :before / :after / :replace / :append / :prepend"
          end
          case position
          when :append  then return with_rows(rows + other.rows)
          when :prepend then return with_rows(other.rows + rows)
          end
          raise ArgumentError, ":#{position} requires target:" if target.nil?
          idx = target.is_a?(Integer) ? target : rows.index { |r| r.title == target.to_s }
          raise ArgumentError, "no row at target #{target.inspect}" unless idx
          new_rows = rows.dup
          case position
          when :before  then other.rows.reverse_each { |r| new_rows.insert(idx, r) }
          when :after   then other.rows.each_with_index { |r, i| new_rows.insert(idx + 1 + i, r) }
          when :replace
            new_rows.delete_at(idx)
            other.rows.each_with_index { |r, i| new_rows.insert(idx + i, r) }
          end
          self.class.new(attributes.merge(rows: new_rows))
        end

        # Concatenate two dashboards' rows into a new dashboard. Tags,
        # variables, annotations are union-merged; metadata defaults to
        # `self`'s side.
        def +(other)
          self.class.new(
            attributes.merge(
              rows: rows + other.rows,
              variables: (variables + other.variables).uniq { |v| v.name },
              annotations: (annotations + other.annotations).uniq { |a| a.name },
              tags: (tags + other.tags).uniq
            )
          )
        end
      end
    end
  end
end
