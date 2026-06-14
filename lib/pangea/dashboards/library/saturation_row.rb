# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'

module Pangea
  module Dashboards
    module Library
      # The canonical USE row — Utilization, Saturation, Errors — for any
      # resource envelope. Generalises the host CPU/mem/disk rows (node_host),
      # the vmagent pending backlog (victoria_metrics_health), the vector
      # buffer fullness (vector_pipeline), and any controller workqueue. USE
      # resources are heterogeneous (a %, a queue depth, a byte count) so this
      # composite takes EXPRS, not metric names — the author supplies the
      # utilization ratio and the saturation/backlog measure; the component
      # owns the consistent layout, thresholds, and the error floor.
      #
      #   row 'CPU' do
      #     Pangea::Dashboards::Library::SaturationRow.add(
      #       self, datasource: 'vm', title: 'CPU',
      #       util_expr: '100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))',
      #       saturation_expr: 'avg(node_load1) / count(node_cpu_seconds_total{mode="idle"})')
      #   end
      module SaturationRow
        # util_expr:        (req) a 0–100 (or 0–1) utilization expression
        # saturation_expr:  (req) queue-depth / backlog / load measure
        # errors_expr:      optional resource-error rate (floored)
        # util_warn/crit:   utilization thresholds (default 70 / 90)
        # util_unit:        'percent' (default) | 'percentunit'
        # saturation_unit:  'short' (default) | 'bytes' | …
        # title:            the resource name (titles all three panels)
        def self.add(row, datasource:, util_expr:, saturation_expr:, errors_expr: nil,
                     util_warn: 70, util_crit: 90, util_unit: 'percent',
                     saturation_unit: 'short', title: 'Resource')
          validate!(datasource: datasource, util_expr: util_expr, saturation_expr: saturation_expr)
          width = errors_expr ? Theme.third : Theme.half
          umax  = util_unit == 'percentunit' ? 1 : 100
          usteps = Theme.defect_steps(warn: util_warn, crit: util_crit)
          sl = slug(title)

          row.panel :"sat_util_#{sl}", kind: :timeseries, width: width, height: Theme::TS_H do
            title "#{title} · utilization"
            unit util_unit
            min 0
            max umax
            graph :area
            query 'A', util_expr, datasource: datasource, presence: :continuous
            threshold steps: usteps
          end

          row.panel :"sat_sat_#{sl}", kind: :timeseries, width: width, height: Theme::TS_H do
            title "#{title} · saturation"
            unit saturation_unit
            min 0
            graph :area
            query 'A', saturation_expr, datasource: datasource, presence: :continuous
          end

          return unless errors_expr

          row.panel :"sat_err_#{sl}", kind: :timeseries, width: width, height: Theme::TS_H do
            title "#{title} · errors"
            unit 'short'
            min 0
            graph :area
            query 'A', Floor.zero(errors_expr), datasource: datasource, presence: :event_driven
          end
        end

        def self.validate!(datasource:, util_expr:, saturation_expr:)
          raise ArgumentError, 'SaturationRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'SaturationRow: util_expr: required' if blank?(util_expr)
          raise ArgumentError, 'SaturationRow: saturation_expr: required' if blank?(saturation_expr)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :validate!, :blank?, :slug
      end
    end
  end
end
