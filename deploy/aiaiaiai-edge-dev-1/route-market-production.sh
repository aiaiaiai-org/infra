#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

mode="${1:-validate}"
case "$mode" in validate | activate) ;; *) exit 2 ;; esac
test "$(hostname)" = edge-dev-1
test "$(id -un)" = deploy

domain=0xda-market.nilx.one
ingress=nilx-public-edge-managed
live="$HOME/.local/share/aiaiaiai-infra/nilx-public-edge/Caddyfile"
test -s "$live"
test ! -L "$live"
test "$(docker inspect -f '{{.State.Running}}' "$ingress")" = true
test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' "$ingress")" = "$(realpath "$live")"
test "$(docker inspect -f '{{if index .NetworkSettings.Networks "nilx-candidate"}}yes{{end}}' "$ingress")" = yes

for upstream in market-bot-production market-api-production; do
  docker exec "$ingress" wget -q -T 5 -O /dev/null "http://$upstream:1927/health"
done

work_dir="$(mktemp -d)"
changed=false
finish() {
  if [[ "$changed" == true ]]; then
    if cat "$work_dir/original" >"$live" &&
       docker exec "$ingress" caddy reload --config /etc/caddy/Caddyfile; then
      echo 'Restored the previous ingress configuration.' >&2
    else
      echo 'Could not restore the previous ingress configuration.' >&2
    fi
  fi
  rm -rf "$work_dir"
}
trap finish EXIT

cp "$live" "$work_dir/original"
cat >"$work_dir/market" <<'CADDY'
0xda-market.nilx.one {
    encode zstd gzip

    handle_path /bot/* {
        reverse_proxy market-bot-production:1927
    }

    handle {
        reverse_proxy market-api-production:1927
    }
}
CADDY

if grep -Fq "$domain" "$work_dir/original"; then
  awk -v domain="$domain" '$0 == domain " {" { print_block = 1 } print_block { print } print_block && $0 == "}" { exit }' \
    "$work_dir/original" >"$work_dir/current-market"
  if ! cmp -s "$work_dir/current-market" "$work_dir/market"; then
    echo 'An existing Market route needs a reviewed update.' >&2
    exit 1
  fi
  cp "$work_dir/original" "$work_dir/candidate"
else
  { cat "$work_dir/original"; printf '\n'; cat "$work_dir/market"; } >"$work_dir/candidate"
fi

docker exec -i "$ingress" caddy adapt --validate --config - --adapter caddyfile <"$work_dir/candidate" >/dev/null
probe() {
  local host="$1" path="$2"
  curl --fail --silent --show-error --connect-timeout 3 --max-time 5 \
    --resolve "$host:443:127.0.0.1" "https://$host$path" >/dev/null
}
probe nilx.one /
if [[ "$mode" == validate ]]; then
  echo 'Market ingress configuration and both private upstreams validated.'
  exit 0
fi

if ! cmp -s "$work_dir/original" "$work_dir/candidate"; then
  cmp -s "$work_dir/original" "$live" || { echo 'The live ingress changed during validation.' >&2; exit 1; }
  changed=true
  cat "$work_dir/candidate" >"$live"
  docker exec "$ingress" caddy reload --config /etc/caddy/Caddyfile
  probe nilx.one /
fi

for _ in $(seq 1 20); do
  if probe "$domain" /health && probe "$domain" /bot/health; then
    changed=false
    echo 'Market Core and Telegram bot answer over HTTPS on edge-dev-1.'
    exit 0
  fi
  sleep 2
done
echo 'Market HTTPS health did not pass.' >&2
exit 1
