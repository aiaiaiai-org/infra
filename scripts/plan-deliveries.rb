#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Plans automatic deliveries without any producer credential.
#
# For every workload contract with spec.delivery, this script
#   1. reads the head commit of the producer's delivery branch,
#   2. resolves the image the producer published for exactly that commit,
#   3. verifies the image's build provenance: signed by the declared workflow
#      of the producer repository, from that branch and that commit, on a
#      GitHub-hosted runner,
#   4. compares it with the last delivery this repository recorded.
#
# Only the branch head is ever planned, so a late run for an older commit can
# never roll a workload back. Infra reads public producer state with its own
# GITHUB_TOKEN; producers hold no token for infra.
#
# Usage: plan-deliveries.rb [--workload NAME] [--force] [--contracts DIR]
# Writes `deliveries` (JSON array) and `count` to $GITHUB_OUTPUT when set.

require "erb"
require "json"
require "open3"
require "yaml"

ROOT = File.expand_path("..", __dir__)
SETTLED_FAILURES = %w[failure error].freeze
IN_FLIGHT = %w[pending queued in_progress].freeze

def option(name)
  index = ARGV.index(name)
  index && ARGV.fetch(index + 1)
end

def run(*command)
  out, err, status = Open3.capture3(*command)
  [out.strip, err.strip, status.success?]
end

def gh_json(path)
  out, err, ok = run("gh", "api", path)
  abort("gh api #{path} failed: #{err}") unless ok
  JSON.parse(out)
end

def delivery_environment(workload)
  "delivery/#{workload}"
end

def branch_head(repository, branch)
  sha = gh_json("repos/#{repository}/commits/#{ERB::Util.url_encode(branch)}").fetch("sha")
  abort("#{repository}@#{branch}: unexpected commit #{sha.inspect}") unless sha.match?(/\A[0-9a-f]{40}\z/)
  sha
end

# The producer tags each published image with its full commit SHA. The tag only
# locates the image; the digest and its provenance are what get trusted.
def published_digest(image, sha)
  out, err, ok = run("docker", "buildx", "imagetools", "inspect", "#{image}:#{sha}", "--format", "{{json .Manifest}}")
  return JSON.parse(out).fetch("digest") if ok
  return nil if err.match?(/not found|manifest unknown/i)

  abort("#{image}:#{sha}: cannot read the registry (grant this repository read access to the package): #{err}")
end

def verify_provenance!(image, digest, repository, delivery, sha)
  _, err, ok = run(
    "gh", "attestation", "verify", "oci://#{image}@#{digest}",
    "--repo", repository,
    "--signer-workflow", "#{repository}/#{delivery.fetch('signerWorkflow')}",
    "--source-ref", "refs/heads/#{delivery.fetch('branch')}",
    "--source-digest", sha,
    "--deny-self-hosted-runners"
  )
  abort("#{image}@#{digest}: build provenance does not verify for #{repository}@#{sha}: #{err}") unless ok
end

def last_delivery(workload)
  repository = ENV.fetch("GITHUB_REPOSITORY")
  environment = ERB::Util.url_encode(delivery_environment(workload))
  deployment = gh_json("repos/#{repository}/deployments?environment=#{environment}&per_page=1").first
  return nil unless deployment

  status = gh_json("repos/#{repository}/deployments/#{deployment.fetch('id')}/statuses?per_page=1").first
  { image: deployment.dig("payload", "image"), state: status ? status.fetch("state") : "pending" }
end

def decide(workload, image_ref, last, force)
  return [true, "first delivery"] if last.nil?
  return [true, "new image"] unless last[:image] == image_ref
  return [true, "forced redelivery"] if force
  return [false, "already delivered"] if last[:state] == "success"
  return [false, "a delivery of this image is still running"] if IN_FLIGHT.include?(last[:state])
  return [false, "the last delivery of this image failed; dispatch with force to retry"] if SETTLED_FAILURES.include?(last[:state])

  [false, "last delivery state #{last[:state]}"]
end

def contracts(dir, only)
  all = Dir.glob(File.join(dir, "*.yaml")).sort.map { |path| YAML.safe_load(File.read(path), aliases: false) }
  selected = all.select { |contract| contract.dig("spec", "delivery") }
  return selected unless only

  match = selected.select { |contract| contract.dig("metadata", "name") == only }
  abort("workload #{only} has no automatic delivery") if match.empty?
  match
end

force = ARGV.include?("--force")
dir = option("--contracts") || File.join(ROOT, "contracts", "services")
deliveries = []
summary = []

contracts(dir, option("--workload")).each do |contract|
  workload = contract.dig("metadata", "name")
  repository = contract.dig("metadata", "owner")
  delivery = contract.dig("spec", "delivery")
  image = delivery.fetch("image")
  sha = branch_head(repository, delivery.fetch("branch"))
  digest = published_digest(image, sha)
  if digest.nil?
    summary << "#{workload}: #{repository}@#{sha[0, 12]} has no published image yet"
    next
  end

  verify_provenance!(image, digest, repository, delivery, sha)
  image_ref = "#{image}@#{digest}"
  deliver, reason = decide(workload, image_ref, last_delivery(workload), force)
  summary << "#{workload}: #{repository}@#{sha[0, 12]} #{image_ref}: #{reason}"
  deliveries << { "workload" => workload, "image" => image_ref, "source_sha" => sha } if deliver
end

puts summary
if ENV["GITHUB_OUTPUT"]
  File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |file|
    file.puts("deliveries=#{JSON.generate(deliveries)}")
    file.puts("count=#{deliveries.length}")
  end
end
if ENV["GITHUB_STEP_SUMMARY"]
  File.open(ENV.fetch("GITHUB_STEP_SUMMARY"), "a") { |file| file.puts(summary.map { |line| "- #{line}" }) }
end
