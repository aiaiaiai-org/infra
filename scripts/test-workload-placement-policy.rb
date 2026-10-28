#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)

def reject_cross_edge_placement(workload, source, destination, expected_target)
  Dir.mktmpdir("infra-placement-") do |root|
    FileUtils.cp_r(File.join(ROOT, "contracts"), root)
    FileUtils.mkdir_p(File.join(root, "scripts"))
    FileUtils.cp(File.join(ROOT, "scripts", "validate-contracts.rb"), File.join(root, "scripts"))

    source_path = File.join(root, "contracts", "servers", "#{source}.yaml")
    destination_path = File.join(root, "contracts", "servers", "#{destination}.yaml")
    original = YAML.safe_load(File.read(source_path))
    misplaced = YAML.safe_load(File.read(destination_path))

    abort("missing test workload #{workload} on #{source}") unless original.dig("spec", "workloads").delete(workload)
    misplaced.fetch("spec").fetch("workloads") << workload
    File.write(source_path, YAML.dump(original))
    File.write(destination_path, YAML.dump(misplaced))

    _output, errors, status = Open3.capture3("ruby", File.join(root, "scripts", "validate-contracts.rb"))
    if status.success? || !errors.include?("workload #{workload}") || !errors.include?("belongs on #{expected_target}")
      abort("cross-edge placement of #{workload} was not rejected as expected: #{errors}")
    end
  end
end

reject_cross_edge_placement("prism-hubot", "edge-prod-2", "edge-prod-1", "edge-prod-2")
reject_cross_edge_placement("h-ua-bot", "edge-prod-2", "edge-prod-1", "edge-prod-2")
reject_cross_edge_placement("nilxone-web", "edge-prod-1", "edge-prod-2", "edge-prod-1")
reject_cross_edge_placement("market-api-production", "edge-prod-1", "edge-prod-2", "edge-prod-1")
reject_cross_edge_placement("market-trading-lab", "edge-prod-1", "edge-prod-2", "edge-prod-1")
reject_cross_edge_placement("market-postgres-production", "edge-prod-1", "edge-prod-2", "edge-prod-1")

puts("cross-edge workload placement is rejected for every product contour")
