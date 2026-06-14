# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The GitOps-convergence headline: a row of liveness :stat tiles — one per
      # FluxCD reconcile kind (Kustomization / HelmRelease / GitRepository …) —
      # each green when that kind's Ready-condition is being met and red when it
      # isn't, plus a single trailing "not ready" defect tile that counts the
      # resources whose Ready condition is currently False. It answers "is the
      # cluster converged to git?" in one preattentive glance: a strip of green
      # = everything FluxCD owns is reconciled; any red = drill into that kind.
      #
      # Ready-per-kind = `sum(ready_metric{type=<kind>,status="True"})` — the
      # count of resources of that kind whose `Ready` gotk_reconcile_condition is
      # True. It is a sampled gauge (continuous), red below 1 and green at/above
      # via Theme.liveness_steps, so a kind with zero ready resources reads red.
      # The not-ready tile = `sum(ready_metric{status="False"})`, an event-driven
      # defect count floored with `or vector(0)` (no series until something
      # fails) and coloured with Theme.defect_steps (higher = worse).
      #
      # ── Why one tile per kind (Theme.tile_width) ────────────────────────
      # Gestalt similarity + alignment: a row of equal-width tiles, one per
      # reconcile kind, reads as one coherent "convergence" group. tile_width
      # splits the 24-col grid evenly across the kinds (+ the trailing failures
      # tile), so the strip always fills a row cleanly rather than reading ragged.
      #
      # ── Why liveness on the kind tiles, defect on the failures tile ─────
      # A kind tile is a LIVENESS gauge (lower = worse: fewer Ready resources is
      # worse) → liveness_steps (red@0, green@1). The failures tile is a DEFECT
      # count (higher = worse: more not-ready resources is worse) → defect_steps.
      # The two semantics share one strip because together they answer the same
      # question from both sides — "what is converged" and "what is not".
      #
      # ── Absorbed from ───────────────────────────────────────────────────
      # convergence_dashboard.rb `fluxcd-reconcile-status-strip` — the legacy
      # hand-written gotk_reconcile_condition Ready-per-kind panel set, lifted
      # onto the typed AST + the design system (Theme/Promql/Floor) so the next
      # GitOps dashboard is one call, not a re-typed panel group.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'GitOps convergence' do
      #     Pangea::Dashboards::Library::FluxReconcileStrip.add(
      #       self, datasource: 'vm',
      #       kinds: %w[Kustomization HelmRelease GitRepository])
      #   end
      module FluxReconcileStrip
        # Emit the convergence strip into `row`.
        #
        # datasource:   (req) metrics datasource uid (vm).
        # kinds:        reconcile kinds to render a Ready tile for, matched on
        #               the `type` label (default Kustomization/HelmRelease/
        #               GitRepository — the FluxCD core kinds).
        # ready_metric: the gotk reconcile-condition gauge (default
        #               'gotk_reconcile_condition'), labelled by `type` + `status`.
        # type_label:   the label carrying the reconcile kind (default 'type').
        # status_label: the label carrying the condition state (default 'status').
        # title:        a label for error/legend context (default 'GitOps
        #               convergence').
        def self.add(row, datasource:, kinds: %w[Kustomization HelmRelease GitRepository],
                     ready_metric: 'gotk_reconcile_condition', type_label: 'type',
                     status_label: 'status', title: 'GitOps convergence')
          validate!(datasource: datasource, kinds: kinds, ready_metric: ready_metric,
                    type_label: type_label, status_label: status_label)

          # One tile per kind + one trailing "not ready" failures tile, all
          # uniform-width so the strip fills the row cleanly (Gestalt).
          width = Theme.tile_width(kinds.length + 1)

          kinds.each_with_index do |kind, idx|
            add_ready_tile(row, datasource: datasource, ready_metric: ready_metric,
                           kind: kind, type_label: type_label, status_label: status_label,
                           width: width, idx: idx)
          end

          add_failures_tile(row, datasource: datasource, ready_metric: ready_metric,
                            status_label: status_label, title: title, width: width)
        end

        # The per-kind Ready liveness tile: `sum(ready_metric{type=<kind>,
        # status="True"})` — the count of that kind's resources whose Ready
        # condition is True. Continuous (a sampled gauge), liveness-coloured
        # (red below 1, green at/above) so an unconverged kind reads red.
        def self.add_ready_tile(row, datasource:, ready_metric:, kind:, type_label:,
                                status_label:, width:, idx:)
          selector = { type_label.to_sym => kind, status_label.to_sym => 'True' }
          expr  = "sum(#{ready_metric}#{Promql.braces(selector)})"
          pid   = :"flux_ready_#{slug(kind)}_#{idx}"
          steps = Theme.liveness_steps(ok: 1)
          row.panel pid, kind: :stat, width: width, height: Theme::STAT_H do
            title "#{kind} ready"
            unit 'short'
            description "Resources of kind #{kind} whose Ready condition is True " \
                        "(sum of #{ready_metric}{#{type_label}=#{kind},#{status_label}=True}). " \
                        'Green = converged to git; red = nothing reconciled.'
            display :background       # colour the tile — preattentive liveness
            graph :area               # trend sparkline behind the number (Tufte)
            # continuous: a Ready count is a sampled gauge, not event-driven.
            query 'A', expr, datasource: datasource, presence: :continuous
            threshold steps: steps
          end
        end

        # The trailing "not ready" defect tile: `sum(ready_metric{status=
        # "False"})` floored with `or vector(0)` — the count of resources whose
        # Ready condition is currently False, across all kinds. Event-driven (no
        # series until something fails) and defect-coloured (higher = worse).
        def self.add_failures_tile(row, datasource:, ready_metric:, status_label:, title:, width:)
          selector = { status_label.to_sym => 'False' }
          expr  = Floor.zero("sum(#{ready_metric}#{Promql.braces(selector)})")
          steps = Theme.defect_steps(warn: 1)
          row.panel :flux_not_ready, kind: :stat, width: width, height: Theme::STAT_H do
            title 'Not ready'
            unit 'short'
            description "#{title}: resources whose Ready condition is False " \
                        "(sum of #{ready_metric}{#{status_label}=False}). " \
                        'Green 0 = all reconciled; red = something is not converged.'
            display :background       # colour the tile — preattentive status
            graph :area               # trend sparkline behind the number (Tufte)
            # event_driven: a floored 0 is healthy, NEVER "broken metric".
            query 'A', expr, datasource: datasource, presence: :event_driven
            threshold steps: steps
          end
        end

        def self.validate!(datasource:, kinds:, ready_metric:, type_label:, status_label:)
          raise ArgumentError, 'FluxReconcileStrip: datasource: required' if blank?(datasource)
          raise ArgumentError, 'FluxReconcileStrip: ready_metric: required' if blank?(ready_metric)
          raise ArgumentError, 'FluxReconcileStrip: type_label: required' if blank?(type_label)
          raise ArgumentError, 'FluxReconcileStrip: status_label: required' if blank?(status_label)
          raise ArgumentError, 'FluxReconcileStrip: kinds must be a non-empty Array' \
            unless kinds.is_a?(Array) && !kinds.empty?
          kinds.each do |k|
            raise ArgumentError, "FluxReconcileStrip: each kind must be non-blank (got #{k.inspect})" if blank?(k)
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_ready_tile, :add_failures_tile, :validate!, :blank?, :slug
      end
    end
  end
end
