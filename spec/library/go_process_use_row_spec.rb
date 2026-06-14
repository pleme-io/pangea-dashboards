# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/go_process_use_row'

# GoProcessUseRow — the USE-style Go-runtime composite row. Builds a
# RowBuilder, runs .add, asserts on the emitted PromQL + panel shape
# (kind/width/presence/threshold) for each requested signal.
RSpec.describe Pangea::Dashboards::Library::GoProcessUseRow do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'the default row over all five signals' do
    let(:built) do
      row_with do |r|
        Lib::GoProcessUseRow.add(r, datasource: 'vm', process_selector: { job: 'gateway' })
      end
    end

    it 'emits one panel per default signal, in show order' do
      expect(built.panels.map(&:id)).to eq(%i[go_cpu go_goroutines go_heap go_gc go_uptime])
    end

    it 'rates process_cpu_seconds_total and floors it (event_driven CPU)' do
      cpu = built.panels.find { |p| p.id == :go_cpu }
      expect(cpu.kind).to eq(:timeseries)
      expect(cpu.queries.first.expr).to eq('sum(rate(process_cpu_seconds_total{job="gateway"}[5m])) or vector(0)')
      expect(cpu.queries.first.presence).to eq(:event_driven)
    end

    it 'plots go_goroutines as a continuous saturation gauge' do
      gr = built.panels.find { |p| p.id == :go_goroutines }
      expect(gr.queries.first.expr).to eq('sum(go_goroutines{job="gateway"})')
      expect(gr.queries.first.presence).to eq(:continuous)
    end

    it 'plots heap inuse + rss + virtual as a three-series bytes panel' do
      heap = built.panels.find { |p| p.id == :go_heap }
      expect(heap.unit).to eq('bytes')
      exprs = heap.queries.map(&:expr)
      expect(exprs).to eq([
        'sum(go_memstats_heap_inuse_bytes{job="gateway"})',
        'sum(process_resident_memory_bytes{job="gateway"})',
        'sum(process_virtual_memory_bytes{job="gateway"})'
      ])
      expect(heap.queries.map(&:legend_format)).to eq(['heap inuse', 'rss', 'virtual'])
    end

    it 'rates go_gc_duration_seconds_sum and floors it (event_driven GC)' do
      gc = built.panels.find { |p| p.id == :go_gc }
      expect(gc.unit).to eq('s')
      expect(gc.queries.first.expr).to eq('sum(rate(go_gc_duration_seconds_sum{job="gateway"}[5m])) or vector(0)')
      expect(gc.queries.first.presence).to eq(:event_driven)
    end

    it 'renders uptime as a liveness stat (lower = worse)' do
      up = built.panels.find { |p| p.id == :go_uptime }
      expect(up.kind).to eq(:stat)
      expect(up.width).to eq(Theme.third)
      expect(up.queries.first.expr).to eq('time() - max(process_start_time_seconds{job="gateway"})')
      expect(up.queries.first.presence).to eq(:continuous)
      expect(up.thresholds.steps.map(&:color)).to eq(%w[red green])
    end

    it 'gives every timeseries signal an equal, half-or-third width' do
      ts = built.panels.reject { |p| p.id == :go_uptime }
      expect(ts.map(&:width).uniq.length).to eq(1)
      expect(ts.first.width).to be_between(Theme.third, Theme.half)
    end
  end

  describe 'a typed Regexp selector + a narrowed show list' do
    let(:built) do
      row_with do |r|
        Lib::GoProcessUseRow.add(r, datasource: 'vm', title: 'sidecar',
          process_selector: { namespace: 'dapr', pod: /gateway-.*/ },
          show: %i[goroutines heap])
      end
    end

    it 'emits only the requested signals, in order' do
      expect(built.panels.map(&:id)).to eq(%i[go_goroutines go_heap])
    end

    it 'renders the Regexp pod matcher as a =~ selector' do
      gr = built.panels.find { |p| p.id == :go_goroutines }
      expect(gr.queries.first.expr).to eq('sum(go_goroutines{namespace="dapr",pod=~"gateway-.*"})')
    end

    it 'prefixes every panel title with the process name' do
      expect(built.panels.map(&:title)).to all(start_with('sidecar · '))
    end
  end

  describe 'validation' do
    it 'requires a non-empty process_selector' do
      expect { row_with { |r| Lib::GoProcessUseRow.add(r, datasource: 'vm', process_selector: {}) } }
        .to raise_error(ArgumentError, /process_selector/)
    end

    it 'requires a datasource' do
      expect { row_with { |r| Lib::GoProcessUseRow.add(r, datasource: nil, process_selector: { job: 'x' }) } }
        .to raise_error(ArgumentError, /datasource/)
    end

    it 'rejects an unknown show signal' do
      expect {
        row_with { |r| Lib::GoProcessUseRow.add(r, datasource: 'vm', process_selector: { job: 'x' }, show: %i[cpu threads]) }
      }.to raise_error(ArgumentError, /unknown show signal/)
    end
  end
end
