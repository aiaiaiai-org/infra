#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

operation="${1:?validate or activate required}"
image="${2:?immutable image required}"
case "$operation" in validate|activate) ;; *) exit 2 ;; esac
[[ "$image" =~ ^ghcr\.io/nilx-one/0x1-identity@sha256:[0-9a-f]{64}$ ]]
test "$(hostname)" = edge-dev-1
test "$(id -un)" = deploy
docker network inspect nilx-candidate >/dev/null
test "$(docker inspect -f '{{.State.Health.Status}}' nilxone-web-candidate)" = healthy

name=nilxone-identity-fresh
volume=nilxone-identity-fresh-data
dir="$HOME/.local/share/aiaiaiai-infra/nilx-identity-fresh"
env_file="$dir/runtime.env"

# Never replace a running legacy service or attach to its historical volume.
if docker inspect nilxone-identity >/dev/null 2>&1; then
  echo 'A legacy identity container exists: refusing a second provider of this alias.' >&2
  exit 1
fi

if docker inspect "$name" >/dev/null 2>&1; then
  test "$(docker inspect -f '{{.Config.Image}}' "$name")" = "$image"
  test "$(docker inspect -f '{{.State.Health.Status}}' "$name")" = healthy
  test -z "$(docker port "$name")"
  echo 'Fresh identity already healthy and private; no changes made.'
  exit 0
fi

if [[ "$operation" == validate ]]; then
  echo 'Fresh identity staging is eligible: old identity untouched, no container or volume created.'
  exit 0
fi

# The identity binary currently includes a Telegram dispatcher and requires
# the real 0x1 bot credential at startup. Do not invent or duplicate a token.
IFS= read -r token
[[ "$token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]] || {
  echo 'A real 0x1 Telegram bot token is required for this image.' >&2
  exit 1
}

umask 077
install -d -m 0700 "$dir"
random_secret() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }
if [[ -e "$env_file" ]]; then
  [[ -f "$env_file" && ! -L "$env_file" ]]
  [[ "$(stat -c '%a' "$env_file")" == 600 ]]
  previous_token="$(sed -n 's/^TELOXIDE_TOKEN=//p' "$env_file")"
  test "$previous_token" = "$token" || {
    echo 'Existing bot credential differs: refusing implicit rotation.' >&2
    exit 1
  }
  for key in NATIVE_AUTH_SECRET PASSWORD_PEPPER GITHUB_EVIDENCE_ENCRYPTION_KEY AIAIAIAI_SIGN_IN_ISSUER; do
    grep -q "^$key=" "$env_file"
  done
else
  temp="$(mktemp "$dir/.runtime.env.XXXXXXXX")"
  trap 'rm -f "$temp"' EXIT
  {
    printf 'DATABASE_URL=sqlite:///data/identity.db\n'
    printf 'HTTP_BIND=0.0.0.0:1927\n'
    printf 'PUBLIC_ORIGIN=https://nilx.one\n'
    printf 'AIAIAIAI_SIGN_IN_ISSUER=https://auth.aiaiaiai.org\n'
    printf 'TELOXIDE_TOKEN=%s\n' "$token"
    printf 'NATIVE_AUTH_SECRET=%s\n' "$(random_secret)"
    printf 'PASSWORD_PEPPER=%s\n' "$(random_secret)"
    printf 'GITHUB_EVIDENCE_ENCRYPTION_KEY=%s\n' "$(random_secret)"
  } > "$temp"
  chmod 600 "$temp"
  mv --no-clobber "$temp" "$env_file"
  trap - EXIT
fi
unset token previous_token

# Unique first-use volume: never reuse nilxone-identity-data (legacy).
if ! docker volume inspect "$volume" >/dev/null 2>&1; then
  docker volume create "$volume" >/dev/null
fi
docker image inspect "$image" >/dev/null
docker run --detach \
  --name "$name" \
  --network nilx-candidate --network-alias nilxone-identity \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  --volume "$volume:/data" \
  --env-file "$env_file" \
  "$image" >/dev/null

for _ in $(seq 1 30); do
  state="$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)"
  if [[ "$state" == healthy ]]; then
    test -z "$(docker port "$name")"
    echo 'Fresh 0x1 Identity backend healthy on private network; existing Web ingress unchanged.'
    exit 0
  fi
  if [[ "$state" == unhealthy ]]; then break; fi
  sleep 3
done
echo 'Fresh Identity did not become healthy. Its persistent volume and secrets were retained.' >&2
docker rm -f "$name" >/dev/null 2>&1 || true
exit 1
