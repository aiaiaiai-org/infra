<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# 0xda-market: production PostgreSQL on edge-prod-1

## Ownership and separation

- **TEST / development:** PostgreSQL hosted in the **0xda-market TEST Supabase project**. Its credentials remain outside production and are owned by the test application environment. A Supabase project must never be assumed active or healthy without checking it.
- **PRODUCTION / release:** **self-hosted PostgreSQL** on **edge-prod-1**, managed through this infra repository.
- No production data is sourced from, copied from, or restored from TEST by default. Market application migrations initialize the schema; product prices, inventory, accounts and broker roles are business state requiring deliberate production setup.
- The production database must never receive a publicly forwarded TCP port, Caddy route, or Cloudflare tunnel route.

The infrastructure workload is `market-postgres-production`: a digest-pinned PostgreSQL 18 image on the existing `nilx-edge` network, internal TCP port **1927**, DNS alias `market-postgres-production`, and persistent Docker volume `market-postgres-production-data`. The volume must not be pruned during application deploys, database restarts, release cleanup, or rollback.

## Deployment gate: do not activate until checked

1. Check edge-prod-1 disk capacity, Docker, available memory, and any existing Market production database/container/volume. **Do not overwrite or initialize an existing production dataset without a documented migration/restore plan.**
2. Verify compatibility of all `0xda-market/core` migrations (currently through `021`) with PostgreSQL 18 in an **isolated disposable database**. Core's Docker startup automatically executes `bin/migrate` before serving traffic. Its advisory-locked migration ledger does not make data-destructive SQL safe to roll back.
3. Establish an **encrypted off-host backup** to storage in a separate failure domain, with a recovery key kept outside the VPS/GitHub. Verify the first backup and a restore into a separate database. A persistent Docker volume alone is **not** a backup. The existing `prism-postgres` backup workflow covers Prism only; it does not back up Market.
4. **Secrets live only in Core's own `production` Environment** (`0xda-market/core`): `MARKET_POSTGRES_PASSWORD` (random, unique, never shared with TEST), `PUBLIC_API_TOKEN`, `MANUAL_PROVIDER_TOKEN` and `NILX_BROWSER_HANDOFF_TOKEN` (the same value as the 0x1 Identity service's). No token for infra exists or is needed: Core holds no credential for this repository, and infra holds none of Core's secrets ([automatic delivery](automatic-delivery.md), "Product secrets"). Never commit, print or paste a value.
5. **Core publishes; infra delivers.** Core's publish workflow runs in that Environment after its CI is green on `master`: it pushes `ghcr.io/0xda-market/core:<full SHA>`, writes exactly the names [`market-api-production`](../contracts/services/market-api-production.yaml) maps (`MARKET_DATABASE_URL`, `MARKET_POSTGRES_PASSWORD`, `PUBLIC_API_TOKEN`, `MANUAL_PROVIDER_TOKEN`, `NILX_BROWSER_HANDOFF_TOKEN`), deriving `MARKET_DATABASE_URL` (`postgres://market:<password>@market-postgres-production:1927/market`, password URL-encoded) from `MARKET_POSTGRES_PASSWORD` so the two can never drift, encrypts them with `age` to `edge-prod-1`'s `spec.encryptionRecipient` and pushes `ghcr.io/0xda-market/core:<full SHA>.secrets`, attesting both digests. In the package settings, give `aiaiaiai-org/infra` **Read**.
6. **Then, in one reviewed infra change:** add `delivery` (`image: ghcr.io/0xda-market/core`, `branch: master`, the publish workflow as `signerWorkflow`) to `market-api-production`, and `secretsFrom: market-api-production` to `market-postgres-production`. The database then takes `POSTGRES_PASSWORD` from Core's last delivered envelope and never from infra; without such an envelope Deploy workload stops. Do this only after step 5 publishes, because the delivery planner aborts on a missing or unreadable package.
   **Timing.** Merging this change lets **Reconcile deliveries** (every 15 minutes, at :07, :22, :37 and :52) deliver Core on its own as soon as Core has published its image and envelope. Core is unhealthy without its database, so do not merge until step 7's database is ready to be brought up by hand in the same window: merge just after a scheduled run and dispatch **Deploy workload** for the database at once. `secretsFrom` needs the producer to deliver automatically, so the two edits cannot merge separately.
7. **Order of activation.** The database comes first, but `secretsFrom` reads only an envelope from a *successful* Core delivery, and Core is not healthy without its database. So the first time, run **Deploy workload** by hand for `market-postgres-production` with `secrets_image` set to Core's envelope from step 5 by digest (`ghcr.io/0xda-market/core@sha256:…`, the `.secrets` tag of the commit about to be delivered); only the names this contract maps are taken from it. Later redeploys use Core's last successful delivery. Then verify `pg_isready` plus a minimal authenticated query from a disposable client on `nilx-edge`, verify the first backup and a restore (step 3), and only then let Core's delivery run. Core connects with the derived `DATABASE_URL` (its `DatabaseTarget` refuses a production URL without a password or pointing anywhere but `market-postgres-production:1927/market`), runs `bin/migrate` on start and serves on the contract port **1927**. Verify `/health` and an authenticated catalog read.
8. **Move the browser and issuer routes last.** Until then `deploy/edge/Caddyfile` sends `/nilx-browser/*`, `/v1/webapp/bootstrap` and `/issuer/v1/orders*` on the production host to `market-api-development`. Switch them to `market-api-production` in a separate reviewed edge change once production Core is healthy, together with the 0x1 Identity service that shares `NILX_BROWSER_HANDOFF_TOKEN`. Telegram's production runtime must point to `market-api-production:1927`. Activating Special for seeds (an active SKU in Market's catalog, Identity's issuer worker) stays a separate, authorized step.

Do not trigger database activation merely because infra CI passed. CI verifies contract structure, **not** backup/restore readiness, live host state, test-to-prod separation, or application/database compatibility.

## Database connectivity

```text
TEST Core (development) -----------------> Supabase 0xda-market TEST
PROD Core (edge-prod-1, nilx-edge) -----> market-postgres-production:1927
                                             |
                                             +-- Docker volume: market-postgres-production-data
```

Only internal containers on `nilx-edge` should be able to reach the production database. This shared network is an existing platform boundary, **not** per-product network isolation; PostgreSQL authentication remains mandatory. Consider a dedicated private Docker network for the database and its approved clients as a later hardening change; do not publish the DB port to compensate for connectivity problems.

Production is not ready for financial settlement just because `/health` returns 200: validate idempotency, migrations, FX, broker listings, reserve/commit logic, payment confirmation, admin permissions, payout controls and recovery before accepting real customer funds.

## Recovery expectations

- Record and preserve the image digest, deployed core/bot commit SHAs, and current backup ID before activation.
- Prefer restoring a previously verified backup into an **isolated** database first; never test restoration by truncating the live production database.
- Reverting a Core container or image does not reverse already-applied database migrations. Check schema compatibility before application rollback.
- Keep production and TEST database passwords, data, users and backup destinations separate.
