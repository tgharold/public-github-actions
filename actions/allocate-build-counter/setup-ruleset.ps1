#!/usr/bin/env pwsh
<#
.SYNOPSIS
Set up the GitHub ruleset for a build-counter repository's counter tags.

.DESCRIPTION
Creates a ruleset on the target repository that restricts tag creation and
deletion on the _counters/** namespace, with the GitHub App added to the
bypass list so that counter increments still succeed.

.PARAMETER Repository
The target repository in `<owner>/<name>` form (e.g. `my-org/build-counter`).
Required.

.PARAMETER AppId
The numeric ID of the GitHub App that should bypass the ruleset. Required.

.EXAMPLE
./setup-ruleset.ps1 -Repository my-org/build-counter -AppId 123456
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]*/[a-zA-Z0-9_][a-zA-Z0-9._-]*$')]
    [string]$Repository,

    [Parameter(Mandatory = $true)]
    [string]$AppId
)

$ErrorActionPreference = 'Stop'

if ($AppId -notmatch '^\d+$') {
    Write-Error "AppId must be a numeric value. Received: $AppId"
    exit 1
}

[int64]$AppIdInt = $AppId
if ($AppIdInt -le 0 -or $AppIdInt -gt [int32]::MaxValue) {
    Write-Error "AppId must be a positive integer between 1 and 2147483647. Received: $AppId"
    exit 1
}

try {
    # Verify the target repository exists and the caller can reach it. The
    # script no longer derives the repo from the current working directory,
    # so this check replaces the cwd-context guard.
    Write-Host "Verifying repository: $Repository" -ForegroundColor Cyan
    $null = gh api "repos/$Repository" --jq '.full_name' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Repository '$Repository' not found or not accessible with the current gh token."
        exit 1
    }

    # Verify the app exists and is reachable. gh's `app/installations` lists
    # installations visible to the current token; if the caller has admin:org
    # on the owning org this will include the build-counter app installation.
    Write-Host "Verifying GitHub App with ID: $AppId" -ForegroundColor Cyan
    $jqAppFilter = ".[] | select(.app_id == $AppIdInt)"
    $appInfo = gh api "app/installations" --paginate --jq $jqAppFilter 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $appInfo) {
        Write-Error "GitHub App with ID $AppId not found or not installed in this organization."
        exit 1
    }

    # Idempotency: skip if a ruleset with the same name already exists.
    $rulesetName = "Build Counter Tag Protection"
    $jqRulesetFilter = ".[] | select(.name == ""$rulesetName"")"
    $existing = gh api "repos/$Repository/rulesets" --jq $jqRulesetFilter 2>&1
    if ($LASTEXITCODE -eq 0 -and $existing) {
        Write-Host "Ruleset '$rulesetName' already exists on $Repository - skipping." -ForegroundColor Yellow
        return
    }

    # Create the ruleset.
    # bypass_mode = "always" because the GitHub App pushes tags directly with
    # `git push origin refs/tags/...` (no pull request involved). The
    # "pull_request" bypass mode would block every counter write.
    Write-Host "Creating ruleset for _counters/** tags on $Repository..." -ForegroundColor Cyan

    $rulesetBody = @{
        name        = $rulesetName
        description = "Restrict modifications to _counters/** tags; GitHub App can bypass"
        target      = "tag"
        enforcement = "active"
        conditions  = @{
            ref_name = @{
                include = @("refs/tags/_counters/**")
                exclude = @()
            }
        }
        rules        = @(
            @{ type = "creation" }
            @{ type = "deletion" }
        )
        bypass_actors = @(
            @{ actor_type = "Integration"; actor_id = [int]$AppId; bypass_mode = "always" }
        )
    } | ConvertTo-Json -Depth 10

    $rulesetBody | gh api "repos/$Repository/rulesets" `
        -X POST `
        --input - `
        -H "Accept: application/vnd.github+json" `
        -H "X-GitHub-Api-Version: 2022-11-28" 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create ruleset. Check that the GitHub App has admin permissions on the repository."
        exit 1
    }

    Write-Host "Ruleset created successfully." -ForegroundColor Green
    Write-Host ""
    Write-Host "Ruleset Details:" -ForegroundColor Cyan
    Write-Host "  Repository:   $Repository"
    Write-Host "  Target:       _counters/** tags"
    Write-Host "  Restrictions: No creation or deletion by users"
    Write-Host "  Bypass:       GitHub App ID $AppId"
    Write-Host ""

} catch {
    Write-Error "An error occurred: $_"
    exit 1
}
