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

RSpec.describe Pangea::Dashboards::Library::LogWindows do
  def build_with(**kwargs)
    builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :test)
    mod = described_class
    builder.instance_eval do
      row 'Logs' do
        mod.add_all(self, **kwargs)
      end
    end
    builder.build
  end

  let(:base) do
    { name: 'pangea-operator',
      stream: '{namespace="pangea-system",app="pangea-operator"}',
      datasource: 'vlogs' }
  end

  it 'emits full-logs, a dedicated error window, and an error-rate panel in order' do
    panels = build_with(**base).rows.first.panels
    expect(panels.map(&:id)).to eq(
      %i[pangea_operator_logs pangea_operator_error_logs pangea_operator_error_rate]
    )
  end

  it 'the error window filters to error-class levels (not a substring match)' do
    panels = build_with(**base).rows.first.panels
    err = panels.find { |p| p.id == :pangea_operator_error_logs }
    expect(err.queries.first.expr).to eq(
      '{namespace="pangea-system",app="pangea-operator"} ' \
      'level:error OR level:fatal OR level:critical OR level:panic'
    )
  end

  it 'marks the error window + rate as event_driven so an empty window is not flagged broken' do
    panels = build_with(**base).rows.first.panels
    err  = panels.find { |p| p.id == :pangea_operator_error_logs }
    rate = panels.find { |p| p.id == :pangea_operator_error_rate }
    expect(err.queries.first.presence).to eq(:event_driven)
    expect(rate.queries.first.presence).to eq(:event_driven)
  end

  it 'the error window title is unmistakably about errors (for fast parsing)' do
    panels = build_with(**base).rows.first.panels
    err = panels.find { |p| p.id == :pangea_operator_error_logs }
    expect(err.title).to match(/ERROR/)
  end

  it 'can omit the full-logs table (error window only)' do
    panels = build_with(**base.merge(full_logs: false)).rows.first.panels
    expect(panels.map(&:id)).to eq(%i[pangea_operator_error_logs pangea_operator_error_rate])
  end

  it 'honors a custom error filter' do
    panels = build_with(**base.merge(error_filter: 'severity:high')).rows.first.panels
    err = panels.find { |p| p.id == :pangea_operator_error_logs }
    expect(err.queries.first.expr).to end_with('severity:high')
  end

  it 'rejects a non-LogsQL stream (no selector braces) at synth time' do
    expect { build_with(**base.merge(stream: 'app=operator')) }
      .to raise_error(ArgumentError, /stream selector/)
  end

  it 'rejects a blank datasource' do
    expect { build_with(**base.merge(datasource: '')) }
      .to raise_error(ArgumentError, /datasource/)
  end
end

RSpec.describe Pangea::Dashboards::Library::DataPresence do
  def build_with(**kwargs)
    builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :test)
    mod = described_class
    builder.instance_eval do
      row 'Data presence' do
        mod.add_all(self, **kwargs)
      end
    end
    builder.build
  end

  let(:base) { { jobs: %w[pangea-operator kubelet node-exporter], datasource: 'vm' } }

  it 'emits an up table, a targets-down stat, and an expected-jobs-present stat' do
    panels = build_with(**base).rows.first.panels
    expect(panels.map(&:id)).to eq(%i[scrape_up scrape_targets_down scrape_jobs_present])
  end

  it 'builds a job regex selector over the expected jobs' do
    panels = build_with(**base).rows.first.panels
    up = panels.find { |p| p.id == :scrape_up }
    expect(up.queries.first.expr).to eq('up{job=~"pangea-operator|kubelet|node-exporter"}')
  end

  it 'targets-down uses or vector(0) so it reads 0 (not no-data) when all up' do
    panels = build_with(**base).rows.first.panels
    down = panels.find { |p| p.id == :scrape_targets_down }
    expect(down.queries.first.expr).to include('or vector(0)')
  end

  it 'expected-jobs-present greens only when all expected jobs report up' do
    panels = build_with(**base).rows.first.panels
    present = panels.find { |p| p.id == :scrape_jobs_present }
    expect(present.title).to include('of 3')
    green = present.thresholds.steps.find { |s| s.color == 'green' }
    expect(green.value).to eq(3.0)
  end

  it 'rejects an empty jobs list' do
    expect { build_with(**base.merge(jobs: [])) }
      .to raise_error(ArgumentError, /non-empty Array/)
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
