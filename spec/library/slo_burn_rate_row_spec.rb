# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/slo_burn_rate_row'

# Pangea::Dashboards::Library::SloBurnRateRow — the Google-SRE multi-window
# multi-burn SLO row. Builds a RowBuilder, runs .add, asserts on the emitted
# PromQL (burn formula, budget-remaining, SLI ratio), panel kind/width/presence,
# and the multi-burn thresholds.
RSpec.describe Pangea::Dashboards::Library::SloBurnRateRow do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  # The canonical happy-path row: 4 windows + budget-remaining + SLI ratio.
  let(:built) do
    row_with do |r|
      Lib::SloBurnRateRow.add(r, datasource: 'vm',
        sli_good_metric: 'sli_good_total', sli_total_metric: 'sli_total_total',
        objective: 0.999)
    end
  end

  it 'emits one burn-rate stat tile per window, plus budget + SLI panels' do
    # 4 windows (1h/6h/24h/72h) + budget-remaining stat + SLI timeseries = 6.
    expect(built.panels.size).to eq(6)
    burn = built.panels.select { |p| p.id.to_s.start_with?('slo_burn_') }
    expect(burn.size).to eq(4)
    expect(burn.map(&:id)).to eq(%i[slo_burn_1h slo_burn_6h slo_burn_24h slo_burn_72h])
    expect(burn.map(&:kind)).to all(eq(:stat))
    # event-driven, colour-flooded burn tiles that always render.
    expect(burn.map(&:display_mode)).to all(eq(:background))
    expect(burn.map { |p| p.queries.first.presence }).to all(eq(:event_driven))
    # uniform tile width across the strip of 4 (24/4 = 6).
    expect(burn.map(&:width)).to all(eq(Theme.tile_width(4)))
  end

  it 'builds the SRE burn formula (1 - good/total)/(1 - objective) inline per window' do
    fast = built.panels.find { |p| p.id == :slo_burn_1h }
    expect(fast.queries.first.expr).to eq(
      '(1 - (sum(rate(sli_good_total[1h])) / sum(rate(sli_total_total[1h])))) / 0.001 or vector(0)'
    )
    slow = built.panels.find { |p| p.id == :slo_burn_72h }
    expect(slow.queries.first.expr).to eq(
      '(1 - (sum(rate(sli_good_total[72h])) / sum(rate(sli_total_total[72h])))) / 0.001 or vector(0)'
    )
  end

  it 'applies the canonical multi-burn thresholds (>1 amber, >14.4 red) only on the fast window' do
    fast = built.panels.find { |p| p.id == :slo_burn_1h }
    # green base + amber at 1 + red at 14.4 (the page-now fast-burn multiplier).
    expect(fast.thresholds.steps.map(&:color)).to eq(%w[green orange red])
    expect(fast.thresholds.steps.map(&:value)).to eq([nil, 1.0, 14.4])
    # slower windows keep amber-only (a slow leak is a watch, not a page).
    slow = built.panels.find { |p| p.id == :slo_burn_24h }
    expect(slow.thresholds.steps.map(&:color)).to eq(%w[green orange])
    expect(slow.thresholds.steps.map(&:value)).to eq([nil, 1.0])
  end

  it 'emits an error-budget-remaining % stat over the budget_window with liveness thresholds' do
    rem = built.panels.find { |p| p.id == :slo_budget_remaining }
    expect(rem.kind).to eq(:stat)
    expect(rem.width).to eq(Theme.third)
    expect(rem.unit).to eq('percent')
    expect(rem.queries.first.expr).to eq(
      '100 * (1 - ((1 - (sum(rate(sli_good_total[30d])) / sum(rate(sli_total_total[30d])))) / 0.001))'
    )
    expect(rem.queries.first.presence).to eq(:continuous)
    # liveness: LOWER = worse (red below the ok floor, green at/above it).
    expect(rem.thresholds.steps.map(&:color)).to eq(%w[red green])
  end

  it 'emits the SLI ratio timeseries with the objective reference line' do
    sli = built.panels.find { |p| p.id == :slo_sli_ratio }
    expect(sli.kind).to eq(:timeseries)
    expect(sli.width).to eq(Theme.two_thirds)
    expect(sli.max).to eq(100)
    expect(sli.queries.first.expr).to eq(
      '100 * (sum(rate(sli_good_total[30d])) / sum(rate(sli_total_total[30d])))'
    )
    # the objective drawn as a flat 99.9% reference line.
    expect(sli.queries[1].legend_format).to eq('objective 99.9%')
    expect(sli.queries[1].expr).to include('99.9')
  end

  it 'applies a typed Hash selector to BOTH the good and total counters' do
    built = row_with do |r|
      Lib::SloBurnRateRow.add(r, datasource: 'vm',
        sli_good_metric: 'reqs_total', sli_total_metric: 'reqs_total',
        objective: 0.99, windows: %w[5m], selector: { route: '/checkout', code: /2../ })
    end
    burn = built.panels.find { |p| p.id == :slo_burn_5m }
    # Hash → =, Regexp → =~; applied inside BOTH rate() bodies.
    expect(burn.queries.first.expr).to eq(
      '(1 - (sum(rate(reqs_total{route="/checkout",code=~"2.."}[5m])) / ' \
      'sum(rate(reqs_total{route="/checkout",code=~"2.."}[5m])))) / 0.01 or vector(0)'
    )
  end

  it 'rejects an out-of-range objective' do
    expect {
      row_with do |r|
        Lib::SloBurnRateRow.add(r, datasource: 'vm',
          sli_good_metric: 'g_total', sli_total_metric: 't_total', objective: 1.5)
      end
    }.to raise_error(ArgumentError, /objective/)
  end

  it 'requires the good + total metrics + a datasource' do
    expect {
      row_with { |r| Lib::SloBurnRateRow.add(r, datasource: nil, sli_good_metric: 'g', sli_total_metric: 't') }
    }.to raise_error(ArgumentError, /datasource/)
    expect {
      row_with { |r| Lib::SloBurnRateRow.add(r, datasource: 'vm', sli_good_metric: '', sli_total_metric: 't') }
    }.to raise_error(ArgumentError, /sli_good_metric/)
  end
end
