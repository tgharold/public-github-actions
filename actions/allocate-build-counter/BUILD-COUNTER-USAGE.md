# Build Counter Usage Guide

The build counter allocates a monotonically increasing integer (0–65535 with rollover) for each build by writing a lightweight Git tag to a dedicated central repository. It requires a single GitHub App and no external services or databases.

## Contents

- [How It Works](#how-it-works)
- [Setup](#setup)
  - [One-Time Setup](#one-time-setup)
  - [Per-Org Setup](#per-org-setup-done-for-each-calling-org)
- [Security](#security)
- [Using the Build Counter in Your Repository](#using-the-build-counter-in-your-repository)
- [Inspection and Troubleshooting](#inspection-and-troubleshooting)
- [Behavior Reference](#behavior-reference)

---

## How It Works

Counter tags live in a single shared `build-counter` repository rather than in each calling repository. Tags are namespaced by the calling repository:

```
_counters/{owner}/{repo}/{counter_key}-{number}
```

Example: `_counters/my-org/my-service/repo-42`

A GitHub App installed **only** on `build-counter` generates short-lived tokens to write tags there. Calling repositories never need `contents: write` and the app's blast radius is limited to one throwaway repo.

One `build-counter` repository and one GitHub App registration serve the entire enterprise — all organizations share the same counter store.

---

## Setup

Setup has two phases: **one-time setup** (done once, regardless of plan) and **per-org setup** (done for each additional organization whose workflows will call the counter — only relevant on GitHub Enterprise with multiple orgs).

---

### One-Time Setup

Run these steps once from the org that will own the `build-counter` repository. For single-org tenants (e.g. GitHub Teams plan), this is the complete setup — the Per-Org Setup section does not apply.

#### 1. Create the counter repository

Create a private repository named `build-counter` in the owning org. Initialize it with a single commit (e.g. a README) so it has a valid HEAD for tag operations.

This repository can be the single tag store for all orgs in the enterprise. The owning org does not need to be the same org as the calling repositories. The counter repository hosts no workflows or action code; calling workflows clone it solely to read and write `_counters/**` tags via the GitHub App token.

#### 2. Register the GitHub App

Navigate to `https://{hostname}/organizations/{org}/settings/apps/new` and fill in the form:

| Field | Value |
|-------|-------|
| GitHub App name | `Build Counter ({org display name})` — include the org name to avoid ambiguity across the enterprise |
| Homepage URL | URL of the `build-counter` repository |
| Webhook | Uncheck **Active** — no webhook needed |
| Repository permissions → Contents | **Read and write** |
| Where can this app be installed? | **Only on this account** |

Click **Create GitHub App**. On the resulting page, note the **App ID** (numeric) and **slug** (from the page URL: `.../apps/{slug}`).

Scroll to the **Private keys** section and click **Generate a private key** — GitHub downloads a `.pem` file. **Store the PEM contents in a secure location immediately** — this specific key cannot be retrieved again from GitHub. Generating a replacement requires updating the secret in every org that uses the counter, so losing the key has real operational cost.

##### Handling the private key

The PEM is multi-line and must be preserved verbatim, including the `-----BEGIN ...-----` and `-----END ...-----` lines. Store it wherever your organization keeps high-value secrets — typically a password manager that supports multi-line content and a master-password re-prompt on access, or a sealed entry in a secrets vault.

Recommended hygiene:

1. Copy the PEM contents straight from the downloaded file into your chosen secret store; do not paste it into chat, email, or shared notes.
2. Delete the downloaded `.pem` file from disk once it is safely stored.
3. Enable any "require master password to view/copy" option your secret store provides for this item.
4. Use a short clipboard auto-clear timeout (e.g. 30 seconds) when copying the PEM into the installation prompt in the next step, so the key does not linger on the clipboard.

One registration serves the entire enterprise. Do not repeat this step for additional orgs.

#### 3. Install and configure

The owning org now needs three things wired up: the app installed on its counter repository, the app credentials stored as org variable + secret, and a tag ruleset on `_counters/**` that limits writes to the app.

Two ways to do that:

##### Option A — use the helper scripts in this action directory

Two PowerShell scripts live alongside this guide in [`actions/allocate-build-counter/`](.). They live here, not in the counter repository, so that the GitHub App that writes counter tags has no path to tamper with them.

Run them from any working directory; the counter repository does not need to be cloned locally — the scripts target it via the `-CounterRepository` parameter.

```powershell
# Omit -PrivateKeyFile so the script prompts for the PEM and you can paste it
# directly from your secret store (no .pem file on disk).
./setup-app-installation.ps1 -Hostname github.com -CounterRepository my-org/build-counter -AppId 123456 -AppSlug my-org-build-counter
```

If you have already saved the PEM to a file for some other reason, pass it explicitly:

```powershell
./setup-app-installation.ps1 -Hostname github.com -CounterRepository my-org/build-counter -AppId 123456 -AppSlug my-org-build-counter -PrivateKeyFile ./build-counter-app.pem
```

The script:
- Guides installation of the app on **only** the counter repository
- Stores `BUILD_COUNTER_APP_ID` as an org-level variable in the owning org (the org part of `-CounterRepository`)
- Stores `BUILD_COUNTER_APP_PRIVATE_KEY` as an org-level secret in the owning org
- Runs the companion `setup-ruleset.ps1` against the counter repository to lock down `_counters/**` tags

##### Option B — perform the steps manually

The same outcome can be reached by hand, which is what to do if you cannot run the helper scripts or want a fully audited path:

1. **Install the app on the counter repository.**
   Open `https://{hostname}/apps/{app-slug}/installations/new`, choose **Only select repositories**, and pick the counter repository only. Verify afterwards via the org's installation list (`Settings → Integrations → GitHub Apps`) that the install scope is **Selected repositories**, not **All repositories**.

2. **Store the app ID and private key in the owning org.**

   ```bash
   # App ID — not sensitive, store as org variable.
   gh variable set BUILD_COUNTER_APP_ID --org my-org --body "123456"

   # Private key — sensitive, store as org secret. Pipe the PEM from your
   # secret store into stdin so it never lands on disk in the clear.
   gh secret set BUILD_COUNTER_APP_PRIVATE_KEY --org my-org < /path/to/key.pem
   ```

3. **Create the tag ruleset** on the counter repository that restricts `_counters/**` to the app. Navigate to the counter repo → **Settings → Rules → Rulesets → New tag ruleset** and configure:
   - Target tags: include pattern `_counters/**`
   - Enforcement status: **Active**
   - Bypass list: add the GitHub App (the one you just registered) as the **only** entry
   - Rules: enable **Restrict creations**, **Restrict updates**, and **Restrict deletions**

   This is what `setup-ruleset.ps1` automates; the script is a short, readable reference if you prefer the API path.

After either option, the owning org is fully configured.

---

### Per-Org Setup (done for each calling org)

For each additional organization whose workflows will call the counter, store the same credentials (the app registration and installation do not need to be repeated):

| Name | Type | Value |
|------|------|-------|
| `BUILD_COUNTER_APP_ID` | Org variable | The app's numeric ID (not sensitive) |
| `BUILD_COUNTER_APP_PRIVATE_KEY` | Org secret | The app's private key (PEM format) |
| `BUILD_COUNTER_REPO_OWNER` | Org variable | The org that owns the `build-counter` repository (e.g. `my-owning-org`) |

`BUILD_COUNTER_REPO_OWNER` tells the reusable workflows where to find the counter repository. It is not needed for single-org tenants (GitHub Teams) — leave it unset and the workflows default to the calling repo's own org.

Then allow the calling org to consume the reusable workflows from the repository that hosts them (for RitterIM that is `ritterim/public-github-actions`; for a private fork, your own actions repository):

1. Navigate to **Settings → Actions → General** in the calling org
2. Select **"Allow reusable workflows from selected repositories"**
3. Add the actions/workflows repository (e.g. `ritterim/public-github-actions`) to the allowlist

If the actions repository is **private**, you also need to configure its **Settings → Actions → General → Access** to be reachable from the calling org or enterprise. Public repositories are accessible to all callers by default.

If your GitHub Enterprise tier supports enterprise-level variables and secrets, store the credentials once at the enterprise level instead of repeating per org.

---

## Security

The GitHub App private key is the primary sensitive credential. If compromised, an attacker can generate tokens for the app's installation — which covers only `build-counter`. They can write tags to that one repo and nothing else.

**Ruleset bypass list** — the app is the only actor in the bypass list for the `_counters/**` tag ruleset. Even org admins cannot modify counter tags without being explicitly added.

**Minimal permissions** — the app has only `Contents: read and write`. It cannot touch Actions, secrets, workflows, or any repository other than `build-counter`.

**No PAT expiry** — GitHub Apps use short-lived installation tokens (1 hour). There is no annual rotation requirement. Rotate the private key by generating a replacement from the App settings, updating `BUILD_COUNTER_APP_PRIVATE_KEY` everywhere it is stored, then revoking the old key. No workflow downtime required.

On GitHub Enterprise with multiple orgs and no enterprise-level secrets, the secret must be updated in every calling org individually. This is the primary operational reason to store credentials at the enterprise level if your tier supports it.

**Audit log** (GitHub Enterprise) — every installation token generation is logged. Anomalous generation volume or unexpected timing is detectable.

---

## Using the Build Counter in Your Repository

### 1. Choose Your Approach

Both approaches are hosted in a shared central repository and called via reusable workflows.

**Option A: Use `calculate-version-using-build-counter-allocator.yml`** (recommended)
- Allocates a counter and computes a full semver in one workflow
- Best when: You need version information for your build artifacts
- Pick your version source:
  - `version_source: version_txt` — read `major.minor` from `version.txt`
  - `version_source: parameters` — pass `major_minor_version` directly

**Option B: Use `build-counter-allocator.yml`** (minimal allocation only)
- Allocates a counter number without version calculation
- Best when: You only need a monotonically increasing counter

### 2. Set Up Your Workflow

> Examples target `ritterim/public-github-actions@v1.17`. Private forks should substitute their own org/repo path.

**If using `calculate-version-using-build-counter-allocator.yml` (recommended), reading major.minor from `version.txt`:**

```yaml
jobs:
  version:
    uses: ritterim/public-github-actions/.github/workflows/calculate-version-using-build-counter-allocator.yml@v1.17
    with:
      version_source: version_txt
    secrets:
      BUILD_COUNTER_APP_PRIVATE_KEY: ${{ secrets.BUILD_COUNTER_APP_PRIVATE_KEY }}

  build:
    needs: version
    runs-on: ubuntu-latest
    steps:
      - name: Use version
        run: echo "Version: ${{ needs.version.outputs.version }}"
```

Or pass `major.minor` as an input instead of reading `version.txt`:

```yaml
jobs:
  version:
    uses: ritterim/public-github-actions/.github/workflows/calculate-version-using-build-counter-allocator.yml@v1.17
    with:
      version_source: parameters
      major_minor_version: "10.1"
    secrets:
      BUILD_COUNTER_APP_PRIVATE_KEY: ${{ secrets.BUILD_COUNTER_APP_PRIVATE_KEY }}
```

The reusable workflow reads `vars.BUILD_COUNTER_APP_ID` and `vars.BUILD_COUNTER_REPO_OWNER` from the calling org automatically — no need to pass them explicitly. PR builds receive `build_number=0` automatically; non-PR builds without the secret fail loudly so misconfiguration cannot silently ship `build_number=0`.

**If using `build-counter-allocator.yml`:**

```yaml
jobs:
  allocate:
    uses: ritterim/public-github-actions/.github/workflows/build-counter-allocator.yml@v1.17
    with:
      counter_key: repo
      max_retries: 25
    secrets:
      BUILD_COUNTER_APP_PRIVATE_KEY: ${{ secrets.BUILD_COUNTER_APP_PRIVATE_KEY }}
```

### 3. Permissions and Counter Allocation

Calling workflows do **not** need `contents: write`. The app token is generated inside the called workflow using the app ID and private key passed in.

**For trunk and release builds** (counter increments required):

Pass the secret. `vars.BUILD_COUNTER_APP_ID` and `vars.BUILD_COUNTER_REPO_OWNER` are read by the reusable workflow automatically:

```yaml
jobs:
  version:
    uses: ritterim/public-github-actions/.github/workflows/calculate-version-using-build-counter-allocator.yml@v1.17
    with:
      version_source: version_txt
    secrets:
      BUILD_COUNTER_APP_PRIVATE_KEY: ${{ secrets.BUILD_COUNTER_APP_PRIVATE_KEY }}
```

If the secret is missing on a non-PR event, the action fails loudly — there is no silent fallback to `build_number=0`.

**For PR builds** (counter increment not required):

On a `pull_request` event the action automatically returns `build_number=0` without allocating, even if a secret is present. The PR version suffix (`-pr123.456.1`) keeps the version unique. You can still pass the secret unconditionally; the workflow does the right thing per event.

### 4. Prevent Accidental Cancellation

Set `cancel-in-progress: false` in your workflow:

```yaml
concurrency:
  group: my-workflow
  cancel-in-progress: false
```

**Why:** Once a tag is written, cancelling the run wastes a counter slot. Gaps in the counter sequence are normal and harmless, but avoiding them keeps version numbers tidy.

### 5. Access the Counter and Version Values

Counter tags are written to the build counter repository in the namespace `_counters/{owner}/{repo}/{counter_key}-{number}`.

**If using `calculate-version-using-build-counter-allocator.yml`**, access the version output:

```yaml
build:
  needs: version
  runs-on: ubuntu-latest
  steps:
    - name: Use version
      run: echo "Version: ${{ needs.version.outputs.version }}"
```

**If using `build-counter-allocator.yml`**, access the counter value:

```yaml
build:
  needs: allocate
  runs-on: ubuntu-latest
  steps:
    - name: Use counter
      run: echo "Build number: ${{ needs.allocate.outputs.build_number }}"
```

---

## Inspection and Troubleshooting

Counter tags live in the build counter repository (usually `build-counter`), not in the calling repository.

**View the current counter for a repository:**
```bash
git -C /path/to/build-counter fetch --tags
git -C /path/to/build-counter tag -l '_counters/my-org/my-repo/*'
```

**Reset the counter to zero:**
Delete the current tag from `build-counter`:
```bash
git push origin --delete '_counters/my-org/my-repo/repo-<N>'
```
The next run will start from `1`.

Note that there is usually a GitHub ruleset installed on the build counter repository which will prevent modification of the `_counters/**` namespace.  You may need to add your administrator/maintainer account to the allow list before making adjustments to build counter tags.

---

## Behavior Reference

**First run:** Counter automatically starts at `1`. No bootstrap required.

**Rollover:** At 65,536, the counter wraps to `0` (16-bit limit; required by build systems such as NPM that reject larger patch values). The action **fails** with an error annotation at 65,500, blocking the build as a safeguard against rollover. A workflow warning annotation starts firing at 65,000 as advance notice (~500 builds of runway). To avoid hitting the hard limit, change the `counter_key` in your calling workflow (e.g. `repo` → `repo2`) before your counter reaches 65,500 — the new counter_key starts a fresh sequence from 1.

**Tag cleanup:** The allocator deletes the previous tag after each successful allocation. Only the current counter value is retained per calling repository per counter_key.

**Corrupted tags:** The allocator self-heals around foreign tags. If a tag's post-prefix portion is non-numeric (e.g. `_counters/my-org/my-repo/repo-abc`), the allocator ignores it for both allocation and cleanup; the next allocation continues from the highest valid numeric tag. You can delete foreign tags manually from `build-counter` at any time, but no immediate action is required.
