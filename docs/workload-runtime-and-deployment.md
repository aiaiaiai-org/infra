<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Workload Runtime and Deployment Model

## Purpose

This document defines how aiaiaiai-org/infra separates workload deployment policy from product repositories.

The infrastructure repository is the source of truth for where a workload runs and how that workload is activated. A product repository owns its application code and requests deployment of a specific revision. The product repository does not choose the production host, SSH credentials, deployment path, systemd unit, container alias, network, or public edge target.

The model is intentionally runtime-neutral. A WorkloadContract describes a workload, while runtime.kind selects the deployment mechanism.

## Deployment boundary

The canonical delivery chain is:

product repository
    |
    | repository_dispatch(workload, ref/image)
    v
aiaiaiai-org/infra
    |
    +-- resolve WorkloadContract
    +-- resolve ServerContract
    +-- select target GitHub Environment
    +-- deploy using the contracted runtime
            |
            v
        production host

The caller supplies only the minimum release identity required by the selected runtime.

For a release-based workload:

{
  "event_type": "deploy-workload",
  "client_payload": {
    "workload": "prism-hub",
    "ref": "master"
  }
}

For a container workload, the caller may supply an immutable image reference:

{
  "event_type": "deploy-workload",
  "client_payload": {
    "workload": "nilxone-web",
    "image": "ghcr.io/nilx-one/web:1.4.2"
  }
}

The dispatch payload must not become a second infrastructure contract. It identifies what to release, not where or how to run it.

## Ownership

| Concern | infra | Product repository |
| --- | --- | --- |
| Workload identity | contract | consumes |
| Production target | owns | does not choose |
| SSH credentials | owns | never receives |
| Deployment path | owns | does not choose |
| Runtime kind | owns | consumes |
| Systemd unit | owns | does not choose |
| Container network/alias/port | owns | declares requirement through contract |
| Application code | does not own | owns |
| Application secrets/data | does not store | owns / provisions through the contracted runtime |
| Release activation | owns | requests |
| Rollback | owns | does not perform |
| Public edge routing | owns | consumes |

The critical security boundary is that a product repository needs a credential capable of requesting a deployment through GitHub, but never a credential capable of logging into the production host.

## Runtime kinds

### systemd-release

A release-based workload is deployed as a versioned application release on the host.

Git commit
    |
    v
release/<commit-sha>
    |
    +-- shared/.env
    +-- shared/bundle/
    +-- shared/var/
    |
    v
current -> releases/<commit-sha>
    |
    v
systemd service

The important property is that the active application is tied to an exact Git revision, while mutable runtime state remains outside the release.

The runtime is suitable for applications that are already native host services, such as a Ruby/Rails application managed by systemd.

A typical contract is:

runtime:
  kind: systemd-release
  deploymentPath: /opt/example
  service: example.service
  releaseRetention: 5
  postActivateCommand: bundle exec rake example:commands

The runtime implementation is responsible for:

1. resolving the requested repository revision;
2. creating a release artifact for that exact revision;
3. installing the release under the contracted deployment path;
4. linking shared runtime configuration and persistent state;
5. installing runtime dependencies into shared storage;
6. validating the release before activation;
7. atomically switching current;
8. restarting the contracted systemd service;
9. running the contracted activation hook;
10. restoring the previous release when activation fails;
11. retaining only the contracted number of releases.



For host-native Ruby releases, the deploy command runs through a non-interactive SSH shell. The runtime implementation therefore normalizes common per-user Ruby manager paths (`rbenv`, `asdf`, and `mise`) before resolving `ruby` and `bundle`; it must not depend on interactive shell startup files. If the declared Ruby runtime is absent, infra may provision the exact runtime declared by the release into the host's managed `/opt/ruby` prefix using a pinned, checksum-verified official Ruby source archive. Runtime provisioning is idempotent and requires non-interactive sudo; it never falls back silently to a different Ruby version.

The release directory is immutable after activation. Persistent state must not be stored inside a release directory.

### container

A container workload is deployed from an immutable container image.

source repository
    |
    v
container image
    |
    v
infra resolves WorkloadContract
    |
    v
production host
    |
    +-- container on contracted network/alias/port

The existing container runtime remains valid and is the preferred model when image immutability, runtime isolation, or portability is materially useful.

A container contract describes the network-facing runtime properties such as network, stable alias, port, and health path. The deployment implementation, not the caller, owns the concrete container lifecycle.

A container contract may also declare:

- `healthKind: tcp` for a workload that speaks no HTTP, such as a database. Its health is its port
  accepting a connection, and it takes no `health` path. The default is `http`.
- `runtime.image`, an image pinned in the contract (a digest, for a third-party image). A dispatch
  cannot replace it; the contract is the release identity.
- `runtime.secrets`, `ENV_NAME=SECRET_NAME` pairs. The values come from the secrets of the target
  server's GitHub Environment at deployment and are never written in a contract. A named secret
  the Environment lacks, or leaves empty, stops the deployment.

## Why both runtimes exist

These runtimes solve different operational problems.

A container image gives a stronger runtime boundary: the application runtime, system libraries, and application dependencies can be packaged into one immutable artifact. This reduces dependence on host software and makes the same image portable across hosts.

A systemd release is simpler for a host-native application. The application remains directly visible to the operating system, systemd provides process supervision, and rollback is a filesystem-level release switch. It avoids introducing a container lifecycle where the workload does not need one.

The infrastructure contract therefore does not make Docker mandatory.

The stable abstraction is:

WorkloadContract
      |
      +-- runtime.kind
            +-- container
            +-- systemd-release

Additional runtime kinds may be introduced later without changing the product-side deployment request.

## Exact revision semantics

A manual production deployment must identify an exact application state.

For systemd-release, the deployment source is resolved to an exact Git commit SHA. The release directory is named by that SHA.

For containers, the deployment should consume an immutable image reference. A mutable tag such as latest is not a sufficient release identity when reproducibility matters.

Therefore:

deploy request
    |
    v
exact revision / immutable image
    |
    v
contract resolution
    |
    v
activation

The deployment system must never silently replace the requested revision with another branch state.

## Validation and activation

Deployment has two distinct phases:

validate
    |
    +-- resolve contract
    +-- resolve target
    +-- verify runtime prerequisites
    +-- prepare release/image
    +-- run pre-activation checks
    |
    v
activate
    |
    +-- switch runtime
    +-- restart/start workload
    +-- run activation checks
    +-- rollback on activation failure

Validation must not mutate the live production workload.

Activation is the only phase that changes the live runtime.

Repository CI and deploy validation happen before merge. Production activation remains a separate, explicit manual operation.

## Rollback

Rollback is an infrastructure responsibility because infra owns the activation boundary.

For systemd-release, rollback means restoring the previous current target and restarting the service.

For containers, rollback means restoring the previously known-good image/runtime state.

A failed activation must not leave the workload pointing at a partially activated release.

Rollback must be observable in workflow output and server logs. The deployment system must not report success when activation or rollback has failed.

## Persistent state

Release artifacts and persistent runtime state are different classes of data.

A release contains application code and release-local configuration.

Persistent state belongs under the contracted shared runtime area or another explicitly contracted persistence mechanism. Examples include:

- environment configuration;
- dependency caches;
- interaction state;
- delivery idempotency state;
- application uploads or other durable data when explicitly required.

A release must be disposable. Deleting an old release must not delete persistent application state.

## Database migrations and activation hooks

Database migrations are application lifecycle operations and must be ordered deliberately relative to release activation.

An activation hook is not automatically equivalent to a pre-activation migration.

If a workload requires:

migrate
    |
    v
activate
    |
    v
health check

then the runtime contract must express that order explicitly. A post-activation hook must not be used merely because it is available when the application's correctness requires migration before activation.

This distinction is especially important for Rails workloads.

## Security model

The deployment architecture follows a one-way trust boundary:

product repository
    |
    | deployment API credential
    v
infra
    |
    | SSH credentials from target Environment
    v
production host

Product repositories must not contain:

- SSH_HOST;
- SSH_USER;
- SSH_PRIVATE_KEY;
- host-specific SSH configuration;
- deployment paths;
- systemd credentials.

The corresponding SSH credentials live only in the GitHub Environment owned by infra.

A compromised product-side deployment token may request a deployment allowed by the existing workload contract. It must not grant shell access or permit an arbitrary host, path, service, network, or port to be selected through the dispatch payload.

## Design invariants

1. Contract over caller input. Infrastructure topology comes from reviewed contracts, never from an untrusted deployment payload.
2. Exact release identity. A deployment activates exactly the revision or immutable image that was requested.
3. Runtime independence. Product repositories depend on the workload contract, not on Docker or systemd implementation details.
4. Single credential boundary. Production SSH credentials exist only in the target GitHub Environment in infra.
5. Release/state separation. Releases are disposable; persistent state is not.
6. Validation before activation. Deployment validation must not mutate the live workload.
7. Rollback is part of deployment correctness. A deployment is not successful merely because the new process was started once.
8. Merge is not deployment. Merging changes code; manual deployment activates that code in production.
9. No cross-product coupling. One workload's deployment must not require another workload to be healthy unless an explicit contract says so.
10. Runtime can evolve. Adding a new runtime must not require changing the product-side deployment protocol.

## Operational model

For a product such as prism-hub, the intended workflow is:

PR
 |
 v
Full CI
 |
 v
Deploy validation
 |
 v
Merge to master
 |
 v
Manual "Deploy production"
 |
 v
repository_dispatch -> infra
 |
 v
resolve prism-hub WorkloadContract
 |
 v
resolve production target
 |
 v
deploy exact revision
 |
 v
activate
 |
 v
minimal post-activation verification

The product repository remains focused on application correctness. infra remains the operational authority for production placement and activation.

## Non-goals

This document does not define:

- application business logic;
- application-specific secret values;
- public API semantics;
- a mandatory containerization policy;
- a specific cloud provider beyond the infrastructure contracts that currently exist;
- automatic production deployment on merge.

Those concerns remain owned by their respective repositories or contracts.
