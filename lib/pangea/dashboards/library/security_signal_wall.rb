# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/overdue_defect_tile'
require 'pangea/dashboards/library/version_skew_defect_tile'
require 'pangea/dashboards/library/new_entity_window_signal'
require 'pangea/dashboards/library/security_event_pipeline_health_row'

module Pangea
  module Dashboards
    module Library
      # The DEFECT-TILE WALL — the security-posture meta board. One colour-flooded
      # StatusOverview strip carrying the WORST-OF defect across the whole security
      # posture (overdue rotations/expiries, config/version skew, new/anomalous
      # entities, plus any board-specific defects the consumer injects), backed by
      # the audit pipeline's OWN health (a silent audit gap is itself the worst
      # defect — if the security tap is dead, every green tile is a lie).
      #
      # This is the meta roll-up over domain 2: it reuses the typed signal builders
      # (OverdueDefectTile / VersionSkewDefectTile / NewEntityWindowSignal) so the
      # wall's tiles are the SAME defect definitions the specialised boards use —
      # one source of truth, surfaced twice. The consumer supplies which signal
      # sources apply (each optional; at least one required so the wall is never
      # empty) + the audit-pipeline health metrics.
      #
      # ── Renderer gap (tier-honest) ──────────────────────────────────────────
      # The catalog's design has each wall tile DRILL-LINK to its specialised
      # dashboard. PanelBuilder has no `links:` field yet (a named renderer gap),
      # so today the wall surfaces the worst-of tiles preattentively and the
      # operator/agent navigates to the specialised board by name. The drill-link
      # is additive once panel `links:` lands.
      #
      #   dash = Pangea::Dashboards::Library::SecuritySignalWall.build(
      #     id: :sec_wall, name: 'security', datasource: 'metrics',
      #     overdue: { elapsed_metric: 'secret_age_seconds', interval_metric: 'secret_rotation_interval_seconds' },
      #     version_skew: { version_metric: 'gateway_config_version' },
      #     extra_signals: [ AuthMethodHealth-style denial signal hashes ],
      #     pipeline_health: true)
      module SecuritySignalWall
        # id/name:         dashboard id + human title
        # datasource:      (req) the metrics datasource uid
        # overdue:         optional Hash splatted into OverdueDefectTile.signal
        # version_skew:    optional Hash splatted into VersionSkewDefectTile.signal
        # new_entity:      optional Hash splatted into NewEntityWindowSignal.signal
        # extra_signals:   optional Array of raw StatusOverview signal Hashes
        #                  (e.g. an AuthMethodHealth denial defect from another board)
        # pipeline_health: when true, add the audit-pipeline self-health row
        # pipeline_opts:   kwargs for SecurityEventPipelineHealthRow.add (all default)
        def self.build(id:, datasource:, name: nil,
                       overdue: nil, version_skew: nil, new_entity: nil,
                       extra_signals: [], pipeline_health: false, pipeline_opts: {})
          validate!(id: id, datasource: datasource)
          signals = []
          signals << Library::OverdueDefectTile.signal(**sym(overdue))           if overdue
          signals << Library::VersionSkewDefectTile.signal(**sym(version_skew))   if version_skew
          signals << Library::NewEntityWindowSignal.signal(**sym(new_entity))     if new_entity
          signals.concat(Array(extra_signals))
          if signals.empty?
            raise ArgumentError,
                  'SecuritySignalWall: at least one signal source required ' \
                  '(overdue / version_skew / new_entity / extra_signals)'
          end

          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · security signal wall")
          b.tags('pleme-io', 'security', 'meta')

          b.row('Security defects — worst-of across the posture') do
            Library::StatusOverview.add(self, datasource: datasource, signals: signals)
          end

          if pipeline_health
            opts = sym(pipeline_opts)
            b.row('Audit pipeline health — is the security tap itself alive?') do
              Library::SecurityEventPipelineHealthRow.add(self, datasource: datasource, **opts)
            end
          end

          b.build
        end

        def self.sym(h) = (h || {}).transform_keys(&:to_sym)

        def self.validate!(id:, datasource:)
          raise ArgumentError, 'SecuritySignalWall: id: required' if blank?(id)
          raise ArgumentError, 'SecuritySignalWall: datasource: required' if blank?(datasource)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :sym, :validate!, :blank?
      end
    end
  end
end
