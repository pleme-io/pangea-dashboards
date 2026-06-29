# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/rotation_lifecycle'

# RotationLifecycle — the dynamic-secret rotation board.
RSpec.describe Pangea::Dashboards::Library::RotationLifecycle do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  describe 'happy path' do
    let(:dash) do
      Lib::RotationLifecycle.build(
        id: :rotation, name: 'Rotation Lifecycle', datasource: 'metrics', logs_datasource: 'logs',
        rotation_metric: 'rotation_total', rotation_latency_metric: 'rotation_seconds_bucket',
        producer_label: 'producer', phase_metric: 'producer_by_phase',
        stream: '{namespace="secrets"}'
      )
    end

    it 'returns a Types::Dashboard tagged pleme-io + rotation-lifecycle' do
      expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
      expect(dash.tags).to include('pleme-io', 'rotation-lifecycle')
    end

    it 'rows are in story order: defects → RED → phase → staleness → top overdue → logs' do
      expect(dash.rows.map(&:title)).to eq([
        'Status — rotation defects',
        'Rotation — RED',
        'Producer phase distribution',
        'Rotation staleness distribution',
        'Top overdue producers',
        'Logs'
      ])
    end

    it 'the defect headline carries the overdue intersection + a failure rate' do
      defects = dash.rows.find { |r| r.title == 'Status — rotation defects' }
      exprs = defects.panels.map { |p| p.queries.first.expr }.join("\n")
      expect(exprs).to include('rotation_seconds_since_last >= rotation_configured_interval_seconds')
      expect(exprs).to include('rotation_total')
      expect(exprs).to include('result=~"error|failed"')
    end

    it 'the staleness panel is a heatmap over the staleness bucket histogram' do
      stale = dash.rows.find { |r| r.title == 'Rotation staleness distribution' }
      p = stale.panels.first
      expect(p.kind).to eq(:heatmap)
      expect(p.queries.first.expr).to include('rotation_staleness_seconds_bucket')
    end

    it 'the producer-phase row is a stacked by-phase strip' do
      phase = dash.rows.find { |r| r.title == 'Producer phase distribution' }
      p = phase.panels.first
      expect(p.queries.first.expr).to include('sum by (phase)(producer_by_phase')
    end

    it 'the top-overdue table ranks producers by elapsed-since-last' do
      top = dash.rows.find { |r| r.title == 'Top overdue producers' }
      expr = top.panels.first.queries.first.expr
      expect(expr).to include('topk(10')
      expect(expr).to include('by (producer)')
      expect(expr).to include('rotation_seconds_since_last')
    end
  end

  describe 'validation' do
    it 'requires id + datasource + rotation/latency/elapsed/interval metrics' do
      expect { Lib::RotationLifecycle.build(id: :x, datasource: 'vm', rotation_metric: '',
        rotation_latency_metric: 'b', elapsed_metric: 'c', interval_metric: 'd') }
        .to raise_error(ArgumentError, /rotation_metric/)
      expect { Lib::RotationLifecycle.build(id: :x, datasource: 'vm', rotation_metric: 'a',
        rotation_latency_metric: 'b', elapsed_metric: '', interval_metric: 'd') }
        .to raise_error(ArgumentError, /elapsed_metric/)
    end
  end
end
