# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Alerts::Render::Prometheus do
  let(:alerts) do
    Pangea::Alerts::DSL::AlertsBuilder.new(id: :rio_alerts).tap do |b|
      b.instance_eval do
        namespace 'monitoring'
        labels(cluster: 'rio')
        group 'storage' do
          alert :pod_oom,
            expr: 'rate(container_memory_oom_kill_total[5m]) > 0',
            for: '2m', severity: 'critical',
            summary: 'Container OOM-killed',
            dd_query: 'avg(last_5m):sum:container.memory.oom_kill{*}.as_rate() > 0'
        end
      end
    end.build
  end

  it 'reuses the Victoria render shape and swaps apiVersion + kind' do
    rendered = described_class.render(alerts)
    expect(rendered['apiVersion']).to eq('monitoring.coreos.com/v1')
    expect(rendered['kind']).to eq('PrometheusRule')
    expect(rendered['metadata']['namespace']).to eq('monitoring')
    expect(rendered['metadata']['name']).to eq('rio-alerts')
    expect(rendered['spec']['groups'].first['name']).to eq('storage')
    expect(rendered['spec']['groups'].first['rules'].first['alert']).to eq('PodOom')
  end

  it 'preserves labels + annotations + for from the AST' do
    rendered = described_class.render(alerts)
    rule = rendered['spec']['groups'].first['rules'].first
    expect(rule['for']).to eq('2m')
    expect(rule['labels']['severity']).to eq('critical')
    expect(rule['annotations']['summary']).to eq('Container OOM-killed')
  end
end
