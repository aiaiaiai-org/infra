<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Trading Lab private deployment

Workloads: `market-trading-lab` (production, port `1927`) and `market-trading-lab-development` (test, port `1703`, automatic delivery from `master`). Application owner: [`0xda-market/trading-lab`](https://github.com/0xda-market/trading-lab).

The workload runs in `edge-prod-1`, on the external `nilx-edge` Docker network, alias `market-trading-lab`, port `1927`. No edge host, public DNS name or public route is allocated. Production keeps its research history in the `trading_lab` database of `market-postgres-production` (below); development has none.

```text
Telegram Mini App → market-bot-production → http://market-trading-lab:1927/v1/paper/replays
                                            (private Docker network)
```

The bot validates Telegram initData and resolves a Market Core user before calling Trading Lab. Trading Lab accepts **paper replay only** and authenticates the bot using a shared bearer token. There is no live trading, exchange order API, wallet access, settlement authority or production balance.

## Secret ownership

- `0xda-market/trading-lab`, Environment `production`: `TRADING_LAB_SERVICE_TOKEN` and `TRADING_LAB_POSTGRES_PASSWORD`. Its publish workflow derives `TRADING_LAB_DATABASE_URL` from the password, so infra never holds either.
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

Trading Lab runs on Market's capacity: one database `trading_lab`, owned by the role `trading_lab`, inside the existing `market-postgres-production` instance. It is a separate database, not a schema in Core's `market` database, so Core's migrations never see the lab's tables and the `trading_lab` role cannot reach Market data.

```text
market-trading-lab ─────────────┐
market-trading-lab-okx-collector ┴─> market-postgres-production:1927/trading_lab
market-trading-lab-development      (no database)
```

- **Production only.** `market-trading-lab-development` ships every `master` commit and migrates at boot; given the database it would migrate the only real research data with unreleased code. It keeps simulating without history.
- **Envelopes.** Trading Lab's production publish emits `:production-<sha>.secrets` (`TRADING_LAB_SERVICE_TOKEN`, `TRADING_LAB_DATABASE_URL`) for `market-trading-lab` and `:production-<sha>.collector.secrets` (`TRADING_LAB_DATABASE_URL` only) for the collectors. Deploy workload admits exactly the names a contract maps, so a collector refuses the service envelope and never holds the service token.
- **Collectors.** `market-trading-lab-okx-collector` runs the release image with `bin/trading-lab collect-okx`: read-only public OKX tickers, no listener, health is the process staying up. A Telegram collector joins once a channel list is chosen, as its own contract with `TRADING_LAB_TELEGRAM_CHANNELS` and the same collector envelope.
- **Growth.** The OKX collector writes about 345,000 rows a day at its defaults. There is no retention yet; watch the volume's disk on edge-prod-1.
- **Backups.** The Market backup required before activation (`docs/market-postgres-production.md`, step 3) must cover the `trading_lab` database as well as `market`, and its restore test must include it.

### Activation order (manual, each step authorized separately)

Nothing here runs before `market-postgres-production` is active and verified (`docs/market-postgres-production.md`, steps 1–7).

1. **Password.** Generate a random password locally and store it as `TRADING_LAB_POSTGRES_PASSWORD` in `0xda-market/trading-lab`'s `production` Environment. Never commit, print or paste it.
2. **Role and database, once.** On edge-prod-1, from the same shell that still holds the password in `$pw`, create them through the container's local socket (the official image trusts local connections; nothing crosses the network):

   ```sh
   docker exec -i -e PW="$pw" market-postgres-production sh -c \
     'psql -v ON_ERROR_STOP=1 -U market -d market -v pw="$PW"' <<'SQL'
   CREATE ROLE trading_lab LOGIN PASSWORD :'pw';
   CREATE DATABASE trading_lab OWNER trading_lab;
   REVOKE ALL ON DATABASE trading_lab FROM PUBLIC;
   REVOKE CONNECT ON DATABASE market FROM trading_lab;
   SQL
   ```

   `REVOKE CONNECT ... FROM trading_lab` only bites once `market` itself revokes `CONNECT` from `PUBLIC`; until then the role can connect to `market` but owns nothing there. Unset `$pw` afterwards.
3. **Release.** Run Trading Lab's *Publish Trading Lab production release* on `master`. The service migrates its schema at boot and refuses to start without its database, so this comes after step 2.
4. **Activate.** Run **Deploy workload** once per printed row: `market-trading-lab`, then `market-trading-lab-okx-collector`. Verify `/health` on the service and, from a disposable client on `nilx-edge`, that `trading_lab.market_stream_sessions` gains an open session.
