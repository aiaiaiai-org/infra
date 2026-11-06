# © 2026 aiaiaiai · aiaiaiai.org
# Operator-only acceptance on the deployed Hub. Never ingests a threat or changes a subscription.
require "digest"
require "json"
require "logger"
ActiveRecord::Base.logger = nil
Rails.logger = Logger.new(File::NULL)

begin
  records = PrismHub::Adapters::ActiveRecordRecords
  matches = records::TelegramSurfaceBinding.includes(:workspace, :bot_instance)
    .where(status: "active", logical_channel: "alerts", message_thread_id: nil)
    .where("chat_id > 0 AND encode(sha256(convert_to(chat_id::text, 'UTF8')), 'hex') = ?", E2E_TARGET_DIGEST)
    .to_a
  raise "target_not_unique" unless matches.length == 1
  surface = matches.first
  workspace = surface.workspace
  bot = surface.bot_instance
  principal = bot.service_principal
  raise "target_inactive" unless workspace.status == "active" && bot.status == "active" &&
    principal.status == "active" && principal.identifier == "h-ua-bot-production"
  identity = records::ProviderIdentityBinding.find_by(provider: "telegram",
    provider_scope: "h-ua-bot", subject_id: surface.chat_id.to_s, status: "active")
  raise "identity_mismatch" unless identity && identity.user_identity_id == surface.created_by_user_identity_id
  raise "owner_missing" unless records::WorkspaceMembership.exists?(workspace: workspace,
    user_identity_id: identity.user_identity_id, status: "active", role: "owner")
  subscription = PrismHub::Adapters::ActiveRecordAlertSubscriptionRepository.new.find(workspace_id: workspace.identifier)
  raise "subscription_mismatch" unless subscription && subscription.categories.sort == %w[bomb drone missile] &&
    subscription.include_nearby && subscription.cell.match?(/\A86[0-9a-f]{13}\z/)
  puts JSON.generate(stage: "preflight", binding: "unique_active_private_alerts",
    owner: "verified", provider_scope: "h-ua-bot", subscription: "saved",
    cell_resolution: 6, categories: subscription.categories, include_nearby: subscription.include_nearby)

  bindings = PrismHub::Adapters::ActiveRecordTelegramSurfaceBindingRepository.new
  binding = bindings.find_by_logical_context(workspace_id: workspace.identifier, logical_channel: "alerts")
  raise "resolved_target_mismatch" unless binding && Digest::SHA256.hexdigest(binding.chat_id.to_s) == E2E_TARGET_DIGEST
  builder = PrismHub::UseCases::BuildDeliveryIntent.new(
    porter_gateway: PrismHub::Adapters::SubprocessPorterGateway.new(
      command: JSON.parse(ENV.fetch("PRISM_PORTER_COMMAND_JSON", '["prism-porter"]')),
      logger: Logger.new(File::NULL), timeout_seconds: 10))
  key = Digest::SHA256.hexdigest("prism-private-e2e\0#{E2E_TEST_ID}\0#{E2E_TARGET_DIGEST}")
  now = Time.now.utc
  payload = {
    "schema_version" => "prism-hub.signal-alert.v1", "event" => "alert",
    "hazard" => {"class" => "drone", "kinds" => []},
    "place" => {"name" => "ТЕСТ ДОСТАВКИ, НЕ РЕАЛЬНА ЗАГРОЗА [#{E2E_TEST_ID}]"},
    "proximity" => "target", "likelihood" => nil,
    "first_reported_at" => now.iso8601, "valid_until" => (now + 60).iso8601,
    "event_at" => now.iso8601, "event_url" => nil,
    "sources" => [{"source_id" => "synthetic.private_acceptance",
      "url" => "https://t.me/prism_synthetic_test/1", "observed_at" => now.iso8601}],
    "still_active" => []
  }
  request = PrismHub::Domain::DeliveryRequest.new(
    artifact: {"artifact_id" => "private-e2e-#{key[0,32]}", "artifact_kind" => "signal.alert", "payload" => payload},
    routes: [{"artifact_kind" => "signal.alert", "logical_context" => {"workspace" => workspace.identifier, "channel" => "alerts"}}],
    workspace: workspace.identifier, channel: "alerts", idempotency_key: key)
  preview = builder.call(artifact: request.artifact, routes: request.routes, chunk_max_chars: 4096)
  raise "unsafe_render" unless preview.chunks.length == 1 &&
    preview.chunks.first.text.include?("ТЕСТ ДОСТАВКИ, НЕ РЕАЛЬНА ЗАГРОЗА") &&
    preview.chunks.first.text.include?(E2E_TEST_ID)
  puts JSON.generate(stage: "porter", chunks: 1, text: preview.chunks.first.text)
  if E2E_MODE == "preflight"
    puts JSON.generate(stage: "preflight_complete", telegram_send: false)
    exit 0
  end
  raise "send_not_explicit" unless E2E_MODE == "send-one-private-test"

  # Hold a dedicated session lock, and refuse any previous attempt with this ID.
  connection = ActiveRecord::Base.connection
  lock_key = key[0,15].to_i(16)
  raise "test_in_progress" unless connection.select_value("SELECT pg_try_advisory_lock(#{lock_key})")
  begin
    raise "test_already_attempted" if records::DeliveryOutboxEntry.exists?(idempotency_key: key)
    outbox = PrismHub::Adapters::ActiveRecordDeliveryOutboxRepository.new
    entry = outbox.enqueue(request: request, available_at: Time.utc(9999,1,1))
    # Isolate exactly this entry from the unattended worker, including after an operator crash.
    record = records::DeliveryOutboxEntry.find(entry.id)
    record.update!(status: "processing", attempts: 1, locked_at: Time.utc(9999,1,1), lock_token: SecureRandom.hex(32))
    scoped = Object.new
    claimed = false
    scoped.define_singleton_method(:claim_due) do |**|
      next [] if claimed
      claimed = true
      [outbox.send(:to_domain, record)]
    end
    scoped.define_singleton_method(:mark_delivered) { |**args| outbox.mark_delivered(**args) }
    scoped.define_singleton_method(:mark_failed) { |**args| outbox.mark_failed(**args.merge(retry_at: nil)) }
    gateway = PrismHub::Adapters::HttpBotDeliveryGateway.new(origin: ENV.fetch("PRISM_BOT_ORIGIN"),
      secret: ENV.fetch("PRISM_BOT_DELIVERY_SECRET"), path_prefix: ENV.fetch("PRISM_BOT_PATH_PREFIX", ""))
    receipts = []
    observed = Object.new
    observed.define_singleton_method(:deliver) do |**args|
      result = gateway.deliver(**args)
      receipts.concat(result)
      result
    end
    resolver = Object.new
    resolver.define_singleton_method(:call) do |workspace_id:, logical_channel:|
      raise "route_expansion" unless workspace_id == workspace.identifier && logical_channel == "alerts"
      current = bindings.find_by_logical_context(workspace_id: workspace_id, logical_channel: logical_channel)
      raise "target_changed" unless current && current.id == binding.id &&
        Digest::SHA256.hexdigest(current.chat_id.to_s) == E2E_TARGET_DIGEST
      current
    end
    dispatcher = PrismHub::UseCases::DispatchDelivery.new(surface_resolver: resolver,
      delivery_gateway: observed, build_delivery_intent: builder)
    PrismHub::UseCases::ProcessDeliveryOutbox.new(outbox_repository: scoped,
      dispatch_delivery: dispatcher).call(limit: 1, lease_seconds: 300)
    record.reload
    raise "delivery_failed" unless record.status == "delivered" && receipts.length == 1
    receipt = receipts.first
    message_id = receipt.fetch("provider_message_id")
    raise "provider_receipt_invalid" unless message_id.is_a?(Integer) && message_id.positive?
    puts JSON.generate(stage: "telegram_acknowledgement", test_id: E2E_TEST_ID,
      outbox_status: record.status, provider_message_id: message_id, at: Time.now.utc.iso8601)
    # Replay immediately while this bot process retains its in-memory deduplication cache.
    replay = dispatcher.call(request: request)
    raise "replay_mismatch" unless replay.length == 1 && replay.first == receipt
    puts JSON.generate(stage: "idempotency_replay", same_provider_message_id: true,
      provider_message_id: message_id, boundary: "current bot process only", recipient_confirmation: "pending")
  ensure
    connection.execute("SELECT pg_advisory_unlock(#{lock_key})")
  end
rescue StandardError => error
  # No exception messages, stack traces, IDs, cells or secrets on a public Actions surface.
  safe = %w[target_not_unique target_inactive identity_mismatch owner_missing subscription_mismatch
    resolved_target_mismatch unsafe_render send_not_explicit test_in_progress test_already_attempted
    route_expansion target_changed delivery_failed provider_receipt_invalid replay_mismatch]
  reason = safe.include?(error.message) ? error.message : error.class.name
  puts JSON.generate(stage: "failed", reason: reason)
  exit 1
end
