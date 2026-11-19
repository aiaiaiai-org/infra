#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "base64"
require "open3"
require "tempfile"

root = File.expand_path("..", __dir__)
load_yaml = ->(path) { YAML.safe_load(File.read(File.join(root, path)), aliases: false) }

bot = load_yaml.call("contracts/services/market-bot-test.yaml")
edge = load_yaml.call("contracts/edges/nilx-edge.yaml")
server = load_yaml.call("contracts/servers/edge-prod-1.yaml")
spec = bot.fetch("spec")
runtime = spec.fetch("runtime")
abort "wrong bot owner" unless bot.dig("metadata", "owner") == "0xda-market/telegram-bot"
abort "wrong address" unless spec["aliases"] == ["market-bot-development"] && spec["port"] == 10000
abort "wrong placement" unless server.dig("spec", "workloads").include?("market-bot-test")
route = edge.dig("spec", "routes").find { |r| r["service"] == "market-bot-test" }
abort "wrong Caddy route" unless route && route["upstream"] == "market-bot-development:10000"
abort "development must be isolated" unless runtime.fetch("environment").include?("DEPLOY_ENV=development")
abort "test must not register webhooks during activation" unless runtime.fetch("environment").include?("REGISTER_TELEGRAM_WEBHOOK=0")
abort "missing secrets" unless runtime.fetch("secrets").sort == %w[TELEGRAM_BOT_TOKEN=TELEGRAM_BOT_TOKEN TELEGRAM_WEBHOOK_SECRET=TELEGRAM_WEBHOOK_SECRET MARKET_API_TOKEN=MARKET_API_TOKEN TRADING_LAB_TOKEN=TRADING_LAB_TOKEN NILX_PARTNER_TOKEN=PARTNER_LOOKUP_TOKEN CHANNEL_ASSERTION_SECRET=CHANNEL_ASSERTION_SECRET].sort
abort "development bot must be delivered automatically" unless spec["delivery"] ==
  { "image" => "ghcr.io/0xda-market/telegram-bot", "branch" => "master", "signerWorkflow" => ".github/workflows/ci.yml" }
abort "bot must call the development Trading Lab" unless
  runtime.fetch("environment").include?("TRADING_LAB_ORIGIN=http://market-trading-lab-development:1703") &&
  runtime.fetch("secrets").include?("TRADING_LAB_TOKEN=TRADING_LAB_TOKEN")
abort "missing public vars" unless runtime.fetch("producerEnvironment").sort == %w[TELEGRAM_BOT_USERNAME MARKET_API_URL PUBLIC_URL NILX_IDENTITY_URL NILX_LINK_URL].sort

# Verify that the actual infra resolver and credential allowlist accept only configured names.
cmd = File.join(root, "scripts/resolve-workload-target.rb")
resolved, err, status = Open3.capture3({ "GITHUB_OUTPUT" => nil }, "ruby", cmd, "market-bot-test")
abort err unless status.success?
abort "resolver drift" unless resolved.include?("target=edge-prod-1\n") && resolved.include?("port=10000\n")

envelope = {
  "TELEGRAM_BOT_TOKEN" => "ci-only",
  "TELEGRAM_WEBHOOK_SECRET" => "ci-only-webhook",
  "MARKET_API_TOKEN" => "ci-only-api",
  "TRADING_LAB_TOKEN" => "ci-only-lab",
  "TELEGRAM_BOT_USERNAME" => "zeroxda_market_test_bot",
  "MARKET_API_URL" => "http://market-api-development:10000",
  "PUBLIC_URL" => "https://0xda-market.nilx.one/bot-test",
  "PARTNER_LOOKUP_TOKEN" => "p" * 64,
  "CHANNEL_ASSERTION_SECRET" => "c" * 64,
  "NILX_IDENTITY_URL" => "https://identity-dev.example",
  "NILX_LINK_URL" => "https://identity-dev.example/"
}
Tempfile.create("market-test-credentials") do |f|
  f.write(envelope.map { |key, value| "#{key}=#{value}\n" }.join)
  f.flush
  env = {
    "WORKLOAD_SECRETS" => Base64.strict_encode64(runtime.fetch("secrets").join("\n") + "\n"),
    "WORKLOAD_PRODUCER_ENVIRONMENT" => Base64.strict_encode64(runtime.fetch("producerEnvironment").join("\n") + "\n"),
    "WORKLOAD_SECRET_SOURCE_FILE" => f.path
  }
  packed, error, result = Open3.capture3(env, "ruby", File.join(root, "scripts/workload-secret-env.rb"))
  abort "envelope rejected: #{error}" unless result.success?
  values = Base64.strict_decode64(packed)
  expected_runtime = runtime.fetch("secrets").map do |mapping|
    name, source_name = mapping.split("=", 2)
    "#{name}=#{envelope.fetch(source_name)}"
  end
  expected_runtime.concat(Array(runtime["producerEnvironment"]).map { |name| "#{name}=#{envelope.fetch(name)}" })
  abort "missing bot credentials" unless values.lines.map(&:chomp).sort == expected_runtime.sort
  f.write("UNKNOWN_KEY=reject\n")
  f.flush
  _, _, result = Open3.capture3(env, "ruby", File.join(root, "scripts/workload-secret-env.rb"))
  abort "unreviewed variable accepted" if result.success?
end

puts "development bot deployment contract verified"
