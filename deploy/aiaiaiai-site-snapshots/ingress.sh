#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
# Adopt two site hosts on the EXISTING public Caddy; never bind 80/443 twice.
set -Eeuo pipefail

operation="${1:-}"
case "$operation" in validate|activate|rollback) ;; *) echo 'Expected validate|activate|rollback' >&2; exit 2 ;; esac
test "$(hostname)" = edge-dev-1
test "$(id -un)" = deploy

root="$HOME/.local/share/aiaiaiai-infra"
candidate="$root/aiaiaiai-site/ingress.Caddyfile"
live="$root/nilx-public-edge/Caddyfile"
backup="$root/aiaiaiai-site/ingress.previous.Caddyfile"
managed=nilx-public-edge-managed
test -s "$candidate"
test -s "$live"
test ! -L "$live"
test "$(docker inspect -f '{{.State.Running}}' "$managed")" = true
test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' "$managed")" = "$(realpath "$live")"
if [[ "$operation" != rollback ]]; then
  test "$(docker inspect -f '{{.State.Running}}' aiaiaiai-site-archive)" = true
fi
test "$(docker inspect -f '{{if index .NetworkSettings.Networks "nilx-candidate"}}yes{{end}}' "$managed")" = yes
test "$(docker inspect -f '{{if index .NetworkSettings.Networks "nilx-candidate"}}yes{{end}}' aiaiaiai-site-archive)" = yes

# Never replace nilx.one's working reverse proxy with an unreviewed one.
cmp <(sed -n '/^nilx\.one {/,/^}/p' "$live") \
    <(sed -n '/^nilx\.one {/,/^}/p' "$candidate")
grep -Fq 'reverse_proxy aiaiaiai-site-archive:1927' "$candidate"
if [[ "$operation" != rollback ]]; then
  docker exec "$managed" wget -q -T 10 -O /dev/null http://aiaiaiai-site-archive:1927/healthz
fi

image="$(docker inspect -f '{{.Config.Image}}' "$managed")"
docker run --rm --network nilx-candidate \
  --volume "$candidate:/etc/caddy/Caddyfile:ro" "$image" \
  caddy validate --config /etc/caddy/Caddyfile >/dev/null

healthy_nilx() {
  curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
    --resolve nilx.one:443:127.0.0.1 https://nilx.one/ >/dev/null
}

if [[ "$operation" == validate ]]; then
  healthy_nilx
  echo 'New site hosts validate on existing ingress; no public config changed.'
  exit 0
fi

if [[ "$operation" == rollback ]]; then
  test -s "$backup" || { echo 'No verified previous Caddyfile' >&2; exit 1; }
  cp -p "$live" "$live.aiaiaiai-current.$$"
  cp "$backup" "$live"
  if ! docker exec "$managed" caddy reload --config /etc/caddy/Caddyfile || ! healthy_nilx; then
    cat "$live.aiaiaiai-current.$$" > "$live"
    docker exec "$managed" caddy reload --config /etc/caddy/Caddyfile || true
    rm -f "$live.aiaiaiai-current.$$"
    echo 'Rollback failed, tried to restore the active config' >&2
    exit 1
  fi
  rm -f "$live.aiaiaiai-current.$$"
  echo 'Restored prior public ingress config.'
  exit 0
fi

if cmp -s "$live" "$candidate"; then
  healthy_nilx
  echo 'Site routes already active; unchanged.'
  exit 0
fi

if [[ -e "$backup" ]]; then
  echo 'A previous ingress backup exists; inspect or roll back before a new cutover' >&2
  exit 1
fi
umask 077
cp -p "$live" "$backup"
# Overwrite the existing inode; the running container bind-mounts this file.
cat "$candidate" > "$live"
if ! docker exec "$managed" caddy reload --config /etc/caddy/Caddyfile || ! healthy_nilx; then
  cat "$backup" > "$live"
  docker exec "$managed" caddy reload --config /etc/caddy/Caddyfile || true
  rm -f "$backup"
  echo 'Site ingress activation failed; restored old ingress file' >&2
  exit 1
fi
echo 'Added two site hosts to existing public Caddy; nilx.one stayed healthy.'
