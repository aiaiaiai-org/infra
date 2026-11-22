<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Fresh 0x1 Identity on edge-dev-1: product-owned credentials

**No product tokens in Infra GitHub Secrets.** `TELEGRAM_BOT_TOKEN` is held only by
the `nilx-one/web` GitHub **production** Environment. Infra uses only scoped
SSH transport credentials, the Actions-generated registry token, a signed
encrypted OCI envelope and the VPS public AGE recipient. Infra never
decrypts or logs the product token.

This is an expressly **fresh 0x1 store**, not an archive restoration. The
owner dropped old `pub_dress` continuity as a prerequisite. Do not delete
old archives or assert that historical Bonds, Avaia, seeds, subscriptions or
Relationship evidence has been recovered.

## Deployment protocol

1. Merge independently reviewed Infra and Web PRs with passing Full CI.
   No merge automatically deploys.
2. On **edge-dev-1** install the OS `age` package one time:
   `sudo apt-get update && sudo apt-get install -y age`.
   It provides the `age-keygen` and `age` commands. The product
   private key is generated and kept in the deploy user's host directory
   by the dedicated manual workflow.
3. Run Infra workflow **Bootstrap fresh 0x1 Identity on edge-dev-1**
   with `operation=recipient`, blank `confirmation`, no
   `encrypted_secrets_image`. This creates or reuses a host-owned AGE
   recipient key and prints only the **public** `age1...` recipient.
   It does not start Identity or touch Web/HTTPS.
4. Store that *public* recipient in `nilx-one/web` production
   Environment variable `EDGE_DEV_1_IDENTITY_AGE_RECIPIENT`.
   Store the genuine **@nilxone_bot** `TELEGRAM_BOT_TOKEN` as a secret
   **in that same product Environment only**.
5. On `nilx-one/web` master run **Package fresh 0x1 Identity secret
   envelope**. It encrypts only the bot token to that host's public
   recipient, publishes an immutable GHCR reference
   `ghcr.io/nilx-one/0x1-identity-fresh-secrets@sha256:...` and attests
   its exact producing workflow and source. The plaintext is never sent
   to Infra. If GHCR restricts reading the package, grant
   `aiaiaiai-org/infra` access to the **encrypted package only**.
6. Run the Infra workflow with `operation=validate`, blank
   `confirmation`, and the *immutable encrypted package* ref.
   Infra verifies product provenance, transfers only `secrets.age`,
   and asks the VPS to decrypt and verify it inside a temporary private
   file. This does not start a container, modify runtime.env or create
   the new database volume.
7. After **separate authorization to deploy**, run with
   `operation=activate`, `confirmation=FRESH_IDENTITY`, and the
   same encrypted digest. Infra pulls and verifies the signed Identity
   image from `nilx-one/web` commit
   `c7533e05f4c12b2a1d425cfb72fb717ec40b71f2`,
   transfers ciphertext to the host and activates a private Identity
   container using the first-use 0x1 store.
8. Verify the public `/api/v1/auth/aiaiaiai/config` returns
   `enabled: true`, the same-origin
   `/api/v1/auth/native/context` is no longer `502`, and perform an
   end-to-end AIS sign-in and new Bond provisioning separately.

## Runtime safeguards

- The AGE **private** key is created and retained only at
  `~deploy/.local/share/aiaiaiai-infra/nilx-identity-fresh/recipient.agekey`.
  Back it up in a protected location; losing it prevents future delivery of
  encrypted product credentials.
- The host alone decrypts `secrets.age`, and writes `runtime.env`
  (mode 0600) on first authorized activation with freshly generated
  `NATIVE_AUTH_SECRET`, `PASSWORD_PEPPER` and
  `GITHUB_EVIDENCE_ENCRYPTION_KEY`; no GitHub repository stores them.
  Do not rotate them implicitly.
- The new named volume is `nilxone-identity-fresh-data`, mounted at
  `/data`. Do **not** confuse it with old `nilxone-identity-data`.
- The private Docker alias is `nilxone-identity` on
  `nilx-candidate`, matching existing Web's reverse proxy. No public
  ports, Caddy reload or Cloudflare change.
- The Identity binary currently also starts Telegram polling. The
  `@nilxone_bot` token must not be polled concurrently by another
  process. The full deployment cannot be marked healthy on the strength
  of a proxy HTTP 200 alone.
- No Market issuer worker is activated: no
  `NILX_BROWSER_HANDOFF_TOKEN`, no
  `MARKET_TELEGRAM_ISSUER_URL`, no paid-order fulfillment.
- The first-use database does not recreate old Bond relations or accounts.
  0x1 continues to use AIS as the issuer (`nilx-one` public client);
  its product profiles and sessions are owned by 0x1 Core.
- The old `edge-prod-1` Infrastructure placement contracts remain
  separate work, and must **not** be blindly deployed against this
  sole VPS.
