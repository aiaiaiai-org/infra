#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

MODE="${1:-post-activation}"
EDGE_SCOPE="${2:-${EDGE_SCOPE:-all}}"
HEALTH_RETRY="${HEALTH_RETRY:-2}"
HEALTH_RETRY_DELAY="${HEALTH_RETRY_DELAY:-2}"
HEALTH_CONNECT_TIMEOUT="${HEALTH_CONNECT_TIMEOUT:-10}"
HEALTH_MAX_TIME="${HEALTH_MAX_TIME:-30}"
NILX_BOND_HEALTH_HOST="${NILX_BOND_HEALTH_HOST:-bond-wildcard-health-0x1.nilx.one}"

if ! [[ "$HEALTH_RETRY" =~ ^[0-9]+$ ]]; then
  echo "HEALTH_RETRY must be a non-negative integer" >&2
  exit 2
fi
if ! [[ "$HEALTH_RETRY_DELAY" =~ ^[0-9]+$ ]]; then
  echo "HEALTH_RETRY_DELAY must be a non-negative integer" >&2
  exit 2
fi

case "$EDGE_SCOPE" in
  market|market-development|nilx-web|all) ;;
  *)
    echo "EDGE_SCOPE must be market, nilx-web, or all" >&2
    exit 2
    ;;
esac

redirects=()

case "$MODE" in
  candidate-dns)
    urls=()
    case "$EDGE_SCOPE" in
      market|market-development)
        hosts=(0xda-market.nilx.one)
        ;;
      nilx-web)
        hosts=(nilx.one "$NILX_BOND_HEALTH_HOST")
        ;;
      all)
        hosts=(0xda-market.nilx.one nilx.one "$NILX_BOND_HEALTH_HOST")
        ;;
    esac
    ;;
  post-activation)
    case "$EDGE_SCOPE" in
      market)
        hosts=(0xda-market.nilx.one)
        urls=(
          https://0xda-market.nilx.one/health
          https://0xda-market.nilx.one/bot/health
          https://0xda-market.nilx.one/bot-test/health
        )
        ;;
      market-development)
        hosts=(0xda-market.nilx.one)
        urls=(
          'https://0xda-market.nilx.one/v1/webapp/bootstrap?preview_0x1=true'
        )
        ;;
      nilx-web)
        hosts=(nilx.one "$NILX_BOND_HEALTH_HOST")
        urls=(
          https://nilx.one/health
          https://nilx.one/telegram/health
          https://nilx.one/discord/health
          "https://${NILX_BOND_HEALTH_HOST}/health"
        )
        redirects=(
          'https://nilx.one/telegram|https://nilx.one/telegram/'
          'https://nilx.one/discord|https://nilx.one/discord/'
        )
        ;;
      all)
        hosts=(0xda-market.nilx.one nilx.one "$NILX_BOND_HEALTH_HOST")
        urls=(
          https://0xda-market.nilx.one/health
          https://0xda-market.nilx.one/bot/health
          https://0xda-market.nilx.one/bot-test/health
          https://nilx.one/health
          https://nilx.one/telegram/health
          https://nilx.one/discord/health
          "https://${NILX_BOND_HEALTH_HOST}/health"
        )
        redirects=(
          'https://nilx.one/telegram|https://nilx.one/telegram/'
          'https://nilx.one/discord|https://nilx.one/discord/'
        )
        ;;
    esac
    ;;
  *)
    echo "mode must be candidate-dns or post-activation" >&2
    exit 2
    ;;
esac

resolve_host() {
  local host="$1"
  local ipv4 ipv6
  local attempt=0

  while :; do
    ipv4="$(getent ahostsv4 "$host" | awk '{print $1}' | sort -u || true)"
    ipv6="$(getent ahostsv6 "$host" | awk '{print $1}' | sort -u || true)"

    if [[ -n "$ipv4" || -n "$ipv6" ]]; then
      break
    fi
    if (( attempt >= HEALTH_RETRY )); then
      break
    fi

    attempt=$((attempt + 1))
    sleep "$HEALTH_RETRY_DELAY"
  done

  echo "resolving $host"
  echo "  IPv4:"
  if [[ -n "$ipv4" ]]; then
    printf '%s\n' "$ipv4" | sed 's/^/    /'
  fi
  echo "  IPv6:"
  if [[ -n "$ipv6" ]]; then
    printf '%s\n' "$ipv6" | sed 's/^/    /'
  fi

  if [[ -z "$ipv4" && -z "$ipv6" ]]; then
    echo "DNS resolution failed for required public host: $host" >&2
    return 1
  fi
}

health() {
  local url="$1"

  echo "checking $url"
  curl \
    --fail \
    --silent \
    --show-error \
    --output /dev/null \
    --retry "$HEALTH_RETRY" \
    --retry-all-errors \
    --retry-delay "$HEALTH_RETRY_DELAY" \
    --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
    --max-time "$HEALTH_MAX_TIME" \
    "$url"
}

canonical_redirect() {
  local source="$1"
  local expected="$2"
  local result status target

  echo "checking canonical redirect $source -> $expected"
  result="$(
    curl \
      --silent \
      --show-error \
      --output /dev/null \
      --retry "$HEALTH_RETRY" \
      --retry-all-errors \
      --retry-delay "$HEALTH_RETRY_DELAY" \
      --connect-timeout "$HEALTH_CONNECT_TIMEOUT" \
      --max-time "$HEALTH_MAX_TIME" \
      --write-out $'%{http_code}\t%{redirect_url}' \
      "$source" || true
  )"
  IFS=$'\t' read -r status target <<<"$result"

  if [[ "$status" != 308 || "$target" != "$expected" ]]; then
    echo "canonical redirect failed: $source expected 308 -> $expected, got ${status:-request-failed} -> ${target:-none}" >&2
    return 1
  fi
}

failed=0
for host in "${hosts[@]}"; do
  if ! resolve_host "$host"; then
    failed=1
  fi
done

if [[ "$MODE" == candidate-dns ]]; then
  if (( failed != 0 )); then
    echo "one or more candidate public hosts do not resolve for scope $EDGE_SCOPE" >&2
    exit 1
  fi
  exit 0
fi

for url in "${urls[@]}"; do
  if ! health "$url"; then
    failed=1
  fi
done

# A missing cookie must be rejected, but the development session endpoint
# must exist. 401 means healthy; 404 or 5xx indicates a broken handoff route.
if [[ "$MODE" == post-activation && "$EDGE_SCOPE" == market-development ]]; then
  session_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout "$HEALTH_CONNECT_TIMEOUT" --max-time "$HEALTH_MAX_TIME" \
    https://0xda-market.nilx.one/nilx-browser/session || true)"
  if [[ "$session_status" != 401 ]]; then
    echo "market development unauthenticated session expected HTTP 401, got ${session_status:-request-failed}" >&2
    failed=1
  fi
fi

for redirect in "${redirects[@]}"; do
  IFS='|' read -r source expected <<<"$redirect"
  if ! canonical_redirect "$source" "$expected"; then
    failed=1
  fi
done

if (( failed != 0 )); then
  echo "one or more shared-edge public health checks failed in $MODE mode for scope $EDGE_SCOPE" >&2
  exit 1
fi
