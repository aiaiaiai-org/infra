#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
#
# Construct the runtime provider file for nilxone-identity without accepting
# arbitrary encrypted payload keys. This never prints any credential.
source = ENV.fetch("WORKLOAD_SECRET_SOURCE_FILE")
output = ENV.fetch("IDENTITY_PROVIDER_ENV_FILE")
ids = {
  "TELEGRAM_OIDC_CLIENT_ID" => ENV.fetch("PROVIDER_TELEGRAM_OIDC_CLIENT_ID"),
  "DISCORD_CLIENT_ID" => ENV.fetch("PROVIDER_DISCORD_CLIENT_ID")
}
abort("missing provider client ID") if ids.values.any?(&:empty?)
abort("invalid provider client ID") if ids.values.any? { |value| value.match?(/[\r\n\0]/) }
abort("invalid provider file") unless File.file?(source) && File.readable?(source)
abort("provider file too large") if File.size(source) > 32_768

secrets = {}
File.foreach(source, chomp: true) do |entry|
  match = /\A([A-Z][A-Z0-9_]*)=([^\r\n\0]*)\z/.match(entry)
  abort("invalid provider entry") unless match
  name, value = match.captures
  abort("duplicate provider entry") if secrets.key?(name)
  secrets[name] = value
end

required = %w[TELOXIDE_TOKEN TELEGRAM_OIDC_CLIENT_SECRET DISCORD_CLIENT_SECRET]
optional = %w[GHCR_PULL_USER GHCR_PULL_TOKEN]
abort("unapproved identity provider entry") unless (secrets.keys - required - optional).empty?
abort("missing identity provider credential") unless required.all? { |name| secrets[name].is_a?(String) && !secrets[name].empty? }
abort("incomplete GHCR credential") if optional.count { |name| secrets.key?(name) } == 1
abort("missing GHCR credential") if optional.any? { |name| secrets[name] == "" }

lines = [
  "PUBLIC_ORIGIN=https://nilx.one",
  "TELOXIDE_TOKEN=#{secrets.fetch('TELOXIDE_TOKEN')}",
  "TELEGRAM_OIDC_CLIENT_ID=#{ids.fetch('TELEGRAM_OIDC_CLIENT_ID')}",
  "TELEGRAM_OIDC_CLIENT_SECRET=#{secrets.fetch('TELEGRAM_OIDC_CLIENT_SECRET')}",
  "DISCORD_CLIENT_ID=#{ids.fetch('DISCORD_CLIENT_ID')}",
  "DISCORD_CLIENT_SECRET=#{secrets.fetch('DISCORD_CLIENT_SECRET')}"
]
File.open(output, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
  file.write(lines.join("\n") + "\n")
end
