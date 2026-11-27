#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MPL-2.0
#
# Upgrade the existing Core/Bot pair to public-key Gateway authorization.
# The Bot is the sole credential owner. Keep the previous pair stopped,
# not removed, until the candidate passes the signed read-only probe.

set -Eeuo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

# Only accept two exact public metadata lines from the verified Bot binary.
validate_public_authority() {
  local -a fields=()
  mapfile -t fields < "$1"
  [[ ${#fields[@]} == 2 &&
     ${fields[0]} =~ ^TELEGRAM_BOT_ID=[1-9][0-9]{0,19}$ &&
     ${fields[1]} =~ ^TELEGRAM_BOT_PUBLIC_KEY=[0-9a-f]{64}$ ]]
}

# Receive Docker's JSON environment. Reject ambiguous or multiline settings.
# Strip any old Telegram credential before writing the Core environment.
# Preserve all unrelated service settings.
project_core_environment() {
  jq -er '
    if type != "array" or
       any(.[]; type != "string" or test("[\r\n]") or (test("^[A-Za-z_][A-Za-z0-9_]*=") | not)) or
       ((map(split("=")[0]) | unique | length) != length)
    then error("Invalid container environment")
    else .[] | select(test("^TELEGRAM_BOT_(TOKEN|ID|PUBLIC_KEY)=") | not)
    end
  '
}

capture_bot_environment() {
  # Secret values stay on the target in a mode-0600 file, never in argv/logs.
  docker inspect -f '{{json .Config.Env}}' "$bot" | jq -er '
    if type != "array" or
       any(.[]; type != "string" or test("[\r\n]") or (test("^[A-Za-z_][A-Za-z0-9_]*=") | not)) or
       ((map(split("=")[0]) | unique | length) != length)
    then error("Invalid Bot environment")
    else .[] end
  ' > "$work/bot.env"
  grep -Eq '^TELEGRAM_BOT_TOKEN=[0-9]+:[A-Za-z0-9_-]+$' "$work/bot.env" ||
    fail 'Existing Bot credential is missing or malformed.'
}

host_ready() {
  local status
  for _ in $(seq 1 15); do
    status=$(curl --silent --max-time 10 --resolve nilx.one:443:127.0.0.1 \
      --output "$work/callback.html" --write-out '%{http_code}' \
      https://nilx.one/api/v1/telegram/login/callback || true)
    if [[ "$status" == 400 ]] && grep -Fq 'Sign-in failed' "$work/callback.html"; then return 0; fi
    sleep 2
  done
  return 1
}

prepare_routes() {
  local added="/api/v1/telegram/profile /api/v1/telegram/login/progress /api/v1/telegram/location /api/v1/telegram/activation /api/v1/telegram/activation/answer /api/v1/telegram/notifications/pull /api/v1/telegram/notifications/ack /api/v1/telegram/admin/delivery/pull /api/v1/telegram/admin/delivery/ack /api/v1/telegram/admin/decide /api/v1/telegram/gateway/health"
  test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' "$ingress")" = "$live" \
    || fail 'Unexpected Telegram ingress config mount.'
  test -f "$live" && test ! -L "$live"
  cp -p "$live" "$work/previous.Caddyfile"
  awk -v added="$added" '
    BEGIN { wanted = split(added, routes, " ") }
    /^nilx[.]one [{]$/ { nilx = 1 }
    /^}/ { nilx = 0 }
    nilx && $1 == "@telegram_login" && $2 == "path" {
      matchers++
      delete found
      for (i = 3; i <= NF; i++) {
        if ($i == "/api/v1/telegram/login/start") start = 1
        if ($i == "/api/v1/telegram/login/confirm") confirm = 1
        if ($i == "/api/v1/telegram/login/callback") callback = 1
        found[$i] = 1
      }
      for (r = 1; r <= wanted; r++) if (!(routes[r] in found)) $0 = $0 " " routes[r]
    }
    nilx && $1 == "reverse_proxy" && $2 == "@telegram_login" &&
      $3 == "nilxone-telegram-login-host:1927" { proxies++ }
    { print }
    END { if (matchers != 1 || proxies != 1 || !start || !confirm || !callback) exit 1 }
  ' "$work/previous.Caddyfile" > "$work/candidate.Caddyfile" \
    || fail 'Expected exactly one Telegram login host route for nilx.one.'
  docker exec -i "$ingress" caddy validate --adapter caddyfile --config - \
    < "$work/candidate.Caddyfile" >/dev/null || fail 'Telegram ingress validation failed.'
}

# Preserve named volume mounts and the base image of each existing container.
# No old service is removed here: rollback retains the original container.
read_mounts() {
  local service=$1 mount_rows name destination
  mount_rows=$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}|{{.Destination}}{{println}}{{end}}{{end}}' "$service")
  mounts=()
  while IFS='|' read -r name destination; do
    [[ -n "$name" && -n "$destination" ]] || continue
    [[ "$destination" == /opt/telegram-runtime ]] && continue
    mounts+=(--volume "$name:$destination")
  done <<< "$mount_rows"
}

start_candidate() {
  local service=$1 binary=$2 image=$3 env_file=$4
  read_mounts "$service-previous"
  docker run --detach --name "$service" --restart unless-stopped --network "$network" \
    --security-opt no-new-privileges:true --no-healthcheck --env-file "$env_file" \
    --volume "$release:/opt/telegram-runtime:ro" "${mounts[@]}" \
    --entrypoint "/opt/telegram-runtime/$binary" "$image" >/dev/null
}

restore_service() {
  local service=$1
  if docker inspect "$service-previous" >/dev/null 2>&1; then
    if docker inspect "$service" >/dev/null 2>&1; then
      docker rm -f "$service" >/dev/null || return 1
    fi
    docker rename "$service-previous" "$service" || return 1
    if [[ "$(docker inspect -f '{{.State.Running}}' "$service")" != true ]]; then
      docker start "$service" >/dev/null || return 1
    fi
  fi
}

cleanup() {
  local result=$? recovery=0
  trap - EXIT
  if (( result != 0 )) && [[ "$committed" == false ]]; then
    # Stop a candidate Bot before restoring the former host/poller.
    if docker inspect "$bot-previous" >/dev/null 2>&1 && docker inspect "$bot" >/dev/null 2>&1; then
      docker rm -f "$bot" >/dev/null || recovery=1
    fi
    restore_service "$host" || recovery=1
    if [[ "$route_changed" == true ]]; then
      if cmp -s "$live" "$work/candidate.Caddyfile"; then
        cat "$work/previous.Caddyfile" > "$live" &&
          docker exec "$ingress" caddy reload --config /etc/caddy/Caddyfile >/dev/null || recovery=1
      else
        echo "::error::Ingress changed during rollback; refusing to overwrite unrelated changes." >&2
        recovery=1
      fi
    fi
    restore_service "$bot" || recovery=1
    if (( recovery != 0 )); then
      echo "::error::Pair rollback incomplete; inspect both containers and ingress before retrying." >&2
    else
      echo "Previous Core/Bot pair restored." >&2
    fi
  fi
  rm -rf -- "$work"
  exit "$result"
}

main() {
  release=${1:?staged release directory required}
  test "$(hostname)" = edge-dev-1
  test "$(id -un)" = deploy
  umask 077
  root="$HOME/.local/share/aiaiaiai-infra/telegram-runtime"
  host=nilxone-telegram-login-host
  bot=nilx-one-bot
  network=nilx-candidate
  ingress=nilx-public-edge-managed
  live="$HOME/.local/share/aiaiaiai-infra/nilx-public-edge/Caddyfile"
  case "$release" in "$root"/*) ;; *) fail 'Release must be staged under the runtime root.' ;; esac
  test -d "$release" && test ! -L "$release" || fail 'Staged release is missing.'
  (cd "$release" && sha256sum -c --quiet SHA256SUMS) || fail 'Staged release does not match its checksums.'
  test "$(sha256sum "$release/SHA256SUMS" | cut -d ' ' -f 1)" = "${release##*/}" || fail 'Release name is not its checksum digest.'
  for service in "$host" "$bot"; do
    test "$(docker inspect -f '{{.State.Running}}' "$service" 2>/dev/null)" = true \
      || fail "$service is not running; inspect activation before upgrading."
    if docker inspect "$service-previous" >/dev/null 2>&1; then
      fail "$service-previous already exists; inspect the previous rollout first."
    fi
  done
  work=$(mktemp -d "$root/.upgrade.XXXXXXXX")
  committed=false
  route_changed=false
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  host_image=$(docker inspect -f '{{.Image}}' "$host")
  bot_image=$(docker inspect -f '{{.Image}}' "$bot")
  capture_bot_environment
  # This temporary Bot process runs getMe and exports only its public metadata.
  # It never starts polling and never exports the signing seed.
  docker run --rm --network "$network" --security-opt no-new-privileges:true \
    --env-file "$work/bot.env" --volume "$release:/opt/telegram-runtime:ro" \
    --entrypoint /opt/telegram-runtime/nilx-one-bot "$bot_image" --gateway-public-key \
    > "$work/public.env" || fail 'Candidate Bot could not prove its public authority.'
  validate_public_authority "$work/public.env" || fail 'Invalid public Bot authority output.'
  # Existing public authority may not silently rotate during an ordinary binary rollout.
  docker inspect -f '{{json .Config.Env}}' "$host" | jq -r '.[] | select(test("^TELEGRAM_BOT_(ID|PUBLIC_KEY)="))' \
    | sort > "$work/previous-public.env"
  if [[ -s "$work/previous-public.env" ]] &&
    ! cmp -s "$work/previous-public.env" <(sort "$work/public.env"); then
    fail 'Public Bot authority changed; explicit rotation is required.'
  fi
  docker inspect -f '{{json .Config.Env}}' "$host" | project_core_environment > "$work/host.env"
  cat "$work/public.env" >> "$work/host.env"
  ! grep -q '^TELEGRAM_BOT_TOKEN=' "$work/host.env" || fail 'Bot credential crossed the Core boundary.'
  docker run --rm --network "$network" --security-opt no-new-privileges:true \
    --env-file "$work/host.env" --volume "$release:/opt/telegram-runtime:ro" \
    --entrypoint /opt/telegram-runtime/nilxone-telegram-login-host "$host_image" \
    --check-public-authority >/dev/null || fail 'Candidate Core public authority rejected.'
  prepare_routes

  # Stop the only poller before changing either half of the protocol.
  docker rename "$bot" "$bot-previous"
  docker stop "$bot-previous" >/dev/null
  docker rename "$host" "$host-previous"
  docker stop "$host-previous" >/dev/null
  start_candidate "$host" nilxone-telegram-login-host "$host_image" "$work/host.env"
  cmp -s "$live" "$work/previous.Caddyfile" || fail 'Telegram ingress changed during validation.'
  if ! cmp -s "$live" "$work/candidate.Caddyfile"; then
    route_changed=true
    cat "$work/candidate.Caddyfile" > "$live"
    docker exec "$ingress" caddy reload --config /etc/caddy/Caddyfile >/dev/null
  fi
  host_ready || fail 'Core callback did not become ready.'
  # Real signed HTTPS round-trip before the candidate poller is started.
  docker run --rm --network "$network" --security-opt no-new-privileges:true \
    --env-file "$work/bot.env" --volume "$release:/opt/telegram-runtime:ro" \
    --entrypoint /opt/telegram-runtime/nilx-one-bot "$bot_image" --check-gateway \
    || fail 'Core/Bot signed Gateway readiness probe failed.'
  start_candidate "$bot" nilx-one-bot "$bot_image" "$work/bot.env"
  sleep 8
  for service in "$host" "$bot"; do
    test "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$service")" = 'true 0' ||
      fail "$service failed readiness."
  done
  if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$host" | grep -q '^TELEGRAM_BOT_TOKEN='; then
    fail 'Core candidate contains a forbidden Bot API token.'
  fi
  committed=true
  # Only after both halves pass the same authority check discard the stopped pair.
  docker rm "$host-previous" "$bot-previous" >/dev/null ||
    fail 'New pair is running; stopped rollback containers require operator cleanup.'
  echo 'Telegram Gateway v2 pair upgraded and signed probe passed. Confirm /login end to end.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
