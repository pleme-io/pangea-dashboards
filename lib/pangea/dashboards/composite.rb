# frozen_string_literal: true

require 'pangea/dashboards/types'

module Pangea
  module Dashboards
    # Composite — fold multiple Dashboard ASTs into one.
    #
    # Used to glue a stack of architectures into a single observability
    # surface:
    #
    #   vpc_dash    = Pangea::Architectures::SecureVpc.dashboard_for(synth, vpc_result)
    #   alb_dash    = Pangea::Architectures::IngressAlb.dashboard_for(synth, alb_result)
    #   merged      = Pangea::Dashboards::Composite.compose(
    #                   id: :network_overview,
    #                   title: 'Network overview',
    #                   uid: 'network-overview',
    #                   dashboards: [vpc_dash, alb_dash]
    #                 )
    #   synth.render_dashboard(merged, backend: :grafana, folder: 'network')
    #
    # The composite's rows are the union of input rows in declared
    # order. Variables, annotations, and tags are union-merged; ties
    # broken by first-occurrence.
    module Composite
      def self.compose(id:, title:, uid:, dashboards:, refresh: '30s',
                       tags: [], description: nil)
        rows         = dashboards.flat_map(&:rows)
        variables    = dashboards.flat_map(&:variables).uniq { |v| v.name }
        annotations  = dashboards.flat_map(&:annotations).uniq { |a| a.name }
        merged_tags  = (tags + dashboards.flat_map(&:tags)).uniq

        Types::Dashboard.new(
          id: id, title: title, uid: uid, description: description,
          tags: merged_tags, refresh: refresh,
          variables: variables, annotations: annotations,
          rows: rows
        )
      end
    end
  end
end
