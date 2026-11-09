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
    It 'says in <File> what 0 resources can mean: empty, or resources the identity cannot read' -ForEach @(
        @{ File = 'Run-AllSubscriptions.ps1' }
        @{ File = 'Run-AllSubscriptions.Stream.ps1' }
    ) {
        $Warnings = @(script:Get-ZeroResourceWarnings -File $File)
        $Warnings.Count | Should -BeGreaterThan 0
        # The role check only lists resource groups, and the query runs as the
        # Azure CLI's account: the warning that names a cause names those, and
        # never 'Likely permission gap' alone or an empty subscription alone.
        $Named = @($Warnings | Where-Object { $_ -match 'Reader' })
        $Named.Count | Should -Be 1
        $Named[0] | Should -Match 'Azure CLI'
        $Named[0] | Should -Match 'resource groups'
        @($Warnings | Where-Object { $_ -match 'Likely permission gap' -or $_ -match 'Resource Graph lists no resource' }) | Should -BeNullOrEmpty
        # The inline warning gives a Search-AzGraph hint that says which account it checks.
        if ($File -eq 'Run-AllSubscriptions.ps1')
        {
            $Hint = @($Warnings | Where-Object { $_ -match 'Search-AzGraph' })
            $Hint.Count | Should -Be 1
            $Hint[0] | Should -Match "it runs as the Az PowerShell account; check the Azure CLI's account apart"
        }
    }
}
