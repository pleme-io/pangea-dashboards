# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/build_info_liveness'

# BuildInfoLiveness — the controller-up :stat + the controller-down signal,
# absorbed from breathe.rb (controller_up + Controller-down tile) and
# pangea_operator.rb (up{job}). Asserts the emitted PromQL text, the panel
# kind/width/presence, the liveness thresholds, and that the down signal is an
# absent() probe (the missing series IS the signal — never floored).
RSpec.describe Pangea::Dashboards::Library::BuildInfoLiveness do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe '.add' do
    it 'emits a max by(version)(build_info) liveness stat' do
      built = row_with do |r|
        Lib::BuildInfoLiveness.add(r, datasource: 'vm',
          build_info_metric: 'breathe_build_info', title: 'breathe')
      end
      p = built.panels.first
      expect(p.kind).to eq(:stat)
      expect(p.width).to eq(Theme.third)
      expect(p.height).to eq(Theme::STAT_H)
      expect(p.display_mode).to eq(:background)
      expect(p.title).to eq('breathe up')
      q = p.queries.first
      expect(q.expr).to eq('max by (version)(breathe_build_info)')
      expect(q.presence).to eq(:continuous)
      expect(q.legend_format).to eq('{{version}}')
    end

    it 'applies LIVENESS thresholds (red below 1, green at/above)' do
      built = row_with do |r|
        Lib::BuildInfoLiveness.add(r, datasource: 'vm', build_info_metric: 'op_build_info')
      end
      steps = built.panels.first.thresholds.steps
      expect(steps.map(&:color)).to eq(%w[red green])
      expect(steps.map(&:value)).to eq([nil, 1.0])
    end

    it 'scopes the up expr with a typed Hash selector + custom version label' do
      built = row_with do |r|
        Lib::BuildInfoLiveness.add(r, datasource: 'vm',
          build_info_metric: 'op_build_info', binary_selector: { binary: 'operator' },
          version_label: 'revision')
      end
      q = built.panels.first.queries.first
      expect(q.expr).to eq('max by (revision)(op_build_info{binary="operator"})')
      expect(q.legend_format).to eq('{{revision}}')
    end

    it 'requires a datasource + build_info_metric' do
      expect { row_with { |r| Lib::BuildInfoLiveness.add(r, datasource: nil, build_info_metric: 'x') } }
        .to raise_error(ArgumentError, /datasource/)
      expect { row_with { |r| Lib::BuildInfoLiveness.add(r, datasource: 'vm', build_info_metric: '') } }
        .to raise_error(ArgumentError, /build_info_metric/)
    end
  end

  describe '.down_signal' do
    it 'returns a StatusOverview signal as an absent() probe with warn: 1' do
      sig = Lib::BuildInfoLiveness.down_signal(build_info_metric: 'breathe_build_info')
      expect(sig[:name]).to eq('Controller down')
      expect(sig[:expr]).to eq('absent(breathe_build_info)')
      expect(sig[:warn]).to eq(1)
      expect(sig[:unit]).to eq('short')
      expect(sig[:desc]).to be_a(String)
    end

    it 'scopes the absent() probe with a typed selector + custom name' do
      sig = Lib::BuildInfoLiveness.down_signal(build_info_metric: 'op_build_info',
        binary_selector: { binary: 'operator' }, name: 'operator down')
      expect(sig[:name]).to eq('operator down')
      expect(sig[:expr]).to eq('absent(op_build_info{binary="operator"})')
    end

    it 'is NOT floored by Floor.zero (the missing series IS the signal)' do
      sig = Lib::BuildInfoLiveness.down_signal(build_info_metric: 'op_build_info')
      expect(Lib::Floor.zero(sig[:expr])).to eq(sig[:expr])
    end

    it 'feeds straight into StatusOverview as an event-driven defect tile' do
      sig = Lib::BuildInfoLiveness.down_signal(build_info_metric: 'op_build_info')
      built = row_with { |r| Lib::StatusOverview.add(r, datasource: 'vm', signals: [sig]) }
      p = built.panels.first
      expect(p.kind).to eq(:stat)
      expect(p.display_mode).to eq(:background)
      # StatusOverview floors via Floor.zero, which leaves absent() untouched.
      expect(p.queries.first.expr).to eq('absent(op_build_info)')
    end

    it 'requires a build_info_metric' do
      expect { Lib::BuildInfoLiveness.down_signal(build_info_metric: nil) }
        .to raise_error(ArgumentError, /build_info_metric/)
    end
  end
end
