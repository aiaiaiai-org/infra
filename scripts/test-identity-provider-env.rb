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
  abort("incorrect public identity") unless data.include?("DISCORD_CLIENT_ID=discord-public-id")
  abort("GHCR token leaked into runtime") if data.include?("ephemeral")
  abort("missing provider env") unless data.start_with?("PUBLIC_ORIGIN=https://nilx.one")

  [
    DEFAULT + "SSH_PRIVATE_KEY=never\n",
    DEFAULT + "TELOXIDE_TOKEN=duplicate\n",
    DEFAULT.sub("DISCORD_CLIENT_SECRET=discord-secret\n", ""),
    DEFAULT.sub("GHCR_PULL_TOKEN=ephemeral\n", ""),
    DEFAULT.sub("TELOXIDE_TOKEN=", "TELOXIDE_TOKEN=bad\nTELOXIDE_TOKEN=")
  ].each do |payload|
    stdout, stderr, status = run.call(payload)
    abort("invalid provider payload accepted") if status.success?
    abort("secret leaked in failure log") if "#{stdout}#{stderr}".include?("bot-secret")
  end
end
puts "identity provider allowlist passes"

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

  _out, _err, status = run_preflight.call("PROVIDER_DISCORD_CLIENT_ID" => "")
  abort("identity accepted missing public provider client ID") if status.success?

  _out, err, status = run_preflight.call("WORKLOAD" => "nilxone-web", "PROVIDER_DISCORD_CLIENT_ID" => "")
  abort("unrelated workload requires identity credentials: #{err}") unless status.success?
end
puts "identity deployment encrypted-handoff preflight passes"
