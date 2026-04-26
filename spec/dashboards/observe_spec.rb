# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pangea::Resources::Dashboards#observe' do
  let(:synth) do
    Class.new do
      include Pangea::Resources::Dashboards
    end.new
  end

  it 'returns a Dashboard AST when render: false (default)' do
    result = { id: 'thing-1', name: 'thing' }
    ast = synth.observe(result) do
      title "Thing · #{result[:name]}"
      row 'r' do
        panel :p, kind: :stat do
          query 'A', %(metric{id="#{result[:id]}"}), datasource: 'vm'
        end
      end
    end
    expect(ast).to be_a(Pangea::Dashboards::Types::Dashboard)
    expect(ast.title).to eq('Thing · thing')
    panel = ast.rows.first.panels.first
    expect(panel.queries.first.expr).to eq('metric{id="thing-1"}')
  end

  it 'derives an id from the result hash' do
    ast = synth.observe(id: 'abc', name: 'n') do
      title 't'
      row 'r' do
        panel :p, kind: :stat do
          query 'A', 'm', datasource: 'vm'
        end
      end
    end
    expect(ast.id).to eq(:observe_abc)
  end
end
