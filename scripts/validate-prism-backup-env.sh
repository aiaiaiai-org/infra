#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Validate offsite backup configuration before installing tooling, opening SSH,
# streaming database content or writing to remote object storage.
# Report variable NAMES only. Never echo credential values.
set -Eeuo pipefail

required=(
  SSH_HOST SSH_USER SSH_PRIVATE_KEY SSH_PORT
  BACKUP_S3_ENDPOINT BACKUP_S3_BUCKET BACKUP_S3_REGION BACKUP_AGE_RECIPIENT
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  GITHUB_RUN_ID GITHUB_RUN_ATTEMPT
)
missing=()
for name in "${required[@]}"; do
  value="$(printenv "$name" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    missing+=("$name")
  fi
done
if (( ${#missing[@]} > 0 )); then
  for name in "${missing[@]}"; do
    echo "::error::Missing backup configuration: $name" >&2
  done
  echo "::error::Set BACKUP_S3_* and BACKUP_AGE_RECIPIENT as Variables, backup S3 credentials as Secrets, in infra / Environment edge-prod-2." >&2
  exit 78
fi

# Validate public configuration shape before any external I/O. The backup
# script additionally checks its pinned SSH target, host key and S3 response.
if [[ ! "$BACKUP_S3_ENDPOINT" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?/?$ ]]; then
  echo "::error::BACKUP_S3_ENDPOINT must be an HTTPS origin" >&2
  exit 78
fi
if [[ ! "$BACKUP_S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  echo "::error::BACKUP_S3_BUCKET must be a valid bucket name" >&2
  exit 78
fi
if [[ ! "$BACKUP_S3_REGION" =~ ^[a-z0-9-]+$ ]]; then
  echo "::error::BACKUP_S3_REGION must be a region identifier" >&2
  exit 78
fi
if [[ "$BACKUP_AGE_RECIPIENT" == *$'\n'* || "$BACKUP_AGE_RECIPIENT" == *$'\r'* ]]; then
  echo "::error::BACKUP_AGE_RECIPIENT must be a single public-key line" >&2
  exit 78
fi

echo "Backup environment configuration: required values are present (not a backup or restore verification)"
