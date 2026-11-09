#Requires -Version 7.0
<#
.SYNOPSIS
    Reveal obfuscated Azure inventory reports back to their real values - either
    a SINGLE report zip or an entire multi-subscription inventory tree.

.DESCRIPTION
    This is the single entry point for the reveal feature. It runs in one of two
    modes, selected by which parameter you pass:

    SINGLE-REPORT MODE (-InputZip)
        Reveal one obfuscated report zip against its ObfuscationDictionary and
        write a selectively-revealed copy. Delegates to the Invoke-RdaReveal
        engine in Functions/RevealObfuscation.Functions.ps1.

    ALL-SUBSCRIPTIONS MODE (-InventoryRoot, or no mode parameter at all)
        A multi-subscription run (Run-AllSubscriptions.ps1 -Obfuscate) leaves,
        under the inventory root, one folder per subscription. Each folder holds:
          - an obfuscated report zip : ResourcesReport_<stamp>.zip
          - its matching dictionary  : ObfuscationDictionary_<ReportName>_<stamp>.json
        This mode walks those folders, pairs each obfuscated zip with the
        dictionary sitting next to it, runs the reveal engine on each pair (in a
        time-bounded background job so one pathological folder cannot stall the
        batch), and consolidates the revealed per-subscription zips into ONE
        outer zip with the same shape a normal multi-subscription run produces,
        so the ingestion server consumes it exactly like an -Obfuscate outer zip
        - just with the chosen dimensions un-masked.

    Both modes reveal ONLY the dimensions you select (default: Subscription name
    + Resource Group); everything else stays masked. Pairing in all-mode is done
    WITHIN each folder, and only between a report zip and the dictionary of the
    same <stamp>, so it never crosses one report's tokens against another's
    dictionary. A report zip with no dictionary of its stamp, or a dictionary
    with no report zip of its stamp, cannot be revealed: it is counted as
    failed and the run exits non-zero (a folder with neither, or a staging
    folder of an earlier reveal, is only noted as skipped).
    Reveal never guesses which of two reports of one subscription is right (a
    newer recovery run of one service is not the fuller report). When a
    subscription id of one report is also a subscription id of another
    report under the root (for example Run-AllSubscriptions.ps1 run twice
    into it, or a recovery run of one subscription), none of those reports is
    revealed, whichever other subscriptions they hold: each such subscription
    is named by its masked token with the report folders that hold it,
    counted as failed, and the run exits non-zero. Pass -InventoryRoot
    pointing at one run's folders, or move the extra report away. Every
    report whose subscriptions are in no other report is still revealed and
    shipped. Two such reports with the same file name (the same stamp in two
    folders) both ship: the later ones by folder name go in the bundle as
    2_ResourcesReport_<stamp>.zip, 3_ResourcesReport_<stamp>.zip and so on.
    Each report's subscriptions are read from the real ids in its dictionary,
    or, when its dictionary names none, from the name of the DebugLog_ or
    ErrorLog_ file its run wrote into
    the inventory root (DebugLog_ResourcesReport_<stamp>_<subscription id>.log).
    A subscription with no resources has an empty dictionary, so it is
    matched by that log alone. Limit: a report whose dictionary names no
    subscription and whose log is not there (a run of ResourceInventory.ps1
    without Run-AllSubscriptions.ps1, which names its log by stamp only, or a
    log that was deleted) cannot be matched, so it is revealed on its own,
    even beside an older report of the same subscription.

    HANDLE WITH CARE. The output contains the real values you chose to reveal.
    Share it only with the party meant to ingest it. Dictionaries and any
    fully-revealed output stay local.

.PARAMETER InputZip
    SINGLE-REPORT MODE. Path to one obfuscated report zip to reveal. Presence of
    this parameter selects single-report mode.

.PARAMETER DictionaryPath
    SINGLE-REPORT MODE. Path to the ObfuscationDictionary_*.json for -InputZip.
    If omitted, the newest ObfuscationDictionary_*.json in the current directory
    is used.

.PARAMETER InventoryRoot
    ALL-SUBSCRIPTIONS MODE. Folder that contains the per-subscription output
    folders. Defaults to C:\InventoryReports on Windows and
    $HOME/InventoryReports elsewhere - the same default Run-AllSubscriptions.ps1
    uses.

.PARAMETER StagingDirectory
    ALL-SUBSCRIPTIONS MODE. Where the individual revealed per-subscription zips
    are written before consolidation. Defaults to
    <InventoryRoot>/RevealedStaging_<timestamp>_<random>, where the timestamp
    goes to the millisecond. Kept after the run (not
    auto-deleted) so a partial run is recoverable; pass -RemoveStaging to delete
    it once the outer zip is built. Must be a new or empty folder, or (with
    -Resume) one a reveal of the same -InventoryRoot staged into before (Reveal
    marks it with a hidden .reveal-staging.json file that records the fields
    and each finished output); any other folder is refused. Reveal makes the
    folder readable by its owner only before writing into it, and expands
    each report while it reveals it into a hidden .reveal-tmp folder inside
    it, which it removes, also after a folder times out. Only one run at a
    time can use a staging folder: a run holds the lock file .reveal-lock in
    it while it runs, and a second run stops with a plain message. Only the zips
    this run revealed (or, with -Resume, found already revealed and matching
    the record) go in the outer zip.

.PARAMETER RemoveStaging
    ALL-SUBSCRIPTIONS MODE. After the outer zip is successfully created (only on
    a fully clean run), delete the revealed zips and the mark from staging, then
    the staging directory itself if nothing else is left in it.

.PARAMETER Resume
    ALL-SUBSCRIPTIONS MODE. Continue an interrupted run instead of starting
    fresh. Re-uses a prior run's staging directory and SKIPS any report whose
    revealed zip the staging mark records as finished (same bytes, same source
    report and dictionary), so a resumed run does not redo completed work - and
    gets past a folder that previously stalled. Any other report is revealed
    again. The run must use the same -Fields (or -All) as the run it resumes,
    or it is refused. With -Resume and no
    explicit -StagingDirectory, the most recent RevealedStaging_* under the
    inventory root is auto-detected.

.PARAMETER ParallelStreams
    ALL-SUBSCRIPTIONS MODE. How many per-subscription folders to reveal
    concurrently. Folders are independent (each has its own report zip +
    dictionary and writes its own output), so this scales the wall-clock of a
    large run roughly by the chosen degree. Defaults to 1 (sequential, identical
    to the prior behaviour). Each concurrent reveal is still bounded by its own
    -FolderTimeoutMinutes cap. Pick a value near the box's core count; very high
    values give diminishing returns because each reveal is disk/CPU heavy
    (Expand-Archive / Compress-Archive).

.PARAMETER FolderTimeoutMinutes
    ALL-SUBSCRIPTIONS MODE. Hard cap, in minutes, on how long a single folder's
    reveal may run before it is abandoned (recorded as a timeout failure) so the
    batch can move on to the next folder. Defaults to 20. Lower it (e.g. 1) to
    blast quickly past folders that stall - combine with -Resume so already
    revealed folders are skipped and only the previously stuck ones are retried
    under the shorter cap. Accepts fractional minutes (e.g. 0.5).

.PARAMETER Fields
    BOTH MODES. Which dimensions to reveal. Valid: ResourceGroup, Subscription,
    Tag, ResourceName, ResourceId, FreeText. Defaults to
    ResourceGroup + Subscription. Ignored when -All is supplied.

.PARAMETER All
    BOTH MODES. Reveal every dimension the dictionary can reverse (full
    un-obfuscate). Overrides -Fields. NOTE this is not a perfect byte-for-byte
    undo: fields nulled or stamped with the lossy 'obfuscated' sentinel at
    obfuscation time do not come back.

.PARAMETER OutputZip
    BOTH MODES. Path for the output zip. Single mode defaults to
    <InputZip>_revealed.zip next to the input; all-mode defaults to
    <InventoryRoot>/AllSubscriptions_Revealed_<timestamp>_<random>.zip.

.EXAMPLE
    # Single report: reveal Subscription name + Resource Group
    ./Reveal.ps1 -InputZip .\ResourcesReport_2026-01-01.zip

.EXAMPLE
    # Single report: full reveal, explicit dictionary and output
    ./Reveal.ps1 -InputZip .\report.zip -DictionaryPath .\ObfuscationDictionary_report.json -All -OutputZip .\report_full.zip

.EXAMPLE
    # All subscriptions: reveal Subscription name + Resource Group, one outer zip
    ./Reveal.ps1

.EXAMPLE
    # All subscriptions: continue an interrupted large run
    ./Reveal.ps1 -Resume

.EXAMPLE
    # All subscriptions: custom root, clean up staging, full reveal
    ./Reveal.ps1 -InventoryRoot D:\Reports -All -RemoveStaging
#>
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    # ---- Single-report mode ----
    [Parameter(ParameterSetName = 'Single', Mandatory = $true)]
    [string]   $InputZip,

    [Parameter(ParameterSetName = 'Single')]
    [string]   $DictionaryPath,

    [Parameter(ParameterSetName = 'Single')]
    [string]   $SearchDirectory = '.',

    # ---- All-subscriptions mode ----
    [Parameter(ParameterSetName = 'All')]
    [string]   $InventoryRoot,

    [Parameter(ParameterSetName = 'All')]
    [string]   $StagingDirectory,

    [Parameter(ParameterSetName = 'All')]
    [switch]   $RemoveStaging,

    [Parameter(ParameterSetName = 'All')]
    [switch]   $Resume,

    [Parameter(ParameterSetName = 'All')]
    [ValidateRange(0.1, 10080)]
    [double]   $FolderTimeoutMinutes = 20,

    [Parameter(ParameterSetName = 'All')]
    [ValidateRange(1, 64)]
    [int]      $ParallelStreams = 1,

    # ---- Common to both modes ----
    [ValidateSet('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')]
    [string[]] $Fields = @('ResourceGroup', 'Subscription'),

    [switch]   $All,

    [string]   $OutputZip
)

$ErrorActionPreference = 'Stop'

# Shared functions: Invoke-RdaReveal + its helpers live in
# RevealObfuscation.Functions.ps1; Write-RdaProgress lives in
# Common.Functions.ps1. Dot-source both so they load into this script's scope.
# Fail loud if missing rather than a confusing later error.
$RevealFunctions = Join-Path $PSScriptRoot 'Functions/RevealObfuscation.Functions.ps1'
$CommonFunctions = Join-Path $PSScriptRoot 'Functions/Common.Functions.ps1'
foreach ($FunctionFile in @($RevealFunctions, $CommonFunctions))
{
    if (-not (Test-Path -LiteralPath $FunctionFile -PathType Leaf))
    {
        throw "Cannot find shared functions at $FunctionFile"
    }
    . $FunctionFile
}

# -All is a full reveal: expand to every reversible dimension (overrides
# -Fields). Done once here so both modes see the expanded list.
if ($All)
{
    $Fields = @('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')
}

# =============================================================================
# SINGLE-REPORT MODE - delegate straight to the engine.
# =============================================================================
if ($PSCmdlet.ParameterSetName -eq 'Single')
{
    $EngineParams = @{
        InputZip = $InputZip
        Fields   = $Fields
    }
    if (-not [string]::IsNullOrEmpty($DictionaryPath)) { $EngineParams.DictionaryPath = $DictionaryPath }
    if (-not [string]::IsNullOrEmpty($SearchDirectory)) { $EngineParams.SearchDirectory = $SearchDirectory }
    if (-not [string]::IsNullOrEmpty($OutputZip)) { $EngineParams.OutputZip = $OutputZip }
    if ($All) { $EngineParams.All = $true }

    Invoke-RdaReveal @EngineParams
    return
}

# =============================================================================
# ALL-SUBSCRIPTIONS MODE
# =============================================================================

# Resolve the inventory root (same default Run-AllSubscriptions.ps1 uses).
if ([string]::IsNullOrEmpty($InventoryRoot))
{
    $InventoryRoot = if ($PSVersionTable.Platform -eq 'Unix') { Join-Path $HOME 'InventoryReports' } else { 'C:\InventoryReports' }
}
if (-not (Test-Path -LiteralPath $InventoryRoot -PathType Container))
{
    throw "Inventory root not found: $InventoryRoot (pass -InventoryRoot to point at the folder holding the per-subscription folders)."
}
# Canonicalize to an absolute path so the staging-directory exclusion compare
# below is airtight even when the caller passes a relative -InventoryRoot.
# Also drop a trailing separator, so 'root/' and 'root' name the same root
# (the staging mark below records it and is compared with it).
$InventoryRoot = ConvertTo-RevealComparablePath (Resolve-Path -LiteralPath $InventoryRoot).Path

# The default staging folder and outer zip are named by the time to the
# millisecond and a short random part, so two runs started in the same second
# (or millisecond) never pick the same names.
$Timestamp = (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6)
if ([string]::IsNullOrEmpty($StagingDirectory))
{
    if ($Resume)
    {
        # Resume re-uses a prior run's staging directory: the revealed zips
        # already in it are the record of which folders completed. Auto-detect
        # the most recent RevealedStaging_* under the inventory root. If none is
        # found we cannot resume, so stop and tell the caller to point
        # -StagingDirectory at the folder holding the already-revealed zips.
        $PriorStaging = Get-ChildItem -LiteralPath $InventoryRoot -Directory -Filter 'RevealedStaging_*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $PriorStaging)
        {
            $StagingDirectory = $PriorStaging.FullName
            Write-Host ("Resume: re-using most recent staging directory: {0}" -f $StagingDirectory) -ForegroundColor Cyan
        }
        else
        {
            throw "-Resume requested but no prior staging directory (RevealedStaging_*) was found under $InventoryRoot. Re-run with -StagingDirectory pointing at the folder that holds the already-revealed zips from the interrupted run."
        }
    }
    else
    {
        $StagingDirectory = Join-Path $InventoryRoot ("RevealedStaging_" + $Timestamp)
    }
}
if ([string]::IsNullOrEmpty($OutputZip))
{
    $OutputZip = Join-Path $InventoryRoot ("AllSubscriptions_Revealed_" + $Timestamp + ".zip")
}
# The outer zip is written with .NET file calls, which read a relative path
# against the process folder, so make it a full path against the PowerShell
# location here, taken as written. Add '.zip' when the name has another
# ending, as Compress-Archive did.
$OutputZip = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputZip)
if ([System.IO.Path]::GetExtension($OutputZip) -ne '.zip') { $OutputZip += '.zip' }
# The staging folder must belong to a reveal of THIS inventory root. Reveal
# marks each staging folder it uses with a small hidden file naming the
# inventory root. A folder that already holds files but has no such mark (or a
# mark for another root) may hold stale or unrelated reports: taking them would
# put them in the upload, -Resume would read them as done, and -RemoveStaging
# would delete them. So such a folder is refused before anything is written.
$StagingMarkerName = '.reveal-staging.json'
$StagingMarkerPurpose = 'Reveal staging folder'
# Each reveal expands its report, with the real values, into a folder inside
# this one, so the copy stays in the owner-only staging folder. A job stopped
# at its time limit cannot remove its copy, so Reveal removes it.
$RevealTempName = '.reveal-tmp'
# The fields this run reveals, in one form, recorded in the mark and compared
# by -Resume.
$FieldsKey = (@($Fields | Sort-Object -Unique) -join ', ')
# The finished outputs of this staging folder, by file name: each output's
# SHA-256 and the report and dictionary (name and SHA-256) it came from. Kept
# in the mark and written again after each output is complete.
$StagingOutputs = @{}
$MarkerData = $null

# Write the mark: the inventory root, the fields and the finished outputs. It
# is written to a sibling file and then moved over the mark, so a run killed
# while writing never leaves half a mark.
function Save-RevealStagingMarker
{
    $Json = [ordered]@{
        Purpose       = $StagingMarkerPurpose
        InventoryRoot = $InventoryRoot
        Fields        = @($Fields | Sort-Object -Unique)
        All           = [bool]$All
        Outputs       = $StagingOutputs
    } | ConvertTo-Json -Depth 5
    $Temp = $StagingMarkerPath + '.tmp'
    [System.IO.File]::WriteAllText($Temp, $Json, [System.Text.UTF8Encoding]::new($false))
    if ($IsWindows)
    {
        $TempItem = Get-Item -LiteralPath $Temp -Force
        $TempItem.Attributes = $TempItem.Attributes -bor [System.IO.FileAttributes]::Hidden
    }
    [System.IO.File]::Move($Temp, $StagingMarkerPath, $true)
}

# The SHA-256 of a file, as upper-case hex.
function Get-RevealFileSha256
{
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# Why a staging mark's Outputs cannot be used, or $null when every record has
# the shape Save-RevealStagingMarker writes: a plain file name that stays
# directly in staging, mapped to its output's SHA-256 and the name and SHA-256
# of the report and dictionary it came from. No Outputs at all is an empty
# record.
function Get-RevealBadOutputRecord
{
    param($Outputs, [string]$StagingDirectory, [System.StringComparison]$PathComparison)
    if ($null -eq $Outputs) { return $null }
    if ($Outputs -isnot [System.Collections.IDictionary]) { return 'its Outputs is not a list of named records' }
    $StagingFull = ConvertTo-RevealComparablePath ([System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StagingDirectory)))
    $Separators = @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar, '/', '\') | Select-Object -Unique
    foreach ($Key in @($Outputs.Keys))
    {
        $Name = [string]$Key
        $Shown = "'" + $Name + "'"
        if ($Key -isnot [string] -or [string]::IsNullOrWhiteSpace($Name)) { return ('an output with no file name') }
        if ($Name -eq '.' -or $Name -eq '..') { return ('the output name {0} is not a file name' -f $Shown) }
        if ($Name.IndexOfAny([char[]]$Separators) -ge 0 -or $Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return ('the output name {0} has a folder part or a character a file name cannot hold' -f $Shown) }
        if ([System.IO.Path]::IsPathRooted($Name)) { return ('the output name {0} is a rooted path' -f $Shown) }
        $Parent = ConvertTo-RevealComparablePath ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath((Join-Path $StagingFull $Name))))
        if (-not [string]::Equals($Parent, $StagingFull, $PathComparison)) { return ('the output name {0} is not in the staging folder' -f $Shown) }
        $Record = $Outputs[$Key]
        if ($Record -isnot [System.Collections.IDictionary]) { return ('the record of {0} is not a record' -f $Shown) }
        foreach ($Field in @('Sha256', 'SourceSha256', 'DictionarySha256'))
        {
            $Value = $Record[$Field]
            if ($Value -isnot [string] -or $Value -notmatch '^[0-9A-Fa-f]{64}\z') { return ('the record of {0} has no SHA-256 of 64 hex characters in {1}' -f $Shown, $Field) }
        }
        foreach ($Field in @('SourceFolder', 'SourceName', 'DictionaryName'))
        {
            $Value = $Record[$Field]
            if ($Value -isnot [string] -or [string]::IsNullOrEmpty($Value)) { return ('the record of {0} has no text in {1}' -f $Shown, $Field) }
        }
    }
    return $null
}
$PathComparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

# Read a staging mark. Its Root is set only when the mark is one Reveal wrote:
# a JSON object whose Purpose is the one Reveal writes and whose
# InventoryRoot is a path. A look-alike file (no Purpose, or another one) is
# not a Reveal mark, so the folder that holds it is not taken as Reveal's.
function Read-RevealStagingMarker
{
    param([string]$Path)
    $Result = [pscustomobject]@{ Data = $null; Root = $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $Result }
    try { $Data = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { return $Result }
    if ($Data -isnot [System.Collections.IDictionary]) { return $Result }
    if ($Data['Purpose'] -isnot [string] -or $Data['Purpose'] -cne $StagingMarkerPurpose) { return $Result }
    if ($Data['InventoryRoot'] -isnot [string] -or [string]::IsNullOrEmpty($Data['InventoryRoot'])) { return $Result }
    $Result.Data = $Data
    $Result.Root = $Data['InventoryRoot']
    return $Result
}

# Whether a mark read by Read-RevealStagingMarker is for this inventory root
# (the same folder, see Test-RevealSamePath).
function Test-RevealMarkerForThisRoot
{
    param($Marker)
    if ([string]::IsNullOrEmpty($Marker.Root)) { return $false }
    try { return [bool](Test-RevealSamePath -Left $Marker.Root -Right $InventoryRoot -PathComparison $PathComparison) }
    catch { return $false }
}

# Why the rest of a Reveal mark that records its fields does not have the
# shape Save-RevealStagingMarker writes, or $null when it does: Fields a list
# of field names Reveal knows, All true or false, and Outputs a set of named
# records (checked one by one by Get-RevealBadOutputRecord).
function Get-RevealMarkerShapeProblem
{
    param([System.Collections.IDictionary]$Data)
    $Known = @('ResourceGroup', 'Subscription', 'Tag', 'ResourceName', 'ResourceId', 'FreeText')
    $MarkedFields = $Data['Fields']
    if ($MarkedFields -isnot [System.Collections.IList] -or $MarkedFields.Count -eq 0) { return 'its Fields is not a list of field names' }
    foreach ($Field in $MarkedFields)
    {
        if ($Field -isnot [string] -or $Known -cnotcontains $Field) { return 'its Fields names a field Reveal does not know' }
    }
    if (-not $Data.Contains('All') -or $Data['All'] -isnot [bool]) { return 'its All is not true or false' }
    if (-not $Data.Contains('Outputs') -or $Data['Outputs'] -isnot [System.Collections.IDictionary]) { return 'its Outputs is not a set of named records' }
    return $null
}

if ((Test-Path -LiteralPath $StagingDirectory) -and -not (Test-Path -LiteralPath $StagingDirectory -PathType Container))
{
    throw "-StagingDirectory names a file, not a folder: $StagingDirectory. Use a new or empty folder."
}
# Only one run at a time may use a staging folder: two runs in one folder
# would share the mark, the expanded copies and the staged outputs, and could
# erase each other's work or replace each other's bundle. So a run takes an
# exclusive lock file in staging (opened with no sharing, held until the run
# ends) before it reads or writes the mark or any other file there; a second
# run then stops with a plain message. A lock file left by a run that was
# killed holds no lock, so it is taken over. A new folder is made first, so
# the lock can be taken in it.
$StagingLockName = '.reveal-lock'
if (-not (Test-Path -LiteralPath $StagingDirectory)) { New-Item -ItemType Directory -Path $StagingDirectory -Force | Out-Null }
$StagingLockPath = Join-Path $StagingDirectory $StagingLockName
$StagingLockExisted = Test-Path -LiteralPath $StagingLockPath
try
{
    $StagingLock = [System.IO.FileStream]::new($StagingLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
}
catch [System.IO.IOException]
{
    throw ("The staging folder {0} is in use by another Reveal run (its lock file {1} is held: {2}). Wait for that run to end, or use another -StagingDirectory." -f $StagingDirectory, $StagingLockPath, $_.Exception.Message)
}
# Release the lock and remove the lock file this run made (so a folder Reveal
# refuses is left as it was), then stop with $Message.
function Stop-RevealStagingRefused
{
    param([string]$Message)
    $StagingLock.Dispose()
    if (-not $StagingLockExisted) { Remove-Item -LiteralPath $StagingLockPath -Force -ErrorAction SilentlyContinue }
    throw $Message
}
# Release the lock and remove its file, when staging is about to be removed
# or the run ends.
function Remove-RevealStagingLock
{
    if ($null -ne $StagingLock) { $StagingLock.Dispose() }
    Remove-Item -LiteralPath $StagingLockPath -Force -ErrorAction SilentlyContinue
}
$StagingMarkerPath = Join-Path $StagingDirectory $StagingMarkerName
$StagingIsEmpty = @(Get-ChildItem -LiteralPath $StagingDirectory -Force -ErrorAction Stop | Where-Object { $_.Name -ne $StagingLockName }).Count -eq 0
$Marker = Read-RevealStagingMarker -Path $StagingMarkerPath
$MarkerData = $Marker.Data
$MarkedRoot = $Marker.Root
$MarkedForThisRoot = Test-RevealMarkerForThisRoot $Marker
if (-not $StagingIsEmpty -and -not $MarkedForThisRoot)
{
    if ($Resume)
    {
        $Why = if ([string]::IsNullOrEmpty($MarkedRoot)) { 'it has no readable Reveal mark {2} (for example a staging folder made by an older Reveal, which did not write one, or a file of that name that Reveal did not write)' } else { 'its Reveal mark {2} names another inventory root, {3}' }
        Stop-RevealStagingRefused (("Cannot resume from {0}: it holds files and is not a Reveal staging folder for {1}: " + $Why + ". Point -StagingDirectory at the staging folder a reveal of {1} used, or run without -Resume to start a new reveal into a new or empty folder.") -f $StagingDirectory, $InventoryRoot, $StagingMarkerPath, $MarkedRoot)
    }
    Stop-RevealStagingRefused ("The staging folder {0} already holds files and is not a Reveal staging folder for {1}. Its files could be stale or unrelated reports, so Reveal will not use it. Use a new or empty folder for -StagingDirectory." -f $StagingDirectory, $InventoryRoot)
}
if (-not $Resume -and $MarkedForThisRoot)
{
    # Reveal's own folder from an earlier run, still holding its files. A
    # fresh run into it would mix with them (and -RemoveStaging would then
    # leave the earlier files without their mark, so the folder could not
    # be resumed or reused). Say plainly what to do instead.
    $Held = @(Get-ChildItem -LiteralPath $StagingDirectory -Force -ErrorAction Stop |
            Where-Object { $_.Name -ne $StagingMarkerName -and $_.Name -ne ($StagingMarkerName + '.tmp') -and $_.Name -ne $RevealTempName -and $_.Name -ne $StagingLockName })
    if ($Held.Count -gt 0)
    {
        Stop-RevealStagingRefused ("The staging folder {0} holds {1} item(s) from an earlier reveal of {2}. Pass -Resume to continue that reveal (its finished reports are checked and kept), or use a new or empty folder for -StagingDirectory." -f $StagingDirectory, $Held.Count, $InventoryRoot)
    }
}
if ($Resume -and $MarkedForThisRoot)
{
    # A resumed run must reveal the same fields as the run it continues, or
    # one bundle would mix reports revealed for different fields.
    $MarkedFields = $MarkerData['Fields']
    if ($null -eq $MarkedFields)
    {
        Stop-RevealStagingRefused ("Cannot resume from {0}: its Reveal mark {1} does not record which fields that reveal used (it was made by an older Reveal), so the resumed bundle could mix reports revealed for different fields. Run without -Resume into a new or empty folder." -f $StagingDirectory, $StagingMarkerPath)
    }
    # The rest of the mark must have the shape Reveal writes, or it is not
    # Reveal's, and the folder is refused before anything in it changes.
    $ShapeProblem = Get-RevealMarkerShapeProblem -Data $MarkerData
    if ($null -ne $ShapeProblem)
    {
        Stop-RevealStagingRefused ("Cannot resume from {0}: its Reveal mark {1} is not one Reveal wrote ({2}), so Reveal will not use the folder and has changed nothing. Run without -Resume into a new or empty folder." -f $StagingDirectory, $StagingMarkerPath, $ShapeProblem)
    }
    $MarkedFieldsKey = (@($MarkedFields | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join ', ')
    if ($MarkedFieldsKey -cne $FieldsKey)
    {
        Stop-RevealStagingRefused ("Cannot resume from {0}: the reveal recorded in {1} used the fields [{2}], but this run asks for [{3}]. Run -Resume again with the same -Fields (or -All), or run without -Resume into a new or empty folder." -f $StagingDirectory, $StagingMarkerPath, $MarkedFieldsKey, $FieldsKey)
    }
    # The recorded outputs are read from a file anyone who can write to
    # staging can change, and -RemoveStaging deletes each one whose bytes
    # match its record. So every record is checked before any is used: its
    # name is a plain file name directly in staging (no folder part, not
    # '.' or '..', not a rooted path), and its fields have the types Reveal
    # writes, with each SHA-256 as 64 hex characters. One bad record
    # refuses the whole mark, before anything is written or deleted.
    $RecordedOutputs = $MarkerData['Outputs']
    $BadRecord = Get-RevealBadOutputRecord -Outputs $RecordedOutputs -StagingDirectory $StagingDirectory -PathComparison $PathComparison
    if ($null -ne $BadRecord)
    {
        Stop-RevealStagingRefused ("Cannot resume from {0}: its Reveal mark {1} has a record of a finished output that Reveal did not write ({2}), so Reveal will not use it and has changed nothing. Run without -Resume into a new or empty folder." -f $StagingDirectory, $StagingMarkerPath, $BadRecord)
    }
    if ($RecordedOutputs -is [System.Collections.IDictionary])
    {
        foreach ($Name in @($RecordedOutputs.Keys)) { $StagingOutputs[[string]$Name] = $RecordedOutputs[$Name] }
    }
}
New-Item -ItemType Directory -Path $StagingDirectory -Force | Out-Null
# Canonicalize staging too, so the per-folder exclusion compare below matches
# the absolute FullName that Get-ChildItem returns.
$StagingDirectory = (Resolve-Path -LiteralPath $StagingDirectory).Path
# Staging will hold real names and ids. Make it owner-only (0700, or an
# owner-only ACL on Windows) before anything is written into it, whether it was
# just made or already existed; stop if that cannot be done.
try { Set-RevealOwnerOnlyDirectory -Path $StagingDirectory }
catch { throw ("Reveal will not write real names and ids into {0}: {1}" -f $StagingDirectory, $_.Exception.Message) }
$StagingMarkerPath = Join-Path $StagingDirectory $StagingMarkerName
Save-RevealStagingMarker
# Expanded copies go here. Any left by an earlier run of this folder that was
# stopped are removed first.
$RevealTempRoot = Join-Path $StagingDirectory $RevealTempName
if (Test-Path -LiteralPath $RevealTempRoot) { Remove-Item -LiteralPath $RevealTempRoot -Recurse -Force -ErrorAction Stop }
New-Item -ItemType Directory -Path $RevealTempRoot -Force | Out-Null
try { Set-RevealOwnerOnlyDirectory -Path $RevealTempRoot }
catch { throw ("Reveal will not write real names and ids into {0}: {1}" -f $RevealTempRoot, $_.Exception.Message) }

# The output zip must not live anywhere inside the staging directory: directly
# in it, it would be swept into itself, and in a folder under it, it would
# stop -RemoveStaging from removing staging. Checked by identity, links
# followed, from the nearest folder of the output path that exists (see
# Test-RevealPathInside).
if (Test-RevealPathInside -Path $OutputZip -Folder $StagingDirectory)
{
    throw "-OutputZip must not be inside the staging directory ($StagingDirectory); it would be included in itself or kept in staging. Choose a path outside staging."
}

Write-Host ("Inventory root : {0}" -f $InventoryRoot) -ForegroundColor Cyan
Write-Host ("Revealing      : {0}" -f ($Fields -join ', ')) -ForegroundColor Cyan
Write-Host ("Staging        : {0}" -f $StagingDirectory) -ForegroundColor Cyan
Write-Host ("Output zip     : {0}" -f $OutputZip) -ForegroundColor Cyan
Write-Host ""

# The staging folder is left out by its identity (see Get-RevealPathIdentity),
# not its name: a report folder whose name differs from staging only by case
# is still read, also in a case-sensitive Windows folder, and staging reached
# through a link is still left out. A folder whose identity cannot be read is
# compared by name, as the platform does.
$StagingIdentity = Get-RevealPathIdentity $StagingDirectory
$Folders = @(Get-ChildItem -LiteralPath $InventoryRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $FolderIdentity = if ($null -ne $StagingIdentity) { Get-RevealPathIdentity $_.FullName } else { $null }
            if ($null -ne $FolderIdentity) { $FolderIdentity -cne $StagingIdentity }
            else { -not [string]::Equals((ConvertTo-RevealComparablePath $_.FullName), (ConvertTo-RevealComparablePath $StagingDirectory), $PathComparison) }
        })

$PairedCount = 0
$RevealedCount = 0
$ResumedCount = 0
$SkippedItems = @()
$FailedItems = @()
# The staged zips this run stands for: the ones it revealed and, under -Resume,
# the ones a prior run of this staging folder already revealed. Only these go
# in the outer zip, never any other *.zip that happens to sit in staging.
$RunOutputs = [System.Collections.Generic.List[string]]::new()

# Hard cap on how long a single folder's reveal may run. A pathological report
# (e.g. an unusually large or malformed zip) can make Expand-Archive /
# Compress-Archive run effectively forever; without a cap one bad folder stalls
# the entire batch. When a folder exceeds this it is abandoned, recorded as a
# timeout failure, and the run continues with the next folder. Configurable via
# -FolderTimeoutMinutes (default 20); Ceiling keeps a fractional-minute value
# (e.g. 0.5) at a whole >=1s Wait-Job timeout.
$RevealTimeoutSeconds = [int][math]::Ceiling($FolderTimeoutMinutes * 60)

# Find the reports to reveal, handling the cheap cases synchronously (half a
# pair -> failed; already revealed under -Resume -> skip). Everything that needs
# the reveal engine becomes a queued work item, drained by the bounded pool
# below.
#
# Run-AllSubscriptions.ps1 runs ResourceInventory.ps1 once per subscription,
# and each of those runs writes a NEW folder ResourcesReport<stamp> under the
# inventory root holding ResourcesReport_<stamp>.zip and
# ObfuscationDictionary_ResourcesReport_<stamp>.json. A second wrapper run into
# the same root adds a second folder per subscription, with new masked tokens.
# So:
#  - every report zip in a folder is paired only with the dictionary of the
#    SAME stamp (never with another stamp's dictionary next to it), and a
#    report with no such dictionary, or a dictionary with no such report, is
#    counted as failed (a folder with neither is only noted as skipped);
#  - Reveal never guesses which of two reports of one subscription is right.
#    The newer report is not always the fuller one: a recovery run of one
#    service (no consumption, no metrics) is newer than the full run it
#    repairs. So each report's subscriptions are read from the real ids in its
#    dictionary's four id maps (the inventory's subscription values are tokens
#    that resolve through these same maps), or, when its dictionary names
#    none, from the name of its run's DebugLog_ or ErrorLog_ file in the
#    inventory root (see $RunLogSubIds), and
#    any report that shares a subscription id with another report is left out
#    together with that other report, whichever subscriptions it also holds.
#    Each such subscription is named by its masked token, with the report
#    folders that hold it, and counted as failed, so the run exits non-zero.
#    The user passes -InventoryRoot pointing at one run's folders, or moves
#    the extra report away. Every report whose subscriptions are in no other
#    report is still revealed and shipped. A shared stamp alone is not
#    ambiguous: two such reports both ship, under distinct names (see
#    $UsedOutNames).
# The log name is what matches a report of a subscription with no resources,
# whose dictionary is empty. Limit: a report whose dictionary names no
# subscription and that has no such log (a run without Run-AllSubscriptions.ps1
# names its log by stamp only, or the log was deleted) cannot be matched to
# one, so it is revealed on its own, and an older non-empty report of the same
# subscription is then revealed beside it. Closing that would need the run to
# write its subscription somewhere Reveal can read, which is a change to what
# the tool writes.
$Candidates = [System.Collections.Generic.List[object]]::new()
# The subscription each run was for, from the names of the local logs it
# wrote. Under Run-AllSubscriptions.ps1 (-RunAllSubs) each
# ResourceInventory.ps1 run writes DebugLog_<report>_<subscription id>.log, and
# ErrorLog_<report>_<subscription id>.log when it logs an error, into the
# parent of its report folder (the inventory root), where <report> is the
# report zip's name without '.zip'. The run writes the debug log for every
# subscription, also one with no resources, whose dictionary is empty and
# names none. So an empty report is matched to its subscription when that
# log is there. The log is used ONLY for a report whose dictionary names no
# subscription: the stamp is not unique to one report (two folders can hold
# reports of one stamp, for example a copied folder), so for a report whose
# dictionary names its subscriptions, the logs of another report of the same
# stamp would wrongly add that report's subscription to it. Logs are keyed by
# the folder that holds them and the report name, and a report reads only the
# logs in the folder that holds its own report folder.
$RunLogSubIds = [System.Collections.Generic.Dictionary[string, object]]::new($(if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }))
foreach ($Log in @(Get-ChildItem -LiteralPath $InventoryRoot -File -ErrorAction SilentlyContinue))
{
    if ($Log.Name -notmatch '^(?:DebugLog|ErrorLog)_(?<report>.+)_(?<sub>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.log$') { continue }
    $LogKey = (ConvertTo-RevealComparablePath $Log.DirectoryName) + [System.IO.Path]::DirectorySeparatorChar + $Matches['report']
    if (-not $RunLogSubIds.ContainsKey($LogKey)) { $RunLogSubIds[$LogKey] = [System.Collections.Generic.List[string]]::new() }
    $LogSubId = $Matches['sub'].ToLowerInvariant()
    if (-not $RunLogSubIds[$LogKey].Contains($LogSubId)) { $RunLogSubIds[$LogKey].Add($LogSubId) }
}
foreach ($Folder in $Folders)
{
    # The obfuscated per-sub reports, excluding any *_revealed.zip or
    # *.partial.zip left by a prior run.
    $Zips = @(Get-ChildItem -LiteralPath $Folder.FullName -Filter 'ResourcesReport_*.zip' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*_revealed.zip' -and $_.Name -notlike '*.partial.zip' } |
            Sort-Object Name)
    $Dicts = @(Get-ChildItem -LiteralPath $Folder.FullName -Filter 'ObfuscationDictionary_*.json' -File -ErrorAction SilentlyContinue)

    # A staging folder of an earlier reveal of this root holds revealed zips
    # under the report names and no dictionary. It is not a report folder. It
    # is known by the Reveal mark it holds for this root, never by its name
    # or by a file of the mark's name alone: a report folder named
    # RevealedStaging_* is still read.
    if (Test-RevealMarkerForThisRoot (Read-RevealStagingMarker -Path (Join-Path $Folder.FullName $StagingMarkerName)))
    {
        $SkippedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = 'a staging folder of an earlier reveal, not a report folder' }
        continue
    }
    # A folder with neither a report zip nor a dictionary may be anything,
    # so it is only noted. A folder with only one of them is a report that
    # cannot be revealed: it is counted as failed, so the run does not look
    # complete without it.
    if ($Zips.Count -eq 0 -and $Dicts.Count -eq 0)
    {
        $SkippedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = 'no obfuscated report zip and no obfuscation dictionary in folder' }
        continue
    }
    if ($Zips.Count -eq 0 -or $Dicts.Count -eq 0)
    {
        $Reason = if ($Zips.Count -eq 0) { 'an obfuscation dictionary but no obfuscated report zip (ResourcesReport_<stamp>.zip) in folder, so its report is not in the bundle' } else { 'an obfuscated report zip but no obfuscation dictionary in folder, so it cannot be revealed and is not in the bundle (a report made without -Obfuscate does not belong under this inventory root)' }
        if ($Zips.Count -gt 0 -and $Folder.Name -like 'RevealedStaging_*')
        {
            $Reason += '. If this is a staging folder of an earlier reveal (it holds no Reveal mark for this inventory root), move it out of the inventory root'
        }
        $FailedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = $Reason; Kind = 'pair'; Folders = @($Folder.Name) }
        continue
    }
    # The dictionaries some report zip of this folder pairs with.
    $PairedDictNames = [System.Collections.Generic.HashSet[string]]::new($(if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }))

    foreach ($Zip in $Zips)
    {
        # ResourcesReport_<stamp>.zip pairs with
        # ObfuscationDictionary_ResourcesReport_<stamp>.json (or the short
        # ObfuscationDictionary_<stamp>.json), and with nothing else.
        $Stamp = $Zip.BaseName.Substring('ResourcesReport_'.Length)
        $DictNames = @(('ObfuscationDictionary_' + $Zip.BaseName + '.json'), ('ObfuscationDictionary_' + $Stamp + '.json'))
        $Matched = @($Dicts | Where-Object { $Name = $_.Name; @($DictNames | Where-Object { [string]::Equals($_, $Name, $PathComparison) }).Count -gt 0 })
        foreach ($M in $Matched) { $null = $PairedDictNames.Add($M.Name) }
        if ($Matched.Count -ne 1)
        {
            $Reason = if ($Matched.Count -eq 0) { "no dictionary with the same stamp ($($DictNames[0])), so it cannot be revealed and is not in the bundle" } else { 'more than one dictionary with the same stamp, so it is not revealed and is not in the bundle' }
            $FailedItems += [pscustomobject]@{ Folder = ('{0}/{1}' -f $Folder.Name, $Zip.Name); Reason = $Reason; Kind = 'pair'; Folders = @($Folder.Name) }
            continue
        }
        $Dict = $Matched[0]
        # Every whole pair (one report zip and the one dictionary of its
        # stamp) is counted, also one whose dictionary then cannot be read
        # and one later left out because its subscription is in another
        # report.
        $PairedCount++

        # The subscriptions: every real subscription id in the dictionary's
        # four id maps (token -> the real id of a resource), and the masked
        # subscription tokens of each id (SubscriptionMap keys), used to name
        # it without printing the real id.
        $SubIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $SubTokens = @{}
        try
        {
            $DictJson = Get-Content -LiteralPath $Dict.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($MapName in @('SubscriptionMap', 'ResourceGroupMap', 'ResourceIdMap', 'ResourceNameMap'))
            {
                $Map = $DictJson.$MapName
                if ($null -eq $Map) { continue }
                foreach ($Property in $Map.PSObject.Properties)
                {
                    $SubId = Get-SubGuidFromResourceId ([string]$Property.Value)
                    if ([string]::IsNullOrEmpty($SubId)) { continue }
                    $SubId = $SubId.ToLowerInvariant()
                    $null = $SubIds.Add($SubId)
                    if ($MapName -eq 'SubscriptionMap')
                    {
                        if (-not $SubTokens.ContainsKey($SubId)) { $SubTokens[$SubId] = [System.Collections.Generic.List[string]]::new() }
                        if (-not $SubTokens[$SubId].Contains($Property.Name)) { $SubTokens[$SubId].Add($Property.Name) }
                    }
                }
            }
        }
        catch
        {
            $FailedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = ('the dictionary {0} could not be read: {1}' -f $Dict.Name, $_.Exception.Message); Kind = 'pair'; Folders = @($Folder.Name) }
            continue
        }
        # A dictionary that names no subscription: the subscription the run's
        # own logs name, in the folder that holds this report's folder (see
        # $RunLogSubIds). Two such reports of one stamp both take every
        # subscription those logs name, so they are left out together rather
        # than either being shipped as the other's subscription.
        if ($SubIds.Count -eq 0)
        {
            $LogKey = (ConvertTo-RevealComparablePath $Folder.Parent.FullName) + [System.IO.Path]::DirectorySeparatorChar + $Zip.BaseName
            if ($RunLogSubIds.ContainsKey($LogKey))
            {
                foreach ($LogSubId in $RunLogSubIds[$LogKey]) { $null = $SubIds.Add($LogSubId) }
            }
        }
        $Candidates.Add([pscustomobject]@{
                Index = $Candidates.Count; Folder = $Folder.Name; Zip = $Zip; Dict = $Dict; Stamp = $Stamp
                Report = ('{0}/{1}' -f $Folder.Name, $Zip.Name)
                SubIds = @($SubIds | Sort-Object); SubTokens = $SubTokens
            })
    }
    # A dictionary no report zip of its stamp pairs with: its report is
    # missing from the folder.
    foreach ($Lone in @($Dicts | Where-Object { -not $PairedDictNames.Contains($_.Name) } | Sort-Object Name))
    {
        $FailedItems += [pscustomobject]@{ Folder = ('{0}/{1}' -f $Folder.Name, $Lone.Name); Reason = 'an obfuscation dictionary with no report zip of the same stamp in its folder, so its report is not in the bundle'; Kind = 'pair'; Folders = @($Folder.Name) }
    }
}

# Which reports hold each subscription id.
$ReportsBySub = @{}
foreach ($Candidate in $Candidates)
{
    foreach ($SubId in $Candidate.SubIds)
    {
        if (-not $ReportsBySub.ContainsKey($SubId)) { $ReportsBySub[$SubId] = [System.Collections.Generic.List[object]]::new() }
        $ReportsBySub[$SubId].Add($Candidate)
    }
}
$Ambiguous = [System.Collections.Generic.HashSet[int]]::new()
$AdviceText = 'Reveal does not guess which report is right, so it reveals none of them. Pass -InventoryRoot pointing at one run''s folders, or move the extra report away.'
foreach ($SubId in @($ReportsBySub.Keys | Sort-Object))
{
    $Holders = @($ReportsBySub[$SubId] | Sort-Object -Property Report)
    if ($Holders.Count -lt 2) { continue }
    foreach ($Holder in $Holders) { $null = $Ambiguous.Add($Holder.Index) }
    # Name the subscription by its masked token in each report (never the
    # real id), with the report that holds it.
    $Named = @($Holders | ForEach-Object {
            $Tokens = if ($_.SubTokens.ContainsKey($SubId)) { @($_.SubTokens[$SubId]) -join ', ' } else { 'no subscription token' }
            '{0} in {1}' -f $Tokens, $_.Report
        })
    $FailedItems += [pscustomobject]@{ Folder = ('subscription masked as ' + ($Named -join '; ')); Reason = ('this subscription is in {0} reports. {1}' -f $Holders.Count, $AdviceText); Kind = 'shared'; Folders = @($Holders | ForEach-Object { $_.Folder }) }
}

$LeftOutItems = @()
$Selected = [System.Collections.Generic.List[object]]::new()
foreach ($Candidate in $Candidates)
{
    if (-not $Ambiguous.Contains($Candidate.Index)) { $Selected.Add($Candidate); continue }
    $Tokens = @($Candidate.SubIds | ForEach-Object { if ($Candidate.SubTokens.ContainsKey($_)) { @($Candidate.SubTokens[$_]) } } | Select-Object -Unique)
    $Holds = if ($Tokens.Count -gt 0) { 'its subscription(s) masked as ' + ($Tokens -join ', ') } else { 'its subscription(s) (no subscription token in its dictionary)' }
    $LeftOutItems += [pscustomobject]@{ Report = $Candidate.Report; Holds = $Holds }
}
$LeftOutItems = @($LeftOutItems | Sort-Object -Property Report)

# A resumed run keeps a recorded output only when it is a name Reveal assigns
# to the report pair the record names: the record's report zip name (a
# ResourcesReport_<stamp>.zip, as Reveal reads them), or that name with a copy
# number in front (2_, 3_ and so on, see $UsedOutNames below). When that pair
# is under the root now (the same folder and report zip name), the record
# must also name its dictionary. A record of a pair no longer under the root
# (for example an older report that was moved away) is kept, so a clean
# -RemoveStaging still removes that older output. Any other record (for
# example one for notes.txt, which Reveal never writes) is dropped from the
# mark, and its file is kept: -RemoveStaging deletes only recorded outputs, so
# it never deletes a file Reveal did not write.
$DroppedRecords = @()
foreach ($Name in @($StagingOutputs.Keys | Sort-Object))
{
    $Record = $StagingOutputs[$Name]
    $SourceName = [string]$Record['SourceName']
    $Assigned = $SourceName -cmatch '\AResourcesReport_.+\.zip\z' -and $SourceName -cnotlike '*_revealed.zip' -and $SourceName -cnotlike '*.partial.zip' -and
    ($Name -ceq $SourceName -or $Name -cmatch ('\A(?:[2-9]|[1-9][0-9]+)_' + [regex]::Escape($SourceName) + '\z'))
    if ($Assigned)
    {
        $Pair = @($Candidates | Where-Object { [string]$Record['SourceFolder'] -ceq $_.Folder -and $SourceName -ceq $_.Zip.Name })
        if ($Pair.Count -gt 0 -and @($Pair | Where-Object { [string]$Record['DictionaryName'] -ceq $_.Dict.Name }).Count -eq 0) { $Assigned = $false }
    }
    if (-not $Assigned)
    {
        $DroppedRecords += $Name
        $null = $StagingOutputs.Remove($Name)
    }
}
if ($DroppedRecords.Count -gt 0)
{
    foreach ($Name in $DroppedRecords)
    {
        Write-Host ("Resume: dropped the staging mark's record of {0}: it is not an output Reveal makes for a report pair under {1}. Its file, if any, is kept." -f $Name, $InventoryRoot) -ForegroundColor Yellow
    }
    Save-RevealStagingMarker
}

$Queue = [System.Collections.Generic.Queue[object]]::new()
$UsedOutNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Candidate in @($Selected | Sort-Object -Property Folder, @{ Expression = { $_.Zip.Name } }))
{
    $Folder = $Candidate.Folder
    $Zip = $Candidate.Zip
    $Dict = $Candidate.Dict

    # Write the revealed copy straight into staging under the ORIGINAL zip name
    # so the consolidated outer zip matches the structure the ingestion server
    # expects from a normal multi-subscription run.
    $OutName = $Zip.Name
    if (-not $UsedOutNames.Add($OutName))
    {
        # Two selected reports with the same file name (the same stamp in two
        # folders, for example a copied folder, with different
        # subscriptions). Both ship: the later ones, by folder name, go in
        # as 2_<name>, 3_<name> and so on, so neither overwrites the other.
        # The number is not taken from the folder's name, which can hold a
        # real customer or resource name. Such a name never starts with
        # 'ResourcesReport_', so it cannot be another report's own name.
        $Copy = 2
        do
        {
            $OutName = ('{0}_{1}' -f $Copy, $Zip.Name)
            $Copy++
        } while (-not $UsedOutNames.Add($OutName))
    }
    $OutPath = Join-Path $StagingDirectory $OutName
    $SourceSha256 = Get-RevealFileSha256 $Zip.FullName
    $DictSha256 = Get-RevealFileSha256 $Dict.FullName

    if ($Resume -and $StagingOutputs.ContainsKey($OutName))
    {
        # Revealed on a prior run. Take it only when the mark recorded it as
        # finished, its bytes still match the record, and it came from this
        # same report and dictionary; otherwise redo it. Skipping lets a
        # resumed run advance past a folder that previously stalled the batch.
        $Record = $StagingOutputs[$OutName]
        $Redo = $null
        if (-not (Test-Path -LiteralPath $OutPath -PathType Leaf)) { $Redo = 'its revealed zip is missing' }
        elseif ([string]$Record['Sha256'] -cne (Get-RevealFileSha256 $OutPath)) { $Redo = 'its revealed zip does not match the one recorded' }
        elseif ([string]$Record['SourceFolder'] -cne $Folder -or [string]$Record['SourceName'] -cne $Zip.Name -or [string]$Record['SourceSha256'] -cne $SourceSha256) { $Redo = 'its source report changed' }
        elseif ([string]$Record['DictionaryName'] -cne $Dict.Name -or [string]$Record['DictionarySha256'] -cne $DictSha256) { $Redo = 'its dictionary changed' }
        else
        {
            try { Assert-RevealZipWithinLimits -Path $OutPath -What 'revealed zip' }
            catch { $Redo = 'its revealed zip is over the zip limits' }
        }
        if ($null -eq $Redo)
        {
            $ResumedCount++
            $RunOutputs.Add($OutPath)
            continue
        }
        Write-Host ("Resume: revealing {0} again: {1}." -f $OutName, $Redo) -ForegroundColor Yellow
        $null = $StagingOutputs.Remove($OutName)
        Save-RevealStagingMarker
    }
    elseif ($Resume -and (Test-Path -LiteralPath $OutPath))
    {
        Write-Host ("Resume: revealing {0} again: the mark has no record of it as finished." -f $OutName) -ForegroundColor Yellow
    }

    $Queue.Enqueue([pscustomobject]@{
            Folder = $Folder; Zip = $Zip.FullName; Dict = $Dict.FullName; OutPath = $OutPath; OutName = $OutName
            SourceName = $Zip.Name; SourceSha256 = $SourceSha256; DictionaryName = $Dict.Name; DictionarySha256 = $DictSha256
        })
}

# Bounded job pool. Keep up to -ParallelStreams reveals in flight, each its own
# child process (so a pathological Expand/Compress can be stopped instead of
# wedging the batch) bounded by its OWN per-folder deadline ($RevealTimeoutSeconds).
# The parent reaps every job serially in this one loop, so the shared counters
# and record lists are mutated only on the parent thread - no cross-thread races.
# The folders are independent (each has its own report zip + dictionary and
# writes its own staged output), so revealing several at once is safe and the
# obfuscation/reveal determinism is per-folder. -ParallelStreams 1 reproduces
# the original one-at-a-time behaviour.
$TotalToReveal = $Queue.Count
$DoneCount = 0
$Running = [System.Collections.Generic.List[object]]::new()

while ($Queue.Count -gt 0 -or $Running.Count -gt 0)
{
    # Fill free slots from the queue, stamping each job with its own deadline.
    while ($Running.Count -lt $ParallelStreams -and $Queue.Count -gt 0)
    {
        $Item = $Queue.Dequeue()
        # This job's own folder for its expanded copy, removed when the job is
        # reaped or stopped.
        $Item | Add-Member -NotePropertyName TempDir -NotePropertyValue (Join-Path $RevealTempRoot ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $Item.TempDir -Force | Out-Null
        $Job = Start-Job -ScriptBlock {
            param($RevealFunctions, $InputZip, $DictionaryPath, $Fields, $OutputZip, $TempDirectory)
            . $RevealFunctions
            Invoke-RdaRevealFolder -InputZip $InputZip -DictionaryPath $DictionaryPath -Fields $Fields -OutputZip $OutputZip -TempDirectory $TempDirectory *> $null
        } -ArgumentList $RevealFunctions, $Item.Zip, $Item.Dict, $Fields, $Item.OutPath, $Item.TempDir
        $LaunchUtc = [DateTime]::UtcNow
        $Running.Add([pscustomobject]@{ Item = $Item; Job = $Job; StartUtc = $LaunchUtc; Deadline = $LaunchUtc.AddSeconds($RevealTimeoutSeconds) })
    }

    Start-Sleep -Seconds 2

    # Reap finished (Completed/Failed/Stopped) or timed-out jobs; keep the rest.
    $StillRunning = [System.Collections.Generic.List[object]]::new()
    foreach ($R in $Running)
    {
        if (@('Completed', 'Failed', 'Stopped') -contains $R.Job.State)
        {
            try
            {
                # Re-throw any terminating error the child raised into the catch.
                Receive-Job -Job $R.Job -ErrorAction Stop | Out-Null
                if (Test-Path -LiteralPath $R.Item.OutPath)
                {
                    $RevealedCount++
                    $RunOutputs.Add($R.Item.OutPath)
                    # Record the finished output in the mark, so a later
                    # -Resume can check it before taking it.
                    $StagingOutputs[$R.Item.OutName] = [ordered]@{
                        Sha256           = Get-RevealFileSha256 $R.Item.OutPath
                        SourceFolder     = $R.Item.Folder
                        SourceName       = $R.Item.SourceName
                        SourceSha256     = $R.Item.SourceSha256
                        DictionaryName   = $R.Item.DictionaryName
                        DictionarySha256 = $R.Item.DictionarySha256
                    }
                    Save-RevealStagingMarker
                }
                else
                {
                    $FailedItems += [pscustomobject]@{ Folder = $R.Item.Folder; Reason = 'reveal completed but produced no output zip'; Kind = 'reveal'; Folders = @($R.Item.Folder) }
                }
            }
            catch
            {
                # Drop any partial/truncated output so it is neither consolidated
                # nor treated as done by a later -Resume.
                Remove-Item -LiteralPath $R.Item.OutPath -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (($R.Item.OutPath -replace '\.zip$', '') + '.partial.zip') -Force -ErrorAction SilentlyContinue
                $FailedItems += [pscustomobject]@{ Folder = $R.Item.Folder; Reason = $_.Exception.Message; Kind = 'reveal'; Folders = @($R.Item.Folder) }
            }
            Remove-Job -Job $R.Job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $R.Item.TempDir -Recurse -Force -ErrorAction SilentlyContinue
            $DoneCount++
        }
        elseif ([DateTime]::UtcNow -ge $R.Deadline)
        {
            # Exceeded this folder's cap. Kill the child so it cannot hold a slot,
            # clean any partial output and the child's expanded copy (its own
            # cleanup never runs once it is killed), record the timeout, free
            # the slot.
            Stop-Job -Job $R.Job -ErrorAction SilentlyContinue
            Remove-Job -Job $R.Job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $R.Item.TempDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $R.Item.OutPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (($R.Item.OutPath -replace '\.zip$', '') + '.partial.zip') -Force -ErrorAction SilentlyContinue
            $FailedItems += [pscustomobject]@{ Folder = $R.Item.Folder; Reason = ("timed out after {0:0.##} minutes" -f ($RevealTimeoutSeconds / 60)); Kind = 'reveal'; Folders = @($R.Item.Folder) }
            $DoneCount++
        }
        else
        {
            $StillRunning.Add($R)
        }
    }
    $Running = $StillRunning

    # Heartbeat: overall done/total plus the in-flight folders and their elapsed.
    $InFlight = ($Running | ForEach-Object { '{0} [{1}s]' -f $_.Item.Folder, [int]([DateTime]::UtcNow - $_.StartUtc).TotalSeconds }) -join ', '
    Write-RdaProgress -Activity 'Revealing per-subscription reports' `
        -CurrentItem ('{0} of {1} done; {2} running: {3}' -f $DoneCount, $TotalToReveal, $Running.Count, $InFlight) `
        -Index $DoneCount -Total $TotalToReveal
}

Write-RdaProgress -Activity 'Revealing per-subscription reports' -Completed
# Every job is reaped, so no expanded copy is still in use.
Remove-Item -LiteralPath $RevealTempRoot -Recurse -Force -ErrorAction SilentlyContinue

# Consolidate the revealed per-sub zips into one outer zip for upload.
# Only this run's outputs (see $RunOutputs) are taken. A *.partial.zip is never
# among them: the single-report engine compresses to a sibling .partial.zip and
# renames it to the final name on success, so a .partial.zip only exists if a
# reveal was hard-killed mid-compress, and must never go in the outer zip.
$StagedZips = @($RunOutputs | Select-Object -Unique |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        ForEach-Object { Get-Item -LiteralPath $_ })
$ConsolidationError = $null
if ($StagedZips.Count -gt 0)
{
    try
    {
        # The outer zip holds the real values, so it is owner-only (0600, or an
        # owner-only ACL on Windows) from the start: it is written to a sibling
        # .partial.zip made owner-only before anything goes in, then moved to
        # its name, which keeps that. Each staged zip goes in at the top by its
        # file name, as Compress-Archive -LiteralPath put it. The paths are
        # taken as written, so '[' and ']' in a name are not a wildcard.
        $OutputZipPartial = ($OutputZip -replace '\.zip$', '') + '.partial.zip'
        Write-RevealZipFromFiles -Files @($StagedZips.FullName) -Path $OutputZipPartial
        # A bundle the ingestion server would refuse is not moved into place,
        # and the run does not say it is ready to upload.
        Assert-RevealZipWithinLimits -Path $OutputZipPartial -What 'outer zip'
        [System.IO.File]::Move($OutputZipPartial, $OutputZip, $true)
    }
    catch
    {
        Remove-Item -LiteralPath $OutputZipPartial -Force -ErrorAction SilentlyContinue
        # Fail LOUD but do not die here. The revealed per-subscription zips are
        # already in staging, so the run is recoverable. Record the reason and
        # fall through to the summary instead of terminating before it prints
        # (which looked like a silent crash - header shown, no summary).
        $ConsolidationError = $_.Exception.Message
    }
}

# ---- Summary ---------------------------------------------------------------
Write-Host ""
Write-Host "================ Reveal Summary ================" -ForegroundColor Green
Write-Host ("Per-subscription folders scanned : {0}" -f $Folders.Count) -ForegroundColor Green
Write-Host ("Paired (zip + dictionary)        : {0}" -f $PairedCount) -ForegroundColor Green
Write-Host ("Revealed successfully            : {0}" -f $RevealedCount) -ForegroundColor Green
Write-Host ("Skipped (already revealed-resume): {0}" -f $ResumedCount) -ForegroundColor $(if ($ResumedCount -gt 0) { 'Cyan' } else { 'Green' })
Write-Host ("Skipped (not a report folder)    : {0}" -f $SkippedItems.Count) -ForegroundColor $(if ($SkippedItems.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("Left out (sub in >1 report)      : {0}" -f $LeftOutItems.Count) -ForegroundColor $(if ($LeftOutItems.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("Failed (see FAIL lines)          : {0}" -f $FailedItems.Count) -ForegroundColor $(if ($FailedItems.Count -gt 0) { 'Red' } else { 'Green' })

foreach ($s in $SkippedItems)
{
    Write-Host ("  SKIP: {0} - {1}" -f $s.Folder, $s.Reason) -ForegroundColor Yellow
}
foreach ($o in $LeftOutItems)
{
    Write-Host ("  LEFT OUT: {0} - not revealed with {1}: it shares a subscription with another report (see FAIL)" -f $o.Report, $o.Holds) -ForegroundColor Yellow
}
foreach ($f in $FailedItems)
{
    Write-Host ("  FAIL: {0} - {1}" -f $f.Folder, $f.Reason) -ForegroundColor Red
}

Write-Host ""
if ($null -eq $ConsolidationError -and $StagedZips.Count -gt 0 -and (Test-Path -LiteralPath $OutputZip))
{
    Write-Host ("Consolidated {0} revealed report(s) into:" -f $StagedZips.Count) -ForegroundColor Green
    Write-Host ("  {0}" -f $OutputZip) -ForegroundColor Green
    Write-Host "Upload this single zip to the ingestion server." -ForegroundColor Green
}
elseif ($null -ne $ConsolidationError)
{
    Write-Host ("Revealed {0} report(s), but consolidating them into the outer zip FAILED:" -f $StagedZips.Count) -ForegroundColor Red
    Write-Host ("  {0}" -f $ConsolidationError) -ForegroundColor Red
    Write-Host ("The revealed per-subscription zips are intact in staging - re-run or zip them manually:" ) -ForegroundColor Yellow
    Write-Host ("  {0}" -f $StagingDirectory) -ForegroundColor Yellow
}
else
{
    Write-Host "No revealed reports were produced - nothing to consolidate. Check the SKIP/FAIL list above." -ForegroundColor Red
}

# Only tear down staging on a fully CLEAN run (outer zip built, nothing failed
# or timed out, no consolidation error). If any folder failed/timed out, the
# staged zips are the only record of what already completed - deleting them
# would defeat a later -Resume. So keep staging and say why.
$CleanRun = ($FailedItems.Count -eq 0 -and $null -eq $ConsolidationError)
if ($RemoveStaging -and $CleanRun -and (Test-Path -LiteralPath $OutputZip))
{
    try
    {
        # Remove only what Reveal put there: this run's zips, the other
        # finished outputs the mark records (when their bytes still match the
        # record, for example a report that an earlier run revealed and this
        # run left out), their partial files and the staging mark. Anything else
        # in the folder is not ours, so the folder is then kept.
        foreach ($Staged in $StagedZips)
        {
            Remove-Item -LiteralPath $Staged.FullName -Force -ErrorAction Stop
            Remove-Item -LiteralPath (($Staged.FullName -replace '\.zip$', '') + '.partial.zip') -Force -ErrorAction SilentlyContinue
        }
        foreach ($Name in @($StagingOutputs.Keys))
        {
            $Recorded = Join-Path $StagingDirectory $Name
            if ((Test-Path -LiteralPath $Recorded -PathType Leaf) -and (Get-RevealFileSha256 $Recorded) -ceq [string]$StagingOutputs[$Name]['Sha256'])
            {
                Remove-Item -LiteralPath $Recorded -Force -ErrorAction Stop
                Remove-Item -LiteralPath (($Recorded -replace '\.zip$', '') + '.partial.zip') -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $StagingMarkerPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($StagingMarkerPath + '.tmp') -Force -ErrorAction SilentlyContinue
        # The run is done with staging, so its lock goes too.
        Remove-RevealStagingLock
        $Leftover = @(Get-ChildItem -LiteralPath $StagingDirectory -Force -ErrorAction Stop)
        if ($Leftover.Count -eq 0)
        {
            Remove-Item -LiteralPath $StagingDirectory -Force -ErrorAction Stop
            Write-Host ("Removed staging directory: {0}" -f $StagingDirectory) -ForegroundColor DarkGray
        }
        else
        {
            Write-Host ("Removed the revealed zips from staging, but kept the folder: it holds {0} item(s) Reveal did not put there: {1}" -f $Leftover.Count, $StagingDirectory) -ForegroundColor Yellow
        }
    }
    catch
    {
        Write-Host ("WARNING: could not remove staging directory {0}: {1}" -f $StagingDirectory, $_.Exception.Message) -ForegroundColor Yellow
    }
}
elseif ($RemoveStaging -and -not $CleanRun)
{
    # Name each cause, with the way out for it, so that following it makes
    # the next run pass: folders whose reveal failed or timed out (the cause
    # each FAIL line names must be fixed first, or -Resume gives the same
    # failure; a timeout needs a longer -FolderTimeoutMinutes), report zips
    # and dictionaries that cannot be paired or read (a missing or broken file
    # must be put back, or an extra dictionary of the same stamp or a report
    # made without -Obfuscate moved away), a subscription in more than one
    # report (the extra report must be moved away first), and the outer zip.
    # Each count is of distinct folders, not of FAIL lines: one folder can
    # have more than one.
    $FolderCount = {
        param([string]$Kind)
        # The names come from one listing of the inventory root, in which two
        # names are two folders, so they are compared exactly: 'bad' and 'BAD'
        # are two folders on Linux and in a case-sensitive Windows folder, and
        # a case-insensitive folder cannot list both.
        $Distinct = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($Name in @($FailedItems | Where-Object { $_.Kind -eq $Kind } | ForEach-Object { $_.Folders })) { $null = $Distinct.Add([string]$Name) }
        $Distinct.Count
    }
    $RevealFailedFolders = & $FolderCount 'reveal'
    $HalfPairFolders = & $FolderCount 'pair'
    $SharedSubs = @($FailedItems | Where-Object { $_.Kind -eq 'shared' }).Count
    $SharedFolders = & $FolderCount 'shared'
    if ($RevealFailedFolders -gt 0)
    {
        Write-Host ("-RemoveStaging skipped: {0} folder(s) failed or timed out (see FAIL). Staging kept: fix the cause each FAIL line names (for a timeout, raise -FolderTimeoutMinutes), then re-run with -Resume:" -f $RevealFailedFolders) -ForegroundColor Yellow
    }
    if ($HalfPairFolders -gt 0)
    {
        Write-Host ("-RemoveStaging skipped: {0} folder(s) hold a report zip or dictionary that cannot be paired or read (see FAIL). Staging kept: put back the missing or broken file each FAIL line names, or move away the extra dictionary of the same stamp or the report made without -Obfuscate, then re-run with -Resume:" -f $HalfPairFolders) -ForegroundColor Yellow
    }
    if ($SharedSubs -gt 0)
    {
        Write-Host ("-RemoveStaging skipped: {0} subscription(s) are in more than one report, in {1} folder(s) (see FAIL). Staging kept: move the extra report away, then re-run with -Resume (or run without -Resume, into a new staging folder, with -InventoryRoot pointing at one run's folders):" -f $SharedSubs, $SharedFolders) -ForegroundColor Yellow
    }
    if ($null -ne $ConsolidationError)
    {
        Write-Host "-RemoveStaging skipped: the outer zip could not be built (see above). Staging kept: fix the cause, then re-run with -Resume, or zip the revealed reports by hand:" -ForegroundColor Yellow
    }
    Write-Host ("  {0}" -f $StagingDirectory) -ForegroundColor Yellow
}
else
{
    Write-Host ("Individual revealed zips kept in: {0}" -f $StagingDirectory) -ForegroundColor DarkGray
}

# The run is done with staging: release its lock (the lock file stays, holding
# no lock, unless staging was removed above).
if ($null -ne $StagingLock) { $StagingLock.Dispose() }

# Non-zero exit if nothing was produced, or if any subscription failed to reveal,
# so an automated/large run surfaces problems instead of looking clean.
if ($StagedZips.Count -eq 0)
{
    exit 1
}
if ($null -ne $ConsolidationError)
{
    exit 1
}
if ($FailedItems.Count -gt 0)
{
    exit 4
}
exit 0
