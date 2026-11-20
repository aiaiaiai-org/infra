<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Production 0x1 migration — VPS and DNS

Goal: move the existing public `nilx.one` and Bond hosts to Contabo
`158.220.74.54`. **No `dev.nilx.one` deployment**. Keep the original
public URLs, paths and product sessions, with the old server available for
rollback.

## Identity and naming

- New host was bootstrapped as `edge-dev-1` (Ubuntu 24.04, SSH `deploy`);
  its pinned SSH preflight passed on 2026-11-20.
- It is **not yet a production host**. Adopt a distinct production name such
  as `edge-nilx-1` at migration, updating its OS hostname, Infra
  ServerContract, SSH preflight expectations and GitHub Environment together.
- Do not reuse `edge-prod-1`: that name still identifies the old public
  edge and legacy 0x1 dependencies. Core and Bot of 0xda-market are
  hosted on Render, not on this old VPS.
- The new server remains `provisioning` in Infra until the migration
  contracts, verified identity/data transfer and readiness gates are complete.

## What must move

1. Web, Telegram Mini App and Discord Activity clients, with
   **production port 1927** and their public paths.
2. `nilxone-identity`, or a compatibility-verified replacement. Its SQLite
   database resides on the old host in `nilxone-identity-data` as
   `/data/identity.db`. Transfer data and the **server-owned signing and
   password secrets** through a protected, verified, consistent backup/restore.
   Do not create a fresh identity store or reset secrets during cutover.
   AIS on Railway is not evidence that the legacy API has been migrated.
3. The Web PMTiles basemap and terrain data. Docker volumes are local to a
   host even when named identically. Validate style JSON, range requests and
   terrain URLs after transfer or independent bootstrap.
4. HTTPS for `nilx.one`, `*.nilx.one` Bond hosts, and the same-path
   `/telegram/`, `/discord/` and `/api/v1/` routing.
5. `0xda-market.nilx.one` is the Market page in the 0x1 world and must
   follow the 0x1 public ingress to the new VPS. Market Core and Bot remain
   on Render. Recreate and test the existing market-host paths (point
   pages/assets, bootstrap, API and checkout handoffs) against verified
   Render-backed services; do not accidentally proxy them to an old-VPS
   container or assume the Web image by itself implements those routes.
   In particular, Web's `/market-api/bootstrap` rewrite targets
   `https://0xda-market.nilx.one/v1/webapp/bootstrap`; the new edge must
   route that API path to the correct Render backend to avoid a proxy loop.

## Cloudflare DNS cutover

Before any change, run **Audit 0x1 DNS migration prerequisites** on
`master` (using the existing edge-prod-1 Environment). It uses GET only and
checks DNS records without printing origin IPs.

Required target after application readiness:

| Record | Content |
| --- | --- |
| `nilx.one` (zone apex, A) | `158.220.74.54` |
| `*.nilx.one` | proxied CNAME → `nilx.one` (unchanged) |
| `0xda-market.nilx.one` | Inherit wildcard to new 0x1 ingress, or use an exact record targeting that ingress |
| `auth.aiaiaiai.org` | Railway, unchanged |

The current Infra `deploy/edge/cloudflare-wildcard.sh` ensures a **proxied
CNAME** `*.nilx.one → nilx.one`. Moving the apex therefore also moves
`0xda-market.nilx.one` if it has no exact DNS record, which is intended:
its page is part of 0x1. If an exact record exists, verify it points to
the **new** 0x1 ingress rather than keeping the old origin. Verify
existing A, AAAA and CNAME records, including `www`, before cutover.
DNS alone does not verify Render API routing or session continuity.

Cloudflare proxied DNS normally has an automatic 300-second TTL. This does
not eliminate a transient cutover window; preserve old origin until rollback
is no longer needed.

## Cutover gates (not completed)

1. Record exact running image digests, Docker networks, volume presence,
   active Identity contract, old Market route and rollback image references
   from the old host. Existing `Debug identity workload` is read-only.
2. Stage new isolated host/network, TLS and production clients without
   moving DNS. Verify trusted image provenance and exact versions.
3. Consistently back up and restore Identity SQLite + server-owned secrets,
   using a documented write-freeze or other verified consistency mechanism.
   Compare non-sensitive integrity checks; keep secrets out of logs.
4. Confirm `https://nilx.one` semantics against the new origin *before*
   public traffic changes: Web, Telegram, Discord, Identity login and
   callbacks, Bond subdomains, PMTiles range reads and rollback.
5. Confirm `0xda-market.nilx.one` will resolve to the **new** 0x1
   ingress through the wildcard or a matching exact record. Test market
   point pages, bootstrap, Render Core/Bot endpoints, checkout and
   authentication handoffs on the new edge before cutover.
6. With separate owner authorization, update the correct apex origin
   record in Cloudflare. If Market has an exact DNS override, change
   that origin as part of the same coordinated cutover; preserve the
   wildcard CNAME and the unrelated Railway AIS DNS.
7. Verify public HTTPS and session continuity, retain old server for
   rollback, then retire old 0x1 backends in separate changes.

**No production DNS update, data transfer, workload activation, merge or
deployment is performed by this document or audit workflow.**

## Staged Web image verification (2026-11-20)

See [the internal Web candidate rollout](nilx-web-candidate.md).
It verifies the real signed Web image on the new VPS without public
ports and does **not** authorize moving DNS before Identity migration.
