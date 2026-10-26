# Prism PostgreSQL offsite backups

The production database is the `prism-postgres` container on `edge-prod-2`.
Its durable Docker volume is `prism-postgres-data`. A second copy on the same
VPS is **not** a disaster-recovery backup.

`.github/workflows/backup-prism-postgres.yml` produces a consistent custom-format
`pg_dump` once per day at **03:17 UTC** and on manual dispatch. A GitHub runner
streams it directly over pinned-key SSH, encrypts it with **age**, and uploads it
to an external S3-compatible bucket using TLS. No plaintext dump is persisted
on the VPS or the runner. An S3 `head-object` confirms the encrypted object
exists and has nonzero length.

## Before activation

1. Create a **private** S3-compatible bucket outside the VPS, ideally in a
   different failure domain. Hetzner Object Storage or another S3 provider
   can be used. Create a dedicated access key with permissions limited to the
   backup bucket (write objects and read object metadata). Use bucket versioning
   or an appropriate object-lock policy where supported. Configure lifecycle
   retention only after an initial restore drill; never rely solely on a local
   Docker volume. Do not expose objects publicly.

2. Create a **dedicated recovery keypair** on a trusted device. Keep its
   private part **off the VPS and outside GitHub**. For example, on a local
   machine with `ssh-keygen`:

   ```sh
   ssh-keygen -t ed25519 -a 100 -C 'prism backup recovery' -f "$HOME/.ssh/prism-backup-recovery"
   cat "$HOME/.ssh/prism-backup-recovery.pub"
   ```

   Enter a strong passphrase when prompted. The public `ssh-ed25519 ...` line
   is a valid age recipient. Store the private key in an independent encrypted
   recovery location as well; losing it
   makes the encrypted backups unreadable. Never reuse the GitHub Actions
   deployment SSH key for backup recovery.

3. Configure the **`aiaiaiai-org/infra` → `edge-prod-2` Environment**:

   | Kind | Name | Value |
   | --- | --- | --- |
   | Existing secret | `SSH_HOST` | `62.238.19.244` |
   | Existing secret | `SSH_USER` | `deploy` |
   | Existing secret | `SSH_PRIVATE_KEY` | Working deploy SSH private key |
   | Existing variable | `SSH_PORT` | `22` |
   | Variable | `BACKUP_S3_ENDPOINT` | S3 HTTPS endpoint URL, e.g. provider's region endpoint |
   | Variable | `BACKUP_S3_BUCKET` | Private backup bucket name |
   | Variable | `BACKUP_S3_REGION` | Provider's actual S3 region |
   | Variable | `BACKUP_AGE_RECIPIENT` | Public age/SSH ED25519 recipient |
   | Secret | `BACKUP_S3_ACCESS_KEY_ID` | S3 access-key ID |
   | Secret | `BACKUP_S3_SECRET_ACCESS_KEY` | S3 secret access key |

   The PostgreSQL password is **not exported** and is not needed by the backup
   runner. `pg_dump` runs inside the existing database container under the
   database's established local authentication configuration.

4. With the backup workflow on `master`, run
   **Actions → Backup Prism PostgreSQL → Run workflow** manually on `master`.
   Check that the job succeeds, including its remote `pg_dump`, encrypted S3
   upload, and S3 object metadata validation. Until then, daily backups are
   **not confirmed active**. The scheduled job runs only from `master`.

## Resolve the current missing-configuration blocker (October 2026)

The production `Backup Prism PostgreSQL` workflow failed on both **25 and
26 October 2026** before reading the database: the `edge-prod-2` Environment
had no `BACKUP_S3_ENDPOINT`. Workflow logs also showed blank
`BACKUP_S3_BUCKET`, `BACKUP_S3_REGION` and `BACKUP_AGE_RECIPIENT`.
These are absent configuration, **not** failures in PostgreSQL.

If using Hetzner Object Storage in the existing Hetzner account:

1. In [Hetzner Console](https://console.hetzner.com), select the intended
   project → **Object Storage → Create Bucket**. Select **Private**,
   optionally enable object locking when creating the bucket (it cannot be
   added afterward), and note the bucket's globally unique name and location.
   Creating Object Storage has a monetary cost: check current pricing first.
2. In **Security → S3 Credentials**, generate S3 keys for this purpose. A key
   can access all buckets in the same project by default; prefer a dedicated
   project or [restrict permissions](https://docs.hetzner.com/storage/object-storage/faq/s3-credentials/)
   with a bucket policy. Store the generated secret securely: it is not
   retrievable from Hetzner Console after closing its display.
3. On a trusted device, generate a **new independent recovery keypair** as in
   the "Before activation" section. Keep the private key off GitHub, off
   `edge-prod-2` and outside the S3 bucket; store an independent encrypted
   recovery copy. Only its *public* key belongs in the GitHub Variable.
4. In **[infra → Settings → Environments → edge-prod-2](https://github.com/aiaiaiai-org/infra/settings/environments)**,
   configure the following *Variables* (example for a bucket created in
   Falkenstein; use the corresponding `nbg1` or `hel1` values otherwise):

   | Variable | Value |
   | --- | --- |
   | `BACKUP_S3_ENDPOINT` | `https://fsn1.your-objectstorage.com` |
   | `BACKUP_S3_BUCKET` | *The actual private bucket's name* |
   | `BACKUP_S3_REGION` | `fsn1` |
   | `BACKUP_AGE_RECIPIENT` | *Only the dedicated age/SSH public key* |

   Configure these *Secrets* in that **same Environment**:

   | Secret | Value |
   | --- | --- |
   | `BACKUP_S3_ACCESS_KEY_ID` | *The newly generated S3 access key* |
   | `BACKUP_S3_SECRET_ACCESS_KEY` | *Its matching secret key* |

   Do not paste credentials into PRs, issues, or chat. These are Environment
   settings, **not** organization-wide secrets and **not** variables in the
   `prism-hub` repository.

5. Run **infra → Actions → Backup Prism PostgreSQL → Run workflow** on
   `master`. The preflight now reports *all missing names* in a single failure
   before installing dependencies, reading the database, or writing data.
   A passing preflight alone does not mean any backup has occurred.
6. Confirm the complete run, including a nonempty encrypted object in the
   bucket, then perform the isolated **restore drill below**. Close the
   incident only once both checks are recorded.

**Do not use** the VPS deploy SSH key as an age recovery key, store an
unencrypted SQL dump in GitHub artifacts, or disable the backup gate to
declare the civilian-alert system production-ready.

## Restore drill — required before relying on backups

Test in a **separate isolated PostgreSQL 18 database**, not production.
Download one `*.dump.age` object from S3 to a secure machine that holds the
recovery private key. With `age` and PostgreSQL client tools installed:

```sh
# Check decryption and custom-dump readability, without writing a plaintext dump:
age -d -i "$HOME/.ssh/prism-backup-recovery" backup.dump.age | pg_restore --list >/dev/null
```

Then **restore into a freshly created staging database**, verify schema and
representative records, and document restoration duration and result. Example
only, after provisioning an isolated staging PostgreSQL and an empty staging DB:

```sh
age -d -i "$HOME/.ssh/prism-backup-recovery" backup.dump.age |
  pg_restore --no-owner --no-acl --exit-on-error --dbname='postgresql://STAGING_HOST/prism_hub_restore'
```

Never use a production `DATABASE_URL` in a restore test; verify the destination
before executing. Do not claim recoverability from `head-object` alone: it
confirms upload, not content validity or successful data restoration.

## Operations

- **Failure visibility:** the workflow fails nonzero if SSH identity, host
  fingerprint, `pg_dump`, encryption, upload, or object confirmation fails.
  Inspect Actions failures; alert delivery depends on the repository's GitHub
  notification settings.
- **Retention:** maintain an explicit bucket lifecycle policy after the restore
  drill. Avoid automatic deletion in the backup script itself.
- **Security:** S3 credentials have no database login and no SSH access.
  The age recovery private key is never uploaded to S3, the VPS, or GitHub.
- **Failure model:** daily logical backups offer a recovery point no newer than
  the last successful run, not point-in-time recovery (PITR). More frequent
  backups/WAL archiving can be added if requirements justify them.
- **Limitations:** GitHub-hosted runner and remote S3 are both required to be
  available at scheduled time. A healthy GitHub Actions run is not a guarantee
  of future successful schedules.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
