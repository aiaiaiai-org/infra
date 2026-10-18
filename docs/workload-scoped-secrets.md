<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Workload-scoped secrets (encrypted dispatch)

Application credentials belong to the producing repository's GitHub Environment. The
infra repository still owns SSH credentials, target selection, SSH transport and
activation. No plaintext application credential is included in `repository_dispatch`.

For deployments that opt in, a product workflow builds a newline-delimited
`NAME=value` document of only the `runtime.secrets` source names required by the
reviewed WorkloadContract, plus optional `GHCR_PULL_USER` and
`GHCR_PULL_TOKEN` for the registry. Values cannot contain newlines, NUL or CR.
The latter two entries are used for GHCR login only; they **never** enter the
runtime container.

The product encrypts this document with `age` to the **public half of the
`SSH_PRIVATE_KEY` in the target infra GitHub Environment**. For an
`ssh-ed25519` key, `age -a -r "$INFRA_AGE_RECIPIENT"` accepts the corresponding
`ssh-ed25519 AAAA...` public key. The public recipient is not secret; store it
as a **Variable** `INFRA_AGE_RECIPIENT` in the owning repository. No product
repository is given the SSH private key.

The product submits `client_payload.secrets_age` as an armored ciphertext
in the existing `deploy-workload` repository dispatch, alongside workload
and image. The infra runner decrypts it with the Environment's SSH identity,
rejects unexpected/missing credential names, translates approved names to
container environment names, and removes the temporary plaintext before the
job finishes. GitHub dispatch retains only ciphertext.

If the package is private, the product can encrypt its **ephemeral**
`github.token` (grant `packages: read`) as `GHCR_PULL_TOKEN` and its
`github.actor` as `GHCR_PULL_USER`. This avoids a permanent registry pull
credential in infra. The dispatch needs `INFRA_DEPLOY_TOKEN` in the producer
repository with permission to invoke the infra workflow; do not put that token
in the dispatched payload.

## Compatibility and migration

Existing workloads without `secrets_age` continue to use the target
Environment's named secrets. This avoids interrupting already running
services during migration. **Do not delete** any existing infra secrets until
the relevant owners have deployed and verified their encrypted handoff,
including on-demand redeploy/rollback.

For a new workload whose credentials should be producer-owned, use
`runtime.secrets` to declare a fixed allowlist. Passing a credential not
declared in the contract fails closed; missing and empty credentials fail
closed. Use a distinct encrypted dispatch per workload and per deployment.

The encrypted dispatch mechanism does not authenticate a source repository
by itself. Restrict `INFRA_DEPLOY_TOKEN` to authorized callers, and never
allow a caller to choose target host, network, path or secret mapping.
The product must use the public key of the correct target Environment;
key rotation requires updating `INFRA_AGE_RECIPIENT` before the next deploy.

## Operator setup

1. Obtain the public key corresponding to `SSH_PRIVATE_KEY` for the target
   Environment (do not copy its private half).
2. Store that public key as `INFRA_AGE_RECIPIENT` in the producing repo's
   production Variables.
3. Store application secrets and `INFRA_DEPLOY_TOKEN` in the producing repo's
   production Secrets.
4. Review the workload's `runtime.secrets` contract.
5. Run the producing repo's explicitly manual Deploy workflow; validate
   the resolved target and health after activation.

No automatic merge or deployment is implied by these instructions.
