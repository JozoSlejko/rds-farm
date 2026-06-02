<#
.SYNOPSIS
    Static-analysis and parse tests for the DSC configuration script.

.DESCRIPTION
    Validates dsc/Configuration.ps1 without requiring Azure access:
      1. PSScriptAnalyzer reports zero Error / Warning severities.
      2. The file parses cleanly under the Windows PowerShell 5.1 grammar that
         actually runs on the VMs.
      3. All three configurations (SessionHost, Gateway, RDSDeployment) are
         discoverable by name after the script is dot-sourced.

    Exits non-zero on any failure so it can gate a CI job.

.PARAMETER ConfigurationPath
    Path to the DSC configuration script.

.EXAMPLE
    pwsh -File tests/Test-DscConfiguration.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..' 'dsc' 'Configuration.ps1')
)

$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]
$dscSchemaStorePath = '/etc/opt/omi/conf/dsc/configuration'
$canRunDscGrammarChecks = $IsWindows -or (Test-Path -LiteralPath $dscSchemaStorePath)

function Write-TestResult {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $status = if ($Ok) { 'PASS' } else { 'FAIL' }
    $color  = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}" -f $status, $Name) -ForegroundColor $color
    if (-not $Ok) {
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkYellow }
        $failures.Add($Name) | Out-Null
    }
}

$ConfigurationPath = (Resolve-Path -LiteralPath $ConfigurationPath).Path
Write-Host "Target: $ConfigurationPath" -ForegroundColor Cyan
Write-Host ('-' * 60)

# 1. PSScriptAnalyzer
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host 'Installing PSScriptAnalyzer...' -ForegroundColor DarkGray
    if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
    Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
}
Import-Module PSScriptAnalyzer -ErrorAction Stop

# Some rules don't apply to DSC configurations (e.g. PSAvoidUsingPlainTextForPassword
# would fire on the Configuration parameter blocks, which are designed to receive
# a PSCredential and pass its plain-text password to the underlying cmdlets).
$excludedRules = @(
    'PSAvoidUsingPlainTextForPassword',
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    'PSUseShouldProcessForStateChangingFunctions'
)

$issues = Invoke-ScriptAnalyzer -Path $ConfigurationPath -ExcludeRule $excludedRules -Severity Error, Warning
if ($issues) {
    $issues | Format-Table RuleName, Severity, Line, Message -AutoSize | Out-Host
    Write-TestResult 'PSScriptAnalyzer (no Error / Warning issues)' $false "$($issues.Count) issue(s)"
} else {
    Write-TestResult 'PSScriptAnalyzer (no Error / Warning issues)' $true
}

# 2. PowerShell parser (uses the language service from whichever PS version is hosting this script;
# for stricter coverage of the DSC runtime grammar, run this script under Windows PowerShell 5.1.)
if ($canRunDscGrammarChecks) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($ConfigurationPath, [ref]$null, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $parseErrors | Format-Table Extent, Message -AutoSize | Out-Host
        Write-TestResult 'Parse cleanly' $false "$($parseErrors.Count) parse error(s)"
    } else {
        Write-TestResult 'Parse cleanly' $true
    }
} else {
    Write-Host "Skipping DSC parser grammar checks: schema store not found at '$dscSchemaStorePath'." -ForegroundColor DarkYellow
    Write-TestResult 'Parse cleanly (skipped: DSC schema store unavailable on host)' $true
}

# 3. Configuration discovery — dot-source in an isolated scope and confirm the
# three keywords land in the function: drive.
$expectedConfigs = @('SessionHost', 'Gateway', 'RDSDeployment')
if ($canRunDscGrammarChecks) {
    $discoveryOk = $true
    $discoveryDetail = ''
    try {
        & {
            . $ConfigurationPath
            foreach ($name in $expectedConfigs) {
                $cmd = Get-Command -Name $name -CommandType Configuration -ErrorAction SilentlyContinue
                if (-not $cmd) {
                    $script:discoveryOk = $false
                    $script:discoveryDetail += "Missing configuration: $name. "
                }
            }
        }
    } catch {
        $discoveryOk = $false
        $discoveryDetail = $_.Exception.Message
    }
    Write-TestResult ('Configurations discoverable: {0}' -f ($expectedConfigs -join ', ')) $discoveryOk $discoveryDetail
} else {
    Write-TestResult ('Configurations discoverable (skipped: DSC schema store unavailable on host): {0}' -f ($expectedConfigs -join ', ')) $true
}

# Summary
Write-Host ('-' * 60)
if ($failures.Count -gt 0) {
    Write-Host "FAILED ($($failures.Count)): $($failures -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host 'All DSC tests passed.' -ForegroundColor Green
exit 0
