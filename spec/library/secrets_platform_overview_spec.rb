# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/secrets_platform_overview'

# SecretsPlatformOverview — the keystone secrets-platform mixin. Asserts the
# story-ordered rows, the Types::Dashboard return, tags, the defect headline's
# emitted PromQL, and validation.
RSpec.describe Pangea::Dashboards::Library::SecretsPlatformOverview do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  describe 'happy path — the full keystone story' do
    let(:dash) do
      Lib::SecretsPlatformOverview.build(
        id: :cell_secrets, name: 'Secrets Platform', datasource: 'metrics',
        logs_datasource: 'logs', selector: { service: 'gateway' },
        jobs: %w[gateway], stream: '{namespace="secrets",app="gateway"}'
      )
    end

    it 'returns a Types::Dashboard (NEVER a Hash)' do
      expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
    end

    it 'tags pleme-io + secrets-platform' do
      expect(dash.tags).to include('pleme-io', 'secrets-platform')
    end

    it 'rows are in story order: presence → defects → ops → auth → cache → rate-limit → sync → logs' do
      titles = dash.rows.map(&:title)
      expect(titles).to eq([
        'Data presence — is the gateway reporting?',
        'Status — security defects',
        'Secret ops — RED matrix',
        'Auth SLI — denial rate per method',
        'Cache effectiveness',
        'Rate-limited consumer (samba)',
        'Gateway config sync',
        'Logs'
      ])
    end

    it 'the security-defects headline carries overdue + version-skew + denial + signing signals' do
      defects = dash.rows.find { |r| r.title == 'Status — security defects' }
      exprs = defects.panels.map { |p| p.queries.first.expr }
      # overdue intersection + version-skew + the two floored rates
      expect(exprs.join("\n")).to include('rotation_seconds_since_last >= rotation_configured_interval_seconds')
      expect(exprs.join("\n")).to include('!= scalar(max(')
      expect(exprs.join("\n")).to include('gateway_auth_denied_total')
      expect(exprs.join("\n")).to include('gateway_signing_failures_total')
    end

    it 'every defect tile is a colour-flooded stat' do
      defects = dash.rows.find { |r| r.title == 'Status — security defects' }
      expect(defects.panels.map(&:kind)).to all(eq(:stat))
      expect(defects.panels.map(&:display_mode)).to all(eq(:background))
    end

    it 'the secret-ops RED matrix folds the dashboard selector into every leg' do
      ops = dash.rows.find { |r| r.title == 'Secret ops — RED matrix' }
      expect(ops.panels.first.queries.first.expr).to include('service="gateway"')
    end
  end

  describe 'optional rows' do
    it 'omits the presence row when no jobs given and the logs row when no stream' do
      d = Lib::SecretsPlatformOverview.build(id: :x, datasource: 'vm')
      titles = d.rows.map(&:title)
      expect(titles).not_to include('Data presence — is the gateway reporting?')
      expect(titles).not_to include('Logs')
      # the keystone body still renders defects → ops → auth → cache → rate-limit → sync
      expect(titles.first).to eq('Status — security defects')
    end
  end

  describe 'validation' do
    it 'requires id + datasource' do
      expect { Lib::SecretsPlatformOverview.build(id: nil, datasource: 'vm') }
        .to raise_error(ArgumentError, /id/)
      expect { Lib::SecretsPlatformOverview.build(id: :x, datasource: '') }
        .to raise_error(ArgumentError, /datasource/)
    end
  end
end
