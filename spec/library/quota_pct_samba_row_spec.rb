# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/quota_pct_samba_row'

# QuotaPctSambaRow — the samba rate-limited-consumer surface. Asserts the
# emitted PromQL, the panel kind/width/presence, the quotaPct gauge bounds +
# defect thresholds, the floored optional legs, and the validation rejection.
RSpec.describe Pangea::Dashboards::Library::QuotaPctSambaRow do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'the quotaPct gauge — the load-bearing knob' do
    let(:built) do
      row_with do |r|
        Lib::QuotaPctSambaRow.add(r, datasource: 'vm', consumer_label: 'consumer',
          quota_metric: 'samba_quota_pct', rate_limit_metric: 'samba_rate_limit_derived')
      end
    end

    it 'renders a 0–100 percent gauge over the quota metric, grouped by consumer' do
      g = built.panels.find { |p| p.id == :samba_quota_pct }
      expect(g.kind).to eq(:gauge)
      expect(g.unit).to eq('percent')
      expect(g.min).to eq(0)
      expect(g.max).to eq(100)
      expect(g.queries.first.expr).to eq('max by (consumer)(samba_quota_pct)')
      expect(g.queries.first.presence).to eq(:continuous)
      expect(g.queries.first.legend_format).to eq('{{consumer}}')
    end

    it 'colours the gauge green→amber→red by the defect thresholds (80 / 95 default)' do
      g = built.panels.find { |p| p.id == :samba_quota_pct }
      expect(g.thresholds.steps.map(&:color)).to eq(%w[green orange red])
      expect(g.thresholds.steps.map(&:value)).to eq([nil, 80.0, 95.0])
    end

    it 'emits the derived-rate timeseries from X-RateLimit-Limit (continuous, not floored)' do
      ts = built.panels.find { |p| p.id == :samba_derived_rate }
      expect(ts.kind).to eq(:timeseries)
      expect(ts.unit).to eq('reqps')
      expect(ts.queries.first.expr).to eq('max by (consumer)(samba_rate_limit_derived)')
      expect(ts.queries.first.presence).to eq(:continuous)
      expect(ts.queries.first.expr).not_to include('vector(0)')
    end

    it 'lays the two core panels out half-width when no optional legs are given' do
      expect(built.panels.size).to eq(2)
      expect(built.panels.map(&:width)).to all(eq(Theme.half))
    end
  end

  describe 'a typed-selector case + the optional floored legs' do
    let(:built) do
      row_with do |r|
        Lib::QuotaPctSambaRow.add(r, datasource: 'vm', consumer_label: 'consumer',
          quota_metric: 'samba_quota_pct', rate_limit_metric: 'samba_rate_limit_derived',
          backpressure_metric: 'samba_backpressure_total',
          ratelimited_counter: 'samba_ratelimited_total',
          selector: { consumer: 'github' })
      end
    end

    it 'pins the consumer with a typed Hash selector on both core panels' do
      g  = built.panels.find { |p| p.id == :samba_quota_pct }
      ts = built.panels.find { |p| p.id == :samba_derived_rate }
      expect(g.queries.first.expr).to eq('max by (consumer)(samba_quota_pct{consumer="github"})')
      expect(ts.queries.first.expr).to eq('max by (consumer)(samba_rate_limit_derived{consumer="github"})')
    end

    it 'emits all four panels third-width when both optional legs are present' do
      expect(built.panels.size).to eq(4)
      expect(built.panels.map(&:width)).to all(eq(Theme.third))
    end

    it 'floors the back-pressure leg with or vector(0) (event-driven)' do
      bp = built.panels.find { |p| p.id == :samba_backpressure_samba_backpressure_total }
      expect(bp.kind).to eq(:timeseries)
      expect(bp.title).to eq('Back-pressure')
      expect(bp.queries.first.expr).to eq('sum by (consumer)(rate(samba_backpressure_total{consumer="github"}[5m])) or vector(0)')
      expect(bp.queries.first.presence).to eq(:event_driven)
    end

    it 'floors the 429 / secondary-rate-limit leg with or vector(0) (event-driven)' do
      rl = built.panels.find { |p| p.id == :samba_ratelimited_samba_ratelimited_total }
      expect(rl.title).to eq('429 / secondary rate-limit')
      expect(rl.queries.first.expr).to eq('sum by (consumer)(rate(samba_ratelimited_total{consumer="github"}[5m])) or vector(0)')
      expect(rl.queries.first.presence).to eq(:event_driven)
    end
  end

  describe 'validation rejections' do
    it 'requires datasource / consumer_label / quota_metric / rate_limit_metric' do
      expect { row_with { |r| Lib::QuotaPctSambaRow.add(r, datasource: nil, consumer_label: 'c', quota_metric: 'q', rate_limit_metric: 'r') } }
        .to raise_error(ArgumentError, /QuotaPctSambaRow: datasource/)
      expect { row_with { |r| Lib::QuotaPctSambaRow.add(r, datasource: 'vm', consumer_label: '', quota_metric: 'q', rate_limit_metric: 'r') } }
        .to raise_error(ArgumentError, /consumer_label/)
      expect { row_with { |r| Lib::QuotaPctSambaRow.add(r, datasource: 'vm', consumer_label: 'c', quota_metric: nil, rate_limit_metric: 'r') } }
        .to raise_error(ArgumentError, /quota_metric/)
      expect { row_with { |r| Lib::QuotaPctSambaRow.add(r, datasource: 'vm', consumer_label: 'c', quota_metric: 'q', rate_limit_metric: '') } }
        .to raise_error(ArgumentError, /rate_limit_metric/)
    end

    it 'rejects quota_warn >= quota_crit (a malformed defect ladder)' do
      expect {
        row_with { |r| Lib::QuotaPctSambaRow.add(r, datasource: 'vm', consumer_label: 'c',
          quota_metric: 'q', rate_limit_metric: 'r', quota_warn: 95, quota_crit: 80) }
      }.to raise_error(ArgumentError, /quota_warn must be < quota_crit/)
    end
  end
end
