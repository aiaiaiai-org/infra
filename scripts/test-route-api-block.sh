#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Runs the REAL block functions of deploy/aiaiaiai-edge-dev-1/route.sh on the shape of the live ingress
# (the nilx.one site, then the api.aiaiaiai.org block that route.sh appended earlier): replacing that block
# with the reviewed one must leave every other site byte for byte as it was.
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
route="$root/deploy/aiaiaiai-edge-dev-1/route.sh"
snippet="$root/deploy/aiaiaiai-edge-dev-1/api.Caddyfile"
for fn in api_block replace_api_block without_api_block collector_route; do
  line="$(grep -E "^$fn\(\) \{.*\}$" "$route")" || { echo "FAIL: $fn is not a one-line function of route.sh" >&2; exit 1; }
  eval "$line"
done
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
new_block="$tmp/new.block"
api_block "$snippet" >"$new_block"
grep -q '/hua-bot/' "$new_block" || fail "the reviewed block does not route the bot"
grep -Fq 'handle_path /4x-errors/*' "$new_block" || fail "collector prefix is not stripped"
grep -Fq 'reverse_proxy 4x-errors:1927' <<<"$(collector_route "$new_block")" || fail "wrong collector upstream"
grep -Fq 'health_uri /ready' <<<"$(collector_route "$new_block")" || fail "collector health must use readiness"
[[ "$(head -n1 "$new_block")" == "api.aiaiaiai.org {" && "$(tail -n1 "$new_block")" == "}" ]] || fail "the extracted block is not one whole site block"

# What was live: the previous reviewed block (without the bot's route), appended after the other sites.
old_block="$tmp/old.block"
awk '/^\t@hua_bot_root/ { skip = 1 } /^\thandle \{/ { skip = 0 } !skip { print }' "$new_block" >"$old_block"
grep -q '/hua-bot/' "$old_block" && fail "the previous block still routes the bot"
[[ -z "$(collector_route "$old_block")" ]] || fail "old block unexpectedly routes the collector"
live="$tmp/live"
{ cat "$root/deploy/nilx-public-edge/Caddyfile"; printf '\n'; cat "$old_block"; printf '\n'; printf 'after.example.test {\n\trespond "after" 200\n}\n'; } >"$live"

candidate="$tmp/candidate"
replace_api_block "$live" "$new_block" >"$candidate"
[[ "$(api_block "$candidate")" == "$(cat "$new_block")" ]] || fail "the block was not replaced by the reviewed one"
cmp -s <(without_api_block "$live") <(without_api_block "$candidate") || fail "something outside the api block changed"
grep -Fq 'respond "after" 200' "$candidate" || fail "the site after the api block was lost"
grep -Fq 'nilx.one {' "$candidate" || fail "the nilx.one site was lost"

# Replacing with the block that is already live changes nothing at all.
again="$tmp/again"
replace_api_block "$candidate" "$new_block" >"$again"
cmp -s "$candidate" "$again" || fail "replacing the reviewed block with itself is not a no-op"
[[ "$(collector_route "$candidate")" == "$(collector_route "$again")" ]] || fail "unchanged collector route is not stable"
[[ "$(grep -Fxc 'api.aiaiaiai.org {' "$candidate")" == 1 ]] || fail "the api block is not unique"

echo "ok: the live api block is replaced in place and nothing else changes"
