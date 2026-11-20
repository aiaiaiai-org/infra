#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

# Public HTTPS only; curl must verify the trusted certificate (never -k).
base_url='https://nilx.one'
html="$(mktemp)"
js="$(mktemp)"
trap 'rm -f "$html" "$js"' EXIT

curl --fail --silent --show-error --location \
  --connect-timeout 5 --max-time 20 --output "$html" "$base_url/"
# A 200 SPA fallback must not masquerade as a completed client load.
grep -Eiq '<(html|!doctype html)' "$html" || {
  echo 'Public root did not return HTML' >&2
  exit 1
}

asset_path="$(sed -nE 's/.*src="(\/assets\/[A-Za-z0-9._/-]+\.js)".*/\1/p' "$html" | sed -n '1p')"
[[ "$asset_path" =~ ^/assets/[A-Za-z0-9._/-]+\.js$ ]] || {
  echo 'No safe versioned JavaScript asset in public index.html' >&2
  exit 1
}

mime="$(curl --fail --silent --show-error --location \
  --connect-timeout 5 --max-time 30 --output "$js" \
  --write-out '%{content_type}' "$base_url$asset_path")"
case "$mime" in
  application/javascript*|text/javascript*) ;;
  *) echo "Unexpected JS MIME type: $mime" >&2; exit 1 ;;
esac
[[ $(wc -c < "$js") -gt 1024 ]] || {
  echo 'Public JS asset incomplete or empty' >&2
  exit 1
}
printf 'Trusted public HTTPS and JS asset verified: %s (%s bytes)\n' \
  "$asset_path" "$(wc -c < "$js")"
