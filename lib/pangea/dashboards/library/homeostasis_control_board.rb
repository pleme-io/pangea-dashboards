# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/at_ceiling_defect_tile'
require 'pangea/dashboards/library/shadow_live_posture_row'
require 'pangea/dashboards/library/breathability_row'
require 'pangea/dashboards/library/band_deviation_heatmap'
require 'pangea/dashboards/library/deviation_rank_table'

module Pangea
  module Dashboards
    module Library
      # The one-call operator dashboard for a resource-homeostasis controller
      # (breathe) holding a whole BAND FLEET at its setpoints. It reads the
      # controller's OWN exported metrics (breathe_band_*) — no cadvisor /
      # kube-state dependency, because the controller IS the observer — so it
      # works the day breathe is live, across every dimension and target kind.
      #
      # The triage STORY, top-to-bottom (Theme: Status → posture → detail →
      # analytics):
      #
      #   Defects headline   →  "is any band about to OOM / has any gone stale?"
      #   Fleet posture      →  enrolled / live / shadow (rollout state)
      #   Per-dimension      →  breathability triple per dim (envelope · util/setpoint · carve activity)
      #   In-band deviation  →  fleet |util − setpoint| heatmap + worst-N rank table
      #
      # Defects-first means the operator (or the agent, over MCP) lands on
      # "is anything wrong?" before any line chart. Everything below is reuse —
      # the only net-new blocks are the two deviation analytics panels; the rest
      # are the shipped breathe building blocks folded over the band identity.
      #
      #   dash = Pangea::Dashboards::Library::HomeostasisControlBoard.build(
      #     id: :tendril_homeostasis, name: 'tendril breathe', datasource: 'metrics',
      #     dimensions: %w[memory cpu])
      module HomeostasisControlBoard
        # id/name:            dashboard id + human title
        # datasource:         (req) the metrics datasource uid
        # dimensions:         the band dimensions to give a breathability row
        #                     (default memory + cpu)
        # unit_for:           dimension → value unit map for the envelope panel
        #                     ('bytes' for memory, 'short' for cpu millicores, …)
        # dry_run_metric:     the per-band shadow/live gauge (1 = shadow, 0 = live)
        # util/setpoint/grow_above/limit/ceiling/staleness_metric:
        #                     the breathe metric names (defaults are breathe's own
        #                     exports — override for a different homeostasis observer)
        # stale_after:        seconds since last refresh that marks a band stale
        # worst_n:            how many offenders the deviation rank table ranks
        def self.build(id:, datasource:, name: nil,
                       dimensions: %w[memory cpu],
                       unit_for: { 'memory' => 'bytes', 'cpu' => 'short' },
                       dry_run_metric: 'breathe_band_dry_run',
                       util_metric: 'breathe_band_util_ratio',
                       setpoint_metric: 'breathe_band_setpoint_ratio',
                       grow_above_metric: 'breathe_band_grow_above_ratio',
                       limit_metric: 'breathe_band_current_limit',
                       ceiling_metric: 'breathe_band_ceiling',
                       staleness_metric: 'breathe_band_staleness_seconds',
                       stale_after: 300, worst_n: 10)
          validate!(id: id, datasource: datasource)
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · homeostasis")
          b.tags('pleme-io', 'homeostasis', 'breathe')

          # 1. Defects headline — OOM risk + stale bands, colour-flooded.
          ceiling_signal = Library::AtCeilingDefectTile.signal(
            util_metric: util_metric, grow_above_metric: grow_above_metric,
            limit_metric: limit_metric, ceiling_metric: ceiling_metric
          )
          stale_signal = {
            name: 'Stale bands',
            expr: "count(#{staleness_metric} >= #{stale_after})",
            warn: 1, crit: 3,
            desc: "Bands not refreshed in #{stale_after}s — a wedged or absent " \
                  'reconcile (the controller has stopped observing them).'
          }
          b.row('Status — bands needing attention') do
            Library::StatusOverview.add(self, datasource: datasource,
                                        signals: [ceiling_signal, stale_signal])
          end

          # 2. Fleet posture — enrolled / live / shadow.
          b.row('Fleet posture — shadow vs live') do
            Library::ShadowLivePostureRow.add(self, datasource: datasource,
                                              dry_run_metric: dry_run_metric)
          end

          # 3. Per-dimension breathability triple.
          Array(dimensions).each do |d|
            dim_s = d.to_s
            unit  = unit_for[dim_s] || 'short'
            b.row("#{dim_s} breathability") do
              Library::BreathabilityRow.add(self, datasource: datasource,
                                            band: { dim: dim_s }, unit: unit,
                                            legend_labels: '{{name}}')
            end
          end

          # 4. In-band deviation analytics — see the hot row, then name the worst.
          b.row('In-band deviation — is the controller converging the fleet?') do
            Library::BandDeviationHeatmap.add(self, datasource: datasource,
                                              util_metric: util_metric,
                                              setpoint_metric: setpoint_metric)
            Library::DeviationRankTable.add(self, datasource: datasource,
                                            util_metric: util_metric,
                                            setpoint_metric: setpoint_metric,
                                            worst_n: worst_n)
          end

          b.build
        end

        def self.validate!(id:, datasource:)
          raise ArgumentError, 'HomeostasisControlBoard: id: required' if blank?(id)
          raise ArgumentError, 'HomeostasisControlBoard: datasource: required' if blank?(datasource)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
