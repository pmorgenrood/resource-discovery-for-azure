<#
    Memory and timing readings per subscription.

    WHAT THIS GUARDS. Five readings per subscription (start, discovery, collectors,
    released, end) record the managed heap, the process working set and its peak so
    far, the memory available to the runtime and the seconds since the subscription
    started. The phase durations (discovery, metrics, collectors, billing, report and
    packaging, total) travel on the 'end' reading. Everything lands in
    $Global:MemoryReadings and is rendered into the shareable Diagnostics log,
    RunSummary.log and the local debug log. A reading only observes: it forces no
    collection and changes nothing the run collects or writes.

    Fully offline. The placement guards read the parsed source; the reading and
    rendering tests call the real functions with synthetic values.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:InvPath = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    $script:WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
    $script:StreamPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1'
    $script:CommonPath = Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1'
    . $script:CommonPath
    . (Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')

    $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw
    $script:WrapperSrc = Get-Content -LiteralPath $script:WrapperPath -Raw
    $script:StreamSrc = Get-Content -LiteralPath $script:StreamPath -Raw

    # Offsets of the load-bearing statements, so the ordering assertions read as 'A comes before
    # B' rather than as line numbers that drift. A bare call is matched with a whitespace-tolerant
    # -Pattern, so a re-indent or a CRLF checkout does not break the anchor.
    function Get-SourceOffset
    {
        param([string]$Source, [string]$Needle, [string]$Pattern)
        if ($Pattern)
        {
            $Match = [regex]::Match($Source, $Pattern)
            if (-not $Match.Success) { throw ("not found in source: {0}" -f $Pattern) }
            return $Match.Index
        }
        $Index = $Source.IndexOf($Needle, [System.StringComparison]::Ordinal)
        if ($Index -lt 0) { throw ("not found in source: {0}" -f $Needle) }
        return $Index
    }

    function New-TestReading
    {
        param([string]$Id, [string]$Stamp, [string]$Phase, [int]$Resources, $Heap, $WorkingSet, $Peak, $Seconds, $Limit = 2560)
        [pscustomobject]@{ Id = $Id; Stamp = $Stamp; Phase = $Phase; Resources = $Resources; HeapMB = $Heap; WorkingSetMB = $WorkingSet; PeakWorkingSetMB = $Peak; LimitMB = $Limit; Seconds = $Seconds }
    }

    function New-TestSubscriptionReadings
    {
        param([string]$Id, [string]$Stamp, [int]$Resources, [double[]]$Heaps, [double[]]$WorkingSets, [object[]]$Peaks, [double[]]$Seconds)
        $Phases = @('start', 'discovery', 'collectors', 'released', 'end')
        $Rows = @()
        for ($i = 0; $i -lt $Phases.Count; $i++)
        {
            $Rows += New-TestReading -Id $Id -Stamp $Stamp -Phase $Phases[$i] -Resources $(if ($i -eq 0) { 0 } else { $Resources }) -Heap $Heaps[$i] -WorkingSet $WorkingSets[$i] -Peak $Peaks[$i] -Seconds $Seconds[$i]
        }
        return $Rows
    }

    function Add-TestTimings
    {
        param($Rows, $Metrics, $Collectors, $Billing, $Report, $Total)
        $End = @($Rows | Where-Object { $_.Phase -eq 'end' })[0]
        $End | Add-Member -NotePropertyName MetricsSeconds -NotePropertyValue $Metrics -Force
        $End | Add-Member -NotePropertyName CollectorsSeconds -NotePropertyValue $Collectors -Force
        $End | Add-Member -NotePropertyName BillingSeconds -NotePropertyValue $Billing -Force
        $End | Add-Member -NotePropertyName ReportSeconds -NotePropertyValue $Report -Force
        $End | Add-Member -NotePropertyName TotalSeconds -NotePropertyValue $Total -Force
        return $Rows
    }

    $script:SubId = '12345678-1234-1234-1234-123456789012'
}

AfterAll {
    Remove-Item function:global:Write-Log -ErrorAction SilentlyContinue
}

Describe 'ResourceInventory.ps1 takes the five readings at the same phase boundaries, observing only' {
    It 'parses' {
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$Errors)
        $Errors | Should -BeNullOrEmpty
    }

    It 'starts the subscription clock before anything else runs' {
        $Clock = Get-SourceOffset $script:InvSrc '$SubscriptionClock = [System.Diagnostics.Stopwatch]::StartNew()'
        $Clock | Should -BeLessThan (Get-SourceOffset $script:InvSrc '$FunctionsFile = Join-Path $PSScriptRoot')
    }

    It 'takes each of the five recorded readings exactly once, at its phase boundary' {
        # Functions are defined before the main body, so file order is not execution order; each
        # reading is pinned against the statement that marks its own phase instead.
        $At = @{}
        foreach ($Phase in @('start', 'discovery', 'collectors', 'released', 'end'))
        {
            $Needle = "Write-RdaMemorySnapshot -Phase '{0}' -Clock `$SubscriptionClock -Record" -f $Phase
            ([regex]::Matches($script:InvSrc, [regex]::Escape($Needle))).Count | Should -Be 1 -Because "the '$Phase' reading is taken exactly once"
            $At[$Phase] = Get-SourceOffset $script:InvSrc $Needle
        }
        $At['start'] | Should -BeGreaterThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^[ \t]*GetSubscriptionsData[ \t]*\r?$') -Because 'start is taken after sign-in and the subscription list'
        $At['start'] | Should -BeLessThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^[ \t]*ResourceInventoryLoop[ \t]*\r?$') -Because 'start is taken before the first Resource Graph page'
        $At['discovery'] | Should -BeGreaterThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^[ \t]*ResourceInventoryAvd[ \t]*\r?$') -Because 'discovery follows the last Resource Graph loop'
        $At['discovery'] | Should -BeLessThan (Get-SourceOffset $script:InvSrc 'function ExecuteInventoryProcessing()')
        $At['collectors'] | Should -BeGreaterThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^[ \t]*ProcessResourceResult[ \t]*\r?$')
        $At['released'] | Should -BeGreaterThan $At['collectors']
        $At['released'] | Should -BeLessThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^[ \t]*GetResorceConsumption[ \t]*\r?$') -Because 'released is taken before the billing pull, as in a build that frees memory there'
        $At['end'] | Should -BeGreaterThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^FinalizeOutputs[ \t]*\r?$') -Because 'the end reading is taken after the HTML report'
        $At['end'] | Should -BeLessThan (Get-SourceOffset $script:InvSrc 'Write-RdaShareableDiagnosticsLog -DefaultPath') -Because 'the end reading must exist before the diagnostics log renders it'
    }

    It 'hands the readings to both diagnostics-log calls' {
        ([regex]::Matches($script:InvSrc, [regex]::Escape('Write-RdaShareableDiagnosticsLog -DefaultPath'))).Count | Should -Be 2
        ([regex]::Matches($script:InvSrc, '-MemoryReadings \$Global:MemoryReadings\b')).Count | Should -Be 2
    }

    It 'times report and packaging from the HTML report, adds the timings before the log and again after the zip' {
        $ReportTimer = Get-SourceOffset $script:InvSrc '$ReportPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()'
        $ReportTimer | Should -BeLessThan (Get-SourceOffset $script:InvSrc -Pattern '(?m)^FinalizeOutputs[ \t]*\r?$')
        $Needle = 'Add-RdaSubscriptionTimings -Clock $SubscriptionClock -ReportClock $ReportPhaseTimer -PhaseTimings $script:PhaseTimings'
        $Calls = [regex]::Matches($script:InvSrc, [regex]::Escape($Needle))
        $Calls.Count | Should -Be 2
        $Zip = Get-SourceOffset $script:InvSrc 'Compress-Archive @CompressionOutput'
        $Calls[0].Index | Should -BeLessThan (Get-SourceOffset $script:InvSrc 'Write-RdaShareableDiagnosticsLog -DefaultPath')
        $Calls[1].Index | Should -BeGreaterThan $Zip
        (Get-SourceOffset $script:InvSrc 'Write-RdaPerformanceDebugLog -Obfuscated:$Obfuscate.IsPresent') | Should -BeGreaterThan $Calls[1].Index
    }

    It 'leaves the existing phase-timing table as it was' {
        ([regex]::Matches($script:InvSrc, [regex]::Escape('$script:PhaseTimings['))).Count | Should -Be 3 -Because 'metrics, collectors and billing are the only entries; a new one would change the HTML report'
    }

    It 'forces no collection: the shared functions hold none and no reading asks for one' {
        # The metrics and collector phases keep the collections they already make; the readings
        # add none and compact nothing.
        $Common = Get-Content -LiteralPath $script:CommonPath -Raw
        $Common | Should -Not -Match 'GC\]::Collect'
        $Common | Should -Not -Match 'LargeObjectHeapCompactionMode'
        $Common | Should -Not -Match 'GetTotalMemory\(\$true\)'
        $script:InvSrc | Should -Not -Match 'LargeObjectHeapCompactionMode'
        $script:InvSrc | Should -Not -Match 'Write-RdaMemorySnapshot[^\r\n]*-Compact'
    }
}

Describe 'The wrappers carry the readings' {
    It '<Label> starts every run with an empty readings list' -ForEach @(
        @{ Label = 'Run-AllSubscriptions.ps1'; Src = { $script:WrapperSrc } }
        @{ Label = 'Run-AllSubscriptions.Stream.ps1'; Src = { $script:StreamSrc } }
    ) {
        (& $Src) | Should -Match '(?m)^\$Global:MemoryReadings = @\(\)\s*$'
    }

    It 'the stream worker reports its readings and the parent folds them in' {
        $script:StreamSrc | Should -Match '(?m)^\s+MemoryReadings\s+= @\(\$MemoryReadings\)\s*$'
        $script:WrapperSrc | Should -Match ([regex]::Escape('$Global:MemoryReadings += @($StreamSummary.MemoryReadings)'))
    }

    It 'the parent passes the readings and its own peak to the run summary builder' {
        $script:WrapperSrc | Should -Match '-MemoryReadings \$Global:MemoryReadings -PeakWorkingSetMB \(Get-RdaPeakWorkingSetMB\)'
    }

    It 'a reading survives the stream summary JSON and renders the same rows' {
        $Rows = New-TestSubscriptionReadings -Id $script:SubId -Stamp 's1' -Resources 7 -Heaps @(10, 11, 12, 12, 13) -WorkingSets @(100, 110, 120, 120, 130) -Peaks @(101, 111, 121, 121, 131) -Seconds @(1.1, 2.2, 3.3, 3.3, 4.4)
        $Rows = Add-TestTimings -Rows $Rows -Metrics 1.5 -Collectors 0.7 -Billing $null -Report 0.4 -Total 4.9
        $Summary = [pscustomobject]@{ StreamId = 1; Status = 'ok'; MemoryReadings = @($Rows) }
        $Back = ($Summary | ConvertTo-Json -Depth 6) | ConvertFrom-Json
        $Folded = @()
        $Folded += @($Back.MemoryReadings)
        (@(Get-RdaMemoryReadingLines -Readings $Folded) -join "`n") | Should -Be (@(Get-RdaMemoryReadingLines -Readings $Rows) -join "`n")
        (@(Get-RdaTimingLines -Readings $Folded) -join "`n") | Should -Be (@(Get-RdaTimingLines -Readings $Rows) -join "`n")
    }
}

Describe 'Write-RdaMemorySnapshot -Record' {
    BeforeAll {
        $script:PriorReadings = $Global:MemoryReadings
        $script:PriorResources = $Global:Resources
        $script:PriorStamp = $Global:CurrentDateTime
        $script:PriorDebugLog = $Global:DebugLogFile
        $Global:DebugLogFile = $null
    }
    AfterAll {
        $Global:MemoryReadings = $script:PriorReadings
        $Global:Resources = $script:PriorResources
        $Global:CurrentDateTime = $script:PriorStamp
        $Global:DebugLogFile = $script:PriorDebugLog
    }
    BeforeEach {
        $Global:MemoryReadings = $null
        $Global:Resources = @(1..42)
        $Global:CurrentDateTime = 'stamp-1'
        Set-Variable -Name SubscriptionID -Value $script:SubId -Scope Script
    }

    It 'appends one record carrying the subscription, stamp, phase, count, the four figures and the seconds' {
        $Clock = [System.Diagnostics.Stopwatch]::new()
        Write-RdaMemorySnapshot -Phase 'collectors' -Clock $Clock -Record
        @($Global:MemoryReadings).Count | Should -Be 1
        $R = @($Global:MemoryReadings)[0]
        $R.Id | Should -Be $script:SubId
        $R.Stamp | Should -Be 'stamp-1'
        $R.Phase | Should -Be 'collectors'
        $R.Resources | Should -Be 42
        $R.HeapMB | Should -BeGreaterThan 0
        $R.WorkingSetMB | Should -BeGreaterThan 0
        $R.LimitMB | Should -BeGreaterThan 0
        $R.Seconds | Should -Be 0 -Because 'a clock that never started reads zero'
        ($R.PSObject.Properties.Name -join ',') | Should -Be 'Id,Stamp,Phase,Resources,HeapMB,WorkingSetMB,PeakWorkingSetMB,LimitMB,Seconds'
    }

    It 'writes the peak as a positive number or as nothing, never as 0' {
        Write-RdaMemorySnapshot -Phase 'start' -Record
        $Peak = @($Global:MemoryReadings)[0].PeakWorkingSetMB
        if ($null -ne $Peak) { $Peak | Should -BeGreaterThan 0 }
        $Direct = Get-RdaPeakWorkingSetMB
        if ($null -ne $Direct) { $Direct | Should -BeGreaterThan 0 }
    }

    It 'leaves the seconds empty without a clock' {
        Write-RdaMemorySnapshot -Phase 'start' -Record
        @($Global:MemoryReadings)[0].Seconds | Should -BeNullOrEmpty
    }

    It 'counts a run that has discovered nothing yet as 0' {
        $Global:Resources = $null
        Write-RdaMemorySnapshot -Phase 'start' -Record
        @($Global:MemoryReadings)[0].Resources | Should -Be 0
    }

    It 'refuses to record a phase the summary does not render' {
        { Write-RdaMemorySnapshot -Phase 'strat' -Record } | Should -Throw -ExpectedMessage '*one of the phases the summary renders*'
        $Global:MemoryReadings | Should -BeNullOrEmpty
    }

    It 'still takes an ad-hoc reading without -Record under any phase name' {
        { Write-RdaMemorySnapshot -Phase 'Before the consumption pull' } | Should -Not -Throw
    }

    It 'records nothing without -Record' {
        Write-RdaMemorySnapshot -Phase 'start'
        $Global:MemoryReadings | Should -BeNullOrEmpty
    }

    It 'accumulates across calls, as the wrapper relies on for one row per subscription' {
        Write-RdaMemorySnapshot -Phase 'start' -Record
        Write-RdaMemorySnapshot -Phase 'discovery' -Record
        @($Global:MemoryReadings).Count | Should -Be 2
        (@($Global:MemoryReadings) | ForEach-Object { $_.Phase }) -join ',' | Should -Be 'start,discovery'
    }

    It 'forces no collection: its body calls no collect, compaction or heap-settling read' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CommonPath, [ref]$null, [ref]$null)
        foreach ($Name in @('Write-RdaMemorySnapshot', 'Get-RdaPeakWorkingSetMB'))
        {
            $Fn = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $true)
            $Fn | Should -Not -BeNullOrEmpty
            $Code = (($Fn.Extent.Text -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
            $Code | Should -Not -Match 'Collect\('
            $Code | Should -Not -Match 'GCSettings'
            $Code | Should -Not -Match 'GetTotalMemory\(\$true\)'
        }
    }
}

Describe 'Write-RdaMemorySnapshot: the local debug log' {
    BeforeAll {
        $script:PriorDebugLogFile = $Global:DebugLogFile
        $script:PriorErrorLogFile = $Global:ErrorLogFile
        $script:PriorStampDebug = $Global:CurrentDateTime
        $script:LogDir = Join-Path ([System.IO.Path]::GetTempPath()) ('PerformanceLogging_{0}' -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        $Global:ErrorLogFile = $null
        $Global:CurrentDateTime = '20260101000000000abcd'
    }
    AfterAll {
        $Global:DebugLogFile = $script:PriorDebugLogFile
        $Global:ErrorLogFile = $script:PriorErrorLogFile
        $Global:CurrentDateTime = $script:PriorStampDebug
        Remove-Item -LiteralPath $script:LogDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes one debug-log line and nothing to the console when the log belongs to this run' {
        $Global:DebugLogFile = Join-Path $script:LogDir ('DebugLog_R_{0}.log' -f $Global:CurrentDateTime)
        $PriorCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            # A comma-decimal culture: the figures must still be written with a dot.
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::new('de-DE')
            $Emitted = @(Write-RdaMemorySnapshot -Phase 'Unit test phase' -Clock ([System.Diagnostics.Stopwatch]::new()) 6>&1)
        }
        finally
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $PriorCulture
        }
        $Emitted.Count | Should -Be 0 -Because 'a memory reading goes to the local debug log, never to the console or the pipeline'
        $Lines = @(Get-Content -LiteralPath $Global:DebugLogFile)
        $Lines.Count | Should -Be 1
        $Lines[0] | Should -Match '\[Memory\] Unit test phase: managed heap \d+(\.\d)? MB, process working set \d+(\.\d)? MB, peak working set (\d+(\.\d)? MB|n/a), memory available to the runtime \d+ MB, 0\.0 s since the subscription started \(no collection forced\)\.$'
    }

    It 'writes nothing while the debug log still names an earlier run' {
        # Under the wrapper the path still names the previous subscription's log until this run
        # sets its own; the reading must not land there.
        $Global:DebugLogFile = Join-Path $script:LogDir 'DebugLog_R_20251231000000000abcd_previous.log'
        Write-RdaMemorySnapshot -Phase 'start'
        Test-Path -LiteralPath $Global:DebugLogFile | Should -BeFalse
    }
}

Describe 'Get-RdaMemoryReadingLines' {
    BeforeAll {
        $script:Big = New-TestSubscriptionReadings -Id $script:SubId -Stamp 's1' -Resources 20000 -Heaps @(310, 525, 640, 320, 335) -WorkingSets @(520, 780, 905, 610, 615) -Peaks @(530, 800, 920, 920, 920) -Seconds @(4.2, 15.0, 80.5, 80.5, 95.3)
        $script:Small = New-TestSubscriptionReadings -Id 'second-subscription' -Stamp 's2' -Resources 412 -Heaps @(312.4, 320.6, 325.6, 314.2, 316.1) -WorkingSets @(612.7, 620.3, 625.4, 612.4, 614.6) -Peaks @(613, 621, 626, 626, 626) -Seconds @(3.0, 4.26, 9.0, 9.0, 12.06)
        $script:Both = @($script:Big) + @($script:Small)
    }

    It 'renders the memory, peak and seconds tables with one row per subscription' {
        $Lines = @(Get-RdaMemoryReadingLines -Readings $script:Both)
        $Lines.Count | Should -Be 12
        $Lines[0] | Should -Be 'Memory (MB, read without forcing a collection; managed heap / process working set):'
        $Lines[1] | Should -Be '  [sub 12345678-1234-1234-1234-123456789012]  resources 20,000  start 310/520  discovery 525/780  collectors 640/905  released 320/610  end 335/615'
        $Lines[2] | Should -Be '  [sub second-subscription]  resources 412  start 312/613  discovery 321/620  collectors 326/625  released 314/612  end 316/615'
        $Lines[3] | Should -Be '  Highest working set sampled : 905 MB'
        $Lines[4] | Should -Be '  Memory available to runtime : 2560 MB'
        $Lines[5] | Should -Be 'Peak working set so far (MB, n/a where the OS does not report it):'
        $Lines[6] | Should -Be '  [sub 12345678-1234-1234-1234-123456789012]  start 530  discovery 800  collectors 920  released 920  end 920'
        $Lines[7] | Should -Be '  [sub second-subscription]  start 613  discovery 621  collectors 626  released 626  end 626'
        $Lines[8] | Should -Be '  Highest peak working set    : 920 MB'
        $Lines[9] | Should -Be 'Seconds since the subscription started, at each reading:'
        $Lines[10] | Should -Be '  [sub 12345678-1234-1234-1234-123456789012]  start 4.2  discovery 15.0  collectors 80.5  released 80.5  end 95.3'
        $Lines[11] | Should -Be '  [sub second-subscription]  start 3.0  discovery 4.3  collectors 9.0  released 9.0  end 12.1'
    }

    It 'names subscriptions by position only when obfuscated' {
        $Lines = @(Get-RdaMemoryReadingLines -Readings $script:Both -Obfuscated)
        $Lines[1] | Should -Match '^\s+\[sub 1\]\s'
        $Lines[2] | Should -Match '^\s+\[sub 2\]\s'
        ($Lines -join "`n") | Should -Not -Match '12345678-1234'
        ($Lines -join "`n") | Should -Not -Match 'second-subscription'
    }

    It 'keeps a standalone run to its own stamp' {
        $Lines = @(Get-RdaMemoryReadingLines -Readings $script:Both -Stamp 's2')
        $Lines.Count | Should -Be 9 -Because 'three headers, one row each, and the three summary lines'
        ($Lines -join "`n") | Should -Not -Match '123456789012\]' -Because 'the other stamp''s subscription is filtered out'
        $Lines[1] | Should -Match 'resources 412'
    }

    It 'marks a phase that was never reached, as a subscription that failed mid-run leaves' {
        $Partial = @($script:Big | Where-Object { $_.Phase -in @('start', 'discovery') })
        $Lines = @(Get-RdaMemoryReadingLines -Readings $Partial)
        $Lines[1] | Should -Match 'discovery 525/780  collectors -  released -  end -$'
        $Lines[5] | Should -Match 'discovery 800  collectors -  released -  end -$'
        $Lines[8] | Should -Match 'discovery 15\.0  collectors -  released -  end -$'
    }

    It 'writes n/a for a peak the OS did not report, and for the highest peak when none was' {
        $NoPeak = New-TestSubscriptionReadings -Id 'mac-subscription' -Stamp 's5' -Resources 3 -Heaps @(1, 2, 3, 2, 2) -WorkingSets @(4, 5, 6, 5, 5) -Peaks @($null, $null, $null, $null, $null) -Seconds @(0.1, 0.2, 0.3, 0.3, 0.4)
        $Lines = @(Get-RdaMemoryReadingLines -Readings $NoPeak)
        $Lines[5] | Should -Be '  [sub mac-subscription]  start n/a  discovery n/a  collectors n/a  released n/a  end n/a'
        $Lines[6] | Should -Be '  Highest peak working set    : n/a'
        ($Lines -join "`n") | Should -Not -Match 'start 0\b' -Because 'a missing peak is never written as 0'
    }

    It 'returns nothing for no readings' {
        @(Get-RdaMemoryReadingLines -Readings @()).Count | Should -Be 0
        @(Get-RdaMemoryReadingLines -Readings $null).Count | Should -Be 0
        @(Get-RdaTimingLines -Readings $null).Count | Should -Be 0
    }

    It 'writes dot decimals under a comma-decimal culture and after a JSON round trip' {
        $Prior = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::new('de-DE')
            $RoundTripped = $script:Both | ConvertTo-Json -Depth 4 | ConvertFrom-Json
            $Lines = @(Get-RdaMemoryReadingLines -Readings $RoundTripped)
        }
        finally
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $Prior
        }
        $Lines[1] | Should -Match 'resources 20,000  start 310/520'
        # The fractional fixture is the culture probe: a culture-sensitive parse reads 312.4 as 3124.
        $Lines[2] | Should -Be '  [sub second-subscription]  resources 412  start 312/613  discovery 321/620  collectors 326/625  released 314/612  end 316/615'
        $Lines[11] | Should -Be '  [sub second-subscription]  start 3.0  discovery 4.3  collectors 9.0  released 9.0  end 12.1'
    }

    It 'names a reading without an id by position and skips a null element' {
        $NoId = @(New-TestSubscriptionReadings -Id '' -Stamp 's4' -Resources 3 -Heaps @(1, 2, 3, 2, 2) -WorkingSets @(4, 5, 6, 5, 5) -Peaks @(4, 5, 6, 6, 6) -Seconds @(0.1, 0.2, 0.3, 0.3, 0.4))
        $Lines = @(Get-RdaMemoryReadingLines -Readings (@($null) + $NoId + @($null)))
        $Lines.Count | Should -Be 9
        $Lines[1] | Should -Match '^\s+\[sub 1\]\s+resources 3\s'
    }
}

Describe 'Add-RdaSubscriptionTimings and Get-RdaTimingLines' {
    BeforeAll {
        $script:PriorReadingsT = $Global:MemoryReadings
        $script:PriorStampT = $Global:CurrentDateTime
    }
    AfterAll {
        $Global:MemoryReadings = $script:PriorReadingsT
        $Global:CurrentDateTime = $script:PriorStampT
    }
    BeforeEach {
        Set-Variable -Name SubscriptionID -Value $script:SubId -Scope Script
        $Global:CurrentDateTime = 'run-2'
        $script:Earlier = New-TestSubscriptionReadings -Id $script:SubId -Stamp 'run-1' -Resources 5 -Heaps @(1, 1, 1, 1, 1) -WorkingSets @(1, 1, 1, 1, 1) -Peaks @(1, 1, 1, 1, 1) -Seconds @(1, 2, 3, 3, 4)
        $script:Current = New-TestSubscriptionReadings -Id $script:SubId -Stamp 'run-2' -Resources 5 -Heaps @(1, 1, 1, 1, 1) -WorkingSets @(1, 1, 1, 1, 1) -Peaks @(1, 1, 1, 1, 1) -Seconds @(4.2, 15.0, 80.5, 80.5, 95.3)
        $Global:MemoryReadings = @($script:Earlier) + @($script:Current)
        $script:Timings = [ordered]@{
            'Metrics collection (Azure Monitor)'              = [timespan]::FromSeconds(30.24)
            'Resource detail collection (service collectors)' = [timespan]::FromSeconds(40.01)
            'Consumption / cost collection (billing)'         = [timespan]::FromSeconds(9.96)
        }
    }

    It 'adds the five durations to this run''s end reading only' {
        $Clock = [System.Diagnostics.Stopwatch]::new()
        $Report = [System.Diagnostics.Stopwatch]::new()
        Add-RdaSubscriptionTimings -Clock $Clock -ReportClock $Report -PhaseTimings $script:Timings
        $End = @($script:Current | Where-Object { $_.Phase -eq 'end' })[0]
        $End.MetricsSeconds | Should -Be 30.2
        $End.CollectorsSeconds | Should -Be 40
        $End.BillingSeconds | Should -Be 10
        $End.ReportSeconds | Should -Be 0
        $End.TotalSeconds | Should -Be 0
        $Old = @($script:Earlier | Where-Object { $_.Phase -eq 'end' })[0]
        $Old.PSObject.Properties.Name | Should -Not -Contain 'TotalSeconds' -Because 'an earlier run of the same prompt keeps its own values'
        $Start = @($script:Current | Where-Object { $_.Phase -eq 'start' })[0]
        $Start.PSObject.Properties.Name | Should -Not -Contain 'TotalSeconds'
    }

    It 'leaves a skipped phase empty and replaces the values on the second call' {
        $Only = [ordered]@{ 'Resource detail collection (service collectors)' = [timespan]::FromSeconds(1) }
        Add-RdaSubscriptionTimings -PhaseTimings $Only
        $End = @($script:Current | Where-Object { $_.Phase -eq 'end' })[0]
        $End.MetricsSeconds | Should -BeNullOrEmpty
        $End.BillingSeconds | Should -BeNullOrEmpty
        $End.CollectorsSeconds | Should -Be 1
        Add-RdaSubscriptionTimings -PhaseTimings $script:Timings
        $End.CollectorsSeconds | Should -Be 40
    }

    It 'does nothing and does not throw when this run took no end reading' {
        $Global:MemoryReadings = @($script:Current | Where-Object { $_.Phase -ne 'end' })
        { Add-RdaSubscriptionTimings -PhaseTimings $script:Timings } | Should -Not -Throw
        @($Global:MemoryReadings | Where-Object { $_.PSObject.Properties.Name -contains 'TotalSeconds' }).Count | Should -Be 0
    }

    It 'renders discovery from the readings and the rest from the end reading' {
        $Rows = Add-TestTimings -Rows $script:Current -Metrics 30.2 -Collectors 40.0 -Billing 10.0 -Report 4.5 -Total 98.7
        $Lines = @(Get-RdaTimingLines -Readings $Rows)
        $Lines.Count | Should -Be 2
        $Lines[0] | Should -Be 'Timings (seconds; report is report and packaging; report and total include the zip):'
        $Lines[1] | Should -Be '  [sub 12345678-1234-1234-1234-123456789012]  discovery 10.8  metrics 30.2  collectors 40.0  billing 10.0  report 4.5  total 98.7'
        (@(Get-RdaTimingLines -Readings $Rows -BeforeZip))[0] | Should -Be 'Timings (seconds; report is report and packaging; report and total stop where this log is written, before the zip):'
        (@(Get-RdaTimingLines -Readings $Rows -Obfuscated))[1] | Should -Match '^  \[sub 1\]  discovery 10\.8  '
    }

    It 'marks phases with no value, as a skipped phase or a subscription that never reached its end leaves' {
        $Partial = @($script:Current | Where-Object { $_.Phase -in @('start', 'discovery') })
        (@(Get-RdaTimingLines -Readings $Partial))[1] | Should -Be '  [sub 12345678-1234-1234-1234-123456789012]  discovery 10.8  metrics -  collectors -  billing -  report -  total -'
    }
}

Describe 'The run summary and the diagnostics log carry the block' {
    BeforeAll {
        $script:Readings = New-TestSubscriptionReadings -Id $script:SubId -Stamp 'run-1' -Resources 100 -Heaps @(300, 320, 340, 305, 306) -WorkingSets @(500, 520, 540, 505, 506) -Peaks @(510, 530, 550, 550, 560) -Seconds @(2.0, 5.5, 20.0, 20.0, 31.0)
        $script:Readings = Add-TestTimings -Rows $script:Readings -Metrics 6.0 -Collectors 7.5 -Billing $null -Report 3.0 -Total 31.0
        $script:Other = New-TestSubscriptionReadings -Id $script:SubId -Stamp 'run-0' -Resources 9 -Heaps @(1, 2, 3, 4, 5) -WorkingSets @(1, 2, 3, 4, 5) -Peaks @(1, 2, 3, 4, 5) -Seconds @(1, 2, 3, 4, 5)
    }

    It 'Get-RunSummaryLogContent renders the block, the run total and the run peak when readings exist' {
        $Start = [datetime]'2026-01-01T00:00:00'
        $With = @(Get-RunSummaryLogContent -Version '0.0.0' -StartTime $Start -EndTime $Start.AddSeconds(185.34) -MemoryReadings $script:Readings -PeakWorkingSetMB 600.4) -join "`n"
        $With | Should -Match 'Memory \(MB, read without forcing a collection; managed heap / process working set\):'
        $With | Should -Match 'resources 100  start 300/500'
        $With | Should -Match 'Timings \(seconds; report is report and packaging; report and total include the zip\):'
        $With | Should -Match 'discovery 3\.5  metrics 6\.0  collectors 7\.5  billing -  report 3\.0  total 31\.0'
        $With | Should -Match '(?m)^  Run total                   : 185\.3 s$'
        $With | Should -Match '(?m)^  Run peak working set        : 600 MB \(highest single process\)$' -Because 'the wrapper process peaked higher than any reading'
        $With | Should -Not -Match 'no readings recorded'
    }

    It 'Get-RunSummaryLogContent takes the run peak from the readings when the wrapper reports none' {
        $Text = @(Get-RunSummaryLogContent -Version '0.0.0' -MemoryReadings $script:Readings -PeakWorkingSetMB $null) -join "`n"
        $Text | Should -Match '(?m)^  Run peak working set        : 560 MB \(highest single process\)$'
    }

    It 'Get-RunSummaryLogContent states the empty case and writes n/a for an unknown peak' {
        $Without = @(Get-RunSummaryLogContent -Version '0.0.0') -join "`n"
        $Without | Should -Not -Match 'Memory \(MB'
        $Without | Should -Match 'Memory: no readings recorded' -Because 'a summary without readings must say so, not look like a build without the block'
        $Without | Should -Match '(?m)^  Run peak working set        : n/a$'
    }

    It 'Get-RunSummaryLogContent hides subscription ids in the block when obfuscated' {
        $Text = @(Get-RunSummaryLogContent -Version '0.0.0' -MemoryReadings $script:Readings -Obfuscated) -join "`n"
        $Text | Should -Match '\[sub 1\]'
        $Text | Should -Not -Match '12345678-1234'
    }

    It 'Write-RdaShareableDiagnosticsLog renders only this run''s readings and keeps its phase timings (<Mode>)' -ForEach @(
        @{ Mode = 'default'; Obfuscated = $false }
        @{ Mode = 'obfuscated'; Obfuscated = $true }
    ) {
        $Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('PerformanceLogging_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        try
        {
            $Phases = [ordered]@{ 'Metrics collection (Azure Monitor)' = [timespan]::FromSeconds(6) }
            $File = Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + [IO.Path]::DirectorySeparatorChar) -ReportName 'R' -RunDateTime 'run-1' -Version '0.0.0' -PhaseTimings $Phases -MemoryReadings (@($script:Other) + @($script:Readings)) -Obfuscated:$Obfuscated
            $File | Should -Not -BeNullOrEmpty
            $Text = Get-Content -LiteralPath $File -Raw
            $Text | Should -Match '(?m)^  Metrics collection \(Azure Monitor\): 0min 06 sec\r?$' -Because 'the existing phase-timing lines are unchanged'
            $Text | Should -Match 'resources 100  start 300/500  discovery 320/520  collectors 340/540  released 305/505  end 306/506'
            $Text | Should -Match 'start 510  discovery 530  collectors 550  released 550  end 560'
            $Text | Should -Match 'Timings \(seconds; report is report and packaging; report and total stop where this log is written, before the zip\):'
            $Text | Should -Match 'discovery 3\.5  metrics 6\.0  collectors 7\.5  billing -  report 3\.0  total 31\.0'
            $Text | Should -Not -Match 'resources 9\b' -Because 'the earlier run''s readings carry a different stamp'
            $Text | Should -Not -Match '12345678-1234' -Because 'the shareable log masks GUIDs in both modes, as its header says'
            if ($Obfuscated) { $Text | Should -Match '\[sub 1\]' } else { $Text | Should -Match '\[sub <guid>\]' }
        }
        finally
        {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Write-RdaShareableDiagnosticsLog without readings writes the log as before, with no block' {
        $Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('PerformanceLogging_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        try
        {
            $File = Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + [IO.Path]::DirectorySeparatorChar) -ReportName 'R' -RunDateTime 'run-1' -Version '0.0.0'
            $Text = Get-Content -LiteralPath $File -Raw
            $Text | Should -Match 'Consumption failed/incomplete subscriptions: 0'
            $Text | Should -Not -Match 'Memory \(MB'
            $Text | Should -Not -Match 'Timings \('
        }
        finally
        {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
