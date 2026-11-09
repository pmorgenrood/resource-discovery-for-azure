#
# Run-AllSubscriptions.ps1 lists every subscription in its end-of-run
# 'Consumption Failures' and 'Metrics Auth Failures' blocks, also when two of
# them share a display name (two 'Pay-As-You-Go' subscriptions, for example).
# Each block prints a count, then one line per subscription; a list that folds
# two subscriptions into one line by name reads one subscription short of the
# count above it and hides which one is missing data.
#
# The wrapper needs Azure to run end to end, so the two blocks are lifted from
# its AST and run as written, as Tests/RunTotalsReset.Tests.ps1 does.
#
# Run with: Invoke-Pester ./Tests/FailureListSameName.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $ParseErrors = $null
    $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$ParseErrors)
    if ($ParseErrors) { throw ('Run-AllSubscriptions.ps1 does not parse: ' + (($ParseErrors | ForEach-Object { $_.Message }) -join '; ')) }
    $script:Top = @($WrapperAst.EndBlock.Statements)
    # The helpers the lifted blocks call (Test-MetricsIncompleteEntry), loaded as
    # the wrapper loads them.
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    function script:Get-TopText
    {
        param([string]$From, [string]$To)
        $F = -1; $T = -1
        for ($i = 0; $i -lt $script:Top.Count; $i++)
        {
            if ($F -lt 0 -and $script:Top[$i].Extent.Text -match $From) { $F = $i }
            if ($F -ge 0 -and $script:Top[$i].Extent.Text -match $To) { $T = $i; break }
        }
        if ($F -lt 0 -or $T -lt 0) { throw "Top-level statements not found in Run-AllSubscriptions.ps1: $From .. $To" }
        return (@($script:Top[$F..$T] | ForEach-Object { $_.Extent.Text }) -join "`n")
    }

    $script:ConsumptionText = Get-TopText '^\$ConsumptionRecords = ' '^if \(\$ConsumptionFailures\.Count -gt 0\)'
    $script:MetricsText = Get-TopText '^\$MetricsFailures = ' '^if \(\$MetricsFailures\.Count -gt 0\)'

    # The run-wide globals the blocks read; this session's values go back in AfterAll.
    $script:TotalNames = @('ConsumptionRecordCount', 'ConsumptionFailedSubs', 'MetricsFailedSubs')
    $script:SessionValues = @{}
    foreach ($Name in $script:TotalNames)
    {
        $Existing = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
        $script:SessionValues[$Name] = if ($Existing) { @{ Value = $Existing.Value } } else { $null }
    }

    function script:Invoke-Block
    {
        param([string]$Text)
        @(. ([scriptblock]::Create($Text)) 6>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } })
    }

    $script:SubA = '12345678-1234-1234-1234-123456789012'
    $script:SubB = '22222222-2222-2222-2222-222222222222'
}

AfterAll {
    foreach ($Name in $script:TotalNames)
    {
        if ($null -ne $script:SessionValues[$Name]) { Set-Variable -Name $Name -Scope Global -Value $script:SessionValues[$Name].Value }
        else { Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue }
    }
}

Describe 'Run-AllSubscriptions.ps1 end-of-run failure lists with two subscriptions of the same name' {

    It 'Consumption Failures lists both on a line each, as its count does' {
        # Set-Variable: only the lifted text reads it.
        Set-Variable -Name ConsumptionCheck -Value $null
        $Global:ConsumptionRecordCount = 0
        $Global:ConsumptionFailedSubs = @(
            [pscustomobject]@{ Name = 'Pay-As-You-Go'; Id = $script:SubA; Message = 'stand-in: billing call failed' },
            [pscustomobject]@{ Name = 'Pay-As-You-Go'; Id = $script:SubB; Message = 'stand-in: billing call failed' })
        $Lines = Invoke-Block $script:ConsumptionText
        ($Lines -join "`n") | Should -Match 'Consumption Failures:\s+2 subscription\(s\)'
        @($Lines | Where-Object { $_ -like '  - Pay-As-You-Go (*' }) | Should -Be @("  - Pay-As-You-Go ($script:SubA)", "  - Pay-As-You-Go ($script:SubB)")
    }

    It 'Metrics Auth Failures lists both on a line each, as its count does' {
        $Global:MetricsFailedSubs = @(
            [pscustomobject]@{ Name = 'Pay-As-You-Go'; Id = $script:SubB; Message = 'Metrics phase skipped: no usable Azure context/token after one reconnect attempt.' },
            [pscustomobject]@{ Name = 'Pay-As-You-Go'; Id = $script:SubA; Message = 'Metrics phase skipped: no usable Azure context/token after one reconnect attempt.' })
        $Lines = Invoke-Block $script:MetricsText
        ($Lines -join "`n") | Should -Match 'Metrics Auth Failures:\s+2 subscription\(s\)'
        @($Lines | Where-Object { $_ -like '  - Pay-As-You-Go (*' }) | Should -Be @("  - Pay-As-You-Go ($script:SubA)", "  - Pay-As-You-Go ($script:SubB)")
    }

    It 'still lists a subscription recorded twice once' {
        $Global:MetricsFailedSubs = @(
            [pscustomobject]@{ Name = 'Pay-As-You-Go'; Id = $script:SubA; Message = 'Metrics phase skipped: no usable Azure context/token after one reconnect attempt.' },
            [pscustomobject]@{ Name = 'Pay-As-You-Go'; Id = $script:SubA; Message = 'Metrics phase skipped: no usable Azure context/token after one reconnect attempt.' })
        $Lines = Invoke-Block $script:MetricsText
        @($Lines | Where-Object { $_ -like '  - Pay-As-You-Go (*' }) | Should -Be @("  - Pay-As-You-Go ($script:SubA)")
    }
}
