#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

operation=${1:?validate or activate required}
credential=${2:?encrypted bot credential required}
case "$operation" in validate|activate) ;; *) exit 2 ;; esac
test "$(hostname)" = edge-dev-1
test "$(id -un)" = deploy
umask 077

root="$HOME/.local/share/aiaiaiai-infra"
release="$root/telegram-runtime/28deeb0ae567fc144087381ac330c1dcb4c9ebdf0944aab15d2f6c6ef1fbc044"
identity=nilxone-identity
ingress=nilx-public-edge-managed
network=nilx-candidate
host=nilxone-telegram-login-host
bot=nilx-one-bot
live="$root/nilx-public-edge/Caddyfile"

fail() { echo "::error::$*" >&2; exit 1; }
test -d "$release" && test ! -L "$release" || fail 'Verified Telegram release is missing.'
(cd "$release" && sha256sum -c SHA256SUMS)
test "$(sha256sum "$release/SHA256SUMS" | cut -d ' ' -f 1)" = "${release##*/}"
if [[ "$(docker inspect -f '{{.State.Health.Status}}' "$identity")" != healthy ]]; then
  docker inspect -f 'Identity status={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}} image={{.Config.Image}}' "$identity"
  # Report only fixed application error labels, not arbitrary startup logs.
  startup_log=$(docker logs --tail 200 "$identity" 2>&1 || true)
  for reason in \
    'TELEGRAM_BOT_TOKEN must be configured' \
    'NATIVE_AUTH_SECRET must be configured' \
    'PASSWORD_PEPPER must be configured' \
    'GITHUB_EVIDENCE_ENCRYPTION_KEY must be configured' \
    'GITHUB_EVIDENCE_ENCRYPTION_KEY must be a 32-byte hexadecimal key' \
    'native authentication secrets must satisfy the minimum length' \
    'identity database must initialize' \
    'the 0x1 product tables must initialize' \
    'AIS Bonds need legacy and product tables in one SQLite store' \
    'Telegram command menu must register for private chats' \
    'Telegram default chat menu button must open the command list' \
    'Telegram login requires the trusted public AIS Ed25519 signing JWK' \
    'Telegram chat sign-in requires a valid host AIS key' \
    'TELEGRAM_POLLING must be enabled or disabled' \
    'identity HTTP listener must bind' \
    'aiaiaiai sign-in configuration:' \
    'AIS Bond sign-in configuration:' \
    'database is locked' \
    'unable to open database file' \
    'no such column' \
    'Permission denied'; do
    if grep -Fq -- "$reason" <<<"$startup_log"; then
      printf 'Identity startup diagnostic: %s\n' "$reason"
    fi
  done
  unset startup_log
  for key in TELEGRAM_BOT_TOKEN DATABASE_URL NATIVE_AUTH_SECRET PASSWORD_PEPPER GITHUB_EVIDENCE_ENCRYPTION_KEY TELEGRAM_POLLING; do
    if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$identity" | grep -E "^${key}=.+" >/dev/null; then
      printf '%s is configured\n' "$key"
    else
      printf '%s is missing or empty\n' "$key"
    fi
  done
  fail 'Identity must be healthy before Telegram activation.'
fi
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$identity" | grep -Fxq 'TELEGRAM_POLLING=disabled' || fail 'Deploy current Identity with TELEGRAM_POLLING=disabled first.'
docker logs --tail 500 "$identity" 2>&1 | grep -F 'Telegram polling is disabled: the 0x1 bot owns @nilxone_bot updates' >/dev/null || fail 'Identity has not confirmed the polling handoff.'
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$identity" | grep -Fxq 'DATABASE_URL=sqlite:///data/identity.db' || fail 'Identity database configuration differs.'
volume=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$identity")
test "$volume" = nilxone-identity-fresh-data || fail 'Unexpected Identity data volume.'
docker volume inspect "$volume" >/dev/null
docker exec "$identity" test -s /data/identity.db || fail 'Existing Identity database is missing.'
test "$(docker inspect -f '{{.State.Running}}' "$ingress")" = true
test "$(docker inspect -f '{{if index .NetworkSettings.Networks "nilx-candidate"}}yes{{end}}' "$ingress")" = yes
test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' "$ingress")" = "$live"
test -f "$live" && test ! -L "$live"
for service in "$host" "$bot"; do
  if docker inspect "$service" >/dev/null 2>&1; then
    fail "$service already exists; inspect the previous rollout before retrying."
  fi
done

curl --fail --silent --show-error --max-time 15 https://auth.aiaiaiai.org/.well-known/openid-configuration \
  | jq -e '.issuer == "https://auth.aiaiaiai.org" and (.scopes_supported | index("telegram_binding") != null)' >/dev/null || fail 'AIS Telegram binding is not live.'
curl --fail --silent --show-error --max-time 15 --resolve nilx.one:443:127.0.0.1 https://nilx.one/ >/dev/null

work=$(mktemp -d "$root/telegram-runtime/.activation.XXXXXXXX")
host_created=false
bot_created=false
route_changed=false
cleanup() {
  result=$?
  if (( result != 0 )); then
    if "$bot_created"; then docker rm -f "$bot" >/dev/null || true; fi
    if "$route_changed"; then
      cat "$work/previous.Caddyfile" > "$live"
      docker exec "$ingress" caddy reload --config /etc/caddy/Caddyfile >/dev/null || true
    fi
    if "$host_created"; then docker rm -f "$host" >/dev/null || true; fi
  fi
  rm -f "$work/bot.env" "$work/candidate.Caddyfile" "$work/previous.Caddyfile" "$work/callback.html"
  rmdir "$work"
}
trap cleanup EXIT

# Preserve other host blocks; reject an ambiguous or already installed route.
test "$(grep -c '^nilx\.one {$' "$live")" = 1
if grep -Fq '/api/v1/telegram/login/' "$live"; then fail 'Existing Telegram route requires inspection.'; fi
awk '/^nilx\.one \{$/ {print; print "    @telegram_login path /api/v1/telegram/login/start /api/v1/telegram/login/confirm /api/v1/telegram/login/callback /api/v1/telegram/profile"; print "    reverse_proxy @telegram_login nilxone-telegram-login-host:1927"; next} {print}' "$live" > "$work/candidate.Caddyfile"
caddy_image=$(docker inspect -f '{{.Image}}' "$ingress")
docker run --rm --network "$network" --volume "$work/candidate.Caddyfile:/etc/caddy/Caddyfile:ro" "$caddy_image" caddy validate --config /etc/caddy/Caddyfile >/dev/null

# Decrypt the Bot repository's credential with the existing host-owned key.
key_file="$root/nilx-identity-fresh/recipient.agekey"
test -f "$key_file" && test ! -L "$key_file" || fail 'Existing host AGE key is missing.'
age --decrypt --identity "$key_file" --output "$work/bot.env" "$credential" || fail 'Cannot decrypt Bot credential for edge-dev-1.'
mapfile -t bot_environment < "$work/bot.env"
[[ ${#bot_environment[@]} == 1 && ${bot_environment[0]} =~ ^TELEGRAM_BOT_TOKEN=[0-9]+:[A-Za-z0-9_-]+$ ]] || fail 'Invalid product bot credential.'
# The URL contains the token. Keep it off argv and suppress diagnostics that might include it.
token=${bot_environment[0]#TELEGRAM_BOT_TOKEN=}
printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$token" | \
  curl --disable --fail --silent --max-time 15 --config - | \
  jq -e '.ok == true and (.result.username | ascii_downcase) == "nilxone_bot"' >/dev/null || \
  fail 'Bot credential did not authenticate as @nilxone_bot.'
unset token bot_environment
echo 'Telegram credential verified for @nilxone_bot.'
base_image=$(docker inspect -f '{{.Image}}' "$identity")
common=(--network "$network" --security-opt no-new-privileges:true --env-file "$work/bot.env" --volume "$release:/opt/telegram-runtime:ro" --no-healthcheck)
bot_env=(--env BOT_LOGIN_START_URL=https://nilx.one/api/v1/telegram/login/start --env BOT_OIDC_CALLBACK_URL=https://nilx.one/api/v1/telegram/login/callback)
docker run --rm "${common[@]}" "${bot_env[@]}" --entrypoint /opt/telegram-runtime/nilx-one-bot "$base_image" --check

if [[ "$operation" == validate ]]; then
  echo 'Verified release, existing healthy Identity, token, AIS discovery and candidate ingress. No service activation.'
  exit 0
fi

docker run --detach --name "$host" --restart unless-stopped "${common[@]}" \
  --volume "$volume:/data" --env DATABASE_URL=sqlite:///data/identity.db \
  --env TELEGRAM_LOGIN_LISTEN_ADDR=0.0.0.0:1927 --env TELEGRAM_LOGIN_SESSION_TTL_SECONDS=2592000 \
  --entrypoint /opt/telegram-runtime/nilxone-telegram-login-host "$base_image" >/dev/null
host_created=true
cp -p "$live" "$work/previous.Caddyfile"
route_changed=true
cat "$work/candidate.Caddyfile" > "$live"
docker exec "$ingress" caddy reload --config /etc/caddy/Caddyfile >/dev/null
for attempt in $(seq 1 15); do
  status=$(curl --silent --show-error --max-time 10 --resolve nilx.one:443:127.0.0.1 \
    --output "$work/callback.html" --write-out '%{http_code}' https://nilx.one/api/v1/telegram/login/callback || true)
  if [[ "$status" == 400 ]] && grep -Fq 'Sign-in failed' "$work/callback.html"; then break; fi
  if [[ "$attempt" == 15 ]]; then fail 'Core callback did not become ready.'; fi
  sleep 2
done
curl --fail --silent --show-error --max-time 15 --resolve nilx.one:443:127.0.0.1 https://nilx.one/ >/dev/null
docker run --detach --name "$bot" --restart unless-stopped "${common[@]}" "${bot_env[@]}" \
  --volume nilx-one-bot-state:/state --env BOT_UI_STATE_PATH=/state/bot-ui-state.json \
  --entrypoint /opt/telegram-runtime/nilx-one-bot "$base_image" >/dev/null
bot_created=true
sleep 5
test "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$bot")" = 'true 0'
test "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$host")" = 'true 0'
echo 'Telegram runtime activated. Confirm /login end to end in the original Telegram chat.'
