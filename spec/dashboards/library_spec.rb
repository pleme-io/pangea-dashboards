# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Dashboards::Library::KubernetesPodPanels do
  it 'splats the canonical pod panel set into a row builder' do
    builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :test)
    described_module = described_class
    builder.instance_eval do
      row 'pods' do
        described_module.add_all(self,
          namespace: 'rio-app',
          deployment: 'immich',
          datasource: 'vm'
        )
      end
    end
    dash = builder.build
    titles = dash.rows.first.panels.map(&:title)
    expect(titles).to eq(['Pods', 'Pod CPU', 'Pod memory', 'Restarts (1h)'])
    expect(dash.rows.first.panels.first.queries.first.expr)
      .to include('namespace="rio-app"')
  end

  it 'every panel ships with a dd_query: for cross-renderer use' do
    builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :test)
    described_module = described_class
    builder.instance_eval do
      row 'pods' do
        described_module.add_count(self, namespace: 'n', datasource: 'vm')
      end
    end
    dash = builder.build
    expect(dash.rows.first.panels.first.queries.first.dd_query).to be_a(String)
  end
end

RSpec.describe Pangea::Dashboards::Library::Derive do
  it 'auto-generates panels from a metric list' do
    builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :test)
    described_module = described_class
    builder.instance_eval do
      row 'falco' do
        described_module.derive_panels(
          row: self,
          metrics: %w[falco_events_total falco_drops_total],
          kind: :stat
        ) do |metric|
          query 'A', "rate(#{metric}[5m])", datasource: 'vm',
                dd_query: "sum:#{metric}.as_rate()"
        end
      end
    end
    dash = builder.build
    panels = dash.rows.first.panels
    expect(panels.size).to eq(2)
    expect(panels.map(&:title)).to eq(['Falco Events Total', 'Falco Drops Total'])
  end

  it 'documents the prefix-based variant as a NotImplementedError' do
    expect {
      described_class.derive_panels_from_prefix(
        row: nil, prefix: 'falco_', prometheus_url: 'http://vm:8429'
      )
    }.to raise_error(NotImplementedError, /not yet built/)
  end
end
