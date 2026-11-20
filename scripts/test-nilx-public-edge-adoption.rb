#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

workflow = File.read('.github/workflows/adopt-nilx-public-edge.yml')
script = File.read('deploy/nilx-public-edge/adopt.sh')
caddy = File.read('deploy/nilx-public-edge/Caddyfile')
def require_contract(value, message)
  abort message unless value
end

require_contract(workflow.match?(/^on:\n  workflow_dispatch:/), 'must be manual-only')
require_contract(workflow.include?("github.ref == 'refs/heads/master'"), 'must require master')
require_contract(workflow.include?('name: edge-dev-1'), 'must use new VPS Environment')
require_contract(workflow.include?('SSH_HOST_ED25519_PUBKEY'), 'must pin host SSH key')
require_contract(workflow.include?('test "$SSH_HOST" = 158.220.74.54'), 'must pin VPS IP')
require_contract(workflow.include?('test "$CONFIRMATION" = ACTIVATE'), 'activation confirmation required')
require_contract(workflow.include?('test "$CONFIRMATION" = ROLLBACK'), 'rollback confirmation required')
require_contract(!workflow.include?('INFRA_DEPLOY_TOKEN'), 'no PATs in ingress')
require_contract(!workflow.include?('repository_dispatch'), 'no cross-repo dispatch')
require_contract(script.include?('trap recover_legacy ERR'), 'automatic legacy restoration')
require_contract(script.include?('trap recover_managed ERR'), 'rollback restoration')
require_contract(script.include?('caddy adapt'), 'compare effective Caddy config')
require_contract(script.include?('nilx-public-edge-caddy-data'), 'reuse TLS data volume')
require_contract(script.include?('nilx-public-edge-caddy-config'), 'reuse TLS config volume')
require_contract(!script.include?('docker volume rm'), 'never delete TLS volumes')
require_contract(!script.include?('docker rm --force "$legacy"'), 'retain manual fallback')
require_contract(!script.include?('docker network create'), 'never create surprise edge network')
require_contract(caddy.match?(/^nilx\.one \{/), 'only apex')
require_contract(caddy.include?('reverse_proxy nilxone-web-candidate:1927'), 'keep verified upstream')
require_contract(!caddy.include?('*.nilx.one'), 'do not fake wildcard support')
require_contract(!caddy.include?('nilxone-identity:'), 'do not fake Identity availability')
puts 'Single-VPS ingress adoption contract validated'
