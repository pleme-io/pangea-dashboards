# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Dashboards::Types do
  describe 'Threshold' do
    it 'allows nil value (base color band)' do
      t = described_class::Threshold.new(color: 'green')
      expect(t.value).to be_nil
      expect(t.color).to eq('green')
    end

    it 'coerces value strings to floats' do
      t = described_class::Threshold.new(color: 'red', value: '90')
      expect(t.value).to eq(90.0)
    end
  end

  describe 'ThresholdConfig' do
    it 'defaults to absolute mode + empty steps' do
      t = described_class::ThresholdConfig.new
      expect(t.mode).to eq('absolute')
      expect(t.steps).to eq([])
    end

    it 'rejects an unknown mode' do
      expect {
        described_class::ThresholdConfig.new(mode: 'logarithmic')
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'Query' do
    it 'requires ref + expr + datasource_uid' do
      q = described_class::Query.new(
        ref: 'A', expr: 'up', datasource_uid: 'vm'
      )
      expect(q.ref).to eq('A')
    end

    it 'accepts dd_query for explicit Datadog override' do
      q = described_class::Query.new(
        ref: 'A', expr: 'up', datasource_uid: 'vm',
        dd_query: 'avg:my.metric{*}'
      )
      expect(q.dd_query).to eq('avg:my.metric{*}')
    end
  end

  describe 'Panel' do
    it 'rejects an unknown kind' do
      expect {
        described_class::Panel.new(
          id: :p, kind: :sankey, title: 't', queries: []
        )
      }.to raise_error(Dry::Struct::Error)
    end

    it 'accepts every supported kind' do
      %i[stat timeseries gauge table heatmap text pie].each do |kind|
        p = described_class::Panel.new(
          id: :p, kind: kind, title: 't', queries: []
        )
        expect(p.kind).to eq(kind)
      end
    end
  end

  describe 'Dashboard' do
    it 'builds with minimal fields + sensible defaults' do
      d = described_class::Dashboard.new(
        id: :d, title: 'D', uid: 'd', rows: []
      )
      expect(d.refresh).to eq('30s')
      expect(d.time.from).to eq('now-1h')
      expect(d.editable).to be true
    end
  end
end
