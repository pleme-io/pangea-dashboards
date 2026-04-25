# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Dashboards::DSL do
  describe 'DashboardBuilder' do
    it 'builds a simple dashboard with rows + panels' do
      d = canonical_dashboard
      expect(d).to be_a(Pangea::Dashboards::Types::Dashboard)
      expect(d.title).to eq('canary')
      expect(d.rows.size).to eq(2)
    end

    it 'derives uid from id when not specified' do
      builder = described_class::DashboardBuilder.new(id: :rio_lareira_services)
      builder.instance_eval do
        title 'rio · lareira services'
      end
      d = builder.build
      expect(d.uid).to eq('rio-lareira-services')
    end

    it 'rejects a panel with no datasource on its query' do
      builder = described_class::DashboardBuilder.new(id: :bad)
      expect {
        builder.instance_eval do
          row 'r' do
            panel :p, kind: :stat do
              query 'A', 'up'   # missing datasource:
            end
          end
        end
      }.to raise_error(ArgumentError, /datasource/)
    end
  end

  describe 'PanelBuilder' do
    it 'derives default width from kind' do
      d = canonical_dashboard
      pod_count = d.rows.first.panels.find { |p| p.id == :pod_count }
      expect(pod_count.width).to eq(6)              # stat default

      restarts = d.rows.first.panels.find { |p| p.id == :restarts_1h }
      expect(restarts.width).to eq(12)              # timeseries default
    end

    it 'captures thresholds + queries in declared order' do
      d = canonical_dashboard
      stat = d.rows.first.panels.first
      expect(stat.thresholds.steps.map(&:color)).to eq(%w[green yellow red])
      expect(stat.queries.map(&:ref)).to eq(['A'])
    end
  end
end
