#Requires -Modules Pester

# Unit tests for the pure helper functions in the Tier 0 / cert scripts.
#
# These scripts run their main flow on load, so we can't dot-source them wholesale.
# Instead we extract just the named function definitions via the AST and define
# them in isolation — no Azure calls, no side effects.

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    # Extract just the named pure functions from each script and dot-source them
    # here in the BeforeAll scope (Pester makes BeforeAll definitions available to
    # the It blocks). We can't dot-source the scripts wholesale because they run
    # their main flow on load. Dot-sourcing must happen directly here, not inside
    # a helper function, or the definitions would be trapped in the helper's scope.
    $targets = @(
        @{ Path = (Join-Path $repoRoot 'scripts' 'New-RdsCertificate.ps1'); Names = @('Get-CertSubject', 'New-KvCertPolicy') }
        @{ Path = (Join-Path $repoRoot 'scripts' 'Initialize-RdsFarm.ps1');  Names = @('Get-DefaultDnsLabel', 'Test-FqdnFormat') }
    )
    foreach ($target in $targets) {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($target.Path, [ref]$null, [ref]$parseErrors)
        if ($parseErrors) { throw "Parse errors in $($target.Path): $($parseErrors -join '; ')" }
        foreach ($fnName in $target.Names) {
            $fn = $ast.Find(
                { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $fnName },
                $true)
            if (-not $fn) { throw "Function '$fnName' not found in $($target.Path)" }
            . ([scriptblock]::Create($fn.Extent.Text))
        }
    }
}

Describe 'Get-CertSubject' {
    It 'prefixes the FQDN with CN=' {
        Get-CertSubject 'rds.slejco.com' | Should -Be 'CN=rds.slejco.com'
    }
}

Describe 'New-KvCertPolicy' {
    BeforeAll {
        $script:policy = New-KvCertPolicy -Fqdn 'rds.slejco.com' -IssuerName 'Self' -ValidityMonths 12
    }

    It 'requests an exportable RSA 2048 key' {
        $policy.keyProperties.exportable | Should -BeTrue
        $policy.keyProperties.keyType    | Should -Be 'RSA'
        $policy.keyProperties.keySize    | Should -Be 2048
    }

    It 'sets the subject and SAN to the FQDN' {
        $policy.x509CertificateProperties.subject | Should -Be 'CN=rds.slejco.com'
        $policy.x509CertificateProperties.subjectAlternativeNames.dnsNames | Should -Contain 'rds.slejco.com'
    }

    It 'includes the Server Authentication EKU' {
        $policy.x509CertificateProperties.ekus | Should -Contain '1.3.6.1.5.5.7.3.1'
    }

    It 'includes digitalSignature key usage (RD Gateway rejects certs without it)' {
        $policy.x509CertificateProperties.keyUsage | Should -Contain 'digitalSignature'
    }

    It 'passes the issuer name through' {
        $policy.issuerParameters.name | Should -Be 'Self'
    }
}

Describe 'Get-DefaultDnsLabel' {
    It 'keeps an already-valid label unchanged' {
        Get-DefaultDnsLabel 'rds-01.slejco.com' | Should -Be 'rds-01'
    }

    It 'strips characters that are invalid in a DNS label' {
        Get-DefaultDnsLabel 'rds_gw.slejco.com' | Should -Be 'rdsgw'
    }

    It 'lowercases an uppercase label' {
        Get-DefaultDnsLabel 'RDS.slejco.com' | Should -Be 'rds'
    }
}

Describe 'Test-FqdnFormat' {
    It 'accepts a real vanity FQDN' {
        Test-FqdnFormat 'rds.slejco.com' | Should -BeTrue
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a bare hostname';  Value = 'rds' }
        @{ Case = 'an underscore';    Value = 'rds_gw.slejco.com' }
        @{ Case = 'a leading hyphen'; Value = '-rds.slejco.com' }
        @{ Case = 'an empty string';  Value = '' }
    ) {
        Test-FqdnFormat $Value | Should -BeFalse
    }
}
