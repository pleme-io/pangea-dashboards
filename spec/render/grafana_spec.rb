# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Dashboards::Render::Grafana do
  let(:dashboard) { canonical_dashboard }
  let(:rendered)  { described_class.render(dashboard) }

  it 'returns a Hash with the expected top-level keys' do
    expect(rendered).to include(
      'title'         => 'canary',
      'uid'           => 'canary',
      'schemaVersion' => 39,
      'editable'      => true
    )
    expect(rendered['tags']).to eq(%w[rio test])
  end

  it 'emits panels in the order they were declared' do
    panels = rendered['panels']
    titles = panels.map { |p| p['title'] }
    # Each row contributes a row-panel header + N data panels in order:
    expect(titles).to eq(['overview', 'Pods', 'Restarts (1h)', 'storage', 'PVC used'])
  end

  it 'maps panel kinds to Grafana panel types' do
    typed = rendered['panels'].each_with_object({}) { |p, o| o[p['title']] = p['type'] }
    expect(typed).to include(
      'overview'      => 'row',
      'Pods'          => 'stat',
      'Restarts (1h)' => 'timeseries',
      'storage'       => 'row',
      'PVC used'      => 'gauge'
    )
  end

  it 'emits queries with refId + expr + datasource' do
    pods = rendered['panels'].find { |p| p['title'] == 'Pods' }
    expect(pods['targets']).to eq([
      {
        'refId'      => 'A',
        'expr'       => 'count(kube_pod_info{namespace=~"$namespace"})',
        'datasource' => { 'type' => 'prometheus', 'uid' => 'vm' }
      }
    ])
  end

  it 'emits thresholds in fieldConfig.defaults.thresholds.steps' do
    pods = rendered['panels'].find { |p| p['title'] == 'Pods' }
    steps = pods['fieldConfig']['defaults']['thresholds']['steps']
    expect(steps).to eq([
      { 'color' => 'green',  'value' => nil },
      { 'color' => 'yellow', 'value' => 20.0 },
      { 'color' => 'red',    'value' => 50.0 }
    ])
  end

  it 'renders the variable list under templating' do
    vars = rendered['templating']['list']
    expect(vars.size).to eq(1)
    expect(vars.first).to include(
      'name'  => 'namespace',
      'type'  => 'query',
      'query' => 'label_values(kube_pod_info, namespace)',
      'multi' => true,
      'includeAll' => true
    )
  end

  it 'serializes to compact JSON via render_json' do
    json = described_class.render_json(dashboard)
    expect(json).to be_a(String)
    expect(json).to include('"uid":"canary"')
  end

  it 'raises UnsupportedBackendError for an exotic kind' do
    panel = Pangea::Dashboards::Types::Panel.new(
      id: :p, kind: :stat, title: 't', queries: []
    )
    expect(described_class.grafana_type(panel.kind)).to eq('stat')

    # Force an unknown kind through reflection to test the guard:
    expect {
      described_class.grafana_type(:sankey)
    }.to raise_error(Pangea::Dashboards::UnsupportedBackendError)
  end
end
