<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Trading Lab private deployment

Workloads: `market-trading-lab` (production, port `1927`) and `market-trading-lab-development` (test, port `1703`, automatic delivery from `master`). Application owner: [`0xda-market/trading-lab`](https://github.com/0xda-market/trading-lab).

The workload runs in `edge-prod-1`, on the external `nilx-edge` Docker network, alias `market-trading-lab`, port `1927`. No edge host, public DNS name or public route is allocated. Production keeps its research history in Market's database (below); development has none.

```text
Telegram Mini App → market-bot-production → http://market-trading-lab:1927/v1/paper/replays
                                            (private Docker network)
```

The bot validates Telegram initData and resolves a Market Core user before calling Trading Lab. Trading Lab accepts **paper replay only** and authenticates the bot using a shared bearer token. There is no live trading, exchange order API, wallet access, settlement authority or production balance.

## Secret ownership

- Production: `0xda-market/core`, Environment `production`, holds `TRADING_LAB_SERVICE_TOKEN`. Trading Lab is part of production Market and owns no production secret (below).
- Development: `0xda-market/trading-lab`, Environment `development`, holds `TRADING_LAB_SERVICE_TOKEN`.
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

## Research database (production only)

Trading Lab is part of production Market and runs on its capacity. It has no database, role or password of its own: it connects to Market's database with Core's credentials and keeps its tables in its own schema, `trading_lab`, inside the `market` database. Core's migrations use the `market` schema and never touch it; Trading Lab's migrations stay in `trading_lab`.

```text
market-api-production ── envelope ─┬─> market-trading-lab              TRADING_LAB_SERVICE_TOKEN, TRADING_LAB_DATABASE_URL
                                    └─> market-trading-lab-okx-collector TRADING_LAB_DATABASE_URL
                                          │
                                          └─> market-postgres-production:1927/market, schema trading_lab
market-trading-lab-development            no database
```

- **Secrets come from Core.** Both Trading Lab workloads use `runtime.secretsFrom: market-api-production`. Deploy workload takes the envelope of Core's last successful delivery and passes only the names each contract maps: the service gets `TRADING_LAB_SERVICE_TOKEN` and `MARKET_DATABASE_URL` as `TRADING_LAB_DATABASE_URL`; the collector gets only the URL. Core's publish seals `TRADING_LAB_SERVICE_TOKEN` because `market-api-production` maps it, which `secretsFrom` requires.
- **Trust.** Trading Lab code runs with Market's database role and could, through a bug, reach Market data. That is the price of not separating it from Core. Its schema separation keeps the two migration histories apart; it is not an access boundary.
- **Production only.** `market-trading-lab-development` ships every `master` commit and migrates at boot; given a database it would migrate production data with unreleased code. It keeps simulating without history.
- **Collectors.** `market-trading-lab-okx-collector` runs the release image with `bin/trading-lab collect-okx`: read-only public OKX tickers, no listener, health is the process staying up. A Telegram collector joins once a channel list is chosen, as its own contract with `TRADING_LAB_TELEGRAM_CHANNELS` and the same `secretsFrom`.
- **Growth.** The OKX collector writes about 345,000 rows a day at its defaults. There is no retention yet; watch the volume's disk on edge-prod-1.
- **Backups.** Market's backup (`docs/market-postgres-production.md`, step 3) is a dump of the `market` database, so it covers the `trading_lab` schema too; its restore test must include it.

### Activation order (manual, each step authorized separately)

1. **Market first.** The `market-api-production` contract declares `delivery.mode: manual`, so the scheduled reconciler cannot activate it. Bootstrap `market-postgres-production`, verify an encrypted off-host backup and isolated restore, then explicitly dispatch **Reconcile deliveries** for `workload=market-api-production` and verify successful Core delivery. Although the Trading Lab consumer contracts are valid with this staged producer, their `secretsFrom` resolution fails closed until the producer has a successful delivery record.
2. **Token.** `TRADING_LAB_SERVICE_TOKEN` is in Core's production Environment (at least 32 bytes) and a Core delivery has sealed it. The production Telegram bot's `TRADING_LAB_TOKEN` carries the same value.
3. **Release.** Run Trading Lab's *Publish Trading Lab production release* on `master`; it publishes only the image.
4. **Activate.** Run **Deploy workload** with the printed image for `market-trading-lab`, then for `market-trading-lab-okx-collector`, leaving `secrets_image` empty so infra takes Core's delivered envelope. The service migrates `trading_lab` at boot. Verify `/health` and, from a disposable client on `nilx-edge`, that `trading_lab.market_stream_sessions` gains an open session.
