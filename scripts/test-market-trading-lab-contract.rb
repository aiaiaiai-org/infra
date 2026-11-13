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

abort "Trading Lab must belong to new owner" unless service.dig("metadata", "owner") == "0xda-market/trading-lab"
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
  runtime.fetch("secrets") == ["TRADING_LAB_SERVICE_TOKEN=TRADING_LAB_SERVICE_TOKEN", "TRADING_LAB_DATABASE_URL=TRADING_LAB_DATABASE_URL"]
abort "missing edge placement" unless server.dig("spec", "workloads").include?("market-trading-lab")
abort "Trading Lab must not have a public route" if edge.dig("spec", "routes").any? { |route| route["service"] == "market-trading-lab" }

stdout, stderr, status = Open3.capture3({ "GITHUB_OUTPUT" => nil }, "ruby", File.join(ROOT, "scripts/resolve-workload-target.rb"), "market-trading-lab")
abort stderr unless status.success?
%w[target=edge-prod-1 network=nilx-edge alias=market-trading-lab port=1927 health=/health].each do |line|
  abort "invalid resolution: #{line}" unless stdout.lines.map(&:strip).include?(line)
end

Tempfile.create("trading-lab-credential") do |file|
  file.write("TRADING_LAB_SERVICE_TOKEN=ci-not-real\nTRADING_LAB_DATABASE_URL=postgres://trading_lab:x@market-postgres-production:1927/trading_lab\n")
  file.flush
  env = {
    "WORKLOAD_SECRETS" => Base64.strict_encode64(runtime.fetch("secrets").join("\n") + "\n"),
    "WORKLOAD_SECRET_SOURCE_FILE" => file.path
  }
  encoded, error, code = Open3.capture3(env, "ruby", File.join(ROOT, "scripts/workload-secret-env.rb"))
  abort error unless code.success?
  abort "missing service secrets" unless Base64.strict_decode64(encoded).lines.sort ==
    ["TRADING_LAB_DATABASE_URL=postgres://trading_lab:x@market-postgres-production:1927/trading_lab\n", "TRADING_LAB_SERVICE_TOKEN=ci-not-real\n"]

  file.write("UNKNOWN_SECRET=refuse\n")
  file.flush
  _, _, code = Open3.capture3(env, "ruby", File.join(ROOT, "scripts/workload-secret-env.rb"))
  abort "unexpected extra credentials accepted" if code.success?
end

development = load_contract.call("contracts/services/market-trading-lab-development.yaml")
dev = development.fetch("spec")
abort "development Trading Lab owner" unless development.dig("metadata", "owner") == "0xda-market/trading-lab"
abort "invalid development Trading Lab settings" unless
  dev["deployment"] == "test" && dev["network"] == "nilx-edge" && dev["aliases"] == ["market-trading-lab-development"] &&
  dev["port"] == 1703 && dev["health"] == "/health" && !dev.key?("public") &&
  dev.dig("runtime", "environment") == ["PORT=1703"] &&
  dev.dig("runtime", "secrets") == ["TRADING_LAB_SERVICE_TOKEN=TRADING_LAB_SERVICE_TOKEN"]
abort "development Trading Lab delivery" unless dev["delivery"] ==
  { "image" => "ghcr.io/0xda-market/trading-lab", "branch" => "master", "signerWorkflow" => ".github/workflows/ci.yml" }
abort "missing development placement" unless server.dig("spec", "workloads").include?("market-trading-lab-development")
abort "edge-prod-1 needs an encryption recipient" unless server.dig("spec", "encryptionRecipient").to_s.start_with?("ssh-ed25519 ")
abort "development Trading Lab must not have a public route" if edge.dig("spec", "routes").any? { |route| route["service"] == "market-trading-lab-development" }
dev_out, dev_err, dev_status = Open3.capture3({ "GITHUB_OUTPUT" => nil }, "ruby", File.join(ROOT, "scripts/resolve-workload-target.rb"), "market-trading-lab-development")
abort dev_err unless dev_status.success?
%w[target=edge-prod-1 alias=market-trading-lab-development port=1703].each do |line|
  abort "invalid development resolution: #{line}" unless dev_out.lines.map(&:strip).include?(line)
end

# The OKX collector: production only, no listener, and nothing but the research database.
collector = load_contract.call("contracts/services/market-trading-lab-okx-collector.yaml")
col = collector.fetch("spec")
abort "collector owner" unless collector.dig("metadata", "owner") == "0xda-market/trading-lab"
abort "invalid collector settings" unless
  col["deployment"] == "production" && col["network"] == "nilx-edge" && col["aliases"] == ["market-trading-lab-okx-collector"] &&
  col["healthKind"] == "process" && !col.key?("public") && !col.key?("delivery") &&
  col.dig("runtime", "command") == %w[bundle exec ruby bin/trading-lab collect-okx]
abort "collector must hold only the research database" unless col.dig("runtime", "secrets") == ["TRADING_LAB_DATABASE_URL=TRADING_LAB_DATABASE_URL"]
abort "missing collector placement" unless server.dig("spec", "workloads").include?("market-trading-lab-okx-collector")
abort "collector must not have a public route" if edge.dig("spec", "routes").any? { |route| route["service"] == "market-trading-lab-okx-collector" }
Tempfile.create("collector-credential") do |file|
  env = { "WORKLOAD_SECRETS" => Base64.strict_encode64(col.dig("runtime", "secrets").join("\n") + "\n"), "WORKLOAD_SECRET_SOURCE_FILE" => file.path }
  file.write("TRADING_LAB_DATABASE_URL=postgres://trading_lab:x@market-postgres-production:1927/trading_lab\n")
  file.flush
  _, error, code = Open3.capture3(env, "ruby", File.join(ROOT, "scripts/workload-secret-env.rb"))
  abort error unless code.success?
  # The service envelope carries the service token, which a collector must not receive.
  file.write("TRADING_LAB_SERVICE_TOKEN=ci-not-real\n")
  file.flush
  _, _, code = Open3.capture3(env, "ruby", File.join(ROOT, "scripts/workload-secret-env.rb"))
  abort "collector accepted the service envelope" if code.success?
end

# Development deliberately has no research database (docs/market-trading-lab.md).
abort "development Trading Lab must not get a database" if dev.dig("runtime", "secrets").any? { |entry| entry.include?("DATABASE") }

puts "private Trading Lab workload placement and secret contract verified"
