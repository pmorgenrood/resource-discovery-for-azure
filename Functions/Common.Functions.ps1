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

# ---------------------------------------------------------------------------
# Microsoft.Insights provider check for -UseMetricsBatch.
#
# The Azure Monitor batch API (metrics:getBatch) answers 403 on a subscription
# where the Microsoft.Insights resource provider is not registered. Only with
# -UseMetricsBatch, the preflight reads the provider's state on every
# subscription in scope (a read, which Reader allows). When some are not
# registered it lists them and asks once whether to register them. Only a "y"
# registers; registering needs the /register/action permission, which the
# Contributor and Owner roles include (Microsoft docs: Azure resource providers
# and types). A "n", no answer (no console) or a failed register leaves those
# subscriptions on the one-call-per-resource metrics path, with the command
# that registers it printed, so no metrics are lost. The wait for a started
# registration is bounded by one shared deadline; nothing loops past it.
# ---------------------------------------------------------------------------

# The ARM API version used to read and register a resource provider.
function Get-RdaInsightsProviderApiVersion
{
    return '2021-04-01'
}

# The command a person runs to register Microsoft.Insights on one subscription.
function Get-RdaInsightsRegisterCommand
{
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)
    return ('Set-AzContext -Subscription {0}; Register-AzResourceProvider -ProviderNamespace Microsoft.Insights' -f $SubscriptionId)
}

# The seconds one read or register of Microsoft.Insights may take before it is given up.
function Get-RdaInsightsCallTimeoutSeconds
{
    return 30
}

# One Invoke-AzRestMethod call. With $TimeoutSeconds above 0 it runs as a job
# and is given up after that many seconds: it then throws a TimeoutException,
# and the job is stopped and removed, so nothing is left running. 0 waits for
# the answer.
function Invoke-RdaBoundedAzRestMethod
{
    param([Parameter(Mandatory = $true)][string]$Method, [Parameter(Mandatory = $true)][string]$Path, [double]$TimeoutSeconds = 0)

    if ($TimeoutSeconds -le 0) { return Invoke-AzRestMethod -Method $Method -Path $Path -ErrorAction Stop }
    $Job = Invoke-AzRestMethod -Method $Method -Path $Path -AsJob -ErrorAction Stop
    try
    {
        if (-not $Job.Finished.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)))
        {
            throw [System.TimeoutException]::new(('Timed out after {0:0.#} s' -f $TimeoutSeconds))
        }
        return Receive-Job -Job $Job -ErrorAction Stop
    }
    finally
    {
        Stop-Job -Job $Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

# The registration state of Microsoft.Insights on one subscription:
# 'Registered', 'NotRegistered', 'Registering', 'Unregistering', or 'Unknown'
# when the state could not be read (the error is in Error). With
# $TimeoutSeconds above 0, each GET is given up after that many seconds (a GET
# that stalls reads as Unknown, and is not sent again); 0 waits for the answer.
function Get-RdaInsightsProviderState
{
    param([Parameter(Mandatory = $true)][string]$SubscriptionId, [int]$MaxRetries = 3, [double]$TimeoutSeconds = 0)

    $Path = '/subscriptions/{0}/providers/Microsoft.Insights?api-version={1}' -f $SubscriptionId, (Get-RdaInsightsProviderApiVersion)
    # One ARM GET, sent again at most $MaxRetries times (1, 2, 4 s apart) after a
    # request that throws, a throttle, an HTTP 408 or a server error. Any other
    # answer that is not a success, or a GET given up on its time limit, reads
    # as Unknown at once.
    $LastError = $null
    for ($Attempt = 0; $Attempt -le $MaxRetries; $Attempt++)
    {
        if ($Attempt -gt 0) { Start-Sleep -Seconds ([math]::Min([math]::Pow(2, $Attempt - 1), 4)) }
        try
        {
            $Response = Invoke-RdaBoundedAzRestMethod -Method GET -Path $Path -TimeoutSeconds $TimeoutSeconds
        }
        catch [System.TimeoutException]
        {
            $LastError = [string]$_.Exception.Message
            break
        }
        catch
        {
            $LastError = [string]$_.Exception.Message
            continue
        }
        $Status = [int]$Response.StatusCode
        if ($Status -ge 200 -and $Status -lt 300)
        {
            try { $Body = [string]$Response.Content | ConvertFrom-Json -ErrorAction Stop }
            catch { return [pscustomobject]@{ SubscriptionId = $SubscriptionId; State = 'Unknown'; Error = 'the answer was not valid JSON' } }
            $State = [string]$Body.registrationState
            if ([string]::IsNullOrEmpty($State)) { $State = 'Unknown' }
            return [pscustomobject]@{ SubscriptionId = $SubscriptionId; State = $State; Error = $null }
        }
        $LastError = 'HTTP {0}' -f $Status
        if (-not ($Status -eq 408 -or $Status -eq 429 -or $Status -ge 500)) { break }
    }
    return [pscustomobject]@{ SubscriptionId = $SubscriptionId; State = 'Unknown'; Error = $LastError }
}

# Starts the registration of Microsoft.Insights on one subscription. Returns
# $null when Azure took it, or the error text. With $TimeoutSeconds above 0 a
# POST that takes longer is given up and reads as a failed register.
function Register-RdaInsightsProvider
{
    param([Parameter(Mandatory = $true)][string]$SubscriptionId, [double]$TimeoutSeconds = 0)

    $Path = '/subscriptions/{0}/providers/Microsoft.Insights/register?api-version={1}' -f $SubscriptionId, (Get-RdaInsightsProviderApiVersion)
    try
    {
        $Response = Invoke-RdaBoundedAzRestMethod -Method POST -Path $Path -TimeoutSeconds $TimeoutSeconds
        $Status = [int]$Response.StatusCode
        if ($Status -ge 200 -and $Status -lt 300) { return $null }
        $Code = ''
        try { $Code = [string](([string]$Response.Content | ConvertFrom-Json -ErrorAction Stop).error.code) } catch { $Code = '' }
        return ('HTTP {0}{1}' -f $Status, $(if ($Code) { ' ' + $Code } else { '' }))
    }
    catch
    {
        return [string]$_.Exception.Message
    }
}

# The preflight. Reads every subscription's state, asks once for those not
# registered, registers on "y" and waits for them on one deadline. Returns
# { Registered; NotRegistered; Asked; Answer } (Asked: the question was shown
# and answered): Registered holds the ids that
# batch may use (registered, or whose state could not be read, so the batch
# call decides and falls back on its own), NotRegistered the ids that stay on
# the per-call path. $Interactive, $ReadAnswer, $DeadlineSeconds,
# $PollSeconds and $CallTimeoutSeconds (the limit of each first read and each
# register) are there for tests.
function Invoke-RdaInsightsProviderPreflight
{
    param(
        [string[]]$SubscriptionIds,
        [Nullable[bool]]$Interactive = $null,
        [scriptblock]$ReadAnswer = { param($Prompt) Read-Host -Prompt $Prompt },
        [int]$DeadlineSeconds = 60,
        [int]$PollSeconds = 10,
        [double]$CallTimeoutSeconds = (Get-RdaInsightsCallTimeoutSeconds)
    )

    $Ids = @($SubscriptionIds | Where-Object { -not [string]::IsNullOrEmpty($_) } | Sort-Object -Unique)
    $Result = [pscustomobject]@{ Registered = [System.Collections.Generic.List[string]]::new(); NotRegistered = [System.Collections.Generic.List[string]]::new(); Asked = $false; Answer = $null }
    if ($Ids.Count -eq 0) { return $Result }
    # Metrics.ps1 batches only in AzureCloud; elsewhere there is nothing to check, ask or register.
    $Environment = try { [string](Get-AzContext -ErrorAction Stop).Environment.Name } catch { '' }
    if ($Environment -ne 'AzureCloud')
    {
        Write-Host ('-UseMetricsBatch: the Azure environment is ''{0}'', not AzureCloud; the batch API is not used there, so Microsoft.Insights is not checked.' -f $Environment) -ForegroundColor DarkGray
        return $Result
    }
    if ($null -eq $Interactive) { $Interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected }

    Write-Host ('-UseMetricsBatch: checking the Microsoft.Insights resource provider on {0} subscription(s)...' -f $Ids.Count) -ForegroundColor Cyan
    $Missing = [System.Collections.Generic.List[object]]::new()
    # Already being registered (by someone else, or an earlier run): nothing to
    # ask; it joins the shared wait below.
    $AlreadyRegistering = [System.Collections.Generic.List[string]]::new()
    foreach ($Id in $Ids)
    {
        $Read = Get-RdaInsightsProviderState -SubscriptionId $Id -TimeoutSeconds $CallTimeoutSeconds
        if ($Read.State -eq 'Registered')
        {
            $Result.Registered.Add($Id)
        }
        elseif ($Read.State -eq 'Unknown')
        {
            # Not readable: the batch call is tried and falls back by itself.
            Write-Host ('  Could not read the Microsoft.Insights state of subscription {0} ({1}); its metrics batch is tried and falls back to one call per resource if Azure refuses it.' -f $Id, $Read.Error) -ForegroundColor Yellow
            $Result.Registered.Add($Id)
        }
        elseif ($Read.State -eq 'Registering')
        {
            $AlreadyRegistering.Add($Id)
        }
        else
        {
            $Missing.Add($Read)
        }
    }
    if ($Missing.Count -eq 0 -and $AlreadyRegistering.Count -eq 0)
    {
        Write-Host '  Microsoft.Insights is registered on every subscription in scope.' -ForegroundColor DarkGray
        return $Result
    }
    $Waiting = [System.Collections.Generic.List[string]]::new()
    foreach ($Id in $AlreadyRegistering)
    {
        Write-Host ('  Microsoft.Insights is being registered on subscription {0}; waiting for it.' -f $Id) -ForegroundColor DarkGray
        $Waiting.Add($Id)
    }

    $Answer = $null
    $Answered = $false
    if ($Missing.Count -gt 0)
    {
        Write-Host ('  Microsoft.Insights is not registered on {0} subscription(s); the metrics batch API needs it:' -f $Missing.Count) -ForegroundColor Yellow
        foreach ($Entry in $Missing) { Write-Host ('    {0} ({1})' -f $Entry.SubscriptionId, $Entry.State) -ForegroundColor Yellow }
        if ($Interactive)
        {
            # Under pwsh -NonInteractive with a terminal attached, Read-Host writes an
            # error instead of asking. With errors stopping here, that is caught and
            # read as "no one can answer", and Asked stays false.
            $SavedPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Stop'
            try
            {
                $Answer = [string](& $ReadAnswer ('Register Microsoft.Insights on these {0} subscription(s) now? [Y/N]' -f $Missing.Count))
                $Answered = $true
            }
            catch
            {
                $Answer = $null
            }
            finally
            {
                $ErrorActionPreference = $SavedPreference
            }
            $Result.Asked = $Answered
            $Result.Answer = $Answer
        }
    }

    $ToRegister = @()
    if ($Missing.Count -gt 0 -and $Answer -notmatch '^\s*(y|yes)\s*$')
    {
        $Why = if ($Answered) { 'Not registering.' } else { 'No one can answer a prompt in this session, so nothing is registered.' }
        Write-Host ('  {0} Their metrics are collected with one call per resource, so none are lost. To register it later (needs Contributor or Owner), run per subscription:' -f $Why) -ForegroundColor Yellow
        foreach ($Entry in $Missing)
        {
            Write-Host ('    ' + (Get-RdaInsightsRegisterCommand -SubscriptionId $Entry.SubscriptionId)) -ForegroundColor Yellow
            $Result.NotRegistered.Add($Entry.SubscriptionId)
        }
    }
    else
    {
        $ToRegister = @($Missing)
    }

    # Start every registration first, then wait for all of them on one deadline.
    foreach ($Entry in $ToRegister)
    {
        $RegisterError = Register-RdaInsightsProvider -SubscriptionId $Entry.SubscriptionId -TimeoutSeconds $CallTimeoutSeconds
        if ($null -eq $RegisterError)
        {
            $Waiting.Add($Entry.SubscriptionId)
        }
        else
        {
            # The right is named only when Azure refused the register for lack of it.
            $Rights = if ($RegisterError -match '\bHTTP 403\b|AuthorizationFailed') { ' Registering needs the /register/action permission, which the Contributor and Owner roles include.' } else { '' }
            Write-Host ('  Could not register Microsoft.Insights on subscription {0} ({1}).{2} Its metrics are collected with one call per resource.' -f $Entry.SubscriptionId, $RegisterError, $Rights) -ForegroundColor Yellow
            $Result.NotRegistered.Add($Entry.SubscriptionId)
        }
    }

    $Deadline = (Get-Date).AddSeconds([math]::Max(0, $DeadlineSeconds))
    # Every read checks the time first, so the wait ends at the deadline however many
    # subscriptions there are; a read while waiting is not retried (a failed one means
    # not registered yet), and is given up when the time left runs out, so one GET
    # that stalls cannot hold the wait past the deadline.
    while ($Waiting.Count -gt 0 -and (Get-Date) -lt $Deadline)
    {
        for ($Idx = $Waiting.Count - 1; $Idx -ge 0 -and (Get-Date) -lt $Deadline; $Idx--)
        {
            $ReadLeft = [math]::Max(0.001, ($Deadline - (Get-Date)).TotalSeconds)
            if ((Get-RdaInsightsProviderState -SubscriptionId $Waiting[$Idx] -MaxRetries 0 -TimeoutSeconds $ReadLeft).State -eq 'Registered')
            {
                Write-Host ('  Microsoft.Insights is now registered on subscription {0}.' -f $Waiting[$Idx]) -ForegroundColor Green
                $Result.Registered.Add($Waiting[$Idx])
                $Waiting.RemoveAt($Idx)
            }
        }
        $Left = ($Deadline - (Get-Date)).TotalSeconds
        if ($Waiting.Count -eq 0 -or $Left -le 0) { break }
        # Never sleep past the deadline.
        Start-Sleep -Milliseconds ([int]([math]::Max(0, [math]::Min($PollSeconds, $Left)) * 1000))
    }
    foreach ($Id in $Waiting)
    {
        Write-Host ('  Microsoft.Insights is still not registered on subscription {0} after {1} s; its metrics are collected with one call per resource this run. A later run finds it registered and uses the batch API.' -f $Id, $DeadlineSeconds) -ForegroundColor Yellow
        $Result.NotRegistered.Add($Id)
    }
    return $Result
}
