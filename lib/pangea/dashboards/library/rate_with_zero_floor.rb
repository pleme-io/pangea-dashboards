# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The Rate leg, as a reusable atom. A rate panel/tile over an
      # event-driven counter that ALWAYS renders — `sum by(group)(rate(metric
      # [w]))` floored with `or vector(0)` so it reads a true 0 (not "No data")
      # until the first event. Generalises the pervasive
      # rate-counter-that-lights-up idiom hand-written across pangea_operator
      # (magma/compile/escalation rates), breathe (conflicts/errors), and
      # vector_pipeline (component rates) — and is the Rate primitive
      # GoldenSignalsRow / QuotaPctSambaRow / AutoscalerPoolStrip consume.
      #
      #   row 'Throughput' do
      #     Pangea::Dashboards::Library::RateWithZeroFloor.add(
      #       self, datasource: 'vm', counter_metric: 'reconcile_total',
      #       group_by: %w[controller], unit: 'ops')
      #   end
      module RateWithZeroFloor
        # counter_metric: (req) the *_total counter to rate()
        # group_by:       labels to sum by (default none → scalar rate)
        # selector:       typed Hash/String matcher (Promql.selector_body)
        # window:         rate window (default 5m)
        # unit:           Grafana unit (default 'reqps')
        # presence:       :event_driven (default — floored) | :continuous
        # kind:           :timeseries (default) | :stat
        # title / legend / id: cosmetic overrides
        def self.add(row, datasource:, counter_metric:, group_by: [], selector: nil,
                     window: '5m', unit: 'reqps', presence: :event_driven,
                     kind: :timeseries, title: nil, legend: nil, id: nil, width: nil)
          validate!(datasource: datasource, counter_metric: counter_metric, kind: kind)
          expr = Floor.zero(Promql.sum_rate(metric: counter_metric, window: window,
                                             group_by: group_by, selector: selector))
          pid  = id || :"rate_#{slug(counter_metric)}"
          ttl  = title || default_title(counter_metric, group_by)
          leg  = legend || default_legend(group_by)
          height = kind == :stat ? Theme::STAT_H : Theme::TS_H
          width  ||= (kind == :stat ? Theme.third : Theme.half)
          row.panel pid, kind: kind, width: width, height: height do
            title ttl
            unit unit
            display(:background) if kind == :stat
            graph :area
            query 'A', expr, datasource: datasource, presence: presence, legend: leg
          end
        end

        def self.default_title(metric, group_by)
          base = metric.to_s.sub(/_total\z/, '').tr('_', ' ')
          group_by.empty? ? "#{base} rate" : "#{base} rate by #{Array(group_by).join('/')}"
        end

        def self.default_legend(group_by)
          gb = Array(group_by).compact
          gb.empty? ? nil : gb.map { |l| "{{#{l}}}" }.join('/')
        end

        def self.validate!(datasource:, counter_metric:, kind:)
          raise ArgumentError, 'RateWithZeroFloor: datasource: required' if blank?(datasource)
          raise ArgumentError, 'RateWithZeroFloor: counter_metric: required' if blank?(counter_metric)
          raise ArgumentError, "RateWithZeroFloor: kind must be :timeseries or :stat (got #{kind.inspect})" \
            unless %i[timeseries stat].include?(kind)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :default_title, :default_legend, :validate!, :blank?, :slug
      end
    end
  end
end
