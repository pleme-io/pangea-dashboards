# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/shadow_live_posture_row'

# ShadowLivePostureRow — enrolled / live / shadow counts from a dry_run gauge.
# Builds a RowBuilder, runs the component, asserts on the emitted PromQL +
# panel shape (kind/width/presence/threshold colour).
RSpec.describe Pangea::Dashboards::Library::ShadowLivePostureRow do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  describe '.add (happy path)' do
    let(:built) do
      row_with { |r| Lib::ShadowLivePostureRow.add(r, datasource: 'vm', dry_run_metric: 'breathe_band_dry_run') }
    end

    it 'emits exactly three third-width :stat tiles' do
      expect(built.panels.size).to eq(3)
      expect(built.panels.map(&:kind)).to all(eq(:stat))
      expect(built.panels.map(&:width)).to all(eq(Theme.tile_width(3)))
      expect(built.panels.map(&:height)).to all(eq(Theme::STAT_H))
    end

    it 'titles the strip enrolled / Live / Shadow' do
      expect(built.panels.map(&:title)).to eq(['Fleet posture (enrolled)', 'Live', 'Shadow'])
    end

    it 'counts the whole population, the live subset (== 0) and the shadow subset (== 1), all floored' do
      enrolled, live, shadow = built.panels
      expect(enrolled.queries.first.expr).to eq('count(breathe_band_dry_run) or vector(0)')
      expect(live.queries.first.expr).to eq('count(breathe_band_dry_run == 0) or vector(0)')
      expect(shadow.queries.first.expr).to eq('count(breathe_band_dry_run == 1) or vector(0)')
    end

    it 'marks every count event_driven (an empty subset is a true 0)' do
      expect(built.panels.map { |p| p.queries.first.presence }).to all(eq(:event_driven))
    end

    it 'paints each tile its posture colour via a single absolute threshold step (value-only)' do
      enrolled, live, shadow = built.panels
      expect(enrolled.thresholds.steps.map(&:color)).to eq([Theme::NEUTRAL])
      expect(live.thresholds.steps.map(&:color)).to eq(['blue'])
      expect(shadow.thresholds.steps.map(&:color)).to eq(['green'])
      expect(built.panels.map(&:display_mode)).to all(eq(:value))
    end
  end

  describe '.add (typed selector + colour overrides)' do
    let(:built) do
      row_with do |r|
        Lib::ShadowLivePostureRow.add(r, datasource: 'vm', dry_run_metric: 'mig_observe',
          dim_selector: { dimension: 'memory', tier: %w[hot warm] },
          live_color: 'red', shadow_color: 'yellow')
      end
    end

    it 'threads the typed Hash selector (exact → =, Array → =~) through every count' do
      built.panels.each do |p|
        expect(p.queries.first.expr).to include('mig_observe{dimension="memory",tier=~"hot|warm"}')
      end
    end

    it 'still floors and still distinguishes == 0 (live) from == 1 (shadow)' do
      _, live, shadow = built.panels
      expect(live.queries.first.expr).to eq('count(mig_observe{dimension="memory",tier=~"hot|warm"} == 0) or vector(0)')
      expect(shadow.queries.first.expr).to eq('count(mig_observe{dimension="memory",tier=~"hot|warm"} == 1) or vector(0)')
    end

    it 'honours the live/shadow colour overrides' do
      _, live, shadow = built.panels
      expect(live.thresholds.steps.map(&:color)).to eq(['red'])
      expect(shadow.thresholds.steps.map(&:color)).to eq(['yellow'])
    end
  end

  describe '.add (validation)' do
    it 'requires a datasource' do
      expect { row_with { |r| Lib::ShadowLivePostureRow.add(r, datasource: nil, dry_run_metric: 'x') } }
        .to raise_error(ArgumentError, /ShadowLivePostureRow: datasource/)
    end

    it 'requires a dry_run_metric' do
      expect { row_with { |r| Lib::ShadowLivePostureRow.add(r, datasource: 'vm', dry_run_metric: '') } }
        .to raise_error(ArgumentError, /ShadowLivePostureRow: dry_run_metric/)
    end
  end
end
