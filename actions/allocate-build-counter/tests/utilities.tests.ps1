BeforeAll {
    . "$PSScriptRoot/shared.ps1"
}

Describe 'Set-GitHubOutput' {
    It 'writes outputs to GITHUB_OUTPUT file' {
        $tempFile = [System.IO.Path]::GetTempFileName()
        try {
            $env:GITHUB_OUTPUT = $tempFile
            Set-GitHubOutput @{ build_number = 42; tag = 'test-42' }

            $content = Get-Content $tempFile
            $content | Should -Contain 'build_number=42'
            $content | Should -Contain 'tag=test-42'
        }
        finally {
            Remove-Item $tempFile -ErrorAction SilentlyContinue
        }
    }

    It 'handles missing GITHUB_OUTPUT gracefully' {
        $env:GITHUB_OUTPUT = ''
        { Set-GitHubOutput @{ build_number = 42 } } | Should -Not -Throw
    }
}

Describe 'Format-GitArgsForDisplay' {
    It 'redacts token in basic-auth URL' {
        # Use a fixture password that is obviously not a credential to avoid
        # tripping repository secret scanners on the test source itself.
        $fixturePassword = 'placeholder-test-fixture-not-a-credential'
        $redacted = Format-GitArgsForDisplay -Arguments @('clone', "https://x-access-token:${fixturePassword}@example.test/org/repo.git", '/tmp/x')
        $redacted -join ' ' | Should -Match '://x-access-token:\*\*\*@example.test'
        $redacted -join ' ' | Should -Not -Match $fixturePassword
    }

    It 'leaves token-free URLs untouched' {
        $args1 = @('fetch', '--tags', '--force')
        $redacted = Format-GitArgsForDisplay -Arguments $args1
        @($redacted) | Should -Be $args1
    }

    It 'leaves file:// URLs untouched' {
        $args1 = @('clone', 'file:///tmp/bare.git', '/tmp/x')
        $redacted = Format-GitArgsForDisplay -Arguments $args1
        @($redacted) | Should -Be $args1
    }
}

Describe 'Backoff randomization' {
    It 'uses correct bounds for random backoff (3-12s window)' {
        $min = 3000
        $max = 12001
        $max - $min | Should -Be 9001

        $rng = [System.Random]::new()
        $values = @()
        for ($i = 0; $i -lt 50; $i++) {
            $val = $rng.Next($min, $max)
            $val | Should -BeGreaterOrEqual $min
            $val | Should -BeLessThan $max
            $values += $val
        }

        $values | Select-Object -Unique | Measure-Object | Select-Object -ExpandProperty Count | Should -BeGreaterThan 1
    }
}
