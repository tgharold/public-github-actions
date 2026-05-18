# Build Counter — Technical Reference

Architecture decisions, security design, and concurrency model for the build counter system.

## Contents

- [Build Counter — Technical Reference](#build-counter--technical-reference)
  - [Contents](#contents)
  - [Why Git Tags as a Counter](#why-git-tags-as-a-counter)
  - [Tag Namespace Design](#tag-namespace-design)
  - [Counter Repository Ownership](#counter-repository-ownership)
  - [Concurrency Model](#concurrency-model)
    - [Layer 1 — Workflow-level serialization (concurrency group)](#layer-1--workflow-level-serialization-concurrency-group)
    - [Layer 2 — Optimistic locking in the action](#layer-2--optimistic-locking-in-the-action)
  - [16-Bit Counter Range](#16-bit-counter-range)
    - [Rollover recovery](#rollover-recovery)
  - [Security Design](#security-design)
    - [GitHub App blast radius](#github-app-blast-radius)
    - [Tag ruleset](#tag-ruleset)
    - [Short-lived tokens](#short-lived-tokens)
    - [Audit log (GitHub Enterprise)](#audit-log-github-enterprise)
  - [Supply-chain hardening](#supply-chain-hardening)
  - [Workflow Inventory](#workflow-inventory)

---

## Why Git Tags as a Counter

Build counters need a single source of truth for sequential integers under concurrent writes. Common approaches:

| Approach | Problem |
|----------|---------|
| Database (Redis, SQL) | External service to provision, monitor, and keep available |
| GitHub API (issues, releases) | Rate limits; API calls are not atomic under concurrency |
| Repository file (commit a counter) | Merge conflicts; requires `contents: write` on every calling repo |
| Git tag push | Atomic at the ref level; native to GitHub; no external service |

Git's ref push atomicity is the key property: if two workflows simultaneously try to push the same tag name, exactly one succeeds and the other receives a push rejection. This is optimistic locking with zero infrastructure.

---

## Tag Namespace Design

Counter tags follow this scheme:

```
_counters/{calling-org}/{calling-repo}/{counter_key}-{N}
```

- **`_counters/` prefix** — underscore prefix groups counter tags visually and makes them easy to filter or list.
- **`{calling-org}/{calling-repo}`** — identifies *who is counting*, not where the counter lives. Two different orgs can share one counter store and their namespaces never collide.
- **`{counter_key}`** — allows a single repo to maintain multiple independent counters (e.g. `web`, `mobile`, `api`). Also the recovery lever for rollover: changing the counter_key starts a new sequence from 1 with no central repo access required.
- **`{N}`** — the counter value. Only the highest tag per `{org}/{repo}/{counter_key}` is retained; the previous tag is deleted after each successful allocation.

---

## Counter Repository Ownership

The `build-counter` repository and the GitHub App registration live in one owning org. Calling workflows in other orgs need no install or registration — they just need read access to the counter repository and the app credentials stored in their org.

```
Owning org
├── build-counter repository  ← all tags written here
└── GitHub App registration   ← installed only on build-counter

Calling org A
├── service-a workflows       ← calls reusable workflows
└── org variables/secrets     ← BUILD_COUNTER_APP_ID, BUILD_COUNTER_APP_PRIVATE_KEY,
                                 BUILD_COUNTER_REPO_OWNER (GHE multi-org only)

Calling org B
└── (same as org A)
```

For single-org GitHub Teams tenants, owning org = calling org and `BUILD_COUNTER_REPO_OWNER` is not needed.

---

## Concurrency Model

Counter allocation uses two layers of concurrency control:

### Layer 1 — Workflow-level serialization (concurrency group)

Each reusable workflow job sets a concurrency group scoped to the caller repository and counter_key, derived directly from `${{ github.repository }}`:

```
build-counter-{github.repository}-{counter_key}
```

Two builds of `org/service-a` with counter_key `repo` queue behind each other. Two builds of `org/service-a` and `org/service-b` run in parallel — they write to different tag prefixes and cannot conflict.

The caller does not need to pass its repository name; `github.repository` resolves to the calling repo even when the workflow is invoked from another repository via `workflow_call`.

### Layer 2 — Optimistic locking in the action

If two workflows slip through the concurrency group simultaneously (e.g. because they use different groups or the group transitions), the tag push itself is atomic. The losing workflow retries with random jitter (3–12 seconds) up to `max_retries` times.

Both layers together make allocation robust under all practical concurrency scenarios.

---

## 16-Bit Counter Range

Counter values are capped at 65,535 (wrapping to 0 on overflow). This is a deliberate constraint, not a limitation:

- **NPM** rejects semver patch values greater than 65,535.
- Other build systems (NuGet, Maven) accept larger values, but the 16-bit cap ensures compatibility with the strictest consumer.

At 50 builds per day, a single counter takes ~3.6 years to reach 65,535. Because counters are scoped per calling repo per counter_key, the realistic per-counter_key build rate is much lower than the enterprise aggregate.

### Rollover recovery

At build number ≥ 65,500 the action **fails** with a `::error::` annotation, blocking the build. At build number 65,000–65,499 it emits a `::warning::` annotation as advance notice (~500 builds of runway). At rollover it emits another warning.

Recovery is self-service: change the `counter_key` in the calling workflow (e.g. `repo` → `repo2`). The new counter_key starts from 1. No access to the central `build-counter` repository is required, and no coordination with the counter store owner is needed.

---

## Security Design

### GitHub App blast radius

The GitHub App is installed on **one repository only** (usually `build-counter`) and has one permission: **Contents: read and write**. A compromised private key allows an attacker to:

- Write or delete tags in `build-counter` — disrupting counter sequences
- Nothing else — no access to Actions, secrets, code in any other repository

This is the intentional blast radius. The counter store is a throwaway tag store; disrupting it delays builds but does not expose code, secrets, or infrastructure.

### Tag ruleset

A tag ruleset on `_counters/**` in the build counter repository restricts tag creation and deletion to the GitHub App. The app is the only actor in the bypass list. Org admins cannot modify counter tags without being explicitly added to the bypass list.

This prevents:
- Manual tag manipulation that would corrupt counter state
- Privilege escalation via a counter reset

### Short-lived tokens

The action uses `actions/create-github-app-token` to generate a fresh installation token per run. Tokens expire after 1 hour. There is no annual rotation requirement.

To rotate the private key: generate a replacement in the App settings, update `BUILD_COUNTER_APP_PRIVATE_KEY` everywhere it is stored, then revoke the old key. No workflow downtime is required during the transition — old and new keys are valid simultaneously until the old one is revoked.

On GitHub Enterprise without enterprise-level secrets, the key must be updated in every calling org individually. This is the primary operational reason to use enterprise-level secrets if available.

### Audit log (GitHub Enterprise)

Every installation token generation appears in the organization audit log. Anomalous generation volume or unexpected timing is detectable.

---

## Supply-chain hardening

The GitHub App token has `Contents: write` on `build-counter`. Any executable file that lives in the build counter repository is reachable by a stolen app key: an attacker could modify it and wait for the next admin or workflow to run the tampered copy.

To eliminate that path, every piece of executable content related to the counter system lives here in [`ritterim/public-github-actions`](https://github.com/ritterim/public-github-actions), where the build-counter GitHub App has no write access:

- The composite action (`action.ps1`, `action.yml`)
- The reusable workflows (`build-counter-allocator.yml`, `calculate-version-using-build-counter-allocator.yml`)
- The operator setup scripts (`setup-app-installation.ps1`, `setup-ruleset.ps1`) — note that the setup scripts run with **admin:org** scope on an operator's laptop, a strictly higher-trust context than the workflow runtime; keeping them off `build-counter` is the more important of the two moves.

The build counter repository itself is a pure tag store with no executable content. Even full write access to the build counter repository  does not let an attacker tamper with the code that callers — or admins — execute.

---

## Workflow Inventory

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `build-counter-allocator.yml` | `workflow_call`, `workflow_dispatch` | Allocate a counter only; no version calculation |
| `calculate-version-using-build-counter-allocator.yml` | `workflow_call`, `workflow_dispatch` | Allocate a counter and compute a full semver. The `version_source` input selects between `version_txt` (read `major.minor` from `version.txt`) and `parameters` (use the `major_minor_version` input) |
| `test-build-counter-allocator-workflow.yml` | `push`, `pull_request`, `workflow_dispatch` | Internal smoke test for `build-counter-allocator.yml`; not intended to be called by consumers |
