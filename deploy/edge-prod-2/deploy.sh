#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Runs from inside one uploaded release directory:
#
#   <base>/releases/<sha>/   Caddyfile, compose.yaml, Dockerfile, .env, scripts
#   <base>/current  -> releases/<sha>   the release the live Caddy mounts
#   <base>/previous -> releases/<sha>   what `rollback` restores
#
# validate  builds and checks this release without touching the live edge;
# activate  recreates Caddy from this release, rolling back if it never turns healthy;
# rollback  restores `previous` after a failed public verification.
set -Eeuo pipefail

release_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$release_dir"
base_dir="$(cd ../.. && pwd -P)"
current_link="$base_dir/current"
previous_link="$base_dir/previous"
keep_releases="${KEEP_RELEASES:-5}"

[[ -f .env ]] || { echo "release .env is missing" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source .env
set +a

mode="${DEPLOY_MODE:-validate}"
case "$mode" in
  validate|activate|rollback) ;;
  *)
    echo "DEPLOY_MODE must be validate, activate, or rollback" >&2
    exit 1
    ;;
esac

[[ "${EDGE_TARGET:-}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "EDGE_TARGET must be a lowercase edge target id" >&2; exit 1; }
for name in CADDY_IMAGE CF_API_TOKEN PRISM_HUB_DOMAIN EDGE_TRANSPORT UPSTREAM_HEALTH_URLS; do
  [[ -n "${!name:-}" ]] || { echo "$name is required" >&2; exit 1; }
done

# The shell holds this release's .env; compose would let it override the
# --env-file of another release, so each call sees only its own release.
compose() {
  env -i PATH="$PATH" HOME="$HOME" ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} \
    docker compose --file "$1/compose.yaml" --env-file "$1/.env" "${@:2}"
}

check_upstreams() {
  local url
  for url in $UPSTREAM_HEALTH_URLS; do
    [[ "$url" =~ ^http://127\.0\.0\.1:[0-9]+/ ]] || { echo "upstream $url is not loopback" >&2; return 1; }
    echo "checking upstream $url"
    curl --fail --silent --show-error --output /dev/null \
      --connect-timeout 5 --max-time 10 \
      --header 'X-Forwarded-Proto: https' \
      "$url"
  done
}

wait_healthy() {
  local dir="$1" container running health
  container="$(compose "$dir" ps --quiet caddy)"
  [[ -n "$container" ]] || { echo "edge Caddy container was not created" >&2; return 1; }

  for _ in $(seq 1 30); do
    running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
    [[ "$running" == "true" ]] || break
    [[ "$health" == "healthy" ]] && return 0
    [[ "$health" == "unhealthy" ]] && break
    sleep 2
  done

  compose "$dir" logs --tail 200 caddy >&2 || true
  echo "edge Caddy did not become healthy from $dir" >&2
  return 1
}

point() {
  ln -sfn "$2" "$1.tmp"
  mv -Tf "$1.tmp" "$1"
}

restore() {
  local target="$1"
  if [[ -n "$target" && -d "$target" ]]; then
    echo "restoring edge release $target" >&2
    compose "$target" up --detach --force-recreate --remove-orphans caddy
    wait_healthy "$target"
    point "$current_link" "$target"
  else
    echo "no earlier edge release; stopping the failed one" >&2
    compose "$release_dir" down --remove-orphans || true
    rm -f "$current_link"
  fi
}

if [[ "$mode" == "rollback" ]]; then
  restore "$(readlink "$previous_link" 2>/dev/null || true)"
  echo "edge rollback completed"
  exit 0
fi

for volume in "${EDGE_TARGET}-caddy-data" "${EDGE_TARGET}-caddy-config"; do
  docker volume inspect "$volume" >/dev/null 2>&1 || docker volume create "$volume" >/dev/null
done

docker build --file Dockerfile --tag "$CADDY_IMAGE" .
docker run --rm "$CADDY_IMAGE" caddy list-modules | grep -Fx 'dns.providers.cloudflare' >/dev/null
docker run --rm \
  --env "CF_API_TOKEN=$CF_API_TOKEN" \
  --env "PRISM_HUB_DOMAIN=$PRISM_HUB_DOMAIN" \
  --env "EDGE_TRANSPORT=$EDGE_TRANSPORT" \
  --volume "$release_dir/Caddyfile:/etc/caddy/Caddyfile:ro" \
  "$CADDY_IMAGE" \
  caddy validate --config /etc/caddy/Caddyfile
compose "$release_dir" config --quiet
check_upstreams

echo "edge image, configuration, volumes, and upstreams are valid for $EDGE_TARGET"
[[ "$mode" == "validate" ]] && exit 0

previous_target="$(readlink "$current_link" 2>/dev/null || true)"
[[ "$previous_target" == "$release_dir" ]] && previous_target="$(readlink "$previous_link" 2>/dev/null || true)"

if ! compose "$release_dir" up --detach --force-recreate --remove-orphans caddy || ! wait_healthy "$release_dir"; then
  restore "$previous_target" || true
  exit 1
fi

if [[ -n "$previous_target" ]]; then
  point "$previous_link" "$previous_target"
else
  rm -f "$previous_link"
fi
point "$current_link" "$release_dir"

mapfile -t releases < <(find "$base_dir/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' | sort -rn | cut -f2)
for old in "${releases[@]:$keep_releases}"; do
  [[ "$old" == "$release_dir" || "$old" == "$previous_target" ]] && continue
  rm -rf "$old"
done

echo "edge release $(basename "$release_dir") is active on $EDGE_TARGET; public verification is the caller's commit boundary"
