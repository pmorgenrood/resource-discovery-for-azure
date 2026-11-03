#Requires -Version 7.0
# =============================================================================
# Common.Functions.ps1
#
# Cross-cutting helper functions shared by the entry-point scripts
# (Run-AllSubscriptions.ps1, Run-AllSubscriptions.Stream.ps1,
# ResourceInventory.ps1, Reveal.ps1). Dot-sourced from the top
# of each so the functions load into that script's scope. Definitions only -
# no top-level code.
# =============================================================================

function Write-RdaProgress
{
    <#
    .SYNOPSIS
        Single, reusable progress reporter used across the tool.

    .DESCRIPTION
        Renders progress so it is visible in every host the tool runs in:
          1. Write-Progress - a live updating bar in an INTERACTIVE host.
          2. A throttled host line - because Write-Progress is a NO-OP in the
             non-interactive hosts the tool frequently uses (parallel `pwsh`
             stream processes, ForEach-Object -Parallel runspaces, transcripts,
             CI). In those hosts a single line per call is written so progress is
             still visible / captured by a parent process or transcript.
          3. An optional durable heartbeat line appended to -HeartbeatLogFile so
             a long run is observable live and after the fact.

        The function is intentionally generic: it knows nothing about
        subscriptions, collectors or staging folders. Every caller does its own
        trivial index/total math and calls this. Two display modes:
          - Determinate  (-Total > 0): "<item> (<index> of <total>)" + a percent.
          - Count-only    (-Total omitted or 0): "<item> (<index>)", no percent,
            for loops whose total is not known up front.

    .PARAMETER Activity
        Task label shown as the progress activity (e.g. 'Processing
        subscriptions', 'Revealing per-subscription reports').

    .PARAMETER CurrentItem
        Short description of the item being processed now (subscription/collector/
        folder name). Callers may enrich it, e.g. 'Sub-Prod-40 (already revealed)'.

    .PARAMETER Index
        1-based position of the current item.

    .PARAMETER Total
        Total number of items. 0 (or omitted) selects count-only mode.

    .PARAMETER Id
        Optional Write-Progress -Id to distinguish nested/parallel bars (default 0).

    .PARAMETER HeartbeatLogFile
        Optional path. When supplied, a timestamped progress line is appended so
        progress is durable even where Write-Progress is a no-op. A write failure
        never throws (best-effort).

    .PARAMETER NonInteractiveLine
        Force emitting the plain-text host line regardless of host detection.
        Useful for child stream processes whose stdout a parent captures.

    .PARAMETER BarOnly
        Suppress the non-interactive plain-text line entirely - emit only the
        Write-Progress bar (plus the optional heartbeat log). Use for
        high-frequency loops that run in non-interactive child processes (e.g.
        the per-collector Service Processing loop, which runs inside a parallel
        stream worker), where one line per item would flood the parent's
        captured stdout. Mirrors the pre-existing Write-Progress-only behavior of
        those loops while still routing through this single function.

    .PARAMETER Completed
        Clears the Write-Progress bar for this -Activity/-Id (and logs a
        completion line when -HeartbeatLogFile is set). Use once after the loop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]   $Activity,

        [string]   $CurrentItem = '',
        [int]      $Index = 0,
        [int]      $Total = 0,
        [int]      $Id = 0,
        [string]   $HeartbeatLogFile,
        [switch]   $NonInteractiveLine,
        [switch]   $BarOnly,
        [switch]   $Completed
    )

    # Build the "(index of total)" or "(index)" suffix once.
    if ($Total -gt 0)
    {
        $Percent = [int](($Index / $Total) * 100)
        if ($Percent -lt 0) { $Percent = 0 }
        elseif ($Percent -gt 100) { $Percent = 100 }
        $Status = '{0} ({1} of {2})' -f $CurrentItem, $Index, $Total
    }
    else
    {
        $Percent = -1
        $Status = '{0} ({1})' -f $CurrentItem, $Index
    }

    if ($Completed)
    {
        Write-Progress -Activity $Activity -Id $Id -Completed
    }
    elseif ($Percent -ge 0)
    {
        Write-Progress -Activity $Activity -Id $Id -Status $Status -PercentComplete $Percent
    }
    else
    {
        Write-Progress -Activity $Activity -Id $Id -Status $Status
    }

    # Non-interactive fallback: Write-Progress renders nothing in redirected /
    # non-interactive hosts, so emit a plain line there (or when forced) so a
    # parent process or transcript still sees movement. Skip on -Completed.
    if (-not $Completed -and -not $BarOnly)
    {
        $HostIsInteractive = ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected)
        if ($NonInteractiveLine -or -not $HostIsInteractive)
        {
            Write-Host ('{0}: {1}' -f $Activity, $Status)
        }
    }

    # Durable heartbeat (best-effort; never throws).
    if (-not [string]::IsNullOrEmpty($HeartbeatLogFile))
    {
        try
        {
            if ($Completed)
            {
                $Line = '[{0:dd-MM-yyyy} {0:HH:mm:ss}] {1}: complete ({2} item(s))' -f (Get-Date), $Activity, $Total
            }
            else
            {
                $Line = '[{0:dd-MM-yyyy} {0:HH:mm:ss}] {1}: {2}' -f (Get-Date), $Activity, $Status
            }
            Add-Content -Path $HeartbeatLogFile -Value $Line -ErrorAction Stop
        }
        catch
        {
            # Best-effort only - progress reporting must never break a run.
        }
    }
}

# =============================================================================
# Write-Log
#
# The single logging entry point for the whole tool. Moved here (from
# ResourceInventory.Functions.ps1) and defined Global: so EVERYTHING that logs
# routes through it - the orchestrator, the wrapper scripts, the metrics
# extension, and the Services/*/*.ps1 collectors (which run via '& $Module' and
# therefore only see Global functions, exactly like Protect-FreeTextValue).
#
# Default behavior is UNCHANGED from the original: with no switches it writes a
# severity-colored line to the console and, for Error severity, appends to the
# local error sink ($Global:ErrorLogFile). The two switches are purely additive
# so existing callers are byte-for-byte unaffected:
#   -NoConsole   suppress the console line (for high-volume diagnostics that
#                must NOT flood the terminal - metrics phase, per-collector
#                heartbeat). The line still goes to any file sink selected.
#   -ToDebugLog  also append the line to the consolidated LOCAL debug log
#                ($Global:DebugLogFile) - the one file the heartbeat and metrics
#                diagnostics share. Local-only, never zipped.
#
# NOTE on scope: the per-line '[<8-char sub>]' tag is read via Get-Variable so it
# resolves the caller's script-scope $SubscriptionID without throwing when none
# is set. From a collector invoked via '&' that lookup may not cross the scope
# boundary, in which case the tag is simply omitted (the debug/error log
# filenames are already SubscriptionID-tagged, so nothing is lost).
#
# Deliberately NOT baked in (kept separate on purpose):
#   - Progress UI: that is Write-RdaProgress above (a bar, not a log line).
#   - Obfuscation scrubbing (Protect-DiagnosticText): only the SHAREABLE
#     Diagnostics_*.log needs scrubbing, and it is built once at packaging time
#     from aggregated health globals - NOT line-by-line here. Scrubbing every
#     log line would be slow and would destroy the local logs' raw
#     troubleshooting value, so it stays out of the hot path.
#   - Per-call logging from inside ForEach-Object -Parallel workers: concurrent
#     appends to one file are not safe. Those paths record into a thread-safe
#     bag and are logged as an aggregated summary on the main thread instead.
# =============================================================================
Function Global:Write-Log([string]$Message, [string]$Severity, [switch]$NoConsole, [switch]$ToDebugLog)
{
    $DateTime = "[{0:dd-MM-yyyy} {0:HH:mm:ss}]" -f (Get-Date)

    # Tag each line with the current subscription (first 8 chars of its GUID)
    # when one is in scope. Read via Get-Variable so it resolves the script-scope
    # $SubscriptionID up the call chain without throwing when no subscription is
    # in scope (e.g. a standalone full-tenant run) - in that case no tag is added
    # and the output is byte-for-byte unchanged.
    $SubId = Get-Variable -Name 'SubscriptionID' -ValueOnly -ErrorAction SilentlyContinue
    $SubTag = if (-not [string]::IsNullOrEmpty($SubId)) { '[{0}] ' -f $SubId.Substring(0, [Math]::Min(8, $SubId.Length)) } else { '' }
    $Message = $SubTag + $Message

    if (-not $NoConsole)
    {
        switch ($Severity)
        {
            "Info" { Write-Host $Message -ForegroundColor Cyan }
            "Warning" { Write-Host $Message -ForegroundColor Yellow }
            "Error" { Write-Host $Message -ForegroundColor Red }
            "Success" { Write-Host $Message -ForegroundColor Green }
            default { Write-Host $Message }
        }
    }

    # Errors-only local sink: when an error-log path has been established append
    # error-severity messages to a dedicated, timestamped file.
    #
    # IMPORTANT: this log is written LOCALLY ONLY and is deliberately NOT added
    # to the obfuscated (server-bound) zip. Error-severity messages can
    # interpolate raw $_.Exception.Message text and local paths (e.g. collector
    # failures, reconnect failures, HTML-gen failures) that carry real Azure
    # identifiers the obfuscation layer never touches. Shipping this file would
    # leak them. Do NOT add $Global:ErrorLogFile to the Compress-Archive Path
    # array without first scrubbing/obfuscating its contents. It is kept on disk
    # for local troubleshooting only, at the same trust level as the transcript.
    if ($Severity -eq 'Error' -and -not [string]::IsNullOrEmpty($Global:ErrorLogFile))
    {
        try
        {
            ('{0} {1}' -f $DateTime, $Message) | Out-File -FilePath $Global:ErrorLogFile -Append -Encoding utf8
        }
        catch
        {
            # Never let an error-log write failure interrupt the run.
        }
    }

    # Consolidated LOCAL debug log sink (opt-in via -ToDebugLog): the single file
    # the per-collector heartbeat and the metrics-phase diagnostics share
    # ($Global:DebugLogFile). Local-only, never zipped - it carries real
    # service/resource names and, for FAIL lines, raw exception text. Silent
    # best-effort like the error sink; nothing is written until the global path
    # exists, so callers before setup (or a standalone extension run) are
    # unaffected.
    if ($ToDebugLog -and -not [string]::IsNullOrEmpty($Global:DebugLogFile))
    {
        try
        {
            ('{0} {1}' -f $DateTime, $Message) | Out-File -FilePath $Global:DebugLogFile -Append -Encoding utf8
        }
        catch
        {
            # Never let a debug-log write failure interrupt the run.
        }
    }
}

# =============================================================================
# Memory and timing readings (observe only)
#
# Five readings per subscription (start, discovery, collectors, released, end)
# record how much memory the process holds and how long the subscription has
# been running. A reading never changes what it measures: no collection is
# forced, so the managed heap figure includes garbage the runtime has not
# collected yet. The records land in $Global:MemoryReadings, which the wrapper
# keeps for the whole run and a stream worker hands back in its summary JSON.
# They are rendered into each subscription's Diagnostics log, RunSummary.log and
# the local debug log, and carry counts, seconds and megabytes only. A
# subscription is named by its id, or by its position when the run is
# obfuscated.
# =============================================================================

function Get-RdaPeakWorkingSetMB
{
    [CmdletBinding()]
    param()

    # The highest working set this process has had so far, in MB, or $null when the OS does not
    # report it: .NET returns 0 where the platform has no peak counter, and the renderers write
    # $null as n/a so a missing figure is never read as 0.
    try
    {
        $PeakBytes = [System.Diagnostics.Process]::GetCurrentProcess().PeakWorkingSet64
        if ($PeakBytes -gt 0)
        {
            return [math]::Round($PeakBytes / 1MB, 1)
        }
    }
    catch
    {
        Write-Verbose ('Peak working set unavailable: {0}' -f $_.Exception.Message)
    }
    return $null
}

function Write-RdaMemorySnapshot
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [System.Diagnostics.Stopwatch]$Clock,
        [switch]$Record
    )

    # Takes one reading: the managed heap ([GC]::GetTotalMemory($false), so no collection is
    # forced), the process working set and its peak so far, the memory available to the runtime,
    # and the seconds since the subscription started ($Clock). -Record appends it to
    # $Global:MemoryReadings, keyed by the subscription being processed and the run stamp. A
    # recorded phase must be one of the five the renderers lay out; a misspelled phase would
    # otherwise render as a silent gap.
    # The reading also goes to the local debug log, but only once that log belongs to this run
    # (its name carries the run stamp): under the wrapper the path still names the previous
    # subscription's log until this run sets its own. The block written at the end of the run
    # carries every reading, the earlier ones included.
    if ($Record)
    {
        $RecordedPhases = @('start', 'discovery', 'collectors', 'released', 'end')
        if ($Phase -notin $RecordedPhases)
        {
            throw [System.ArgumentException]::new(("A recorded memory reading must use one of the phases the summary renders ({0}); got '{1}'." -f ($RecordedPhases -join ', '), $Phase), 'Phase')
        }
    }

    $Stamp = [string]$Global:CurrentDateTime
    $DebugLogName = if ([string]::IsNullOrEmpty([string]$Global:DebugLogFile)) { '' } else { [System.IO.Path]::GetFileName([string]$Global:DebugLogFile) }
    $DebugLogIsThisRun = (-not [string]::IsNullOrEmpty($Stamp)) -and $DebugLogName.Contains($Stamp)
    try
    {
        $Inv = [cultureinfo]::InvariantCulture
        $HeapMB = [math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 1)
        $WorkingSetMB = [math]::Round([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB, 1)
        $PeakMB = Get-RdaPeakWorkingSetMB
        $LimitMB = [math]::Round([System.GC]::GetGCMemoryInfo().TotalAvailableMemoryBytes / 1MB, 0)
        $Seconds = if ($null -ne $Clock) { [math]::Round($Clock.Elapsed.TotalSeconds, 1) } else { $null }
        if ($Record)
        {
            $SubId = Get-Variable -Name 'SubscriptionID' -ValueOnly -ErrorAction SilentlyContinue
            # .Count on the array itself: wrapping it in @() would copy every row to count them.
            $ResourceCount = if ($null -ne $Global:Resources) { [int]$Global:Resources.Count } else { 0 }
            if ($null -eq $Global:MemoryReadings) { $Global:MemoryReadings = @() }
            $Global:MemoryReadings += [pscustomobject]@{
                Id               = [string]$SubId
                Stamp            = $Stamp
                Phase            = $Phase
                Resources        = $ResourceCount
                HeapMB           = $HeapMB
                WorkingSetMB     = $WorkingSetMB
                PeakWorkingSetMB = $PeakMB
                LimitMB          = $LimitMB
                Seconds          = $Seconds
            }
        }
        if ($DebugLogIsThisRun)
        {
            $PeakText = if ($null -ne $PeakMB) { '{0} MB' -f $PeakMB.ToString($Inv) } else { 'n/a' }
            $SecondsText = if ($null -ne $Seconds) { '{0} s' -f $Seconds.ToString('0.0', $Inv) } else { 'n/a' }
            Write-Log -Message ('[Memory] {0}: managed heap {1} MB, process working set {2} MB, peak working set {3}, memory available to the runtime {4} MB, {5} since the subscription started (no collection forced).' -f $Phase, $HeapMB.ToString($Inv), $WorkingSetMB.ToString($Inv), $PeakText, $LimitMB.ToString($Inv), $SecondsText) -Severity 'Info' -NoConsole -ToDebugLog
        }
    }
    catch
    {
        if ($DebugLogIsThisRun)
        {
            Write-Log -Message ('[Memory] {0}: reading unavailable: {1}' -f $Phase, $_.Exception.Message) -Severity 'Info' -NoConsole -ToDebugLog
        }
    }
}

function Add-RdaSubscriptionTimings
{
    [CmdletBinding()]
    param(
        [System.Diagnostics.Stopwatch]$Clock,
        [System.Diagnostics.Stopwatch]$ReportClock,
        $PhaseTimings
    )

    # Adds the phase durations of the subscription being processed to its 'end' reading, so they
    # travel with the readings to the wrapper and through a stream worker's summary JSON. In
    # seconds, one decimal: MetricsSeconds, CollectorsSeconds and BillingSeconds are read from
    # the phase-timing table the HTML report and the Diagnostics log already show ($null when the
    # phase did not run); ReportSeconds is the report and packaging, timed by $ReportClock from
    # the start of the HTML report; TotalSeconds is the time since the subscription started.
    # Called before the Diagnostics log is written and again after the zip, so the log holds the
    # values at the time it was written and RunSummary.log and the debug log include the zip.
    # Does nothing when this run took no 'end' reading.
    try
    {
        $SubId = [string](Get-Variable -Name 'SubscriptionID' -ValueOnly -ErrorAction SilentlyContinue)
        $Stamp = [string]$Global:CurrentDateTime
        $EndReading = @(@($Global:MemoryReadings) | Where-Object { $null -ne $_ -and [string]$_.Phase -eq 'end' -and [string]$_.Stamp -eq $Stamp -and [string]$_.Id -eq $SubId } | Select-Object -Last 1)
        if ($EndReading.Count -eq 0) { return }

        $Values = [ordered]@{
            MetricsSeconds    = $null
            CollectorsSeconds = $null
            BillingSeconds    = $null
            ReportSeconds     = if ($null -ne $ReportClock) { [math]::Round($ReportClock.Elapsed.TotalSeconds, 1) } else { $null }
            TotalSeconds      = if ($null -ne $Clock) { [math]::Round($Clock.Elapsed.TotalSeconds, 1) } else { $null }
        }
        if ($null -ne $PhaseTimings)
        {
            $BillingTotal = $null
            foreach ($PhaseName in @($PhaseTimings.Keys))
            {
                $PhaseSeconds = ([TimeSpan]$PhaseTimings[$PhaseName]).TotalSeconds
                if ($PhaseName -eq 'Metrics collection (Azure Monitor)') { $Values['MetricsSeconds'] = [math]::Round($PhaseSeconds, 1) }
                elseif ($PhaseName -eq 'Resource detail collection (service collectors)') { $Values['CollectorsSeconds'] = [math]::Round($PhaseSeconds, 1) }
                elseif ([string]$PhaseName -like '* (billing)') { $BillingTotal = [double]$BillingTotal + $PhaseSeconds }
            }
            if ($null -ne $BillingTotal) { $Values['BillingSeconds'] = [math]::Round($BillingTotal, 1) }
        }
        foreach ($Field in $Values.Keys)
        {
            $EndReading[0] | Add-Member -NotePropertyName $Field -NotePropertyValue $Values[$Field] -Force
        }
    }
    catch
    {
        Write-Verbose ('Subscription timings not recorded: {0}' -f $_.Exception.Message)
    }
}

function Get-RdaReadingGroups
{
    [CmdletBinding()]
    param(
        $Readings = @(),
        [string]$Stamp,
        [switch]$Obfuscated
    )

    # Groups the readings by subscription, in the order they were first seen, and labels each
    # group: 'sub <id>', or 'sub <position>' when obfuscated or when a reading carries no id.
    # -Stamp keeps a standalone run's log to its own readings when the same prompt has run the
    # script before.
    $Rows = @(@($Readings) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrEmpty([string]$_.Phase) })
    if (-not [string]::IsNullOrEmpty($Stamp))
    {
        $Rows = @($Rows | Where-Object { [string]$_.Stamp -eq $Stamp })
    }
    $Groups = [ordered]@{}
    foreach ($Row in $Rows)
    {
        $Key = [string]$Row.Id
        if ([string]::IsNullOrEmpty($Key)) { $Key = [string]$Row.Stamp }
        if (-not $Groups.Contains($Key)) { $Groups[$Key] = [System.Collections.Generic.List[object]]::new() }
        $Groups[$Key].Add($Row)
    }
    $Result = [System.Collections.Generic.List[object]]::new()
    $Position = 0
    foreach ($Key in $Groups.Keys)
    {
        $Position++
        $Group = @($Groups[$Key])
        $Label = if ($Obfuscated -or [string]::IsNullOrEmpty([string]$Group[0].Id)) { 'sub {0}' -f $Position } else { 'sub {0}' -f [string]$Group[0].Id }
        $Result.Add([pscustomobject]@{ Label = $Label; Rows = $Group })
    }
    return $Result.ToArray()
}

function ConvertTo-RdaReadingNumber
{
    [CmdletBinding()]
    [OutputType([double])]
    param($Value)

    # A reading field as a double, or $null when it is missing or not a number. Parsed with the
    # invariant culture, so a value that came back through JSON reads the same under a
    # comma-decimal culture.
    if ($null -eq $Value -or [string]::IsNullOrEmpty([string]$Value)) { return $null }
    $Number = 0.0
    if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$Number)) { return $Number }
    return $null
}

function Get-RdaMemoryReadingLines
{
    [CmdletBinding()]
    param(
        $Readings = @(),
        [string]$Stamp,
        [switch]$Obfuscated
    )

    # Renders the readings Write-RdaMemorySnapshot -Record collected, as three tables with one
    # row per subscription and one cell per phase: managed heap / working set, the peak working
    # set so far, and the seconds since the subscription started. '-' marks a phase that was
    # never reached and 'n/a' a figure the OS did not report. Under the first two tables come the
    # highest working set, the memory available to the runtime and the highest peak. Megabytes
    # are whole numbers, seconds have one decimal.
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Groups = @(Get-RdaReadingGroups -Readings $Readings -Stamp $Stamp -Obfuscated:$Obfuscated)
    if ($Groups.Count -eq 0) { return $Lines.ToArray() }

    $Inv = [cultureinfo]::InvariantCulture
    $Phases = @('start', 'discovery', 'collectors', 'released', 'end')
    $HighestWorkingSet = 0.0
    $HighestPeak = $null
    $Limit = 0.0
    $MemoryRows = [System.Collections.Generic.List[string]]::new()
    $PeakRows = [System.Collections.Generic.List[string]]::new()
    $SecondsRows = [System.Collections.Generic.List[string]]::new()
    foreach ($Group in $Groups)
    {
        $Resources = 0
        foreach ($Row in $Group.Rows)
        {
            $RowResources = 0
            if ([int]::TryParse([string]$Row.Resources, [ref]$RowResources) -and $RowResources -gt $Resources) { $Resources = $RowResources }
            $RowWs = ConvertTo-RdaReadingNumber $Row.WorkingSetMB
            if ($null -ne $RowWs -and $RowWs -gt $HighestWorkingSet) { $HighestWorkingSet = $RowWs }
            $RowPeak = ConvertTo-RdaReadingNumber $Row.PeakWorkingSetMB
            if ($null -ne $RowPeak -and ($null -eq $HighestPeak -or $RowPeak -gt $HighestPeak)) { $HighestPeak = $RowPeak }
            $RowLimit = ConvertTo-RdaReadingNumber $Row.LimitMB
            if ($null -ne $RowLimit -and $RowLimit -gt $Limit) { $Limit = $RowLimit }
        }
        $MemoryCells = [System.Collections.Generic.List[string]]::new()
        $MemoryCells.Add(('resources {0}' -f $Resources.ToString('N0', $Inv)))
        $PeakCells = [System.Collections.Generic.List[string]]::new()
        $SecondsCells = [System.Collections.Generic.List[string]]::new()
        foreach ($Phase in $Phases)
        {
            $Reading = @($Group.Rows | Where-Object { [string]$_.Phase -eq $Phase } | Select-Object -Last 1)
            if ($Reading.Count -eq 0)
            {
                $MemoryCells.Add(('{0} -' -f $Phase))
                $PeakCells.Add(('{0} -' -f $Phase))
                $SecondsCells.Add(('{0} -' -f $Phase))
                continue
            }
            $Heap = ConvertTo-RdaReadingNumber $Reading[0].HeapMB
            $Ws = ConvertTo-RdaReadingNumber $Reading[0].WorkingSetMB
            $HeapText = if ($null -ne $Heap) { [math]::Round($Heap).ToString($Inv) } else { 'n/a' }
            $WsText = if ($null -ne $Ws) { [math]::Round($Ws).ToString($Inv) } else { 'n/a' }
            $MemoryCells.Add(('{0} {1}/{2}' -f $Phase, $HeapText, $WsText))
            $Peak = ConvertTo-RdaReadingNumber $Reading[0].PeakWorkingSetMB
            $PeakCells.Add(('{0} {1}' -f $Phase, $(if ($null -ne $Peak) { [math]::Round($Peak).ToString($Inv) } else { 'n/a' })))
            $Seconds = ConvertTo-RdaReadingNumber $Reading[0].Seconds
            $SecondsCells.Add(('{0} {1}' -f $Phase, $(if ($null -ne $Seconds) { $Seconds.ToString('0.0', $Inv) } else { 'n/a' })))
        }
        $MemoryRows.Add(('  [{0}]  {1}' -f $Group.Label, ($MemoryCells -join '  ')))
        $PeakRows.Add(('  [{0}]  {1}' -f $Group.Label, ($PeakCells -join '  ')))
        $SecondsRows.Add(('  [{0}]  {1}' -f $Group.Label, ($SecondsCells -join '  ')))
    }

    $Lines.Add('Memory (MB, read without forcing a collection; managed heap / process working set):')
    foreach ($Row in $MemoryRows) { $Lines.Add($Row) }
    $Lines.Add(('  Highest working set sampled : {0} MB' -f [math]::Round($HighestWorkingSet).ToString($Inv)))
    if ($Limit -gt 0)
    {
        $Lines.Add(('  Memory available to runtime : {0} MB' -f [math]::Round($Limit).ToString($Inv)))
    }
    $Lines.Add('Peak working set so far (MB, n/a where the OS does not report it):')
    foreach ($Row in $PeakRows) { $Lines.Add($Row) }
    $Lines.Add(('  Highest peak working set    : {0}' -f $(if ($null -ne $HighestPeak) { '{0} MB' -f [math]::Round($HighestPeak).ToString($Inv) } else { 'n/a' })))
    $Lines.Add('Seconds since the subscription started, at each reading:')
    foreach ($Row in $SecondsRows) { $Lines.Add($Row) }

    return $Lines.ToArray()
}

function Get-RdaTimingLines
{
    [CmdletBinding()]
    param(
        $Readings = @(),
        [string]$Stamp,
        [switch]$Obfuscated,
        [switch]$BeforeZip
    )

    # Renders one row of phase durations per subscription, in seconds with one decimal:
    # discovery (the Resource Graph pages, from the 'start' to the 'discovery' reading), then
    # metrics, collectors, billing, report and total as Add-RdaSubscriptionTimings put them on
    # the 'end' reading. '-' marks a phase that did not run or a subscription that never reached
    # its 'end' reading. -BeforeZip states in the header that report and total stop where the
    # log is written, which is the case for the log that ships inside the subscription's zip.
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Groups = @(Get-RdaReadingGroups -Readings $Readings -Stamp $Stamp -Obfuscated:$Obfuscated)
    if ($Groups.Count -eq 0) { return $Lines.ToArray() }

    $Inv = [cultureinfo]::InvariantCulture
    $Format = {
        param($Value)
        $Number = ConvertTo-RdaReadingNumber $Value
        if ($null -ne $Number) { $Number.ToString('0.0', $Inv) } else { '-' }
    }
    if ($BeforeZip)
    {
        $Lines.Add('Timings (seconds; report is report and packaging; report and total stop where this log is written, before the zip):')
    }
    else
    {
        $Lines.Add('Timings (seconds; report is report and packaging; report and total include the zip):')
    }
    foreach ($Group in $Groups)
    {
        $Start = @($Group.Rows | Where-Object { [string]$_.Phase -eq 'start' } | Select-Object -Last 1)
        $Discovery = @($Group.Rows | Where-Object { [string]$_.Phase -eq 'discovery' } | Select-Object -Last 1)
        $End = @($Group.Rows | Where-Object { [string]$_.Phase -eq 'end' } | Select-Object -Last 1)
        $DiscoverySeconds = $null
        if ($Start.Count -gt 0 -and $Discovery.Count -gt 0)
        {
            $From = ConvertTo-RdaReadingNumber $Start[0].Seconds
            $To = ConvertTo-RdaReadingNumber $Discovery[0].Seconds
            # [double] 0: with an int first argument [math]::Max picks its integer overload and drops the decimal.
            if ($null -ne $From -and $null -ne $To) { $DiscoverySeconds = [math]::Max([double]0, [math]::Round($To - $From, 1)) }
        }
        $EndRow = if ($End.Count -gt 0) { $End[0] } else { [pscustomobject]@{} }
        $Cells = @(
            ('discovery {0}' -f (& $Format $DiscoverySeconds))
            ('metrics {0}' -f (& $Format $EndRow.MetricsSeconds))
            ('collectors {0}' -f (& $Format $EndRow.CollectorsSeconds))
            ('billing {0}' -f (& $Format $EndRow.BillingSeconds))
            ('report {0}' -f (& $Format $EndRow.ReportSeconds))
            ('total {0}' -f (& $Format $EndRow.TotalSeconds))
        )
        $Lines.Add(('  [{0}]  {1}' -f $Group.Label, ($Cells -join '  ')))
    }

    return $Lines.ToArray()
}

function Write-RdaPerformanceDebugLog
{
    [CmdletBinding()]
    param(
        [switch]$Obfuscated
    )

    # Writes this run's memory and timing block to the local debug log, one line per row, after
    # the zip, so the debug log holds the same figures as RunSummary.log. Never breaks a run.
    try
    {
        $Stamp = [string]$Global:CurrentDateTime
        $BlockLines = @(Get-RdaMemoryReadingLines -Readings $Global:MemoryReadings -Stamp $Stamp -Obfuscated:$Obfuscated) + @(Get-RdaTimingLines -Readings $Global:MemoryReadings -Stamp $Stamp -Obfuscated:$Obfuscated)
        foreach ($BlockLine in $BlockLines)
        {
            Write-Log -Message ('[Performance] {0}' -f $BlockLine) -Severity 'Info' -NoConsole -ToDebugLog
        }
    }
    catch
    {
        Write-Log -Message ('[Performance] block unavailable: {0}' -f $_.Exception.Message) -Severity 'Info' -NoConsole -ToDebugLog
    }
}
