#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

wf = File.read('.github/workflows/bootstrap-nilx-identity-fresh.yml')
runtime = File.read('deploy/nilx-identity-fresh/activate.sh')
def contract(condition, message)
  abort message unless condition
end

contract(wf.include?("on:\n  workflow_dispatch:"), 'manual-only workflow')
contract(!wf.include?('repository_dispatch'), 'no cross-repo automatic delivery')
contract(wf.include?("github.ref == 'refs/heads/master'"), 'trusted branch')
contract(wf.include?('deployment: ${{ inputs.operation == \'activate\' }}'), 'validate is not a deploy')
contract(wf.include?('test "$SSH_HOST" = 158.220.74.54'), 'sole VPS pin')
contract(wf.include?('test "$SSH_USER" = deploy'), 'least-privilege deploy user')
contract(wf.include?('SSH_HOST_ED25519_PUBKEY'), 'host key pinning')
contract(wf.include?('FRESH_IDENTITY'), 'explicit one-time fresh-store consent')
contract(wf.include?('TELOXIDE_TOKEN'), 'real Telegram bot token required')
contract(wf.include?('gh attestation verify'), 'image provenance verified')
contract(wf.include?('package-identity-service.yml'), 'verify correct signer')
contract(wf.include?('c7533e05f4c12b2a1d425cfb72fb717ec40b71f2'), 'exact pinned source')
contract(wf.include?('jq -e'), 'real AIS product client configured')
contract(!wf.include?('INFRA_DEPLOY_TOKEN'), 'no PAT needed')
contract(runtime.include?('nilxone-identity-fresh-data'), 'isolated new data volume')
contract(runtime.include?('docker volume create'), 'persistent storage')
contract(runtime.include?('--network-alias nilxone-identity'), 'compatible Web upstream')
contract(runtime.include?('AIAIAIAI_SIGN_IN_ISSUER=https://auth.aiaiaiai.org'), 'AIS is identity issuer')
contract(runtime.include?('PUBLIC_ORIGIN=https://nilx.one'), 'same origin product callback')
contract(runtime.include?('NATIVE_AUTH_SECRET='), 'host-owned native key')
contract(runtime.include?('PASSWORD_PEPPER='), 'host-owned password pepper')
contract(runtime.include?('GITHUB_EVIDENCE_ENCRYPTION_KEY='), 'host-owned evidence key')
contract(runtime.include?('mv --no-clobber'), 'secret file never overwritten')
contract(!runtime.include?('nilxone-identity-data:/data'), 'never mount legacy volume')
contract(!runtime.include?('--publish'), 'no public Identity port')
contract(!runtime.include?('MARKET_TELEGRAM_ISSUER_URL='), 'purchase queue not enabled')
contract(!runtime.include?('NILX_BROWSER_HANDOFF_TOKEN='), 'no issuer worker configured')
contract(!runtime.include?('docker volume rm'), 'never delete state')
puts 'Fresh Identity first-use bootstrap boundaries: OK'
