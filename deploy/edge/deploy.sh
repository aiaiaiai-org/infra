#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f .env ]]; then
  echo "deploy/edge/.env is missing" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

mode="${DEPLOY_MODE:-validate}"
edge_target="${EDGE_TARGET:-}"
edge_scope="${EDGE_SCOPE:-nilx-web}"
edge_network="${EDGE_NETWORK:-nilx-edge}"
legacy_caddy="${LEGACY_CADDY_CONTAINER:-mind-web-prod-1-caddy}"
release_sha="${RELEASE_SHA:-local}"
caddy_image="${CADDY_IMAGE:-zero-x-infra-caddy-cloudflare:${release_sha}}"
legacy_was_running=0

case "$mode" in
  validate|activate|rollback) ;;
  *)
    echo "DEPLOY_MODE must be validate, activate, or rollback" >&2
    exit 1
    ;;
esac
case "$edge_scope" in
  mind-web|market|nilx-web|all) ;;
  *)
    echo "EDGE_SCOPE must be mind-web, market, nilx-web, or all" >&2
    exit 1
    ;;
esac

if [[ ! "$edge_target" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  echo "EDGE_TARGET must be a lowercase edge target id" >&2
  exit 1
fi
if [[ ! "$edge_network" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "EDGE_NETWORK is invalid" >&2
  exit 1
fi
if [[ ! "$legacy_caddy" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "LEGACY_CADDY_CONTAINER is invalid" >&2
  exit 1
fi

for name in MARKET_DOMAIN NILX_WEB_DOMAIN NILX_BOND_DOMAIN NILX_BOND_TRANSPORT MIND_WEB_DOMAIN CF_API_TOKEN; do
  [[ -n "${!name:-}" ]] || { echo "$name is required" >&2; exit 1; }
done

export CADDY_IMAGE="$caddy_image"
export EDGE_NETWORK="$edge_network"

docker network inspect "$edge_network" >/dev/null

volume_from_live() {
  local destination="$1"
  docker inspect "$legacy_caddy" \
    --format '{{range .Mounts}}{{printf "%s\t%s\t%s\n" .Destination .Type .Name}}{{end}}' \
    | awk -F '\t' -v target="$destination" '$1 == target && $2 == "volume" {print $3; exit}'
}

resolve_volume() {
  local configured="$1"
  local destination="$2"
  local default_name="$3"

  if [[ -n "$configured" ]] && docker volume inspect "$configured" >/dev/null 2>&1; then
    printf '%s\n' "$configured"
    return 0
  fi

  if docker inspect "$legacy_caddy" >/dev/null 2>&1; then
    local discovered
    discovered="$(volume_from_live "$destination")"
    if [[ -n "$discovered" ]]; then
      docker volume inspect "$discovered" >/dev/null
      printf '%s\n' "$discovered"
      return 0
    fi
  fi

  docker volume create "$default_name" >/dev/null
  printf '%s\n' "$default_name"
}

if [[ "$mode" == "rollback" ]]; then
  docker compose --file compose.yaml down --remove-orphans || true
  if docker inspect "$legacy_caddy" >/dev/null 2>&1; then
    docker start "$legacy_caddy" >/dev/null || true
  fi
  echo "shared edge rollback completed"
  exit 0
fi

CADDY_DATA_VOLUME="$(resolve_volume "${CADDY_DATA_VOLUME:-}" /data "${edge_target}-caddy-data")"
CADDY_CONFIG_VOLUME="$(resolve_volume "${CADDY_CONFIG_VOLUME:-}" /config "${edge_target}-caddy-config")"
export CADDY_DATA_VOLUME CADDY_CONFIG_VOLUME

docker build --file Dockerfile --tag "$caddy_image" .
docker run --rm "$caddy_image" caddy list-modules | grep -Fx 'dns.providers.cloudflare' >/dev/null

docker run --rm \
  --env "CF_API_TOKEN=$CF_API_TOKEN" \
  --env "MARKET_DOMAIN=$MARKET_DOMAIN" \
  --env "NILX_WEB_DOMAIN=$NILX_WEB_DOMAIN" \
  --env "NILX_BOND_DOMAIN=$NILX_BOND_DOMAIN" \
  --env "NILX_BOND_TRANSPORT=$NILX_BOND_TRANSPORT" \
  --env "MIND_WEB_DOMAIN=$MIND_WEB_DOMAIN" \
  --volume "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  "$caddy_image" \
  caddy validate --config /etc/caddy/Caddyfile

docker compose --file compose.yaml config --quiet
bash ./check-upstreams.sh "$edge_scope"

echo "edge image, configuration, volumes, network, and upstreams are valid for $edge_target"

if [[ "$mode" == "validate" ]]; then
  exit 0
fi

if [[ "${VERIFY_PUBLIC_HTTPS:-0}" != "1" ]]; then
  echo "VERIFY_PUBLIC_HTTPS must be 1 for activation" >&2
  exit 1
fi

rollback() {
  local exit_code=$?
  trap - ERR
  echo "edge activation failed; rolling back to $legacy_caddy" >&2
  docker compose --file compose.yaml down --remove-orphans || true
  if [[ "$legacy_was_running" == "1" ]]; then
    docker start "$legacy_caddy" >/dev/null || true
  fi
  exit "$exit_code"
}
trap rollback ERR

if docker inspect "$legacy_caddy" >/dev/null 2>&1 \
  && [[ "$(docker inspect --format '{{.State.Running}}' "$legacy_caddy")" == "true" ]]; then
  legacy_was_running=1
  docker stop --time 30 "$legacy_caddy" >/dev/null
fi

docker compose --file compose.yaml up --detach --remove-orphans caddy
container="$(docker compose --file compose.yaml ps --quiet caddy)"
[[ -n "$container" ]] || { echo "edge Caddy container was not created" >&2; exit 1; }

for _ in $(seq 1 30); do
  running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
  if [[ "$running" != "true" ]]; then
    docker compose --file compose.yaml logs --tail 200 caddy >&2 || true
    exit 1
  fi
  if [[ "$health" == "healthy" ]]; then
    break
  fi
  if [[ "$health" == "unhealthy" ]]; then
    docker compose --file compose.yaml logs --tail 200 caddy >&2 || true
    exit 1
  fi
  sleep 2
done

health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container")"
[[ "$health" == "healthy" ]] || {
  docker compose --file compose.yaml logs --tail 200 caddy >&2 || true
  echo "edge Caddy did not become healthy: $health" >&2
  exit 1
}

trap - ERR
echo "shared edge candidate is active; public DNS/TLS verification remains the caller's commit boundary"
