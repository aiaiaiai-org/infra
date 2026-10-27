#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Infrastructure owns health of routed services, not product authentication.
# The historical script name is retained to avoid unrelated path changes.
set -Eeuo pipefail
umask 077

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "::error::$tool required" >&2; exit 78; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
origin="https://api.aiaiaiai.org"
health() {
  local label="$1" path="$2"
  curl --silent --show-error --fail --proto '=https' --max-time 15 \
    --output "$tmp/health.json" "$origin$path"
  if ! jq -e --arg label "$label" \
    '.status == "ok" and (.service == $label or .service == null)' "$tmp/health.json" >/dev/null; then
    echo "::error::$label: invalid health response" >&2
    exit 1
  fi
  echo "$label: HTTP health ok"
}

health "prism-hub" "/prism-hub/healthz"
health "h-ua-bot" "/hua-bot/health"
echo "Infra health check passed. Delivery authentication belongs to prism-hub/production."
echo "NOT VERIFIED: delivery secret, subscriptions, source scheduler, Porter or Telegram message."
