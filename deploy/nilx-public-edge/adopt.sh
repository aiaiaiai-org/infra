#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

mode="${1:-}"
case "$mode" in validate|activate|rollback) ;; *) echo 'Expected validate|activate|rollback' >&2; exit 2 ;; esac
test "$(hostname)" = edge-dev-1
test "$(id -un)" = deploy

config="$HOME/.local/share/aiaiaiai-infra/nilx-public-edge/Caddyfile"
test -s "$config"
# Digest observed in the operator's existing docker pull; no mutable image tag.
image='caddy:2-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0'
legacy=nilx-public-edge
managed=nilx-public-edge-managed
candidate=nilxone-web-candidate
network=nilx-candidate

docker network inspect "$network" >/dev/null
for volume in nilx-public-edge-caddy-data nilx-public-edge-caddy-config; do
  docker volume inspect "$volume" >/dev/null
done
docker image inspect "$image" >/dev/null
test "$(docker inspect -f '{{.State.Health.Status}}' "$candidate")" = healthy
test "$(docker inspect -f '{{.Config.Image}}' "$candidate")" = 'ghcr.io/nilx-one/web@sha256:de655de0c264dfa5b589fa2513d57fe0e9168d02c92a298771e7181d2d609d90'
docker run --rm --network "$network" --security-opt no-new-privileges:true \
  --volume "$config:/etc/caddy/Caddyfile:ro" "$image" \
  caddy validate --config /etc/caddy/Caddyfile >/dev/null

healthy_https() {
  curl --fail --silent --show-error --output /dev/null \
    --connect-timeout 4 --max-time 12 \
    --resolve nilx.one:443:127.0.0.1 https://nilx.one/
}

verify_legacy() {
  test "$(docker inspect -f '{{.State.Running}}' "$legacy")" = true
  test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$legacy")" = nilx-public-edge-caddy-data
  test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Name}}{{end}}{{end}}' "$legacy")" = nilx-public-edge-caddy-config
  test "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' "$legacy")" = "$(docker network inspect --format '{{.Id}}' "$network")"
  # Compare effective config, independent of whitespace and copyright comments.
  live_json="$(docker exec "$legacy" caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null)"
  desired_json="$(docker run --rm --network "$network" \
    --volume "$config:/etc/caddy/Caddyfile:ro" "$image" \
    caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null)"
  test -n "$live_json"
  test "$live_json" = "$desired_json" || {
    echo "::error::Live Caddy routing differs from reviewed Infra config." >&2
    exit 1
  }
  healthy_https
}

if [[ "$mode" == validate ]]; then
  if [[ "$(docker inspect -f '{{.State.Running}}' "$managed" 2>/dev/null || true)" == true ]]; then
    healthy_https
    echo 'Managed ingress is healthy; no changes made.'
  else
    verify_legacy
    test -z "$(docker inspect -f '{{.Name}}' "$managed" 2>/dev/null || true)" || {
      echo 'A stopped managed container exists. Inspect before retrying.' >&2
      exit 1
    }
    echo 'Manual ingress verified; no containers changed.'
  fi
  exit 0
fi

if [[ "$mode" == activate ]]; then
  if [[ "$(docker inspect -f '{{.State.Running}}' "$managed" 2>/dev/null || true)" == true ]]; then
    healthy_https
    echo 'Managed ingress already active.'
    exit 0
  fi
  test -z "$(docker inspect -f '{{.Name}}' "$managed" 2>/dev/null || true)" || {
    echo 'Managed name already taken; refusing overwrite.' >&2
    exit 1
  }
  verify_legacy
  recover_legacy() {
    status=$?
    trap - ERR
    docker rm --force "$managed" >/dev/null 2>&1 || true
    docker start "$legacy" >/dev/null || true
    healthy_https || echo '::error::Failed to restore previous HTTPS listener.' >&2
    exit "$status"
  }
  trap recover_legacy ERR
  docker stop --time 15 "$legacy" >/dev/null
  docker run --detach --name "$managed" --restart unless-stopped \
    --network "$network" --security-opt no-new-privileges:true \
    --publish 80:80/tcp --publish 443:443/tcp \
    --volume "$config:/etc/caddy/Caddyfile:ro" \
    --volume nilx-public-edge-caddy-data:/data \
    --volume nilx-public-edge-caddy-config:/config "$image" >/dev/null
  for _ in {1..12}; do
    if healthy_https; then
      trap - ERR
      echo 'Managed HTTPS active; original container retained for rollback.'
      exit 0
    fi
    sleep 2
  done
  echo '::error::Managed HTTPS health probe failed.' >&2
  false
fi

test "$(docker inspect -f '{{.State.Running}}' "$managed")" = true
test "$(docker inspect -f '{{.State.Running}}' "$legacy")" = false
recover_managed() {
  status=$?
  trap - ERR
  docker stop --time 10 "$legacy" >/dev/null 2>&1 || true
  docker start "$managed" >/dev/null || true
  healthy_https || echo '::error::Managed HTTPS recovery failed.' >&2
  exit "$status"
}
trap recover_managed ERR
docker stop --time 15 "$managed" >/dev/null
docker start "$legacy" >/dev/null
for _ in {1..12}; do
  if healthy_https; then
    trap - ERR
    echo 'Manual ingress restored; managed container retained stopped.'
    exit 0
  fi
  sleep 2
done
echo '::error::Rollback HTTPS health probe failed.' >&2
false
