# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Runs INSIDE the prism-hub container (`bin/rails runner`), read from stdin by migrate.sh.
# Makes sure the service principal prism-hubot exists with the least privilege its Telegram client
# needs, issues it a fresh client credential and revokes every earlier one of that principal.
#
# It prints exactly one line the caller keeps, `ISSUED_TOKEN=<token>`; the hub stores only the token's
# SHA-256 digest. Running it again is safe: the principal is verified (never silently widened) and
# the previous credential is replaced.

PRINCIPAL = "prism-hubot"
# Identity (actors), the personal bot lifecycle and the channel catalogue. No publications and no
# alert subscriptions: nothing the Whisper client does needs them. Channels: none are granted.
CAPABILITIES = %w[
  actors:resolve
  actors:onboard
  bot_instances:read
  bot_instances:manage
  channels:read
].freeze

principals = PrismHub::Adapters::ActiveRecordServicePrincipalRepository.new
credentials = PrismHub::Adapters::ActiveRecordClientCredentialRepository.new

PrismHub::UseCases::ProvisionServicePrincipal.new(repository: principals)
  .call(principal_id: PRINCIPAL, capabilities: CAPABILITIES, channel_ids: [])

issued = PrismHub::UseCases::IssueClientCredential.new(
  repository: credentials,
  token_generator: PrismHub::Adapters::SecureClientCredentialGenerator.new
).call(principal_id: PRINCIPAL)

previous = PrismHub::Adapters::ActiveRecordRecords::ClientCredential
  .joins(:service_principal)
  .where(service_principals: {identifier: PRINCIPAL}, revoked_at: nil)
  .where.not(id: issued.id)
  .pluck(:id)
revoke = PrismHub::UseCases::RevokeClientCredential.new(repository: credentials)
previous.each { |id| revoke.call(credential_id: id) }

$stderr.puts "prism-hubot principal ready; credential #{issued.id} issued, #{previous.length} earlier revoked"
puts "ISSUED_TOKEN=#{issued.token}"
