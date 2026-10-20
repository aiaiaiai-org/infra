#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "yaml"

root = File.expand_path("..", __dir__)
load_contract = ->(relative) { YAML.safe_load(File.read(File.join(root, relative)), aliases: false) }
contract = load_contract.call("contracts/services/market-postgres-production.yaml")
server = load_contract.call("contracts/servers/edge-prod-1.yaml")
edge = load_contract.call("contracts/edges/nilx-edge.yaml")

abort "unexpected workload" unless contract.dig("metadata", "name") == "market-postgres-production"
abort "unexpected workload owner" unless contract.dig("metadata", "owner") == "aiaiaiai-org/infra"
spec = contract.fetch("spec")
runtime = spec.fetch("runtime")

abort "wrong deployment class" unless spec["deployment"] == "production"
abort "must share edge-prod-1 internal network" unless spec["network"] == "nilx-edge"
abort "wrong internal address" unless spec["aliases"] == ["market-postgres-production"] && spec["port"] == 1927
abort "database must use TCP health" unless spec["protocol"] == "tcp" && spec["healthKind"] == "tcp"
abort "production database must not have a public route" if spec.key?("public")
abort "must use immutable image" unless runtime.fetch("image").match?(/\Apostgres@sha256:[0-9a-f]{64}\z/)
abort "missing database identity" unless runtime.fetch("environment").sort == %w[PGPORT=1927 POSTGRES_DB=market POSTGRES_USER=market].sort
abort "missing secret mapping" unless runtime.fetch("secrets") == ["POSTGRES_PASSWORD=MARKET_POSTGRES_PASSWORD"]
abort "missing persistent volume" unless runtime.fetch("volumes") == ["market-postgres-production-data:/var/lib/postgresql"]
abort "not placed on edge-prod-1" unless server.dig("spec", "workloads").include?("market-postgres-production")
abort "database must not expose a host port" unless (server.dig("spec", "publicPorts") & %w[1927/tcp 5432/tcp]).empty?
abort "database must not be publicly routed by edge" if Array(edge.dig("spec", "routes")).any? { |r| r["service"] == "market-postgres-production" }

puts "market production PostgreSQL isolation contract validated"
