# Run-AllSubscriptions.ps1 and Run-AllSubscriptions.Stream.ps1: the warning
# printed when a subscription returns 0 resources.
#
# A subscription the identity cannot read never reaches collection: the
# up-front role check stops the run (or skips it with -AllowPartialAccess). So
# the warning must not name a permission gap as the likely cause. The warning
# lines are read from the parsed scripts; neither script can run here.
#
# Run with: Invoke-Pester ./Tests/ZeroResourceWarning.Tests.ps1 -Output Detailed

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent

    # Every Write-Host / Write-Stream call in $File whose text holds 'returned 0 resources'.
    function script:Get-ZeroResourceWarnings
    {
        param([string]$File)
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $File), [ref]$null, [ref]$null)
        @($Ast.FindAll({
                    $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                    @('Write-Host', 'Write-Stream') -contains $args[0].GetCommandName() -and
                    $args[0].Extent.Text.Contains('returned 0 resources')
                }, $true) | ForEach-Object { $_.Extent.Text })
    }
}

Describe 'The 0-resources warning of a collected subscription' {
    It 'says in <File> that the subscription passed the up-front role check, and names no permission gap' -ForEach @(
        @{ File = 'Run-AllSubscriptions.ps1' }
        @{ File = 'Run-AllSubscriptions.Stream.ps1' }
    ) {
        $Warnings = @(script:Get-ZeroResourceWarnings -File $File)
        $Warnings.Count | Should -BeGreaterThan 0
        @($Warnings | Where-Object { $_ -match 'passed the up-front role check' }).Count | Should -Be 1
        @($Warnings | Where-Object { $_ -match 'permission gap' }) | Should -BeNullOrEmpty
    }
}
