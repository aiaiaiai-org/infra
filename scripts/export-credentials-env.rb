#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Turns the `secrets` document of a sealed export (JSON on stdin: workload => {container env name => value})
# into the `SOURCE_NAME=value` file Deploy workload reads for one workload, by inverting the reviewed
# contract's spec.runtime.secrets lines (`ENV_NAME=SOURCE_NAME`). It writes only what that contract maps,
# and refuses a missing or empty value, so a workload never starts with half its configuration.
# Every value is registered for log masking on stderr; nothing but names appears in an error.
#
#   open secrets | export-credentials-env.rb prism-hub > cred.env

require "json"
require "yaml"

ROOT = File.expand_path("..", __dir__)
workload = ARGV[0]
abort "usage: export-credentials-env.rb WORKLOAD" unless ARGV.length == 1 && workload.to_s.match?(/\A[a-z0-9][a-z0-9-]*\z/)

contract = YAML.safe_load_file(File.join(ROOT, "contracts", "services", "#{workload}.yaml"))
mappings = Array(contract.dig("spec", "runtime", "secrets")).map do |line|
  env_name, source_name = line.to_s.split("=", 2)
  abort "#{workload}: a secret mapping is not ENV_NAME=SOURCE_NAME" unless env_name&.match?(/\A[A-Z][A-Z0-9_]*\z/) && source_name&.match?(/\A[A-Z][A-Z0-9_]*\z/)
  [env_name, source_name]
end
abort "#{workload}: the contract maps no secrets" if mappings.empty?

document = JSON.parse($stdin.read)
values = document.is_a?(Hash) ? document[workload] : nil
abort "#{workload}: the export holds no secrets for it" unless values.is_a?(Hash)

lines = mappings.map do |env_name, source_name|
  value = values[env_name]
  abort "#{workload}: #{env_name} is missing or empty in the export" unless value.is_a?(String) && !value.empty?
  abort "#{workload}: #{env_name} spans lines" if value.match?(/[\r\n\0]/)
  $stderr.puts "::add-mask::#{value}"
  "#{source_name}=#{value}"
end
abort "#{workload}: two secrets map to one source name" unless mappings.map(&:last).uniq.length == mappings.length

puts lines
