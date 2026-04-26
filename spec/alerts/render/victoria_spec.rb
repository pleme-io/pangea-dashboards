# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Alerts::Render::Victoria do
  let(:alerts) do
    Pangea::Alerts::DSL::AlertsBuilder.new(id: :rio_alerts).tap do |b|
      b.instance_eval do
        namespace 'monitoring'
        labels(cluster: 'rio')
        group 'rio-spine', interval: '1m' do
          alert :pod_down,
            expr: 'kube_deployment_status_replicas_available == 0',
            for: '5m', severity: 'critical',
            summary: 'Deployment has zero replicas'
        end
      end
    end.build
  end

  it 'emits an operator.victoriametrics.com VMRule manifest hash' do
    out = described_class.render(alerts)
    expect(out['apiVersion']).to eq('operator.victoriametrics.com/v1beta1')
    expect(out['kind']).to eq('VMRule')
    expect(out['metadata']['name']).to eq('rio-alerts')
    expect(out['metadata']['namespace']).to eq('monitoring')
    expect(out['metadata']['labels']).to eq('cluster' => 'rio')
  end

  it 'emits each rule with severity baked into labels' do
    out = described_class.render(alerts)
    rule = out['spec']['groups'].first['rules'].first
    expect(rule['alert']).to eq('PodDown')        # CamelCased from :pod_down
    expect(rule['expr']).to eq('kube_deployment_status_replicas_available == 0')
    expect(rule['for']).to eq('5m')
    expect(rule['labels']).to eq('severity' => 'critical')
    expect(rule['annotations']).to include('summary' => 'Deployment has zero replicas')
  end

  it 'accepts a name_override for the manifest metadata.name' do
    out = described_class.render(alerts, name_override: 'rio-alerts-prod')
    expect(out['metadata']['name']).to eq('rio-alerts-prod')
  end
end
