# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The node-PRESSURE defect strip — one colour-flooded `:stat` tile per
      # node CONDITION (MemoryPressure / DiskPressure / PIDPressure / NotReady),
      # each counting the nodes currently asserting that condition. A tile reads
      # green at 0 (no node under that pressure) and amber/red as nodes pile up —
      # the preattentive "is any node in trouble?" headline for the node fleet.
      #
      # ── Why ONE condition metric + a condition list ─────────────────────
      # kube-state-metrics exposes every node condition through a SINGLE series
      # family — `kube_node_status_condition{condition=<C>,status="true"}` — so
      # the strip is parameterised by ONE metric name plus the list of conditions
      # to surface. Each tile is `sum(<metric>{condition="<C>",status="true"})`,
      # floored so a healthy fleet reads a lit green 0 (not ambiguous "No data").
      # NotReady is the inverse — a node is NotReady when its `Ready` condition is
      # `status="false"` — so it is expressed by flipping the status matcher.
      #
      # ── Why defect_steps ────────────────────────────────────────────────
      # A pressure condition is a DEFECT count: higher = worse. Theme.defect_steps
      # (green below warn, amber at warn, red at crit) — never a hand-typed colour.
      #
      #   row 'Node pressure' do
      #     Pangea::Dashboards::Library::NodePressureStrip.add(
      #       self, datasource: 'vm',
      #       condition_metric: 'kube_node_status_condition',
      #       conditions: %w[MemoryPressure DiskPressure PIDPressure])
      #   end
      module NodePressureStrip
        # The canonical pressure conditions kube-state-metrics exposes, plus the
        # synthetic NotReady (Ready=false). Each entry: the condition label value
        # and the status the DEFECT asserts ("true" for pressures, "false" for
        # Ready → NotReady).
        DEFAULT_CONDITIONS = %w[MemoryPressure DiskPressure PIDPressure NotReady].freeze

        # datasource:       (req) the metrics datasource uid
        # condition_metric: (req) the node-condition gauge family
        #                   (kube_node_status_condition style)
        # conditions:       node conditions to surface as tiles (default the four
        #                   canonical ones). 'NotReady' is special-cased to the
        #                   Ready=false matcher.
        # selector:         typed Hash/String matcher scoping the node population
        #                   (e.g. { cluster: '$cell' }) — merged into every tile
        # warn / crit:      defect thresholds (default 1 / 1 — any node under
        #                   pressure is already an alarm)
        # condition_label / status_label: kube-state label names (overridable)
        def self.add(row, datasource:, condition_metric: 'kube_node_status_condition',
                     conditions: DEFAULT_CONDITIONS, selector: nil, warn: 1, crit: 1,
                     condition_label: 'condition', status_label: 'status')
          validate!(datasource: datasource, condition_metric: condition_metric, conditions: conditions)
          list  = Array(conditions).map(&:to_s).reject(&:empty?)
          width = Theme.tile_width(list.length)
          steps = Theme.defect_steps(warn: warn, crit: crit)
          list.each_with_index do |cond, idx|
            add_tile(row, datasource: datasource, condition_metric: condition_metric,
                     condition: cond, selector: selector, condition_label: condition_label,
                     status_label: status_label, width: width, idx: idx, steps: steps)
          end
        end

        # One condition tile — count of nodes asserting that condition, floored.
        def self.add_tile(row, datasource:, condition_metric:, condition:, selector:,
                          condition_label:, status_label:, width:, idx:, steps:)
          sel  = condition_selector(selector, condition, condition_label, status_label)
          expr = Floor.zero("sum(#{condition_metric}#{Promql.braces(sel)})")
          pid  = :"node_pressure_#{slug(condition)}_#{idx}"
          row.panel pid, kind: :stat, width: width, height: Theme::STAT_H do
            title condition
            unit 'short'
            display :background      # colour the whole tile — preattentive defect
            graph :area              # trend sparkline behind the count (Tufte)
            description "Nodes currently asserting #{condition}. Green = none."
            # event_driven: a floored 0 is healthy, never "broken metric".
            query 'A', expr, datasource: datasource, presence: :event_driven
            threshold steps: steps
          end
        end

        # Build the typed condition selector. A pressure condition asserts
        # status="true"; the synthetic NotReady asserts the Ready condition with
        # status="false". The caller's scoping selector merges in front.
        def self.condition_selector(selector, condition, condition_label, status_label)
          cond, status = condition == 'NotReady' ? %w[Ready false] : [condition, 'true']
          inner = { condition_label.to_sym => cond, status_label.to_sym => status }
          case selector
          when ::Hash then selector.merge(inner)
          when nil then inner
          else "#{selector},#{Promql.selector_body(inner)}"
          end
        end

        def self.validate!(datasource:, condition_metric:, conditions:)
          raise ArgumentError, 'NodePressureStrip: datasource: required' if blank?(datasource)
          raise ArgumentError, 'NodePressureStrip: condition_metric: required' if blank?(condition_metric)
          list = Array(conditions).map(&:to_s).reject(&:empty?)
          raise ArgumentError, 'NodePressureStrip: conditions must be a non-empty list' if list.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_tile, :condition_selector, :validate!, :blank?, :slug
      end
    end
  end
end
