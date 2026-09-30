#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# usage: cloudflare-dns.sh ensure   <state-file> <host>...
#        cloudflare-dns.sh rollback <state-file>
#
# ensure   points every host at this edge (A from EDGE_PUBLIC_IPV4, AAAA from
#          the optional EDGE_PUBLIC_IPV6) as DNS-only records. A host that
#          already has an address record elsewhere is never overwritten: moving
#          it is an explicit operator decision.
# rollback deletes only the records this run created.
set -Eeuo pipefail

mode="${1:-}"
state_file="${2:-}"
shift 2 || true
zone_name="${CF_ZONE_NAME:-}"
api="https://api.cloudflare.com/client/v4"
token="${CF_API_TOKEN:-}"

[[ -n "$state_file" ]] || { echo "state file is required" >&2; exit 2; }
command -v curl >/dev/null
command -v jq >/dev/null

cf() {
  curl --fail-with-body --silent --show-error \
    --header "Authorization: Bearer ${token}" \
    --header "Content-Type: application/json" \
    "$@"
}

case "$mode" in
  ensure)
    test -n "$token" || { echo "CF_API_TOKEN is required" >&2; exit 2; }
    [[ "$zone_name" =~ ^[a-z0-9.-]+$ ]] || { echo "CF_ZONE_NAME is required" >&2; exit 2; }
    [[ "${EDGE_PUBLIC_IPV4:-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "EDGE_PUBLIC_IPV4 is required" >&2; exit 2; }
    (( $# > 0 )) || { echo "at least one host is required" >&2; exit 2; }

    zone_id="$(cf "${api}/zones?name=${zone_name}&status=active&per_page=50" | jq -er '.result | select(length == 1) | .[0].id')"
    wanted=("A|${EDGE_PUBLIC_IPV4}")
    [[ -n "${EDGE_PUBLIC_IPV6:-}" ]] && wanted+=("AAAA|${EDGE_PUBLIC_IPV6}")

    echo '[]' > "$state_file"
    for host in "$@"; do
      [[ "$host" == "$zone_name" || "$host" == *".${zone_name}" ]] || { echo "$host is outside zone $zone_name" >&2; exit 1; }
      records="$(cf "${api}/zones/${zone_id}/dns_records?name=${host}&per_page=100")"

      if jq -e '[.result[] | select(.type == "CNAME")] | length > 0' <<<"$records" >/dev/null; then
        echo "$host is a CNAME; refusing to replace it" >&2
        exit 1
      fi

      for entry in "${wanted[@]}"; do
        IFS='|' read -r type content <<<"$entry"
        existing="$(jq -c --arg type "$type" '[.result[] | select(.type == $type)]' <<<"$records")"
        count="$(jq 'length' <<<"$existing")"

        if [[ "$count" == "0" ]]; then
          created="$(cf --request POST \
            --data "$(jq -nc --arg type "$type" --arg name "$host" --arg content "$content" \
              '{type:$type, name:$name, content:$content, ttl:1, proxied:false, comment:"aiaiaiai-org/infra edge-prod-2"}')" \
            "${api}/zones/${zone_id}/dns_records")"
          jq --arg zone "$zone_id" --arg id "$(jq -er '.result.id' <<<"$created")" --arg name "$host" --arg type "$type" \
            '. + [{zone_id:$zone, record_id:$id, name:$name, type:$type}]' "$state_file" > "$state_file.tmp"
          mv "$state_file.tmp" "$state_file"
          echo "created $type $host -> $content"
        elif [[ "$count" == "1" ]] && jq -e --arg content "$content" '.[0].content == $content' <<<"$existing" >/dev/null; then
          echo "$type $host already points at this edge"
        else
          echo "$type $host points elsewhere ($(jq -r '[.[].content] | join(", ")' <<<"$existing")); move it deliberately, then re-run" >&2
          exit 1
        fi
      done
    done
    ;;

  rollback)
    [[ -s "$state_file" ]] || exit 0
    test -n "$token" || { echo "CF_API_TOKEN is required" >&2; exit 2; }
    jq -c '.[]' "$state_file" | while read -r record; do
      cf --request DELETE "${api}/zones/$(jq -r '.zone_id' <<<"$record")/dns_records/$(jq -r '.record_id' <<<"$record")" >/dev/null
      echo "removed $(jq -r '.type + " " + .name' <<<"$record") created by this failed deployment"
    done
    ;;

  *)
    echo "mode must be ensure or rollback" >&2
    exit 2
    ;;
esac
