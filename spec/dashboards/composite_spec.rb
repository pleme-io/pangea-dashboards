# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Dashboards::Composite do
  it 'concatenates rows from multiple dashboards in declared order' do
    a = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :a).tap do |b|
      b.instance_eval do
        title 'A'
        row 'a-row' do
          panel :ap, kind: :stat do
            query 'A', 'a_metric', datasource: 'vm'
          end
        end
      end
    end.build

    b = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :b).tap do |bb|
      bb.instance_eval do
        title 'B'
        row 'b-row' do
          panel :bp, kind: :stat do
            query 'A', 'b_metric', datasource: 'vm'
          end
        end
      end
    end.build

    composed = described_class.compose(
      id: :both, title: 'Both', uid: 'both',
      dashboards: [a, b]
    )
    expect(composed.rows.map(&:title)).to eq(%w[a-row b-row])
    expect(composed.title).to eq('Both')
    expect(composed.uid).to eq('both')
  end
end
