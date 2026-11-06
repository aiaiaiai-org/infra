#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Read-only check of the four configured Telegram-source cursors.
# No post bodies, subscriber data, chat identifiers or credentials are queried.
set -Eeuo pipefail
umask 077

for name in SSH_HOST SSH_USER SSH_PRIVATE_KEY SSH_PORT; do
  [[ -n "$(printenv "$name")" ]] || { echo "::error::Missing SSH credential $name" >&2; exit 78; }
done
[[ "$SSH_HOST" == "62.238.19.244" && "$SSH_USER" == "deploy" ]] ||
  { echo "::error::Unexpected production target" >&2; exit 78; }
[[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) ||
  { echo "::error::Invalid SSH port" >&2; exit 78; }

for command in ssh ssh-keyscan ssh-keygen; do
  command -v "$command" >/dev/null || { echo "::error::Missing $command" >&2; exit 78; }
done

ssh_dir="$(mktemp -d)"
trap 'rm -rf "$ssh_dir"' EXIT
printf '%s\n' "$SSH_PRIVATE_KEY" > "$ssh_dir/key"
chmod 600 "$ssh_dir/key"
ssh-keygen -y -P '' -f "$ssh_dir/key" >/dev/null
ssh-keyscan -T 10 -p "$SSH_PORT" -t ed25519 "$SSH_HOST" > "$ssh_dir/known_hosts" 2>/dev/null
test -s "$ssh_dir/known_hosts"
fingerprints="$(ssh-keygen -lf "$ssh_dir/known_hosts" -E sha256)"
[[ "$(printf '%s\n' "$fingerprints" | wc -l)" -eq 1 ]] ||
  { echo "::error::Unexpected SSH host key count" >&2; exit 1; }
actual="$(printf '%s\n' "$fingerprints" | awk '{print $2}')"
[[ "$actual" == "SHA256:B66nNmPvaJBwlsjKwqbr4/hEArInm8pAeJoaSqsMwmA" ]] ||
  { echo "::error::Production SSH fingerprint mismatch" >&2; exit 1; }


# Only a digest is supplied; the concrete Telegram ID never enters source or Actions logs.
[[ "${E2E_TARGET_DIGEST:-}" =~ ^[0-9a-f]{64}$ ]] || exit 64
[[ "${E2E_TEST_ID:-}" =~ ^[a-z0-9-]{8,40}$ ]] || exit 64
[[ "${E2E_MODE:-}" == preflight || "${E2E_MODE:-}" == send-one-private-test ]] || exit 64
{
  printf 'E2E_TARGET_DIGEST = "%s"\nE2E_TEST_ID = "%s"\nE2E_MODE = "%s"\n' "$E2E_TARGET_DIGEST" "$E2E_TEST_ID" "$E2E_MODE"
  cat "$(dirname "$0")/prism-private-e2e.rb"
} > "$ssh_dir/acceptance.rb"
ssh -T -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$ssh_dir/known_hosts" -o ConnectTimeout=10 \
  -i "$ssh_dir/key" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
  'docker exec -i prism-hub bundle exec rails runner -' < "$ssh_dir/acceptance.rb"
