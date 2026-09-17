#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f .env ]]; then
  echo "deploy/workload/.env is missing" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

mode="${DEPLOY_MODE:-validate}"
workload="${WORKLOAD:-}"
image_ref="${IMAGE_REF:-}"
network="${EDGE_NETWORK:-nilx-edge}"
alias_name="${WORKLOAD_ALIAS:-}"
port="${WORKLOAD_PORT:-}"
health_path="${WORKLOAD_HEALTH:-}"
previous_marker=".previous-image"

case "$mode" in
  validate|activate|rollback) ;;
  *)
    echo "DEPLOY_MODE must be validate, activate, or rollback" >&2
    exit 1
    ;;
esac

if [[ ! "$workload" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "WORKLOAD is invalid" >&2
  exit 1
fi
if [[ ! "$image_ref" =~ ^[a-z0-9.-]+(/[a-z0-9._-]+)*(:[A-Za-z0-9_.-]+|@sha256:[0-9a-f]{64})$ ]]; then
  echo "IMAGE_REF is invalid" >&2
  exit 1
fi
if [[ ! "$network" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "EDGE_NETWORK is invalid" >&2
  exit 1
fi
if [[ ! "$alias_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "WORKLOAD_ALIAS is invalid" >&2
  exit 1
fi
if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
  echo "WORKLOAD_PORT is invalid" >&2
  exit 1
fi
if [[ ! "$health_path" =~ ^/ ]]; then
  echo "WORKLOAD_HEALTH must start with /" >&2
  exit 1
fi

docker network inspect "$network" >/dev/null

if [[ "$mode" == "rollback" ]]; then
  [[ -f "$previous_marker" ]] || { echo "no previous image recorded for $workload" >&2; exit 1; }
  previous_image="$(cat "$previous_marker")"
  docker run --detach \
    --name "$workload" \
    --network "$network" \
    --network-alias "$alias_name" \
    --restart unless-stopped \
    --security-opt no-new-privileges:true \
    --replace \
    "$previous_image" >/dev/null
  echo "workload $workload rolled back to $previous_image"
  exit 0
fi

docker pull "$image_ref"

if [[ "$mode" == "validate" ]]; then
  echo "workload $workload image $image_ref is pullable and network $network exists"
  exit 0
fi

current_image=""
if docker inspect "$workload" >/dev/null 2>&1; then
  current_image="$(docker inspect --format '{{.Config.Image}}' "$workload")"
fi

docker run --detach \
  --name "$workload" \
  --network "$network" \
  --network-alias "$alias_name" \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  --replace \
  "$image_ref" >/dev/null

healthy=0
for _ in $(seq 1 30); do
  running="$(docker inspect --format '{{.State.Running}}' "$workload" 2>/dev/null || true)"
  if [[ "$running" != "true" ]]; then
    docker logs --tail 200 "$workload" >&2 || true
    break
  fi
  if docker run --rm --network "$network" curlimages/curl:latest \
      --fail --silent --show-error \
      "http://${alias_name}:${port}${health_path}" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done

if [[ "$healthy" != "1" ]]; then
  echo "workload $workload did not become healthy on $alias_name:$port$health_path" >&2
  if [[ -n "$current_image" ]]; then
    docker run --detach \
      --name "$workload" \
      --network "$network" \
      --network-alias "$alias_name" \
      --restart unless-stopped \
      --security-opt no-new-privileges:true \
      --replace \
      "$current_image" >/dev/null
    echo "rolled back $workload to $current_image" >&2
  fi
  exit 1
fi

if [[ -n "$current_image" ]]; then
  printf '%s\n' "$current_image" > "$previous_marker"
fi

echo "workload $workload is active on $alias_name:$port with $image_ref"
