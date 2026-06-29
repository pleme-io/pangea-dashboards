# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor'

module Pangea
  module Dashboards
    module Library
      # The RESIDENCY / COMPLIANCE posture strip — one colour-flooded `:stat`
      # tile per posture group (a value of a residency / compliance label, e.g.
      # `region=eu`, `data_class=pii`, `regime=pci`), each counting the members
      # of that group that are OUT of posture. A green wall = every group compliant;
      # a red tile = a residency or compliance seam violated for that group. The
      # data-sovereignty / regulatory analog of the defects headline: "is anything
      # off-posture right now?" answered preattentively per group.
      #
      # The count for group G is the violation expression evaluated with
      # `<posture_label>="G"` substituted in — so each tile measures ITS group's
      # off-posture cardinality (members in the wrong region, secrets in the wrong
      # class, controls failing a regime).
      #
      # ── Renderer gap (tier-honest) ──────────────────────────────────────────
      # Groups are HAND-LISTED today (`groups:`) for the same reason as
      # `CellStatusGrid` (no panel `repeat:` over `label_values(<posture_label>)`
      # yet — catalog §9.4). The operator enumerates the posture groups or fills
      # them from the posture label's values.
      #
      # ── Why event_driven + zero-floor ───────────────────────────────────────
      # An off-posture COUNT is event-driven (no series until a violation exists);
      # a compliant group reads a lit green 0 via Floor.zero, never an ambiguous
      # "No data" that could hide a compliant group OR a broken metric.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Residency posture' do
      #     Pangea::Dashboards::Library::ResidencyComplianceStrip.add(
      #       self, datasource: 'vm', posture_label: 'region',
      #       groups: %w[eu us apac],
      #       violation_expr: 'count(tenant_residency_info{region="%{group}",compliant="false"})',
      #       warn: 1, crit: 1)
      #   end
      module ResidencyComplianceStrip
        # datasource:      (req) the metrics datasource uid
        # posture_label:   (req) the residency/compliance grouping label
        # groups:          (req) non-empty Array of group values — one tile each
        # violation_expr:  (req) a PromQL template with `%{group}` substituted
        #                  (the per-group off-posture count)
        # warn / crit:     defect thresholds (default 1 / 1 — any violation = red)
        # unit:            tile unit (default 'short')
        # title_suffix:    cosmetic per-tile title suffix
        def self.add(row, datasource:, posture_label:, groups:, violation_expr:,
                     warn: 1, crit: 1, unit: 'short', title_suffix: nil)
          validate!(datasource: datasource, posture_label: posture_label,
                    groups: groups, violation_expr: violation_expr)
          width = Theme.tile_width(groups.length)
          steps = Theme.defect_steps(warn: warn, crit: crit)
          groups.each_with_index do |group, idx|
            add_tile(row, group: group.to_s, datasource: datasource, violation_expr: violation_expr,
                     steps: steps, unit: unit, width: width, title_suffix: title_suffix, idx: idx)
          end
        end

        def self.add_tile(row, group:, datasource:, violation_expr:, steps:, unit:, width:, title_suffix:, idx:)
          expr = Floor.zero(format(violation_expr, group: group))
          ttl  = title_suffix ? "#{group} #{title_suffix}" : group
          pid  = :"residency_#{slug(group)}_#{idx}"
          row.panel pid, kind: :stat, width: width, height: Theme::STAT_H do
            title ttl
            unit unit
            description "Members of #{group} out of residency/compliance posture. Green ⇒ compliant; red ⇒ violated."
            display :background      # colour the tile — preattentive posture wall
            graph :area              # trend sparkline behind the number (Tufte)
            query 'A', expr, datasource: datasource, presence: :event_driven, legend: group
            threshold steps: steps
          end
        end

        def self.validate!(datasource:, posture_label:, groups:, violation_expr:)
          raise ArgumentError, 'ResidencyComplianceStrip: datasource: required' if blank?(datasource)
          raise ArgumentError, 'ResidencyComplianceStrip: posture_label: required' if blank?(posture_label)
          raise ArgumentError, 'ResidencyComplianceStrip: groups must be a non-empty Array' \
            unless groups.is_a?(::Array) && !groups.empty?
          raise ArgumentError, 'ResidencyComplianceStrip: violation_expr: required (a %{group} template)' \
            if blank?(violation_expr)
          raise ArgumentError, 'ResidencyComplianceStrip: violation_expr must contain %{group}' \
            unless violation_expr.to_s.include?('%{group}')
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_tile, :validate!, :blank?, :slug
      end
    end
  end
end
