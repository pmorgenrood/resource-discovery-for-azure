#Requires -Version 7.0
# =============================================================================
# WrapperConsumptionMaxPages.Tests.ps1
# Run with: Invoke-Pester ./Tests/WrapperConsumptionMaxPages.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# ResourceInventory.ps1 reads at most -ConsumptionMaxPages usage pages for one
# subscription (10,000 when not given) and, at the limit, advises a run with a
# higher value. Run-AllSubscriptions.ps1 and its stream workers take the same
# parameter (last, so every earlier position stays) and pass it on to every
# ResourceInventory.ps1 run when it is given, so a wrapper run has that way out.
# The statements that build $InventoryPassthrough are run from the scripts'
# AST, so nothing is collected.
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Parsed = @{}
    foreach ($File in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1'))
    {
        $script:Parsed[$File] = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $File), [ref]$null, [ref]$null)
    }
    # Runs the top-level statements of $File from '$InventoryPassthrough = @{}'
    # to the one that sets ConcurrencyLimit and the next one, and returns the
    # $InventoryPassthrough they build.
    function Invoke-PassthroughStatements
    {
        param([string]$File, [hashtable]$Variables)
        $Top = @($script:Parsed[$File].EndBlock.Statements)
        $First = @(0..($Top.Count - 1) | Where-Object { $Top[$_].Extent.Text -match '^\$InventoryPassthrough = @\{\}' })[0]
        $Last = @(0..($Top.Count - 1) | Where-Object { $_ -gt $First -and $Top[$_].Extent.Text -match "^\`$InventoryPassthrough\['ConcurrencyLimit'\]" })[0]
        if ($null -eq $First -or $null -eq $Last) { throw ('Statements not found in {0}.' -f $File) }
        $Last = [Math]::Min($Last + 1, $Top.Count - 1)
        $Text = (@($Top[$First..$Last] | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n`$InventoryPassthrough"
        $Block = [scriptblock]::Create('param($Vars) foreach ($K in $Vars.Keys) { Set-Variable -Name $K -Value $Vars[$K] }' + "`n" + $Text)
        return (& $Block $Variables)
    }
}

Describe 'Run-AllSubscriptions.ps1 passes -ConsumptionMaxPages on' {
    It 'takes it as the last parameter of the wrapper and of the stream worker, as an [int]' {
        foreach ($File in $script:Parsed.Keys)
        {
            $Params = @($script:Parsed[$File].ParamBlock.Parameters)
            $Params[-1].Name.VariablePath.UserPath | Should -BeExactly 'ConsumptionMaxPages'
            $Params[-1].StaticType | Should -Be ([int])
            # A negative number fails at the start instead of reading as the default.
            @($Params[-1].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateRange' }).Count | Should -Be 1
        }
        $Inner = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $InnerParam = @($Inner.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ConsumptionMaxPages' })[0]
        @($InnerParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateRange' }).Count | Should -Be 1
    }

    It 'adds it to $InventoryPassthrough when given, and leaves it out when not (<File>)' -ForEach @(@{ File = 'Run-AllSubscriptions.ps1' }, @{ File = 'Run-AllSubscriptions.Stream.ps1' }) {
        $Given = Invoke-PassthroughStatements -File $File -Variables @{ ConcurrencyLimit = 6; ConsumptionMaxPages = 20000 }
        $Given['ConsumptionMaxPages'] | Should -Be 20000
        $NotGiven = Invoke-PassthroughStatements -File $File -Variables @{ ConcurrencyLimit = 6; ConsumptionMaxPages = 0 }
        $NotGiven.ContainsKey('ConsumptionMaxPages') | Should -BeFalse
    }

    It 'gives it to every parallel worker' {
        $script:Parsed['Run-AllSubscriptions.ps1'].Extent.Text | Should -Match ([regex]::Escape('if ($ConsumptionMaxPages -gt 0) { $WorkerArgs.ConsumptionMaxPages = $ConsumptionMaxPages }'))
    }
}
