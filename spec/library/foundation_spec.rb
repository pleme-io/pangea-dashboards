# frozen_string_literal: true

require 'spec_helper'

# Wave 0 — the foundation primitives every higher layer composes.
# Builds a RowBuilder, runs the component, asserts on the emitted PromQL +
# panel shape (kind/width/height/presence/threshold).
RSpec.describe 'Pangea::Dashboards::Library Wave 0 foundation' do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe Pangea::Dashboards::Library::Floor do
    it 'appends `or vector(0)` to a bare expr' do
      expect(Lib::Floor.zero('sum(rate(x[5m]))')).to eq('sum(rate(x[5m])) or vector(0)')
    end

    it 'is idempotent when a vector() literal is already present' do
      expr = 'sum(rate(x[5m])) or vector(0)'
      expect(Lib::Floor.zero(expr)).to eq(expr)
    end

    it 'never floors an absent() probe (the missing-series IS the signal)' do
      expect(Lib::Floor.zero('absent(up{job="x"})')).to eq('absent(up{job="x"})')
    end
  end

  describe Pangea::Dashboards::Library::Promql do
    it 'renders a Hash selector as exact matchers' do
      expect(Lib::Promql.braces(namespace: 'monitoring', container: 'vector'))
        .to eq('{namespace="monitoring",container="vector"}')
    end

    it 'renders a Regexp value as a =~ matcher' do
      expect(Lib::Promql.braces(code: /5../)).to eq('{code=~"5.."}')
    end

    it 'renders an Array value as an any-of =~ matcher' do
      expect(Lib::Promql.braces(result: %w[error requeue])).to eq('{result=~"error|requeue"}')
    end

    it 'drops nil selector values' do
      expect(Lib::Promql.braces(a: 'x', b: nil)).to eq('{a="x"}')
    end

    it 'returns "" for an empty/nil selector' do
      expect(Lib::Promql.braces(nil)).to eq('')
      expect(Lib::Promql.braces({})).to eq('')
    end

    it 'builds a by() grouping clause and "" when empty' do
      expect(Lib::Promql.by(%w[a b])).to eq(' by (a, b)')
      expect(Lib::Promql.by([])).to eq('')
    end

    it 'composes sum_rate / histogram_quantile' do
      expect(Lib::Promql.sum_rate(metric: 'http_total', window: '5m', group_by: %w[route]))
        .to eq('sum by (route)(rate(http_total[5m]))')
      expect(Lib::Promql.histogram_quantile(quantile: 0.99, bucket_metric: 'd_seconds_bucket',
                                            window: '5m', group_by: %w[verb]))
        .to eq('histogram_quantile(0.99, sum by (verb, le)(rate(d_seconds_bucket[5m])))')
    end
  end

  describe Pangea::Dashboards::Library::RateWithZeroFloor do
    it 'emits a floored sum-rate timeseries by default' do
      built = row_with { |r| Lib::RateWithZeroFloor.add(r, datasource: 'vm', counter_metric: 'reconcile_total', group_by: %w[controller]) }
      p = built.panels.first
      expect(p.kind).to eq(:timeseries)
      expect(p.queries.first.expr).to eq('sum by (controller)(rate(reconcile_total[5m])) or vector(0)')
      expect(p.queries.first.presence).to eq(:event_driven)
      expect(p.queries.first.legend_format).to eq('{{controller}}')
    end

    it 'supports a stat variant with a colour-flooded tile' do
      built = row_with { |r| Lib::RateWithZeroFloor.add(r, datasource: 'vm', counter_metric: 'errs_total', kind: :stat) }
      p = built.panels.first
      expect(p.kind).to eq(:stat)
      expect(p.display_mode).to eq(:background)
      expect(p.height).to eq(Theme::STAT_H)
    end

    it 'applies a typed selector' do
      built = row_with { |r| Lib::RateWithZeroFloor.add(r, datasource: 'vm', counter_metric: 'x_total', selector: { code: /5../ }) }
      expect(built.panels.first.queries.first.expr).to include('x_total{code=~"5.."}')
    end

    it 'requires a datasource + counter_metric' do
      expect { row_with { |r| Lib::RateWithZeroFloor.add(r, datasource: nil, counter_metric: 'x') } }.to raise_error(ArgumentError, /datasource/)
      expect { row_with { |r| Lib::RateWithZeroFloor.add(r, datasource: 'vm', counter_metric: '') } }.to raise_error(ArgumentError, /counter_metric/)
    end
  end

  describe Pangea::Dashboards::Library::LatencyHistogramPanel do
    it 'emits one query per quantile with p-token legends' do
      built = row_with do |r|
        Lib::LatencyHistogramPanel.add(r, datasource: 'vm',
          bucket_metric: 'reconcile_time_seconds_bucket', group_by: %w[controller],
          quantiles: [0.5, 0.95, 0.99])
      end
      p = built.panels.first
      expect(p.kind).to eq(:timeseries)
      expect(p.queries.map(&:ref)).to eq(%w[A B C])
      expect(p.queries.map(&:legend_format)).to eq(['p50 {{controller}}', 'p95 {{controller}}', 'p99 {{controller}}'])
      expect(p.queries[2].expr).to eq('histogram_quantile(0.99, sum by (controller, le)(rate(reconcile_time_seconds_bucket[5m])))')
      expect(p.min).to eq(0)
    end

    it 'rejects an out-of-range quantile' do
      expect { row_with { |r| Lib::LatencyHistogramPanel.add(r, datasource: 'vm', bucket_metric: 'x_bucket', quantiles: [1.5]) } }
        .to raise_error(ArgumentError, /quantile/)
    end
  end

  describe Pangea::Dashboards::Library::TopNTable do
    it 'wraps an increase aggregation in topk by default' do
      built = row_with do |r|
        Lib::TopNTable.add(r, datasource: 'vm', metric: 'kube_pod_container_status_restarts_total',
          group_by: %w[namespace pod], n: 5, window: '1h')
      end
      p = built.panels.first
      expect(p.kind).to eq(:table)
      expect(p.queries.first.instant).to be(true)
      expect(p.queries.first.expr).to eq('topk(5, sum by (namespace, pod)(increase(kube_pod_container_status_restarts_total[1h])))')
    end

    it 'merges failure_results into a result=~ matcher' do
      built = row_with do |r|
        Lib::TopNTable.add(r, datasource: 'vm', metric: 'job_runs_total', group_by: %w[repo],
          failure_results: %w[failed cancelled])
      end
      expect(built.panels.first.queries.first.expr).to include('job_runs_total{result=~"failed|cancelled"}')
    end

    it 'requires a non-empty group_by' do
      expect { row_with { |r| Lib::TopNTable.add(r, datasource: 'vm', metric: 'x', group_by: []) } }
        .to raise_error(ArgumentError, /group_by/)
    end
  end

  describe Pangea::Dashboards::Library::FailedResourcesTable do
    it 'emits an instant > gt table with a red threshold' do
      built = row_with do |r|
        Lib::FailedResourcesTable.add(r, datasource: 'vm', failed_metric: 'pangea_template_failed_resources',
          group_by: %w[schema template])
      end
      p = built.panels.first
      expect(p.kind).to eq(:table)
      expect(p.queries.first.instant).to be(true)
      expect(p.queries.first.expr).to eq('sum by (schema, template)(pangea_template_failed_resources) > 0')
      # green base + red step (warn = gt+1 = 1)
      expect(p.thresholds.steps.map(&:color)).to eq(%w[green red])
    end
  end
end
