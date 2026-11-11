<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Automatic delivery

Infra deploys a producer's verified builds on its own. The producer holds no
credential for infra: no personal access token, no GitHub App key and no
webhook secret. Any repository can publish through infra this way by adding
one block to its workload contract.

## How it works

1. **The producer publishes.** After its CI is green on the delivery branch, a
   producer workflow pushes the verified image to
   `ghcr.io/<owner>/<repository>:<full commit SHA>` and creates a
   [build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations)
   for the image digest. Both use the workflow's own `GITHUB_TOKEN` and OIDC,
   with `packages: write`, `id-token: write` and `attestations: write`.
2. **Infra plans.** **Reconcile deliveries** runs every 15 minutes and on
   dispatch. For each contract with `spec.delivery`, `scripts/plan-deliveries.rb`:
   - reads the delivery branch head of the producer repository;
   - resolves the image tagged with exactly that commit;
   - verifies its provenance with `gh attestation verify`. The attestation must
     come from the producer repository and the declared `signerWorkflow`, for
     `refs/heads/<branch>` and that commit, on a GitHub-hosted runner;
   - compares the digest with the last delivery recorded in this repository.
3. **Infra deploys.** **Deliver workload** records a GitHub deployment in the
   `delivery/<workload>` environment. That record holds the image digest, the
   source commit and the run. It then calls **Deploy workload**, the same path
   as a manual deploy, so placement, Environment protection and health checks
   are unchanged, and settles the record as `success` or `failure`.

Only the branch head is ever planned, so a late build of an older commit can
never roll a workload back. An image whose delivery failed is not retried
automatically; dispatch **Reconcile deliveries** with `force` once the cause is
fixed. Rollbacks stay manual: run **Deploy workload** with the earlier
verified digest.

## Onboarding a producer

1. Add the publish workflow to the producer. It must push the tag above and
   attest the pushed digest (`actions/attest-build-provenance` with
   `push-to-registry: true`). It only publishes what its own CI verified.
2. In the package settings on GitHub (**Package settings → Manage Actions
   access**), give `aiaiaiai-org/infra` **Read** access. Infra reads the
   registry with its own `GITHUB_TOKEN`; this is a setting, not a secret.
3. Add to the workload contract:

   ```yaml
   spec:
     delivery:
       image: ghcr.io/<owner>/<repository>   # the owner's package (see below)
       branch: master
       signerWorkflow: .github/workflows/<publish workflow>.yml
   ```

   `scripts/validate-contracts.rb` enforces the image name, the branch and the
   workflow path. A contract that pins `runtime.image` cannot also deliver
   automatically.

   The image is the repository's own package, `ghcr.io/<owner>/<repository>`.
   A repository that delivers more than one workload (`nilx-one/web` delivers
   the 0x1 web client and the 0x1 API) publishes each under another package
   name of the same organization, `ghcr.io/<owner>/<package>`. The name only
   locates the image: **Reconcile deliveries** trusts it only when its
   provenance verifies for exactly the owner repository, the signer workflow
   and the branch, so another repository cannot sign for it. Workloads may
   share a package (one client image for several hosts) only when none of them
   takes secrets, because a commit has one `<sha>.secrets` envelope.

Artifact attestations are available for public repositories. A private producer
needs a plan that offers them.

## Product secrets

Infra holds only its own `SSH_*` credentials, never a product's secrets. A workload
whose contract names `runtime.secrets` receives them in an envelope the producer
publishes next to its image:

1. Its server contract publishes `spec.encryptionRecipient`, the public half of
   that Environment's `SSH_PRIVATE_KEY`. Run **Issue workload encryption
   recipient** by hand with the server name to print it. The key is public; the
   producer reads it from this repository without any credential.
2. The producer's publish workflow runs in the producer's own Environment,
   writes exactly the secret names the contract maps (one `NAME=value` per
   line), encrypts them with `age` to that recipient and pushes them as a
   one-file image (`FROM scratch`, `/secrets.age`) tagged
   `ghcr.io/<owner>/<repository>:<full commit SHA>.secrets`. It attests that
   digest with the same workflow as the image.
3. **Reconcile deliveries** resolves and verifies the envelope like the image,
   from the same signer workflow, branch and commit. A head without an envelope
   is not delivered yet.
4. **Deploy workload** pulls the envelope by digest and decrypts it only inside
   the target Environment's job. The values go to the workload's runtime
   environment and are kept nowhere in infra. The deployment record holds the
   envelope's digest, never its content.

A workload with no producer of its own, such as a database pinned by digest,
names one with `runtime.secretsFrom`. Deploy workload then takes the envelope
of that workload's last successful delivery and passes only the names this
contract maps. Without such an envelope it stops; it never falls back to the
Environment's secrets.

To rotate a secret, change it in the producer's Environment and re-run its
publish workflow for the head commit. The new envelope digest is a new delivery.
`scripts/validate-contracts.rb` rejects a delivered workload with secrets whose
server publishes no recipient.

The envelope is ciphertext in the producer's package for as long as that tag is
kept. Everything published under the old recipient becomes readable if that
server key leaks, so rotate the key and republish when that happens.

### A workload that prepares its own environment (`delivery.envelope`)

`nilxone-identity` builds its runtime environment with its producer's
`runtime.prepareEnv` script, so it cannot also map `runtime.secrets`: the deploy
script takes either `WORKLOAD_SECRET_ENV` or `WORKLOAD_SECRET_ENV_FILE`. Its
contract lists the names of the producer's envelope under `delivery.envelope`
instead:

```yaml
spec:
  delivery:
    image: ghcr.io/nilx-one/0x1-identity
    branch: master
    signerWorkflow: .github/workflows/package-identity-service.yml
    envelope:
      - TELOXIDE_TOKEN
      - ...
```

The envelope is resolved, verified and decrypted exactly like any other (steps 3
and 4 above); a head without one is not delivered yet. `prepare-identity-provider-env.rb`
then accepts only the listed provider credentials and the two public client IDs,
which travel in the envelope too, so a delivered Identity needs no
`PROVIDER_*` variable from a caller. The envelope may also carry the pair for
sign-in through AIS, `AIAIAIAI_SIGN_IN_ISSUER` (an https origin) and
`AIAIAIAI_SIGN_IN_CLIENT_SECRET` (at least 32 bytes), both or neither: the
script refuses half of it, and without it nothing about AIS reaches the
runtime file. The secret is AIS's client secret for `nilx-one`; AIS keeps only
its SHA-256.

`NATIVE_AUTH_SECRET`, `PASSWORD_PEPPER` and `GITHUB_EVIDENCE_ENCRYPTION_KEY` are
**server-owned**. The host's `runtime.env` keeps them: the producer's
`prepare-runtime-env.sh` reuses the existing values and refuses an override.
`validate-contracts.rb` and the provider-env script both refuse them in an
envelope. Copying them into a GitHub Environment would let one wrong value lock
out every password, end every session and lose every stored GitHub token.

## What still holds secrets

Infra's own server access is unchanged. `SSH_*` stays in the server
Environments and is used only inside **Deploy workload**. That is all infra
holds. Producers that still
send `repository_dispatch` with a token keep working until they migrate; after
migration, delete their token secrets.
