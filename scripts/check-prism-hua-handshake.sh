#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Production transport check only; the malformed request can never dispatch a Telegram message.
# The secret is read from the infra edge-prod-2 Environment, NOT from an arbitrary caller.
set -Eeuo pipefail
umask 077

: "${PRISM_BOT_DELIVERY_SECRET:?Missing edge-prod-2 PRISM_BOT_DELIVERY_SECRET}"
[[ "${#PRISM_BOT_DELIVERY_SECRET}" -ge 32 ]] || {
  echo "Hub delivery secret must be at least 32 characters" >&2
  exit 1
}
[[ "$PRISM_BOT_DELIVERY_SECRET" != *$'\r'* &&
   "$PRISM_BOT_DELIVERY_SECRET" != *$'\n'* ]] || {
  echo "Hub delivery secret must occupy one line" >&2
  exit 1
}

for program in curl jq; do
  command -v "$program" >/dev/null || { echo "$program required" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'x-prism-bot-delivery-secret: %s\n' "$PRISM_BOT_DELIVERY_SECRET" > "$tmp/header"

origin="https://api.aiaiaiai.org"
health() {
  local label="$1" path="$2"
  curl --silent --show-error --fail --proto '=https' --max-time 15 \
    --output "$tmp/response.json" "$origin$path"
  jq -e '.status == "ok"' "$tmp/response.json" >/dev/null || {
    echo "$label: not healthy" >&2
    exit 1
  }
  echo "$label: HTTP health ok"
}

health "Prism Hub" "/prism-hub/healthz"
health "h-ua-bot" "/hua-bot/health"

# DO NOT add chat_id, text, or idempotency_key: this must NEVER send a message.
# Authentication runs before validation. An expected 400/invalid_request proves
# that the *infra-owned Hub secret* is accepted by the running bot.
status="$(curl --silent --show-error --proto '=https' --max-time 15 \
  --header 'content-type: application/json' \
  --header "@$tmp/header" \
  --data-binary '{}' \
  --output "$tmp/response.json" \
  --write-out '%{http_code}' \
  "$origin/hua-bot/api/v1/delivery")"
if [[ "$status" != "400" ]] ||
   ! jq -e '.status == "error" and .error.code == "invalid_request"' "$tmp/response.json" >/dev/null; then
  echo "Hub↔h-ua-bot authentication/routing failed (HTTP $status)" >&2
  echo "Check deployed versions and PRISM_BOT_DELIVERY_SECRET/HUA_DELIVERY_SECRET parity." >&2
  exit 1
fi

echo "Delivery handshake ok: valid credential, invalid body rejected; no Telegram message sent"
echo "Not verified: bot service-principal token, subscription state, collector, or actual delivery"
