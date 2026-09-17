#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

mode="${1:-ensure}"
state_file="${2:-${CF_WILDCARD_STATE_FILE:-/tmp/nilx-wildcard-state.json}}"
zone_name="${CF_ZONE_NAME:-nilx.one}"
record_name="*.${zone_name}"
api="https://api.cloudflare.com/client/v4"
token="${CF_API_TOKEN:-}"

test -n "$token" || { echo "CF_API_TOKEN is required" >&2; exit 2; }
command -v curl >/dev/null
command -v jq >/dev/null

cf() {
  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --header "Authorization: Bearer ${token}" \
    --header "Content-Type: application/json" \
    "$@"
}

zone_id="$(
  cf "${api}/zones?name=${zone_name}&status=active&per_page=50" \
    | jq -er '.result | select(length == 1) | .[0].id'
)"

case "$mode" in
  ensure)
    records="$(cf "${api}/zones/${zone_id}/dns_records?name=${record_name}&per_page=100")"
    count="$(jq -r '.result | length' <<<"$records")"

    if [[ "$count" == "0" ]]; then
      created="$(
        cf \
          --request POST \
          --data "$(jq -nc --arg name "$record_name" --arg content "$zone_name" '{type:"CNAME", name:$name, content:$content, ttl:1, proxied:true}')" \
          "${api}/zones/${zone_id}/dns_records"
      )"
      record_id="$(jq -er '.result.id' <<<"$created")"
      jq -n \
        --arg zone_id "$zone_id" \
        --arg record_id "$record_id" \
        --arg record_name "$record_name" \
        '{created:true, zone_id:$zone_id, record_id:$record_id, record_name:$record_name}' \
        > "$state_file"
      echo "created proxied wildcard CNAME ${record_name} -> ${zone_name}"
      exit 0
    fi

    if [[ "$count" != "1" ]]; then
      echo "refusing to mutate ambiguous wildcard DNS state for ${record_name}" >&2
      exit 1
    fi

    if ! jq -e --arg zone "$zone_name" '
      .result[0].type == "CNAME"
      and .result[0].content == $zone
      and .result[0].proxied == true
    ' <<<"$records" >/dev/null; then
      echo "existing ${record_name} record does not match the required proxied CNAME; refusing to overwrite it" >&2
      exit 1
    fi

    record_id="$(jq -er '.result[0].id' <<<"$records")"
    jq -n \
      --arg zone_id "$zone_id" \
      --arg record_id "$record_id" \
      --arg record_name "$record_name" \
      '{created:false, zone_id:$zone_id, record_id:$record_id, record_name:$record_name}' \
      > "$state_file"
    echo "existing wildcard DNS already matches the required contract"
    ;;

  rollback)
    [[ -s "$state_file" ]] || exit 0
    created="$(jq -er '.created' "$state_file")"
    if [[ "$created" != "true" ]]; then
      echo "wildcard DNS pre-existed this deployment; leaving it unchanged"
      exit 0
    fi
    state_zone="$(jq -er '.zone_id' "$state_file")"
    record_id="$(jq -er '.record_id' "$state_file")"
    cf --request DELETE "${api}/zones/${state_zone}/dns_records/${record_id}" >/dev/null
    echo "removed wildcard DNS record created by this failed deployment"
    ;;

  *)
    echo "mode must be ensure or rollback" >&2
    exit 2
    ;;
esac
