# Identity operator execution

Core's operator request workflows own domain validation and build the operator
binary. Infra's manually started **Identity operator** owns the production
credentials and chooses `edge-prod-1`. No producer PAT, direct Core SSH access,
new public administrative HTTP route, deployment or service restart is needed.

The request travels as an attested OCI image in
`ghcr.io/nilx-one/core-identity-operator`. After the first Core request creates
the package, its owner must set the package visibility to public once. This
permits cross-organization consumption without a PAT or copying Core tokens
into infra. Request images contain only the operator binary, checksums and
selected addresses/role; they never contain the production database or results.

1. After the Core and infra changes are merged, start Core's **List registered
   Bonds**, **Create Business Bond**, or **Add Business Bond member** on master.
   The selected revision must already have all five Rust CI jobs green, with
   the verified static operator binary artifact still available. Supply an existing human
   owner when creating a business.
2. Copy its successful request run ID into infra's **Identity operator** workflow
   on master. This second manual action authorizes execution of that exact
   request. No workflow runs automatically after a pull request or merge.
3. Read the actual execution result and provenance artifact. A successful Core
   preparation alone is never evidence of a database change.

The actor-ID allowlist defaults to the project owner's two configured GitHub
identities. Override it using `IDENTITY_OPERATOR_ACTOR_IDS` in infra when the
authorized operators change. Both the Core request actor/triggering actor and
the infra execution actor must be on this list. The `edge-prod-1` environment's
existing protection rules and SSH credentials still apply.

Requests from forks, feature branches, other workflows, failed runs or rerun
attempts are refused. The source must be in current Core master ancestry.
The Core workflow artifact is an optional one-day download for inspection;
infra consumes the immutable OCI digest and validates the signed source ref,
commit, signer workflow and run-ID label before extracting the request.
Duplicate member additions intentionally fail instead of becoming a replayed
grant. Creation replays may only acknowledge the same existing owner.

Before executing, infra verifies the live container is healthy, non-root user
`identity`, exact DATABASE_URL `sqlite:///data/identity.db`, and named volume
`nilxone-identity-data` at `/data`. The uploaded tool is checksum-verified again
on the server. It runs in a temporary networkless, read-only-root container
using the live service's existing image ID, with only the tool and selected
data volume mounted. Listing mounts the volume read-only too. There is no
image pull, service activation, opportunistic schema migration or SQL shell.

Only operator-requested registration/membership operations may write domain
state. `hire`, `freed`, deletion and lifecycle timers are deliberately refused
until their separate domain contract and implementation are available. No
operation fabricates employment, user acceptance or BondChain evidence.

Production transport, public OCI package access, static binary execution
and schema compatibility still need an explicitly requested live read-only
listing after merge. CI fixtures do not claim those live results. Neither
installing these workflows nor a listing assigns `0x0sky` ownership of any
business. Creating those memberships requires their own explicit requests.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
