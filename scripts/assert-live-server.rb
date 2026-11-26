#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Refuses a server that is unknown or retired. A workflow that is about to select a GitHub
# Environment named after a server runs this first, so a retired host's SSH credentials are
# never selected (scripts/resolve-workload-target.rb does the same for a workload's server).

require "yaml"

ROOT = File.expand_path("..", __dir__)
name = ARGV.first.to_s
abort("usage: assert-live-server.rb <server>") unless name.match?(/\A[a-z0-9][a-z0-9-]*\z/)

path = File.join(ROOT, "contracts", "servers", "#{name}.yaml")
abort("unknown server #{name}") unless File.file?(path)

server = YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: false)
abort("server #{name} is retired: its credentials are not selected") if server.dig("spec", "state") == "retired"
puts("server #{name} is live")
