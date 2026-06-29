# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/wake_event_timeline'

# WakeEventTimeline — one step-interpolated replica-count series (continuous
# gauge) + a floored wake-event rate overlay. Step interpolation rides the typed
# options(grafana:) fieldConfig escape hatch (degrades gracefully).
RSpec.describe Pangea::Dashboards::Library::WakeEventTimeline do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'replicas + wakes' do
    let(:built) do
      row_with do |r|
        Lib::WakeEventTimeline.add(r, datasource: 'vm',
          replica_metric: 'kube_deployment_status_replicas',
          wake_counter: 'keda_scaledobject_activations_total',
          group_by: %w[deployment])
      end
    end

    it 'emits ONE timeseries panel' do
      expect(built.panels.size).to eq(1)
      expect(built.panels.first.kind).to eq(:timeseries)
    end

    it 'replicas are a continuous gauge (NEVER floored), grouped by the labels' do
      p = built.panels.first
      a = p.queries.find { |q| q.ref == 'A' }
      expect(a.expr).to eq('sum by (deployment)(kube_deployment_status_replicas)')
      expect(a.presence).to eq(:continuous)
      expect(a.expr).not_to include('vector(0)')
    end

    it 'wakes are a floored event-driven rate overlay' do
      p = built.panels.first
      b = p.queries.find { |q| q.ref == 'B' }
      expect(b.expr).to include('rate(keda_scaledobject_activations_total[5m])').and include('or vector(0)')
      expect(b.presence).to eq(:event_driven)
      expect(b.legend_format).to eq('wakes/s {{deployment}}')
    end

    it 'sets step interpolation via the typed grafana fieldConfig escape hatch (degraded gap)' do
      p = built.panels.first
      interp = p.options.dig(:grafana, :fieldConfig, :defaults, :custom, :lineInterpolation)
      expect(interp).to eq('stepAfter')
    end
  end

  describe 'replicas only' do
    it 'omits the wake overlay when no wake_counter is given' do
      built = row_with { |r| Lib::WakeEventTimeline.add(r, datasource: 'vm', replica_metric: 'replicas') }
      expect(built.panels.first.queries.map(&:ref)).to eq(%w[A])
    end
  end

  it 'requires datasource + replica_metric' do
    expect { row_with { |r| Lib::WakeEventTimeline.add(r, datasource: nil, replica_metric: 'r') } }
      .to raise_error(ArgumentError, /datasource/)
    expect { row_with { |r| Lib::WakeEventTimeline.add(r, datasource: 'vm', replica_metric: '') } }
      .to raise_error(ArgumentError, /replica_metric/)
  end
end
