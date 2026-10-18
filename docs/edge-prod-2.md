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

1. **A server.** A VPS with Ubuntu 24.04 or Debian 12. If the provider has its own firewall (a
   Hetzner Cloud Firewall, for one), open 22022/tcp, 80/tcp, 443/tcp and 443/udp there too.

   Make a deploy key on your own machine; it never goes to the server, only its public half:

   ```sh
   ssh-keygen -t ed25519 -N '' -C 'infra deploy edge-prod-2' -f ~/.ssh/edge-prod-2-deploy
   ```

   Then prepare the server as root with `deploy/edge-aiaiaiai/bootstrap-server.sh`: Docker Engine
   and the Compose plugin, a `deploy` user in the `docker` group with that key, SSH on 22022 by
   key only, and a firewall with only SSH and the edge's ports.

   ```sh
   scp deploy/edge-aiaiaiai/bootstrap-server.sh root@<server>:
   ssh root@<server> "DEPLOY_PUBKEY='$(cat ~/.ssh/edge-prod-2-deploy.pub)' bash bootstrap-server.sh"
   ssh -i ~/.ssh/edge-prod-2-deploy -p 22022 deploy@<server> docker ps   # must work
   ssh -p 22022 root@<server> bash bootstrap-server.sh --finalize         # closes port 22
   ```

2. **DNS.** An `A` record `api.aiaiaiai.org` → the server's IPv4 address, and an `AAAA` record only
   if the server has IPv6. Caddy obtains its certificate over HTTP-01, so the record must resolve
   before the edge is activated. On Cloudflare, keep the record **DNS only** (grey cloud) for the
   first activation.
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

   With the GitHub CLI, the generated values go straight into the Environment and are never shown:

   ```sh
   repo=aiaiaiai-org/infra
   gh api -X PUT "repos/$repo/environments/edge-prod-2" >/dev/null
   gh secret set SSH_HOST        -R "$repo" --env edge-prod-2 --body '<server>'
   gh secret set SSH_USER        -R "$repo" --env edge-prod-2 --body deploy
   gh secret set SSH_PRIVATE_KEY -R "$repo" --env edge-prod-2 < ~/.ssh/edge-prod-2-deploy
   openssl rand -hex 32 | gh secret set PRISM_POSTGRES_PASSWORD   -R "$repo" --env edge-prod-2
   openssl rand -hex 64 | gh secret set PRISM_HUB_SECRET_KEY_BASE -R "$repo" --env edge-prod-2
   ```

   `PRISM_POSTGRES_PASSWORD` is read once, when the database volume is first created. Changing the
   secret later does not change the database's password.

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

## Backups and recovery

Encrypted logical backups to independent S3 storage are documented in
[`prism-postgres-backups.md`](prism-postgres-backups.md). The backup workflow must be
configured, merged and verified with an actual offsite restore drill before it can be
considered operational. This is not a substitute for PostgreSQL PITR.

## What stays by hand

- Provisioning private S3 storage, a separate recovery key, retention, and restore drills.
- Upgrading PostgreSQL across a major version: a new digest in the contract is not a migration.
