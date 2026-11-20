<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Credentials and configuration

Infra holds the credentials to reach a server and nothing else. Everything a product
needs to run, and every secret it uses, comes from the product.

## What infra holds

For each server there is one GitHub Environment in this repository holding only how to
reach that server: `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY` (secrets) and `SSH_PORT`,
`SSH_HOST_ED25519_PUBKEY` (variables). The same key's public half is published as the
server's `encryptionRecipient`, so producers can encrypt to it without holding any
credential. See [`edge-dev-1.md`](edge-dev-1.md) for a server's enrollment.

Infra also owns the reviewed *shape* of each workload in `contracts/`: its name, port,
network, health check, public route, which secret names it maps and the fixed non-secret
environment values written in its contract. These files contain names and public
addresses, never a secret value.

## What comes from products

| Item | Where it comes from |
| --- | --- |
| Image | The product's publish workflow, attested and verified before delivery |
| Secrets | The product's own GitHub Environment, in an encrypted envelope published next to the image (`runtime.secrets`, [`automatic-delivery.md`](automatic-delivery.md#product-secrets)) |
| Values that belong to the product | The producer's own Environment, named in the contract's `producerEnvironment` and carried in the same envelope |
| Application behavior and its own constants | The product's code |

Infra stores no product secret, passes none through a dispatch in plaintext and never
falls back to its own Environment's secrets for a workload. Rotating a secret is done in
the producer's Environment by re-running its publish workflow
([`workload-scoped-secrets.md`](workload-scoped-secrets.md)).

## Authorizing a Telegram Special purchase

No credential is shared between products for this. The buyer's Telegram account is
resolved by AIS (`aiaiaiai-org/4x-ais`, `docs/hub-protocol.md`):

1. 0x1 reports a verified Telegram binding to AIS with its own product key.
2. The requesting product asks AIS for a permit for one confirmed order. AIS answers
   only a product it granted that scope to, and signs a two-minute `purchase+jwt` for 0x1
   naming the buyer and the exact order terms.
3. 0x1 verifies the permit against AIS's public signing keys, claims the Market order the
   permit names, matches the terms and settles it once.

The only secrets involved are each product's own, delivered in its own envelope.
AIS's address is a constant in the products that use it, so there is no setting for it
and no secret that could be copied into the wrong environment. See
[`telegram-seeds-checkout.md`](telegram-seeds-checkout.md).
