<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Telegram Special checkout for seeds

A buyer confirms a 0x1 Special in the private bot chat and pays in seeds. 0x1 debits and
grants once; a repeated confirmation debits nothing more. USDT is unchanged.

The buyer is authorized by an AIS permit, not by credentials shared between products. See
[`credentials-and-configuration.md`](credentials-and-configuration.md) for who holds what.

## Flow

```text
bot ──confirmed order──▶ Market ──(order terms frozen)
bot ──permit request───▶ AIS      (via Prism Hub; needs the product's grant)
bot ◀──purchase+jwt────  AIS      (two minutes; buyer + exact terms)
bot ──permit───────────▶ 0x1      POST /api/v1/identity/ais-purchase
0x1 verifies the permit against AIS's keys, claims the Market order the permit names,
matches the terms, debits and grants atomically, then confirms or rejects it in Market.
```

- The permit is the only credential on the 0x1 route. A permit that does not match the
  Market order, the buyer's Bond or AIS's signature is refused before anything is debited.
- The Market worker no longer settles Telegram orders by polling; only a permit
  authorizes one. A Telegram order stays `pending` until its permit arrives or Market
  expires it.
- The wallet operation is keyed by issuer, requesting product and order ID, so a repeat
  confirms the same order again without a second debit.

## Configuration

| Where | What |
| --- | --- |
| 0x1 identity service | `MARKET_TELEGRAM_ISSUER_URL` (Market's Telegram issuer queue) and its existing `NILX_BROWSER_HANDOFF_TOKEN`. AIS's origin, the permitted product and AIS's keys are held in Core, not set per service |
| AIS | The registry grants `telegram.link.put` to 0x1 and `telegram.special.purchase` to the requesting product, for audience `prism-hub` |
| Each product | Its own secrets, in its own envelope |

`PARTNER_LOOKUP_TOKEN` and `CHANNEL_ASSERTION_SECRET` are not part of this checkout. Infra's
identity-provider preparation still requires `PARTNER_LOOKUP_TOKEN` for the existing
partner lookup; that is separate from authorizing a purchase.

## Before enabling it

- Reports of Telegram bindings from 0x1 to AIS, the Hub relay of the permit request, and
  the bot and Market calling AIS are delivered by their own repositories.
- The AIS registry names the client `0x1` and carries the grants above.
- Run Core's `bundle exec ruby bin/activate_nilx_seeds_checkout` with no arguments for the
  read-only catalog preflight; it selects only `0x1_special_1m`. `--activate` is a separate
  authorized catalog change.
- With an authorized test Bond, buy the offered term from the bot chat and verify one
  debit, one receipt, the entitlement, a repeated tap, low balance and an existing Special.

Deploying any of this is a separate, explicitly authorized step.
