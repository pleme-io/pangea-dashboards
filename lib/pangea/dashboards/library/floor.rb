# frozen_string_literal: true

module Pangea
  module Dashboards
    module Library
      # The shared zero-floor primitive. An event-driven counter has no series
      # until its first event, so a healthy workload's rate/count reads "No
      # data" — ambiguous (broken? or fine?). Appending `or vector(0)` makes
      # healthy a true 0, so every event-driven panel is honest and always lit.
      #
      # Extracted from StatusOverview.ensure_zero_floor so every component that
      # renders an event-driven series (RateWithZeroFloor, the Errors leg of
      # GoldenSignalsRow, the backpressure tiles of QuotaPctSambaRow, …) floors
      # through ONE place — solve-once, per the prime directive.
      module Floor
        # Append `or vector(0)` unless the expr already guarantees a value
        # (it already contains a vector() literal, or is an absent() probe
        # whose whole point is the missing-series semantics).
        def self.zero(expr)
          e = expr.to_s
          return e if e.include?('vector(') || e.strip.start_with?('absent')
          "#{e} or vector(0)"
        end
      end
    end
  end
end
