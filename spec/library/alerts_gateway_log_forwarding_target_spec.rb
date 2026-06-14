# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/alerts/gateway_log_forwarding_target'

# GatewayLogForwardingTarget — the one akeyless-authored primitive: a typed
# Dry::Struct log-ROUTING artifact (returns a struct, emits no panel). It
# collapses 22 hand-written Go resources (11 SIEM backends × 2 streams) into ONE
# schema + a target enum. The spec asserts the enum-validated struct shape, a
# valid per-backend (datadog) field shape, the second stream reusing the same
# backend, and that the enum rejects an unknown target + a missing required
# per-backend field.
RSpec.describe Pangea::Dashboards::Library::Alerts::GatewayLogForwardingTarget do
  Klass = Pangea::Dashboards::Library::Alerts::GatewayLogForwardingTarget unless defined?(Klass)

  describe '.build (happy path — datadog audit sink)' do
    subject(:sink) do
      Klass.build(
        stream: :gateway_audit,
        target: :datadog,
        api_key: 'dd-secret',
        host: 'http-intake.logs.datadoghq.com',
        log_source: 'akeyless',
        log_tags: 'env:prod',
        log_service: 'gateway'
      )
    end

    it 'returns a typed LogForwardingTarget struct' do
      expect(sink).to be_a(Klass::LogForwardingTarget)
    end

    it 'validates the enum-typed stream + target' do
      expect(sink.stream).to eq(:gateway_audit)
      expect(sink.target).to eq(:datadog)
    end

    it 'defaults enable=true and output_format=json' do
      expect(sink.enable).to be(true)
      expect(sink.output_format).to eq('json')
      expect(sink.pull_interval).to be_nil
    end

    it 'carries the per-backend field shape in settings' do
      expect(sink.settings).to include(
        api_key: 'dd-secret',
        log_source: 'akeyless',
        log_service: 'gateway'
      )
    end

    it 'declares both streams + all 11 SIEM backends as the typed enum' do
      expect(Klass::STREAMS).to eq(%i[gateway_audit remote_access_session])
      expect(Klass::TARGETS).to contain_exactly(
        :datadog, :splunk, :elasticsearch, :logstash, :logz_io, :sumologic,
        :syslog, :google_chronicle, :azure_analytics, :aws_s3, :stdout
      )
    end
  end

  describe '.build (typed-enum case — the SAME backend on the session stream)' do
    subject(:sink) do
      Klass.build(
        stream: :remote_access_session,
        target: :splunk,
        splunk_url: 'https://splunk:8088',
        token: 'splunk-hec-token',
        index: 'akeyless',
        enable: false,
        output_format: 'cef',
        pull_interval: '15'
      )
    end

    it 'reuses one schema for the second stream (the 22→1 collapse)' do
      expect(sink.stream).to eq(:remote_access_session)
      expect(sink.target).to eq(:splunk)
    end

    it 'honours the enable / output_format overrides' do
      expect(sink.enable).to be(false)
      expect(sink.output_format).to eq('cef')
    end

    it 'coerces pull_interval to an Integer' do
      expect(sink.pull_interval).to eq(15)
    end

    it 'rejects an output_format outside the typed enum' do
      expect { Klass.build(stream: :gateway_audit, target: :stdout, output_format: 'yaml') }
        .to raise_error(Dry::Struct::Error)
    end
  end

  describe '.build (stdout needs no per-backend fields)' do
    it 'builds with an empty settings shape' do
      sink = Klass.build(stream: :gateway_audit, target: :stdout)
      expect(sink.target).to eq(:stdout)
      expect(sink.settings).to eq({})
    end
  end

  describe '.build (validation)' do
    it 'rejects an unknown target' do
      expect { Klass.build(stream: :gateway_audit, target: :kafka, broker: 'x') }
        .to raise_error(ArgumentError, /target must be one of/)
    end

    it 'rejects an unknown stream' do
      expect { Klass.build(stream: :worker, target: :datadog, api_key: 'x') }
        .to raise_error(ArgumentError, /stream must be one of/)
    end

    it 'rejects a datadog sink missing its required api_key field' do
      expect { Klass.build(stream: :gateway_audit, target: :datadog, host: 'h') }
        .to raise_error(ArgumentError, /api_key/)
    end

    it 'rejects a splunk sink missing one of its two required fields' do
      expect { Klass.build(stream: :remote_access_session, target: :splunk, splunk_url: 'u') }
        .to raise_error(ArgumentError, /token/)
    end
  end
end
