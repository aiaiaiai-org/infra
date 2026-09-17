#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

EDGE_NETWORK="${EDGE_NETWORK:-nilx-edge}"
EDGE_SCOPE="${1:-${EDGE_SCOPE:-all}}"

case "$EDGE_SCOPE" in
  mind-web|market|nilx-web|all) ;;
  *)
    echo "EDGE_SCOPE must be mind-web, market, nilx-web, or all" >&2
    exit 2
    ;;
esac

check_upstream() {
  local label="$1"
  local url="$2"

  echo "checking upstream $label at $url"
  docker run --rm --network "$EDGE_NETWORK" alpine:3.22 \
    wget -q -T 10 -O /dev/null "$url"
  echo "upstream healthy: $label"
}

check_mind() {
  check_upstream mind-web http://mind-web:8080/health
}

check_market() {
  check_upstream market-api-production http://market-api-production:10000/health
  check_upstream market-bot-production http://market-bot-production:10000/health
  check_upstream market-bot-test http://market-bot-development:10000/health
}

check_nilx_web() {
  check_upstream nilxone-web http://nilxone-web:1927/health
  check_upstream nilxone-telegram http://nilxone-telegram:1927/health
  check_upstream nilxone-discord http://nilxone-discord:1927/health
}

case "$EDGE_SCOPE" in
  mind-web)
    check_mind
    ;;
  market)
    check_market
    ;;
  nilx-web)
    check_nilx_web
    ;;
  all)
    check_mind
    check_market
    check_nilx_web
    ;;
esac
