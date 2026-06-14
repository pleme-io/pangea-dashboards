# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/red_sli_gauge_strip'
require 'pangea/dashboards/library/controller_runtime_row'
require 'pangea/dashboards/library/webhook_latency_heatmap'
require 'pangea/dashboards/library/failed_resources_table'
require 'pangea/dashboards/library/rate_with_zero_floor'
require 'pangea/dashboards/library/go_process_use_row'
require 'pangea/dashboards/library/log_windows'

module Pangea
  module Dashboards
    module Library
      # The one-call operator dashboard for ANY kubebuilder / controller-runtime
      # Go workload. Composes the whole RED/SLI story —
      #
      #   SLIs (per object-kind)  →  controller-runtime golden signals  →
      #   [webhook latency]  →  [provider-API errors]  →  [Go runtime]  →  [logs]
      #
      # — into a whole Types::Dashboard. Directly fills the akeyless
      # cert-manager-issuer gap (it emits the controller_runtime_* metrics but
      # ships no dashboard) and every pleme-io engenho/pangea controller. The
      # highest-quality vendored reference was external-secrets'
      # ControllerRuntimeDashboard; this is its typed, fleet-generic form.
      #
      #   dash = Pangea::Dashboards::Library::ControllerRuntimeDashboard.build(
      #     id: :cert_manager_issuer, name: 'cert-manager-issuer', datasource: 'vm',
      #     service_selector: { job: 'cert-manager-issuer' },
      #     object_kinds: %w[Certificate CertificateRequest Order Challenge])
      module ControllerRuntimeDashboard
        # id/name:           dashboard id + human title
        # datasource:        metrics datasource uid
        # service_selector:  (req) typed Hash matcher identifying the controller
        # object_kinds:      reconciled kinds → a per-kind error-rate SLI strip
        # windows:           { rate:, latency_quantile: } (defaults 15m / 0.99)
        # include_webhook + webhook_metric: add a webhook latency heatmap
        # provider_api_metric: add an upstream provider-API call rate row
        # process_selector:  add a Go-runtime USE row
        # logs_datasource + stream: add the standard log windows
        # sli_metric / controller_label: override the reconcile metric + label
        def self.build(id:, datasource:, service_selector:, name: nil, object_kinds: [],
                       windows: { rate: '15m', latency_quantile: 0.99 },
                       include_webhook: false, webhook_metric: nil, provider_api_metric: nil,
                       process_selector: nil, logs_datasource: nil, stream: nil,
                       sli_metric: 'controller_runtime_reconcile_total', controller_label: 'controller')
          validate!(id: id, datasource: datasource, service_selector: service_selector)
          rate_w = windows.fetch(:rate, '15m')
          b = DSL::DashboardBuilder.new(id: id)
          b.title("#{name || id} · controller")
          b.tags('pleme-io', 'controller-runtime')

          # SLIs — per object-kind error-rate gauges (the headline)
          unless Array(object_kinds).empty?
            subsystems = Array(object_kinds).map do |k|
              { name: k, extra_selector: kind_selector(service_selector, controller_label, k) }
            end
            b.row('SLIs — error rate per reconciled kind') do
              Library::RedSliGaugeStrip.add(self, datasource: datasource, metric: sli_metric,
                                            subsystems: subsystems, window: rate_w)
            end
          end

          # Controller-runtime golden signals (reconcile latency/rate/errors + workqueue + apiserver)
          b.row('Controller runtime — golden signals') do
            Library::ControllerRuntimeRow.add(self, datasource: datasource, service_selector: service_selector,
                                              controller_label: controller_label, window: rate_w)
          end

          # Webhook latency distribution (optional)
          if include_webhook && webhook_metric
            b.row('Admission / webhook latency') do
              Library::WebhookLatencyHeatmap.add(self, datasource: datasource, histogram_metric: webhook_metric,
                                                 selector: service_selector, window: rate_w)
            end
          end

          # Upstream provider-API calls (optional — e.g. external-secrets → AWS/Vault)
          if provider_api_metric
            half = Pangea::Dashboards::Theme.half
            err_sel = error_selector(service_selector) # hoisted: self is the RowBuilder inside the block
            b.row('Provider API calls') do
              Library::RateWithZeroFloor.add(self, datasource: datasource, counter_metric: provider_api_metric,
                                             selector: service_selector, group_by: %w[provider], window: rate_w,
                                             unit: 'reqps', width: half, title: 'Provider API call rate')
              Library::RateWithZeroFloor.add(self, datasource: datasource, counter_metric: provider_api_metric,
                                             selector: err_sel, group_by: %w[provider],
                                             window: rate_w, unit: 'reqps', width: half,
                                             title: 'Provider API errors', id: :crd_provider_api_errors)
            end
          end

          # Go runtime USE (optional)
          if process_selector
            b.row('Go runtime') do
              Library::GoProcessUseRow.add(self, datasource: datasource, process_selector: process_selector)
            end
          end

          # Logs (optional)
          if stream && logs_datasource
            b.row('Logs') do
              Library::LogWindows.add_all(self, name: (name || id).to_s, stream: stream, datasource: logs_datasource)
            end
          end

          b.build
        end

        # Merge the controller's service selector with the per-kind controller
        # label, preserving the typed Hash form so RedSliGaugeStrip renders it.
        def self.kind_selector(service_selector, controller_label, kind)
          base = service_selector.is_a?(::Hash) ? service_selector.dup : {}
          base.merge(controller_label.to_sym => kind)
        end

        # An error-result variant of the service selector (provider-API errors).
        def self.error_selector(service_selector)
          base = service_selector.is_a?(::Hash) ? service_selector.dup : {}
          base.merge(status: /error|failure|5../)
        end

        def self.validate!(id:, datasource:, service_selector:)
          raise ArgumentError, 'ControllerRuntimeDashboard: id: required' if blank?(id)
          raise ArgumentError, 'ControllerRuntimeDashboard: datasource: required' if blank?(datasource)
          raise ArgumentError, 'ControllerRuntimeDashboard: service_selector: required (Hash/String)' \
            if service_selector.nil? || (service_selector.respond_to?(:empty?) && service_selector.empty?)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :kind_selector, :error_selector, :validate!, :blank?
      end
    end
  end
end
