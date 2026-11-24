#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
#
# The registry login step names where its pull credential came from, never its value.
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

workflow = YAML.load_file(File.expand_path("../.github/workflows/deploy-workload.yml", __dir__))
step = workflow.fetch("jobs").fetch("deploy").fetch("steps").find { |item| item["name"] == "Authenticate container registry" }
abort("registry login step missing") unless step
script = step.fetch("run")

Dir.mktmpdir("ghcr-pull-source") do |dir|
  bin = File.join(dir, "bin")
  FileUtils.mkdir_p(bin)
  File.write(File.join(bin, "ssh"), "#!/usr/bin/env bash\ncat >/dev/null\n")
  File.chmod(0o755, File.join(bin, "ssh"))
  base = {
    "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
    "HOME" => dir,
    "RUNNER_TEMP" => dir,
    "SSH_PORT" => "22",
    "SSH_HOST" => "host",
    "SSH_USER" => "deploy",
    "GITHUB_REPOSITORY_OWNER" => "aiaiaiai-org",
    "GHCR_PULL_USER" => "pull-user",
    "GHCR_PULL_TOKEN" => "infra-token-value",
    "GHCR_PULL_USER_SOURCE" => "github.actor",
    "GHCR_PULL_TOKEN_SOURCE" => "github.token",
    "IMAGE_REF" => "ghcr.io/aiaiaiai-org/aiaiaiai.org@sha256:#{'a' * 64}"
  }
  run = ->(overrides = {}) { Open3.capture2e(base.merge(overrides), "bash", "-c", script) }

  output, status = run.call
  abort("login step failed: #{output}") unless status.success?
  abort("token source not logged: #{output}") unless output.include?("token from github.token, user pull-user from github.actor")
  abort("token value leaked") if output.include?("infra-token-value")
  abort("unexpected fallback warning") if output.include?("::warning::")

  output, status = run.call("IMAGE_REF" => "ghcr.io/0xda-market/core@sha256:#{'a' * 64}")
  abort("fallback login failed: #{output}") unless status.success?
  abort("cross-owner github.token fallback not flagged") unless output.include?("::warning::GHCR pull falls back to github.token")

  output, = run.call("IMAGE_REF" => "ghcr.io/aiaiaiai-org/prism-hub:1")
  abort("same-owner github.token flagged") if output.include?("::warning::")

  File.write(File.join(dir, "source-credentials.env"), "GHCR_PULL_USER=producer-actor\nGHCR_PULL_TOKEN=envelope-token-value\n")
  output, status = run.call
  abort("envelope login failed: #{output}") unless status.success?
  abort("envelope source not logged: #{output}") unless output.include?("token from producer envelope, user producer-actor from producer envelope")
  abort("envelope token leaked") if output.include?("envelope-token-value")
end
# The login must use infra's own token, never a long-lived personal access token.
env = step.fetch("env")
abort("registry login must use github.token") unless env["GHCR_PULL_TOKEN"] == "${{ github.token }}" && env["GHCR_PULL_TOKEN_SOURCE"] == "github.token"
abort("registry login must not reference INFRA_DEPLOY_TOKEN") if env.values.join.include?("INFRA_DEPLOY_TOKEN")
puts "ghcr pull credential source is logged without values"
