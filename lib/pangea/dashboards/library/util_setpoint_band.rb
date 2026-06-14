# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The HOMEOSTASIS-BAND panel. ONE timeseries that plots a workload's
      # observed utilization ratio against the setpoint it is being held to —
      # the green band a resource-homeostasis controller (breathe) carves
      # toward. Query A is the live util_ratio series (one line per dimension
      # member, legend by labels); Query B is the overlaid avg setpoint line.
      # Seeing the two together is the whole story: a util line riding its
      # setpoint = converged; a util line drifting away = the controller has
      # carving to do. A util/setpoint PAIR on one canvas reads as "are we in
      # band?" preattentively — distance from the setpoint line IS the defect.
      #
      # Generalises the breathe mem_util / cpu_util panels
      # (breathe_band_util_ratio vs breathe_band_setpoint_ratio) and the
      # storage_carving storage_util_setpoint panel — every one of which is the
      # same shape (a util series + its setpoint overlay, folded over a
      # dimension selector). The author supplies the two gauge metrics + the
      # dimension; the component owns the typed PromQL, the overlay, the
      # 0–1 (or 0–100) framing, and the legends.
      #
      # ── Why :continuous, not :event_driven ─────────────────────────────
      # A util_ratio / setpoint_ratio is a GAUGE that is always present while
      # the band exists — there is no first-event gap to floor. `or vector(0)`
      # would be wrong here: a true 0 utilization is a real reading, and a
      # band that has vanished SHOULD read "No data" (the band is gone), not a
      # misleading green 0. So neither series is floored.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Memory homeostasis' do
      #     Pangea::Dashboards::Library::UtilSetpointBand.add(
      #       self, datasource: 'vm',
      #       util_metric: 'breathe_band_util_ratio',
      #       setpoint_metric: 'breathe_band_setpoint_ratio',
      #       dim: { resource: 'memory' })
      #   end
      module UtilSetpointBand
        # datasource:      (req) the metrics datasource uid
        # util_metric:     (req) the observed util_ratio gauge metric
        # setpoint_metric: (req) the target setpoint_ratio gauge metric
        # dim:             (req) the dimension selector folded into BOTH series
        #                  (typed Hash preferred, e.g. { resource: 'memory' };
        #                  a String/Regexp/Array value works per Promql rules)
        # legend_labels:   util-series legend template (default
        #                  '{{namespace}}/{{name}}')
        # unit:            Grafana unit (default 'percentunit' → 0–1 ratio)
        # min/max:         y-axis framing (default 0 / 1 — the ratio band)
        # title:           cosmetic override (default derived from util_metric)
        def self.add(row, datasource:, util_metric:, setpoint_metric:, dim:,
                     legend_labels: '{{namespace}}/{{name}}',
                     unit: 'percentunit', min: 0, max: 1, title: nil)
          validate!(datasource: datasource, util_metric: util_metric,
                    setpoint_metric: setpoint_metric, dim: dim)
          util_expr     = "#{util_metric}#{Promql.braces(dim)}"
          setpoint_expr = "avg(#{setpoint_metric}#{Promql.braces(dim)})"
          pid = :"util_setpoint_#{slug(util_metric)}"
          ttl = title || default_title(util_metric)
          row.panel pid, kind: :timeseries, width: Theme.half, height: Theme::TS_H do
            title ttl
            unit unit
            min min
            max max
            graph :area
            # The live utilization — one line per dimension member.
            query 'A', util_expr, datasource: datasource,
                  presence: :continuous, legend: legend_labels
            # The setpoint overlay — the green band the controller carves to.
            query 'B', setpoint_expr, datasource: datasource,
                  presence: :continuous, legend: 'setpoint'
          end
        end

        def self.default_title(util_metric)
          base = util_metric.to_s.sub(/_ratio\z/, '').sub(/_util\z/, '').tr('_', ' ')
          "#{base} · util vs setpoint"
        end

        def self.validate!(datasource:, util_metric:, setpoint_metric:, dim:)
          raise ArgumentError, 'UtilSetpointBand: datasource: required' if blank?(datasource)
          raise ArgumentError, 'UtilSetpointBand: util_metric: required' if blank?(util_metric)
          raise ArgumentError, 'UtilSetpointBand: setpoint_metric: required' if blank?(setpoint_metric)
          raise ArgumentError, 'UtilSetpointBand: dim: required (the dimension selector)' if blank?(dim)
        end

        def self.blank?(v)
          return true if v.nil?
          return v.empty? if v.is_a?(::Hash) || v.is_a?(::Array)

          v.to_s.strip.empty?
        end

        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :default_title, :validate!, :blank?, :slug
      end
    end
  end
end
