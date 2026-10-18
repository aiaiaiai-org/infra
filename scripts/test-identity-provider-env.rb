#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
require "open3"
require "tmpdir"

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
