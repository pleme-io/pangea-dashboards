# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/allocatable_vs_requested_panel'

# AllocatableVsRequestedPanel — the capacity-headroom :timeseries.
# Builds a RowBuilder, runs the component, asserts on the emitted PromQL +
# panel shape (kind/width/presence/unit) and the validation rejection.
RSpec.describe Pangea::Dashboards::Library::AllocatableVsRequestedPanel do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  it 'emits a two-series cpu allocatable-vs-requested timeseries by default' do
    built = row_with { |r| Lib::AllocatableVsRequestedPanel.add(r, datasource: 'vm') }
    p = built.panels.first
    expect(p.kind).to eq(:timeseries)
    expect(p.id).to eq(:alloc_vs_req_cpu)
    expect(p.width).to eq(Theme.half)
    expect(p.height).to eq(Theme::TS_H)
    expect(p.unit).to eq('short')                 # cpu → short
    expect(p.min).to eq(0)
    expect(p.title).to eq('cpu allocatable vs requested')

    expect(p.queries.map(&:ref)).to eq(%w[A B])
    expect(p.queries.map(&:presence)).to all(eq(:continuous))
    expect(p.queries[0].expr).to eq('sum(kube_node_status_allocatable{resource="cpu"})')
    expect(p.queries[1].expr).to eq('sum(kube_pod_container_resource_requests{resource="cpu"})')
    expect(p.queries.map(&:legend_format)).to eq(%w[allocatable requested])
  end

  it 'switches the resource matcher + default unit to bytes for :memory' do
    built = row_with { |r| Lib::AllocatableVsRequestedPanel.add(r, datasource: 'vm', resource: :memory) }
    p = built.panels.first
    expect(p.id).to eq(:alloc_vs_req_memory)
    expect(p.unit).to eq('bytes')                 # memory → bytes
    expect(p.queries[0].expr).to eq('sum(kube_node_status_allocatable{resource="memory"})')
    expect(p.queries[1].expr).to eq('sum(kube_pod_container_resource_requests{resource="memory"})')
  end

  it 'honours unit + title overrides' do
    built = row_with do |r|
      Lib::AllocatableVsRequestedPanel.add(r, datasource: 'vm', resource: :cpu,
                                           unit: 'percentunit', title: 'Cluster CPU headroom')
    end
    p = built.panels.first
    expect(p.unit).to eq('percentunit')
    expect(p.title).to eq('Cluster CPU headroom')
  end

  it 'requires a datasource' do
    expect { row_with { |r| Lib::AllocatableVsRequestedPanel.add(r, datasource: nil) } }
      .to raise_error(ArgumentError, /datasource/)
    expect { row_with { |r| Lib::AllocatableVsRequestedPanel.add(r, datasource: '') } }
      .to raise_error(ArgumentError, /datasource/)
  end

  it 'rejects an unsupported resource' do
    expect { row_with { |r| Lib::AllocatableVsRequestedPanel.add(r, datasource: 'vm', resource: :gpu) } }
      .to raise_error(ArgumentError, /resource must be :cpu or :memory/)
  end
end
