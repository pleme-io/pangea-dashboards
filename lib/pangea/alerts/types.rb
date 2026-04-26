# frozen_string_literal: true

require 'dry-types'
require 'dry-struct'

module Pangea
  module Alerts
    module Types
      include Dry.Types()

      Severity = Types::Strict::String.enum('info', 'warning', 'critical')

      class AlertRule < Dry::Struct
        attribute :name, Types::Strict::Symbol
        attribute :expr, Types::Strict::String
        attribute? :for_, Types::Strict::String.default('5m'.freeze)
        attribute :severity, Severity
        attribute? :summary, Types::Strict::String.optional
        attribute? :description, Types::Strict::String.optional
        attribute? :runbook_url, Types::Strict::String.optional
        attribute? :labels, Types::Strict::Hash.default({}.freeze)
        attribute? :annotations, Types::Strict::Hash.default({}.freeze)
        # Explicit Datadog query override (when expr is PromQL-only).
        attribute? :dd_query, Types::Strict::String.optional
        # Datadog monitor type override; if unset the renderer infers
        # from the expr shape ('metric alert', 'query alert', etc.).
        attribute? :dd_monitor_type, Types::Strict::String.optional
      end

      class AlertGroup < Dry::Struct
        attribute :name, Types::Strict::String
        attribute? :interval, Types::Strict::String.default('30s'.freeze)
        attribute :rules, Types::Strict::Array.of(AlertRule).default([].freeze)
      end

      class Alerts < Dry::Struct
        # Logical id (`:secure_vpc_prod_alerts`). Backends use it to
        # derive resource names + namespace defaults.
        attribute :id, Types::Strict::Symbol
        # Where to deploy (Kubernetes namespace for Victoria/Prometheus
        # backends; ignored by Datadog).
        attribute? :namespace, Types::Strict::String.default('monitoring'.freeze)
        # Common labels stamped on every emitted resource.
        attribute? :labels, Types::Strict::Hash.default({}.freeze)
        attribute :groups, Types::Strict::Array.of(AlertGroup).default([].freeze)
      end
    end
  end
end
