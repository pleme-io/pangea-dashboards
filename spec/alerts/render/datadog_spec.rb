# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Alerts::Render::Datadog do
  it 'emits one datadog_monitor entry per AlertRule with severity tag + priority' do
    alerts = Pangea::Alerts::DSL::AlertsBuilder.new(id: :test).tap do |b|
      b.instance_eval do
        labels(service: 'secure-vpc')
        group 'sv' do
          alert :rejected_high,
            expr: 'rate(aws_vpc_flow_log_rejects[5m]) > 100',
            for: '5m', severity: 'warning',
            summary: 'VPC rejecting flows',
            dd_query: 'avg(last_5m):sum:aws.vpc.flow_log.rejects{*}.as_rate() > 100'
        end
      end
    end.build

    rendered = described_class.render(alerts)
    expect(rendered.size).to eq(1)
    e = rendered.first
    expect(e[:resource_id]).to eq(:test_rejected_high)
    expect(e[:attrs][:type]).to eq('metric alert')
    expect(e[:attrs][:query]).to eq('avg(last_5m):sum:aws.vpc.flow_log.rejects{*}.as_rate() > 100')
    expect(e[:attrs][:tags]).to include('alert-group:sv', 'severity:warning', 'service:secure-vpc')
    expect(e[:attrs][:priority]).to eq(3)
  end

  it 'raises UntranslatableExprError when expr has PromQL-only syntax + no dd_query' do
    alerts = Pangea::Alerts::DSL::AlertsBuilder.new(id: :bad).tap do |b|
      b.instance_eval do
        group 'g' do
          alert :a, expr: 'rate(my_metric[5m]) > 1', severity: 'warning'
        end
      end
    end.build
    expect {
      described_class.render(alerts)
    }.to raise_error(Pangea::Alerts::UntranslatableExprError, /PromQL-only syntax/)
  end
end
