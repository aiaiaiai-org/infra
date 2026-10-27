#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Mocked tests for independent website lifecycle; no Docker daemon needed.
set -Eeuo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == container && "$2" == inspect && "$3" == aiaiaiai-site ]]; then
  [[ "$MOCK_SITE" != absent ]]
  exit
fi
[[ "$1" == run && "$2" == --rm && "$3" == --network &&
   "$4" == aiaiaiai-edge && "$5" == alpine:3.22 &&
   "$6" == wget ]] || {
  printf 'Unexpected docker invocation:' >&2
  printf ' %q' "$@" >&2
  echo >&2
  exit 91
}
# The final argument is the URL; avoid assumptions about wget option count.
while (($# > 1)); do shift; done
url="$1"
printf '%s\n' "$url" >> "$MOCK_LOG"
case "$url" in
  http://prism-hub:1927/healthz) [[ "$MOCK_HUB" == ok ]] ;;
  http://h-ua-bot:1927/health) [[ "$MOCK_BOT" == ok ]] ;;
  http://aiaiaiai-site:1927/healthz) [[ "$MOCK_SITE" == ok ]] ;;
  *) echo "Unexpected URL" >&2; exit 92 ;;
esac
DOCKER
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"
export EDGE_NETWORK=aiaiaiai-edge
export MOCK_LOG="$tmp/requests"

export MOCK_HUB=ok MOCK_BOT=ok MOCK_SITE=absent
bash deploy/edge-aiaiaiai/verify.sh > "$tmp/missing.log"
grep -Fq 'workload not deployed; skipping optional website health' "$tmp/missing.log"
test "$(wc -l < "$tmp/requests")" -eq 2
! grep -Fq 'aiaiaiai-site' "$tmp/requests"

export MOCK_SITE=ok
: > "$tmp/requests"
bash deploy/edge-aiaiaiai/verify.sh > "$tmp/present.log"
test "$(wc -l < "$tmp/requests")" -eq 3
grep -Fxq 'http://aiaiaiai-site:1927/healthz' "$tmp/requests"

export MOCK_SITE=unhealthy
: > "$tmp/requests"
if bash deploy/edge-aiaiaiai/verify.sh > "$tmp/bad-site.log" 2>&1; then
  echo "Deployed but unhealthy website must fail" >&2; exit 1
fi

export MOCK_SITE=absent MOCK_BOT=down
: > "$tmp/requests"
if bash deploy/edge-aiaiaiai/verify.sh > "$tmp/bad-bot.log" 2>&1; then
  echo "Required h-ua-bot must fail" >&2; exit 1
fi

export MOCK_BOT=ok MOCK_HUB=down
: > "$tmp/requests"
if bash deploy/edge-aiaiaiai/verify.sh > "$tmp/bad-hub.log" 2>&1; then
  echo "Required Prism Hub must fail" >&2; exit 1
fi

echo "Edge verification: missing website tolerated, deployed website and both APIs required"
