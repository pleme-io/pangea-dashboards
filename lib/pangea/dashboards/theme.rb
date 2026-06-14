# frozen_string_literal: true

module Pangea
  module Dashboards
    # The pleme-io dashboard DESIGN SYSTEM — the single place the visual
    # language is decided, so every generated dashboard is consistent and
    # calm rather than "all over the place". Dashboards-as-code means the
    # aesthetic is a typed constant, not a per-panel guess.
    #
    # ── The principles it encodes (named, so they're falsifiable) ─────────
    # • Gestalt — alignment + similarity + proximity: uniform tile sizes per
    #   role, rows that fill the 24-col grid evenly, related panels grouped
    #   under one row title. Ragged widths and mixed heights read as "broken"
    #   to the eye before any data is parsed.
    # • Preattentive processing: colour + size are perceived in <200ms, before
    #   reading. So STATUS gets colour (a red tile is seen, not read) and the
    #   rest stays neutral — colour is a signal, not decoration. One red tile
    #   in a field of grey is found instantly; a rainbow dashboard hides it.
    # • Tufte data-ink: maximise signal per pixel — soft gradient fills, no
    #   point clutter, sparklines behind single numbers, no chartjunk.
    # • Stephen Few (Information Dashboard Design): the dashboard tells a
    #   triage STORY top-to-bottom — Status → Presence → Golden signals →
    #   Detail → Logs — so the eye lands on "is it OK?" first and drills down
    #   only if not.
    # • Visual hierarchy: the most decision-relevant panel is biggest/highest;
    #   supporting detail is smaller/lower.
    module Theme
      GRID = 24 # Grafana's fixed column count.

      # ── Status palette ──────────────────────────────────────────────────
      # Green→amber→red, the universal traffic-light semantics. Amber (not
      # yellow) reads better on Grafana's dark canvas; red is reserved for
      # "act now" so it keeps its alarm value.
      OK     = 'green'
      WARN   = 'orange'
      CRIT   = 'red'
      NEUTRAL = 'blue'
      MUTED  = 'text'

      # Defect thresholds: a defect counter where HIGHER = worse. green below
      # `warn`, amber at `warn`, red at `crit`. nil base = the implicit green.
      def self.defect_steps(warn: 1, crit: nil)
        steps = [{ color: OK, value: nil }, { color: WARN, value: warn.to_f }]
        steps << { color: CRIT, value: crit.to_f } if crit
        steps
      end

      # Liveness thresholds: a health gauge where LOWER = worse (e.g. up,
      # expected-jobs-present). red below `ok`, green at/above it.
      def self.liveness_steps(ok: 1)
        [{ color: CRIT, value: nil }, { color: OK, value: ok.to_f }]
      end

      # ── Grid tiling ───────────────────────────────────────────────────
      # Uniform tile width for a row of `count` equal stat tiles that fills
      # the 24-col grid cleanly. ≤4 tiles split 24 exactly (24/12/8/6); 5+
      # tiles use a uniform width 4 (6 per row) and wrap — uniform beats
      # "exactly fills" because the eye values equal sizes over a full row.
      def self.tile_width(count)
        return GRID if count <= 1
        count <= 4 ? GRID / count : 4
      end

      # Half / third / full width helpers for time-series + tables, so
      # authors name intent ("two side by side") not magic numbers.
      def self.full = GRID
      def self.half = GRID / 2          # 12 — two charts side by side
      def self.third = GRID / 3         # 8  — three across
      def self.two_thirds = (GRID / 3) * 2 # 16 — chart + companion

      # ── Role heights (mirror dsl.rb default_height; named for authors) ──
      STAT_H  = 4
      TS_H    = 8
      TABLE_H = 9
      HERO_TS_H = 10 # the one headline chart gets extra room
    end
  end
end
