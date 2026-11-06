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

Both product repositories own their application secrets. They publish them only as age-encrypted envelopes to the `edge-prod-1` `encryptionRecipient`. Infra owns `SSH_*`, destination placement, activation and rollback.

Trading Lab holds **no infra token**. Its package `ghcr.io/0xda-market/trading-lab` is public, so infra pulls images and envelopes without registry credentials. GHCR cannot grant a package to a repository of another organization. No server SSH key enters the product repository.

The `market-bot-production` contract currently lacks its own complete production secret/encrypted dispatch integration. It must be reviewed and enabled separately, preserving the existing production Telegram/payment settings rather than assuming safe defaults. **Deploying Trading Lab alone does not turn on the Telegram Trading tab.**

## Release gate

1. Merge reviewed application and infra contracts only after exact-head CI and pre-activation validation.
2. In `0xda-market/trading-lab`, run **Publish Trading Lab production release** on `master`. It requires exact-head push Full CI and runs in Environment `production`. It publishes and attests `:production-<sha>` and the envelope `:production-<sha>.secrets`, and prints both digests.
3. An infra operator runs **Deploy workload** by hand with `workload=market-trading-lab`, `image` and `secrets_image` from step 2. Infra resolves the contract, decrypts only allowlisted credentials, validates, activates and verifies `/health`.
4. Enable the bot only after the backend is healthy and its separate production deployment contract is reviewed.

Neither a PR nor a successful GitHub Actions image build authorizes activation.

## Development delivery

`market-trading-lab-development` is delivered automatically (docs/automatic-delivery.md).
After push Full CI passes on `master`, the trading-lab `ci.yml` publish job pushes
`ghcr.io/0xda-market/trading-lab:<sha>` and the envelope `:<sha>.secrets`. The envelope holds
`TRADING_LAB_SERVICE_TOKEN` from the trading-lab `development` Environment, encrypted to the
`edge-prod-1` `encryptionRecipient`. Both are attested by that job. The package is public;
infra verifies the attestations, not registry access.

The development bot (`market-bot-test`) reaches it at
`TRADING_LAB_ORIGIN=http://market-trading-lab-development:1703` with `TRADING_LAB_TOKEN`
(the same value) in its own secret envelope.
