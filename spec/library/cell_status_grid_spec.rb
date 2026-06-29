# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/cell_status_grid'

# CellStatusGrid — a strip of colour-flooded :stat tiles, one per hand-listed
# member, each reading a %{member}-substituted defect score, floored + defect-
# coloured. Asserts the emitted PromQL substitution + panel shape.
RSpec.describe Pangea::Dashboards::Library::CellStatusGrid do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  let(:built) do
    row_with do |r|
      Lib::CellStatusGrid.add(r, datasource: 'vm', topology_label: 'cell',
        members: %w[cell-a cell-b cell-c],
        score_expr: 'count(up{cell="%{member}"} == 0)', warn: 1, crit: 3)
    end
  end

  it 'emits one colour-flooded :stat tile per member' do
    expect(built.panels.size).to eq(3)
    expect(built.panels.map(&:kind)).to all(eq(:stat))
    expect(built.panels.map(&:display_mode)).to all(eq(:background))
  end

  it 'substitutes %{member} into the score expr and floors it to a lit 0' do
    a = built.panels.first
    expect(a.queries.first.expr).to eq('count(up{cell="cell-a"} == 0) or vector(0)')
    expect(a.queries.first.presence).to eq(:event_driven)
    expect(a.title).to eq('cell-a')
  end

  it 'applies the defect thresholds (warn amber / crit red)' do
    a = built.panels.first
    steps = a.thresholds.steps
    expect(steps.map(&:color)).to eq(%w[green orange red])
    expect(steps.map(&:value)).to eq([nil, 1.0, 3.0])
  end

  it 'gives each tile a uniform width for the grid' do
    expect(built.panels.map(&:width).uniq).to eq([Theme.tile_width(3)])
  end

  it 'requires datasource, topology_label, members, and a %{member} score expr' do
    expect { row_with { |r| Lib::CellStatusGrid.add(r, datasource: '', topology_label: 'cell',
      members: %w[a], score_expr: '%{member}') } }.to raise_error(ArgumentError, /datasource/)
    expect { row_with { |r| Lib::CellStatusGrid.add(r, datasource: 'vm', topology_label: 'cell',
      members: [], score_expr: '%{member}') } }.to raise_error(ArgumentError, /members/)
    expect { row_with { |r| Lib::CellStatusGrid.add(r, datasource: 'vm', topology_label: 'cell',
      members: %w[a], score_expr: 'count(up)') } }.to raise_error(ArgumentError, /%\{member\}/)
  end
end
