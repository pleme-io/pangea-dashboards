# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Pangea
  module Dashboards
    module Library
      # `derive_panels(metrics: ...)` and `derive_panels_from_prefix(...)` —
      # auto-generate panels by iterating a list of metric names + a
      # per-panel template block.
      #
      # The literal-list form is sturdy: works with any Prometheus naming
      # convention without a live introspection client. The introspection
      # form hits a Prometheus `/api/v1/label/__name__/values` endpoint
      # to discover metric names matching a prefix, then delegates to the
      # literal form.
      #
      # Usage inside a row block:
      #
      #   row 'falco' do
      #     Pangea::Dashboards::Library::Derive.derive_panels_from_prefix(
      #       row: self,
      #       prefix: 'falco_',
      #       prometheus_url: 'http://vmsingle-vm.monitoring.svc:8429',
      #       kind: :stat
      #     ) do |metric|
      #       title metric.split('_').map(&:capitalize).join(' ')
      #       query 'A', "rate(#{metric}[5m])", datasource: 'vm'
      #     end
      #   end
      module Derive
        # Default HTTP fetcher. Returns the parsed JSON body or raises
        # IntrospectionError. Override with `http_client:` for testing
        # or for non-default auth (e.g. Bearer token).
        DEFAULT_HTTP_CLIENT = lambda do |url|
          uri = URI(url)
          response = Net::HTTP.get_response(uri)
          unless response.is_a?(Net::HTTPSuccess)
            raise IntrospectionError,
                  "Prometheus introspection HTTP #{response.code} from #{url}: #{response.body[0, 200]}"
          end
          JSON.parse(response.body)
        end

        # Cache keyed by URL — synth time should hit Prometheus at most
        # once per URL per process. Workspaces that call
        # derive_panels_from_prefix multiple times against the same store
        # share the discovery result.
        @cache = {}

        class IntrospectionError < StandardError; end

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

        # Discover metric names from Prometheus matching `prefix`, then
        # delegate to derive_panels. Cached per (url, prefix) pair to
        # avoid redundant HTTP at synth time.
        def self.derive_panels_from_prefix(row:, prefix:, prometheus_url:,
                                           kind: :stat, http_client: DEFAULT_HTTP_CLIENT, &block)
          raise ArgumentError, 'derive_panels_from_prefix requires a block' unless block

          metrics = fetch_metric_names(prometheus_url, http_client).select { |m| m.start_with?(prefix) }
          if metrics.empty?
            raise IntrospectionError,
                  "no metrics matching prefix #{prefix.inspect} at #{prometheus_url}"
          end

          derive_panels(row: row, metrics: metrics, kind: kind, &block)
        end

        # Hit /api/v1/label/__name__/values to enumerate every metric
        # name the store knows about. Returns the cached result if we've
        # already asked this URL during this synth run.
        def self.fetch_metric_names(prometheus_url, http_client)
          @cache[prometheus_url] ||= begin
            url = "#{prometheus_url.chomp('/')}/api/v1/label/__name__/values"
            data = http_client.call(url)
            unless data['status'] == 'success'
              raise IntrospectionError,
                    "Prometheus returned status=#{data['status']}: #{data['error']}"
            end
            unless data['data'].is_a?(Array)
              raise IntrospectionError,
                    "Prometheus response missing data array: #{data.inspect}"
            end
            data['data']
          end
        end

        # Reset the cache. Useful in test setup.
        def self.clear_cache!
          @cache = {}
        end
      end
    end
  end
end
