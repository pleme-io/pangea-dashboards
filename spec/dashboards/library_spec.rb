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

  describe '.derive_panels_from_prefix' do
    let(:fake_http) do
      ->(url) {
        @last_url = url
        {
          'status' => 'success',
          'data' => %w[falco_events_total falco_drops_total node_cpu_seconds_total kube_pod_info]
        }
      }
    end

    before { described_class.clear_cache! }

    it 'discovers matching metrics + emits one panel per match' do
      builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :test)
      described_module = described_class
      h = fake_http
      builder.instance_eval do
        row 'falco' do
          described_module.derive_panels_from_prefix(
            row: self,
            prefix: 'falco_',
            prometheus_url: 'http://vm:8429',
            http_client: h,
            kind: :stat
          ) do |metric|
            query 'A', "rate(#{metric}[5m])", datasource: 'vm'
          end
        end
      end
      dash = builder.build
      panels = dash.rows.first.panels
      expect(panels.map(&:id)).to eq(%i[falco_events_total falco_drops_total])
    end

    it 'caches the introspection result by URL' do
      call_count = 0
      counting_http = ->(url) {
        call_count += 1
        { 'status' => 'success', 'data' => ['x_total', 'y_total'] }
      }

      2.times do
        builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :test)
        described_module = described_class
        builder.instance_eval do
          row 'r' do
            described_module.derive_panels_from_prefix(
              row: self, prefix: 'x_',
              prometheus_url: 'http://same-url',
              http_client: counting_http
            ) { |m| query 'A', "rate(#{m}[5m])", datasource: 'vm' }
          end
        end
      end
      expect(call_count).to eq(1)
    end

    it 'raises IntrospectionError when no metrics match the prefix' do
      builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :test)
      described_module = described_class
      h = fake_http
      expect {
        builder.instance_eval do
          row 'r' do
            described_module.derive_panels_from_prefix(
              row: self, prefix: 'nonexistent_',
              prometheus_url: 'http://vm:8429',
              http_client: h
            ) { |m| query 'A', m, datasource: 'vm' }
          end
        end
      }.to raise_error(Pangea::Dashboards::Library::Derive::IntrospectionError,
                       /no metrics matching prefix/)
    end

    it 'raises when Prometheus returns a non-success status' do
      bad_http = ->(_url) { { 'status' => 'error', 'error' => 'invalid query' } }
      builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :test)
      described_module = described_class
      expect {
        builder.instance_eval do
          row 'r' do
            described_module.derive_panels_from_prefix(
              row: self, prefix: 'x_',
              prometheus_url: 'http://broken',
              http_client: bad_http
            ) { |m| query 'A', m, datasource: 'vm' }
          end
        end
      }.to raise_error(Pangea::Dashboards::Library::Derive::IntrospectionError,
                       /status=error/)
    end
  end
end
