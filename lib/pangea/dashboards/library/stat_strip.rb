# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'

module Pangea
  module Dashboards
    module Library
      # The generic "row of headline numbers": a horizontal strip of single-
      # value `:stat` tiles, each with its own threshold colour steps + an
      # optional area sparkline. The neutral cousin of StatusOverview —
      # StatusOverview is defects-only (always `defect_steps`, always colour-
      # flooded, always `event_driven`), whereas StatStrip lets each tile carry
      # ARBITRARY semantics: a liveness gauge (lower = worse), a neutral count,
      # a hand-authored threshold ladder, value-only colouring, or no sparkline.
      #
      # This is the "overview stat strip" hand-written across the corpus — the
      # akeylesslabs argocd dashboard's Apps Synced / OutOfSync / Degraded strip,
      # and the github-actions Total / Failed / Success-Rate strip — lifted into
      # ONE typed component so a new strip is a list of tile Hashes, not three
      # near-identical hand-rolled panels.
      #
      # ── Why uniform tile widths (Theme.tile_width) ──────────────────────
      # Gestalt similarity + alignment: a row of equal-width tiles reads as one
      # coherent group ("these are the headline numbers"), where ragged widths
      # read as broken. tile_width splits the 24-col grid evenly for ≤4 tiles
      # and falls back to a uniform width-4 (wrapping) beyond that.
      #
      # ── Why the per-tile threshold choice (liveness vs defect) ──────────
      # A tile's colour semantics depend on its meaning. A DEFECT count (higher
      # = worse: OutOfSync, Degraded, Failed) wants `defect_steps`. A LIVENESS
      # gauge (lower = worse: Synced, up, Success-Rate) wants `liveness_steps`.
      # `liveness: true` picks the latter; an explicit `steps:` overrides both.
      #
      # ── Why `or vector(0)` on every tile ────────────────────────────────
      # Most headline numbers rate/count an event-driven counter that has no
      # series until its first event. `Floor.zero` makes a never-fired tile read
      # a true 0 (lit, honest) instead of an ambiguous "No data". Delegates to
      # the shared Library::Floor primitive (solve-once).
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Argo CD' do
      #     Pangea::Dashboards::Library::StatStrip.add(
      #       self, datasource: ds, tiles: [
      #         { title: 'Apps Synced',  expr: 'count(argocd_app_info{sync_status="Synced"})',
      #           liveness: true, color_mode: :value },
      #         { title: 'OutOfSync',    expr: 'count(argocd_app_info{sync_status="OutOfSync"})',
      #           steps: nil },                       # → defect_steps (higher = worse)
      #         { title: 'Degraded',     expr: 'count(argocd_app_info{health_status="Degraded"})' },
      #       ])
      #   end
      module StatStrip
        # Emit the headline tiles into `row`. `tiles` is an Array of Hashes:
        #   title:      (req) tile title — short
        #   expr:       (req) PromQL evaluating to the headline number
        #   unit:       Grafana unit (default 'short')
        #   steps:      explicit threshold steps (Array of {color:,value:});
        #               when nil, derived from `liveness:`
        #   liveness:   true → Theme.liveness_steps (lower = worse);
        #               false (default) → Theme.defect_steps (higher = worse)
        #   color_mode: display mode — :background (default) | :value | :none
        #   sparkline:  true (default) → graph :area, false → graph :none
        #   desc:       panel description
        #   datasource: per-tile override of the strip default
        #   id:         panel id symbol (default derived from title)
        def self.add(row, datasource:, tiles:)
          validate!(datasource: datasource, tiles: tiles)
          width = Theme.tile_width(tiles.length)
          tiles.each_with_index do |tile, idx|
            add_tile(row, tile.transform_keys(&:to_sym), default_ds: datasource, width: width, idx: idx)
          end
        end

        def self.add_tile(row, tile, default_ds:, width:, idx:)
          title      = tile.fetch(:title)
          expr       = tile.fetch(:expr)
          ds         = tile[:datasource] || default_ds
          unit       = tile.fetch(:unit, 'short')
          color_mode = tile.fetch(:color_mode, :background)
          sparkline  = tile.fetch(:sparkline, true)
          desc       = tile[:desc]
          pid        = tile[:id] || :"stat_#{slug(title)}_#{idx}"
          steps      = threshold_steps(tile)
          q          = Floor.zero(expr)
          row.panel pid, kind: :stat, width: width, height: Theme::STAT_H do
            title title
            unit unit
            description(desc) if desc
            display color_mode                 # :background floods the tile (preattentive)
            graph(sparkline ? :area : :none)   # area sparkline behind the number (Tufte)
            # event_driven: a floored 0 is healthy, NEVER "broken metric".
            query 'A', q, datasource: ds, presence: :event_driven
            threshold steps: steps
          end
        end

        # An explicit `steps:` wins; otherwise pick by semantics —
        # liveness (lower = worse) vs defect (higher = worse).
        def self.threshold_steps(tile)
          return tile[:steps] if tile[:steps]
          tile.fetch(:liveness, false) ? Theme.liveness_steps : Theme.defect_steps
        end

        def self.validate!(datasource:, tiles:)
          raise ArgumentError, 'StatStrip: tiles must be a non-empty Array' \
            unless tiles.is_a?(Array) && !tiles.empty?
          tiles.each do |t|
            h = t.transform_keys(&:to_sym)
            raise ArgumentError, "StatStrip: each tile needs :title (got #{t.inspect})" if blank?(h[:title])
            raise ArgumentError, "StatStrip: tile #{h[:title].inspect} needs :expr" if blank?(h[:expr])
            raise ArgumentError, "StatStrip: tile #{h[:title].inspect} needs a datasource" \
              if blank?(h[:datasource]) && blank?(datasource)
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_tile, :threshold_steps, :blank?, :slug
      end
    end
  end
end
