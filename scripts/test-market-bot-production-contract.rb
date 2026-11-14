#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "yaml"

root = File.expand_path("..", __dir__)
load_contract = ->(path) { YAML.safe_load(File.read(File.join(root, path)), aliases: false) }
bot = load_contract.call("contracts/services/market-bot-production.yaml")
test_bot = load_contract.call("contracts/services/market-bot-test.yaml")
edge = load_contract.call("contracts/edges/nilx-edge.yaml")
server = load_contract.call("contracts/servers/edge-prod-1.yaml")
caddy = File.read(File.join(root, "deploy/edge/Caddyfile"))
upstream_checks = File.read(File.join(root, "deploy/edge/check-upstreams.sh"))

abort "wrong production bot owner" unless bot.dig("metadata", "owner") == "0xda-market/telegram-bot"
spec = bot.fetch("spec")
runtime = spec.fetch("runtime")
abort "production must use its own identity and port" unless
  spec["deployment"] == "production" &&
  spec["aliases"] == ["market-bot-production"] &&
  spec["port"] == 1927 &&
  runtime["kind"] == "container"
abort "production bot not placed on edge-prod-1" unless server.dig("spec", "workloads").include?("market-bot-production")
abort "must not reuse test bot alias" if spec["aliases"] == test_bot.dig("spec", "aliases")

environment = runtime.fetch("environment")
%w[
  DEPLOY_ENV=production
  MARKET_CORE_ENV=production
  PORT=1927
  REGISTER_TELEGRAM_WEBHOOK=0
  REGISTER_TELEGRAM_WEBAPP=0
  TRADING_LAB_ORIGIN=http://market-trading-lab:1927
].each { |key| abort "missing safe production environment #{key}" unless environment.include?(key) }
abort "production credentials cannot be plain environment strings" if
  environment.any? { |line| line.start_with?("TELEGRAM_BOT_TOKEN=", "MARKET_API_TOKEN=") }

expected_secrets = %w[
  TELEGRAM_BOT_TOKEN=TELEGRAM_BOT_TOKEN
  TELEGRAM_WEBHOOK_SECRET=TELEGRAM_WEBHOOK_SECRET
  MARKET_API_TOKEN=MARKET_API_TOKEN
  TRADING_LAB_TOKEN=TRADING_LAB_TOKEN
  FOUR_X_ERRORS_URL=FOUR_X_ERRORS_URL
  FOUR_X_ERRORS_TOKEN=FOUR_X_ERRORS_TOKEN
]
abort "unexpected secrets mapping" unless runtime.fetch("secrets").sort == expected_secrets.sort
abort "production must supply its own bot identity, API and public URL" unless
  runtime.fetch("producerEnvironment").sort == %w[TELEGRAM_BOT_USERNAME MARKET_API_URL PUBLIC_URL].sort
abort "prod must never share dev's delivery image" if
  spec.dig("delivery", "image") == test_bot.dig("spec", "delivery", "image")
abort "production must never deploy on schedule" unless spec.fetch("delivery") == {
  "image" => "ghcr.io/0xda-market/telegram-bot-production",
  "branch" => "master",
  "signerWorkflow" => ".github/workflows/publish-production.yml",
  "mode" => "manual"
}

route = edge.dig("spec", "routes").find { |entry| entry["service"] == "market-bot-production" }
abort "production edge route missing" unless
  route &&
  route["pathPrefix"] == "/bot/" &&
  route["upstream"] == "market-bot-production:1927"
abort "Caddy must use production contract port" unless
  caddy.include?("reverse_proxy market-bot-production:1927") &&
  !caddy.include?("reverse_proxy market-bot-production:10000")
abort "development Caddy route must be untouched" unless
  caddy.include?("reverse_proxy market-bot-development:10000")
abort "production upstream health check must use contract port" unless
  upstream_checks.include?("http://market-bot-production:#{spec.fetch("port")}/health") &&
  !upstream_checks.include?("http://market-bot-production:10000/health")
abort "development bot health check must stay on test port" unless
  upstream_checks.include?("http://market-bot-development:10000/health")

puts "production bot release contract verified (manual-only)"
