# Run-AllSubscriptions.ps1 and its stream worker read the inventory folder
# only by literal path. -Path reads [ and ] as a wildcard, so a home folder
# holding them (C:\Users\a[1]) would list the wrong folders.
#
# Run with: Invoke-Pester ./Tests/InventoryRootLiteralPath.Tests.ps1 -Output Detailed

Describe 'The inventory folder is read by literal path' {
    It '<Script> passes $InventoryRoot to Get-ChildItem, Get-Item and Test-Path with -LiteralPath, never -Path' -ForEach @(
        @{ Script = 'Run-AllSubscriptions.ps1' }
        @{ Script = 'Run-AllSubscriptions.Stream.ps1' }
    ) {
        $File = Join-Path (Split-Path $PSScriptRoot -Parent) $Script
        $Tokens = $null; $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$Tokens, [ref]$Errors)
        $Errors.Count | Should -Be 0
        $Commands = $Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] -and @('Get-ChildItem', 'Get-Item', 'Test-Path') -contains $Node.GetCommandName() }, $true)
        $Wildcard = @(foreach ($Command in $Commands)
            {
                $Elements = @($Command.CommandElements)
                for ($i = 0; $i -lt $Elements.Count - 1; $i++)
                {
                    $Element = $Elements[$i]
                    if ($Element -is [System.Management.Automation.Language.CommandParameterAst] -and $Element.ParameterName -eq 'Path' -and $Elements[$i + 1].Extent.Text -match '^\$InventoryRoot$')
                    {
                        'line {0}: {1}' -f $Command.Extent.StartLineNumber, $Command.Extent.Text
                    }
                }
            })
        $Wildcard | Should -BeNullOrEmpty -Because ($Wildcard -join "`n")
    }
}
