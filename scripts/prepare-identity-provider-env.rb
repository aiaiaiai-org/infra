#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
#
# Construct the runtime provider file for nilxone-identity without accepting
# arbitrary encrypted payload keys. This never prints any credential.
source = ENV.fetch("WORKLOAD_SECRET_SOURCE_FILE")
output = ENV.fetch("IDENTITY_PROVIDER_ENV_FILE")
public_names = %w[TELEGRAM_OIDC_CLIENT_ID DISCORD_CLIENT_ID]
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

required = %w[TELOXIDE_TOKEN TELEGRAM_OIDC_CLIENT_SECRET DISCORD_CLIENT_SECRET NILX_BROWSER_HANDOFF_TOKEN]
optional = %w[GHCR_PULL_USER GHCR_PULL_TOKEN]
# Sign-in through AIS: both or neither. The issuer is the public origin AIS serves; the secret is
# AIS's client secret for `nilx-one`.
sign_in = %w[AIAIAIAI_SIGN_IN_ISSUER AIAIAIAI_SIGN_IN_CLIENT_SECRET]
# The public client IDs come in the producer's envelope (delivery.envelope), or, for a caller that
# still dispatches, in PROVIDER_* variables. The envelope wins; one source never mixes with the other.
ids = public_names.to_h do |name|
  [name, secrets.key?(name) ? secrets.fetch(name) : ENV.fetch("PROVIDER_#{name}", "")]
end
abort("missing provider client ID") if ids.values.any?(&:empty?)
abort("invalid provider client ID") if ids.values.any? { |value| value.match?(/[\r\n\0]/) }
# NATIVE_AUTH_SECRET, PASSWORD_PEPPER and GITHUB_EVIDENCE_ENCRYPTION_KEY stay on the host and are
# refused here like any other unapproved name.
abort("unapproved identity provider entry") unless (secrets.keys - required - optional - public_names - sign_in).empty?
abort("missing identity provider credential") unless required.all? { |name| secrets[name].is_a?(String) && !secrets[name].empty? }
abort("NILX_BROWSER_HANDOFF_TOKEN must contain at least 32 bytes") if secrets.fetch("NILX_BROWSER_HANDOFF_TOKEN").bytesize < 32
abort("incomplete GHCR credential") if optional.count { |name| secrets.key?(name) } == 1
abort("missing GHCR credential") if optional.any? { |name| secrets[name] == "" }
abort("incomplete AIS sign-in settings") if sign_in.count { |name| secrets.key?(name) } == 1
if secrets.key?("AIAIAIAI_SIGN_IN_ISSUER")
  abort("AIAIAIAI_SIGN_IN_ISSUER must be an https origin") unless secrets.fetch("AIAIAIAI_SIGN_IN_ISSUER").match?(%r{\Ahttps://[^/\s]+\z})
  abort("AIAIAIAI_SIGN_IN_CLIENT_SECRET must contain at least 32 bytes") if secrets.fetch("AIAIAIAI_SIGN_IN_CLIENT_SECRET").bytesize < 32
end

lines = [
  "PUBLIC_ORIGIN=https://nilx.one",
  "TELOXIDE_TOKEN=#{secrets.fetch('TELOXIDE_TOKEN')}",
  "TELEGRAM_OIDC_CLIENT_ID=#{ids.fetch('TELEGRAM_OIDC_CLIENT_ID')}",
  "TELEGRAM_OIDC_CLIENT_SECRET=#{secrets.fetch('TELEGRAM_OIDC_CLIENT_SECRET')}",
  "DISCORD_CLIENT_ID=#{ids.fetch('DISCORD_CLIENT_ID')}",
  "DISCORD_CLIENT_SECRET=#{secrets.fetch('DISCORD_CLIENT_SECRET')}",
  "NILX_BROWSER_HANDOFF_TOKEN=#{secrets.fetch('NILX_BROWSER_HANDOFF_TOKEN')}"
]
sign_in.each { |name| lines << "#{name}=#{secrets.fetch(name)}" } if secrets.key?("AIAIAIAI_SIGN_IN_ISSUER")
File.open(output, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
  file.write(lines.join("\n") + "\n")
end

