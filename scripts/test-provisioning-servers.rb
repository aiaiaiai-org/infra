#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"
ROOT = File.expand_path("..", __dir__)
SERVER = "contracts/servers/edge-dev-1.yaml"
EDGE = "contracts/edges/nilx-dev-edge.yaml"
SERVICE = "contracts/services/nilxone-web-development.yaml"

def unstage(contract, root)
  contract.fetch("spec")["state"] = "provisioning"
  contract["spec"].delete("edgeNetwork")
  contract["spec"].delete("publicPorts")
  contract["spec"]["workloads"] = []
  FileUtils.rm(File.join(root, EDGE))
  FileUtils.rm(File.join(root, SERVICE))
end

def verify(success, error = nil)
  Dir.mktmpdir("nilx-dev-placement-") do |root|
    FileUtils.cp_r(File.join(ROOT, "contracts"), root)
    FileUtils.mkdir_p(File.join(root, "scripts"))
    FileUtils.cp(File.join(ROOT, "scripts", "validate-contracts.rb"), File.join(root, "scripts"))
    file = File.join(root, SERVER)
    contract = YAML.safe_load(File.read(file))
    yield(contract, root) if block_given?
    File.write(file, YAML.dump(contract))
    out, err, status = Open3.capture3("ruby", File.join(root, "scripts", "validate-contracts.rb"))
    abort("unexpected validation status: #{out} #{err}") unless status.success? == success
    abort("missing expected validation error #{error}: #{err}") if error && !err.include?(error)
  end
end

verify(true)
verify(true) { |contract, root| unstage(contract, root) }
verify(false, "provisioning server must declare empty workloads") do |contract, root|
  unstage(contract, root)
  contract["spec"]["workloads"] = ["nilxone-web"]
end
verify(false, "provisioning server must not declare an edge network") do |contract, root|
  unstage(contract, root)
  contract["spec"]["edgeNetwork"] = "nilx-edge"
end
verify(false, "provisioning server must not expose public ports") do |contract, root|
  unstage(contract, root)
  contract["spec"]["publicPorts"] = ["80/tcp"]
end
verify(false, "state must be active or provisioning") do |contract|
  contract["spec"]["state"] = "unknown"
end
verify(false, "edgeNetwork must be the network of an edge") do |contract|
  contract["spec"]["edgeNetwork"] = "unknown"
end
verify(false, "is still provisioning") do |contract, root|
  unstage(contract, root)
  File.write(File.join(root, EDGE), YAML.dump({
    "apiVersion" => "infra.nilx.one/v1",
    "kind" => "EdgeContract",
    "metadata" => {"name" => "invalid-edge", "owner" => "aiaiaiai-org/infra"},
    "spec" => {
      "placement" => {"target" => "edge-dev-1"},
      "network" => {"name" => "nilx-dev-edge", "external" => true},
      "entrypoint" => {"service" => "caddy", "ports" => ["80/tcp"]},
      "routes" => [{"id" => "invalid", "service" => "nilxone-web", "host" => "dev.nilx.one",
                    "pathPrefix" => "/", "upstream" => "nilxone-web:1927", "health" => "/health"}]
    }
  }))
end
puts "active development and provisioning isolation validated"
