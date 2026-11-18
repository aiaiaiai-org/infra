# Telegram Special checkout for seeds

The production bot submits a signed issuer order directly from a private chat.
0x1 resolves the Telegram binding and atomically debits/grants through its existing
issuer worker. No browser visit or xPing flight is required. USDT is unchanged.

## Credential owners

Provision these **production Environment secrets before merging the coordinated
publisher changes**. Values must be random, single-line, at least 32 bytes and
different from each other and from `NILX_BROWSER_HANDOFF_TOKEN`.

| Secret | Repositories that need the identical value | Runtime purpose |
| --- | --- | --- |
| `PARTNER_LOOKUP_TOKEN` | `nilx-one/web`, `0xda-market/core`, `0xda-market/telegram-bot` | Identity read-only provider lookup/account summary |
| `CHANNEL_ASSERTION_SECRET` | `0xda-market/core`, `0xda-market/telegram-bot` | Core verifies Bot-authenticated Telegram customers |

The Bot receives neither the handoff/issuer settlement key nor database credentials.
Each producer encrypts its own envelope to edge-prod-1. Infra stores no secret values.
Empty/malformed settings fail before candidate publication. The Identity provider
preparer and secret handoff allowlists must deploy with the new envelope contract.

## Coordinated release

1. Verify all four PR heads and required CI. Provision the matching secrets without
   placing their values in comments, logs, repository files or chat.
2. Merge the coordinated Infra contracts and producers only with authorization.
   Publication during a producer/consumer mismatch fails closed; running containers
   remain unchanged. Publish/retry candidates only after the complete contract lands.
3. With separate deployment authorization, deploy `nilxone-identity`, then
   `market-api-production`, then `market-bot-production`, using their verified
   candidates. All three workloads remain manual-only. Do not deploy the unrelated
   telemetry work in infra#119 / telegram-bot#145 as part of this task.
4. Confirm public health, matching partner lookup and customer assertion keys, the
   Telegram provider binding and a running issuer worker pointing at production Core.
5. Run Core's `bundle exec ruby bin/activate_nilx_seeds_checkout` without arguments
   for read-only catalog preflight. Its existing activation policy selects only
   `0x1_special_1m`; do not silently activate longer terms or Exclusive.
   `--activate` is a separate explicitly authorized catalog change if still needed.
6. With an isolated authorized test Bond, buy the offered Special term from the
   private bot chat: verify price/recipient, one debit, one receipt, the correct
   entitlement, repeat-tap replay and refresh. Verify low balance, existing Special,
   stale confirmation and unchanged disabled USDT behavior.

No live acceptance purchase or catalogue mutation is performed by these changes.
Development configuration remains isolated and is not given production wallet keys.
If rolling the Bot back, keep Core's additive confirmed-terms API. Do not resume old
unsigned chat confirmations; disable the Bot checkout settings if rollback requires it.

© 2026 aiaiaiai · aiaiaiai.org
