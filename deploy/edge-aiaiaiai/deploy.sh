#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Validates or activates the aiaiaiai.org edge on its server.
#
#   validate  checks the image, the Caddyfile, and the Compose file; changes nothing
#   activate  creates the edge network and Caddy's volumes if they are missing, then starts Caddy
#   rollback  stops the edge
#
# The edge network is created here, not by a workload, so the first workload on a new server has a
# network to join. Whether the routed workloads answer is checked by verify.sh, after they run.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f .env ]]; then
  echo "deploy/edge-aiaiaiai/.env is missing" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

mode="${DEPLOY_MODE:-validate}"
edge_target="${EDGE_TARGET:-}"
edge_network="${EDGE_NETWORK:-aiaiaiai-edge}"
caddy_image="${CADDY_IMAGE:-caddy:2-alpine}"

case "$mode" in
  validate|activate|rollback) ;;
  *)
    echo "DEPLOY_MODE must be validate, activate, or rollback" >&2
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
if [[ ! "${PRISM_API_DOMAIN:-}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
  echo "PRISM_API_DOMAIN must be a host name" >&2
  exit 1
fi

export EDGE_TARGET="$edge_target" EDGE_NETWORK="$edge_network" CADDY_IMAGE="$caddy_image"

if [[ "$mode" == "rollback" ]]; then
  docker compose --file compose.yaml down --remove-orphans || true
  echo "aiaiaiai edge stopped"
  exit 0
fi

docker pull --quiet "$caddy_image" >/dev/null
docker run --rm \
  --env "PRISM_API_DOMAIN=$PRISM_API_DOMAIN" \
  --volume "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  "$caddy_image" \
  caddy validate --config /etc/caddy/Caddyfile

if [[ "$mode" == "validate" ]]; then
  if ! docker network inspect "$edge_network" >/dev/null 2>&1; then
    echo "network $edge_network does not exist yet; activation creates it"
  fi
  echo "aiaiaiai edge image and configuration are valid for $edge_target"
  exit 0
fi

if ! docker network inspect "$edge_network" >/dev/null 2>&1; then
  docker network create --driver bridge "$edge_network" >/dev/null
  echo "created network $edge_network"
fi
for volume in "${edge_target}-caddy-data" "${edge_target}-caddy-config"; do
  docker volume inspect "$volume" >/dev/null 2>&1 || docker volume create "$volume" >/dev/null
done

docker compose --file compose.yaml config --quiet
docker compose --file compose.yaml up --detach --remove-orphans caddy
container="$(docker compose --file compose.yaml ps --quiet caddy)"
[[ -n "$container" ]] || { echo "edge Caddy container was not created" >&2; exit 1; }

for _ in $(seq 1 30); do
  running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
  if [[ "$running" != "true" || "$health" == "unhealthy" ]]; then
    docker compose --file compose.yaml logs --tail 200 caddy >&2 || true
    exit 1
  fi
  if [[ "$health" == "healthy" ]]; then
    echo "aiaiaiai edge is active on $edge_target"
    exit 0
  fi
  sleep 2
done

docker compose --file compose.yaml logs --tail 200 caddy >&2 || true
echo "edge Caddy did not become healthy" >&2
exit 1
