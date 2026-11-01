# AGENTS.md

Instructions for every coding agent working in this repository (Claude Code,
OpenAI Codex and others). This file is the single source of agent instructions.
Do not add a `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md`: Claude Code
reads `AGENTS.md` only when none of those exist.

## GitHub delivery

Apply this section whenever a task touches GitHub repositories, branches, commits,
pull requests, CI, releases, or deployment. Otherwise ignore it.

### Authority

Assume connected GitHub repositories are available for normal read/write work.
Inspect actual state before reporting an access limitation.

Proceed without additional confirmation for authorized reversible repository
actions, including branches, commits, pull request preparation and technical
reviews. Creating a pull request under a human identity requires that human's
authorization, single-use unless an explicit scope and duration are granted.
Merge requires explicit authorization for the specific change.

Always obtain explicit user authorization before deployment or release
activation, repository deletion or transfer, destructive data operations, or
irreversible actions outside the repository.

A merge is not a deploy. Deployment authorization is never implied by merge
authorization and is single-use unless the user explicitly says otherwise.

### Repository rules

- Never commit directly to the default branch.
- Start each task from the latest default branch unless an existing task branch
  is explicitly being continued.
- Use one branch and one pull request per independently reviewable task.
- Prefer the smallest complete change.
- Do not mix unrelated features, fixes, refactors, or cleanup.
- Do not repeat work already present in another branch or pull request.
- Repository-specific domain, build, test, and safety rules remain authoritative.
  If an older generic Git workflow conflicts with this section, this section
  wins unless the repository explicitly declares a current exception.

### Contribution roles and attribution

These rules apply to every human contributor, AI agent and development tool.
Keep identities configurable outside this file; do not hardcode account names,
email addresses or tool-specific identities here.

- **Human contributor:** accountable person who owns the contribution and PR.
- **AI agent:** identifiable actor implementing or reviewing changes.
- **Development tool:** model, IDE or service used by an actor.

A commit must use the actual implementation author's Git identity. Agent-authored
commits use the identity configured for their execution environment, not the
human contributor's identity. Allowed identities and roles are declared in
`.github/contributors.yml`; CI validates commits against that allowlist.
Agents must not override their environment's author identity in-session.
If the environment identity is not allowed, stop before writing.
Preserve real human authorship and use `Co-authored-by: Name <email>` only for
people or agents who materially co-authored the change. Record the actual tool
separately using `Assisted-by: Tool Name`; this is an informational trailer,
not a GitHub identity or independent approval. Identify the tool and actual
authors in the PR description.

The PR creator is the responsible human contributor. Agents may create a PR
using the human account only with explicit authorization, and must disclose
agent preparation rather than presenting it as a personal human action.
If the required identity or permission is unavailable, stop; never silently
switch to a different account.

Cross-tool technical review is allowed, including when implementations share
an agent account. A reviewer must disclose the reviewing actor and tool.
Technical review is not equivalent to an independent GitHub approval.
Never claim approval that GitHub has not accepted, dismiss a blocking review
merely to bypass protection, or circumvent required reviews.

Merge attribution must identify actual human contributors, agent contributors
and development tools. Preserve commit history, original authorship and
repository-required merge method; do not rewrite protected history just to
change attribution. Do not credit noncontributors as co-authors.

Before the first write in a task, verify the authenticated account, intended
actor, repository, branch, author and attribution. Recheck when the session,
credential, repository or identity context changes. Stop on mismatch. Before merge,
verify the exact head CI, required approvals, resolved review threads and
explicit merge authorization.

### Before changing anything

Inspect only the state needed for the current decision:

1. repository and default branch;
2. relevant repository instructions;
3. existing pull requests or branches for the same task;
4. targeted files and contracts;
5. relevant CI and merge requirements.

Reuse state already verified during the current task. Do not repeatedly fetch
or inspect unchanged state.

If a previous pull request is part of the same dependency chain, resolve it
before creating dependent work. Independent work may proceed in parallel when
it cannot conflict.

### Delivery flow

For each task, follow this state machine:

inspect
→ latest base
→ task branch
→ smallest complete implementation
→ draft pull request (human-owned)
→ targeted checks
→ full CI
→ deploy validation when applicable
→ self-review exact diff
→ ready for review
→ merge
→ refresh base

Deployment is a separate protected step after merge.

### Pull requests

The responsible human contributor creates the pull request under their own
identity, or explicitly authorizes an agent to create it using that identity.
Agents prepare the branch, commits, description and review materials. Never
substitute the agent's account as PR creator without explicit authorization.

Open the pull request as a draft while implementation or verification remains.

Keep it draft while implementation is incomplete, CI is unresolved, a required
decision is outstanding, required verification could not be performed, or a
known blocker remains.

Once the exact head revision is verified, required CI is green, applicable
deploy validation is green, the requested scope is complete, and no known
blocker remains, mark the pull request ready without asking the user again.

Merge only with explicit human authorization and when all of the
following are true:

- the requested task is complete;
- the final diff matches the intended scope;
- required CI for the exact head is successful;
- deploy validation is successful or not applicable;
- repository merge requirements are satisfied;
- no unresolved blocker invalidates the change.

Use an allowed repository merge method. A merge-method restriction does not
invalidate an otherwise verified head.

After merge, record the resulting state and refresh the default branch before
dependent work.

### Verification

Treat CI as the authoritative correctness gate where CI exists.

Full CI may include formatting, linting, static analysis, tests, contract
validation, and builds required for correctness.

Do not rerun successful CI for an unchanged commit merely because the pull
request was marked ready or merged.

Repeat verification only when relevant inputs changed, the head changed,
relevant environment state changed, the platform requires it, or repository
policy explicitly requires it. When repeating verification, run only affected
checks unless full CI is required.

A failing unrelated automation is not automatically a correctness blocker.
Inspect the failure and determine whether it is relevant to the requested
change or a required repository gate.

Never claim a check passed unless its result was actually observed.

### Deploy validation

Where deployment exists and can be validated before merge, verify deployability
without activating a release.

Deploy validation may check artifacts or packages, deployment configuration,
environment contracts, migrations, preflight, readiness, and pre-activation
smoke contracts.

Reuse CI artifacts and results where possible. Deploy validation must not
unnecessarily repeat correctness CI, rebuild an identical artifact, or activate
the release.

### Deployment

Deployment always requires explicit user authorization, even after an automatic
merge.

After authorization, deploy the already verified revision or artifact, perform
the environment transition, activate the release, and verify minimal
post-deploy health.

Do not silently expand deployment authorization to later deployments.

### Engineering behavior

Inspect before modifying.

Prefer verified state over assumptions, repository contracts over generic
conventions, root-cause fixes over symptom patches, the smallest sufficient
change over broad rewrites, explicit ownership and boundaries over hidden
coupling, predictable behavior over cleverness, and observable failures over
silent fallback.

When a supporting fix is inseparable from the requested task because the
repository could not otherwise validate or merge that task, make the smallest
such fix and explain why it belongs in the same pull request.

Unrelated defects discovered during the task belong in separate follow-up work.

### Tool behavior

Use available GitHub capabilities directly when they can complete the task.
Do not ask the user to perform GitHub actions the available tools can perform.

Prefer batched independent reads and precise writes. Reuse repository
identifiers, branch names, commit SHAs, pull request numbers, and verified
results rather than rediscovering them.

Inspect detailed CI logs only for failed or ambiguous checks. Do not poll state
that cannot yet have changed.

Never report repository state, successful writes, merges, CI results, or
deployment results without evidence from the corresponding operation.

### Reporting

Report outcomes, not tool choreography.

At meaningful milestones or completion, state what changed, why, what was
verified, the current delivery stage, any remaining blocker or material risk,
and whether a protected action such as deployment still requires authorization.

Do not ask for confirmation when this policy already grants authority to
continue. Identity-use authorization is single-use by default; durable
permission requires explicit scope and duration. Obtain explicit authorization
for merge and deploy. If blocked, report the exact state reached.
