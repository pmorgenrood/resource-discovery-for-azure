# =============================================================================
# WrapperForwardsReadme.Tests.ps1
#
# WHY THIS TEST EXISTS
# --------------------
# The README says which parameters Run-AllSubscriptions.ps1 passes to the
# inner ResourceInventory.ps1. A parameter added to a forward list was easy to
# leave out of that paragraph. The inner run gets its parameters from one of
# two lists: the wrapper's own $InventoryPassthrough (sequential path) and the
# stream worker's (Run-AllSubscriptions.Stream.ps1, parallel streams). This
# test reads every key of both lists and checks that the paragraph names it.
# =============================================================================

BeforeDiscovery {
    $Root = Split-Path $PSScriptRoot -Parent
    $script:Keys = @(
        foreach ($File in 'Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1')
        {
            $Text = Get-Content -LiteralPath (Join-Path $Root $File) -Raw
            [regex]::Matches($Text, "\`$InventoryPassthrough\['(\w+)'\]\s*=") | ForEach-Object { $_.Groups[1].Value }
        }
    ) | Sort-Object -Unique
}

Describe 'The README names every parameter the wrapper forwards' {
    BeforeAll {
        $Readme = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'README.md') -Raw
        # The paragraph that starts 'The wrapper forwards', up to the next blank line.
        $Match = [regex]::Match($Readme, 'The wrapper forwards .+?(?=\r?\n\s*\r?\n)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $script:Paragraph = if ($Match.Success) { $Match.Value } else { $null }
    }

    It 'finds the forward lists and the README paragraph' {
        $Keys.Count | Should -BeGreaterThan 0
        $script:Paragraph | Should -Match 'to the inner `ResourceInventory\.ps1`'
    } -ForEach @{ Keys = $script:Keys }

    It 'names -<_>' -ForEach $script:Keys {
        $script:Paragraph | Should -Match ('`-{0}`' -f [regex]::Escape($_))
    }
}
