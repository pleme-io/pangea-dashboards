# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Dashboards::Render::Datadog do
  let(:dashboard) { canonical_dashboard }
  let(:rendered)  { described_class.render(dashboard) }

  it 'returns a Hash with the expected top-level keys' do
    expect(rendered).to include(
      title:         'canary',
      layout_type:   'ordered',
      reflow_type:   'auto',
      is_read_only:  false
    )
    expect(rendered[:tags]).to eq(%w[rio test])
  end

  it 'wraps each row in a group widget with nested data widgets' do
    overview = rendered[:widget].first[:definition]
    expect(overview[:type]).to eq('group')
    expect(overview[:title]).to eq('overview')
    expect(overview[:widget].size).to eq(2)   # pod_count + restarts_1h
  end

  it 'maps stat → query_value' do
    overview = rendered[:widget].first[:definition]
    pods = overview[:widget].first[:definition]
    expect(pods[:type]).to eq('query_value')
    expect(pods[:title]).to eq('Pods')
  end

  it 'maps timeseries → timeseries' do
    overview = rendered[:widget].first[:definition]
    restarts = overview[:widget].last[:definition]
    expect(restarts[:type]).to eq('timeseries')
  end

  it 'maps gauge → query_value with conditional_formats from thresholds' do
    storage = rendered[:widget].last[:definition]
    pvc = storage[:widget].first[:definition]
    expect(pvc[:type]).to eq('query_value')
    formats = pvc[:requests].first[:conditional_formats]
    expect(formats).to include(
      hash_including(value: 75.0, palette: 'yellow_on_white'),
      hash_including(value: 90.0, palette: 'red_on_white')
    )
  end

  it 'uses dd_query: when provided' do
    overview = rendered[:widget].first[:definition]
    restarts_req = overview[:widget].last[:definition][:requests].first
    expect(restarts_req[:q]).to eq('avg:kubernetes.containers.restarts{*}.as_rate()')
  end

  it 'raises UntranslatableQueryError when PromQL has no dd_query: override' do
    builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :bad)
    builder.instance_eval do
      row 'r' do
        panel :p, kind: :stat do
          # rate(...) is PromQL-only; no dd_query override → raise
          query 'A', 'rate(kube_pod_container_status_restarts_total[5m])', datasource: 'vm'
        end
      end
    end
    bad = builder.build
    expect {
      described_class.render(bad)
    }.to raise_error(Pangea::Dashboards::UntranslatableQueryError, /PromQL-only syntax/)
  end

  it 'pass-through expr that has no PromQL-only tokens' do
    builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :ok)
    builder.instance_eval do
      row 'r' do
        panel :p, kind: :stat do
          query 'A', 'kubernetes.containers.restarts', datasource: 'vm'
        end
      end
    end
    ok = builder.build
    expect {
      out = described_class.render(ok)
      expect(out[:widget].first[:definition][:widget].first[:definition][:requests].first[:q]).to eq('kubernetes.containers.restarts')
    }.not_to raise_error
  end
end
