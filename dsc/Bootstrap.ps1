<#
.SYNOPSIS
    CSE bootstrap that compiles + applies one of the DSC configurations
    defined in Configuration.ps1.

.DESCRIPTION
    Invoked by Microsoft.Compute/CustomScriptExtension. CSE downloads
    Bootstrap.ps1 + Configuration.zip into the same directory using the VM's
    user-assigned managed identity (Storage Blob Data Reader on the artifacts
    SA). This script then:
      1. Extracts Configuration.zip next to itself.
      2. Dot-sources Configuration.ps1 to register the three configuration
         functions (Gateway, SessionHost, RDSDeployment).
      3. Decodes the base64-JSON arg blobs (public + protected) into
         hashtables, promoting any { UserName, Password } entries into
         PSCredentials.
      4. Compiles the selected configuration into a MOF under C:\RdsBootstrap
         with PSDscAllowPlainTextPassword (the MOF is local-only and removed
         at the end of the run).
      5. Runs Start-DscConfiguration -Wait -Force. The localhost.meta.mof is
         deliberately discarded so the default LCM (RebootNodeIfNeeded=$false)
         stays in effect; DSC reports pending-reboot instead of killing the
         CSE process mid-stream.
      6. If a reboot is pending, schedules a deferred restart (120s) so CSE
         can report success first. CSE docs explicitly say "Don't put
         restarts inside the script" — shutdown.exe /r /t is the documented
         escape hatch because it returns immediately.

.NOTES
    Replaces the Microsoft.Powershell/DSC extension, which silently ignored
    our managedIdentity protectedSettings and tried anonymous downloads.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ConfigurationFunction,
    [Parameter(Mandatory)] [string] $ArgumentsBase64,
    [string] $ProtectedArgumentsBase64 = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$workDir = 'C:\RdsBootstrap'
$logDir  = Join-Path $workDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $logDir "bootstrap-$ConfigurationFunction-$stamp.log"
Start-Transcript -Path $logPath -Append | Out-Null

try {
    Write-Host "==> Bootstrap start: $ConfigurationFunction ($stamp)"

    # -----------------------------------------------------------------------
    # 1. Locate + extract Configuration.zip (CSE puts both files in the same
    #    Downloads\<seq> directory, which is our $PSScriptRoot here).
    # -----------------------------------------------------------------------
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $zipPath = Join-Path $scriptDir 'Configuration.zip'
    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "Configuration.zip not found next to Bootstrap.ps1 (looked in $scriptDir). Check that CSE fileUris includes both files."
    }
    $dscDir = Join-Path $workDir 'dsc'
    if (Test-Path -LiteralPath $dscDir) { Remove-Item -LiteralPath $dscDir -Recurse -Force }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $dscDir -Force
    Write-Host "    Extracted $zipPath -> $dscDir"

    # -----------------------------------------------------------------------
    # 2. Dot-source Configuration.ps1 in this session
    # -----------------------------------------------------------------------
    $configPs1 = Get-ChildItem -LiteralPath $dscDir -Filter 'Configuration.ps1' -Recurse |
                 Select-Object -First 1
    if (-not $configPs1) { throw "Configuration.ps1 not found inside Configuration.zip" }
    . $configPs1.FullName
    Write-Host "    Loaded $($configPs1.FullName)"

    if (-not (Get-Command -Name $ConfigurationFunction -CommandType Configuration -ErrorAction SilentlyContinue)) {
        $available = (Get-Command -CommandType Configuration | Select-Object -ExpandProperty Name) -join ', '
        throw "Configuration function '$ConfigurationFunction' not registered. Available: $available"
    }

    # -----------------------------------------------------------------------
    # 3. Decode argument blobs (base64-encoded JSON)
    # -----------------------------------------------------------------------
    function ConvertFrom-Base64Json {
        param([string] $Base64)
        if ([string]::IsNullOrWhiteSpace($Base64)) { return @{} }
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
        if ([string]::IsNullOrWhiteSpace($json) -or $json.Trim() -eq '{}') { return @{} }
        $obj = $json | ConvertFrom-Json
        $hash = @{}
        foreach ($p in $obj.PSObject.Properties) {
            $hash[$p.Name] = $p.Value
        }
        return $hash
    }

    $public    = ConvertFrom-Base64Json -Base64 $ArgumentsBase64
    $protected = ConvertFrom-Base64Json -Base64 $ProtectedArgumentsBase64

    $params = @{}
    foreach ($k in $public.Keys) { $params[$k] = $public[$k] }
    foreach ($k in $protected.Keys) {
        $v = $protected[$k]
        $hasUser = $false
        $hasPass = $false
        if ($v -is [psobject]) {
            $hasUser = ($v.PSObject.Properties.Name -contains 'UserName')
            $hasPass = ($v.PSObject.Properties.Name -contains 'Password')
        }
        if ($hasUser -and $hasPass) {
            $sec = ConvertTo-SecureString -String $v.Password -AsPlainText -Force
            $params[$k] = [pscredential]::new($v.UserName, $sec)
            Write-Host "    Promoted '$k' to PSCredential (User=$($v.UserName))"
        } else {
            $params[$k] = $v
        }
    }

    # -----------------------------------------------------------------------
    # 4. Compile MOF
    # -----------------------------------------------------------------------
    $mofDir = Join-Path $workDir "mof-$ConfigurationFunction"
    if (Test-Path -LiteralPath $mofDir) { Remove-Item -LiteralPath $mofDir -Recurse -Force }
    New-Item -ItemType Directory -Path $mofDir | Out-Null

    # PSCredential params require ConfigurationData allowing plaintext. The MOF
    # only exists under C:\RdsBootstrap on local disk and is removed at the end.
    $cfgData = @{
        AllNodes = @(
            @{
                NodeName                    = 'localhost'
                PSDscAllowPlainTextPassword = $true
                PSDscAllowDomainUser        = $true
            }
        )
    }

    $params['ConfigurationData'] = $cfgData
    $params['OutputPath']        = $mofDir

    Write-Host "    Compiling $ConfigurationFunction ..."
    & $ConfigurationFunction @params | Out-Null
    $mofs = Get-ChildItem -LiteralPath $mofDir -Filter '*.mof' | ForEach-Object FullName
    Write-Host "    Wrote MOFs: $($mofs -join ', ')"

    # Drop the meta MOF so the default LCM (RebootNodeIfNeeded=$false) stays
    # in effect; we handle the post-DSC reboot ourselves with shutdown.exe so
    # CSE can report success before the VM goes down. Mid-DSC reboots would
    # kill the CSE process and put the extension into Failed.
    $metaMof = Join-Path $mofDir 'localhost.meta.mof'
    if (Test-Path -LiteralPath $metaMof) {
        Remove-Item -LiteralPath $metaMof -Force
        Write-Host "    Removed $metaMof (reboots are handled by Bootstrap.ps1 after DSC completes)"
    }

    # -----------------------------------------------------------------------
    # 5. Apply
    # -----------------------------------------------------------------------
    Write-Host "    Applying DSC configuration ..."
    Start-DscConfiguration -Path $mofDir -Wait -Force -Verbose
    Write-Host "    Start-DscConfiguration completed."

    # Surface partial failures. Start-DscConfiguration -Wait does NOT throw when
    # an individual resource's SetScript fails - it logs to the DSC stream and
    # returns normally. Without this gate the CSE (and therefore the ARM
    # deployment) reports success even when, e.g., certificate binding failed,
    # hiding the problem behind a green deploy. Only an explicit Status='Failure'
    # is treated as fatal, so a benign pending-reboot does not trip it.
    $dscStatus = Get-DscConfigurationStatus -ErrorAction SilentlyContinue
    if ($null -ne $dscStatus -and $dscStatus.Status -ne 'Success') {
        $failedIds = @($dscStatus.ResourcesNotInDesiredState | ForEach-Object { $_.ResourceId }) -join ', '
        throw "DSC apply did not converge (Status=$($dscStatus.Status)). Resources not in desired state: $failedIds"
    }
    Write-Host "    DSC convergence: $(if ($dscStatus) { $dscStatus.Status } else { 'unverified' })"

    # -----------------------------------------------------------------------
    # 6. Reboot handling
    # -----------------------------------------------------------------------
    function Test-PendingReboot {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        )
        foreach ($k in $keys) {
            if (Test-Path -LiteralPath $k) { return $true }
        }
        $pf = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($pf -and $pf.PendingFileRenameOperations) { return $true }
        return $false
    }

    if (Test-PendingReboot) {
        Write-Host "    Pending reboot detected -- scheduling restart in 120s so CSE reports success first."
        & shutdown.exe /r /t 120 /c "RdsBootstrap deferred reboot after $ConfigurationFunction"
    } else {
        Write-Host "    No reboot required."
    }

    Write-Host "==> Bootstrap success: $ConfigurationFunction"
    Stop-Transcript | Out-Null
    exit 0
}
catch {
    Write-Host "==> Bootstrap FAILED: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    Stop-Transcript | Out-Null
    exit 1
}
