#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# market-api-production's invariants: its secrets come only from Core's
# attested envelope, its database credentials derive from the very secret
# market-postgres-production is created with, and it listens on the contract
# port the edge routes to.

require "yaml"

root = File.expand_path("..", __dir__)
load_contract = ->(relative) { YAML.safe_load(File.read(File.join(root, relative)), aliases: false) }
api = load_contract.call("contracts/services/market-api-production.yaml")
database = load_contract.call("contracts/services/market-postgres-production.yaml")
edge = load_contract.call("contracts/edges/nilx-edge.yaml")
caddy = File.read(File.join(root, "deploy/edge/Caddyfile"))

abort "unexpected owner" unless api.dig("metadata", "owner") == "0xda-market/core"
spec = api.fetch("spec")
runtime = spec.fetch("runtime")
environment = runtime.fetch("environment")
secrets = runtime.fetch("secrets")

abort "must be a production container" unless spec["deployment"] == "production" && runtime["kind"] == "container"
abort "must listen on the contract port" unless spec["port"] == 1927 && environment.include?("PORT=1927")
abort "must run Core in production mode" unless environment.include?("DEPLOY_ENV=production")
abort "mock payments must stay off" unless environment.include?("ENABLE_MOCK_PAYMENT_PROVIDER=0")
# Core's DatabaseTarget requires the password in a production URL, so the URL
# is never a plain variable: it arrives in the envelope, derived by Core's
# publish workflow from the same MARKET_POSTGRES_PASSWORD the database uses.
abort "DATABASE_URL must not be a plain variable" if environment.any? { |entry| entry.start_with?("DATABASE_URL=") }
abort "no pinned image: Core delivers its own" if runtime.key?("image")
abort "secrets come from the envelope, not prepareEnv" if runtime.key?("prepareEnv")

# Core delivers itself from its verified master head; the database takes its password from
# Core's envelope, never from infra (docs/market-postgres-production.md, step 6).
delivery = spec.fetch("delivery") { abort "market-api-production must deliver automatically" }
abort "wrong delivery image" unless delivery["image"] == "ghcr.io/0xda-market/core"
abort "must deliver master only" unless delivery["branch"] == "master"
abort "Core signs image and envelope from ci.yml" unless delivery["signerWorkflow"] == ".github/workflows/ci.yml"
abort "delivery.envelope is for prepareEnv workloads" if delivery.key?("envelope")
abort "the database must take its password from Core's envelope" unless
  database.dig("spec", "runtime", "secretsFrom") == "market-api-production"
abort "the database is not delivered on its own" if database.dig("spec").key?("delivery")

expected = %w[
  DATABASE_URL=MARKET_DATABASE_URL
  PGPASSWORD=MARKET_POSTGRES_PASSWORD
  PUBLIC_API_TOKEN=PUBLIC_API_TOKEN
  MANUAL_PROVIDER_TOKEN=MANUAL_PROVIDER_TOKEN
  NILX_BROWSER_HANDOFF_TOKEN=NILX_BROWSER_HANDOFF_TOKEN
]
abort "unexpected secret mapping: #{secrets.inspect}" unless secrets.sort == expected.sort
database_secret = database.dig("spec", "runtime", "secrets").first.split("=", 2).last
abort "API and database must share one password secret" unless database_secret == "MARKET_POSTGRES_PASSWORD"
abort "no secret may also be a plain variable" unless (environment.map { |e| e.split("=", 2).first } & secrets.map { |s| s.split("=", 2).first }).empty?

route = Array(edge.dig("spec", "routes")).find { |r| r["id"] == "market-api-production" } || abort("missing edge route")
abort "edge must route to the contract port" unless route["upstream"] == "market-api-production:1927"
abort "Caddy must proxy to the contract port" unless caddy.include?("reverse_proxy market-api-production:1927") && !caddy.include?("market-api-production:10000")

puts "production Core contract verified"
