<#
.SYNOPSIS
Allocates unique, incrementing build numbers for distributed CI/CD workflows.

.DESCRIPTION
Uses git tags in a central repository as a distributed counter to allocate unique build numbers.
Each build reserves a number by creating and pushing a tag, with random jitter (3-12s) between
retries to handle concurrent builds. Numbers wrap around at 65535 (0-65535 range, 16-bit unsigned).

.PARAMETER CounterKey
Alphanumeric identifier (1-32 chars) that selects which counter sequence to allocate from.
Used as the last path segment of the tag.
Example: 'repo' creates tags like '_counters/org/repo/repo-1', '_counters/org/repo/repo-2'

.PARAMETER MaxRetries
Maximum attempts to allocate a build number (1-100). Each attempt waits for random jitter (3-12s).
Default: 25 retries; worst-case ~190 seconds of jitter wait plus ~38 seconds of git work.

.PARAMETER AppToken
GitHub personal access token for writing to the counter repository. If not provided and
APP_TOKEN env var is not set, runs in read-only mode and returns build_number=0.

.PARAMETER NoRun
Switch for testing only. When set, loads functions but skips execution of main logic.

.OUTPUTS
GitHub action outputs:
  build_number - The allocated build number (0 if in read-only mode)
  tag - The git tag created for this build counter
#>

#Requires -Version 7.0

param(
    [string] $CounterKey = 'repo',
    [int] $MaxRetries = 25,
    [switch] $NoRun
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

function Test-ValidCounterKey {
    param([string] $CounterKey)
    if ($CounterKey -notmatch '^[a-zA-Z0-9]{1,32}$') {
        Write-Error "counter_key must be alphanumeric, 1-32 chars, got: $CounterKey"
        return $false
    }
    return $true
}

function Test-ValidMaxRetries {
    param([int] $MaxRetries)
    if ($MaxRetries -lt 1 -or $MaxRetries -gt 100) {
        Write-Error "max_retries must be 1-100, got: $MaxRetries"
        return $false
    }
    return $true
}

function Test-ValidGitHubOwner {
    param(
        [string] $Owner,
        [string] $Source = 'input'
    )
    if ($Owner -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?$') {
        Write-Error "Invalid owner from ${Source} - must be 1-39 alphanumeric/hyphen chars, no leading/trailing hyphen, got: '$Owner'"
        return $false
    }
    return $true
}

function Test-ValidRepositoryName {
    param(
        [string] $Name,
        [string] $Source = 'input'
    )
    # GitHub repo naming: 1-255 chars; first char must be alphanumeric or underscore
    # (no leading dot/dash); subsequent chars allow dot/dash/underscore; reject
    # literal '.' and '..' and consecutive dots.
    if ($Name -notmatch '^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,254}$' -or $Name -match '\.\.') {
        Write-Error "Invalid repository name from ${Source} - must be 1-255 chars, start with alphanumeric or underscore, no consecutive dots, got: '$Name'"
        return $false
    }
    return $true
}

<#
Validates that a URL is exactly the canonical GitHub.com server URL.

This validator runs on $env:GITHUB_SERVER_URL. Despite that env var being GitHub-set,
it is treated as low-trust to harden against compromised runner envs and self-hosted
runner pollution. The check is strict equality with the literal 'https://github.com'
(case-sensitive). Every variant below is intentionally rejected; the Pester suite
has a case for each one.

Rejected attack patterns:

  - Userinfo present (e.g. https://user:pass@github.com/)
      Risk: credential confusion; embedded auth-info could trick a less strict
      consumer into treating 'user:pass' as the host or as ambient auth.

  - Multiple @ characters (e.g. https://a@b@github.com/)
      Risk: host-extraction ambiguity between RFC-compliant and tolerant parsers.

  - Port confusion (e.g. https://github.com:443@evil.com/)
      Risk: looks like github.com but actually points at evil.com via userinfo
      masquerade with an embedded port-like prefix.

  - Implicit auth (e.g. https://:@github.com/)
      Risk: empty credential placeholder that can confuse URL parsers.

  - Empty host (e.g. https:///foo)
      Risk: falls through to local URL resolution depending on git config.

  - Percent-encoded host (e.g. https://github%2ecom@evil.com/)
      Risk: decoding mismatch between validator regex and the URL consumer.

  - IDN / Unicode homograph (e.g. https://gìthub.com/)
      Risk: visual lookalike that resolves to a different DNS name.

  - Trailing whitespace or control characters (e.g. https://github.com\r\n)
      Risk: header injection in the underlying HTTP request.

  - Fragment present (e.g. https://github.com#x)
      Risk: parser desync where the validator sees one host and git sees another.

  - Query string present (e.g. https://github.com?x=y)
      Risk: same parser-desync risk as fragments.

  - Path traversal (e.g. https://github.com/../)
      Risk: escape from the expected path layout.

  - Case-variant scheme or host (e.g. HTTPS://GITHUB.COM)
      Risk: bypass via case folding when downstream code does case-sensitive
      comparison.

  - Port :0 (e.g. https://github.com:0/)
      Risk: malformed shape often used to confuse parsers.

  - Host length > 253 chars
      Risk: malformed shape.

  - Trailing .git on the bare server URL (e.g. https://github.com.git)
      Risk: malformed shape; would be parsed as a different host.

Strict equality with the literal 'https://github.com' covers every pattern above.
The detailed list is preserved for audit purposes and to keep the Pester suite
easy to extend if a new pattern is discovered.
#>
function Test-ValidGitHubServerUrl {
    param(
        [string] $Url,
        [string] $Source = 'input'
    )
    if ($Url -cne 'https://github.com') {
        Write-Error "Invalid GitHub server URL from ${Source} - must be exactly 'https://github.com' (case-sensitive, no trailing slash, no userinfo, no port, no query, no fragment, no path), got: '$Url'"
        return $false
    }
    return $true
}

function Test-ValidGitCounterRepoUrl {
    param(
        [string] $Url,
        [string] $Source = 'input'
    )
    # file:// allowed for test fixtures. No token is attached on this scheme,
    # so token-exfiltration risks do not apply; tests need an arbitrary local path.
    if ($Url -like 'file://*') {
        return $true
    }
    if ($Url -notmatch '^https://github\.com/.+$') {
        Write-Error "Invalid counter repo URL from ${Source} - must be 'file:///<path>' or 'https://github.com/<owner>/<repo>...', got: '$Url'"
        return $false
    }
    return $true
}

function Get-ResolvedOrganization {
    if ($env:GITHUB_REPOSITORY_OWNER) {
        return @{ Value = $env:GITHUB_REPOSITORY_OWNER; Source = 'GITHUB_REPOSITORY_OWNER env var' }
    }
    return @{ Value = 'local-org'; Source = 'fallback default' }
}

function Get-ResolvedRepository {
    if ($env:GITHUB_REPOSITORY) {
        return @{ Value = ($env:GITHUB_REPOSITORY -split '/')[1]; Source = 'GITHUB_REPOSITORY env var' }
    }
    return @{ Value = 'local-repo'; Source = 'fallback default' }
}

function Format-GitArgsForDisplay {
    param([string[]] $Arguments)
    # Redact embedded tokens and credentials before logging.
    # Pattern 1: scheme://userinfo:token@host -> scheme://userinfo:***@host
    # Pattern 2: Authorization: token ... -> Authorization: token ***
    return $Arguments | ForEach-Object {
        $_ -replace '(://[^:/\s@]+):[^@\s]+@', '$1:***@' `
           -replace '(Authorization: token\s+)\S+', '$1***'
    }
}

function Invoke-GitCommand {
    param(
        [string[]] $Arguments,
        [string] $RepoPath = '',
        [switch] $IgnoreErrors,
        [switch] $CaptureOutput
    )

    $finalArgs = if ($RepoPath) { @('-C', $RepoPath) + $Arguments } else { $Arguments }

    $displayArgs = Format-GitArgsForDisplay -Arguments $finalArgs
    Write-Verbose "git $($displayArgs -join ' ')"

    if ($CaptureOutput) {
        $output = & git @finalArgs 2>&1
    } else {
        & git @finalArgs 2>&1 | Out-Null
    }

    if ($LASTEXITCODE -ne 0 -and -not $IgnoreErrors) {
        Write-Error "git command failed with exit code $LASTEXITCODE"
        exit 1
    }

    if ($CaptureOutput) {
        return $output
    }
}

function Initialize-CounterRepository {
    param(
        [string] $Owner,
        [string] $Name,
        [string] $Token,
        [string] $GitServer = 'https://github.com',
        [string] $RepoUrl = '',
        [string] $DestPath = ''
    )

    # Use clean URL without embedded token; authentication via http.extraheader in git commands
    $resolvedUrl = if ($RepoUrl) { $RepoUrl } else { "${GitServer}/${Owner}/${Name}.git" }
    $clonePath = if ($DestPath) { $DestPath } else { '/tmp/build-counter-repo' }

    # Validate that $clonePath is safe (under temp directory or is the hardcoded default)
    if ($clonePath -ne '/tmp/build-counter-repo') {
        $tmpRoot = [System.IO.Path]::GetTempPath()
        $resolved = [System.IO.Path]::GetFullPath($clonePath)
        if (-not $resolved.StartsWith($tmpRoot)) {
            Write-Error "DestPath must be under temp directory, got: $clonePath"
            exit 1
        }
    }

    Write-Verbose "Cloning counter repository from $Owner/$Name"
    Remove-Item -Path $clonePath -Recurse -Force -ErrorAction SilentlyContinue

    # Clone with token via header to keep it out of git config
    $authHeader = "Authorization: token $Token"
    Invoke-GitCommand @('-c', "http.extraheader=$authHeader", 'clone', '--filter=blob:none', '--no-checkout', '--depth=1', $resolvedUrl, $clonePath)

    # Ensure remote URL has no embedded credentials
    $cleanUrl = if ($RepoUrl -like 'file://*') { $RepoUrl } else { $resolvedUrl }
    Invoke-GitCommand @('remote', 'set-url', 'origin', $cleanUrl) -RepoPath $clonePath -IgnoreErrors

    Write-Verbose "Successfully cloned to $clonePath"
    return $clonePath
}

function Get-NextBuildNumber {
    param(
        [string] $RepoPath,
        [string] $TagPrefix,
        [string] $Token = ''
    )

    Write-Verbose "Fetching tags for prefix: $TagPrefix"
    $fetchArgs = if ($Token) { @('-c', "http.extraheader=Authorization: token $Token") + @('fetch', '--tags', '--force') } else { @('fetch', '--tags', '--force') }
    Invoke-GitCommand $fetchArgs -RepoPath $RepoPath -IgnoreErrors

    $allTags = Invoke-GitCommand @('tag', '-l', "${TagPrefix}*") -RepoPath $RepoPath -IgnoreErrors -CaptureOutput | Where-Object { $_ }

    # Self-healing: keep only tags whose post-prefix portion is digits-only.
    # Foreign tags (e.g. created manually, or pre-validator history) are ignored
    # for allocation purposes and left untouched on the remote.
    $prefixLen = $TagPrefix.Length
    $numericTags = @($allTags | Where-Object {
        $_.Length -gt $prefixLen -and $_.Substring($prefixLen) -match '^[0-9]+$'
    })

    if (-not $numericTags) {
        Write-Verbose "No existing numeric tags found, starting at build number 1"
        return @{ NextNumber = 1; CurrentTag = $null }
    }

    $sortedTags = @($numericTags | Sort-Object { [int]$_.Substring($prefixLen) })
    $latestTag = $sortedTags[-1]
    $lastNumber = [int]$latestTag.Substring($prefixLen)

    $nextNumber = ($lastNumber + 1) % 65536
    Write-Verbose "Current tag: $latestTag, allocating build number: $nextNumber"

    return @{ NextNumber = $nextNumber; CurrentTag = $latestTag }
}

function Push-BuildNumberTag {
    param(
        [string] $RepoPath,
        [string] $NewTag,
        [string] $Token = ''
    )

    Write-Verbose "Creating tag: $NewTag"
    Invoke-GitCommand @('tag', $NewTag) -RepoPath $RepoPath

    Write-Verbose "Pushing tag to origin"
    $pushArgs = if ($Token) { @('-c', "http.extraheader=Authorization: token $Token") + @('push', 'origin', "refs/tags/${NewTag}") } else { @('push', 'origin', "refs/tags/${NewTag}") }
    Invoke-GitCommand $pushArgs -RepoPath $RepoPath -IgnoreErrors
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    Write-Verbose "Tag push failed (conflict)"
    Invoke-GitCommand @('tag', '-d', $NewTag) -RepoPath $RepoPath -IgnoreErrors
    return $false
}

function Remove-OldBuildNumberTags {
    param(
        [string] $RepoPath,
        [string] $TagPrefix,
        [string] $NewTag,
        [string] $Token = ''
    )

    # Self-healing: only consider tags whose post-prefix portion is digits-only.
    # Leave foreign tags untouched.
    $prefixLen = $TagPrefix.Length
    $allTags = Invoke-GitCommand @('tag', '-l', "${TagPrefix}*") -RepoPath $RepoPath -IgnoreErrors -CaptureOutput
    $tagsToDelete = @($allTags | Where-Object {
        $_ -and $_ -ne $NewTag -and $_.Length -gt $prefixLen -and $_.Substring($prefixLen) -match '^[0-9]+$'
    })

    if ($tagsToDelete) {
        Write-Verbose "Cleaning up $($tagsToDelete.Count) old tag(s)"
        foreach ($oldTag in $tagsToDelete) {
            $deleteArgs = if ($Token) { @('-c', "http.extraheader=Authorization: token $Token") + @('push', 'origin', '--delete', $oldTag) } else { @('push', 'origin', '--delete', $oldTag) }
            Invoke-GitCommand $deleteArgs -RepoPath $RepoPath -IgnoreErrors
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to delete old tag $oldTag (git exit code $LASTEXITCODE) - tag will be retried on next allocation"
            }
        }
        if ($tagsToDelete.Count -ge 3) {
            Write-Output "::warning::Found $($tagsToDelete.Count) stale counter tags for prefix '$TagPrefix' - cleanup may be backlogged. Inspect the counter repo if this persists."
        }
    }
}

function Set-GitHubOutput {
    param(
        [hashtable] $Outputs
    )

    if ($env:GITHUB_OUTPUT) {
        foreach ($key in $Outputs.Keys) {
            Add-Content -Path $env:GITHUB_OUTPUT -Value "$key=$($Outputs[$key])"
            Write-Verbose "Set output: $key=$($Outputs[$key])"
        }
    }
}

function Invoke-AllocateBuildCounter {
    param(
        [string] $CounterKey,
        [int] $MaxRetries,
        [string] $RepoUrl = '',
        [string] $DestPath = ''
    )

    # Resolve all inputs first. The Get-Resolved* helpers do not validate;
    # the validation block below handles every input in one place with
    # provenance info for error messages.
    $orgInfo = Get-ResolvedOrganization
    $repoInfo = Get-ResolvedRepository

    $resolvedOrg = $orgInfo.Value
    $resolvedRepo = $repoInfo.Value

    if ($env:COUNTER_REPO_OWNER) {
        $counterRepoOwner = $env:COUNTER_REPO_OWNER
        $counterRepoOwnerSource = 'COUNTER_REPO_OWNER env var'
    } else {
        $counterRepoOwner = $resolvedOrg
        $counterRepoOwnerSource = "COUNTER_REPO_OWNER env var (fallback to resolved org from $($orgInfo.Source))"
    }

    if ($env:COUNTER_REPO_NAME) {
        $counterRepoName = $env:COUNTER_REPO_NAME
        $counterRepoNameSource = 'COUNTER_REPO_NAME env var'
    } else {
        $counterRepoName = 'build-counter'
        $counterRepoNameSource = 'COUNTER_REPO_NAME env var (fallback to build-counter)'
    }

    if ($env:GITHUB_SERVER_URL) {
        $gitServer = $env:GITHUB_SERVER_URL
        $gitServerSource = 'GITHUB_SERVER_URL env var'
    } else {
        $gitServer = 'https://github.com'
        $gitServerSource = 'GITHUB_SERVER_URL env var (fallback to https://github.com)'
    }

    # Validate all inputs in risk-order with first-fail short-circuit. URL- and
    # network-facing inputs run first because they feed into git clone with the
    # app token attached; caller-supplied numeric / string params run last.
    try {
        if (-not (Test-ValidGitHubServerUrl -Url $gitServer -Source $gitServerSource -ErrorAction Stop)) { return }
        if ($RepoUrl) {
            if (-not (Test-ValidGitCounterRepoUrl -Url $RepoUrl -Source '-RepoUrl parameter' -ErrorAction Stop)) { return }
        }
        if (-not (Test-ValidGitHubOwner -Owner $counterRepoOwner -Source $counterRepoOwnerSource -ErrorAction Stop)) { return }
        if (-not (Test-ValidRepositoryName -Name $counterRepoName -Source $counterRepoNameSource -ErrorAction Stop)) { return }
        if (-not (Test-ValidGitHubOwner -Owner $resolvedOrg -Source $orgInfo.Source -ErrorAction Stop)) { return }
        if (-not (Test-ValidRepositoryName -Name $resolvedRepo -Source $repoInfo.Source -ErrorAction Stop)) { return }
        if (-not (Test-ValidCounterKey -CounterKey $CounterKey -ErrorAction Stop)) { return }
        if (-not (Test-ValidMaxRetries -MaxRetries $MaxRetries -ErrorAction Stop)) { return }
    }
    catch {
        return
    }

    $counterRepo = "$counterRepoOwner/$counterRepoName"

    $AppToken = $env:APP_TOKEN

    $tagPrefix = "_counters/$resolvedOrg/$resolvedRepo/$CounterKey-"

    if ([string]::IsNullOrEmpty($AppToken)) {
        # Fail loud unless the build is a PR. PR builds don't have access to
        # repository secrets in restricted contexts (e.g. forks), and their
        # version suffix (`-pr{n}.{run}.{attempt}`) already makes the version
        # unique without a real counter value. Any other event missing a
        # token is a misconfigured workflow; we refuse to silently ship
        # `version 0` and force the caller to fix the secret wiring.
        # Empty GITHUB_EVENT_NAME is treated as non-PR (fail closed).
        if ($env:GITHUB_EVENT_NAME -eq 'pull_request') {
            Write-Verbose "No app token (PR event), returning read-only build_number=0"
            Set-GitHubOutput @{
                build_number = 0
                tag = "${tagPrefix}0"
            }
            return
        }

        throw "No APP_TOKEN provided outside of pull_request context (event: '$($env:GITHUB_EVENT_NAME)'). Pass a valid GitHub App private key via the BUILD_COUNTER_APP_PRIVATE_KEY secret so the action can allocate a real counter value."
    }

    # Warn when fallback to caller's org occurred without explicit configuration.
    # Likely-misconfigured: caller in a consumer org forgot to set
    # BUILD_COUNTER_REPO_OWNER and the action will try to clone <caller-org>/build-counter
    # which probably doesn't exist.
    if (-not $env:COUNTER_REPO_OWNER -and $counterRepoOwner -eq $resolvedOrg) {
        Write-Output "::warning::counter_repo_owner defaulted to the calling org ('$counterRepoOwner'). If the build-counter repo lives in a different org, set BUILD_COUNTER_REPO_OWNER as an org variable in this org."
    }

    Write-Verbose "App token available, allocating counter in $counterRepo"

    $repoPath = Initialize-CounterRepository -Owner $counterRepoOwner -Name $counterRepoName -Token $AppToken `
        -GitServer $gitServer -RepoUrl $RepoUrl -DestPath $DestPath

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Verbose "Attempt $attempt/${MaxRetries}: fetching current counter"

        $counterInfo = Get-NextBuildNumber -RepoPath $repoPath -TagPrefix $tagPrefix -Token $AppToken
        $nextNumber = $counterInfo.NextNumber

        if ($nextNumber -ge 65500) {
            Write-Output "::error::Build counter '$CounterKey' is at $nextNumber which is at or above the hard limit (65500). Change the counter_key (e.g. 'repo2') in your calling workflow to reset the counter."
            throw "Build counter '$CounterKey' reached hard limit at $nextNumber (>= 65500)"
        } elseif ($nextNumber -eq 0) {
            Write-Output "::warning::Build counter has rolled over from 65535 to 0. Change the counter_key (e.g. 'repo2') in your calling workflow to start a fresh counter sequence without touching the central repository."
        } elseif ($nextNumber -ge 65000) {
            Write-Output "::warning::Build counter is at $nextNumber (max 65535). Plan a counter_key change (e.g. 'repo2') in your calling workflow before rollover."
        }

        $newTag = "${tagPrefix}${nextNumber}"

        if (Push-BuildNumberTag -RepoPath $repoPath -NewTag $newTag -Token $AppToken) {
            Remove-OldBuildNumberTags -RepoPath $repoPath -TagPrefix $tagPrefix -NewTag $newTag -Token $AppToken

            Write-Verbose "Successfully allocated build number: $nextNumber"
            Set-GitHubOutput @{
                build_number = $nextNumber
                tag = $newTag
            }
            return
        }

        if ($attempt -lt $MaxRetries) {
            # Random jitter window much wider than typical critical path (~500ms-2.5s)
            # so colliding workers are unlikely to re-collide on the next attempt.
            $backoffMs = Get-Random -Minimum 3000 -Maximum 12001
            Write-Verbose "Retrying after ${backoffMs}ms"
            Start-Sleep -Milliseconds $backoffMs
        }
    }

    throw "Failed to allocate build counter after $MaxRetries attempts"
}

# Main logic (skip during testing)
if ($NoRun) { return }

$resolvedCounterKey = if ($env:COUNTER_KEY) { $env:COUNTER_KEY } else { $CounterKey }
$resolvedMaxRetries = if ($env:MAX_RETRIES) { [int]$env:MAX_RETRIES } else { $MaxRetries }

# Test seam env vars: only honored outside the GitHub Actions runtime.
# Inside GHA, $env:GITHUB_ACTIONS is set to 'true' on every step; setting it
# is reserved for GitHub itself, so an attacker controlling other env on the
# runner cannot strip it. Restricting the test seam to local Pester runs
# prevents a hostile workflow input from redirecting clones to a file:// path
# or arbitrary dest path during a production run.
$isGitHubActions = ($env:GITHUB_ACTIONS -eq 'true')
$resolvedRepoUrl  = if (-not $isGitHubActions -and $env:BUILD_COUNTER_REPO_URL)  { $env:BUILD_COUNTER_REPO_URL }  else { '' }
$resolvedDestPath = if (-not $isGitHubActions -and $env:BUILD_COUNTER_DEST_PATH) { $env:BUILD_COUNTER_DEST_PATH } else { '' }

try {
    Invoke-AllocateBuildCounter -CounterKey $resolvedCounterKey -MaxRetries $resolvedMaxRetries `
        -RepoUrl $resolvedRepoUrl -DestPath $resolvedDestPath
}
catch {
    Write-Error "Action failed: $_"
    exit 1
}
