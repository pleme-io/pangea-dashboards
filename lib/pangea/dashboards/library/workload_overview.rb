# frozen_string_literal: true

require 'pangea/dashboards/dsl'
require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/data_presence'
require 'pangea/dashboards/library/status_overview'
require 'pangea/dashboards/library/golden_signals_row'
require 'pangea/dashboards/library/kubernetes_pod_panels'
require 'pangea/dashboards/library/log_windows'

module Pangea
  module Dashboards
    module Library
      # THE KEYSTONE. Composes the canonical triage STORY every Monitorable
      # architecture re-assembles by hand —
      #
      #   Presence  →  Status  →  Golden signals  →  Resources  →  Logs
      #
      # (the Stephen-Few top-to-bottom "is it OK? → why? → how bad? → where?"
      # narrative Theme.rb encodes) into a whole Types::Dashboard with ONE call.
      # Authoring a new service dashboard stops being "re-assemble six rows" and
      # becomes a single typed invocation; consistency across every fleet
      # dashboard becomes a property of construction, not discipline.
      #
      # Two entry points:
      #   • compose(builder, …) — adds the standard rows to an existing
      #     DashboardBuilder (use INSIDE a Monitorable `monitor do |r, opts|`
      #     block, where the builder is `self`).
      #   • build(…) — opens a fresh builder, composes, returns the Dashboard
      #     (use in a workspace for a standalone service dashboard).
      #
      #   dash = Pangea::Dashboards::Library::WorkloadOverview.build(
      #     id: :payments, name: 'payments', datasource: 'vm', logs_datasource: 'vlogs',
      #     jobs: %w[payments], namespace: 'payments', stream: 'payments',
      #     rate_metric: 'http_requests_total',
      #     latency_metric: 'http_request_duration_seconds_bucket',
      #     group_by: %w[route], error_selector: { code: '5..' },
      #     signals: [
      #       { name: 'Pods not ready', expr: 'count(kube_pod_status_ready{namespace="payments",condition="false"})', warn: 1, crit: 1 },
      #       { name: '5xx /s', expr: 'sum(rate(http_requests_total{namespace="payments",code=~"5.."}[5m]))', warn: 0.1 },
      #     ])
      module WorkloadOverview
        # All keyword args (see build) bar the builder.
        def self.compose(builder, datasource:, logs_datasource: nil, name:, jobs:, signals:,
                         rate_metric: nil, latency_metric: nil, error_selector: nil, group_by: [],
                         namespace: nil, stream: nil, extra_rows: [])
          validate!(datasource: datasource, name: name, jobs: jobs, signals: signals,
                    rate_metric: rate_metric, latency_metric: latency_metric,
                    stream: stream, logs_datasource: logs_datasource)

          # 1. Presence — is it reporting at all? (the no-data answer first)
          builder.row('Data presence — is it reporting?') do
            Library::DataPresence.add_all(self, jobs: jobs, datasource: datasource)
          end

          # 2. Status — the defects-first headline (what needs attention NOW)
          builder.row('Status — what needs attention?') do
            Library::StatusOverview.add(self, signals: signals, datasource: datasource)
          end

          # 3. Golden signals — rate · errors · latency (only if request-shaped)
          if rate_metric && latency_metric
            es = error_selector ? { error_selector: error_selector } : {}
            builder.row('Golden signals — rate · errors · latency') do
              Library::GoldenSignalsRow.add(self, datasource: datasource, rate_metric: rate_metric,
                                            latency_metric: latency_metric, group_by: group_by, **es)
            end
          end

          # 4. Resources — pod cpu/mem/restarts/count (only if namespaced)
          if namespace
            builder.row('Resources — pods') do
              Library::KubernetesPodPanels.add_all(self, namespace: namespace, datasource: datasource)
            end
          end

          # 5. Logs — full stream + ERROR window + error-rate (only if a stream)
          if stream
            lds = logs_datasource || datasource
            builder.row('Logs') do
              Library::LogWindows.add_all(self, name: name, stream: stream, datasource: lds)
            end
          end

          # 6. Author escape hatch — extra rows appended after the canon.
          Array(extra_rows).each { |p| p.call(builder) if p.respond_to?(:call) }

          builder
        end

        # Build a complete Types::Dashboard from scratch.
        def self.build(id:, name:, **kwargs)
          builder = DSL::DashboardBuilder.new(id: id)
          builder.title("#{name} · overview")
          builder.tags('pleme-io', 'workload-overview')
          compose(builder, name: name, **kwargs)
          builder.build
        end

        def self.validate!(datasource:, name:, jobs:, signals:, rate_metric:, latency_metric:, stream:, logs_datasource:)
          raise ArgumentError, 'WorkloadOverview: datasource: required' if blank?(datasource)
          raise ArgumentError, 'WorkloadOverview: name: required' if blank?(name)
          raise ArgumentError, 'WorkloadOverview: jobs must be a non-empty Array' \
            unless jobs.is_a?(Array) && !jobs.empty?
          raise ArgumentError, 'WorkloadOverview: signals must be a non-empty Array' \
            unless signals.is_a?(Array) && !signals.empty?
          # Golden signals is all-or-nothing — a rate without a latency (or vice
          # versa) is an incomplete RED row; make the half-spec unrepresentable.
          if !!rate_metric ^ !!latency_metric
            raise ArgumentError, 'WorkloadOverview: rate_metric and latency_metric must be given together (RED needs both)'
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :validate!, :blank?
      end
    end
  end
end
