BeforeAll {
    . "$PSScriptRoot/shared.ps1"
}

Describe 'Invoke-AllocateBuildCounter' {
    BeforeEach {
        $env:APP_TOKEN = ''
        $env:GITHUB_OUTPUT = ''
        $env:GITHUB_REPOSITORY_OWNER = 'org'
        $env:GITHUB_REPOSITORY = 'org/repo'
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:COUNTER_REPO_OWNER = ''
        $env:COUNTER_REPO_NAME = ''
        $env:GITHUB_EVENT_NAME = 'pull_request'
    }

    It 'returns build_number=0 in read-only mode on pull_request event' {
        $env:GITHUB_EVENT_NAME = 'pull_request'
        $env:APP_TOKEN = ''
        Mock -CommandName 'Set-GitHubOutput'

        Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5

        Assert-MockCalled -CommandName 'Set-GitHubOutput' -Times 1 -ParameterFilter {
            $Outputs.build_number -eq 0 -and $Outputs.tag -match '_counters/org/repo/repo-0'
        }
    }

    It 'throws when no token AND event is not pull_request' {
        $env:GITHUB_EVENT_NAME = 'push'
        $env:APP_TOKEN = ''
        { Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5 } | Should -Throw '*No APP_TOKEN provided outside of pull_request context*'
    }

    It 'throws when no token AND GITHUB_EVENT_NAME is empty (fail closed)' {
        $env:GITHUB_EVENT_NAME = ''
        $env:APP_TOKEN = ''
        { Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5 } | Should -Throw '*No APP_TOKEN provided outside of pull_request context*'
    }

    It 'throws when no token AND event is workflow_dispatch' {
        $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
        $env:APP_TOKEN = ''
        { Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5 } | Should -Throw '*No APP_TOKEN provided outside of pull_request context*'
    }

    It 'uses APP_TOKEN environment variable' {
        $testRepo = New-TestGitRepo
        $env:APP_TOKEN = 'env-token'

        Mock -CommandName 'Set-GitHubOutput' -MockWith { }

        Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5 `
            -RepoUrl "file://$($testRepo.BareDir)" -DestPath "$($testRepo.WorkDir)-test"

        Assert-MockCalled -CommandName 'Set-GitHubOutput' -Times 1 -ParameterFilter {
            $Outputs.build_number -eq 1
        }

        Remove-TestGitRepo -Repo $testRepo
        Remove-Item "$($testRepo.WorkDir)-test" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'successfully allocates build number on first attempt' {
        $testRepo = New-TestGitRepo
        $env:APP_TOKEN = 'test-token'
        $script:capturedOutput = @{}

        Mock -CommandName 'Set-GitHubOutput' -MockWith {
            param($Outputs)
            $script:capturedOutput = $Outputs
        }

        Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5 `
            -RepoUrl "file://$($testRepo.BareDir)" -DestPath "$($testRepo.WorkDir)-test"

        $script:capturedOutput.build_number | Should -Be 1
        $script:capturedOutput.tag | Should -Be '_counters/org/repo/repo-1'

        Remove-TestGitRepo -Repo $testRepo
        Remove-Item "$($testRepo.WorkDir)-test" -Recurse -Force -ErrorAction SilentlyContinue
    }



    It 'returns early when counter_key validation fails' {
        $env:APP_TOKEN = 'test-token'
        $initRepoCalls = 0
        Mock -CommandName 'Initialize-CounterRepository' -MockWith {
            $initRepoCalls++
        }

        Invoke-AllocateBuildCounter -CounterKey 'invalid-key!' -MaxRetries 5

        $initRepoCalls | Should -Be 0
    }

    It 'returns early when max retries validation fails' {
        $env:APP_TOKEN = 'test-token'
        $initRepoCalls = 0
        Mock -CommandName 'Initialize-CounterRepository' -MockWith {
            $initRepoCalls++
        }

        Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 101

        $initRepoCalls | Should -Be 0
    }

    It 'returns early when GITHUB_SERVER_URL is not the canonical github.com' {
        $env:GITHUB_SERVER_URL = 'https://evil.com'
        $env:APP_TOKEN = 'test-token'
        $initRepoCalls = 0
        Mock -CommandName 'Initialize-CounterRepository' -MockWith { $initRepoCalls++ }

        Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5

        $initRepoCalls | Should -Be 0
    }

    It 'returns early when -RepoUrl is malformed' {
        $env:APP_TOKEN = 'test-token'
        $initRepoCalls = 0
        Mock -CommandName 'Initialize-CounterRepository' -MockWith { $initRepoCalls++ }

        Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5 `
            -RepoUrl 'http://github.com/org/repo.git'

        $initRepoCalls | Should -Be 0
    }

    It 'returns early when COUNTER_REPO_OWNER is malformed' {
        $env:COUNTER_REPO_OWNER = 'bad-owner-'
        $env:APP_TOKEN = 'test-token'
        $initRepoCalls = 0
        Mock -CommandName 'Initialize-CounterRepository' -MockWith { $initRepoCalls++ }

        Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5

        $initRepoCalls | Should -Be 0
    }

    It 'returns early when COUNTER_REPO_NAME is malformed' {
        $env:COUNTER_REPO_NAME = 'bad@name'
        $env:APP_TOKEN = 'test-token'
        $initRepoCalls = 0
        Mock -CommandName 'Initialize-CounterRepository' -MockWith { $initRepoCalls++ }

        Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5

        $initRepoCalls | Should -Be 0
    }

    It 'returns early when GITHUB_REPOSITORY_OWNER is malformed' {
        $env:GITHUB_REPOSITORY_OWNER = 'bad-owner-'
        $env:COUNTER_REPO_OWNER = 'goodowner'  # avoid validator failing on counter owner first
        $env:APP_TOKEN = 'test-token'
        $initRepoCalls = 0
        Mock -CommandName 'Initialize-CounterRepository' -MockWith { $initRepoCalls++ }

        Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5

        $initRepoCalls | Should -Be 0
    }

    It 'returns early when GITHUB_REPOSITORY is malformed' {
        $env:GITHUB_REPOSITORY = 'org/bad@repo'
        $env:APP_TOKEN = 'test-token'
        $initRepoCalls = 0
        Mock -CommandName 'Initialize-CounterRepository' -MockWith { $initRepoCalls++ }

        Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5

        $initRepoCalls | Should -Be 0
    }

    It 'throws hard error when build counter reaches exactly 65500' {
        $testRepo = New-TestGitRepo
        $env:APP_TOKEN = 'test-token'
        $tagPrefix = '_counters/org/repo/repo-'

        & git -C $testRepo.BareDir tag "${tagPrefix}65499" 2>&1 | Out-Null
        & git -C $testRepo.WorkDir push origin "refs/tags/${tagPrefix}65499" 2>&1 | Out-Null

        { Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5 `
            -RepoUrl "file://$($testRepo.BareDir)" -DestPath "$($testRepo.WorkDir)-test" } | Should -Throw '*reached hard limit*65500*'

        Remove-TestGitRepo -Repo $testRepo
        Remove-Item "$($testRepo.WorkDir)-test" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'throws hard error when build counter already past 65500 (skip scenario)' {
        $testRepo = New-TestGitRepo
        $env:APP_TOKEN = 'test-token'
        $tagPrefix = '_counters/org/repo/repo-'

        & git -C $testRepo.BareDir tag "${tagPrefix}65510" 2>&1 | Out-Null
        & git -C $testRepo.WorkDir push origin "refs/tags/${tagPrefix}65510" 2>&1 | Out-Null

        { Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5 `
            -RepoUrl "file://$($testRepo.BareDir)" -DestPath "$($testRepo.WorkDir)-test" } | Should -Throw '*reached hard limit*'

        Remove-TestGitRepo -Repo $testRepo
        Remove-Item "$($testRepo.WorkDir)-test" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'emits warning and allocates successfully at 65001' {
        $testRepo = New-TestGitRepo
        $env:APP_TOKEN = 'test-token'
        $tagPrefix = '_counters/org/repo/repo-'
        $script:capturedOutput = @{}

        & git -C $testRepo.BareDir tag "${tagPrefix}65000" 2>&1 | Out-Null
        & git -C $testRepo.WorkDir push origin "refs/tags/${tagPrefix}65000" 2>&1 | Out-Null

        Mock -CommandName 'Set-GitHubOutput' -MockWith {
            param($Outputs)
            $script:capturedOutput = $Outputs
        }

        { Invoke-AllocateBuildCounter -CounterKey 'repo' -MaxRetries 5 `
            -RepoUrl "file://$($testRepo.BareDir)" -DestPath "$($testRepo.WorkDir)-test" } | Should -Not -Throw

        $script:capturedOutput.build_number | Should -Be 65001
        $script:capturedOutput.tag | Should -Be "${tagPrefix}65001"

        Remove-TestGitRepo -Repo $testRepo
        Remove-Item "$($testRepo.WorkDir)-test" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
