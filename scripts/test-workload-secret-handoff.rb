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
end
puts "workload secret handoff contract passes"
