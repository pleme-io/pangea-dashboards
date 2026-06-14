# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/webhook_latency_heatmap'

# Webhook latency heatmap — a :heatmap over a *_latency_seconds_bucket
# histogram. Builds a RowBuilder, runs the component, asserts on the emitted
# PromQL (sum by(le)(rate(...))), the panel kind/width/height/presence, and
# the validation rejections.
RSpec.describe Pangea::Dashboards::Library::WebhookLatencyHeatmap do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe '.add (happy path)' do
    let(:built) do
      row_with do |r|
        Lib::WebhookLatencyHeatmap.add(r, datasource: 'vm',
          histogram_metric: 'apiserver_admission_webhook_admission_duration_seconds_bucket')
      end
    end

    let(:panel) { built.panels.first }

    it 'emits a full-width heatmap panel at table height' do
      expect(built.panels.size).to eq(1)
      expect(panel.kind).to eq(:heatmap)
      expect(panel.width).to eq(Theme.full)
      expect(panel.height).to eq(Theme::TABLE_H)
    end

    it 'builds the canonical sum by(le)(rate(...)) bucket series' do
      expect(panel.queries.size).to eq(1)
      expect(panel.queries.first.expr)
        .to eq('sum by (le)(rate(apiserver_admission_webhook_admission_duration_seconds_bucket[5m]))')
    end

    it 'renders a continuous series with a seconds unit and le legend' do
      q = panel.queries.first
      expect(q.presence).to eq(:continuous)
      expect(q.legend_format).to eq('{{le}}')
      expect(panel.unit).to eq('s')
    end

    it 'defaults the title to "Webhook latency"' do
      expect(panel.title).to eq('Webhook latency')
    end
  end

  describe '.add (typed selector + overrides)' do
    let(:panel) do
      built = row_with do |r|
        Lib::WebhookLatencyHeatmap.add(r, datasource: 'vm',
          histogram_metric: 'webhook_latency_seconds_bucket',
          selector: { name: 'external-secrets', code: /5../ },
          window: '10m', le_label: 'le', title: 'ESO admission latency')
      end
      built.panels.first
    end

    it 'threads a typed Hash selector through Promql (= and =~ matchers)' do
      expect(panel.queries.first.expr)
        .to eq('sum by (le)(rate(webhook_latency_seconds_bucket{name="external-secrets",code=~"5.."}[10m]))')
    end

    it 'honours the title override' do
      expect(panel.title).to eq('ESO admission latency')
    end
  end

  describe '.add (validation)' do
    it 'requires a datasource' do
      expect {
        row_with { |r| Lib::WebhookLatencyHeatmap.add(r, datasource: nil, histogram_metric: 'x_bucket') }
      }.to raise_error(ArgumentError, /WebhookLatencyHeatmap.*datasource/)
    end

    it 'requires a histogram_metric' do
      expect {
        row_with { |r| Lib::WebhookLatencyHeatmap.add(r, datasource: 'vm', histogram_metric: '') }
      }.to raise_error(ArgumentError, /WebhookLatencyHeatmap.*histogram_metric/)
    end

    it 'requires a non-empty window' do
      expect {
        row_with { |r| Lib::WebhookLatencyHeatmap.add(r, datasource: 'vm', histogram_metric: 'x_bucket', window: '') }
      }.to raise_error(ArgumentError, /WebhookLatencyHeatmap.*window/)
    end
  end
end
