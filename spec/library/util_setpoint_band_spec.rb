# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/util_setpoint_band'

# UtilSetpointBand — ONE timeseries plotting a util_ratio series against an
# overlaid setpoint line (the green homeostasis band). Builds a RowBuilder,
# runs .add, and asserts on the emitted PromQL + panel shape.
RSpec.describe Pangea::Dashboards::Library::UtilSetpointBand do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe '.add (happy path)' do
    let(:panel) do
      built = row_with do |r|
        Lib::UtilSetpointBand.add(r, datasource: 'vm',
          util_metric: 'breathe_band_util_ratio',
          setpoint_metric: 'breathe_band_setpoint_ratio',
          dim: { resource: 'memory' })
      end
      built.panels.first
    end

    it 'emits ONE timeseries panel at half width / TS height' do
      expect(panel.kind).to eq(:timeseries)
      expect(panel.width).to eq(Theme.half)
      expect(panel.height).to eq(Theme::TS_H)
    end

    it 'frames the panel as a 0–1 percentunit ratio band' do
      expect(panel.unit).to eq('percentunit')
      expect(panel.min).to eq(0)
      expect(panel.max).to eq(1)
    end

    it 'emits query A = the dim-folded util series, legend by labels, continuous' do
      a = panel.queries.find { |q| q.ref == 'A' }
      expect(a.expr).to eq('breathe_band_util_ratio{resource="memory"}')
      expect(a.legend_format).to eq('{{namespace}}/{{name}}')
      expect(a.presence).to eq(:continuous)
    end

    it 'emits query B = avg(setpoint) overlay, legend "setpoint", continuous' do
      b = panel.queries.find { |q| q.ref == 'B' }
      expect(b.expr).to eq('avg(breathe_band_setpoint_ratio{resource="memory"})')
      expect(b.legend_format).to eq('setpoint')
      expect(b.presence).to eq(:continuous)
    end

    it 'never floors either gauge series with `or vector(0)`' do
      expect(panel.queries.map(&:expr).join).not_to include('vector(0)')
    end

    it 'derives a util-vs-setpoint title and a stable slugged id' do
      expect(panel.title).to eq('breathe band · util vs setpoint')
      expect(panel.id).to eq(:util_setpoint_breathe_band_util_ratio)
    end
  end

  describe '.add (typed-selector cases)' do
    it 'folds a Regexp dim into BOTH selectors as a =~ matcher' do
      built = row_with do |r|
        Lib::UtilSetpointBand.add(r, datasource: 'vm',
          util_metric: 'storage_util_ratio', setpoint_metric: 'storage_setpoint_ratio',
          dim: { pvc: /data-.*/ })
      end
      exprs = built.panels.first.queries.map(&:expr)
      expect(exprs[0]).to eq('storage_util_ratio{pvc=~"data-.*"}')
      expect(exprs[1]).to eq('avg(storage_setpoint_ratio{pvc=~"data-.*"})')
    end

    it 'honours legend_labels / unit / min / max / title overrides' do
      built = row_with do |r|
        Lib::UtilSetpointBand.add(r, datasource: 'vm',
          util_metric: 'cpu_util_ratio', setpoint_metric: 'cpu_setpoint_ratio',
          dim: { resource: 'cpu' }, legend_labels: '{{pod}}',
          unit: 'percent', min: 0, max: 100, title: 'CPU homeostasis')
      end
      p = built.panels.first
      expect(p.title).to eq('CPU homeostasis')
      expect(p.unit).to eq('percent')
      expect(p.max).to eq(100)
      expect(p.queries.find { |q| q.ref == 'A' }.legend_format).to eq('{{pod}}')
    end
  end

  describe '.add (validation)' do
    it 'rejects a missing setpoint_metric' do
      expect do
        row_with do |r|
          Lib::UtilSetpointBand.add(r, datasource: 'vm',
            util_metric: 'u_ratio', setpoint_metric: '', dim: { resource: 'memory' })
        end
      end.to raise_error(ArgumentError, /UtilSetpointBand: setpoint_metric/)
    end

    it 'rejects an empty dim selector' do
      expect do
        row_with do |r|
          Lib::UtilSetpointBand.add(r, datasource: 'vm',
            util_metric: 'u_ratio', setpoint_metric: 's_ratio', dim: {})
        end
      end.to raise_error(ArgumentError, /UtilSetpointBand: dim/)
    end
  end
end
