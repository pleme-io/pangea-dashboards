# frozen_string_literal: true

module Pangea
  module Dashboards
    module Library
      # `derive_panels_from(metrics: ...)` — auto-generate panels by
      # iterating a list of metric names + a per-panel template block.
      #
      # The literal-list form is the sturdy v1: works with any Prometheus
      # metric naming convention without a live introspection client.
      # The introspection form (`metric_prefix:` + a Prometheus URL) is
      # documented as a follow-up — needs a small HTTP client + cache,
      # not yet implemented.
      #
      # Usage inside a row block:
      #
      #   row 'falco' do
      #     Pangea::Dashboards::Library::Derive.derive_panels(
      #       row: self,
      #       metrics: %w[falco_events_total falco_drops_total],
      #       kind: :stat
      #     ) do |metric|
      #       title metric.split('_').map(&:capitalize).join(' ')
      #       query 'A', "rate(#{metric}[5m])", datasource: 'vm'
      #     end
      #   end
      module Derive
        # Emit one panel per metric, applying the block to each panel.
        # `row` is the current RowBuilder (passed because we need to
        # invoke its `panel` method on the consumer's behalf).
        def self.derive_panels(row:, metrics:, kind: :stat, &block)
          raise ArgumentError, 'derive_panels requires a block' unless block

          metrics.each do |metric|
            panel_id = metric.to_sym
            row.panel(panel_id, kind: kind) do
              # Default title from the metric name; the block can override.
              title metric.split('_').map(&:capitalize).join(' ')
              # Yield the metric so the block can compose queries / titles
              # against the actual metric name.
              instance_exec(metric, &block)
            end
          end
        end

        # Stub for the introspection variant. Documents the intended
        # shape; raises NotImplementedError until the HTTP client lands.
        def self.derive_panels_from_prefix(row:, prefix:, prometheus_url:, kind: :stat, &block)
          raise NotImplementedError,
                'derive_panels_from_prefix needs a Prometheus introspection HTTP client; not yet built. ' \
                "Use derive_panels(metrics: [...]) with an explicit list for now."
        end
      end
    end
  end
end
