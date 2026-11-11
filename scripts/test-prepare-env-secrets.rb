#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# runtime.prepareEnvSecrets: a workload may name its own prepareEnv's runtime.env as its secret
# environment, so a service that owns its secrets (AIS) generates them on the host instead of
# taking them from a GitHub Environment or an envelope. Exercises the contract validator, the
# target resolver and the deploy workflow's wiring against copies of the real files.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
AIS = File.join("contracts", "services", "4x-ais.yaml")

def in_copy(mutate = nil)
  Dir.mktmpdir("prepare-env-secrets") do |dir|
    FileUtils.mkdir_p(File.join(dir, "scripts"))
    %w[validate-contracts.rb resolve-workload-target.rb].each { |name| FileUtils.cp(File.join(ROOT, "scripts", name), File.join(dir, "scripts", name)) }
    FileUtils.cp_r(File.join(ROOT, "contracts"), File.join(dir, "contracts"))
    if mutate
      path = File.join(dir, AIS)
      original = File.read(path, encoding: "UTF-8")
      changed = mutate.call(original)
      abort("fixture did not change the contract") if changed == original
      File.write(path, changed)
    end
    yield dir
  end
end

def run(dir, script, *args)
  Open3.capture2e({ "GITHUB_OUTPUT" => nil }, RbConfig.ruby, File.join(dir, "scripts", script), *args)
end

# The shipped contracts are valid. AIS opts in; the others do not.
in_copy do |dir|
  output, status = run(dir, "validate-contracts.rb")
  abort("shipped contracts refused:\n#{output}") unless status.success?
  { "4x-ais" => "true", "nilxone-identity" => "false", "nilxone-web" => "false" }.each do |workload, expected|
    output, status = run(dir, "resolve-workload-target.rb", workload)
    abort("#{workload} did not resolve:\n#{output}") unless status.success?
    abort("#{workload}: prepare_env_secrets should be #{expected}\n#{output}") unless output.lines.map(&:chomp).include?("prepare_env_secrets=#{expected}")
  end
end

def refused(name, pattern, &mutate)
  in_copy(mutate) do |dir|
    output, status = run(dir, "validate-contracts.rb")
    abort("#{name}: accepted") if status.success?
    abort("#{name}: refused for another reason:\n#{output}") unless output.match?(pattern)
  end
end

refused("not a boolean", /prepareEnvSecrets must be true or false/) { |text| text.sub("prepareEnvSecrets: true", 'prepareEnvSecrets: "yes"') }
refused("without a prepareEnv", /prepareEnvSecrets needs runtime.prepareEnv/) { |text| text.sub(/^    prepareEnv: .*\n/, "") }
refused("with runtime.secrets", /mutually exclusive/) { |text| text.sub("    prepareEnvSecrets: true\n", "    prepareEnvSecrets: true\n    secrets:\n      - TOKEN=TOKEN\n") }

# The deploy workflow injects the prepared runtime.env for an opted-in workload, and still does for
# nilxone-identity by name.
workflow = YAML.load_file(File.join(ROOT, ".github", "workflows", "deploy-workload.yml"))
deploy = workflow.fetch("jobs").fetch("deploy")
resolve = workflow.fetch("jobs").fetch("resolve")
abort("resolve job lost its prepare_env_secrets output") unless resolve.dig("outputs", "prepare_env_secrets").to_s.include?("steps.resolve.outputs.prepare_env_secrets")
abort("deploy job does not receive PREPARE_ENV_SECRETS") unless deploy.fetch("env")["PREPARE_ENV_SECRETS"].to_s.include?("needs.resolve.outputs.prepare_env_secrets")
step = deploy.fetch("steps").find { |item| item["name"] == "Prepare target runtime environment" } || abort("prepare step missing")
injection = step.fetch("run")[/if \[\[[^\n]*\]\]; then\n\s*printf 'WORKLOAD_SECRET_ENV_FILE=runtime.env[^\n]*\n\s*fi/m] || abort("the prepared runtime.env is no longer injected")
abort("nilxone-identity is no longer injected") unless injection.include?('"$WORKLOAD" == "nilxone-identity"')
abort("an opted-in workload is not injected") unless injection.include?('"$PREPARE_ENV_SECRETS" == "true"')
puts "prepareEnvSecrets: contract, resolver and workflow wiring passed"
