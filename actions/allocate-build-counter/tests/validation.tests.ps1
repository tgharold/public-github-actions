BeforeAll {
    . "$PSScriptRoot/shared.ps1"
}

Describe 'Test-ValidCounterKey' {
    It 'accepts valid alphanumeric counter_key' {
        Test-ValidCounterKey -CounterKey 'repo' | Should -Be $true
        Test-ValidCounterKey -CounterKey 'build123' | Should -Be $true
        Test-ValidCounterKey -CounterKey 'a' | Should -Be $true
    }

    It 'accepts 32-character counter_key (max length)' {
        $counterKey32 = 'a' * 32
        Test-ValidCounterKey -CounterKey $counterKey32 | Should -Be $true
    }

    It 'rejects empty counter_key' {
        { Test-ValidCounterKey -CounterKey '' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects counter_key longer than 32 chars' {
        $counterKey33 = 'a' * 33
        { Test-ValidCounterKey -CounterKey $counterKey33 -ErrorAction Stop } | Should -Throw
    }

    It 'rejects counter_key with special characters' {
        { Test-ValidCounterKey -CounterKey 'repo-app' -ErrorAction Stop } | Should -Throw
        { Test-ValidCounterKey -CounterKey 'repo_app' -ErrorAction Stop } | Should -Throw
        { Test-ValidCounterKey -CounterKey 'repo.app' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects counter_key with spaces' {
        { Test-ValidCounterKey -CounterKey 'repo app' -ErrorAction Stop } | Should -Throw
    }
}

Describe 'Test-ValidMaxRetries' {
    It 'accepts valid retry counts' {
        Test-ValidMaxRetries -MaxRetries 1 | Should -Be $true
        Test-ValidMaxRetries -MaxRetries 25 | Should -Be $true
        Test-ValidMaxRetries -MaxRetries 100 | Should -Be $true
    }

    It 'rejects zero retries' {
        { Test-ValidMaxRetries -MaxRetries 0 -ErrorAction Stop } | Should -Throw
    }

    It 'rejects negative retries' {
        { Test-ValidMaxRetries -MaxRetries -1 -ErrorAction Stop } | Should -Throw
    }

    It 'rejects retries over 100' {
        { Test-ValidMaxRetries -MaxRetries 101 -ErrorAction Stop } | Should -Throw
    }
}

Describe 'Test-ValidGitHubOwner' {
    It 'accepts valid GitHub owners' {
        Test-ValidGitHubOwner -Owner 'myorg' | Should -Be $true
        Test-ValidGitHubOwner -Owner 'my-org' | Should -Be $true
        Test-ValidGitHubOwner -Owner 'org123' | Should -Be $true
        Test-ValidGitHubOwner -Owner 'a' | Should -Be $true
    }

    It 'accepts 39-character owner (max length)' {
        $owner39 = 'a' * 39
        Test-ValidGitHubOwner -Owner $owner39 | Should -Be $true
    }

    It 'rejects empty owner' {
        { Test-ValidGitHubOwner -Owner '' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects owner longer than 39 chars' {
        $owner40 = 'a' * 40
        { Test-ValidGitHubOwner -Owner $owner40 -ErrorAction Stop } | Should -Throw
    }

    It 'rejects owner starting with hyphen' {
        { Test-ValidGitHubOwner -Owner '-org' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects owner ending with hyphen' {
        { Test-ValidGitHubOwner -Owner 'org-' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects owner with special characters' {
        { Test-ValidGitHubOwner -Owner 'org_name' -ErrorAction Stop } | Should -Throw
        { Test-ValidGitHubOwner -Owner 'org.name' -ErrorAction Stop } | Should -Throw
        { Test-ValidGitHubOwner -Owner 'org@name' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects owner with spaces' {
        { Test-ValidGitHubOwner -Owner 'org name' -ErrorAction Stop } | Should -Throw
    }
}

Describe 'Test-ValidRepositoryName' {
    It 'accepts valid repository names' {
        Test-ValidRepositoryName -Name 'my-repo' | Should -Be $true
        Test-ValidRepositoryName -Name 'my_repo' | Should -Be $true
        Test-ValidRepositoryName -Name 'my.repo' | Should -Be $true
        Test-ValidRepositoryName -Name 'repo123' | Should -Be $true
        Test-ValidRepositoryName -Name 'a' | Should -Be $true
        Test-ValidRepositoryName -Name '_repo' | Should -Be $true
    }

    It 'accepts 255-character name (max length)' {
        $name255 = 'a' * 255
        Test-ValidRepositoryName -Name $name255 | Should -Be $true
    }

    It 'rejects empty name' {
        { Test-ValidRepositoryName -Name '' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects name longer than 255 chars' {
        $name256 = 'a' * 256
        { Test-ValidRepositoryName -Name $name256 -ErrorAction Stop } | Should -Throw
    }

    It 'rejects name with special characters' {
        { Test-ValidRepositoryName -Name 'repo@name' -ErrorAction Stop } | Should -Throw
        { Test-ValidRepositoryName -Name 'repo#name' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects name with spaces' {
        { Test-ValidRepositoryName -Name 'repo name' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects name starting with a dot' {
        { Test-ValidRepositoryName -Name '.foo' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects name starting with a hyphen' {
        { Test-ValidRepositoryName -Name '-foo' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects bare dot / double-dot' {
        { Test-ValidRepositoryName -Name '.' -ErrorAction Stop } | Should -Throw
        { Test-ValidRepositoryName -Name '..' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects consecutive dots inside the name' {
        { Test-ValidRepositoryName -Name 'foo..bar' -ErrorAction Stop } | Should -Throw
    }
}

Describe 'Test-ValidGitHubServerUrl' {
    It 'accepts the canonical github.com URL' {
        Test-ValidGitHubServerUrl -Url 'https://github.com' | Should -Be $true
    }

    # Each rejection below corresponds to an attack pattern documented in the
    # block comment above Test-ValidGitHubServerUrl. The strict equality check
    # is what enforces these; the cases below pin the behavior.

    It 'rejects userinfo present - credential confusion / auth masquerade' {
        { Test-ValidGitHubServerUrl -Url 'https://user:pass@github.com' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects multiple @ characters - host-extraction ambiguity' {
        { Test-ValidGitHubServerUrl -Url 'https://a@b@github.com' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects port confusion via userinfo masquerade - looks like github.com but points elsewhere' {
        { Test-ValidGitHubServerUrl -Url 'https://github.com:443@evil.com' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects implicit empty auth - credential placeholder confuses parser' {
        { Test-ValidGitHubServerUrl -Url 'https://:@github.com' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects empty host - would fall through to local URL resolution' {
        { Test-ValidGitHubServerUrl -Url 'https:///foo' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects percent-encoded host - decoding mismatch between validator and consumer' {
        { Test-ValidGitHubServerUrl -Url 'https://github%2ecom@evil.com' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects IDN / Unicode homograph - visual lookalike resolving elsewhere' {
        { Test-ValidGitHubServerUrl -Url "https://g$([char]0x00EC)thub.com" -ErrorAction Stop } | Should -Throw
    }

    It 'rejects trailing whitespace / control chars - header-injection risk' {
        { Test-ValidGitHubServerUrl -Url "https://github.com`r`n" -ErrorAction Stop } | Should -Throw
    }

    It 'rejects fragment - parser desync between validator and git' {
        { Test-ValidGitHubServerUrl -Url 'https://github.com#x' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects query string - same parser desync risk as fragments' {
        { Test-ValidGitHubServerUrl -Url 'https://github.com?x=y' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects path traversal - escape from expected path layout' {
        { Test-ValidGitHubServerUrl -Url 'https://github.com/../' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects case-variant scheme/host - case-fold bypass risk' {
        { Test-ValidGitHubServerUrl -Url 'HTTPS://GITHUB.COM' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects port :0 - malformed shape used to confuse parsers' {
        { Test-ValidGitHubServerUrl -Url 'https://github.com:0' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects trailing .git on bare server URL - parsed as different host' {
        { Test-ValidGitHubServerUrl -Url 'https://github.com.git' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects trailing slash - strict equality (no normalization)' {
        { Test-ValidGitHubServerUrl -Url 'https://github.com/' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects empty URL' {
        { Test-ValidGitHubServerUrl -Url '' -ErrorAction Stop } | Should -Throw
    }

    It 'includes the Source label in the error message for troubleshooting' {
        try {
            Test-ValidGitHubServerUrl -Url 'https://evil.com' -Source 'GITHUB_SERVER_URL env var' -ErrorAction Stop
        }
        catch {
            $_.ToString() | Should -Match 'GITHUB_SERVER_URL env var'
        }
    }
}

Describe 'Test-ValidGitCounterRepoUrl' {
    It 'accepts file:// URLs (test fixture seam, no token attached)' {
        Test-ValidGitCounterRepoUrl -Url 'file:///tmp/anything' | Should -Be $true
        Test-ValidGitCounterRepoUrl -Url 'file:///tmp/path/with/../traversal' | Should -Be $true
    }

    It 'accepts https://github.com/<owner>/<repo>.git URLs' {
        Test-ValidGitCounterRepoUrl -Url 'https://github.com/org/repo.git' | Should -Be $true
    }

    It 'rejects http:// (no TLS)' {
        { Test-ValidGitCounterRepoUrl -Url 'http://github.com/org/repo.git' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects other hosts' {
        { Test-ValidGitCounterRepoUrl -Url 'https://evil.com/org/repo.git' -ErrorAction Stop } | Should -Throw
    }

    It 'rejects empty URL' {
        { Test-ValidGitCounterRepoUrl -Url '' -ErrorAction Stop } | Should -Throw
    }
}
