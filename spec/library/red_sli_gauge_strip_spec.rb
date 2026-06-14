# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/red_sli_gauge_strip'

# RedSliGaugeStrip — a horizontal row of per-subsystem error-ratio gauges
# using the increase-ratio idiom. Builds a RowBuilder, runs the component,
# asserts the emitted PromQL + gauge shape (kind/width/unit/min/max/threshold).
RSpec.describe Pangea::Dashboards::Library::RedSliGaugeStrip do
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
        Lib::RedSliGaugeStrip.add(r, datasource: 'vm',
          metric: 'externalsecret_sync_calls_total',
          subsystems: [
            { name: 'ExternalSecret',     extra_selector: { kind: 'ExternalSecret' } },
            { name: 'ClusterSecretStore', extra_selector: { kind: 'ClusterSecretStore' } }
          ])
      end
    end

    it 'emits one gauge tile per subsystem, evenly tiled across the grid' do
      expect(built.panels.size).to eq(2)
      expect(built.panels.map(&:kind)).to all(eq(:gauge))
      # 2 tiles → tile_width(2) = 12 each (fills the 24-col grid cleanly).
      expect(built.panels.map(&:width)).to all(eq(Theme.tile_width(2)))
      expect(built.panels.map(&:height)).to all(eq(Theme::STAT_H))
    end

    it 'builds the increase-ratio (error-increase / total-increase) per subsystem' do
      p = built.panels.first
      expect(p.queries.first.expr).to eq(
        'sum(increase(externalsecret_sync_calls_total{kind="ExternalSecret",result=~"error|requeue"}[15m])) / ' \
        'sum(increase(externalsecret_sync_calls_total{kind="ExternalSecret"}[15m]))'
      )
    end

    it 'renders a unit-less percentunit gauge bounded 0–1 with a continuous presence' do
      p = built.panels.first
      expect(p.unit).to eq('percentunit')
      expect(p.min).to eq(0)
      expect(p.max).to eq(1)
      expect(p.queries.first.presence).to eq(:continuous)
    end

    it 'bakes the window into the tile title and the defect thresholds into the gauge' do
      expect(built.panels.map(&:title)).to eq(['ExternalSecret errors (15m)', 'ClusterSecretStore errors (15m)'])
      # green base + amber warn + red crit (Theme.defect_steps(warn:, crit:)).
      expect(built.panels.first.thresholds.steps.map(&:color)).to eq(%w[green orange red])
      vals = built.panels.first.thresholds.steps.map(&:value)
      expect(vals).to eq([nil, 0.01, 0.05])
    end
  end

  describe '.add (typed-selector merging)' do
    it 'merges a Hash extra_selector with a Hash error_label_match into one matcher' do
      built = row_with do |r|
        Lib::RedSliGaugeStrip.add(r, datasource: 'vm', metric: 'sync_calls_total',
          error_label_match: { result: %w[error requeue] }, window: '5m',
          subsystems: [{ name: 'PushSecret', extra_selector: { kind: 'PushSecret', namespace: 'es' } }])
      end
      expr = built.panels.first.queries.first.expr
      # numerator carries BOTH the partition labels AND the regex error matcher
      expect(expr).to include('sync_calls_total{kind="PushSecret",namespace="es",result=~"error|requeue"}[5m]')
      # denominator carries ONLY the partition labels
      expect(expr).to include('sum(increase(sync_calls_total{kind="PushSecret",namespace="es"}[5m]))')
    end

    it 'AND-joins a String error_label_match onto a Hash partition body' do
      built = row_with do |r|
        Lib::RedSliGaugeStrip.add(r, datasource: 'vm', metric: 'calls_total',
          subsystems: [{ name: 'Store', extra_selector: { kind: 'Store' } }])
      end
      # default error_label_match is the String 'result=~"error|requeue"'
      expect(built.panels.first.queries.first.expr).to include(
        'calls_total{kind="Store",result=~"error|requeue"}'
      )
    end

    it 'honours an overridden window in both legs and the title' do
      built = row_with do |r|
        Lib::RedSliGaugeStrip.add(r, datasource: 'vm', metric: 'm_total', window: '1h',
          subsystems: [{ name: 'Kind', extra_selector: { kind: 'Kind' } }])
      end
      p = built.panels.first
      expect(p.queries.first.expr).to include('[1h]')
      expect(p.title).to eq('Kind errors (1h)')
    end

    it 'uses a custom title_suffix when supplied' do
      built = row_with do |r|
        Lib::RedSliGaugeStrip.add(r, datasource: 'vm', metric: 'm_total', title_suffix: 'SLI',
          subsystems: [{ name: 'Kind', extra_selector: { kind: 'Kind' } }])
      end
      expect(built.panels.first.title).to eq('Kind SLI')
    end
  end

  describe '.add (validation)' do
    it 'requires a datasource' do
      expect { row_with { |r| Lib::RedSliGaugeStrip.add(r, datasource: nil, metric: 'm', subsystems: [{ name: 'a' }]) } }
        .to raise_error(ArgumentError, /RedSliGaugeStrip.*datasource/)
    end

    it 'requires a metric' do
      expect { row_with { |r| Lib::RedSliGaugeStrip.add(r, datasource: 'vm', metric: '', subsystems: [{ name: 'a' }]) } }
        .to raise_error(ArgumentError, /RedSliGaugeStrip.*metric/)
    end

    it 'rejects an empty subsystems array' do
      expect { row_with { |r| Lib::RedSliGaugeStrip.add(r, datasource: 'vm', metric: 'm', subsystems: []) } }
        .to raise_error(ArgumentError, /subsystems/)
    end

    it 'rejects a subsystem missing :name' do
      expect { row_with { |r| Lib::RedSliGaugeStrip.add(r, datasource: 'vm', metric: 'm', subsystems: [{ extra_selector: { kind: 'x' } }]) } }
        .to raise_error(ArgumentError, /needs :name/)
    end
  end
end
