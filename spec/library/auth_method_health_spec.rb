# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/auth_method_health'

# AuthMethodHealth — the trust-boundary board.
RSpec.describe Pangea::Dashboards::Library::AuthMethodHealth do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  describe 'happy path' do
    let(:dash) do
      Lib::AuthMethodHealth.build(
        id: :auth_health, name: 'Auth Method Health', datasource: 'metrics', logs_datasource: 'logs',
        auth_metric: 'gateway_auth_total', method_label: 'method', outcome_label: 'outcome',
        methods: %w[token oauth saml], identity_label: 'identity',
        stream: '{namespace="gateway"}'
      )
    end

    it 'returns a Types::Dashboard tagged pleme-io + auth-method-health' do
      expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
      expect(dash.tags).to include('pleme-io', 'auth-method-health')
    end

    it 'rows are in story order: defects → SLI → outcomes → latency → top denied → logs' do
      expect(dash.rows.map(&:title)).to eq([
        'Status — trust-boundary defects',
        'SLI — denial rate per method',
        'Auth outcomes',
        'Auth decision latency',
        'Top denied identities',
        'Logs'
      ])
    end

    it 'the SLI strip renders one denial gauge per method scoped to the denied outcomes' do
      sli = dash.rows.find { |r| r.title == 'SLI — denial rate per method' }
      gauges = sli.panels.select { |p| p.kind == :gauge }
      expect(gauges.size).to eq(3)
      expect(gauges.first.queries.first.expr).to include('outcome=~"denied|error"')
    end

    it 'the top-denied table ranks the identity label filtered to denied outcomes' do
      top = dash.rows.find { |r| r.title == 'Top denied identities' }
      expr = top.panels.first.queries.first.expr
      expect(expr).to include('by (identity)')
      expect(expr).to include('outcome=~"denied|error"')
      expect(expr).to include('topk(10')
    end

    it 'the auth-latency tail is a p99 histogram grouped by method' do
      lat = dash.rows.find { |r| r.title == 'Auth decision latency' }
      p = lat.panels.first
      expect(p.queries.map(&:expr)).to all(include('histogram_quantile'))
    end
  end

  describe 'validation' do
    it 'requires id + datasource + auth_metric + non-empty methods' do
      expect { Lib::AuthMethodHealth.build(id: :x, datasource: 'vm', auth_metric: '', methods: %w[t]) }
        .to raise_error(ArgumentError, /auth_metric/)
      expect { Lib::AuthMethodHealth.build(id: :x, datasource: 'vm', auth_metric: 'a', methods: []) }
        .to raise_error(ArgumentError, /methods/)
    end
  end
end
