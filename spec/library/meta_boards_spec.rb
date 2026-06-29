# frozen_string_literal: true

require 'spec_helper'
require 'pangea/dashboards/library/nervous_system_self_health_board'
require 'pangea/dashboards/library/security_signal_wall'

# Wave 7 — the cross-domain meta boards that roll up other domains' strips.
RSpec.describe 'Pangea::Dashboards::Library meta boards (Wave 7)' do
  Lib = Pangea::Dashboards::Library unless defined?(Lib)

  describe Pangea::Dashboards::Library::NervousSystemSelfHealthBoard do
    let(:dash) do
      Lib::NervousSystemSelfHealthBoard.build(
        id: :tendril_nss, name: 'tendril nervous system', datasource: 'metrics',
        subsystems: [
          { title: 'metrics store', expr: 'up{job="vmsingle"}' },
          { title: 'log store',     expr: 'up{job="victoria-logs"}' }
        ],
        drop_metric: 'vector_buffer_discarded_events_total'
      )
    end

    it 'builds a typed Types::Dashboard tagged meta' do
      expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
      expect(dash.tags).to include('pleme-io', 'nervous-system', 'meta')
    end

    it 'rolls up subsystem liveness + a forward-drop defect' do
      titles = dash.rows.map(&:title)
      expect(titles.first).to match(/Subsystem liveness/)
      expect(titles).to include(match(/Forward-sink drops/))
      drop = dash.rows.last.panels.first
      expect(drop.queries.first.expr).to include('vector_buffer_discarded_events_total')
      expect(drop.queries.first.expr).to include('vector(0)') # event-driven, floored
    end

    it 'omits the liveness strip when no subsystems given' do
      d = Lib::NervousSystemSelfHealthBoard.build(id: :n, datasource: 'metrics')
      expect(d.rows.map(&:title)).not_to include(match(/Subsystem liveness/))
    end

    it 'requires id + datasource' do
      expect { Lib::NervousSystemSelfHealthBoard.build(id: :n, datasource: '') }
        .to raise_error(ArgumentError, /datasource/)
    end
  end

  describe Pangea::Dashboards::Library::SecuritySignalWall do
    let(:dash) do
      Lib::SecuritySignalWall.build(
        id: :sec_wall, name: 'security', datasource: 'metrics',
        overdue: { elapsed_metric: 'secret_age_seconds', interval_metric: 'secret_rotation_interval_seconds' },
        version_skew: { version_metric: 'gateway_config_version' },
        pipeline_health: true
      )
    end

    it 'builds a typed Types::Dashboard tagged security meta' do
      expect(dash).to be_a(Pangea::Dashboards::Types::Dashboard)
      expect(dash.tags).to include('pleme-io', 'security', 'meta')
    end

    it 'surfaces the worst-of defect tiles + the audit-pipeline health row' do
      titles = dash.rows.map(&:title)
      expect(titles.first).to match(/Security defects/)
      expect(titles).to include(match(/Audit pipeline health/))
      # two signal sources => two colour-flooded tiles
      expect(dash.rows.first.panels.size).to eq(2)
    end

    it 'refuses an empty wall (no signal sources)' do
      expect { Lib::SecuritySignalWall.build(id: :w, datasource: 'metrics') }
        .to raise_error(ArgumentError, /at least one signal source/)
    end

    it 'requires id + datasource' do
      expect { Lib::SecuritySignalWall.build(id: :w, datasource: '', overdue: { elapsed_metric: 'a', interval_metric: 'b' }) }
        .to raise_error(ArgumentError, /datasource/)
    end
  end
end
