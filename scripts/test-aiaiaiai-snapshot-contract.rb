#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "yaml"

def check(condition, message)
  abort(message) unless condition
end

site = YAML.safe_load(File.read("contracts/services/aiaiaiai-site.yaml"))
check(site.dig("spec", "delivery", "mode") == "manual", "legacy site auto-delivery must be frozen")
check(site.dig("spec", "port") == 1927, "site port changed")
old = YAML.safe_load(File.read("contracts/servers/edge-prod-2.yaml"))
check(old.dig("spec", "workloads").include?("aiaiaiai-site"), "retire old site only after rollback no longer needed")
new_target = YAML.safe_load(File.read("contracts/servers/edge-dev-1.yaml"))
check(new_target.dig("spec", "state") == "provisioning", "no surprise production workload placement")
check(new_target.dig("spec", "workloads") == [], "new VPS contract must not silently assign public workloads")

ingress = File.read("deploy/nilx-public-edge/Caddyfile")
check(ingress.match?(/^nilx\.one \{/), "existing nilx.one ingress removed")
check(ingress.include?("reverse_proxy nilxone-web-candidate:1927"), "nilx.one upstream changed")
check(ingress.include?("aiaiaiai.org, beta.aiaiaiai.org"), "site hosts not on shared ingress")
check(ingress.include?("reverse_proxy aiaiaiai-site-archive:1927"), "site upstream missing")

private_caddy = File.read("deploy/aiaiaiai-site-snapshots/Caddyfile")
check(private_caddy.include?("auto_https off"), "private site must not request public TLS")
check(private_caddy.include?(":1927 {"), "private site port missing")
check(private_caddy.include?("path_regexp beta_version"), "beta historical matcher missing")
check(private_caddy.include?("path_regexp release_version"), "release historical matcher missing")
check(private_caddy.include?("/beta/current/index.html"), "beta alias missing")
check(private_caddy.include?("/release/current/index.html"), "release alias missing")
check(private_caddy.include?("https://beta.aiaiaiai.org 302"), "unreleased apex redirect missing")

snapshot = File.read("deploy/aiaiaiai-site-snapshots/stage.sh")
check(snapshot.include?('ghcr\\.io/aiaiaiai-org/aiaiaiai\\.org@sha256:'), "only immutable image digests may be staged")
check(snapshot.include?('test "$(hostname)" = edge-dev-1'), "archive must pin new host")
check(snapshot.include?('test -z "$(docker port aiaiaiai-site-archive)"'), "archive must not publish ports")
check(snapshot.include?('Version already exists with another digest'), "immutable version guard missing")
check(snapshot.include?('mv -Tf "$alias_path.new.$$" "$alias_path"'), "alias switch must be atomic")
check(snapshot.include?("previous alias restored"), "alias activation must roll back")
check(snapshot.include?("Automatic release downgrade refused"), "release alias must be monotonic")

%w[
  .github/workflows/stage-aiaiaiai-snapshots.yml
  .github/workflows/adopt-aiaiaiai-ingress.yml
].each do |path|
  wf = File.read(path)
  check(wf.match?(/^on:\n  workflow_dispatch:/), "#{path}: public mutation must be manual-only")
  check(wf.include?("name: edge-dev-1"), "#{path}: must use pinned VPS Environment")
  check(wf.include?("SSH_HOST_ED25519_PUBKEY"), "#{path}: missing SSH host pin")
  check(wf.include?("github.ref == 'refs/heads/master'"), "#{path}: branch protection missing")
  check(wf.include?("CONFIRMATION"), "#{path}: missing explicit activation confirmation")
  check(!wf.include?("INFRA_DEPLOY_TOKEN") && !wf.match?(/^\s*ssh-keyscan /), "#{path}: unsafe credentials")
end

public_adoption = File.read("deploy/aiaiaiai-site-snapshots/ingress.sh")
check(public_adoption.include?("nilx-public-edge-managed"), "must reuse running 0x1 ingress")
check(public_adoption.include?("ingress.previous.Caddyfile"), "missing rollback snapshot")
check(public_adoption.include?("healthy_nilx"), "nilx.one smoke required")
check(!public_adoption.include?("--publish") && !public_adoption.include?("docker network create"), "must not create second public ingress")

auto = File.read(".github/workflows/reconcile-aiaiaiai-site.yml")
reconciler = File.read("scripts/reconcile-aiaiaiai-site.sh")
check(auto.include?("schedule:") && auto.include?("workflow_dispatch:"), "automatic publication must be scheduled")
check(auto.include?("name: edge-dev-1"), "automatic publication must use pinned VPS environment")
check(auto.include?("cancel-in-progress: false"), "reconciler must serialize")
check(auto.include?("github.ref == 'refs/heads/master'"), "reconciler may only run from master")
check(reconciler.include?("--source-digest"), "attestation must match source commit")
check(reconciler.include?("--source-ref"), "attestation must match source ref")
check(reconciler.include?("current_master"), "beta must follow merge commit master head")
check(reconciler.include?("git/ref/tags") == false, "release check uses resolved tag commit")
check(reconciler.include?('commits/$latest_tag'), "release tag target must be rechecked")
check(reconciler.include?("sort -Vu"), "release versions must sort by SemVer")
check(reconciler.include?("stage_remote") && reconciler.include?("activate_remote"), "publication must stage and activate")
check(!reconciler.include?("INFRA_DEPLOY_TOKEN"), "no cross-repository personal token")
check(!reconciler.include?("cloudflare") && !reconciler.include?("docker network create"), "no automatic DNS or ingress mutation")

puts "aiaiaiai.org site snapshot isolation and automatic publication validated"
