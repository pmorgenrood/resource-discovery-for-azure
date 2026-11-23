#Requires -Version 7.0
<#
.SYNOPSIS
    Mask a finished plain (not -Obfuscate) report offline, the way a live
    -Obfuscate run masks it: no Azure sign-in and no collection.

.DESCRIPTION
    Reads a plain report - the consolidated AllSubscriptions_ResourcesReport_*.zip
    of Run-AllSubscriptions.ps1, one ResourcesReport_*.zip, or a folder that holds
    ResourcesReport_*.zip files - and writes the masked report and its obfuscation
    dictionaries to a new folder, laid out as a -Obfuscate run lays out its
    inventory folder:

        <OutputDirectory>/AllSubscriptions_ResourcesReport_<stamp>.zip   (share this)
        <OutputDirectory>/ResourcesReport<stamp>/ResourcesReport_<stamp>.zip
        <OutputDirectory>/ResourcesReport<stamp>/ObfuscationDictionary_ResourcesReport_<stamp>.json  (keep local)

    Each report is masked with the live run's own functions (token loop, row,
    metric and consumption masking, dictionary), loaded from ResourceInventory.ps1
    and Extension/Metrics.ps1, so ids, names, links, file names and the zip layout
    are those of a -Obfuscate run. As in a -Obfuscate run, each report gets its own
    tokens and its own dictionary, and the tokens differ from run to run.
    Reveal.ps1 -InventoryRoot <OutputDirectory> maps the masked report back.

    It refuses (exit 1, nothing left behind) a report that is already masked, a
    file it cannot read whole, a file it does not know, and any output that still
    holds a real name or id.

.PARAMETER Path
    The plain report: a consolidated zip, one report zip, or a folder holding
    report zips (an unzipped consolidated zip).

.PARAMETER OutputDirectory
    A new or empty folder for the masked report. Default: next to -Path,
    named <name of -Path>_masked.

.EXAMPLE
    ./Protect-RdaReport.ps1 -Path ~/InventoryReports/AllSubscriptions_ResourcesReport_2026-11-13_08-00-00.zip
#>
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

foreach ($F in 'Functions/Common.Functions.ps1', 'Functions/ResourceInventory.Functions.ps1', 'Functions/InventoryJson.Functions.ps1', 'Functions/AllSubHtmlSummary.Functions.ps1', 'Functions/RunAllSubscriptions.Functions.ps1', 'Functions/CsvHeader.Functions.ps1', 'Functions/IdText.Functions.ps1', 'Functions/OfflineObfuscation.Functions.ps1')
{
    $FPath = Join-Path $PSScriptRoot $F
    if (-not (Test-Path -LiteralPath $FPath -PathType Leaf)) { Write-Host ("ERROR: required file not found: {0}" -f $FPath) -ForegroundColor Red; exit 2 }
    . $FPath
}
foreach ($Block in (Get-RdaLiveMaskFunction -RepoRoot $PSScriptRoot)) { . $Block }
# What a run of this code writes: anything else in the plain report is refused.
$Shape = Get-RdaReportShape -RepoRoot $PSScriptRoot
Initialize-RdaOfflineType
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# A stop: the message (never a real value), then exit 1 with nothing written.
function Stop-RdaOfflineMask
{
    param([string]$Message)
    $Stop = [System.InvalidOperationException]::new($Message)
    # Marked, so only this script's own stops print their text (another error's text can quote data).
    $Stop.Data['RdaOfflineStop'] = $true
    throw $Stop
}

# --- Input ------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path)) { Write-Host ("ERROR: -Path not found: {0}" -f $Path) -ForegroundColor Red; exit 2 }
$InputItem = Get-Item -LiteralPath $Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory))
{
    $Base = if ($InputItem.PSIsContainer) { $InputItem.Name } else { [IO.Path]::GetFileNameWithoutExtension($InputItem.Name) }
    $Parent = if ($InputItem.PSIsContainer) { $InputItem.Parent.FullName } else { $InputItem.DirectoryName }
    $OutputDirectory = Join-Path $Parent ($Base + '_masked')
}
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
# A folder given as -Path is copied whole, so the output cannot be inside it.
if ($InputItem.PSIsContainer)
{
    # Compared where the paths really are, links and junctions followed, in any case on the
    # file systems that ignore case (Windows, and macOS by default).
    # shortcut: a Windows 8.3 short name (PROGRA~1) is not expanded; upgrade with GetLongPathName if needed.
    try
    {
        $InFull = (Resolve-RdaRealPath $InputItem.FullName).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $OutFull = (Resolve-RdaRealPath $OutputDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    }
    catch
    {
        $Why = if ($_.Exception.Message -eq 'a path holds too many links') { 'goes through too many links' } else { 'cannot be resolved' }
        Write-Host ('ERROR: -Path or -OutputDirectory {0}. Give a plain folder.' -f $Why) -ForegroundColor Red
        exit 2
    }
    $Compare = if ($IsWindows -or $IsMacOS) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($OutFull.StartsWith($InFull, $Compare) -or $InFull.StartsWith($OutFull, $Compare))
    {
        Write-Host 'ERROR: -OutputDirectory is inside -Path, or -Path inside it. Give an output folder outside the report folder.' -ForegroundColor Red
        exit 2
    }
}
$OutFullPath = [IO.Path]::GetFullPath($OutputDirectory)
$Seps = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if ($OutFullPath.TrimEnd($Seps) -eq ([string][IO.Path]::GetPathRoot($OutFullPath)).TrimEnd($Seps)) { Write-Host 'ERROR: -OutputDirectory is a drive or file system root. Give a folder.' -ForegroundColor Red; exit 2 }
$OutParent = [IO.Path]::GetDirectoryName($OutFullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
if ((Test-Path -LiteralPath $OutputDirectory) -and @(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0)
{
    Write-Host ("ERROR: -OutputDirectory is not empty: {0}. Give a new or empty folder." -f $OutputDirectory) -ForegroundColor Red
    exit 2
}
$CreatedOutput = -not (Test-Path -LiteralPath $OutputDirectory)
$Published = [System.Collections.Generic.List[string]]::new()
# The plain copies are unpacked beside the output folder, never inside it: a mask
# that is killed leaves no plain file in the folder to be shared.
$Work = Join-Path $OutParent ((Split-Path -Path $OutputDirectory -Leaf) + '.rda-work-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
# Everything is written here first and moved to -OutputDirectory only once the last
# check has passed, so a mask that stops part-way, even killed, leaves nothing to share.
$WorkOut = Join-Path $Work 'out'

# A failure until the last check passes: a stop the catch never sees (Ctrl+C) still
# removes what was written.
$ExitCode = 1
# The run's masking reads and fills these globals; they hold real values while the
# mask runs, so the caller's own values are put back at the end, in any case.
$GlobalNames = 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'TagValueDictionary', 'FreeTextDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'ObfuscationSubscriptionIndex', 'Subscriptions', 'CollectorFailures', 'MetricsFailedSubs', 'ConsumptionFailedSubs'
$SavedGlobals = @{}
foreach ($G in $GlobalNames) { $SavedGlobals[$G] = Get-Variable -Name $G -Scope Global -ValueOnly -ErrorAction SilentlyContinue }
try
{
    # Made inside the guarded region: a failure to make any of them still removes what was made.
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $Work -Force | Out-Null
    New-Item -ItemType Directory -Path $WorkOut -Force | Out-Null
    # The plain report's members: its report zips and the consolidated zip's extras.
    $InStage = Join-Path $Work 'in'
    New-Item -ItemType Directory -Path $InStage -Force | Out-Null
    $OuterName = $null
    if ($InputItem.PSIsContainer)
    {
        Copy-Item -Path (Join-Path ([WildcardPattern]::Escape($InputItem.FullName)) '*') -Destination $InStage -Recurse -Force
        # An unzipped consolidated zip: zipped again as a run names one.
        $OuterName = ''
    }
    else
    {
        if (@([RdaZipCheck]::BadMembers($InputItem.FullName)).Count -gt 0) { Stop-RdaOfflineMask 'A file in -Path is cut off or damaged (it does not match the size and CRC the zip recorded). Nothing was written.' }
        $Probe = [System.IO.Compression.ZipFile]::OpenRead($InputItem.FullName)
        try { $Names = @($Probe.Entries | ForEach-Object { $_.FullName }) } finally { $Probe.Dispose() }
        $InvMember = @($Names | Where-Object { $_ -like 'Inventory_*.json' })
        if ($InvMember.Count -gt 0)
        {
            # One report zip: named as a run names it, whatever it was renamed to; only a
            # stamp of the form a run writes is taken (no path can be made of it).
            if ($InvMember[0] -cnotmatch '^Inventory_ResourcesReport_(\d{14}(?:\d{3})?(?:[0-9a-f]{4})?)\.json$') { Stop-RdaOfflineMask 'The report''s inventory file is not named as a run names one. Nothing was written.' }
            Copy-Item -LiteralPath $InputItem.FullName -Destination (Join-Path $InStage ('ResourcesReport_{0}.zip' -f $Matches[1]))
        }
        else
        {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($InputItem.FullName, $InStage)
            $OuterName = $InputItem.Name
        }
    }
    # The consolidated zip keeps its name only when it is the name a run gives one: a
    # name someone gave it can hold real text, and the name is shared with the zip.
    if ($null -ne $OuterName -and $OuterName -cnotmatch '^AllSubscriptions_ResourcesReport_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.zip$')
    {
        $OuterName = 'AllSubscriptions_ResourcesReport_{0}.zip' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    }
    $ReportZips = @(Get-ChildItem -LiteralPath $InStage -Filter 'ResourcesReport_*.zip' -File | Sort-Object Name)
    if ($ReportZips.Count -eq 0) { Stop-RdaOfflineMask 'No ResourcesReport_*.zip report was found in -Path.' }
    # Each report's page sits in the folder the wrapper names after its stamp; no other page is known.
    $KnownOuter = @($ReportZips | ForEach-Object { $_.Name; ($_.Name -replace '^ResourcesReport_(.+)\.zip$', 'HTML$1/ResourcesReport_$1.html') }) + @('RunSummary.log', 'MainSummary.html')
    # Names are matched case for case: a run writes them so, and files are found by them.
    foreach ($Member in @(Get-ChildItem -LiteralPath $InStage -Recurse -File -Force))
    {
        $Rel = [IO.Path]::GetRelativePath($InStage, $Member.FullName) -replace '\\', '/'
        if ($KnownOuter -ccontains $Rel) { continue }
        Stop-RdaOfflineMask 'The report holds a file this script does not know how to mask (its name is not printed: it can hold real text). Nothing was written.'
    }

    # Every text file is read as UTF-8 as it is: a byte that is not valid UTF-8 would be read as U+FFFD and
    # written on as that, so the report is refused, not rewritten (a run writes valid UTF-8 only).
    $CheckUtf8 = {
        param([string]$Dir, [string]$Name)
        foreach ($File in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force | Where-Object { $_.Extension -ne '.zip' }))
        {
            if (-not (Test-RdaStrictUtf8File -Path $File.FullName)) { Stop-RdaOfflineMask ("{0} holds text that is not valid UTF-8 (a file name is not printed: it can hold real text). Nothing was written." -f $Name) }
        }
    }
    & $CheckUtf8 $InStage 'The report'

    $PlainRunSummary = Join-Path $InStage 'RunSummary.log'
    $HasRunSummary = Test-Path -LiteralPath $PlainRunSummary
    if ($HasRunSummary -and ((Get-Content -LiteralPath $PlainRunSummary -TotalCount 3) -match '^Obfuscated run')) { Stop-RdaOfflineMask 'The report is already masked (its RunSummary.log says it is an obfuscated run). Nothing was written.' }

    $ExtraReal = [System.Collections.Generic.List[string]]::new()
    # A GUID on a plain report page or log (the tenant's, a subscription's) is a real id,
    # one every report's checks look for (OuterReal), not only the first's.
    $OuterReal = [System.Collections.Generic.List[string]]::new()
    foreach ($Page in @(Get-ChildItem -LiteralPath $InStage -Recurse -File -Force | Where-Object { $_.Extension -in '.html', '.log' }))
    {
        foreach ($M in [regex]::Matches([System.IO.File]::ReadAllText($Page.FullName), '(?i)(?<![0-9a-f-])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f-])')) { $OuterReal.Add($M.Value) }
    }
    $ExtraReal.AddRange($OuterReal)
    $AllRealValues = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($V in $OuterReal) { [void]$AllRealValues.Add($V) }
    # The values the plain report holds in fields neither a run nor this script masks
    # (Test-RdaMaskedOutputLeak -Exempt): Azure's own words there, such as a location or a SKU.
    $Exempt = $null
    $Scans = [System.Collections.Generic.List[object]]::new()
    $ReportExempt = @{}
    $Unresolved = @{}
    # Per report: the consumption rows whose usage is not counted (see the row loop).
    $DroppedReport = [System.Collections.Generic.List[object]]::new()
    $SubFolders = [System.Collections.Generic.List[string]]::new()
    $PerReportFailures = [System.Collections.Generic.List[object]]::new()
    $Version = $null

    foreach ($ReportZip in $ReportZips)
    {
        # ResourcesReport_<stamp>.zip: report name ResourcesReport, run stamp <stamp>,
        # and the folder a run keeps it in, ResourcesReport<stamp>.
        # The stamp is the run's time and a process number (ResourceInventory.ps1,
        # $Global:CurrentDateTime), so a stamp of any other form is not printed or kept.
        if ($ReportZip.Name -cnotmatch '^(ResourcesReport)_(\d{14}(?:\d{3})?(?:[0-9a-f]{4})?)\.zip$') { Stop-RdaOfflineMask 'A report zip is not named as a run names one (ResourcesReport_<stamp>.zip). Nothing was written.' }
        $ReportName = $Matches[1]
        $Stamp = $Matches[2]
        if (@([RdaZipCheck]::BadMembers($ReportZip.FullName)).Count -gt 0) { Stop-RdaOfflineMask ("{0}: a file in it is cut off or damaged (it does not match the size and CRC the zip recorded). Nothing was written." -f $ReportZip.Name) }
        $Folder = $ReportName + $Stamp
        $In = Join-Path $Work ('r-' + $Stamp)
        $Out = Join-Path $WorkOut $Folder
        New-Item -ItemType Directory -Path $In, $Out -Force | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ReportZip.FullName, $In)
        foreach ($Page in @(Get-ChildItem -LiteralPath $In -File | Where-Object { $_.Extension -in '.html', '.log' }))
        {
            foreach ($M in [regex]::Matches([System.IO.File]::ReadAllText($Page.FullName), '(?i)(?<![0-9a-f-])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f-])')) { $ExtraReal.Add($M.Value) }
        }

        $Expected = @{
            Html        = "{0}_{1}.html" -f $ReportName, $Stamp
            Consumption = "Consumption_{0}_{1}.csv" -f $ReportName, $Stamp
            Diagnostics = "Diagnostics_{0}_{1}.log" -f $ReportName, $Stamp
            Inventory   = "Inventory_{0}_{1}.json" -f $ReportName, $Stamp
        }
        $MetricsFiles = @(Get-ChildItem -LiteralPath $In -File | Where-Object { $_.Name -cmatch ('^Metrics_{0}_{1}(__\d+)?\.json$' -f $ReportName, $Stamp) } | Sort-Object Name)
        foreach ($Member in @(Get-ChildItem -LiteralPath $In -Recurse -File -Force))
        {
            # A run's report zip holds its files at the top level only.
            if ($Member.DirectoryName -eq (Get-Item -LiteralPath $In).FullName -and ($Expected.Values -ccontains $Member.Name -or $MetricsFiles.Name -ccontains $Member.Name)) { continue }
            Stop-RdaOfflineMask ("{0} holds a file this script does not know how to mask (its name is not printed: it can hold real text). Nothing was written." -f $ReportZip.Name)
        }
        foreach ($Need in 'Inventory', 'Consumption', 'Html')
        {
            if (-not (Test-Path -LiteralPath (Join-Path $In $Expected[$Need]))) { Stop-RdaOfflineMask ("{0} has no {1}. Nothing was written." -f $ReportZip.Name, $Expected[$Need]) }
        }
        # A run always writes a metrics file ({"Metrics":[]} when it has none, -SkipMetrics too).
        if ($MetricsFiles.Count -eq 0) { Stop-RdaOfflineMask ("{0} has no metrics file, which every run writes. Nothing was written." -f $ReportZip.Name) }

        & $CheckUtf8 $In $ReportZip.Name

        # The values this report holds in fields no one masks (its own, so one report's
        # Azure words never hide another report's real values).
        $Exempt = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        # A fresh token space per report, as each subscription's run has its own,
        # built as a run's Variables builds it (ids keyed ignoring case).
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:TagValueDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ObfuscationSubscriptionTokens = @{}
        $Global:ObfuscationResourceGroupTokens = @{}
        $Global:ObfuscationSubscriptionIndex = $null
        # New-ObfuscatedRowIdWithoutId's per-run state, reset as a run's Variables resets it.
        $script:RdaNoIdRowsSeen = $null
        $script:RdaNoIdNameIndex = $null
        $Global:CollectorFailures = @()
        $Global:MetricsFailedSubs = @()
        $Global:ConsumptionFailedSubs = @()

        # --- Read the plain inventory and metrics, whole or not at all --------
        try
        {
            $Inventory = ConvertFrom-RdaJsonText -Text ([System.IO.File]::ReadAllText((Join-Path $In $Expected.Inventory), [System.Text.UTF8Encoding]::new($false))) -OrderedRoot
            foreach ($Key in @($Inventory.Keys))
            {
                $Value = $Inventory[$Key]
                if ($Key -cne 'Version' -and $null -ne $Value -and -not ($Value -is [array] -and @($Value | Where-Object { $_ -isnot [hashtable] }).Count -eq 0)) { throw 'a section is not a list of records' }
            }
        }
        catch
        {
            # The parser's own text can quote the file, so it is not printed.
            Stop-RdaOfflineMask ("{0}: the inventory file cannot be read whole, or is not the shape a run writes. Nothing was written." -f $ReportZip.Name)
        }
        # Each report's pages show the version that wrote it (a continued run can carry older reports).
        $ReportVersion = if ($Inventory.Contains('Version')) { $Inventory['Version'] } else { $null }
        # The tool version is Version.json's three numbers (GetLocalVersion), which a run always writes.
        if ($ReportVersion -isnot [string] -or $ReportVersion -cnotmatch '^\d+\.\d+\.\d+\z') { Stop-RdaOfflineMask ("{0}: the inventory names a tool version a run does not write. Nothing was written." -f $ReportZip.Name) }
        if ($null -eq $Version) { $Version = $ReportVersion }
        $Rows = @{}
        foreach ($Key in @($Inventory.Keys)) { if ($Key -cne 'Version' -and $null -ne $Inventory[$Key]) { $Rows[$Key] = $Inventory[$Key] } }
        if (Test-RdaReportMasked -Inventory $Rows) { Stop-RdaOfflineMask ("{0} is already masked (its inventory holds masked ids or names). Nothing was written." -f $ReportZip.Name) }
        # Every top-level key is a collector's section (an empty one too) or Version.
        if (@($Inventory.Keys | Where-Object { $_ -cne 'Version' -and -not $Shape.Sections.ContainsKey($_) }).Count -gt 0) { Stop-RdaOfflineMask ("{0}: the inventory holds a section no collector writes, so it cannot be masked as a run masks it. Nothing was written." -f $ReportZip.Name) }
        $UnknownShape = Get-RdaUnknownInventoryShape -Rows $Rows -Shape $Shape
        if ($null -ne $UnknownShape) { Stop-RdaOfflineMask ("{0}: the inventory holds {1}, so it cannot be masked as a run masks it. Nothing was written." -f $ReportZip.Name, $UnknownShape) }

        $Metrics = [ordered]@{}
        foreach ($MF in $MetricsFiles)
        {
            try
            {
                $MObj = Read-RdaJsonFile -Path $MF.FullName
                if ($MObj -isnot [hashtable] -or @($MObj.Keys) -cnotcontains 'Metrics' -or $MObj.Count -ne 1 -or $MObj['Metrics'] -isnot [array]) { throw 'not an object with a Metrics list' }
                foreach ($Rec in @($MObj['Metrics'])) { if (-not (Test-RdaMetricRecordShape -Record $Rec -Shape $Shape)) { throw 'a record a run does not write' } }
                $Metrics[$MF.Name] = $MObj
            }
            catch
            {
                Stop-RdaOfflineMask ("{0}: {1} cannot be read whole, or is not the shape a run writes. Nothing was written." -f $ReportZip.Name, $MF.Name)
            }
            foreach ($Rec in @($MObj['Metrics'])) { if ($Rec -is [hashtable] -and ([string]$Rec['ID'] -match $(Get-RdaTokenRegex))) { Stop-RdaOfflineMask ("{0} is already masked (its metrics hold masked ids). Nothing was written." -f $ReportZip.Name) } }
        }

        # The plain diagnostics log, read back into what the run had: phase times and
        # failures (written again below as a -Obfuscate run writes the log).
        $PhaseTimings = [ordered]@{}
        $Parsed = $null
        $DiagIn = Join-Path $In $Expected.Diagnostics
        if (Test-Path -LiteralPath $DiagIn)
        {
            try { $Parsed = ConvertFrom-RdaDiagnosticsText -Lines (Get-Content -LiteralPath $DiagIn) -ReportFolder $Folder }
            catch { Stop-RdaOfflineMask ("{0}: the diagnostics log is cut off or not as a run writes it. Nothing was written." -f $ReportZip.Name) }
            if ($Parsed.Obfuscated) { Stop-RdaOfflineMask ("{0} is already masked (its diagnostics log says it is an obfuscated run). Nothing was written." -f $ReportZip.Name) }
            $PhaseTimings = $Parsed.PhaseTimings
            # One run writes one version into its inventory and its log.
            if ($Parsed.Version -cne $ReportVersion) { Stop-RdaOfflineMask ("{0}: the diagnostics log and the inventory name different tool versions. Nothing was written." -f $ReportZip.Name) }
            # The log prints phase and collector names as given: only names this code writes are copied on.
            if (@($PhaseTimings.Keys | Where-Object { $Shape.PhaseNames -cnotcontains $_ }).Count -gt 0 -or @($Parsed.CollectorFailures | Where-Object { -not $Shape.Sections.ContainsKey([string]$_.Module) }).Count -gt 0)
            {
                Stop-RdaOfflineMask ("{0}: the diagnostics log names a phase or collector this code does not have. Nothing was written." -f $ReportZip.Name)
            }
        }
        # This run's failed collectors are the ones its page names (Summary.ps1's banner is
        # given this run's failures only). The diagnostics log is not used for this: a
        # stream worker's log also lists collectors that failed for an earlier subscription.
        $PageText = [System.IO.File]::ReadAllText((Join-Path $In $Expected.Html))
        try { $FailedCollectors = @(Get-RdaPageFailedCollector -Html $PageText) }
        catch { Stop-RdaOfflineMask ("{0}: the report page is cut off or not as a run writes it. Nothing was written." -f $ReportZip.Name) }
        if (@($FailedCollectors | Where-Object { $_ -ne '(unnamed collector)' -and -not $Shape.Sections.ContainsKey($_) }).Count -gt 0) { Stop-RdaOfflineMask ("{0}: the report page names a collector this code does not have. Nothing was written." -f $ReportZip.Name) }

        # --- The run's subscriptions and resource rows, as the pull gave them ---
        $SubNames = [ordered]@{}
        $IdSub = { param($Id) if ([string]$Id -match '^/subscriptions/([^/]+)') { $Matches[1] } else { $null } }
        foreach ($Section in $Rows.Keys)
        {
            foreach ($Row in $Rows[$Section])
            {
                $SubId = & $IdSub $Row['ID']
                if ($null -ne $SubId -and -not $SubNames.Contains($SubId) -and -not [string]::IsNullOrEmpty([string]$Row['Subscription'])) { $SubNames[$SubId] = [string]$Row['Subscription'] }
            }
        }
        foreach ($MObj in $Metrics.Values)
        {
            foreach ($Rec in @($MObj['Metrics']))
            {
                $SubId = & $IdSub $Rec['ID']
                if ($null -ne $SubId -and -not $SubNames.Contains($SubId) -and -not [string]::IsNullOrEmpty([string]$Rec['Subscription'])) { $SubNames[$SubId] = [string]$Rec['Subscription'] }
            }
        }
        # A report with no inventory or metric record (a subscription of only network
        # resources, for example) names its subscription on its page only: a run of one
        # subscription writes it there. Its usage rows then give the id.
        if ($SubNames.Count -eq 0)
        {
            $CsvSubs = @(Import-Csv -LiteralPath (Join-Path $In $Expected.Consumption) | ForEach-Object { & $IdSub $_.ResourceId } | Where-Object { $_ } | Select-Object -Unique)
            if ($PageText -match '<b>Subscription:</b> ([^<\r\n]+)' -and $CsvSubs.Count -eq 1)
            {
                $PageSub = [System.Net.WebUtility]::HtmlDecode($Matches[1].Trim())
                if ($PageSub -ne '(unknown)' -and $PageSub -notmatch '^\d+ subscriptions \(consolidated\)$') { $SubNames[$CsvSubs[0]] = $PageSub }
            }
        }
        $Global:Subscriptions = @($SubNames.Keys | ForEach-Object { [pscustomobject]@{ id = $_; name = $SubNames[$_] } })
        $InScope = @($SubNames.Keys)
        # A row or metric record whose subscription the report does not name (no display name
        # anywhere) would get no token from the run's token loop, so its id would be masked as a
        # flat token, not an Azure-shaped one: refused, not guessed.
        foreach ($Rec in @(foreach ($Section in $Rows.Keys) { $Rows[$Section] }) + @(foreach ($MObj in $Metrics.Values) { @($MObj['Metrics']) | Where-Object { $_ -is [hashtable] } }))
        {
            $SubId = & $IdSub $Rec['ID']
            if ($null -ne $SubId -and -not $SubNames.Contains($SubId)) { Stop-RdaOfflineMask ("{0}: a record is of a subscription the report does not name, so its masked id could not keep its shape. Nothing was written." -f $ReportZip.Name) }
        }

        # Every id the pull held that this report shows: each inventory row's own id
        # (with its Resource Graph name and group) and each metric record's id
        # (metrics are asked for pulled resources only), in one of the run's
        # subscriptions. An id a field only points at is not added: the report
        # cannot tell whether the pull held it (a deleted disk, a resource of a type
        # no collector reports), so such a reference is written 'obfuscated', as a
        # run writes an id it does not know. Any other id is left to the code that
        # masks an id the pull did not hold, as in a run.
        $TokenRows = [System.Collections.Generic.List[object]]::new()
        $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $AddTokenRow = {
            # $Group is not typed: [string] would turn $null (take the id's group) into ''.
            param([string]$Id, [string]$Name, $Group)
            # The id as the pull gave it: lower case, or as Azure wrote it when the pull kept a
            # row whose lower-cased text does not parse; the run's token loop takes it so too.
            if ([string]::IsNullOrEmpty($Id) -or -not $Seen.Add($Id)) { return }
            $Parts = $Id.Split('/')
            if ($Parts.Count -lt 3 -or $Parts[1] -ne 'subscriptions' -or $InScope -notcontains $Parts[2]) { return }
            if ([string]::IsNullOrEmpty($Name)) { $Name = $Parts[-1] }
            if ([string]::IsNullOrEmpty($Group) -and $Parts.Count -gt 4 -and $Parts[3] -eq 'resourcegroups') { $Group = $Parts[4] }
            $TokenRows.Add([pscustomobject]@{ ID = $Id; name = $Name; subscriptionId = $Parts[2]; resourceGroup = $Group })
        }
        foreach ($Section in $Rows.Keys)
        {
            foreach ($Row in $Rows[$Section]) { & $AddTokenRow ([string]$Row['ID']) ([string]$Row['Name']) ([string]$Row['ResourceGroup']) }
        }
        $Rules = @(Get-RdaOfflineFieldRule)
        foreach ($Rule in $Rules)
        {
            if (-not $Rows.ContainsKey($Rule.Section)) { continue }
            foreach ($Row in $Rows[$Rule.Section])
            {
                if (-not $Row.ContainsKey($Rule.Field)) { continue }
                # An object masked part by part: its real parts are the free-text dictionary's,
                # which the checks below look for.
                if ($Rule.Kind -eq 'Walk') { continue }
                $V = [string]$Row[$Rule.Field]
                # The plain value a rule replaces must not be in the masked report.
                if ($V -notin @('', 'None', 'False', 'Unknown', 'obfuscated'))
                {
                    if ($Rule.Kind -eq 'WafList') { foreach ($W in (($V -replace ' \(\d+ of \d+ endpoints without WAF\)$', '') -split ', ')) { $ExtraReal.Add($W) } }
                    elseif ($Rule.Kind -ne 'Value' -or $V.Length -ge 5) { $ExtraReal.Add($V) }
                }
            }
        }
        foreach ($MObj in $Metrics.Values) { foreach ($Rec in @($MObj['Metrics'])) { if ($Rec -is [hashtable]) { & $AddTokenRow ([string]$Rec['ID']) $null $null } } }
        # Any full id in any field of the plain report, a field no rule masks too (an id no
        # row holds, a tenant-scope id too): its subscription, group and name parts are real
        # values the masked report must not hold (Get-RdaRealValueSet splits it), so the leak
        # scan finds it.
        # A Databricks workspace's managed group, masked by the row masking with no
        # field rule: its plain name must not be in the masked report either.
        if ($Rows.ContainsKey('Databricks')) { foreach ($Row in $Rows['Databricks']) { $V = [string]$Row['ManagedResourceGroup']; if ($V -notin @('', 'obfuscated')) { $ExtraReal.Add($V) } } }
        foreach ($Section in $Rows.Keys) { $ExtraReal.AddRange([string[]]@(Get-RdaFullIdInValue -Value $Rows[$Section])) }
        foreach ($MObj in $Metrics.Values) { $ExtraReal.AddRange([string[]]@(Get-RdaFullIdInValue -Value @($MObj['Metrics']))) }
        # A collector of the plain run that failed left out rows its pull held: the ids
        # that point at that collector's resources are taken as pulled, as the run had them.
        foreach ($Rule in @($Rules | Where-Object { $_.Target -and $FailedCollectors -contains $_.Target -and $Rows.ContainsKey($_.Section) }))
        {
            foreach ($Row in $Rows[$Rule.Section]) { if ($Row.ContainsKey($Rule.Field)) { & $AddTokenRow (Get-RdaReferencedId -Rule $Rule -Row $Row) $null $null } }
        }

        Add-RdaExemptValue -Rows $Rows -Metrics @($Metrics.Values) -Rules $Rules -Exempt $Exempt

        # --- Mask, in a run's order: tokens, metrics, collector rows, consumption ---
        Add-RdaObfuscationToken -Rows $TokenRows

        foreach ($MObj in $Metrics.Values)
        {
            $Recs = @($MObj['Metrics'] | Where-Object { $_ -is [hashtable] })
            Protect-RdaMetricRecord -Metrics $Recs -ResourceIdDictionary $Global:ResourceIdDictionary -ResourceNameDictionary $Global:ResourceNameDictionary -ResourceSubDictionary $Global:ResourceSubscriptionDictionary -ResourceGroupDictionary $Global:ResourceResourceGroupDictionary
        }

        $NameIndexes = @{}
        foreach ($Rule in $Rules)
        {
            if ($Rule.Kind -eq 'NameRef') { $NameIndexes[$Rule.Section + '.' + $Rule.Field] = New-RdaNameIndex -Inventory $Rows -Sections $Rule.Sections }
            if ($Rule.Kind -eq 'NameRef' -and $Rule.Also) { $NameIndexes[$Rule.Section + '.' + $Rule.Field + '.also'] = New-RdaNameIndex -Inventory $Rows -Sections $Rule.Also }
            if ($Rule.Kind -eq 'PublicIpRef') { $NameIndexes['PublicIP.AssociatedResource'] = New-RdaNameIndex -Inventory $Rows -Sections @('NATGAteway') }
        }
        foreach ($Section in @($Inventory.Keys))
        {
            if (-not $Rows.ContainsKey($Section)) { continue }
            $SectionRules = @($Rules | Where-Object { $_.Section -eq $Section })
            foreach ($Row in $Rows[$Section])
            {
                if ($SectionRules.Count -gt 0) { Protect-RdaOfflineField -Row $Row -Rules $SectionRules -NameIndexes $NameIndexes }
            }
            foreach ($Rule in @($SectionRules | Where-Object { $_.Kind -eq 'NameRef' }))
            {
                $Key = $Rule.Section + '.' + $Rule.Field
                $N = @($Rows[$Section] | Where-Object { $_[$Rule.Field] -eq 'obfuscated' }).Count
                if ($N -gt 0) { $Unresolved[$Key] = [int]$Unresolved[$Key] + $N }
            }
            # The section is the collector's name, which a run passes as the collector.
            Protect-RdaCollectorRow -Rows $Rows[$Section] -Collector $Section
        }

        # --- Check every masked slot before anything is written ------------------
        $RealNow = Get-RdaRealValueSet -ExtraValue $ExtraReal.ToArray()
        $SlotRules = @{}
        foreach ($Rule in $Rules) { if ($Rule.Kind -notin @('Value', 'WafList', 'Walk') -and -not $Rule.Within) { if (-not $SlotRules.ContainsKey($Rule.Section)) { $SlotRules[$Rule.Section] = @() }; $SlotRules[$Rule.Section] += $Rule.Field } }
        foreach ($Section in $Rows.Keys)
        {
            $Fields = @('ID', 'Name', 'ResourceGroup', 'Subscription', 'Tags') + @($SlotRules[$Section])
            $i = 0
            foreach ($Row in $Rows[$Section])
            {
                $Bad = @(Test-RdaMaskedSlot -Row $Row -Field $Fields -RealValue $RealNow)
                foreach ($Rule in @($Rules | Where-Object { $_.Section -eq $Section -and $_.Within })) { foreach ($Item in @($Row[$Rule.Within] | Where-Object { $_ -is [hashtable] })) { $Bad += @(Test-RdaMaskedSlot -Row $Item -Field $Rule.Field -RealValue $RealNow) } }
                foreach ($Rule in @($Rules | Where-Object { $_.Section -eq $Section -and $_.Kind -eq 'Walk' })) { if ($Row.ContainsKey($Rule.Field) -and -not (Test-RdaSitePropertiesMasked $Row[$Rule.Field])) { $Bad += $Rule.Field } }
                if ($Bad.Count -gt 0) { Stop-RdaOfflineMask ("{0}: section {1}, record {2}: field(s) {3} still hold a real value after masking. Nothing was written." -f $ReportZip.Name, $Section, $i, ($Bad -join ', ')) }
                $i++
            }
        }
        foreach ($MName in $Metrics.Keys)
        {
            $i = 0
            foreach ($Rec in @($Metrics[$MName]['Metrics'] | Where-Object { $_ -is [hashtable] }))
            {
                $Bad = @(Test-RdaMaskedSlot -Row $Rec -Field @('ID', 'Name', 'ResourceGroup', 'Subscription') -RealValue $RealNow)
                if ($Bad.Count -gt 0) { Stop-RdaOfflineMask ("{0}: {1}, record {2}: field(s) {3} still hold a real value after masking. Nothing was written." -f $ReportZip.Name, $MName, $i, ($Bad -join ', ')) }
                $i++
            }
        }

        # --- Write the masked inventory and metrics with the run's own writers ---
        $InvObject = [pscustomobject]$Inventory
        $InvOut = Join-Path $Out $Expected.Inventory
        Write-InventoryJson -InputObject $InvObject -Path $InvOut
        foreach ($MName in $Metrics.Keys)
        {
            [pscustomobject]@{ Metrics = @($Metrics[$MName]['Metrics']) } | ConvertTo-Json -Depth 5 -Compress | Out-File -LiteralPath (Join-Path $Out $MName) -Encoding utf8
        }

        # --- Consumption: each row through the run's row masking -----------------
        $CsvIn = Join-Path $In $Expected.Consumption
        $CsvOut = Join-Path $Out $Expected.Consumption
        $Header = Get-Content -LiteralPath $CsvIn -TotalCount 1
        if (@(Get-Content -LiteralPath $CsvIn -TotalCount 2).Count -lt 2)
        {
            # Header only: the run writes it as one plain line, which holds no value.
            if (($Header.TrimStart([char]0xFEFF)) -cne ($Shape.ConsumptionColumns -join ',')) { Stop-RdaOfflineMask ("{0}: the consumption file's columns are not the ones a run writes. Nothing was written." -f $ReportZip.Name) }
            Copy-Item -LiteralPath $CsvIn -Destination $CsvOut
        }
        else
        {
            # Each name as the header holds it, read as CSV (a name with a '"' written twice is
            # that name, not the one with the quotes taken out), and in the run's order.
            $Columns = ConvertFrom-RdaCsvHeaderLine ($Header.TrimStart([char]0xFEFF))
            if ($null -eq $Columns -or -not [System.Linq.Enumerable]::SequenceEqual([string[]]$Columns, [string[]]$Shape.ConsumptionColumns, [System.StringComparer]::Ordinal)) { Stop-RdaOfflineMask ("{0}: the consumption file's columns are not the ones a run writes. Nothing was written." -f $ReportZip.Name) }
            # Import-Csv drops a cell past the header's count, so each record's cells are counted first.
            Initialize-RdaOfflineType
            $BadRecord = [RdaCsvCheck]::FirstBadRecord($CsvIn, $Columns.Count)
            if ($BadRecord -gt 0) { Stop-RdaOfflineMask ("{0}: consumption row {1} is cut off, or holds more cells than the header names: it cannot be read. Nothing was written." -f $ReportZip.Name, $BadRecord) }
            # The cells a run wrote empty with no quotes (a null value), per record: Import-Csv
            # reads them as "", and they are given back as null so Export-Csv writes them as the
            # run did (offline = live, byte for byte).
            $BareCells = [RdaCsvCheck]::BareEmptyCells($CsvIn)
            $RowIndex = 0
            # Rows whose usage is not counted, by kind: { Row, Id } with the row's masked id.
            $NegativeRows = [System.Collections.Generic.List[object]]::new()
            $NoMeterRows = [System.Collections.Generic.List[object]]::new()
            $NoIdRows = [System.Collections.Generic.List[object]]::new()
            $TokenRegex = Get-RdaTokenRegex
            # Each plain id whose masked id was checked (see below), so an id is checked once.
            $UsageIdsChecked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            Import-Csv -LiteralPath $CsvIn | ForEach-Object {
                $RowIndex++
                if ($RowIndex % 250000 -eq 0) { Write-Host ("  {0}: {1} consumption rows masked" -f $ReportZip.Name, $RowIndex) }
                $UsageRow = $_
                try { $Instance = ConvertFrom-RdaJsonText -Text ([string]$UsageRow.InstanceData) -AsObject }
                catch { Stop-RdaOfflineMask ("{0}: consumption row {1} has an InstanceData value that cannot be read. Nothing was written." -f $ReportZip.Name, $RowIndex) }
                # Exactly the shape a run writes: Microsoft.Resources with ResourceUri, Location and additionalInfo.
                $Res = if ($Instance -is [pscustomobject]) { $Instance.PSObject.Properties['Microsoft.Resources'] } else { $null }
                $ResNames = if ($null -ne $Res -and $Res.Value -is [pscustomobject]) { @($Res.Value.PSObject.Properties.Name) } else { @() }
                # additionalInfo: main's 18 fields, in main's order, each text or a number.
                $Info = if ($ResNames -contains 'additionalInfo' -and $Res.Value.additionalInfo -is [pscustomobject]) { @($Res.Value.additionalInfo.PSObject.Properties) } else { @() }
                $InfoOk = (@($Info.Name) -join ',') -ceq ($Shape.InstanceInfo -join ',') -and @($Info | Where-Object { $_.Value -isnot [string] -and $_.Value -isnot [long] -and $_.Value -isnot [double] }).Count -eq 0
                if (@($Instance.PSObject.Properties).Count -ne 1 -or ($ResNames -join ',') -cne 'ResourceUri,Location,additionalInfo' -or -not $InfoOk)
                {
                    Stop-RdaOfflineMask ("{0}: consumption row {1} has an InstanceData value that is not the shape a run writes. Nothing was written." -f $ReportZip.Name, $RowIndex)
                }
                # A run writes the row's id, location and meter from the same values as its
                # InstanceData's; the masking reads the InstanceData's id, so they must agree.
                $Uri = $Instance.'Microsoft.Resources'
                if ([string]$UsageRow.ResourceId -cne [string]$Uri.ResourceUri -or [string]$UsageRow.ResourceLocation -cne [string]$Uri.Location -or [string]$UsageRow.ConsumptionMeter -cne [string]$Uri.additionalInfo.ConsumptionMeter)
                {
                    Stop-RdaOfflineMask ("{0}: consumption row {1} has an id, location or meter its InstanceData does not have. Nothing was written." -f $ReportZip.Name, $RowIndex)
                }
                # An id that ends on the word '$system' with no name after it is a form this
                # tool does not support (Test-RdaTrailingSystemTypeId): refused with its own
                # reason, as masking the report again would stop here again.
                if (Test-RdaTrailingSystemTypeId ([string]$UsageRow.ResourceId)) { Stop-RdaOfflineMask ("{0}: consumption row {1} has an id that ends on the word '`$system' with no name after it ('.../<type>/<name>/`$system'). That is an id form this tool does not support: no Azure billing row seen so far has it, and downstream would read '`$system' as the resource's name. Ask the owner of this tool how to handle it. Nothing was written." -f $ReportZip.Name, $RowIndex) }
                # The id masking keeps an id's provider and type words: they must be Azure's.
                if (-not (Test-RdaIdPathWord ([string]$UsageRow.ResourceId))) { Stop-RdaOfflineMask ("{0}: consumption row {1} has an id whose provider or type is not as Azure writes one. Nothing was written." -f $ReportZip.Name, $RowIndex) }
                # A subscription id that ends on a type word, or on a provider namespace, with no
                # name after it, and a tenant-scope id a run masks part by part that ends on a
                # provider namespace, are forms this tool does not support either
                # (Test-RdaTrailingTypeWordId): refused with its own reason, as masking the report
                # again would stop here again. An odd number of segments is the namespace form; an
                # even one ends on a word, which the reason names when it is the word providers or
                # the group word resourceGroups (segment 3), and else calls a type word.
                if (Test-RdaTrailingTypeWordId ([string]$UsageRow.ResourceId))
                {
                    $IdParts = ([string]$UsageRow.ResourceId).Split('/')
                    $EndsOn = if (($IdParts.Count % 2) -eq 1) { "a provider namespace with no type or name after it ('.../providers/<namespace>')" }
                    elseif ($IdParts[-1] -ieq 'providers') { "the word 'providers' with no provider namespace after it ('.../providers')" }
                    elseif ($IdParts.Count -eq 4 -and $IdParts[3] -ieq 'resourcegroups') { "the word 'resourceGroups' with no group name after it ('/subscriptions/<id>/resourceGroups')" }
                    else { "a type word with no name after it ('.../<type>/<name>/<type>')" }
                    $IdParts = $null
                    Stop-RdaOfflineMask ("{0}: consumption row {1} has an id that ends on {2}. That is an id form this tool does not support: no Azure billing row seen so far has it, and downstream would read that word as the resource's name. Ask the owner of this tool how to handle it. Nothing was written." -f $ReportZip.Name, $RowIndex, $EndsOn)
                }
                # One cell that cannot be read makes the whole file unusable: the quantity a number
                # with a dot (as PowerShell writes one), the times as the run writes them
                # ('M/d/yyyy h:mm:ss tt', invariant) or in ISO form.
                $Qty = 0.0
                if ([string]$UsageRow.Quantity -cnotmatch '^-?[0-9]+(?:\.[0-9]+)?(?:[Ee][-+]?[0-9]+)?\z' -or -not [double]::TryParse([string]$UsageRow.Quantity, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$Qty) -or -not [double]::IsFinite($Qty) -or -not (Test-RdaUsageTime ([string]$UsageRow.UsageStartTime)) -or -not (Test-RdaUsageTime ([string]$UsageRow.UsageEndTime)))
                {
                    Stop-RdaOfflineMask ("{0}: consumption row {1} has a quantity or time that cannot be read. Nothing was written." -f $ReportZip.Name, $RowIndex)
                }
                # Rule: offline = live. A row with a negative Quantity, an empty MeterId or an
                # empty ResourceId is written byte for byte as a live -Obfuscate run writes it:
                # unchanged, never dropped, fixed or refused.
                # Reason: the client must not change data rows (the output contract), and a
                # masked report must read as the plain one does, so the offline mask
                # may not differ from a run. Such a row's usage is not counted, so the
                # mask counts each kind and names the rows (row number and masked id, or "no id")
                # at the end: the loss is then not silent.
                $IsNegative = $Qty -lt 0
                $IsNoMeter = [string]::IsNullOrEmpty([string]$UsageRow.MeterId)
                # Read from the plain id: the mask writes a stand-in for an empty one.
                $IsNoId = [string]::IsNullOrEmpty([string]$UsageRow.ResourceId)
                if ([string]$UsageRow.ResourceId -match $TokenRegex) { Stop-RdaOfflineMask ("{0} is already masked (its consumption holds masked ids). Nothing was written." -f $ReportZip.Name) }
                # A row with fewer cells than the header is cut off (a run writes every cell, "" when empty).
                $Short = $false
                foreach ($P in $UsageRow.PSObject.Properties) { if ($null -eq $P.Value) { $Short = $true } }
                if ($Short) { Stop-RdaOfflineMask ("{0}: consumption row {1} is cut off. Nothing was written." -f $ReportZip.Name, $RowIndex) }
                # A subscription the report does not name would get a token from its id, whose
                # prefix need not be the one its name gives in a run: refused, not guessed.
                $RowSub = & $IdSub $UsageRow.ResourceId
                if ($null -ne $RowSub -and -not $SubNames.Contains($RowSub)) { Stop-RdaOfflineMask ("{0}: consumption row {1} is of a subscription the report does not name, so its prod or nonprod prefix cannot be the run's. Nothing was written." -f $ReportZip.Name, $RowIndex) }
                # Values neither a run nor this script masks: Azure's words, except a full id,
                # whose parts are real values the masked output must not hold (it is refused).
                $Unmasked = @(foreach ($P in $UsageRow.PSObject.Properties) { if ($P.Name -notin 'InstanceData', 'ResourceId', 'ReservationId', 'ReservationOrderId') { [string]$P.Value } }) + @(foreach ($P in $Instance.'Microsoft.Resources'.additionalInfo.PSObject.Properties) { [string]$P.Value })
                foreach ($V in $Unmasked)
                {
                    # A full id in any form ('/subscriptions/...' or a tenant-scope '/providers/...',
                    # with or without its first '/', URL-encoded): its parts are real values.
                    $CellIds = if ($V.IndexOf('%') -ge 0 -or $V.IndexOf('subscriptions', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $V.IndexOf('providers', [StringComparison]::OrdinalIgnoreCase) -ge 0) { @(Get-RdaFullIdInValue -Value $V) } else { @() }
                    if ($CellIds.Count -gt 0) { $ExtraReal.AddRange([string[]]$CellIds) }
                    elseif (-not $Exempt.Contains($V) -and (Test-RdaAzureWordCandidate $V)) { [void]$Exempt.Add($V) }
                }
                [void]$Exempt.Add([string]$Instance.'Microsoft.Resources'.Location)
                $PlainId = [string]$UsageRow.ResourceId
                Protect-RdaUsageRow -Row $UsageRow -InstanceObject $Instance
                # The masked id (the row's ResourceId and its InstanceData's ResourceUri) must be
                # the one a run writes, every name part a token. The inventory and metric slot
                # checks above never see an id that only billing holds, and the last leak scan
                # does not look for a short name of letters, or Azure's fixed name '$system',
                # inside a text: so a name part left as written is refused here. Any other
                # shape a run does not write (another number of segments, a flat token for an
                # id a run masks part by part, a token of another form or hint) is refused too.
                # The ResourceId is checked against the plain id below. The ResourceUri check
                # here cannot fail today: Protect-RdaUsageRow writes both cells from one value,
                # and the checks above make the plain ResourceId equal the ResourceUri, case for
                # case. It is kept only as a guard against a future change to
                # Protect-RdaUsageRow that writes the two cells from different values (the
                # tests put such a change in a copy of this tool, and this check stops it).
                if ([string]$Instance.'Microsoft.Resources'.ResourceUri -cne [string]$UsageRow.ResourceId)
                {
                    Stop-RdaOfflineMask ("{0}: consumption row {1}: the id in its InstanceData is not the row's masked id after masking (a run writes both from one value). Nothing was written." -f $ReportZip.Name, $RowIndex)
                }
                if ($UsageIdsChecked.Add($PlainId) -and -not (Test-RdaMaskedUsageId -PlainId $PlainId -MaskedId ([string]$UsageRow.ResourceId)))
                {
                    Stop-RdaOfflineMask ("{0}: consumption row {1}: its masked id is not the one a run writes (a name part left as written, or another shape). Nothing was written." -f $ReportZip.Name, $RowIndex)
                }
                $UsageRow.InstanceData = $Instance | ConvertTo-Json -Compress
                $Bare = if ($RowIndex -le $BareCells.Length) { $BareCells[$RowIndex - 1] } else { 0 }
                if ($Bare -ne 0)
                {
                    $Cell = 0
                    foreach ($P in $UsageRow.PSObject.Properties)
                    {
                        if ($Cell -lt 31 -and ($Bare -band (1 -shl $Cell)) -ne 0 -and [string]::IsNullOrEmpty([string]$P.Value)) { $P.Value = $null }
                        $Cell++
                    }
                }
                # Named by its masked id, or "no id" for a row that has none.
                $NamedId = if ($IsNoId) { 'no id' } else { [string]$UsageRow.ResourceId }
                if ($IsNegative) { $NegativeRows.Add([pscustomobject]@{ Row = $RowIndex; Id = $NamedId }) }
                if ($IsNoMeter) { $NoMeterRows.Add([pscustomobject]@{ Row = $RowIndex; Id = $NamedId }) }
                if ($IsNoId) { $NoIdRows.Add([pscustomobject]@{ Row = $RowIndex; Id = $NamedId }) }
                $UsageRow
            } | Export-Csv -LiteralPath $CsvOut -Encoding utf8 -NoTypeInformation
            if (($NegativeRows.Count + $NoMeterRows.Count + $NoIdRows.Count) -gt 0) { $DroppedReport.Add([pscustomobject]@{ Zip = $ReportZip.Name; Negative = $NegativeRows.ToArray(); NoMeter = $NoMeterRows.ToArray(); NoId = $NoIdRows.ToArray() }) }
        }

        # --- The dictionary, then the logs and the report page -------------------
        $DictOut = Join-Path $Out ("ObfuscationDictionary_{0}_{1}.json" -f $ReportName, $Stamp)
        Get-RdaObfuscationDictionary | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $DictOut -Encoding utf8

        # The plain diagnostics log, read back into what the run had (phase times
        # and failures), then written again as a -Obfuscate run writes it: no failure
        # text, only the facts the plain log holds.
        # Set for every report: the main summary below reads it with or without a log.
        $OnlySub = if ($SubNames.Count -eq 1) { @($SubNames.Keys)[0] } else { $null }
        if ($null -ne $Parsed)
        {
            # No failure text is kept: the log holds each failure's collector and count, and the
            # closed-list facts it already holds (Get-RdaDiagnosticMessage), as a run writes it.
            # The subscription is this report's one subscription, written as its token.
            # A stream worker's log also lists earlier subscriptions' failures, all as <guid>:
            # only a collector failure this report's page names is this subscription's.
            # The others stay <guid>, as a run writes a subscription it does not know.
            # The log lists the worker's earlier subscriptions first: a module's last entry is this one's.
            $OwnModules = @($FailedCollectors)
            $Entries = @($Parsed.CollectorFailures)
            for ($E = $Entries.Count - 1; $E -ge 0; $E--)
            {
                $Entry = $Entries[$E]
                if ($null -ne $OnlySub -and $Entry.Id -eq '<guid>' -and $OwnModules -contains $Entry.Module) { $Entry.Id = $OnlySub; $OwnModules = @($OwnModules | Where-Object { $_ -ne $Entry.Module }) }
            }
            $Global:CollectorFailures = @($Parsed.CollectorFailures)
            $Global:MetricsFailedSubs = @($Parsed.MetricsFailedSubs)
            $Global:ConsumptionFailedSubs = @($Parsed.ConsumptionFailedSubs)
            $DefaultPathForDiag = $Out + [IO.Path]::DirectorySeparatorChar
            $DiagWritten = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPathForDiag -ReportName $ReportName -RunDateTime $Stamp -Version $(if ($Parsed.Version) { $Parsed.Version } else { $ReportVersion }) -PhaseTimings $PhaseTimings -Obfuscated
            if ([string]::IsNullOrEmpty($DiagWritten)) { Stop-RdaOfflineMask ("{0}: the diagnostics log could not be written. Nothing was written." -f $ReportZip.Name) }
        }

        # The main summary counts each report's own collector failures (its page's), once,
        # with or without a diagnostics log.
        $PerReportFailures.Add([pscustomobject]@{ CollectorFailures = @($FailedCollectors | ForEach-Object { [pscustomobject]@{ Id = $OnlySub; Module = $_; Message = '' } }) })

        $HtmlOut = Join-Path $Out $Expected.Html
        # A run over several subscriptions labels its page with their count, as the plain
        # page does (a count, nothing to mask); a run of one takes the first record's token.
        # The environment the plain run ran on, as its page shows it (not this host's).
        $PagePlat = if ($PageText -match '<div><b>Environment:</b> ([^<]*)</div>') { [System.Net.WebUtility]::HtmlDecode($Matches[1]) } else { $null }
        # A run labels it with one of its fixed words (ResourceInventory.ps1, $Global:PlatformOS).
        if ($null -ne $PagePlat -and $PagePlat -cnotin 'PowerShell Desktop', 'Azure CloudShell', 'PowerShell Unix') { Stop-RdaOfflineMask ("{0}: the report page names an environment a run does not write. Nothing was written." -f $ReportZip.Name) }
        # The run's setup and discovery time, and its total collection time when the run measured
        # it (a run stopped in its processing step has none), as its page shows them (Summary.ps1:
        # whole seconds under a minute, else minutes to two places in the host culture's mark).
        # shortcut: minutes are written again in this host's decimal mark; upgrade if a reader
        # needs the writer's.
        $ReadPageTime = {
            param([string]$Label, [string]$MaxSeconds)
            $Found = @([regex]::Matches($PageText, ('<div><b>{0}:</b> ([^<]*)</div>' -f [regex]::Escape($Label))))
            if ($Found.Count -eq 0) { return $null }
            $T = $Found[0].Groups[1].Value
            # '#######.##' writes no trailing zero; digits are ASCII.
            # 60 Seconds is a total of 59.5 to 59.99 (rounded): given back so, it prints the same.
            if ($Found.Count -eq 1 -and $T -cmatch ('^({0}) Seconds\z' -f $MaxSeconds)) { return [TimeSpan]::FromSeconds($(if ($Matches[1] -eq '60') { 59.5 } else { [int]$Matches[1] })) }
            if ($Found.Count -eq 1 -and $T -cmatch '^([1-9][0-9]{0,6})(?:[.,/\u066B]([0-9]?[1-9]))? Minutes\z') { return [TimeSpan]::FromMinutes([double]::Parse(('{0}.{1}' -f $Matches[1], $(if ($Matches[2]) { $Matches[2] } else { '0' })), [cultureinfo]::InvariantCulture)) }
            Stop-RdaOfflineMask ("{0}: the report page's run times are not as a run writes them. Nothing was written." -f $ReportZip.Name)
        }
        # Setup's seconds part (0-59); the total's whole seconds, rounded (0-60).
        $PageSetup = & $ReadPageTime 'Setup and resource discovery' '[1-5]?[0-9]'
        $PageTotal = & $ReadPageTime 'Total collection (all phases)' '[1-5]?[0-9]|60'
        # A run writes the setup time on every page.
        if ($null -eq $PageSetup -or @([regex]::Matches($PageText, '<b>Setup and resource discovery:</b>|<b>Total collection \(all phases\):</b>')).Count -ne $(if ($null -ne $PageTotal) { 2 } else { 1 })) { Stop-RdaOfflineMask ("{0}: the report page's run times are not as a run writes them. Nothing was written." -f $ReportZip.Name) }
        $PageLabel = if ($PageText -match '<b>Subscription:</b> (\d+ subscriptions \(consolidated\))') { $Matches[1] } else { $null }
        $null = & (Join-Path $PSScriptRoot 'Extension/Summary.ps1') -JsonFile $InvOut -HtmlFile $HtmlOut -Title ('Azure Resource Inventory - {0}' -f $ReportName) -SubscriptionName $PageLabel -TenantId $null -Version $ReportVersion -ExtractionRunTime $PageSetup -ReportingRunTime $PageTotal -PhaseTimings $PhaseTimings -PlatOS $PagePlat -ConsumptionFile $CsvOut -CollectorFailures @($FailedCollectors | ForEach-Object { [pscustomobject]@{ Module = $_ } }) *> $null
        if (-not (Test-Path -LiteralPath $HtmlOut)) { Stop-RdaOfflineMask ("{0}: the report page could not be written. Nothing was written." -f $ReportZip.Name) }

        # --- The report zip, with the files a run puts in it, in its order ------
        $ZipFiles = @($HtmlOut, $CsvOut)
        if (Test-Path -LiteralPath (Join-Path $Out $Expected.Diagnostics)) { $ZipFiles += (Join-Path $Out $Expected.Diagnostics) }
        $ZipFiles += @(Get-ChildItem -LiteralPath $Out -Filter '*.json' -File | Where-Object { $_.Name -notlike 'ObfuscationDictionary_*' } | Sort-Object Name | Select-Object -ExpandProperty FullName)
        $ReportZipOut = Join-Path $Out $ReportZip.Name
        Compress-RdaReportArchive -Path @($ZipFiles | ForEach-Object { [WildcardPattern]::Escape($_) }) -DestinationPath $ReportZipOut -CompressionLevel Fastest
        $ReportReal = @(Get-RdaRealValueSet -ExtraValue $ExtraReal.ToArray())
        # Logs hold no Azure words of the report's fields: scanned with no exemption.
        $Scans.Add([pscustomobject]@{ Files = @($ZipFiles | Where-Object { $_ -notlike '*.log' }); Real = $ReportReal; Exempt = $Exempt })
        $Scans.Add([pscustomobject]@{ Files = @($ZipFiles | Where-Object { $_ -like '*.log' }); Real = $ReportReal; Exempt = $null })
        $SubFolders.Add($Folder)
        foreach ($V in $ReportReal) { [void]$AllRealValues.Add($V) }
        $ReportExempt[$Folder] = $Exempt
        $ExtraReal.Clear()
        $ExtraReal.AddRange($OuterReal)
        Write-Host ("Masked {0}" -f $ReportZip.Name) -ForegroundColor Green
    }

    # --- The consolidated zip, as the wrapper builds it ---------------------------
    if ($null -ne $OuterName)
    {
        $Stage = Join-Path $Work 'bundle'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        $Failed = @()
        $Coverage = @()
        if ($HasRunSummary)
        {
            try { $Summary = ConvertFrom-RdaRunSummaryText -Lines (Get-Content -LiteralPath $PlainRunSummary) }
            catch { Stop-RdaOfflineMask 'RunSummary.log is cut off or not as a run writes it. Nothing was written.' }
            if ($Summary.Arguments.Version) { $Version = $Summary.Arguments.Version }
            $Coverage = @($Summary.CoverageLines)
            $Failed = @(1..$Summary.Failed | Where-Object { $Summary.Failed -gt 0 } | ForEach-Object { 'failed' })
            $RsArgs = $Summary.Arguments
            $RunSummaryLines = Get-RunSummaryLogContent @RsArgs -Obfuscated
            $RunSummaryLines | Out-File -FilePath (Join-Path $Stage 'RunSummary.log') -Encoding utf8
        }
        if (Test-Path -LiteralPath (Join-Path $InStage 'MainSummary.html'))
        {
            $MainHtml = Join-Path $Work 'MainSummary.html'
            # The plain main summary shows the metrics and consumption failures as the wrapper had
            # them: its banner counts and the rows it marks. They are rebuilt from it (a count and
            # a report folder are not real values).
            $PlainMain = [System.IO.File]::ReadAllText((Join-Path $InStage 'MainSummary.html'))
            $MainPlat = if ($PlainMain -match '<div><b>Environment:</b> ([^<]*)</div>') { [System.Net.WebUtility]::HtmlDecode($Matches[1]) } else { $null }
            # The wrapper writes the host's $PSVersionTable.OS there (Darwin's and Ubuntu's hold
            # '~', '#', ':' and '/'). shortcut: held to one line of printable text of an OS
            # string's length with no GUID, not to a list of every OS; the leak scan still looks
            # for every real value in it.
            if ($null -ne $MainPlat -and ($MainPlat -notmatch '^[\x20-\x7E]{1,512}\z' -or $MainPlat -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-')) { Stop-RdaOfflineMask 'MainSummary.html names an environment that is not an OS name. Nothing was written.' }
            try { $Marks = ConvertFrom-RdaMainSummaryMark -Html $PlainMain -RunSummary $(if ($HasRunSummary) { $Summary.Arguments } else { $null }) }
            catch { Stop-RdaOfflineMask 'MainSummary.html is cut off, or does not show the failures RunSummary.log counts. Nothing was written.' }
            $MainMetrics = $Marks.MetricsFailedSubs; $MainConsumption = $Marks.ConsumptionFailedSubs
            $Detailed = $HasRunSummary -and $Summary.Arguments.InvocationParameters.Contains('Detailed')
            New-RdaAllSubHtmlSummary -RunOutputDirectory $WorkOut -HtmlFile $MainHtml -ReportFolders @($SubFolders) -CoverageLines $Coverage `
                -FailedSubscriptions $Failed `
                -ConsumptionFailedSubs $MainConsumption `
                -MetricsFailedSubs $MainMetrics `
                -CollectorFailures @($PerReportFailures | ForEach-Object { $_.CollectorFailures }) `
                -TenantId $null -Version $Version -PlatOS $MainPlat -Detailed:$Detailed -Obfuscated *> $null
            (Get-Content -LiteralPath $MainHtml -Raw) -replace 'href="ResourcesReport', 'href="HTML' | Set-Content -LiteralPath (Join-Path $Stage 'MainSummary.html') -Encoding utf8
        }
        foreach ($Folder in $SubFolders)
        {
            $SubHtml = Get-ChildItem -LiteralPath (Join-Path $WorkOut $Folder) -Filter '*.html' -File | Select-Object -First 1
            $HtmlDir = Join-Path $Stage ($Folder -replace '^ResourcesReport', 'HTML')
            New-Item -ItemType Directory -Path $HtmlDir -Force | Out-Null
            Copy-Item -LiteralPath $SubHtml.FullName -Destination (Join-Path $HtmlDir $SubHtml.Name)
        }
        $OuterZip = Join-Path $WorkOut $OuterName
        # The inner zips and the bundle extras the wrapper adds, written by the run's
        # streaming zip writer (Compress-Archive keeps every entry in memory). That writer
        # puts folder contents (HTML<stamp>/) before files, so the entry order is not the
        # wrapper's; each inner zip is read by its name, not its place.
        $OuterItems = @($SubFolders | ForEach-Object { Join-Path (Join-Path $WorkOut $_) ("ResourcesReport_{0}.zip" -f $_.Substring('ResourcesReport'.Length)) }) + @(Get-ChildItem -LiteralPath $Stage -Force | Sort-Object Name | ForEach-Object { $_.FullName })
        Compress-RdaReportArchive -Path @($OuterItems | ForEach-Object { [WildcardPattern]::Escape($_) }) -DestinationPath $OuterZip -CompressionLevel Optimal
        # Each report page copy with its own report's exemptions; the run's own summaries with none.
        foreach ($Folder in $SubFolders)
        {
            $Copies = @(Get-ChildItem -LiteralPath (Join-Path $Stage ($Folder -replace '^ResourcesReport', 'HTML')) -File | Select-Object -ExpandProperty FullName)
            $Scans.Add([pscustomobject]@{ Files = $Copies; Real = @($AllRealValues); Exempt = $ReportExempt[$Folder] })
        }
        $Scans.Add([pscustomobject]@{ Files = @(Get-ChildItem -LiteralPath $Stage -File | Select-Object -ExpandProperty FullName); Real = @($AllRealValues); Exempt = $null })
    }

    # --- The last check: no real value in any file written to share --------------
    $Leaks = @(foreach ($Scan in $Scans) { if (@($Scan.Files).Count -gt 0) { Test-RdaMaskedOutputLeak -Path @($Scan.Files) -RealValue @($Scan.Real) -Exempt $Scan.Exempt } })
    if ($Leaks.Count -gt 0)
    {
        Stop-RdaOfflineMask ("A real name or id is still in: {0}. Nothing was written." -f (($Leaks | ForEach-Object { '{0} ({1} hit(s))' -f $_.File, $_.Hits }) -join ', '))
    }

    Publish-RdaOfflineOutput -From $WorkOut -To $OutputDirectory -Published $Published

    foreach ($Key in ($Unresolved.Keys | Sort-Object))
    {
        Write-Host ("{0}: {1} reference(s) to a resource this report does not hold are written as 'obfuscated', as a run writes an id it does not know." -f $Key, $Unresolved[$Key]) -ForegroundColor Yellow
    }
    # Each kind is counted and named by row number and masked id (never a real value):
    # the rows are written as a live run writes them (see the row loop), and their
    # usage is not counted.
    foreach ($D in $DroppedReport)
    {
        Write-Host ("In {0}, the usage of these consumption rows is not counted. They are written unchanged, as a live run writes them:" -f $D.Zip) -ForegroundColor Yellow
        foreach ($Kind in @(@{ Rows = $D.Negative; Text = 'a negative Quantity' }, @{ Rows = $D.NoMeter; Text = 'an empty MeterId' }, @{ Rows = $D.NoId; Text = 'an empty ResourceId' }))
        {
            $KindRows = @($Kind.Rows)
            if ($KindRows.Count -eq 0) { continue }
            $Shown = @($KindRows | Select-Object -First 10 | ForEach-Object { 'row {0} ({1})' -f $_.Row, $_.Id })
            $More = if ($KindRows.Count -gt $Shown.Count) { ('; and {0} more' -f ($KindRows.Count - $Shown.Count)) } else { '' }
            $Noun = if ($KindRows.Count -eq 1) { 'row has' } else { 'rows have' }
            Write-Host ("  {0} {1} {2}: {3}{4}" -f $KindRows.Count, $Noun, $Kind.Text, ($Shown -join '; '), $More) -ForegroundColor Yellow
        }
    }
    $Share = if ($null -ne $OuterName) { Join-Path $OutputDirectory $OuterName } else { Join-Path (Join-Path $OutputDirectory $SubFolders[0]) $ReportZips[0].Name }
    Write-Host ''
    Write-Host ("Masked report (safe to share): {0}" -f $Share) -ForegroundColor Green
    Write-Host ("Obfuscation dictionaries (keep local, do not share): {0}{1}<report folder>{1}ObfuscationDictionary_*.json" -f $OutputDirectory, [IO.Path]::DirectorySeparatorChar) -ForegroundColor Yellow
    Write-Host ("To map it back: ./Reveal.ps1 -InventoryRoot '{0}'" -f $OutputDirectory) -ForegroundColor Cyan
    $ExitCode = 0
}
catch
{
    $ExitCode = 1
    $Why = if ($_.Exception.Data.Contains('RdaOfflineStop')) { $_.Exception.Message } else { 'the mask stopped on an error: {0} (line {1}). Nothing was written.' -f $_.Exception.GetType().Name, $_.InvocationInfo.ScriptLineNumber }
    Write-Host ("ERROR: {0}" -f $Why) -ForegroundColor Red
}
finally
{
    foreach ($G in $GlobalNames) { Set-Variable -Name $G -Scope Global -Value $SavedGlobals[$G] }
    # Each step of the cleanup is its own: a path the host cannot test (too long) must not stop the next.
    try { if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue } } catch { $null = $_ }
    if ($ExitCode -ne 0)
    {
        # Nothing half-masked is left to be shared; only what this mask put there is removed.
        foreach ($Item in $Published) { try { if (Test-Path -LiteralPath $Item) { Remove-Item -LiteralPath $Item -Recurse -Force -ErrorAction SilentlyContinue } } catch { $null = $_ } }
        try { if ($CreatedOutput -and (Test-Path -LiteralPath $OutputDirectory) -and @(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $OutputDirectory -Force -ErrorAction SilentlyContinue } } catch { $null = $_ }
    }
}
exit $ExitCode
