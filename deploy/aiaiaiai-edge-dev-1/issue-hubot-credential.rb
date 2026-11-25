# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Runs INSIDE the prism-hub container (`bin/rails runner`), read from stdin by migrate.sh.
# HUBOT_CREDENTIAL_MODE selects one of three steps, so that issuing and revoking are never one action:
#
#   issue            make sure the service principal prism-hubot exists with the least privilege its
#                    Telegram client needs and issue it a fresh client credential. Nothing is revoked:
#                    the credential the running prism-hubot uses stays valid. Prints ISSUED_ID and
#                    ISSUED_TOKEN (the hub stores only the token's SHA-256 digest).
#   keep ID          after the new credential is proved, revoke every other active credential of the principal.
#   abandon ID       revoke the credential a failed run issued, so an unproved one is not left behind.
#
# Repeating `issue` is safe: the principal is verified (never silently widened).

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

mode = ENV.fetch("HUBOT_CREDENTIAL_MODE")
id = ENV.fetch("HUBOT_CREDENTIAL_ID", "")
credentials = PrismHub::Adapters::ActiveRecordClientCredentialRepository.new
revoke = PrismHub::UseCases::RevokeClientCredential.new(repository: credentials)
own = PrismHub::Adapters::ActiveRecordRecords::ClientCredential
  .joins(:service_principal)
  .where(service_principals: {identifier: PRINCIPAL})

case mode
when "issue"
  PrismHub::UseCases::ProvisionServicePrincipal
    .new(repository: PrismHub::Adapters::ActiveRecordServicePrincipalRepository.new)
    .call(principal_id: PRINCIPAL, capabilities: CAPABILITIES, channel_ids: [])
  issued = PrismHub::UseCases::IssueClientCredential.new(
    repository: credentials,
    token_generator: PrismHub::Adapters::SecureClientCredentialGenerator.new
  ).call(principal_id: PRINCIPAL)
  $stderr.puts "prism-hubot principal ready; credential #{issued.id} issued (earlier ones still valid)"
  puts "ISSUED_ID=#{issued.id}"
  puts "ISSUED_TOKEN=#{issued.token}"
when "keep"
  abort "keep needs the id of the proved credential" unless own.where(id: id, revoked_at: nil).exists?
  stale = own.where(revoked_at: nil).where.not(id: id).pluck(:id)
  stale.each { |old| revoke.call(credential_id: old) }
  $stderr.puts "credential #{id} kept; #{stale.length} earlier revoked"
when "abandon"
  abort "abandon needs a credential of #{PRINCIPAL}" unless own.where(id: id).exists?
  revoke.call(credential_id: id)
  $stderr.puts "credential #{id} revoked: it was not proved"
else
  abort "unknown HUBOT_CREDENTIAL_MODE"
end
