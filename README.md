# infra

Canonical infrastructure contract for the `aiaiaiai-org` public edge.

This repository owns the edge target, public ports, Caddy routing, deployment validation, activation, public verification, and rollback. Product repositories own their application runtime, data, secrets, images, and release lifecycle.

## Current production model

```text
edge target:       edge-prod-1
role:              public-edge
provider:          Hetzner
edge network:      nilx-edge
live Caddy:        mind-web-prod-1-caddy
```

`edge-prod-1` is a logical infrastructure identity. It intentionally does not encode a hardware class, provider, or product name.

## Architecture

```text
Internet
└── edge-prod-1
    └── Caddy: mind-web-prod-1-caddy
        ├── mind.aiaiaiai.org
        │   └── mind-web:8080
        ├── 0xda-market.nilx.one
        │   ├── /bot-test/* → market-bot-development:10000
        │   ├── /bot/*      → market-bot-production:10000
        │   └── /*           → market-api-production:10000
        └── nilx.one
            └── /*           → ox1-telegram-mini-app:8080

external Docker network: nilx-edge
```

`nilx.one` is the canonical public Web host for 0x1. `0x1.nilx.one` is not an active edge host; introducing it later requires working public DNS and an explicit edge-contract change before Caddy may manage TLS for it.

The shared edge routes five workload identities. Development `0xda-market` core is intentionally not public; `0xda-market-test` reaches `market-api-development:10000` directly over `nilx-edge`.

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

- `mind-web` → `aiaiaiai-org/mind-web`;
- `market-api-production` → `0xda-market/core`;
- `market-bot-production` → `0xda-market/telegram-bot` (`0xda-market`);
- `market-bot-test` → `0xda-market/telegram-bot` (`0xda-market-test`);
- `ox1-telegram-mini-app` → `nilx-one/web` (`0x1`, historical workload alias).

## Contracts

The server contract is [`contracts/servers/edge-prod-1.yaml`](contracts/servers/edge-prod-1.yaml). It exposes `80/tcp`, `443/tcp`, and `443/udp`.

The route registry is [`contracts/edge.yaml`](contracts/edge.yaml). Workload contracts live under [`contracts/services`](contracts/services).

Public routes:

| Public route | Upstream | Prefix behavior |
| --- | --- | --- |
| `https://mind.aiaiaiai.org/*` | `mind-web:8080` | preserve |
| `https://0xda-market.nilx.one/bot/*` | `market-bot-production:10000` | strip `/bot` |
| `https://0xda-market.nilx.one/bot-test/*` | `market-bot-development:10000` | strip `/bot-test` |
| `https://0xda-market.nilx.one/*` | `market-api-production:10000` | preserve |
| `https://nilx.one/*` | `ox1-telegram-mini-app:8080` | preserve |

The two market bot prefixes must be evaluated before the market API fallback.

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
MIND_WEB_DOMAIN=mind.aiaiaiai.org
EDGE_NETWORK=nilx-edge
```

Existing Caddy data/config volume names retain historical `zero-x-da-market` identifiers only as physical state identifiers so current TLS state is not discarded.

## GitHub Environment

Production edge credentials belong to GitHub Environment `edge-prod-1`.

Required secrets:

- `SSH_HOST`
- `SSH_USER`
- `SSH_PRIVATE_KEY`

Optional variable:

- `SSH_PORT=22022`

## Delivery gates

### CI

`.github/workflows/ci.yml` runs on pull requests and manual dispatch only. It validates YAML contracts, shell syntax, Compose, Caddy, and an isolated routing fixture containing all five upstream identities. It proves the market API fallback, both stripped Telegram prefixes, and the canonical 0x1 Web host resolve to the intended upstreams.

### Live candidate validation

`.github/workflows/edge-ready-validate.yml` runs for ready pull requests using trusted workflow code from `master`. It fetches only the candidate `deploy/edge/Caddyfile` from the PR head SHA and validates it inside the running Caddy container without reload or live mutation.

### Deploy shared edge

`.github/workflows/deploy-edge.yml` is manual. The selected GitHub ref is the deployment source. Every run explicitly selects an activation scope:

| Scope | DNS/upstream/public verification owned by the run |
| --- | --- |
| `nilx-web` | `nilx.one` and `ox1-telegram-mini-app:8080` |
| `market` | `0xda-market.nilx.one` and the three production/test market upstreams |
| `mind-web` | `mind.aiaiaiai.org` and `mind-web:8080` |
| `all` | every active public edge surface |

All scopes first verify `https://mind.aiaiaiai.org/health` as the existing rollback anchor. Scope-specific DNS is then checked before SSH or Caddy mutation. After SSH connectivity is established, only the selected surface's upstreams are checked directly through `nilx-edge` before the Caddyfile can be reloaded.

After Caddy reload, the rollback anchor plus the selected public surface are verified. For example, `nilx-web` requires:

```text
https://mind.aiaiaiai.org/health
https://nilx.one/health
```

while `market` additionally requires:

```text
https://0xda-market.nilx.one/health
https://0xda-market.nilx.one/bot/health
https://0xda-market.nilx.one/bot-test/health
```

`all` preserves the strict whole-edge gate and checks every active DNS name, upstream, and public health surface.

Missing required DNS or an unhealthy/missing upstream for the selected scope fails before live Caddy mutation. A failed reload or scoped post-activation verification restores the previous mounted Caddyfile.

## Rollout dependency

The selected activation scope must have its corresponding workload aliases available on `nilx-edge`:

```text
mind-web                     # mind-web
market-api-production         # market
market-bot-production         # market
market-bot-development        # market
ox1-telegram-mini-app         # nilx-web
```

The product deployments and shared-edge deployment are separate manual operations. Merge is never a deployment. `all` is appropriate only when the whole declared edge is intentionally being activated or revalidated together.

## Workload deployment

`SSH_HOST`/`SSH_USER`/`SSH_PRIVATE_KEY` for a target exist in exactly one place: that target's GitHub Environment in this repository. No other repository holds them. A product repository deploys its own workload by firing a `repository_dispatch` against `aiaiaiai-org/infra` instead of SSHing anywhere itself:

```text
POST /repos/aiaiaiai-org/infra/dispatches
{
  "event_type": "deploy-workload",
  "client_payload": {
    "workload": "mind-web",
    "image": "ghcr.io/aiaiaiai-org/mind-web:1.4.2",
    "source_repository": "aiaiaiai-org/mind-web"
  }
}
```

`.github/workflows/deploy-workload.yml` handles it in two jobs:

1. **`resolve`** — holds no secrets. It validates the payload shape, then runs `scripts/resolve-workload-target.rb` to look up `workload`'s server, network, alias, port, and health path from `contracts/services/*.yaml` and `contracts/servers/*.yaml`. The caller supplies only `workload` and `image`; everything about *where* and *how* it lands is read from contracts already reviewed and merged into this repository, never from the dispatch payload.
2. **`deploy`** — selects `environment: ${{ needs.resolve.outputs.target }}`, the same GitHub Environment `deploy-edge.yml` already uses for that box, so it reuses the existing `SSH_*` secrets rather than duplicating them. It ships `deploy/workload/deploy.sh` to the target and runs it in `validate` then `activate` mode: pull the image, run the single container on the resolved network/alias/port with `--replace`, poll its health path from inside the Docker network, and roll back to the previous image automatically if it never turns healthy.

The credential a product repository needs to hold is therefore narrowed to whatever can call the GitHub dispatch API for this repository (a fine-grained token scoped only to `Contents: write` on `aiaiaiai-org/infra`, or an installation token from a GitHub App installed only here) — never a box credential. Losing that credential lets someone request a redeploy of an already-contracted workload; it does not grant shell access, and it cannot point a workload at an undeclared box, alias, or port.

## Repository layout

```text
.
├── contracts/
│   ├── edge.yaml
│   ├── servers/edge-prod-1.yaml
│   └── services/
│       ├── market-api-production.yaml
│       ├── market-bot-production.yaml
│       ├── market-bot-test.yaml
│       ├── mind-web.yaml
│       └── ox1-telegram-mini-app.yaml
├── deploy/
│   ├── edge/
│   └── workload/deploy.sh
├── docs/
├── scripts/
│   ├── validate-contracts.rb
│   └── resolve-workload-target.rb
└── .github/workflows/
    ├── ci.yml
    ├── deploy-edge.yml
    ├── deploy-workload.yml
    └── edge-ready-validate.yml
```

The core rule is: **infra owns public routing; product repositories own workloads; one product's deployment must not mutate or gate on another product's runtime.**
