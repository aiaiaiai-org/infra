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
refused("empty prepareEnv", /relative path inside the source repository/) { |text| text.sub("prepareEnv: deploy/prepare-runtime-env.sh", 'prepareEnv: ""') }
refused("traversing prepareEnv", /relative path inside the source repository/) { |text| text.sub("prepareEnv: deploy/prepare-runtime-env.sh", "prepareEnv: ../escape.sh") }
refused("absolute prepareEnv", /relative path inside the source repository/) { |text| text.sub("prepareEnv: deploy/prepare-runtime-env.sh", "prepareEnv: /etc/passwd") }
refused("with runtime.secrets", /mutually exclusive/) { |text| text.sub("    prepareEnvSecrets: true\n", "    prepareEnvSecrets: true\n    secrets:\n      - TOKEN=TOKEN\n") }
refused("with delivery.envelope", /mutually exclusive/) { |text| text.sub("    signerWorkflow: .github/workflows/publish.yml\n", "    signerWorkflow: .github/workflows/publish.yml\n    envelope:\n      - TOKEN\n") }

in_copy(->(text) { text.sub(/^    prepareEnv: .*\n/, "") }) do |dir|
  output, status = run(dir, "resolve-workload-target.rb", "4x-ais")
  abort("resolver accepted prepareEnvSecrets without prepareEnv") if status.success?
  abort("resolver refused for another reason:\n#{output}") unless output.include?("prepareEnvSecrets needs runtime.prepareEnv")
end

in_copy(->(text) { text.sub("prepareEnv: deploy/prepare-runtime-env.sh", "prepareEnv: ../escape.sh") }) do |dir|
  output, status = run(dir, "resolve-workload-target.rb", "4x-ais")
  abort("resolver accepted traversing prepareEnv") if status.success?
  abort("resolver refused for another reason:\n#{output}") unless output.include?("relative path inside the source repository")
end

# The deploy workflow injects the prepared runtime.env for an opted-in workload, and still does for
# nilxone-identity by name. Temporary files on the host are cleaned via trap even on script failure,
# and secret-bearing runtime.env files are locked down to 0600.
workflow = YAML.load_file(File.join(ROOT, ".github", "workflows", "deploy-workload.yml"))
deploy = workflow.fetch("jobs").fetch("deploy")
resolve = workflow.fetch("jobs").fetch("resolve")
abort("resolve job lost its prepare_env_secrets output") unless resolve.dig("outputs", "prepare_env_secrets").to_s.include?("steps.resolve.outputs.prepare_env_secrets")
abort("deploy job does not receive PREPARE_ENV_SECRETS") unless deploy.fetch("env")["PREPARE_ENV_SECRETS"].to_s.include?("needs.resolve.outputs.prepare_env_secrets")
step = deploy.fetch("steps").find { |item| item["name"] == "Prepare target runtime environment" } || abort("prepare step missing")
run_script = step.fetch("run")
remote_body = run_script[/<<'EOF'\n(.*?)\n\s*EOF/m, 1] || abort("remote heredoc missing")
Dir.mktmpdir("prepare-remote") do |dir|
  File.write(File.join(dir, "prepare-runtime-env.sh"), "#!/bin/sh\numask 022\necho KEY=val > \"$1\"\n")
  File.write(File.join(dir, "provider.env"), "SECRET=plain\n")
  output, status = Open3.capture2e("bash", "-s", "--", dir, "4x-ais", "true", stdin_data: remote_body)
  abort("remote snippet failed:\n#{output}") unless status.success?
  abort("provider.env left on host") if File.exist?(File.join(dir, "provider.env"))
  abort("prepare-runtime-env.sh left on host") if File.exist?(File.join(dir, "prepare-runtime-env.sh"))
  mode = File.stat(File.join(dir, "runtime.env")).mode & 0o777
  abort("runtime.env mode #{mode.to_s(8)}, expected 600") unless mode == 0o600

  File.write(File.join(dir, "prepare-runtime-env.sh"), "#!/bin/sh\nexit 1\n")
  File.write(File.join(dir, "provider.env"), "SECRET=plain\n")
  _output, status = Open3.capture2e("bash", "-s", "--", dir, "4x-ais", "true", stdin_data: remote_body)
  abort("failing prepareEnv succeeded") if status.success?
  abort("provider.env leaked on host after failure") if File.exist?(File.join(dir, "provider.env"))
  abort("prepare-runtime-env.sh left on host after failure") if File.exist?(File.join(dir, "prepare-runtime-env.sh"))
end
injection = run_script[/if \[\[[^\n]*\]\]; then\n\s*printf 'WORKLOAD_SECRET_ENV_FILE=runtime.env[^\n]*\n\s*fi/m] || abort("the prepared runtime.env is no longer injected")
abort("nilxone-identity is no longer injected") unless injection.include?('"$WORKLOAD" == "nilxone-identity"')
abort("an opted-in workload is not injected") unless injection.include?('"$PREPARE_ENV_SECRETS" == "true"')
cleanup = deploy.fetch("steps").find { |item| item["name"] == "Clean runner secret material" } || abort("runner cleanup step missing")
abort("runner cleanup omits identity-provider.env") unless cleanup.fetch("run").include?("identity-provider.env")

deliver = YAML.load_file(File.join(ROOT, ".github", "workflows", "deliver-workload.yml"))
abort("deliver-workload does not pin ref to source_sha") unless
  deliver.dig("jobs", "deploy", "with", "ref").to_s.include?("inputs.source_sha")
puts "prepareEnvSecrets: contract, resolver and workflow wiring passed"
