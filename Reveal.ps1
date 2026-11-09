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
    dictionary. When the root holds more than one run of the same subscription
    (Run-AllSubscriptions.ps1 run twice into it), only the newest report of each
    subscription is revealed; the older ones are listed as left out.

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
    <InventoryRoot>/RevealedStaging_<timestamp>. Kept after the run (not
    auto-deleted) so a partial run is recoverable; pass -RemoveStaging to delete
    it once the outer zip is built. Must be a new or empty folder, or (with
    -Resume) one a reveal of the same -InventoryRoot staged into before (Reveal
    marks it with a hidden .reveal-staging.json file that records the fields
    and each finished output); any other folder is refused. Reveal makes the
    folder readable by its owner only before writing into it. Only the zips
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
    <InventoryRoot>/AllSubscriptions_Revealed_<timestamp>.zip.

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

$Timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
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
# The staging folder must belong to a reveal of THIS inventory root. Reveal
# marks each staging folder it uses with a small hidden file naming the
# inventory root. A folder that already holds files but has no such mark (or a
# mark for another root) may hold stale or unrelated reports: taking them would
# put them in the upload, -Resume would read them as done, and -RemoveStaging
# would delete them. So such a folder is refused before anything is written.
$StagingMarkerName = '.reveal-staging.json'
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
        Purpose       = 'Reveal staging folder'
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
$PathComparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
if (Test-Path -LiteralPath $StagingDirectory)
{
    if (-not (Test-Path -LiteralPath $StagingDirectory -PathType Container))
    {
        throw "-StagingDirectory names a file, not a folder: $StagingDirectory. Use a new or empty folder."
    }
    $StagingMarkerPath = Join-Path $StagingDirectory $StagingMarkerName
    $StagingIsEmpty = @(Get-ChildItem -LiteralPath $StagingDirectory -Force -ErrorAction Stop).Count -eq 0
    $MarkedRoot = $null
    if (Test-Path -LiteralPath $StagingMarkerPath -PathType Leaf)
    {
        try
        {
            $MarkerData = Get-Content -LiteralPath $StagingMarkerPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $MarkedRoot = [string]$MarkerData['InventoryRoot']
        }
        catch { $MarkerData = $null; $MarkedRoot = $null }
    }
    $MarkedForThisRoot = $false
    if (-not [string]::IsNullOrEmpty($MarkedRoot))
    {
        try { $MarkedForThisRoot = [string]::Equals((ConvertTo-RevealComparablePath $MarkedRoot), $InventoryRoot, $PathComparison) }
        catch { $MarkedForThisRoot = $false }
    }
    if (-not $StagingIsEmpty -and -not $MarkedForThisRoot)
    {
        if ($Resume)
        {
            $Why = if ([string]::IsNullOrEmpty($MarkedRoot)) { 'it has no readable Reveal mark {2} (for example a staging folder made by an older Reveal, which did not write one)' } else { 'its Reveal mark {2} names another inventory root, {3}' }
            throw (("Cannot resume from {0}: it holds files and is not a Reveal staging folder for {1}: " + $Why + ". Point -StagingDirectory at the staging folder a reveal of {1} used, or run without -Resume to start a new reveal into a new or empty folder.") -f $StagingDirectory, $InventoryRoot, $StagingMarkerPath, $MarkedRoot)
        }
        throw ("The staging folder {0} already holds files and is not a Reveal staging folder for {1}. Its files could be stale or unrelated reports, so Reveal will not use it. Use a new or empty folder for -StagingDirectory." -f $StagingDirectory, $InventoryRoot)
    }
    if (-not $Resume -and $MarkedForThisRoot)
    {
        # Reveal's own folder from an earlier run, still holding its files. A
        # fresh run into it would mix with them (and -RemoveStaging would then
        # leave the earlier files without their mark, so the folder could not
        # be resumed or reused). Say plainly what to do instead.
        $Held = @(Get-ChildItem -LiteralPath $StagingDirectory -Force -ErrorAction Stop |
                Where-Object { $_.Name -ne $StagingMarkerName -and $_.Name -ne ($StagingMarkerName + '.tmp') })
        if ($Held.Count -gt 0)
        {
            throw ("The staging folder {0} holds {1} item(s) from an earlier reveal of {2}. Pass -Resume to continue that reveal (its finished reports are checked and kept), or use a new or empty folder for -StagingDirectory." -f $StagingDirectory, $Held.Count, $InventoryRoot)
        }
    }
    if ($Resume -and $MarkedForThisRoot)
    {
        # A resumed run must reveal the same fields as the run it continues, or
        # one bundle would mix reports revealed for different fields.
        $MarkedFields = $MarkerData['Fields']
        if ($null -eq $MarkedFields)
        {
            throw ("Cannot resume from {0}: its Reveal mark {1} does not record which fields that reveal used (it was made by an older Reveal), so the resumed bundle could mix reports revealed for different fields. Run without -Resume into a new or empty folder." -f $StagingDirectory, $StagingMarkerPath)
        }
        $MarkedFieldsKey = (@($MarkedFields | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join ', ')
        if ($MarkedFieldsKey -cne $FieldsKey)
        {
            throw ("Cannot resume from {0}: the reveal recorded in {1} used the fields [{2}], but this run asks for [{3}]. Run -Resume again with the same -Fields (or -All), or run without -Resume into a new or empty folder." -f $StagingDirectory, $StagingMarkerPath, $MarkedFieldsKey, $FieldsKey)
        }
        $RecordedOutputs = $MarkerData['Outputs']
        if ($RecordedOutputs -is [System.Collections.IDictionary])
        {
            foreach ($Name in @($RecordedOutputs.Keys)) { $StagingOutputs[[string]$Name] = $RecordedOutputs[$Name] }
        }
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

# The output zip must not live inside the staging directory, or it would be
# swept into itself on the final Compress-Archive.
# NB: Split-Path's -Parent switch is only valid with -Path, not -LiteralPath
# (the two are in different parameter sets), so -Path is required here.
$OutputZipParent = Split-Path -Path $OutputZip -Parent
if (-not [string]::IsNullOrEmpty($OutputZipParent) -and (Test-Path -LiteralPath $OutputZipParent -PathType Container))
{
    $OutputZipParent = (Resolve-Path -LiteralPath $OutputZipParent).Path
    if ($OutputZipParent -eq $StagingDirectory)
    {
        throw "-OutputZip must not be inside the staging directory ($StagingDirectory); it would be included in itself. Choose a path outside staging."
    }
}

Write-Host ("Inventory root : {0}" -f $InventoryRoot) -ForegroundColor Cyan
Write-Host ("Revealing      : {0}" -f ($Fields -join ', ')) -ForegroundColor Cyan
Write-Host ("Staging        : {0}" -f $StagingDirectory) -ForegroundColor Cyan
Write-Host ("Output zip     : {0}" -f $OutputZip) -ForegroundColor Cyan
Write-Host ""

$Folders = @(Get-ChildItem -LiteralPath $InventoryRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $StagingDirectory })

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

# Find the reports to reveal, handling the cheap cases synchronously (missing
# pair -> skip; already revealed under -Resume -> skip). Everything that needs
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
#    report with no such dictionary is skipped;
#  - for each subscription (read from the real subscription ids in its
#    dictionary) only the NEWEST report is revealed. Shipping an older run's
#    report too would put the same resources in the bundle twice under
#    different tokens, and downstream would count them twice. The older ones
#    are listed in the summary as left out.
# A report whose dictionary names no subscription (a subscription with no
# resources has an empty dictionary) cannot be matched to one, so it is
# revealed on its own; it carries no resources or costs to count twice.
$Candidates = [System.Collections.Generic.List[object]]::new()
foreach ($Folder in $Folders)
{
    # The obfuscated per-sub reports, excluding any *_revealed.zip or
    # *.partial.zip left by a prior run.
    $Zips = @(Get-ChildItem -LiteralPath $Folder.FullName -Filter 'ResourcesReport_*.zip' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*_revealed.zip' -and $_.Name -notlike '*.partial.zip' } |
            Sort-Object Name)
    $Dicts = @(Get-ChildItem -LiteralPath $Folder.FullName -Filter 'ObfuscationDictionary_*.json' -File -ErrorAction SilentlyContinue)

    if ($Zips.Count -eq 0 -or $Dicts.Count -eq 0)
    {
        $Reason = if ($Zips.Count -eq 0) { 'no obfuscated report zip in folder' } else { 'no obfuscation dictionary in folder' }
        $SkippedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = $Reason }
        continue
    }

    foreach ($Zip in $Zips)
    {
        # ResourcesReport_<stamp>.zip pairs with
        # ObfuscationDictionary_ResourcesReport_<stamp>.json (or the short
        # ObfuscationDictionary_<stamp>.json), and with nothing else.
        $Stamp = $Zip.BaseName.Substring('ResourcesReport_'.Length)
        $DictNames = @(('ObfuscationDictionary_' + $Zip.BaseName + '.json'), ('ObfuscationDictionary_' + $Stamp + '.json'))
        $Matched = @($Dicts | Where-Object { $Name = $_.Name; @($DictNames | Where-Object { [string]::Equals($_, $Name, $PathComparison) }).Count -gt 0 })
        if ($Matched.Count -ne 1)
        {
            $Reason = if ($Matched.Count -eq 0) { "no dictionary with the same stamp ($($DictNames[0]))" } else { 'more than one dictionary with the same stamp' }
            $SkippedItems += [pscustomobject]@{ Folder = ('{0}/{1}' -f $Folder.Name, $Zip.Name); Reason = $Reason }
            continue
        }
        $Dict = $Matched[0]

        # The subscription: the real subscription ids in the dictionary's
        # SubscriptionMap (token -> the real id of a resource of that
        # subscription).
        $SubIds = @()
        try
        {
            $DictJson = Get-Content -LiteralPath $Dict.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $DictJson.SubscriptionMap)
            {
                foreach ($Property in $DictJson.SubscriptionMap.PSObject.Properties)
                {
                    $SubId = Get-SubGuidFromResourceId ([string]$Property.Value)
                    if (-not [string]::IsNullOrEmpty($SubId)) { $SubIds += $SubId.ToLowerInvariant() }
                }
            }
        }
        catch
        {
            $FailedItems += [pscustomobject]@{ Folder = $Folder.Name; Reason = ('the dictionary {0} could not be read: {1}' -f $Dict.Name, $_.Exception.Message) }
            continue
        }
        $SubIds = @($SubIds | Sort-Object -Unique)
        $Key = if ($SubIds.Count -gt 0) { 'subscription:' + ($SubIds -join ',') } else { 'report:' + $Zip.FullName }
        # Newest first: by the stamp's date and time (yyyyMMddHHmmssfff), else
        # by the zip's write time in the same form.
        $Order = if ($Stamp -match '^(\d{17})') { $Matches[1] } else { $Zip.LastWriteTime.ToString('yyyyMMddHHmmssfff', [System.Globalization.CultureInfo]::InvariantCulture) }
        $Candidates.Add([pscustomobject]@{ Folder = $Folder.Name; Zip = $Zip; Dict = $Dict; Key = $Key; Order = $Order })
    }
}

$LeftOutItems = @()
$Selected = [System.Collections.Generic.List[object]]::new()
foreach ($Group in ($Candidates | Group-Object -Property Key))
{
    $Newest = @($Group.Group | Sort-Object -Property @{ Expression = 'Order'; Descending = $true }, @{ Expression = { $_.Zip.FullName }; Descending = $true })
    $Selected.Add($Newest[0])
    foreach ($Older in @($Newest | Select-Object -Skip 1))
    {
        $LeftOutItems += [pscustomobject]@{ Report = ('{0}/{1}' -f $Older.Folder, $Older.Zip.Name); Newer = ('{0}/{1}' -f $Newest[0].Folder, $Newest[0].Zip.Name) }
    }
}

$Queue = [System.Collections.Generic.Queue[object]]::new()
$UsedOutNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Candidate in @($Selected | Sort-Object -Property Folder, @{ Expression = { $_.Zip.Name } }))
{
    $Folder = $Candidate.Folder
    $Zip = $Candidate.Zip
    $Dict = $Candidate.Dict
    $PairedCount++

    # Write the revealed copy straight into staging under the ORIGINAL zip name
    # so the consolidated outer zip matches the structure the ingestion server
    # expects from a normal multi-subscription run.
    $OutName = $Zip.Name
    if (-not $UsedOutNames.Add($OutName))
    {
        # Two selected reports with the same file name (stamps are unique, so
        # only a copied folder does this): never let one overwrite the other.
        $OutName = $Folder + '_' + $Zip.Name
        $null = $UsedOutNames.Add($OutName)
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
        $Job = Start-Job -ScriptBlock {
            param($RevealFunctions, $InputZip, $DictionaryPath, $Fields, $OutputZip)
            . $RevealFunctions
            Invoke-RdaRevealFolder -InputZip $InputZip -DictionaryPath $DictionaryPath -Fields $Fields -OutputZip $OutputZip *> $null
        } -ArgumentList $RevealFunctions, $Item.Zip, $Item.Dict, $Fields, $Item.OutPath
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
                    $FailedItems += [pscustomobject]@{ Folder = $R.Item.Folder; Reason = 'reveal completed but produced no output zip' }
                }
            }
            catch
            {
                # Drop any partial/truncated output so it is neither consolidated
                # nor treated as done by a later -Resume.
                Remove-Item -LiteralPath $R.Item.OutPath -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (($R.Item.OutPath -replace '\.zip$', '') + '.partial.zip') -Force -ErrorAction SilentlyContinue
                $FailedItems += [pscustomobject]@{ Folder = $R.Item.Folder; Reason = $_.Exception.Message }
            }
            Remove-Job -Job $R.Job -Force -ErrorAction SilentlyContinue
            $DoneCount++
        }
        elseif ([DateTime]::UtcNow -ge $R.Deadline)
        {
            # Exceeded this folder's cap. Kill the child so it cannot hold a slot,
            # clean any partial output, record the timeout, free the slot.
            Stop-Job -Job $R.Job -ErrorAction SilentlyContinue
            Remove-Job -Job $R.Job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $R.Item.OutPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (($R.Item.OutPath -replace '\.zip$', '') + '.partial.zip') -Force -ErrorAction SilentlyContinue
            $FailedItems += [pscustomobject]@{ Folder = $R.Item.Folder; Reason = ("timed out after {0:0.##} minutes" -f ($RevealTimeoutSeconds / 60)) }
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
        # -LiteralPath (not -Path): staged names are taken verbatim. -Path treats
        # each value as a wildcard, so a report name containing '[' or ']' would
        # silently fail to match and abort the archive.
        # -DestinationPath has no literal form and also reads '[' and ']' as a
        # wildcard, so an inventory root 'Reports[1]' would write the outer zip
        # into a neighbour 'Reports1'. Escape it so it is taken as written.
        Compress-Archive -LiteralPath $StagedZips.FullName -DestinationPath ([WildcardPattern]::Escape($OutputZip)) -Force
    }
    catch
    {
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
Write-Host ("Skipped (missing zip or dict)    : {0}" -f $SkippedItems.Count) -ForegroundColor $(if ($SkippedItems.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("Left out (older, same sub)       : {0}" -f $LeftOutItems.Count) -ForegroundColor $(if ($LeftOutItems.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("Failed during reveal             : {0}" -f $FailedItems.Count) -ForegroundColor $(if ($FailedItems.Count -gt 0) { 'Red' } else { 'Green' })

foreach ($s in $SkippedItems)
{
    Write-Host ("  SKIP: {0} - {1}" -f $s.Folder, $s.Reason) -ForegroundColor Yellow
}
foreach ($o in $LeftOutItems)
{
    Write-Host ("  OLDER: {0} - left out: {1} is a newer report of the same subscription" -f $o.Report, $o.Newer) -ForegroundColor Yellow
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
        # record, for example an older report of a subscription that this run
        # left out), their partial files and the staging mark. Anything else
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
    # Name each cause: failed folders, the outer zip, or both.
    if ($FailedItems.Count -gt 0)
    {
        Write-Host ("-RemoveStaging skipped: {0} folder(s) failed or timed out. Staging kept so you can recover them with -Resume:" -f $FailedItems.Count) -ForegroundColor Yellow
    }
    if ($null -ne $ConsolidationError)
    {
        Write-Host "-RemoveStaging skipped: the outer zip could not be built (see above). Staging kept so you can re-run, or zip the revealed reports by hand:" -ForegroundColor Yellow
    }
    Write-Host ("  {0}" -f $StagingDirectory) -ForegroundColor Yellow
}
else
{
    Write-Host ("Individual revealed zips kept in: {0}" -f $StagingDirectory) -ForegroundColor DarkGray
}

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
