# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/controller_runtime_dashboard'
require 'pangea/dashboards/library/log_explorer_dashboard'

# Wave 4 capstones — the full-dashboard mixins that compose the library into
# whole Types::Dashboard objects in one call.
RSpec.describe 'Pangea::Dashboards::Library dashboard mixins' do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  describe Pangea::Dashboards::Library::ControllerRuntimeDashboard do
    let(:dash) do
      Lib::ControllerRuntimeDashboard.build(
        id: :cert_manager_issuer, name: 'cert-manager-issuer', datasource: 'vm',
        service_selector: { job: 'cert-manager-issuer' },
        object_kinds: %w[Certificate Order]
      )
    end

    it 'builds a Types::Dashboard with the SLI + golden-signals rows' do
      expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
      titles = dash.rows.map(&:title)
      expect(titles.first).to match(/SLIs/)
      expect(titles).to include(match(/golden signals/i))
    end

    it 'emits one SLI gauge per object kind, scoped to the controller + kind' do
      sli = dash.rows.first
      expect(sli.panels.size).to eq(2)
      certs = sli.panels.first
      expect(certs.kind).to eq(:gauge)
      # numerator/denominator scope to job + controller=Certificate
      expect(certs.queries.first.expr).to include('job="cert-manager-issuer"')
      expect(certs.queries.first.expr).to include('controller="Certificate"')
    end

    it 'pulls in optional webhook + provider-api + process + logs rows when asked' do
      d = Lib::ControllerRuntimeDashboard.build(
        id: :eso, name: 'external-secrets', datasource: 'vm', logs_datasource: 'vlogs',
        service_selector: { job: 'external-secrets' },
        include_webhook: true, webhook_metric: 'webhook_request_duration_seconds_bucket',
        provider_api_metric: 'externalsecret_provider_api_calls_total',
        process_selector: { job: 'external-secrets' }, stream: '{namespace="external-secrets"}'
      )
      titles = d.rows.map(&:title)
      expect(titles).to include(match(/webhook/i), match(/Provider API/), match(/Go runtime/), 'Logs')
    end

    it 'works with no object_kinds (golden signals only)' do
      d = Lib::ControllerRuntimeDashboard.build(id: :op, datasource: 'vm', service_selector: { job: 'op' })
      expect(d.rows.map(&:title)).to eq(['Controller runtime — golden signals'])
    end

    it 'requires id + datasource + service_selector' do
      expect { Lib::ControllerRuntimeDashboard.build(id: :x, datasource: 'vm', service_selector: {}) }
        .to raise_error(ArgumentError, /service_selector/)
    end
  end

  describe Pangea::Dashboards::Library::LogExplorerDashboard do
    let(:dash) do
      Lib::LogExplorerDashboard.build(id: :rio_logs, logs_datasource: 'vlogs',
        root_label: 'namespace', cascade: %w[app container])
    end

    it 'builds a Types::Dashboard with the search + cascading template vars' do
      expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
      vars = dash.variables.map(&:name)
      expect(vars).to eq(%i[search namespace app container])
    end

    it 'cascades each var query filtered by its ancestors' do
      app = dash.variables.find { |v| v.name == :app }
      expect(app.query).to eq('label_values({namespace=~"$namespace"}, app)')
      container = dash.variables.find { |v| v.name == :container }
      expect(container.query).to eq('label_values({namespace=~"$namespace",app=~"$app"}, container)')
    end

    it 'scopes a log-volume chart + the standard log windows to the vars' do
      titles = dash.rows.map(&:title)
      expect(titles).to include('Volume', 'Logs')
      vol = dash.rows.find { |r| r.title == 'Volume' }.panels.first
      expect(vol.queries.first.expr).to include('namespace=~"$namespace"').and include('stats by (container)')
      logs = dash.rows.find { |r| r.title == 'Logs' }
      # full + error window + error-rate, all over the $search-appended stream
      expect(logs.panels.map { |p| p.queries.first.expr }).to all(include('$search'))
    end

    it 'requires id + logs_datasource + root_label' do
      expect { Lib::LogExplorerDashboard.build(id: :x, logs_datasource: '', root_label: 'ns') }
        .to raise_error(ArgumentError, /logs_datasource/)
    end
  end
end
