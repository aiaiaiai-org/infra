#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Checks from inside the edge network that every routed workload answers its health path.
set -Eeuo pipefail

EDGE_NETWORK="${EDGE_NETWORK:-aiaiaiai-edge}"

check_upstream() {
  local label="$1"
  local url="$2"

  echo "checking upstream $label at $url"
  docker run --rm --network "$EDGE_NETWORK" alpine:3.22 \
    wget -q -T 10 -O /dev/null "$url"
  echo "upstream healthy: $label"
}

# Hub and bot must always be healthy for this edge deployment to succeed.
check_upstream prism-hub http://prism-hub:1927/healthz
check_upstream h-ua-bot http://h-ua-bot:1927/health

# The website is independently released. It may not have been deployed yet.
# Skip ONLY if its canonical workload container is absent. Once present, even
# when stopped, an unhealthy site must fail the verification visibly.
if docker container inspect aiaiaiai-site >/dev/null 2>&1; then
  check_upstream aiaiaiai-site http://aiaiaiai-site:1927/healthz
else
  echo "aiaiaiai-site workload not deployed; skipping optional website health"
fi

# The auth identity service (aiaiaiai-org/4x-ais) is released independently and
# may not exist yet. Same rule as the website: skip only when its container is
# absent; once present, an unhealthy service fails the verification.
if docker container inspect 4x-ais >/dev/null 2>&1; then
  check_upstream 4x-ais http://4x-ais:1927/healthz
else
  echo "4x-ais workload not deployed; skipping optional auth health"
fi
