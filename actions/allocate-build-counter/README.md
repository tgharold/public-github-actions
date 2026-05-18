# Allocate Build Counter Action

This composite GitHub Action allocates a monotonic build counter (0-65535) using Git tags written to a dedicated central repository. It solves the problem of safely generating sequential build numbers in concurrent CI/CD workflows without requiring external services or databases.

## How It Works

Counter tags live in a shared build counter repository (usually `build-counter`) and are namespaced by the calling repository:

```
_counters/{owner}/{repo}/{counter_key}-{number}
```

The action uses a GitHub App installed on the build counter repository to generate a short-lived token, then clones that repository and uses Git's atomic tag push semantics to implement optimistic locking:

1. **Clone counter repo** using the short-lived app token
2. **Fetch existing tags** matching the calling repo's namespace
3. **Calculate next number** by incrementing the highest existing tag (rolls over at 65536)
4. **Push new tag** — atomic via git; fails if another workflow pushed the same tag first
5. **Delete old tag** for the same namespace (one tag retained per calling repo per counter_key)
6. **Retry on conflicts** with random jitter until `max_retries` is exhausted
7. **Output build number and tag name** for downstream use

This approach is:
- **Lock-free**: No external coordination beyond Git's native ref atomicity
- **Concurrent-safe**: Optimistic locking with jitter handles simultaneous allocations from multiple repos
- **Bounded storage**: Only the latest tag per calling repo per counter_key is retained
- **No PAT expiry**: Short-lived app tokens are generated fresh each run

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `counter_key` | No | `repo` | Identifies which counter sequence to allocate from. Appears as the last path segment of the tag. Use distinct values to maintain parallel counters in the same repo, or to start a fresh sequence after rollover (e.g. `repo` → `repo2`). Must be alphanumeric, 1-32 chars. |
| `max_retries` | No | `25` | Maximum retry attempts if tag push conflicts occur (1-100). |
| `app_id` | No | — | GitHub App ID with Contents write access on the counter repository. |
| `private_key` | No | — | GitHub App private key (PEM format). |
| `counter_repo_owner` | No | Calling repo's owner | Owner of the `build-counter` repository. |
| `counter_repo_name` | No | `build-counter` | Name of the counter repository. |

## Read-Only Mode

If `app_id` is not provided (i.e. the calling workflow omitted `counter_app_id` and the private key), the action returns `0` as the build number without writing anything to the counter repository. This is the intended behavior for PR builds, which use a PR-number version suffix to ensure version uniqueness regardless of the counter value.

## Outputs

| Output | Description |
|--------|-------------|
| `build_number` | The allocated build number (0-65535). Rolls over after 65535. `0` in read-only mode. |
| `tag` | The full Git tag name that was created (e.g. `_counters/my-org/my-repo/repo-42`). |

## Usage

### Basic Usage

```yaml
- uses: ritterim/public-github-actions/actions/allocate-build-counter@v1.17
  id: allocate
  with:
    app_id: ${{ vars.BUILD_COUNTER_APP_ID }}
    private_key: ${{ secrets.BUILD_COUNTER_APP_PRIVATE_KEY }}

- run: echo "Build number is ${{ steps.allocate.outputs.build_number }}"
```

### Custom Counter Key (Multiple Independent Counters per Repo)

```yaml
- uses: ritterim/public-github-actions/actions/allocate-build-counter@v1.17
  id: allocate
  with:
    app_id: ${{ vars.BUILD_COUNTER_APP_ID }}
    private_key: ${{ secrets.BUILD_COUNTER_APP_PRIVATE_KEY }}
    counter_key: mobile-app
    max_retries: 50

- run: echo "Mobile build number is ${{ steps.allocate.outputs.build_number }}"
```

### Usage in Version Calculation

```yaml
- uses: ritterim/public-github-actions/actions/allocate-build-counter@v1.17
  id: allocate
  with:
    app_id: ${{ vars.BUILD_COUNTER_APP_ID }}
    private_key: ${{ secrets.BUILD_COUNTER_APP_PRIVATE_KEY }}

- run: |
    MAJOR_MINOR="$(awk 'NF {print; exit}' version.txt | xargs)"
    VERSION="${MAJOR_MINOR}.${{ steps.allocate.outputs.build_number }}"
    echo "Calculated version: $VERSION"
```

## Implementation Details

### Concurrency Handling

The action uses optimistic locking with random backoff:
- If a tag push fails (another workflow beat us to it), we fetch fresh tags, recalculate, and retry
- Random sleep (3-12 seconds) between retries prevents thundering herd
- Maximum of `max_retries` attempts before failing

### Rollover Behavior

Build numbers wrap at 65536 (0-65535, 16-bit). At build number ≥ 65,500 the action fails with a `::error::` annotation and blocks the build. At build number 65,000–65,499 it emits a `::warning::` annotation as advance notice (~500 builds of runway). At rollover to 0 it emits another warning.

To avoid hitting the hard limit, change the `counter_key` in the calling workflow (e.g. `repo` → `repo2`) before your counter reaches 65,500. The new counter_key starts a fresh sequence from 1. No access to the central repository is required.

### Tag Cleanup

After each successful allocation, the action deletes the previous tag for the same namespace from the counter repository. Only one tag per `{owner}/{repo}/{counter_key}` is retained at any time.

### Workflow Cancellation

If a workflow is cancelled after a tag is written, the counter slot is skipped. Gaps in the sequence are normal and harmless — subsequent runs continue from the next available number.

## Troubleshooting

### "Failed to allocate build counter after N attempts"

Likely causes:
- High concurrency: increase `max_retries`
- App ID or private key missing: ensure `BUILD_COUNTER_APP_ID` (org variable) and `BUILD_COUNTER_APP_PRIVATE_KEY` (org secret) are available and explicitly passed by the calling workflow
- Counter repo unreachable: verify the app is installed on `build-counter` and the secrets are correct

### Build number is always 0

The action is running in read-only mode — `app_id` was not provided. Check that `counter_app_id` (and the private key secret) are passed by the workflow job that calls this action.

Pull requests callers will also get zero by design.

### Counter reset unexpectedly

A tag push failure followed by a retry will re-read the counter state from the remote. If the old tag was deleted before the new one was pushed successfully, and the push then failed, a subsequent retry will see no tags and restart from 1. This is rare but possible under network errors. Increase `max_retries` to reduce the window.

## Requirements

### GitHub App

The action requires a GitHub App with **Contents: read and write** installed on the `build-counter` repository. See [BUILD-COUNTER-USAGE.md](./BUILD-COUNTER-USAGE.md) for full setup instructions.

These values must be accessible to the workflow (typically as org-level variable and secret):

| Name | Type | Notes |
|------|------|-------|
| `BUILD_COUNTER_APP_ID` | Org variable | GitHub App's numeric ID (not sensitive) |
| `BUILD_COUNTER_APP_PRIVATE_KEY` | Org secret | GitHub App private key (PEM format) |
| `BUILD_COUNTER_REPO_OWNER` | Org variable | Owner of the `build-counter` repository. Only needed on GitHub Enterprise with multiple organizations — leave unset on single-org (Teams) tenants. |

The calling workflow itself does **not** need `contents: write`.

### Runner Requirements

- PowerShell 7.0+ (available on all GitHub Actions runners)
- `git` (standard on GitHub Actions runners)
- Internet access to clone the build counter repository via HTTPS

## Security

The GitHub App private key is the primary sensitive credential. If compromised, an attacker can generate tokens for the app's installation — which covers **only** the build counter repository. They can write tags to that one repository and nothing else.

Key mitigations:

- **Single-repo installation** — the app is installed on the build counter repository only. No other repository is reachable with the token.
- **Ruleset bypass** — a tag ruleset on `_counters/**` restricts creation and deletion to the app. Even org admins cannot modify counter tags without being in the bypass list.
- **Minimal permissions** — the app has only `Contents: read and write`. No Actions, secrets, workflow, or administration access.
- **Short-lived tokens** — installation tokens expire after 1 hour and are generated fresh each run. The private key itself does not expire but can be rotated by generating a replacement, updating the org secret, and revoking the old key.

## Related Workflows

| Workflow | Use when |
|----------|----------|
| [`build-counter-allocator.yml`](../../.github/workflows/build-counter-allocator.yml) | You only need a monotonically increasing number |
| [`calculate-version-using-build-counter-allocator.yml`](../../.github/workflows/calculate-version-using-build-counter-allocator.yml) | You want a full semver — set `version_source: version_txt` to read `major.minor` from `version.txt`, or `version_source: parameters` to pass it as the `major_minor_version` input |
