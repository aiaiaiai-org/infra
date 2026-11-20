<!-- © 2026 aiaiaiai · aiaiaiai.org -->
# edge-dev-1 development placement

Host: Contabo VPS 158.220.74.54, Ubuntu 24.04 (noble). SSH user deploy.

This contract places only nilxone-web-development on edge-dev-1.
Its nilx-dev-edge Docker network is separate from nilx.one production on
edge-prod-1. Delivery mode is manual, never scheduled.

Development uses port 1703 and separate Identity and Market DNS aliases.
They deliberately do not resolve until isolated development services exist.
Unauthenticated static Web can work; authentication and Market bootstrap
will fail instead of using production sessions or purchase flows.

The existing Web map preparation creates a *host-local* Docker volume
nilxone-web-map-data. Volumes with that name on edge-prod-1 and edge-dev-1
are physically distinct. It prepares terrain only. Bootstrap the
regional basemap.pmtiles on edge-dev-1 independently; do not run the
production-only web basemap workflow for this target.

Rollout prerequisites:
- Web PR for WEB_PORT and isolated upstreams: Full CI, merge, signed GHCR image.
- Infra CI green, owner-approved merge.
- Create the Docker network on edge-dev-1 using:
  docker network inspect nilx-dev-edge >/dev/null 2>&1 ||
    docker network create nilx-dev-edge
- Explicitly dispatch Deploy workload for nilxone-web-development with the
  Web master image and source ref, then check the container health.
- Create dev.nilx.one A record pointing to 158.220.74.54 in Cloudflare.
- Activate a separate development Caddy edge on the new host; production
  edge deployment workflows MUST NOT be used for dev.

SSH preflight uses Environment edge-dev-1 with secrets SSH_HOST, SSH_USER,
SSH_PRIVATE_KEY, and vars SSH_PORT and SSH_HOST_ED25519_PUBKEY.

No merge, DNS write, image activation or server mutation is implied.
