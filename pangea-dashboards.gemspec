# frozen_string_literal: true
lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require_relative 'lib/pangea-dashboards/version'

Gem::Specification.new do |spec|
  spec.name = 'pangea-dashboards'
  spec.version = PangeaDashboards::VERSION
  spec.authors = ['drzzln']
  spec.email = ['drzzln@protonmail.com']
  spec.description = 'Backend-agnostic typed AST for observability dashboards. Authors define a Dashboard once via typed Dry::Struct nodes (Row, Panel, Query, Variable, Annotation); renderers emit Grafana JSON (via pangea-grafana) or Datadog widgets (via pangea-datadog). Same pattern as pangea-kubernetes serving 8 cluster backends from one typed surface.'
  spec.summary = 'Backend-agnostic dashboard AST + Grafana / Datadog renderers'
  spec.homepage = 'https://github.com/pleme-io/pangea-dashboards'
  spec.license = 'Apache-2.0'
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>=3.3.0'
  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.add_dependency 'pangea-core', '~> 0.2'
  spec.add_dependency 'dry-types', '~> 1.7'
  spec.add_dependency 'dry-struct', '~> 1.6'
  spec.add_development_dependency 'rspec', '~> 3.12'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
