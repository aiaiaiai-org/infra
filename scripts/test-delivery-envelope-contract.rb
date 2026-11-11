#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Exercises validate-contracts.rb on nilxone-identity's delivery.envelope, against a copy of the
# real contracts. The envelope may list the names its prepareEnv consumes, never a server-owned
# native secret, and never combines with runtime.secrets.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
VALIDATOR = File.join(ROOT, "scripts", "validate-contracts.rb")
IDENTITY = File.join("contracts", "services", "nilxone-identity.yaml")

def validate(mutate)
  Dir.mktmpdir("envelope-contract") do |dir|
    FileUtils.mkdir_p(File.join(dir, "scripts"))
    FileUtils.cp(VALIDATOR, File.join(dir, "scripts", "validate-contracts.rb"))
    FileUtils.cp_r(File.join(ROOT, "contracts"), File.join(dir, "contracts"))
    path = File.join(dir, IDENTITY)
    original = File.read(path, encoding: "UTF-8")
    changed = mutate.call(original)
    abort("fixture did not change the identity contract") if changed == original
    File.write(path, changed)
    output, status = Open3.capture2e(RbConfig.ruby, File.join(dir, "scripts", "validate-contracts.rb"))
    [status.success?, output]
  end
end

def refused(name, pattern, &mutate)
  ok, output = validate(mutate)
  abort("#{name}: accepted") if ok
  abort("#{name}: refused for another reason:\n#{output}") unless output.match?(pattern)
end

# The shipped contract is valid and lists exactly what the identity envelope carries.
contract = File.read(File.join(ROOT, IDENTITY), encoding: "UTF-8")
abort("identity contract lost its envelope") unless contract.include?("    envelope:\n")
%w[NATIVE_AUTH_SECRET PASSWORD_PEPPER GITHUB_EVIDENCE_ENCRYPTION_KEY].each do |name|
  abort("identity contract lists server-owned #{name}") if contract.match?(/^\s+- #{name}$/)
end
# The AIS sign-in pair is listed together, so a producer that carries it is not refused.
%w[AIAIAIAI_SIGN_IN_ISSUER AIAIAIAI_SIGN_IN_CLIENT_SECRET].each do |name|
  abort("identity contract does not list #{name}") unless contract.match?(/^      - #{name}$/)
end

%w[NATIVE_AUTH_SECRET PASSWORD_PEPPER GITHUB_EVIDENCE_ENCRYPTION_KEY].each do |name|
  refused("server-owned #{name}", /server-owned #{name}/) { |text| text.sub("      - TELOXIDE_TOKEN\n", "      - TELOXIDE_TOKEN\n      - #{name}\n") }
end
refused("registry credential", /GHCR_ credentials never travel/) { |text| text.sub("      - TELOXIDE_TOKEN\n", "      - TELOXIDE_TOKEN\n      - GHCR_PULL_TOKEN\n") }
refused("duplicate name", /names a variable twice/) { |text| text.sub("      - TELOXIDE_TOKEN\n", "      - TELOXIDE_TOKEN\n      - TELOXIDE_TOKEN\n") }
refused("lowercase name", /non-empty array of NAMES/) { |text| text.sub("      - TELOXIDE_TOKEN\n", "      - teloxide_token\n") }
refused("empty envelope", /non-empty array of NAMES/) { |text| text.sub(/    envelope:\n(      - [A-Z_]+\n)+/, "    envelope: []\n") }
refused("no prepareEnv", /needs runtime.prepareEnv/) { |text| text.sub(/^    prepareEnv: .*\n/, "") }
refused("with runtime.secrets", /mutually exclusive/) { |text| text.sub("    labels:\n", "    secrets:\n      - TOKEN=TOKEN\n    labels:\n") }
puts "Delivery envelope contract: 9 cases passed"
