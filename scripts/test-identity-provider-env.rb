#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
require "open3"
require "tmpdir"
require "yaml"

SCRIPT = File.expand_path("prepare-identity-provider-env.rb", __dir__)
DEFAULT = [
  "TELOXIDE_TOKEN=bot-secret",
  "TELEGRAM_OIDC_CLIENT_SECRET=telegram-secret",
  "DISCORD_CLIENT_SECRET=discord-secret",
  "NILX_BROWSER_HANDOFF_TOKEN=#{'h' * 64}",
  "GHCR_PULL_USER=test-user",
  "GHCR_PULL_TOKEN=ephemeral"
].join("\n") + "\n"

Dir.mktmpdir("identity-secret-contract") do |dir|
  source = File.join(dir, "input")
  output = File.join(dir, "output")
  env = {
    "WORKLOAD_SECRET_SOURCE_FILE" => source,
    "IDENTITY_PROVIDER_ENV_FILE" => output,
    "PROVIDER_TELEGRAM_OIDC_CLIENT_ID" => "telegram-public-id",
    "PROVIDER_DISCORD_CLIENT_ID" => "discord-public-id"
  }
  run = lambda do |content|
    File.write(source, content)
    File.delete(output) if File.exist?(output)
    Open3.capture3(env, "ruby", SCRIPT)
  end

  _out, errors, ok = run.call(DEFAULT)
  abort("valid provider rejected: #{errors}") unless ok.success?
  data = File.read(output)
  abort("Telegram secret absent") unless data.include?("TELEGRAM_OIDC_CLIENT_SECRET=telegram-secret")
  abort("handoff token absent") unless data.include?("NILX_BROWSER_HANDOFF_TOKEN=#{'h' * 64}\n")
  abort("incorrect public identity") unless data.include?("DISCORD_CLIENT_ID=discord-public-id")
  abort("GHCR token leaked into runtime") if data.include?("ephemeral")
  abort("missing provider env") unless data.start_with?("PUBLIC_ORIGIN=https://nilx.one")

  [
    DEFAULT.sub(/NILX_BROWSER_HANDOFF_TOKEN=.*\n/, ""),
    DEFAULT.sub('h' * 64, 'short'),
    DEFAULT.sub('h' * 64, 'x' * 31),
    DEFAULT + "SSH_PRIVATE_KEY=never\n",
    DEFAULT + "TELOXIDE_TOKEN=duplicate\n",
    DEFAULT.sub("DISCORD_CLIENT_SECRET=discord-secret\n", ""),
    DEFAULT.sub("GHCR_PULL_TOKEN=ephemeral\n", ""),
    DEFAULT.sub("TELOXIDE_TOKEN=", "TELOXIDE_TOKEN=bad\nTELOXIDE_TOKEN=")
  ].each do |payload|
    stdout, stderr, status = run.call(payload)
    abort("invalid provider payload accepted") if status.success?
    abort("secret leaked in failure log") if ["bot-secret", 'h' * 64].any? { |secret| "#{stdout}#{stderr}".include?(secret) }
  end
end
puts "identity provider allowlist passes"

# The producer's envelope (delivery.envelope) carries the public client IDs too, so a delivered
# identity needs no PROVIDER_* variables. Server-owned native secrets are refused.
Dir.mktmpdir("identity-envelope-ids") do |dir|
  source = File.join(dir, "input")
  output = File.join(dir, "output")
  env = { "WORKLOAD_SECRET_SOURCE_FILE" => source, "IDENTITY_PROVIDER_ENV_FILE" => output }
  with_ids = DEFAULT + "TELEGRAM_OIDC_CLIENT_ID=envelope-telegram-id\nDISCORD_CLIENT_ID=envelope-discord-id\n"
  run = lambda do |content, extra = {}|
    File.write(source, content)
    File.delete(output) if File.exist?(output)
    Open3.capture3(env.merge(extra), "ruby", SCRIPT)
  end

  _out, errors, ok = run.call(with_ids)
  abort("envelope client IDs rejected: #{errors}") unless ok.success?
  data = File.read(output)
  abort("envelope Telegram ID absent") unless data.include?("TELEGRAM_OIDC_CLIENT_ID=envelope-telegram-id\n")
  abort("envelope Discord ID absent") unless data.include?("DISCORD_CLIENT_ID=envelope-discord-id\n")
  abort("GHCR token leaked into runtime") if data.include?("ephemeral")

  # The envelope wins over a caller's variable.
  _out, errors, ok = run.call(with_ids, "PROVIDER_DISCORD_CLIENT_ID" => "caller-discord-id", "PROVIDER_TELEGRAM_OIDC_CLIENT_ID" => "caller-telegram-id")
  abort("envelope with caller IDs rejected: #{errors}") unless ok.success?
  abort("caller ID overrode the envelope") if File.read(output).include?("caller-")

  # Neither source: refuse.
  _out, _errors, ok = run.call(DEFAULT)
  abort("missing client IDs accepted") if ok.success?
  # One ID short in the envelope: refuse (no mixing sources on a guess).
  _out, _errors, ok = run.call(DEFAULT + "TELEGRAM_OIDC_CLIENT_ID=only-telegram\n")
  abort("half the client IDs accepted") if ok.success?

  %w[NATIVE_AUTH_SECRET PASSWORD_PEPPER GITHUB_EVIDENCE_ENCRYPTION_KEY].each do |name|
    stdout, stderr, status = run.call(with_ids + "#{name}=#{'n' * 64}\n")
    abort("server-owned #{name} accepted from the envelope") if status.success?
    abort("secret leaked in failure log") if "#{stdout}#{stderr}".include?("n" * 64)
  end
end
puts "identity envelope client IDs pass"

# Sign-in through AIS rides the envelope as a pair, and only as a well-formed pair. Neither half is
# ever logged when the pair is refused.
Dir.mktmpdir("identity-ais-sign-in") do |dir|
  source = File.join(dir, "input")
  output = File.join(dir, "output")
  env = { "WORKLOAD_SECRET_SOURCE_FILE" => source, "IDENTITY_PROVIDER_ENV_FILE" => output }
  with_ids = DEFAULT + "TELEGRAM_OIDC_CLIENT_ID=envelope-telegram-id\nDISCORD_CLIENT_ID=envelope-discord-id\n"
  secret = "s" * 40
  pair = "AIAIAIAI_SIGN_IN_ISSUER=https://auth.aiaiaiai.org\nAIAIAIAI_SIGN_IN_CLIENT_SECRET=#{secret}\n"
  run = lambda do |content|
    File.write(source, content)
    File.delete(output) if File.exist?(output)
    Open3.capture3(env, "ruby", SCRIPT)
  end

  _out, errors, ok = run.call(with_ids + pair)
  abort("AIS sign-in pair rejected: #{errors}") unless ok.success?
  data = File.read(output)
  abort("AIS issuer absent") unless data.include?("AIAIAIAI_SIGN_IN_ISSUER=https://auth.aiaiaiai.org\n")
  abort("AIS client secret absent") unless data.include?("AIAIAIAI_SIGN_IN_CLIENT_SECRET=#{secret}\n")
  abort("GHCR token leaked into runtime") if data.include?("ephemeral")

  # Without the pair, nothing about AIS reaches the runtime file.
  _out, errors, ok = run.call(with_ids)
  abort("envelope without the AIS pair rejected: #{errors}") unless ok.success?
  abort("AIS names appeared without the pair") if File.read(output).include?("AIAIAIAI_")

  [
    with_ids + "AIAIAIAI_SIGN_IN_ISSUER=https://auth.aiaiaiai.org\n",
    with_ids + "AIAIAIAI_SIGN_IN_CLIENT_SECRET=#{secret}\n",
    with_ids + pair.sub("https://", "http://"),
    with_ids + pair.sub("auth.aiaiaiai.org", "auth.aiaiaiai.org/path"),
    with_ids + pair.sub(secret, "s" * 31),
    with_ids + pair + pair
  ].each do |payload|
    stdout, stderr, status = run.call(payload)
    abort("invalid AIS sign-in settings accepted") if status.success?
    abort("secret leaked in failure log") if "#{stdout}#{stderr}".include?(secret)
  end
end
puts "identity AIS sign-in pair passes"

# Regression: infra must not request a second set of production provider secrets
# after the encrypted producer handoff has already been decrypted.
workflow_path = File.expand_path("../.github/workflows/deploy-workload.yml", __dir__)
workflow = YAML.load_file(workflow_path)
job = workflow.fetch("jobs").fetch("deploy")
env = job.fetch("env")
%w[PROVIDER_TELOXIDE_TOKEN PROVIDER_TELEGRAM_OIDC_CLIENT_SECRET PROVIDER_DISCORD_CLIENT_SECRET].each do |name|
  abort("legacy infra provider secret dependency restored: #{name}") if env.key?(name)
end
step = job.fetch("steps").find { |item| item["name"] == "Prepare container environment" }
abort("identity deployment preflight step missing") unless step
preflight = step.fetch("run")
Dir.mktmpdir("identity-preflight") do |dir|
  base_env = {
    "RUNNER_TEMP" => dir,
    "WORKLOAD" => "nilxone-identity",
    "IMAGE_REF" => "ghcr.io/nilx-one/0x1-identity:sha-test",
    "EDGE_NETWORK" => "nilx-edge",
    "WORKLOAD_ALIAS" => "nilxone-identity",
    "WORKLOAD_PORT" => "1927",
    "WORKLOAD_HEALTH" => "/health",
    "WORKLOAD_HEALTH_KIND" => "http",
    "WORKLOAD_ENVIRONMENT" => "",
    "WORKLOAD_LABELS" => "",
    "WORKLOAD_VOLUMES" => "",
    "PROVIDER_TELEGRAM_OIDC_CLIENT_ID" => "telegram-public-id",
    "PROVIDER_DISCORD_CLIENT_ID" => "discord-public-id"
  }
  run_preflight = lambda do |overrides = {}|
    Open3.capture3(base_env.merge(overrides), "bash", "-c", preflight)
  end
  path = File.join(dir, "source-credentials.env")
  File.write(path, DEFAULT)
  _out, err, status = run_preflight.call
  abort("encrypted identity preflight rejected: #{err}") unless status.success?

  File.delete(path)
  _out, err, status = run_preflight.call
  abort("identity accepted missing encrypted credentials") if status.success?
  abort("missing envelope diagnostic was not actionable") unless err.include?("requires encrypted workload-scoped credentials")

  File.write(path, "")
  _out, _err, status = run_preflight.call
  abort("identity accepted empty credential envelope") if status.success?

  File.write(path, DEFAULT)
  _out, _err, status = run_preflight.call("PROVIDER_DISCORD_CLIENT_ID" => "")
  abort("identity accepted missing public provider client ID") if status.success?

  _out, err, status = run_preflight.call("WORKLOAD" => "nilxone-web", "PROVIDER_DISCORD_CLIENT_ID" => "")
  abort("unrelated workload requires identity credentials: #{err}") unless status.success?
end
puts "identity deployment encrypted-handoff preflight passes"

