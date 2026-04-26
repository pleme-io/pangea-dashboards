# frozen_string_literal: true

require 'pangea-core'
require 'pangea-dashboards/version'

# Dashboards: typed AST + Grafana/Datadog renderers + DSL + composition.
require 'pangea/dashboards'
require 'pangea/dashboards/types'
require 'pangea/dashboards/dsl'
require 'pangea/dashboards/composite'
require 'pangea/dashboards/library'
require 'pangea/dashboards/render/grafana'
require 'pangea/dashboards/render/datadog'

# Alerts: typed AST + Victoria/Prometheus/Datadog renderers + DSL.
require 'pangea/alerts'
require 'pangea/alerts/types'
require 'pangea/alerts/dsl'
require 'pangea/alerts/render/victoria'
require 'pangea/alerts/render/prometheus'
require 'pangea/alerts/render/datadog'

# Synth mixins.
require 'pangea/resources/dashboards'
require 'pangea/resources/alerts'
