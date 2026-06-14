# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/per_namespace_breakdown_row'

# PerNamespaceBreakdownRow — CPU/memory/restarts/pod-count by namespace with the
# dual-scrape cadvisor dedupe baked in. Builds a RowBuilder, runs .add, asserts
# on the emitted PromQL text + panel kind/width/presence + the metrics_path pin.
RSpec.describe Pangea::Dashboards::Library::PerNamespaceBreakdownRow do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe '.add — happy path (all four metrics)' do
    let(:built) { row_with { |r| Lib::PerNamespaceBreakdownRow.add(r, datasource: 'vm') } }

    it 'emits one :timeseries per requested metric, in order' do
      expect(built.panels.size).to eq(4)
      expect(built.panels.map(&:kind)).to all(eq(:timeseries))
      expect(built.panels.map(&:id)).to eq(
        %i[by_namespace_cpu by_namespace_memory by_namespace_restarts by_namespace_count]
      )
    end

    it 'sizes the panels through Theme (4 tiles → 6 clamped up to third)' do
      # tile_width(4) = 6, clamped to >= Theme.third (8)
      expect(built.panels.map(&:width)).to all(eq(Theme.third))
      expect(built.panels.map(&:height)).to all(eq(Theme::TS_H))
    end

    it 'groups every series by namespace with a {{namespace}} legend' do
      expect(built.panels.map { |p| p.queries.first.legend_format }).to all(eq('{{namespace}}'))
    end
  end

  describe '.add — the cadvisor dual-scrape dedupe (the load-bearing detail)' do
    let(:built) { row_with { |r| Lib::PerNamespaceBreakdownRow.add(r, datasource: 'vm') } }

    it 'pins metrics_path="/metrics/cadvisor" on container_* (cadvisor) series' do
      cpu = built.panels.find { |p| p.id == :by_namespace_cpu }
      mem = built.panels.find { |p| p.id == :by_namespace_memory }
      expect(cpu.queries.first.expr).to eq(
        'sum by (namespace)(rate(container_cpu_usage_seconds_total{metrics_path="/metrics/cadvisor"}[5m])) or vector(0)'
      )
      expect(mem.queries.first.expr).to eq(
        'sum by (namespace)(container_memory_working_set_bytes{metrics_path="/metrics/cadvisor"})'
      )
    end

    it 'NEVER pins kube-state-metrics (single-scrape) series' do
      restarts = built.panels.find { |p| p.id == :by_namespace_restarts }
      count    = built.panels.find { |p| p.id == :by_namespace_count }
      expect(restarts.queries.first.expr).to eq(
        'sum by (namespace)(rate(kube_pod_container_status_restarts_total[5m])) or vector(0)'
      )
      expect(restarts.queries.first.expr).not_to include('metrics_path')
      expect(count.queries.first.expr).to eq('count by (namespace)(kube_pod_info)')
      expect(count.queries.first.expr).not_to include('metrics_path')
    end

    it 'floors the rate (event-driven) series and marks them :event_driven' do
      cpu      = built.panels.find { |p| p.id == :by_namespace_cpu }
      restarts = built.panels.find { |p| p.id == :by_namespace_restarts }
      mem      = built.panels.find { |p| p.id == :by_namespace_memory }
      expect(cpu.queries.first.expr).to end_with('or vector(0)')
      expect(cpu.queries.first.presence).to eq(:event_driven)
      expect(restarts.queries.first.presence).to eq(:event_driven)
      # gauges are continuous + never floored
      expect(mem.queries.first.presence).to eq(:continuous)
      expect(mem.queries.first.expr).not_to include('vector(0)')
    end

    it 'omits the pin entirely when dedupe: nil (single-scrape cluster)' do
      built = row_with { |r| Lib::PerNamespaceBreakdownRow.add(r, datasource: 'vm', dedupe: nil, metrics: %i[cpu]) }
      expect(built.panels.first.queries.first.expr).to eq(
        'sum by (namespace)(rate(container_cpu_usage_seconds_total[5m])) or vector(0)'
      )
    end
  end

  describe '.add — typed-selector + per-tenant generalisation' do
    it 'merges a typed Hash selector with the cadvisor pin and groups by the chosen label' do
      built = row_with do |r|
        Lib::PerNamespaceBreakdownRow.add(r, datasource: 'vm', namespace_label: 'tenant',
          metrics: %i[cpu memory], selector: { cluster: 'rio' }, title: 'By tenant')
      end
      cpu = built.panels.find { |p| p.id == :by_tenant_cpu }
      expect(cpu).not_to be_nil
      expect(cpu.title).to eq('By tenant · CPU (cores)')
      expect(cpu.queries.first.expr).to eq(
        'sum by (tenant)(rate(container_cpu_usage_seconds_total{cluster="rio",metrics_path="/metrics/cadvisor"}[5m])) or vector(0)'
      )
      expect(cpu.queries.first.legend_format).to eq('{{tenant}}')
      # two tiles → half-width
      expect(built.panels.map(&:width)).to all(eq(Theme.half))
    end

    it 'applies the selector to non-cadvisor series WITHOUT the pin' do
      built = row_with do |r|
        Lib::PerNamespaceBreakdownRow.add(r, datasource: 'vm',
          metrics: %i[count], selector: { cluster: 'rio' })
      end
      expect(built.panels.first.queries.first.expr).to eq('count by (namespace)(kube_pod_info{cluster="rio"})')
    end
  end

  describe '.add — validation' do
    it 'requires a datasource' do
      expect { row_with { |r| Lib::PerNamespaceBreakdownRow.add(r, datasource: nil) } }
        .to raise_error(ArgumentError, /PerNamespaceBreakdownRow.*datasource/)
    end

    it 'rejects an unknown metric key' do
      expect { row_with { |r| Lib::PerNamespaceBreakdownRow.add(r, datasource: 'vm', metrics: %i[cpu disk]) } }
        .to raise_error(ArgumentError, /unknown metrics/)
    end

    it 'rejects an empty metrics list' do
      expect { row_with { |r| Lib::PerNamespaceBreakdownRow.add(r, datasource: 'vm', metrics: []) } }
        .to raise_error(ArgumentError, /metrics must be a non-empty Array/)
    end

    it 'rejects an invalid dedupe mode' do
      expect { row_with { |r| Lib::PerNamespaceBreakdownRow.add(r, datasource: 'vm', dedupe: :both) } }
        .to raise_error(ArgumentError, /dedupe must be :cadvisor or nil/)
    end
  end
end
