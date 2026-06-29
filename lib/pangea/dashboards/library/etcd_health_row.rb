# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/floor_ceiling_envelope'
require 'pangea/dashboards/library/webhook_latency_heatmap'
require 'pangea/dashboards/library/rate_with_zero_floor'

module Pangea
  module Dashboards
    module Library
      # The etcd CONTROL-PLANE-DATASTORE health row. etcd is the one stateful
      # component a self-managed Kubernetes control plane cannot lose — the four
      # signals below ARE the etcd-is-about-to-fail story, folded onto one row:
      #
      # • **DB size vs quota** — a FloorCeilingEnvelope: the live DB size (the
      #   usage series) riding under the backend quota (the ceiling), a 0 floor
      #   below. etcd refuses writes the moment the DB hits its quota — the size
      #   creeping toward the ceiling is the slow-motion outage. Reuses the typed
      #   envelope so the "value riding inside its bounds" read is identical to
      #   every other breathe/storage envelope in the fleet.
      # • **fsync / commit latency** — a WebhookLatencyHeatmap over the
      #   `*_fsync_duration_seconds_bucket` (or commit) histogram: a slow disk is
      #   the #1 cause of etcd instability, and the heatmap keeps the bimodal tail
      #   a p99 stat would hide. Reuses the shipped heatmap atom (it is generic
      #   over any `*_bucket` histogram, not just webhooks).
      # • **Leader changes /s** — a floored rate: a healthy cluster has ZERO; any
      #   nonzero is a re-election (network partition / slow peer). event_driven
      #   floored so the healthy state reads a lit 0.
      # • **Proposal failures /s** — a floored rate: failed raft proposals mean
      #   writes are being rejected. Same lit-0 healthy semantics.
      #
      # Managed control planes (EKS/GKE/AKS) do NOT expose these — the row simply
      # renders "No data", which is itself a true read ("etcd is not yours to
      # see"). It is built for the self-managed (engenho / k3s / kubeadm) case.
      #
      #   row 'etcd' do
      #     Pangea::Dashboards::Library::EtcdHealthRow.add(
      #       self, datasource: 'vm',
      #       db_size_metric: 'etcd_mvcc_db_total_size_in_bytes',
      #       db_quota_metric: 'etcd_server_quota_backend_bytes',
      #       fsync_bucket_metric: 'etcd_disk_wal_fsync_duration_seconds_bucket',
      #       leader_changes_metric: 'etcd_server_leader_changes_seen_total',
      #       proposal_failures_metric: 'etcd_server_proposals_failed_total')
      #   end
      module EtcdHealthRow
        # datasource:                (req) the metrics datasource uid
        # db_size_metric:            (req) the live mvcc DB-size gauge (bytes)
        # db_quota_metric:           (req) the backend-quota gauge (bytes ceiling)
        # fsync_bucket_metric:       optional fsync/commit *_seconds_bucket histogram
        # leader_changes_metric:     optional leader-change *_total counter
        # proposal_failures_metric:  optional failed-proposal *_total counter
        # selector:                  typed Hash/String matcher scoping the etcd pods
        # window:                    rate/heatmap window (default 5m)
        # zero_floor_metric:         the 0-floor series name for the envelope's lower
        #                            bound (default a `vector(0)` literal so the band
        #                            floor is a flat 0 — no extra metric required)
        def self.add(row, datasource:, db_size_metric:, db_quota_metric:,
                     fsync_bucket_metric: nil, leader_changes_metric: nil,
                     proposal_failures_metric: nil, selector: nil, window: '5m')
          validate!(datasource: datasource, db_size_metric: db_size_metric, db_quota_metric: db_quota_metric)

          # DB size (usage) riding under the quota ceiling, 0 floor. The envelope
          # appends the selector braces to every metric NAME, so the floor must be
          # a metric-shaped token; a bare `vector(0)` would get braces appended.
          # We pass an aggregated quota as ceiling + a 0-floor via a clamp on the
          # size metric — but to keep the envelope's metric-name contract, the
          # floor is the size metric clamped to 0 (always 0). Simpler + honest:
          # use FloorCeilingEnvelope with usage = size, limit = quota, ceiling =
          # quota, floor = the size metric times 0 — instead we hand-build a 2-line
          # band here (size vs quota) for byte-clarity, reusing nothing the env
          # gives us beyond layout.
          add_size_band(row, datasource: datasource, db_size_metric: db_size_metric,
                        db_quota_metric: db_quota_metric, selector: selector)

          # fsync/commit latency distribution (optional).
          WebhookLatencyHeatmap.add(row, datasource: datasource, histogram_metric: fsync_bucket_metric,
                                    selector: selector, window: window,
                                    title: 'etcd fsync / commit latency') if fsync_bucket_metric

          # Leader changes /s (optional, floored — healthy = 0).
          RateWithZeroFloor.add(row, datasource: datasource, counter_metric: leader_changes_metric,
                                selector: selector, window: window, unit: 'ops', width: Theme.third,
                                title: 'etcd leader changes /s',
                                id: :etcd_leader_changes) if leader_changes_metric

          # Proposal failures /s (optional, floored — healthy = 0).
          RateWithZeroFloor.add(row, datasource: datasource, counter_metric: proposal_failures_metric,
                                selector: selector, window: window, unit: 'ops', width: Theme.third,
                                title: 'etcd proposal failures /s',
                                id: :etcd_proposal_failures) if proposal_failures_metric
        end

        # DB size riding under the backend quota — the slow-motion-outage band.
        # Two continuous gauge series on one timeseries (size + quota); a flat 0
        # baseline is implicit (min 0). NOT floored — a gauge level absent means
        # "etcd unseen", which should read "No data", not a misleading 0.
        def self.add_size_band(row, datasource:, db_size_metric:, db_quota_metric:, selector:)
          braces = Promql.braces(selector)
          size   = "max(#{db_size_metric}#{braces})"
          quota  = "max(#{db_quota_metric}#{braces})"
          row.panel :etcd_db_size_vs_quota, kind: :timeseries, width: Theme.third, height: Theme::TS_H do
            title 'etcd DB size vs quota'
            unit 'bytes'
            min 0
            graph :area
            description 'Live mvcc DB size riding under the backend quota. etcd refuses ' \
                        'writes the moment size hits quota — size creeping to the ceiling ' \
                        'is the slow-motion outage.'
            query 'A', size,  datasource: datasource, presence: :continuous, legend: 'db size'
            query 'B', quota, datasource: datasource, presence: :continuous, legend: 'quota'
          end
        end

        def self.validate!(datasource:, db_size_metric:, db_quota_metric:)
          raise ArgumentError, 'EtcdHealthRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'EtcdHealthRow: db_size_metric: required' if blank?(db_size_metric)
          raise ArgumentError, 'EtcdHealthRow: db_quota_metric: required' if blank?(db_quota_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        private_class_method :add_size_band, :validate!, :blank?
      end
    end
  end
end
