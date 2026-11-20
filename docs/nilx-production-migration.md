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
- Do not reuse `edge-prod-1`: that name still identifies the old server
  serving the 0xda-market origin and legacy 0x1 dependencies.
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
5. The old `0xda-market.nilx.one` origin stays on the old VPS. Its Caddy
   currently uses `nilxone-web:1927` for point pages/assets. Preserve that
   backend or replace the Market route deliberately before removing it.

## Cloudflare DNS cutover

Before any change, run **Audit 0x1 DNS migration prerequisites** on
`master` (using the existing edge-prod-1 Environment). It uses GET only and
checks DNS records without printing origin IPs.

Required target after application readiness:

| Record | Content |
| --- | --- |
| `nilx.one` (zone apex, A) | `158.220.74.54` |
| `*.nilx.one` | proxied CNAME → `nilx.one` (unchanged) |
| `0xda-market.nilx.one` | exact A/CNAME to old origin, distinct from apex |
| `auth.aiaiaiai.org` | Railway, unchanged |

The current Infra `deploy/edge/cloudflare-wildcard.sh` ensures a **proxied
CNAME** `*.nilx.one → nilx.one`. Without an explicit Market record, moving
the apex would move Market too. Verify existing A, AAAA and CNAME records,
including any `www` record, in Cloudflare before changing the apex; do not
invent old-origin IP addresses.

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
5. Confirm `0xda-market.nilx.one` resolves to the *old* origin through its
   exact DNS record, with point pages and bootstrap working.
6. With separate owner authorization, update only the correct apex
   origin record in Cloudflare, preserving wildcard, Market and AIS.
7. Verify public HTTPS and session continuity, retain old server for
   rollback, then retire old 0x1 backends in separate changes.

**No production DNS update, data transfer, workload activation, merge or
deployment is performed by this document or audit workflow.**
