# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/rate_with_zero_floor'

module Pangea
  module Dashboards
    module Library
      # The autoscaler POOL STRIP — an overview-strip atom that answers "how
      # big is each pool right now, and is the scaler keeping up?" in one
      # glance. A uniform grid of pool-cardinality :gauge tiles (one per
      # pool role: desired / idle / running / pending …), optionally followed
      # by a current-vs-max replica :timeseries and a floored scaler-error
      # rate. The cardinalities are preattentive (size of the number is the
      # signal); the current-vs-max trend shows whether the pool is pinned at
      # its ceiling; the error rate lights up the moment the scaler can't act.
      #
      # Absorbed from the akeylesslabs github-actions ARC autoscaler-pool-gauges
      # (desired/idle/running runner tiles) and the keda scaler-error + replica
      # timeline. Provider-agnostic by metric INJECTION — the same strip covers
      # ARC, KEDA, and Karpenter by passing each system's metrics:
      #   • ARC      pool_roles: { desired: '…', idle: '…', running: '…' }
      #   • KEDA     current/max from kube_*_status_replicas, error from
      #              keda_scaler_errors_total
      #   • Karpenter pool_roles over karpenter_nodes_*; error from
      #              karpenter_*_errors_total
      #
      #   row 'Autoscaler' do
      #     Pangea::Dashboards::Library::AutoscalerPoolStrip.add(
      #       self, datasource: 'vm',
      #       pool_roles: {
      #         desired: 'sum(github_runner_scale_set_desired_replicas)',
      #         idle:    'sum(github_runner_scale_set_idle_runners)',
      #         running: 'sum(github_runner_scale_set_running_jobs)'
      #       },
      #       max_metric: 'kube_horizontalpodautoscaler_spec_max_replicas',
      #       current_metric: 'kube_horizontalpodautoscaler_status_current_replicas',
      #       error_metric: 'keda_scaler_errors_total',
      #       selector: { scaledobject: 'runners' })
      #   end
      module AutoscalerPoolStrip
        # pool_roles:     (req) Hash{ role => PromQL expr } — one cardinality
        #                 gauge tile per entry, in declared order. Exprs are
        #                 already-complete PromQL (NOT a metric to wrap), so the
        #                 author keeps full control of the aggregation.
        # max_metric:     *_max_replicas gauge — drawn as the ceiling line on
        #                 the current-vs-max timeseries (omit to skip the chart)
        # current_metric: *_current_replicas gauge — the replica line; both
        #                 max_metric AND current_metric are needed for the chart
        # error_metric:   scaler-error *_total counter — a floored RateWithZeroFloor
        #                 timeseries (omit to skip). event_driven: 0 = healthy.
        # selector:       typed Hash/String matcher applied to max/current/error
        #                 metrics (NOT to the pool_roles exprs, which are whole)
        # title:          strip title prefix (default 'Autoscaler')
        def self.add(row, datasource:, pool_roles:, max_metric: nil, current_metric: nil,
                     error_metric: nil, selector: nil, title: 'Autoscaler')
          validate!(datasource: datasource, pool_roles: pool_roles)

          # ── Pool-cardinality gauge tiles (one per role) ──
          width = Theme.tile_width(pool_roles.length)
          pool_roles.each_with_index do |(role, expr), idx|
            add_pool_tile(row, datasource: datasource, role: role, expr: expr,
                          width: width, idx: idx, title_prefix: title)
          end

          # ── Current-vs-max replica timeseries (optional) ──
          add_replica_timeline(row, datasource: datasource, max_metric: max_metric,
                               current_metric: current_metric, selector: selector,
                               title_prefix: title) if max_metric && current_metric

          # ── Scaler-error rate (optional, floored) ──
          RateWithZeroFloor.add(row, datasource: datasource, counter_metric: error_metric,
                                selector: selector, width: Theme.third, unit: 'errps',
                                title: "#{title} · scaler errors",
                                id: :"autoscaler_errors_#{slug(error_metric)}") if error_metric
        end

        # One pool-cardinality gauge — a single number that IS the pool's size
        # for that role. event_driven floored so an idle pool reads a true 0,
        # never ambiguous "No data".
        def self.add_pool_tile(row, datasource:, role:, expr:, width:, idx:, title_prefix:)
          q   = Floor.zero(expr)
          pid = :"autoscaler_pool_#{slug(role)}_#{idx}"
          row.panel pid, kind: :gauge, width: width, height: Theme::STAT_H do
            title role.to_s.tr('_', ' ').capitalize
            unit 'short'
            min 0
            graph :area
            query 'A', q, datasource: datasource, presence: :event_driven
          end
        end

        # current replicas vs the max-replicas ceiling — the trend that shows
        # whether the pool is pinned at its limit (scaling-out exhausted).
        def self.add_replica_timeline(row, datasource:, max_metric:, current_metric:, selector:, title_prefix:)
          braces = Promql.braces(selector)
          cur    = Floor.zero("sum(#{current_metric}#{braces})")
          mx     = Floor.zero("sum(#{max_metric}#{braces})")
          row.panel :autoscaler_replicas, kind: :timeseries, width: Theme.two_thirds, height: Theme::TS_H do
            title "#{title_prefix} · replicas (current vs max)"
            unit 'short'
            min 0
            graph :area
            query 'A', cur, datasource: datasource, presence: :continuous, legend: 'current'
            query 'B', mx, datasource: datasource, presence: :continuous, legend: 'max'
          end
        end

        def self.validate!(datasource:, pool_roles:)
          raise ArgumentError, 'AutoscalerPoolStrip: datasource: required' if blank?(datasource)
          raise ArgumentError, 'AutoscalerPoolStrip: pool_roles must be a non-empty Hash' \
            unless pool_roles.is_a?(Hash) && !pool_roles.empty?
          pool_roles.each do |role, expr|
            raise ArgumentError, "AutoscalerPoolStrip: pool role #{role.inspect} needs a non-empty expr" \
              if blank?(expr)
          end
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_pool_tile, :add_replica_timeline, :validate!, :blank?, :slug
      end
    end
  end
end
