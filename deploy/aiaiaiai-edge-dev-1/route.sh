#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
# Adds api.aiaiaiai.org to the EXISTING public Caddy of edge-dev-1; never binds 80/443 twice and never
# touches the nilx.one or aiaiaiai.org site blocks: the candidate is the live file plus one block, so
# everything already there is preserved byte for byte, and a reload that leaves nilx.one unhealthy
# restores the previous file.
#
#   route.sh validate|activate|rollback
set -Eeuo pipefail

operation="${1:-}"
case "$operation" in validate | activate | rollback) ;; *) echo 'Expected validate|activate|rollback' >&2; exit 2 ;; esac
test "$(hostname)" = edge-dev-1
test "$(id -un)" = deploy

root="$HOME/.local/share/aiaiaiai-infra"
snippet="$root/aiaiaiai-api/api.Caddyfile"
candidate="$root/aiaiaiai-api/ingress.Caddyfile"
backup="$root/aiaiaiai-api/ingress.previous.Caddyfile"
live="$root/nilx-public-edge/Caddyfile"
managed=nilx-public-edge-managed
test -s "$live"
test ! -L "$live"
test "$(docker inspect -f '{{.State.Running}}' "$managed")" = true
test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' "$managed")" = "$(realpath "$live")"
test "$(docker inspect -f '{{if index .NetworkSettings.Networks "nilx-candidate"}}yes{{end}}' "$managed")" = yes

healthy_nilx() {
  curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
    --resolve nilx.one:443:127.0.0.1 https://nilx.one/ >/dev/null
}

restore_from() {
  cat "$1" >"$live"
  docker exec "$managed" caddy reload --config /etc/caddy/Caddyfile || true
}

if [[ "$operation" == rollback ]]; then
  test -s "$backup" || { echo 'No previous Caddyfile to restore' >&2; exit 1; }
  cp -p "$live" "$live.aiaiaiai-api-current.$$"
  cat "$backup" >"$live"
  if ! docker exec "$managed" caddy reload --config /etc/caddy/Caddyfile || ! healthy_nilx; then
    restore_from "$live.aiaiaiai-api-current.$$"
    rm -f "$live.aiaiaiai-api-current.$$"
    echo 'Rollback failed; tried to restore the config that was active' >&2
    exit 1
  fi
  rm -f "$live.aiaiaiai-api-current.$$" "$backup"
  echo 'Restored the ingress config from before api.aiaiaiai.org.'
  exit 0
fi

test -s "$snippet"
for workload in prism-hub prism-hubot; do
  test "$(docker inspect -f '{{.State.Running}}' "$workload")" = true || {
    echo "$workload is not running; deploy it before the route" >&2
    exit 1
  }
  test "$(docker inspect -f '{{if index .NetworkSettings.Networks "nilx-candidate"}}yes{{end}}' "$workload")" = yes
done

if grep -Fq 'api.aiaiaiai.org {' "$live"; then
  echo 'api.aiaiaiai.org is already routed by the live config; unchanged.'
  cat "$live" >"$candidate"
else
  { cat "$live"; printf '\n'; cat "$snippet"; } >"$candidate"
fi
# Everything that was live must still be there, unchanged, at the start of the candidate.
cmp -s -n "$(stat -c %s "$live")" "$live" "$candidate"

image="$(docker inspect -f '{{.Config.Image}}' "$managed")"
docker run --rm --network nilx-candidate \
  --volume "$candidate:/etc/caddy/Caddyfile:ro" "$image" \
  caddy validate --config /etc/caddy/Caddyfile >/dev/null

if [[ "$operation" == validate ]]; then
  healthy_nilx
  echo 'The api.aiaiaiai.org route validates on the existing ingress; no public config changed.'
  exit 0
fi

if cmp -s "$live" "$candidate"; then
  healthy_nilx
  echo 'Route already active; unchanged.'
  exit 0
fi
if [[ -e "$backup" ]]; then
  echo 'A previous api ingress backup exists; inspect it or roll back before activating again' >&2
  exit 1
fi

umask 077
cp -p "$live" "$backup"
# Overwrite the existing inode: the running container bind-mounts this file.
cat "$candidate" >"$live"
if ! docker exec "$managed" caddy reload --config /etc/caddy/Caddyfile || ! healthy_nilx; then
  restore_from "$backup"
  rm -f "$backup"
  echo 'Activation failed or nilx.one became unhealthy; restored the previous ingress file' >&2
  exit 1
fi

# Caddy obtains the certificate on reload (HTTP-01 on port 80); give it time before judging the route.
for _ in $(seq 1 45); do
  if curl --fail --silent --connect-timeout 5 --max-time 15 \
    --resolve api.aiaiaiai.org:443:127.0.0.1 https://api.aiaiaiai.org/prism-hub/healthz >/dev/null; then
    echo 'api.aiaiaiai.org answers over TLS through the ingress; nilx.one stayed healthy.'
    exit 0
  fi
  sleep 2
done
echo 'The route is active and nilx.one is healthy, but api.aiaiaiai.org did not answer over TLS in 90 s' >&2
echo 'Inspect the ingress logs; roll back with route.sh rollback if needed.' >&2
exit 1
