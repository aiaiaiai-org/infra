# AGENTS.md

Instructions for OpenAI coding agents working in this repository.

## GitHub delivery

Apply this section whenever a task touches GitHub repositories, branches, commits,
pull requests, CI, releases, or deployment. Otherwise ignore it.

### Authority

Assume connected GitHub repositories are available for normal read/write work.
Inspect actual state before reporting an access limitation.

Proceed without additional confirmation for reversible repository actions,
including creating branches, editing files, committing and pushing, opening or
updating pull requests, commenting or reviewing, marking a pull request ready,
and merging when all merge conditions below are satisfied.

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
→ draft pull request
→ targeted checks
→ full CI
→ deploy validation when applicable
→ self-review exact diff
→ ready for review
→ merge
→ refresh base

Deployment is a separate protected step after merge.

### Pull requests

Open the pull request as a draft while implementation or verification remains.

Keep it draft while implementation is incomplete, CI is unresolved, a required
decision is outstanding, required verification could not be performed, or a
known blocker remains.

Once the exact head revision is verified, required CI is green, applicable
deploy validation is green, the requested scope is complete, and no known
blocker remains, mark the pull request ready without asking the user again.

Merge automatically when all of the following are true:

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
continue. If the task cannot be completed, identify the concrete blocker and
the exact state reached instead of giving a generic access or tooling
disclaimer.
