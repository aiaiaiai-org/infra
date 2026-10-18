#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
#
# Test the contract boundary without copying application credentials to infra.
require "base64"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("workload-secret-env.rb", __dir__)
MAPPING = Base64.strict_encode64("HUA_HUB_TOKEN=HUA_HUB_TOKEN\nHUA_DELIVERY_SECRET=HUA_DELIVERY_SECRET\n")
SOURCE = "HUA_HUB_TOKEN=prism_client_v1_#{'a' * 43}\nHUA_DELIVERY_SECRET=#{'b' * 64}\nGHCR_PULL_USER=bot-owner\nGHCR_PULL_TOKEN=short-lived\n"

Dir.mktmpdir("scoped-secrets") do |directory|
  path = File.join(directory, "source.env")
  run = lambda do |data|
    File.write(path, data)
    Open3.capture3(
      {
        "WORKLOAD_SECRETS" => MAPPING,
        "WORKLOAD_SECRET_SOURCE_FILE" => path,
        "ALL_SECRETS" => '{"SSH_PRIVATE_KEY":"must-not-be-used"}'
      },
      "ruby", SCRIPT
    )
  end

  stdout, stderr, status = run.call(SOURCE)
  abort("valid source was rejected: #{stderr}") unless status.success?
  expected = SOURCE.lines.reject { |line| line.start_with?("GHCR_") }.join
  abort("registry credentials reached runtime") unless Base64.strict_decode64(stdout) == expected

  [
    SOURCE + "SSH_PRIVATE_KEY=forbidden\n",
    SOURCE + "HUA_HUB_TOKEN=duplicate\n",
    SOURCE.sub(/HUA_DELIVERY_SECRET=.*\n/, ""),
    SOURCE.sub("HUA_HUB_TOKEN=", "HUA_HUB_TOKEN2="),
    SOURCE.sub("HUA_HUB_TOKEN=", "HUA_HUB_TOKEN=wrong\nHUA_HUB_TOKEN=")
  ].each do |invalid|
    out, err, result = run.call(invalid)
    abort("invalid source accepted") if result.success?
    abort("secret content leaked into diagnostics") if "#{out}#{err}".include?("short-lived")
  end

  # Workloads without runtime.secrets must still enforce the registry-only allowlist.
  run_unmapped = lambda do |data, workload|
    File.write(path, data)
    Open3.capture3(
      {
        "WORKLOAD" => workload,
        "WORKLOAD_SECRETS" => "",
        "WORKLOAD_SECRET_SOURCE_FILE" => path
      },
      "ruby", SCRIPT
    )
  end
  registry = "GHCR_PULL_USER=bot-owner\nGHCR_PULL_TOKEN=short-lived\n"
  _out, errors, status = run_unmapped.call(registry, "nilxone-web")
  abort("registry-only web payload rejected: #{errors}") unless status.success?

  [
    registry + "SSH_PRIVATE_KEY=unexpected\n",
    registry + "GHCR_PULL_TOKEN=duplicate\n",
    registry.sub("GHCR_PULL_TOKEN=short-lived\n", ""),
    registry + "TELOXIDE_TOKEN=not-for-web\n",
    registry + "UNRELATED=bad\n",
    registry + ("X" * 33_000),
    registry + "INVALID=carriage\rreturn\n",
    registry + "INVALID=nul\0byte\n"
  ].each do |invalid|
    out, err, result = run_unmapped.call(invalid, "nilxone-web")
    abort("invalid registry-only payload accepted") if result.success?
    abort("registry token leaked into diagnostics") if "#{out}#{err}".include?("short-lived")
  end

  identity = registry + "TELOXIDE_TOKEN=t\nTELEGRAM_OIDC_CLIENT_SECRET=u\nDISCORD_CLIENT_SECRET=v\n"
  _out, errors, status = run_unmapped.call(identity, "nilxone-identity")
  abort("encrypted identity rejected without legacy secrets: #{errors}") unless status.success?
  [
    identity.sub("DISCORD_CLIENT_SECRET=v\n", ""),
    identity + "HUA_HUB_TOKEN=unapproved\n"
  ].each do |invalid|
    _, _, result = run_unmapped.call(invalid, "nilxone-identity")
    abort("invalid identity credentials accepted") if result.success?
  end
end
puts "workload secret handoff contract passes"
