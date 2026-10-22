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
health_kind="${WORKLOAD_HEALTH_KIND:-http}"
command_b64="${WORKLOAD_COMMAND:-}"
environment_b64="${WORKLOAD_ENVIRONMENT:-}"
labels_b64="${WORKLOAD_LABELS:-}"
volumes_b64="${WORKLOAD_VOLUMES:-}"
secret_environment_b64="${WORKLOAD_SECRET_ENV:-}"
secret_environment_file="${WORKLOAD_SECRET_ENV_FILE:-}"
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
case "$health_kind" in
  http)
    if [[ ! "$health_path" =~ ^/ ]]; then
      echo "WORKLOAD_HEALTH must start with /" >&2
      exit 1
    fi
    ;;
  tcp|process) ;;
  *)
    echo "WORKLOAD_HEALTH_KIND must be http, tcp or process" >&2
    exit 1
    ;;
esac
if [[ ! "$command_b64" =~ ^[A-Za-z0-9+/]*={0,2}$ ]]; then
  echo "WORKLOAD_COMMAND is invalid" >&2
  exit 1
fi
if [[ ! "$environment_b64" =~ ^[A-Za-z0-9+/]*={0,2}$ ]]; then
  echo "WORKLOAD_ENVIRONMENT is invalid" >&2
  exit 1
fi
if [[ ! "$labels_b64" =~ ^[A-Za-z0-9+/]*={0,2}$ ]]; then
  echo "WORKLOAD_LABELS is invalid" >&2
  exit 1
fi
if [[ ! "$volumes_b64" =~ ^[A-Za-z0-9+/]*={0,2}$ ]]; then
  echo "WORKLOAD_VOLUMES is invalid" >&2
  exit 1
fi
if [[ ! "$secret_environment_b64" =~ ^[A-Za-z0-9+/]*={0,2}$ ]]; then
  echo "WORKLOAD_SECRET_ENV is invalid" >&2
  exit 1
fi
if [[ -n "$secret_environment_file" && ! -r "$secret_environment_file" ]]; then
  echo "WORKLOAD_SECRET_ENV_FILE is not readable" >&2
  exit 1
fi
if [[ -n "$secret_environment_b64" && -n "$secret_environment_file" ]]; then
  echo "WORKLOAD_SECRET_ENV and WORKLOAD_SECRET_ENV_FILE are mutually exclusive" >&2
  exit 1
fi

write_environment_file() {
  local path="$1"
  : > "$path"
  if [[ -n "$environment_b64" ]]; then
    printf '%s' "$environment_b64" | base64 --decode > "$path"
  fi
  if [[ -n "$secret_environment_b64" ]]; then
    printf '%s' "$secret_environment_b64" | base64 --decode >> "$path"
  elif [[ -n "$secret_environment_file" ]]; then
    cat "$secret_environment_file" >> "$path"
  fi
  chmod 600 "$path"
}

environment_file="$PWD/.environment"
write_environment_file "$environment_file"
trap 'rm -f "$environment_file"' EXIT

write_labels() {
  local encoded="$1"
  if [[ -n "$encoded" ]]; then
    printf "%s" "$encoded" | base64 --decode
  fi
}

mapfile -t workload_command < <(write_labels "$command_b64")
if (( ${#workload_command[@]} > 16 )); then
  echo "WORKLOAD_COMMAND has too many arguments" >&2
  exit 1
fi
for arg in "${workload_command[@]}"; do
  [[ "$arg" =~ ^[A-Za-z0-9_./-]+$ ]] || { echo "WORKLOAD_COMMAND has an invalid argument" >&2; exit 1; }
done
if [[ "$health_kind" == "process" && ${#workload_command[@]} -eq 0 ]]; then
  echo "process health requires a command" >&2
  exit 1
fi
mapfile -t workload_labels < <(write_labels "$labels_b64" | sed '/^$/d')
mapfile -t workload_volumes < <(write_labels "$volumes_b64" | sed '/^$/d')
for volume in "${workload_volumes[@]}"; do
  [[ "$volume" =~ ^[a-z0-9][a-z0-9_.-]*:/[A-Za-z0-9_./-]+(:ro|:rw)?$ ]] || { echo "WORKLOAD_VOLUMES contains an invalid volume" >&2; exit 1; }
done
for label in "${workload_labels[@]}"; do
  [[ "$label" =~ ^[a-z0-9][a-z0-9_.-]*=[A-Za-z0-9_./:@+-]+$ ]] || { echo "WORKLOAD_LABELS contains an invalid label" >&2; exit 1; }
done

docker network inspect "$network" >/dev/null

if [[ "$mode" == "rollback" ]]; then
  [[ -f "$previous_marker" ]] || { echo "no previous image recorded for $workload" >&2; exit 1; }
  previous_image="$(cat "$previous_marker")"
  label_args=()
  for label in "${workload_labels[@]}"; do label_args+=(--label "$label"); done
  volume_args=()
  for volume in "${workload_volumes[@]}"; do volume_args+=(--volume "$volume"); done
  docker rm -f "$workload" >/dev/null 2>&1 || true
  docker run --detach \
    "${label_args[@]}" "${volume_args[@]}" \
    --name "$workload" \
    --network "$network" \
    --network-alias "$alias_name" \
    --restart unless-stopped \
    --security-opt no-new-privileges:true \
    --env-file "$environment_file" \
    "$previous_image" "${workload_command[@]}" >/dev/null
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

label_args=()
for label in "${workload_labels[@]}"; do label_args+=(--label "$label"); done
volume_args=()
for volume in "${workload_volumes[@]}"; do volume_args+=(--volume "$volume"); done

docker rm -f "$workload" >/dev/null 2>&1 || true
docker run --detach \
  "${label_args[@]}" "${volume_args[@]}" \
  --name "$workload" \
  --network "$network" \
  --network-alias "$alias_name" \
  --restart unless-stopped \
  --security-opt no-new-privileges:true \
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  --env-file "$environment_file" \
  "$image_ref" "${workload_command[@]}" >/dev/null

# An HTTP workload is healthy when its health path answers; a TCP one (a database) when its port
# accepts a connection.
probe_health() {
  if [[ "$health_kind" == "process" ]]; then
    [[ "$(docker inspect --format '{{.State.Running}}' "$workload" 2>/dev/null || true)" == true ]]
  elif [[ "$health_kind" == "tcp" ]]; then
    docker run --rm --network "$network" alpine:3.22 \
      nc -z -w 2 "$alias_name" "$port" >/dev/null 2>&1
  else
    docker run --rm --network "$network" curlimages/curl:latest \
      --fail --silent --show-error \
      "http://${alias_name}:${port}${health_path}" >/dev/null 2>&1
  fi
}

healthy=0
if [[ "$health_kind" == "process" ]]; then
  sleep 5
fi
for _ in $(seq 1 30); do
  running="$(docker inspect --format '{{.State.Running}}' "$workload" 2>/dev/null || true)"
  if [[ "$running" != "true" ]]; then
    docker logs --tail 200 "$workload" >&2 || true
    break
  fi
  if probe_health; then
    healthy=1
    break
  fi
  sleep 2
done

if [[ "$healthy" != "1" ]]; then
  echo "workload $workload did not become healthy on $alias_name:$port$health_path" >&2
  if [[ -n "$current_image" ]]; then
    # The previous image gets the environment too: without it a workload that needs its
    # configuration (a database URL, a key) would be rolled back into a crash loop.
    docker rm -f "$workload" >/dev/null 2>&1 || true
    docker run --detach \
      "${label_args[@]}" "${volume_args[@]}" \
      --name "$workload" \
      --network "$network" \
      --network-alias "$alias_name" \
      --restart unless-stopped \
      --security-opt no-new-privileges:true \
      --log-driver json-file \
      --log-opt max-size=10m \
      --log-opt max-file=3 \
      --env-file "$environment_file" \
      "$current_image" "${workload_command[@]}" >/dev/null
    echo "rolled back $workload to $current_image" >&2
  fi
  exit 1
fi

if [[ -n "$current_image" ]]; then
  printf '%s\n' "$current_image" > "$previous_marker"
fi

echo "workload $workload is active on $alias_name:$port with $image_ref"
