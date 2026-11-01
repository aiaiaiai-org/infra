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
       image: ghcr.io/<owner>/<repository>   # must be the contract owner's package
       branch: master
       signerWorkflow: .github/workflows/<publish workflow>.yml
   ```

   `scripts/validate-contracts.rb` enforces the image name, the branch and the
   workflow path. A contract that pins `runtime.image` cannot also deliver
   automatically.

Artifact attestations are available for public repositories. A private producer
needs a plan that offers them.

## What still holds secrets

Infra's own server access is unchanged. `SSH_*` stays in the server
Environments and is used only inside **Deploy workload**. Producers that still
send `repository_dispatch` with a token keep working until they migrate; after
migration, delete their token secrets.
