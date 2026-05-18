# Shared test helpers and dependencies for allocate-build-counter tests

. "$PSScriptRoot/../action.ps1" -NoRun

# Helper to create a bare "origin" repo and a working clone seeded with one commit
function New-TestGitRepo {
    param([string] $Prefix = 'pester')
    $rand = [System.IO.Path]::GetRandomFileName() -replace '\..*', ''
    $tempBase = [System.IO.Path]::GetTempPath()
    $bareDir  = Join-Path $tempBase "${Prefix}-bare-${rand}.git"
    $initDir  = Join-Path $tempBase "${Prefix}-init-${rand}"
    $workDir  = Join-Path $tempBase "${Prefix}-work-${rand}"

    # Create bare repo (acts as origin)
    & git init --bare $bareDir 2>&1 | Out-Null

    # Clone to init dir, create one commit, push it, then remove init dir
    & git clone $bareDir $initDir 2>&1 | Out-Null
    & git -C $initDir config user.email 'pester@test.local' 2>&1 | Out-Null
    & git -C $initDir config user.name 'Pester' 2>&1 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $initDir '.gitkeep'), '')
    & git -C $initDir add '.gitkeep' 2>&1 | Out-Null
    & git -C $initDir commit -m 'Initial commit for tests' 2>&1 | Out-Null
    & git -C $initDir push origin HEAD 2>&1 | Out-Null
    Remove-Item $initDir -Recurse -Force

    # Clone again for use as working copy in tests
    & git clone $bareDir $workDir 2>&1 | Out-Null
    & git -C $workDir config user.email 'pester@test.local' 2>&1 | Out-Null
    & git -C $workDir config user.name 'Pester' 2>&1 | Out-Null

    return @{
        BareDir = $bareDir
        WorkDir = $workDir
    }
}

function Remove-TestGitRepo {
    param([hashtable] $Repo)
    Remove-Item $Repo.BareDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $Repo.WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
