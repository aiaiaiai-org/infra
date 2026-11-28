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

# The api.aiaiaiai.org site block of a Caddyfile: its opening line to the first closing brace at column 0.
api_block() { awk '$0 == "api.aiaiaiai.org {" { on = 1 } on { print } on && $0 == "}" { exit }' "$1"; }
replace_api_block() { awk -v new="$2" '$0 == "api.aiaiaiai.org {" { while ((getline line < new) > 0) print line; skip = 1 } !skip { print } skip && $0 == "}" { skip = 0 }' "$1"; }
without_api_block() { awk '$0 == "api.aiaiaiai.org {" { skip = 1 } !skip { print } skip && $0 == "}" { skip = 0 }' "$1"; }
collector_route() { api_block "$1" | awk '/^\thandle_path \/4x-errors\/\* \{/ { on = 1 } on { print } on && /^\t\}$/ { exit }'; }

# append: the host is new, so the reviewed block is added at the end. update: the host is already routed and
# the reviewed block differs (a route was added), so that one block is replaced in place.
mode=append
if grep -Fq 'api.aiaiaiai.org {' "$live"; then
  [[ "$(grep -Fxc 'api.aiaiaiai.org {' "$live")" == 1 ]] || { echo 'the live config holds more than one api.aiaiaiai.org block' >&2; exit 1; }
  new_block="$root/aiaiaiai-api/api.block"
  api_block "$snippet" >"$new_block"
  test -s "$new_block"
  if [[ "$(api_block "$live")" == "$(cat "$new_block")" ]]; then
    echo 'The live api.aiaiaiai.org block already is the reviewed one; unchanged.'
    cat "$live" >"$candidate"
  else
    echo 'Replacing the live api.aiaiaiai.org block with the reviewed one; every other site stays as it is.'
    mode=update
    replace_api_block "$live" "$new_block" >"$candidate"
  fi
else
  { cat "$live"; printf '\n'; cat "$snippet"; } >"$candidate"
fi
if [[ "$mode" == append ]]; then
  # Everything that was live must still be there, unchanged, at the start of the candidate.
  cmp -s -n "$(stat -c %s "$live")" "$live" "$candidate"
else
  # Outside the api block nothing may differ: nilx.one and every other site stay byte for byte.
  cmp -s <(without_api_block "$live") <(without_api_block "$candidate")
fi

image="$(docker inspect -f '{{.Config.Image}}' "$managed")"
docker run --rm --network nilx-candidate \
  --volume "$candidate:/etc/caddy/Caddyfile:ro" "$image" \
  caddy validate --config /etc/caddy/Caddyfile >/dev/null

# A new or changed collector route must not be activated against an absent or
# unready workload. Unchanged collector routes do not gate unrelated API changes.
collector_changed=false
if [[ "$(collector_route "$live")" != "$(collector_route "$candidate")" ]]; then
  collector_changed=true
fi

if [[ "$operation" == validate ]]; then
  healthy_nilx
  echo 'The api.aiaiaiai.org route validates on the existing ingress; no public config changed.'
  exit 0
fi

if [[ "$collector_changed" == true ]]; then
  docker exec "$managed" wget -q -T 5 -O /dev/null http://4x-errors:1927/ready || {
    echo '4x-errors is not ready; deploy the verified collector before activating its route' >&2
    exit 1
  }
fi

if cmp -s "$live" "$candidate"; then
  healthy_nilx
  echo 'Route already active; unchanged.'
  exit 0
fi
if [[ "$mode" == append && -e "$backup" ]]; then
  echo 'A previous api ingress backup exists; inspect it or roll back before activating again' >&2
  exit 1
fi

umask 077
# The backup of the file from before api.aiaiaiai.org existed is what `rollback` restores; an update keeps it and
# leaves its own single-level undo beside it.
if [[ "$mode" == update ]]; then undo="$root/aiaiaiai-api/ingress.before-update.Caddyfile"; else undo="$backup"; fi
cp -p "$live" "$undo"
# Overwrite the existing inode: the running container bind-mounts this file.
cat "$candidate" >"$live"
if ! docker exec "$managed" caddy reload --config /etc/caddy/Caddyfile || ! healthy_nilx; then
  restore_from "$undo"
  [[ "$mode" == update ]] || rm -f "$backup"
  echo 'Activation failed or nilx.one became unhealthy; restored the previous ingress file' >&2
  exit 1
fi

# Caddy obtains the certificate on reload (HTTP-01 on port 80); give it time before judging the route.
for _ in $(seq 1 45); do
  if curl --fail --silent --connect-timeout 5 --max-time 15 \
    --resolve api.aiaiaiai.org:443:127.0.0.1 https://api.aiaiaiai.org/prism-hub/healthz >/dev/null; then
    if [[ "$collector_changed" == true ]] && ! curl --fail --silent --connect-timeout 5 --max-time 15 \
      --resolve api.aiaiaiai.org:443:127.0.0.1 https://api.aiaiaiai.org/4x-errors/ready >/dev/null; then
      sleep 2
      continue
    fi
    echo 'api.aiaiaiai.org answers over TLS through the ingress; nilx.one stayed healthy.'
    exit 0
  fi
  sleep 2
done
if [[ "$collector_changed" == true ]]; then
  restore_from "$undo"
  [[ "$mode" == update ]] || rm -f "$backup"
  echo 'Collector route readiness was not proved; restored the previous ingress file' >&2
  exit 1
fi
echo 'The route is active and nilx.one is healthy, but api.aiaiaiai.org did not answer over TLS in 90 s' >&2
echo 'Inspect the ingress logs; roll back with route.sh rollback if needed.' >&2
exit 1
