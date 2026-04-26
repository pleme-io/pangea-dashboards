# frozen_string_literal: true

require 'pangea/alerts/types'

module Pangea
  module Alerts
    module Render
      # AST → operator.victoriametrics.com/v1beta1 VMRule manifest.
      #
      # Returns a Hash. Workspace serializes to YAML + writes to a
      # FluxCD-managed cluster manifest path (typically
      # `clusters/<cluster>/infrastructure/<arch>/alerts.yaml`).
      module Victoria
        API_VERSION = 'operator.victoriametrics.com/v1beta1'
        KIND        = 'VMRule'

        def self.render(alerts, name_override: nil)
          {
            'apiVersion' => API_VERSION,
            'kind'       => KIND,
            'metadata'   => {
              'name'      => name_override || alerts.id.to_s.tr('_', '-'),
              'namespace' => alerts.namespace,
              'labels'    => alerts.labels
            },
            'spec' => {
              'groups' => alerts.groups.map { |g| render_group(g) }
            }
          }
        end

        def self.render_group(group)
          {
            'name'     => group.name,
            'interval' => group.interval,
            'rules'    => group.rules.map { |r| render_rule(r) }
          }
        end

        def self.render_rule(rule)
          h = {
            'alert'  => camelize(rule.name.to_s),
            'expr'   => rule.expr,
            'for'    => rule.for_,
            'labels' => { 'severity' => rule.severity }.merge(rule.labels)
          }
          unless rule.annotations.empty?
            h['annotations'] = rule.annotations.transform_keys(&:to_s)
          end
          h
        end

        # snake_case → CamelCase for the Prometheus alertname convention.
        # Preserves common abbreviations as ALL-CAPS rather than
        # capitalizing only the first letter (vm_disk → VMDisk, NOT VmDisk).
        ABBREVIATIONS = %w[
          VM CPU GPU IO ID URL URI HTTP HTTPS TLS SSL DNS API SDK
          K8S KMS IAM ARN VPC NAT NLB ALB ELB SQS SNS S3 RDS EC2
          DB SQL CSV JSON YAML XML HTML CSS JS TCP UDP IP ICMP MTU
          AZ NUMA SMP MMU TLB CRD RBAC OIDC SAML JWT
          ASG EKS ECS GKE AKS NTFY VPN WAF CDN OOM
        ].freeze

        ABBREVIATION_LOOKUP = ABBREVIATIONS.each_with_object({}) { |a, h| h[a.downcase] = a }.freeze

        def self.camelize(name)
          name.split('_').map { |chunk| ABBREVIATION_LOOKUP[chunk] || chunk.capitalize }.join
        end
      end
    end
  end
end
