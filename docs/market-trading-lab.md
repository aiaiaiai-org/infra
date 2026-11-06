<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Trading Lab private deployment

Workloads: `market-trading-lab` (production, port `1927`) and `market-trading-lab-development` (test, port `1703`, automatic delivery from `master`). Application owner: [`0xda-market/trading-lab`](https://github.com/0xda-market/trading-lab).

The workload runs in `edge-prod-1`, on the external `nilx-edge` Docker network, alias `market-trading-lab`, port `1927`. No edge host, public DNS name, public route or database is allocated.

```text
Telegram Mini App → market-bot-production → http://market-trading-lab:1927/v1/paper/replays
                                            (private Docker network)
```

The bot validates Telegram initData and resolves a Market Core user before calling Trading Lab. Trading Lab accepts **paper replay only** and authenticates the bot using a shared bearer token. There is no live trading, exchange order API, wallet access, settlement authority or production balance.

## Secret ownership

- `0xda-market/trading-lab`, Environment `production`: `TRADING_LAB_SERVICE_TOKEN`.
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

## Development delivery

`market-trading-lab-development` is delivered automatically (docs/automatic-delivery.md).
After push Full CI passes on `master`, the trading-lab `ci.yml` publish job pushes
`ghcr.io/0xda-market/trading-lab:<sha>` and the envelope `:<sha>.secrets`. The envelope holds
`TRADING_LAB_SERVICE_TOKEN` from the trading-lab `development` Environment, encrypted to the
`edge-prod-1` `encryptionRecipient`. Both are attested by that job. The package must grant
`aiaiaiai-org/infra` **Read** under *Manage Actions access*.

The development bot (`market-bot-test`) reaches it at
`TRADING_LAB_ORIGIN=http://market-trading-lab-development:1703` with `TRADING_LAB_TOKEN`
(the same value) in its own secret envelope.
