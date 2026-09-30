<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# edge-prod-2 — the aiaiaiai.org edge

`edge-prod-2` is the public edge of the parent organisation. It serves the
whole `aiaiaiai.org` domain and nothing else. `edge-prod-1` keeps `nilx.one`
(0x1, 0xda-market) and must never publish a host under `aiaiaiai.org`.

```text
Internet
└── edge-prod-2                          Hetzner, contracts/servers/edge-prod-2.yaml
    └── Caddy (host network)             contracts/edges/edge-prod-2.yaml
        └── hub.aiaiaiai.org/*  →  127.0.0.1:1927  prism-hub.service (systemd-release)
```

## Domain ownership

Every `EdgeContract` declares `spec.domains`. `scripts/validate-contracts.rb`
rejects, in CI and before every edge deployment:

- a route whose host is outside its edge's domains;
- a site address in the edge's Caddyfile (`spec.entrypoint.config`, with
  `{$VAR:default}` resolved to its default) outside its edge's domains;
- two edges claiming the same or nested domains (`aiaiaiai.org` and
  `prism.aiaiaiai.org` count as overlapping);
- a workload placed on more than one server.

Moving an `aiaiaiai.org` host to `edge-prod-1` therefore can't pass CI.
It has to be an explicit change to both edge contracts.

## Why host networking

Prism workloads are host-native Ruby releases (`runtime.kind: systemd-release`),
not containers. On this edge Caddy runs with `network_mode: host`, so every
upstream binds to **loopback only** and is never reachable from outside, even
without a firewall. The contract enforces that shape:

- a `systemd-release` workload routed by an edge declares `spec.listen:
  127.0.0.1:<port>` and `spec.health`;
- its route's `upstream` must equal that `listen` address;
- only a host-network edge (`network.driver: host`) may route to it, and
  container upstreams need a bridge edge;
- `listen` addresses are unique per server.

The Caddy admin API is disabled (`admin off`): on the host network it would
listen next to the workloads. Activation recreates the container and never
reloads it.

## Host prerequisites

Infra does not provision the machine. Before the first deployment:

1. **Firewall** (Hetzner Cloud Firewall): inbound `80/tcp`, `443/tcp`,
   `443/udp` and the SSH port only.
2. **Deploy user** (e.g. `deploy`) with SSH key access, membership in the
   `docker` group, and passwordless `sudo`. It needs sudo for:
   - Ruby provisioning;
   - `systemctl restart prism-hub.service`;
   - `systemd-run` for `hookEnvironment: service` hooks.
3. **Docker Engine** with the Compose plugin.
4. **PostgreSQL**, with the `prism_hub` database and role that `DATABASE_URL`
   points at. Migrations run on every activation; creating the database does
   not.
5. **Ruby 4.0.6**. The first release provisions it into `/opt/ruby/current`
   when it is missing.
6. **Hub runtime executables** on the service `PATH`: `prism-runtime`,
   `prism-mail`, `prism-porter`, `prism-signal-collect` and
   `prism-signal-runtime`, as referenced by the `*_COMMAND_JSON` variables.
7. **`/opt/prism-hub/shared/.env`**, owned by the deploy user and mode `600`.
   It uses systemd `EnvironmentFile=` syntax: no `export`, no `$(...)`, and
   anything with spaces or metacharacters goes in quotes. At minimum it holds:
   - `SECRET_KEY_BASE` and `DATABASE_URL`;
   - `PRISM_HUB_*`, `PRISM_*_COMMAND_JSON` and `HQBASE_ORIGIN`, per
     `prism-hub/.env.example`.

   Don't set `PORT` there: the unit binds explicitly.
8. **The unit**: install `deploy/edge-prod-2/prism-hub.service` as
   `/etc/systemd/system/prism-hub.service` (adjust `User=` if needed), then
   run `systemctl daemon-reload` and `systemctl enable prism-hub.service`. Don't
   start it yet: `current` does not exist before the first release.

## GitHub Environment `edge-prod-2`

| Kind | Name | Meaning |
| --- | --- | --- |
| secret | `SSH_HOST` | address of edge-prod-2 |
| secret | `SSH_USER` | the deploy user |
| secret | `SSH_PRIVATE_KEY` | its private key |
| secret | `CLOUDFLARE_API_TOKEN` | `Zone:Read` + `DNS:Edit` on `aiaiaiai.org` only (ACME DNS-01 and edge DNS records) |
| secret | `INFRA_DEPLOY_TOKEN` | only if container workloads ever land here |
| variable | `SSH_PORT` | SSH port; defaults to `22022` |
| variable | `EDGE_PUBLIC_IPV4` | public IPv4 the `aiaiaiai.org` hosts point at |
| variable | `EDGE_PUBLIC_IPV6` | optional; adds `AAAA` records |

## First activation order

1. Provision the host as above and create the `edge-prod-2` Environment.
2. **prism-hub**: run *Deploy production* in `aiaiaiai-org/prism-hub`. Infra
   resolves `edge-prod-2` from the contract and then, for the release:
   - validates it: `bin/rails zeitwerk:check` under the unit's environment;
   - migrates: `bin/rails db:migrate`, before `current` moves;
   - switches `current`, restarts the unit, and polls
     `http://127.0.0.1:1927/healthz`, rolling back if it never answers.
3. **Edge**: run *Deploy* in this repository with surface `aiaiaiai`. The
   workflow:
   1. uploads a release under `~/.local/share/aiaiaiai-infra/edge-prod-2/releases/<sha>`;
   2. validates the image, the Caddyfile, Compose and the loopback upstreams;
   3. ensures DNS-only `A`/`AAAA` records for every contracted host;
   4. recreates Caddy;
   5. verifies `https://hub.aiaiaiai.org/healthz` over public DNS/TLS.

   If the public check fails, the previous edge release comes back and the DNS
   records this run created are removed.

DNS is never overwritten. If a host already has an address record pointing
elsewhere, or is a CNAME, the run stops and says so. Repointing it is a
deliberate operator step.

## Not yet on this edge

- **`prism-hubot`** stays placed on `edge-prod-1` for now. Its public hook
  would be an `aiaiaiai.org` host, which `edge-prod-1` may not serve, so it
  moves in a follow-up change. That change adds `listen`/`health` to its
  contract, a route here, and the matching unit bind address.
- Hub background processes (`bin/prism-hub-delivery-worker`, the mail-digest
  and signal schedulers) need their own units. They are not public routes.
- The live candidate-validation workflow (`edge-ready-validate.yml`) still
  covers `edge-prod-1` only.
