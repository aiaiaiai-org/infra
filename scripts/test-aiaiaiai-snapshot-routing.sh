#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
# Smoke-test the actual archive Caddy routing against immutable static fixtures.
set -Eeuo pipefail

work="$(mktemp -d)"
container="aiaiaiai-snapshot-routing-${GITHUB_RUN_ID:-test}-$$"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
tag=v1.2.3
mkdir -p "$work/beta/$sha/_astro" "$work/release/$tag/_astro"
printf 'BETA-SNAPSHOT\n' > "$work/beta/$sha/index.html"
printf 'beta-assets\n' > "$work/beta/$sha/_astro/test.js"
printf 'RELEASE-SNAPSHOT\n' > "$work/release/$tag/index.html"
printf 'release-assets\n' > "$work/release/$tag/_astro/test.js"
ln -s "$sha" "$work/beta/current"

docker run -d --name "$container" --publish 127.0.0.1:1937:1927 \
  --volume "$PWD/deploy/aiaiaiai-site-snapshots/Caddyfile:/etc/caddy/Caddyfile:ro" \
  --volume "$work:/srv/versions:ro" caddy:2-alpine >/dev/null

url=http://127.0.0.1:1937
for attempt in $(seq 1 25); do
  if curl --fail --silent "$url/healthz" > /dev/null; then break; fi
  sleep 1
done
test "$(curl --fail --silent "$url/healthz")" = ok
test "$(curl -fsS -H 'Host: beta.aiaiaiai.org' "$url/")" = BETA-SNAPSHOT
test "$(curl -fsS -H 'Host: beta.aiaiaiai.org' "$url/$sha/")" = BETA-SNAPSHOT
test "$(curl -fsS -H 'Host: beta.aiaiaiai.org' "$url/$sha/_astro/test.js")" = beta-assets
test "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: beta.aiaiaiai.org' "$url/000000/")" = 404

# Before the first release the apex redirects to the beta hostname, not /beta/.
test "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: aiaiaiai.org' "$url/")" = 302
test "$(curl -sS -o /dev/null -w '%{redirect_url}' -H 'Host: aiaiaiai.org' "$url/")" = https://beta.aiaiaiai.org/

# Stable release path is available even before the apex latest alias is active.
test "$(curl -fsS -H 'Host: aiaiaiai.org' "$url/$tag/")" = RELEASE-SNAPSHOT
test "$(curl -fsS -H 'Host: aiaiaiai.org' "$url/$tag/_astro/test.js")" = release-assets
ln -s "$tag" "$work/release/current"
test "$(curl -fsS -H 'Host: aiaiaiai.org' "$url/")" = RELEASE-SNAPSHOT
test "$(curl -fsS -H 'Host: aiaiaiai.org' "$url/$tag/")" = RELEASE-SNAPSHOT

echo 'aiaiaiai archive Caddy routes pass: beta merge-SHA, release SemVer, assets, redirects'
