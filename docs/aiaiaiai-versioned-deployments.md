# © 2026 aiaiaiai · aiaiaiai.org
# Versioned deployment contract — aiaiaiai.org

Status: migration implementation prepared; **not yet activated**. Historical
`edge-prod-2` routing remains in place until an approved origin cutover.

## Ownership and host

- `aiaiaiai-org/aiaiaiai.org` builds/test-attests exact immutable site images.
- `aiaiaiai-org/infra` controls snapshot staging, verification, alias activation,
  Caddy ingress, rollback, and eventual DNS cutover.
- New site origin: `edge-dev-1` (Contabo `158.220.74.54`), reusing
  the running `nilx-public-edge-managed` Caddy as a **shared listener**, with
  a separate `aiaiaiai-site-archive` container and read-only archive volume.
- Existing AIS on Railway, Prism/HUA on `edge-prod-2`, and `nilx.one`
  are not moved by this site migration.
- Workflows use only pinned `edge-dev-1` GitHub Environment SSH credentials,
  no source repository PAT.

## URL contract

| URL | Source and behavior |
| --- | --- |
| `https://beta.aiaiaiai.org/` | Latest automatically activated, verified master merge SHA |
| `https://beta.aiaiaiai.org/<full 40-character SHA>/` | Immutable verified master artifact |
| `https://aiaiaiai.org/` | Latest verified SemVer release tag |
| `https://aiaiaiai.org/<vX.Y.Z>/` | Immutable verified SemVer tag artifact |
| `https://aiaiaiai.org/` before first release | HTTP 302 to `https://beta.aiaiaiai.org` |

Short SHA aliases and SHA/tag subdomains are not part of this contract.

## Guarantees and restrictions

- `master` creates development candidates; it never activates a production
  release by itself.
- Full CI uses an Astro path-scoped build base (`/<SHA>` or `/<tag>`) so
  every historical snapshot loads its own immutable assets.
- Every staged version requires an image digest verified against its producer's
  attestation and signer workflow; an existing version with a different digest
  is rejected rather than overwritten.
- Once this delivery policy is approved and merged, Infra reconciles at most
  every 15 minutes (GitHub Actions schedule is best-effort). It stages attested
  versions and atomically updates `current` after private health checks.
- A newer master commit may never be replaced by a stale pending beta publish;
  an older SemVer tag may never automatically downgrade the release alias.
  Failed alias health checks restore the previous alias.
- Preserve archive and provenance manifest in backups; do not garbage-collect
  historical snapshots without a separate version retention and revocation
  decision.
- The old `aiaiaiai-site` automatic delivery on `edge-prod-2` is frozen
  with `delivery.mode: manual` during migration; the old origin remains
  available for rollback.
- Neither stage nor alias activation is a DNS cutover. The existing
  `nilx.one` ingress routes and certificate volumes must remain intact.

## Controlled rollout

1. Review and merge the site artifact PR, then the Infra migration PR, after
   Full CI and Caddy validation are green for their exact heads.
2. Ensure the site master image exists in GHCR by digest and the Infra GHCR
   package read permission is correct.
3. Once the automatic publication policy is approved, `Reconcile aiaiaiai
   site snapshots` polls the verified master merge commit artifact and all
   versioned releases, then stages and activates `current` aliases after
   successful checks. A manual dispatch with `channel=all` may trigger the
   same check earlier. Neither action changes public DNS.
5. Run `Adopt aiaiaiai.org ingress on edge-dev-1` with `validate`; only
   after separately approved cutover, use `activate` + `ACTIVATE`.
6. Verify pinned server TLS and origin response, then change only the
   Cloudflare `aiaiaiai.org` apex and `beta.aiaiaiai.org` DNS to the
   verified new origin. Check both A/AAAA records and existing exact CNAMEs;
   do not touch `auth.aiaiaiai.org` or the Prism hostnames.
7. Verify latest beta and full-SHA page, their own JS and CSS assets,
   canonical redirects, TLS, and that `nilx.one` still works.
8. After a release tag is pushed, Full CI builds the version-scoped artifact,
   the producer attests it, then Infra stages it without operator intervention
   and advances the release alias to the highest successfully verified SemVer.
   Confirm `aiaiaiai.org/` and `/<vX.Y.Z>/` are correct.
9. Keep the old site origin and the reviewed ingress rollback until
   post-cutover health and retention are accepted.

`Adopt aiaiaiai.org ingress` exposes an explicit `rollback` operation;
old-origin DNS restoration must be coordinated if necessary.

## Revocation

- States: active, superseded, quarantined, revoked.
- Identify affected digests using actual dependency/security evidence;
  version ordering alone cannot prove a version safe or affected.
- In a separately authorized remediation, withdraw affected routes, invalidate
  caches, preserve a minimal audit record, and revert mutable aliases to a
  verified safe digest or a maintenance response.
- Do not silently rebuild an old version to `fix` its immutable path.
  Do not assume that clients holding an old browser bundle are remediated.

No merge, deployment, release activation, DNS change or secret operation
has happened merely because this contract is committed.
