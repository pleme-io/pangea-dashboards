# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/flux_reconcile_strip'

# FluxReconcileStrip — the GitOps-convergence overview strip: one liveness
# Ready :stat per reconcile kind + a trailing not-ready defect :stat. Builds a
# RowBuilder, runs .add, and asserts on the emitted PromQL text, the panel
# kind/width/presence, and the threshold colours.
RSpec.describe Pangea::Dashboards::Library::FluxReconcileStrip do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe '.add — happy path (default kinds)' do
    let(:built) do
      row_with { |r| Lib::FluxReconcileStrip.add(r, datasource: 'vm') }
    end

    it 'emits one Ready tile per kind plus a trailing not-ready tile' do
      expect(built.panels.size).to eq(4) # 3 kinds + 1 failures
      ids = built.panels.map(&:id)
      expect(ids).to eq(%i[
                          flux_ready_kustomization_0
                          flux_ready_helmrelease_1
                          flux_ready_gitrepository_2
                          flux_not_ready
                        ])
    end

    it 'tiles are uniform-width :stat tiles sized for kinds + failures tile' do
      # 3 kinds + 1 failures = 4 tiles → tile_width(4) = 6.
      expect(built.panels.map(&:width)).to all(eq(Theme.tile_width(4)))
      expect(built.panels.map(&:width)).to all(eq(6))
      expect(built.panels.map(&:kind)).to all(eq(:stat))
      expect(built.panels.map(&:height)).to all(eq(Theme::STAT_H))
      expect(built.panels.map(&:display_mode)).to all(eq(:background))
    end

    it 'each Ready tile is sum(ready_metric{type=<kind>,status="True"}), continuous + liveness-coloured' do
      kust = built.panels.find { |p| p.id == :flux_ready_kustomization_0 }
      expect(kust.title).to eq('Kustomization ready')
      expect(kust.queries.first.expr)
        .to eq('sum(gotk_reconcile_condition{type="Kustomization",status="True"})')
      expect(kust.queries.first.presence).to eq(:continuous)
      # liveness: red below 1, green at/above (lower = worse).
      expect(kust.thresholds.steps.map(&:color)).to eq(%w[red green])
      expect(kust.thresholds.steps.map(&:value)).to eq([nil, 1.0])

      hr = built.panels.find { |p| p.id == :flux_ready_helmrelease_1 }
      expect(hr.queries.first.expr)
        .to eq('sum(gotk_reconcile_condition{type="HelmRelease",status="True"})')
    end

    it 'the not-ready tile is a floored event-driven defect over status="False"' do
      nr = built.panels.find { |p| p.id == :flux_not_ready }
      expect(nr.title).to eq('Not ready')
      expect(nr.queries.first.expr)
        .to eq('sum(gotk_reconcile_condition{status="False"}) or vector(0)')
      expect(nr.queries.first.presence).to eq(:event_driven)
      # defect: green base + amber at warn=1 (higher = worse).
      expect(nr.thresholds.steps.map(&:color)).to eq(%w[green orange])
    end
  end

  describe '.add — typed selector via custom kinds + labels' do
    let(:built) do
      row_with do |r|
        Lib::FluxReconcileStrip.add(r, datasource: 'vm',
          kinds: %w[OCIRepository],
          ready_metric: 'flux_resource_condition',
          type_label: 'kind', status_label: 'state')
      end
    end

    it 'threads the kind through the typed type_label selector and renders Hash matchers' do
      expect(built.panels.size).to eq(2) # 1 kind + 1 failures
      ready = built.panels.first
      expect(ready.queries.first.expr)
        .to eq('sum(flux_resource_condition{kind="OCIRepository",state="True"})')
      # single kind + failures = 2 tiles → tile_width(2) = 12.
      expect(ready.width).to eq(Theme.tile_width(2))
      expect(ready.width).to eq(12)
    end

    it 'the not-ready tile uses the custom status_label too' do
      nr = built.panels.find { |p| p.id == :flux_not_ready }
      expect(nr.queries.first.expr)
        .to eq('sum(flux_resource_condition{state="False"}) or vector(0)')
    end
  end

  describe '.add — validation' do
    it 'requires a datasource' do
      expect { row_with { |r| Lib::FluxReconcileStrip.add(r, datasource: nil) } }
        .to raise_error(ArgumentError, /FluxReconcileStrip.*datasource/)
    end

    it 'requires a non-empty kinds array' do
      expect { row_with { |r| Lib::FluxReconcileStrip.add(r, datasource: 'vm', kinds: []) } }
        .to raise_error(ArgumentError, /FluxReconcileStrip.*kinds/)
    end

    it 'rejects a blank kind entry' do
      expect { row_with { |r| Lib::FluxReconcileStrip.add(r, datasource: 'vm', kinds: ['HelmRelease', '']) } }
        .to raise_error(ArgumentError, /FluxReconcileStrip.*kind/)
    end
  end
end
