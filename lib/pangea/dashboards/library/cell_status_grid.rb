# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'

module Pangea
  module Dashboards
    module Library
      # The FLEET HEALTH GRID — a strip of colour-flooded `:stat` tiles, one per
      # cell/member of a topology, each reading a per-member health score and
      # coloured green→amber→red by the shared defect thresholds. It is the
      # preattentive fleet map: a red tile in a field of green IS the cell that
      # needs attention, found before any number is read. The grid-heatmap of
      # fleet health that opens every fleet-topology board.
      #
      # Membership is derived from a TOPOLOGY LABEL (cell / region / cloud /
      # tenant). The score for member M is the defect expression evaluated with
      # `<topology_label>="M"` substituted into the selector — one tile per
      # named member.
      #
      # ── Renderer gap (degraded form, tier-honest) ──────────────────────────
      # The IDEAL form would `repeat:` one panel across `label_values(<label>)`
      # so the grid grows with the fleet automatically; PanelBuilder has no
      # `repeat:` field yet (catalog §9.4). Until it lands, members are
      # HAND-LISTED via the `members:` kwarg (the operator enumerates the cells,
      # or fills them from a `$cell` template variable's values). A true geo-map
      # variant additionally needs a `:geomap` panel kind (catalog §9.2) — also
      # a renderer gap; the grid form ships today.
      #
      # ── Why event_driven + zero-floor ──────────────────────────────────────
      # A health-defect score is a count of unhealthy things for the member; a
      # member with zero defects has no series until its first defect, so the
      # score is floored to a lit green 0 (Floor.zero) — never an ambiguous
      # "No data" that hides a healthy cell.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Cells' do
      #     Pangea::Dashboards::Library::CellStatusGrid.add(
      #       self, datasource: 'vm', topology_label: 'cell',
      #       members: %w[cell-a cell-b cell-c],
      #       score_expr: 'count(up{cell="%{member}"} == 0)', warn: 1, crit: 3)
      #   end
      module CellStatusGrid
        # datasource:      (req) the metrics datasource uid
        # topology_label:  (req) the label that partitions the fleet (cell/region/…)
        # members:         (req) non-empty Array of member values — one tile each
        # score_expr:      (req) a PromQL template with `%{member}` substituted
        #                  for each member value (the per-member defect score)
        # warn / crit:     defect thresholds (default 1 / 3)
        # unit:            tile unit (default 'short')
        # title_suffix:    cosmetic per-tile title suffix
        def self.add(row, datasource:, topology_label:, members:, score_expr:,
                     warn: 1, crit: 3, unit: 'short', title_suffix: nil)
          validate!(datasource: datasource, topology_label: topology_label,
                    members: members, score_expr: score_expr)
          width = Theme.tile_width(members.length)
          steps = Theme.defect_steps(warn: warn, crit: crit)
          members.each_with_index do |member, idx|
            add_tile(row, member: member.to_s, datasource: datasource,
                     score_expr: score_expr, steps: steps, unit: unit,
                     width: width, title_suffix: title_suffix, idx: idx)
          end
        end

        def self.add_tile(row, member:, datasource:, score_expr:, steps:, unit:, width:, title_suffix:, idx:)
          expr = Floor.zero(format(score_expr, member: member))
          ttl  = title_suffix ? "#{member} #{title_suffix}" : member
          pid  = :"cell_#{slug(member)}_#{idx}"
          row.panel pid, kind: :stat, width: width, height: Theme::STAT_H do
            title ttl
            unit unit
            description "Health score for #{member}. Green ⇒ no defects; red ⇒ act."
            display :background      # colour the whole tile — preattentive fleet map
            graph :area              # trend sparkline behind the number (Tufte)
            # event_driven: a healthy cell reads a green 0, never "No data".
            query 'A', expr, datasource: datasource, presence: :event_driven, legend: member
            threshold steps: steps
          end
        end

        def self.validate!(datasource:, topology_label:, members:, score_expr:)
          raise ArgumentError, 'CellStatusGrid: datasource: required' if blank?(datasource)
          raise ArgumentError, 'CellStatusGrid: topology_label: required' if blank?(topology_label)
          raise ArgumentError, 'CellStatusGrid: members must be a non-empty Array' \
            unless members.is_a?(::Array) && !members.empty?
          raise ArgumentError, 'CellStatusGrid: score_expr: required (a %{member} template)' if blank?(score_expr)
          raise ArgumentError, 'CellStatusGrid: score_expr must contain %{member}' \
            unless score_expr.to_s.include?('%{member}')
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_tile, :validate!, :blank?, :slug
      end
    end
  end
end
