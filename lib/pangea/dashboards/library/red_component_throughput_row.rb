# frozen_string_literal: true

require 'pangea/dashboards/theme'
require 'pangea/dashboards/library/rate_with_zero_floor'

module Pangea
  module Dashboards
    module Library
      # The pipeline THROUGHPUT row — received/s vs sent/s (and optionally
      # received-bytes/s vs sent-bytes/s) for any ingest→transform→egress
      # component pipeline, each `sum by(component)(rate(counter[w]))` floored
      # so a quiet stage reads a true 0 instead of "No data". Generalises the
      # vector_pipeline "Throughput" + "By component kind" rows (events received
      # vs sent per component_id) and the dapr inbound-vs-outbound row — the
      # de-facto shape of every *_total component-pipeline counter where the
      # decision question is "is what comes in coming out?".
      #
      # Composes the Wave-0 RateWithZeroFloor atom once per counter so the
      # zero-floor / sum-by / legend discipline lives in ONE place (solve-once).
      # 2 counters → two half-width timeseries; add the byte counters and all
      # four tile third-width so the whole throughput story sits on one row.
      #
      #   row 'Throughput' do
      #     Pangea::Dashboards::Library::RedComponentThroughputRow.add(
      #       self, datasource: 'vm',
      #       in_counter: 'vector_component_received_events_total',
      #       out_counter: 'vector_component_sent_events_total',
      #       component_label: 'component_id')
      #   end
      module RedComponentThroughputRow
        # in_counter:        (req) the *_total counter for items ENTERING the stage
        # out_counter:       (req) the *_total counter for items LEAVING the stage
        # in_bytes_counter:  optional *_total bytes-received counter (BPS leg)
        # out_bytes_counter: optional *_total bytes-sent counter (BPS leg)
        # component_label:   label to sum by (default 'component_id')
        # window:            rate window (default 5m)
        # title:             title prefix for every leg (default 'Throughput')
        def self.add(row, datasource:, in_counter:, out_counter:,
                     in_bytes_counter: nil, out_bytes_counter: nil,
                     component_label: 'component_id', window: '5m', title: 'Throughput')
          validate!(datasource: datasource, in_counter: in_counter, out_counter: out_counter,
                    in_bytes_counter: in_bytes_counter, out_bytes_counter: out_bytes_counter)
          legs  = build_legs(in_counter, out_counter, in_bytes_counter, out_bytes_counter)
          width = Theme.tile_width(legs.length)
          gb    = component_label ? [component_label] : []
          legs.each do |leg|
            RateWithZeroFloor.add(row, datasource: datasource, counter_metric: leg[:metric],
                                  group_by: gb, window: window, unit: leg[:unit],
                                  width: width, title: "#{title} · #{leg[:label]}", id: leg[:id])
          end
        end

        # The ordered legs: events in/out always, bytes in/out only when given.
        # Each is a {metric:, label:, unit:, id:} the atom renders.
        def self.build_legs(in_counter, out_counter, in_bytes_counter, out_bytes_counter)
          legs = [
            { metric: in_counter,  label: 'received/s', unit: 'cps', id: :"throughput_in_#{slug(in_counter)}" },
            { metric: out_counter, label: 'sent/s',     unit: 'cps', id: :"throughput_out_#{slug(out_counter)}" }
          ]
          unless blank?(in_bytes_counter)
            legs << { metric: in_bytes_counter, label: 'received bytes/s', unit: 'Bps',
                      id: :"throughput_in_bytes_#{slug(in_bytes_counter)}" }
          end
          unless blank?(out_bytes_counter)
            legs << { metric: out_bytes_counter, label: 'sent bytes/s', unit: 'Bps',
                      id: :"throughput_out_bytes_#{slug(out_bytes_counter)}" }
          end
          legs
        end

        def self.validate!(datasource:, in_counter:, out_counter:, in_bytes_counter:, out_bytes_counter:)
          raise ArgumentError, 'RedComponentThroughputRow: datasource: required' if blank?(datasource)
          raise ArgumentError, 'RedComponentThroughputRow: in_counter: required' if blank?(in_counter)
          raise ArgumentError, 'RedComponentThroughputRow: out_counter: required' if blank?(out_counter)
          # Bytes legs are paired-or-neither only by convention; each is
          # independently optional, so no cross-validation beyond presence.
        end

        def self.blank?(v) = v.nil? || v.to_s.strip.empty?
        def self.slug(name) = name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        private_class_method :build_legs, :validate!, :blank?, :slug
      end
    end
  end
end
