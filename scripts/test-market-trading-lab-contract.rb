#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "tempfile"
require "yaml"

ROOT = File.expand_path("..", __dir__)
load_contract = ->(path) { YAML.safe_load_file(File.join(ROOT, path), aliases: false) }
service = load_contract.call("contracts/services/market-trading-lab.yaml")
server = load_contract.call("contracts/servers/edge-prod-1.yaml")
edge = load_contract.call("contracts/edges/nilx-edge.yaml")
spec = service.fetch("spec")
runtime = spec.fetch("runtime")

abort "Trading Lab must belong to new owner" unless service.dig("metadata", "owner") == "0x0sky/trading-lab"
abort "invalid internal service settings" unless
  spec["deployment"] == "production" &&
  spec["network"] == "nilx-edge" &&
  spec["aliases"] == ["market-trading-lab"] &&
  spec["port"] == 1927 &&
  spec["health"] == "/health" &&
  runtime["kind"] == "container"

abort "Trading Lab must not declare a public origin" if spec.key?("public")
abort "unexpected Trading Lab environment" unless runtime.fetch("environment") == ["PORT=1927"]
abort "unexpected Trading Lab secret allowlist" unless
  runtime.fetch("secrets") == ["TRADING_LAB_SERVICE_TOKEN=TRADING_LAB_SERVICE_TOKEN"]
abort "missing edge placement" unless server.dig("spec", "workloads").include?("market-trading-lab")
abort "Trading Lab must not have a public route" if edge.dig("spec", "routes").any? { |route| route["service"] == "market-trading-lab" }

stdout, stderr, status = Open3.capture3({ "GITHUB_OUTPUT" => nil }, "ruby", File.join(ROOT, "scripts/resolve-workload-target.rb"), "market-trading-lab")
abort stderr unless status.success?
%w[target=edge-prod-1 network=nilx-edge alias=market-trading-lab port=1927 health=/health].each do |line|
  abort "invalid resolution: #{line}" unless stdout.lines.map(&:strip).include?(line)
end

Tempfile.create("trading-lab-credential") do |file|
  file.write("TRADING_LAB_SERVICE_TOKEN=ci-not-real\n")
  file.flush
  env = {
    "WORKLOAD_SECRETS" => Base64.strict_encode64(runtime.fetch("secrets").join("\n") + "\n"),
    "WORKLOAD_SECRET_SOURCE_FILE" => file.path
  }
  encoded, error, code = Open3.capture3(env, "ruby", File.join(ROOT, "scripts/workload-secret-env.rb"))
  abort error unless code.success?
  abort "missing service secret" unless Base64.strict_decode64(encoded) == "TRADING_LAB_SERVICE_TOKEN=ci-not-real\n"

  file.write("UNKNOWN_SECRET=refuse\n")
  file.flush
  _, _, code = Open3.capture3(env, "ruby", File.join(ROOT, "scripts/workload-secret-env.rb"))
  abort "unexpected extra credentials accepted" if code.success?
end

puts "private Trading Lab workload placement and secret contract verified"
