# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The SLEEP/WAKE POSTURE row — four headline tiles answering "how much of
      # the scale-to-zero fleet is resting RIGHT NOW, and how much of the time
      # has it been resting?" from a single replica-count gauge. The scale-to-zero
      # analog of ShadowLivePostureRow (which counts shadow-vs-live from a dry_run
      # gauge); here the partition is asleep (`replicas == 0`) vs awake
      # (`replicas > 0`) across an enrolled population, plus a time-at-rest % that
      # IS the efficiency promise (a fleet that sleeps 80% of the time is doing
      # its job).
      #
      #   enrolled  =  count(replicas)
      #   asleep    =  count(replicas == 0)     — resting, costing nothing
      #   awake     =  count(replicas > 0)      — serving
      #   at-rest % =  avg_over_time((replicas == bool 0)[window]) — fraction asleep
      #
      # ── Why value-coloured posture tiles (not defect tiles) ───────────────
      # Like ShadowLivePostureRow, these are NOT defects — an all-asleep fleet at
      # 3am is the IDEAL state, not "red". So enrolled/asleep/awake carry fixed
      # BRAND colours (value-only display), reserving the colour-flooded defect
      # tiles for actual alarms. The at-rest % uses a liveness ladder (higher % =
      # better savings) so a fleet that never sleeps reads amber.
      #
      # ── Why every count is floored ────────────────────────────────────────
      # `count(replicas == 0)` has no series until at least one workload is
      # asleep, so an all-awake fleet would read "No data" — ambiguous. `Floor.zero`
      # makes an empty subset a true, lit 0. Delegates to the shared
      # Library::Floor primitive (solve-once). The at-rest % uses `bool` + an
      # avg_over_time average that is always defined while the gauge exists.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Sleep/wake posture' do
      #     Pangea::Dashboards::Library::SleepWakePostureRow.add(
      #       self, datasource: 'vm', replica_metric: 'kube_deployment_status_replicas',
      #       selector: { namespace: 'apps' }, rest_window: '24h')
      #   end
      module SleepWakePostureRow
        # datasource:     (req) the metrics datasource uid
        # replica_metric: (req) replica-count gauge (0 ↔ N) per workload
        # selector:       typed Hash/String matcher scoping the enrolled fleet
        # rest_window:    averaging window for the time-at-rest % (default 24h)
        # title:          enrolled-total tile title prefix (default 'Workloads')
        # asleep_color / awake_color: fixed brand colours (defaults green/blue)
        def self.add(row, datasource:, replica_metric:, selector: nil,
                     rest_window: '24h', title: 'Workloads',
                     asleep_color: 'green', awake_color: 'blue')
          validate!(datasource: datasource, replica_metric: replica_metric)
          braces = Promql.braces(selector)
          width  = Theme.tile_width(4)

          # ── Enrolled total ── the whole scoped scale-to-zero population.
          add_count(row, datasource: datasource, id: :"swp_enrolled_#{slug(replica_metric)}",
                    title: "#{title} (enrolled)", color: Theme::NEUTRAL, width: width,
                    expr: "count(#{replica_metric}#{braces})",
                    desc: 'Workloads enrolled in the scale-to-zero fleet.')

          # ── Asleep ── replicas == 0 (resting, costing nothing).
          add_count(row, datasource: datasource, id: :"swp_asleep_#{slug(replica_metric)}",
                    title: 'Asleep', color: asleep_color, width: width,
                    expr: "count(#{replica_metric}#{braces} == 0)",
                    desc: 'Workloads scaled to zero — resting, costing nothing.')

          # ── Awake ── replicas > 0 (serving).
          add_count(row, datasource: datasource, id: :"swp_awake_#{slug(replica_metric)}",
                    title: 'Awake', color: awake_color, width: width,
                    expr: "count(#{replica_metric}#{braces} > 0)",
                    desc: 'Workloads currently scaled up and serving.')

          # ── Time at rest % ── fraction of the window asleep (the savings promise).
          add_at_rest(row, datasource: datasource, replica_metric: replica_metric,
                      braces: braces, rest_window: rest_window, width: width)
        end

        # One posture tile — a floored count carrying a FIXED brand colour through
        # a single absolute threshold step (the design system's one place colour
        # is decided), value-only so it reads as posture not a defect alarm.
        def self.add_count(row, datasource:, id:, title:, color:, width:, expr:, desc:)
          q = Floor.zero(expr)
          row.panel id, kind: :stat, width: width, height: Theme::STAT_H do
            title title
            unit 'short'
            description desc
            display :value
            graph :area
            query 'A', q, datasource: datasource, presence: :event_driven
            threshold steps: [{ color: color, value: nil }]
          end
        end

        # Time at rest % — `avg(avg_over_time((replicas == bool 0)[window]))`: the
        # mean fraction of the window each workload spent asleep. Liveness ladder
        # (higher % = better savings): a fleet that never sleeps reads amber/red.
        def self.add_at_rest(row, datasource:, replica_metric:, braces:, rest_window:, width:)
          expr = "avg(avg_over_time((#{replica_metric}#{braces} == bool 0)[#{rest_window}:]))"
          row.panel :"swp_at_rest_#{slug(replica_metric)}", kind: :stat, width: width, height: Theme::STAT_H do
            title "Time at rest (#{rest_window})"
            unit 'percentunit'
            min 0
            max 1
            description 'Fraction of the window the fleet spent asleep — the scale-to-zero savings promise. Higher = more rest.'
            display :value
            graph :area
            query 'A', expr, datasource: datasource, presence: :continuous
            # liveness: a LOW rest fraction (fleet never sleeps) is the defect.
            threshold steps: Theme.liveness_steps(ok: 0.5)
          end
        end

        def self.validate!(datasource:, replica_metric:)
          raise ArgumentError, 'SleepWakePostureRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'SleepWakePostureRow: replica_metric: required' if blank?(replica_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_count, :add_at_rest, :validate!, :blank?, :slug
      end
    end
  end
end
