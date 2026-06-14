# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/floor'
require 'pangea/dashboards/library/promql'

module Pangea
  module Dashboards
    module Library
      # The "is the controller alive, and which build?" answer made first-class.
      # Almost every pleme-io controller exports a `*_build_info` gauge — a
      # constant `1` carrying the running version as a label. Two facts fall out
      # of that one series, and this component surfaces both:
      #
      #   • controller UP + which build → a :stat of `max by(version)(build_info)`
      #     with LIVENESS thresholds (red below 1, green at/above) — a single
      #     green tile shows "alive", and the panel value carries the version.
      #   • controller DOWN → `absent(build_info{sel})`, a StatusOverview signal.
      #     When the controller stops exporting, the series vanishes; absent()
      #     becomes 1, and the defect tile fires red. The MISSING series IS the
      #     down signal, so Floor.zero must NOT floor it (a `or vector(0)` would
      #     mask the very absence we are watching for) — Floor.zero already skips
      #     absent() probes, which is exactly why the down signal stays honest.
      #
      # ── Absorbed from ───────────────────────────────────────────────────────
      # • breathe.rb        — the controller_up stat + the "Controller down" tile
      # • pangea_operator.rb — the up{job} liveness panel
      # …both hand-wrote the same `max by(version)(build_info)` + `absent(...)`
      # pair. This is that pair, solve-once.
      #
      # ── Usage ───────────────────────────────────────────────────────────────
      #   row 'Liveness' do
      #     Pangea::Dashboards::Library::BuildInfoLiveness.add(
      #       self, datasource: ds, build_info_metric: 'breathe_build_info',
      #       title: 'breathe')
      #   end
      #
      #   # …and feed the down signal into the StatusOverview headline:
      #   Pangea::Dashboards::Library::StatusOverview.add(self, datasource: ds,
      #     signals: [Pangea::Dashboards::Library::BuildInfoLiveness.down_signal(
      #       build_info_metric: 'breathe_build_info', name: 'breathe down')])
      module BuildInfoLiveness
        # Emit the controller-up :stat into `row`.
        #
        # build_info_metric: (req) the `*_build_info` gauge (constant 1 + version label)
        # binary_selector:   typed Hash/String matcher to scope to one binary
        # version_label:     the label carrying the build (default 'version')
        # title:             panel/legend title (default 'Controller')
        # datasource:        (req) metrics datasource uid (vm)
        def self.add(row, datasource:, build_info_metric:, binary_selector: nil,
                     version_label: 'version', title: 'Controller')
          validate!(datasource: datasource, build_info_metric: build_info_metric,
                    version_label: version_label)
          expr = up_expr(build_info_metric: build_info_metric, binary_selector: binary_selector,
                         version_label: version_label)
          pid  = :"build_info_up_#{slug(build_info_metric)}"
          ttl  = title
          row.panel pid, kind: :stat, width: Theme.third, height: Theme::STAT_H do
            title "#{ttl} up"
            unit 'short'
            description "#{ttl} liveness: max by(#{version_label}) of #{build_info_metric}. " \
                        'A green 1 = the controller is exporting (alive); the value ' \
                        'carries the running build. Red 0/absent = the controller is down.'
            display :background       # colour the tile — preattentive liveness
            # continuous: build_info is a constant-1 gauge while the controller
            # lives; its ABSENCE (not a 0) is the down signal (see down_signal).
            query 'A', expr, datasource: datasource, presence: :continuous,
                  legend: "{{#{version_label}}}"
            threshold steps: Theme.liveness_steps(ok: 1)
          end
        end

        # Return the StatusOverview defect signal for "controller down": an
        # `absent(build_info{sel})` probe that is 1 exactly when the series is
        # gone. Floor.zero leaves absent() alone, so the missing series stays the
        # signal. warn: 1 → the tile turns amber/red the moment it fires.
        #
        # build_info_metric: (req) the `*_build_info` gauge
        # binary_selector:   typed Hash/String matcher to scope to one binary
        # name:              the defect-tile title (default 'Controller down')
        def self.down_signal(build_info_metric:, binary_selector: nil, name: 'Controller down')
          validate_signal!(build_info_metric: build_info_metric, name: name)
          {
            name: name,
            expr: "absent(#{build_info_metric}#{Promql.braces(binary_selector)})",
            warn: 1,
            unit: 'short',
            desc: "1 when #{build_info_metric} stops being exported — the " \
                  'controller is down (the missing series IS the signal).'
          }
        end

        # ── helpers ────────────────────────────────────────────────────────────

        # max by(version)(build_info{sel}) — the live build, one series per
        # running version (a green 1 while alive).
        def self.up_expr(build_info_metric:, binary_selector:, version_label:)
          "max#{Promql.by(version_label)}(#{build_info_metric}#{Promql.braces(binary_selector)})"
        end

        def self.validate!(datasource:, build_info_metric:, version_label:)
          raise ArgumentError, 'BuildInfoLiveness: datasource: required' if blank?(datasource)
          raise ArgumentError, 'BuildInfoLiveness: build_info_metric: required' if blank?(build_info_metric)
          raise ArgumentError, 'BuildInfoLiveness: version_label: required' if blank?(version_label)
        end

        def self.validate_signal!(build_info_metric:, name:)
          raise ArgumentError, 'BuildInfoLiveness: build_info_metric: required' if blank?(build_info_metric)
          raise ArgumentError, 'BuildInfoLiveness: down_signal name: required' if blank?(name)
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :up_expr, :validate!, :validate_signal!, :blank?, :slug
      end
    end
  end
end
