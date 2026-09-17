# Shared edge cutover — historical note

The original shared-edge cutover was completed on **2026-07-29**. Earlier revisions hosted several unrelated workloads behind the same Caddy instance and used hardware/provider-coupled names such as `vps-spaceship-01`.

Those details are historical evidence only. They are not the current production contract.

## Current production model

```text
logical edge target: edge-prod-1
provider:            Hetzner
role:                public-edge
edge network:        nilx-edge
live Caddy container: mind-web-prod-1-caddy
managed workload:    mind-web
```

The current edge intentionally routes only:

```text
mind.aiaiaiai.org -> mind-web:8080
mind.nilx.one     -> mind-web:8080  (temporary legacy host)
```

`0xda-market`, its bot/web app, `infraBot`, and `nilx-one` are not part of this edge contract. Their availability must not block `mind-web` edge deployment.

## Current workflow

Static contracts and isolated routing are checked by CI. When a PR becomes ready for review, `.github/workflows/edge-ready-validate.yml` validates only its candidate Caddyfile against the running Caddy binary without changing the live configuration.

Production changes use `.github/workflows/deploy-edge.yml`. The selected GitHub ref is the deployment source. Before mutation the workflow verifies the two currently managed public mind hosts; after reload it verifies the same surfaces and restores the previous Caddyfile if activation fails.

The live workflow discovers the host-side `/etc/caddy/Caddyfile` mount from the running container and does not require the declarative `runtimeRoot` to exist.

## Credentials

The canonical GitHub Environment is `edge-prod-1`:

- `SSH_HOST`
- `SSH_USER`
- `SSH_PRIVATE_KEY`
- optional variable `SSH_PORT=22022`

## Current verification

```bash
docker exec mind-web-prod-1-caddy \
  caddy validate --config /etc/caddy/Caddyfile

curl -fsS https://mind.aiaiaiai.org/health
curl -fsS https://mind.nilx.one/health
```

The physical Caddy volume names may still contain historical product identifiers. They are retained to preserve existing TLS state and should not be renamed as part of a routing cleanup.

For exact historical cutover commands, use this file's Git history rather than executing old paths against the current production host.
