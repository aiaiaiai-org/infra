#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# The aiaiaiai Identity Service (4x-ais, auth.aiaiaiai.org) is deployed by Railway, not by this
# repository (owner, 2026-11-26). It must stay out of every contract and script infra deploys,
# routes or exports with, while the places that only consume it as an external issuer stay valid.

require "yaml"

ROOT = File.expand_path("..", __dir__)

def read(path)
  File.read(File.join(ROOT, path), encoding: "UTF-8")
end

def yaml(path)
  YAML.safe_load(read(path), aliases: false)
end

def files(*globs)
  globs.flat_map { |glob| Dir.glob(File.join(ROOT, glob)) }.select { |path| File.file?(path) }.sort
end

# --- absent: no workload contract, no placement, no route, no edge variable, no export entry.
abort("a 4x-ais workload contract exists") if File.exist?(File.join(ROOT, "contracts", "services", "4x-ais.yaml"))
workloads = files("contracts/services/*.yaml").map { |path| yaml(path.delete_prefix("#{ROOT}/")) }
abort("a workload contract is owned by aiaiaiai-org/4x-ais") if workloads.any? { |c| c.dig("metadata", "owner") == "aiaiaiai-org/4x-ais" }
abort("a workload contract is named 4x-ais") if workloads.any? { |c| c.dig("metadata", "name") == "4x-ais" }
abort("a workload contract claims auth.aiaiaiai.org as its public host") if workloads.any? { |c| c.dig("spec", "public", "host") == "auth.aiaiaiai.org" }
abort("a workload contract delivers the 4x-ais image") if workloads.any? { |c| c.dig("spec", "delivery", "image").to_s.end_with?("/4x-ais") }

files("contracts/servers/*.yaml").each do |path|
  abort("#{File.basename(path)} places 4x-ais") if Array(yaml(path.delete_prefix("#{ROOT}/")).dig("spec", "workloads")).include?("4x-ais")
end
files("contracts/edges/*.yaml").each do |path|
  routes = Array(yaml(path.delete_prefix("#{ROOT}/")).dig("spec", "routes"))
  abort("#{File.basename(path)} routes 4x-ais or the auth host") if routes.any? { |r| r["service"] == "4x-ais" || r["id"] == "4x-ais" || r["host"].to_s.include?("AUTH_DOMAIN") || r["host"] == "auth.aiaiaiai.org" }
end

# What infra deploys, routes, verifies or exports with: nothing may mention the service or its host variable.
owned = files("deploy/edge-aiaiaiai/*", ".github/workflows/deploy-aiaiaiai-edge.yml", ".github/workflows/export-aiaiaiai-migration.yml",
              "scripts/extract-workload-secrets.rb", "scripts/build-export-manifest.rb")
abort("no edge deploy or export files found") if owned.empty?
owned.each do |path|
  text = File.read(path, encoding: "UTF-8")
  %w[4x-ais AIAIAIAI_AUTH_DOMAIN].each do |needle|
    abort("#{path.delete_prefix("#{ROOT}/")} mentions #{needle}") if text.include?(needle)
  end
  abort("#{path.delete_prefix("#{ROOT}/")} routes the auth host") if text.include?("auth.aiaiaiai.org")
end

# --- present: the consumers of AIS as an external issuer still point at it.
identity = yaml("contracts/services/nilxone-identity.yaml")
abort("nilxone-identity lost its AIS issuer") unless
  Array(identity.dig("spec", "runtime", "environment")).include?("AIAIAIAI_SIGN_IN_ISSUER=https://auth.aiaiaiai.org")
%w[.github/workflows/bootstrap-nilx-identity-fresh.yml deploy/telegram-runtime/activate.sh].each do |path|
  abort("#{path} no longer reads the external AIS issuer") unless read(path).include?("https://auth.aiaiaiai.org")
end

puts "AIS ownership: absent from every infra contract, route and export, still consumed as the external issuer"
