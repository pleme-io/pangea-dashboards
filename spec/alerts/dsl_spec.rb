# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Alerts::DSL do
  describe 'AlertsBuilder' do
    it 'builds an Alerts AST with groups + rules' do
      builder = described_class::AlertsBuilder.new(id: :test_alerts)
      builder.instance_eval do
        namespace 'monitoring'
        labels(team: 'platform', cluster: 'rio')
        group 'secure-vpc', interval: '1m' do
          alert :rejected_high,
            expr: 'rate(aws_vpc_flow_log_rejects[5m]) > 100',
            for: '5m', severity: 'warning',
            summary: 'VPC rejecting flows',
            description: 'Sustained high reject rate',
            runbook_url: 'https://runbooks/secure-vpc'
        end
      end
      ast = builder.build
      expect(ast).to be_a(Pangea::Alerts::Types::Alerts)
      expect(ast.namespace).to eq('monitoring')
      expect(ast.labels).to eq('team' => 'platform', 'cluster' => 'rio')
      expect(ast.groups.size).to eq(1)
      group = ast.groups.first
      expect(group.name).to eq('secure-vpc')
      expect(group.interval).to eq('1m')
      rule = group.rules.first
      expect(rule.name).to eq(:rejected_high)
      expect(rule.severity).to eq('warning')
      expect(rule.for_).to eq('5m')
      expect(rule.annotations['summary']).to eq('VPC rejecting flows')
      expect(rule.annotations['description']).to eq('Sustained high reject rate')
      expect(rule.annotations['runbook_url']).to eq('https://runbooks/secure-vpc')
    end

    it 'rejects invalid severity at construction' do
      builder = described_class::AlertsBuilder.new(id: :bad)
      expect {
        builder.instance_eval do
          group 'g' do
            alert :a, expr: 'x', severity: 'panic'
          end
        end
      }.to raise_error(Dry::Struct::Error)
    end

    it 'rejects unknown options on alert' do
      builder = described_class::AlertsBuilder.new(id: :bad)
      expect {
        builder.instance_eval do
          group 'g' do
            alert :a, expr: 'x', severity: 'info', oops: true
          end
        end
      }.to raise_error(ArgumentError, /unknown options/)
    end
  end
end
