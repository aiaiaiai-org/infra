#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Read-only check of the four configured Telegram-source cursors.
# No post bodies, subscriber data, chat identifiers or credentials are queried.
set -Eeuo pipefail
umask 077

for name in SSH_HOST SSH_USER SSH_PRIVATE_KEY SSH_PORT; do
  [[ -n "$(printenv "$name")" ]] || { echo "::error::Missing SSH credential $name" >&2; exit 78; }
done
[[ "$SSH_HOST" == "62.238.19.244" && "$SSH_USER" == "deploy" ]] ||
  { echo "::error::Unexpected production target" >&2; exit 78; }
[[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) ||
  { echo "::error::Invalid SSH port" >&2; exit 78; }

for command in ssh ssh-keyscan ssh-keygen; do
  command -v "$command" >/dev/null || { echo "::error::Missing $command" >&2; exit 78; }
done

ssh_dir="$(mktemp -d)"
trap 'rm -rf "$ssh_dir"' EXIT
printf '%s\n' "$SSH_PRIVATE_KEY" > "$ssh_dir/key"
chmod 600 "$ssh_dir/key"
ssh-keygen -y -P '' -f "$ssh_dir/key" >/dev/null
ssh-keyscan -T 10 -p "$SSH_PORT" -t ed25519 "$SSH_HOST" > "$ssh_dir/known_hosts" 2>/dev/null
test -s "$ssh_dir/known_hosts"
fingerprints="$(ssh-keygen -lf "$ssh_dir/known_hosts" -E sha256)"
[[ "$(printf '%s\n' "$fingerprints" | wc -l)" -eq 1 ]] ||
  { echo "::error::Unexpected SSH host key count" >&2; exit 1; }
actual="$(printf '%s\n' "$fingerprints" | awk '{print $2}')"
[[ "$actual" == "SHA256:B66nNmPvaJBwlsjKwqbr4/hEArInm8pAeJoaSqsMwmA" ]] ||
  { echo "::error::Production SSH fingerprint mismatch" >&2; exit 1; }

# A static SELECT, with no user-provided SQL fragments.
ssh -T -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$ssh_dir/known_hosts" -o ConnectTimeout=10 \
    -i "$ssh_dir/key" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
    'docker exec -i prism-postgres psql -X -U prism_hub -d prism_hub -At -F "|" -v ON_ERROR_STOP=1' \
    > "$ssh_dir/cursors" <<'SQL'
WITH configured(source_id) AS (
  VALUES
    ('telegram.channel:vanek_nikolaev'),
    ('telegram.channel:kpszsu'),
    ('telegram.channel:war_monitor'),
    ('telegram.channel:monitorwarr')
)
SELECT
  configured.source_id,
  CASE WHEN cursor.cursor IS NULL OR cursor.cursor = '' THEN 'missing' ELSE 'present' END,
  COALESCE(to_char(cursor.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '-'),
  COUNT(evidence.external_id) FILTER (WHERE evidence.published_at >= NOW() - INTERVAL '4 hours')
FROM configured
LEFT JOIN signal_source_cursors AS cursor ON cursor.source_id = configured.source_id
LEFT JOIN signal_evidence AS evidence ON evidence.source_id = configured.source_id
GROUP BY configured.source_id, cursor.cursor, cursor.updated_at
ORDER BY configured.source_id;
SQL

result=0
seen=0
while IFS='|' read -r source cursor updated recent; do
  case "$source" in
    telegram.channel:vanek_nikolaev|telegram.channel:kpszsu|telegram.channel:war_monitor|telegram.channel:monitorwarr) ;;
    *) echo "::error::Unexpected source in read-only query" >&2; exit 1 ;;
  esac
  [[ "$cursor" == present || "$cursor" == missing ]] ||
    { echo "::error::Invalid cursor status for $source" >&2; exit 1; }
  [[ "$recent" =~ ^[0-9]+$ ]] ||
    { echo "::error::Invalid evidence count for $source" >&2; exit 1; }
  ((seen+=1))
  if [[ "$cursor" == missing ]]; then
    echo "::error::$source has no ingestion cursor (last observed $updated, 4h reports $recent)" >&2
    result=1
  else
    echo "$source: cursor present, last ingest with posts $updated, 4h reports $recent"
  fi
done < "$ssh_dir/cursors"
[[ "$seen" -eq 4 ]] || { echo "::error::Expected four source rows, found $seen" >&2; exit 1; }

echo "Cursor presence is NOT proof of successful recent polling: inspect Hub signal scheduler logs for source failures."
exit "$result"
