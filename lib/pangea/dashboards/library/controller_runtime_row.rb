# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/rate_with_zero_floor'
require 'pangea/dashboards/library/latency_histogram_panel'

module Pangea
  module Dashboards
    module Library
      # The full kubebuilder / controller-runtime golden-signals block for ANY
      # operator, given its service/namespace selector. This is the de-facto
      # cross-org operator vocabulary — akeylesslabs ARC, akeyless-community
      # external-secrets, cert-manager-issuer, and every pleme-io engenho/
      # pangea controller emit the SAME `controller_runtime_*` + `workqueue_*`
      # + `rest_client_*` metrics. Composes Wave-0/1 atoms over the standard
      # metric names so a controller dashboard is one call.
      #
      #   row 'Controller' do
      #     Pangea::Dashboards::Library::ControllerRuntimeRow.add(
      #       self, datasource: 'vm', service_selector: { job: 'cert-manager-issuer' })
      #   end
      module ControllerRuntimeRow
        # The standard controller-runtime metric surface (override per-arg if a
        # vendor renames them).
        DEFAULTS = {
          reconcile_bucket: 'controller_runtime_reconcile_time_seconds_bucket',
          reconcile_errors: 'controller_runtime_reconcile_errors_total',
          reconcile_total:  'controller_runtime_reconcile_total',
          workqueue_depth:  'workqueue_depth',
          active_workers:   'controller_runtime_active_workers',
          rest_client:      'rest_client_requests_total'
        }.freeze

        # service_selector:    (req) typed Hash matcher identifying the controller
        #                      (e.g. { job: 'cert-manager-issuer' } or { namespace: 'x', pod: /…/ })
        # controller_label:    label to group reconcile latency/errors by (default 'controller')
        # window:              rate window (default 5m)
        # include_workqueue:   add workqueue_depth + active_workers stats (default true)
        # include_rest_client: add the apiserver-call rest_client row (default true)
        # metrics:             override any of DEFAULTS
        def self.add(row, datasource:, service_selector:, controller_label: 'controller',
                     window: '5m', include_workqueue: true, include_rest_client: true,
                     title: 'Controller', metrics: {})
          validate!(datasource: datasource, service_selector: service_selector)
          m  = DEFAULTS.merge(metrics)
          gb = controller_label ? [controller_label] : []

          # Reconcile latency (Duration)
          LatencyHistogramPanel.add(row, datasource: datasource, bucket_metric: m[:reconcile_bucket],
                                    selector: service_selector, group_by: gb, quantiles: [0.5, 0.95, 0.99],
                                    window: window, width: Theme.third, title: "#{title} · reconcile latency")

          # Reconcile rate + errors (Rate + Errors)
          RateWithZeroFloor.add(row, datasource: datasource, counter_metric: m[:reconcile_total],
                                selector: service_selector, group_by: gb, window: window, unit: 'ops',
                                width: Theme.third, title: "#{title} · reconcile rate",
                                id: :cr_reconcile_rate)
          RateWithZeroFloor.add(row, datasource: datasource, counter_metric: m[:reconcile_errors],
                                selector: service_selector, group_by: gb, window: window, unit: 'ops',
                                width: Theme.third, title: "#{title} · reconcile errors",
                                id: :cr_reconcile_errors)

          if include_workqueue
            add_stat(row, id: :cr_workqueue_depth, title: "#{title} · workqueue depth", datasource: datasource,
                     expr: "sum(#{m[:workqueue_depth]}#{Promql.braces(service_selector)})", warn: 10, crit: 50)
            add_stat(row, id: :cr_active_workers, title: "#{title} · active workers", datasource: datasource,
                     expr: "sum(#{m[:active_workers]}#{Promql.braces(service_selector)})", liveness: true)
          end

          return unless include_rest_client

          rc = Promql.sum_rate(metric: m[:rest_client], window: window, group_by: %w[method code],
                               selector: service_selector)
          row.panel :cr_rest_client, kind: :timeseries, width: Theme.full, height: Theme::TS_H do
            title "#{title} · apiserver calls (rest_client)"
            unit 'reqps'
            min 0
            graph :area
            query 'A', Floor.zero(rc), datasource: datasource, presence: :event_driven, legend: '{{method}} {{code}}'
          end
        end

        def self.add_stat(row, id:, title:, datasource:, expr:, warn: nil, crit: nil, liveness: false)
          steps = liveness ? Theme.liveness_steps(ok: 1) : Theme.defect_steps(warn: warn || 1, crit: crit)
          row.panel id, kind: :stat, width: Theme.third, height: Theme::STAT_H do
            title title
            display :background
            graph :area
            query 'A', "#{expr} or vector(0)", datasource: datasource, presence: :event_driven
            threshold steps: steps
          end
        end

        def self.validate!(datasource:, service_selector:)
          raise ArgumentError, 'ControllerRuntimeRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'ControllerRuntimeRow: service_selector: required (Hash/String)' \
            if service_selector.nil? || (service_selector.respond_to?(:empty?) && service_selector.empty?)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :add_stat, :validate!, :blank?
      end
    end
  end
end
