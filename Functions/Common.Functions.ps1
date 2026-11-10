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

# The metrics entries of the subscriptions whose Azure Monitor metric request
# (grouped or for one metric) still failed after its retries
# (Extension/Metrics.ps1 records them with Complete = $false), unique by name
# and id. Leaves out the entries for metrics
# skipped because the sign-in could not be refreshed, which the wrapper reports
# in its FAILED (auth) banner.
function Get-MetricsIncompleteEntries
{
    param([object[]]$Entries)
    @(@($Entries) | Where-Object { Test-MetricsIncompleteEntry -Entry $_ } | Sort-Object Name, Id -Unique)
}

# True for a metrics entry recorded as incomplete (Complete = $false), false for
# one recorded because the sign-in could not be refreshed (no Complete field).
function Test-MetricsIncompleteEntry
{
    param([object]$Entry)
    $null -ne $Entry -and $null -ne $Entry.PSObject.Properties['Complete'] -and $Entry.Complete -eq $false
}

# The last lines of a run in which the metrics of one or more subscriptions are
# incomplete because Azure Monitor kept failing: each subscription, then $Advice
# (the command that collects them again). Run-AllSubscriptions.ps1 and direct
# runs of ResourceInventory.ps1 then exit 3 (5 with a collector failure).
# Prints nothing when there are none.
function Write-MetricsIncompleteBanner
{
    param([object[]]$Entries, [string[]]$Advice)
    $List = @(Get-MetricsIncompleteEntries -Entries $Entries)
    if ($List.Count -eq 0) { return }
    Write-Host ''
    Write-Host '=================== FAILED (metrics) ===================' -ForegroundColor Red
    Write-Host ('Metrics are incomplete for {0} subscription(s): Azure Monitor requests still failed after their retries (throttling, a timeout, an expired sign-in, a server error or an error with no status):' -f $List.Count) -ForegroundColor Red
    foreach ($Entry in $List)
    {
        Write-Host ('  - {0} ({1})' -f $Entry.Name, $Entry.Id) -ForegroundColor Red
    }
    foreach ($Line in @($Advice)) { Write-Host $Line -ForegroundColor Red }
    Write-Host '========================================================' -ForegroundColor Red
}

# The command that collects the metrics of one subscription again, with the
# data switches of the run. With no $SubscriptionId it is the run's own command
# over every subscription. $RunParameters is the run's bound parameters (a
# direct run) or the switches the wrapper forwards. -Obfuscate is kept, so a
# masked run is not collected again unmasked, with -ObfuscationDictionary when
# the run used one. -MetricsLookbackDays, -ResourceGroup, -Service, -ReportName
# and -OutputDirectory are kept when the run set them. Credentials such as
# -Secret are never written.
#
# $DictionaryFile is the dictionary the masked run saved for that subscription.
# It wins over the one the run was seeded with: it holds every masked id of the
# first zip, so the new zip gets the same ids and is not counted twice.
function Get-MetricsRetryCommand
{
    param([string]$TenantID, [string]$SubscriptionId, [System.Collections.IDictionary]$RunParameters, [string]$DictionaryFile)

    # A plain copy, so a run's $PSBoundParameters reads the same as a hashtable.
    $Given = @{}
    if ($null -ne $RunParameters) { foreach ($Key in @($RunParameters.Keys)) { $Given[[string]$Key] = $RunParameters[$Key] } }
    $Parts = [System.Collections.Generic.List[string]]::new()
    $Parts.Add('./ResourceInventory.ps1')
    if (-not [string]::IsNullOrEmpty($TenantID)) { $Parts.Add('-TenantID'); $Parts.Add($TenantID) }
    if (-not [string]::IsNullOrEmpty($SubscriptionId)) { $Parts.Add('-SubscriptionID'); $Parts.Add($SubscriptionId) }
    foreach ($Name in @('Obfuscate', 'SkipConsumption', 'DeviceLogin'))
    {
        if ($Given.Contains($Name) -and [bool]$Given[$Name]) { $Parts.Add('-' + $Name) }
    }
    if ($Given.Contains('ConcurrencyLimit') -and [string]$Given['ConcurrencyLimit'] -match '^\s*\d+\s*$')
    {
        $Parts.Add('-ConcurrencyLimit'); $Parts.Add(([string]$Given['ConcurrencyLimit']).Trim())
    }
    $Masked = $Given.Contains('Obfuscate') -and [bool]$Given['Obfuscate']
    $Seed = if (-not [string]::IsNullOrEmpty($DictionaryFile)) { $DictionaryFile } elseif ($Given.Contains('ObfuscationDictionary')) { [string]$Given['ObfuscationDictionary'] } else { '' }
    if ($Masked -and -not [string]::IsNullOrEmpty($Seed))
    {
        $Parts.Add('-ObfuscationDictionary'); $Parts.Add("'" + $Seed.Replace("'", "''") + "'")
    }
    # The run's scope and output, when it set them, so the new report covers the
    # same resources and lands where the first one did.
    # The lookback is written as the whole number of days the run used, as
    # Metrics.ps1 reads it ([int], so 7.5 is 8). A value that does not convert
    # is left out.
    $Days = if ($Given.Contains('MetricsLookbackDays') -and $Given['MetricsLookbackDays'] -isnot [bool]) { $Given['MetricsLookbackDays'] -as [int] } else { $null }
    if ($null -ne $Days)
    {
        $Parts.Add('-MetricsLookbackDays'); $Parts.Add([string]$Days)
    }
    if ($Given.Contains('ResourceGroup') -and -not [string]::IsNullOrEmpty([string]$Given['ResourceGroup']))
    {
        $Parts.Add('-ResourceGroup'); $Parts.Add("'" + ([string]$Given['ResourceGroup']).Replace("'", "''") + "'")
    }
    $Services = @(if ($Given.Contains('Service')) { @($Given['Service']) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } })
    if ($Services.Count -gt 0)
    {
        $Parts.Add('-Service'); $Parts.Add((@($Services | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ','))
    }
    foreach ($Name in @('ReportName', 'OutputDirectory'))
    {
        if ($Given.Contains($Name) -and -not [string]::IsNullOrEmpty([string]$Given[$Name]))
        {
            $Parts.Add('-' + $Name); $Parts.Add("'" + ([string]$Given[$Name]).Replace("'", "''") + "'")
        }
    }
    return ($Parts -join ' ')
}

# The end of a run with incomplete metrics, for Run-AllSubscriptions.ps1 and a
# direct ResourceInventory.ps1 run: the FAILED (metrics) lines, with the command
# that collects the metrics again. Returns $true when there were any.
# The wrapper (it passes $ReportRoot) and a direct run with -SubscriptionID
# write one zip per subscription, so each subscription gets its own command. A
# direct run without -SubscriptionID covers every subscription in one zip, so
# it gets the run's own command, with the same scope and settings.
# After a masked run each command is seeded with the dictionary that run saved:
# $DictionaryFile for a direct run, else the one ObfuscationDictionary_*.json
# in the entry's report folder under $ReportRoot (the wrapper). When it cannot
# be found a line says so. One line says which zip the new zip replaces in the
# upload, after a plain run too: uploading both counts the resources twice.
# With -NoAllSubscriptionsZip (the wrapper exits before it makes its outer
# zip) that line names the subscription's zip in its report folder instead.
# A subscription whose zip could not be written (in $Unwritten) has none, so
# its line says no zip was made and that -ResumeFailedOnly collects it again.
# After a run that signed in with -Appid, one line says to add -Appid and
# -Secret, since the commands hold neither; their values are never written.
# A direct run that wrote no zip ($ZipWritten false) has no first zip to
# replace, so that line says the new zip is the report instead.
function Write-MetricsIncompleteRunEnd
{
    param([object[]]$Entries, [string]$TenantID, [System.Collections.IDictionary]$RunParameters, [string]$DictionaryFile, [string]$ReportRoot, [switch]$NoAllSubscriptionsZip, [bool]$ZipWritten = $true, [string[]]$Unwritten = @())

    $List = @(Get-MetricsIncompleteEntries -Entries $Entries)
    if ($List.Count -eq 0) { return $false }
    $Masked = $null -ne $RunParameters -and @($RunParameters.Keys) -contains 'Obfuscate' -and [bool]$RunParameters['Obfuscate']
    $Wrapper = -not [string]::IsNullOrEmpty($ReportRoot)
    $OneSubscription = $null -ne $RunParameters -and @($RunParameters.Keys) -contains 'SubscriptionID' -and -not [string]::IsNullOrEmpty([string]$RunParameters['SubscriptionID'])
    $Advice = [System.Collections.Generic.List[string]]::new()
    $NotFound = [System.Collections.Generic.List[string]]::new()
    if ($Wrapper -or $OneSubscription)
    {
        $Advice.Add('To collect one again, run:')
        foreach ($Entry in $List)
        {
            $Dict = ''
            if ($Masked)
            {
                if (-not [string]::IsNullOrEmpty($DictionaryFile) -and (Test-Path -LiteralPath $DictionaryFile -PathType Leaf))
                {
                    $Dict = $DictionaryFile
                }
                elseif ($Wrapper -and -not [string]::IsNullOrEmpty([string]$Entry.ReportFolder))
                {
                    $Found = @(Get-ChildItem -LiteralPath (Join-Path $ReportRoot ([string]$Entry.ReportFolder)) -Filter 'ObfuscationDictionary_*.json' -File -ErrorAction SilentlyContinue)
                    if ($Found.Count -eq 1) { $Dict = $Found[0].FullName }
                }
                if ([string]::IsNullOrEmpty($Dict))
                {
                    $NotFound.Add(("  The dictionary of the first run was not found for {0} ({1}): pass that run's ObfuscationDictionary_*.json as -ObfuscationDictionary, or the new zip gets new masked ids." -f $Entry.Name, $Entry.Id))
                }
            }
            $Advice.Add('  ' + (Get-MetricsRetryCommand -TenantID $TenantID -SubscriptionId ([string]$Entry.Id) -RunParameters $RunParameters -DictionaryFile $Dict))
        }
    }
    else
    {
        # One zip for every subscription: a command for one of them would make a
        # zip that, uploaded in place of the first, drops all the others.
        $Dict = ''
        if ($Masked)
        {
            if (-not [string]::IsNullOrEmpty($DictionaryFile) -and (Test-Path -LiteralPath $DictionaryFile -PathType Leaf)) { $Dict = $DictionaryFile }
            else { $NotFound.Add("  The dictionary of the first run was not found: pass that run's ObfuscationDictionary_*.json as -ObfuscationDictionary, or the new zip gets new masked ids.") }
        }
        $Advice.Add('To collect them again, run the same command again:')
        $Advice.Add('  ' + (Get-MetricsRetryCommand -TenantID $TenantID -SubscriptionId '' -RunParameters $RunParameters -DictionaryFile $Dict))
    }
    foreach ($Line in $NotFound) { $Advice.Add($Line) }
    if ($null -ne $RunParameters -and @($RunParameters.Keys) -contains 'Appid' -and -not [string]::IsNullOrEmpty([string]$RunParameters['Appid']))
    {
        $Advice.Add('  The first run signed in with -Appid: add -Appid <id> -Secret <secret> to sign in the same way.')
    }
    if ($Wrapper -and $NoAllSubscriptionsZip)
    {
        # A subscription whose zip could not be written ($Unwritten, by its
        # report folder) has no first zip to replace.
        $UnwrittenFolders = @(@($Unwritten) | Where-Object { -not [string]::IsNullOrEmpty($_) } | ForEach-Object { Split-Path -Path (Split-Path -Path $_ -Parent) -Leaf })
        $NoZip = @($List | Where-Object { -not [string]::IsNullOrEmpty([string]$_.ReportFolder) -and $UnwrittenFolders -contains [string]$_.ReportFolder })
        if ($NoZip.Count -gt 0)
        {
            $Advice.Add(("  No zip was made for {0}: its command's zip is that subscription's report, or run the wrapper again with -ResumeFailedOnly, which collects it again." -f (@($NoZip | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Id }) -join ', ')))
        }
        $FolderZip = "Each new zip replaces that subscription's zip in its report folder (no AllSubscriptions_ResourcesReport_*.zip was made): put it there in place of the first one, do not keep both, or its resources are counted twice."
        if ($NoZip.Count -eq 0) { $Advice.Add('  ' + $FolderZip) }
        elseif ($NoZip.Count -lt $List.Count) { $Advice.Add('  For the others: ' + $FolderZip) }
    }
    elseif ($Wrapper)
    {
        $Advice.Add("  Each new zip replaces that subscription's inner zip in the AllSubscriptions_ResourcesReport_*.zip: swap it in for the first one, do not add it next to it, or its resources are counted twice.")
    }
    elseif (-not $ZipWritten)
    {
        $Advice.Add('  This run made no zip, so there is no first zip to replace: the new zip is the report to upload.')
    }
    elseif ($OneSubscription)
    {
        $Advice.Add("  Each new zip replaces that subscription's zip in the upload: upload it instead of the first one, not as well, or its resources are counted twice.")
    }
    else
    {
        $Advice.Add('  The new zip replaces the whole first zip in the upload: upload it instead of the first one, not as well, or every resource is counted twice.')
    }
    Write-MetricsIncompleteBanner -Entries $List -Advice @($Advice)
    return $true
}

# The exit code at the end of a direct ResourceInventory.ps1 run (not under
# -RunAllSubs, where the wrapper decides): 2 when its report zip was not
# written ($ZipWritten false, also when a partial zip is left), which wins; 3 when metrics or consumption
# ($ConsumptionEntries, this run's entries) were skipped because the sign-in
# could not be refreshed, after a short FAILED (auth) line, or when its metrics
# are incomplete, after the FAILED (metrics) lines; 0 otherwise. With no zip
# the lines are still printed, after the run's own "No report was written" line.
function Get-DirectRunMetricsExitCode
{
    param([object[]]$Entries, [string]$TenantID, [System.Collections.IDictionary]$RunParameters, [bool]$ZipWritten, [string]$DictionaryFile, [object[]]$ConsumptionEntries = @())

    $AuthSkipped = @(@($Entries) | Where-Object { $null -ne $_ -and -not (Test-MetricsIncompleteEntry -Entry $_) } | Sort-Object Name, Id -Unique)
    # Consumption skipped for the sign-in is the '(auth)' entry of this run.
    $ConsumptionAuthSkipped = @(@($ConsumptionEntries) | Where-Object { $null -ne $_ -and [string]$_.Id -eq '(auth)' }).Count -gt 0
    $Phases = @()
    if ($AuthSkipped.Count -gt 0) { $Phases += ('Metrics for {0} subscription(s)' -f $AuthSkipped.Count) }
    if ($ConsumptionAuthSkipped) { $Phases += 'Consumption' }
    if ($Phases.Count -gt 0)
    {
        Write-Host ''
        Write-Host '===================== FAILED (auth) =====================' -ForegroundColor Red
        Write-Host ('Could not collect: {0}. Reason: no usable Azure context/token (even after one reconnect attempt).' -f ($Phases -join ' and ')) -ForegroundColor Red
        Write-Host 'Fix: sign in again (Connect-AzAccount), then run the same command again.' -ForegroundColor Red
        Write-Host '=========================================================' -ForegroundColor Red
    }
    $Incomplete = Write-MetricsIncompleteRunEnd -Entries $Entries -TenantID $TenantID -RunParameters $RunParameters -DictionaryFile $DictionaryFile -ZipWritten $ZipWritten
    if (-not $ZipWritten) { return 2 }
    if ($Incomplete -or $Phases.Count -gt 0) { return 3 }
    return 0
}
