# PSScriptAnalyzer settings — rds-farm
#
# Applies to the laptop / CI-side PowerShell (scripts/, tests/), which run on
# PowerShell 7, where PS7 idioms are allowed.
#
# The server-side DSC (dsc/Configuration.ps1, dsc/Bootstrap.ps1) must stay
# Windows PowerShell 5.1-compatible. That constraint is enforced separately by a
# real 5.1 *parse* in tests/Test-DscConfiguration.ps1 and the validate.yml
# "dsc-parse" job — NOT by a global PSUseCompatibleSyntax rule here, because a
# blanket 5.1 rule would false-positive on the intentional PS7 idioms (??, ?.,
# ternary, -Parallel) used in the laptop scripts.
@{
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning')

    ExcludeRules = @(
        # DSC configs receive a [PSCredential] and must hand the plain-text
        # password to the legacy RemoteDesktop cmdlets; these two rules fire on
        # that by-design pattern.
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingConvertToSecureStringWithPlainText'

        # The deploy/init helper functions intentionally omit ShouldProcess so
        # they stay non-interactive in CI and Tier 0 automation.
        'PSUseShouldProcessForStateChangingFunctions'

        # These are CLI / deploy scripts: colored Write-Host progress output is
        # intentional operator UX, not pipeline data.
        'PSAvoidUsingWriteHost'

        # scripts/ and tests/ run on PowerShell 7, where a UTF-8 BOM is not
        # required. The BOM only matters for the 5.1-executed dsc/ files, which
        # the validate.yml encoding guard checks separately.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
