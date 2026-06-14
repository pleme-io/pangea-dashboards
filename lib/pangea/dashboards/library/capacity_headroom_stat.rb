# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # A single headroom STAT tile, as a reusable atom. One colour-flooded
      # `:stat` with an area sparkline behind the number, for a "how much room
      # is left?" gauge where LOWER = worse — free-disk bytes, memory-available
      # %, remaining active-series budget. The whole expr is wrapped in a
      # reducer (`min` by default — the worst node is the one that fills up
      # first, so min is the honest fleet-wide headroom) and read against a
      # red→orange→green liveness ladder: red below the floor (act now), orange
      # at the warn shelf, green once there's comfortable headroom.
      #
      # ── Why red→orange→green (not the defect green→amber→red) ────────────
      # A headroom metric inverts the usual sense: a BIG number is healthy and
      # a SMALL one is the alarm. So the threshold steps run red at the bottom
      # and green at the top — the opposite direction of a defect counter.
      # Theme.liveness_steps only encodes the two-stop case (red→green); a
      # three-stop headroom ladder needs an explicit red/orange/green built
      # from the Theme palette (CRIT/WARN/OK), which is what this component
      # does — never a hand-typed colour string.
      #
      # ── Why a reducer ───────────────────────────────────────────────────
      # `min(node_memory_MemAvailable_bytes / …)` reports the tightest node;
      # `max`/`avg` are offered for the cases where the aggregate or the
      # average is the headroom that matters. The author names the intent
      # (:min/:max/:avg) rather than hand-wrapping the expr.
      #
      # Absorbed from victoria_metrics_health.rb's `free_disk` /
      # `active_series` tiles and node_host.rb's `mem_avail_pct` tile — three
      # hand-written copies of the same min-wrapped, area-sparkline,
      # red→orange→green headroom stat. Per the prime directive: solve once.
      #
      #   row 'Capacity' do
      #     Pangea::Dashboards::Library::CapacityHeadroomStat.add(
      #       self, datasource: 'vm', title: 'Free disk space',
      #       expr: 'vm_free_disk_space_bytes', unit: 'bytes',
      #       floor: 5e9, ok: 2e10)
      #   end
      module CapacityHeadroomStat
        REDUCERS = %i[min max avg].freeze

        # datasource: (req) metrics datasource uid
        # expr:       (req) the headroom expression (wrapped in `reducer(...)`)
        # reducer:    :min (default) | :max | :avg — fleet aggregation
        # unit:       Grafana unit (default 'percent')
        # floor:      (req) below this → red (act now)
        # warn:       at/above this → orange; nil (default) collapses the
        #             middle shelf so it's a two-stop red→green ladder
        # ok:         (req) at/above this → green (comfortable headroom)
        # title:      (req) tile title — the resource, not the metric
        # id:         panel id symbol (default derived from title)
        def self.add(row, datasource:, expr:, reducer: :min, unit: 'percent',
                     floor:, warn: nil, ok:, title:, id: nil)
          validate!(datasource: datasource, expr: expr, reducer: reducer,
                    floor: floor, warn: warn, ok: ok, title: title)
          q     = reduced(reducer, expr)
          pid   = id || :"headroom_#{slug(title)}"
          steps = headroom_steps(floor: floor, warn: warn, ok: ok)
          row.panel pid, kind: :stat, width: Theme.tile_width(4), height: Theme::STAT_H do
            title title
            unit unit
            display :background      # colour the whole tile — preattentive status
            graph :area              # trend sparkline behind the number (Tufte)
            # continuous: a headroom gauge always has a value (it's a level,
            # not an event), so NEVER floor it with `or vector(0)`.
            query 'A', q, datasource: datasource, presence: :continuous
            threshold steps: steps
          end
        end

        # Wrap the expr in the chosen reducer: min(expr) / max(expr) / avg(expr).
        def self.reduced(reducer, expr) = "#{reducer}(#{expr})"

        # The red→orange→green liveness ladder for a LOWER-is-worse metric,
        # built from the Theme palette (never hand-typed colours). Base step
        # has nil value = "everything below the next step", i.e. red. The
        # orange shelf is omitted when `warn` is nil → a two-stop red→green.
        def self.headroom_steps(floor:, warn:, ok:)
          steps = [{ color: Theme::CRIT, value: nil }]
          steps << { color: Theme::WARN, value: (warn || floor).to_f }
          steps << { color: Theme::OK, value: ok.to_f }
          steps
        end

        def self.validate!(datasource:, expr:, reducer:, floor:, warn:, ok:, title:)
          raise ArgumentError, 'CapacityHeadroomStat: datasource: required' if blank?(datasource)
          raise ArgumentError, 'CapacityHeadroomStat: expr: required' if blank?(expr)
          raise ArgumentError, 'CapacityHeadroomStat: title: required' if blank?(title)
          raise ArgumentError, "CapacityHeadroomStat: reducer must be one of #{REDUCERS.inspect} (got #{reducer.inspect})" \
            unless REDUCERS.include?(reducer)
          raise ArgumentError, 'CapacityHeadroomStat: floor: required (Numeric)' \
            unless floor.is_a?(Numeric)
          raise ArgumentError, 'CapacityHeadroomStat: ok: required (Numeric)' \
            unless ok.is_a?(Numeric)
          raise ArgumentError, "CapacityHeadroomStat: warn: must be Numeric or nil (got #{warn.inspect})" \
            unless warn.nil? || warn.is_a?(Numeric)
          raise ArgumentError, "CapacityHeadroomStat: thresholds must ascend floor#{warn ? ' ≤ warn' : ''} ≤ ok (got floor=#{floor}, warn=#{warn.inspect}, ok=#{ok})" \
            unless ascending?(floor, warn, ok)
        end

        # floor ≤ warn ≤ ok (warn optional, skipped when nil).
        def self.ascending?(floor, warn, ok)
          ordered = [floor, warn, ok].compact
          ordered.each_cons(2).all? { |a, b| a <= b }
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :reduced, :headroom_steps, :validate!, :ascending?, :blank?, :slug
      end
    end
  end
end
