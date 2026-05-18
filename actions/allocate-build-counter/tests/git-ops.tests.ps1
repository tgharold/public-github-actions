BeforeAll {
    . "$PSScriptRoot/shared.ps1"
}

Describe 'Get-NextBuildNumber' {
    BeforeAll {
        $script:gcbnRepo = New-TestGitRepo -Prefix 'gcbn'
    }

    AfterAll {
        Remove-TestGitRepo $script:gcbnRepo
    }

    BeforeEach {
        # Clean up all local and remote tags from previous tests (operate via -C on the work dir)
        $work = $script:gcbnRepo.WorkDir
        $localTags = & git -C $work tag -l 2>&1
        if ($localTags) {
            $localTags | ForEach-Object { & git -C $work tag -d $_ 2>&1 | Out-Null }
        }
        $remoteTags = & git -C $work ls-remote --tags origin 2>&1 | Where-Object { $_ -match 'refs/tags/' } | ForEach-Object { ($_ -split '\s+')[1] -replace '\^\{\}$' }
        if ($remoteTags) {
            $remoteTags | ForEach-Object { & git -C $work push origin --delete $_ 2>&1 | Out-Null }
        }
    }

    It 'returns NextNumber=1 and CurrentTag=$null when no tags exist' {
        $result = Get-NextBuildNumber -RepoPath $script:gcbnRepo.WorkDir -TagPrefix 'gcbn-empty-'
        $result | Should -BeOfType [hashtable]
        $result.NextNumber | Should -Be 1
        $result.CurrentTag | Should -BeNull
    }

    It 'returns correct NextNumber and CurrentTag when tags exist on remote' {
        $work = $script:gcbnRepo.WorkDir
        $prefix = 'gcbn-existing-'
        # Create and push tags
        & git -C $work tag "${prefix}3" 2>&1 | Out-Null
        & git -C $work tag "${prefix}7" 2>&1 | Out-Null
        & git -C $work tag "${prefix}15" 2>&1 | Out-Null
        & git -C $work push origin "refs/tags/${prefix}3" "refs/tags/${prefix}7" "refs/tags/${prefix}15" 2>&1 | Out-Null
        # Delete local tags so fetch is required to see them
        & git -C $work tag -d "${prefix}3" "${prefix}7" "${prefix}15" 2>&1 | Out-Null

        $result = Get-NextBuildNumber -RepoPath $work -TagPrefix $prefix
        $result.CurrentTag | Should -Be "${prefix}15"
        $result.NextNumber | Should -Be 16
    }

    It 'wraps around to 0 after 65535' {
        $work = $script:gcbnRepo.WorkDir
        $prefix = 'gcbn-wrap-'
        & git -C $work tag "${prefix}65535" 2>&1 | Out-Null
        & git -C $work push origin "refs/tags/${prefix}65535" 2>&1 | Out-Null
        & git -C $work tag -d "${prefix}65535" 2>&1 | Out-Null

        $result = Get-NextBuildNumber -RepoPath $work -TagPrefix $prefix
        $result.CurrentTag | Should -Be "${prefix}65535"
        $result.NextNumber | Should -Be 0
    }

    It 'self-heals: ignores foreign tags whose post-prefix is non-numeric' {
        $work = $script:gcbnRepo.WorkDir
        $prefix = 'gcbn-heal-'
        & git -C $work tag "${prefix}5" 2>&1 | Out-Null
        & git -C $work tag "${prefix}foo" 2>&1 | Out-Null
        & git -C $work tag "${prefix}10-bad" 2>&1 | Out-Null
        & git -C $work push origin "refs/tags/${prefix}5" "refs/tags/${prefix}foo" "refs/tags/${prefix}10-bad" 2>&1 | Out-Null
        & git -C $work tag -d "${prefix}5" "${prefix}foo" "${prefix}10-bad" 2>&1 | Out-Null

        $result = Get-NextBuildNumber -RepoPath $work -TagPrefix $prefix
        $result.CurrentTag | Should -Be "${prefix}5"
        $result.NextNumber | Should -Be 6
    }

    It 'self-heals: returns NextNumber=1 when only foreign tags exist' {
        $work = $script:gcbnRepo.WorkDir
        $prefix = 'gcbn-only-foreign-'
        & git -C $work tag "${prefix}abc" 2>&1 | Out-Null
        & git -C $work push origin "refs/tags/${prefix}abc" 2>&1 | Out-Null
        & git -C $work tag -d "${prefix}abc" 2>&1 | Out-Null

        $result = Get-NextBuildNumber -RepoPath $work -TagPrefix $prefix
        $result.CurrentTag | Should -BeNull
        $result.NextNumber | Should -Be 1
    }

    It 'calculates rollover correctly at 65535 (pure arithmetic)' {
        $nextNum = (65535 + 1) % 65536
        $nextNum | Should -Be 0
    }
}

Describe 'Push-BuildNumberTag' {
    BeforeAll {
        $script:pbtRepo = New-TestGitRepo -Prefix 'pbt'

        # Create a second clone to simulate a competing worker
        $rand = [System.IO.Path]::GetRandomFileName() -replace '\..*', ''
        $script:otherWorkerDir = Join-Path ([System.IO.Path]::GetTempPath()) "pbt-other-${rand}"
        & git clone $script:pbtRepo.BareDir $script:otherWorkerDir 2>&1 | Out-Null
        & git -C $script:otherWorkerDir config user.email 'pester@test.local' 2>&1 | Out-Null
        & git -C $script:otherWorkerDir config user.name 'Pester' 2>&1 | Out-Null
    }

    AfterAll {
        Remove-TestGitRepo $script:pbtRepo
        Remove-Item $script:otherWorkerDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns $true and leaves tag on remote when push succeeds' {
        $work = $script:pbtRepo.WorkDir
        $tag = 'pbt-success-1'

        $result = Push-BuildNumberTag -RepoPath $work -NewTag $tag

        $result | Should -Be $true

        # Tag should exist on remote
        $remoteTags = & git -C $work ls-remote --tags origin 2>&1 | Where-Object { $_ -match [regex]::Escape($tag) }
        $remoteTags | Should -Not -BeNullOrEmpty

        # Tag should still exist locally
        $localTag = & git -C $work tag -l $tag 2>&1
        $localTag | Should -Be $tag
    }

    It 'returns $false and removes local tag when push is rejected due to conflict' {
        $work = $script:pbtRepo.WorkDir
        $tag = 'pbt-conflict-1'

        # Other worker pushes this tag first, pointing to base commit
        & git -C $script:otherWorkerDir tag $tag 2>&1 | Out-Null
        & git -C $script:otherWorkerDir push origin "refs/tags/${tag}" 2>&1 | Out-Null

        # Our worker makes a new commit so the tag will point to a different SHA
        [System.IO.File]::WriteAllText((Join-Path $work 'pbt-extra'), 'conflict test')
        & git -C $work add 'pbt-extra' 2>&1 | Out-Null
        & git -C $work commit -m 'add file for conflict test' 2>&1 | Out-Null

        $result = Push-BuildNumberTag -RepoPath $work -NewTag $tag

        $result | Should -Be $false

        # Local tag must have been cleaned up
        $localTag = & git -C $work tag -l $tag 2>&1
        $localTag | Should -BeNullOrEmpty

        # Remote still has the other worker's tag
        $remoteTags = & git -C $work ls-remote --tags origin 2>&1 | Where-Object { $_ -match [regex]::Escape($tag) }
        $remoteTags | Should -Not -BeNullOrEmpty
    }
}

Describe 'Remove-OldBuildNumberTags' {
    BeforeAll {
        $script:robtRepo = New-TestGitRepo -Prefix 'robt'
    }

    AfterAll {
        Remove-TestGitRepo $script:robtRepo
    }

    It 'deletes old prefixed tags on remote but keeps the new tag' {
        $work = $script:robtRepo.WorkDir
        $prefix = 'robt-cleanup-'
        $newTag = "${prefix}3"

        # Push several tags with the prefix
        & git -C $work tag "${prefix}1" 2>&1 | Out-Null
        & git -C $work tag "${prefix}2" 2>&1 | Out-Null
        & git -C $work tag "${prefix}3" 2>&1 | Out-Null
        & git -C $work push origin "refs/tags/${prefix}1" "refs/tags/${prefix}2" "refs/tags/${prefix}3" 2>&1 | Out-Null

        # Verify setup: all 3 tags on remote
        $beforeTags = & git -C $work ls-remote --tags origin 2>&1 | Where-Object { $_ -match [regex]::Escape($prefix) }
        $beforeTags | Should -HaveCount 3

        Remove-OldBuildNumberTags -RepoPath $work -TagPrefix $prefix -NewTag $newTag

        # Verify: only newTag remains on remote
        $afterTags = & git -C $work ls-remote --tags origin 2>&1 | Where-Object { $_ -match [regex]::Escape($prefix) }
        $afterTags | Should -HaveCount 1
        $afterTags | Where-Object { $_ -like "*$newTag" } | Should -HaveCount 1
    }

    It 'does nothing when only the new tag exists' {
        $work = $script:robtRepo.WorkDir
        $prefix = 'robt-sole-'
        $newTag = "${prefix}1"

        & git -C $work tag $newTag 2>&1 | Out-Null
        & git -C $work push origin "refs/tags/${newTag}" 2>&1 | Out-Null

        { Remove-OldBuildNumberTags -RepoPath $work -TagPrefix $prefix -NewTag $newTag } | Should -Not -Throw

        $remoteTags = & git -C $work ls-remote --tags origin 2>&1 | Where-Object { $_ -match [regex]::Escape($prefix) }
        $remoteTags | Should -HaveCount 1
    }

    It 'does not delete tags with a different prefix' {
        $work = $script:robtRepo.WorkDir
        $prefix      = 'robt-nocrss-'
        $otherPrefix = 'robt-other-'
        $newTag      = "${prefix}2"

        & git -C $work tag "${prefix}1" 2>&1 | Out-Null
        & git -C $work tag "${prefix}2" 2>&1 | Out-Null
        & git -C $work tag "${otherPrefix}99" 2>&1 | Out-Null
        & git -C $work push origin "refs/tags/${prefix}1" "refs/tags/${prefix}2" "refs/tags/${otherPrefix}99" 2>&1 | Out-Null

        Remove-OldBuildNumberTags -RepoPath $work -TagPrefix $prefix -NewTag $newTag

        # Other prefix tag must still exist on remote
        $otherTag = & git -C $work ls-remote --tags origin 2>&1 | Where-Object { $_ -match [regex]::Escape($otherPrefix) }
        $otherTag | Should -HaveCount 1
    }

    It 'self-heals: does not delete foreign (non-numeric post-prefix) tags' {
        $work = $script:robtRepo.WorkDir
        $prefix = 'robt-heal-'
        $newTag = "${prefix}5"

        & git -C $work tag "${prefix}1" 2>&1 | Out-Null
        & git -C $work tag "${prefix}foo" 2>&1 | Out-Null
        & git -C $work tag "${prefix}5" 2>&1 | Out-Null
        & git -C $work push origin "refs/tags/${prefix}1" "refs/tags/${prefix}foo" "refs/tags/${prefix}5" 2>&1 | Out-Null

        Remove-OldBuildNumberTags -RepoPath $work -TagPrefix $prefix -NewTag $newTag

        $afterTags = & git -C $work ls-remote --tags origin 2>&1 | Where-Object { $_ -match [regex]::Escape($prefix) } | ForEach-Object { ($_ -split '\s+')[1] }
        $afterTags | Should -Contain "refs/tags/${prefix}foo"
        $afterTags | Should -Contain "refs/tags/${prefix}5"
        $afterTags | Should -Not -Contain "refs/tags/${prefix}1"
    }
}

Describe 'Initialize-CounterRepository' {
    BeforeAll {
        $script:icrRepo = New-TestGitRepo -Prefix 'icr'
        $rand = [System.IO.Path]::GetRandomFileName() -replace '\..*', ''
        $script:destPath = Join-Path ([System.IO.Path]::GetTempPath()) "icr-dest-${rand}"
        $script:icrCwdBefore = (Get-Location).Path
    }

    AfterAll {
        Remove-TestGitRepo $script:icrRepo
        Remove-Item $script:destPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'clones the repo and returns the dest path without mutating cwd' {
        $fileUrl = "file://$($script:icrRepo.BareDir)"

        $returned = Initialize-CounterRepository -Owner 'unused' -Name 'unused' -Token 'unused' `
            -RepoUrl $fileUrl -DestPath $script:destPath

        $returned | Should -Be $script:destPath
        (Get-Location).Path | Should -Be $script:icrCwdBefore
        (Join-Path $script:destPath '.git') | Should -Exist
    }

    It 'removes existing dest path before cloning (idempotent)' {
        $fileUrl = "file://$($script:icrRepo.BareDir)"

        $returned = Initialize-CounterRepository -Owner 'unused' -Name 'unused' -Token 'unused' `
            -RepoUrl $fileUrl -DestPath $script:destPath

        $returned | Should -Be $script:destPath
        (Get-Location).Path | Should -Be $script:icrCwdBefore
    }
}
