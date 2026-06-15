# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/floor_ceiling_envelope'

# FloorCeilingEnvelope — ONE timeseries plotting current_limit (A) riding
# inside [floor (B), ceiling (C)], legends "limit/floor/ceiling {{labels}}".
# Builds a RowBuilder, runs the component, asserts the emitted PromQL +
# panel shape (kind/width/height/presence) and the legends.
RSpec.describe Pangea::Dashboards::Library::FloorCeilingEnvelope do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe 'happy path — three series on one timeseries' do
    let(:built) do
      row_with do |r|
        Lib::FloorCeilingEnvelope.add(r, datasource: 'vm',
          limit_metric:   'breathe_band_current_limit_bytes',
          floor_metric:   'breathe_band_floor_bytes',
          ceiling_metric: 'breathe_band_ceiling_bytes',
          dim: { resource: 'memory' })
      end
    end

    it 'emits exactly ONE half-width timeseries panel' do
      expect(built.panels.size).to eq(1)
      p = built.panels.first
      expect(p.kind).to eq(:timeseries)
      expect(p.width).to eq(Theme.half)
      expect(p.height).to eq(Theme::TS_H)
    end

    it 'plots A=limit, B=floor, C=ceiling in that order' do
      p = built.panels.first
      expect(p.queries.map(&:ref)).to eq(%w[A B C])
      expect(p.queries.map(&:expr)).to eq([
        'breathe_band_current_limit_bytes{resource="memory"}',
        'breathe_band_floor_bytes{resource="memory"}',
        'breathe_band_ceiling_bytes{resource="memory"}'
      ])
    end

    it 'legends each series "limit/floor/ceiling {{namespace}}/{{name}}" by default' do
      p = built.panels.first
      expect(p.queries.map(&:legend_format)).to eq([
        'limit {{namespace}}/{{name}}',
        'floor {{namespace}}/{{name}}',
        'ceiling {{namespace}}/{{name}}'
      ])
    end

    it 'marks every series continuous (gauge state — NEVER floored to vector(0))' do
      p = built.panels.first
      expect(p.queries.map(&:presence)).to all(eq(:continuous))
      expect(p.queries.map(&:expr)).to all(satisfy { |e| !e.include?('vector(0)') })
    end

    it 'defaults unit to bytes, min to 0, and derives a title' do
      p = built.panels.first
      expect(p.unit).to eq('bytes')
      expect(p.min).to eq(0)
      expect(p.title).to eq('breathe band envelope')
    end
  end

  describe 'typed-selector + overrides' do
    it 'applies a Regexp/Array dim selector as a =~ matcher to all three series' do
      built = row_with do |r|
        Lib::FloorCeilingEnvelope.add(r, datasource: 'vm',
          limit_metric:   'pvc_carved_bytes',
          floor_metric:   'pvc_floor_bytes',
          ceiling_metric: 'pvc_ceiling_bytes',
          dim: { namespace: %w[blue green] })
      end
      p = built.panels.first
      expect(p.queries.map(&:expr)).to eq([
        'pvc_carved_bytes{namespace=~"blue|green"}',
        'pvc_floor_bytes{namespace=~"blue|green"}',
        'pvc_ceiling_bytes{namespace=~"blue|green"}'
      ])
    end

    it 'honours custom legend_labels, unit, and title' do
      built = row_with do |r|
        Lib::FloorCeilingEnvelope.add(r, datasource: 'vm',
          limit_metric:   'cpu_limit_millicores',
          floor_metric:   'cpu_floor_millicores',
          ceiling_metric: 'cpu_ceiling_millicores',
          dim: { pod: 'web' }, legend_labels: '{{pod}}', unit: 'short', title: 'CPU envelope')
      end
      p = built.panels.first
      expect(p.title).to eq('CPU envelope')
      expect(p.unit).to eq('short')
      expect(p.queries.map(&:legend_format)).to eq(['limit {{pod}}', 'floor {{pod}}', 'ceiling {{pod}}'])
    end

    it 'drops the suffix when legend_labels is blank' do
      built = row_with do |r|
        Lib::FloorCeilingEnvelope.add(r, datasource: 'vm',
          limit_metric: 'a', floor_metric: 'b', ceiling_metric: 'c',
          dim: nil, legend_labels: '')
      end
      p = built.panels.first
      # nil dim ⇒ no braces; blank legend ⇒ bare role labels.
      expect(p.queries.map(&:expr)).to eq(%w[a b c])
      expect(p.queries.map(&:legend_format)).to eq(%w[limit floor ceiling])
    end
  end

  describe 'breathability overlay — optional usage_metric' do
    let(:built) do
      row_with do |r|
        Lib::FloorCeilingEnvelope.add(r, datasource: 'vm',
          limit_metric:   'breathe_band_current_limit',
          floor_metric:   'breathe_band_floor',
          ceiling_metric: 'breathe_band_ceiling',
          usage_metric:   'breathe_band_used',
          dim: { name: 'arc-runner', dim: 'memory' }, legend_labels: '{{name}}')
      end
    end

    it 'prepends the usage series U (the real workload riding inside the band)' do
      p = built.panels.first
      expect(p.queries.map(&:ref)).to eq(%w[U A B C])
      expect(p.queries.first.expr).to eq('breathe_band_used{name="arc-runner",dim="memory"}')
      expect(p.queries.map(&:legend_format)).to eq([
        'used {{name}}', 'limit {{name}}', 'floor {{name}}', 'ceiling {{name}}'
      ])
      # usage shares the band dim selector + stays continuous (gauge, never floored).
      expect(p.queries.map(&:presence)).to all(eq(:continuous))
    end

    it 'omitting usage_metric keeps the classic 3-series envelope (byte-unchanged)' do
      plain = row_with do |r|
        Lib::FloorCeilingEnvelope.add(r, datasource: 'vm',
          limit_metric: 'a', floor_metric: 'b', ceiling_metric: 'c', dim: nil)
      end
      expect(plain.panels.first.queries.map(&:ref)).to eq(%w[A B C])
    end
  end

  describe 'validation' do
    it 'requires a datasource' do
      expect { row_with { |r| Lib::FloorCeilingEnvelope.add(r, datasource: nil,
        limit_metric: 'a', floor_metric: 'b', ceiling_metric: 'c', dim: {}) } }
        .to raise_error(ArgumentError, /FloorCeilingEnvelope.*datasource/)
    end

    it 'requires each of limit/floor/ceiling metric' do
      expect { row_with { |r| Lib::FloorCeilingEnvelope.add(r, datasource: 'vm',
        limit_metric: '', floor_metric: 'b', ceiling_metric: 'c', dim: {}) } }
        .to raise_error(ArgumentError, /limit_metric/)
      expect { row_with { |r| Lib::FloorCeilingEnvelope.add(r, datasource: 'vm',
        limit_metric: 'a', floor_metric: nil, ceiling_metric: 'c', dim: {}) } }
        .to raise_error(ArgumentError, /floor_metric/)
      expect { row_with { |r| Lib::FloorCeilingEnvelope.add(r, datasource: 'vm',
        limit_metric: 'a', floor_metric: 'b', ceiling_metric: '  ', dim: {}) } }
        .to raise_error(ArgumentError, /ceiling_metric/)
    end
  end
end
