

# Moving the aiaiaiai edge from edge-prod-2 to edge-dev-1

edge-dev-1 is the only server left and `api.aiaiaiai.org` already resolves to it, while the data and
secrets of the aiaiaiai edge are still on edge-prod-2. PostgreSQL there has **no backup** (offsite backups
were deliberately not activated), so the first step is to get everything off that server in a form
that can be checked, before anything is switched.

What is on edge-dev-1 already: the 0x1 ingress `nilx-public-edge-managed` owns public ports 80 and 443
(the provider firewall allows 22, 80 and 443), next to the site archive and 0x1 workloads. There is no
Docker Compose plugin. So the aiaiaiai hosts are added to that ingress (see
[`aiaiaiai-snapshots-edge-dev-1.md`](aiaiaiai-snapshots-edge-dev-1.md): never a second public Caddy), and
workloads run with `deploy/workload/deploy.sh`.

## Step 1: sealed export (this change)

Run **Export aiaiaiai edge for migration** (manual, type `EXPORT`). Three jobs:

1. **Recipient** (Environment `edge-dev-1`): derives the public half of edge-dev-1's deploy key.
2. **Export** (Environment `edge-prod-2`): over SSH, pinned to the server's host fingerprint, seals with age
   while streaming, so no plaintext touches a disk on either server or on the runner:
   - `postgres-globals` (roles) and one `db-<name>` custom-format `pg_dump` per application database;
   - `secrets`: only the environment names each workload contract declares under `spec.runtime.secrets`
     (`prism-postgres`, `prism-hub`, `prism-hubot`, `h-ua-bot`, `4x-ais`, `4x-errors`). Values are registered for
     log masking first and are never printed; the log shows names and set/empty/missing counts only;
   - `volume-prism-hubot-state` and `volume-4x-ais-data`, read-only and without network, at most 256 MiB each.
   `manifest.json` lists each item's ciphertext and plaintext hash and size. Only the ciphertext and the
   manifest are uploaded (artifact `aiaiaiai-migration-export-<run id>`, kept 3 days).
3. **Open and check** (Environment `edge-dev-1`): decrypts with edge-dev-1's identity, compares every
   item with the manifest, checks a database item is a PostgreSQL custom-format dump and a volume is a tar, and
   prints the workloads and secret **names** in `secrets`. This proves the recipient and the data before any import.

Nothing on edge-prod-2 is stopped, changed or removed. `4x-ais` declares no secrets in its contract (its
credentials arrive in its own producer envelope), so none are taken from it.

## What the export does not do

- It does not write any GitHub secret. Producers seal their own secrets from their own Environment (for
  example prism-hubot's `production`), and that Environment still has to hold the values.
- It does not restore, start, route or switch anything. Import and restore on edge-dev-1, the contracts
  and ingress routes for edge-dev-1, and the DNS cutover are separate, separately authorized changes.

## Step 2: run the core on edge-dev-1 (this change)

**Migrate aiaiaiai core to edge-dev-1** (manual, type `MIGRATE`, `master` only) runs one stage per dispatch. It
uses `deploy/workload/deploy.sh` and the values of the same reviewed contracts as Deploy workload, on edge-dev-1's
private network `nilx-candidate`, so nothing is published on a host port. Images are pinned to a digest and their
build provenance (`gh attestation verify`, signer `publish.yml`) is verified first. The sealed export is checked
against its manifest again before anything uses it, and secrets reach the containers through the same
`workload-secret-env.rb` as a normal deploy, taken from the export by `scripts/export-credentials-env.rb` (the contract's
`ENV=SOURCE` lines inverted; only declared names, nothing missing or empty).

| Stage | What it does |
| --- | --- |
| `data` | prism-postgres (image pinned by its contract), restores `prism_hub` from the export when the database is empty, then prism-hub; checks `/healthz` through the ingress container |
| `route-validate` | proves the `api.aiaiaiai.org` route on the live ingress without changing it |
| `route-activate` | appends the route to the live Caddy file (everything that was there stays byte for byte), reloads, requires nilx.one to stay healthy or restores the old file, then waits for TLS on `api.aiaiaiai.org` |
| `hubot` | restores `prism-hubot-state` when empty, then prism-hubot, which registers its Telegram webhook and command menu on start |
| `hubot-credential` | gives prism-hubot a credential the Hub accepts: provisions the `prism-hubot` principal (least privilege), issues a fresh credential, redeploys prism-hubot with it and requires the Hub to answer 200 to it. Earlier credentials are revoked after proof |
| `speech` | gives Whisper its voice: deploys `prism-ai-tts` (private, no route), re-resolves prism-hubot's contract environment (`PRISM_HUBOT_TTS_URL`, `PRISM_HUBOT_AIS_CLIENT_ID`) and takes its secrets from its resealed, attested envelope, redeploys prism-hubot, and proves from inside the running hubot that its own configuration gets an AIS token, the TTS service speaks and the audio encodes to Opus |
| `route-rollback` | restores the ingress file from before the route |

Order: `data`, `hubot`, `route-validate`, `route-activate` (the route needs both backends running), then `hubot-credential`. The route comes before hubot because Telegram checks
the webhook's TLS when the bot registers it. It reuses the one public Caddy (never a second), and its candidate is
validated in CI together with the live file. `prism-hub` and `prism-hubot` are set to manual delivery so that
nothing keeps deploying them to edge-prod-2. edge-prod-2 is left running and untouched until the new core is
verified; the contracts still place these workloads on it, and a later change moves them for good.

### Whisper's voice on edge-dev-1

`speech` needs the verified `hubot_sha`, `tts_sha` (the `prism-ai` commit whose `Publish image` run attested the TTS image) and `envelope_run_id` (below), and no export. Run it only when, in this order:

1. AIS is released with `prism-hubot` and `prism-ai` registered as product clients (`4x-ais` `deploy/prepare-runtime-env.sh`), or the proof's token request is refused;
2. prism-hubot's publish workflow has sealed `prism-hubot:<hubot_sha>.secrets` (from its `production` Environment, which must hold `PRISM_HUBOT_AIS_PRIVATE_KEY`) and you have run **Reseal prism-hubot envelope for edge-dev-1** for that commit (type `RESEAL`). The envelope is sealed to the server the contract still places hubot on, edge-prod-2, whose key edge-dev-1 does not hold. The reseal workflow verifies the envelope's provenance, opens it with edge-prod-2's deploy key (the Environment secret behind the recipient its contract publishes) and seals it again, in one pipe, to edge-dev-1's public key; its artifact (ciphertext, one day) is what `speech` takes as `envelope_run_id`. A secret the contract names and the envelope lacks stops `speech` before anything changes;
3. the images are published and attested.

`prism-ai-tts` has no `public` route on purpose: the live `api.aiaiaiai.org` block is not rewritten by `route.sh`, and prism-hubot reaches the service as `http://prism-ai-tts:1927/v1/speech` on the server's own Docker network (hubot accepts cleartext only for such a single-label alias). Every request still needs an AIS product token with audience `prism-ai` and scope `tts.synthesize`. Everything speech sends to Telegram is a voice note; the proof sends nothing to Telegram.

## Step 3: edge-dev-1 in the contracts

edge-dev-1 is an **active** server contract now (the isolation rules of a `provisioning` server are tested on a fixture). It
places the Prism chain that already runs there, `prism-postgres`, `prism-hub`, `prism-hubot` and `prism-ai-tts`, and names the
network of its one public Caddy, `nilx-candidate`, in the edge contract `aiaiaiai-dev-edge` (which routes only the hub and hubot;
the TTS service has no public route). The contract describes that ingress; it never starts a second one, and its Caddyfile is
still changed only by the reviewed route scripts. Consequences:

- Deploy workload and Reconcile resolve these four workloads to the `edge-dev-1` Environment, and producers seal their envelopes to
  edge-dev-1's recipient from the contract, so the reseal workflow and the migrate stages are no longer needed for new releases.
- Every one of the four is `manual` or contract-pinned, so the 15-minute schedule starts none of them.
- What stays on edge-prod-2 for now: `aiaiaiai-site` (kept as the rollback of the snapshot archive), `h-ua-bot`, `4x-ais`
  (the live issuer runs in Railway) and `4x-errors`. Each moves, or is retired, in its own change.
- `backup-prism-postgres` and the diagnostic workflows still name edge-prod-2; they follow in the cleanup change.

### Hubot credential on edge-dev-1

After the initial Hubot deployment, dispatch `hubot-credential` with the verified Hubot commit SHA. It reuses the installed workload configuration and needs no export. The deploy account stores the token in a mode-0600 file in Hubot's private workload directory. Activation and rollback on this host use that token, including producer-triggered deployments using this deploy script. If rotation stops after the file is installed, rerun the stage. Earlier credentials remain valid until the Hub confirms the new one. A replacement server needs a fresh bootstrap and credential.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
