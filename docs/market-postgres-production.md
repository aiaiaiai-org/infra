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
4. Configure the **`0xda-market/core` GitHub `production` Environment** with secret `MARKET_POSTGRES_PASSWORD` (random, unique, not shared with TEST), secret `INFRA_DEPLOY_TOKEN` (permission to dispatch only to infra), and variable `INFRA_AGE_RECIPIENT` (the public SSH/age recipient for `infra` `edge-prod-1`). The Core workflow encrypts the DB password into a scoped `secrets_age` dispatch; only infra's SSH private key can decrypt it. **Do not put the Market database password in infra Environment secrets.** Infra retains `SSH_*` and only other deliberately infra-owned credentials. Never commit, print, or paste the password.
5. Configure the **production** Core runtime file `/opt/0xda-market/environments/production/shared/.env` with `DEPLOY_ENV=production` and a URL-encoded `DATABASE_URL` targeting **`market-postgres-production:1927/market`** with database user `market`. Its password must match the configured infra secret. Keep that file mode `0600`. Never use a Supabase hostname in the production URL.
6. Confirm the Core runtime's existing `PUBLIC_API_TOKEN`, `MANUAL_PROVIDER_TOKEN`, `EDGE_OWNER=infra`, and production-safe `ENABLE_MOCK_PAYMENT_PROVIDER=0`. Ensure the Telegram production runtime points to `market-api-production:10000`, not the test Core.
7. Merge this reviewed infra change **only after Full CI and deploy preflight**. After the Core workflow is merged, use Core's manually dispatched **Deploy Market PostgreSQL** workflow (type `RECOVERY_READY` only after a recovery drill). It sends an encrypted credential envelope to infra's **Deploy workload** flow for `market-postgres-production`. The image is pinned by the contract. Inspect the actual infra run and verify internal PostgreSQL readiness with `pg_isready` plus a minimal authenticated query from a disposable client on `nilx-edge`.
8. Deploy the compatible production Core release **after the database is healthy and its backup is verified**, then the matching Telegram Bot. Verify Core migrations, `/health`, complete WebApp bootstrap, `/bot/health`, authenticated catalog and Telegram webhook. Registration of the webhook and Mini App menu is a separate intentional external operation.

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
