# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'
require 'pangea/dashboards/library/rate_with_zero_floor'

module Pangea
  module Dashboards
    module Library
      # The cache USE row — utilisation/saturation/effectiveness for any cache
      # exposing hits / misses / evictions counters. Four panels on one row:
      #
      #   • hit-ratio % — LIVENESS (HIGHER = healthier): hits/(hits+misses) over
      #     the window, ×100. A collapsing hit ratio means the cache stopped
      #     paying for itself (cold, undersized, or thrashing). liveness_steps —
      #     red below `hit_warn`, green at/above.
      #   • miss rate — the misses/s timeseries (floored). A rising miss rate is
      #     the leading indicator of the hit ratio about to fall.
      #   • eviction rate — the evictions/s timeseries (floored). Sustained
      #     evictions ⇒ the cache is too small for the working set.
      #   • cold-cache defect — a stat counting the moment the hit ratio drops
      #     below the warn floor (a defect tile, colour-flooded), so "is the
      #     cache cold right now?" is preattentive.
      #
      # Generic over any cache (gateway secret cache, an HTTP CDN, a Redis
      # instance, a build cache). The author supplies the three metric names;
      # the component owns the typed PromQL + the ratio maths.
      #
      #   row 'Cache effectiveness' do
      #     Pangea::Dashboards::Library::CacheEffectivenessRow.add(
      #       self, datasource: 'vm',
      #       hits_metric: 'cache_hits_total',
      #       misses_metric: 'cache_misses_total',
      #       evictions_metric: 'cache_evictions_total')
      #   end
      module CacheEffectivenessRow
        # datasource:       (req) the metrics datasource uid
        # hits_metric:      (req) the cache-hits *_total counter
        # misses_metric:    (req) the cache-misses *_total counter
        # evictions_metric: optional cache-evictions *_total counter
        # selector:         optional typed Hash/String matcher
        # window:           rate window (default 5m)
        # hit_warn/crit:    hit-ratio % thresholds (LIVENESS, default 90 / 70 —
        #                   red below 70%, amber below 90%, green at/above 90%);
        #                   `hit_warn` is the cold-cache defect floor
        def self.add(row, datasource:, hits_metric:, misses_metric:,
                     evictions_metric: nil, selector: nil, window: '5m',
                     hit_warn: 90, hit_crit: 70)
          validate!(datasource: datasource, hits_metric: hits_metric, misses_metric: misses_metric)

          # The optional eviction panel decides tiling: with it, four thirds +
          # a stat → use thirds; without, hit-ratio + miss share half/half plus
          # the defect stat. Keep widths uniform per the Gestalt alignment rule.
          show_evictions = !blank?(evictions_metric)
          ts_width = show_evictions ? Theme.third : Theme.half

          add_hit_ratio(row, datasource: datasource, hits_metric: hits_metric,
                        misses_metric: misses_metric, selector: selector, window: window,
                        hit_warn: hit_warn, hit_crit: hit_crit, width: ts_width)

          RateWithZeroFloor.add(row, datasource: datasource, counter_metric: misses_metric,
                                selector: selector, window: window, unit: 'ops', width: ts_width,
                                title: 'Miss rate', id: :"cache_miss_rate_#{slug(misses_metric)}")

          if show_evictions
            RateWithZeroFloor.add(row, datasource: datasource, counter_metric: evictions_metric,
                                  selector: selector, window: window, unit: 'ops', width: ts_width,
                                  title: 'Eviction rate', id: :"cache_evict_rate_#{slug(evictions_metric)}")
          end

          add_cold_defect(row, datasource: datasource, hits_metric: hits_metric,
                          misses_metric: misses_metric, selector: selector, window: window,
                          hit_warn: hit_warn)
        end

        # hit-ratio % liveness panel — hits/(hits+misses) ×100 over the window.
        def self.add_hit_ratio(row, datasource:, hits_metric:, misses_metric:, selector:, window:, hit_warn:, hit_crit:, width:)
          h = Promql.sum_rate(metric: hits_metric, window: window, selector: selector)
          m = Promql.sum_rate(metric: misses_metric, window: window, selector: selector)
          expr = "100 * (#{h}) / ((#{h}) + (#{m}))"
          row.panel :"cache_hit_ratio_#{slug(hits_metric)}", kind: :timeseries, width: width, height: Theme::TS_H do
            title 'Hit ratio %'
            unit 'percent'
            min 0
            max 100
            graph :area
            description 'Cache hit ratio over the window. LOWER is worse — a ' \
                        'collapsing ratio means the cache stopped paying off.'
            # continuous: defined whenever the cache sees traffic; an idle cache
            # reads NaN/no-data (the honest divide-by-zero answer), NOT a 0.
            query 'A', expr, datasource: datasource, presence: :continuous, legend: 'hit %'
            threshold steps: Theme.liveness_steps(ok: hit_crit) # red below crit
          end
        end

        # cold-cache defect stat — counts whether the hit ratio is below the
        # warn floor right now (1 = cold, colour-flooded red).
        def self.add_cold_defect(row, datasource:, hits_metric:, misses_metric:, selector:, window:, hit_warn:)
          h = Promql.sum_rate(metric: hits_metric, window: window, selector: selector)
          m = Promql.sum_rate(metric: misses_metric, window: window, selector: selector)
          ratio = "100 * (#{h}) / ((#{h}) + (#{m}))"
          expr  = Floor.zero("count(#{ratio} < #{hit_warn})")
          row.panel :"cache_cold_defect_#{slug(hits_metric)}", kind: :stat, width: Theme.third, height: Theme::STAT_H do
            title "Cold cache (hit% < #{hit_warn})"
            unit 'short'
            display :background
            graph :area
            description "Caches whose hit ratio is below #{hit_warn}%. RED ⇒ the " \
                        'cache is cold — warm it or resize it.'
            # event_driven: a healthy cache yields an empty `< warn` set → green 0.
            query 'A', expr, datasource: datasource, presence: :event_driven
            threshold steps: Theme.defect_steps(warn: 1, crit: 1)
          end
        end

        def self.validate!(datasource:, hits_metric:, misses_metric:)
          raise ArgumentError, 'CacheEffectivenessRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'CacheEffectivenessRow: hits_metric: required' if blank?(hits_metric)
          raise ArgumentError, 'CacheEffectivenessRow: misses_metric: required' if blank?(misses_metric)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :add_hit_ratio, :add_cold_defect, :validate!, :blank?, :slug
      end
    end
  end
end
