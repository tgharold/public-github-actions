#!/usr/bin/env pwsh
<#
.SYNOPSIS
Install the build counter GitHub App on the owning org (run once per org).

.DESCRIPTION
Installs the GitHub App on the counter repository, stores the app ID as an
org variable and the private key as an org secret, then runs the tag
ruleset setup against the counter repository.

Run this after creating the GitHub App manually via the GitHub UI. For
additional calling orgs in the enterprise, store the credentials there
manually — the registration and installation already exist.

Requires admin:org scope on the gh token to set org variables and secrets.

This script can be run from any working directory; it does not require a
clone of the counter repository on disk. All targeting is via parameters.

.PARAMETER Hostname
GitHub hostname (e.g. github.com or github.example.com). Must match the host
you are authenticated to via gh auth login. Required — prevents silently
targeting the wrong enterprise.

.PARAMETER CounterRepository
The counter repository in `<owner>/<name>` form (e.g. `my-org/build-counter`).
The owner is also the org in which the app is installed and where credentials
are stored. Required.

.PARAMETER AppId
Numeric ID of the registered GitHub App. Required.

.PARAMETER AppSlug
Slug of the GitHub App (used to build the installation URL). Optional — if
omitted, the script opens the org's app settings page instead.

.PARAMETER PrivateKeyFile
Path to the PEM file containing the app's private key. If omitted, the script
prompts for the value interactively.

.PARAMETER SkipCredentialStore
Skip storing BUILD_COUNTER_APP_ID and BUILD_COUNTER_APP_PRIVATE_KEY as org
variable/secret. Use if credentials are already stored.

.PARAMETER SkipRuleset
Skip running setup-ruleset.ps1 at the end.

.EXAMPLE
./setup-app-installation.ps1 -Hostname github.com -CounterRepository my-org/build-counter -AppId 123456 -AppSlug my-org-build-counter

./setup-app-installation.ps1 -Hostname github.com -CounterRepository my-org/build-counter -AppId 123456 -PrivateKeyFile ./build-counter-app.pem

./setup-app-installation.ps1 -Hostname github.com -CounterRepository my-org/build-counter -AppId 123456 -SkipCredentialStore
#>

param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.\-]*[a-zA-Z0-9]$')]
    [string]$Hostname,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]*/[a-zA-Z0-9_][a-zA-Z0-9._-]*$')]
    [string]$CounterRepository,

    [Parameter(Mandatory = $true)]
    [string]$AppId,

    [ValidatePattern('^[a-z0-9][a-z0-9-]*[a-z0-9]$')]
    [string]$AppSlug,

    [string]$PrivateKeyFile,

    [switch]$SkipCredentialStore,

    [switch]$SkipRuleset
)

$ErrorActionPreference = 'Stop'

$Org = ($CounterRepository -split '/')[0]
$CounterRepoName = ($CounterRepository -split '/')[1]

function Assert-Hostname {
    param([string]$Hostname)
    $null = gh auth status --hostname $Hostname 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Not authenticated to '$Hostname'. Run: gh auth login --hostname $Hostname"
        exit 1
    }
}

function Assert-CounterRepository {
    param([string]$Repository, [string]$Hostname)
    $null = gh api "repos/$Repository" --hostname $Hostname --jq '.full_name' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Counter repository '$Repository' not found or not accessible on $Hostname. Create it first, or check that your gh token has access."
        exit 1
    }
}

function Open-Url {
    param([string]$Url)
    # Validate URL format to prevent opening malicious URLs
    if (-not ($Url -match '^https://[a-zA-Z0-9][a-zA-Z0-9.\-]*[a-zA-Z0-9](/.*)?$')) {
        Write-Error "Invalid URL format: $Url"
        exit 1
    }
    if ($IsWindows) { Start-Process $Url }
    elseif ($IsMacOS) { & open $Url }
    else { & xdg-open $Url 2>/dev/null }
}

function Get-Installation {
    param([string]$Org, [string]$Hostname, [int]$Id)
    $jqFilter = ".installations[] | select(.app_id == $Id)"
    $result = gh api "/orgs/$Org/installations" --hostname $Hostname --paginate `
        --jq $jqFilter 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $result) { return $null }
    return $result | ConvertFrom-Json
}

# --- main ---

if ($AppId -notmatch '^\d+$') {
    Write-Error "AppId must be numeric. Received: $AppId"
    exit 1
}

Assert-Hostname -Hostname $Hostname
Assert-CounterRepository -Repository $CounterRepository -Hostname $Hostname

$env:GH_HOST = $Hostname

# --- step 1: verify or guide installation ---

Write-Host "Checking installation of app $AppId in org $Org on $Hostname ..." -ForegroundColor Cyan

$installation = Get-Installation -Org $Org -Hostname $Hostname -Id ([int]$AppId)

if ($installation) {
    $permissions = $installation.permissions
    if ($permissions.contents -ne "write") {
        Write-Error "App $AppId is installed but does not have 'Contents: write'. Found: $($permissions.contents)"
        exit 1
    }
    if ($installation.repository_selection -ne "selected") {
        Write-Error "App $AppId is installed on all repositories. Re-install scoped to only $CounterRepository : https://$Hostname/organizations/$Org/settings/installations/$($installation.id)"
        exit 1
    }
    Write-Host "  App already installed. Slug: $($installation.app_slug), permissions: contents=$($permissions.contents), scope: $($installation.repository_selection)" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Warning "App $AppId is not yet installed in org $Org (or token lacks admin:org scope to verify)."
    Write-Host ""

    if ($AppSlug) {
        $installUrl = "https://$Hostname/apps/$AppSlug/installations/new"
    } else {
        $installUrl = "https://$Hostname/organizations/$Org/settings/apps"
        Write-Host "Tip: provide -AppSlug to get a direct installation URL next time." -ForegroundColor DarkGray
    }

    Write-Host "Opening browser to install the app ..." -ForegroundColor Cyan
    Write-Host "  $installUrl" -ForegroundColor Yellow
    Open-Url -Url $installUrl
    Write-Host ""
    Write-Host "In the browser:" -ForegroundColor Yellow
    Write-Host "  1. Select 'Only select repositories'."
    Write-Host "  2. Choose only the $CounterRepoName repository."
    Write-Host "  3. Click 'Install'."
    Write-Host ""
    Read-Host "Press Enter once the app is installed"

    # Re-verify
    $installation = Get-Installation -Org $Org -Hostname $Hostname -Id ([int]$AppId)
    if (-not $installation) {
        Write-Error "Cannot confirm app installation via API. Installation may have failed."
        Write-Error "Check app settings: https://$Hostname/organizations/$Org/settings/installations"
        exit 1
    }
    if ($installation.repository_selection -ne "selected") {
        Write-Error "App installed on all repositories. Re-install scoped to only $CounterRepository : https://$Hostname/organizations/$Org/settings/installations/$($installation.id)"
        exit 1
    }
    Write-Host "  Installation confirmed. Scope: $($installation.repository_selection)" -ForegroundColor Green
}

# --- step 2: store org variable and secret ---

if (-not $SkipCredentialStore) {
    Write-Host ""
    Write-Host "Storing credentials in org $Org ..." -ForegroundColor Cyan

    # App ID as org variable (not sensitive)
    gh variable set BUILD_COUNTER_APP_ID --org $Org --body "$AppId"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to set org variable BUILD_COUNTER_APP_ID."
        exit 1
    }
    Write-Host "  BUILD_COUNTER_APP_ID variable set." -ForegroundColor Green

    # Private key as org secret
    if ($PrivateKeyFile) {
        if (-not (Test-Path $PrivateKeyFile)) {
            Write-Error "Private key file not found: $PrivateKeyFile"
            exit 1
        }
        $privateKey = Get-Content $PrivateKeyFile -Raw
    } else {
        Write-Host ""
        Write-Host "Paste the private key PEM (input will be hidden):" -ForegroundColor Yellow
        Write-Host "Press Enter, then Ctrl+Z on Windows / Ctrl+D on Mac/Linux when done:" -ForegroundColor Yellow
        $lines = @()
        while ($true) {
            $line = Read-Host -MaskInput -ErrorAction SilentlyContinue
            if ($null -eq $line) { break }
            $lines += $line
        }
        $privateKey = $lines -join "`n"
    }

    if ([string]::IsNullOrWhiteSpace($privateKey)) {
        Write-Error "Private key is empty."
        exit 1
    }

    $privateKey | gh secret set BUILD_COUNTER_APP_PRIVATE_KEY --org $Org
    $setSecretExitCode = $LASTEXITCODE

    # Clear sensitive data from memory
    [System.GC]::Collect()

    if ($setSecretExitCode -ne 0) {
        Write-Error "Failed to set org secret BUILD_COUNTER_APP_PRIVATE_KEY."
        exit 1
    }
    Write-Host "  BUILD_COUNTER_APP_PRIVATE_KEY secret set." -ForegroundColor Green
}

# --- step 3: ruleset ---

if (-not $SkipRuleset) {
    Write-Host ""
    Write-Host "Running tag ruleset setup ..." -ForegroundColor Cyan

    $rulesetScript = Join-Path $PSScriptRoot "setup-ruleset.ps1"
    if (-not (Test-Path $rulesetScript)) {
        Write-Error "setup-ruleset.ps1 not found at: $rulesetScript"
        exit 1
    }

    & $rulesetScript -Repository $CounterRepository -AppId $AppId
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Ruleset setup failed."
        exit 1
    }
}

Write-Host ""
Write-Host "Installation complete for org $Org." -ForegroundColor Green
Write-Host ""
Write-Host "For each additional calling org that will use the counter:" -ForegroundColor Cyan
Write-Host "  1. Store the same app ID ($AppId) as org variable BUILD_COUNTER_APP_ID."
Write-Host "  2. Store the same private key as org secret BUILD_COUNTER_APP_PRIVATE_KEY."
Write-Host "  3. Store $Org as org variable BUILD_COUNTER_REPO_OWNER (GitHub Enterprise multi-org only)."
Write-Host "  4. Allow reusable workflows from the repository that hosts them"
Write-Host "     (e.g. ritterim/public-github-actions, or your private fork):"
Write-Host "       Settings > Actions > General > Allow reusable workflows from selected repositories"
