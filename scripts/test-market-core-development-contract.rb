#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "yaml"
require "base64"
require "open3"
require "tempfile"

root = File.expand_path("..", __dir__)
read = ->(path) { YAML.safe_load(File.read(File.join(root, path)), aliases: false) }
server = read.call("contracts/servers/edge-prod-1.yaml")
edge = read.call("contracts/edges/nilx-edge.yaml")
workloads = %w[market-api-development market-fx-development market-prices-development]
command = {
  "market-fx-development" => %w[bundle exec ruby bin/refresh_fx_rates_loop],
  "market-prices-development" => %w[bundle exec ruby bin/refresh_market_prices_loop]
}

workloads.each do |id|
  contract = read.call("contracts/services/#{id}.yaml")
  spec = contract.fetch("spec")
  runtime = spec.fetch("runtime")
  abort "wrong owner" unless contract.dig("metadata", "owner") == "0xda-market/core"
  abort "wrong target" unless server.dig("spec", "workloads").include?(id)
  abort "wrong environment" unless spec["deployment"] == "test" && spec["network"] == "nilx-edge"
  abort "not isolated" unless runtime.fetch("environment").include?("DEPLOY_ENV=development")
  abort "wrong alias" unless spec.fetch("aliases") == [id]
  abort "public exposure forbidden" if edge.dig("spec", "routes").any? { |route| route["service"] == id }
  abort "static environment missing" unless runtime.fetch("environment").is_a?(Array)

  if id == "market-api-development"
    abort "wrong API port" unless spec["port"] == 10000 && spec["health"] == "/health"
    abort "wrong API secrets" unless runtime.fetch("secrets").sort ==
      %w[DATABASE_URL=DATABASE_URL PUBLIC_API_TOKEN=PUBLIC_API_TOKEN MANUAL_PROVIDER_TOKEN=MANUAL_PROVIDER_TOKEN NILX_BROWSER_HANDOFF_TOKEN=NILX_BROWSER_HANDOFF_TOKEN].sort
  else
    abort "worker port must be private" unless spec["port"] == 1703 && spec["healthKind"] == "process"
    abort "unexpected worker command" unless runtime.fetch("command") == command.fetch(id)
    abort "worker must only access database" unless runtime.fetch("secrets") == ["DATABASE_URL=DATABASE_URL"]
  end

  output, err, result = Open3.capture3({ "GITHUB_OUTPUT" => nil }, "ruby",
    File.join(root, "scripts/resolve-workload-target.rb"), id)
  abort err unless result.success?
  abort "resolver target drift" unless output.include?("target=edge-prod-1\n")
  expected = command.fetch(id, [])
  if expected.any?
    encoded = output[/^command=(.*)$/, 1]
    abort "worker command drift" unless Base64.strict_decode64(encoded).lines.map(&:strip) == expected
  end

  credentials = { "DATABASE_URL" => "postgresql://postgres.test:example@aws-0.pooler.supabase.com:5432/postgres" }
  if id == "market-api-development"
    credentials["PUBLIC_API_TOKEN"] = "ci-only-api-token"
    credentials["MANUAL_PROVIDER_TOKEN"] = "ci-only-manual-token"
    credentials["NILX_BROWSER_HANDOFF_TOKEN"] = "h" * 64
  end
  Tempfile.create("market-core-credentials") do |f|
    credentials.each { |k,v| f.write("#{k}=#{v}\n") }
    f.flush
    env = {
      "WORKLOAD" => id,
      "WORKLOAD_SECRETS" => Base64.strict_encode64(runtime.fetch("secrets").join("\n") + "\n"),
      "WORKLOAD_SECRET_SOURCE_FILE" => f.path
    }
    packed, error, status = Open3.capture3(env, "ruby", File.join(root, "scripts/workload-secret-env.rb"))
    abort error unless status.success?
    values = Base64.strict_decode64(packed)
    abort "credentials mismatch" unless credentials.all? { |k,v| values.include?("#{k}=#{v}\n") }
    f.write("PRODUCTION_TOKEN=reject\n")
    f.flush
    _, _, status = Open3.capture3(env, "ruby", File.join(root, "scripts/workload-secret-env.rb"))
    abort "undeclared credential accepted" if status.success?
  end
end

puts "development Core + worker contracts verified"
