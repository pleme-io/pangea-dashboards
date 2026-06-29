# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/health_matrix_table'

# HealthMatrixTable — the category-defining N-column per-entity :table. Asserts
# one instant query per column joined on the topology label + the typed
# options(grafana:) fieldConfig override carrying per-column units + thresholds.
RSpec.describe Pangea::Dashboards::Library::HealthMatrixTable do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  let(:built) do
    row_with do |r|
      Lib::HealthMatrixTable.add(r, datasource: 'vm', topology_label: 'tenant',
        columns: [
          { name: 'Rate',    expr: 'sum by(tenant)(rate(req_total[5m]))', unit: 'reqps' },
          { name: 'Error %', expr: '100 * sum by(tenant)(rate(req_total{code=~"5.."}[5m]))', unit: 'percent', warn: 1, crit: 5 },
        ])
    end
  end

  it 'emits ONE full-width instant :table' do
    expect(built.panels.size).to eq(1)
    p = built.panels.first
    expect(p.kind).to eq(:table)
    expect(p.width).to eq(Theme.full)
    expect(p.queries.map(&:instant)).to all(be(true))
  end

  it 'emits one query per column, refs A,B, each by(tenant)' do
    p = built.panels.first
    expect(p.queries.map(&:ref)).to eq(%w[A B])
    expect(p.queries.map(&:expr)).to eq([
      'sum by(tenant)(rate(req_total[5m]))',
      '100 * sum by(tenant)(rate(req_total{code=~"5.."}[5m]))'
    ])
    expect(p.queries.map(&:legend_format)).to eq(['Rate', 'Error %'])
  end

  it 'merges rows + carries a per-column fieldConfig override with units' do
    p = built.panels.first
    g = p.options[:grafana]
    expect(g['transformations']).to include('id' => 'merge', 'options' => {})
    overrides = g['fieldConfig']['overrides']
    expect(overrides.size).to eq(2)
    rate_o = overrides.first
    expect(rate_o['matcher']).to eq('id' => 'byName', 'options' => 'Value #A')
    props = rate_o['properties']
    expect(props).to include('id' => 'unit', 'value' => 'reqps')
  end

  it 'cell-colours a column with warn/crit defect thresholds' do
    p = built.panels.first
    err_o = p.options[:grafana]['fieldConfig']['overrides'][1]
    thr = err_o['properties'].find { |pr| pr['id'] == 'thresholds' }
    expect(thr['value']['steps'].map { |s| s['value'] }).to eq([nil, 1.0, 5.0])
    expect(err_o['properties']).to include('id' => 'custom.cellOptions', 'value' => { 'type' => 'color-background' })
  end

  it 'requires datasource, topology_label, and non-empty columns with name+expr' do
    expect { row_with { |r| Lib::HealthMatrixTable.add(r, datasource: '', topology_label: 't', columns: [{ name: 'X', expr: 'a' }]) } }
      .to raise_error(ArgumentError, /datasource/)
    expect { row_with { |r| Lib::HealthMatrixTable.add(r, datasource: 'vm', topology_label: 't', columns: []) } }
      .to raise_error(ArgumentError, /columns/)
    expect { row_with { |r| Lib::HealthMatrixTable.add(r, datasource: 'vm', topology_label: 't', columns: [{ name: 'X' }]) } }
      .to raise_error(ArgumentError, /needs :expr/)
  end
end
