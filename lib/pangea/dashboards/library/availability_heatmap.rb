# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # PER-MEMBER AVAILABILITY over time — ONE `:heatmap` plotting each fleet
      # member's availability (from a synthetic uptime probe) as a lane over time,
      # so a dip in any member's availability is a cool/hot band the eye finds
      # immediately. Read top-to-bottom + left-to-right: a calm green field =
      # everyone up; a hot cell = a member down at that moment.
      #
      # The series is `avg by(<topology_label>)(<probe_up_metric>)` — the mean
      # success of the probe per member, a 0–1 availability ratio. One series per
      # member, bucketed by the heatmap over the time axis.
      #
      # ── Renderer gap (tier-honest — :heatmap, NOT :status_history) ───────────
      # The IDEAL panel kind for "one discrete up/down lane per member" is
      # Grafana's `:status_history` / `:state_timeline` (catalog §9.3) — a
      # renderer gap (PanelKind has no such member). Until it lands, this uses
      # `:heatmap` (the buildable-today approximation the catalog names): a
      # continuous availability lane reads the same dip-finding story without the
      # discrete state cells. The `options(grafana:)` seam carries the per-member
      # bucket hint; a backend ignoring it degrades to a plain heatmap.
      #
      # ── Why :continuous (no zero-floor) ─────────────────────────────────────
      # The probe is a gauge always present while a member is enrolled; a genuine
      # 0 availability is a real (bad) reading, a vanished member SHOULD read
      # "No data" (probe stopped) — so the series is never floored.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Availability' do
      #     Pangea::Dashboards::Library::AvailabilityHeatmap.add(
      #       self, datasource: 'vm', topology_label: 'cell',
      #       probe_up_metric: 'probe_success', selector: { job: 'blackbox' })
      #   end
      module AvailabilityHeatmap
        # datasource:       (req) the metrics datasource uid
        # topology_label:   (req) the per-member lane label (cell/tenant/region)
        # probe_up_metric:  (req) the synthetic-probe up gauge (1 = up, 0 = down)
        # selector:         optional typed matcher scoping the probe population
        # title:            cosmetic override
        def self.add(row, datasource:, topology_label:, probe_up_metric:, selector: nil, title: nil)
          validate!(datasource: datasource, topology_label: topology_label, probe_up_metric: probe_up_metric)
          expr = "avg#{Promql.by(topology_label)}(#{probe_up_metric}#{Promql.braces(selector)})"
          row.panel :availability_heatmap, kind: :heatmap, width: Theme.full, height: Theme::TABLE_H do
            title title || "Availability by #{topology_label} over time"
            unit 'percentunit'
            min 0
            max 1
            description "Per-#{topology_label} synthetic-probe availability over time. " \
                        'A hot cell = a member down at that moment. ' \
                        '(:heatmap approximation — a per-member status_history lane is a renderer gap.)'
            # The typed grafana seam: bucket the heatmap by the member label so
            # each member is its own lane. Ignored gracefully by a backend that
            # doesn't know the key (degrades to a plain heatmap).
            options(grafana: { 'heatmap' => { 'yBucketBound' => 'auto' },
                               'rowsFrame' => { 'layout' => "#{topology_label}" } })
            query 'A', expr, datasource: datasource, presence: :continuous, legend: "{{#{topology_label}}}"
          end
        end

        def self.validate!(datasource:, topology_label:, probe_up_metric:)
          raise ArgumentError, 'AvailabilityHeatmap: datasource: required' if blank?(datasource)
          raise ArgumentError, 'AvailabilityHeatmap: topology_label: required' if blank?(topology_label)
          raise ArgumentError, 'AvailabilityHeatmap: probe_up_metric: required' if blank?(probe_up_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
