# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Alerts::Render::Victoria, '#camelize' do
  it 'capitalizes plain words' do
    expect(described_class.camelize('pod_down')).to eq('PodDown')
    expect(described_class.camelize('high_error_rate')).to eq('HighErrorRate')
  end

  it 'preserves known abbreviations as ALL-CAPS' do
    expect(described_class.camelize('vm_disk_critical')).to eq('VMDiskCritical')
    expect(described_class.camelize('cpu_starvation')).to eq('CPUStarvation')
    expect(described_class.camelize('http_5xx_burst')).to eq('HTTP5xxBurst')
    expect(described_class.camelize('s3_bucket_drift')).to eq('S3BucketDrift')
    expect(described_class.camelize('k8s_api_unhealthy')).to eq('K8SAPIUnhealthy')
  end

  it 'handles single-token names' do
    expect(described_class.camelize('crash')).to eq('Crash')
    expect(described_class.camelize('vm')).to eq('VM')
  end

  it 'leaves unknown tokens capitalized' do
    expect(described_class.camelize('frobnicator_starved')).to eq('FrobnicatorStarved')
  end
end
