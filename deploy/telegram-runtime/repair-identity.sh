#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

image=${1:?verified immutable Identity image required}
[[ "$image" =~ ^ghcr\.io/nilx-one/0x1-identity@sha256:[0-9a-f]{64}$ ]]
test "$(hostname)" = edge-dev-1
test "$(id -un)" = deploy
umask 077

identity=nilxone-identity
previous=nilxone-identity-before-telegram
network=nilx-candidate
volume=nilxone-identity-fresh-data
root="$HOME/.local/share/aiaiaiai-infra"
fail() { echo "::error::$*" >&2; exit 1; }

docker image inspect "$image" >/dev/null
if [[ "$(docker inspect -f '{{.Config.Image}}' "$identity")" == "$image" ]] &&
   [[ "$(docker inspect -f '{{.State.Health.Status}}' "$identity")" == healthy ]]; then
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$identity" | grep -Fx 'TELEGRAM_POLLING=disabled' >/dev/null
  echo 'Identity already healthy with polling disabled.'
  exit 0
fi
test "$(docker inspect -f '{{.Config.Image}}' "$identity")" = ghcr.io/nilx-one/0x1-identity:6bbb5aa9fb72c4bdbed6afd57fd68026676ea1cf || fail 'Identity image differs from the diagnosed release.'
test "$(docker inspect -f '{{.State.ExitCode}}' "$identity")" = 101 || fail 'Identity is no longer in the diagnosed startup failure.'
test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$identity")" = "$volume"
test "$(docker inspect -f '{{len .Mounts}}' "$identity")" = 1
test "$(docker inspect -f '{{len .NetworkSettings.Networks}}' "$identity")" = 1
test "$(docker inspect -f '{{if index .NetworkSettings.Networks "nilx-candidate"}}yes{{end}}' "$identity")" = yes
test -z "$(docker port "$identity")"
docker volume inspect "$volume" >/dev/null
if docker inspect "$previous" >/dev/null 2>&1; then fail 'Previous Identity recovery container already exists.'; fi
if docker inspect nilx-one-bot >/dev/null 2>&1; then fail 'Telegram bot already exists; recover through normal delivery.'; fi

work=$(mktemp -d "$root/telegram-runtime/.identity-repair.XXXXXXXX")
renamed=false
created=false
cleanup() {
  result=$?
  if (( result != 0 )); then
    if "$created"; then docker rm -f "$identity" >/dev/null || true; fi
    if "$renamed"; then docker rename "$previous" "$identity" || true; fi
    echo 'Recovery failed. Original container and database snapshot retained; inspect before restarting.' >&2
  fi
  rm -f "$work/runtime.env" "$work/old.env"
  rmdir "$work"
}
trap cleanup EXIT

# Preserve the current workload's environment locally. The runner never sees
# any of these values. Docker env files require single-line values.
docker inspect -f '{{json .Config.Env}}' "$identity" | jq -e 'all(.[]; (contains("\n") or contains("\r")) | not)' >/dev/null
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$identity" > "$work/old.env"
for key in TELEGRAM_BOT_TOKEN DATABASE_URL NATIVE_AUTH_SECRET PASSWORD_PEPPER GITHUB_EVIDENCE_ENCRYPTION_KEY; do
  test "$(grep -Ec "^${key}=.+" "$work/old.env")" = 1 || fail "Missing or duplicate configuration: $key"
done
grep -Fx 'DATABASE_URL=sqlite:///data/identity.db' "$work/old.env" >/dev/null
grep -v '^TELEGRAM_POLLING=' "$work/old.env" > "$work/runtime.env"
printf 'TELEGRAM_POLLING=disabled\n' >> "$work/runtime.env"

# Stop the crash loop before the consistent, host-private SQLite volume copy.
docker stop "$identity" >/dev/null
backup=$(mktemp -d "$root/telegram-runtime/identity-backup.XXXXXXXX")
docker cp "$identity:/data/." "$backup/"
test -s "$backup/identity.db"
echo 'Existing Identity database backed up on edge-dev-1.'
docker rename "$identity" "$previous"
renamed=true
docker run --detach --name "$identity" --network "$network" --network-alias "$identity" \
  --restart unless-stopped --security-opt no-new-privileges:true \
  --volume "$volume:/data" --env-file "$work/runtime.env" "$image" >/dev/null
created=true

for attempt in $(seq 1 30); do
  if [[ "$(docker inspect -f '{{.State.Health.Status}}' "$identity")" == healthy ]]; then
    docker logs --tail 500 "$identity" 2>&1 | grep -F 'Telegram polling is disabled: the 0x1 bot owns @nilxone_bot updates' >/dev/null
    echo 'Identity recovered on existing database. Legacy Telegram polling is disabled.'
    exit 0
  fi
  if [[ "$attempt" == 30 ]]; then fail 'Replacement Identity did not become healthy.'; fi
  sleep 3
done
