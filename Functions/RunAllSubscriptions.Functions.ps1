#Requires -Version 7.0
# =============================================================================
# RunAllSubscriptions.Functions.ps1
#
# Shared helper functions for the multi-subscription wrappers. Dot-sourced by
# BOTH Run-AllSubscriptions.ps1 (parent) and Run-AllSubscriptions.Stream.ps1
# (per-stream worker), which is safe because each dot-sources this file from
# its OWN $PSScriptRoot - the stream worker runs in a fresh Start-Job process
# and cannot inherit the parent's function table, so it loads its own copy.
#
# Definitions only - no top-level code. Functions that reference caller-scope
# variables ($WrapperTranscriptStarted, $Tag, $TenantID, $StreamId) resolve
# them at CALL time from whichever script dot-sourced this file; a script only
# ever calls the functions relevant to it.
#
# The single Add-FailedAttempt / Remove-FailedAttempt pair replaces what used
# to be duplicated as Add-StreamFailedAttempt / Remove-StreamFailedAttempt in
# the worker - identical logic, now defined once.
# =============================================================================

# ---- Wrapper / shared -------------------------------------------------------
# Single exit path that ensures the wrapper transcript is stopped before
# returning to the host. Used by every error path that previously called
# `exit <code>` directly.
function Exit-Wrapper
{
    param([int]$Code = 0)
    # Every early exit of the wrapper passes here, and the resume state is kept
    # at each of them. The per-stream state files the run folded in at startup
    # (or, after the end-of-run merge of a parallel run, the ones its streams
    # wrote) are deleted first, once the resume state holds their records
    # (Invoke-FoldedStreamStateCleanup), so a run that stops early leaves none
    # behind and no exit needs code of its own. There are none before the fold,
    # and none after the end-of-run clean-up.
    if (@($FoldedStreamFiles | Where-Object { $null -ne $_ }).Count -gt 0)
    {
        $null = Invoke-FoldedStreamStateCleanup -Files $FoldedStreamFiles -ResumeStateFile $ResumeStateFile -Tenant $TenantID -Ids $FoldedRecordIds -CompletedIds $CompletedIds -FailedAttempts $FailedAttempts -Source $FoldedSource
    }
    if ($WrapperTranscriptStarted)
    {
        try { Stop-Transcript | Out-Null }
        catch { Write-Verbose ("Stop-Transcript on Exit-Wrapper failed: {0}" -f $_.Exception.Message) }
    }
    exit $Code
}

# Auto-tune parallelism to the current host. Detects logical CPU count and total
# physical RAM, then recommends a ParallelStreams / ConcurrencyLimit pair using
# the same guidance documented on Run-AllSubscriptions.ps1's parameters:
#   - Each stream is a separate pwsh process (~1-1.5 GB resident once Az is
#     loaded and its metrics runspaces are active), so RAM caps the stream
#     count; ~2 GB is reserved for the OS.
#   - One stream per ~2 vCPUs, so each stream still has a core for its own
#     metrics threads. On a 2-vCPU box this yields 1 (sequential), which is
#     faster there than two streams fighting over the cores.
#   - Tenant-scoped Resource Graph limits make more than ~6 streams pointless.
#   - Metric calls are network-I/O bound, so the per-stream metrics throttle can
#     oversubscribe the CPU a little: 2x vCPU, bounded to [6,16] (Azure Monitor's
#     ~12k reads/hour/subscription makes higher concurrency pointless).
# Returns a PSCustomObject { VCpu, RamGB (0 when undetectable), Streams,
# Concurrency }. The caller applies these ONLY for parameters the operator did
# not pass explicitly; the existing clamp to the eligible subscription count
# still applies on top.
function Get-RecommendedParallelism
{
    $VCpu = [int][Environment]::ProcessorCount
    if ($VCpu -lt 1) { $VCpu = 1 }

    # Total physical RAM in GB, best-effort and cross-platform. 0 = undetectable.
    $RamGB = 0.0
    try
    {
        if ($IsWindows)
        {
            $Bytes = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
            if ($Bytes) { $RamGB = [math]::Round([double]$Bytes / 1GB, 1) }
        }
        elseif ($IsLinux)
        {
            $MemLine = Select-String -Path '/proc/meminfo' -Pattern '^MemTotal:\s+(\d+)\s+kB' -ErrorAction Stop | Select-Object -First 1
            if ($MemLine) { $RamGB = [math]::Round([double]$MemLine.Matches[0].Groups[1].Value / 1MB, 1) }
        }
        elseif ($IsMacOS)
        {
            $Bytes = [double](& sysctl -n hw.memsize 2>$null)
            if ($Bytes) { $RamGB = [math]::Round($Bytes / 1GB, 1) }
        }
    }
    catch
    {
        $RamGB = 0.0
    }

    # One stream per ~2 vCPUs, capped at 6 (tenant Resource Graph ceiling).
    $Streams = [int][math]::Floor($VCpu / 2)
    if ($Streams -lt 1) { $Streams = 1 }
    if ($Streams -gt 6) { $Streams = 6 }

    # RAM cap when known: reserve ~2 GB for the OS, budget ~1.5 GB per stream.
    if ($RamGB -gt 0)
    {
        $StreamsByRam = [int][math]::Floor(($RamGB - 2) / 1.5)
        if ($StreamsByRam -lt 1) { $StreamsByRam = 1 }
        if ($StreamsByRam -lt $Streams) { $Streams = $StreamsByRam }
    }

    # Metrics throttle: I/O bound, so 2x vCPU, bounded to [6,16].
    $Concurrency = $VCpu * 2
    if ($Concurrency -lt 6) { $Concurrency = 6 }
    if ($Concurrency -gt 16) { $Concurrency = 16 }

    [pscustomobject]@{
        VCpu        = $VCpu
        RamGB       = $RamGB
        Streams     = [int]$Streams
        Concurrency = [int]$Concurrency
    }
}

# Disable the Windows console "QuickEdit Mode" for this session (best-effort).
#
# QuickEdit is on by default in conhost. If the user clicks in the window - or it
# otherwise enters mark/select mode - Windows SUSPENDS the process the instant it
# next writes to the console, until a key is pressed (Enter/Esc). During a long
# run (especially -ParallelStreams, where the wrapper continuously writes collated
# child output) this looks like a random hang that only clears when you press
# Enter. Clearing ENABLE_QUICK_EDIT_INPUT stops that.
#
# Windows-only and interactive-only: on Linux/macOS, or when input/output is
# redirected (CI, SSM run-command, piped to a file), there is no interactive
# console mode to change, so this no-ops. Best-effort: any failure is swallowed -
# tweaking the console must never break a run. The mode is not restored
# afterwards (it resets when the console window closes); selecting text to copy
# still works via the terminal's own selection, just not the legacy click-drag
# mark that caused the freeze.
function Disable-ConsoleQuickEdit
{
    if (-not $IsWindows) { return }
    if (-not [Environment]::UserInteractive) { return }
    try { if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return } } catch { return }

    try
    {
        if (-not ('Rda.ConsoleMode' -as [type]))
        {
            Add-Type -Namespace 'Rda' -Name 'ConsoleMode' -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        }

        $STD_INPUT_HANDLE = -10
        $ENABLE_QUICK_EDIT = [uint32]0x0040
        $ENABLE_EXTENDED_FLAGS = [uint32]0x0080

        $Handle = [Rda.ConsoleMode]::GetStdHandle($STD_INPUT_HANDLE)
        $Mode = [uint32]0
        if ([Rda.ConsoleMode]::GetConsoleMode($Handle, [ref]$Mode))
        {
            $NewMode = ($Mode -band (-bnot $ENABLE_QUICK_EDIT)) -bor $ENABLE_EXTENDED_FLAGS
            [void][Rda.ConsoleMode]::SetConsoleMode($Handle, $NewMode)
        }
    }
    catch
    {
        # Never let console-mode tweaking break a run.
    }
}

# === Pre-flight checks ===
#
# Detect the most common environment problems that make a long run pointless,
# before authentication, tenant resolution, or any per-subscription work.
# Each check is one of:
#   - Hard fail: print a clear message + remediation, call Exit-Wrapper.
#   - Warn:      print a clear message and continue (the run will still
#                produce useful output, just with a known caveat).
#
# NOTE: Run-AllSubscriptions.ps1 dot-sources this function from the shared
# Functions folder. ResourceInventory.ps1 keeps its OWN inline variant of the
# same checks (it deliberately differs: it honors -OutputDirectory, throws
# instead of calling Exit-Wrapper, and is gated on -not $RunAllSubs). Keep the
# two behaviorally in sync - if you change a check here, mirror it there.
function Invoke-PreFlightChecks
{
    param(
        [Parameter(Mandatory = $true)] [string] $InventoryRoot
    )

    Write-Host "Running pre-flight checks..." -ForegroundColor Cyan

    # 1. Cloud Shell mount detection.
    #
    # Get-CloudDrive ships with the Az.CloudShell module which is preloaded
    # in Cloud Shell and not present in regular PowerShell installs. So the
    # cmdlet's existence is our "are we in Cloud Shell" probe; its return
    # value is our "is the drive mounted" probe.
    #   - Cmdlet absent       -> not in Cloud Shell, skip the check entirely.
    #   - Cmdlet present, $null returned -> Cloud Shell, ephemeral mode
    #                            (verified live: emits "Clouddrive is not
    #                            mounted" warning on stream 3 and returns null).
    #   - Cmdlet present, object returned -> Cloud Shell, drive mounted.
    # The 3>$null suppresses the noisy WARNING so our message is the first
    # thing the user sees.
    if (Get-Command Get-CloudDrive -ErrorAction SilentlyContinue)
    {
        $CheckCloudDrive = Get-CloudDrive 3>$null 2>$null
        if ($null -eq $CheckCloudDrive)
        {
            Write-Host ""
            Write-Host "WARNING: Cloud Shell detected, but no storage account is mounted." -ForegroundColor Yellow
            Write-Host "  Outputs in $InventoryRoot will be lost when this Cloud Shell session ends." -ForegroundColor Yellow
            Write-Host "  This includes the resume-state file, so -Resume on a future session won't help recover." -ForegroundColor Yellow
            Write-Host "  To persist outputs across sessions, attach a storage account via the Cloud Shell" -ForegroundColor Yellow
            Write-Host "  settings menu (gear icon) > Reset User Settings > Mount storage account." -ForegroundColor Yellow
            Write-Host "  Continuing in ephemeral mode - download the report ZIP from $InventoryRoot before closing the shell." -ForegroundColor Yellow
            Write-Host ""
        }
        else
        {
            Write-Host ("Cloud Shell drive mounted: {0}" -f $CheckCloudDrive.Name) -ForegroundColor Green
        }
    }

    # 2. Disk space probe at the inventory root.
    #
    # Cloud Shell's overlay filesystem provides ~50 GB (verified with `df -h`
    # in 2026); the legacy 5 GB number some older docs cite is outdated.
    # A 100+ subscription run can produce 200-500 MB of zips and intermediate
    # files; if free space is already low (typically because something else
    # is filling the home directory) the run will fail late with a confusing
    # "There is not enough space" during report generation or zip packaging.
    # Catch it now.
    try
    {
        $RootItem = Get-Item -Path $InventoryRoot -ErrorAction Stop
        $Drive = $RootItem.PSDrive
        if ($null -ne $Drive -and $null -ne $Drive.Free)
        {
            $FreeMB = [math]::Round($Drive.Free / 1MB, 0)
            if ($FreeMB -lt 100)
            {
                Write-Host ("ERROR: Free disk space at {0} is {1} MB. The script needs at least 100 MB to start. Free space and re-run." -f $InventoryRoot, $FreeMB) -ForegroundColor Red
                Exit-Wrapper -Code 1
            }
            elseif ($FreeMB -lt 500)
            {
                Write-Host ("WARNING: Free disk space at {0} is {1} MB. A large multi-subscription run can exceed this. Consider freeing space before running." -f $InventoryRoot, $FreeMB) -ForegroundColor Yellow
            }
            else
            {
                Write-Host ("Free disk space: {0:N0} MB at {1}" -f $FreeMB, $InventoryRoot) -ForegroundColor Green
            }
        }
    }
    catch
    {
        # If we cannot read free space (uncommon - usually means the inventory
        # root is on an exotic filesystem), warn but do not fail. The write
        # probe below is the real correctness gate.
        Write-Host ("WARNING: Could not determine free disk space at {0}: {1}" -f $InventoryRoot, $_.Exception.Message) -ForegroundColor Yellow
    }

    # 3. Write probe.
    #
    # Catches any reason the script cannot create files in $InventoryRoot:
    # readonly mount, permissions, antivirus quarantine, DLP product, etc.
    # Cheap (~1 ms) and definitive.
    $ProbePath = Join-Path $InventoryRoot (".write-probe-{0}.tmp" -f ([guid]::NewGuid()))
    try
    {
        Set-Content -Path $ProbePath -Value 'preflight write probe' -Encoding utf8 -ErrorAction Stop
        $ProbeRead = Get-Content -Path $ProbePath -Raw -ErrorAction Stop
        if ($ProbeRead -notmatch 'preflight write probe')
        {
            throw "Write probe content mismatch (read back '$ProbeRead')"
        }
        Remove-Item -Path $ProbePath -Force -ErrorAction Stop
        Write-Host ("Write probe: OK ({0})" -f $InventoryRoot) -ForegroundColor Green
    }
    catch
    {
        Write-Host ("ERROR: Cannot write to {0}: {1}" -f $InventoryRoot, $_.Exception.Message) -ForegroundColor Red
        Write-Host "  This usually means: readonly directory, denied permissions, antivirus or DLP product blocking writes, or a stale handle." -ForegroundColor Red
        Write-Host "  Verify the directory is writable and re-run." -ForegroundColor Red
        # Best-effort cleanup in case Set-Content partially succeeded.
        try { if (Test-Path $ProbePath) { Remove-Item -Path $ProbePath -Force -ErrorAction SilentlyContinue } }
        catch { Write-Verbose ("Probe cleanup failed at {0}: {1}" -f $ProbePath, $_.Exception.Message) }
        Exit-Wrapper -Code 1
    }

    # 4. (removed) ImportExcel / EPPlus health probe.
    #
    # The report format changed from Excel (.xlsx) to a self-contained HTML
    # report (Extension/Summary.ps1), which has no external module dependency.
    # There is nothing to preflight here any more. This is the dependency that
    # previously failed in Cloud Shell when ImportExcel was partially installed.

    Write-Host "Pre-flight checks passed." -ForegroundColor Green
    Write-Host ""
}

# Resolve a tenant identifier to a tenant GUID.
#
# -TenantID may be passed as either a GUID (the canonical form) or as a verified
# domain (e.g. "contoso.onmicrosoft.com" or "contoso.com"). When given a domain,
# resolve it to the GUID via Microsoft's public OIDC discovery endpoint:
#
#   https://login.microsoftonline.com/<domain>/v2.0/.well-known/openid-configuration
#
# That endpoint is anonymous (no sign-in required) and returns a JSON document
# whose "issuer" field embeds the tenant GUID. Resolving up front means every
# downstream call (Connect-AzAccount, Get-AzSubscription, the resume state filename, the
# auth gate) operates on a stable identifier even if Azure later renames the
# domain.
function Resolve-TenantId
{
    param([Parameter(Mandatory = $true)][string]$Value)

    $GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($Value -match $GuidPattern) { return $Value }

    $Url = "https://login.microsoftonline.com/$Value/v2.0/.well-known/openid-configuration"
    Write-Host ("Resolving tenant '{0}' via OIDC discovery..." -f $Value) -ForegroundColor Cyan
    try
    {
        $Config = Invoke-RestMethod -Uri $Url -Method Get -ErrorAction Stop
    }
    catch
    {
        throw "Could not resolve tenant '$Value' to a GUID. Check that it is a valid Azure AD domain or pass the tenant GUID directly. Underlying error: $($_.Exception.Message)"
    }

    if ($null -eq $Config -or [string]::IsNullOrWhiteSpace($Config.issuer))
    {
        throw "OIDC discovery for tenant '$Value' returned an unexpected response (no issuer)."
    }

    # issuer looks like https://login.microsoftonline.com/<guid>/v2.0
    $Segments = $Config.issuer -split '/'
    $Resolved = $Segments | Where-Object { $_ -match $GuidPattern } | Select-Object -First 1
    if (-not $Resolved)
    {
        throw "OIDC discovery for tenant '$Value' did not contain a recognizable tenant GUID. issuer='$($Config.issuer)'"
    }

    Write-Host ("Resolved tenant '{0}' -> {1}" -f $Value, $Resolved) -ForegroundColor Green
    return $Resolved
}

function Get-CompletedSubscriptionIds
{
    param([string]$Path, [string]$Tenant)

    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @() }
    try
    {
        $State = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($State.TenantID -ne $Tenant)
        {
            Write-Host ("Resume state file is for a different tenant ({0}); ignoring." -f $State.TenantID) -ForegroundColor Yellow
            return @()
        }
        if ($null -eq $State.CompletedSubscriptionIds) { return @() }
        return @($State.CompletedSubscriptionIds)
    }
    catch
    {
        Write-Host ("Could not read resume state file ({0}); starting fresh. $_" -f $Path) -ForegroundColor Yellow
        return @()
    }
}

# Read the FailedAttempts list out of the same resume-state file. Returns an
# array of objects shaped { Id, Name, LastFailedAt, Reason, Attempts }, or an
# empty array if the file is absent, malformed, or for a different tenant.
# Backward-compatible: a state file written by an older version of this
# script (which has CompletedSubscriptionIds but no FailedAttempts key) reads
# back as empty here, so existing on-disk state never blocks an upgrade.
function Get-FailedAttempts
{
    param([string]$Path, [string]$Tenant)

    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @() }
    try
    {
        $State = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($State.TenantID -ne $Tenant) { return @() }
        if ($null -eq $State.FailedAttempts) { return @() }
        return @($State.FailedAttempts)
    }
    catch
    {
        return @()
    }
}

# Read the CompletedReports list out of the same resume-state file, the same way
# as Get-FailedAttempts: an empty array if the file is absent, malformed, for a
# different tenant, or written by an older version without the key. Entries are
# returned as stored; Get-ResumeCarriedReports validates each one before use.
function Get-CompletedReports
{
    param([string]$Path, [string]$Tenant)

    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @() }
    try
    {
        $State = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($State.TenantID -ne $Tenant) { return @() }
        if ($null -eq $State.CompletedReports) { return @() }
        return @($State.CompletedReports)
    }
    catch
    {
        return @()
    }
}

# Read the NotReadableSubscriptionIds list (the subscriptions the up-front access
# check skipped as not readable) out of the same resume-state file, the same way
# as Get-FailedAttempts: an empty array if the file is absent, malformed, for a
# different tenant, or written by a version without the key.
function Get-NotReadableSubscriptionIds
{
    param([string]$Path, [string]$Tenant)

    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @() }
    try
    {
        $State = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($State.TenantID -ne $Tenant) { return @() }
        if ($null -eq $State.NotReadableSubscriptionIds) { return @() }
        return @($State.NotReadableSubscriptionIds)
    }
    catch
    {
        return @()
    }
}

# True when the resume-state file for this tenant has no CompletedReports key at
# all: it was written by a version that did not record report zips, so a -Resume
# run has no report to carry for any subscription it lists as completed. A key
# holding an empty list does not count. A file that is absent, malformed or for a
# different tenant reads as false, as it reads as no state in Get-CompletedReports.
function Test-ResumeStateWithoutReports
{
    param([string]$Path, [string]$Tenant)

    if (-not (Test-Path -Path $Path -PathType Leaf)) { return $false }
    try
    {
        $State = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($State.TenantID -ne $Tenant) { return $false }
        return ($null -eq $State.PSObject.Properties['CompletedReports'])
    }
    catch
    {
        return $false
    }
}

function Save-CompletedSubscriptionIds
{
    param([string]$Path, [string]$Tenant, [string[]]$Ids, $FailedAttempts = @(), $Reports = @(), $NotReadable = @())

    # One report record per completed id (the last one given wins), none for an
    # id that is not completed. See New-CompletedReportRecord for the shape.
    $LatestReports = Get-LatestCompletedReports -Reports $Reports
    # Only the access check passes -NotReadable; every other save keeps the list
    # the file already holds.
    if (-not $PSBoundParameters.ContainsKey('NotReadable')) { $NotReadable = Get-NotReadableSubscriptionIds -Path $Path -Tenant $Tenant }
    $State = [pscustomobject]@{
        TenantID                  = $Tenant
        CompletedSubscriptionIds  = @($Ids)
        # The report zip each completed subscription wrote, so a -Resume run that
        # skips the subscription can still put its report in the consolidated zip.
        CompletedReports          = @(foreach ($Id in @($Ids)) { if (-not [string]::IsNullOrWhiteSpace($Id) -and $LatestReports.ContainsKey($Id)) { $LatestReports[$Id] } })
        # FailedAttempts is the canonical "what to retry" list. The wrapper
        # appends/refreshes entries on every catch and removes them on the
        # next successful attempt for the same sub, so the file is always
        # an accurate snapshot of "subs that failed at least once and have
        # not yet succeeded since".
        FailedAttempts            = @($FailedAttempts)
        # The subscriptions the up-front access check skipped as not readable,
        # so a -ResumeFailedOnly run does not name them as never collected.
        NotReadableSubscriptionIds = @(@($NotReadable) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        LastUpdated               = (Get-Date).ToString('o')
    }
    try
    {
        # Atomic write: serialize to a sibling temp file, then swap it into place
        # with File.Move(overwrite). A move within the same volume is a rename,
        # which is atomic - so a crash / SIGKILL / disk-full DURING the write can
        # never leave a truncated or half-written resume-state file. That matters
        # because Get-CompletedSubscriptionIds treats an unparseable file as
        # "start fresh", which would silently discard all recorded progress and
        # reprocess every subscription from scratch (potentially hours of work in
        # a large tenant / Cloud Shell run that gets killed). The temp file shares
        # the target directory so the move stays on the same volume.
        $TmpPath = "$Path.tmp"
        $State | ConvertTo-Json -Depth 4 | Set-Content -Path $TmpPath -Encoding utf8
        [System.IO.File]::Move($TmpPath, $Path, $true)
    }
    catch
    {
        Write-Host ("WARNING: Failed to persist resume state to {0}: $_" -f $Path) -ForegroundColor Yellow
        Remove-Item -LiteralPath "$Path.tmp" -Force -ErrorAction SilentlyContinue
    }
}

# Update an in-memory FailedAttempts list to record (or refresh) one sub's
# failure. Increments Attempts when the sub is already in the list. Caller
# is responsible for persisting via Save-CompletedSubscriptionIds afterwards.
function Add-FailedAttempt
{
    param(
        # [object] rather than [System.Collections.IEnumerable]: when the list
        # holds exactly one prior failure, PowerShell collapses it to a single
        # PSCustomObject on assignment at the call site, and a PSCustomObject is
        # NOT IEnumerable - the stricter type threw a parameter-transformation
        # error on the second failure. The @(...) normalization below already
        # handles scalar, $null, and array uniformly.
        [object]$Existing,
        [string]$Id,
        [string]$Name,
        [string]$Reason
    )
    $List = @($Existing | Where-Object { $_ })
    $ExistingEntry = $List | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($null -ne $ExistingEntry)
    {
        $List = @($List | Where-Object { $_.Id -ne $Id })
        $Attempts = (Get-FailedAttemptCount -Entry $ExistingEntry) + 1
    }
    else
    {
        $Attempts = 1
    }
    $List += [pscustomobject]@{
        Id           = $Id
        Name         = $Name
        LastFailedAt = (Get-Date).ToString('o')
        Reason       = $Reason
        Attempts     = $Attempts
    }
    return $List
}

# Remove a sub's FailedAttempts entry once it has succeeded on a retry, so
# the resume-state file does not grow into a graveyard of historical
# failures. Caller persists.
function Remove-FailedAttempt
{
    param(
        # [object] not [System.Collections.IEnumerable]: same single-element
        # collapse as Add-FailedAttempt - a lone prior failure arrives as a
        # scalar PSCustomObject. @(...) below normalizes scalar/$null/array.
        [object]$Existing,
        [string]$Id
    )
    return @($Existing | Where-Object { $_ -and $_.Id -ne $Id })
}

# The retry-list reason for a subscription whose report was written but whose
# metrics or consumption were skipped or left incomplete, or $null when they
# were not. ResourceInventory.ps1 appends one entry to $Global:MetricsFailedSubs
# or $Global:ConsumptionFailedSubs for each such gap; -MetricsBefore and
# -ConsumptionBefore are the sizes of those lists just before the call for this
# subscription, so only the entries that call appended count. Entries are not
# matched by Id because a consumption sign-in skip is recorded as '(auth)'.
function Get-IncompleteDataReason
{
    param(
        # [object]: same single-element collapse as Add-FailedAttempt.
        [object]$MetricsEntries,
        [int]$MetricsBefore = 0,
        [object]$ConsumptionEntries,
        [int]$ConsumptionBefore = 0
    )
    $NewMetrics = @(@($MetricsEntries | Where-Object { $null -ne $_ }) | Select-Object -Skip ([Math]::Max($MetricsBefore, 0)))
    $NewConsumption = @(@($ConsumptionEntries | Where-Object { $null -ne $_ }) | Select-Object -Skip ([Math]::Max($ConsumptionBefore, 0)))
    $Phases = @()
    if ($NewMetrics.Count -gt 0) { $Phases += 'Metrics' }
    if ($NewConsumption.Count -gt 0) { $Phases += 'Consumption' }
    if ($Phases.Count -eq 0) { return $null }
    $Messages = @(@($NewMetrics) + @($NewConsumption) | ForEach-Object { [string]$_.Message } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($Messages.Count -eq 0) { return ('{0} incomplete.' -f ($Phases -join ' and ')) }
    return ('{0} incomplete: {1}' -f ($Phases -join ' and '), ($Messages -join ' '))
}

# Discover every per-stream resume-state file on disk for a tenant, rather
# than iterating 0..($StreamCount-1). $StreamCount reflects THIS run's
# -ParallelStreams value; if an earlier interrupted run used a LARGER value,
# its higher-numbered per-stream files would otherwise never be read (losing
# their Completed/FailedAttempts data) nor cleaned up (leaving them as
# orphans). -Force is required because these filenames are dot-prefixed and
# Get-ChildItem hides dot-files by default on Unix. Pulled out to its own
# function purely so it can be exercised by a Pester test against a temp
# directory without spinning up any streams.
function Get-StreamResumeStateFiles
{
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant
    )
    return @(Get-ChildItem -Path $InventoryRoot -Filter (".resume-state-{0}-stream-*.json" -f $Tenant) -File -Force -ErrorAction SilentlyContinue)
}

# Read one per-stream resume-state file. Returns its content, or $null when the
# file cannot be read or does not hold a JSON object. A write cut short leaves a
# partial file, which fails to parse, or an empty one, which ConvertFrom-Json
# turns into $null without an error; both come back as $null here.
function Read-StreamResumeStateFile
{
    param([Parameter(Mandatory = $true)][string]$Path)
    try
    {
        $Obj = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        return $null
    }
    if ($Obj -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    return $Obj
}

# A per-stream state file that a run cannot read: the startup fold of a
# resuming run (an interrupted write can leave it cut short), or, with
# -AtRunEnd, the end-of-run merge of a parallel run (Read-StreamResumeStateFile).
# Its records are not used, so the subscriptions it lists are not counted as
# completed: at startup a -Resume run collects them again, and under
# -ResumeFailedOnly a later -Resume does; after the end-of-run merge a later
# -Resume collects them. The file is renamed in place to
# <name>.unreadable-<UTC time> and kept for inspection: that name ends neither
# in '.json' nor matches Get-StreamResumeStateFiles, so no later run reads it
# and no zip step that picks files by '*.json' takes it. Prints a warning
# naming the file, never its content. Returns { Name; MovedTo } (MovedTo is
# $null when the rename failed).
function Move-UnreadableStreamStateFile
{
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$File,
        [datetime]$Now = [datetime]::UtcNow,
        # -ResumeFailedOnly retries only the retry list, so it does not collect
        # the subscriptions the file lists; a later -Resume does.
        [switch]$ResumeFailedOnly,
        # Found by the end-of-run merge of a parallel run, after collection.
        [switch]$AtRunEnd
    )
    $MovedTo = '{0}.unreadable-{1}' -f $File.Name, $Now.ToString('yyyyMMdd-HHmmss')
    if ($AtRunEnd)
    {
        $Lead = 'WARNING: The per-stream state file {0} could not be read, so its records are not used: the subscriptions it lists are not counted as completed, and a later -Resume collects them again.' -f $File.Name
        $Again = 'a later run'
    }
    else
    {
        $Then = if ($ResumeFailedOnly) { 'a later -Resume collects them (-ResumeFailedOnly retries only the retry list)' } else { 'this run collects them again' }
        $Lead = 'WARNING: The per-stream state file {0} from an interrupted parallel run could not be read, so its records are not used: the subscriptions it lists are not counted as completed and {1}.' -f $File.Name, $Then
        $Again = 'a later -Resume'
    }
    try
    {
        Rename-Item -LiteralPath $File.FullName -NewName $MovedTo -ErrorAction Stop
        Write-Host ('{0} It was moved aside to {1}.' -f $Lead, $MovedTo) -ForegroundColor Yellow
    }
    catch
    {
        $MovedTo = $null
        Write-Host ('{0} It could not be moved aside ({1}), so {2} finds it again.' -f $Lead, $_.Exception.Message, $Again) -ForegroundColor Yellow
    }
    return [pscustomobject]@{ Name = $File.Name; Path = $File.FullName; MovedTo = $MovedTo }
}

# A per-stream state file that cannot be moved aside stays under its active
# name, so every later run would find it again and warn about it again, with
# no end. The run stops instead: this names each such file and prints the
# command that removes it. Each item is { Name; Path } (Path is the full path).
# The caller exits 1; the next run goes on once the files are gone.
function Write-StreamStateFileStop
{
    param([object[]]$Files, [string]$Why = 'could not be read')
    $Stuck = @($Files | Where-Object { $null -ne $_ })
    if ($Stuck.Count -eq 0) { return }
    Write-Host ''
    Write-Host '============== STOPPED (per-stream state file left in place) ==============' -ForegroundColor Red
    foreach ($File in $Stuck)
    {
        Write-Host ('The per-stream state file {0} {1} and could not be moved aside, so every run would find it again.' -f $File.Path, $Why) -ForegroundColor Red
    }
    Write-Host 'Remove it (or let this account rename files in that folder), then run again:' -ForegroundColor Red
    foreach ($File in $Stuck)
    {
        Write-Host ("  Remove-Item -LiteralPath '{0}' -Force" -f ([string]$File.Path).Replace("'", "''")) -ForegroundColor Red
    }
    Write-Host '==========================================================================' -ForegroundColor Red
}

# The per-stream state files a run WITHOUT -Resume or -ResumeFailedOnly finds
# at startup: an interrupted parallel run left them, and their records belong to
# that earlier run. This run collects every subscription again, so they are not
# folded in; left under their active names, a later -Resume would fold them in
# and skip a subscription they list as completed, carrying an old report. Each
# is renamed to <name>.stranded-<UTC time>, which ends neither in '.json' nor
# matches Get-StreamResumeStateFiles, so no later run reads it and no zip step
# takes it. The files themselves are renamed, not deleted; only the newest
# moved-aside set is kept, so the sets of earlier runs are removed once this
# set is in place. Returns the
# files that could not be renamed ({ Name; Path }), for Write-StreamStateFileStop.
function Move-StrandedStreamStateFiles
{
    param(
        [System.IO.FileInfo[]]$Files,
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [datetime]$Now = [datetime]::UtcNow
    )
    $Suffix = '.stranded-{0}' -f $Now.ToString('yyyyMMdd-HHmmss')
    $Moved = @()
    $Stuck = @()
    foreach ($File in @($Files | Where-Object { $null -ne $_ }))
    {
        try
        {
            Rename-Item -LiteralPath $File.FullName -NewName ($File.Name + $Suffix) -ErrorAction Stop
            $Moved += ($File.Name + $Suffix)
        }
        catch
        {
            $Stuck += [pscustomobject]@{ Name = $File.Name; Path = $File.FullName }
        }
    }
    if ($Moved.Count -gt 0)
    {
        Write-Host ('Moved aside {0} per-stream state file(s) an interrupted parallel run left: this run collects every subscription again, so their records are not used. Kept as: {1}' -f $Moved.Count, ($Moved -join ', ')) -ForegroundColor Yellow
        $Pattern = [System.Management.Automation.WildcardPattern]::Escape(('.resume-state-{0}-stream-' -f $Tenant)) + '*.json.stranded-*'
        $Older = @(Get-ChildItem -LiteralPath $InventoryRoot -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $Pattern -and -not $_.Name.EndsWith($Suffix) })
        foreach ($Old in $Older)
        {
            try { Remove-Item -LiteralPath $Old.FullName -Force -ErrorAction Stop }
            catch { Write-Host ('WARNING: Could not remove {0}, an older moved-aside per-stream state file: {1}' -f $Old.Name, $_.Exception.Message) -ForegroundColor Yellow }
        }
    }
    return $Stuck
}

# The end-of-run line for each per-stream state file this run could not read
# (Move-UnreadableStreamStateFile): whether the resume state was cleared or
# kept, and where the file went. Such a run is not a clean run, whatever else
# happened, so it never prints "Resume state cleared (clean run).".
function Write-UnreadableStreamStateSummary
{
    param([object[]]$Unreadable, [bool]$StateKept)
    $Word = if ($StateKept) { 'kept' } else { 'cleared' }
    foreach ($File in @($Unreadable | Where-Object { $null -ne $_ }))
    {
        $Where = if ([string]::IsNullOrEmpty([string]$File.MovedTo)) { 'was left in place (it could not be moved aside)' } else { 'was moved aside to {0}' -f $File.MovedTo }
        Write-Host ('Resume state {0}, but not a clean run: the per-stream state file {1} could not be read and {2}; its records were not used.' -f $Word, $File.Name, $Where) -ForegroundColor Yellow
    }
}

# Remove the resume state at the end of a run that clears it: first each
# per-stream state file in -StreamFiles (the ones this run read), then the
# resume state file -StateFile. Each removal stops on an error and is then
# checked: a file that is still there gets a warning naming it. While a
# per-stream file is left, the resume state file is kept too, so the next
# -Resume reads the same state and that per-stream file again. Only some runs
# remove per-stream files, so the warning asks for the named files to be
# removed once the folder can be written. Returns the paths left on disk (none
# when all were removed).
function Remove-ResumeStateFiles
{
    param([string[]]$StreamFiles = @(), [Parameter(Mandatory = $true)][string]$StateFile)
    $Left = [System.Collections.Generic.List[string]]::new()
    foreach ($Path in @(@($StreamFiles | Where-Object { -not [string]::IsNullOrEmpty($_) }) + $StateFile))
    {
        $IsState = $Path -eq $StateFile
        if ($IsState -and $Left.Count -gt 0)
        {
            Write-Host ('  The resume state file {0} is kept, so the next -Resume reads the same state and the per-stream state file(s) above again. Once the folder can be written, remove the file(s) named above.' -f (Split-Path -Path $StateFile -Leaf)) -ForegroundColor Yellow
            $Left.Add($Path)
            continue
        }
        $Reason = $null
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        catch { $Reason = $_.Exception.Message }
        if (-not (Test-Path -LiteralPath $Path)) { continue }
        if ([string]::IsNullOrEmpty($Reason)) { $Reason = 'it is still there after the removal' }
        $What = if ($IsState) { 'resume state file' } else { 'per-stream state file' }
        Write-Host ('WARNING: Could not remove the {0} {1}: {2}' -f $What, (Split-Path -Path $Path -Leaf), $Reason) -ForegroundColor Yellow
        if ($IsState) { Write-Host '  The next run reads it again and retries the removal.' -ForegroundColor Yellow }
        $Left.Add($Path)
    }
    return $Left.ToArray()
}

# Remove per-stream state files while the resume state file stays: the files a
# run that keeps the resume state folded in at startup, or that its streams
# wrote. Each removal stops on an error and is then checked, with the same
# warning as Remove-ResumeStateFiles, and the same line under it: the resume
# state file is kept, so the next -Resume reads the same state and the named
# files again. Returns the paths left on disk (none when all were removed).
function Remove-StreamStateFiles
{
    param([string[]]$StreamFiles = @(), [Parameter(Mandatory = $true)][string]$StateFile)
    $Left = [System.Collections.Generic.List[string]]::new()
    foreach ($Path in @($StreamFiles | Where-Object { -not [string]::IsNullOrEmpty($_) }))
    {
        $Reason = $null
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        catch { $Reason = $_.Exception.Message }
        if (-not (Test-Path -LiteralPath $Path)) { continue }
        if ([string]::IsNullOrEmpty($Reason)) { $Reason = 'it is still there after the removal' }
        Write-Host ('WARNING: Could not remove the per-stream state file {0}: {1}' -f (Split-Path -Path $Path -Leaf), $Reason) -ForegroundColor Yellow
        $Left.Add($Path)
    }
    if ($Left.Count -gt 0)
    {
        Write-Host ('  The resume state file {0} is kept, so the next -Resume reads the same state and the per-stream state file(s) above again. Once the folder can be written, remove the file(s) named above.' -f (Split-Path -Path $StateFile -Leaf)) -ForegroundColor Yellow
    }
    return $Left.ToArray()
}

# The ids among $Ids whose record in the resume state file on disk is not the
# one this run holds in $CompletedIds and $FailedAttempts: listed as completed
# or not, on the retry list or not, and the retry entry's Attempts. Every id
# comes back when the file is missing, cannot be read or is for another tenant.
# Read before the per-stream state files folded in at startup are deleted, so
# they are deleted only once the resume state holds their records.
function Get-ResumeStateRecordMismatch
{
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Tenant,
        # [object]: a one-item list arrives as a bare string or object.
        [object]$Ids,
        [object]$CompletedIds,
        [object]$FailedAttempts
    )
    $Wanted = @($Ids | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if ($Wanted.Count -eq 0) { return @() }
    try
    {
        $State = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        return $Wanted
    }
    if ($State -isnot [System.Management.Automation.PSCustomObject] -or [string]$State.TenantID -ne $Tenant) { return $Wanted }
    $OnDiskCompleted = @($State.CompletedSubscriptionIds | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $RunCompleted = @($CompletedIds | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $OnDiskRetry = @{}
    foreach ($Entry in @($State.FailedAttempts | Where-Object { $_ })) { $OnDiskRetry[[string]$Entry.Id] = [string]$Entry.Attempts }
    $RunRetry = @{}
    foreach ($Entry in @($FailedAttempts | Where-Object { $_ })) { $RunRetry[[string]$Entry.Id] = [string]$Entry.Attempts }
    return @($Wanted | Where-Object {
            (($OnDiskCompleted -contains $_) -ne ($RunCompleted -contains $_)) -or
            ($OnDiskRetry.ContainsKey($_) -ne $RunRetry.ContainsKey($_)) -or
            ($RunRetry.ContainsKey($_) -and $OnDiskRetry[$_] -ne $RunRetry[$_])
        })
}

# For a run that keeps the resume state (at the end of the run, or when it
# ends early): delete per-stream state files ($Files, the ids they hold records
# for in $Ids) once the resume state file on disk holds those records as this
# run holds them (Get-ResumeStateRecordMismatch); each removal is checked
# (Remove-StreamStateFiles). Otherwise keep them, with a warning naming them, so
# a later -Resume folds them in again and nothing is lost. The files are the
# ones the run folded in at startup, or, after the end-of-run merge of a
# parallel run, the ones its streams wrote ($Source says which, for the
# warning). Returns the paths left on disk.
function Invoke-FoldedStreamStateCleanup
{
    param(
        [object]$Files,
        [Parameter(Mandatory = $true)][string]$ResumeStateFile,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [object]$Ids,
        [object]$CompletedIds,
        [object]$FailedAttempts,
        [string]$Source = 'this run read at startup'
    )
    $Left = @($Files | Where-Object { $null -ne $_ -and (Test-Path -LiteralPath $_.FullName -PathType Leaf) })
    if ($Left.Count -eq 0) { return @() }
    $NotHeld = @(Get-ResumeStateRecordMismatch -Path $ResumeStateFile -Tenant $Tenant -Ids $Ids -CompletedIds $CompletedIds -FailedAttempts $FailedAttempts)
    if ($NotHeld.Count -gt 0)
    {
        Write-Host ("WARNING: The resume state file {0} could not be written or read back with every record of the per-stream state files {1}, so they are kept and a later -Resume reads them again: {2}" -f (Split-Path -Path $ResumeStateFile -Leaf), $Source, (@($Left | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
        return @($Left | ForEach-Object { $_.FullName })
    }
    return @(Remove-StreamStateFiles -StreamFiles @($Left | ForEach-Object { $_.FullName }) -StateFile $ResumeStateFile)
}

# The subscriptions the up-front role check skipped for a cause that can pass
# on a later run: the check could not finish (Unknown), or the two answers
# disagree while a role change takes effect (Disagree). Each one is put on the
# retry list as a failed run (Add-FailedAttempt, so the run count goes up) and
# taken off the completed list, so the resume state is kept and -Resume and
# -ResumeFailedOnly check it again; the retry limit ends the retries of one
# that keeps failing. A subscription skipped for a missing role is not added:
# it needs Reader first. Pure; the caller persists. Returns
# { FailedAttempts; CompletedIds; Added }.
function Add-RoleCheckRetryAttempts
{
    param([object]$FailedAttempts, [object]$CompletedIds, $Decision)
    $Added = @(if ($null -ne $Decision) { @($Decision.Inaccessible) | Where-Object { $null -ne $_ -and @('Unknown', 'Disagree') -contains [string]$_.State } })
    $List = @($FailedAttempts | Where-Object { $_ })
    foreach ($Skip in $Added)
    {
        $List = @(Add-FailedAttempt -Existing $List -Id ([string]$Skip.Id) -Name ([string]$Skip.Name) -Reason ('skipped by the up-front role check: {0}' -f $Skip.Reason))
    }
    $AddedIds = @($Added | ForEach-Object { [string]$_.Id })
    return [pscustomobject]@{
        FailedAttempts = $List
        CompletedIds   = @(@($CompletedIds) | Where-Object { $_ -and $AddedIds -notcontains [string]$_ })
        Added          = $Added
    }
}

# Write the retry list and the completed ids into the resume state file and
# leave every other key the file holds as it is, so records other code keeps
# there survive. Writes a new file through Save-CompletedSubscriptionIds when
# there is none (or it is for another tenant or cannot be read). Same atomic
# write as Save-CompletedSubscriptionIds.
function Update-ResumeStateRetryList
{
    param([string]$Path, [string]$Tenant, [string[]]$Ids, $FailedAttempts = @())
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $State = $null
    if (Test-Path -LiteralPath $Path -PathType Leaf)
    {
        try { $State = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $State = $null }
    }
    if ($null -eq $State -or $State -isnot [pscustomobject] -or [string]$State.TenantID -ne $Tenant)
    {
        Save-CompletedSubscriptionIds -Path $Path -Tenant $Tenant -Ids $Ids -FailedAttempts $FailedAttempts
        return
    }
    $State | Add-Member -NotePropertyName CompletedSubscriptionIds -NotePropertyValue @($Ids) -Force
    $State | Add-Member -NotePropertyName FailedAttempts -NotePropertyValue @($FailedAttempts) -Force
    $State | Add-Member -NotePropertyName LastUpdated -NotePropertyValue (Get-Date).ToString('o') -Force
    try
    {
        $TmpPath = "$Path.tmp"
        $State | ConvertTo-Json -Depth 6 | Set-Content -Path $TmpPath -Encoding utf8
        [System.IO.File]::Move($TmpPath, $Path, $true)
    }
    catch
    {
        Write-Host ("WARNING: Failed to persist resume state to {0}: $_" -f $Path) -ForegroundColor Yellow
        Remove-Item -LiteralPath "$Path.tmp" -Force -ErrorAction SilentlyContinue
    }
}

# Reconcile FailedAttempts entries gathered from multiple streams (plus any
# pre-existing entries) against the unified CompletedIds list.
#   - A sub that now appears in CompletedIds (any stream, or a prior run,
#     succeeded for it) is dropped entirely.
#   - Otherwise, when the same sub failed in more than one place, the entry
#     with the most recent LastFailedAt wins - so a stale failure recorded
#     before a later, more informative failure never shadows it.
# Pulled out to its own function (previously inlined) so this decision can
# be unit-tested directly instead of only via full multi-stream runs.
function Merge-FailedAttempts
{
    param(
        # [object], not [System.Collections.IEnumerable], for all three: same
        # single-element-collapse hazard as Add-/Remove-FailedAttempt. When any
        # of these lists holds exactly one item it arrives as a scalar
        # PSCustomObject/string, which is not IEnumerable and would throw a
        # parameter-transformation error. Every use below is already @()-wrapped,
        # so scalar/$null/array all normalize correctly.
        [object]$ExistingFailedAttempts,
        [object]$StreamFailedAttempts,
        [object]$CompletedIds
    )
    $CompletedIds = @($CompletedIds)
    if (@($StreamFailedAttempts).Count -eq 0)
    {
        # No new stream failures: still prune any existing entry whose sub
        # now appears in CompletedIds (a different stream succeeded for it).
        return @($ExistingFailedAttempts | Where-Object { $_ -and -not ($CompletedIds -contains $_.Id) })
    }
    $Merged = @($ExistingFailedAttempts) + @($StreamFailedAttempts)
    $ById = $Merged | Where-Object { $_ } | Group-Object -Property Id
    $Reconciled = @()
    foreach ($g in $ById)
    {
        if ($CompletedIds -contains $g.Name) { continue }
        $Best = $g.Group | Sort-Object -Property @{Expression = { [datetime]($_.LastFailedAt) } } -Descending | Select-Object -First 1
        $Reconciled += $Best
    }
    return $Reconciled
}

# The eligible subscriptions that no run has completed and that are not on the
# retry list: after an interrupted run, the ones it never reached.
# -ResumeFailedOnly retries only the retry list, so it does not collect these;
# -Resume does. A subscription the up-front access check skipped as not readable
# (-NotReadableIds) is left out: the run that skipped it already listed it, and
# a later run checks it again.
function Get-NotCollectedSubscriptions
{
    param([object]$Eligible, [object]$CompletedIds, [object]$RetryIds, [object]$NotReadableIds)
    $Done = @(@($CompletedIds) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $Retry = @(@($RetryIds) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $NotReadable = @(@($NotReadableIds) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    return @(@($Eligible) | Where-Object { $null -ne $_ -and $Done -notcontains [string]$_.Id -and $Retry -notcontains [string]$_.Id -and $NotReadable -notcontains [string]$_.Id })
}

# Name the subscriptions Get-NotCollectedSubscriptions returned on a
# -ResumeFailedOnly run, which keeps the resume state for them. Prints nothing
# for an empty list.
function Write-NotCollectedSummary
{
    param([object]$NotCollected, [string]$ResumeStateFile)
    $List = @(@($NotCollected) | Where-Object { $null -ne $_ })
    if ($List.Count -eq 0) { return }
    Write-Host ("Not Collected:           {0} ({1}) - no run has completed these and -ResumeFailedOnly retries only the retry list" -f $List.Count, (@($List | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
    Write-Host ("Resume State:            {0} (kept)" -f $ResumeStateFile) -ForegroundColor Yellow
    Write-Host "Re-run with -Resume to collect them; it skips the subscriptions already completed." -ForegroundColor Yellow
}

# The number of failed runs a retry-list entry records (its Attempts): one more
# for each run that failed the subscription, removed when it completes. An entry
# without a whole number of at least 1 there (written by hand, or damaged) counts
# as one failed run, so it is retried as before instead of stopping the run.
function Get-FailedAttemptCount
{
    param([object]$Entry)
    $Count = 0
    if ($null -ne $Entry -and [int]::TryParse([string]$Entry.Attempts, [ref]$Count) -and $Count -ge 1) { return $Count }
    return 1
}

# The retry-list entries of the subscriptions that failed $RetryLimit runs in a
# row. -Resume and -ResumeFailedOnly do not collect these; a run without either
# still does, and so does ./ResourceInventory.ps1 -SubscriptionID on its own.
function Get-RetryLimitedAttempts
{
    param([object]$FailedAttempts)
    $RetryLimit = 3
    return @(@($FailedAttempts) | Where-Object { $null -ne $_ -and (Get-FailedAttemptCount -Entry $_) -ge $RetryLimit })
}

# Name the retry-list entries Get-RetryLimitedAttempts returned at the end of a
# run, with their count and last reason, as incomplete. Prints nothing for an
# empty list.
function Write-RetryLimitSummary
{
    param([object]$RetryLimited, [string]$TenantID)
    $List = @(@($RetryLimited) | Where-Object { $null -ne $_ })
    if ($List.Count -eq 0) { return }
    Write-Host ("Retry Limit Reached:     {0} ({1}) - incomplete; -Resume and -ResumeFailedOnly do not collect these" -f $List.Count, (@($List | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
    foreach ($Entry in $List)
    {
        Write-Host ("  - {0} ({1}): failed {2} runs in a row; last reason: {3}" -f $Entry.Name, $Entry.Id, (Get-FailedAttemptCount -Entry $Entry), $Entry.Reason) -ForegroundColor Yellow
    }
    Write-Host "  To try one again, run it on its own, or start a run without -Resume:" -ForegroundColor Yellow
    foreach ($Entry in $List)
    {
        Write-Host ("    ./ResourceInventory.ps1 -TenantID {0} -SubscriptionID {1}" -f $TenantID, $Entry.Id) -ForegroundColor Yellow
    }
}

# The resume-state record for one completed subscription's report zip:
# { Id, Name, Zip, Obfuscated }, where Zip is the path relative to the inventory
# root (so the state still resolves if the root is mounted elsewhere later) and
# Obfuscated is the -Obfuscate setting the report was written with. Returns $null
# when there is no zip on disk at $ZipPath or it is not under the inventory root;
# such a subscription is then reported by a later -Resume run instead of carried.
function New-CompletedReportRecord
{
    param(
        [string]$InventoryRoot,
        [string]$Id,
        [string]$Name,
        [string]$ZipPath,
        [bool]$Obfuscated
    )
    if ([string]::IsNullOrWhiteSpace($InventoryRoot) -or [string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($ZipPath)) { return $null }
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { return $null }
    try
    {
        $Rel = [System.IO.Path]::GetRelativePath([System.IO.Path]::GetFullPath($InventoryRoot), [System.IO.Path]::GetFullPath($ZipPath))
    }
    catch
    {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($Rel) -or (@($Rel -split '[\\/]') -contains '..')) { return $null }
    return [pscustomobject]@{
        Id         = $Id
        Name       = $Name
        Zip        = $Rel
        Obfuscated = $Obfuscated
    }
}

# Index report records by subscription id, the last record for an id winning.
# Entries that are not objects with a non-empty string Id (a hand-edited or
# corrupted state file) are ignored, so they read as "no record" for that id.
function Get-LatestCompletedReports
{
    param([object]$Reports)
    $ById = @{}
    foreach ($Report in @($Reports))
    {
        if ($null -eq $Report -or $Report -is [string] -or $Report -is [ValueType]) { continue }
        $IdProp = $Report.PSObject.Properties['Id']
        if ($null -eq $IdProp -or $IdProp.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($IdProp.Value)) { continue }
        $ById[$IdProp.Value] = $Report
    }
    return $ById
}

# Decide, for each subscription a -Resume run skipped because an earlier run
# completed it, whether that earlier run's report zip can go into this run's
# consolidated zip. A record is carried only when its path is a relative path
# inside the inventory root, names a .zip that is not a de-obfuscated
# (*_revealed*) copy, exists, opens as a zip with at least one entry, and was
# written with the same -Obfuscate setting as this run, so one bundle never mixes
# obfuscated and real identifiers. Everything else is returned under Missing with
# the reason. Cost: one file-exists check and one zip-directory read per skipped
# subscription; no Azure calls. Returns { Carried = @({ Id, Name, Zip, Folder }),
# Missing = @({ Id, Name, Reason }) }, where Zip is the full path.
function Get-ResumeCarriedReports
{
    param(
        [object]$SkippedSubscriptions = @(),
        [object]$Reports = @(),
        [string]$InventoryRoot,
        [bool]$Obfuscated = $false
    )
    $ById = Get-LatestCompletedReports -Reports $Reports
    $Carried = @()
    $Missing = @()
    $SeenIds = @{}
    foreach ($Sub in @($SkippedSubscriptions))
    {
        if ($null -eq $Sub -or [string]::IsNullOrWhiteSpace([string]$Sub.Id)) { continue }
        $Id = [string]$Sub.Id
        if ($SeenIds.ContainsKey($Id)) { continue }
        $SeenIds[$Id] = $true

        $Record = if ($ById.ContainsKey($Id)) { $ById[$Id] } else { $null }
        $Reason = $null
        $FullPath = $null
        if ($null -eq $Record)
        {
            $Reason = 'the resume state records no report zip for it (state written by an older version of this tool)'
        }
        else
        {
            $Zip = $Record.PSObject.Properties['Zip']
            $Obf = $Record.PSObject.Properties['Obfuscated']
            if ($null -eq $Zip -or $Zip.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Zip.Value))
            {
                $Reason = 'its report path in the resume state is missing or not text'
            }
            elseif ($null -eq $Obf -or $Obf.Value -isnot [bool])
            {
                $Reason = 'its -Obfuscate setting in the resume state is missing or not true/false'
            }
            else
            {
                $Rel = $Zip.Value
                try
                {
                    $Unsafe = [System.IO.Path]::IsPathRooted($Rel) -or (@($Rel -split '[\\/]') -contains '..')
                    if (-not $Unsafe) { $FullPath = [System.IO.Path]::GetFullPath((Join-Path $InventoryRoot $Rel)) }
                }
                catch
                {
                    $Unsafe = $true
                }
                if ($Unsafe)
                {
                    $Reason = 'its report path in the resume state is not a path inside the inventory root'
                }
                elseif ([System.IO.Path]::GetExtension($FullPath) -ne '.zip' -or [System.IO.Path]::GetFileName($FullPath) -like '*_revealed*')
                {
                    $Reason = ('its report path in the resume state is not a report zip: {0}' -f $Rel)
                }
                elseif (-not (Test-Path -LiteralPath $FullPath -PathType Leaf))
                {
                    $Reason = ('its report zip is no longer on disk: {0}' -f $Rel)
                }
                else
                {
                    $EntryCount = -1
                    try
                    {
                        Add-Type -AssemblyName System.IO.Compression.FileSystem
                        $Archive = [System.IO.Compression.ZipFile]::OpenRead($FullPath)
                        try { $EntryCount = $Archive.Entries.Count }
                        finally { $Archive.Dispose() }
                    }
                    catch
                    {
                        Write-Verbose ("Could not open {0} as a zip: {1}" -f $FullPath, $_.Exception.Message)
                    }
                    if ($EntryCount -lt 0)
                    {
                        $Reason = ('its report zip cannot be opened as a zip: {0}' -f $Rel)
                    }
                    elseif ($EntryCount -eq 0)
                    {
                        $Reason = ('its report zip is empty: {0}' -f $Rel)
                    }
                    elseif ($Obf.Value -ne $Obfuscated)
                    {
                        $WasText = if ($Obf.Value) { 'with' } else { 'without' }
                        $NowText = if ($Obfuscated) { 'with' } else { 'without' }
                        $Reason = ('its report was written {0} -Obfuscate and this run is {1} it, and one bundle never mixes the two: {2}' -f $WasText, $NowText, $Rel)
                    }
                }
            }
        }

        if ($null -eq $Reason)
        {
            $Carried += [pscustomobject]@{
                Id     = $Id
                Name   = [string]$Sub.Name
                Zip    = $FullPath
                Folder = Split-Path -Path (Split-Path -Path $FullPath -Parent) -Leaf
            }
        }
        else
        {
            $Missing += [pscustomobject]@{ Id = $Id; Name = [string]$Sub.Name; Reason = $Reason }
        }
    }
    return [pscustomobject]@{ Carried = $Carried; Missing = $Missing }
}

# This run's per-subscription zips plus the zips carried from an earlier run
# (Get-ResumeCarriedReports), each file once, this run's first. Used by both the
# output verification and the consolidation so they always count the same set.
function Join-CarriedReportZips
{
    param([object]$Zips = @(), [object]$CarriedReports = @())
    $Seen = @{}
    $Result = @()
    $CarriedItems = @(foreach ($C in @($CarriedReports)) { if ($null -ne $C -and -not [string]::IsNullOrWhiteSpace([string]$C.Zip)) { Get-Item -LiteralPath $C.Zip -ErrorAction SilentlyContinue } })
    foreach ($Item in @(@($Zips) + $CarriedItems))
    {
        if ($null -eq $Item -or $Seen.ContainsKey($Item.FullName)) { continue }
        $Seen[$Item.FullName] = $true
        $Result += $Item
    }
    return $Result
}

# Machine-facing signal. Exit code 3 == "completed, but a requested data phase
# was auth-skipped". Exit code 4 == "completed, but one or more collectors
# failed for one or more subscriptions" (#22). Exit code 5 == BOTH occurred in
# the same run. A plain if/elseif chain would let 3 mask 4 (or vice versa) when
# both problems occur together, silently hiding one from any automation that
# only checks the exit code (the console banners above always print both
# independently, but the exit code itself must not lose information either -
# same "do not sweep failures under the rug" requirement as everywhere else in
# this fix). Distinct from the existing codes (1 = hard pre-flight / auth /
# setup failure, 2 = per-subscription output verification gap, 0 = clean).
# Nothing inside this repo consumes the WRAPPER's exit code (it is the
# top-level entrypoint); the inner ResourceInventory.ps1 exit code is left
# UNCHANGED because the wrapper treats inner non-zero as "this whole
# subscription failed" (see the $LASTEXITCODE checks in the run loops).
#
# Priority logic pulled into its own function so it is independently
# unit-testable (see Tests/RunAllSubscriptionsReconciliation.Tests.ps1) without
# requiring a live wrapper run. Pure function: two booleans in, exit code out.
function Get-WrapperExitCode
{
    param(
        [bool]$AuthSkipped,
        [bool]$CollectorsFailed,
        # A -Resume run skipped a subscription whose earlier report zip could not
        # be carried into the consolidated zip, so that report is missing from it.
        # Same meaning as the verification gap (2) and takes precedence over 3-5:
        # a missing report is worse than an incomplete one.
        [bool]$ReportsMissing = $false,
        # A subscription failed this run (it is listed under Subscriptions
        # Failed), so its report is missing from the consolidated zip: the same
        # meaning as a missing report, so 2, and the run is never reported as clean.
        [bool]$SubscriptionsFailed = $false
    )
    if ($ReportsMissing -or $SubscriptionsFailed) { return 2 }
    if ($AuthSkipped -and $CollectorsFailed) { return 5 }
    if ($AuthSkipped) { return 3 }
    if ($CollectorsFailed) { return 4 }
    return 0
}

# ---- Stream worker output + per-stream state --------------------------------

function Write-Stream
{
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ("{0} {1}" -f $Tag, $Message) -ForegroundColor $Color
}

function Read-StreamState
{
    param([string]$Path)
    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @{ Completed = @(); Failed = @(); Reports = @() } }
    try
    {
        $Obj = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return @{
            Completed = if ($null -eq $Obj.Completed) { @() } else { @($Obj.Completed) }
            # Backward-compatible: state files written by an older worker had
            # no FailedAttempts key, so default to @(). Files written before
            # Write-StreamState dropped null entries can hold one; skip it.
            Failed    = if ($null -eq $Obj.FailedAttempts) { @() } else { @($Obj.FailedAttempts | Where-Object { $_ }) }
            # Same for Reports (see New-CompletedReportRecord).
            Reports   = if ($null -eq $Obj.Reports) { @() } else { @($Obj.Reports) }
        }
    }
    catch
    {
        Write-Stream ("WARNING: could not read stream state at {0}: {1}" -f $Path, $_.Exception.Message) 'Yellow'
        return @{ Completed = @(); Failed = @(); Reports = @() }
    }
}

function Write-StreamState
{
    param([string]$Path, [string[]]$Completed, $FailedAttempts = @(), $Reports = @())
    try
    {
        @{
            Tenant         = $TenantID
            StreamId       = $StreamId
            Completed      = $Completed
            # Remove-FailedAttempt returns nothing once the list is empty, and
            # @($null) is a one-entry array; drop that entry so the file holds
            # only real failure records.
            FailedAttempts = @($FailedAttempts | Where-Object { $_ })
            Reports        = @($Reports)
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding utf8
    }
    catch
    {
        Write-Stream ("WARNING: failed to persist stream state to {0}: {1}" -f $Path, $_.Exception.Message) 'Yellow'
    }
}


# Build the run-level "RunSummary.log" content for the consolidated
# AllSubscriptions zip. Pure and deterministic apart from the generation
# timestamp (no file I/O, no Azure calls) so it is unit-testable offline: the
# caller writes the returned lines to RunSummary.log and adds that file to the
# outer zip.
#
# Safety posture: the wrapper does NOT hold the per-subscription obfuscation
# dictionaries (those live in the child ResourceInventory.ps1 scope - in a
# separate process for parallel runs), so it CANNOT tokenize a real identifier.
# Therefore an obfuscated run emits COUNTS ONLY - never subscription names, ids,
# or raw failure messages - so the shipped log is safe to share. A
# non-obfuscated run emits the per-subscription detail (names / ids / messages),
# consistent with the rest of that (non-obfuscated) bundle. The TenantID and
# SubscriptionID parameters are always dropped from the recorded parameter list
# regardless of mode (the operator asked for the invocation flags, not the
# targeted identifiers).
function Get-RunSummaryLogContent
{
    param(
        # PSBoundParameters (or any name -> value map) of the wrapper invocation.
        [System.Collections.IDictionary]$InvocationParameters = @{},
        [string]$Version,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$Visible,
        [int]$Excluded,
        [int]$Eligible,
        [int]$Processed,
        [int]$Skipped,
        # Per-subscription health collections ({ Name; Id } / { Name; Id; Message }).
        $EmptyNoAccess = @(),
        $EmptyGenuinelyEmpty = @(),
        $EmptyUndetermined = @(),
        $FailedSubscriptions = @(),
        $CollectorFailures = @(),
        $MetricsFailedSubs = @(),
        $ConsumptionFailedSubs = @(),
        # Retry-list entries past the retry limit ({ Name; Id; Attempts; Reason }),
        # from Get-RetryLimitedAttempts.
        $RetryLimited = @(),
        [int]$ConsumptionRecordCount = 0,
        # Host size and resolved parallelism (run-environment metadata, not
        # identifiers). Emitted in both modes. Defaults mean "not supplied" and
        # the whole section is omitted (keeps standalone/offline callers clean).
        [int]$HostVCpu = 0,
        [double]$HostRamGB = 0,
        [int]$Streams = 0,
        [string]$StreamsSource,
        [int]$Concurrency = 0,
        [string]$ConcurrencySource,
        # When set, emit counts only (no names / ids / raw messages).
        [switch]$Obfuscated
    )

    # Parameters that identify the TARGET rather than describe the run - never
    # recorded, in either mode. Matched case-insensitively.
    $ExcludedParamNames = @('TenantID', 'SubscriptionID', 'InventoryRoot')

    # Valued (non-switch) parameters whose VALUE is safe to print verbatim even in
    # an obfuscated bundle (tuning knobs, never identifiers). Any other valued
    # parameter has its value omitted under -Obfuscated so a future value-carrying
    # parameter cannot leak into a shared log.
    $SafeValueParamNames = @('ParallelStreams', 'ConcurrencyLimit')

    # Normalise possibly-$null collections to real arrays so .Count is stable.
    $NoAccess = @(@($EmptyNoAccess) | Where-Object { $null -ne $_ })
    $Empty = @(@($EmptyGenuinelyEmpty) | Where-Object { $null -ne $_ })
    $Undetermined = @(@($EmptyUndetermined) | Where-Object { $null -ne $_ })
    $Failed = @(@($FailedSubscriptions) | Where-Object { $null -ne $_ })
    $Collector = @(@($CollectorFailures) | Where-Object { $null -ne $_ })
    $Metrics = @(@($MetricsFailedSubs) | Where-Object { $null -ne $_ })
    $Consumption = @(@($ConsumptionFailedSubs) | Where-Object { $null -ne $_ })
    $Limited = @(@($RetryLimited) | Where-Object { $null -ne $_ })

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add('Resource Discovery for Azure - run summary')
    if ($Obfuscated)
    {
        $Lines.Add('Obfuscated run: subscription names/ids and raw error text are omitted')
        $Lines.Add('(counts only) so this log is safe to share.')
    }
    else
    {
        $Lines.Add('Non-obfuscated run: contains real subscription names/ids.')
    }
    $Lines.Add(('Generated (UTC) : {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')))
    $Lines.Add(('Tool version    : {0}' -f [string]$Version))
    if ($StartTime -is [datetime] -and $StartTime -ne [datetime]::MinValue)
    {
        $Lines.Add(('Run started     : {0}' -f $StartTime.ToString('yyyy-MM-dd HH:mm:ss')))
    }
    if ($EndTime -is [datetime] -and $EndTime -ne [datetime]::MinValue)
    {
        $Lines.Add(('Run finished    : {0}' -f $EndTime.ToString('yyyy-MM-dd HH:mm:ss')))
    }
    if (($StartTime -is [datetime]) -and ($EndTime -is [datetime]) -and ($EndTime -ge $StartTime) -and ($StartTime -ne [datetime]::MinValue))
    {
        $TotalSec = [int][math]::Round((($EndTime - $StartTime).TotalSeconds))
        $DurText = if ($TotalSec -ge 3600)
        {
            '{0}h {1:D2}m {2:D2}s' -f [int][math]::Floor($TotalSec / 3600), [int][math]::Floor(($TotalSec % 3600) / 60), ($TotalSec % 60)
        }
        else
        {
            '{0}m {1:D2}s' -f [int][math]::Floor($TotalSec / 60), ($TotalSec % 60)
        }
        $Lines.Add(('Total duration  : {0}' -f $DurText))
    }

    # --- Invocation parameters (target identifiers dropped) ------------------
    $Lines.Add('')
    $Lines.Add('Parameters:')
    $ParamNames = @()
    if ($null -ne $InvocationParameters) { $ParamNames = @($InvocationParameters.Keys | Sort-Object) }
    $Emitted = 0
    foreach ($Name in $ParamNames)
    {
        if ($ExcludedParamNames -contains $Name) { continue }
        $Value = $InvocationParameters[$Name]
        # Switch / boolean parameters: list the flag only when it was enabled.
        if ($Value -is [switch])
        {
            if ($Value.IsPresent) { $Lines.Add(('  -{0}' -f $Name)); $Emitted++ }
            continue
        }
        if ($Value -is [bool])
        {
            if ($Value) { $Lines.Add(('  -{0}' -f $Name)); $Emitted++ }
            continue
        }
        # Valued parameter. Print the value verbatim only for known-safe tuning
        # knobs OR any non-obfuscated run; otherwise omit the value so an
        # obfuscated bundle never carries a raw parameter value.
        if (($SafeValueParamNames -contains $Name) -or (-not $Obfuscated))
        {
            $Lines.Add(('  -{0} {1}' -f $Name, [string]$Value))
        }
        else
        {
            $Lines.Add(('  -{0} <value omitted>' -f $Name))
        }
        $Emitted++
    }
    if ($Emitted -eq 0) { $Lines.Add('  (defaults - no switches or values passed)') }

    # --- Host / parallelism --------------------------------------------------
    # vCPU/RAM counts and the resolved streams/concurrency (auto vs explicit) are
    # run-environment metadata, not identifiers, so they are emitted in BOTH
    # modes. Each line is guarded on a supplied value; when nothing is passed
    # (standalone/offline callers) the whole section is omitted.
    $HostLines = [System.Collections.Generic.List[string]]::new()
    if ($HostVCpu -gt 0) { $HostLines.Add(('  Host vCPU         : {0}' -f $HostVCpu)) }
    if ($HostRamGB -gt 0) { $HostLines.Add(('  Host RAM (GB)     : {0}' -f $HostRamGB)) }
    if ($Streams -gt 0)
    {
        $StreamsSrcText = if (-not [string]::IsNullOrEmpty($StreamsSource)) { ' ({0})' -f $StreamsSource } else { '' }
        $HostLines.Add(('  Parallel streams  : {0}{1}' -f $Streams, $StreamsSrcText))
    }
    if ($Concurrency -gt 0)
    {
        $ConcurrencySrcText = if (-not [string]::IsNullOrEmpty($ConcurrencySource)) { ' ({0})' -f $ConcurrencySource } else { '' }
        $HostLines.Add(('  Concurrency limit : {0}{1}' -f $Concurrency, $ConcurrencySrcText))
    }
    if ($HostLines.Count -gt 0)
    {
        $Lines.Add('')
        $Lines.Add('Host / parallelism:')
        foreach ($HostLine in $HostLines) { $Lines.Add($HostLine) }
    }

    # --- Subscription tally --------------------------------------------------
    $Lines.Add('')
    $Lines.Add('Subscriptions:')
    $Lines.Add(('  Visible   : {0}' -f $Visible))
    $Lines.Add(('  Excluded  : {0} (non-Enabled)' -f $Excluded))
    $Lines.Add(('  Eligible  : {0}' -f $Eligible))
    $Lines.Add(('  Skipped   : {0} (already completed / resume)' -f $Skipped))
    $Lines.Add(('  Processed : {0}' -f $Processed))
    $Lines.Add(('  Failed    : {0}' -f $Failed.Count))
    $Lines.Add(('  Retry limit reached : {0} (incomplete; -Resume and -ResumeFailedOnly do not collect these)' -f $Limited.Count))
    $Lines.Add(('  0 resources - no access   : {0}' -f $NoAccess.Count))
    $Lines.Add(('  0 resources - empty       : {0}' -f $Empty.Count))
    $Lines.Add(('  0 resources - undetermined: {0}' -f $Undetermined.Count))

    # --- Health --------------------------------------------------------------
    $Lines.Add('')
    $Lines.Add('Health:')
    $Lines.Add(('  Consumption records collected : {0}' -f $ConsumptionRecordCount))
    $Lines.Add(('  Failed subscriptions          : {0}' -f $Failed.Count))
    $Lines.Add(('  Collector failures            : {0}' -f $Collector.Count))
    $Lines.Add(('  Metrics auth-skipped subs     : {0}' -f $Metrics.Count))
    $Lines.Add(('  Consumption failed subs       : {0}' -f $Consumption.Count))

    # Per-subscription detail is emitted ONLY for a non-obfuscated bundle, where
    # real names already appear throughout the report. An obfuscated bundle stops
    # at the counts above.
    if (-not $Obfuscated)
    {
        if ($Failed.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Failed subscriptions (detail):')
            foreach ($FailedSub in $Failed) { $Lines.Add(('  - {0} ({1})' -f [string]$FailedSub.Name, [string]$FailedSub.Id)) }
        }
        if ($Limited.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Retry limit reached (detail; run each on its own with ./ResourceInventory.ps1 -SubscriptionID, or start a run without -Resume):')
            foreach ($LimitedSub in $Limited) { $Lines.Add(('  - {0} ({1}): failed {2} runs in a row; last reason: {3}' -f [string]$LimitedSub.Name, [string]$LimitedSub.Id, (Get-FailedAttemptCount -Entry $LimitedSub), [string]$LimitedSub.Reason)) }
        }
        if ($NoAccess.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('0-resource subscriptions with NO ACCESS (grant Reader, re-run -Resume):')
            foreach ($NoAccessSub in $NoAccess) { $Lines.Add(('  - {0} ({1})' -f [string]$NoAccessSub.Name, [string]$NoAccessSub.Id)) }
        }
        if ($Collector.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Collector failures (detail):')
            foreach ($CollectorFail in $Collector) { $Lines.Add(('  - [sub {0}] {1}: {2}' -f [string]$CollectorFail.Id, [string]$CollectorFail.Module, [string]$CollectorFail.Message)) }
        }
        if ($Metrics.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Metrics auth-skipped subscriptions (detail):')
            foreach ($MetricSub in $Metrics) { $Lines.Add(('  - {0} ({1}): {2}' -f [string]$MetricSub.Name, [string]$MetricSub.Id, [string]$MetricSub.Message)) }
        }
        if ($Consumption.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Consumption failed subscriptions (detail):')
            foreach ($ConsumpSub in $Consumption) { $Lines.Add(('  - {0} ({1}): {2}' -f [string]$ConsumpSub.Name, [string]$ConsumpSub.Id, [string]$ConsumpSub.Message)) }
        }
    }

    return $Lines.ToArray()
}

# ---- Consolidated zip check -------------------------------------------------

# Returns $null when the consolidated zip at $Path opens and holds every
# per-subscription zip named in $SubZipNames, otherwise one line saying why not.
# Compress-Archive removes its destination when a write fails (a full disk does
# this, also during -Update), so "the command finished" does not mean the zip is
# there. Reads only the zip's directory, not the reports in it.
function Get-ConsolidatedZipProblem
{
    param(
        [string]$Path,
        [string[]]$SubZipNames
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return 'the zip is not on disk.'
    }
    try
    {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try
        {
            $EntryNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Archive.Entries | ForEach-Object { $_.FullName }), [System.StringComparer]::Ordinal)
        }
        finally
        {
            $Archive.Dispose()
        }
    }
    catch
    {
        return ('the zip cannot be read: {0}' -f $_.Exception.Message)
    }
    $Missing = @($SubZipNames | Where-Object { -not $EntryNames.Contains($_) })
    if ($Missing.Count -gt 0)
    {
        return ('{0} of the {1} per-subscription zip(s) are not in it.' -f $Missing.Count, @($SubZipNames).Count)
    }
    return $null
}
