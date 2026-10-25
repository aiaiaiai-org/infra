#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Builds a workload's secret environment from the secrets of its target GitHub Environment.
#
#   ALL_SECRETS      the Environment's secrets as a JSON object (`toJSON(secrets)`)
#   WORKLOAD_SECRETS base64 of the contract's `runtime.secrets` lines, `ENV_NAME=SECRET_NAME`
#   WORKLOAD_PRODUCER_ENVIRONMENT base64 of allowlisted producer variable names
#
# Prints base64 of `ENV_NAME=value` lines for deploy.sh's WORKLOAD_SECRET_ENV. A secret the
# contract names but the Environment lacks, or leaves empty, stops the deployment: a workload
# never starts with half its configuration. No value is ever printed in an error.

require "base64"
require "json"

MAPPING = /\A([A-Z][A-Z0-9_]*)=([A-Z][A-Z0-9_]*)\z/

mapping_b64 = ENV.fetch("WORKLOAD_SECRETS", "")
source_file = ENV.fetch("WORKLOAD_SECRET_SOURCE_FILE", "")
abort("WORKLOAD_SECRETS is empty") if mapping_b64.strip.empty? && source_file.empty?

begin
  mapping = mapping_b64.strip.empty? ? [] : Base64.strict_decode64(mapping_b64).lines.map(&:strip).reject(&:empty?)
rescue ArgumentError
  abort("WORKLOAD_SECRETS is not base64")
end
abort("WORKLOAD_SECRETS names no secret") if mapping.empty? && source_file.empty?

producer_names_b64 = ENV.fetch("WORKLOAD_PRODUCER_ENVIRONMENT", "")
begin
  producer_names = producer_names_b64.strip.empty? ? [] :
    Base64.strict_decode64(producer_names_b64).lines.map(&:strip).reject(&:empty?)
rescue ArgumentError
  abort("WORKLOAD_PRODUCER_ENVIRONMENT is not base64")
end
abort("invalid producer environment allowlist") unless
  producer_names.all? { |name| name.match?(/\A[A-Z][A-Z0-9_]*\z/) } &&
  producer_names.uniq.length == producer_names.length
abort("producer variables require a source envelope") if source_file.empty? && !producer_names.empty?

# A caller can supply an age-encrypted, per-run source file instead of copying its
# application credentials to infra's Environment. Only keys declared by the
# reviewed workload contract may enter the container. _GHCR_* credentials are
# reserved for the registry login step and never enter the workload runtime.
if !source_file.empty?
  abort("source secret file is unreadable") unless File.file?(source_file) && File.readable?(source_file)
  raw = File.binread(source_file)
  abort("source secret file is too large") if raw.bytesize > 32_768
  raw.force_encoding(Encoding::UTF_8)
  abort("source secret file is not valid UTF-8") unless raw.valid_encoding?
  secrets = {}
  raw.lines(chomp: true).each do |line|
    match = /\A([A-Z][A-Z0-9_]*)=([^\r\n\0]*)\z/.match(line)
    abort("invalid source secret entry") unless match
    key, value = match.captures
    abort("duplicate source secret entry") if secrets.key?(key)
    secrets[key] = value
  end
else
  begin
    secrets = JSON.parse(ENV.fetch("ALL_SECRETS", "{}"))
  rescue JSON::ParserError
    abort("ALL_SECRETS is not a JSON object")
  end
  abort("ALL_SECRETS is not a JSON object") unless secrets.is_a?(Hash)
end

if !source_file.empty?
  expected = mapping.map do |entry|
    match = MAPPING.match(entry) || abort("secret mapping must be ENV_NAME=SECRET_NAME")
    match[2]
  end.uniq
  identity = ENV.fetch("WORKLOAD", "") == "nilxone-identity"
  provider_names = identity ? %w[TELOXIDE_TOKEN TELEGRAM_OIDC_CLIENT_SECRET DISCORD_CLIENT_SECRET NILX_BROWSER_HANDOFF_TOKEN] : []
  extras = secrets.keys - expected - producer_names - provider_names - %w[GHCR_PULL_USER GHCR_PULL_TOKEN]
  missing = expected + producer_names + provider_names - secrets.keys
  abort("unexpected source credential names") unless extras.empty?
  abort("missing contract-specified source credentials") unless missing.empty?
  registry_names = %w[GHCR_PULL_USER GHCR_PULL_TOKEN]
  provided = registry_names.count { |name| secrets.key?(name) }
  abort("incomplete registry credential pair") if provided == 1
  abort("empty registry credential") if registry_names.any? { |name| secrets.key?(name) && secrets[name].empty? }
end

names = []
if secrets.key?("NILX_BROWSER_HANDOFF_TOKEN")
  token = secrets["NILX_BROWSER_HANDOFF_TOKEN"]
  abort("NILX_BROWSER_HANDOFF_TOKEN must contain at least 32 bytes") unless token.is_a?(String) && token.bytesize >= 32
end
lines = mapping.map do |entry|
  match = MAPPING.match(entry) || abort("secret mapping must be ENV_NAME=SECRET_NAME")
  env_name, secret_name = match.captures
  abort("registry credentials may not enter workload runtime") if [env_name, secret_name].any? { |name| name.start_with?("GHCR_") }
  abort("secret mapping sets #{env_name} twice") if names.include?(env_name)
  names << env_name

  value = secrets[secret_name]
  abort("the target Environment has no secret #{secret_name}") unless value.is_a?(String) && !value.empty?
  abort("secret #{secret_name} must be a single line") if value.match?(/[\r\n\0]/)

  "#{env_name}=#{value}"
end

producer_lines = producer_names.map do |name|
  abort("producer variable duplicates runtime secret") if names.include?(name)
  value = secrets[name]
  abort("missing producer variable #{name}") unless value.is_a?(String) && !value.empty?
  abort("invalid producer variable #{name}") unless value.match?(/\A[A-Za-z0-9_\.\/:@+,-]+\z/)
  "#{name}=#{value}"
end

print(Base64.strict_encode64((lines + producer_lines).join("\n") + "\n"))

