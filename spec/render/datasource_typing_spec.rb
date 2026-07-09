# frozen_string_literal: true

require 'pangea-dashboards'

# The typed datasource registry makes two whole classes of rendered-dashboard
# bug unrepresentable: wrong panel datasource `type`, and a query whose language
# mismatches its datasource. This is the regression guard for the bug where the
# pangea-operator Logs panels rendered vlogs with type 'prometheus' and errored.
RSpec.describe Pangea::Dashboards::Datasources do
  describe '.ref derives the grafana type from the registry (no hardcoded prometheus)' do
    it 'types VictoriaMetrics (vm) as prometheus' do
      expect(described_class.ref('vm')).to eq('type' => 'prometheus', 'uid' => 'vm')
    end

    it 'types VictoriaLogs (vlogs) as victoriametrics-logs-datasource — NOT prometheus' do
      expect(described_class.ref('vlogs')).to eq('type' => 'victoriametrics-logs-datasource', 'uid' => 'vlogs')
    end

    it 'passes template-variable datasources through (resolved by grafana at runtime)' do
      expect(described_class.ref('$datasource')).to eq('type' => 'prometheus', 'uid' => '$datasource')
    end

    it 'defaults an unregistered concrete uid to prometheus (backward-compatible)' do
      expect(described_class.ref('some-other-ds')).to eq('type' => 'prometheus', 'uid' => 'some-other-ds')
    end
  end

  describe '.validate_query! rejects a query whose language mismatches its datasource' do
    it 'raises when a LogsQL query targets a PromQL datasource (the original bug class)' do
      expect { described_class.validate_query!('{namespace="x",app="y"} | error', 'vm') }
        .to raise_error(Pangea::Dashboards::DatasourceLanguageMismatchError, /LogsQL/)
    end

    it 'allows a LogsQL query on the logs datasource' do
      expect { described_class.validate_query!('{namespace="x",app="y"} | error', 'vlogs') }.not_to raise_error
    end

    it 'raises when a PromQL query targets a LogsQL datasource' do
      expect { described_class.validate_query!('rate(pangea_drift_detected_total[5m])', 'vlogs') }
        .to raise_error(Pangea::Dashboards::DatasourceLanguageMismatchError, /PromQL/)
    end

    it 'allows a PromQL query on the metrics datasource' do
      expect { described_class.validate_query!('sum by (controller) (rate(x[5m]))', 'vm') }.not_to raise_error
    end

    # Regression: a PromQL label-regex alternation (outcome=~"denied|error") carries
    # a `|error` substring that the LogsQL pipe classifier false-matched, so
    # AuthMethodHealth / SecretsPlatformOverview (which emit exactly this against the
    # vm PromQL datasource) raised DatasourceLanguageMismatchError at render. A `|`
    # INSIDE a quoted string is never a LogsQL pipe operator.
    it 'does NOT mistake a PromQL label-regex alternation for LogsQL (the denied|error bug)' do
      expect { described_class.validate_query!('sum(rate(auth_total{outcome=~"denied|error"}[5m]))', 'vm') }
        .not_to raise_error
    end

    it 'classifies a denied|error label-regex expr as promql, not logsql' do
      expr = 'sum(rate(auth_total{outcome=~"denied|error"}[5m]))'
      expect(described_class.logsql?(expr)).to be(false)
      expect(described_class.promql?(expr)).to be(true)
    end

    it 'still catches a real LogsQL pipe even when a quoted alternation is present' do
      # {app="a|b"} is a quoted alternation (inert); `| stats` is a genuine LogsQL pipe.
      expect { described_class.validate_query!('{app="a|b"} | stats count()', 'vm') }
        .to raise_error(Pangea::Dashboards::DatasourceLanguageMismatchError, /LogsQL/)
    end
  end

  describe 'end-to-end: a rendered dashboard types its panels from the registry' do
    let(:dashboard) do
      builder = Pangea::Dashboards::DSL::DashboardBuilder.new(id: :t)
      builder.instance_eval do
        title 't'
        row 'metrics' do
          panel :m, kind: :timeseries do
            title 'm'
            query 'A', 'rate(foo[5m])', datasource: 'vm'
          end
        end
        row 'logs' do
          panel :l, kind: :table do
            title 'l'
            query 'A', '{namespace="pangea-system"} | error', datasource: 'vlogs'
          end
        end
      end
      builder.build
    end

    it 'renders the metric panel target as prometheus/vm and the log panel target as VictoriaLogs/vlogs' do
      json = Pangea::Dashboards::Render::Grafana.render(dashboard)
      targets = json['panels'].flat_map { |p| p['type'] == 'row' ? [] : p['targets'] }
      vm_t    = targets.find { |t| t['expr'].include?('rate(foo') }
      logs_t  = targets.find { |t| t['expr'].include?('| error') }
      expect(vm_t['datasource']).to eq('type' => 'prometheus', 'uid' => 'vm')
      expect(logs_t['datasource']).to eq('type' => 'victoriametrics-logs-datasource', 'uid' => 'vlogs')
    end
  end
end
