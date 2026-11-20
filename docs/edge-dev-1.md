# edge-dev-1 enrollment

Server: Contabo VPS \`158.220.74.54\` (observed Ubuntu apt sources: noble/24.04).
Host identity: \`edge-dev-1\`; dedicated SSH user: \`deploy\`.

This server starts in \`provisioning\`. It has **no assigned workloads, no
approved public ingress, and no active edge contract**. This is deliberate:
registering a server must not activate \`nilx-one/web\` or alter production
placement on \`edge-prod-1\`.

## GitHub Environment (operator setup)

In \`aiaiaiai-org/infra\`, create Environment **edge-dev-1**:

- Secrets: \`SSH_HOST=158.220.74.54\`, \`SSH_USER=deploy\`,
  \`SSH_PRIVATE_KEY\` (the private deploy SSH key; never commit it).
- Variables: \`SSH_PORT=22\` (or the verified SSH listener port),
  \`SSH_HOST_ED25519_PUBKEY\` (the **server's host public key**, not the
  deploy user's authorized key).

Get the host key from a trusted Termius session on the VPS:

\`\`\`sh
awk '{print $1 " " $2}' /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
\`\`\`

Paste only the two-field \`ssh-ed25519 AAAA...\` value into the GitHub
Environment **Variable**. Compare its fingerprint with the trusted
server-side output. The fingerprint printed when generating
\`/root/.ssh/edge-dev-1-actions\` identifies a **client** key and is not
the server host fingerprint.

After this PR is merged, manually dispatch **Check edge-dev-1 SSH access**
from trusted \`master\`. The workflow only checks pinned SSH host identity,
the \`deploy\` account, \`edge-dev-1\` hostname, and Docker Engine access.
It does not install packages, create containers, change DNS, deploy or restart
a service. Missing credentials or unpinned host identity fail closed.

Before an application can be deployed, a separate reviewed PR must add its
own development edge/network, a matching workload and correct runtime port.
The existing 0x1 Web image listens on port 1927; Infra's test-workload
contract expects port 1703, so that mismatch must be resolved explicitly
rather than bypassing validation. Also establish independent dev
identity/session and data boundaries, and validate GHCR image provenance.

No merge or deploy is implied by preparing this enrollment.
