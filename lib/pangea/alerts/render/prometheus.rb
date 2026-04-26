# frozen_string_literal: true

require 'pangea/alerts/render/victoria'

module Pangea
  module Alerts
    module Render
      # AST → monitoring.coreos.com/v1 PrometheusRule manifest.
      #
      # Same shape as VMRule (the two CRDs are deliberately
      # interchangeable at the spec level — vmalert reads both). The
      # only difference is the apiVersion + kind. Reuses the Victoria
      # renderer's group/rule logic.
      module Prometheus
        API_VERSION = 'monitoring.coreos.com/v1'
        KIND        = 'PrometheusRule'

        def self.render(alerts, name_override: nil)
          base = Pangea::Alerts::Render::Victoria.render(alerts, name_override: name_override)
          base.merge(
            'apiVersion' => API_VERSION,
            'kind'       => KIND
          )
        end
      end
    end
  end
end
