source 'https://rubygems.org'
gemspec
gem 'pangea-core', path: '../pangea-core'
# Renderers compose with these gems but don't hard-require them — the
# Grafana renderer optionally invokes Pangea::Grafana::DashboardBuilder
# when present, the Datadog renderer is standalone.
group :development do
  gem 'pangea-grafana', path: '../pangea-grafana'
  gem 'pangea-datadog', path: '../pangea-datadog'
end
