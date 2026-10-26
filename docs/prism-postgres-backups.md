# Prism PostgreSQL offsite backups

The production database is the `prism-postgres` container on `edge-prod-2`.
Its durable Docker volume is `prism-postgres-data`. A second copy on the same
VPS is **not** a disaster-recovery backup.

Paid S3 backups are **not activated** for the first h-ua-bot release, by the
project owner's decision on 26 October 2026. No scheduled backup runs.
The optional `.github/workflows/backup-prism-postgres.yml` workflow can
produce a consistent custom-format `pg_dump` **only on manual dispatch**,
after configuring an external destination and independent recovery keypair. A GitHub runner
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

4. If the owner later opts in, run
   **Actions → Backup Prism PostgreSQL → Run workflow** manually on `master`.
   Check that the job succeeds, including its remote `pg_dump`, encrypted S3
   upload, and S3 object metadata validation. Until then, daily backups are
   **not confirmed active**. The workflow has no schedule.

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
- **Failure model:** manually triggered logical backups offer a recovery point as old as
  the last successful run, not point-in-time recovery (PITR). More frequent
  backups/WAL archiving can be added if requirements justify them.
- **Limitations:** GitHub-hosted runner and remote S3 are required for any manual run.
  Nothing is automatically scheduled, and backup recoverability has not been verified.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
