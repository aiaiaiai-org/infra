#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# usage: check-public.sh <health-url>...
# Every host must resolve, and every URL must answer 2xx over public HTTPS.
set -Eeuo pipefail

HEALTH_RETRY="${HEALTH_RETRY:-2}"
HEALTH_RETRY_DELAY="${HEALTH_RETRY_DELAY:-2}"

[[ "$HEALTH_RETRY" =~ ^[0-9]+$ && "$HEALTH_RETRY_DELAY" =~ ^[0-9]+$ ]] || {
  echo "HEALTH_RETRY and HEALTH_RETRY_DELAY must be non-negative integers" >&2
  exit 2
}
(( $# > 0 )) || { echo "usage: check-public.sh <health-url>..." >&2; exit 2; }

failed=0
for url in "$@"; do
  [[ "$url" =~ ^https://([a-z0-9.-]+)/ ]] || { echo "not a public HTTPS URL: $url" >&2; exit 2; }
  host="${BASH_REMATCH[1]}"

  resolved=""
  for (( attempt = 0; attempt <= HEALTH_RETRY; attempt++ )); do
    resolved="$(getent ahosts "$host" | awk '{print $1}' | sort -u || true)"
    [[ -n "$resolved" ]] && break
    sleep "$HEALTH_RETRY_DELAY"
  done
  if [[ -z "$resolved" ]]; then
    echo "DNS resolution failed for $host" >&2
    failed=1
    continue
  fi
  echo "resolved $host:"
  printf '%s\n' "$resolved" | sed 's/^/  /'

  echo "checking $url"
  curl --fail --silent --show-error --output /dev/null \
    --retry "$HEALTH_RETRY" --retry-all-errors --retry-delay "$HEALTH_RETRY_DELAY" \
    --connect-timeout 10 --max-time 30 \
    "$url" || failed=1
done

if (( failed != 0 )); then
  echo "public verification failed" >&2
  exit 1
fi
echo "public verification passed"
