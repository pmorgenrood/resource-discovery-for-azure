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
    # An exit runs the finally blocks it leaves; one of them may call
    # Exit-WrapperInterrupted, which then lets this exit keep its code.
    $script:WrapperExiting = $true
    # Every early exit of the wrapper passes here, and the resume state is kept
    # at each of them. The per-stream state files the run folded in at startup
    # are deleted first, once the resume state holds their records
    # (Invoke-FoldedStreamStateCleanup), so a run that stops early leaves none
    # behind and no exit needs code of its own. There are none before the fold,
    # and none after the end-of-run merge of a parallel run or the end-of-run
    # clean-up, which deal with them.
    if (@($FoldedStreamFiles | Where-Object { $null -ne $_ }).Count -gt 0)
    {
        $null = Invoke-FoldedStreamStateCleanup -Files $FoldedStreamFiles -ResumeStateFile $ResumeStateFile -Tenant $TenantID -Ids $FoldedRecordIds -CompletedIds $CompletedIds -FailedAttempts $FailedAttempts
    }
    # An early exit is not a clean run, so it names the per-stream state files
    # of another run left on disk, as the end of such a run does. Only once the
    # run id has been read ($OtherRunLineReady); before that no run id is known.
    if ($OtherRunLineReady)
    {
        # Against the run the state file holds now: a new run that has written
        # its state makes the earlier run's files another run's.
        $IdOnDisk = Get-ResumeStateRunId -Path $ResumeStateFile -Tenant $TenantID
        Write-OtherRunStreamStateLine -InventoryRoot $InventoryRoot -Tenant $TenantID -RunId $(if ($null -ne $IdOnDisk) { $IdOnDisk } else { $RunId })
    }
    # Then the run lock, after the per-stream files (their clean-up writes the
    # resume state, so the lock must still be held) and before the transcript
    # stops. Before the lock is taken there is none to release.
    $HeldRunLock = Get-Variable -Name 'RunLock' -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $HeldRunLock) { Remove-RunLock -Lock $HeldRunLock }
    if ($WrapperTranscriptStarted)
    {
        try { Stop-Transcript | Out-Null }
        catch { Write-Verbose ("Stop-Transcript on Exit-Wrapper failed: {0}" -f $_.Exception.Message) }
    }
    exit $Code
}

# Whether a run stopped by Ctrl+C may set the exit code of its pwsh process,
# which ends that process once the script returns. A plain `exit 130` is not
# enough under `pwsh -File`: after a Ctrl+C, PowerShell exits 0 for an advanced
# script (this one has [Parameter()] attributes). Setting the process's code
# would close a session, so it is done only when the wrapper is the process's
# startup script (-File, or the script path as pwsh's first value, which pwsh
# takes as -File) and pwsh was not given -NoExit. -NoExit counts in every form
# pwsh might take, so anything that could be it keeps the run as in a session:
# any argument before the script path that starts with 'noe' once leading '-',
# '/' and dash characters are removed, in any case (pwsh documents -NoExit and
# -noe). The arguments are read here only; they are never printed or logged.
# Returns $false for anything it cannot read, and when the script path is not
# among the arguments (for example under Start-Job -FilePath, whose job process
# is started without it).
function Test-WrapperOwnsProcessExit
{
    param([bool]$IsStartupScript, [string]$ScriptPath, [object]$ProcessArguments)
    if (-not $IsStartupScript -or [string]::IsNullOrWhiteSpace($ScriptPath)) { return $false }
    try
    {
        $Arguments = @($ProcessArguments)
        foreach ($Argument in @($Arguments | Select-Object -Skip 1))
        {
            $Text = [string]$Argument
            if (-not [string]::IsNullOrWhiteSpace($Text))
            {
                $IsScript = $false
                try { $IsScript = [string]::Equals([System.IO.Path]::GetFullPath($Text), $ScriptPath, [System.StringComparison]::OrdinalIgnoreCase) }
                catch { $IsScript = $false }
                # Everything after the script path is the script's own.
                if ($IsScript) { return $true }
            }
            $Key = $Text.Trim().TrimStart([char]'-', [char]'/', [char]0x2013, [char]0x2014, [char]0x2015)
            if ($Key -like 'noe*') { return $false }
        }
        return $false
    }
    catch
    {
        return $false
    }
}

# Ends a run stopped by Ctrl+C before every subscription was processed: one
# line, then exit 130 (128 + SIGINT, the code a shell reports for a command
# stopped by Ctrl+C), so a scheduler or a script does not read the stop as a
# clean run. A run started with `pwsh -File` (without -NoExit) gets 130 as the
# process's exit code (Test-WrapperOwnsProcessExit). A run started inside a
# PowerShell session, or by `pwsh -NoExit -File`, goes back to the prompt with
# $LASTEXITCODE 130 and the session stays open. A `pwsh -Command` run ends
# with PowerShell's own code for a stopped command, 1. The caller runs this
# last in a finally block, after its own cleanup; the resume state written so
# far is left as it is.
function Exit-WrapperInterrupted
{
    param([string]$InventoryRoot, [bool]$OwnsProcessExit)
    if (Get-Variable -Name 'WrapperExiting' -Scope Script -ValueOnly -ErrorAction SilentlyContinue) { return }
    Write-Host ("Interrupted (Ctrl+C) before all subscriptions were processed. The resume state is kept in {0}; to continue, run the same command again with -Resume." -f $InventoryRoot) -ForegroundColor Yellow
    # Only marks the code: the process ends once the script has returned, so
    # Exit-Wrapper's clean-up still runs.
    if ($OwnsProcessExit) { $Host.SetShouldExit(130) }
    Exit-Wrapper -Code 130
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

# The right shape of a resume state record, parsed from JSON: the resume state
# file (-Kind Main, written by Save-CompletedSubscriptionIds) or a per-stream
# state file (-Kind Stream, written by Write-StreamState). The wrapper checks the
# resume state file here once, at startup, before Get-CompletedSubscriptionIds
# and Get-FailedAttempts read it (Move-WrongShapeResumeStateFile); those two do
# not check it again. A per-stream record is checked by the wrapper's startup
# fold and end-of-run merge, and by the stream worker's Read-StreamState.
# Returns $null when the record has the right shape, otherwise a short text
# naming the first field that does not (never a value from the file).
#   - The record is a JSON object.
#   - Main: TenantID is text, and CompletedSubscriptionIds is a list of text
#     ids. Stream: Completed is a list of text ids.
#   - RunId, when the record has one, is text: it is compared as text with the
#     run's id (Test-StreamStateRunId), so a number 5 must not match the text
#     '5'. A null RunId reads as none, like a record without the key.
#   - FailedAttempts (the retry list) is a list. Each entry is an object with a
#     non-empty text Id and LastFailedAt a date, the values Add-FailedAttempt
#     and Merge-FailedAttempts convert (a missing or unreadable Attempts counts
#     as one failed run, Get-FailedAttemptCount). A
#     file written before the retry list existed has no FailedAttempts key,
#     which reads as an empty list.
# The tool itself writes a null entry when a list becomes empty, and an empty
# completed id where Save-CompletedSubscriptionIds converts a null entry to text,
# so both are accepted and skipped here. Neither matches a subscription; of the
# readers, Get-FailedAttempts drops null retry entries.
# A $null record also returns $null: ConvertFrom-Json turns an empty or
# whitespace-only file (a write cut short) into $null without an error. That
# file is not valid JSON, so it is left to the readers, which treat it as they
# did before this check.
function Get-ResumeStateShapeProblem
{
    param(
        [object]$Record,
        [Parameter(Mandatory = $true)][ValidateSet('Main', 'Stream')][string]$Kind
    )
    if ($null -eq $Record) { return $null }
    if ($Record -isnot [System.Management.Automation.PSCustomObject]) { return 'it is not a JSON object' }
    if ($Kind -eq 'Main' -and $Record.TenantID -isnot [string]) { return 'TenantID is not text' }
    $RunIdProp = $Record.PSObject.Properties['RunId']
    if ($null -ne $RunIdProp -and $null -ne $RunIdProp.Value -and $RunIdProp.Value -isnot [string]) { return 'RunId is not text' }
    $IdsKey = if ($Kind -eq 'Main') { 'CompletedSubscriptionIds' } else { 'Completed' }
    if ($null -eq $Record.PSObject.Properties[$IdsKey]) { return ('{0} is missing' -f $IdsKey) }
    if ($null -ne $Record.$IdsKey -and $Record.$IdsKey -isnot [array]) { return ('{0} is not a list' -f $IdsKey) }
    # foreach, not a pipeline: a large tenant has thousands of ids here.
    foreach ($Id in @($Record.$IdsKey))
    {
        if ($null -eq $Id) { continue }
        if ($Id -isnot [string]) { return ('{0} holds an entry that is not a text id' -f $IdsKey) }
    }

    $List = $Record.FailedAttempts
    if ($null -ne $List -and $List -isnot [array]) { return 'FailedAttempts is not a list' }
    $N = 0
    foreach ($Entry in @($List))
    {
        $N++
        if ($null -eq $Entry) { continue }
        if ($Entry -isnot [System.Management.Automation.PSCustomObject]) { return ('FailedAttempts entry {0} is not an object' -f $N) }
        if ($Entry.Id -isnot [string] -or [string]::IsNullOrWhiteSpace($Entry.Id)) { return ('FailedAttempts entry {0} has no text Id' -f $N) }
        # Attempts is not checked: an entry whose Attempts is missing or is not a
        # whole number of at least 0 counts as one failed run (Get-FailedAttemptCount),
        # so its file is used, not moved aside.
        # ConvertFrom-Json turns an ISO 8601 date text into a [datetime]; any
        # other text must parse as one the way the [datetime] cast does.
        $When = [datetime]::MinValue
        if ($Entry.LastFailedAt -isnot [datetime] -and -not ($Entry.LastFailedAt -is [string] -and [datetime]::TryParse($Entry.LastFailedAt, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$When)))
        {
            return ('FailedAttempts entry {0}: LastFailedAt is not a date' -f $N)
        }
    }
    return $null
}

# Check one resume state file (-Kind Main) or per-stream state file (-Kind
# Stream) for the right shape (Get-ResumeStateShapeProblem). -Record is the
# parsed content when the caller has already read it; otherwise the file is
# read here, and a file that is absent or cannot be parsed is left to the
# reader's own handling. Returns nothing when the record has the right shape.
# Otherwise its records are not used: the file is renamed in place to
# <name>.unreadable-<UTC yyyyMMdd-HHmmss>, with -2, -3 and so on added when that
# name is taken, and kept for inspection. The name neither ends in '.json' nor
# matches a state file name, so no later run reads it, and it stays a dot-file
# in the inventory root, which no zip step of the wrapper takes. Prints a
# warning naming the file and the field, never its content; with -Resume and a
# per-stream file, also what this run does instead. Returns { Kind; Name;
# MovedTo; Path; Problem; Reason; NotMoved }.
# When the file cannot be renamed, the run must not use its records or write
# over it, and must not carry on as if the file were not there: later runs read
# it again. At startup the run stops here with exit 1
# (Stop-WrongShapeStateNotMoved). With -AfterCollection (the end-of-run merge of
# a parallel run) the run is finished first: this prints a notice and returns
# the file with NotMoved set; the wrapper leaves the file alone and, at the end
# of the run, stops with exit 1 the same way. -ResumeFailedOnly only changes
# what the stop advises.
function Move-WrongShapeResumeStateFile
{
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Main', 'Stream')][string]$Kind,
        [object]$Record,
        [switch]$Resume,
        # The end-of-run merge of a parallel run, after this run's collection.
        [switch]$AfterCollection,
        [switch]$ResumeFailedOnly,
        [datetime]$Now = [datetime]::UtcNow
    )
    if (-not $PSBoundParameters.ContainsKey('Record'))
    {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
        try { $Record = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { return }
    }
    $Problem = Get-ResumeStateShapeProblem -Record $Record -Kind $Kind
    if ($null -eq $Problem) { return }

    $Name = Split-Path -Path $Path -Leaf
    $What = if ($Kind -eq 'Main') { 'resume state file' } else { 'per-stream state file' }
    $Base = '{0}.unreadable-{1}' -f $Name, $Now.ToString('yyyyMMdd-HHmmss')
    # A second move in the same second, or a name an earlier run left, must not
    # make the rename fail. Up to 100 names are tried.
    $Folder = Split-Path -Path $Path -Parent
    $MovedTo = $Base
    $N = 1
    while ($null -ne $MovedTo -and (Test-Path -LiteralPath (Join-Path $Folder $MovedTo)))
    {
        $N++
        $MovedTo = if ($N -le 100) { '{0}-{1}' -f $Base, $N } else { $null }
    }
    try
    {
        if ($null -eq $MovedTo) { throw ('every name from {0} to {0}-100 is taken' -f $Base) }
        Rename-Item -LiteralPath $Path -NewName $MovedTo -ErrorAction Stop
    }
    catch
    {
        $NotMoved = [pscustomobject]@{ Kind = $Kind; Name = $Name; MovedTo = $null; Path = $Path; Problem = $Problem; Reason = $_.Exception.Message; NotMoved = $true }
        if (-not $AfterCollection) { Stop-WrongShapeStateNotMoved -Files @($NotMoved) -ResumeFailedOnly:$ResumeFailedOnly }
        Write-WrongShapeNotMovedLine -File $NotMoved
        Write-Host "  This run does not use the file's records and does not write over it. It goes on as usual and ends with exit 1 (exit 2 when a report is missing or a subscription failed), with what to do next at its end." -ForegroundColor Red
        return $NotMoved
    }
    Write-Host ('WARNING: The {0} {1} is not the right shape ({2}), so its records are not used. It was moved aside to {3}, kept for inspection; no run reads it again.' -f $What, $Name, $Problem, $MovedTo) -ForegroundColor Yellow
    if ($Resume -and $Kind -eq 'Stream')
    {
        Write-Host '  This run does not count the subscriptions it lists as completed.' -ForegroundColor Yellow
    }
    return [pscustomobject]@{ Kind = $Kind; Name = $Name; MovedTo = $MovedTo; Path = $Path; Problem = $Problem; Reason = $null; NotMoved = $false }
}

# The first line about a state file that is not the right shape and could not
# be moved aside (Move-WrongShapeResumeStateFile): the file, the field and the
# reason the rename failed.
function Write-WrongShapeNotMovedLine
{
    param([Parameter(Mandatory = $true)][object]$File)
    $What = if ($File.Kind -eq 'Main') { 'resume state file' } else { 'per-stream state file' }
    if ($File.PSObject.Properties['Unreadable'] -and $File.Unreadable)
    {
        Write-Host ('ERROR: The {0} {1} could not be read, and it could not be moved aside: {2}' -f $What, $File.Name, $File.Reason) -ForegroundColor Red
        return
    }
    Write-Host ('ERROR: The {0} {1} is not the right shape ({2}), and it could not be moved aside: {3}' -f $What, $File.Name, $File.Problem, $File.Reason) -ForegroundColor Red
}

# Stop the run with exit 1 for state files that are not the right shape, or
# per-stream files that cannot be read, and could not be moved aside (-Files,
# from Move-WrongShapeResumeStateFile or Move-UnreadableStreamStateFile): name
# each one with the reason; say what this run did and did not do, and what
# later runs do while the file stays; print the command that removes each file
# and the command to run next. The remove command is a Remove-Item -LiteralPath
# of the full path, quoted for PowerShell, with -Force: on Linux and macOS
# PowerShell treats a file whose name starts with a dot as hidden and does not
# remove it without -Force; on Windows a leading dot does not hide a file, so
# -Force is not needed there and changes nothing for this file.
# -AfterCollection: the files were found by the end-of-run merge of a parallel
# run, which left them alone. When the per-subscription output check passes,
# the run first finishes (its consolidated zip, main summary and end-of-run
# summary) and calls this at its end. When that check fails, it calls this right
# after the check's lines, before the consolidated zip and the summaries, and
# ends with exit 2. In both cases -NoExit is given and the wrapper sets the exit
# code (exit 1 in place of 0 and 3-5; exit 2 keeps its code). Without
# -AfterCollection the run stops at its start, before it collects any
# subscription.
function Stop-WrongShapeStateNotMoved
{
    param(
        [Parameter(Mandatory = $true)][object[]]$Files,
        [switch]$AfterCollection,
        [switch]$ResumeFailedOnly,
        # Print the stop and return: the caller ends the run with its exit code
        # (after collection, exit 2 keeps its code over this stop).
        [switch]$NoExit
    )
    $Files = @($Files | Where-Object { $null -ne $_ })
    foreach ($File in $Files) { Write-WrongShapeNotMovedLine -File $File }
    if ($AfterCollection)
    {
        Write-Host "  This run ends with exit 1 in place of 0 and 3-5; a run that ends with exit 2 (a report is missing) keeps exit 2. It did not use the file's records and did not write over it; the rest of the run above went as usual." -ForegroundColor Red
    }
    else
    {
        Write-Host "  This run stops here (exit 1), before it collects any subscription or writes any resume state. It does not use the file's records and does not write over it." -ForegroundColor Red
    }
    $IsUnreadable = { param($F) $null -ne $F.PSObject.Properties['Unreadable'] -and [bool]$F.Unreadable }
    if (@($Files | Where-Object { $_.Kind -eq 'Main' }).Count -gt 0)
    {
        Write-Host '  While the file cannot be moved aside, every later run reads it at its start and stops the same way.' -ForegroundColor Yellow
    }
    elseif (@($Files | Where-Object { -not (& $IsUnreadable $_) }).Count -eq 0)
    {
        # Only per-stream files that cannot be read: the startup fold of
        # -Resume and -ResumeFailedOnly reads them, and the end-of-run merge of
        # a run with more than one stream.
        Write-Host '  While the file cannot be moved aside, every later run that continues the unfinished run (with or without -Resume, and -ResumeFailedOnly) reads it at its start and stops the same way. A later run that starts a new run (-Fresh) does not read it at its start; one that runs more than one stream reads it at its end and stops the same way there, unless one of its streams writes that file first.' -ForegroundColor Yellow
    }
    else
    {
        Write-Host "  While the file cannot be moved aside, every later run that continues the unfinished run (with or without -Resume, and -ResumeFailedOnly) reads it at its start and stops the same way. A later run that starts a new run (-Fresh) and runs one stream does not use it and leaves it as it is. One that runs more streams (set by -ParallelStreams, or chosen for this host when it is not given) stops the same way, at its start when one of its streams has this file's number and otherwise at its end." -ForegroundColor Yellow
    }
    $Lead = if ($Files.Count -gt 1) { '  Once the cause shown above is fixed, remove the files with these commands:' } else { '  Once the cause shown above is fixed, remove the file with this command:' }
    Write-Host $Lead -ForegroundColor Yellow
    foreach ($File in $Files)
    {
        Write-Host ("  Remove-Item -LiteralPath '{0}' -Force" -f [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($File.Path)) -ForegroundColor Yellow
    }
    if ($ResumeFailedOnly)
    {
        Write-Host "  Then run the same command without -ResumeFailedOnly, with -Resume: the retry list then holds none of this file's entries, so -ResumeFailedOnly would not retry them." -ForegroundColor Yellow
    }
    else
    {
        Write-Host '  Then run the same command again.' -ForegroundColor Yellow
    }
    if ($NoExit) { return }
    Exit-Wrapper -Code 1
}

# The end-of-run line for each state file this run moved aside for its shape
# (Move-WrongShapeResumeStateFile): whether the resume state was cleared or
# kept, and where the file went. Such a run is not a clean run, whatever else
# happened, so it never prints "Resume state cleared (clean run).".
function Write-WrongShapeStateSummary
{
    param([object[]]$Files, [bool]$StateKept)
    $Word = if ($StateKept) { 'kept' } else { 'cleared' }
    foreach ($File in @($Files | Where-Object { $null -ne $_ }))
    {
        $What = if ($File.Kind -eq 'Main') { 'resume state file' } else { 'per-stream state file' }
        Write-Host ('Resume state {0}, but not a clean run: the {1} {2} was not the right shape and was moved aside to {3}; its records were not used.' -f $Word, $What, $File.Name, $File.MovedTo) -ForegroundColor Yellow
    }
}

# What a -Resume run that moved the resume state file aside uses instead, once
# the per-stream state of an interrupted parallel run has been folded in: none
# (it starts fresh) or only that per-stream state.
function Write-WrongShapeResumeLine
{
    param([bool]$UsesStreamState)
    if ($UsesStreamState)
    {
        Write-Host '  This run does not use the completed list or retry list of the resume state file moved aside above; it uses only the per-stream state recovered above.' -ForegroundColor Yellow
    }
    else
    {
        Write-Host '  Starting fresh: this run does not use the completed list or retry list of the resume state file moved aside above.' -ForegroundColor Yellow
    }
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
        # A null entry is not a failure record (Get-ResumeStateShapeProblem).
        return @($State.FailedAttempts | Where-Object { $null -ne $_ })
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

# After a failed write of the resume state: remove its temporary path ($Path)
# when it is a file (what the write left) or an empty folder, never anything
# inside a folder. A folder with content there makes every write of the resume
# state fail, so the warning names it and the command that removes it. Removing
# a folder with content without -Recurse would ask for confirmation, which a
# non-interactive run cannot answer; [System.IO.Directory]::Delete with
# recursive $false throws on one instead.
function Remove-ResumeStateTempPath
{
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf)
    {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    try
    {
        [System.IO.Directory]::Delete($Path, $false)
    }
    catch
    {
        # The same PowerShell command on every OS, as the stop's remove command
        # (Stop-WrongShapeStateNotMoved): it is pasted into the PowerShell
        # session the tool runs in. A quote in the path is doubled. -Force
        # because on Linux and macOS PowerShell treats a name that starts with a
        # dot as hidden and does not remove it without -Force.
        $Command = "Remove-Item -LiteralPath '{0}' -Recurse -Force" -f [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Path)
        Write-Host ("WARNING: {0} is a folder with content, so no write of the resume state can succeed while it is there. Check what it holds, then remove it: {1}" -f $Path, $Command) -ForegroundColor Yellow
    }
}

function Save-CompletedSubscriptionIds
{
    param([string]$Path, [string]$Tenant, [string[]]$Ids, $FailedAttempts = @(), $Reports = @(), $NotReadable = @(), [string]$RunId)

    # One report record per completed id (the last one given wins), none for an
    # id that is not completed. See New-CompletedReportRecord for the shape.
    $LatestReports = Get-LatestCompletedReports -Reports $Reports
    # Only the access check passes -NotReadable; every other save keeps the list
    # the file already holds.
    if (-not $PSBoundParameters.ContainsKey('NotReadable')) { $NotReadable = Get-NotReadableSubscriptionIds -Path $Path -Tenant $Tenant }
    # The id of the run the per-stream state files belong to (Get-ResumeStateRunId).
    # Every save writes it, so a save that is not given it writes the script's
    # $RunId, and the per-stream files of this run keep matching.
    # This run's record (Get-ResumeStateRunRecord), when the script holds one:
    # its id and its start time, settings and cost window go into every save.
    $Record = Get-ResumeStateRunRecord
    if (-not $PSBoundParameters.ContainsKey('RunId')) { $RunId = if ($null -ne $Record) { [string]$Record.RunId } else { [string](Get-ResumeStateRunList -Name 'RunId') } }
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
    if (-not [string]::IsNullOrEmpty($RunId)) { $State | Add-Member -NotePropertyName 'RunId' -NotePropertyValue $RunId }
    # The start time, settings and cost window: this run's record, or, without
    # one, the ones the file holds, kept as stored, so a save never turns the
    # file into one that records none.
    $RunInfo = if ($null -ne $Record) { $Record.Info } else { Get-ResumeStateRunInfoValues -Path $Path -Tenant $Tenant }
    foreach ($Key in @($RunInfo.Keys)) { $State | Add-Member -NotePropertyName $Key -NotePropertyValue $RunInfo[$Key] -Force }
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
        Remove-ResumeStateTempPath -Path "$Path.tmp"
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
        [string]$Reason,
        # The subscription was not attempted (its stream did not load its Az
        # context snapshot): keep it on the retry list with its count of failed
        # runs unchanged, 0 when it had no entry, and mark the entry so the end
        # of the run can say it was not counted.
        [switch]$NotCounted
    )
    $List = @($Existing | Where-Object { $_ })
    $ExistingEntry = $List | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    $Added = if ($NotCounted) { 0 } else { 1 }
    if ($null -ne $ExistingEntry)
    {
        $List = @($List | Where-Object { $_.Id -ne $Id })
        $Attempts = (Get-FailedAttemptCount -Entry $ExistingEntry) + $Added
    }
    else
    {
        $Attempts = $Added
    }
    $List += [pscustomobject]@{
        Id           = $Id
        Name         = $Name
        LastFailedAt = (Get-Date).ToString('o')
        Reason       = $Reason
        Attempts     = $Attempts
    }
    if ($NotCounted) { $List[-1] | Add-Member -NotePropertyName NotCounted -NotePropertyValue $true }
    return $List
}

# Name the retry-list entries whose last run was not counted toward the retry
# limit (Add-FailedAttempt -NotCounted): their stream did not load its Az
# context snapshot. Prints nothing when there are none.
function Write-NotCountedRetrySummary
{
    param([object]$FailedAttempts)
    $List = @(@($FailedAttempts) | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['NotCounted'] -and $_.NotCounted -eq $true })
    if ($List.Count -eq 0) { return }
    Write-Host ("Not counted toward the retry limit: {0} ({1}) - the last run for these did not start their stream (it did not load its Az context snapshot), so that run is not counted as a failed run; each keeps its count. Run with -ParallelStreams 1 to collect them without stream workers." -f $List.Count, (@($List | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
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

# The run id the resume state file for $Tenant holds, or $null when there is no
# file, it cannot be read, it is for another tenant, or it was written before
# run ids existed. A run without -Resume or -ResumeFailedOnly writes a new id at
# its start; -Resume and -ResumeFailedOnly keep this one. The per-stream state
# files a parallel run writes carry the same id (Write-StreamState).
function Get-ResumeStateRunId
{
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Tenant)
    try
    {
        $State = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        return $null
    }
    if ($State -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $TenantProp = $State.PSObject.Properties['TenantID']
    if ($null -eq $TenantProp -or [string]$TenantProp.Value -ne $Tenant) { return $null }
    # Only a text id: the file is read before its shape check, so any other
    # value is not taken for one.
    $Prop = $State.PSObject.Properties['RunId']
    if ($null -eq $Prop -or $Prop.Value -isnot [string] -or [string]::IsNullOrEmpty($Prop.Value)) { return $null }
    return $Prop.Value
}

# Write $RunId into the resume state file for $Tenant at the start of a run
# without -Resume or -ResumeFailedOnly, keeping every other key the file holds
# (a version that keeps more lists keeps them too). With no file, or one that
# cannot be read or is for another tenant, it writes a state with nothing
# completed or failed. Atomic like Save-CompletedSubscriptionIds. Prints nothing:
# the caller reads the id back (Get-ResumeStateRunId) and says what a failed
# write means.
function Set-ResumeStateRunId
{
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [Parameter(Mandatory = $true)][string]$RunId,
        # The start time, settings and cost window of the run (New-ResumeRunInfo),
        # written over the ones the file holds.
        [System.Collections.IDictionary]$RunInfo,
        # A new run: the completed list and its reports start empty, so a later
        # run that continues this one carries no report of an earlier run. The
        # retry list is kept, with its counts.
        [switch]$NewRun
    )
    $State = $null
    try
    {
        $Read = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $TenantProp = if ($Read -is [System.Management.Automation.PSCustomObject]) { $Read.PSObject.Properties['TenantID'] }
        if ($null -ne $TenantProp -and [string]$TenantProp.Value -eq $Tenant) { $State = $Read }
    }
    catch
    {
        $State = $null
    }
    if ($null -eq $State) { $State = [pscustomobject]@{ TenantID = $Tenant; CompletedSubscriptionIds = @(); FailedAttempts = @() } }
    $State | Add-Member -NotePropertyName 'RunId' -NotePropertyValue $RunId -Force
    if ($NewRun)
    {
        $State | Add-Member -NotePropertyName 'CompletedSubscriptionIds' -NotePropertyValue @() -Force
        $State | Add-Member -NotePropertyName 'CompletedReports' -NotePropertyValue @() -Force
    }
    if ($null -ne $RunInfo)
    {
        foreach ($Key in @($RunInfo.Keys)) { $State | Add-Member -NotePropertyName $Key -NotePropertyValue $RunInfo[$Key] -Force }
    }
    $State | Add-Member -NotePropertyName 'LastUpdated' -NotePropertyValue ((Get-Date).ToString('o')) -Force
    try
    {
        $TmpPath = "$Path.tmp"
        $State | ConvertTo-Json -Depth 6 | Set-Content -Path $TmpPath -Encoding utf8
        [System.IO.File]::Move($TmpPath, $Path, $true)
    }
    catch
    {
        Remove-ResumeStateTempPath -Path "$Path.tmp"
    }
}

# Write a new run id ($RunId) into the resume state file for $Tenant, for a run
# without -Resume or -ResumeFailedOnly, right before it starts collecting
# (Set-ResumeStateRunId), and read it back: a failed write does not stop the
# run, and the warning says what it means for a later -Resume.
function Write-StartOfRunId
{
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [Parameter(Mandatory = $true)][object]$Record,
        [string[]]$Ids = @(),
        $FailedAttempts = @(),
        $Reports = @()
    )
    $State = $null
    try
    {
        $Read = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($Read -is [System.Management.Automation.PSCustomObject] -and [string]$Read.TenantID -eq $Tenant) { $State = $Read }
    }
    catch { $State = $null }
    # A run that continues one whose file already holds this record writes
    # nothing here.
    if ($null -ne $State -and -not $Record.NewRun -and [string](Get-ResumeStateRunId -Path $Path -Tenant $Tenant) -eq [string]$Record.RunId)
    {
        $Same = $true
        foreach ($Key in @($Record.Info.Keys))
        {
            $Prop = $State.PSObject.Properties[$Key]
            if ($null -eq $Prop -or (ConvertTo-Json -InputObject $Prop.Value -Depth 4 -Compress) -ne (ConvertTo-Json -InputObject $Record.Info[$Key] -Depth 4 -Compress)) { $Same = $false; break }
        }
        if ($Same) { return }
    }
    if ($null -eq $State)
    {
        # No file of this tenant (a file moved aside, or a new run's first
        # write): one from this run's lists.
        $Latest = Get-LatestCompletedReports -Reports $Reports
        $State = [pscustomobject]@{
            TenantID                   = $Tenant
            CompletedSubscriptionIds   = @($Ids)
            CompletedReports           = @(foreach ($Id in @($Ids)) { if (-not [string]::IsNullOrWhiteSpace($Id) -and $Latest.ContainsKey($Id)) { $Latest[$Id] } })
            FailedAttempts             = @($FailedAttempts)
            NotReadableSubscriptionIds = @()
        }
    }
    elseif ($Record.NewRun)
    {
        # A new run: nothing completed. The file keeps every other key it holds
        # (a version that keeps more lists keeps them).
        $State | Add-Member -NotePropertyName 'CompletedSubscriptionIds' -NotePropertyValue @() -Force
        $State | Add-Member -NotePropertyName 'CompletedReports' -NotePropertyValue @() -Force
    }
    Add-ResumeRunRecordKeys -State $State -Record $Record -Ids @($State.CompletedSubscriptionIds)
    $State | Add-Member -NotePropertyName 'LastUpdated' -NotePropertyValue ((Get-Date).ToString('o')) -Force
    try
    {
        $TmpPath = "$Path.tmp"
        $State | ConvertTo-Json -Depth 6 | Set-Content -Path $TmpPath -Encoding utf8 -ErrorAction Stop
        [System.IO.File]::Move($TmpPath, $Path, $true)
    }
    catch
    {
        Remove-ResumeStateTempPath -Path "$Path.tmp"
    }
    $Back = Read-ResumeRunInfo -Path $Path -Tenant $Tenant
    $IdOk = [string]::IsNullOrEmpty([string]$Record.RunId) -or (Get-ResumeStateRunId -Path $Path -Tenant $Tenant) -eq [string]$Record.RunId
    # As dates: the file gives the time back as a date, the record holds text.
    $Want = ConvertFrom-ResumeRunStartTime -Value $Record.Info['RunStartedAt']
    $StartOk = $Back.Exists -and $(if ($null -eq $Want) { $null -eq $Back.StartedAt } else { $null -ne $Back.StartedAt -and $Back.StartedAt -eq $Want })
    if (-not ($IdOk -and $StartOk) -and -not $Record.NewRun)
    {
        Write-Host ("WARNING: Could not record this run's start time, settings and cost window in the resume state file {0}. A later write of it in this run records them; until one succeeds, the next run reads the file as it was." -f (Split-Path -Path $Path -Leaf)) -ForegroundColor Yellow
    }
    elseif (-not ($IdOk -and $StartOk))
    {
        Write-Host ("WARNING: The resume state file {0} could not be written at the start of this run, so it does not hold this run's id. Unless a later write of it in this run succeeds, a later run may not see what this run completed or failed: when an earlier run's resume state file is there, it continues that run and does not use this run's per-stream state files. Once the file can be written, start the next run with -Fresh." -f (Split-Path -Path $Path -Leaf)) -ForegroundColor Yellow
    }
}

# ---- Resume by default --------------------------------------------------------
# A run continues the unfinished run the resume state file holds (as -Resume
# does) and starts a new one only when there is none, with -Fresh, or when the
# unfinished run is older than -ResumeMaxAgeDays (a run without -Resume or
# -ResumeFailedOnly only). The file records the run's start time
# (RunStartedAt, UTC), its settings (RunSettings) and its cost window
# (ConsumptionWindowStart/End); every save of the file keeps them.

# The settings that change what a run collects or how it masks it, so one
# consolidated zip must not mix them: -Obfuscate masks the reports,
# -SkipMetrics and -SkipConsumption leave a phase out, -IncludeDisabled changes
# which subscriptions are in scope. The others do not count: -DeviceLogin (how
# the run signs in), -ConcurrencyLimit and -ParallelStreams (how many at once),
# -Detailed (read only when the main summary is built at the end of the run,
# over every report in the zip), -MainSummary and -AllowPartialAccess (accepted
# and change nothing).
function Get-RunDataSettingNames
{
    return @('Obfuscate', 'SkipMetrics', 'SkipConsumption', 'IncludeDisabled')
}

function Get-RunDataSettings
{
    param([bool]$Obfuscate, [bool]$SkipMetrics, [bool]$SkipConsumption, [bool]$IncludeDisabled)
    return [ordered]@{ Obfuscate = $Obfuscate; SkipMetrics = $SkipMetrics; SkipConsumption = $SkipConsumption; IncludeDisabled = $IncludeDisabled }
}

# The settings as the start line and the stop name them: the switches that are
# on ('-Obfuscate -SkipMetrics'), or 'none of these switches' when none is.
function Format-RunDataSettings
{
    param([System.Collections.IDictionary]$Settings)
    $On = @(foreach ($Name in @(Get-RunDataSettingNames)) { if ($null -ne $Settings -and $Settings[$Name]) { '-' + $Name } })
    if ($On.Count -eq 0) { return 'none of -Obfuscate, -SkipMetrics, -SkipConsumption, -IncludeDisabled' }
    return ($On -join ' ')
}

# A UTC time as the start lines show it: '29 Oct 2026 14:02 UTC'.
function Format-RunStartTime
{
    param([Parameter(Mandatory = $true)][datetime]$Time)
    return ($Time.ToString('d MMM yyyy HH:mm', [cultureinfo]::InvariantCulture) + ' UTC')
}

# The run start time a resume state file records, as a UTC time, or $null when
# the value is not a date. ConvertFrom-Json turns an ISO 8601 text into a
# [datetime] (Kind Utc for a 'Z' time, Local for one with an offset); any other
# text must parse as a date, read as UTC when it carries no offset.
function ConvertFrom-ResumeRunStartTime
{
    param([object]$Value)
    if ($Value -is [datetime])
    {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $null }
    $When = [datetime]::MinValue
    $Styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if (-not [datetime]::TryParse($Value, [cultureinfo]::InvariantCulture, $Styles, [ref]$When)) { return $null }
    return $When
}

# The start time, settings and cost window to record for a run.
function New-ResumeRunInfo
{
    param(
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory = $true)]$Window
    )
    $WindowArgs = ConvertTo-ConsumptionWindowArgument -Window $Window
    return [ordered]@{
        RunStartedAt           = $StartedAt.ToUniversalTime().ToString('o', [cultureinfo]::InvariantCulture)
        RunSettings            = [pscustomobject]$Settings
        ConsumptionWindowStart = $WindowArgs.ConsumptionWindowStart
        ConsumptionWindowEnd   = $WindowArgs.ConsumptionWindowEnd
    }
}

# The names of the keys New-ResumeRunInfo writes.
function Get-ResumeRunInfoKeys
{
    return @('RunStartedAt', 'RunSettings', 'ConsumptionWindowStart', 'ConsumptionWindowEnd')
}

# The run start time, settings and cost window keys the resume state file for
# $Tenant holds, as stored, so a save that rewrites the file keeps them. Empty
# when there is no file, it cannot be read or is for another tenant.
function Get-ResumeStateRunInfoValues
{
    param([string]$Path, [string]$Tenant)
    $Values = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $Values }
    try { $State = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { return $Values }
    if ($State -isnot [System.Management.Automation.PSCustomObject] -or [string]$State.TenantID -ne $Tenant) { return $Values }
    foreach ($Key in @(Get-ResumeRunInfoKeys))
    {
        $Prop = $State.PSObject.Properties[$Key]
        if ($null -ne $Prop) { $Values[$Key] = $Prop.Value }
    }
    return $Values
}

# What the resume state file for $Tenant says about the run it holds. Exists:
# the file is there, is a JSON object and is for this tenant (the test
# Get-ResumeStateRunId makes); that run is unfinished, since a clean run
# removes the file. Legacy: it records neither a start time nor settings (it
# was written before runs recorded them). StartedAt (UTC) or StartedAtProblem;
# Settings (by Get-RunDataSettingNames) or SettingsProblem; Window (as
# Get-ConsumptionWindow returns it) or WindowProblem. Values: the four keys as
# stored. Present: a file is at the path, whether or not it can be read.
# StreamOnly is set by the caller when there is no such file but per-stream
# state files of an interrupted parallel run are there.
# Reads nothing else from the file.
function Read-ResumeRunInfo
{
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Tenant)
    $Info = [pscustomobject]@{ Present = (Test-Path -LiteralPath $Path -PathType Leaf); Exists = $false; StreamOnly = $false; ShapeProblem = $null; Legacy = $false; StartedAt = $null; StartedAtProblem = $null; Settings = $null; SettingsProblem = $null; Window = $null; WindowProblem = $null; Values = [ordered]@{} }
    try { $State = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { return $Info }
    if ($State -isnot [System.Management.Automation.PSCustomObject]) { return $Info }
    $TenantProp = $State.PSObject.Properties['TenantID']
    if ($null -eq $TenantProp -or [string]$TenantProp.Value -ne $Tenant) { return $Info }
    $Info.Exists = $true
    # A file that is not the right shape is moved aside later in the run
    # (Move-WrongShapeResumeStateFile); the run continues as -Resume does then.
    $Info.ShapeProblem = Get-ResumeStateShapeProblem -Record $State -Kind Main
    Set-ResumeRunInfoFields -Info $Info -State $State
    return $Info
}

# Fill $Info (the object Read-ResumeRunInfo returns) from the run record keys a
# parsed state object ($State: the resume state file, or a per-stream state
# file) holds: Values, Legacy, StartedAt or StartedAtProblem, Settings or
# SettingsProblem, Window or WindowProblem. Reads nothing else.
function Set-ResumeRunInfoFields
{
    param([Parameter(Mandatory = $true)][object]$Info, [Parameter(Mandatory = $true)][object]$State)
    foreach ($Key in @(Get-ResumeRunInfoKeys))
    {
        $Prop = $State.PSObject.Properties[$Key]
        if ($null -ne $Prop) { $Info.Values[$Key] = $Prop.Value }
    }

    $StartProp = $State.PSObject.Properties['RunStartedAt']
    $SettingsProp = $State.PSObject.Properties['RunSettings']
    $Info.Legacy = ($null -eq $StartProp -and $null -eq $SettingsProp)

    if ($null -eq $StartProp) { $Info.StartedAtProblem = 'it is not recorded' }
    else
    {
        $Info.StartedAt = ConvertFrom-ResumeRunStartTime -Value $StartProp.Value
        if ($null -eq $Info.StartedAt) { $Info.StartedAtProblem = 'it is not a date' }
    }

    if ($null -eq $SettingsProp) { $Info.SettingsProblem = 'they are not recorded' }
    elseif ($SettingsProp.Value -isnot [System.Management.Automation.PSCustomObject]) { $Info.SettingsProblem = 'they are not a JSON object' }
    else
    {
        $Settings = [ordered]@{}
        foreach ($Name in @(Get-RunDataSettingNames))
        {
            $Prop = $SettingsProp.Value.PSObject.Properties[$Name]
            if ($null -eq $Prop) { $Info.SettingsProblem = ('{0} is not recorded' -f $Name); break }
            if ($Prop.Value -isnot [bool]) { $Info.SettingsProblem = ('{0} is not true or false' -f $Name); break }
            $Settings[$Name] = $Prop.Value
        }
        if ($null -eq $Info.SettingsProblem) { $Info.Settings = $Settings }
    }

    $StartText = $State.PSObject.Properties['ConsumptionWindowStart']
    $EndText = $State.PSObject.Properties['ConsumptionWindowEnd']
    if ($null -eq $StartText -or $null -eq $EndText) { $Info.WindowProblem = 'it is not recorded' }
    else
    {
        # Only text: the window is written as two 'yyyy-MM-dd' strings.
        $Window = $null
        if ($StartText.Value -is [string] -and $EndText.Value -is [string]) { $Window = ConvertFrom-ConsumptionWindowArgument -Start $StartText.Value -End $EndText.Value }
        if ($null -eq $Window) { $Info.WindowProblem = 'it is not two yyyy-MM-dd dates, the start not after the end' }
        else { $Info.Window = $Window }
    }
}

# How two run records (as Read-ResumeRunInfo returns them) differ: one
# { What; Main; Other } for the start time, each setting and the cost window
# whose values are not the same (a value that cannot be read counts as its own
# value). Start times are compared as UTC times.
function Get-ResumeRunRecordDifferences
{
    param([Parameter(Mandatory = $true)][object]$Main, [Parameter(Mandatory = $true)][object]$Other)
    $Found = [System.Collections.Generic.List[object]]::new()
    $When = { param($Info) if ($null -ne $Info.StartedAt) { $Info.StartedAt.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss.fffffff', [cultureinfo]::InvariantCulture) + ' UTC' } else { 'a start time that cannot be read' } }
    $A = & $When $Main; $B = & $When $Other
    if ($A -ne $B) { $Found.Add([pscustomobject]@{ What = 'the start time'; Main = $A; Other = $B }) }
    foreach ($Name in @(Get-RunDataSettingNames))
    {
        $Value = { param($Info) if ($null -eq $Info.Settings) { 'not readable' } elseif ($Info.Settings[$Name]) { 'on' } else { 'off' } }
        $A = & $Value $Main; $B = & $Value $Other
        if ($A -ne $B) { $Found.Add([pscustomobject]@{ What = ('-' + $Name); Main = $A; Other = $B }) }
    }
    $Window = { param($Info) if ($null -ne $Info.Window) { Format-ConsumptionWindow -Window $Info.Window } else { 'a cost window that cannot be read' } }
    $A = & $Window $Main; $B = & $Window $Other
    if ($A -ne $B) { $Found.Add([pscustomobject]@{ What = 'the cost window'; Main = $A; Other = $B }) }
    return $Found.ToArray()
}

# The per-stream state files of the run the resume state file holds (its run
# id, Test-StreamStateRunId), readable and of the right shape, whose run record
# is not the one the resume state file records ($Main, from Read-ResumeRunInfo):
# { File; Differences } (Get-ResumeRunRecordDifferences). Files without a record
# (written before runs recorded one) are not compared.
function Get-StreamRecordMismatches
{
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [string]$RunId = '',
        [Parameter(Mandatory = $true)][object]$Main
    )
    $Found = [System.Collections.Generic.List[object]]::new()
    foreach ($File in @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $Tenant | Sort-Object Name))
    {
        $Obj = Read-StreamResumeStateFile -Path $File.FullName
        if ($null -eq $Obj -or $null -ne (Get-ResumeStateShapeProblem -Record $Obj -Kind Stream)) { continue }
        if (-not (Test-StreamStateRunId -State $Obj -RunId $RunId)) { continue }
        if ($null -eq $Obj.PSObject.Properties['RunStartedAt'] -and $null -eq $Obj.PSObject.Properties['RunSettings']) { continue }
        $Info = [pscustomobject]@{ Present = $true; Exists = $true; StreamOnly = $false; ShapeProblem = $null; Legacy = $false; StartedAt = $null; StartedAtProblem = $null; Settings = $null; SettingsProblem = $null; Window = $null; WindowProblem = $null; Values = [ordered]@{} }
        Set-ResumeRunInfoFields -Info $Info -State $Obj
        $Differences = @(Get-ResumeRunRecordDifferences -Main $Main -Other $Info)
        if ($Differences.Count -gt 0) { $Found.Add([pscustomobject]@{ File = $File.Name; Differences = $Differences }) }
    }
    return $Found.ToArray()
}

# The run record the per-stream state files of this tenant hold, for a run
# that has no resume state file it can use: none (-MainExists $false), or one
# that is not the right shape and is moved aside (-MainExists $true, -RunId its
# run id, '' when it has none). Only readable files of the right shape count.
# With a resume state file, the files of its run id; without one, the files
# that carry a record, of the run id whose record started last. Returns
# { HasRecord; RunId; Files; Conflict; Info }: Info as Read-ResumeRunInfo
# returns it (Exists set) when the files of that run that carry a record all
# carry the same one; Conflict lists those files when they do not. A file
# without a record (written by a version that did not record one) gives none.
function Read-StreamRunInfo
{
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [bool]$MainExists,
        [string]$RunId = ''
    )
    $Result = [pscustomobject]@{ HasRecord = $false; RunId = ''; Files = @(); Conflict = @(); Info = $null }
    $Read = @()
    foreach ($File in @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $Tenant | Sort-Object Name))
    {
        $Obj = Read-StreamResumeStateFile -Path $File.FullName
        if ($null -eq $Obj -or $null -ne (Get-ResumeStateShapeProblem -Record $Obj -Kind Stream)) { continue }
        $IdProp = $Obj.PSObject.Properties['RunId']
        $HasRecord = $null -ne $Obj.PSObject.Properties['RunStartedAt'] -or $null -ne $Obj.PSObject.Properties['RunSettings']
        $Read += [pscustomobject]@{ Name = $File.Name; RunId = $(if ($null -eq $IdProp) { '' } else { [string]$IdProp.Value }); Obj = $Obj; HasRecord = $HasRecord }
    }
    if ($MainExists) { $Run = @($Read | Where-Object { $_.RunId -eq [string]$RunId }) }
    else
    {
        $WithRecord = @($Read | Where-Object { $_.HasRecord })
        if ($WithRecord.Count -eq 0) { return $Result }
        # The run whose record started last; one whose start time cannot be read counts as the oldest.
        $Latest = @($WithRecord | Sort-Object -Property @{ Expression = { $When = ConvertFrom-ResumeRunStartTime -Value $_.Obj.PSObject.Properties['RunStartedAt'].Value; if ($null -eq $When) { [datetime]::MinValue } else { $When } } } -Descending)[0]
        $Run = @($Read | Where-Object { $_.RunId -eq $Latest.RunId })
    }
    $Recorded = @($Run | Where-Object { $_.HasRecord })
    if ($Recorded.Count -eq 0) { return $Result }
    $Result.RunId = [string]$Recorded[0].RunId
    $Result.Files = @($Run | ForEach-Object { $_.Name })
    $Texts = @($Recorded | ForEach-Object {
            $One = [ordered]@{}
            foreach ($Key in @(Get-ResumeRunInfoKeys)) { $P = $_.Obj.PSObject.Properties[$Key]; $One[$Key] = $(if ($null -eq $P) { $null } else { $P.Value }) }
            ConvertTo-Json -InputObject $One -Depth 4 -Compress
        } | Sort-Object -Unique)
    if ($Texts.Count -gt 1)
    {
        # Info holds only the latest start time these files record, so the run
        # can judge its age before it stops for the conflict (Resolve-RunStart).
        $Result.Conflict = @($Recorded | ForEach-Object { $_.Name })
        $Starts = @($Recorded | ForEach-Object { ConvertFrom-ResumeRunStartTime -Value $(if ($null -ne $_.Obj.PSObject.Properties['RunStartedAt']) { $_.Obj.PSObject.Properties['RunStartedAt'].Value }) } | Where-Object { $null -ne $_ } | Sort-Object -Descending)
        $Result.Info = [pscustomobject]@{ Present = $true; Exists = $true; StreamOnly = $false; ShapeProblem = $null; Legacy = $false; StartedAt = $(if ($Starts.Count -gt 0) { $Starts[0] } else { $null }); StartedAtProblem = $(if ($Starts.Count -gt 0) { $null } else { 'none of the per-stream state files records one that can be read' }); Settings = $null; SettingsProblem = 'the per-stream state files record different ones'; Window = $null; WindowProblem = 'the per-stream state files record different ones'; Values = [ordered]@{} }
        return $Result
    }
    $Info = [pscustomobject]@{ Present = $true; Exists = $true; StreamOnly = $false; ShapeProblem = $null; Legacy = $false; StartedAt = $null; StartedAtProblem = $null; Settings = $null; SettingsProblem = $null; Window = $null; WindowProblem = $null; Values = [ordered]@{} }
    Set-ResumeRunInfoFields -Info $Info -State $Recorded[0].Obj
    $Result.Info = $Info
    $Result.HasRecord = $true
    return $Result
}

# This run's record: { RunId; Info; NewRun }. Every write of the resume state
# carries it: the run id (none for a run that continues a file without one, so
# its per-stream files keep matching), and Info, the start time, settings and
# cost window (New-ResumeRunInfo keys). NewRun: a new run, whose writes start
# with nothing completed. Built once, where the run decides how it starts
# ($Start, from Resolve-RunStart), and kept in the script's $RunRecord:
#   a new run: a new id, this run's start time, settings and window;
#   a run that continues a file that records them: its id and record as
#     stored, with $Window as its cost window (the recorded one when it can be
#     used, which the caller passes);
#   a run that continues a file from an earlier version, only per-stream files
#     or a file that is not the right shape (moved aside): the stored id, if
#     any, with this run's start time, settings and window.
function New-ResumeRunRecord
{
    param(
        [Parameter(Mandatory = $true)][object]$Start,
        [Parameter(Mandatory = $true)][object]$StoredRun,
        [string]$StoredRunId,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory = $true)]$Window
    )
    $Own = New-ResumeRunInfo -StartedAt $StartedAt -Settings $Settings -Window $Window
    if ($Start.Mode -ne 'Continue') { return [pscustomobject]@{ RunId = [guid]::NewGuid().ToString(); Info = $Own; NewRun = $true } }
    if ($Start.Reason -in 'legacy', 'stream-only', 'wrong-shape') { return [pscustomobject]@{ RunId = [string]$StoredRunId; Info = $Own; NewRun = $false } }
    $Info = [ordered]@{}
    foreach ($Key in @($StoredRun.Values.Keys)) { $Info[$Key] = $StoredRun.Values[$Key] }
    $Info['ConsumptionWindowStart'] = $Own['ConsumptionWindowStart']
    $Info['ConsumptionWindowEnd'] = $Own['ConsumptionWindowEnd']
    return [pscustomobject]@{ RunId = [string]$StoredRunId; Info = $Info; NewRun = $false }
}

# The script's $RunRecord (New-ResumeRunRecord), or $null when there is none
# (the helpers used on their own).
function Get-ResumeStateRunRecord
{
    $Record = Get-ResumeStateRunList -Name 'RunRecord'
    if ($null -eq $Record -or $null -eq $Record.PSObject.Properties['Info'] -or $Record.Info -isnot [System.Collections.IDictionary]) { return $null }
    return $Record
}

# Put the run record ($Record) on a resume state object ($State) that is about
# to be written: the run id (when it has one) and the Info keys. For a new run,
# report records are kept only for the completed ids given ($Ids), as
# Save-CompletedSubscriptionIds keeps them. Does nothing without a record.
function Add-ResumeRunRecordKeys
{
    param([Parameter(Mandatory = $true)][object]$State, [object]$Record, [string[]]$Ids = @())
    if ($null -eq $Record) { return }
    if (-not [string]::IsNullOrEmpty([string]$Record.RunId)) { $State | Add-Member -NotePropertyName 'RunId' -NotePropertyValue ([string]$Record.RunId) -Force }
    foreach ($Key in @($Record.Info.Keys)) { $State | Add-Member -NotePropertyName $Key -NotePropertyValue $Record.Info[$Key] -Force }
    if ($Record.NewRun -and $null -ne $State.PSObject.Properties['CompletedReports'])
    {
        $Keep = @($Ids | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $State | Add-Member -NotePropertyName 'CompletedReports' -NotePropertyValue @(@($State.CompletedReports) | Where-Object { $null -ne $_ -and $Keep -contains [string]$_.Id }) -Force
    }
}


# Decide how a run starts, from what the resume state file holds (-Info, from
# Read-ResumeRunInfo), the switches given and this run's settings (-Settings,
# from Get-RunDataSettings). Prints nothing; returns { Mode; Reason; ExitCode;
# Lines; Differences }. Mode is Continue (continue the unfinished run, as
# -Resume does), New (start a new run) or Stop (end with ExitCode before it
# signs in, collects anything or writes the resume state; the transcript and
# the run lock are written before, as by every run). Lines are { Text; Colour }
# to print now.
# The rules, in order:
#   -Fresh with -Resume or -ResumeFailedOnly: Stop.
#   No resume state file but per-stream state files (StreamOnly), without
#     -Fresh: Continue, as -Resume does.
#   No unfinished run: New; with -ResumeFailedOnly, Stop (there is no retry list).
#   -Fresh: New.
#   A file that is not the right shape: Continue (it is moved aside later, as
#     for -Resume).
#   A file from before runs recorded their start time and settings: Continue
#     (neither can be checked; the start line says so).
#   The age, before the settings: the run started more than -MaxAgeDays ago,
#     its start time cannot be read, or it is more than a day in the future.
#     Without -Resume or -ResumeFailedOnly: New. With one: the settings, and a
#     warning naming its start date once they match.
#   The settings cannot be read, or differ from this run's: Stop.
#   Otherwise: Continue.
function Resolve-RunStart
{
    param(
        [Parameter(Mandatory = $true)][object]$Info,
        [bool]$Resume,
        [bool]$ResumeFailedOnly,
        [bool]$Fresh,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Settings,
        [int]$MaxAgeDays = 7,
        [datetime]$Now = [datetime]::UtcNow
    )
    $Lines = [System.Collections.Generic.List[object]]::new()
    $Differences = [System.Collections.Generic.List[object]]::new()
    $Explicit = $Resume -or $ResumeFailedOnly
    $Switch = if ($ResumeFailedOnly) { '-ResumeFailedOnly' } else { '-Resume' }
    $Decide = {
        param([string]$Mode, [string]$Reason, [int]$Code = 0)
        [pscustomobject]@{ Mode = $Mode; Reason = $Reason; ExitCode = $Code; Lines = $Lines.ToArray(); Differences = $Differences.ToArray() }
    }
    $Say = { param([string]$Text, [string]$Colour = 'Cyan') $Lines.Add([pscustomobject]@{ Text = $Text; Colour = $Colour }) }
    # How to start over: -Fresh, which -ResumeFailedOnly does not take.
    $FreshHow = if ($ResumeFailedOnly) { 'run the same command without -ResumeFailedOnly, with -Fresh,' } else { 'pass -Fresh' }
    $FreshAgain = if ($ResumeFailedOnly) { 'end this run and run the same command without -ResumeFailedOnly, with -Fresh' } else { 'end this run and start again with -Fresh' }
    # What a stop before sign-in leaves out. The transcript and the run lock are
    # written before this decision, as by every run.
    $NotDone = 'before it signs in, collects anything or writes the resume state'

    if ($Fresh -and $Explicit)
    {
        & $Say ('ERROR: -Fresh starts a new run and {0} continues the unfinished one, so they cannot be used together. This run stops here (exit 1), {1}.' -f $Switch, $NotDone) 'Red'
        & $Say ('  Next: run the same command with only one of them: -Fresh to start over, or {0}.' -f $Switch) 'Yellow'
        return (& $Decide 'Stop' 'fresh-with-resume' 1)
    }
    # Only per-stream state files of an interrupted parallel run: continue it, as
    # -Resume does (the startup fold reads them). Nothing records its start time
    # or settings.
    if (-not $Info.Exists -and $Info.StreamOnly -and -not $Fresh)
    {
        $Goes = if ($ResumeFailedOnly) { 'It reads them as -Resume does. When they hold a retry list it can use, it retries that list, uses its own cost window, and records its own start time, settings and cost window; when one is not the right shape, the retry list is not complete and it stops (see below).' } else { 'It continues that run, as -Resume does, uses its own cost window, and records its own start time, settings and cost window once it starts collecting.' }
        & $Say ('Per-stream state files of an interrupted parallel run are in the inventory folder, but no resume state file records when that run started, with which settings or which cost window, so this run cannot check them. {0}' -f $Goes) 'Yellow'
        & $Say ('  If that run used other settings than this one (-Obfuscate, -SkipMetrics, -SkipConsumption or -IncludeDisabled), {0}, so one consolidated zip does not mix them.' -f $FreshAgain) 'Yellow'
        return (& $Decide 'Continue' 'stream-only')
    }
    if (-not $Info.Exists)
    {
        if ($ResumeFailedOnly)
        {
            $Why = if ($Info.Present) { 'The resume state file for this tenant cannot be read (it is empty, not JSON, or for another tenant)' } else { 'No resume state file for this tenant is in the inventory folder' }
            & $Say ('ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry. {0}, so there is no retry list. It did not sign in, collect anything or write the resume state.' -f $Why) 'Red'
            & $Say '  Next: run the same command without -ResumeFailedOnly. It starts a new run that collects every subscription.' 'Yellow'
            return (& $Decide 'Stop' 'nothing-to-retry' 1)
        }
        if ($Resume)
        {
            & $Say 'Resume mode: no previous state found; processing all subscriptions.'
            & $Say 'Starting a new run: there is no unfinished run to continue.'
        }
        else { & $Say 'Starting a new run.' }
        return (& $Decide 'New' 'none')
    }
    $FromStreams = $null -ne $Info.PSObject.Properties['RecordSource'] -and $Info.RecordSource -eq 'stream'
    $Started = if ($null -ne $Info.StartedAt) { Format-RunStartTime -Time $Info.StartedAt } else { $null }
    if ($FromStreams -and -not $Fresh)
    {
        $Why = if ($Info.MainShapeProblem) { 'is not the right shape (it is moved aside below)' } else { 'is not in the inventory folder' }
        & $Say ('The resume state file {0}, so this run checks the start time, settings and cost window that the per-stream state files of the unfinished run record ({1}).' -f $Why, (@($Info.StreamFiles) -join ', ')) 'Yellow'
    }
    if ($Fresh)
    {
        $Which = if ($Started) { 'started {0}' -f $Started } else { 'in the resume state file' }
        & $Say ('Starting a new run (-Fresh). The unfinished run {0} is not continued: this run collects every subscription again.' -f $Which)
        return (& $Decide 'New' 'fresh')
    }
    # Not the right shape: the run continues as -Resume does, and the shape check
    # moves the file aside and says what the run uses instead.
    if ($null -ne $Info.ShapeProblem) { return (& $Decide 'Continue' 'wrong-shape') }
    if ($Info.Legacy)
    {
        & $Say 'The resume state file was written by an earlier version, which did not record when its run started, with which settings or which cost window, so this run cannot check them. It continues that run, as -Resume does, uses its own cost window, and records its own start time, settings and cost window in the file once it starts collecting.' 'Yellow'
        & $Say ('  If that run used other settings than this one (-Obfuscate, -SkipMetrics, -SkipConsumption or -IncludeDisabled), {0}, so one consolidated zip does not mix them.' -f $FreshAgain) 'Yellow'
        return (& $Decide 'Continue' 'legacy')
    }

    $AgeProblem = Get-ResumeRunAgeProblem -Info $Info -MaxAgeDays $MaxAgeDays -Now $Now
    if ($null -ne $AgeProblem)
    {
        $What = switch ($AgeProblem)
        {
            'old' { 'The unfinished run started {0}, more than {1} days ago' -f $Started, $MaxAgeDays }
            'future' { 'The resume state file records a start time in the future for the unfinished run ({0}), so its age is not known' -f $Started }
            default { 'The start time of the unfinished run cannot be read from the resume state file ({0}), so its age is not known' -f $Info.StartedAtProblem }
        }
        if (-not $Explicit)
        {
            & $Say ('{0}; starting a new run. Pass -Resume to continue it anyway.' -f $What) 'Yellow'
            return (& $Decide 'New' 'too-old')
        }
        # Said once the settings check below passes, so a run it stops does
        # not claim to continue; the metrics claim only when metrics are
        # collected (the settings check makes the stored setting the same).
        $Later = if ($Settings['SkipMetrics']) { '' } else { '; the metrics of the subscriptions it collects cover a later period than those collected earlier in that run' }
        $AgeWarning = 'WARNING: {0}. This run continues it because {1} was passed{2}.' -f $What, $Switch, $Later
    }

    # Per-stream files of the unfinished run that carry different records: the
    # run cannot tell which one is its own, so it stops (-Fresh starts over).
    # After the age check, judged by the latest start time they record: a run
    # without -Resume past the age limit has started a new run above, and the
    # old per-stream files are another run's.
    if ($FromStreams -and @($Info.RecordConflict).Count -gt 0 -and -not $Fresh)
    {
        & $Say ('ERROR: This run stops here (exit 1), {0}: the per-stream state files of the unfinished run record different start times, settings or cost windows ({1}), so this run cannot check that it collects the same way.' -f $NotDone, (@($Info.RecordConflict) -join ', ')) 'Red'
        & $Say ('  Next: {0} to start a new run that collects every subscription again.' -f $FreshHow) 'Yellow'
        return (& $Decide 'Stop' 'stream-records-differ' 1)
    }
    # A usable resume state file whose per-stream state files of the same run
    # record another start time, settings or cost window (StreamMismatch, from
    # Get-StreamRecordMismatches): one of them was changed or damaged after the
    # run wrote it, so this run cannot tell which one its earlier subscriptions
    # were collected with, and stops (-Fresh starts over). After the age check:
    # a run without -Resume past the age limit has started a new run above, and
    # the old per-stream files are another run's.
    $Mismatch = @(if ($null -ne $Info.PSObject.Properties['StreamMismatch']) { $Info.StreamMismatch | Where-Object { $null -ne $_ } })
    if ($Mismatch.Count -gt 0 -and -not $Fresh)
    {
        & $Say ('ERROR: This run stops here (exit 1), {0}: the resume state file and the per-stream state files of the unfinished run no longer record the same start time, settings and cost window ({1}). Only a file that was changed or damaged after the run wrote it can cause this, so this run cannot check that it collects the same way.' -f $NotDone, (@($Mismatch | ForEach-Object { $_.File }) -join ', ')) 'Red'
        foreach ($Item in $Mismatch)
        {
            foreach ($Difference in @($Item.Differences))
            {
                & $Say ('  {0}: {1} is {2} there, {3} in the resume state file.' -f $Item.File, $Difference.What, $Difference.Other, $Difference.Main) 'Red'
            }
        }
        & $Say ('  Next: {0} to start a new run that collects every subscription again.' -f $FreshHow) 'Yellow'
        return (& $Decide 'Stop' 'stream-records-differ-from-main' 1)
    }

    if ($null -ne $Info.SettingsProblem)
    {
        & $Say ('ERROR: This run stops here (exit 1), {0}: the resume state file records the settings of the unfinished run, but they cannot be read ({1}), so this run cannot check that it collects the same way.' -f $NotDone, $Info.SettingsProblem) 'Red'
        & $Say ('  Next: {0} to start a new run that collects every subscription again.' -f $FreshHow) 'Yellow'
        return (& $Decide 'Stop' 'settings-unreadable' 1)
    }
    foreach ($Name in @(Get-RunDataSettingNames))
    {
        if ([bool]$Info.Settings[$Name] -ne [bool]$Settings[$Name])
        {
            $Differences.Add([pscustomobject]@{ Name = $Name; Stored = [bool]$Info.Settings[$Name]; Given = [bool]$Settings[$Name] })
        }
    }
    if ($Differences.Count -gt 0)
    {
        $Which = if ($Started) { ' started {0}' -f $Started } else { '' }
        & $Say ('ERROR: This run stops here (exit 1), {0}: the unfinished run{1} used other settings than this run, and one consolidated zip must not mix them.' -f $NotDone, $Which) 'Red'
        foreach ($Difference in $Differences)
        {
            $OnOff = { param([bool]$Value) if ($Value) { 'on' } else { 'off' } }
            & $Say ('  -{0}: {1} in the unfinished run, {2} in this run.' -f $Difference.Name, (& $OnOff $Difference.Stored), (& $OnOff $Difference.Given)) 'Red'
        }
        & $Say ('  Next: run the same command with the unfinished run''s settings ({0}) to continue it, or {1} to start a new run that collects every subscription again.' -f (Format-RunDataSettings -Settings $Info.Settings), $FreshHow) 'Yellow'
        return (& $Decide 'Stop' 'settings-differ' 1)
    }
    if ($null -ne $AgeProblem) { & $Say $AgeWarning 'Yellow' }
    return (& $Decide 'Continue' $(if ($null -ne $AgeProblem) { 'old-explicit' } else { 'continue' }))
}

# True when per-stream state files of this tenant are in the inventory folder
# that a run continuing without a resume state file reads at its start: one
# with no run id (written before run ids existed, so the startup fold uses it),
# or one that cannot be read or is not the right shape (the startup fold moves
# it aside, as -Resume did). -Mode says which other files count: Any (-Resume)
# counts every file that cannot be used; Parsed (-ResumeFailedOnly) counts one
# that parses as JSON but is not the right shape, which the startup check moves
# aside and which stops -ResumeFailedOnly there (its retry list is not
# complete), but not one that cannot be parsed, which holds no retry list;
# Records (a run without either switch) counts neither, so such a run starts a
# new run and handles them as before. A file that carries a run id belongs to a
# run whose resume state file is gone, so no run can continue it; the end of a
# run names or removes it as another run's.
function Test-ResumableStreamStateFiles
{
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [ValidateSet('Any', 'Parsed', 'Records')][string]$Mode = 'Any'
    )
    foreach ($File in @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $Tenant))
    {
        $Obj = Read-StreamResumeStateFile -Path $File.FullName
        $Usable = $null -ne $Obj -and $null -eq (Get-ResumeStateShapeProblem -Record $Obj -Kind Stream)
        if ($Usable)
        {
            if (Test-StreamStateRunId -State $Obj -RunId '') { return $true }
            continue
        }
        if ($Mode -eq 'Any') { return $true }
        if ($Mode -eq 'Parsed')
        {
            $Parsed = $null
            try { $Parsed = Get-Content -LiteralPath $File.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $Parsed = $null }
            if ($null -ne $Parsed) { return $true }
        }
    }
    return $false
}

# Why a run without -Resume or -ResumeFailedOnly does not continue the run
# $Info (from Read-ResumeRunInfo) for its age: 'old' (it started more than
# $MaxAgeDays days ago), 'future' (more than a day ahead), 'unreadable' (no
# start time can be read), or $null when its age lets it continue.
function Get-ResumeRunAgeProblem
{
    param([Parameter(Mandatory = $true)][object]$Info, [int]$MaxAgeDays = 7, [datetime]$Now = [datetime]::UtcNow)
    if ($null -eq $Info.StartedAt) { return 'unreadable' }
    if ($Info.StartedAt -gt $Now.AddDays(1)) { return 'future' }
    if (($Now - $Info.StartedAt).TotalDays -gt $MaxAgeDays) { return 'old' }
    return $null
}

# The start line of a run that continues an unfinished run: when it started,
# how many of the subscriptions in scope are done and past the retry limit, its
# settings, and how to start over instead.
function Get-RunContinueLine
{
    param(
        [Parameter(Mandatory = $true)][object]$Info,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Settings,
        [int]$Done,
        [int]$Total,
        [int]$PastRetryLimit,
        # -ResumeFailedOnly does not take -Fresh: say to run without it.
        [switch]$ResumeFailedOnly
    )
    $Counts = '{0} of {1} subscriptions done' -f $Done, $Total
    if ($PastRetryLimit -gt 0) { $Counts += (', {0} past the retry limit' -f $PastRetryLimit) }
    $Lead = if ($null -ne $Info.StartedAt) { 'Continuing the run started {0} ({1})' -f (Format-RunStartTime -Time $Info.StartedAt), $Counts }
    elseif ($Info.Legacy) { 'Continuing the unfinished run (its start time is not recorded; {0})' -f $Counts }
    else { 'Continuing the unfinished run (its start time cannot be read; {0})' -f $Counts }
    $Over = if ($ResumeFailedOnly) { 'To start over, run the same command without -ResumeFailedOnly, with -Fresh.' } else { 'Pass -Fresh to start over.' }
    return ('{0}. Settings: {1}. {2}' -f $Lead, (Format-RunDataSettings -Settings $Settings), $Over)
}


# True when a per-stream state file ($State, as Read-StreamResumeStateFile
# returns it) belongs to the run with id $RunId: its RunId is the same, or
# neither has one (files written before run ids existed). A file of another
# run is never folded in, merged or deleted by this run.
function Test-StreamStateRunId
{
    param([object]$State, [string]$RunId)
    if ($null -eq $State) { return $false }
    $Prop = $State.PSObject.Properties['RunId']
    # A RunId that is not text belongs to no run: [string] of the number 5
    # would match a run id '5' (Get-ResumeStateShapeProblem also rejects it).
    if ($null -eq $Prop -or $null -eq $Prop.Value) { $FileRunId = '' }
    elseif ($Prop.Value -is [string]) { $FileRunId = $Prop.Value }
    else { return $false }
    return ($FileRunId -eq [string]$RunId)
}

# The per-stream state files of this tenant on disk now that another run wrote:
# readable, the right shape (Get-ResumeStateShapeProblem), with a run id other
# than $RunId (Test-StreamStateRunId), sorted by name. Files that cannot be read
# are not among them, nor files that are not the right shape: those are handled
# where per-stream files are read (Move-WrongShapeResumeStateFile), and a
# one-stream run without -Resume or -ResumeFailedOnly leaves them as they are.
function Get-OtherRunStreamStateFiles
{
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [string]$RunId
    )
    return @(Get-StreamResumeStateFiles -InventoryRoot $InventoryRoot -Tenant $Tenant | Sort-Object -Property Name | Where-Object {
            $Obj = Read-StreamResumeStateFile -Path $_.FullName
            $null -ne $Obj -and $null -eq (Get-ResumeStateShapeProblem -Record $Obj -Kind Stream) -and -not (Test-StreamStateRunId -State $Obj -RunId $RunId)
        })
}

# A run that does not end clean names the per-stream state files of another run
# still on disk (Get-OtherRunStreamStateFiles): at its normal end and at every
# early exit (Exit-Wrapper) once its run id is set. Prints nothing when there
# are none.
function Write-OtherRunStreamStateLine
{
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [string]$RunId
    )
    $Names = @(Get-OtherRunStreamStateFiles -InventoryRoot $InventoryRoot -Tenant $Tenant -RunId $RunId | ForEach-Object { $_.Name })
    if ($Names.Count -gt 0)
    {
        Write-Host ("The per-stream state files {0} were written by another run, so this run does not use them; they are left in place." -f ($Names -join ', ')) -ForegroundColor DarkGray
    }
}

# At the end of a run that ends clean: remove the per-stream state files of this
# tenant that another run wrote (Get-OtherRunStreamStateFiles). No run can
# resume them. Each removal stops on an error and is then checked; a file that
# is still there is named in a warning. Files that cannot be read are left for
# the -Resume that handles them. Returns { Removed; Left } (file names).
function Remove-OtherRunStreamStateFiles
{
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant,
        [string]$RunId
    )
    $Removed = @()
    $Left = @()
    foreach ($File in @(Get-OtherRunStreamStateFiles -InventoryRoot $InventoryRoot -Tenant $Tenant -RunId $RunId))
    {
        $Reason = $null
        try { Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop }
        catch { $Reason = $_.Exception.Message }
        if (-not (Test-Path -LiteralPath $File.FullName)) { $Removed += $File.Name; continue }
        if ([string]::IsNullOrEmpty($Reason)) { $Reason = 'it is still there after the removal' }
        Write-Host ('WARNING: Could not remove the per-stream state file {0}, which another run wrote: {1}' -f $File.Name, $Reason) -ForegroundColor Yellow
        $Left += $File.Name
    }
    if ($Removed.Count -gt 0)
    {
        Write-Host ('Removed the per-stream state files {0}, which another run wrote and no run can resume.' -f ($Removed -join ', ')) -ForegroundColor DarkGray
    }
    return [pscustomobject]@{ Removed = $Removed; Left = $Left }
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
# <name>.unreadable-<UTC time>, with -2, -3 and so on added when that name is
# taken, and kept for inspection: that name ends neither in '.json' nor
# matches Get-StreamResumeStateFiles, so no later run reads it
# and no zip step that picks files by '*.json' takes it. Prints a warning
# naming the file, never its content. Returns { Kind; Name; MovedTo; Path;
# Problem; Reason; NotMoved; Unreadable }.
# When the file cannot be renamed, later runs would read it again and warn
# again with no end, so the run stops the way it does for a file that is not
# the right shape (Stop-WrongShapeStateNotMoved): the result has NotMoved set
# and MovedTo $null, and this prints nothing at startup, where the caller stops
# with exit 1 before any file is folded in; with -AtRunEnd it prints the notice
# and the wrapper stops at the end of the run under the exit-2 rule.
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
    $Base = '{0}.unreadable-{1}' -f $File.Name, $Now.ToString('yyyyMMdd-HHmmss')
    # As in Move-WrongShapeResumeStateFile: a second move in the same second, or
    # a name an earlier run left, must not make the rename fail. Up to 100 names
    # are tried.
    $MovedTo = $Base
    $N = 1
    while ($null -ne $MovedTo -and (Test-Path -LiteralPath (Join-Path $File.DirectoryName $MovedTo)))
    {
        $N++
        $MovedTo = if ($N -le 100) { '{0}-{1}' -f $Base, $N } else { $null }
    }
    if ($AtRunEnd)
    {
        $Lead = 'WARNING: The per-stream state file {0} could not be read, so its records are not used: the subscriptions it lists are not counted as completed, and a later -Resume collects them again.' -f $File.Name
    }
    else
    {
        $Then = if ($ResumeFailedOnly) { 'a later -Resume collects them (-ResumeFailedOnly retries only the retry list)' } else { 'this run collects them again' }
        $Lead = 'WARNING: The per-stream state file {0} from an interrupted parallel run could not be read, so its records are not used: the subscriptions it lists are not counted as completed and {1}.' -f $File.Name, $Then
    }
    try
    {
        if ($null -eq $MovedTo) { throw ('every name from {0} to {0}-100 is taken' -f $Base) }
        Rename-Item -LiteralPath $File.FullName -NewName $MovedTo -ErrorAction Stop
        Write-Host ('{0} It was moved aside to {1}.' -f $Lead, $MovedTo) -ForegroundColor Yellow
    }
    catch
    {
        $NotMoved = [pscustomobject]@{ Kind = 'Stream'; Name = $File.Name; MovedTo = $null; Path = $File.FullName; Problem = $null; Reason = $_.Exception.Message; NotMoved = $true; Unreadable = $true }
        if ($AtRunEnd)
        {
            Write-WrongShapeNotMovedLine -File $NotMoved
            Write-Host "  This run does not use the file's records and does not write over it. It goes on as usual and ends with exit 1 (exit 2 when a report is missing or a subscription failed), with what to do next at its end." -ForegroundColor Red
        }
        return $NotMoved
    }
    return [pscustomobject]@{ Kind = 'Stream'; Name = $File.Name; MovedTo = $MovedTo; Path = $File.FullName; Problem = $null; Reason = $null; NotMoved = $false; Unreadable = $true }
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

# The subscription ids a per-stream state file holds records for: every id in
# its lists, whether listed as an id (Completed) or as a record with an Id
# (FailedAttempts, and any other list of per-id records the file carries).
function Get-StreamStateRecordIds
{
    param([object]$State)
    if ($null -eq $State) { return @() }
    $Ids = @()
    foreach ($Prop in @($State.PSObject.Properties))
    {
        if ($null -eq $Prop.Value -or $Prop.Value -is [string] -or $Prop.Value -isnot [System.Collections.IEnumerable]) { continue }
        foreach ($Item in @($Prop.Value))
        {
            if ($Item -is [string]) { $Ids += $Item }
            elseif ($null -ne $Item -and $null -ne $Item.PSObject.Properties['Id']) { $Ids += [string]$Item.Id }
        }
    }
    return @($Ids | Where-Object { $_ } | Sort-Object -Unique)
}

# One per-id record as a string that two copies of the same record share
# whether they come from this run's memory or from the file: a round trip
# through JSON (so a date read from the file and the one this run wrote compare
# alike), then every field in name order.
function ConvertTo-ResumeRecordText
{
    param([object]$Record)
    if ($null -eq $Record) { return '' }
    $Copy = $Record | ConvertTo-Json -Depth 6 -Compress | ConvertFrom-Json
    $Sorted = [ordered]@{}
    foreach ($Name in @($Copy.PSObject.Properties.Name | Sort-Object)) { $Sorted[$Name] = $Copy.$Name }
    return ($Sorted | ConvertTo-Json -Depth 6 -Compress)
}

# The per-id lists this version keeps in the resume state and in a per-stream
# state file, and the script variable a run keeps each one in: State is the key
# in the resume state file, Stream the key in a per-stream state file, Run the
# variable. CompletedOnly marks a list the resume state keeps for completed
# subscriptions only. A list a later version adds needs its entry here, or a
# per-stream state file holding it is renamed aside once its other records are
# held (Get-StreamStateUntrackedLists, Move-UntrackedStreamStateFiles).
function Get-ResumeStateRecordLists
{
    return @(
        [pscustomobject]@{ State = 'CompletedSubscriptionIds'; Stream = 'Completed'; Run = 'CompletedIds'; CompletedOnly = $false }
        [pscustomobject]@{ State = 'FailedAttempts'; Stream = 'FailedAttempts'; Run = 'FailedAttempts'; CompletedOnly = $false }
        # The report zip of each completed subscription (New-CompletedReportRecord):
        # 'CompletedReports' in the resume state, 'Reports' in a per-stream file.
        [pscustomobject]@{ State = 'CompletedReports'; Stream = 'Reports'; Run = 'CompletedReports'; CompletedOnly = $true }
    )
}

# The value of the script variable $Name, or $null when there is none. The name
# is taken literally (no wildcard), and only the script scope is read, so a
# local of the same name in a calling function is not used.
function Get-ResumeStateRunList
{
    param([Parameter(Mandatory = $true)][string]$Name)
    $Variable = $ExecutionContext.SessionState.PSVariable.Get('script:' + $Name)
    if ($null -eq $Variable) { return $null }
    return $Variable.Value
}

# True for a per-id record: an object with an Id.
function Test-ResumeStateRecord
{
    param([object]$Item)
    return ($null -ne $Item -and $Item -isnot [string] -and $Item -isnot [ValueType] -and $null -ne $Item.PSObject.Properties['Id'])
}

# The lists with entries in a per-stream state file ($State, as
# Read-StreamResumeStateFile returns it) that this version does not keep: keys
# holding a list other than the Stream names of Get-ResumeStateRecordLists.
function Get-StreamStateUntrackedLists
{
    param([object]$State)
    if ($null -eq $State) { return @() }
    $Tracked = @(Get-ResumeStateRecordLists | ForEach-Object { $_.Stream })
    return @($State.PSObject.Properties | Where-Object {
            $Tracked -notcontains $_.Name -and $null -ne $_.Value -and $_.Value -isnot [string] -and
            $_.Value -is [System.Collections.IEnumerable] -and @($_.Value | Where-Object { $null -ne $_ }).Count -gt 0
        } | ForEach-Object { $_.Name })
}

# The ids among $Ids whose record in the resume state file on disk is not the
# one this run holds. Compared: whether the id is completed ($CompletedIds
# against CompletedSubscriptionIds), then, as whole records, every list of
# per-id records that this version keeps (Get-ResumeStateRecordLists: the retry
# list $FailedAttempts, and each other list from its script variable) or that
# the file holds (records with an Id). A list the file does not have, or the
# run does not keep, reads as none on that side, so a record on only one side is
# a mismatch. Lists marked CompletedOnly are compared for the ids this run holds
# as completed, every other list for every id. Each list is indexed by id once,
# the last record winning, as each writer lets it. Every id comes back when the
# file is missing, cannot be read or is for another tenant. Read before
# per-stream state files are deleted, so they are deleted only once the resume
# state holds every record they gave as this run holds it.
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
        $OnDisk = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        return $Wanted
    }
    if ($OnDisk -isnot [System.Management.Automation.PSCustomObject]) { return $Wanted }
    # A key the file does not have reads as none.
    $Key = { param($Name) $Prop = $OnDisk.PSObject.Properties[$Name]; if ($null -ne $Prop) { $Prop.Value } }
    if ([string](& $Key 'TenantID') -ne $Tenant) { return $Wanted }
    $OnDiskCompleted = [System.Collections.Generic.HashSet[string]]::new([string[]]@(& $Key 'CompletedSubscriptionIds' | Where-Object { $_ } | ForEach-Object { [string]$_ }))
    $RunCompleted = [System.Collections.Generic.HashSet[string]]::new([string[]]@($CompletedIds | Where-Object { $_ } | ForEach-Object { [string]$_ }))
    $Index = {
        param($List)
        $ById = @{}
        foreach ($Item in @($List)) { if (Test-ResumeStateRecord -Item $Item) { $ById[[string]$Item.Id] = $Item } }
        $ById
    }
    # The record lists to compare, by their key in the resume state file.
    $Lists = [ordered]@{}
    foreach ($Entry in @(Get-ResumeStateRecordLists))
    {
        if ($Entry.State -eq 'CompletedSubscriptionIds') { continue }
        $RunList = if ($Entry.Run -eq 'FailedAttempts') { $FailedAttempts } else { Get-ResumeStateRunList -Name $Entry.Run }
        $Lists[$Entry.State] = [pscustomobject]@{ Run = $RunList; CompletedOnly = [bool]$Entry.CompletedOnly }
    }
    foreach ($Prop in @($OnDisk.PSObject.Properties))
    {
        if ($Prop.Name -eq 'CompletedSubscriptionIds' -or $Lists.Contains($Prop.Name)) { continue }
        if (@($Prop.Value | Where-Object { Test-ResumeStateRecord -Item $_ }).Count -gt 0)
        {
            $Lists[$Prop.Name] = [pscustomobject]@{ Run = $null; CompletedOnly = $false }
        }
    }
    $Mismatch = [System.Collections.Generic.List[string]]::new()
    foreach ($Id in $Wanted)
    {
        if ($OnDiskCompleted.Contains($Id) -ne $RunCompleted.Contains($Id)) { $Mismatch.Add($Id) }
    }
    foreach ($Name in @($Lists.Keys))
    {
        $RunById = & $Index $Lists[$Name].Run
        $DiskById = & $Index (& $Key $Name)
        foreach ($Id in $Wanted)
        {
            if ($Mismatch.Contains($Id)) { continue }
            if ($Lists[$Name].CompletedOnly -and -not $RunCompleted.Contains($Id)) { continue }
            $InRun = $RunById.ContainsKey($Id)
            $OnFile = $DiskById.ContainsKey($Id)
            if (-not $InRun -and -not $OnFile) { continue }
            if ($InRun -ne $OnFile -or (ConvertTo-ResumeRecordText -Record $RunById[$Id]) -ne (ConvertTo-ResumeRecordText -Record $DiskById[$Id])) { $Mismatch.Add($Id) }
        }
    }
    return @($Mismatch | Sort-Object -Unique)
}

# A per-stream state file holding a list this version does not keep
# (Get-StreamStateUntrackedLists) is not deleted where the others are: its
# completed and failed subscriptions were used, and the file is renamed in place
# to <name>.unused-<UTC time> with a warning naming the list, kept for
# inspection. That name ends neither in '.json' nor matches
# Get-StreamResumeStateFiles, so no run reads it, and it stays a dot-file in the
# inventory root, which no zip step takes. $Files are file objects or paths.
# Returns { Left = the paths of the other files; Moved = @({ Name; MovedTo;
# Lists }); NotMoved = the paths that could not be renamed }.
function Move-UntrackedStreamStateFiles
{
    param([object]$Files, [datetime]$Now = [datetime]::UtcNow)
    $Left = @()
    $Moved = @()
    $NotMoved = @()
    foreach ($File in @($Files | Where-Object { $null -ne $_ }))
    {
        $Path = if ($File -is [string]) { $File } else { $File.FullName }
        $Lists = @(Get-StreamStateUntrackedLists -State (Read-StreamResumeStateFile -Path $Path))
        if ($Lists.Count -eq 0) { $Left += $Path; continue }
        $Name = Split-Path -Path $Path -Leaf
        $MovedTo = '{0}.unused-{1}' -f $Name, $Now.ToString('yyyyMMdd-HHmmss')
        $Lead = 'WARNING: The per-stream state file {0} holds records this version does not keep ({1}); its completed and failed subscriptions were used.' -f $Name, ($Lists -join ', ')
        try
        {
            Rename-Item -LiteralPath $Path -NewName $MovedTo -ErrorAction Stop
            Write-Host ('{0} It was moved aside to {1}.' -f $Lead, $MovedTo) -ForegroundColor Yellow
            $Moved += [pscustomobject]@{ Name = $Name; MovedTo = $MovedTo; Lists = $Lists }
        }
        catch
        {
            Write-Host ('{0} It could not be moved aside ({1}), so a later -Resume reads it again.' -f $Lead, $_.Exception.Message) -ForegroundColor Yellow
            $NotMoved += $Path
        }
    }
    return [pscustomobject]@{ Left = $Left; Moved = $Moved; NotMoved = $NotMoved }
}

# Delete per-stream state files ($Files, the ids they hold records for in $Ids)
# once the resume state file on disk holds those records as this run holds
# them (Get-ResumeStateRecordMismatch); each removal is checked
# (Remove-StreamStateFiles), and the resume state file is kept while one is
# left. A file holding a list this version does not keep is renamed aside
# instead (Move-UntrackedStreamStateFiles); -Moved, when given, collects those.
# Otherwise keep them all, with a warning naming them, so a later -Resume folds
# them in again and nothing is lost. That holds while the resume state file
# holds this run's id ($RunId, the script's when not given); when it does not
# (its write failed from the start of the run), a later -Resume does not read
# these files, and the warning says so. Used for the files a run folded in at
# startup when it keeps the resume state or ends early, and for the files of a
# parallel run's streams at its end-of-run merge ($Source says which, for the
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
        [string]$Source = 'this run read at startup',
        [System.Collections.Generic.List[object]]$Moved,
        [string]$RunId
    )
    if (-not $PSBoundParameters.ContainsKey('RunId')) { $RunId = [string](Get-ResumeStateRunList -Name 'RunId') }
    $Left = @($Files | Where-Object { $null -ne $_ -and (Test-Path -LiteralPath $_.FullName -PathType Leaf) })
    if ($Left.Count -eq 0) { return @() }
    $NotHeld = @(Get-ResumeStateRecordMismatch -Path $ResumeStateFile -Tenant $Tenant -Ids $Ids -CompletedIds $CompletedIds -FailedAttempts $FailedAttempts)
    if ($NotHeld.Count -gt 0)
    {
        $StateName = Split-Path -Path $ResumeStateFile -Leaf
        $Names = @($Left | ForEach-Object { $_.Name }) -join ', '
        if ([string](Get-ResumeStateRunId -Path $ResumeStateFile -Tenant $Tenant) -eq [string]$RunId)
        {
            Write-Host ("WARNING: The resume state file {0} could not be written or read back with every record of the per-stream state files {1}, so they are kept and a later -Resume reads them again: {2}" -f $StateName, $Source, $Names) -ForegroundColor Yellow
        }
        else
        {
            Write-Host ("WARNING: The resume state file {0} could not be written or read back with every record of the per-stream state files {1}, so they are kept: {2}. The resume state file does not hold this run's id, so a later run does not read them and may not see what this run completed or failed. Once the file can be written, start the next run with -Fresh." -f $StateName, $Source, $Names) -ForegroundColor Yellow
        }
        return @($Left | ForEach-Object { $_.FullName })
    }
    $Untracked = Move-UntrackedStreamStateFiles -Files $Left
    if ($null -ne $Moved) { foreach ($Item in @($Untracked.Moved)) { $Moved.Add($Item) } }
    return @($Untracked.NotMoved) + @(Remove-StreamStateFiles -StreamFiles @($Untracked.Left) -StateFile $ResumeStateFile)
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
# The retry-list entries ($FailedAttempts) of the subscriptions the up-front
# role check ($Decision) skipped because the identity has no read role on them
# (State NoAccess), and the list without them: { FailedAttempts; Removed }. A
# check that could not finish, or answers that disagree, keep their entries
# (Add-RoleCheckRetryAttempts).
function Remove-NoRoleRetryAttempts
{
    param([object]$FailedAttempts, $Decision)
    $NoRoleIds = @(if ($null -ne $Decision) { @($Decision.Inaccessible) | Where-Object { $null -ne $_ -and [string]$_.State -eq 'NoAccess' } | ForEach-Object { [string]$_.Id } })
    $List = @($FailedAttempts | Where-Object { $null -ne $_ })
    return [pscustomobject]@{
        FailedAttempts = @($List | Where-Object { $NoRoleIds -notcontains [string]$_.Id })
        Removed        = @($List | Where-Object { $NoRoleIds -contains [string]$_.Id })
    }
}

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
    # This run's record goes into the same write, so the file never pairs this
    # run's lists with the record of the run it replaces (Add-ResumeRunRecordKeys).
    Add-ResumeRunRecordKeys -State $State -Record (Get-ResumeStateRunRecord) -Ids $Ids
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
# for each run that failed the subscription, removed when it completes. 0 is a
# subscription on the retry list that no run has failed: its stream did not load
# its Az context snapshot (Add-FailedAttempt -NotCounted). An entry without a
# whole number of at least 0 there (written by hand, or damaged) counts as one
# failed run, so it is retried as before instead of stopping the run.
function Get-FailedAttemptCount
{
    param([object]$Entry)
    $Count = 0
    if ($null -ne $Entry -and [int]::TryParse([string]$Entry.Attempts, [ref]$Count) -and $Count -ge 0) { return $Count }
    return 1
}

# The retry-list entries of the subscriptions that failed $RetryLimit runs in a
# row. A run that continues the unfinished run (with or without -Resume) and
# -ResumeFailedOnly do not collect these; a new run (-Fresh, or one past
# -ResumeMaxAgeDays) still does, and only such a run takes them off the retry list.
function Get-RetryLimitedAttempts
{
    param([object]$FailedAttempts)
    $RetryLimit = 3
    return @(@($FailedAttempts) | Where-Object { $null -ne $_ -and (Get-FailedAttemptCount -Entry $_) -ge $RetryLimit })
}

# The lines under the wrapper's FAILED (consumption) banner: the command that
# collects each such subscription again. One that has now failed $RetryLimit
# runs in a row is not collected by a run that continues this one, so it is
# named apart with the -Fresh command, as Write-RetryLimitSummary names it.
function Get-ConsumptionFailedAdvice
{
    param([object[]]$Entries, [object]$FailedAttempts, [string]$TenantID)
    $List = @(Get-ConsumptionIncompleteEntries -Entries $Entries)
    $LimitIds = @(Get-RetryLimitedAttempts -FailedAttempts $FailedAttempts | ForEach-Object { [string]$_.Id })
    $Retried = @($List | Where-Object { $LimitIds -notcontains [string]$_.Id })
    $AtLimit = @($List | Where-Object { $LimitIds -contains [string]$_.Id })
    $Lines = @()
    if ($Retried.Count -gt 0)
    {
        $Lines += ('On the retry list, so the next run with the same settings collects {0} again; to collect only the retry list:' -f (@($Retried | ForEach-Object { $_.Name }) -join ', '))
        $Lines += ('  ./Run-AllSubscriptions.ps1 -TenantID {0} -ResumeFailedOnly' -f $TenantID)
        $Lines += 'A subscription that fails 3 runs in a row is not collected again by a run that continues this one (Retry Limit Reached).'
    }
    if ($AtLimit.Count -gt 0)
    {
        $Lines += ('{0} failed 3 runs in a row (Retry Limit Reached), so a run that continues this one does not collect {1} again; to try again, start a new run with -Fresh:' -f (@($AtLimit | ForEach-Object { $_.Name }) -join ', '), $(if ($AtLimit.Count -eq 1) { 'it' } else { 'them' }))
        $Lines += ('  ./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh' -f $TenantID)
    }
    return $Lines
}

# Name the retry-list entries Get-RetryLimitedAttempts returned at the end of a
# run, with their count and last reason, as incomplete. Prints nothing for an
# empty list.
function Write-RetryLimitSummary
{
    param([object]$RetryLimited, [string]$TenantID, [string[]]$NotListedIds = @(), [string[]]$NotReadableIds = @())
    $List = @(@($RetryLimited) | Where-Object { $null -ne $_ })
    if ($List.Count -eq 0) { return }
    Write-Host ("Retry Limit Reached:     {0} ({1}) - incomplete; a run that continues this one (with or without -Resume) and -ResumeFailedOnly do not collect these" -f $List.Count, (@($List | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
    foreach ($Entry in $List)
    {
        Write-Host ("  - {0} ({1}): failed {2} runs in a row; last reason: {3}" -f $Entry.Name, $Entry.Id, (Get-FailedAttemptCount -Entry $Entry), $Entry.Reason) -ForegroundColor Yellow
    }
    # A subscription missing from a listing that came back with warnings or
    # errors is kept until a complete listing: no run can tell whether it is
    # gone (then the run drops it) or only hidden (then a new run with -Fresh
    # collects it), so the advice is to fix the listing first.
    $NotListed = @($List | Where-Object { @($NotListedIds) -contains [string]$_.Id })
    if ($NotListed.Count -gt 0)
    {
        Write-Host ("  {0} not in the subscription list, which came back with warnings or errors (printed at the start of the run). Fix those until 'Get-AzSubscription -TenantId {1}' lists the tenant without them, then run again: the run drops a subscription that is gone from the retry list, and collects one that is listed again, for example:" -f ((@($NotListed | ForEach-Object { $_.Name }) -join ', ') + $(if ($NotListed.Count -eq 1) { ' is' } else { ' are' })), $TenantID) -ForegroundColor Yellow
        Write-Host ("    ./Run-AllSubscriptions.ps1 -TenantID {0}" -f $TenantID) -ForegroundColor Yellow
    }
    $List = @($List | Where-Object { @($NotListedIds) -notcontains [string]$_.Id })
    if ($List.Count -eq 0) { return }
    # A subscription this run's access check skipped stays out of every run until
    # the check passes for it, so the advice names that first. Such an entry is
    # one whose check could not finish or whose two answers disagree; one with no
    # read role was taken off the retry list by the check.
    $NotReadable = @($List | Where-Object { @($NotReadableIds) -contains [string]$_.Id })
    if ($NotReadable.Count -gt 0)
    {
        Write-Host ("  {0} skipped by the access check at the start of this run (the reason and the fix are printed there). Once the check passes for {1}, start a new run with -Fresh, for example:" -f ((@($NotReadable | ForEach-Object { $_.Name }) -join ', ') + $(if ($NotReadable.Count -eq 1) { ' was' } else { ' were' })), $(if ($NotReadable.Count -eq 1) { 'it' } else { 'them' })) -ForegroundColor Yellow
        Write-Host ("    ./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh" -f $TenantID) -ForegroundColor Yellow
    }
    $List = @($List | Where-Object { @($NotReadableIds) -notcontains [string]$_.Id })
    if ($List.Count -eq 0) { return }
    Write-Host "  To try them again, start a new run with -Fresh (it collects every subscription again), for example:" -ForegroundColor Yellow
    Write-Host ("    ./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh" -f $TenantID) -ForegroundColor Yellow
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
        # A subscription's billing download failed or stopped part-way for a
        # reason other than the sign-in: its cost data is incomplete, so 3, as
        # for a data phase skipped for the sign-in.
        [bool]$ConsumptionFailed = $false,
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
    $DataIncomplete = $AuthSkipped -or $ConsumptionFailed
    if ($DataIncomplete -and $CollectorsFailed) { return 5 }
    if ($DataIncomplete) { return 3 }
    if ($CollectorsFailed) { return 4 }
    return 0
}

# ---- One run at a time for each tenant --------------------------------------
# Two runs for one tenant in one inventory folder would share the resume state
# file and the per-stream state files and overwrite each other's progress, so
# the wrapper holds a lock file for the tenant from before it reads any resume
# state until it exits:
#   <InventoryRoot>/.run-lock-<TenantID>.json
# It is a dot-file named like the resume state file; no resume-state,
# per-stream or zip step reads it or packs it. A run creates the lock only when
# there is none (the file is created only if it is absent, and written to disk
# before the run goes on), and only that run refreshes it and removes it. A run
# that finds a lock stops with exit 1, whoever wrote it: a lock is never taken
# over. The lock holds the full host name, the process id, that process's
# start time (on Linux also the boot id and the start in clock ticks since
# boot), the run's start time, a heartbeat time refreshed every minute (all
# UTC), an id for this run of the wrapper and the id of the runspace it runs
# in. They are used only to say in the stop message who holds the lock and
# what to do about it (Get-RunLockHolder, Write-RunLockHeldMessage).
# Stream worker processes never take the lock; the wrapper holds it for them.

function Get-RunLockPath
{
    param(
        [Parameter(Mandatory = $true)][string]$InventoryRoot,
        [Parameter(Mandatory = $true)][string]$Tenant
    )
    # Small letters: a tenant id typed in capitals names the same tenant, and
    # on a file system that tells case apart it would otherwise get a lock of
    # its own.
    return (Join-Path $InventoryRoot ('.run-lock-{0}.json' -f $Tenant.ToLowerInvariant()))
}

# The lock's times are written as round-trip UTC text ('o'). Returns that time
# as UTC, or $null for a value that is missing, not text, or not a date.
function ConvertTo-RunLockTime
{
    param($Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $null }
    $Parsed = [datetime]::MinValue
    $Styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $Styles, [ref]$Parsed)) { return $Parsed }
    return $null
}

function Format-RunLockTime
{
    param([Parameter(Mandatory = $true)][datetime]$Value)
    return ('{0} UTC' -f $Value.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture))
}

# Reads a lock file. Returns Exists, Valid, Problem (why it is not valid), Raw
# (its text; $null when it could not be read), FileWriteTimeUtc and the
# recorded values, times as UTC. A read that fails, or a lock that is not
# valid, is read again for about 2 seconds (Attempts): a run that has just
# created its lock may not have written it yet, and a file another process has
# open for a moment, or a share that is away for a moment, is not reported as
# unreadable. Read as plain JSON (System.Text.Json) so the recorded times stay
# text until ConvertTo-RunLockTime parses them. The run id and the runspace id
# are not required.
function Read-RunLock
{
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Attempts = 10,
        [int]$RetryMilliseconds = 200
    )
    for ($Try = 1; $Try -le $Attempts; $Try++)
    {
        $Lock = Read-RunLockOnce -Path $Path
        if (-not $Lock.Exists -or $Lock.Valid) { return $Lock }
        if ($Try -lt $Attempts) { Start-Sleep -Milliseconds $RetryMilliseconds }
    }
    return $Lock
}

function Read-RunLockOnce
{
    param([Parameter(Mandatory = $true)][string]$Path)
    $Lock = [pscustomobject]@{
        Exists              = $false
        Valid               = $false
        Problem             = $null
        Raw                 = $null
        FileWriteTimeUtc    = $null
        MachineName         = $null
        ProcessId           = $null
        ProcessStartTimeUtc = $null
        RunStartTimeUtc     = $null
        HeartbeatUtc        = $null
        BootId              = $null
        ProcessStartTicks   = $null
        InvocationId        = $null
        RunspaceId          = $null
    }
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $Item) { return $Lock }
    $Lock.Exists = $true
    $Lock.FileWriteTimeUtc = $Item.LastWriteTimeUtc
    try
    {
        $Lock.Raw = Read-RunLockText -Path $Item.FullName
    }
    catch [System.IO.FileNotFoundException]
    {
        $Lock.Exists = $false
        return $Lock
    }
    catch
    {
        $Lock.Problem = Get-RunLockErrorText -ErrorRecord $_
        return $Lock
    }

    $Values = @{}
    try
    {
        $Document = [System.Text.Json.JsonDocument]::Parse($Lock.Raw)
        try
        {
            foreach ($Property in $Document.RootElement.EnumerateObject())
            {
                $Number = 0
                if ($Property.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::String) { $Values[$Property.Name] = $Property.Value.GetString() }
                elseif ($Property.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::Number -and $Property.Value.TryGetInt32([ref]$Number)) { $Values[$Property.Name] = $Number }
                else { $Values[$Property.Name] = $null }
            }
        }
        finally
        {
            $Document.Dispose()
        }
    }
    catch
    {
        $Lock.Problem = $(if ($Lock.Raw.Length -eq 0) { 'it is empty' } else { 'it is not a JSON object' })
        return $Lock
    }

    $NotValid = @()
    if ($Values['MachineName'] -is [string] -and -not [string]::IsNullOrWhiteSpace($Values['MachineName'])) { $Lock.MachineName = $Values['MachineName'] }
    else { $NotValid += 'MachineName' }
    if ($Values['ProcessId'] -is [int] -and $Values['ProcessId'] -gt 0) { $Lock.ProcessId = $Values['ProcessId'] }
    else { $NotValid += 'ProcessId' }
    foreach ($Name in 'ProcessStartTimeUtc', 'RunStartTimeUtc', 'HeartbeatUtc')
    {
        $Time = ConvertTo-RunLockTime -Value $Values[$Name]
        if ($null -eq $Time) { $NotValid += $Name }
        else { $Lock.$Name = $Time }
    }
    if ($NotValid.Count -gt 0)
    {
        $Lock.Problem = ('{0} missing or not valid' -f ($NotValid -join ', '))
        return $Lock
    }
    if ($Values['InvocationId'] -is [string] -and -not [string]::IsNullOrWhiteSpace($Values['InvocationId'])) { $Lock.InvocationId = $Values['InvocationId'] }
    if ($Values['RunspaceId'] -is [int]) { $Lock.RunspaceId = $Values['RunspaceId'] }
    # Linux only; a lock without them is described by its start time.
    if ($Values['BootId'] -is [string] -and $Values['BootId'] -match '^[0-9a-f-]{36}$') { $Lock.BootId = $Values['BootId'] }
    if ($Values['ProcessStartTicks'] -is [string] -and $Values['ProcessStartTicks'] -match '^[0-9]{1,20}$') { $Lock.ProcessStartTicks = $Values['ProcessStartTicks'] }
    $Lock.Valid = $true
    return $Lock
}

# The text of a lock file (one function, so a failed read can be tested).
function Read-RunLockText
{
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

# The message of an error, without the 'Exception calling "Move" with "2"
# argument(s):' text PowerShell puts around an error from a .NET method.
function Get-RunLockErrorText
{
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    $Exception = $ErrorRecord.Exception
    if ($Exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $Exception.InnerException) { return $Exception.InnerException.Message }
    return $Exception.Message
}

# This machine's full host name. On Linux and macOS [Environment]::MachineName
# is the host name cut at the first dot, so build.east.example and
# build.west.example would both be 'build'. Host names are compared without
# regard to case (Test-RunLockThisMachine).
function Get-RunLockHostName
{
    $Name = $null
    try { $Name = [System.Net.Dns]::GetHostName() }
    catch { Write-Verbose ('Host name not readable: {0}' -f $_.Exception.Message) }
    if ([string]::IsNullOrWhiteSpace($Name)) { return [Environment]::MachineName }
    return $Name
}

function Test-RunLockThisMachine
{
    param([string]$Name)
    return [string]::Equals($Name, (Get-RunLockHostName), [System.StringComparison]::OrdinalIgnoreCase)
}

# The id of the current boot of this machine (Linux; $null elsewhere or when it
# cannot be read). A process recorded under another boot id is from before a
# restart.
function Get-RunLockBootId
{
    if (-not $IsLinux) { return $null }
    try { $Id = [System.IO.File]::ReadAllText('/proc/sys/kernel/random/boot_id').Trim() }
    catch { return $null }
    if ($Id -match '^[0-9a-f-]{36}$') { return $Id }
    return $null
}

# When this machine started (UTC; Linux, from 'btime' in /proc/stat; $null
# elsewhere or when it cannot be read).
function Get-RunLockBootTime
{
    if (-not $IsLinux) { return $null }
    try { $Lines = [System.IO.File]::ReadAllLines('/proc/stat') }
    catch { return $null }
    foreach ($Line in $Lines)
    {
        $Seconds = [long]0
        if ($Line.StartsWith('btime ') -and [long]::TryParse($Line.Substring(6).Trim(), [System.Globalization.NumberStyles]::None, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Seconds)) { return [DateTimeOffset]::FromUnixTimeSeconds($Seconds).UtcDateTime }
    }
    return $null
}

# When a process started, in clock ticks since boot, and its state (Linux;
# $null elsewhere or when it cannot be read). On Linux .NET works out
# Process.StartTime from the current wall clock, so a clock step (time
# synchronisation, a virtual machine paused or resumed) moves it; the ticks
# since boot do not move. They are field 22 of /proc/<id>/stat. The command
# name (field 2) is in parentheses and can hold spaces and parentheses, so the
# fields are counted from the last ')'.
function Get-RunLockLinuxStart
{
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    if (-not $IsLinux) { return $null }
    try { $Text = [System.IO.File]::ReadAllText(('/proc/{0}/stat' -f $ProcessId)) }
    catch { return $null }
    $End = $Text.LastIndexOf(')')
    if ($End -lt 0) { return $null }
    $Fields = $Text.Substring($End + 1).Trim().Split(' ')
    # $Fields[0] is field 3 (the state), so field 22 is $Fields[19].
    if ($Fields.Count -lt 20) { return $null }
    $Ticks = [long]0
    if (-not [long]::TryParse($Fields[19], [System.Globalization.NumberStyles]::None, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Ticks)) { return $null }
    return [pscustomobject]@{ State = $Fields[0]; Ticks = [string]$Ticks }
}

# Whether a process with this id is running on this machine and, when they can
# be read, when it started (UTC; $null when it cannot be read) and, on Linux,
# its start in clock ticks since boot (StartTicks). A process that has ended
# but whose parent has not yet collected it (state Z) is not running.
function Get-RunLockProcess
{
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    try
    {
        $Process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
    }
    catch
    {
        return [pscustomobject]@{ Running = $false; StartTimeUtc = $null; StartTicks = $null }
    }
    try
    {
        $StartTimeUtc = $null
        try { $StartTimeUtc = $Process.StartTime.ToUniversalTime() }
        catch { Write-Verbose ('Start time of process {0} not readable: {1}' -f $ProcessId, $_.Exception.Message) }
        $Exited = $false
        try { $Exited = $Process.HasExited }
        catch { Write-Verbose ('Exit state of process {0} not readable: {1}' -f $ProcessId, $_.Exception.Message) }
        $Linux = Get-RunLockLinuxStart -ProcessId $ProcessId
        if ($null -ne $Linux -and $Linux.State -eq 'Z') { $Exited = $true }
        return [pscustomobject]@{ Running = (-not $Exited); StartTimeUtc = $StartTimeUtc; StartTicks = $(if ($null -ne $Linux) { $Linux.Ticks } else { $null }) }
    }
    finally
    {
        $Process.Dispose()
    }
}

# ---- Runs of the wrapper in this process ----
# Every run that holds a lock is listed, by its run id, in one table for the
# whole process (kept in the process's AppDomain data, so every runspace sees
# the same table). Each entry is the run's lock state (a synchronized
# hashtable, New-RunLockState): Path, Identity (the values that make the lock
# this run's), InvocationId, Runspace, Pipeline (the command the run's
# runspace was running when the run took the lock), Stopped (no more
# heartbeats), Released (this run no longer touches the file) and Warned.

function Get-RunLockRegistry
{
    $Domain = [System.AppDomain]::CurrentDomain
    [System.Threading.Monitor]::Enter($Domain)
    try
    {
        $Registry = $Domain.GetData('RdaRunLock.Runs.V3')
        if ($null -eq $Registry)
        {
            $Registry = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
            $Domain.SetData('RdaRunLock.Runs.V3', $Registry)
        }
    }
    finally
    {
        [System.Threading.Monitor]::Exit($Domain)
    }
    return , $Registry
}

# The command the calling runspace is running now ($null when it cannot be
# read). PowerShell has no public way to see from another thread whether a
# runspace is still running a given command: its RunspaceAvailability reads
# Available while a 'pwsh -File' script is still running (measured). So this
# reads the runspace's own record of its running command, a non-public
# method, here only. When it cannot be read, the heartbeat keeps going and the
# lock is removed when the session is closed (see Get-RunLockInvocationState).
function Get-RunLockCurrentPipeline
{
    try
    {
        $Method = [System.Management.Automation.Runspaces.Runspace].GetMethod('GetCurrentlyRunningPipeline', [System.Reflection.BindingFlags]'NonPublic, Instance')
        if ($null -eq $Method) { return $null }
        return $Method.Invoke([System.Management.Automation.Runspaces.Runspace]::DefaultRunspace, @())
    }
    catch
    {
        return $null
    }
}

# Whether the run behind a lock state is still going: Running, Ended (its
# runspace is closed, or the command that started it has finished, stopped or
# failed, its clean-up included) or Unknown (that command cannot be read).
# Self-contained, because the heartbeat runspace runs it too.
function Get-RunLockInvocationState
{
    param([Parameter(Mandatory = $true)]$State)
    $Runspace = $State['Runspace']
    if ($null -eq $Runspace -or $Runspace.RunspaceStateInfo.State -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened) { return 'Ended' }
    $Pipeline = $State['Pipeline']
    if ($null -eq $Pipeline) { return 'Unknown' }
    $PipelineState = [string]$Pipeline.PipelineStateInfo.State
    if ($PipelineState -eq 'Completed' -or $PipelineState -eq 'Failed' -or $PipelineState -eq 'Stopped') { return 'Ended' }
    return 'Running'
}

# Lists a run in the process's table (Request-RunLock does this before the
# lock file can appear). An earlier run of the same runspace is left as it
# is: its own heartbeat removes its lock once the command that started it has
# ended, and its release at process exit when the process ends. Only the run
# that created a lock removes it.
function Register-RunLockInvocation
{
    param([Parameter(Mandatory = $true)]$State)
    $null = (Get-RunLockRegistry).TryAdd([string]$State['InvocationId'], $State)
}

function Unregister-RunLockInvocation
{
    param([Parameter(Mandatory = $true)]$State)
    $Registry = Get-RunLockRegistry
    $Removed = $null
    $null = $Registry.TryRemove([string]$State['InvocationId'], [ref]$Removed)
    $ExitRelease = 'RdaRunLock.ExitReleaseV3' -as [type]
    if ($null -ne $ExitRelease) { $ExitRelease::Remove($State) }
}

# Who holds an existing lock (from Read-RunLock), only to choose what the stop
# message says (Write-RunLockHeldMessage); no run acts on it. Returns Kind,
# Why, AgeSeconds (how long ago the heartbeat was refreshed; $null for a lock
# that is not valid). Kind is one of:
#   Running      this machine, and the process that wrote the lock is running
#                (Why: ThisSession when it is this process: a run of this
#                PowerShell session always counts as still going);
#   Ended        this machine, and that process is not running (Why:
#                ProcessGone, ProcessIdReused, Restarted);
#   Unknown      this machine, a process with that id is running, but whether
#                it is the one that wrote the lock cannot be told (Why:
#                StartUnreadable, or StartTimeDiffers on Linux for a lock
#                without the boot id and start ticks, where a clock step
#                also moves the start time);
#   OtherMachine another full host name, or this host name with another boot
#                id and a refresh after this machine started (Why: OtherBoot),
#                which is another machine with the same name, not a restart;
#   Unreadable   the lock cannot be read or holds values that are not valid.
# On Linux the process is told by the boot id and the start in clock ticks
# since boot, which a clock step does not move; elsewhere, and for a lock
# written without them, by the start time, to within one second.
function Get-RunLockHolder
{
    param([Parameter(Mandatory = $true)]$Lock)
    if (-not $Lock.Valid) { return [pscustomobject]@{ Kind = 'Unreadable'; Why = $null; AgeSeconds = $null } }
    $Age = [int][math]::Floor([math]::Max(0, ([datetime]::UtcNow - $Lock.HeartbeatUtc).TotalSeconds))
    $Holder = [pscustomobject]@{ Kind = 'Running'; Why = $null; AgeSeconds = $Age }
    if (-not (Test-RunLockThisMachine -Name $Lock.MachineName)) { $Holder.Kind = 'OtherMachine'; return $Holder }
    $BootId = $null
    if ($null -ne $Lock.BootId -and $null -ne $Lock.ProcessStartTicks) { $BootId = Get-RunLockBootId }
    if ($null -ne $BootId -and $BootId -ne $Lock.BootId)
    {
        # A restart only when the lock was last refreshed before this boot.
        $BootTime = Get-RunLockBootTime
        if ($null -ne $BootTime -and $Lock.HeartbeatUtc -lt $BootTime) { $Holder.Kind = 'Ended'; $Holder.Why = 'Restarted' }
        else { $Holder.Kind = 'OtherMachine'; $Holder.Why = 'OtherBoot' }
        return $Holder
    }
    $Process = Get-RunLockProcess -ProcessId $Lock.ProcessId
    if (-not $Process.Running) { $Holder.Kind = 'Ended'; $Holder.Why = 'ProcessGone'; return $Holder }
    if ($null -ne $BootId)
    {
        if ($null -eq $Process.StartTicks) { $Holder.Kind = 'Unknown'; $Holder.Why = 'StartUnreadable'; return $Holder }
        if ($Process.StartTicks -cne $Lock.ProcessStartTicks) { $Holder.Kind = 'Ended'; $Holder.Why = 'ProcessIdReused'; return $Holder }
    }
    elseif ($null -eq $Process.StartTimeUtc) { $Holder.Kind = 'Unknown'; $Holder.Why = 'StartUnreadable'; return $Holder }
    elseif ([math]::Abs(($Process.StartTimeUtc - $Lock.ProcessStartTimeUtc).TotalSeconds) -gt 1)
    {
        # Another process reads a process's start time to within a fraction of
        # a millisecond of what the process reads for itself.
        if ($IsLinux) { $Holder.Kind = 'Unknown'; $Holder.Why = 'StartTimeDiffers' }
        else { $Holder.Kind = 'Ended'; $Holder.Why = 'ProcessIdReused' }
        return $Holder
    }
    if ($Lock.ProcessId -eq $PID)
    {
        # A run of this PowerShell session always counts as still going: its
        # lock is removed when its command ends (its heartbeat) or when the
        # session is closed (its release at process exit).
        $Holder.Why = 'ThisSession'
    }
    return $Holder
}

# The record this run writes into its lock (all values as written).
function New-RunLockRecord
{
    param(
        [Parameter(Mandatory = $true)][datetime]$RunStartTime,
        [Parameter(Mandatory = $true)][string]$InvocationId
    )
    $Self = [System.Diagnostics.Process]::GetCurrentProcess()
    try { $SelfStart = $Self.StartTime.ToUniversalTime() }
    finally { $Self.Dispose() }
    $Record = [ordered]@{
        MachineName         = (Get-RunLockHostName)
        ProcessId           = $PID
        ProcessStartTimeUtc = $SelfStart.ToString('o')
        RunStartTimeUtc     = $RunStartTime.ToUniversalTime().ToString('o')
        HeartbeatUtc        = [datetime]::UtcNow.ToString('o')
        InvocationId        = $InvocationId
        RunspaceId          = [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.Id
    }
    # Linux: which process this is, in a form a clock step does not move.
    $BootId = Get-RunLockBootId
    $Start = Get-RunLockLinuxStart -ProcessId $PID
    if ($null -ne $BootId -and $null -ne $Start)
    {
        $Record['BootId'] = $BootId
        $Record['ProcessStartTicks'] = $Start.Ticks
    }
    return $Record
}

# Whether the lock file at Path is still this run's: the same machine name,
# process id, process start time and run id as Record (the lock record, or a
# state's Identity). Returns State (Ours, Other, Missing or Unreadable: the
# file could not be read now) and Holder (who holds it, or why it cannot be
# read). A file that is not a valid lock is not this run's. Self-contained,
# because the heartbeat runspace runs it too.
function Test-RunLockOwner
{
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Record
    )
    try
    {
        $Text = [System.IO.File]::ReadAllText($Path)
    }
    catch [System.IO.FileNotFoundException]
    {
        return [pscustomobject]@{ State = 'Missing'; Holder = $null }
    }
    catch
    {
        $Problem = if ($null -ne $_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        return [pscustomobject]@{ State = 'Unreadable'; Holder = $Problem }
    }
    $Values = @{}
    try
    {
        $Document = [System.Text.Json.JsonDocument]::Parse($Text)
        try
        {
            foreach ($Property in $Document.RootElement.EnumerateObject()) { $Values[$Property.Name] = $Property.Value.ToString() }
        }
        finally
        {
            $Document.Dispose()
        }
    }
    catch
    {
        return [pscustomobject]@{ State = 'Other'; Holder = 'a file that is not a valid run lock' }
    }
    foreach ($Name in 'MachineName', 'ProcessId', 'ProcessStartTimeUtc', 'InvocationId')
    {
        if ([string]$Values[$Name] -cne [string]$Record[$Name])
        {
            $Holder = if ([string]$Values['ProcessId'] -eq [string]$PID -and [string]::Equals([string]$Values['MachineName'], [string]$Record['MachineName'], [System.StringComparison]::OrdinalIgnoreCase)) { 'another run in this process' } else { 'process {0} on {1}' -f $Values['ProcessId'], $Values['MachineName'] }
            return [pscustomobject]@{ State = 'Other'; Holder = $Holder }
        }
    }
    return [pscustomobject]@{ State = 'Ours'; Holder = $null }
}

# Rewrites (NewText) or removes (-Remove) this run's lock file, only while it
# is still this run's (Test-RunLockOwner). Once it is not (another lock is in
# its place, or it is gone), Released is set and this run never writes or
# removes that file again. The heartbeat, the release and the release at
# process exit of one run take the state's own lock (its SyncRoot) first, so
# they never interleave. A rewrite goes through a temporary file written to
# disk and a rename, so a reader never sees a half-written lock. Returns
# Outcome (Written, Removed, Released (this run no longer touches the file),
# Missing, Other, Busy (another part of this run held the state for
# TimeoutSeconds) or Failed), Holder (for Other) and Problem. Self-contained,
# because the heartbeat runspace runs it too.
function Invoke-RunLockFileChange
{
    param(
        [Parameter(Mandatory = $true)]$State,
        [string]$NewText,
        [switch]$Remove,
        [int]$TimeoutSeconds = 10
    )
    $Gate = $State.SyncRoot
    $Held = $false
    try
    {
        $Held = [System.Threading.Monitor]::TryEnter($Gate, [TimeSpan]::FromSeconds($TimeoutSeconds))
        if (-not $Held) { return [pscustomobject]@{ Outcome = 'Busy'; Holder = $null; Problem = ('another part of this run held the run lock state for {0} seconds' -f $TimeoutSeconds) } }
        if ($State['Released']) { return [pscustomobject]@{ Outcome = 'Released'; Holder = $null; Problem = $null } }
        $Path = [string]$State['Path']
        $Owner = Test-RunLockOwner -Path $Path -Record $State['Identity']
        if ($Owner.State -eq 'Unreadable') { return [pscustomobject]@{ Outcome = 'Failed'; Holder = $null; Problem = $Owner.Holder } }
        if ($Owner.State -eq 'Missing' -or $Owner.State -eq 'Other')
        {
            $State['Released'] = $true
            return [pscustomobject]@{ Outcome = $Owner.State; Holder = $Owner.Holder; Problem = $null }
        }
        if ($Remove)
        {
            [System.IO.File]::Delete($Path)
            $State['Released'] = $true
            return [pscustomobject]@{ Outcome = 'Removed'; Holder = $null; Problem = $null }
        }
        $Temp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N').Substring(0, 8)
        try
        {
            # Written to disk before the rename, so a crash does not leave an
            # empty lock in its place.
            $TempStream = [System.IO.File]::Open($Temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try
            {
                $TempBytes = [System.Text.Encoding]::UTF8.GetBytes($NewText)
                $TempStream.Write($TempBytes, 0, $TempBytes.Length)
                $TempStream.Flush($true)
            }
            finally
            {
                $TempStream.Dispose()
            }
            [System.IO.File]::Move($Temp, $Path, $true)
        }
        catch
        {
            try { if ([System.IO.File]::Exists($Temp)) { [System.IO.File]::Delete($Temp) } }
            catch { Write-Verbose ('Could not remove {0}: {1}' -f $Temp, $_.Exception.Message) }
            throw
        }
        return [pscustomobject]@{ Outcome = 'Written'; Holder = $null; Problem = $null }
    }
    catch
    {
        $Problem = if ($_.Exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        return [pscustomobject]@{ Outcome = 'Failed'; Holder = $null; Problem = $Problem }
    }
    finally
    {
        if ($Held) { [System.Threading.Monitor]::Exit($Gate) }
    }
}

# Removes this run's lock when the process exits, if a run of the wrapper still
# holds it then: a 'pwsh -File' run that was interrupted (Ctrl+C) or ended
# with an error ends its process right after its clean-up, before the
# heartbeat may see it. Compiled, because a process-exit handler runs on a
# thread with no PowerShell runspace. Same checks as Invoke-RunLockFileChange.
$script:RunLockTypeSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Threading;

namespace RdaRunLock
{
    public static class ExitReleaseV3
    {
        private static readonly object Gate = new object();
        private static readonly List<Hashtable> States = new List<Hashtable>();
        private static bool hooked;

        public static void Add(Hashtable state)
        {
            lock (Gate)
            {
                if (!States.Contains(state)) { States.Add(state); }
                if (!hooked)
                {
                    AppDomain.CurrentDomain.ProcessExit += OnExit;
                    hooked = true;
                }
            }
        }

        public static void Remove(Hashtable state)
        {
            lock (Gate) { States.Remove(state); }
        }

        private static void OnExit(object sender, EventArgs e)
        {
            Hashtable[] all;
            lock (Gate) { all = States.ToArray(); }
            foreach (Hashtable state in all)
            {
                try { Release(state); } catch (Exception) { }
            }
        }

        private static void Release(Hashtable state)
        {
            object gate = state.SyncRoot;
            if (!Monitor.TryEnter(gate, TimeSpan.FromSeconds(5))) { return; }
            try
            {
                if (true.Equals(state["Released"])) { return; }
                string path = Convert.ToString(state["Path"], CultureInfo.InvariantCulture);
                string text;
                try { text = File.ReadAllText(path); }
                catch (IOException) { return; }
                catch (UnauthorizedAccessException) { return; }
                if (IsOwn(text, state["Identity"] as Hashtable))
                {
                    File.Delete(path);
                    state["Released"] = true;
                }
            }
            finally
            {
                Monitor.Exit(gate);
            }
        }

        private static bool IsOwn(string text, Hashtable identity)
        {
            if (identity == null) { return false; }
            try
            {
                using (JsonDocument document = JsonDocument.Parse(text))
                {
                    if (document.RootElement.ValueKind != JsonValueKind.Object) { return false; }
                    foreach (string name in new[] { "MachineName", "ProcessId", "ProcessStartTimeUtc", "InvocationId" })
                    {
                        JsonElement value;
                        if (!document.RootElement.TryGetProperty(name, out value)) { return false; }
                        if (!string.Equals(value.ToString(), Convert.ToString(identity[name], CultureInfo.InvariantCulture), StringComparison.Ordinal)) { return false; }
                    }
                    return true;
                }
            }
            catch (JsonException)
            {
                return false;
            }
        }
    }
}
'@

# The state of a lock this run has just taken (see Get-RunLockRegistry): the
# values that make the lock this run's, and the runspace and the command that
# took it.
function New-RunLockState
{
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Record
    )
    $Identity = @{}
    foreach ($Name in 'MachineName', 'ProcessId', 'ProcessStartTimeUtc', 'InvocationId') { $Identity[$Name] = [string]$Record[$Name] }
    return [hashtable]::Synchronized(@{
            Path         = $Path
            Identity     = $Identity
            InvocationId = [string]$Record['InvocationId']
            Runspace     = [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace
            Pipeline     = (Get-RunLockCurrentPipeline)
            Stopped      = $false
            Released     = $false
            Warned       = $false
            Beating      = $false
        })
}

# The runspace the heartbeat runs in.
function New-RunLockHeartbeatRunspace
{
    $Runspace = [runspacefactory]::CreateRunspace($Host)
    $Runspace.Open()
    return $Runspace
}

# Starts the background runspace that rewrites the heartbeat every
# IntervalSeconds and, once the command that started the run has finished (its
# clean-up included), releases the lock and stops. That covers a run ended by
# an error or by Ctrl+C in an interactive session, where the process goes on
# (Cloud Shell runs every command in one pwsh process). In 'pwsh -File' the
# process exits right after the run, so the lock is also released at process
# exit. A runspace of its own rather than Start-ThreadJob: thread jobs share
# one limit of five running jobs per process, and on a sequential run the
# metrics phase (Extension/Metrics.ps1) runs its calls as thread jobs in this
# process, so a heartbeat thread job would hold one of those five for the
# whole run. Returns $false, after one ERROR line, when the heartbeat cannot
# start: without it the lock would not be released when the command ends in a
# session that goes on, so the caller stops before reading or writing any run
# state. The release at process exit needs a compiled handler; when that
# cannot be set up, one warning says so and the run goes on.
function Start-RunLockHeartbeat
{
    param(
        [Parameter(Mandatory = $true)]$Lock,
        [int]$IntervalSeconds = 60
    )
    # Request-RunLock listed the run when it took the lock; the heartbeat
    # attaches to that entry.
    $State = $Lock.State
    if ($null -eq $State)
    {
        $State = New-RunLockState -Path $Lock.Path -Record $Lock.Record
        $Lock.State = $State
        Register-RunLockInvocation -State $State
    }
    try
    {
        $Runspace = New-RunLockHeartbeatRunspace
        $PowerShell = [powershell]::Create()
        $PowerShell.Runspace = $Runspace
        $Loop = {
            param($State, $Record, $IntervalSeconds, $Functions)
            foreach ($Name in $Functions.Keys) { Set-Item -Path ('Function:{0}' -f $Name) -Value ([scriptblock]::Create($Functions[$Name])) }
            $Warned = $false
            $Due = [datetime]::UtcNow.AddSeconds($IntervalSeconds)
            while (-not $State['Stopped'] -and -not $State['Released'])
            {
                Start-Sleep -Milliseconds 250
                if ((Get-RunLockInvocationState -State $State) -eq 'Ended')
                {
                    $null = Invoke-RunLockFileChange -State $State -Remove
                    $State['Stopped'] = $true
                    Unregister-RunLockInvocation -State $State
                    break
                }
                if ([datetime]::UtcNow -lt $Due) { continue }
                $Due = [datetime]::UtcNow.AddSeconds($IntervalSeconds)
                $Copy = [ordered]@{}
                foreach ($Key in $Record.Keys) { $Copy[$Key] = $Record[$Key] }
                $Copy['HeartbeatUtc'] = [datetime]::UtcNow.ToString('o')
                $Change = Invoke-RunLockFileChange -State $State -NewText ($Copy | ConvertTo-Json -Compress)
                if ($Change.Outcome -eq 'Failed' -or $Change.Outcome -eq 'Busy')
                {
                    if (-not $Warned)
                    {
                        Write-Host ('WARNING: Could not refresh the run lock {0}: {1}. The run goes on; the lock shows the time of its last refresh.' -f $State['Path'], $Change.Problem) -ForegroundColor Yellow
                        $Warned = $true
                    }
                    continue
                }
                if ($Change.Outcome -eq 'Other' -or $Change.Outcome -eq 'Missing')
                {
                    $Why = if ($Change.Outcome -eq 'Missing') { 'it was removed' } else { 'it is now held by {0}' -f $Change.Holder }
                    Write-Host ('WARNING: This run no longer refreshes or removes the run lock {0}: {1}. The run goes on.' -f $State['Path'], $Why) -ForegroundColor Yellow
                    $State['Warned'] = $true
                    $State['Stopped'] = $true
                    break
                }
            }
        }
        $Functions = @{}
        foreach ($Name in 'Get-RunLockInvocationState', 'Invoke-RunLockFileChange', 'Test-RunLockOwner', 'Get-RunLockRegistry', 'Unregister-RunLockInvocation')
        {
            $Functions[$Name] = (Get-Command -Name $Name -CommandType Function).ScriptBlock.ToString()
        }
        $null = $PowerShell.AddScript($Loop.ToString()).AddArgument($State).AddArgument($Lock.Record).AddArgument($IntervalSeconds).AddArgument($Functions)
        $Lock.Heartbeat = [pscustomobject]@{ PowerShell = $PowerShell; Runspace = $Runspace; Handle = $PowerShell.BeginInvoke() }
        $State['Beating'] = $true
    }
    catch
    {
        Write-Host ''
        Write-Host ('ERROR: Could not start the heartbeat of the run lock {0}: {1}' -f $Lock.Path, (Get-RunLockErrorText -ErrorRecord $_)) -ForegroundColor Red
        Write-Host '  Without it, this run''s lock would not be refreshed, and would not be removed if the run ended with an error in a session that goes on, so this run stopped before reading or writing any run state.' -ForegroundColor Red
        # Release the new lock and take the run off the list now.
        Remove-RunLock -Lock $Lock
        return $false
    }
    try
    {
        # A run in another runspace of this process may compile it at the same
        # moment; the type it compiled serves this run too.
        try { if (-not ('RdaRunLock.ExitReleaseV3' -as [type])) { Add-Type -TypeDefinition $script:RunLockTypeSource -ErrorAction Stop } }
        catch { if (-not ('RdaRunLock.ExitReleaseV3' -as [type])) { throw } }
        ('RdaRunLock.ExitReleaseV3' -as [type])::Add($State)
    }
    catch
    {
        Write-Host ('WARNING: Could not set up the release of the run lock {0} at process exit: {1}. The run goes on; if it is interrupted or ends with an error, its lock stays and the next run stops with the command to remove it.' -f $Lock.Path, (Get-RunLockErrorText -ErrorRecord $_)) -ForegroundColor Yellow
    }
    return $true
}

function Stop-RunLockHeartbeat
{
    param([Parameter(Mandatory = $true)]$Lock)
    if ($null -ne $Lock.State) { $Lock.State['Stopped'] = $true }
    if ($null -eq $Lock.Heartbeat) { return }
    try
    {
        $Lock.Heartbeat.PowerShell.Stop()
        $Lock.Heartbeat.PowerShell.Dispose()
        $Lock.Heartbeat.Runspace.Dispose()
    }
    catch
    {
        Write-Verbose ('Stopping the run lock heartbeat failed: {0}' -f $_.Exception.Message)
    }
    $Lock.Heartbeat = $null
}

# How long ago a time was, for the messages: seconds under 2 minutes, minutes
# under 2 hours, hours under 2 days, then days.
function Format-RunLockAge
{
    param([Parameter(Mandatory = $true)][int]$Seconds)
    if ($Seconds -lt 120) { return ('{0} seconds' -f $Seconds) }
    if ($Seconds -lt 7200) { return ('{0} minutes' -f [int][math]::Floor($Seconds / 60)) }
    if ($Seconds -lt 172800) { return ('{0} hours' -f [int][math]::Floor($Seconds / 3600)) }
    return ('{0} days' -f [int][math]::Floor($Seconds / 86400))
}

# Removes, with one line each, the temporary files '<lock>.<8 hex>.tmp' that a
# run leaves next to the lock when it is killed while it refreshes its lock
# (Invoke-RunLockFileChange). Called right after this run created the lock:
# only the run that holds the lock writes them, so one that is there now was
# left by an earlier run.
function Remove-RunLockTemp
{
    param([Parameter(Mandatory = $true)][string]$Path)
    $Folder = Split-Path -Path $Path -Parent
    $Leaf = Split-Path -Path $Path -Leaf
    $Pattern = '^{0}\.[0-9a-f]{{8}}\.tmp$' -f [regex]::Escape($Leaf)
    try
    {
        $Files = @([System.IO.Directory]::EnumerateFiles($Folder, ($Leaf + '.*.tmp')) | Where-Object { [System.IO.Path]::GetFileName($_) -match $Pattern } | Sort-Object)
    }
    catch
    {
        Write-Verbose ('Could not list {0}: {1}' -f $Folder, (Get-RunLockErrorText -ErrorRecord $_))
        return
    }
    foreach ($File in $Files)
    {
        try
        {
            [System.IO.File]::Delete($File)
            Write-Host ('Removed {0}: a run left it when it was stopped while it refreshed its run lock.' -f $File) -ForegroundColor Yellow
        }
        catch
        {
            Write-Host ('WARNING: Could not remove {0}, left by a run that was stopped while it refreshed its run lock: {1}' -f $File, (Get-RunLockErrorText -ErrorRecord $_)) -ForegroundColor Yellow
        }
    }
}

# Takes the lock for this run. The run is listed in the process's table first
# (Register-RunLockInvocation), so a run in another runspace of this process
# that reads the new lock finds it listed, and it is taken off the list again
# when the request ends without the lock. The file is created only if it is
# absent, so of two runs that start together exactly one gets it, and it is
# written to disk before the run goes on. A lock that is there already is never
# replaced or removed: the run does not get the lock, and Held (the lock as
# read) and Holder (Get-RunLockHolder) say who holds it. When the lock is gone
# again by the time it is read (its run released it in between), the run tries
# to create it again, at most MaxAttempts times in all. When it is the lock of
# a run of this PowerShell session, the run waits up to
# SessionWaitMilliseconds, once, for it to go (a command that ended an instant
# ago is released by its heartbeat within a quarter of a second), then tries
# to create it again; a lock still there is that of a run still going. Returns Acquired, Path,
# Record, Text (the lock as written), State and Heartbeat (set by
# Start-RunLockHeartbeat), Held, Holder and Problem (why the lock could not be
# created, when there is no lock to name).
function Request-RunLock
{
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][datetime]$RunStartTime,
        [int]$MaxAttempts = 3,
        [int]$SessionWaitMilliseconds = 1000
    )
    $Result = [pscustomobject]@{ Acquired = $false; Path = $Path; Record = $null; Text = $null; State = $null; Heartbeat = $null; Held = $null; Holder = $null; Problem = $null }
    $InvocationId = [guid]::NewGuid().ToString()
    $State = New-RunLockState -Path $Path -Record (New-RunLockRecord -RunStartTime $RunStartTime -InvocationId $InvocationId)
    $null = (Get-RunLockRegistry).TryAdd($InvocationId, $State)
    try
    {
        return (Request-RunLockListed -Result $Result -State $State -RunStartTime $RunStartTime -InvocationId $InvocationId -MaxAttempts $MaxAttempts -SessionWaitMilliseconds $SessionWaitMilliseconds)
    }
    finally
    {
        if (-not $Result.Acquired) { Unregister-RunLockInvocation -State $State }
    }
}

# The attempts of Request-RunLock, made while this run is listed.
function Request-RunLockListed
{
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][datetime]$RunStartTime,
        [Parameter(Mandatory = $true)][string]$InvocationId,
        [int]$MaxAttempts = 3,
        [int]$SessionWaitMilliseconds = 1000
    )
    $Path = $Result.Path
    $Waited = $false
    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
    {
        $Record = New-RunLockRecord -RunStartTime $RunStartTime -InvocationId $InvocationId
        $Text = $Record | ConvertTo-Json -Compress
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $Stream = $null
        try
        {
            $Stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        }
        catch
        {
            $Result.Problem = Get-RunLockErrorText -ErrorRecord $_
        }
        if ($null -ne $Stream)
        {
            try
            {
                $Stream.Write($Bytes, 0, $Bytes.Length)
                # On disk before the run goes on, so a crash does not leave an
                # empty lock.
                $Stream.Flush($true)
                $Stream.Dispose()
            }
            catch
            {
                # Created but not written (for example a full disk): remove the
                # empty file so later runs do not stop on it.
                $Result.Problem = Get-RunLockErrorText -ErrorRecord $_
                $Stream.Dispose()
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                continue
            }
            $Result.State = $State
            Register-RunLockInvocation -State $State
            Remove-RunLockTemp -Path $Path
            $Result.Acquired = $true
            $Result.Record = $Record
            $Result.Text = $Text
            $Result.Held = $null
            $Result.Holder = $null
            $Result.Problem = $null
            return $Result
        }
        $Held = Read-RunLock -Path $Path
        # Gone already: its run released it in between (or the file could not
        # be created for another reason, kept in Problem). Try again.
        if (-not $Held.Exists) { continue }
        $Result.Held = $Held
        $Result.Holder = Get-RunLockHolder -Lock $Held
        $Result.Problem = $null
        if ($Result.Holder.Why -eq 'ThisSession' -and -not $Waited -and $Attempt -lt $MaxAttempts)
        {
            # Only that run removes it; nothing is taken over.
            $Waited = $true
            $Clock = [System.Diagnostics.Stopwatch]::StartNew()
            while ([System.IO.File]::Exists($Path) -and $Clock.ElapsedMilliseconds -lt $SessionWaitMilliseconds) { Start-Sleep -Milliseconds 25 }
            continue
        }
        return $Result
    }
    return $Result
}

# What a run that did not get the lock prints before it stops with exit 1:
# who holds the lock (host name, process id and start, the last refresh and
# how long ago), then one of four things by what Get-RunLockHolder found:
# the process is running on this machine (wait for it or stop it; no remove
# command, since removing a live lock would give two holders); it is not
# running (the remove command); another machine, or this machine but the
# process cannot be told apart (how to check, and the remove command for once
# no run is using the folder); the lock cannot be read (the remove command,
# with the same check first). When there was no lock to name, the reason the
# lock could not be created.
function Write-RunLockHeldMessage
{
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$Tenant
    )
    $Held = $Request.Held
    $Holder = $Request.Holder
    $Remove = "    Remove-Item -LiteralPath '{0}' -Force" -f ($Request.Path -replace "'", "''")
    $Stopped = 'so this run stopped before reading or writing any run state.'
    Write-Host ''
    if ($null -eq $Held -or $null -eq $Holder)
    {
        Write-Host ('ERROR: Could not create the run lock for tenant {0}, {1}' -f $Tenant, $Stopped) -ForegroundColor Red
        Write-Host ('  Lock file: {0}' -f $Request.Path) -ForegroundColor Red
        Write-Host ('  Reason:    {0}' -f $Request.Problem) -ForegroundColor Red
        return
    }
    if ($Holder.Kind -eq 'Unreadable')
    {
        Write-Host ('ERROR: The run lock for tenant {0} cannot be read ({1}), {2}' -f $Tenant, $Held.Problem, $Stopped) -ForegroundColor Red
        Write-Host ('  Lock file:    {0}' -f $Request.Path) -ForegroundColor Red
        if ($null -ne $Held.FileWriteTimeUtc) { Write-Host ('  Last written: {0} ({1} ago)' -f (Format-RunLockTime -Value $Held.FileWriteTimeUtc), (Format-RunLockAge -Seconds ([int][math]::Floor([math]::Max(0, ([datetime]::UtcNow - $Held.FileWriteTimeUtc).TotalSeconds))))) -ForegroundColor Red }
        Write-Host '  It was read again for about 2 seconds. Which machine and process hold it is not known; it may have been left by a run that stopped while it was writing it.' -ForegroundColor Yellow
        Write-Host '  Check that no run for this tenant is going on any machine that uses this folder. Then remove the lock and run this command again:' -ForegroundColor Yellow
        Write-Host $Remove -ForegroundColor Yellow
        return
    }
    $Started = Format-RunLockTime -Value $Held.ProcessStartTimeUtc
    Write-Host ('ERROR: Another run for tenant {0} holds the lock on this inventory folder, {1}' -f $Tenant, $Stopped) -ForegroundColor Red
    Write-Host ('  Lock file:    {0}' -f $Request.Path) -ForegroundColor Red
    Write-Host ('  Held by:      process {0} on {1}, started {2}; its run started {3}' -f $Held.ProcessId, $Held.MachineName, $Started, (Format-RunLockTime -Value $Held.RunStartTimeUtc)) -ForegroundColor Red
    Write-Host ('  Last refresh: {0} ({1} ago)' -f (Format-RunLockTime -Value $Held.HeartbeatUtc), (Format-RunLockAge -Seconds $Holder.AgeSeconds)) -ForegroundColor Red
    $Check = "Get-Process -Id {0} | Select-Object Id, ProcessName, @{{ Name = 'StartTimeUtc'; Expression = {{ `$_.StartTime.ToUniversalTime() }} }}" -f $Held.ProcessId
    switch ($Holder.Kind)
    {
        'Running'
        {
            if ($Holder.Why -eq 'ThisSession')
            {
                Write-Host ('  It is held by a run of this PowerShell session (process {0}), which counts as a run that is still going.' -f $Held.ProcessId) -ForegroundColor Yellow
                Write-Host '  The lock is removed when that command ends, or when this session is closed; then run this command again.' -ForegroundColor Yellow
            }
            else
            {
                Write-Host ('  Process {0} on this machine is still running, so a run is using this folder.' -f $Held.ProcessId) -ForegroundColor Yellow
                Write-Host '  Wait for that run to finish, or stop it, then run this command again.' -ForegroundColor Yellow
            }
        }
        'Ended'
        {
            $Why = switch ($Holder.Why)
            {
                'ProcessIdReused' { 'process {0} on this machine is now another process' -f $Held.ProcessId }
                'Restarted' { 'this machine has restarted since' }
                default { 'process {0} is not running on this machine' -f $Held.ProcessId }
            }
            Write-Host ('  That run is no longer running ({0}). It ended without removing its lock, for example because it was killed or its terminal or Cloud Shell session was closed.' -f $Why) -ForegroundColor Yellow
            Write-Host '  Remove the lock, then run this command again:' -ForegroundColor Yellow
            Write-Host $Remove -ForegroundColor Yellow
        }
        'Unknown'
        {
            $Why = if ($Holder.Why -eq 'StartTimeDiffers') { 'its start time differs from the recorded one, and a change of the clock also moves it' } else { 'its start time cannot be read' }
            Write-Host ('  A process {0} is running on this machine, but whether it is the run that wrote the lock cannot be told ({1}).' -f $Held.ProcessId, $Why) -ForegroundColor Yellow
            Write-Host ('  To check: {0}' -f $Check) -ForegroundColor Yellow
            Write-Host ('  Once you know that no run is using this folder (no process {0} that started at {1} is running), remove the lock, then run this command again:' -f $Held.ProcessId, $Started) -ForegroundColor Yellow
            Write-Host $Remove -ForegroundColor Yellow
        }
        default
        {
            if ($Holder.Why -eq 'OtherBoot') { Write-Host ('  The lock names this host name, {0}, but another start of the machine, and it was refreshed after this machine started: it is from another machine with the same name, so whether that run is still going cannot be checked from here.' -f $Held.MachineName) -ForegroundColor Yellow }
            else { Write-Host ('  The lock is from another machine, {0}, so whether that run is still going cannot be checked from here.' -f $Held.MachineName) -ForegroundColor Yellow }
            Write-Host ('  To check, on {0}: {1}' -f $Held.MachineName, $Check) -ForegroundColor Yellow
            Write-Host ('  Once you know that no run is using this folder (no process {0} that started at {1} is running on {2}), remove the lock, then run this command again:' -f $Held.ProcessId, $Started, $Held.MachineName) -ForegroundColor Yellow
            Write-Host $Remove -ForegroundColor Yellow
        }
    }
}

# Releases this run's lock on its way out: removes the lock file only while it
# is still this run's (Invoke-RunLockFileChange), then stops the heartbeat.
# Safe to call twice. A lock that is no longer this run's is left in place,
# with one warning for the run (none when the heartbeat already gave it).
function Remove-RunLock
{
    param($Lock)
    if ($null -eq $Lock -or -not $Lock.Acquired) { return }
    $Lock.Acquired = $false
    $State = $Lock.State
    if ($null -eq $State)
    {
        # A lock object that Request-RunLock did not make.
        $State = New-RunLockState -Path ([string]$Lock.Path) -Record $Lock.Record
        $State['Stopped'] = $true
    }
    $Change = Invoke-RunLockFileChange -State $State -Remove
    Stop-RunLockHeartbeat -Lock $Lock
    Unregister-RunLockInvocation -State $State
    if ($Change.Outcome -eq 'Other' -and -not $State['Warned'])
    {
        Write-Host ('WARNING: Left the run lock {0} in place: it is now held by {1}.' -f $Lock.Path, $Change.Holder) -ForegroundColor Yellow
        $State['Warned'] = $true
    }
    elseif ($Change.Outcome -eq 'Failed' -or $Change.Outcome -eq 'Busy')
    {
        Write-RunLockNotRemoved -Path $Lock.Path -Reason $Change.Problem
    }
}

function Write-RunLockNotRemoved
{
    param([string]$Path, [string]$Reason)
    Write-Host ('WARNING: The run lock {0} was not removed: {1}' -f $Path, $Reason) -ForegroundColor Yellow
    Write-Host ("  Until it is removed, every run for this tenant in this folder stops with exit 1. To remove it now: Remove-Item -LiteralPath '{0}' -Force" -f ($Path -replace "'", "''")) -ForegroundColor Yellow
}

# ---- Stream worker output + per-stream state --------------------------------

function Write-Stream
{
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ("{0} {1}" -f $Tag, $Message) -ForegroundColor $Color
}

function Read-StreamState
{
    # $RunId: a file of another run (Test-StreamStateRunId) reads as empty.
    param([string]$Path, [string]$RunId)
    if (-not (Test-Path -Path $Path -PathType Leaf)) { return @{ Completed = @(); Failed = @(); Reports = @() } }
    try
    {
        $Obj = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        # The wrapper moves a file that is not the right shape aside before any
        # stream starts; one left in place is not used either, nor one of
        # another run.
        $Problem = Get-ResumeStateShapeProblem -Record $Obj -Kind Stream
        if ($null -ne $Problem) { throw ('it is not the right shape ({0})' -f $Problem) }
        if (-not (Test-StreamStateRunId -State $Obj -RunId $RunId)) { return @{ Completed = @(); Failed = @(); Reports = @() } }
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
    $State = [ordered]@{
        Tenant         = $TenantID
        StreamId       = $StreamId
        # The run this file belongs to (Test-StreamStateRunId).
        RunId          = $RunId
    }
    # The run's record (start time, settings, cost window), as the parent run
    # passed it ($StreamRunRecord), in the same write as the lists, so a run
    # that continues from this file can check them (Read-StreamRunInfo).
    $Record = Get-Variable -Name 'StreamRunRecord' -ValueOnly -ErrorAction SilentlyContinue
    if ($Record -is [System.Management.Automation.PSCustomObject])
    {
        foreach ($Key in @(Get-ResumeRunInfoKeys)) { $P = $Record.PSObject.Properties[$Key]; if ($null -ne $P) { $State[$Key] = $P.Value } }
    }
    $State.Completed = $Completed
    # Remove-FailedAttempt returns nothing once the list is empty, and
    # @($null) is a one-entry array; drop that entry so the file holds only
    # real failure records.
    $State.FailedAttempts = @($FailedAttempts | Where-Object { $_ })
    $State.Reports = @($Reports)
    try
    {
        # Through a sibling temporary file and a replace, as the resume state
        # file is written: a write cut short leaves the earlier file whole.
        $TmpPath = "$Path.tmp"
        $State | ConvertTo-Json -Depth 6 | Set-Content -Path $TmpPath -Encoding utf8 -ErrorAction Stop
        [System.IO.File]::Move($TmpPath, $Path, $true)
    }
    catch
    {
        Write-Stream ("WARNING: failed to persist stream state to {0}: {1}" -f $Path, $_.Exception.Message) 'Yellow'
        Remove-ResumeStateTempPath -Path "$Path.tmp"
    }
}

# ---- Az context snapshot for stream workers ---------------------------------
# Each stream worker signs in by importing its own copy of the wrapper's Az
# context, written by Save-AzContext to the inventory folder just before the
# worker is started. The copy holds a full token cache, including a refresh
# token that can get new access tokens after the ones in the file expire. A
# worker reads its copy once, at start-up, and deletes it straight after; the
# wrapper deletes any copy still there when the streams end. A copy's name
# says which process wrote it, so a later run can delete the copies of a run
# that was killed, and only those.

# The command that removes one file, as printed for the operator.
function Get-RemoveFileCommand
{
    param([Parameter(Mandatory = $true)][string]$Path)
    return ("Remove-Item -LiteralPath '{0}' -Force" -f $Path.Replace("'", "''"))
}

# A path for a new snapshot in the inventory folder. The name holds the owner:
# this machine's name (escaped so it is a valid file name), this process's id
# and start time (UTC), and a random id.
function New-AzContextSnapshotPath
{
    param([Parameter(Mandatory = $true)][string]$InventoryRoot)
    $Self = [System.Diagnostics.Process]::GetCurrentProcess()
    $Started = $Self.StartTime.ToUniversalTime()
    $Stamp = $Started.ToString('yyyyMMddTHHmmssfffZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $Name = '.rda-stream-azcontext-{0}-{1}-{2}-{3}.json' -f [uri]::EscapeDataString([Environment]::MachineName), $PID, $Stamp, [guid]::NewGuid().ToString('N')
    return (Join-Path $InventoryRoot $Name)
}

# The owner recorded in a snapshot's file name: { Valid, MachineName,
# ProcessId, ProcessStartTimeUtc }. Valid is $false for a name in another form
# (such as the random-only names of earlier versions) or with a value that
# cannot be read.
function ConvertFrom-AzContextSnapshotName
{
    param([Parameter(Mandatory = $true)][string]$Name)
    $Owner = [pscustomobject]@{ Valid = $false; MachineName = $null; ProcessId = 0; ProcessStartTimeUtc = $null }
    if ($Name -notmatch '^\.rda-stream-azcontext-(?<Machine>[A-Za-z0-9._~%-]+)-(?<Pid>\d{1,10})-(?<Start>\d{8}T\d{9}Z)-[0-9a-f]{32}\.json$') { return $Owner }
    $Machine = $Matches['Machine']; $PidText = $Matches['Pid']; $StartText = $Matches['Start']
    try { $MachineName = [uri]::UnescapeDataString($Machine) } catch { return $Owner }
    $ProcessId = 0
    if (-not [int]::TryParse($PidText, [ref]$ProcessId) -or $ProcessId -le 0) { return $Owner }
    $Started = [datetime]::MinValue
    $Styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if (-not [datetime]::TryParseExact($StartText, 'yyyyMMddTHHmmssfffZ', [System.Globalization.CultureInfo]::InvariantCulture, $Styles, [ref]$Started)) { return $Owner }
    $Owner.Valid = $true
    $Owner.MachineName = $MachineName
    $Owner.ProcessId = $ProcessId
    $Owner.ProcessStartTimeUtc = $Started
    return $Owner
}

# Whether the process that wrote a snapshot can still use it. Returns one of:
#   ProcessGone, ProcessIdReused - that process has ended, so its runs have
#     too, and the copy can be deleted. The id counts as reused only when the
#     process now holding it started more than ReusedAfter (one hour) after
#     the start time in the name: a process started at another time is
#     usually far apart, while a clock correction can shift the start time
#     one process reads for another (on Linux each .NET process computes it
#     from a boot time it fixes when it starts), so a smaller difference, or
#     a process that seems to have started earlier, keeps the copy;
#   ThisProcess, ProcessRunning, StartTimeUnknown - it may still be in use.
#     ThisProcess is this process itself: PowerShell can run several
#     invocations of the wrapper at once in one process (in runspaces or
#     thread jobs), and the name does not say which of them wrote the copy;
#   OtherMachine, Unreadable - this machine cannot tell.
function Get-AzContextSnapshotOwnerState
{
    param(
        [Parameter(Mandatory = $true)]$Owner,
        [timespan]$ReusedAfter = [timespan]::FromHours(1)
    )
    if (-not $Owner.Valid) { return 'Unreadable' }
    if ($Owner.MachineName -ne [Environment]::MachineName) { return 'OtherMachine' }
    try { $Process = [System.Diagnostics.Process]::GetProcessById($Owner.ProcessId) }
    catch { return 'ProcessGone' }
    try
    {
        $Exited = $false
        try { $Exited = $Process.HasExited }
        catch { Write-Verbose ('Exit state of process {0} not readable: {1}' -f $Owner.ProcessId, $_.Exception.Message) }
        if ($Exited) { return 'ProcessGone' }
        $Started = $null
        try { $Started = $Process.StartTime.ToUniversalTime() }
        catch { Write-Verbose ('Start time of process {0} not readable: {1}' -f $Owner.ProcessId, $_.Exception.Message) }
        if ($null -eq $Started) { return 'StartTimeUnknown' }
        if (($Started - $Owner.ProcessStartTimeUtc) -gt $ReusedAfter) { return 'ProcessIdReused' }
        if ($Owner.ProcessId -eq $PID) { return 'ThisProcess' }
        return 'ProcessRunning'
    }
    finally { $Process.Dispose() }
}

# The security descriptor of a new Windows snapshot: full control for the
# current user, SYSTEM and Administrators, and nothing inherited from the
# folder. Throws off Windows.
function New-OwnerOnlyFileSecurity
{
    $Security = [System.Security.AccessControl.FileSecurity]::new()
    $Security.SetAccessRuleProtection($true, $false)
    foreach ($Sid in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User, [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')))
    {
        $Security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($Sid, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow))
    }
    return $Security
}

# Create an empty file for a secret, before anything is written to it. On Linux
# and macOS it is created with mode 600 in the same call, and on Windows with
# the access list of New-OwnerOnlyFileSecurity, so it is never readable by
# other users. Save-AzContext and the copies below write into it in place,
# which keeps that mode or list. On Windows, an error in building or applying
# the access list that is not an I/O error makes it create the file with the
# folder's access list instead, and Test-OwnerOnlyFile then reports it; an
# I/O error (the file already exists, the folder cannot be written) is thrown,
# and no file is created. Before PowerShell 7.3 on Linux and macOS the file
# gets the default mode, which Test-OwnerOnlyFile reports. Throws when the
# file already exists.
function New-OwnerOnlyFile
{
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($IsWindows)
    {
        try
        {
            $Security = New-OwnerOnlyFileSecurity
            ([System.IO.FileSystemAclExtensions]::Create([System.IO.FileInfo]::new($Path), [System.IO.FileMode]::CreateNew, [System.Security.AccessControl.FileSystemRights]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::None, $Security)).Dispose()
            return
        }
        catch [System.IO.IOException] { throw }
        catch { Write-Verbose ('Could not create {0} with an owner-only access list: {1}' -f $Path, $_.Exception.Message) }
    }
    else
    {
        # UnixCreateMode needs .NET 7 (PowerShell 7.3 or later).
        $OptionsType = 'System.IO.FileStreamOptions' -as [type]
        if ($null -ne $OptionsType -and $null -ne $OptionsType.GetProperty('UnixCreateMode'))
        {
            $Options = $OptionsType::new()
            $Options.Mode = [System.IO.FileMode]::CreateNew
            $Options.Access = [System.IO.FileAccess]::Write
            $Options.UnixCreateMode = [System.IO.UnixFileMode]'UserRead, UserWrite'
            ([System.IO.FileStream]::new($Path, $Options)).Dispose()
            return
        }
    }
    ([System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)).Dispose()
}

# $true when an access list lets no one but the allowed accounts in: it does not
# inherit from its folder, and every Allow entry is for one of AllowedSids.
# Rules are { Sid, Type } (SID text, 'Allow' or 'Deny').
function Test-OwnerOnlyAccessList
{
    param(
        [Parameter(Mandatory = $true)][bool]$Protected,
        [object[]]$Rules = @(),
        [Parameter(Mandatory = $true)][string[]]$AllowedSids
    )
    if (-not $Protected) { return $false }
    foreach ($Rule in @($Rules))
    {
        if ([string]$Rule.Type -eq 'Allow' -and $AllowedSids -notcontains [string]$Rule.Sid) { return $false }
    }
    return $true
}

# $true when no user other than the owner can read or write the file: on Linux
# and macOS no group or other permission bit is set; on Windows its effective
# access list, read back from the file, passes Test-OwnerOnlyAccessList for the
# current user, SYSTEM and Administrators. $false when that cannot be read.
function Test-OwnerOnlyFile
{
    param([Parameter(Mandatory = $true)][string]$Path)
    try
    {
        if ($IsWindows)
        {
            $Acl = [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.FileInfo]::new($Path))
            $Rules = @($Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { [pscustomobject]@{ Sid = $_.IdentityReference.Value; Type = [string]$_.AccessControlType } })
            $Allowed = @([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
            return (Test-OwnerOnlyAccessList -Protected $Acl.AreAccessRulesProtected -Rules $Rules -AllowedSids $Allowed)
        }
        $Mode = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).UnixFileMode
        if ($null -eq $Mode) { return $false }
        $GroupOrOther = [System.IO.UnixFileMode]'GroupRead, GroupWrite, GroupExecute, OtherRead, OtherWrite, OtherExecute'
        return (([int]$Mode -band [int]$GroupOrOther) -eq 0)
    }
    catch
    {
        Write-Verbose ('Could not read the access of {0}: {1}' -f $Path, $_.Exception.Message)
        return $false
    }
}

# Write one stream's snapshot. The file is created owner-only first. Without
# Content, Save-AzContext writes the wrapper's current context into it; with
# Content (the bytes of an earlier snapshot of this run), those bytes are
# written. On Linux and macOS a write that widened the mode is narrowed again.
# Returns { OwnerOnly, Content }, Content being the bytes written. Throws when
# the file cannot be written (the caller deletes it).
function Save-StreamAzContextSnapshot
{
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [byte[]]$Content
    )
    New-OwnerOnlyFile -Path $Path
    if ($null -eq $Content)
    {
        Save-AzContext -Path $Path -Force -ErrorAction Stop | Out-Null
        $Content = [System.IO.File]::ReadAllBytes($Path)
    }
    else
    {
        [System.IO.File]::WriteAllBytes($Path, $Content)
    }
    # $null before .NET 7, which has no API to set a mode.
    $ModeType = 'System.IO.UnixFileMode' -as [type]
    if (-not $IsWindows -and $null -ne $ModeType -and -not (Test-OwnerOnlyFile -Path $Path))
    {
        # A file system that refuses the change only earns the caller's warning.
        try { [System.IO.File]::SetUnixFileMode($Path, ($ModeType::UserRead -bor $ModeType::UserWrite)) }
        catch { Write-Verbose ("Could not set mode 600 on {0}: {1}" -f $Path, $_.Exception.Message) }
    }
    return [pscustomobject]@{ OwnerOnly = (Test-OwnerOnlyFile -Path $Path); Content = $Content }
}

# Delete Az context snapshots. Never throws, so a failed delete cannot hide the
# real exit reason. A file that is gone, also when another process deleted it
# first, counts as deleted. Returns one { Path, Message } per file that is
# still there, so the caller can say it must be deleted by hand.
function Remove-AzContextSnapshot
{
    param([string[]]$Path = @())
    $Failed = @()
    foreach ($Item in @($Path | Where-Object { -not [string]::IsNullOrEmpty($_) }))
    {
        if (-not (Test-Path -LiteralPath $Item)) { continue }
        try { Remove-Item -LiteralPath $Item -Force -ErrorAction Stop }
        catch
        {
            if (Test-Path -LiteralPath $Item) { $Failed += [pscustomobject]@{ Path = $Item; Message = $_.Exception.Message } }
        }
    }
    return $Failed
}

# Look at the Az context snapshots in the inventory folder at the start of a
# run. A run that is killed (for example when its terminal window is closed)
# never reaches its own cleanup, and its copies stay. A copy is deleted only
# when its name shows it was written by a process on this machine that has
# ended; the copies of a process that is still running, this one included,
# are kept, however old they are and whatever the tenant of their run. Such a
# copy is deleted by its own run's cleanup, or by a later run once that
# process has ended. A copy from another machine or with a name in another
# form is never deleted here: it is returned in Unknown so the caller can
# name it. Returns { Removed, Failed, Unknown }; Unknown entries are
# { Path, Reason, MachineName }.
function Remove-OrphanedAzContextSnapshot
{
    param([Parameter(Mandatory = $true)][string]$InventoryRoot)
    $Orphaned = @()
    $Unknown = @()
    foreach ($File in @(Get-ChildItem -Path $InventoryRoot -Filter '.rda-stream-azcontext-*.json' -File -Force -ErrorAction SilentlyContinue))
    {
        $Owner = ConvertFrom-AzContextSnapshotName -Name $File.Name
        $State = Get-AzContextSnapshotOwnerState -Owner $Owner
        switch ($State)
        {
            { $_ -in 'ProcessGone', 'ProcessIdReused' } { $Orphaned += $File.FullName }
            { $_ -in 'OtherMachine', 'Unreadable' } { $Unknown += [pscustomobject]@{ Path = $File.FullName; Reason = $State; MachineName = $Owner.MachineName } }
        }
    }
    $Failed = @(Remove-AzContextSnapshot -Path $Orphaned)
    return [pscustomobject]@{
        Removed = $Orphaned.Count - $Failed.Count
        Failed  = $Failed
        Unknown = $Unknown
    }
}

# Whether Az context autosave is off for this process, so an imported context
# (and its token cache) is kept in memory and not written to the user's Az
# profile files: Get-AzContextAutosaveSetting reports Process mode with no
# context or cache file. Returns { Disabled; Detail }, Detail saying what the
# setting reported, or why it could not be read, when it is not off.
function Get-AzContextAutosaveCheck
{
    try { $Setting = Get-AzContextAutosaveSetting -Scope Process -ErrorAction Stop }
    catch { return [pscustomobject]@{ Disabled = $false; Detail = ('Get-AzContextAutosaveSetting failed: {0}' -f $_.Exception.Message) } }
    if ($null -eq $Setting) { return [pscustomobject]@{ Disabled = $false; Detail = 'Get-AzContextAutosaveSetting returned nothing' } }
    $NoFile = { param($Value) [string]::IsNullOrEmpty([string]$Value) -or [string]$Value -eq 'None' }
    if ([string]$Setting.Mode -eq 'Process' -and (& $NoFile $Setting.ContextFile) -and (& $NoFile $Setting.CacheFile)) { return [pscustomobject]@{ Disabled = $true; Detail = $null } }
    return [pscustomobject]@{ Disabled = $false; Detail = ('Get-AzContextAutosaveSetting reports Mode={0}, ContextFile={1}, CacheFile={2}' -f $Setting.Mode, $Setting.ContextFile, $Setting.CacheFile) }
}

# The subscriptions visible to the tenant that have no report in this run's
# consolidated zip, each with the reason the run recorded, and the numbers the
# main summary and RunSummary.log give: the subscriptions in the run (those
# visible and not left out as not enabled), those visible to the tenant, and
# the reports in the zip. The first reason that applies is used, in this
# order: report missing, skipped by the up-front role check, retry limit
# reached, earlier report not carried, not enabled or excluded, collection
# failed (on the retry list after this run), not collected. Kind is a fixed
# word for each reason; Reason is the text, which for a failed collection
# ends with the reason the retry list records (raw error text, so a summary of
# an obfuscated run shows Kind counts only).
function Get-RunReportCoverage
{
    param(
        # Get-AzSubscription answers ({ Id; Name; State }).
        $Visible = @(),
        # Ids of the subscriptions the run covers.
        $RunIds = @(),
        # Ids of the subscriptions whose report is in the consolidated zip.
        $InZipIds = @(),
        [int]$ReportsInZip = 0,
        # { Name; Id } of the subscriptions completed this run whose report zip
        # is missing, and how many there are (some may not be nameable).
        $MissingReports = @(),
        [int]$MissingReportCount = 0,
        $NotReadableIds = @(),
        # Retry-list entries past the retry limit (Get-RetryLimitedAttempts).
        $RetryLimited = @(),
        # { Id; Name; Reason } of the subscriptions a run that continued the
        # unfinished run skipped as completed but could not carry.
        $Uncarried = @(),
        # The retry list after this run ({ Id; Name; Attempts; Reason }).
        $FailedAttempts = @()
    )
    $Ids = { param($Items) @(@($Items) | Where-Object { $null -ne $_ } | ForEach-Object { if ($_ -is [string]) { $_ } else { [string]$_.Id } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
    $VisibleSubs = @(@($Visible) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Id) })
    $Run = @(& $Ids $RunIds)
    $InZip = @(& $Ids $InZipIds)
    $Missing = @(& $Ids $MissingReports)
    $NotReadable = @(& $Ids $NotReadableIds)
    $Limited = @(@($RetryLimited) | Where-Object { $null -ne $_ })
    $LimitedIds = @(& $Ids $Limited)
    $UncarriedIds = @(& $Ids $Uncarried)
    $Retry = @(@($FailedAttempts) | Where-Object { $null -ne $_ })
    $RetryIds = @(& $Ids $Retry)
    $Without = @(foreach ($Sub in $VisibleSubs)
        {
            $Id = [string]$Sub.Id
            if ($InZip -contains $Id) { continue }
            $Kind, $Reason = if ($Missing -contains $Id) { 'report missing', 'report missing (collected, but its report zip was not written or is gone; the next run collects it)' }
            elseif ($NotReadable -contains $Id) { 'skipped by the role check', 'skipped by the up-front role check (not readable)' }
            elseif ($LimitedIds -contains $Id)
            {
                $Entry = @($Limited | Where-Object { [string]$_.Id -eq $Id })[0]
                'retry limit reached', ('retry limit reached (failed {0} runs in a row; to try it again, start a new run with -Fresh)' -f (Get-FailedAttemptCount -Entry $Entry))
            }
            elseif ($UncarriedIds -contains $Id) { 'earlier report not carried', 'earlier report not carried (completed by an earlier run, but its report could not be carried into this zip)' }
            elseif ($Run -notcontains $Id) { 'not enabled or excluded', ('not enabled or excluded (state: {0})' -f [string]$Sub.State) }
            elseif ($RetryIds -contains $Id)
            {
                $Entry = @($Retry | Where-Object { [string]$_.Id -eq $Id })[0]
                'collection failed', ('collection failed: {0}' -f [string]$Entry.Reason)
            }
            else { 'not collected', 'not collected by this run (for example an interrupted run; the next run collects it)' }
            [pscustomobject]@{ Name = [string]$Sub.Name; Id = $Id; Kind = $Kind; Reason = $Reason }
        })
    # A subscription completed this run whose report is missing but which could
    # not be named still counts.
    $Unnamed = [math]::Max(0, $MissingReportCount - @($Without | Where-Object { $_.Kind -eq 'report missing' }).Count)
    return [pscustomobject]@{
        InRun          = @($VisibleSubs | Where-Object { $Run -contains [string]$_.Id }).Count
        Visible        = $VisibleSubs.Count
        ReportsInZip   = $ReportsInZip
        WithoutReport  = $Without
        UnnamedMissing = [int]$Unnamed
    }
}

# The lines MainSummary.html and RunSummary.log give for Get-RunReportCoverage:
# the two numbers, then each subscription without a report in this zip with its
# reason. Under -Obfuscated, the number of subscriptions for each kind of
# reason only, as the summaries give counts only there.
function Get-RunReportCoverageLines
{
    param($Coverage, [switch]$Obfuscated)
    if ($null -eq $Coverage) { return @() }
    $Without = @(@($Coverage.WithoutReport) | Where-Object { $null -ne $_ })
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add(('{0} subscription(s) in this run ({1} visible to the tenant), {2} report(s) in this zip.' -f [int]$Coverage.InRun, [int]$Coverage.Visible, [int]$Coverage.ReportsInZip))
    $Unnamed = [int]$Coverage.UnnamedMissing
    if ($Without.Count + $Unnamed -eq 0) { return $Lines.ToArray() }
    $Lines.Add(('{0} subscription(s) without a report in this zip:' -f ($Without.Count + $Unnamed)))
    if ($Obfuscated)
    {
        foreach ($Group in @($Without | Group-Object -Property Kind | Sort-Object -Property Name)) { $Lines.Add(('  - {0} {1}' -f $Group.Count, $Group.Name)) }
    }
    else
    {
        # A subscription the role check found not readable is named without its
        # id: no zip a run leaves holds the id of a not-readable subscription.
        foreach ($Sub in @($Without | Sort-Object -Property Name, Id))
        {
            if ($Sub.Kind -eq 'skipped by the role check') { $Lines.Add(('  - {0}: {1}' -f $Sub.Name, $Sub.Reason)) }
            else { $Lines.Add(('  - {0} ({1}): {2}' -f $Sub.Name, $Sub.Id, $Sub.Reason)) }
        }
    }
    if ($Unnamed -gt 0) { $Lines.Add(('  - {0} report missing that could not be named (see Per-subscription output verification on the console)' -f $Unnamed)) }
    return $Lines.ToArray()
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
        # Subscriptions completed this run whose report zip is missing, so the
        # consolidated zip does not hold them: the count (some may not be
        # nameable) and the ones named ({ Name; Id }).
        [int]$MissingReportCount = 0,
        $MissingReports = @(),
        # Get-RunReportCoverageLines: the subscriptions in the run, the reports in
        # this zip, and each subscription without one with its reason.
        [string[]]$CoverageLines = @(),
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
    $Missing = @(@($MissingReports) | Where-Object { $null -ne $_ })
    $MissingTotal = [math]::Max($MissingReportCount, $Missing.Count)

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
    $Lines.Add(('  Retry limit reached : {0} (incomplete; a run that continues this one and -ResumeFailedOnly do not collect these)' -f $Limited.Count))
    if ($MissingTotal -gt 0)
    {
        $Lines.Add(('  Report missing      : {0} (completed, but their report zip is not in this zip; the next run collects them)' -f $MissingTotal))
    }
    $Lines.Add(('  0 resources - no access   : {0}' -f $NoAccess.Count))
    $Lines.Add(('  0 resources - empty       : {0}' -f $Empty.Count))
    $Lines.Add(('  0 resources - undetermined: {0}' -f $Undetermined.Count))
    $Coverage = @(@($CoverageLines) | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($Coverage.Count -gt 0)
    {
        $Lines.Add('')
        $Lines.Add('Reports in this zip:')
        foreach ($CoverageLine in $Coverage) { $Lines.Add(('  {0}' -f $CoverageLine)) }
    }

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
            # Run-AllSubscriptions.ps1 collects each failure as a line of text (the
            # subscription name, '<name> (stream-N: <reason>)', or 'stream-N (no
            # summary)'), which has no Name or Id; an object carries both.
            foreach ($FailedSub in $Failed)
            {
                if ($FailedSub -is [string]) { $Lines.Add(('  - {0}' -f $FailedSub)) }
                else { $Lines.Add(('  - {0} ({1})' -f [string]$FailedSub.Name, [string]$FailedSub.Id)) }
            }
        }
        if ($Limited.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Retry limit reached (detail; to try them again, start a new run with -Fresh):')
            foreach ($LimitedSub in $Limited) { $Lines.Add(('  - {0} ({1}): failed {2} runs in a row; last reason: {3}' -f [string]$LimitedSub.Name, [string]$LimitedSub.Id, (Get-FailedAttemptCount -Entry $LimitedSub), [string]$LimitedSub.Reason)) }
        }
        if ($Missing.Count -gt 0)
        {
            $Lines.Add('')
            $Lines.Add('Report missing (detail; not in this zip, the next run collects them):')
            foreach ($MissingSub in $Missing) { $Lines.Add(('  - {0} ({1})' -f [string]$MissingSub.Name, [string]$MissingSub.Id)) }
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
