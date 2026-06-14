# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/by_phase_strip'

# ByPhaseStrip — the lifecycle/FSM distribution row. A stacked by-phase
# timeseries (+ optional liveness settled stat). Builds a RowBuilder, runs
# .add, and asserts on the emitted PromQL text, panel kind/width/presence,
# the grafana stacking override, and the settled stat's liveness thresholds.
RSpec.describe Pangea::Dashboards::Library::ByPhaseStrip do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'happy path — strip only' do
    let(:built) do
      row_with do |r|
        Lib::ByPhaseStrip.add(r, datasource: 'vm', phase_metric: 'pangea_template_by_phase')
      end
    end

    it 'emits a single full-width stacked timeseries' do
      expect(built.panels.size).to eq(1)
      p = built.panels.first
      expect(p.kind).to eq(:timeseries)
      expect(p.width).to eq(Theme.full)
      expect(p.height).to eq(Theme::TS_H)
      expect(p.min).to eq(0)
    end

    it 'builds sum by(phase)(metric) through Promql with a {{phase}} legend' do
      q = built.panels.first.queries.first
      expect(q.expr).to eq('sum by (phase)(pangea_template_by_phase)')
      expect(q.legend_format).to eq('{{phase}}')
    end

    it 'is continuous (a sampled FSM gauge, never event-driven — no zero-floor)' do
      q = built.panels.first.queries.first
      expect(q.presence).to eq(:continuous)
      expect(q.expr).not_to include('vector(0)')
    end

    it 'sets grafana stacking through the typed options escape hatch (not hardcoded)' do
      stacking = built.panels.first.options.dig(:grafana, 'fieldConfig', 'defaults', 'custom', 'stacking')
      expect(stacking).to eq('mode' => 'normal', 'group' => 'A')
    end
  end

  describe 'typed selector + custom phase_label' do
    let(:built) do
      row_with do |r|
        Lib::ByPhaseStrip.add(r, datasource: 'vm', phase_metric: 'kube_pod_status_phase',
          phase_label: 'phase', selector: { namespace: 'payments' })
      end
    end

    it 'scopes the population with a typed Hash selector' do
      expect(built.panels.first.queries.first.expr)
        .to eq('sum by (phase)(kube_pod_status_phase{namespace="payments"})')
    end
  end

  describe 'with a settled liveness stat' do
    let(:built) do
      row_with do |r|
        Lib::ByPhaseStrip.add(r, datasource: 'vm', phase_metric: 'pangea_template_by_phase',
          settled_metric: 'pangea_template_settled', settled_threshold: 7)
      end
    end

    it 'narrows the strip to two-thirds and adds a third-width settled stat' do
      expect(built.panels.size).to eq(2)
      strip, settled = built.panels
      expect(strip.kind).to eq(:timeseries)
      expect(strip.width).to eq(Theme.two_thirds)
      expect(settled.kind).to eq(:stat)
      expect(settled.width).to eq(Theme.third)
      expect(settled.height).to eq(Theme::STAT_H)
    end

    it 'sums the settled metric and colour-floods the tile' do
      settled = built.panels.last
      expect(settled.queries.first.expr).to eq('sum(pangea_template_settled)')
      expect(settled.queries.first.presence).to eq(:continuous)
      expect(settled.display_mode).to eq(:background)
    end

    it 'uses liveness thresholds (red below the expected count, green at/above)' do
      settled = built.panels.last
      steps = settled.thresholds.steps
      expect(steps.map(&:color)).to eq(%w[red green])
      expect(steps.last.value).to eq(7.0)
    end

    it 'threads the selector through the settled stat too' do
      built2 = row_with do |r|
        Lib::ByPhaseStrip.add(r, datasource: 'vm', phase_metric: 'm_by_phase',
          settled_metric: 'm_settled', selector: { schema: 'rio' })
      end
      expect(built2.panels.last.queries.first.expr).to eq('sum(m_settled{schema="rio"})')
    end
  end

  describe 'validation' do
    it 'requires a datasource' do
      expect { row_with { |r| Lib::ByPhaseStrip.add(r, datasource: nil, phase_metric: 'm') } }
        .to raise_error(ArgumentError, /ByPhaseStrip.*datasource/)
    end

    it 'requires a phase_metric' do
      expect { row_with { |r| Lib::ByPhaseStrip.add(r, datasource: 'vm', phase_metric: '') } }
        .to raise_error(ArgumentError, /ByPhaseStrip.*phase_metric/)
    end

    it 'requires a non-blank phase_label' do
      expect { row_with { |r| Lib::ByPhaseStrip.add(r, datasource: 'vm', phase_metric: 'm', phase_label: '') } }
        .to raise_error(ArgumentError, /ByPhaseStrip.*phase_label/)
    end
  end
end
