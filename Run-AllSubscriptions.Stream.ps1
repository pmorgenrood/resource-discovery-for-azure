#Requires -Version 7.0

# Run-AllSubscriptions.Stream.ps1
#
# Worker script invoked by Run-AllSubscriptions.ps1 when -ParallelStreams > 1.
# Each instance of this worker:
#   - Runs as a separate `pwsh` background job (fresh process, fresh AppDomain).
#   - Owns its own slice of the subscription list.
#   - Owns its own resume-state file (.resume-state-<tenant key>-stream-<N>.json),
#     so the streams cannot race on a shared file.
#   - Imports an Az PowerShell context from its own snapshot file written by
#     the parent wrapper, so authentication is not re-prompted per stream,
#     and deletes that file once read.
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
    [switch] $IncludeNetworkResources,
    [int]    $ConcurrencyLimit = 6,
    # The parent's consumption window ('yyyy-MM-dd'), forwarded to every
    # ResourceInventory.ps1 so each collects the window the parent checked.
    [string] $ConsumptionWindowStart,
    [string] $ConsumptionWindowEnd,
    # The parent run's id: written into this stream's state file, and an
    # existing file is read on -Resume only when it carries the same id.
    [string] $RunId = '',
    # The parent run's record (start time, settings, cost window) as JSON:
    # written into this stream's state file with its lists (Write-StreamState).
    [string] $RunRecordJson = ''
)

# ---------------------------------------------------------------------------
# Load shared helper functions. Dot-sourced (NOT invoked via &) so they load
# into this script's scope. Fail loud if the file is missing rather than
# breaking later with a confusing "command not found".
# ---------------------------------------------------------------------------
$FunctionsFile = Join-Path $PSScriptRoot 'Functions/RunAllSubscriptions.Functions.ps1'
if (-not (Test-Path -Path $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

# The per-subscription count line (Get-RdaResourceCountMessage) is shared with
# the wrapper and the inner script.
$CommonFunctionsFile = Join-Path $PSScriptRoot 'Functions/Common.Functions.ps1'
if (-not (Test-Path -Path $CommonFunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $CommonFunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $CommonFunctionsFile

# The supported Az.Accounts version (Get-RdaAzAccountsMinimumVersion). The
# wrapper already stopped when this file is missing; it only defines functions.
$AzModulesFunctionsFile = Join-Path $PSScriptRoot 'Functions/AzModules.Functions.ps1'
if (Test-Path -LiteralPath $AzModulesFunctionsFile -PathType Leaf)
{
    . $AzModulesFunctionsFile
}

# The parent run's record for Write-StreamState; a stream started without one
# writes none.
$StreamRunRecord = $null
if (-not [string]::IsNullOrWhiteSpace($RunRecordJson))
{
    try { $StreamRunRecord = $RunRecordJson | ConvertFrom-Json -ErrorAction Stop } catch { $StreamRunRecord = $null }
}

# Tag used to prefix all stdout lines so the parent wrapper can demultiplex
# interleaved output across streams.
$Tag = "[stream-$StreamId]"


# Empty slice = nothing to do. Write a minimal "ok with zero subs" summary so
# the parent's aggregation step (which expects a summary file from every
# stream) does not flag this as a missing-summary failure, and exit cleanly.
if ($SubscriptionIds.Count -eq 0)
{
    Write-Stream "no subscriptions in slice; exiting cleanly" 'Yellow'
    # This stream never imports its Az context snapshot, so delete it now.
    foreach ($Failure in @(Remove-AzContextSnapshot -Path $AzContextPath))
    {
        Write-Stream ("WARNING: could not remove Az context snapshot at {0}: {1}. It holds an Azure token cache; remove it with: {2}" -f $Failure.Path, $Failure.Message, (Get-RemoveFileCommand -Path $Failure.Path)) 'Yellow'
    }
    @{
        StreamId              = $StreamId
        Tenant                = $TenantID
        Status                = 'ok'
        SubsProcessed         = 0
        Completed             = @()
        Failed                = @()
        ResourceCounts        = @()
        ConsumptionRecords    = 0
        ConsumptionFailedSubs = @()
        MetricsFailedSubs     = @()
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $StreamSummaryPath -Encoding utf8
    exit 0
}

Write-Stream ("starting; subs in slice: {0}" -f $SubscriptionIds.Count) 'Cyan'

# ---- Az context import -------------------------------------------------------
#
# The parent wrapper called Save-AzContext on its already-authenticated session
# and passed us the path of this stream's own copy. Importing it gives this
# child process a working Az context without prompting for sign-in. The file
# holds a token cache and nothing reads it again, so it is deleted in the
# `finally`, whether the import worked or not.
$ImportStep = 'module'
try
{
    # -MinimumVersion, as in the wrapper: a plain import takes the first copy
    # in PSModulePath order, which can be older than the supported one.
    # Without Functions/AzModules.Functions.ps1 (the wrapper stops before it
    # starts a stream then) any version is taken, as before.
    $AzAccountsMinimum = [version]'0.0'
    if (Get-Command -Name Get-RdaAzAccountsMinimumVersion -CommandType Function -ErrorAction SilentlyContinue)
    {
        $AzAccountsMinimum = Get-RdaAzAccountsMinimumVersion
    }
    Import-Module Az.Accounts -MinimumVersion $AzAccountsMinimum -ErrorAction Stop -Force | Out-Null
    # The imported context and its token cache must stay in this process's
    # memory. With autosave on, Import-AzContext also writes them to the user's
    # Az profile files (AzureRmContext.json and the token cache file), where
    # they outlive this stream's snapshot and every stream writes to the same
    # files. So the snapshot is imported only once autosave is confirmed off
    # for this process.
    $ImportStep = 'autosave'
    $AutosaveError = $null
    try { Disable-AzContextAutosave -Scope Process -ErrorAction Stop | Out-Null }
    catch { $AutosaveError = $_.Exception.Message }
    $AutosaveCheck = Get-AzContextAutosaveCheck
    if (-not $AutosaveCheck.Disabled)
    {
        $Detail = if ($AutosaveError) { 'Disable-AzContextAutosave failed: {0}; {1}' -f $AutosaveError, $AutosaveCheck.Detail } else { $AutosaveCheck.Detail }
        throw ("Az context autosave could not be turned off for this stream ({0}), so its Az context snapshot was not imported: importing it would write the token cache to the user's Az profile files." -f $Detail)
    }
    $ImportStep = 'import'
    Import-AzContext -Path $AzContextPath -ErrorAction Stop | Out-Null
    Write-Stream "Az context imported from snapshot" 'Green'
}
catch
{
    $Reason = $_.Exception.Message
    if ($ImportStep -eq 'autosave')
    {
        Write-Stream ("FATAL: {0} Its subscriptions are reported as failed; run with -ParallelStreams 1 to collect them without stream workers." -f $Reason) 'Red'
        $SubReason = 'stream did not start: Az context autosave could not be turned off'
    }
    elseif ($ImportStep -eq 'module')
    {
        Write-Stream ("FATAL: could not load the Az.Accounts module: {0}" -f $Reason) 'Red'
        $SubReason = 'stream did not start: the Az.Accounts module could not be loaded'
    }
    else
    {
        Write-Stream ("FATAL: could not import Az context from {0}: {1}" -f $AzContextPath, $Reason) 'Red'
        $SubReason = 'stream did not start: Az context import failed'
    }
    # Write a minimum stream summary so the parent doesn't think the stream
    # disappeared silently.
    @{
        StreamId      = $StreamId
        Tenant        = $TenantID
        Status        = 'failed-to-start'
        Reason        = $Reason
        # The step that stopped the stream: 'module' (Az.Accounts did not
        # load), 'autosave' or 'import' (its Az context snapshot was not
        # loaded). The parent counts no failed run for the last two.
        FailedStep    = $ImportStep
        Completed     = @()
        Failed        = @(0..([Math]::Max($SubscriptionIds.Count, $SubscriptionNames.Count) - 1) | ForEach-Object {
                $Name = if ($_ -lt $SubscriptionNames.Count) { $SubscriptionNames[$_] } else { '<unknown>' }
                $Id = if ($_ -lt $SubscriptionIds.Count) { $SubscriptionIds[$_] }   else { '<unknown>' }
                [pscustomobject]@{ Id = $Id; Name = $Name; Reason = $SubReason }
            })
        ResourceCounts = @()
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $StreamSummaryPath -Encoding utf8
    exit 1
}
finally
{
    foreach ($Failure in @(Remove-AzContextSnapshot -Path $AzContextPath))
    {
        Write-Stream ("WARNING: could not remove Az context snapshot at {0}: {1}. It holds an Azure token cache; remove it with: {2}" -f $Failure.Path, $Failure.Message, (Get-RemoveFileCommand -Path $Failure.Path)) 'Yellow'
    }
}

# ---- Per-stream resume state -------------------------------------------------
#
# Each stream owns a separate file. No races, no locking, simple semantics.
$StreamStateFile = Get-ResumeStatePath -InventoryRoot $InventoryRoot -Tenant $TenantID -Stream $StreamId





$CompletedIds = @()
$FailedAttempts = @()
# The report zip recorded per completed sub (New-CompletedReportRecord), kept in
# this stream's state so the parent can carry it on a later -Resume.
$Reports = @()
if ($Resume -or $ResumeFailedOnly)
{
    $State = Read-StreamState -Path $StreamStateFile -RunId $RunId
    $CompletedIds = $State.Completed
    $FailedAttempts = $State.Failed
    $Reports = @($State.Reports)
    # The parent leaves completed subscriptions out of the slices, so this file
    # usually lists none of this slice; count only those that are in it.
    $CompletedInSlice = @($CompletedIds | Where-Object { $SubscriptionIds -contains $_ })
    if ($CompletedInSlice.Count -gt 0)
    {
        Write-Stream ("resume: skipping {0} previously-completed subs in this slice" -f $CompletedInSlice.Count) 'DarkGray'
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
if ($IncludeNetworkResources) { $InventoryPassthrough['IncludeNetworkResources'] = $true }
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
# Subs this stream skipped on -Resume as completed; reported in the summary so
# the parent can carry their recorded reports into the consolidated zip.
$SkippedSubs = @()
# Subs this stream collected without a zip being written; reported in the
# summary so the parent takes them off the unified completed list.
$NoReportSubs = @()
# The report zip of every subscription this stream collected that wrote one,
# complete or not: the parent builds the consolidated zip from these.
$RunReports = @()
# Subs this stream collected with metrics or consumption left incomplete; they
# are in the retry list, and the summary names them so the parent also takes
# them off the unified completed list.
$IncompleteSubs = @()

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

    Write-Stream ("processing ({0} of {1}): {2} ({3})" -f ($i + 1), $PairCount, $SubName, $SubId) 'Cyan'

    try
    {
        # Cleared first so a stale path from the previous sub is never recorded as this one's.
        $Global:ZipOutputFile = $null
        # Counted before the call, so Get-IncompleteDataReason sees only what this call appends.
        $MetricsGapsBefore = @($Global:MetricsFailedSubs | Where-Object { $null -ne $_ }).Count
        $ConsumptionGapsBefore = @($Global:ConsumptionFailedSubs | Where-Object { $null -ne $_ }).Count
        # ResourceInventory.ps1 ends without `exit` when it succeeds, and that
        # leaves $LASTEXITCODE as it was: the `exit 1` of an earlier
        # subscription in this stream would mark this one failed.
        $global:LASTEXITCODE = 0
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
        # Network rows the inner script left out of the pull (reset by it on
        # every run; $null when its count query failed).
        # Read with Get-Variable: an inner run that stopped before it set them
        # leaves them unset, which strict mode would stop on.
        $SkipRaw = Get-Variable -Name SkippedResourceCount -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        $SkipTypes = Get-Variable -Name SkippedResourceTypes -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        $SkipCount = if ($null -ne $SkipRaw) { [long]$SkipRaw } else { [long]0 }
        $ResourceCounts += [pscustomobject]@{ Name = $SubName; Id = $SubId; Count = $ResCount; Skipped = $SkipCount }

        $CountMessage = Get-RdaResourceCountMessage -Collected $ResCount -Skipped $SkipRaw -SkippedByType $SkipTypes
        if ($CountMessage.Kind -eq 'Empty')
        {
            Write-Stream ("WARNING: '{0}' returned 0 resources (it passed the up-front role check, so it is an empty subscription)" -f $SubName) 'Yellow'
        }
        else
        {
            Write-Stream ("done: {0} - {1}" -f $SubName, $CountMessage.Text) 'Green'
        }

        # Record the zip this run wrote, replacing any earlier record for the sub.
        $NewReport = New-CompletedReportRecord -InventoryRoot $InventoryRoot -Id $SubId -Name $SubName -ZipPath $Global:ZipOutputFile -Obfuscated ([bool]$Obfuscate)
        if ($null -ne $NewReport)
        {
            $Reports = @(@($Reports | Where-Object { $null -ne $_ -and [string]$_.Id -ne $SubId }) + $NewReport)
            $RunReports = @(@($RunReports) + $NewReport)
        }
        $IncompleteReason = Get-IncompleteDataReason -MetricsEntries $Global:MetricsFailedSubs -MetricsBefore $MetricsGapsBefore -ConsumptionEntries $Global:ConsumptionFailedSubs -ConsumptionBefore $ConsumptionGapsBefore

        if ($null -eq $NewReport)
        {
            # The run left no zip, so there is no report a later -Resume could
            # carry: the sub is not completed. Named in the summary so the parent
            # also ends an earlier run's completion of it in the unified state.
            # It goes on the retry list as a failed run, as in the parent.
            $NoReportSubs += [pscustomobject]@{ Id = $SubId; Name = $SubName }
            $Completed = @($Completed | Where-Object { $_ -ne $SubId })
            $Reports = @($Reports | Where-Object { $null -ne $_ -and [string]$_.Id -ne $SubId })
            $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts -Id $SubId -Name $SubName -Reason 'the run wrote no report zip (see the errors above)'
            Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts -Reports $Reports
        }
        elseif ($null -ne $IncompleteReason)
        {
            # Same as the parent's sequential branch: the report was written
            # without some of its metrics or consumption, so the sub goes into
            # the retry list instead of the completed list.
            Write-Stream ("{0} It stays in the retry list, so -Resume or -ResumeFailedOnly collects '{1}' again." -f $IncompleteReason, $SubName) 'Yellow'
            $IncompleteSubs += [pscustomobject]@{ Id = $SubId; Name = $SubName }
            $Completed = @($Completed | Where-Object { $_ -ne $SubId })
            $Reports = @($Reports | Where-Object { $null -ne $_ -and [string]$_.Id -ne $SubId })
            $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts -Id $SubId -Name $SubName -Reason $IncompleteReason
            Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts -Reports $Reports
        }
        elseif (-not ($Completed -contains $SubId))
        {
            $Completed += $SubId
            # If this is a retry that finally succeeded, drop the sub from
            # FailedAttempts so the unified resume-state file reflects truth.
            $FailedAttempts = Remove-FailedAttempt -Existing $FailedAttempts -Id $SubId
            Write-StreamState -Path $StreamStateFile -Completed @($Completed) -FailedAttempts $FailedAttempts -Reports $Reports
        }
        else
        {
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

        try { $DiagLines | Out-File -FilePath $StreamFailuresPath -Append -Encoding utf8 }
        catch { Write-Stream ("could not write to stream failures log {0}: {1}" -f $StreamFailuresPath, $_.Exception.Message) 'Yellow' }

        $FailedSubs += [pscustomobject]@{ Id = $SubId; Name = $SubName; Reason = $ErrRecord.Exception.Message }
        # Persist the failure to the per-stream state file. The parent
        # wrapper will fold these entries into the unified FailedAttempts
        # list when it merges per-stream state at run end. Persisting on
        # every failure (rather than only at end-of-stream) means a worker
        # that is killed mid-slice still surfaces its partial failure
        # history to the next -ResumeFailedOnly invocation.
        $FailedAttempts = Add-FailedAttempt -Existing $FailedAttempts `
            -Id $SubId -Name $SubName -Reason $ErrRecord.Exception.Message
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

$Summary = [pscustomobject]@{
    StreamId               = $StreamId
    Tenant                 = $TenantID
    Status                 = if ($FailedSubs.Count -eq 0) { 'ok' } else { 'partial-failure' }
    SubsProcessed          = $PairCount
    Completed              = @($Completed)
    Failed                 = $FailedSubs
    Skipped                = @($SkippedSubs)
    NoReport               = @($NoReportSubs)
    Incomplete             = @($IncompleteSubs)
    RunReports             = @($RunReports)
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
    $Summary | ConvertTo-Json -Depth 6 | Set-Content -Path $StreamSummaryPath -Encoding utf8
}
catch
{
    Write-Stream ("FATAL: could not write stream summary to {0}: {1}" -f $StreamSummaryPath, $_.Exception.Message) 'Red'
    exit 1
}

# Count only this slice's subscriptions, as the resume line above does: on
# -Resume the state file can list completions of earlier slices too.
$SucceededInSlice = @($Completed | Where-Object { $SubscriptionIds -contains $_ }).Count
Write-Stream ("complete: {0}/{1} succeeded, {2} failed" -f $SucceededInSlice, $PairCount, $FailedSubs.Count) 'Green'
exit 0
