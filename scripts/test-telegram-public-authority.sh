#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MPL-2.0
set -Eeuo pipefail

source deploy/telegram-runtime/upgrade.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
key=$(printf 'a%.0s' {1..64})
printf 'TELEGRAM_BOT_ID=123456\nTELEGRAM_BOT_PUBLIC_KEY=%s\n' "$key" > "$work/valid"
validate_public_authority "$work/valid"
for fixture in zero invalid duplicate secret reordered; do
  case "$fixture" in
    zero) sed 's/123456/0/' "$work/valid" > "$work/invalid" ;;
    invalid) printf 'TELEGRAM_BOT_ID=123456\nTELEGRAM_BOT_PUBLIC_KEY=invalid\n' > "$work/invalid" ;;
    duplicate) cat "$work/valid" "$work/valid" > "$work/invalid" ;;
    secret) { cat "$work/valid"; printf 'TELEGRAM_BOT_TOKEN=synthetic\n'; } > "$work/invalid" ;;
    reordered) tac "$work/valid" > "$work/invalid" ;;
  esac
  if validate_public_authority "$work/invalid"; then
    fail "Public authority accepted $fixture fixture."
  fi
done

printf '%s\n' '["DATABASE_URL=sqlite:///data/identity.db","TELEGRAM_BOT_TOKEN=synthetic","TELEGRAM_BOT_ID=123","TELEGRAM_BOT_PUBLIC_KEY=old","OTHER=preserved=exactly"]' \
  | project_core_environment > "$work/host.env"
printf '%s\n' 'DATABASE_URL=sqlite:///data/identity.db' 'OTHER=preserved=exactly' > "$work/expected"
cmp "$work/expected" "$work/host.env"
for fixture in '["OTHER=first","OTHER=second"]' '["OTHER=line\nnext"]' '["invalid"]'; do
  if project_core_environment <<< "$fixture" >/dev/null 2>&1; then
    fail 'Accepted ambiguous environment.'
  fi
done
test "$(legacy_bot_id <<< '["TELEGRAM_BOT_TOKEN=123456:synthetic"]')" = 123456
test -z "$(legacy_bot_id <<< '["OTHER=preserved"]')"
for fixture in '["TELEGRAM_BOT_TOKEN=123:one","TELEGRAM_BOT_TOKEN=456:two"]' '["TELEGRAM_BOT_TOKEN=invalid"]'; do
  if legacy_bot_id <<< "$fixture" >/dev/null 2>&1; then
    fail 'Accepted malformed or ambiguous legacy Bot identity.'
  fi
done
echo 'Telegram public authority environment fixtures passed.'
