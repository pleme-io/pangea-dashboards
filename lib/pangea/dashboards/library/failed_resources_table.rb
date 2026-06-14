# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The "which NAMED resource is broken" table, as a reusable atom. An
      # instant `:table` over `sum by(entity, ns)(failed_metric{sel}) > gt`
      # with a green→red threshold — it surfaces EXACTLY which entities are
      # failing, not an aggregate count. The load-bearing drill-down from
      # pangea_operator (magma_failed_by_template, drift_detail) and external-
      # secrets (not-ready objects). Distinct from TopNTable (ranking) — this
      # is the partial-failure roster filtered to the broken set.
      #
      #   row 'Failures' do
      #     Pangea::Dashboards::Library::FailedResourcesTable.add(
      #       self, datasource: 'vm', failed_metric: 'pangea_template_failed_resources',
      #       group_by: %w[schema template])
      #   end
      module FailedResourcesTable
        # failed_metric:      (req) a per-entity gauge/counter of failures
        # group_by:           (req) the identifying labels (entity, namespace…)
        # gt:                 threshold the sum must exceed to appear (default 0)
        # condition_selector: typed Hash/String matcher (e.g. a status label)
        # title:              panel title
        def self.add(row, datasource:, failed_metric:, group_by:, gt: 0,
                     condition_selector: nil, title: 'Failing resources')
          validate!(datasource: datasource, failed_metric: failed_metric, group_by: group_by)
          expr  = "sum#{Promql.by(group_by)}(#{failed_metric}#{Promql.braces(condition_selector)}) > #{gt}"
          pid   = :"failing_#{slug(failed_metric)}"
          # A resource that appears in this table IS failing — that's critical,
          # never a "warning". Green base, red the instant a value crosses gt.
          steps = [{ color: Theme::OK, value: nil }, { color: Theme::CRIT, value: (gt + 1).to_f }]
          row.panel pid, kind: :table, width: Theme.full, height: Theme::TABLE_H do
            title title
            description 'Each row is a resource currently failing. Empty = all healthy.'
            # event_driven floor not needed — an empty `> gt` table IS "all
            # healthy"; the absence of rows is the green state by construction.
            query 'A', expr, datasource: datasource, instant: true, presence: :event_driven
            threshold steps: steps
          end
        end

        def self.validate!(datasource:, failed_metric:, group_by:)
          raise ArgumentError, 'FailedResourcesTable: datasource: required' if blank?(datasource)
          raise ArgumentError, 'FailedResourcesTable: failed_metric: required' if blank?(failed_metric)
          raise ArgumentError, 'FailedResourcesTable: group_by must be a non-empty Array' \
            unless group_by.is_a?(Array) && !group_by.empty?
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :validate!, :blank?, :slug
      end
    end
  end
end
