<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# edge-prod-2: the aiaiaiai edge

`edge-prod-2` is the server for aiaiaiai.org: `prism-*` and other aiaiaiai services. It is
separate from `edge-prod-1`, which carries the 0x1 product (`nilx.one`), so load and failures on
one never reach the other.

```text
Internet
└── edge-prod-2
    └── Caddy (deploy/edge-aiaiaiai)
        └── api.aiaiaiai.org
            └── /prism-hub/* → prism-hub:1927   (prefix stripped)
                                  └── prism-postgres:1927   (not public)

Docker network: aiaiaiai-edge
```

| Contract | What it is |
| --- | --- |
| `contracts/servers/edge-prod-2.yaml` | the server, its public ports, and what runs on it |
| `contracts/edges/aiaiaiai-edge.yaml` | the edge: network `aiaiaiai-edge`, Caddy, the routes |
| `contracts/services/prism-postgres.yaml` | PostgreSQL 18, image pinned by digest, data on the `prism-postgres-data` volume |
| `contracts/services/prism-hub.yaml` | prism-hub, image `ghcr.io/aiaiaiai-org/prism-hub:<commit>` from its release |

## Before the first deployment

These are done once, by hand, outside this repository.

1. **A server.** A VPS with Docker Engine and the Compose plugin, SSH by key, ports 80/tcp,
   443/tcp, and 443/udp open.
2. **DNS.** `api.aiaiaiai.org` → the server's address. Caddy obtains its certificate over HTTP-01,
   so the record must resolve before the edge is activated.
3. **GitHub Environment `edge-prod-2`** in this repository, with:

   | Kind | Name | Value |
   | --- | --- | --- |
   | secret | `SSH_HOST` | the server |
   | secret | `SSH_USER` | the deploy user (in the `docker` group) |
   | secret | `SSH_PRIVATE_KEY` | its key |
   | variable | `SSH_PORT` | the SSH port, if not 22022 |
   | secret | `PRISM_POSTGRES_PASSWORD` | a long random string; the database is created with it and prism-hub connects with it |
   | secret | `PRISM_HUB_SECRET_KEY_BASE` | 64+ random characters |

   The container registry login the workload deployment uses (`GHCR_PULL_USER`,
   `INFRA_DEPLOY_TOKEN`) must also reach this Environment, as it does `edge-prod-1`'s.

A secret a contract names but the Environment lacks stops the deployment before anything changes.

## First deployment, in order

1. **Edge:** Actions → *Deploy aiaiaiai edge*, with *verify upstreams* **off**. This creates the
   `aiaiaiai-edge` network and starts Caddy. Nothing is routed yet, so nothing is verified.
2. **Database:** Actions → *Deploy workload*, workload `prism-postgres`, no image (the contract
   pins it). Healthy when its port accepts connections.
3. **prism-hub:** from prism-hub, *Deploy production* with the commit to release. It migrates the
   database before it serves.
4. **Edge again,** with *verify upstreams* **on**: prism-hub answers inside the network, and
   `https://api.aiaiaiai.org/prism-hub/healthz` answers from outside.

After that, each step is repeated only for what changed. A database image changes only through a
reviewed change to its contract.

## What stays by hand

- Backups of the `prism-postgres-data` volume. Nothing here takes them yet.
- Upgrading PostgreSQL across a major version: a new digest in the contract is not a migration.
