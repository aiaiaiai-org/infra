<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# aiaiaiai.org website on edge-prod-2

`aiaiaiai-site` is a static container workload owned by
`aiaiaiai-org/aiaiaiai.org`. Its container listens on `1927`, serves `/healthz`,
and joins `aiaiaiai-edge` on `edge-prod-2`. The apex host `aiaiaiai.org` routes
to it; `api.aiaiaiai.org` and all existing Prism/HUA paths remain independent.
There are no model services, databases, volumes or application secrets.

The product's Full CI builds the static site. Validate packages and smoke-tests
that output, then preserves the exact image artifact. The product's manual
**Publish verified image** workflow publishes that artifact without rebuilding.

## First activation

1. Merge the reviewed product and infra changes after their checks pass.
2. Publish the verified product image and retain its `ghcr.io/...@sha256:...`
   digest. Check the intended UI scope: the initial image is the safe blank
   baseline; Star Awakening remains development-only pending real runtime work.
3. With release authorization, run infra **Deploy workload**, selecting
   `aiaiaiai-site` and the immutable image digest. Placement is resolved from
   contracts; no SSH host or credentials are accepted from the product.
4. Confirm the workload's `/healthz` from the edge network before deploying
   **Deploy aiaiaiai edge**. DNS for `aiaiaiai.org` must resolve to edge-prod-2;
   the existing server Environment owns its SSH and private GHCR credentials.
5. Verify `https://aiaiaiai.org/healthz`, the root page and existing API routes.

Merging these files does not activate either the workload or the edge. Deploying
the edge before the workload is healthy would produce a 502/503 at the apex;
use the order above. No `www` alias or wildcard domain is implied.

For rollback, redeploy the previous verified digest through **Deploy workload**.
For a failed first rollout, restore the previous edge revision. Do not alter
other workloads or move SSH credentials into the website repository.
