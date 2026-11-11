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
# test reads every key of both lists and checks that the paragraph names each
# one, and names no parameter neither list forwards.
# =============================================================================

BeforeDiscovery {
    $Root = Split-Path $PSScriptRoot -Parent
    # $InventoryPassthrough['Key'] = ..., ["Key"] = ... or .Key = ...
    $Pattern = "\`$InventoryPassthrough(?:\[['""](\w+)['""]\]|\.(\w+))\s*="
    $script:Keys = @(
        foreach ($File in 'Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1')
        {
            $Text = Get-Content -LiteralPath (Join-Path $Root $File) -Raw
            [regex]::Matches($Text, $Pattern) | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } }
        }
    ) | Sort-Object -Unique
}

Describe 'The README names every parameter the wrapper forwards' {
    BeforeAll {
        $Root = Split-Path $PSScriptRoot -Parent
        $Readme = Get-Content -LiteralPath (Join-Path $Root 'README.md') -Raw
        # The paragraph that starts 'The wrapper forwards', up to the next blank line.
        $Match = [regex]::Match($Readme, 'The wrapper forwards .+?(?=\r?\n\s*\r?\n)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $script:Paragraph = if ($Match.Success) { $Match.Value } else { $null }
        $script:Stream = Get-Content -LiteralPath (Join-Path $Root 'Run-AllSubscriptions.Stream.ps1') -Raw
        $script:Wrapper = Get-Content -LiteralPath (Join-Path $Root 'Run-AllSubscriptions.ps1') -Raw
    }

    It 'finds the forward lists and the README paragraph' {
        $Keys.Count | Should -BeGreaterThan 0
        $script:Paragraph | Should -Match 'to the inner `ResourceInventory\.ps1`'
    } -ForEach @{ Keys = $script:Keys }

    It 'names -<_>' -ForEach $script:Keys {
        $script:Paragraph | Should -Match ('`-{0}`' -f [regex]::Escape($_))
    }

    It 'names no parameter that neither list forwards' {
        $Named = @([regex]::Matches($script:Paragraph, '`-(\w+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        @($Named | Where-Object { $Keys -notcontains $_ }) | Should -BeNullOrEmpty
    } -ForEach @{ Keys = $script:Keys }

    It 'says -Debug does not reach parallel streams only while the stream path does not pass it' {
        if ($script:Paragraph -match 'not to parallel streams')
        {
            $script:Stream | Should -Not -Match "InventoryPassthrough(?:\[['""]Debug['""]\]|\.Debug)\s*="
            $script:Wrapper | Should -Not -Match "WorkerArgs(?:\[['""]Debug['""]\]|\.Debug)\s*=|WorkerArgs\s*=\s*@\{[^}]*\bDebug\s*="
            $script:Wrapper | Should -Not -Match "WorkerArgs\.Add\(\s*['""]Debug['""]"
        }
    }
}
