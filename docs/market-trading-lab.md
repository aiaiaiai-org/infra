<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Trading Lab private deployment

Workload: `market-trading-lab`. Application owner: [`0x0sky/trading-lab`](https://github.com/0x0sky/trading-lab).

The workload runs in `edge-prod-1`, on the external `nilx-edge` Docker network, alias `market-trading-lab`, port `1927`. No edge host, public DNS name, public route or database is allocated.

```text
Telegram Mini App → market-bot-production → http://market-trading-lab:1927/v1/paper/replays
                                            (private Docker network)
```

The bot validates Telegram initData and resolves a Market Core user before calling Trading Lab. Trading Lab accepts **paper replay only** and authenticates the bot using a shared bearer token. There is no live trading, exchange order API, wallet access, settlement authority or production balance.

## Secret ownership

- `0x0sky/trading-lab`, Environment `production`: `TRADING_LAB_SERVICE_TOKEN`.
- `0xda-market/telegram-bot`, Environment `production`: `TRADING_LAB_TOKEN` with the **same** random value.
- The bot's nonsecret configuration is `TRADING_LAB_ORIGIN=http://market-trading-lab:1927`, accepted only as the specifically allowlisted Docker host.

Both product repositories own their application secrets. They dispatch age-encrypted workload-scoped credential payloads to `aiaiaiai-org/infra`. Infra owns `SSH_*`, destination placement, activation and rollback.

For the **Trading Lab** deployment, its producer also requires `INFRA_DEPLOY_TOKEN` with narrowly-scoped infra repository dispatch, workflow run and artifact-read access. The producer's ephemeral `GITHUB_TOKEN` can be encrypted as `GHCR_PULL_TOKEN` for package access. No server SSH key enters the product repository.

The `market-bot-production` contract currently lacks its own complete production secret/encrypted dispatch integration. It must be reviewed and enabled separately, preserving the existing production Telegram/payment settings rather than assuming safe defaults. **Deploying Trading Lab alone does not turn on the Telegram Trading tab.**

## Release gate

1. Merge reviewed application and infra contracts only after exact-head CI and pre-activation validation.
2. Manually request an immutable image deployment from the producing repository.
3. Infra resolves the contract, decrypts only allowlisted credentials, validates, activates and verifies `/health`.
4. Enable the bot only after the backend is healthy and its separate production deployment contract is reviewed.

Neither a PR nor a successful GitHub Actions image build authorizes activation.
