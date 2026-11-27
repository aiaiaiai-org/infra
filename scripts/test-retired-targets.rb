#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# A retired server must not be a deployment target: no entrypoint may select its GitHub Environment
# (the SSH credentials behind it). Exercises both credential-selecting entrypoints that resolve a
# server from a contract, with negative cases, and pins the structure that keeps them that way.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "lib/live_copy"

ROOT = File.expand_path("..", __dir__)

def run(*command, env: {})
  Open3.capture3(env, RbConfig.ruby, *command)
end

# --- entrypoint 1: Deploy workload and the recipient dispatch path resolve a workload's server.
# A workload on a retired server is refused, and nothing reaches the job's outputs.
%w[market-api-production market-bot-production market-postgres-production aiaiaiai-site].each do |workload|
  Dir.mktmpdir("retired-output") do |dir|
    output = File.join(dir, "output")
    stdout, stderr, status = run(File.join(ROOT, "scripts", "resolve-workload-target.rb"), workload,
                                 env: { "GITHUB_OUTPUT" => output })
    abort("#{workload}: a retired placement resolved") if status.success?
    abort("#{workload}: refused for another reason: #{stderr}") unless stderr.include?("placed on retired server")
    abort("#{workload}: the resolver printed a target") if stdout.include?("target=")
    abort("#{workload}: the resolver wrote outputs before refusing") if File.exist?(output)
  end
end

# A workload on a live server still resolves.
stdout, stderr, status = run(File.join(ROOT, "scripts", "resolve-workload-target.rb"), "prism-hub", env: { "GITHUB_OUTPUT" => nil })
abort("prism-hub did not resolve: #{stderr}") unless status.success? && stdout.lines.map(&:chomp).include?("target=edge-dev-1")

# The shape of a retired server's workload contract is still checked, on a copy where it is active.
stdout, stderr, status = LiveCopy.resolve(ROOT, "market-api-production")
abort("market-api-production did not resolve on the live copy: #{stderr}") unless status.success?
%w[target=edge-prod-1 network=nilx-edge].each do |line|
  abort("market-api-production: missing #{line}") unless stdout.lines.map(&:chomp).include?(line)
end

# The 0x1 product runs on edge-dev-1: it resolves there, in the managed ingress's network.
stdout, stderr, status = run(File.join(ROOT, "scripts", "resolve-workload-target.rb"), "nilxone-web", env: { "GITHUB_OUTPUT" => nil })
abort("nilxone-web did not resolve: #{stderr}") unless status.success?
%w[target=edge-dev-1 network=nilx-candidate alias=nilxone-web port=1927 health=/health].each do |line|
  abort("nilxone-web: missing #{line}") unless stdout.lines.map(&:chomp).include?(line)
end

# --- entrypoint 2: a server named directly (Issue workload encryption recipient, by hand).
guard = File.join(ROOT, "scripts", "assert-live-server.rb")
out, = run(guard, "edge-dev-1")
abort("a live server was refused") unless out.include?("server edge-dev-1 is live")
%w[edge-prod-1 edge-prod-2].each do |server|
  _, stderr, status = run(guard, server)
  abort("#{server}: a retired server was accepted") if status.success?
  abort("#{server}: refused for another reason: #{stderr}") unless stderr.include?("is retired")
end
[["no-such-server", "unknown server"], ["../servers/edge-dev-1", "usage"], ["", "usage"]].each do |name, reason|
  _, stderr, status = run(guard, name)
  abort("#{name.inspect}: accepted") if status.success?
  abort("#{name.inspect}: refused for another reason: #{stderr}") unless stderr.include?(reason)
end

# --- the workflows keep going through those entrypoints.
recipient = YAML.load_file(File.join(ROOT, ".github", "workflows", "issue-workload-recipient.yml"))
resolve_script = recipient.dig("jobs", "resolve", "steps").find { |step| step["id"] == "target" }.fetch("run")
abort("the by-hand recipient path no longer asserts a live server") unless
  resolve_script.include?('ruby scripts/assert-live-server.rb "$TARGET"') &&
  resolve_script.index("assert-live-server.rb") < resolve_script.index('echo "target=$TARGET"')
abort("the dispatch recipient path no longer resolves through the resolver") unless
  resolve_script.include?('ruby scripts/resolve-workload-target.rb "$WORKLOAD"')
abort("the recipient job must take its Environment from the resolve job") unless
  recipient.dig("jobs", "recipient", "environment", "name") == "${{ needs.resolve.outputs.target }}"

deploy = YAML.load_file(File.join(ROOT, ".github", "workflows", "deploy-workload.yml"))
abort("Deploy workload must take its Environment only from the resolver") unless
  deploy.dig("jobs", "deploy", "environment", "name") == "${{ needs.resolve.outputs.target }}"
resolve_step = deploy.dig("jobs", "resolve", "steps").find { |step| step["id"] == "resolve" } || abort("resolve step missing")
abort("Deploy workload's resolve step no longer runs the resolver") unless resolve_step.fetch("run").include?("scripts/resolve-workload-target.rb")

show = YAML.load_file(File.join(ROOT, ".github", "workflows", "show-encryption-recipient.yml"))
options = show.dig(true, "workflow_dispatch", "inputs", "target", "options") || show.dig("on", "workflow_dispatch", "inputs", "target", "options")
retired = Dir.glob(File.join(ROOT, "contracts", "servers", "*.yaml")).filter_map do |path|
  server = YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: false)
  server.dig("metadata", "name") if server.dig("spec", "state") == "retired"
end
abort("Show workload encryption recipient offers no server") if options.to_a.empty?
abort("Show workload encryption recipient offers a retired server: #{options & retired}") unless (options & retired).empty?

puts "retired targets: resolver, by-hand recipient and workflow wiring passed"
