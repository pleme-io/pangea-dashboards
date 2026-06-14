# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The shadow-vs-live POSTURE row — three headline `:stat` tiles answering
      # "how much of the fleet is being OBSERVED vs ACTED on?" from a single
      # dry-run gauge. A controller that ships shadow-first (observe a decision
      # before it mutates anything) exposes a per-entity gauge where
      # `1 = shadow/observe` and `0 = live/act`; this row counts the whole
      # population, the live subset (gauge == 0), and the shadow subset
      # (gauge == 1), so the rollout posture is one preattentive glance:
      # enrolled total, how many are LIVE, how many are still SHADOW.
      #
      # Absorbed from breathe.rb's Fleet row (bands_total / bands_live /
      # bands_shadow over the breathe band `dryRun` gauge) and generalised — the
      # same shape fits ANY controller with a shadow/live mode knob (a migration
      # FSM's observe-then-cutover gauge, a feature-flag dark-launch gauge, an
      # autoscaler's recommend-vs-enforce gauge). The next such dashboard is one
      # call, not three re-typed count panels.
      #
      # ── Why three plain counts (display: :value, not :background) ─────────
      # These tiles are NOT defects — a fleet that is all-shadow is a healthy
      # mid-rollout state, all-live is the converged end state, and neither is
      # "red". So they carry a fixed BRAND colour (live vs shadow), value-only,
      # reserving the colour-flooded :background tiles of StatusOverview for the
      # actual defects elsewhere on the dashboard (preattentive: colour stays a
      # signal, not decoration). The enrolled total is the neutral anchor.
      #
      # ── Why `or vector(0)` on every count ────────────────────────────────
      # `count(gauge == 1)` has no series until at least one entity is in that
      # mode, so a fleet with zero shadow bands would read "No data" — ambiguous
      # (broken scrape? or genuinely none?). `Floor.zero` makes an empty subset
      # a true, lit 0. Delegates to the shared Library::Floor primitive
      # (solve-once).
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Fleet posture' do
      #     Pangea::Dashboards::Library::ShadowLivePostureRow.add(
      #       self, datasource: 'vm', dry_run_metric: 'breathe_band_dry_run',
      #       dim_selector: { dimension: 'memory' })
      #   end
      module ShadowLivePostureRow
        # dry_run_metric: (req) the per-entity gauge where 1 = shadow/observe
        #                 and 0 = live/act.
        # dim_selector:   typed Hash/String matcher scoping the population
        #                 (e.g. { dimension: 'memory' }); nil → whole fleet.
        # title:          the enrolled-total tile's title (default 'Fleet posture').
        # enrolled_label: noun for the total tile suffix (default 'enrolled').
        # live_color / shadow_color: fixed Grafana colours for the live/shadow
        #                 tiles (defaults 'blue' / 'green').
        def self.add(row, datasource:, dry_run_metric:, dim_selector: nil,
                     title: 'Fleet posture', enrolled_label: 'enrolled',
                     live_color: 'blue', shadow_color: 'green')
          validate!(datasource: datasource, dry_run_metric: dry_run_metric)
          braces = Promql.braces(dim_selector)
          width  = Theme.tile_width(3)

          # ── Enrolled total ── count of the whole scoped population.
          add_count(row, datasource: datasource, id: :"posture_enrolled_#{slug(dry_run_metric)}",
                    title: "#{title} (#{enrolled_label})", color: Theme::NEUTRAL, width: width,
                    expr: "count(#{dry_run_metric}#{braces})",
                    desc: 'Entities enrolled in the shadow/live controller.')

          # ── Live ── gauge == 0 means the controller is ACTING.
          add_count(row, datasource: datasource, id: :"posture_live_#{slug(dry_run_metric)}",
                    title: 'Live', color: live_color, width: width,
                    expr: "count(#{dry_run_metric}#{braces} == 0)",
                    desc: 'Entities the controller is acting on (dry_run = 0).')

          # ── Shadow ── gauge == 1 means the controller is only OBSERVING.
          add_count(row, datasource: datasource, id: :"posture_shadow_#{slug(dry_run_metric)}",
                    title: 'Shadow', color: shadow_color, width: width,
                    expr: "count(#{dry_run_metric}#{braces} == 1)",
                    desc: 'Entities the controller is only observing (dry_run = 1).')
        end

        # One posture tile: a floored count carrying a FIXED brand colour. The
        # colour is set through the typed `threshold` path as a single absolute
        # step (the design system's one place colour is decided) — a one-stop
        # ladder paints the whole value/tile that colour regardless of magnitude.
        def self.add_count(row, datasource:, id:, title:, color:, width:, expr:, desc:)
          q = Floor.zero(expr)
          row.panel id, kind: :stat, width: width, height: Theme::STAT_H do
            title title
            unit 'short'
            description desc
            display :value           # plain coloured number — posture, not a defect alarm
            graph :area              # trend sparkline behind the count (Tufte)
            # event_driven: an empty subset is a true 0, NEVER "broken metric".
            query 'A', q, datasource: datasource, presence: :event_driven
            # A single absolute step fixes the brand colour for the whole range.
            threshold steps: [{ color: color, value: nil }]
          end
        end

        def self.validate!(datasource:, dry_run_metric:)
          raise ArgumentError, 'ShadowLivePostureRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'ShadowLivePostureRow: dry_run_metric: required' if blank?(dry_run_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_count, :validate!, :blank?, :slug
      end
    end
  end
end
