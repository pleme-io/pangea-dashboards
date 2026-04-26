# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Dashboard AST splice helpers' do
  let(:base) { canonical_dashboard }
  let(:extra_row) do
    Pangea::Dashboards::Types::Row.new(
      title: 'extras',
      panels: [
        Pangea::Dashboards::Types::Panel.new(
          id: :extra_p, kind: :stat, title: 'extra',
          queries: [Pangea::Dashboards::Types::Query.new(
            ref: 'A', expr: 'foo', datasource_uid: 'vm'
          )]
        )
      ]
    )
  end

  describe '#append_row' do
    it 'returns a new Dashboard with the row appended' do
      out = base.append_row(extra_row)
      expect(out.rows.last.title).to eq('extras')
      expect(out.rows.size).to eq(base.rows.size + 1)
      expect(base.rows.size).to eq(2)  # original is unmodified
    end
  end

  describe '#prepend_row' do
    it 'returns a new Dashboard with the row prepended' do
      out = base.prepend_row(extra_row)
      expect(out.rows.first.title).to eq('extras')
    end
  end

  describe '#insert_row' do
    it 'inserts at an integer index' do
      out = base.insert_row(extra_row, at: 1)
      expect(out.rows[1].title).to eq('extras')
    end

    it 'inserts at a row title' do
      out = base.insert_row(extra_row, at: 'storage')
      expect(out.rows[1].title).to eq('extras')
      expect(out.rows[2].title).to eq('storage')
    end

    it 'raises on unknown title' do
      expect { base.insert_row(extra_row, at: 'nope') }
        .to raise_error(ArgumentError, /no row titled/)
    end
  end

  describe '#with_rows' do
    it 'replaces rows with the block return value' do
      out = base.with_rows { |rs| rs.reverse }
      expect(out.rows.map(&:title)).to eq(%w[storage overview])
    end
  end

  describe '#splice' do
    let(:other) do
      Pangea::Dashboards::DSL::DashboardBuilder.new(id: :other).tap do |b|
        b.instance_eval do
          row 'spliced' do
            panel :p, kind: :stat do
              query 'A', 'spliced_metric', datasource: 'vm'
            end
          end
        end
      end.build
    end

    it 'splices :after a target row' do
      out = base.splice(other, position: :after, target: 'overview')
      expect(out.rows.map(&:title)).to eq(%w[overview spliced storage])
    end

    it 'splices :before a target row' do
      out = base.splice(other, position: :before, target: 'storage')
      expect(out.rows.map(&:title)).to eq(%w[overview spliced storage])
    end

    it ':append concatenates' do
      out = base.splice(other, position: :append)
      expect(out.rows.map(&:title)).to eq(%w[overview storage spliced])
    end
  end

  describe '#+' do
    it 'concatenates two dashboards merging tags + variables + annotations' do
      other = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :other).tap do |b|
        b.instance_eval do
          tags 'extra'
          row 'r2' do
            panel :p, kind: :stat do
              query 'A', 'm2', datasource: 'vm'
            end
          end
        end
      end.build
      out = base + other
      expect(out.rows.map(&:title)).to eq(%w[overview storage r2])
      expect(out.tags).to include('rio', 'test', 'extra')
    end
  end
end
