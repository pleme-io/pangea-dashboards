# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/secret_ops_golden_matrix_row'

# SecretOpsGoldenMatrixRow — verb-partitioned RED matrix: a stacked per-verb
# rate timeseries, a per-verb error timeseries, and the shared p99 latency tail.
RSpec.describe Pangea::Dashboards::Library::SecretOpsGoldenMatrixRow do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'happy path — three panels (rate · errors · latency)' do
    let(:built) do
      row_with do |r|
        Lib::SecretOpsGoldenMatrixRow.add(r, datasource: 'vm',
          ops_metric: 'secret_operation_total', latency_metric: 'secret_op_seconds_bucket',
          verb_label: 'op', result_label: 'result', error_results: %w[error denied])
      end
    end

    it 'emits exactly three third-width panels' do
      expect(built.panels.size).to eq(3)
      expect(built.panels.map(&:width)).to all(eq(Theme.third))
    end

    it 'panel 1 is a stacked rate timeseries grouped by the verb label' do
      p = built.panels[0]
      expect(p.kind).to eq(:timeseries)
      expect(p.queries.first.expr).to eq('sum by (op)(rate(secret_operation_total[5m])) or vector(0)')
      # stacking via the typed grafana override
      stack = p.options.dig(:grafana, 'fieldConfig', 'defaults', 'custom', 'stacking', 'mode')
      expect(stack).to eq('normal')
      expect(p.queries.first.legend_format).to eq('{{op}}')
    end

    it 'panel 2 is the error leg filtered to the error results by the result label' do
      p = built.panels[1]
      expect(p.kind).to eq(:timeseries)
      expect(p.queries.first.expr).to include('result=~"error|denied"')
      expect(p.queries.first.expr).to include('sum by (op)(rate(secret_operation_total')
      expect(p.queries.first.expr).to end_with('or vector(0)')
    end

    it 'panel 3 is the shared p99 latency histogram grouped by verb' do
      p = built.panels[2]
      expect(p.kind).to eq(:timeseries)
      expect(p.queries.map(&:expr)).to all(include('histogram_quantile'))
      expect(p.queries.last.expr).to include('le, op').or include('op, le')
    end
  end

  describe 'typed selector scoping' do
    it 'folds a Hash selector into the rate matrix and AND-joins the error results' do
      built = row_with do |r|
        Lib::SecretOpsGoldenMatrixRow.add(r, datasource: 'vm',
          ops_metric: 'op_total', latency_metric: 'op_seconds_bucket',
          selector: { service: 'gw' })
      end
      expect(built.panels[0].queries.first.expr).to include('op_total{service="gw"}')
      err = built.panels[1].queries.first.expr
      expect(err).to include('service="gw"')
      expect(err).to include('result=~"error|denied"')
    end
  end

  describe 'validation' do
    it 'requires datasource + ops_metric + latency_metric' do
      expect { row_with { |r| Lib::SecretOpsGoldenMatrixRow.add(r, datasource: nil,
        ops_metric: 'a', latency_metric: 'b') } }.to raise_error(ArgumentError, /datasource/)
      expect { row_with { |r| Lib::SecretOpsGoldenMatrixRow.add(r, datasource: 'vm',
        ops_metric: '', latency_metric: 'b') } }.to raise_error(ArgumentError, /ops_metric/)
      expect { row_with { |r| Lib::SecretOpsGoldenMatrixRow.add(r, datasource: 'vm',
        ops_metric: 'a', latency_metric: nil) } }.to raise_error(ArgumentError, /latency_metric/)
    end
  end
end
