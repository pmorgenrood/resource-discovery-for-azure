# =============================================================================
# WrapperForwardsReadme.Tests.ps1
#
# WHY THIS TEST EXISTS
# --------------------
# The README says which parameters Run-AllSubscriptions.ps1 forwards to the
# inner ResourceInventory.ps1. A parameter added to the wrapper's forward list
# ($InventoryPassthrough) was easy to leave out of that sentence. This test
# reads every key the wrapper puts in $InventoryPassthrough and checks that the
# sentence names it.
# =============================================================================

Describe 'The README names every parameter the wrapper forwards' {
    BeforeAll {
        $Root = Split-Path $PSScriptRoot -Parent
        $Wrapper = Get-Content -LiteralPath (Join-Path $Root 'Run-AllSubscriptions.ps1') -Raw
        $script:Keys = @([regex]::Matches($Wrapper, "\`$InventoryPassthrough\['(\w+)'\]\s*=") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $Readme = Get-Content -LiteralPath (Join-Path $Root 'README.md') -Raw
        $Match = [regex]::Match($Readme, 'The wrapper forwards (.+?) to the inner `ResourceInventory\.ps1`', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $script:Sentence = if ($Match.Success) { $Match.Groups[1].Value } else { $null }
    }

    It 'finds the forward list and the README sentence' {
        $script:Keys.Count | Should -BeGreaterThan 0
        $script:Sentence | Should -Not -BeNullOrEmpty
    }

    It 'names -<_>' -ForEach @(
        $Root = Split-Path $PSScriptRoot -Parent
        $Wrapper = Get-Content -LiteralPath (Join-Path $Root 'Run-AllSubscriptions.ps1') -Raw
        [regex]::Matches($Wrapper, "\`$InventoryPassthrough\['(\w+)'\]\s*=") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    ) {
        $script:Sentence | Should -Match ('`-{0}`' -f [regex]::Escape($_))
    }
}
