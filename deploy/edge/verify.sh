#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f .env ]]; then
  echo "deploy/edge/.env is missing" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

edge_scope="${EDGE_SCOPE:-all}"

case "$edge_scope" in
  market|nilx-web|all) ;;
  *)
    echo "EDGE_SCOPE must be market, nilx-web, or all" >&2
    exit 2
    ;;
esac

bash ./check-upstreams.sh "$edge_scope"

if [[ "${VERIFY_PUBLIC_HTTPS:-0}" != "1" ]]; then
  echo "public HTTPS verification is disabled" >&2
  exit 1
fi

bash ./check-public.sh post-activation "$edge_scope"
echo "shared edge verification passed for $edge_scope"
