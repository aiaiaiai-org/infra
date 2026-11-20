<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Fresh 0x1 Identity on the sole VPS

This is an **explicit clean start** on `edge-dev-1`, **not a restoration**
of the retired `edge-prod-1`. The owner no longer requires the legacy
`pub_dress` database for initial product access. This does not authorize
deleting old archives or claiming that historical Bonds, Avaia, seeds,
subscriptions or Relationship histories were recovered.

## Ownership and boundaries

- `4x-ais` at `auth.aiaiaiai.org` is the cross-product identity issuer.
  0x1 uses the public OIDC client `nilx-one`, pairwise subject and a
  product-owned profile/database. The product's profile must be created
  through the existing Core contract, not by guessing a private AIS ID.
- A new persistent Docker volume, `nilxone-identity-fresh-data`, holds
  `/data/identity.db` and is never confused with historical
  `nilxone-identity-data`. No old account or credential is imported.
- The host owns `NATIVE_AUTH_SECRET`, `PASSWORD_PEPPER` and
  `GITHUB_EVIDENCE_ENCRYPTION_KEY`. They are generated on first
  authorized activation, written once to mode-600 `runtime.env`, and
  never stored in GitHub Actions or printed.
- The current Identity binary also starts Telegram polling. Therefore
  `edge-dev-1` GitHub Environment must contain one valid
  `TELOXIDE_TOKEN` for **the 0x1 Telegram bot**. It must not be
  simultaneously polled by a different runtime. This is a necessary
  runtime dependency of the existing image, not a new AIS secret.
- `NILX_BROWSER_HANDOFF_TOKEN` and issuer queue settings are not
  configured. This bootstrap does **not** activate Market checkout,
  Telegram purchase settlement, or automated entitlement issuance.
- The container is private on `nilx-candidate` and has the
  `nilxone-identity` Docker alias expected by the current Web
  candidate's same-origin `/api/v1/` reverse proxy. No published host
  port and no Caddy/DNS modification.

## Manual delivery

Workflow: **Bootstrap fresh 0x1 Identity on edge-dev-1**, from
trusted Infra `master`.

1. `operation=validate`, empty `confirmation`: verify a
   provenance-attested, immutable 0x1 Identity image, pinned SSH host,
   existing Web/network, and absence of conflicting identity containers.
   It stages a script but creates no Identity volume/container/secret.
2. Only after **separate explicit deployment approval** and validation:
   `operation=activate`, `confirmation=FRESH_IDENTITY`. This writes
   first-use host secrets and starts the new container with its own
   persistent volume, using the real 0x1 bot token.
3. Verify `/api/v1/auth/aiaiaiai/config` reports `enabled: true`
   with issuer `https://auth.aiaiaiai.org`. Verify that
   `/api/v1/auth/native/context` no longer responds with proxy 502.
4. Manually test an AIS sign-in end-to-end, callback and profile
   provisioning before declaring authentication recovered. A green
   HTTP healthcheck is necessary but **not sufficient**.

The image source is pinned to `nilx-one/web` commit
`c7533e05f4c12b2a1d425cfb72fb717ec40b71f2` and verified
against `package-identity-service.yml` provenance. This workflow
does not update the obsolete `nilx-edge` production placement contract
or grant automatic delivery: those belong to a separate reviewed PR.

**Caution:** The current binary still exposes legacy native auth
routes as well as AIS client routes. Do not treat a fresh native
credential as a cross-product AIS identity or assert that any user has
recovered their old Bond. Follow up by closing native registration
for AIS-only onboarding once the existing product UX/contract is
reviewed. Never create fake provider bindings as a workaround.
