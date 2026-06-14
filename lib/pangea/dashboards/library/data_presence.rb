# frozen_string_literal: true

module Pangea
  module Dashboards
    module Library
      # The "is this panel's NO-DATA real, or just nothing-yet?" answer, made
      # first-class on the dashboard. Every "no data" has exactly one of four
      # causes, and they are mechanically distinguishable:
      #
      #   1. target NOT wired   → no `up{job=…}` series at all   (scrape config gap)
      #   2. target DOWN        → `up{job=…} == 0`               (target failing)
      #   3. wired but EMPTY    → `up==1` AND `count(metric)==0` (BROKEN: dead metric)
      #   4. present but FILTERED→ `count(metric)>0`, query empty (IDLE: healthy/quiet)
      #
      # This helper emits the scrape-side half (causes 1+2): a per-job `up`
      # table + a "targets down / absent" stat. Paired with the per-metric
      # Health probe (causes 3+4, see Pangea::Dashboards::Health), a viewer
      # can always tell a broken panel from a quiet one without guessing.
      #
      # ── Usage ───────────────────────────────────────────────────────────
      #   row 'Data presence' do
      #     Pangea::Dashboards::Library::DataPresence.add_all(
      #       self,
      #       jobs: %w[pangea-operator kubelet kube-state-metrics],
      #       datasource: ds
      #     )
      #   end
      #
      # `jobs:` are the Prometheus `job` labels this dashboard depends on; a
      # job absent from `up` (cause 1) renders as a 0-height gap that the
      # `expected_jobs` stat counts, so a never-deployed exporter (e.g.
      # node-exporter) is visible rather than silently missing.
      module DataPresence
        # Emit the scrape-health panel set into `row`.
        #
        # @param row [DSL::RowBuilder]
        # @param jobs [Array<String>] Prometheus job labels this dashboard reads
        # @param datasource [String] metrics datasource uid (vm)
        def self.add_all(row, jobs:, datasource: 'vm')
          validate!(jobs: jobs, datasource: datasource)
          add_up_table(row, jobs: jobs, datasource: datasource)
          add_targets_down(row, jobs: jobs, datasource: datasource)
          add_expected_present(row, jobs: jobs, datasource: datasource)
        end

        # `up` per (job, instance): 1 = scraped+healthy, 0 = target down.
        # A job MISSING from this table is cause #1 (never wired).
        def self.add_up_table(row, jobs:, datasource:)
          sel = job_selector(jobs)
          row.panel :scrape_up, kind: :table do
            title 'Scrape targets — up (1) / down (0)'
            description 'Per (job,instance) scrape health. 1 = scraped + healthy, ' \
                        '0 = target DOWN. A job absent from this table is NOT WIRED ' \
                        '(no scrape config) — that is the real cause of its panels\' no-data.'
            query 'A', "up{#{sel}}", datasource: datasource, instant: true
          end
        end

        # Count of targets currently DOWN (up==0) — should be 0.
        def self.add_targets_down(row, jobs:, datasource:)
          sel = job_selector(jobs)
          row.panel :scrape_targets_down, kind: :stat do
            title 'Targets down'
            description 'Number of expected scrape targets reporting up==0. ' \
                        '>0 = a real target is failing (not "no data yet").'
            # or vector(0): when every target is up the `== 0` set is empty;
            # render 0, not no-data (this stat must never be ambiguous).
            query 'A', "count(up{#{sel}} == 0) or vector(0)", datasource: datasource,
                  presence: :event_driven
            threshold steps: [
              { color: 'green', value: nil },
              { color: 'red',   value: 1 }
            ]
          end
        end

        # How many of the EXPECTED jobs are actually present in `up`.
        # `expected < jobs.length` means a job was never wired (cause #1).
        def self.add_expected_present(row, jobs:, datasource:)
          sel = job_selector(jobs)
          expected = jobs.length
          row.panel :scrape_jobs_present, kind: :stat do
            title "Expected jobs present (of #{expected})"
            description "Distinct jobs reporting `up` out of the #{expected} this " \
                        'dashboard depends on. Below target = an exporter is not ' \
                        'deployed/scraped (e.g. node-exporter) — fix the scrape, ' \
                        'do not wait for data.'
            query 'A', "count(group by (job) (up{#{sel}})) or vector(0)",
                  datasource: datasource, presence: :continuous
            threshold steps: [
              { color: 'red',    value: nil },
              { color: 'yellow', value: 1 },
              { color: 'green',  value: expected }
            ]
          end
        end

        # ── helpers ────────────────────────────────────────────────────────

        # Build a `job=~"a|b|c"` selector. Jobs are regex-escaped lightly
        # (the values are operator-authored label literals, not user input).
        def self.job_selector(jobs)
          alt = jobs.map { |j| j.to_s.gsub(/([.\\+*?()\[\]{}|^$])/, '\\\\\\1') }.join('|')
          %(job=~"#{alt}")
        end

        def self.validate!(jobs:, datasource:)
          raise ArgumentError, 'DataPresence: jobs must be a non-empty Array' \
            unless jobs.is_a?(Array) && !jobs.empty?
          if jobs.any? { |j| j.nil? || j.to_s.strip.empty? }
            raise ArgumentError, 'DataPresence: every job label must be non-empty'
          end
          raise ArgumentError, 'DataPresence: datasource uid required' \
            if datasource.nil? || datasource.to_s.strip.empty?
        end

        private_class_method :job_selector
      end
    end
  end
end
