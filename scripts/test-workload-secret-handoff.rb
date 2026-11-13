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

  # runtime.secretsFrom: a subset of another workload's envelope, and nothing else, reaches runtime.
  File.write(path, SOURCE + "OTHER_PRODUCT_SECRET=not-for-this-workload\n")
  out, err, result = Open3.capture3(
    {
      "WORKLOAD_SECRETS" => Base64.strict_encode64("TOKEN=HUA_HUB_TOKEN\n"),
      "WORKLOAD_SECRETS_FROM" => "producer",
      "WORKLOAD_SECRET_SOURCE_FILE" => path
    },
    "ruby", SCRIPT
  )
  abort("secretsFrom subset rejected: #{err}") unless result.success?
  abort("secretsFrom passed more than its mapping") unless Base64.strict_decode64(out) == "TOKEN=prism_client_v1_#{'a' * 43}\n"
  File.write(path, SOURCE + "OTHER_PRODUCT_SECRET=not-for-this-workload\n")
  _out, _err, result = Open3.capture3(
    { "WORKLOAD_SECRETS" => Base64.strict_encode64("TOKEN=HUA_HUB_TOKEN\n"), "WORKLOAD_SECRET_SOURCE_FILE" => path },
    "ruby", SCRIPT
  )
  abort("a superset was accepted without secretsFrom") if result.success?

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

  identity = registry + "TELOXIDE_TOKEN=t\nTELEGRAM_OIDC_CLIENT_SECRET=u\nDISCORD_CLIENT_SECRET=v\nNILX_BROWSER_HANDOFF_TOKEN=#{'h' * 64}\n"
  _out, errors, status = run_unmapped.call(identity, "nilxone-identity")
  abort("encrypted identity rejected without legacy secrets: #{errors}") unless status.success?
  [
    identity.sub("DISCORD_CLIENT_SECRET=v\n", ""),
    identity.sub(/NILX_BROWSER_HANDOFF_TOKEN=.*\n/, ""),
    identity.sub('h' * 64, 'short'),
    identity + "HUA_HUB_TOKEN=unapproved\n"
  ].each do |invalid|
    _, _, result = run_unmapped.call(invalid, "nilxone-identity")
    abort("invalid identity credentials accepted") if result.success?
  end

  # API containers receive the token through runtime.secrets; unrelated workers reject it.
  token_line = "NILX_BROWSER_HANDOFF_TOKEN=#{'h' * 64}\n"
  File.write(path, token_line)
  out, err, result = Open3.capture3(
    {"WORKLOAD" => "market-api-development",
     "WORKLOAD_SECRETS" => Base64.strict_encode64("NILX_BROWSER_HANDOFF_TOKEN=NILX_BROWSER_HANDOFF_TOKEN\n"),
     "WORKLOAD_SECRET_SOURCE_FILE" => path}, "ruby", SCRIPT
  )
  abort("API handoff token rejected: #{err}") unless result.success?
  abort("API handoff token missing") unless Base64.strict_decode64(out) == token_line
  _, _, result = run_unmapped.call(registry + token_line, "market-fx-development")
  abort("worker accepted handoff token") if result.success?

  # First-time Market PostgreSQL bootstrap uses Core's complete production
  # envelope before Core has a successful delivery; only the database password
  # from this exact producer envelope may reach the PostgreSQL container.
  market_password = "market-test-" + ("p" * 32)
  market_source = [
    "MARKET_DATABASE_URL=postgres://market:#{market_password}@market-postgres-production:1927/market",
    "MARKET_POSTGRES_PASSWORD=#{market_password}",
    "PUBLIC_API_TOKEN=core-api-token",
    "MANUAL_PROVIDER_TOKEN=manual-provider-token",
    "NILX_BROWSER_HANDOFF_TOKEN=#{'h' * 64}",
    "TRADING_LAB_SERVICE_TOKEN=#{'t' * 64}"
  ].join("\n") + "\n"
  postgres_mapping = Base64.strict_encode64("POSTGRES_PASSWORD=MARKET_POSTGRES_PASSWORD\n")
  postgres_run = lambda do |data, workload = "market-postgres-production", mapping = postgres_mapping|
    File.write(path, data)
    Open3.capture3(
      {
        "WORKLOAD" => workload,
        "WORKLOAD_SECRETS" => mapping,
        "WORKLOAD_SECRET_SOURCE_FILE" => path
      },
      "ruby", SCRIPT
    )
  end
  out, err, status = postgres_run.call(market_source)
  abort("Market bootstrap envelope rejected: #{err}") unless status.success?
  abort("Market bootstrap leaked Core credentials") unless
    Base64.strict_decode64(out) == "POSTGRES_PASSWORD=#{market_password}\n"

  [
    [market_source + "SSH_PRIVATE_KEY=unrelated\n", "market-postgres-production", postgres_mapping],
    [market_source.sub(/^PUBLIC_API_TOKEN=.*\n/, ""), "market-postgres-production", postgres_mapping],
    [market_source.sub(/^TRADING_LAB_SERVICE_TOKEN=.*$/, "TRADING_LAB_SERVICE_TOKEN="), "market-postgres-production", postgres_mapping],
    [market_source + "MARKET_POSTGRES_PASSWORD=duplicate\n", "market-postgres-production", postgres_mapping],
    [market_source, "market-api-production", postgres_mapping],
    [market_source, "market-postgres-production", Base64.strict_encode64("API_TOKEN=PUBLIC_API_TOKEN\n")]
  ].each do |data, workload, mapping|
    out, err, status = postgres_run.call(data, workload, mapping)
    abort("unauthorized Market bootstrap envelope accepted") if status.success?
    abort("Market bootstrap leaked credential values") if "#{out}#{err}".include?(market_password)
  end
end
puts "workload secret handoff contract passes"

