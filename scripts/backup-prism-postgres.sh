#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Logical, encrypted offsite backup. No plaintext dump is written to the runner or VPS.
set -Eeuo pipefail

# Run the same fail-closed preflight as the GitHub workflow even when invoked
# directly. No database contents are read while a configuration value is missing.
bash "$(dirname "$0")/validate-prism-backup-env.sh"

# This backup belongs to the verified edge-prod-2 host and deploy identity only.
[[ "$SSH_HOST" == '62.238.19.244' && "$SSH_USER" == 'deploy' ]] ||
  { echo '::error::Unexpected SSH backup target' >&2; exit 78; }
[[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) ||
  { echo '::error::Invalid SSH_PORT' >&2; exit 78; }
[[ "$BACKUP_S3_ENDPOINT" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?/?$ ]] ||
  { echo '::error::BACKUP_S3_ENDPOINT must be an HTTPS origin' >&2; exit 78; }
[[ "$BACKUP_S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
  { echo '::error::Invalid BACKUP_S3_BUCKET' >&2; exit 78; }
[[ "$BACKUP_S3_REGION" =~ ^[a-z0-9-]+$ ]] ||
  { echo '::error::Invalid BACKUP_S3_REGION' >&2; exit 78; }
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]] ||
  { echo '::error::Invalid run identity' >&2; exit 78; }

for command in ssh ssh-keyscan ssh-keygen age aws; do
  command -v "$command" >/dev/null ||
    { echo "::error::Missing executable: $command" >&2; exit 78; }
done

# Validate encryption recipient before acquiring any database data.
age -r "$BACKUP_AGE_RECIPIENT" </dev/null >/dev/null

ssh_dir="$(mktemp -d)"
trap 'rm -rf "$ssh_dir"' EXIT
chmod 700 "$ssh_dir"
printf '%s\n' "$SSH_PRIVATE_KEY" > "$ssh_dir/key"
chmod 600 "$ssh_dir/key"
ssh-keygen -y -P '' -f "$ssh_dir/key" >/dev/null
ssh-keyscan -T 10 -p "$SSH_PORT" -t ed25519 "$SSH_HOST" > "$ssh_dir/known_hosts" 2>/dev/null
test -s "$ssh_dir/known_hosts"
chmod 600 "$ssh_dir/known_hosts"

# A keyscan is NOT trust: pin the previously verified SSH ED25519 host fingerprint.
fingerprints="$(ssh-keygen -lf "$ssh_dir/known_hosts" -E sha256)"
[[ "$(printf '%s\n' "$fingerprints" | wc -l)" -eq 1 ]] ||
  { echo '::error::Unexpected host key count' >&2; exit 1; }
actual="$(printf '%s\n' "$fingerprints" | awk '{print $2}')"
[[ "$actual" == 'SHA256:B66nNmPvaJBwlsjKwqbr4/hEArInm8pAeJoaSqsMwmA' ]] ||
  { echo '::error::SSH host fingerprint mismatch' >&2; exit 1; }

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_key="prism-postgres/${timestamp:0:4}/${timestamp:4:2}/${timestamp:6:2}/${timestamp}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.dump.age"

# pg_dump -Fc is transactionally consistent, unlike copying a live PGDATA directory.
# Pipe directly through age into offsite S3; pipefail prevents a truncated dump from
# being reported as successful when SSH, pg_dump, age, or aws fails.
ssh -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$ssh_dir/known_hosts" \
    -o ConnectTimeout=10 \
    -i "$ssh_dir/key" \
    -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
    'test "$(docker inspect -f "{{.State.Running}}" prism-postgres)" = true &&
     exec docker exec prism-postgres pg_dump --username=prism_hub --dbname=prism_hub --format=custom --no-owner --no-acl' |
  age -r "$BACKUP_AGE_RECIPIENT" |
  aws --region "$BACKUP_S3_REGION" --endpoint-url "$BACKUP_S3_ENDPOINT" \
    s3 cp - "s3://$BACKUP_S3_BUCKET/$backup_key" --only-show-errors

bytes="$(aws --region "$BACKUP_S3_REGION" --endpoint-url "$BACKUP_S3_ENDPOINT" \
  s3api head-object --bucket "$BACKUP_S3_BUCKET" --key "$backup_key" \
  --query ContentLength --output text)"
[[ "$bytes" =~ ^[1-9][0-9]*$ ]] ||
  { echo '::error::Backup object was not confirmed in offsite storage' >&2; exit 1; }

echo "Encrypted backup uploaded and confirmed: s3://$BACKUP_S3_BUCKET/$backup_key ($bytes bytes)"
