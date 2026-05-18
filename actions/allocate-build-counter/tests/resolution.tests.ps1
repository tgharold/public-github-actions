BeforeAll {
    . "$PSScriptRoot/shared.ps1"
}

Describe 'Get-ResolvedOrganization' {
    It 'uses GITHUB_REPOSITORY_OWNER env var when set' {
        $env:GITHUB_REPOSITORY_OWNER = 'envorg'
        $info = Get-ResolvedOrganization
        $info.Value | Should -Be 'envorg'
        $info.Source | Should -Be 'GITHUB_REPOSITORY_OWNER env var'
    }

    It 'uses default fallback when env is empty' {
        $env:GITHUB_REPOSITORY_OWNER = ''
        $info = Get-ResolvedOrganization
        $info.Value | Should -Be 'local-org'
        $info.Source | Should -Be 'fallback default'
    }

    It 'does not validate inside the helper - returns raw value even when invalid' {
        $env:GITHUB_REPOSITORY_OWNER = 'invalid-org-'
        $info = Get-ResolvedOrganization
        $info.Value | Should -Be 'invalid-org-'
    }
}

Describe 'Get-ResolvedRepository' {
    It 'extracts repo from GITHUB_REPOSITORY when env is set' {
        $env:GITHUB_REPOSITORY = 'org/envrepo'
        $info = Get-ResolvedRepository
        $info.Value | Should -Be 'envrepo'
        $info.Source | Should -Be 'GITHUB_REPOSITORY env var'
    }

    It 'uses default fallback when env is empty' {
        $env:GITHUB_REPOSITORY = ''
        $info = Get-ResolvedRepository
        $info.Value | Should -Be 'local-repo'
        $info.Source | Should -Be 'fallback default'
    }

    It 'does not validate inside the helper - returns raw value even when invalid' {
        $env:GITHUB_REPOSITORY = 'org/repo@invalid'
        $info = Get-ResolvedRepository
        $info.Value | Should -Be 'repo@invalid'
    }
}
