#Requires -Version 7.0

# Run-AllSubscriptions.Stream.ps1
#
# Worker script invoked by Run-AllSubscriptions.ps1 when -ParallelStreams > 1.
# Each instance of this worker:
#   - Runs as a separate `pwsh` background job (fresh process, fresh AppDomain).
#   - Owns its own slice of the subscription list.
#   - Owns its own resume-state file (.resume-state-<TenantID>-stream-<N>.json),
#     so the streams cannot race on a shared file.
#   - Imports an Az PowerShell context from a shared snapshot file written by
#     the parent wrapper, so authentication is not re-prompted per stream.
#   - Calls ResourceInventory.ps1 once per subscription in its slice.
#   - Emits structured progress lines to stdout (prefixed [stream-N]) so the
#     parent wrapper can collate output across streams.
#   - Writes a per-stream JSON summary at the end so the parent can aggregate
#     resource counts, consumption results, and failures into the final
#     wrapper-level summary.
#
# Start-Job runs this script block in a fresh runspace (separate process) where
# the parent's functions and variables are NOT in scope, so the wrapper passes
# everything via explicit parameters. Shared helper functions are dot-sourced
# below from this worker's OWN $PSScriptRoot (Functions/RunAllSubscriptions.Functions.ps1)
# - the same file the parent loads - rather than inherited from the parent.

param (
    [Parameter(Mandatory = $true)] [string]   $TenantID,
    # The wrapper run's id, written in the summary so the wrapper accepts only
    # its own run's summaries.
    [Parameter(Mandatory = $true)] [string]   $RunId,
    [Parameter(Mandatory = $true)] [string]   $StreamId,
    [Parameter(Mandatory = $true)] [string]   $InventoryRoot,
    [Parameter(Mandatory = $true)] [string]   $ScriptRoot,
    [Parameter(Mandatory = $true)] [string]   $AzContextPath,
    [Parameter(Mandatory = $true)] [string]   $StreamSummaryPath,
    [Parameter(Mandatory = $true)] [string]   $StreamFailuresPath,
    # SubscriptionIds / SubscriptionNames are intentionally NOT Mandatory.
    # PowerShell rejects empty arrays passed to Mandatory [string[]] params,
    # which would hard-fail the worker before any logging runs. The parent
    # currently guarantees non-empty slices via [Math]::Min(StreamCount, subs)
    # but a future change to the slicing logic should not silently break the
    # worker's binding. Default to @() and guard the body explicitly.
    [string[]] $SubscriptionIds = @(),
    [string[]] $SubscriptionNames = @(),
    # The parent's retry-list entries for this slice ({ Id, Name, LastFailedAt,
    # Reason, Attempts }). [object] for the same single-element collapse as
    # Add-FailedAttempt's -Existing.
    [object] $PriorFailedAttempts = @(),

    [switch] $Resume,
    # The parent already narrowed $SubscriptionIds to just the failed subs
    # before starting this worker, so the worker does no filtering of its own.
    # This flag is passed in only so the worker can note "failed-only mode" in
    # its summary, and so it's already wired up if the parent ever needs it.
    [switch] $ResumeFailedOnly,
    [switch] $DeviceLogin,
    [switch] $Obfuscate,
    [switch] $SkipMetrics,
    [switch] $SkipConsumption,
    [int]    $ConcurrencyLimit = 6,
    # The parent's consumption window ('yyyy-MM-dd'), forwarded to every
    # ResourceInventory.ps1 so each collects the window the parent checked.
    [string] $ConsumptionWindowStart,
    [string] $ConsumptionWindowEnd
)

# ---------------------------------------------------------------------------
# Load shared helper functions. Dot-sourced (NOT invoked via &) so they load
# into this script's scope. Fail loud if the file is missing rather than
# breaking later with a confusing "command not found".
# ---------------------------------------------------------------------------
$FunctionsFile = Join-Path $PSScriptRoot 'Functions/RunAllSubscriptions.Functions.ps1'
if (-not (Test-Path -LiteralPath $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

# The supported Az.Accounts version (Get-RdaAzAccountsMinimumVersion). The
# wrapper stops when this file is missing, but the worker checks too: without
# it, it would load any Az.Accounts and make Azure calls with it.
$AzModulesFunctionsFile = Join-Path $PSScriptRoot 'Functions/AzModules.Functions.ps1'
if (-not (Test-Path -LiteralPath $AzModulesFunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $AzModulesFunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $AzModulesFunctionsFile

# Tag used to prefix all stdout lines so the parent wrapper can demultiplex
# interleaved output across streams.
$Tag = "[stream-$StreamId]"


# Empty slice = nothing to do. Write a minimal "ok with zero subs" summary so
# the parent's aggregation step (which expects a summary file from every
# stream) does not flag this as a missing-summary failure, and exit cleanly.
if ($SubscriptionIds.Count -eq 0)
{
    Write-Stream "no subscriptions in slice; exiting cleanly" 'Yellow'
    # -ErrorAction Stop: a failed write is otherwise a non-terminating error,
    # and the worker would end with exit 0 and no summary.
    try
    {
        @{
            RunId                 = $RunId
            StreamId              = $StreamId
            Tenant                = $TenantID
            Status                = 'ok'
            SubsProcessed         = 0
            Completed             = @()
            Failed                = @()
            Skipped               = @()
            NoReport              = @()
            Incomplete            = @()
            NotAttempted          = @()
            ResourceCounts        = @()
            ConsumptionRecords    = 0
            ConsumptionFailedSubs = @()
            MetricsFailedSubs     = @()
            CollectorFailures     = @()
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StreamSummaryPath -Encoding utf8 -ErrorAction Stop
    }
    catch
    {
        Write-Stream ("FATAL: could not write stream summary to {0}: {1}" -f $StreamSummaryPath, $_.Exception.Message) 'Red'
        exit 1
    }
    exit 0
}

Write-Stream ("starting; subs in slice: {0}" -f $SubscriptionIds.Count) 'Cyan'

# ---- Az context import -------------------------------------------------------
#
# The parent wrapper called Save-AzContext on its already-authenticated session
# and passed us the path. Importing it gives this child process a working Az
# context without prompting for sign-in. Import-AzContext is idempotent.
try
{
    # -MinimumVersion, as in the wrapper: a plain import takes the first copy
    # in PSModulePath order, which can be older than the supported one.
    Import-Module Az.Accounts -MinimumVersion (Get-RdaAzAccountsMinimumVersion) -ErrorAction Stop -Force | Out-Null
    # Prevent the imported context from being persisted to the user's on-disk
    # AzureRmContext.json. Without this, every parallel worker writes its
    # token cache to the same shared profile and the streams race on disk
    # state. Process-scope auto-save is per-process, so calling it here
    # confines this worker's context to in-memory.
    try { Disable-AzContextAutosave -Scope Process -ErrorAction Stop | Out-Null }
    catch { Write-Stream ("WARNING: could not disable AzContext autosave: {0}" -f $_.Exception.Message) 'Yellow' }
    Import-AzContext -Path $AzContextPath -ErrorAction Stop | Out-Null
    Write-Stream "Az context imported from shared snapshot" 'Green'
}
catch
{
    Write-Stream ("FATAL: could not import Az context from {0}: {1}" -f $AzContextPath, $_.Exception.Message) 'Red'
    $ImportError = $_.Exception.Message
    # Under -Resume the stream would have skipped the subscriptions its own
    # resume file lists as completed, so they are not failed this run and get
    # no row. A file that cannot be read skips none (Read-StreamState), as in
    # the loop below.
    $PriorDone = @()
    if ($Resume)
    {
        $PriorDone = @((Read-StreamState -Path (Join-Path $InventoryRoot (".resume-state-{0}-stream-{1}.json" -f $TenantID, $StreamId))).Completed)
    }
    # Write a minimum stream summary so the parent doesn't think the stream
    # disappeared silently. -ErrorAction Stop, so a failed write is named.
    try
    {
        @{
            RunId         = $RunId
            StreamId      = $StreamId
            Tenant        = $TenantID
            Status        = 'failed-to-start'
            Reason        = $ImportError
            Completed     = @()
            Failed        = @(0..([Math]::Max($SubscriptionIds.Count, $SubscriptionNames.Count) - 1) | ForEach-Object {
                    $Name = if ($_ -lt $SubscriptionNames.Count) { $SubscriptionNames[$_] } else { '<unknown>' }
                    $Id = if ($_ -lt $SubscriptionIds.Count) { $SubscriptionIds[$_] }   else { '<unknown>' }
                    [pscustomobject]@{ Id = $Id; Name = $Name; Reason = 'stream did not start: Az context import failed' }
                } | Where-Object { $PriorDone -notcontains $_.Id })
            # Every property of the full summary, so the wrapper reads it under
            # Set-StrictMode too.
            SubsProcessed         = 0
            Skipped               = @()
            NoReport              = @()
            Incomplete            = @()
            NotAttempted          = @()
            ResourceCounts        = @()
            ConsumptionRecords    = 0
            ConsumptionFailedSubs = @()
            MetricsFailedSubs     = @()
            CollectorFailures     = @()
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StreamSummaryPath -Encoding utf8 -ErrorAction Stop
    }
    catch
    {
        Write-Stream ("FATAL: could not write stream summary to {0}: {1}" -f $StreamSummaryPath, $_.Exception.Message) 'Red'
    }
    exit 1
}

# ---- Per-stream resume state -------------------------------------------------
#
# Each stream owns a separate file. No races, no locking, simple semantics.
$StreamStateFile = Join-Path $InventoryRoot (".resume-state-{0}-stream-{1}.json" -f $TenantID, $StreamId)





$CompletedIds = @()
$FailedAttempts = @()
# The report zip recorded per completed sub (New-CompletedReportRecord), kept in
# this stream's state so the parent can carry it on a later -Resume.
$Reports = @()
if ($Resume -or $ResumeFailedOnly)
{
    $State = Read-StreamState -Path $StreamStateFile
    $CompletedIds = $State.Completed
    $FailedAttempts = $State.Failed
    $Reports = @($State.Reports)
    if ($CompletedIds.Count -gt 0)
    {
        Write-Stream ("resume: skipping {0} previously-completed subs in this slice" -f $CompletedIds.Count) 'DarkGray'
    }
    if ($ResumeFailedOnly -and $FailedAttempts.Count -gt 0)
    {
        Write-Stream ("resume-failed-only: prior FailedAttempts list has {0} entry(ies) for this stream" -f $FailedAttempts.Count) 'DarkGray'
    }
}
# Start from the parent's retry-list entries, so a failure here counts one more
# run on top of the earlier ones instead of starting again at one. The newer
# entry wins where this stream's own state file has the same subscription.
$Prior = @(@($PriorFailedAttempts) | Where-Object { $null -ne $_ })
if ($Prior.Count -gt 0)
{
    $FailedAttempts = @(Merge-FailedAttempts -ExistingFailedAttempts $Prior -StreamFailedAttempts $FailedAttempts -CompletedIds @())
}

# ---- Build the inner-script passthrough --------------------------------------
$InventoryPassthrough = @{}
if ($DeviceLogin) { $InventoryPassthrough['DeviceLogin'] = $true }
if ($Obfuscate) { $InventoryPassthrough['Obfuscate'] = $true }
if ($SkipMetrics) { $InventoryPassthrough['SkipMetrics'] = $true }
if ($SkipConsumption) { $InventoryPassthrough['SkipConsumption'] = $true }
$InventoryPassthrough['ConcurrencyLimit'] = $ConcurrencyLimit
if (-not [string]::IsNullOrEmpty($ConsumptionWindowStart)) { $InventoryPassthrough['ConsumptionWindowStart'] = $ConsumptionWindowStart }
if (-not [string]::IsNullOrEmpty($ConsumptionWindowEnd)) { $InventoryPassthrough['ConsumptionWindowEnd'] = $ConsumptionWindowEnd }

# ---- Per-sub iteration -------------------------------------------------------
#
# This is the same shape as the wrapper's existing loop: invoke the inner
# script via `&`, capture $Global:ResourceCount / $Global:Consumption* afterward,
# and record a per-sub status row for the wrapper to aggregate.

$ResourceCounts = @()
# Plain string array. We never call .Add() on this — only `+=`, which creates a
# new array each time. Cheaper than fighting [List[T]]::new() constructor
# overload resolution against an empty PowerShell array argument.
$Completed = @($CompletedIds)
$FailedSubs = @()
# Subs this stream skipped on -Resume as completed (its own file of this run
# lists them). None today: the parent's pre-filter gives a stream only subs not
# done, and this file is new each run. A sub skipped here would count as done
# only through that same file of this run with its report record (the parent's
# merge rule), and its report would be carried.
$SkippedSubs = @()
# Subs this stream collected without a zip being written; reported in the
# summary so the parent takes them off the unified completed list.
$NoReportSubs = @()
# Subs this stream collected with metrics or consumption left incomplete; they
# are in the retry list, and the summary names them so the parent also takes
# them off the unified completed list.
$IncompleteSubs = @()
# Subs this stream did not collect because it could not save its write-ahead count.
$NotAttemptedSubs = @()

# The inner script's $Global:ConsumptionRecordCount / $Global:ConsumptionFailedSubs
# are *running totals*: ResourceInventory.ps1 only nil-initializes them once and
# then accumulates with += across every subscription it processes in this
# worker's scope. Reset them to known-zero state up-front so the worker reads
# the entire-slice running total once after the loop, instead of summing
# per-iteration snapshots (which would double-count: 100, 300, 600 for three
# 100-record subs).
$Global:ConsumptionRecordCount = 0
$Global:ConsumptionFailedSubs = @()

# Per-subscription metrics-phase auth health. ResourceInventory.ps1 appends to
# $Global:MetricsFailedSubs (in this worker's scope, since it is invoked via `&`)
# for each sub whose metrics phase was skipped because no usable Azure
# context/token could be established. Reset up-front so a stale value cannot leak
# in; read once after the slice loop and reported in the summary JSON.
$Global:MetricsFailedSubs = @()

# Per-subscription collector failures (#22). ResourceInventory.ps1 appends to
# $Global:CollectorFailures (in this worker's scope, since it is invoked via `&`)
# each time one of the Services/*/*.ps1 collectors throws for a subscription.
# Same reset/aggregate/report lifecycle as $Global:MetricsFailedSubs above.
$Global:CollectorFailures = @()

$PairCount = [Math]::Min($SubscriptionIds.Count, $SubscriptionNames.Count)
for ($i = 0; $i -lt $PairCount; $i++)
{
    $SubId = $SubscriptionIds[$i]
    $SubName = $SubscriptionNames[$i]

    if ($Resume -and ($Completed -contains $SubId))
    {
        Write-Stream ("skipping (already completed): {0} ({1})" -f $SubName, $SubId) 'DarkGray'
        $SkippedSubs += [pscustomobject]@{ Id = $SubId; Name = $SubName }
        continue
    }

    # Write-ahead count (fail-safe rule, see the wrapper): one more failed run of
    # the sub is written to this stream's state file, and read back, before it
    # is collected; only a good result takes it away, and a failure only sets
    # the reason. If the file does not hold it, the sub is not collected this
    # run (NotAttempted: the parent counts nothing for it and names it).
    $Undo = @{ Failed = $FailedAttempts; Completed = $Completed; Reports = $Reports }
    $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts -Id $SubId -Name $SubName -Reason 'its collection started and no result was saved'
    $WantCount = Get-FailedAttemptCount -Entry @($FailedAttempts | Where-Object { $_.Id -eq $SubId })[0]
    $Completed = @($Completed | Where-Object { $_ -ne $SubId })
    $Reports = @($Reports | Where-Object { $null -ne $_ -and [string]$_.Id -ne $SubId })
    Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts -Reports $Reports
    $Back = Read-StreamState -Path $StreamStateFile
    $BackEntry = @($Back.Failed | Where-Object { $null -ne $_ -and [string]$_.Id -eq $SubId })
    if ($BackEntry.Count -eq 0 -or (Get-FailedAttemptCount -Entry $BackEntry[0]) -ne $WantCount)
    {
        Write-Stream ("ERROR: could not save this stream's state before collecting {0}, so it is not collected this run" -f $SubName) 'Red'
        $NotAttemptedSubs += [pscustomobject]@{ Id = $SubId; Name = $SubName; Reason = "its stream could not save its state before collecting it, so it was not collected; free disk space or fix the folder, then run again" }
        # Not collected, so nothing about it changes (a later save of this
        # file must not carry its count or drop its completion).
        $FailedAttempts = $Undo.Failed
        $Completed = $Undo.Completed
        $Reports = $Undo.Reports
        continue
    }

    Write-Stream ("processing ({0} of {1}): {2} ({3})" -f ($i + 1), $PairCount, $SubName, $SubId) 'Cyan'

    try
    {
        # ResourceInventory.ps1 ends without `exit` when it succeeds, and that
        # leaves $LASTEXITCODE as it was: the `exit 1` of an earlier
        # subscription in this stream would mark this one failed.
        $global:LASTEXITCODE = 0
        # Cleared too, so a run that ends before naming its zip cannot leave
        # the previous subscription's zip as its own.
        $Global:ZipOutputFile = $null
        # Counted before the call, so Get-IncompleteDataReason sees only what this call appends.
        $MetricsGapsBefore = @($Global:MetricsFailedSubs | Where-Object { $null -ne $_ }).Count
        $ConsumptionGapsBefore = @($Global:ConsumptionFailedSubs | Where-Object { $null -ne $_ }).Count
        & (Join-Path $ScriptRoot 'ResourceInventory.ps1') -TenantID $TenantID -SubscriptionID $SubId @InventoryPassthrough -RunAllSubs
        # Only treat as failure if the inner script set a non-zero exit code.
        # Some completion paths in ResourceInventory.ps1 leave $LASTEXITCODE
        # unset ($null), and PowerShell's `-ne 0` returns $true against $null,
        # which would spuriously fail every successful sub.
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Script exited with code $LASTEXITCODE" }

        # Capture inner-script globals while we are still in the same scope.
        # ResourceInventory.ps1 is invoked via `&` so its $Global:ResourceCount lives
        # in this stream worker's scope. The inner script resets $Global:ResourceCount
        # to 0 at the start of every invocation.
        $ResCount = if ($null -ne $Global:ResourceCount) { $Global:ResourceCount } else { 0 }
        # Zip: the report zip this run wrote, which the wrapper's output
        # verification looks for.
        $ResourceCounts += [pscustomobject]@{ Name = $SubName; Id = $SubId; Count = $ResCount; Zip = $Global:ZipOutputFile }

        # Narration only, as in the wrapper: a failed write must not turn the
        # success into a failure (the subscription would be listed as both).
        try
        {
            if ($ResCount -eq 0)
            {
                Write-Stream ("WARNING: '{0}' returned 0 resources (likely permission gap or empty sub)" -f $SubName) 'Yellow'
            }
            else
            {
                Write-Stream ("done: {0} - {1:N0} resources" -f $SubName, $ResCount) 'Green'
            }
        }
        catch
        {
            # Its own guard, as in the wrapper.
            $NarrationError = $_.Exception.Message
            try { Write-Verbose ("Could not write the completion line: {0}" -f $NarrationError) }
            catch { $null = $_ }
        }

        # Record the zip this run wrote, replacing any earlier record for the sub.
        $NewReport = New-CompletedReportRecord -InventoryRoot $InventoryRoot -Id $SubId -Name $SubName -ZipPath $Global:ZipOutputFile -Obfuscated ([bool]$Obfuscate)
        if ($null -ne $NewReport)
        {
            $Reports = @(@($Reports | Where-Object { $null -ne $_ -and [string]$_.Id -ne $SubId }) + $NewReport)
        }
        $IncompleteReason = Get-IncompleteDataReason -MetricsEntries $Global:MetricsFailedSubs -MetricsBefore $MetricsGapsBefore -ConsumptionEntries $Global:ConsumptionFailedSubs -ConsumptionBefore $ConsumptionGapsBefore

        if ($null -eq $NewReport)
        {
            # The run left no zip, so there is no report a later -Resume could
            # carry: the sub is not completed. Named in the summary so the parent
            # also ends an earlier run's completion of it in the unified state.
            $NoReportSubs += [pscustomobject]@{ Id = $SubId; Name = $SubName }
            # The write-ahead step counted this failed run and took any earlier
            # completion out; only the reason is set.
            $FailedAttempts = Set-FailedAttemptReason -Existing $FailedAttempts -Id $SubId -Name $SubName -Reason 'it left no report zip, so it is collected again'
            Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts -Reports $Reports
        }
        elseif ($null -ne $IncompleteReason)
        {
            # Same as the parent's sequential branch: the report was written
            # without some of its metrics or consumption, so the sub goes into
            # the retry list instead of the completed list. The write-ahead step
            # counted this run; only the reason is set.
            Write-Stream ("{0} It stays in the retry list, so -Resume or -ResumeFailedOnly collects '{1}' again." -f $IncompleteReason, $SubName) 'Yellow'
            $IncompleteSubs += [pscustomobject]@{ Id = $SubId; Name = $SubName; Reason = $IncompleteReason }
            $Reports = @($Reports | Where-Object { $null -ne $_ -and [string]$_.Id -ne $SubId })
            $FailedAttempts = Set-FailedAttemptReason -Existing $FailedAttempts -Id $SubId -Name $SubName -Reason $IncompleteReason
            Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts -Reports $Reports
        }
        else
        {
            # The good result and its report are saved in this file, so the
            # write-ahead count goes with it: a parent cut off before its merge
            # leaves a completion the start-up fold takes (#38), and a sub this
            # stream did not finish keeps its count (#68).
            $Completed += $SubId
            $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $SubId
            Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts -Reports $Reports
        }
    }
    catch
    {
        $ErrRecord = $_
        Write-Stream ("ERROR processing {0}: {1}" -f $SubName, $ErrRecord.Exception.Message) 'Red'

        # Build a structured failure record. Append to a per-stream failures log
        # so per-sub diagnostic detail survives even when many subs fail in one
        # stream. Mirrors the parent wrapper's diag-log shape.
        $DiagLines = @()
        $DiagLines += "==== Failure for subscription: $SubName ($SubId) [$Tag] ===="
        $DiagLines += "Timestamp: $(Get-Date -Format 'o')"
        $DiagLines += "Message:   $($ErrRecord.Exception.Message)"
        $DiagLines += "Type:      $($ErrRecord.Exception.GetType().FullName)"
        $Inner = $ErrRecord.Exception.InnerException
        $Depth = 0
        while ($null -ne $Inner -and $Depth -lt 5)
        {
            $DiagLines += "Inner[$Depth] Type:    $($Inner.GetType().FullName)"
            $DiagLines += "Inner[$Depth] Message: $($Inner.Message)"
            $Inner = $Inner.InnerException
            $Depth++
        }
        if ($null -ne $ErrRecord.InvocationInfo)
        {
            $DiagLines += "ScriptName:    $($ErrRecord.InvocationInfo.ScriptName)"
            $DiagLines += "Line:          $($ErrRecord.InvocationInfo.ScriptLineNumber)"
            $DiagLines += "PositionMsg:   $($ErrRecord.InvocationInfo.PositionMessage)"
        }
        $DiagLines += "StackTrace:"
        $DiagLines += $ErrRecord.ScriptStackTrace
        if ($null -ne $ErrRecord.Exception.StackTrace)
        {
            $DiagLines += "ExceptionStackTrace:"
            $DiagLines += $ErrRecord.Exception.StackTrace
        }
        $DiagLines += ""

        try { $DiagLines | Out-File -LiteralPath $StreamFailuresPath -Append -Encoding utf8 }
        catch { Write-Stream ("could not write to stream failures log {0}: {1}" -f $StreamFailuresPath, $_.Exception.Message) 'Yellow' }

        $FailedSubs += [pscustomobject]@{ Id = $SubId; Name = $SubName; Reason = $ErrRecord.Exception.Message }
        # Persist the failure to the per-stream state file. The parent
        # wrapper will fold these entries into the unified FailedAttempts
        # list when it merges per-stream state at run end. Persisting on
        # every failure (rather than only at end-of-stream) means a worker
        # that is killed mid-slice still surfaces its partial failure
        # history to the next -ResumeFailedOnly invocation.
        # The write-ahead step counted this failed run; only the reason is set.
        $FailedAttempts = Set-FailedAttemptReason -Existing $FailedAttempts `
            -Id $SubId -Name $SubName -Reason $ErrRecord.Exception.Message
        # The write-ahead step already took any earlier completion of it out,
        # so the file and the summary do not list it as both.
        Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts -Reports $Reports
    }
}

# ---- Per-stream summary ------------------------------------------------------
#
# Single JSON file the parent wrapper aggregates across all streams.
#
# Read the consumption totals from the inner-script globals once, here, after
# the entire slice has been processed. The inner script accumulates these
# across all subs in this worker's scope (see the reset at the top of the
# loop), so a single read at the end gives the correct slice total without
# the per-iteration double-counting trap.
$ConsumptionTotal = if ($null -ne $Global:ConsumptionRecordCount) { [int]$Global:ConsumptionRecordCount } else { 0 }
$ConsumptionFailedSubs = if ($null -ne $Global:ConsumptionFailedSubs) { @($Global:ConsumptionFailedSubs) } else { @() }
$MetricsFailedSubs = if ($null -ne $Global:MetricsFailedSubs) { @($Global:MetricsFailedSubs) } else { @() }
$CollectorFailures = if ($null -ne $Global:CollectorFailures) { @($Global:CollectorFailures) } else { @() }
# One row per Id, Name, Message and SubscriptionId (the '(auth)' sign-in
# row's own subscription), first seen kept, in order: the rows are objects,
# and Select-Object -Unique sees two of them as one.
$SeenConsumptionFailure = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$ConsumptionFailedSubs = @($ConsumptionFailedSubs | Where-Object { $SeenConsumptionFailure.Add(('{0}|{1}|{2}|{3}' -f $_.Id, $_.Name, $_.Message, $_.SubscriptionId)) })

$Summary = [pscustomobject]@{
    RunId                  = $RunId
    StreamId               = $StreamId
    Tenant                 = $TenantID
    Status                 = if ($FailedSubs.Count -eq 0) { 'ok' } else { 'partial-failure' }
    SubsProcessed          = $PairCount
    Completed              = @($Completed)
    Failed                 = $FailedSubs
    Skipped                = @($SkippedSubs)
    NoReport               = @($NoReportSubs)
    Incomplete             = @($IncompleteSubs)
    NotAttempted           = @($NotAttemptedSubs)
    ResourceCounts         = $ResourceCounts
    ConsumptionRecords     = $ConsumptionTotal
    # Every entry (one per subscription). Not Select-Object -Unique: it treats any
    # two of these objects as equal, which would keep only the first.
    ConsumptionFailedSubs  = @($ConsumptionFailedSubs)
    MetricsFailedSubs      = @($MetricsFailedSubs)
    CollectorFailures      = @($CollectorFailures)
}
try
{
    # -ErrorAction Stop: a failed write is otherwise a non-terminating error
    # that skips this catch, and the worker said "complete" with exit 0.
    $Summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StreamSummaryPath -Encoding utf8 -ErrorAction Stop
}
catch
{
    Write-Stream ("FATAL: could not write stream summary to {0}: {1}" -f $StreamSummaryPath, $_.Exception.Message) 'Red'
    exit 1
}

Write-Stream ("complete: {0}/{1} succeeded, {2} failed" -f $Completed.Count, $PairCount, $FailedSubs.Count) 'Green'
exit 0
