# frozen_string_literal: true

require 'spec_helper'

# Wave 1 — the canonical composite rows + the WorkloadOverview keystone.
RSpec.describe 'Pangea::Dashboards::Library Wave 1 composites' do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe Pangea::Dashboards::Library::GoldenSignalsRow do
    let(:built) do
      row_with do |r|
        Lib::GoldenSignalsRow.add(r, datasource: 'vm',
          rate_metric: 'http_requests_total',
          latency_metric: 'http_request_duration_seconds_bucket',
          group_by: %w[route], error_selector: { code: '5..' })
      end
    end

    it 'emits Rate + Errors + Latency, all third-width on one row' do
      expect(built.panels.size).to be >= 3
      expect(built.panels.map(&:width).first(3)).to all(eq(Theme.third))
      titles = built.panels.map(&:title)
      expect(titles).to include('Rate', 'Errors', match(/latency/i))
    end

    it 'floors the rate leg with or vector(0)' do
      rate = built.panels.find { |p| p.title == 'Rate' }
      expect(rate.queries.first.expr).to eq('sum by (route)(rate(http_requests_total[5m])) or vector(0)')
    end

    it 'renders the error selector as a regex matcher (5.. → =~)' do
      errors = built.panels.find { |p| p.title == 'Errors' }
      expect(errors.queries.first.expr).to include('http_requests_total{code=~"5.."}')
    end

    it 'plots the error ratio % as a second query by default' do
      errors = built.panels.find { |p| p.title == 'Errors' }
      expect(errors.queries.size).to eq(2)
      expect(errors.queries[1].expr).to include('100 *')
      expect(errors.queries[1].legend_format).to eq('error %')
    end

    it 'emits p95 + p99 latency quantiles' do
      lat = built.panels.find { |p| p.title =~ /latency/i }
      expect(lat.queries.map(&:legend_format)).to eq(['p95 {{route}}', 'p99 {{route}}'])
    end
  end

  describe Pangea::Dashboards::Library::SaturationRow do
    it 'emits util + saturation (half-width) with util thresholds' do
      built = row_with do |r|
        Lib::SaturationRow.add(r, datasource: 'vm', title: 'CPU',
          util_expr: '100*(1-avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))',
          saturation_expr: 'avg(node_load1)')
      end
      expect(built.panels.size).to eq(2)
      expect(built.panels.map(&:width)).to all(eq(Theme.half))
      util = built.panels.first
      expect(util.max).to eq(100)
      expect(util.thresholds.steps.map(&:color)).to eq(%w[green orange red])
    end

    it 'adds a third floored errors panel when errors_expr given (all third-width)' do
      built = row_with do |r|
        Lib::SaturationRow.add(r, datasource: 'vm', title: 'Disk',
          util_expr: 'disk_util', saturation_expr: 'disk_queue', errors_expr: 'rate(disk_errors_total[5m])')
      end
      expect(built.panels.size).to eq(3)
      expect(built.panels.map(&:width)).to all(eq(Theme.third))
      expect(built.panels.last.queries.first.expr).to eq('rate(disk_errors_total[5m]) or vector(0)')
    end
  end

  describe Pangea::Dashboards::Library::ControllerRuntimeRow do
    let(:built) do
      row_with do |r|
        Lib::ControllerRuntimeRow.add(r, datasource: 'vm', service_selector: { job: 'cert-manager-issuer' })
      end
    end

    it 'composes reconcile latency + rate + errors over controller_runtime_* metrics' do
      titles = built.panels.map(&:title)
      expect(titles).to include(match(/reconcile latency/), match(/reconcile rate/), match(/reconcile errors/))
      lat = built.panels.find { |p| p.title =~ /reconcile latency/ }
      expect(lat.queries.last.expr).to include('controller_runtime_reconcile_time_seconds_bucket{job="cert-manager-issuer"}')
    end

    it 'adds workqueue depth + active workers stats and a rest_client row' do
      ids = built.panels.map(&:id)
      expect(ids).to include(:cr_workqueue_depth, :cr_active_workers, :cr_rest_client)
      rc = built.panels.find { |p| p.id == :cr_rest_client }
      expect(rc.queries.first.expr).to include('rest_client_requests_total{job="cert-manager-issuer"}')
      expect(rc.queries.first.legend_format).to eq('{{method}} {{code}}')
    end

    it 'requires a non-empty service_selector' do
      expect { row_with { |r| Lib::ControllerRuntimeRow.add(r, datasource: 'vm', service_selector: {}) } }
        .to raise_error(ArgumentError, /service_selector/)
    end
  end

  describe Pangea::Dashboards::Library::WorkloadOverview do
    let(:dash) do
      Lib::WorkloadOverview.build(
        id: :payments, name: 'payments', datasource: 'vm', logs_datasource: 'vlogs',
        jobs: %w[payments], namespace: 'payments', stream: '{namespace="payments"}',
        rate_metric: 'http_requests_total',
        latency_metric: 'http_request_duration_seconds_bucket',
        group_by: %w[route], error_selector: { code: '5..' },
        signals: [
          { name: 'Pods not ready', expr: 'count(kube_pod_status_ready{namespace="payments",condition="false"})', warn: 1, crit: 1 },
          { name: '5xx /s', expr: 'sum(rate(http_requests_total{namespace="payments",code=~"5.."}[5m]))', warn: 0.1 }
        ]
      )
    end

    it 'collapses the whole triage story into one Types::Dashboard' do
      expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
      titles = dash.rows.map(&:title)
      expect(titles).to eq([
        'Data presence — is it reporting?',
        'Status — what needs attention?',
        'Golden signals — rate · errors · latency',
        'Resources — pods',
        'Logs'
      ])
    end

    it 'renders the status row from the supplied defect signals' do
      status = dash.rows.find { |r| r.title =~ /needs attention/ }
      expect(status.panels.map(&:title)).to include('Pods not ready', '5xx /s')
      expect(status.panels).to all(have_attributes(kind: :stat, display_mode: :background))
    end

    it 'omits golden signals when no rate/latency metric is given' do
      d = Lib::WorkloadOverview.build(id: :infra, name: 'infra', datasource: 'vm',
        jobs: %w[infra], signals: [{ name: 'x', expr: 'up', warn: 1 }])
      expect(d.rows.map(&:title)).to eq(['Data presence — is it reporting?', 'Status — what needs attention?'])
    end

    it 'makes a half-specified RED row unrepresentable (rate without latency)' do
      expect {
        Lib::WorkloadOverview.build(id: :bad, name: 'bad', datasource: 'vm', jobs: %w[bad],
          signals: [{ name: 'x', expr: 'up', warn: 1 }], rate_metric: 'http_total')
      }.to raise_error(ArgumentError, /together/)
    end

    it 'appends author extra_rows after the canon' do
      d = Lib::WorkloadOverview.build(id: :svc, name: 'svc', datasource: 'vm', jobs: %w[svc],
        signals: [{ name: 'x', expr: 'up', warn: 1 }],
        extra_rows: [->(b) { b.row('Custom') { panel(:c, kind: :stat) { query 'A', 'up', datasource: 'vm' } } }])
      expect(d.rows.last.title).to eq('Custom')
    end
  end
end
