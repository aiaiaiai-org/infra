#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

operation="${1:?recipient, validate, or activate required}"
image="${2:?immutable image required}"
case "$operation" in recipient|validate|activate) ;; *) exit 2 ;; esac
[[ "$image" =~ ^ghcr\.io/nilx-one/0x1-identity@sha256:[0-9a-f]{64}$ ]]
test "$(hostname)" = edge-dev-1
test "$(id -un)" = deploy
docker network inspect nilx-candidate >/dev/null
test "$(docker inspect -f '{{.State.Health.Status}}' nilxone-web-candidate)" = healthy

name=nilxone-identity-fresh
volume=nilxone-identity-fresh-data
dir="$HOME/.local/share/aiaiaiai-infra/nilx-identity-fresh"
key_file="$dir/recipient.agekey"
cipher_file="$dir/secrets.age"
env_file="$dir/runtime.env"

# Never replace a running legacy service or attach to its historical volume.
if docker inspect nilxone-identity >/dev/null 2>&1; then
  echo 'A legacy identity container exists: refusing a second provider of this alias.' >&2
  exit 1
fi

umask 077
install -d -m 0700 "$dir"

# Separate, host-owned AGE identity; Infra stores the public recipient only
# in workflow output. The actual Telegram token remains in the Web repo.
if [[ "$operation" == recipient ]]; then
  command -v age-keygen >/dev/null || {
    echo 'age-keygen must be installed on edge-dev-1 (sudo apt install age).' >&2
    exit 1
  }
  if [[ ! -e "$key_file" ]]; then
    age-keygen -o "$key_file" >/dev/null 2>&1
  fi
  [[ -f "$key_file" && ! -L "$key_file" ]]
  test "$(stat -c '%a' "$key_file")" = 600
  echo 'Copy this PUBLIC recipient into nilx-one/web production variable EDGE_DEV_1_IDENTITY_AGE_RECIPIENT:'
  age-keygen -y "$key_file"
  exit 0
fi

for bin in age age-keygen; do command -v "$bin" >/dev/null; done
[[ -f "$key_file" && ! -L "$key_file" ]]
test "$(stat -c '%a' "$key_file")" = 600
[[ -f "$cipher_file" && ! -L "$cipher_file" && -s "$cipher_file" ]]
test "$(stat -c '%a' "$cipher_file")" = 600

# Only this host ever decrypts product-owned credentials. No bot token is
# exposed to Infra's runner, GitHub Secrets, logs or Docker image.
credential="$(mktemp "$dir/.credential.XXXXXXXX")"
trap 'rm -f "$credential"' EXIT
age --decrypt --identity "$key_file" --output "$credential" "$cipher_file" >/dev/null
line="$(cat "$credential")"
[[ "$line" =~ ^TELOXIDE_TOKEN=[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]] || {
  echo 'Encrypted product package must contain only one valid TELOXIDE_TOKEN.' >&2
  exit 1
}
token="${line#TELOXIDE_TOKEN=}"
unset line

random_secret() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }
if [[ -e "$env_file" ]]; then
  [[ -f "$env_file" && ! -L "$env_file" ]]
  test "$(stat -c '%a' "$env_file")" = 600
  previous_token="$(sed -n 's/^TELOXIDE_TOKEN=//p' "$env_file")"
  test "$previous_token" = "$token" || {
    echo 'Existing product bot credential differs: refusing implicit rotation.' >&2
    exit 1
  }
  for key in NATIVE_AUTH_SECRET PASSWORD_PEPPER GITHUB_EVIDENCE_ENCRYPTION_KEY AIAIAIAI_SIGN_IN_ISSUER; do
    grep -q "^$key=" "$env_file"
  done
fi

if docker inspect "$name" >/dev/null 2>&1; then
  test "$(docker inspect -f '{{.Config.Image}}' "$name")" = "$image"
  test "$(docker inspect -f '{{.State.Health.Status}}' "$name")" = healthy
  test -z "$(docker port "$name")"
  echo 'Fresh identity already healthy and private; no changes made.'
  exit 0
fi

if [[ "$operation" == validate ]]; then
  echo 'Signed product secret decrypts only on the target VPS; no container, volume, or secrets were created.'
  exit 0
fi

# Activation only. These secrets and SQLite volume are NEW and are not legacy
# restoration. On a retry, never rotate previously written host-owned keys.
if [[ ! -e "$env_file" ]]; then
  temp="$(mktemp "$dir/.runtime.env.XXXXXXXX")"
  trap 'rm -f "$credential" "$temp"' EXIT
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
  trap 'rm -f "$credential"' EXIT
fi
unset token previous_token
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
    echo 'Fresh Identity healthy on private network; old Web ingress and TLS untouched.'
    exit 0
  fi
  if [[ "$state" == unhealthy ]]; then break; fi
  sleep 3
done
echo 'Fresh Identity unhealthy; its new persistent volume and host secrets were retained.' >&2
docker rm -f "$name" >/dev/null 2>&1 || true
exit 1
