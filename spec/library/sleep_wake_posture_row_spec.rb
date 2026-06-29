# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/sleep_wake_posture_row'

# SleepWakePostureRow — enrolled/asleep/awake floored counts + a time-at-rest %.
# The scale-to-zero analog of ShadowLivePostureRow (value-coloured posture, not
# defects).
RSpec.describe Pangea::Dashboards::Library::SleepWakePostureRow do
  Lib   = Pangea::Dashboards::Library unless defined?(Lib)
  Theme = Pangea::Dashboards::Theme   unless defined?(Theme)

  def row_with(&blk)
    r = Pangea::Dashboards::DSL::RowBuilder.new('test')
    blk.call(r)
    r.build
  end

  let(:built) do
    row_with do |r|
      Lib::SleepWakePostureRow.add(r, datasource: 'vm',
        replica_metric: 'kube_deployment_status_replicas',
        selector: { namespace: 'apps' }, rest_window: '24h')
    end
  end

  it 'emits four tiles: enrolled, asleep, awake, time-at-rest' do
    expect(built.panels.size).to eq(4)
    expect(built.panels.map(&:title)).to eq([
      'Workloads (enrolled)', 'Asleep', 'Awake', 'Time at rest (24h)'
    ])
    expect(built.panels.map(&:kind)).to all(eq(:stat))
  end

  it 'partitions the population with floored == 0 and > 0 counts, scoped by the selector' do
    enrolled, asleep, awake = built.panels[0..2]
    expect(enrolled.queries.first.expr).to eq('count(kube_deployment_status_replicas{namespace="apps"}) or vector(0)')
    expect(asleep.queries.first.expr).to eq('count(kube_deployment_status_replicas{namespace="apps"} == 0) or vector(0)')
    expect(awake.queries.first.expr).to eq('count(kube_deployment_status_replicas{namespace="apps"} > 0) or vector(0)')
    expect([enrolled, asleep, awake].map { |p| p.queries.first.presence }).to all(eq(:event_driven))
  end

  it 'posture tiles are value-coloured with fixed brand colours (NOT defect-flooded)' do
    enrolled, asleep, awake = built.panels[0..2]
    expect([enrolled, asleep, awake].map(&:display_mode)).to all(eq(:value))
    expect(enrolled.thresholds.steps.first.color).to eq(Theme::NEUTRAL)
    expect(asleep.thresholds.steps.first.color).to eq('green')
    expect(awake.thresholds.steps.first.color).to eq('blue')
  end

  it 'time-at-rest is a fraction over avg_over_time(== bool 0), liveness-coloured' do
    rest = built.panels.last
    expect(rest.unit).to eq('percentunit')
    expect(rest.queries.first.expr).to eq(
      'avg(avg_over_time((kube_deployment_status_replicas{namespace="apps"} == bool 0)[24h:]))'
    )
    expect(rest.queries.first.presence).to eq(:continuous)
    # liveness: a LOW rest fraction is the defect (red below ok, green at/above)
    expect(rest.thresholds.steps.map(&:color)).to eq(%w[red green])
  end

  it 'requires datasource + replica_metric' do
    expect { row_with { |r| Lib::SleepWakePostureRow.add(r, datasource: '', replica_metric: 'r') } }
      .to raise_error(ArgumentError, /datasource/)
    expect { row_with { |r| Lib::SleepWakePostureRow.add(r, datasource: 'vm', replica_metric: nil) } }
      .to raise_error(ArgumentError, /replica_metric/)
  end
end
