# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/auth_outcomes_row'

# AuthOutcomesRow — a stacked allowed/denied/error outcomes timeseries + one
# per-method denial-rate gauge (RedSliGaugeStrip over the outcome label).
RSpec.describe Pangea::Dashboards::Library::AuthOutcomesRow do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'happy path — stack + per-method gauges' do
    let(:built) do
      row_with do |r|
        Lib::AuthOutcomesRow.add(r, datasource: 'vm',
          auth_metric: 'gateway_auth_total', method_label: 'method', outcome_label: 'outcome',
          denied_outcomes: %w[denied error], methods: %w[token oauth saml])
      end
    end

    it 'emits the stack + one gauge per method (1 + 3)' do
      expect(built.panels.size).to eq(4)
    end

    it 'panel 1 is a stacked outcomes timeseries grouped by outcome label, floored' do
      p = built.panels.first
      expect(p.kind).to eq(:timeseries)
      expect(p.queries.first.expr).to eq('sum by (outcome)(rate(gateway_auth_total[5m])) or vector(0)')
      stack = p.options.dig(:grafana, 'fieldConfig', 'defaults', 'custom', 'stacking', 'mode')
      expect(stack).to eq('normal')
      expect(p.queries.first.legend_format).to eq('{{outcome}}')
    end

    it 'renders one denial-rate gauge per auth method scoped to that method' do
      gauges = built.panels.select { |p| p.kind == :gauge }
      expect(gauges.size).to eq(3)
      # numerator scopes to the method AND the denied outcomes
      expr = gauges.first.queries.first.expr
      expect(expr).to include('method="token"')
      expect(expr).to include('outcome=~"denied|error"')
    end
  end

  describe 'validation' do
    it 'requires datasource + auth_metric + non-empty methods' do
      expect { row_with { |r| Lib::AuthOutcomesRow.add(r, datasource: nil,
        auth_metric: 'a', methods: %w[t]) } }.to raise_error(ArgumentError, /datasource/)
      expect { row_with { |r| Lib::AuthOutcomesRow.add(r, datasource: 'vm',
        auth_metric: '', methods: %w[t]) } }.to raise_error(ArgumentError, /auth_metric/)
      expect { row_with { |r| Lib::AuthOutcomesRow.add(r, datasource: 'vm',
        auth_metric: 'a', methods: []) } }.to raise_error(ArgumentError, /methods/)
    end
  end
end
