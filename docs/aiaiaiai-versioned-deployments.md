# © 2026 aiaiaiai · aiaiaiai.org
# Versioned deployment contract — aiaiaiai.org

Status: design contract; not yet activated. Production releases remain disabled.

## Ownership
- `aiaiaiai-org/aiaiaiai.org` produces and tests site artifacts.
- `aiaiaiai-org/infra` exclusively validates, activates, routes, revokes and rolls back deployments on `edge-prod-2`.
- No personal access token or `INFRA_DEPLOY_TOKEN` is required to invoke a reusable workflow via `workflow_call`.
- SSH credentials remain scoped to the deployment environment; do not assume that secrets from infra are automatically available to a workflow invoked in the caller repository's context. Validate the credential boundary before replacing `repository_dispatch`.

## Channels
- `master` is development, never production.
- `https://aiaiaiai.org/beta/` points to the latest **successfully activated and verified** master snapshot.
- `https://<sha>.beta.aiaiaiai.org/` identifies an immutable build of a full commit SHA. A short SHA alias may be exposed only when unique.
- `https://v<major>-<minor>-<patch>.aiaiaiai.org/` identifies a release snapshot (canonical SemVer `vX.Y.Z` in metadata).
- `https://aiaiaiai.org/` remains a temporary redirect to `/beta/` until a separately approved first release.

## Artifact invariants
- Build once; promote the exact digest, never rebuild a previous version.
- Record source repository, full SHA, image digest, build workflow run, activation time and security status.
- Do not point `/beta/` at a new snapshot until its health check succeeds.
- Every preview must serve its own assets, not mutable shared assets from `/beta/`.
- Preview hostname, DNS, TLS and Caddy routing must be verified before advertising URLs.

## Revocation
- Statuses: active, superseded, quarantined, revoked.
- Revocation identifies **all affected digests** using a verified affected-version range, dependencies and/or SBOM; version ordering alone is not proof.
- Block revoked digests from future activation, withdraw public routes, invalidate caches and move mutable aliases to a verified safe digest or maintenance response.
- Remove affected public artifacts only after preserving a minimal audit record (digest, SHA, reason, timestamp, advisory).
- Revocation does not imply that clients already holding a vulnerable bundle are remediated.

## Rollout order
1. Validate the existing `deploy-workload.yml` contracts, GitHub environment secrets and caller identity.
2. Add a tokenless reusable deployment entrypoint without bypassing environment protections.
3. Add immutable snapshot storage, manifest, wildcard DNS/TLS and host routing.
4. Add revocation enforcement and tests (including deny/redeploy and rollback).
5. Integrate the site workflow; merge commit becomes the first candidate snapshot after successful Full CI.
6. Activate development only. Production release requires separate authorization.

No deployment, secret removal or production route mutation is authorized by this document.
