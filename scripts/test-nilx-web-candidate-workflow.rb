#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "yaml"
path = File.expand_path("../.github/workflows/stage-nilx-web-candidate.yml", __dir__)
source = File.read(path)
flow = YAML.load_file(path)
abort "must be manually dispatched" unless source.match?(/^on:\n  workflow_dispatch:\n\n/)
abort "must use edge-dev-1 Environment" unless flow.dig("jobs", "stage", "environment", "name") == "edge-dev-1"
abort "SSH host key not pinned" unless source.include?("StrictHostKeyChecking=yes") && source.include?("vars.SSH_HOST_ED25519_PUBKEY")
abort "source provenance not verified" unless source.include?("gh attestation verify") && source.include?("--source-digest") && source.include?("--deny-self-hosted-runners")
abort "candidate image unpinned" unless source.include?("ghcr.io/nilx-one/web@sha256:")
docker_run = source[/docker run --detach[\s\S]*?"\$image" >\/dev\/null/]
abort "missing Docker candidate creation" unless docker_run
abort "candidate must not publish ports" if docker_run.match?(/\s(?:-p|--publish|--publish-all)(?:\s|=)/)
abort "candidate must not alter DNS" if source.include?("dns_records") || source.include?("cloudflare-wildcard.sh")
abort "candidate must not replace Identity data" if source.include?("identity.db") || source.include?("nilxone-identity-data")
abort "candidate must fail on different image" unless source.include?("refuse to replace")
abort "Telegram candidate missing" unless source.include?("nilxone-telegram-candidate") && source.include?("/srv/telegram-mini-app")
abort "Discord candidate missing" unless source.include?("nilxone-discord-candidate") && source.include?("/srv/discord-activity")
abort "client staging must use the verified digest" unless source.include?('bash -s -- "$IMAGE"')
abort "client staging may not publish Docker ports" if source.scan(/docker run --detach[\s\S]*?"\$image" >\/dev\/null/).any? { |cmd| cmd.match?(/\s(?:-p|--publish|--publish-all)(?:\s|=)/) }

puts "candidate contract is manual, attested, isolated, read-only outside its own runtime"
