#Requires -Version 7.0
# =============================================================================
# RecoveryMerge.Functions.ps1
#
# Merge-RecoveryData: splice a scoped recovery run's output back into an earlier
# (incomplete) report bundle and re-package the result as a single clean bundle
# that looks like the original run completed successfully.
#
# Recovers THREE independent dimensions, each from the recovery bundle:
#   - Inventory service key(s)   : always (selected by -Service; default = all).
#   - Consumption CSV            : opt-in via -RecoverConsumption (whole-file
#                                  replace; use when the gap run's consumption is
#                                  missing/incomplete/truncated).
#   - Metrics file(s)            : opt-in via -RecoverMetrics (whole-file replace,
#                                  rebased to the output bundle name).
# Consumption/metrics default to being carried forward from the gap bundle
# unchanged (byte-for-byte the prior behaviour) unless their switch is set.
#
# Context: when a collector fails (or is intentionally scoped out with -Service)
# a report bundle is produced that is MISSING one or more service types. Rather
# than re-run the whole tenant (hours), the operator re-collects only the missing
# service(s) with:
#     ResourceInventory.ps1 -Service <name> -Obfuscate -ObfuscationDictionary <gap dict>
# The -ObfuscationDictionary seed guarantees the recovery run's obfuscated tokens
# match the gap bundle's tokens exactly, so the recovered rows can be spliced in
# with no remapping. This function performs that splice + re-package.
#
# Dot-source this file, then call Merge-RecoveryData. On load it runs one step:
# it checks that Functions/InventoryJson.Functions.ps1 is next to it (throws if
# not, and the throw stops the caller under any $ErrorActionPreference) and
# dot-sources it, which defines Write-InventoryJson. So it works when
# dot-sourced on its own. The rest is definitions. Merge-RecoveryData has no
# dependency on ResourceInventory.ps1's globals; it only reads/writes files and
# re-invokes Extension/Summary.ps1 to regenerate the HTML report.
# =============================================================================

# InventoryJson.Functions.ps1 defines only Write-InventoryJson, so loading it
# sets no variable and leaves the caller's other functions as they were.
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'InventoryJson.Functions.ps1') -PathType Leaf))
{
    # A plain throw here, even one re-thrown from a catch, is skipped when the caller
    # runs with $ErrorActionPreference = 'SilentlyContinue' or 'Ignore'. Thrown from a
    # child scope set to Stop, it stops the caller under any preference. The child
    # scope ends here, so the caller's own preference is left as it was.
    & {
        $ErrorActionPreference = 'Stop'
        throw ("RecoveryMerge.Functions.ps1: required file not found: {0}. Keep the Functions folder together." -f (Join-Path $PSScriptRoot 'InventoryJson.Functions.ps1'))
    }
}
. (Join-Path $PSScriptRoot 'InventoryJson.Functions.ps1')

function Merge-RecoveryData
{
    [CmdletBinding()]
    param(
        # Folder of the incomplete run (the "gap" bundle). Must contain an
        # Inventory_*.json; may also contain Consumption_*.csv, Metrics_*.json,
        # and the local ObfuscationDictionary_*.json.
        [Parameter(Mandatory)][string]$GapBundlePath,

        # Folder of the scoped recovery run (produced with -Service + the gap
        # bundle's dictionary as -ObfuscationDictionary). Must contain an
        # Inventory_*.json holding the recovered service key(s).
        [Parameter(Mandatory)][string]$RecoveryBundlePath,

        # Folder to write the rebuilt bundle into (created if absent).
        [Parameter(Mandatory)][string]$OutputPath,

        # Optional: which collector key(s) to take from the recovery inventory.
        # Defaults to every service key present in the recovery inventory (i.e.
        # exactly what the scoped recovery run collected), excluding 'Version'.
        [string[]]$Service,

        # Whole-file replace the CONSUMPTION CSV with the recovery bundle's copy
        # instead of carrying the gap bundle's forward. Use when the gap run's
        # consumption is missing/incomplete (e.g. truncated by a transient
        # "copying content to a stream" error). Consumption is a per-subscription
        # whole file, so this is a clean replace, not a row-merge. The recovery
        # bundle MUST contain a Consumption_*.csv or the function fails loud.
        [switch]$RecoverConsumption,

        # Whole-file replace the METRICS file(s) with the recovery bundle's copy
        # instead of carrying the gap bundle's forward. Use when the gap run's
        # metrics are missing/incomplete. The recovery bundle MUST contain at
        # least one Metrics_*.json or the function fails loud. Recovered metrics
        # files are rebased to the output bundle name so they stay consistent
        # with the rest of the rebuilt bundle.
        [switch]$RecoverMetrics
    )

    $ErrorActionPreference = 'Stop'

    # Non-fatal advisories. Each is emitted via Write-Warning for the operator AND
    # collected here so it is returned in the result's .Warnings property (lets
    # callers/tests assert them). These guards catch operator-discipline traps
    # that would otherwise produce a bundle that LOOKS complete but is subtly
    # wrong (mismatched obfuscation tokens, a shifted billing window, a silent
    # record downgrade). They never block the merge - they surface the risk.
    $MergeWarnings = [System.Collections.Generic.List[string]]::new()
    function Add-MergeWarning([string]$Message)
    {
        Write-Warning ('Merge-RecoveryData: ' + $Message)
        $MergeWarnings.Add($Message)
    }

    # -- Summarise a consumption CSV (row count + billing window endpoints) so
    #    the -RecoverConsumption path can flag a shrunk row set or a shifted
    #    billing period. Endpoints are compared as strings only (same tool, same
    #    format on both sides), so equality/inequality is a reliable drift signal
    #    without needing culture-aware date parsing. -----------------------------
    function Get-ConsumptionCsvStats([string]$Path)
    {
        # One pass, keeping no row: the count and the lowest start and highest
        # end, compared as Sort-Object compares strings.
        $RowCount = 0
        $MinStart = $null
        $MaxEnd = $null
        Import-Csv -LiteralPath $Path -ErrorAction Stop | ForEach-Object {
            $RowCount++
            $Start = $_.UsageStartTime
            $End = $_.UsageEndTime
            if ($Start -and ($null -eq $MinStart -or [string]::Compare($Start, $MinStart, [System.StringComparison]::CurrentCultureIgnoreCase) -lt 0)) { $MinStart = $Start }
            if ($End -and ($null -eq $MaxEnd -or [string]::Compare($End, $MaxEnd, [System.StringComparison]::CurrentCultureIgnoreCase) -gt 0)) { $MaxEnd = $End }
        }
        [PSCustomObject]@{
            RowCount = $RowCount
            MinStart = $MinStart
            MaxEnd   = $MaxEnd
        }
    }

    # -- Verify an ObfuscationDictionary actually BELONGS to a given inventory.
    #    An obfuscated inventory stores per-resource tokens (prod_/nonprod_<guid>)
    #    in its ID/Name/cross-ref fields; those exact tokens are the KEYS of the
    #    dictionary's maps (ResourceIdMap/ResourceNameMap/... are token -> real).
    #    So the dictionary that goes with an inventory must contain (almost) all of
    #    that inventory's tokens as keys. If someone points at the WRONG dictionary
    #    (a different run/subscription), the inventory's tokens are absent and
    #    coverage collapses to ~0. Returns matched/total counts plus a few sample
    #    unmatched tokens. Tokens are already obfuscated, so they are safe to
    #    surface in diagnostics; the dictionary VALUES (real IDs) are never touched.
    function Test-DictionaryMatchesInventory
    {
        param([string]$DictionaryPath, [string]$InventoryPath)

        $DictKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Dict = Get-Content -LiteralPath $DictionaryPath -Raw | ConvertFrom-Json
        foreach ($MapProp in $Dict.PSObject.Properties)
        {
            # Only object-valued properties are token maps; skip scalar metadata
            # such as GeneratedAt.
            if ($MapProp.Value -is [System.Management.Automation.PSCustomObject])
            {
                foreach ($TokenKey in $MapProp.Value.PSObject.Properties.Name) { [void]$DictKeys.Add($TokenKey) }
            }
        }

        # Collect the DISTINCT obfuscation tokens present in the inventory text.
        # The pattern matches single prod_/nonprod_<guid> tokens. Inventory IDs are not
        # flat tokens: they are ARM-shaped paths
        # (/subscriptions/<token>/resourcegroups/<token>/providers/<type>/<token>),
        # so the pattern finds the subscription, resource-group and name tokens inside
        # each path, and the Name/Subscription/ResourceGroup fields carry the same
        # tokens. Those single tokens are keys of the name, subscription and
        # resource-group maps, so they are what this check counts. Consumption-style
        # tokens (prod_sub_/prod_rg_...) live in the CSV, not the inventory JSON, so
        # they never enter this scan.
        $InventoryText = Get-Content -LiteralPath $InventoryPath -Raw
        $InventoryTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($TokenMatch in [regex]::Matches($InventoryText, '(?i)\b(?:prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'))
        {
            [void]$InventoryTokens.Add($TokenMatch.Value)
        }

        $Unmatched = @($InventoryTokens | Where-Object { -not $DictKeys.Contains($_) })
        [PSCustomObject]@{
            TokenCount   = $InventoryTokens.Count
            MatchedCount = ($InventoryTokens.Count - @($Unmatched).Count)
            Unmatched    = $Unmatched
        }
    }

    # -- A masking token as the masked run writes it: prod_ or nonprod_, any
    #    type hints (sub_, rg_, rg_mc_, aks_, vmss_, databricks_ ...), then a
    #    GUID. ------------------------------------------------------------------
    $MergeTokenPattern = '(?:prod|nonprod)_(?:[a-z0-9]+_)*[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    $MergeWholeTokenPattern = '(?i)^(?:' + $MergeTokenPattern + ')$'
    # True when an id is masked. Accepted forms:
    # - one flat token (prod_/nonprod_<guid>, type hints allowed), and
    #   'obfuscated' or 'obfuscated_<guid>' for an id that could not be
    #   masked. These are what this tool writes under -Obfuscate today (the
    #   owner kept these flat forms); keep accepting them.
    # - an ARM path, the masked form an ARM-path masking writes: the
    #   subscription, the resource group when present, and EVERY name segment
    #   after each provider namespace/type pair (parent names such as a SQL
    #   server or a scale set too, and the names after a nested '/providers/')
    #   must each be a token. Namespace and type segments, and the literal
    #   '$system' name, stay as Azure wrote them.
    function Test-MergeMaskedId([string]$Value)
    {
        if ($Value -match $MergeWholeTokenPattern) { return $true }
        if ($Value -match '(?i)^obfuscated(?:_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$') { return $true }
        if ($Value -notmatch '(?i)^/subscriptions/([^/]+)(?:/resourcegroups/([^/]+))?(?:/providers/(.+))?$') { return $false }
        $IdSub = $Matches[1]; $IdRg = $Matches[2]; $IdProviders = $Matches[3]
        if ($IdSub -notmatch $MergeWholeTokenPattern) { return $false }
        if ($IdRg -and $IdRg -notmatch $MergeWholeTokenPattern) { return $false }
        if ($IdProviders)
        {
            # Each '/providers/' part is namespace/type/name[/type/name...]:
            # the names sit at the even places from 2 on.
            foreach ($ProviderPart in ($IdProviders.TrimEnd('/') -split '(?i)/providers/'))
            {
                $Parts = $ProviderPart -split '/'
                for ($NameIndex = 2; $NameIndex -lt $Parts.Count; $NameIndex += 2)
                {
                    if ($Parts[$NameIndex] -ne '$system' -and $Parts[$NameIndex] -notmatch $MergeWholeTokenPattern) { return $false }
                }
            }
        }
        return $true
    }

    # -- Check one parsed metric record the way downstream reads it. Returns
    #    $null when it is fine, else a plain reason. MetricCount, MetricValue
    #    and MetricPercentile are JSON numbers; MetricError is true or false;
    #    MetricSeries is a number or a list of numbers. Extension/Metrics.ps1
    #    writes a null MetricSeries for a metric with no series, so a null or
    #    absent series is fine; null or text inside a list is not. -------------
    function Test-MergeJsonNumber($Value)
    {
        return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [System.Numerics.BigInteger])
    }
    function Get-MetricRecordProblem($Record)
    {
        if ($Record -isnot [System.Management.Automation.PSCustomObject]) { return 'is not a JSON object' }
        $Names = $Record.PSObject.Properties.Name
        foreach ($Field in 'MetricCount', 'MetricValue', 'MetricPercentile')
        {
            if ($Names -notcontains $Field -or -not (Test-MergeJsonNumber $Record.$Field)) { return ("has a {0} that is not a number" -f $Field) }
        }
        if ($Names -notcontains 'MetricError' -or $Record.MetricError -isnot [bool]) { return 'has a MetricError that is not true or false' }
        if ($Names -contains 'MetricSeries' -and $null -ne $Record.MetricSeries)
        {
            $Series = $Record.MetricSeries
            if ($Series -is [System.Array])
            {
                foreach ($Point in $Series)
                {
                    if (-not (Test-MergeJsonNumber $Point)) { return 'has a MetricSeries with a value that is not a number' }
                }
            }
            elseif (-not (Test-MergeJsonNumber $Series)) { return 'has a MetricSeries that is not a number or a list of numbers' }
        }
        return $null
    }

    # -- Read an ObfuscationDictionary and check its shape: a JSON object whose
    #    properties, GeneratedAt aside, are token maps (JSON objects or null)
    #    holding plain values. Throws a plain message otherwise, so a broken
    #    dictionary stops the merge before anything is written. ---------------
    function Read-MergeDictionary
    {
        param($File, [string]$Label)
        $Problem = $null
        $Parsed = $null
        try
        {
            $Text = Get-Content -LiteralPath $File.FullName -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($Text)) { $Problem = 'the file is empty' }
            else { $Parsed = ConvertFrom-Json -InputObject $Text -NoEnumerate -ErrorAction Stop }
        }
        catch
        {
            $Problem = $_.Exception.Message
        }
        if ($null -eq $Problem -and $Parsed -isnot [System.Management.Automation.PSCustomObject])
        {
            $Problem = 'it is not a JSON object'
        }
        if ($null -eq $Problem)
        {
            foreach ($MapProp in $Parsed.PSObject.Properties)
            {
                if ($MapProp.Name -eq 'GeneratedAt' -or $null -eq $MapProp.Value) { continue }
                if ($MapProp.Value -isnot [System.Management.Automation.PSCustomObject])
                {
                    $Problem = ("its '{0}' is not a map of tokens" -f $MapProp.Name)
                    break
                }
                foreach ($Entry in $MapProp.Value.PSObject.Properties)
                {
                    if ($Entry.Value -is [System.Management.Automation.PSCustomObject] -or $Entry.Value -is [System.Array])
                    {
                        $Problem = ("its '{0}' holds a value that is not plain text" -f $MapProp.Name)
                        break
                    }
                }
                if ($null -ne $Problem) { break }
            }
        }
        if ($null -ne $Problem)
        {
            throw ("Merge-RecoveryData: the {0} bundle's dictionary '{1}' cannot be read: {2}. Nothing was written to '{3}'. Put back the dictionary that run wrote, or re-run that bundle into a new folder, then run this merge again." -f $Label, $File.FullName, $Problem, $OutputPath)
        }
        return $Parsed
    }

    # -- Locate the newest file matching a filter in a bundle folder ----------
    function Get-BundleFile
    {
        param([string]$Directory, [string]$Filter, [switch]$Optional)
        $MatchingFiles = @(Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
        if (@($MatchingFiles).Count -gt 1)
        {
            # More than one match means the folder is probably NOT a single
            # per-subscription bundle (e.g. -GapBundlePath was pointed at the
            # InventoryRoot that holds many sub folders/runs). Newest-wins is a
            # silent guess, so make it loud.
            Add-MergeWarning ("{0} files match '{1}' in '{2}'; using the newest ('{3}'). If this is not a single per-subscription bundle folder, point the path at one subscription's folder instead. Matches: [{4}]" -f @($MatchingFiles).Count, $Filter, $Directory, $MatchingFiles[0].Name, (($MatchingFiles | ForEach-Object { $_.Name }) -join ', '))
        }
        $Found = $MatchingFiles | Select-Object -First 1
        if (-not $Found -and -not $Optional)
        {
            throw ("Merge-RecoveryData: required file '{0}' not found in '{1}'." -f $Filter, $Directory)
        }
        return $Found
    }

    if (-not (Test-Path -LiteralPath $GapBundlePath -PathType Container)) { throw ("Merge-RecoveryData: GapBundlePath not found: {0}" -f $GapBundlePath) }
    if (-not (Test-Path -LiteralPath $RecoveryBundlePath -PathType Container)) { throw ("Merge-RecoveryData: RecoveryBundlePath not found: {0}" -f $RecoveryBundlePath) }
    $GapInventoryFile = Get-BundleFile -Directory $GapBundlePath      -Filter 'Inventory_*.json'
    $RecoveryInventoryFile = Get-BundleFile -Directory $RecoveryBundlePath -Filter 'Inventory_*.json'
    $GapConsumptionFile = Get-BundleFile -Directory $GapBundlePath      -Filter 'Consumption_*.csv'  -Optional
    $GapDictionaryFile = Get-BundleFile -Directory $GapBundlePath      -Filter 'ObfuscationDictionary_*.json' -Optional
    $RecoveryDictionaryFile = Get-BundleFile -Directory $RecoveryBundlePath -Filter 'ObfuscationDictionary_*.json' -Optional

    # The merge writes a new bundle; written into a source folder it would
    # replace that bundle's own files. An output folder that does not exist
    # yet cannot be a source folder. When it exists, a file with a new random
    # name is made in it and looked for in each source folder; it is removed
    # straight after. That catches every way to reach one folder: relative
    # paths, '~', links, junctions, bind mounts, mapped or substituted drives
    # and short names. Two folders whose names differ only in case are one
    # folder only where the file system says so. A copy of a source bundle is
    # a different folder and is not refused.
    if (Test-Path -LiteralPath $OutputPath -PathType Container)
    {
        $ProbeName = '.rda-merge-probe-' + [guid]::NewGuid().ToString('N')
        $Probe = Join-Path $OutputPath $ProbeName
        $SharedSource = $null
        try
        {
            $null = New-Item -ItemType File -Path $Probe -ErrorAction Stop
            foreach ($Source in @($GapBundlePath, $RecoveryBundlePath))
            {
                if (Test-Path -LiteralPath (Join-Path $Source $ProbeName)) { $SharedSource = $Source; break }
            }
        }
        catch
        {
            throw ("Merge-RecoveryData: -OutputPath '{0}' cannot be written: {1} Nothing was written." -f $OutputPath, $_.Exception.Message)
        }
        finally
        {
            Remove-Item -LiteralPath $Probe -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $SharedSource)
        {
            throw ("Merge-RecoveryData: -OutputPath '{0}' is a source bundle folder ('{1}'). Use a new empty folder. Nothing was written." -f $OutputPath, $SharedSource)
        }
    }

    # -- Guard: obfuscation-dictionary compatibility --------------------------
    # The whole "recovered rows splice in cleanly" guarantee rests on the recovery
    # run having been SEEDED with the gap bundle's dictionary
    # (-ObfuscationDictionary <gap dict>), so identical real values map to identical
    # tokens. If the operator forgets that seed, the recovery run mints fresh random
    # tokens and the recovered service's cross-references to OTHER services'
    # resources will not join - silent referential corruption in a bundle that
    # otherwise looks complete. We cannot repair that here, but we CAN detect the
    # tell-tale: a seeded recovery's ResourceIdMap shares (almost) all of the gap's
    # tokens, whereas an unseeded one shares none. Zero overlap STOPS the merge.
    # Every guard in this block runs before the output folder is created, so a
    # stopped merge writes, zips and leaves nothing; the way out is to fix the
    # named bundle and run the same merge again. Both dictionaries are read and
    # checked first; one that cannot be read stops the merge here.
    $GapDictionary = if ($GapDictionaryFile) { Read-MergeDictionary -File $GapDictionaryFile -Label 'gap' } else { $null }
    $RecoveryDictionary = if ($RecoveryDictionaryFile) { Read-MergeDictionary -File $RecoveryDictionaryFile -Label 'recovery' } else { $null }
    if ($GapDictionaryFile -and $RecoveryDictionaryFile)
    {
        # Drop the $null that an empty or missing map yields, so an empty
        # ResourceIdMap (a run that found no resources) counts as 0 keys and
        # the check below is skipped instead of stopping a merge that no
        # re-run could ever get past. A bundle with an empty map must then give
        # the merge no resource; that is checked once the sources are known.
        $SharedIdKeyCount = $null
        $GapIdKeys = @($GapDictionary.ResourceIdMap.PSObject.Properties.Name | Where-Object { $_ })
        $RecoveryIdKeys = @($RecoveryDictionary.ResourceIdMap.PSObject.Properties.Name | Where-Object { $_ })
        if (@($GapIdKeys).Count -gt 0 -and @($RecoveryIdKeys).Count -gt 0)
        {
            # A set lookup per recovery key, stopping at the first shared one,
            # so maps of many thousand ids are compared in well under a second.
            $GapIdKeySet = [System.Collections.Generic.HashSet[string]]::new([string[]]$GapIdKeys, [System.StringComparer]::OrdinalIgnoreCase)
            $SharedIdKeyCount = 0
            foreach ($RecoveryIdKey in $RecoveryIdKeys)
            {
                if ($GapIdKeySet.Contains($RecoveryIdKey)) { $SharedIdKeyCount = 1; break }
            }
        }
        if ($SharedIdKeyCount -eq 0)
        {
            throw ("Merge-RecoveryData: the recovery bundle's dictionary '{0}' and the gap bundle's dictionary '{1}' share no ResourceIdMap token. The recovery run was almost certainly not seeded with the gap dictionary, so the same resource would carry different tokens in different files of the merged bundle. Nothing was written to '{2}'. Re-run the recovery with -Obfuscate -ObfuscationDictionary '{3}' into a new folder (the default when -OutputDirectory is not set; a reused folder still holds the old files), then run this merge again with -RecoveryBundlePath pointing at it." -f $RecoveryDictionaryFile.Name, $GapDictionaryFile.Name, $OutputPath, $GapDictionaryFile.FullName)
        }
    }
    elseif ($GapDictionaryFile)
    {
        # Masked gap, recovery without a dictionary: the recovery inventory may
        # hold real names and ids, which would ship inside a masked zip.
        throw ("Merge-RecoveryData: the recovery bundle '{0}' has no ObfuscationDictionary_*.json, but the gap bundle has '{1}'. The recovery run was probably not masked, so its real names and ids would ship inside a masked bundle. Nothing was written to '{2}'. Re-run the recovery with -Obfuscate -ObfuscationDictionary '{3}' into a new folder (the default when -OutputDirectory is not set; a reused folder still holds the old files), then run this merge again with -RecoveryBundlePath pointing at it. If the recovery run was masked and its dictionary was moved, put it back in that folder." -f $RecoveryBundlePath, $GapDictionaryFile.Name, $OutputPath, $GapDictionaryFile.FullName)
    }
    elseif ($RecoveryDictionaryFile)
    {
        # Masked recovery, gap without a dictionary: the gap inventory may hold
        # real names and ids next to masked recovered rows.
        throw ("Merge-RecoveryData: the gap bundle '{0}' has no ObfuscationDictionary_*.json, but the recovery bundle has '{1}'. The gap run was probably not masked, so real names and ids would sit next to masked rows in one bundle. Nothing was written to '{2}'. If the gap run was masked and its dictionary was moved, put it back in that folder. Otherwise the quickest way out is to re-run the recovery without -Obfuscate into a new folder (the default when -OutputDirectory is not set; a reused folder still holds the old files), then run this merge again with -RecoveryBundlePath pointing at it. To ship a masked bundle instead, re-run the gap with -Obfuscate -ObfuscationDictionary '{3}' into a new folder, so its tokens match the recovery's, then run this merge again with -GapBundlePath pointing at it." -f $GapBundlePath, $RecoveryDictionaryFile.Name, $OutputPath, $RecoveryDictionaryFile.FullName)
    }

    # -- Guard: dictionary-belongs-to-its-inventory (HARD FAIL) ---------------
    # Distinct from the seed-overlap check above. That one asks "was the recovery
    # seeded from the gap?"; this one asks "does the dictionary sitting in each
    # folder actually belong to THAT folder's inventory?". A wrong dictionary
    # (operator pointed at a different run's / subscription's folder, or passed the
    # wrong -ObfuscationDictionary) would be carried forward silently and make the
    # merged bundle impossible to Reveal - the tokens in the report would map to
    # nothing. We detect it by coverage: (almost) every obfuscated token in an
    # inventory must exist as a key in the dictionary beside it. Zero coverage over
    # a meaningful sample is unambiguous (right dict ~= 100%, wrong dict = 0%), so
    # we HARD FAIL with a diagnostic naming the files, the counts, sample tokens,
    # and the fix. Partial coverage is only suspicious, so it warns.
    foreach ($DictPair in @(
            @{ Label = 'gap'; Dict = $GapDictionaryFile; Inv = $GapInventoryFile; ParamName = '-GapBundlePath' },
            @{ Label = 'recovery'; Dict = $RecoveryDictionaryFile; Inv = $RecoveryInventoryFile; ParamName = '-RecoveryBundlePath' }
        ))
    {
        if (-not $DictPair.Dict) { continue }
        try
        {
            $DictMatch = Test-DictionaryMatchesInventory -DictionaryPath $DictPair.Dict.FullName -InventoryPath $DictPair.Inv.FullName
        }
        catch
        {
            Add-MergeWarning ("could not verify the {0} bundle's dictionary matches its inventory (check skipped): {1}" -f $DictPair.Label, $_.Exception.Message)
            continue
        }
        # No tokens = non-obfuscated inventory (or empty); nothing to verify.
        if ($DictMatch.TokenCount -eq 0) { continue }

        $SampleUnmatched = (@($DictMatch.Unmatched | Select-Object -First 3) -join ', ')
        if ($DictMatch.TokenCount -ge 3 -and $DictMatch.MatchedCount -eq 0)
        {
            throw ("Merge-RecoveryData: the {0} bundle's ObfuscationDictionary does NOT match its inventory - 0 of {1} obfuscated token(s) in '{2}' were found as keys in '{3}'. That dictionary is almost certainly from a DIFFERENT run or subscription; carrying it forward would make the merged bundle impossible to reveal (its tokens would map to nothing). Point {4} at the folder whose ObfuscationDictionary matches its Inventory, or supply the correct dictionary. Example unmatched tokens: [{5}]." -f $DictPair.Label, $DictMatch.TokenCount, $DictPair.Inv.Name, $DictPair.Dict.Name, $DictPair.ParamName, $SampleUnmatched)
        }
        elseif ($DictMatch.MatchedCount -lt $DictMatch.TokenCount -and ($DictMatch.MatchedCount / $DictMatch.TokenCount) -lt 0.5)
        {
            Add-MergeWarning ("the {0} bundle's dictionary covers only {1} of {2} obfuscated inventory token(s). It may be a partial or slightly-mismatched dictionary; a later reveal will leave the uncovered tokens unresolved. Confirm the dictionary belongs to this inventory. Example unmatched tokens: [{3}]." -f $DictPair.Label, $DictMatch.MatchedCount, $DictMatch.TokenCount, $SampleUnmatched)
        }
    }

    # -- Load inventories -----------------------------------------------------
    $GapInventory = Get-Content -LiteralPath $GapInventoryFile.FullName -Raw | ConvertFrom-Json
    $RecoveryInventory = Get-Content -LiteralPath $RecoveryInventoryFile.FullName -Raw | ConvertFrom-Json

    # Determine which service keys to splice in. Default = every collector key the
    # recovery run produced (excluding the 'Version' marker); -Service narrows it.
    $RecoveryKeys = @($RecoveryInventory.PSObject.Properties.Name | Where-Object { $_ -ne 'Version' })
    if ($Service -and @($Service).Count -gt 0)
    {
        $MergeKeys = @($RecoveryKeys | Where-Object { $_ -in $Service })
    }
    else
    {
        $MergeKeys = $RecoveryKeys
    }
    # Guard the inventory splice. Fail-loud rules:
    #   - If -Service was EXPLICITLY named, EVERY requested name must be present
    #     in the recovery inventory. Throw on ANY unmatched name - a TOTAL miss
    #     (none matched) OR a PARTIAL miss (e.g. -Service A,B where A exists but B
    #     does not). Silently splicing only the subset that happened to be there
    #     would drop a dimension the caller explicitly asked for (a typo or the
    #     wrong/incomplete recovery bundle), even if a recover switch is set.
    #   - With no explicit -Service, MergeKeys defaults to "all recovery keys".
    #     Only an empty recovery inventory reaches the error below; that is an
    #     error unless the caller asked to rebuild consumption/metrics only
    #     (leaving the already-complete gap inventory untouched).
    $ServiceExplicit = ($Service -and @($Service).Count -gt 0)
    if ($ServiceExplicit)
    {
        $UnmatchedServices = @($Service | Where-Object { $_ -notin $RecoveryKeys })
        if (@($UnmatchedServices).Count -gt 0)
        {
            throw ("Merge-RecoveryData: -Service name(s) not found in the recovery inventory: [{0}]. Present keys: [{1}]. Check the names or point at the correct recovery bundle." -f ($UnmatchedServices -join ', '), ($RecoveryKeys -join ', '))
        }
    }
    elseif (@($MergeKeys).Count -eq 0 -and -not ($RecoverConsumption -or $RecoverMetrics))
    {
        throw "Merge-RecoveryData: nothing to merge - the recovery inventory has no service keys."
    }

    # Splice each recovered service key into the gap inventory (add if missing,
    # replace if already present). -Force overwrites any existing property.
    foreach ($Key in $MergeKeys)
    {
        # Guard: whole-key replace can silently DOWNGRADE. If the recovery run
        # came back thinner than the gap bundle for this key (its own throttling,
        # a partial collection), replacing wholesale drops the extra gap records
        # with no trace. Compare counts and warn; do not block (the operator may
        # know the gap key was itself corrupt and the smaller recovery set is the
        # correct one).
        $GapKeyCount = if ($GapInventory.PSObject.Properties.Name -contains $Key) { @($GapInventory.$Key).Count } else { 0 }
        $RecoveryKeyCount = @($RecoveryInventory.$Key).Count
        if ($GapKeyCount -gt 0 -and $RecoveryKeyCount -lt $GapKeyCount)
        {
            Add-MergeWarning ("service '{0}' is being REPLACED with FEWER records than the gap bundle held ({1} from recovery vs {2} in gap). Whole-key replace will drop the extra gap records. Confirm the recovery run for '{0}' completed fully (no throttling / partial collection) before shipping the merged bundle." -f $Key, $RecoveryKeyCount, $GapKeyCount)
        }
        $GapInventory | Add-Member -NotePropertyName $Key -NotePropertyValue $RecoveryInventory.$Key -Force
    }

    # -- Compute output naming (mirror ResourceInventory.ps1's bundle names) ---
    # Gap inventory file is "Inventory_<ReportName>_<stamp>.json"; reuse that
    # "<ReportName>_<stamp>" base so the rebuilt bundle keeps the run's identity.
    $BundleBase = $GapInventoryFile.BaseName -replace '^Inventory_', ''

    # -- Every requested recovery source is checked before anything is
    #    written, so a stop never leaves a partial output folder.
    #    Each is looked up once here and used below.
    $RecoveryConsumptionFile = $null
    if ($RecoverConsumption)
    {
        $RecoveryConsumptionFile = Get-BundleFile -Directory $RecoveryBundlePath -Filter 'Consumption_*.csv' -Optional
        if (-not $RecoveryConsumptionFile)
        {
            throw ("Merge-RecoveryData: -RecoverConsumption was requested but the recovery bundle '{0}' has no Consumption_*.csv. Re-run the recovery WITHOUT -SkipConsumption. Nothing was written." -f $RecoveryBundlePath)
        }
    }
    $RecoveryMetricsFiles = @()
    if ($RecoverMetrics)
    {
        $RecoveryMetricsFiles = @(Get-ChildItem -LiteralPath $RecoveryBundlePath -Filter 'Metrics_*.json' -File -ErrorAction SilentlyContinue)
        if ($RecoveryMetricsFiles.Count -eq 0)
        {
            throw ("Merge-RecoveryData: -RecoverMetrics was requested but the recovery bundle '{0}' has no Metrics_*.json. Re-run the recovery WITHOUT -SkipMetrics. Nothing was written." -f $RecoveryBundlePath)
        }
    }
    # The gap bundle's metrics files, carried forward when -RecoverMetrics is not set.
    $GapMetricsFiles = @()
    if (-not $RecoverMetrics)
    {
        $GapMetricsFiles = @(Get-ChildItem -LiteralPath $GapBundlePath -Filter 'Metrics_*.json' -File -ErrorAction SilentlyContinue)
    }

    # -- The consumption and metrics files that will be zipped are checked
    #    here, before anything is written. Downstream drops a consumption file
    #    without the columns it needs, and every metric in a zip when one
    #    Metrics file is not an object with a Metrics list, both without an
    #    error, so such a file stops the merge instead. ------------------------
    # Set by the one pass over the consumption file below.
    $ConsumptionHasRows = $false
    $ConsumptionUnmaskedRow = 0
    $ConsumptionSource = if ($RecoverConsumption) { 'recovery' } else { 'gap' }
    $ConsumptionSourceFile = if ($RecoverConsumption) { $RecoveryConsumptionFile } else { $GapConsumptionFile }
    if ($ConsumptionSourceFile)
    {
        $HeaderNames = @()
        try
        {
            $HeaderLine = Get-Content -LiteralPath $ConsumptionSourceFile.FullName -TotalCount 1 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($HeaderLine))
            {
                # Two copies of the header line read as a header and one row,
                # so the CSV reader parses the names, quotes included.
                $HeaderNames = @((@($HeaderLine, $HeaderLine) | ConvertFrom-Csv -ErrorAction Stop | Select-Object -First 1).PSObject.Properties.Name)
            }
        }
        catch
        {
            $HeaderNames = @()
        }
        # Downstream finds its columns by header name. Without one of these it
        # loses the rows, or cannot read the Quantity and dates of any row.
        $MissingColumns = @('ResourceId', 'MeterCategory', 'MeterSubCategory', 'MeterName', 'MeterId', 'Quantity', 'UsageStartTime', 'UsageEndTime' | Where-Object { $_ -notin $HeaderNames })
        if ($MissingColumns.Count -gt 0)
        {
            $Hint = if ($ConsumptionSource -eq 'gap') { 'Run this merge with -RecoverConsumption and a recovery bundle whose consumption file is whole.' } else { 'Re-run the recovery WITHOUT -SkipConsumption into a new folder, then run this merge again pointed at it.' }
            throw ("Merge-RecoveryData: the {0} bundle's consumption file '{1}' has no {2} column, which downstream needs to read its rows, so they would be dropped. Nothing was written to '{3}'. {4}" -f $ConsumptionSource, $ConsumptionSourceFile.FullName, ($MissingColumns -join ', '), $OutputPath, $Hint)
        }

        # Downstream drops the whole file in silence when one Quantity,
        # UsageStartTime or UsageEndTime cell, or one Cost or UnitPrice cell
        # where those columns exist, does not parse; a file cut mid-row by a
        # failed pull ends in such a row. Numbers are read with the invariant
        # culture (a dot, no thousands mark), as the tool writes them. A row
        # with an empty ResourceId or MeterId, or a negative Quantity, is only
        # dropped by itself, and the tool's own run writes such rows, so they
        # do not stop the merge (the gap, the recovery and a re-run would all
        # carry the same row, so a stop would never clear); one warning gives
        # their count instead.
        # One streaming pass reads the file row by row and keeps no row, so a
        # large file is never held in memory: it checks the cells, counts the
        # rows downstream drops one by one, notes whether there are rows and,
        # in a masked merge, the first row whose ResourceId is not masked (the
        # masking guard below reports it, after its own earlier checks).
        $Invariant = [System.Globalization.CultureInfo]::InvariantCulture
        $NumberColumns = @('Quantity', 'Cost', 'UnitPrice' | Where-Object { $_ -in $HeaderNames })
        $DateColumns = @('UsageStartTime', 'UsageEndTime')
        $CheckMaskedRows = [bool]($GapDictionaryFile -and $RecoveryDictionaryFile)
        $BadCell = $null
        $RowIndex = 0
        $DroppedRowCount = 0
        Import-Csv -LiteralPath $ConsumptionSourceFile.FullName -ErrorAction Stop | ForEach-Object {
            # After a bad cell the file stops the merge, so the rest is not checked.
            if ($null -ne $BadCell) { return }
            $Row = $_
            $RowIndex++
            $ConsumptionHasRows = $true
            $RowId = [string]$Row.ResourceId
            $RowDropped = ([string]::IsNullOrWhiteSpace($RowId) -or [string]::IsNullOrWhiteSpace([string]$Row.MeterId))
            foreach ($Column in $NumberColumns)
            {
                $Cell = $Row.$Column
                $Number = 0.0
                if (-not [double]::TryParse([string]$Cell, [System.Globalization.NumberStyles]::Float, $Invariant, [ref]$Number) -or [double]::IsNaN($Number) -or [double]::IsInfinity($Number))
                {
                    $BadCell = ("row {0} has a {1} of '{2}', which is not a number written with a dot and no thousands mark" -f $RowIndex, $Column, $Cell)
                    break
                }
                if ($Column -eq 'Quantity' -and $Number -lt 0) { $RowDropped = $true }
            }
            if ($RowDropped) { $DroppedRowCount++ }
            if ($null -eq $BadCell)
            {
                foreach ($Column in $DateColumns)
                {
                    $Cell = $Row.$Column
                    $Date = [datetimeoffset]::MinValue
                    if ([string]::IsNullOrWhiteSpace([string]$Cell) -or -not [datetimeoffset]::TryParse([string]$Cell, $Invariant, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$Date))
                    {
                        $BadCell = ("row {0} has a {1} of '{2}', which is not a date" -f $RowIndex, $Column, $Cell)
                        break
                    }
                }
            }
            # A row with an empty ResourceId is dropped downstream and names nothing.
            if ($CheckMaskedRows -and $ConsumptionUnmaskedRow -eq 0 -and -not [string]::IsNullOrEmpty($RowId) -and -not (Test-MergeMaskedId $RowId))
            {
                $ConsumptionUnmaskedRow = $RowIndex
            }
        }
        if ($null -ne $BadCell)
        {
            $Hint = if ($ConsumptionSource -eq 'gap') { 'Run this merge with -RecoverConsumption and a recovery bundle whose consumption file is whole.' } else { 'Re-run the recovery WITHOUT -SkipConsumption into a new folder, then run this merge again pointed at it.' }
            throw ("Merge-RecoveryData: the {0} bundle's consumption file '{1}' cannot be used: {2}. Downstream would drop the whole file, and with it every cost. Nothing was written to '{3}'. {4}" -f $ConsumptionSource, $ConsumptionSourceFile.FullName, $BadCell, $OutputPath, $Hint)
        }
        if ($DroppedRowCount -gt 0)
        {
            Add-MergeWarning ("the {0} bundle's consumption file '{1}' has {2} row(s) with an empty ResourceId or MeterId or a negative Quantity. Downstream drops each such row by itself; the rest of the file is used." -f $ConsumptionSource, $ConsumptionSourceFile.Name, $DroppedRowCount)
        }
    }
    $MetricsSourceLabel = if ($RecoverMetrics) { 'recovery' } else { 'gap' }
    $SelectedMetricsCount = 0
    $SelectedMetricRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($MetricsFile in @(if ($RecoverMetrics) { $RecoveryMetricsFiles } else { $GapMetricsFiles }))
    {
        $Problem = $null
        try
        {
            $MetricsText = Get-Content -LiteralPath $MetricsFile.FullName -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($MetricsText)) { $Problem = 'the file is empty' }
            else
            {
                $MetricsDoc = ConvertFrom-Json -InputObject $MetricsText -NoEnumerate -ErrorAction Stop
                if ($MetricsDoc -isnot [System.Management.Automation.PSCustomObject]) { $Problem = 'it is not a JSON object' }
                elseif ($MetricsDoc.PSObject.Properties.Name -notcontains 'Metrics') { $Problem = 'it has no Metrics list' }
                elseif ($MetricsDoc.Metrics -isnot [System.Array]) { $Problem = 'its Metrics is not a list' }
                else
                {
                    $SelectedMetricsCount += $MetricsDoc.Metrics.Count
                    $MetricIndex = 0
                    foreach ($MetricRecord in $MetricsDoc.Metrics)
                    {
                        $MetricIndex++
                        $Problem = Get-MetricRecordProblem $MetricRecord
                        if ($null -ne $Problem) { $Problem = ('metric {0} {1}' -f $MetricIndex, $Problem); break }
                        $SelectedMetricRecords.Add([PSCustomObject]@{ File = $MetricsFile.Name; Index = $MetricIndex; Record = $MetricRecord })
                    }
                }
            }
        }
        catch
        {
            $Problem = $_.Exception.Message
        }
        if ($null -ne $Problem)
        {
            $Hint = if ($MetricsSourceLabel -eq 'gap') { 'Run this merge with -RecoverMetrics and a recovery bundle whose metrics are whole.' } else { 'Re-run the recovery WITHOUT -SkipMetrics into a new folder, then run this merge again pointed at it.' }
            throw ("Merge-RecoveryData: the {0} bundle's metrics file '{1}' cannot be used: {2}. Downstream would drop every metric in the zip. Nothing was written to '{3}'. {4}" -f $MetricsSourceLabel, $MetricsFile.FullName, $Problem, $OutputPath, $Hint)
        }
    }

    # -- Guard: an empty ResourceIdMap in a masked merge. The shared-token
    #    check above is skipped when a ResourceIdMap is empty, because a masked
    #    run over a subscription with no resources writes an empty map. Every
    #    resource a masked run writes, in its inventory, consumption or metrics,
    #    gets a ResourceIdMap entry. So a bundle with an empty map that still
    #    gives this merge an inventory record, a consumption row or a metric was
    #    not masked by that dictionary (for example a plain run written into a
    #    folder that still holds an old masked run's dictionary), and its real
    #    names and ids would ship inside a masked bundle. That stops the merge.
    if ($GapDictionaryFile -and $RecoveryDictionaryFile)
    {
        $GapKeptKeys = @($GapInventory.PSObject.Properties.Name | Where-Object { $_ -ne 'Version' -and $_ -notin $MergeKeys })
        foreach ($Side in @(
                @{ Label = 'gap'; IdKeys = $GapIdKeys; Dict = $GapDictionaryFile; Inventory = $GapInventory; Keys = $GapKeptKeys },
                @{ Label = 'recovery'; IdKeys = $RecoveryIdKeys; Dict = $RecoveryDictionaryFile; Inventory = $RecoveryInventory; Keys = $MergeKeys }
            ))
        {
            if (@($Side.IdKeys).Count -gt 0) { continue }
            $Given = [System.Collections.Generic.List[string]]::new()
            $RecordCount = 0
            foreach ($Key in $Side.Keys) { $RecordCount += @($Side.Inventory.$Key | Where-Object { $null -ne $_ }).Count }
            if ($RecordCount -gt 0) { $Given.Add(('{0} inventory record(s)' -f $RecordCount)) }
            if ($ConsumptionHasRows -and $ConsumptionSource -eq $Side.Label) { $Given.Add('consumption rows') }
            if ($SelectedMetricsCount -gt 0 -and $MetricsSourceLabel -eq $Side.Label) { $Given.Add(('{0} metric(s)' -f $SelectedMetricsCount)) }
            if ($Given.Count -eq 0) { continue }
            $Way = if ($Side.Label -eq 'recovery') { "Re-run the recovery with -Obfuscate -ObfuscationDictionary '{0}'" -f $GapDictionaryFile.FullName } else { "Re-run the gap with -Obfuscate -ObfuscationDictionary '{0}'" -f $RecoveryDictionaryFile.FullName }
            throw ("Merge-RecoveryData: the {0} bundle's dictionary '{1}' has an empty ResourceIdMap, so that run masked no resource, but the {0} bundle gives this merge {2}. They were not masked with that dictionary, so real names and ids would ship inside a masked bundle. Nothing was written to '{3}'. If that run's own dictionary was moved, put it back in that folder. Otherwise {4} into a new folder (the default when -OutputDirectory is not set; a reused folder still holds the old files), then run this merge again pointed at it." -f $Side.Label, $Side.Dict.Name, ($Given -join ', '), $OutputPath, $Way)
        }

        # -- Guard: plain records in a masked merge. A dictionary whose
        #    ResourceIdMap is not empty says nothing about the files beside it:
        #    a plain run written into a folder that still holds an old masked
        #    run's dictionary gives real names and ids next to that dictionary.
        #    So every id this merge takes from a side must be masked: an
        #    inventory record's ID, a consumption row's ResourceId and a
        #    metric's ID. Masked means what Test-MergeMaskedId accepts: one
        #    flat token or 'obfuscated' (with or without a GUID), as this tool
        #    writes under -Obfuscate today, or an ARM path whose subscription,
        #    resource group and every name segment, parents included, are
        #    tokens. A side
        #    whose inventory records hold no token at all is plain too. The
        #    error names the file and the record, never the value. ------------
        foreach ($Side in @(
                @{ Label = 'gap'; Inventory = $GapInventory; Keys = $GapKeptKeys; InventoryFile = $GapInventoryFile },
                @{ Label = 'recovery'; Inventory = $RecoveryInventory; Keys = $MergeKeys; InventoryFile = $RecoveryInventoryFile }
            ))
        {
            $Way = if ($Side.Label -eq 'recovery') { "re-run the recovery with -Obfuscate -ObfuscationDictionary '{0}'" -f $GapDictionaryFile.FullName } else { "re-run the gap with -Obfuscate -ObfuscationDictionary '{0}'" -f $RecoveryDictionaryFile.FullName }
            $Found = $null
            $RecordCount = 0
            $SawMasked = $false
            foreach ($Key in $Side.Keys)
            {
                $Index = 0
                foreach ($Record in @($Side.Inventory.$Key))
                {
                    $Index++
                    if ($null -eq $Record) { continue }
                    $RecordCount++
                    $RecordId = if ($Record -is [System.Management.Automation.PSCustomObject] -and $Record.PSObject.Properties.Name -contains 'ID') { $Record.ID } else { $null }
                    if ($RecordId -is [string] -and $RecordId.Length -gt 0)
                    {
                        if (-not (Test-MergeMaskedId $RecordId)) { $Found = ("record {0} of '{1}' in '{2}' has an ID that is not masked" -f $Index, $Key, $Side.InventoryFile.Name); break }
                        $SawMasked = $true
                    }
                    elseif (-not $SawMasked -and [regex]::IsMatch((ConvertTo-Json -InputObject $Record -Depth 100 -Compress), $MergeTokenPattern, 'IgnoreCase'))
                    {
                        $SawMasked = $true
                    }
                }
                if ($null -ne $Found) { break }
            }
            if ($null -eq $Found -and $RecordCount -gt 0 -and -not $SawMasked)
            {
                $Found = ("its {0} inventory record(s) in '{1}' hold no masked token" -f $RecordCount, $Side.InventoryFile.Name)
            }
            if ($null -eq $Found -and $ConsumptionSource -eq $Side.Label -and $ConsumptionSourceFile)
            {
                # Found in the one pass over the file with the cell checks above.
                if ($ConsumptionUnmaskedRow -gt 0) { $Found = ("row {0} of the consumption file '{1}' has a ResourceId that is not masked" -f $ConsumptionUnmaskedRow, $ConsumptionSourceFile.Name) }
            }
            if ($null -eq $Found -and $MetricsSourceLabel -eq $Side.Label)
            {
                foreach ($MetricEntry in $SelectedMetricRecords)
                {
                    $MetricId = if ($MetricEntry.Record -is [System.Management.Automation.PSCustomObject] -and $MetricEntry.Record.PSObject.Properties.Name -contains 'ID') { $MetricEntry.Record.ID } else { $null }
                    if ($MetricId -is [string] -and $MetricId.Length -gt 0 -and -not (Test-MergeMaskedId $MetricId))
                    {
                        $Found = ("metric {0} of '{1}' has an ID that is not masked" -f $MetricEntry.Index, $MetricEntry.File)
                        break
                    }
                }
            }
            if ($null -eq $Found) { continue }
            throw ("Merge-RecoveryData: both bundles have a dictionary, so this is a masked merge, but in the {0} bundle {1}. That run was not masked, so real names and ids would ship inside a masked bundle. Nothing was written to '{2}'. If that folder holds a plain run next to an old masked run's dictionary, {3} into a new folder (the default when -OutputDirectory is not set; a reused folder still holds the old files), then run this merge again pointed at it." -f $Side.Label, $Found, $OutputPath, $Way)
        }
    }

    $SummaryScript = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'Extension/Summary.ps1'
    if (-not (Test-Path -LiteralPath $SummaryScript -PathType Leaf))
    {
        throw ("Merge-RecoveryData: report generator not found at '{0}'. Keep the Extension folder with the Functions folder. Nothing was written." -f $SummaryScript)
    }

    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container))
    {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $OutInventoryFile = Join-Path $OutputPath ("Inventory_{0}.json" -f $BundleBase)
    $OutConsumptionFile = Join-Path $OutputPath ("Consumption_{0}.csv" -f $BundleBase)
    $OutMetricsFile = Join-Path $OutputPath ("Metrics_{0}.json" -f $BundleBase)
    $OutHtmlFile = Join-Path $OutputPath ("{0}.html" -f $BundleBase)
    $OutZipFile = Join-Path $OutputPath ("{0}.zip" -f $BundleBase)
    $OutDictionaryFile = Join-Path $OutputPath ("ObfuscationDictionary_{0}.json" -f $BundleBase)

    # -- Write the merged inventory with Write-InventoryJson, as
    #    ResourceInventory.ps1 does: one collector at a time, so the whole
    #    document is never one string, and the same bytes as
    #    'ConvertTo-Json -Depth 100 -Compress | Out-File'. A failed write stops
    #    the merge and leaves no new, empty or partial inventory; an inventory
    #    already at $OutInventoryFile is left unchanged. -------------------------
    Write-InventoryJson -InputObject $GapInventory -Path $OutInventoryFile

    # -- Consumption source. By default carry the gap bundle's CSV forward: an
    #    inventory gap does not affect the whole-subscription consumption file.
    #    With -RecoverConsumption, whole-file REPLACE it with the recovery
    #    bundle's CSV instead (used when the gap run's consumption is missing or
    #    incomplete - e.g. truncated by a transient "copying content to a stream"
    #    error). Consumption ResourceUris keep the ARM path structure for
    #    categorisation. A ResourceUri that matches an inventory id exactly
    #    takes that resource's whole masked path from the run's ResourceIdMap;
    #    any other ResourceUri gets subscription, resource group and name
    #    tokens minted for that run's consumption file. So a replaced
    #    consumption file categorises correctly, but its tokens can differ
    #    from the gap run's, and a resource that is not in the inventory can
    #    carry subscription and resource group tokens different from the
    #    inventory's for the same real values. If the chosen
    #    source has none, write a canonical empty file so the bundle is
    #    structurally complete. --------------------------------------------------
    if ($RecoverConsumption)
    {

        # Guard: consumption row-shrink and billing-window drift. The recovery run
        # pulls a NOW-relative billing window, so a recovery done later than the
        # original run covers a DIFFERENT period; a whole-file replace then swaps
        # in that different window silently. Also flag a smaller row set (a
        # partial recovery pull). Both are warnings only - the replace is still
        # the right call for a truncated gap CSV.
        if ($GapConsumptionFile)
        {
            try
            {
                $GapConsumptionStats = Get-ConsumptionCsvStats -Path $GapConsumptionFile.FullName
                $RecoveryConsumptionStats = Get-ConsumptionCsvStats -Path $RecoveryConsumptionFile.FullName
                if ($GapConsumptionStats.RowCount -gt 0 -and $RecoveryConsumptionStats.RowCount -lt $GapConsumptionStats.RowCount)
                {
                    Add-MergeWarning ('the recovery consumption CSV has FEWER rows than the gap CSV ({0} vs {1}). -RecoverConsumption whole-file-replaces, so the extra gap rows will be dropped. Confirm the recovery consumption pull completed fully before shipping.' -f $RecoveryConsumptionStats.RowCount, $GapConsumptionStats.RowCount)
                }
                if ($GapConsumptionStats.RowCount -gt 0 -and $RecoveryConsumptionStats.RowCount -gt 0 -and ($GapConsumptionStats.MinStart -ne $RecoveryConsumptionStats.MinStart -or $GapConsumptionStats.MaxEnd -ne $RecoveryConsumptionStats.MaxEnd))
                {
                    Add-MergeWarning ('the recovery consumption billing window differs from the gap bundle''s (gap: {0}..{1}; recovery: {2}..{3}). The recovery run pulls a NOW-relative window, so the merged bundle''s consumption will reflect the recovery date, not the original run''s. Re-run recovery close to the original run date if the billing period must match.' -f $GapConsumptionStats.MinStart, $GapConsumptionStats.MaxEnd, $RecoveryConsumptionStats.MinStart, $RecoveryConsumptionStats.MaxEnd)
                }
            }
            catch
            {
                Add-MergeWarning ('could not compare the gap/recovery consumption CSVs (row-count/window check skipped): {0}' -f $_.Exception.Message)
            }
        }
    }
    if ($ConsumptionSourceFile)
    {
        Copy-Item -LiteralPath $ConsumptionSourceFile.FullName -Destination $OutConsumptionFile -Force
    }
    else
    {
        "InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId" | Out-File -LiteralPath $OutConsumptionFile -Encoding utf8
    }
    # -- Metrics source. By default carry ALL gap Metrics_*.json forward verbatim.
    #    The metrics phase writes one file per batch (Metrics_<base>__<idx>.json),
    #    so picking only the newest would silently drop batches; the gap files
    #    already carry this rebuilt bundle's <ReportName>_<stamp> base. With
    #    -RecoverMetrics, whole-file REPLACE them with the recovery bundle's
    #    metrics instead, REBASED to the output bundle name so the batch files
    #    stay consistent with the rest of the bundle. Metrics IDs are obfuscated
    #    via the seeded ResourceIdMap, so a recovery run seeded with the gap
    #    dictionary yields metrics tokens that match the merged inventory. Write a
    #    canonical empty file only if the chosen source has none.
    if ($RecoverMetrics)
    {
        # Recovery metrics carry the recovery run's base; rebase to $BundleBase.
        $RecoveryBase = $RecoveryInventoryFile.BaseName -replace '^Inventory_', ''
        foreach ($MetricsFile in $RecoveryMetricsFiles)
        {
            $Suffix = $MetricsFile.BaseName -replace ('^Metrics_' + [regex]::Escape($RecoveryBase)), ''
            $RebasedName = 'Metrics_' + $BundleBase + $Suffix + '.json'
            Copy-Item -LiteralPath $MetricsFile.FullName -Destination (Join-Path $OutputPath $RebasedName) -Force
        }
        $MetricsSource = 'recovery'
        # Advisory: the regenerated HTML does not render metrics (Summary.ps1
        # consumes inventory + consumption only), so recovering metrics updates
        # the zipped Metrics_*.json but leaves the HTML visually unchanged. Set
        # the operator's expectation so a "the report still looks the same"
        # observation is not mistaken for the recovery having failed.
        Add-MergeWarning ('recovered metrics were written to the bundle''s Metrics_*.json, but the regenerated HTML report does not render metrics (it uses inventory + consumption only). The zipped metrics JSON is updated; the HTML will look unchanged for metrics.')
    }
    else
    {
        if ($GapMetricsFiles.Count -gt 0)
        {
            foreach ($MetricsFile in $GapMetricsFiles)
            {
                Copy-Item -LiteralPath $MetricsFile.FullName -Destination (Join-Path $OutputPath $MetricsFile.Name) -Force
            }
        }
        else
        {
            @{ Metrics = @() } | ConvertTo-Json -Depth 5 -Compress | Out-File -LiteralPath $OutMetricsFile -Encoding utf8
        }
        $MetricsSource = 'gap'
    }

    # -- Merge the obfuscation dictionaries (LOCAL only, never zipped). Both runs
    #    share identical tokens (the recovery was seeded from the gap dict), so
    #    this is a union: start from the gap dictionary (a superset - the gap run
    #    extracted every resource) and add any map entries the recovery holds that
    #    the gap does not. Only meaningful for obfuscated bundles. ------------
    $DictionaryMerged = $false
    if ($GapDictionaryFile)
    {
        # Read and checked before anything was written (above).
        $MergedDictionary = $GapDictionary
        if ($RecoveryDictionaryFile)
        {
            foreach ($MapProp in $RecoveryDictionary.PSObject.Properties)
            {
                $MapName = $MapProp.Name
                if ($MapName -eq 'GeneratedAt') { continue }
                if ($null -eq $MergedDictionary.$MapName)
                {
                    $MergedDictionary | Add-Member -NotePropertyName $MapName -NotePropertyValue $MapProp.Value -Force
                    continue
                }
                foreach ($Entry in $MapProp.Value.PSObject.Properties)
                {
                    if ($null -eq $MergedDictionary.$MapName.$($Entry.Name))
                    {
                        $MergedDictionary.$MapName | Add-Member -NotePropertyName $Entry.Name -NotePropertyValue $Entry.Value -Force
                    }
                }
            }
        }
        $MergedDictionary | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $OutDictionaryFile -Encoding utf8
        $DictionaryMerged = $true
    }

    # -- Regenerate the HTML report from the merged inventory via Summary.ps1.
    #    Located relative to this functions file (Functions/ -> ../Extension);
    #    checked before anything was written (above). --
    $ReportVersion = if ($GapInventory.PSObject.Properties.Name -contains 'Version') { $GapInventory.Version } else { $null }
    & $SummaryScript -JsonFile $OutInventoryFile -HtmlFile $OutHtmlFile -Title 'Azure Resource Inventory' -Version $ReportVersion -ConsumptionFile $OutConsumptionFile | Out-Null

    # -- Re-zip, mirroring ResourceInventory.ps1's packaging filter: HTML +
    #    Consumption CSV + every *.json EXCEPT the local-only dictionary/Full/
    #    Heartbeat/ErrorLog files. The dictionary is deliberately NOT zipped. ---
    $ZipJsonFiles = Get-ChildItem -LiteralPath $OutputPath -Filter '*.json' |
        Where-Object { $_.Name -notlike 'ObfuscationDictionary_*' -and $_.Name -notlike 'Full_*' -and $_.Name -notlike 'Heartbeat_*' -and $_.Name -notlike 'ErrorLog_*' } |
        Select-Object -ExpandProperty FullName
    $ZipPaths = @($OutHtmlFile, $OutConsumptionFile) + $ZipJsonFiles
    if (Test-Path -LiteralPath $OutZipFile) { Remove-Item -LiteralPath $OutZipFile -Force }
    # -DestinationPath has no literal form, so its wildcard characters are escaped.
    Compress-Archive -LiteralPath $ZipPaths -CompressionLevel Fastest -DestinationPath ([WildcardPattern]::Escape($OutZipFile))

    # -- Report what was done -------------------------------------------------
    return [PSCustomObject]@{
        MergedServiceKeys = $MergeKeys
        ConsumptionSource = $ConsumptionSource
        MetricsSource     = $MetricsSource
        OutputInventory   = $OutInventoryFile
        OutputHtml        = $OutHtmlFile
        OutputZip         = $OutZipFile
        OutputDictionary  = if ($DictionaryMerged) { $OutDictionaryFile } else { $null }
        BundleBase        = $BundleBase
        Warnings          = @($MergeWarnings)
    }
}
