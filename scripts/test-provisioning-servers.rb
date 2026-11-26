#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
# edge-dev-1 is an active deployment target now, so the isolation rules are exercised on a fixture
# that is enrolled but not yet reviewed, exactly what edge-dev-1 was before its activation.
SERVER = "contracts/servers/edge-fixture.yaml"
FIXTURE = {
  "apiVersion" => "infra.nilx.one/v1",
  "kind" => "ServerContract",
  "metadata" => { "name" => "edge-fixture", "owner" => "aiaiaiai-org/infra" },
  "spec" => {
    "state" => "provisioning", "provider" => "contabo", "role" => "development",
    "runtimeRoot" => "/opt/infra/targets/edge-fixture", "workloads" => []
  }
}.freeze

def verify(expect_success, expected_error = nil)
  Dir.mktmpdir("infra-provisioning-") do |root|
    FileUtils.cp_r(File.join(ROOT, "contracts"), root)
    FileUtils.mkdir_p(File.join(root, "scripts"))
    FileUtils.cp(File.join(ROOT, "scripts", "validate-contracts.rb"), File.join(root, "scripts"))

    contract_path = File.join(root, SERVER)
    contract = Marshal.load(Marshal.dump(FIXTURE))
    yield(contract, root) if block_given?
    File.write(contract_path, YAML.dump(contract))

    stdout, stderr, status = Open3.capture3("ruby", File.join(root, "scripts", "validate-contracts.rb"))
    abort("provisioning fixture unexpectedly #{status.success? ? 'passed' : 'failed'}: #{stdout} #{stderr}") unless status.success? == expect_success
    abort("missing expected error #{expected_error.inspect}: #{stderr}") if expected_error && !stderr.include?(expected_error)
  end
end

verify(true)
verify(false, "provisioning server must declare empty workloads") do |contract|
  contract["spec"]["workloads"] = ["nilxone-web"]
end
verify(false, "provisioning server must not declare an edge network") do |contract|
  contract["spec"]["edgeNetwork"] = "nilx-edge"
end
verify(false, "provisioning server must not expose public ports") do |contract|
  contract["spec"]["publicPorts"] = ["80/tcp"]
end
verify(false, "edgeNetwork must be the network of an edge") do |contract|
  contract["spec"]["state"] = "active"
end
verify(false, "state must be active, provisioning or retired") do |contract|
  contract["spec"]["state"] = "unknown"
end

verify(false, "is still provisioning") do |_contract, root|
  File.write(File.join(root, "contracts", "edges", "provisional.yaml"), YAML.dump({
    "apiVersion" => "infra.nilx.one/v1",
    "kind" => "EdgeContract",
    "metadata" => { "name" => "provisional", "owner" => "aiaiaiai-org/infra" },
    "spec" => {
      "placement" => { "target" => "edge-fixture" },
      "network" => { "name" => "nilx-dev-edge", "external" => true },
      "entrypoint" => { "service" => "caddy", "ports" => ["80/tcp"] },
      "routes" => [{ "id" => "unapproved", "host" => "dev.nilx.one",
                     "pathPrefix" => "/", "service" => "nilxone-web",
                     "upstream" => "nilxone-web:1927", "health" => "/health" }]
    }
  }))
end

puts "provisioning server remains isolated until activation is reviewed"
