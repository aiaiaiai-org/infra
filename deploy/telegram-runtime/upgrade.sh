#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MPL-2.0
#
# Replaces the running Telegram login host and bot on edge-dev-1 with a staged
# release. Infra's deploy/telegram-runtime/activate.sh made the first
# activation; this keeps every setting of the running containers (network,
# volumes, base image, environment including the bot token) and swaps only
# the binaries. The token never leaves the host and is never decrypted again.
#
# A service whose binary is byte-identical to the one it already runs is left
# alone, so a Core-only change never restarts the bot and a repeated delivery
# is a no-op. Otherwise one service at a time: the old container is renamed
# and stopped, the new one started and checked. A failed check restores the old container. The bot is
# stopped before its replacement polls, so @nilxone_bot has one poller.
set -Eeuo pipefail

release=${1:?staged release directory required}
test "$(hostname)" = edge-dev-1
test "$(id -un)" = deploy
umask 077

root="$HOME/.local/share/aiaiaiai-infra/telegram-runtime"
host=nilxone-telegram-login-host
bot=nilx-one-bot
network=nilx-candidate

fail() { echo "::error::$*" >&2; exit 1; }
case "$release" in "$root"/*) ;; *) fail 'Release must be staged under the runtime root.' ;; esac
test -d "$release" && test ! -L "$release" || fail 'Staged release is missing.'
(cd "$release" && sha256sum -c --quiet SHA256SUMS) || fail 'Staged release does not match its checksums.'
test "$(sha256sum "$release/SHA256SUMS" | cut -d ' ' -f 1)" = "${release##*/}" || fail 'Release name is not its checksum digest.'
for service in "$host" "$bot"; do
  test "$(docker inspect -f '{{.State.Running}}' "$service" 2>/dev/null)" = true \
    || fail "$service is not running; use Infra's activation first."
done

work=$(mktemp -d "$root/.upgrade.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT

# The checksum line of `binary` in a release's SHA256SUMS.
sum_of() { grep -E "  $2\$" "$1/SHA256SUMS" | cut -d ' ' -f 1; }

# Recreate `service` from its own settings with `binary` from the release.
replace() {
  local service=$1 binary=$2 check=$3 current
  current=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/telegram-runtime"}}{{.Source}}{{end}}{{end}}' "$service")
  if [[ -n "$current" && -f "$current/SHA256SUMS" ]] \
      && [[ "$(sum_of "$current" "$binary")" == "$(sum_of "$release" "$binary")" ]]; then
    echo "$service already runs this $binary; left unchanged."
    return 0
  fi
  local image env_file="$work/$service.env" previous="$service-previous"
  image=$(docker inspect -f '{{.Image}}' "$service")
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$service" | grep -v '^$' > "$env_file"
  local -a mounts=()
  while IFS='|' read -r name destination; do
    [[ "$destination" == /opt/telegram-runtime ]] && continue
    mounts+=(--volume "$name:$destination")
  done < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}|{{.Destination}}{{println}}{{end}}{{end}}' "$service" | grep -v '^$')

  docker rm -f "$previous" >/dev/null 2>&1 || true
  docker rename "$service" "$previous"
  docker stop "$previous" >/dev/null
  if docker run --detach --name "$service" --restart unless-stopped --network "$network" \
      --security-opt no-new-privileges:true --no-healthcheck --env-file "$env_file" \
      --volume "$release:/opt/telegram-runtime:ro" "${mounts[@]}" \
      --entrypoint "/opt/telegram-runtime/$binary" "$image" >/dev/null && "$check"; then
    docker rm "$previous" >/dev/null
    rm -f "$env_file"
    echo "$service now runs $binary from ${release##*/}."
  else
    docker logs --tail 20 "$service" 2>&1 | grep -E 'refused|failed|required|invalid' | head -5 || true
    docker rm -f "$service" >/dev/null 2>&1 || true
    docker rename "$previous" "$service"
    docker start "$service" >/dev/null
    rm -f "$env_file"
    fail "$service did not become ready; the previous release is running again."
  fi
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

ensure_profile_route() {
  local ingress=nilx-public-edge-managed
  local live="$HOME/.local/share/aiaiaiai-infra/nilx-public-edge/Caddyfile"
  local profile=/api/v1/telegram/profile
  test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' "$ingress")" = "$live" \
    || fail 'Unexpected Telegram ingress config mount.'
  cp -p "$live" "$work/previous.Caddyfile"
  awk -v profile="$profile" '
    /^nilx[.]one [{]$/ { nilx = 1 }
    /^}/ { nilx = 0 }
    nilx && $1 == "@telegram_login" && $2 == "path" {
      matchers++
      for (i = 3; i <= NF; i++) {
        if ($i == "/api/v1/telegram/login/start") start = 1
        if ($i == "/api/v1/telegram/login/confirm") confirm = 1
        if ($i == profile) found = 1
      }
      if (!found) $0 = $0 " " profile
    }
    nilx && $1 == "reverse_proxy" && $2 == "@telegram_login" &&
      $3 == "nilxone-telegram-login-host:1927" { proxies++ }
    { print }
    END { if (matchers != 1 || proxies != 1 || !start || !confirm) exit 1 }
  ' "$work/previous.Caddyfile" > "$work/candidate.Caddyfile" \
    || fail 'Expected exactly one Telegram login host route for nilx.one.'
  if cmp -s "$work/previous.Caddyfile" "$work/candidate.Caddyfile"; then return 0; fi

  docker exec -i "$ingress" caddy validate --adapter caddyfile --config - \
    < "$work/candidate.Caddyfile" >/dev/null || fail 'Telegram profile ingress validation failed.'
  cmp -s "$live" "$work/previous.Caddyfile" || fail 'Telegram ingress changed during validation.'
  # Overwrite in place to retain the inode of the live bind mount.
  if ! { cat "$work/candidate.Caddyfile" > "$live" &&
    docker exec "$ingress" caddy reload --config /etc/caddy/Caddyfile >/dev/null; }; then
    cat "$work/previous.Caddyfile" > "$live"
    docker exec "$ingress" caddy reload --config /etc/caddy/Caddyfile >/dev/null \
      || fail 'Could not restore the previous Telegram ingress.'
    fail 'Could not reload Telegram ingress. The previous route was restored.'
  fi
}

bot_ready() {
  sleep 8
  test "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$bot")" = 'true 0'
}

replace "$host" nilxone-telegram-login-host host_ready
ensure_profile_route
replace "$bot" nilx-one-bot bot_ready
echo "Telegram runtime upgraded to ${release##*/}. Send /login to @nilxone_bot to confirm end to end."
