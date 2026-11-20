#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

path = File.expand_path("../.github/workflows/stage-nilx-clients-from-web.yml", __dir__)
source = File.read(path)
abort "only scoped repository_dispatch allowed" unless source.match?(/^on:\n  repository_dispatch:\n    types: \[stage-nilx-clients\]/)
abort "must verify source workflow run" unless source.include?("stage-clients.yml") &&
  source.include?(".head_sha == $sha") && source.include?(".head_branch == $branch") &&
  source.include?(".conclusion == \"success\"")
abort "must verify exact OCI image" unless source.include?("gh attestation verify") &&
  source.include?("--source-digest") && source.include?("--source-ref") &&
  source.include?("--deny-self-hosted-runners")
abort "must use isolated target Environment" unless source.include?("name: edge-dev-1")
abort "must pin SSH host identity" unless source.include?("StrictHostKeyChecking=yes") &&
  source.include?("SSH_HOST_ED25519_PUBKEY")
abort "all client selectors required" unless %w[all web telegram discord].all? { |x| source.include?(x) }
abort "production container guard required" unless source.include?("for name in nilxone-web nilxone-telegram nilxone-discord nilxone-identity")
abort "must use no public ports" if source.match?(/docker run[^\n]*(?:--publish|-p )/)
abort "must not alter DNS" if source.include?("dns_records") || source.include?("cloudflare-wildcard.sh")
abort "must not open legacy Identity database" if source.include?("identity.db") || source.include?("nilxone-identity-data")
puts "cross-repository staging bounded to attested Web run, selectors and private candidates"
