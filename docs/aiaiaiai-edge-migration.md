<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Moving the aiaiaiai edge from edge-prod-2 to edge-dev-1

edge-dev-1 is the only server left and `api.aiaiaiai.org` already resolves to it, while the data and
secrets of the aiaiaiai edge are still on edge-prod-2. PostgreSQL there has **no backup** (offsite backups
were deliberately not activated), so the first step is to get everything off that server in a form
that can be checked, before anything is switched.

What is on edge-dev-1 already: the 0x1 ingress `nilx-public-edge-managed` owns public ports 80 and 443
(the provider firewall allows 22, 80 and 443), next to the site archive and 0x1 workloads. There is no
Docker Compose plugin. So the aiaiaiai hosts are added to that ingress (see
[`aiaiaiai-snapshots-edge-dev-1.md`](aiaiaiai-snapshots-edge-dev-1.md): never a second public Caddy), and
workloads run with `deploy/workload/deploy.sh`.

## Step 1: sealed export (this change)

Run **Export aiaiaiai edge for migration** (manual, type `EXPORT`). Three jobs:

1. **Recipient** (Environment `edge-dev-1`): derives the public half of edge-dev-1's deploy key.
2. **Export** (Environment `edge-prod-2`): over SSH, pinned to the server's host fingerprint, seals with age
   while streaming, so no plaintext touches a disk on either server or on the runner:
   - `postgres-globals` (roles) and one `db-<name>` custom-format `pg_dump` per application database;
   - `secrets`: only the environment names each workload contract declares under `spec.runtime.secrets`
     (`prism-postgres`, `prism-hub`, `prism-hubot`, `h-ua-bot`, `4x-ais`, `4x-errors`). Values are registered for
     log masking first and are never printed; the log shows names and set/empty/missing counts only;
   - `volume-prism-hubot-state` and `volume-4x-ais-data`, read-only and without network, at most 256 MiB each.
   `manifest.json` lists each item's ciphertext and plaintext hash and size. Only the ciphertext and the
   manifest are uploaded (artifact `aiaiaiai-migration-export-<run id>`, kept 3 days).
3. **Open and check** (Environment `edge-dev-1`): decrypts with edge-dev-1's identity, compares every
   item with the manifest, checks a database item is a PostgreSQL custom-format dump and a volume is a tar, and
   prints the workloads and secret **names** in `secrets`. This proves the recipient and the data before any import.

Nothing on edge-prod-2 is stopped, changed or removed. `4x-ais` declares no secrets in its contract (its
credentials arrive in its own producer envelope), so none are taken from it.

## What the export does not do

- It does not write any GitHub secret. Producers seal their own secrets from their own Environment (for
  example prism-hubot's `production`), and that Environment still has to hold the values.
- It does not restore, start, route or switch anything. Import and restore on edge-dev-1, the contracts
  and ingress routes for edge-dev-1, and the DNS cutover are separate, separately authorized changes.
