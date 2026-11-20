<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Controlled adoption of the sole-VPS nilx.one public ingress

The only available VPS is `edge-dev-1` (`158.220.74.54`).
The operator created `nilx-public-edge` manually using `caddy:2-alpine`,
serving the healthy private `nilxone-web-candidate` over HTTPS.
The certificate data already exists in the volumes
`nilx-public-edge-caddy-data` and `nilx-public-edge-caddy-config`.

The new workflow **Adopt existing nilx.one ingress on edge-dev-1**
is available only via manual dispatch from trusted Infra `master`.
It uses the existing pinned `edge-dev-1` SSH Environment,
not `INFRA_DEPLOY_TOKEN` and not the retired VPS.

- **validate** (default): stage reviewed files, verify the existing image,
  TLS volumes, private network and Web candidate digest, compare the live
  Caddy routes with the reviewed Caddyfile, and test trusted HTTPS.
  It does **not** stop any container.
- **activate**: requires confirmation `ACTIVATE` plus a separate
  production deploy authorization. Stops `nilx-public-edge`, starts
  `nilx-public-edge-managed` with the existing certificate volumes,
  and validates HTTPS. On failure the script attempts to restart the old
  ingress. The old container is retained for rollback. Expect a brief
  interruption while port 443 changes ownership.
- **rollback**: requires `ROLLBACK` and separate authorization; restarts
  the original Caddy, tests HTTPS, and attempts to restore the managed
  container if that rollback fails.

This workflow deliberately preserves the existing Web image digest
`ghcr.io/nilx-one/web@sha256:de655de0c264dfa5b589fa2513d57fe0e9168d02c92a298771e7181d2d609d90`.
It does **not** deploy the newer Web build, create a fresh Identity database,
move Cloudflare DNS or activate Market or Bot services.

**Partial recovery is not full 0x1 production readiness.**
The temporary apex route does not claim functioning Bond subdomains,
legacy Identity, valid sessions, Telegram, Discord, PMTiles terrain,
or Render-backed Market API handoffs.

The historical `edge-prod-1` placement in Infra is obsolete for 0x1
and must be corrected separately, together with identity and data boundaries.
Do not invoke the existing multi-upstream `deploy.yml` against the
nonexistent old server. Never delete the previous ingress container or
its TLS volumes while this handover/rollback is needed.
