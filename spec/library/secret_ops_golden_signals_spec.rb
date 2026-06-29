# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/secret_ops_golden_signals'

# SecretOpsGoldenSignals — secret data-plane RED board.
RSpec.describe Pangea::Dashboards::Library::SecretOpsGoldenSignals do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  describe 'happy path' do
    let(:dash) do
      Lib::SecretOpsGoldenSignals.build(
        id: :secret_dp, name: 'Secret data plane', datasource: 'metrics', logs_datasource: 'logs',
        ops_metric: 'secret_operation_total', latency_metric: 'secret_op_seconds_bucket',
        verb_label: 'op', result_label: 'result', caller_label: 'caller',
        stream: '{namespace="secrets"}'
      )
    end

    it 'returns a Types::Dashboard' do
      expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
    end

    it 'tags pleme-io + secret-ops-golden' do
      expect(dash.tags).to include('pleme-io', 'secret-ops-golden')
    end

    it 'rows are in story order: defects → matrix → latency → SLO → quota → top → logs' do
      expect(dash.rows.map(&:title)).to eq([
        'Status — what needs attention?',
        'Secret ops — RED matrix',
        'Op latency distribution',
        'SLO / error budget',
        'Rate-limited consumer (samba)',
        'Top failing — ops + callers',
        'Logs'
      ])
    end

    it 'the SLO row builds good = result-negated subset, total = all ops' do
      slo = dash.rows.find { |r| r.title == 'SLO / error budget' }
      exprs = slo.panels.flat_map { |p| p.queries.map(&:expr) }.join("\n")
      expect(exprs).to include('result!~"error|denied"')
      expect(exprs).to include('secret_operation_total')
    end

    it 'the latency distribution is a heatmap over the op-seconds bucket' do
      lat = dash.rows.find { |r| r.title == 'Op latency distribution' }
      p = lat.panels.first
      expect(p.kind).to eq(:heatmap)
      expect(p.queries.first.expr).to include('secret_op_seconds_bucket')
    end

    it 'the top-failing row ranks ops + callers filtered to failure results' do
      top = dash.rows.find { |r| r.title == 'Top failing — ops + callers' }
      expect(top.panels.size).to eq(2)
      expect(top.panels.map(&:kind)).to all(eq(:table))
      expect(top.panels.first.queries.first.expr).to include('topk(10')
      expect(top.panels.last.queries.first.expr).to include('by (caller)')
    end
  end

  describe 'validation' do
    it 'requires id + datasource + ops_metric + latency_metric' do
      expect { Lib::SecretOpsGoldenSignals.build(id: :x, datasource: 'vm', ops_metric: '', latency_metric: 'b') }
        .to raise_error(ArgumentError, /ops_metric/)
      expect { Lib::SecretOpsGoldenSignals.build(id: :x, datasource: 'vm', ops_metric: 'a', latency_metric: nil) }
        .to raise_error(ArgumentError, /latency_metric/)
    end
  end
end
