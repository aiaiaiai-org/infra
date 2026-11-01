#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Exercises plan-deliveries.rb against stubbed gh and docker commands.

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

PLANNER = File.expand_path("plan-deliveries.rb", __dir__)
SHA = "a" * 40
DIGEST = "sha256:#{'b' * 64}"
IMAGE = "ghcr.io/example/site"
IMAGE_REF = "#{IMAGE}@#{DIGEST}"
CONTRACT = <<~YAML
  apiVersion: infra.nilx.one/v1
  kind: WorkloadContract
  metadata:
    name: example-site
    owner: example/site
  spec:
    delivery:
      image: #{IMAGE}
      branch: master
      signerWorkflow: .github/workflows/publish.yml
YAML

# Stubs read the scenario from $STUB_STATE and log their arguments.
GH_STUB = "#!#{RbConfig.ruby}\n" + <<~'RUBY'
  require "json"
  state = JSON.parse(File.read(ENV.fetch("STUB_STATE")))
  File.open(ENV.fetch("STUB_LOG"), "a") { |f| f.puts(ARGV.join(" ")) }
  if ARGV[0] == "attestation"
    exit(state.fetch("attested") ? 0 : 1)
  end
  path = ARGV.fetch(1)
  if path.start_with?("repos/example/site/commits/")
    puts JSON.generate("sha" => state.fetch("head"))
  elsif path.include?("/statuses")
    puts JSON.generate(state["last_state"] ? [{ "state" => state["last_state"] }] : [])
  elsif path.include?("/deployments?")
    last = state["last_image"]
    puts JSON.generate(last ? [{ "id" => 7, "payload" => { "image" => last } }] : [])
  else
    warn "unexpected gh api #{path}"
    exit 1
  end
RUBY
DOCKER_STUB = "#!#{RbConfig.ruby}\n" + <<~'RUBY'
  require "json"
  state = JSON.parse(File.read(ENV.fetch("STUB_STATE")))
  if state["published"]
    puts JSON.generate("digest" => state.fetch("digest"))
  else
    warn "ERROR: #{ARGV[3]}: not found"
    exit 1
  end
RUBY

def plan(state, *args)
  Dir.mktmpdir do |dir|
    bin = File.join(dir, "bin")
    contracts = File.join(dir, "contracts")
    FileUtils.mkdir_p([bin, contracts])
    { "gh" => GH_STUB, "docker" => DOCKER_STUB }.each do |name, body|
      File.write(File.join(bin, name), body)
      File.chmod(0o755, File.join(bin, name))
    end
    File.write(File.join(contracts, "example-site.yaml"), CONTRACT)
    File.write(File.join(dir, "state.json"), JSON.generate({ "head" => SHA, "digest" => DIGEST }.merge(state)))
    output = File.join(dir, "output")
    env = {
      "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
      "STUB_STATE" => File.join(dir, "state.json"),
      "STUB_LOG" => File.join(dir, "gh.log"),
      "GITHUB_REPOSITORY" => "example/infra",
      "GITHUB_OUTPUT" => output,
      "GITHUB_STEP_SUMMARY" => File.join(dir, "summary")
    }
    log, status = Open3.capture2e(env, RbConfig.ruby, PLANNER, "--contracts", contracts, *args)
    outputs = File.exist?(output) ? File.read(output).lines.to_h { |line| line.chomp.split("=", 2) } : {}
    calls = File.exist?(env["STUB_LOG"]) ? File.read(env["STUB_LOG"]) : ""
    { ok: status.success?, count: outputs["count"]&.to_i, deliveries: JSON.parse(outputs["deliveries"] || "[]"), log: log, calls: calls }
  end
end

def expect(name, result, ok:, count: nil)
  return if result[:ok] == ok && (count.nil? || result[:count] == count)

  abort("#{name}: expected ok=#{ok} count=#{count.inspect}, got ok=#{result[:ok]} count=#{result[:count].inspect}\n#{result[:log]}")
end

attested = { "published" => true, "attested" => true }

first = plan(attested)
expect("first delivery", first, ok: true, count: 1)
abort("first delivery: wrong entry #{first[:deliveries]}") unless
  first[:deliveries] == [{ "workload" => "example-site", "image" => IMAGE_REF, "source_sha" => SHA }]
verify = first[:calls].lines.find { |line| line.start_with?("attestation verify") }.to_s
%W[oci://#{IMAGE_REF} --repo\ example/site --signer-workflow\ example/site/.github/workflows/publish.yml
   --source-ref\ refs/heads/master --source-digest\ #{SHA} --deny-self-hosted-runners].each do |part|
  abort("first delivery: attestation verify lacks #{part}: #{verify}") unless verify.include?(part)
end

expect("up to date", plan(attested.merge("last_image" => IMAGE_REF, "last_state" => "success")), ok: true, count: 0)
expect("new image", plan(attested.merge("last_image" => "#{IMAGE}@sha256:#{'c' * 64}", "last_state" => "success")), ok: true, count: 1)
expect("in flight", plan(attested.merge("last_image" => IMAGE_REF, "last_state" => "in_progress")), ok: true, count: 0)
expect("failed, no retry", plan(attested.merge("last_image" => IMAGE_REF, "last_state" => "failure")), ok: true, count: 0)
expect("failed, forced", plan(attested.merge("last_image" => IMAGE_REF, "last_state" => "failure"), "--force"), ok: true, count: 1)
expect("not published yet", plan("published" => false, "attested" => true), ok: true, count: 0)
expect("provenance mismatch", plan("published" => true, "attested" => false), ok: false)
expect("unknown workload", plan(attested, "--workload", "missing"), ok: false)
expect("workload filter", plan(attested, "--workload", "example-site"), ok: true, count: 1)
puts "Delivery planner: 10 cases passed"
