#
# Run-AllSubscriptions.ps1 starts every run from zero run-wide totals.
#
# A PowerShell window (Azure Cloud Shell included) keeps its globals between
# runs, and the run-wide consumption totals are only ever added to: by
# ResourceInventory.ps1 on the sequential path, and by the per-stream summary
# aggregation on the parallel path. A second run in the same window, for example
# after signing in again as the "FAILED (auth)" banner advises, must not report
# the first run's consumption failures, exit 3 because of them, or add the first
# run's record count to its own.
#
# The wrapper needs Azure to run end to end, so its own statements are lifted
# from its AST and run as written: the top-level resets, the per-stream summary
# aggregation, and the end-of-run consumption summary and exit code.
#
# Run with: Invoke-Pester ./Tests/RunTotalsReset.Tests.ps1 -Output Detailed

BeforeDiscovery {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    $StreamErrors = $null
    $StreamAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'Run-AllSubscriptions.Stream.ps1'), [ref]$null, [ref]$StreamErrors)
    # The run-wide totals the stream worker resets for its own process. The wrapper
    # must reset the same set for its own process.
    $script:WorkerResets = @($StreamAst.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Operator -eq 'Equals' -and
            $_.Left.Extent.Text -match '^\$Global:\w+$'
        } | ForEach-Object { @{ Name = $_.Left.Extent.Text.Substring('$Global:'.Length) } })
}

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestRoot = Join-Path $TmpBase ('RunTotalsReset_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

    # These tests write the run-wide globals; keep this session's values and put them back in AfterAll.
    $script:TotalNames = @('ConsumptionRecordCount', 'ConsumptionFailedSubs', 'MetricsFailedSubs', 'CollectorFailures')
    $script:SessionValues = @{}
    foreach ($Name in $script:TotalNames)
    {
        $Existing = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
        $script:SessionValues[$Name] = if ($Existing) { @{ Value = $Existing.Value } } else { $null }
    }

    $ParseErrors = $null
    $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$ParseErrors)
    if ($ParseErrors) { throw ('Run-AllSubscriptions.ps1 does not parse: ' + (($ParseErrors | ForEach-Object { $_.Message }) -join '; ')) }
    # Top-level statements only: a reset nested in a function or a branch does not run on every start.
    $script:Top = @($WrapperAst.EndBlock.Statements)

    # The statement that dispatches the subscription loop; the sequential and parallel paths both live under it.
    $script:Dispatch = $script:Top | Where-Object {
        $_ -is [System.Management.Automation.Language.IfStatementAst] -and
        $_.Clauses[0].Item1.Extent.Text -eq '$ParallelStreams -le 1'
    } | Select-Object -First 1
    if (-not $script:Dispatch) { throw 'The subscription dispatch (if ($ParallelStreams -le 1)) was not found at the top level of Run-AllSubscriptions.ps1.' }

    # Every top-level $Global:<name> = ... ahead of the dispatch, in source order.
    $script:Resets = @($script:Top | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Operator -eq 'Equals' -and
            $_.Left.Extent.Text -match '^\$Global:\w+$' -and
            $_.Extent.EndOffset -le $script:Dispatch.Extent.StartOffset
        })
    $script:ResetText = (@($script:Resets | ForEach-Object { $_.Extent.Text }) -join "`n")

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

    # End-of-run consumption summary, then the auth banner and the exit code.
    $script:SummaryText = Get-TopText '^\$ConsumptionRecords = ' '^if \(\$ConsumptionFailures\.Count -gt 0\)'
    $script:FinalText = Get-TopText '^\$AuthSkippedPhases = @\(\)' '^\$WrapperExitCode = Get-WrapperExitCode'

    # The parallel path's per-stream summary aggregation.
    $Aggregation = @($WrapperAst.FindAll({
                $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] -and
                $args[0].Condition.Extent.Text -eq '$StreamSummaries' -and
                $args[0].Body.Extent.Text -match 'ConsumptionRecords'
            }, $true))
    if ($Aggregation.Count -ne 1) { throw ('Expected one per-stream summary aggregation loop in Run-AllSubscriptions.ps1, found {0}.' -f $Aggregation.Count) }
    $script:AggregationText = $Aggregation[0].Extent.Text

    # What an earlier run in the same window leaves behind when its consumption step
    # was skipped for sign-in: two records collected, and the '(auth)' entry.
    function script:Set-EarlierRunTotals
    {
        $Global:ConsumptionRecordCount = 2
        $Global:ConsumptionFailedSubs = @([pscustomobject]@{ Name = '(all subscriptions)'; Id = '(auth)'; Message = 'Consumption phase skipped: no usable Azure context/token after one reconnect attempt.' })
        $Global:MetricsFailedSubs = @()
        $Global:CollectorFailures = @()
    }

    function script:ConvertTo-Lines
    {
        param($Records)
        @($Records | ForEach-Object { if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } })
    }
}

AfterAll {
    foreach ($Name in $script:TotalNames)
    {
        if ($null -ne $script:SessionValues[$Name]) { Set-Variable -Name $Name -Scope Global -Value $script:SessionValues[$Name].Value }
        else { Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue }
    }
    if ($script:TestRoot -and (Test-Path -LiteralPath $script:TestRoot)) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force }
}

Describe 'Run-AllSubscriptions.ps1 starts each run with zero run-wide totals' {

    It 'finds the run-wide totals the stream worker resets' {
        @($script:WorkerResets).Count | Should -BeGreaterThan 0 -Because 'an empty list would silently skip the per-total cases below'
    }

    It 'resets $Global:<Name> before the first subscription, as the stream worker does' -ForEach $script:WorkerResets {
        @($script:Resets | Where-Object { $_.Left.Extent.Text -eq ('$Global:' + $Name) }).Count | Should -BeGreaterThan 0 -Because "without it a second run in the same window inherits the previous run's $Name"
    }

    Context 'a second run in the same window, after the first could not collect consumption' {

        BeforeEach {
            Set-EarlierRunTotals
            # The end-of-run statements may also read these: the wrapper transcript is off, and
            # (where the wrapper carries earlier -Resume reports) none failed to carry.
            # Set-Variable: only the lifted text reads them.
            Set-Variable -Name WrapperTranscriptStarted -Value $false
            Set-Variable -Name UncarriedSkipped -Value @()
        }

        It 'sequential run: reports only its own consumption records and exits 0' {
            . ([scriptblock]::Create($script:ResetText))
            # ResourceInventory.ps1 adds this run's records to the run-wide total.
            if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
            if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
            $Global:ConsumptionRecordCount += 2

            $Lines = ConvertTo-Lines (. ([scriptblock]::Create($script:SummaryText + "`n" + $script:FinalText)) 6>&1)

            ($Lines -join "`n") | Should -Match 'Consumption Records:\s+2 record\(s\) collected'
            ($Lines -join "`n") | Should -Not -Match 'Consumption Failures'
            ($Lines -join "`n") | Should -Not -Match 'FAILED \(auth\)'
            $WrapperExitCode | Should -Be 0
        }

        It 'parallel run: the totals added from the stream summaries are only this run''s' {
            $SummaryPath = Join-Path $script:TestRoot '.rda-stream-0-summary.json'
            [pscustomobject]@{
                StreamId              = 0
                Status                = 'ok'
                ResourceCounts        = @([pscustomobject]@{ Name = 'Sub A'; Id = '12345678-1234-1234-1234-123456789012'; Count = 1 })
                Failed                = @()
                ConsumptionRecords    = 2
                ConsumptionFailedSubs = @()
                MetricsFailedSubs     = @()
                CollectorFailures     = @()
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SummaryPath -Encoding utf8
            Set-Variable -Name InventoryRoot -Value $script:TestRoot
            Set-Variable -Name StreamSummaries -Value @([pscustomobject]@{ StreamId = 0; SummaryPath = $SummaryPath; FailuresPath = (Join-Path $script:TestRoot 'failures-stream-0.log') })
            Set-Variable -Name FailedSubscriptions -Value @()
            Set-Variable -Name SubResourceCounts -Value @()
            Set-Variable -Name DiagFile -Value $null

            . ([scriptblock]::Create($script:ResetText))
            $null = . ([scriptblock]::Create($script:AggregationText)) 6>&1
            $Lines = ConvertTo-Lines (. ([scriptblock]::Create($script:SummaryText + "`n" + $script:FinalText)) 6>&1)

            ($Lines -join "`n") | Should -Match 'Consumption Records:\s+2 record\(s\) collected'
            ($Lines -join "`n") | Should -Not -Match 'Consumption Failures'
            ($Lines -join "`n") | Should -Not -Match 'FAILED \(auth\)'
            $WrapperExitCode | Should -Be 0
        }

        It 'still reports a consumption step skipped for sign-in in this run' {
            . ([scriptblock]::Create($script:ResetText))
            if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
            $Global:ConsumptionFailedSubs += [pscustomobject]@{ Name = '(all subscriptions)'; Id = '(auth)'; Message = 'Consumption phase skipped: no usable Azure context/token after one reconnect attempt.' }

            $Lines = ConvertTo-Lines (. ([scriptblock]::Create($script:SummaryText + "`n" + $script:FinalText)) 6>&1)

            ($Lines -join "`n") | Should -Match 'Consumption Failures:\s+1 subscription\(s\)'
            ($Lines -join "`n") | Should -Match 'Could not collect: Consumption'
            $WrapperExitCode | Should -Be 3
        }
    }
}
