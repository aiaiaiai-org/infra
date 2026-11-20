<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# aiaiaiai.org snapshots on edge-dev-1

This is the isolated site migration **candidate**, not a deployed public origin.
`nilx.one` already owns public 80/443 on this VPS. Never run a second
public Caddy. The existing `nilx-public-edge-managed` ingress can proxy two
additional hosts to the independent private `aiaiaiai-site-archive` container
on the existing `nilx-candidate` Docker network.

## Routes

| Host/path | Meaning |
|---|---|
| `beta.aiaiaiai.org/` | latest activated beta |
| `beta.aiaiaiai.org/{full 40-char SHA}/` | immutable beta |
| `aiaiaiai.org/` | latest approved release, otherwise HTTP 302 to beta |
| `aiaiaiai.org/{vX.Y.Z}/` | immutable release |

The archive preserves full static site content and per-version assets under
`$HOME/.local/share/aiaiaiai-infra/aiaiaiai-site/versions`; each version has
a verified image-digest manifest outside the public root. Existing versions
with a different digest are rejected. Only `current` symlinks are mutable.
Preserve archive and manifests in VPS backups.

The public ingress config is in `deploy/nilx-public-edge/Caddyfile`. Changing
this file in Git **does not** update the running ingress; it requires a
separately authorized activation with rollback and TLS validation. The private
archive can be staged and tested without changing DNS or public routes.

## Deployment order and gates

1. Merge the website path-scoped build and release publisher, and freeze the
   legacy `edge-prod-2` site delivery (`mode: manual`) **before** the next
   master artifact is published.
2. Use a verified image digest whose CI output embeds
   `/<full SHA>/_astro/` or `/<tag>/_astro/`.
3. Stage a beta snapshot via the reviewed `Stage aiaiaiai snapshots`
   workflow. It verifies GHCR attestation, pinned SSH host identity, and
   makes no public listener.
4. Activate the private beta alias (a separate manual action), verify both
   `/{SHA}/` and the root via direct host matching on the server.
5. Independently activate the additional host routes on the existing 0x1
   ingress; preserve `nilx.one`, the old Caddy config and TLS volumes.
6. Verify TLS readiness and DNS records; cut over the two aiaiaiai hostnames
   only with explicit authorization. Verify root, snapshot assets, rollback,
   and no changes to `nilx.one`, `auth.aiaiaiai.org` (Railway), or Prism.
7. Publish an approved release tag separately. Stage, verify, and activate
   its immutable digest. Never promote unverified master to release.

The old `aiaiaiai-site` WorkloadContract remains on `edge-prod-2` for
rollback during migration and is set to manual delivery. It is not the new
archive workload. A later independent cleanup removes legacy routing only
after the new origin has been verified.

No merge, DNS change, rollout, or deployment is implied by this PR.
