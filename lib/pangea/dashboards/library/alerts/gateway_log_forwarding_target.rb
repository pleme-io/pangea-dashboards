# frozen_string_literal: true

require 'dry-types'
require 'dry-struct'
require 'pangea/dashboards/types'

module Pangea
  module Dashboards
    module Library
      module Alerts
        # The ONE genuinely akeyless-authored observability primitive in the
        # library: a typed Dry::Struct model of an Akeyless gateway
        # log-forwarding / remote-access-session (RAS) log SINK, parameterised
        # by SIEM backend. It is NOT a panel — it is a typed log-ROUTING
        # artifact: the declaration of WHERE a gateway streams its audit /
        # session logs, validated by construction.
        #
        # ── What it absorbs ─────────────────────────────────────────────────
        # akeyless-community/terraform-provider-akeyless ships the gateway
        # log-forwarding surface as 11 backend-specific resources
        # (akeyless_gateway_log_forwarding_{datadog,splunk,elasticsearch,
        # logstash,logz_io,sumologic,syslog,google_chronicle,azure_analytics,
        # aws_s3,stdout}) — and the session-log surface repeats the SAME 11
        # backends a SECOND time for remote-access session logs. That is 22
        # hand-written Go resources for what is structurally ONE schema (a
        # gateway, a stream, a backend, enable + format + pull-interval) plus a
        # backend enum and a per-backend field shape. This collapses the 22 to
        # ONE typed struct + a target enum (solve-once, per the prime
        # directive): authoring a sink is now a single typed `build` call whose
        # per-backend field shape is validated by Dry::Types rather than by 22
        # copies of the same HCL.
        #
        # ── Why a typed struct, not a panel ─────────────────────────────────
        # Log forwarding is a ROUTING decision (which sink, with which
        # credentials), not a visualisation. The library's panels VISUALISE the
        # telemetry that arrives; this primitive declares the pipe that telemetry
        # flows through. Modelling it as a typed value means an unknown backend
        # or a malformed per-backend field shape is rejected at construction —
        # an invalid sink is unrepresentable, never a runtime surprise in the
        # gateway.
        #
        # ── Usage ───────────────────────────────────────────────────────────
        #   Pangea::Dashboards::Library::Alerts::GatewayLogForwardingTarget.build(
        #     stream: :gateway_audit,
        #     target: :datadog,
        #     api_key: 'dd-…', host: 'http-intake.logs.datadoghq.com',
        #     log_source: 'akeyless', log_service: 'gateway')
        #
        #   Pangea::Dashboards::Library::Alerts::GatewayLogForwardingTarget.build(
        #     stream: :remote_access_session,
        #     target: :splunk,
        #     splunk_url: 'https://splunk:8088', token: '…', index: 'akeyless')
        module GatewayLogForwardingTarget
          # The two log streams a gateway forwards. `:gateway_audit` is the
          # gateway's own audit log; `:remote_access_session` is the RAS
          # session-recording log — the same 11 backends, a different source.
          STREAMS = %i[gateway_audit remote_access_session].freeze

          # The 11 SIEM backends the upstream provider models. Ordered as the
          # provider documents them so the enum reads as the canonical list.
          TARGETS = %i[
            datadog splunk elasticsearch logstash logz_io sumologic syslog
            google_chronicle azure_analytics aws_s3 stdout
          ].freeze

          # ── typed leaves ──────────────────────────────────────────────────
          module Schema
            include Dry.Types()

            Stream = Strict::Symbol.enum(*STREAMS)
            Target = Strict::Symbol.enum(*TARGETS)
            # 'json' | 'text' | 'cef' — the wire encoding the sink expects.
            OutputFormat = Strict::String.default('json'.freeze).enum('json', 'text', 'cef')
          end

          # The typed log-routing artifact `build` returns. A gateway's sink
          # for ONE (stream, target) pair: the enum-validated stream + backend,
          # the enable toggle, the wire format, an optional pull-interval, and
          # the per-backend field Hash (already validated against the target's
          # required-field shape by the time it lands here).
          class LogForwardingTarget < Dry::Struct
            attribute :stream, Schema::Stream
            attribute :target, Schema::Target
            attribute? :enable, Types::Strict::Bool.default(true)
            attribute? :output_format, Schema::OutputFormat
            # Akeyless polls the source every `pull_interval` seconds (nil ⇒ the
            # gateway default). Coerced so '10' and 10 both validate.
            attribute? :pull_interval, Types::Coercible::Integer.optional.default(nil)
            # The per-backend field shape (api_key/host/… for datadog,
            # splunk_url/token/index for splunk, …). Validated against the
            # target's required-field list before the struct is built.
            attribute? :settings, Types::Strict::Hash.default({}.freeze)
          end

          # The required per-backend field shape. Each backend names the fields
          # the upstream resource marks required; `build` rejects a sink whose
          # settings omit any of them. (Optional fields pass through untouched.)
          TARGET_REQUIRED_FIELDS = {
            datadog: %i[api_key],
            splunk: %i[splunk_url token],
            elasticsearch: %i[server_type index],
            logstash: %i[dns protocol],
            logz_io: %i[logz_io_token],
            sumologic: %i[sumologic_endpoint],
            syslog: %i[dns],
            google_chronicle: %i[gcp_key customer_id],
            azure_analytics: %i[workspace_id workspace_key],
            aws_s3: %i[bucket_name],
            stdout: [].freeze
          }.freeze

          # Build the typed log-routing artifact for ONE (stream, target) pair.
          #
          # stream:        (req) :gateway_audit | :remote_access_session
          # target:        (req) one of TARGETS — rejected if unknown
          # enable:        forward toggle (default true)
          # output_format: 'json' (default) | 'text' | 'cef'
          # pull_interval: source poll seconds (nil ⇒ gateway default)
          # **target_opts: the per-backend field shape (datadog: api_key/host/
          #                log_source/log_tags/log_service; splunk: splunk_url/
          #                token/index; …) — validated against the target's
          #                required-field list.
          def self.build(stream:, target:, enable: true, output_format: 'json',
                         pull_interval: nil, **target_opts)
            validate!(stream: stream, target: target, settings: target_opts)
            LogForwardingTarget.new(
              stream: stream,
              target: target,
              enable: enable,
              output_format: output_format,
              pull_interval: pull_interval,
              settings: target_opts
            )
          end

          def self.validate!(stream:, target:, settings:)
            unless STREAMS.include?(stream)
              raise ArgumentError,
                    "GatewayLogForwardingTarget: stream must be one of #{STREAMS.inspect} (got #{stream.inspect})"
            end
            unless TARGETS.include?(target)
              raise ArgumentError,
                    "GatewayLogForwardingTarget: target must be one of #{TARGETS.inspect} (got #{target.inspect})"
            end
            required = TARGET_REQUIRED_FIELDS.fetch(target)
            missing = required.reject { |f| present?(settings[f]) }
            return if missing.empty?

            raise ArgumentError,
                  "GatewayLogForwardingTarget: target #{target.inspect} requires #{missing.inspect} " \
                  "(got fields #{settings.keys.inspect})"
          end

          def self.present?(v) = !blank?(v)
          def self.blank?(v) = v.nil? || v.to_s.strip.empty?
          def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
          private_class_method :validate!, :present?, :blank?, :slug
        end
      end
    end
  end
end
