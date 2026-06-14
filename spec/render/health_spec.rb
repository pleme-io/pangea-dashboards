# frozen_string_literal: true

require 'pangea-dashboards'

# The Health probe is the RUNTIME half of dashboard correctness: it answers,
# definitively, whether a panel's "no data" means broken (the metric is never
# emitted) or merely idle (the metric is wired but quiet). The publish gate
# refuses any dashboard whose `:continuous` metrics are not wired — so a broken
# dashboard cannot ship.
RSpec.describe Pangea::Dashboards::Health do
  before do
    Pangea::Dashboards::Datasources.register('vm', grafana_type: 'prometheus', query_lang: :promql)
    Pangea::Dashboards::Datasources.register('vlogs', grafana_type: 'victoriametrics-logs-datasource', query_lang: :logsql)
  end

  let(:dashboard) do
    b = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :t)
    b.instance_eval do
      title 't'
      uid 't'
      row 'metrics' do
        panel :a, kind: :timeseries do
          title 'reconciles'
          query 'A', 'sum by (controller) (rate(pangea_reconciles_total[5m]))', datasource: 'vm' # continuous (default)
        end
        panel :b, kind: :timeseries do
          title 'errors'
          query 'A', 'rate(pangea_errors_total[5m])', datasource: 'vm', presence: :event_driven
        end
        panel :c, kind: :stat do
          title 'magma'
          query 'A', 'max(pangea_magma_resources_failed)', datasource: 'vm', presence: :conditional
        end
      end
      row 'logs' do
        panel :l, kind: :table do
          title 'logs'
          query 'A', '{namespace="x"} | error', datasource: 'vlogs' # LogsQL — skipped
        end
      end
    end
    b.build
  end

  describe 'metric extraction' do
    let(:metrics) { described_class.metrics(dashboard) }

    it 'extracts metric base names only — not functions, by-labels, or log streams' do
      expect(metrics.keys).to contain_exactly(
        'pangea_reconciles_total', 'pangea_errors_total', 'pangea_magma_resources_failed'
      )
    end

    it 'does NOT mistake a by-clause label for a metric' do
      expect(metrics.keys).not_to include('controller')
    end

    it 'skips LogsQL (vlogs) queries entirely' do
      expect(metrics.keys).not_to include('namespace', 'error')
    end

    it 'carries the typed presence class' do
      expect(metrics['pangea_reconciles_total'][:presence]).to eq(:continuous)
      expect(metrics['pangea_errors_total'][:presence]).to eq(:event_driven)
      expect(metrics['pangea_magma_resources_failed'][:presence]).to eq(:conditional)
    end
  end

  describe 'the definitive broken-vs-idle classification (probe against a live TSDB)' do
    # series counts: a metric EMITTED has ≥1 series (even at value 0); a metric
    # NEVER emitted has 0 series. That is the one distinguisher.
    def probe(counts)
      described_class.probe(dashboard) { |m| counts.fetch(m) }
    end

    it 'classifies wired (series present) vs not_wired (no series) vs error' do
      results = probe(
        'pangea_reconciles_total' => 4,       # wired, has data
        'pangea_errors_total' => 0,            # not_wired (no series)
        'pangea_magma_resources_failed' => 0   # not_wired (no series)
      )
      by = results.each_with_object({}) { |r, h| h[r.metric] = r.status }
      expect(by['pangea_reconciles_total']).to eq(:wired)
      expect(by['pangea_errors_total']).to eq(:not_wired)
      expect(by['pangea_magma_resources_failed']).to eq(:not_wired)
    end

    it 'marks a metric whose probe raises as :error' do
      results = described_class.probe(dashboard) do |m|
        m == 'pangea_reconciles_total' ? (raise 'datasource down') : 1
      end
      r = results.find { |x| x.metric == 'pangea_reconciles_total' }
      expect(r.status).to eq(:error)
    end
  end

  describe 'the publish gate — broken dashboards cannot ship' do
    def gate(counts)
      described_class.gate(described_class.probe(dashboard) { |m| counts.fetch(m) })
    end

    it 'is publishable when every continuous metric is wired (idle conditionals are fine)' do
      g = gate('pangea_reconciles_total' => 5, 'pangea_errors_total' => 1, 'pangea_magma_resources_failed' => 0)
      expect(g[:publishable]).to be(true)
      expect(g[:broken]).to be_empty
    end

    it 'HARD-FAILS when a CONTINUOUS metric is not wired (the broken case)' do
      g = gate('pangea_reconciles_total' => 0, 'pangea_errors_total' => 1, 'pangea_magma_resources_failed' => 1)
      expect(g[:publishable]).to be(false)
      expect(g[:broken].map(&:metric)).to include('pangea_reconciles_total')
    end

    it 'does NOT fail on an idle :conditional metric (legitimately-off workload)' do
      g = gate('pangea_reconciles_total' => 5, 'pangea_errors_total' => 1, 'pangea_magma_resources_failed' => 0)
      expect(g[:broken].map(&:metric)).not_to include('pangea_magma_resources_failed')
    end

    it 'WARNS (not fails) on an absent :event_driven metric' do
      g = gate('pangea_reconciles_total' => 5, 'pangea_errors_total' => 0, 'pangea_magma_resources_failed' => 1)
      expect(g[:publishable]).to be(true)
      expect(g[:warnings].map(&:metric)).to include('pangea_errors_total')
    end

    it 'HARD-FAILS on any datasource error' do
      results = described_class.probe(dashboard) { |_m| raise 'tsdb unreachable' }
      g = described_class.gate(results)
      expect(g[:publishable]).to be(false)
      expect(g[:broken]).not_to be_empty
    end
  end
end
