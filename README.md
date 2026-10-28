# infra

Canonical infrastructure contract for the `aiaiaiai-org` public edge.

This repository owns the edge target, public ports, Caddy routing, deployment validation, activation, public verification, and rollback. Product repositories own their application runtime, data, secrets, images, and release lifecycle.

## Standard workload ports

See [`docs/workload-ports.md`](docs/workload-ports.md) for the normative workload-port policy and contract rules.

`aiaiaiai-org/infra` reserves the workload ports by deployment class:

| Deployment class | Container port | Rule |
| --- | ---: | --- |
| Test | `1703` | All test workloads use `*:1703` by default |
| Production | `1927` | All production workloads use `*:1927` by default |

The port is part of the workload contract. Product repositories must not invent a deployment-specific port unless the infra contract is intentionally changed. Edge upstreams and workload contracts must always agree. Test and production ports are deliberately distinct.

## Edges

Each product contour has its own edge: one server, one Docker network, one Caddy. A workload joins
the network of the edge on the server it is placed on, and an edge routes only to its own workloads.

| Edge | Server | Network | Serves | Contract |
| --- | --- | --- | --- | --- |
| 0x1 | `edge-prod-1` | `nilx-edge` | `nilx.one`, `0xda-market.nilx.one` | [`contracts/edges/nilx-edge.yaml`](contracts/edges/nilx-edge.yaml) |
| aiaiaiai | `edge-prod-2` | `aiaiaiai-edge` | `aiaiaiai.org`, `api.aiaiaiai.org`, Prism services, `h-ua-bot` | [`contracts/edges/aiaiaiai-edge.yaml`](contracts/edges/aiaiaiai-edge.yaml) |

**Product placement policy:** workloads from `nilx-one/*` and `0xda-market/*` run only on `edge-prod-1`; workloads from `aiaiaiai-org/*` and `0x0sky/h-ua-bot` run only on `edge-prod-2`. The explicitly contracted `0x0sky/trading-lab` is a Market workload on `edge-prod-1`; infrastructure-owned PostgreSQL workloads follow their product (`market-postgres-production` on `edge-prod-1`, `prism-postgres` on `edge-prod-2`). `aiaiaiai-org/infra` orchestrates both edges but is not itself an application workload. CI enforces these boundaries.

The sections below up to **Workload deployment** describe the 0x1 edge. The aiaiaiai edge, and how
to bring `edge-prod-2` up, is [`docs/edge-prod-2.md`](docs/edge-prod-2.md).

## Current production model

```text
edge target:       edge-prod-1
role:              public-edge
provider:          Hetzner
edge network:      nilx-edge
live Caddy:        edge-prod-1-caddy
```

`edge-prod-1` is a logical infrastructure identity. It intentionally does not encode a hardware class, provider, or product name.

## Architecture

```text
Internet
└── edge-prod-1
    └── Caddy: edge-prod-1-caddy
        ├── 0xda-market.nilx.one
        │   ├── /bot-test/* → market-bot-development:1703
        │   ├── /bot/*      → market-bot-production:1927
        │   └── /*           → market-api-production:1927
        └── nilx.one
            ├── /telegram/* → nilxone-telegram:1927
            ├── /discord/*  → nilxone-discord:1927
            └── /*           → nilxone-web:1927

external Docker network: nilx-edge
```

`nilx.one` is the canonical public Web host for 0x1, split by path prefix across three workloads. `0x1.nilx.one` is not an active edge host; introducing it later requires working public DNS and an explicit edge-contract change before Caddy may manage TLS for it.

The shared edge routes six workload identities: `market-api-production`, `market-bot-production`, `market-bot-test`, `nilxone-web`, `nilxone-telegram`, `nilxone-discord`. Development `0xda-market` core is intentionally not public; `0xda-market-test` reaches `market-api-development:10000` directly over `nilx-edge`. `0xda-market` DNS is already pointed at `edge-prod-1`, but the workload itself has not been implemented yet — its contract and routes exist ahead of that build.

## Ownership boundary

| Concern | `aiaiaiai-org/infra` | Product repository |
| --- | --- | --- |
| Edge target and public ports | owns | consumes |
| Caddy and automatic TLS | owns | does not configure |
| Public host/path routing | owns | declares requirement |
| External `nilx-edge` network | defines contract | joins with stable alias |
| Workload image/container | does not own | owns |
| Application secrets/data | does not store | owns |
| Product release lifecycle | does not own | owns |
| Edge validation/activation/rollback | owns | does not perform |

Current workload owners:

- `market-api-production` → `0xda-market/core`;
- `market-bot-production` → `0xda-market/telegram-bot` (`0xda-market`);
- `market-bot-test` → `0xda-market/telegram-bot` (`0xda-market-test`);
- `nilxone-web`, `nilxone-telegram`, `nilxone-discord` → `nilx-one/web` (`0x1`).

## Contracts

The server contract is [`contracts/servers/edge-prod-1.yaml`](contracts/servers/edge-prod-1.yaml). It exposes `80/tcp`, `443/tcp`, and `443/udp`.

The route registry of this edge is [`contracts/edges/nilx-edge.yaml`](contracts/edges/nilx-edge.yaml). Workload contracts live under [`contracts/services`](contracts/services).

Public routes:

| Public route | Upstream | Prefix behavior |
| --- | --- | --- |
| `https://0xda-market.nilx.one/bot/*` | `market-bot-production:1927` | strip `/bot` |
| `https://0xda-market.nilx.one/bot-test/*` | `market-bot-development:1703` | strip `/bot-test` |
| `https://0xda-market.nilx.one/*` | `market-api-production:1927` | preserve |
| `https://nilx.one/telegram/*` | `nilxone-telegram:1927` | strip `/telegram` |
| `https://nilx.one/discord/*` | `nilxone-discord:1927` | strip `/discord` |
| `https://nilx.one/*` | `nilxone-web:1927` | preserve |

The two market bot prefixes must be evaluated before the market API fallback, and the `/telegram` and `/discord` prefixes must be evaluated before the `nilxone-web` fallback.

A public route is an activation dependency only when its surface is selected for the current edge activation. An unrelated product outage must remain observable without blocking another product's otherwise valid edge change.

## Edge configuration

Runtime-independent assets live under [`deploy/edge`](deploy/edge):

```text
deploy/edge/
├── Caddyfile
├── check-public.sh
├── check-upstreams.sh
├── compose.yaml
├── deploy.sh
├── env.example
└── verify.sh
```

Environment contract:

```env
EDGE_TARGET=edge-prod-1
MARKET_DOMAIN=0xda-market.nilx.one
NILX_WEB_DOMAIN=nilx.one
EDGE_NETWORK=nilx-edge
```

## GitHub Environment

Production edge credentials belong to GitHub Environment `edge-prod-1`.

Required secrets:

- `SSH_HOST`
- `SSH_USER`
- `SSH_PRIVATE_KEY`
- `CLOUDFLARE_API_TOKEN`

Optional variable:

- `SSH_PORT=1927`

The deployment workflow uses `1927` when `SSH_PORT` is not set. A dedicated test environment may override the same variable with `1703`; the workload ports described above remain a separate application-level contract.

## Delivery gates

### CI

`.github/workflows/ci.yml` runs on pull requests and manual dispatch only. It validates YAML contracts, shell syntax, Compose, Caddy, and an isolated routing fixture containing all active upstream identities. It proves the market API fallback, both stripped Telegram/Discord prefixes, and the canonical 0x1 Web host resolve to the intended upstreams.

### Live candidate validation

`.github/workflows/edge-ready-validate.yml` runs for ready pull requests using trusted workflow code from `master`. It fetches only the candidate `deploy/edge/Caddyfile` from the PR head SHA and validates it inside the running Caddy container without reload or live mutation. On a target where the shared Caddy container doesn't exist yet (first-ever activation), the live-cutover-prerequisites check is skipped rather than failing.

### Deployment workflow

`.github/workflows/deploy.yml` is manual and uses one workflow with an explicit deployment-surface selector:

- `nilx-web` — deploys and verifies only the `nilx-web` edge surface and owns the nilx wildcard DNS lifecycle;
- `market` — deploys and verifies only the `market` edge surface;

The selected ref is the infra ref for the 0x1/Market edge surfaces only. Prism Hubot deploys independently via `aiaiaiai-org/prism-hubot` → `repository_dispatch` → `deploy-workload.yml`, which resolves the target `edge-prod-2` from the server contracts. The edge deployment workflow cannot deploy Prism to `edge-prod-1`.


## Rollout dependency

The selected activation scope must have its corresponding workload aliases available on `nilx-edge`:

```text
market-api-production         # market
market-bot-production         # market
market-bot-development        # market
nilxone-web                   # nilx-web
nilxone-telegram              # nilx-web
nilxone-discord               # nilx-web
```

The product deployments and shared-edge deployment are separate manual operations. Merge is never a deployment. `all` is appropriate only when the whole declared edge is intentionally being activated or revalidated together.

## Workload deployment

`SSH_HOST`/`SSH_USER`/`SSH_PRIVATE_KEY` for a target exist in exactly one place: that target's GitHub Environment in this repository. No other repository holds them. A product repository deploys its own workload by firing a `repository_dispatch` against `aiaiaiai-org/infra` instead of SSHing anywhere itself:

```text
POST /repos/aiaiaiai-org/infra/dispatches
{
  "event_type": "deploy-workload",
  "client_payload": {
    "workload": "nilxone-web",
    "image": "ghcr.io/nilx-one/web:1.4.2",
    "source_repository": "nilx-one/web"
  }
}
```

`.github/workflows/deploy-workload.yml` handles it in two jobs:

1. **`resolve`** — holds no secrets. It validates the payload shape, then runs `scripts/resolve-workload-target.rb` to look up `workload`'s server, network, alias, port, and health path from `contracts/services/*.yaml` and `contracts/servers/*.yaml`. The caller supplies only `workload` and `image`; everything about *where* and *how* it lands is read from contracts already reviewed and merged into this repository, never from the dispatch payload.
2. **`deploy`** — selects `environment: ${{ needs.resolve.outputs.target }}`, the same GitHub Environment `deploy-edge.yml` already uses for that box, so it reuses the existing `SSH_*` secrets rather than duplicating them. It ships `deploy/workload/deploy.sh` to the target and runs it in `validate` then `activate` mode: pull the image, run the single container on the resolved network/alias/port with `--replace`, poll its health path from inside the Docker network, and roll back to the previous image automatically if it never turns healthy.

The credential a product repository needs to hold is therefore narrowed to whatever can call the GitHub dispatch API for this repository (a fine-grained token scoped only to `Contents: write` on `aiaiaiai-org/infra`, or an installation token from a GitHub App installed only here) — never a box credential. Losing that credential lets someone request a redeploy of an already-contracted workload; it does not grant shell access, and it cannot point a workload at an undeclared box, alias, or port.

## GitHub relay

GitHub events (new issues, assignees, close/reopen, and GitHub Projects status changes) reach Discord and Telegram through a Cloudflare Worker rather than the edge: `projects_v2_item` events exist only on organization webhooks and can't trigger Actions. `RELAY_ROUTES` maps a source, an organization or a single `owner/repo`, to its destinations. The Worker lives in [`deploy/github-relay/`](deploy/github-relay/README.md), its secrets in the `github-relay` GitHub Environment, and `deploy-github-relay.yml` deploys it.

## Repository layout

```text
.
├── contracts/
│   ├── edges/
│   │   ├── nilx-edge.yaml
│   │   └── aiaiaiai-edge.yaml
│   ├── servers/
│   │   ├── edge-prod-1.yaml
│   │   └── edge-prod-2.yaml
│   └── services/
│       ├── market-api-production.yaml
│       ├── market-bot-production.yaml
│       ├── market-bot-test.yaml
│       ├── nilxone-discord.yaml
│       ├── nilxone-telegram.yaml
│       ├── nilxone-web.yaml
│       ├── prism-hub.yaml
│       └── prism-postgres.yaml
├── deploy/
│   ├── edge/
│   ├── edge-aiaiaiai/
│   ├── github-relay/
│   └── workload/deploy.sh
├── scripts/
│   ├── validate-contracts.rb
│   ├── resolve-workload-target.rb
│   └── workload-secret-env.rb
└── .github/workflows/
    ├── ci.yml
    ├── deploy-aiaiaiai-edge.yml
    ├── deploy-github-relay.yml
    ├── deploy-market.yml
    ├── deploy-nilx-web.yml
    ├── deploy-prism.yml
    ├── deploy-workload.yml
    └── edge-ready-validate.yml
```

The core rule is: **infra owns public routing; product repositories own workloads; one product's deployment must not mutate or gate on another product's runtime.**

### Release-based workloads

Not every workload is a container. A `WorkloadContract` may declare
`runtime.kind: systemd-release` when the product is a release-directory service
managed by systemd.

The `prism-hubot` contract is the first such workload:

- repository: `aiaiaiai-org/prism-hubot`;
- target: resolved from server placement, `edge-prod-2`;
- deployment path: `/opt/prism-hubot`;
- service: `prism-hubot.service`;
- release retention: `5`.

The product workflow supplies only the workload identity and requested release
ref. Infra reads the repository, target, deployment path, service and retention
from the merged contract, selects that target's GitHub Environment, and uses its
existing `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY` and `SSH_PORT`. The
product repository therefore holds no box credentials and no deployment path.

For a systemd release, infra checks out the contracted public repository at the
requested ref, archives the exact resolved commit, uploads the release to the
contracted path, validates the existing `shared/.env` and service prerequisites,
runs the repository's `bundle exec rake env:check`, then atomically switches
`current` and restarts the contracted unit. A failed post-activation service
check restores the previous release when one exists.

The caller still needs a GitHub credential capable of creating
`repository_dispatch` events in this repository. That credential is a GitHub
API credential, not a machine credential; it never grants SSH access to the
target.
