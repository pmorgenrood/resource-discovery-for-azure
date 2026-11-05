#requires -Version 7.0
param(
    $Subscriptions,
    $Resources, # The massive list of raw discovered infrastructure items (VMs, Disks, DBs)
    $Task, # String tracking the script task mode (e.g., 'Processing')
    $ConcurrencyLimit, # Number of concurrent threads allowed to run simultaneously
    $FilePath, # Root destination directory path for saving JSON data chunks
    $ResourceIdDictionary, # Map dictionary to replace original Resource IDs with obfuscated GUID values
    $ResourceNameDictionary, # Map dictionary to mask the actual human-readable names of the items
    [Alias('ResourceSubscriptionDictionary')]$ResourceSubDictionary, # Map dictionary to obfuscate subscription names
    [Alias('ResourceResourceGroupDictionary')]$ResourceGroupDictionary, # Map dictionary to obfuscate resource group names
    $Obfuscate, # Boolean flag toggle indicating whether sensitive infrastructure details should be masked
    $MetricsLookbackDays = 31, # Default tracking duration window determining how far back to ask Azure for data
    # Opt-in: ask the Azure Monitor batch API (metrics:getBatch) for up to 50
    # resources of one subscription, region and type in one request. Anything it
    # cannot answer goes through the per-resource Get-AzMetric path below.
    [switch]$UseMetricsBatch,
    # Subscriptions the -UseMetricsBatch preflight left without Microsoft.Insights
    # (the person said no, nobody could answer, the register failed or did not
    # finish in time): their metrics stay on the per-resource path this run.
    [string[]]$MetricsBatchPerCallSubscriptionIds = @(),
    # The batch API's regional endpoint, {0} being the region. Internal: tests
    # point it at a local listener.
    [string]$MetricsBatchEndpointFormat = 'https://{0}.metrics.monitor.azure.com',
    # Internal: seconds each Azure Monitor request may take. Tests lower it.
    [int]$MetricsCallTimeoutSeconds = 120
)


if (-not (Get-Command -Name 'Write-RdaProgress' -ErrorAction SilentlyContinue))
{
    $CommonFunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1'
    if (Test-Path -Path $CommonFunctionsFile -PathType Leaf)
    {
        . $CommonFunctionsFile
    }
}


if (-not (Get-Command -Name 'Resolve-ObfuscationToken' -ErrorAction SilentlyContinue))
{
    function Resolve-ObfuscationToken
    {
        param(
            [string]$RealValue,
            [string]$LookupKey,
            $SharedDictionary,
            [hashtable]$LocalCache,
            [string]$TokenPrefix
        )

        if ($null -ne $SharedDictionary -and $SharedDictionary.ContainsKey($LookupKey)) { return $SharedDictionary[$LookupKey] }
        if ($LocalCache.ContainsKey($RealValue)) { return $LocalCache[$RealValue] }

        $Token = $TokenPrefix + [guid]::NewGuid().ToString()
        $LocalCache[$RealValue] = $Token
        return $Token
    }
}

if (-not (Get-Command -Name 'Build-ObfuscatedResourceUri' -ErrorAction SilentlyContinue))
{
    function Build-ObfuscatedResourceUri
    {
        param(
            [string]$RawUri,
            [string]$Prefix,
            $SubscriptionDictionary,
            $ResourceGroupDictionary,
            $NameDictionary,
            [hashtable]$SubCache,
            [hashtable]$RgCache,
            [hashtable]$NameCache
        )

        if ([string]::IsNullOrEmpty($RawUri))
        {
            return 'obfuscated'
        }

        if ($RawUri -notmatch '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/(.+))?$')
        {
            if (-not $NameCache.ContainsKey($RawUri))
            {
                $NameCache[$RawUri] = $Prefix + [guid]::NewGuid().ToString()
            }
            return $NameCache[$RawUri]
        }

        $RealSub = $Matches[1]
        $RealRg = $Matches[3]
        $RealProv = $Matches[5]

        $ObfSub = Resolve-ObfuscationToken -RealValue $RealSub -LookupKey $RawUri -SharedDictionary $SubscriptionDictionary -LocalCache $SubCache -TokenPrefix ($Prefix + 'sub_')

        $RebuiltUri = '/subscriptions/' + $ObfSub

        if (-not [string]::IsNullOrEmpty($RealRg))
        {
            $RgTag = if ($RealRg -match '^mc_') { 'mc_' } else { '' }
            $ObfRg = Resolve-ObfuscationToken -RealValue $RealRg -LookupKey $RawUri -SharedDictionary $ResourceGroupDictionary -LocalCache $RgCache -TokenPrefix ($Prefix + 'rg_' + $RgTag)
            $RebuiltUri += '/resourcegroups/' + $ObfRg
        }

        if (-not [string]::IsNullOrEmpty($RealProv))
        {
            $ProvParts = $RealProv -split '/'
            $Rebuilt = @()
            for ($Pi = 0; $Pi -lt $ProvParts.Count; $Pi++)
            {
                $Part = $ProvParts[$Pi]
                $IsNameSegment = ($Pi -ge 2 -and ($Pi % 2 -eq 0))
                if ($IsNameSegment -and -not [string]::IsNullOrEmpty($Part) -and $Part -ne '$system')
                {
                    $NameSharedDict = if ($Pi -eq $ProvParts.Count - 1) { $NameDictionary } else { $null }
                    $Rebuilt += Resolve-ObfuscationToken -RealValue $Part -LookupKey $RawUri -SharedDictionary $NameSharedDict -LocalCache $NameCache -TokenPrefix $Prefix
                }
                else
                {
                    $Rebuilt += $Part
                }
            }
            $RebuiltUri += '/providers/' + ($Rebuilt -join '/')
        }

        return $RebuiltUri
    }
}

# For the summary log: of the given resource ids (Azure Monitor answered 404 for them), the ones
# Resource Graph lists as being deleted, mapped to that state (for example a PostgreSQL flexible
# server whose properties.state is 'Dropping'). Read only for those ids, so a run with no 404
# reads nothing. Matching ignores case.
function Get-MetricDeletingState
{
    param($Resources, [string[]]$Ids)

    $Found = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (@($Ids).Count -eq 0) { return $Found }
    $Wanted = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Ids), [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Resource in $Resources)
    {
        $Id = [string]$Resource.Id
        if ([string]::IsNullOrEmpty($Id) -or -not $Wanted.Contains($Id) -or $Found.ContainsKey($Id)) { continue }
        $Properties = $Resource.properties
        if ($null -eq $Properties) { continue }
        foreach ($Field in 'state', 'status', 'provisioningState')
        {
            $Value = [string]$Properties.$Field
            if ($Value -match '^(dropping|deleting)$')
            {
                $Found[$Id] = $Value
                break
            }
        }
    }
    return $Found
}

# Definitions of one resource that share a time window, time grain and aggregation
# can be fetched with one Get-AzMetric call, since -MetricName takes several names.
# -AggregationType takes a single value, so different aggregations stay separate
# calls. Time grains are compared as TimeSpan, so '1:00:00' and '01:00:00' match.
function Get-MetricGroupKey
{
    param($Def)

    $Grain = [timespan]::Zero
    $GrainKey = if ([timespan]::TryParse([string]$Def.Interval, [cultureinfo]::InvariantCulture, [ref]$Grain)) { $Grain.Ticks } else { [string]$Def.Interval }
    return ('{0}|{1}|{2}|{3}' -f ([datetime]$Def.StartTime).Ticks, ([datetime]$Def.EndTime).Ticks, $GrainKey, $Def.Aggregation)
}

# Returns a list of groups; each group is an array of definitions, in their original
# order, that can share one Get-AzMetric call. A resource's definitions are added
# consecutively, so grouping only looks within a run of definitions that share the
# same resource Id. Azure Monitor accepts at most 20 metric names in one request, so
# a group holds at most $MaxMetricNames distinct names; definitions that share a
# metric name stay in the same group.
function Group-MetricDefinition
{
    param($MetricDefs, [int]$MaxMetricNames = 20)

    $MetricGroups = [System.Collections.Generic.List[object]]::new()
    $ResourceGroups = [ordered]@{}
    $GroupResourceId = $null
    foreach ($Def in $MetricDefs)
    {
        if (-not [string]::Equals([string]$Def.Id, $GroupResourceId, [System.StringComparison]::Ordinal))
        {
            foreach ($Members in $ResourceGroups.Values) { $MetricGroups.Add($Members.ToArray()) }
            $ResourceGroups.Clear()
            $GroupResourceId = [string]$Def.Id
        }
        $GroupKey = Get-MetricGroupKey -Def $Def
        if (-not $ResourceGroups.Contains($GroupKey)) { $ResourceGroups[$GroupKey] = [System.Collections.Generic.List[object]]::new() }
        $ResourceGroups[$GroupKey].Add($Def)
    }
    foreach ($Members in $ResourceGroups.Values) { $MetricGroups.Add($Members.ToArray()) }

    # Split every group that names more than $MaxMetricNames metrics.
    $Capped = [System.Collections.Generic.List[object]]::new()
    foreach ($Group in $MetricGroups)
    {
        $Chunks = [System.Collections.Generic.List[object]]::new()
        $ChunkOfName = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $NamesInLast = 0
        foreach ($Def in $Group)
        {
            $Name = [string]$Def.MetricName
            if (-not $ChunkOfName.ContainsKey($Name))
            {
                if ($Chunks.Count -eq 0 -or $NamesInLast -ge $MaxMetricNames)
                {
                    $Chunks.Add([System.Collections.Generic.List[object]]::new())
                    $NamesInLast = 0
                }
                $ChunkOfName[$Name] = $Chunks.Count - 1
                $NamesInLast++
            }
            $Chunks[$ChunkOfName[$Name]].Add($Def)
        }
        foreach ($Chunk in $Chunks) { $Capped.Add($Chunk.ToArray()) }
    }

    Write-Output -NoEnumerate -InputObject $Capped
}

# What the batch API needs to know of one resource id: its subscription and its
# metric namespace (the resource type, lower case, for example
# 'microsoft.sql/servers/databases'). $null when the id is not a plain ARM
# resource id (no resource group, an extension resource with a second
# '/providers/', an odd number of type and name parts), which the batch call
# cannot express, so that resource keeps the per-resource path.
function Get-MetricBatchTarget
{
    param([string]$Id)

    if ([string]::IsNullOrEmpty($Id)) { return $null }
    if ($Id -notmatch '^/subscriptions/([^/]+)/resourcegroups/[^/]+/providers/(.+)$') { return $null }
    $SubscriptionId = $Matches[1]
    $ProviderPart = $Matches[2]
    if ($ProviderPart -match '(?i)/providers/') { return $null }
    $Parts = @($ProviderPart -split '/')
    if ($Parts.Count -lt 3 -or ($Parts.Count % 2) -ne 1) { return $null }
    foreach ($Part in $Parts) { if ([string]::IsNullOrEmpty($Part)) { return $null } }
    $Types = for ($Pi = 1; $Pi -lt $Parts.Count; $Pi += 2) { $Parts[$Pi] }
    return [pscustomobject]@{
        SubscriptionId = $SubscriptionId.ToLowerInvariant()
        Namespace      = (@($Parts[0]) + @($Types) -join '/').ToLowerInvariant()
    }
}

# A time grain as the batch API takes it (ISO 8601: 'PT1H', 'P1D', 'PT1M'), or
# $null when it is not a time span.
function ConvertTo-MetricBatchInterval
{
    param($Interval)

    $Grain = [timespan]::Zero
    if (-not [timespan]::TryParse([string]$Interval, [cultureinfo]::InvariantCulture, [ref]$Grain) -or $Grain -le [timespan]::Zero) { return $null }
    return [System.Xml.XmlConvert]::ToString($Grain)
}

# Splits the per-resource groups (Group-MetricDefinition) into work items, in
# order of first appearance:
#   - a batch unit: groups of up to $MaxResources distinct resources that share
#     subscription, region, namespace, metric-name set, time window, time grain
#     and aggregation, so one getBatch request answers all of them;
#   - a plain group (the group's own array), for a group the batch call cannot
#     express, or of a subscription not in $AllowedSubscriptionIds; it goes
#     through the per-resource path exactly as without -UseMetricsBatch.
# Resource ids are compared without case. A resource listed twice joins the
# same unit and each of its groups gets the same answer.
function New-MetricBatchPlan
{
    param(
        $MetricGroups,
        $AllowedSubscriptionIds,
        [int]$MaxResources = 50
    )

    $Allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($AllowedId in @($AllowedSubscriptionIds)) { if (-not [string]::IsNullOrEmpty([string]$AllowedId)) { [void]$Allowed.Add([string]$AllowedId) } }
    $Aggregations = @('Average', 'Maximum', 'Minimum', 'Total', 'Count')

    $Items = [System.Collections.Generic.List[object]]::new()
    $OpenUnits = @{}
    foreach ($Group in $MetricGroups)
    {
        $First = $Group[0]
        $Target = Get-MetricBatchTarget -Id ([string]$First.Id)
        $Region = ([string]$First.Location).ToLowerInvariant()
        $IsoGrain = ConvertTo-MetricBatchInterval -Interval $First.Interval
        $Expressible = $null -ne $Target -and $Allowed.Contains($Target.SubscriptionId) -and $Region -match '^[a-z0-9]+$' -and $Region -ne 'global' -and $null -ne $IsoGrain -and $Aggregations -contains [string]$First.Aggregation -and $First.StartTime -is [datetime] -and $First.EndTime -is [datetime]
        if (-not $Expressible)
        {
            $Items.Add($Group)
            continue
        }

        # Distinct names without regard to case, as Group-MetricDefinition groups them.
        $NameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Names = [string[]]@($Group | ForEach-Object { [string]$_.MetricName } | Where-Object { $NameSet.Add($_) })
        $NameKey = (@($Names | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object) -join '|')
        $Key = '{0}|{1}|{2}|{3}|{4}' -f $Target.SubscriptionId, $Region, $Target.Namespace, $NameKey, (Get-MetricGroupKey -Def $First)
        $ResourceKey = ([string]$First.Id).TrimEnd('/').ToLowerInvariant()

        $Unit = $OpenUnits[$Key]
        if ($null -ne $Unit -and -not $Unit.ResourceSet.Contains($ResourceKey) -and $Unit.ResourceSet.Count -ge $MaxResources)
        {
            $Unit = $null
        }
        if ($null -eq $Unit)
        {
            $Unit = [pscustomobject]@{
                RdaBatchUnit   = $true
                SubscriptionId = $Target.SubscriptionId
                Region         = $Region
                Namespace      = $Target.Namespace
                MetricNames    = $Names
                Aggregation    = [string]$First.Aggregation
                Interval       = $IsoGrain
                StartTime      = ([datetime]$First.StartTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture)
                EndTime        = ([datetime]$First.EndTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture)
                Groups         = [System.Collections.Generic.List[object]]::new()
                ResourceIds    = [System.Collections.Generic.List[string]]::new()
                ResourceSet    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                DefCount       = 0
            }
            $OpenUnits[$Key] = $Unit
            $Items.Add($Unit)
        }
        if ($Unit.ResourceSet.Add($ResourceKey)) { $Unit.ResourceIds.Add($ResourceKey) }
        $Unit.Groups.Add($Group)
        $Unit.DefCount += @($Group).Count
    }

    Write-Output -NoEnumerate -InputObject $Items
}

# The number of metric definitions in one work item: a plain group (an array)
# or a batch unit.
function Get-MetricWorkItemDefCount
{
    param($Item)
    if ($Item -is [System.Array]) { return $Item.Count }
    if ($null -ne $Item.PSObject.Properties['DefCount']) { return [int]$Item.DefCount }
    return @($Item).Count
}

if ($Task -eq 'Processing')
{
    function Write-MetricsDiag([string]$Line)
    {
        Write-Log -Message ('[Metrics] ' + $Line) -NoConsole -ToDebugLog
    }
    # Instantiate a clean, empty generic PowerShell Custom Object container
    $Tmp = New-Object PSObject

    # Attach a custom note property placeholder string to hold metrics arrays later on
    $Tmp | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet

    # Swap the placeholder property value for a highly optimized, thread-safe concurrent collection bucket
    $Tmp.Metrics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

    # Create a dynamic, variable-length list array to track specific metric request definitions
    $MetricDefs = [System.Collections.Generic.List[object]]::new()

    # Convert the lookback parameter integer into a clean negative integer value for time calculations
    $MetricsLookbackPeriodDays = -1 * [math]::Abs([int]$MetricsLookbackDays)

    # Calculate the exact starting time date object by rolling back the calendar based on the lookback value
    $MetricStartTime = (Get-Date).AddDays($MetricsLookbackPeriodDays)

    # Record the precise real-time timestamp representing the current end time marker
    $MetricEndTime = (Get-Date)
    # Establish an offset timestamp rolled back exactly 24 hours ago
    $MetricTimeOneDay = (Get-Date).AddDays(-1)

    $SubLookup = @{}
    foreach ($subItem in $Subscriptions)
    {
        if ($null -ne $subItem -and ![string]::IsNullOrEmpty($subItem.id))
        {
            $SubLookup[$subItem.id] = $subItem
        }
    }

    # Define VM Metrics
    $VirtualMachines = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachines' }

    $MetricCountId = 1;

    if ($VirtualMachines)
    {
        foreach ($virtualMachine in $VirtualMachines)
        {
            $Subscription = $SubLookup[$virtualMachine.subscriptionId]
            # Construct and append a custom configuration object onto the main definitions table for CPU metrics
            $MetricDefs.Add([PSCustomObject]@{
                    MetricIndex = $MetricCountId++;
                    MetricName = 'Percentage CPU';
                    StartTime = $MetricStartTime;
                    EndTime = $MetricEndTime;
                    Interval = '1:00:00';
                    Aggregation = 'Maximum';
                    Measure = 'Average';
                    Id = $virtualMachine.Id;
                    SubName = $Subscription.Name;
                    ResourceGroup = $virtualMachine.ResourceGroup;
                    Name = $virtualMachine.Name;
                    Location = $virtualMachine.Location;
                    Service = 'Virtual Machines';
                    Series = 'true'
                })
            # Construct and append an additional layout tracking object focused strictly on VM memory capacity
            $MetricDefs.Add([PSCustomObject]@{
                    MetricIndex = $MetricCountId++;
                    MetricName = 'Available Memory Bytes';
                    StartTime = $MetricStartTime;
                    EndTime = $MetricEndTime;
                    Interval = '1:00:00';
                    Aggregation = 'Minimum';
                    Measure = 'Average';
                    Id = $virtualMachine.Id;
                    SubName = $Subscription.Name;
                    ResourceGroup = $virtualMachine.ResourceGroup;
                    Name = $virtualMachine.Name;
                    Location = $virtualMachine.Location;
                    Service = 'Virtual Machines';
                    Series = 'true'
                })
        }
    }

    $ManagedDisks = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/disks' -and -not [string]::IsNullOrEmpty($_.ManagedBy) }

    if ($ManagedDisks)
    {
        foreach ($managedDisk in $ManagedDisks)
        {
            $Subscription = $SubLookup[$managedDisk.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Read Operations/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Write Operations/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Read Bytes/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Composite Disk Write Bytes/sec'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $managedDisk.Id; SubName = $Subscription.Name; ResourceGroup = $managedDisk.ResourceGroup; Name = $managedDisk.Name; Location = $managedDisk.Location; Service = 'Managed Disk'; Series = 'true' })
        }
    }

    #Define SQL Metrics

    $SqlDatabases = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/servers/databases' -and $_.name -ne 'master' }

    if ($SqlDatabases)
    {
        foreach ($sqlDb in $SqlDatabases)
        {
            $Subscription = $SubLookup[$sqlDb.subscriptionId]

            if ($sqlDb.kind -match 'vcore')
            {
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_limit'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_used'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })

                if ($sqlDb.kind -match 'serverless')
                {
                    $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'app_cpu_billed'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '0.00:01:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                }
            }
            else
            {
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'dtu_limit'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'dtu_used'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })
            }

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'allocated_data_storage'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Average'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'physical_data_read_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'log_write_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Largest'; Id = $sqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $sqlDb.ResourceGroup; Name = $sqlDb.Name; Location = $sqlDb.Location; Service = 'SQL Database'; Series = 'false' })
        }
    }

    # Define App Service Metrics

    $AppServices = $Resources | Where-Object { $_.TYPE -eq 'microsoft.web/sites' }

    if ($AppServices)
    {
        foreach ($app in $AppServices)
        {
            $Subscription = $SubLookup[$app.subscriptionId]

            if ($app.kind -match 'functionapp')
            {
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'FunctionExecutionCount'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $Subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
                $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'FunctionExecutionUnits'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '1.00:00:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $app.Id; SubName = $Subscription.Name; ResourceGroup = $app.ResourceGroup; Name = $app.Name; Location = $app.Location; Service = 'Functions'; Series = 'false' })
            }
        }
    }

    # Define MariaDB Metrics

    $MariaDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.dbformariadb/servers' }

    if ($MariaDbs)
    {
        foreach ($mariaDb in $MariaDbs)
        {
            $Subscription = $SubLookup[$mariaDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mariaDb.Id; SubName = $Subscription.Name; ResourceGroup = $mariaDb.ResourceGroup; Name = $mariaDb.Name; Location = $mariaDb.Location; Service = 'MariaDB'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mariaDb.Id; SubName = $Subscription.Name; ResourceGroup = $mariaDb.ResourceGroup; Name = $mariaDb.Name; Location = $mariaDb.Location; Service = 'MariaDB'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Maximum'; Id = $mariaDb.Id; SubName = $Subscription.Name; ResourceGroup = $mariaDb.ResourceGroup; Name = $mariaDb.Name; Location = $mariaDb.Location; Service = 'MariaDB'; Series = 'false' })
        }
    }

    # Define PostgreSQL Metrics

    $PostgresDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.dbforpostgresql/servers' }

    if ($PostgresDbs)
    {
        foreach ($postgreDb in $PostgresDbs)
        {
            $Subscription = $SubLookup[$postgreDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL'; Series = 'false' })
        }
    }

    # Define MySQL Metrics

    $MySqldbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.DBforMySQL/servers' }

    if ($MySqldbs)
    {
        foreach ($mysqlDb in $MySqldbs)
        {
            $Subscription = $SubLookup[$mysqlDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL'; Series = 'false' })
        }
    }

    # Define MySQL Flexible Metrics

    $MySqldbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.DBforMySQL/flexibleServers' }

    if ($MySqldbs)
    {
        foreach ($mysqlDb in $MySqldbs)
        {
            $Subscription = $SubLookup[$mysqlDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL Flexible'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL Flexible'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Maximum'; Id = $mysqlDb.Id; SubName = $Subscription.Name; ResourceGroup = $mysqlDb.ResourceGroup; Name = $mysqlDb.Name; Location = $mysqlDb.Location; Service = 'MySQL Flexible'; Series = 'false' })
        }
    }

    # Define PostgreSQL Flexible Metrics

    $PostgresDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.DBforPostgreSQL/flexibleServers' }

    if ($PostgresDbs)
    {
        foreach ($postgreDb in $PostgresDbs)
        {
            $Subscription = $SubLookup[$postgreDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'cpu_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL Flexible'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'memory_percent'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL Flexible'; Series = 'true' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'storage_percent'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Average'; Measure = 'Maximum'; Id = $postgreDb.Id; SubName = $Subscription.Name; ResourceGroup = $postgreDb.ResourceGroup; Name = $postgreDb.Name; Location = $postgreDb.Location; Service = 'PostgreSQL Flexible'; Series = 'false' })
        }
    }

    # Define Scale Set Metrics

    $VmScaleSets = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/virtualmachinescalesets' }

    if ($VmScaleSets)
    {
        foreach ($vmss in $VmScaleSets)
        {
            $Subscription = $SubLookup[$vmss.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Percentage CPU'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Average'; Id = $vmss.Id; SubName = $Subscription.Name; ResourceGroup = $vmss.ResourceGroup; Name = $vmss.Name; Location = $vmss.Location; Service = 'Virtual Machines Scale Sets'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'Available Memory Bytes'; StartTime = $MetricStartTime; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Minimum'; Measure = 'Average'; Id = $vmss.Id; SubName = $Subscription.Name; ResourceGroup = $vmss.ResourceGroup; Name = $vmss.Name; Location = $vmss.Location; Service = 'Virtual Machines Scale Sets'; Series = 'false' })
        }
    }

    # Define CosmosDB Metrics

    $CosmosDbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.documentdb/databaseaccounts' }

    if ($CosmosDbs)
    {
        foreach ($cosmosDb in $CosmosDbs)
        {
            $Subscription = $SubLookup[$cosmosDb.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'TotalRequests'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '00:01:00'; Aggregation = 'Count'; Measure = 'Largest'; Id = $cosmosDb.Id; SubName = $Subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'TotalRequestUnits'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '00:01:00'; Aggregation = 'Total'; Measure = 'Sum'; Id = $cosmosDb.Id; SubName = $Subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'DataUsage'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Total'; Measure = 'Largest'; Id = $cosmosDb.Id; SubName = $Subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'ProvisionedThroughput'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $cosmosDb.Id; SubName = $Subscription.Name; ResourceGroup = $cosmosDb.ResourceGroup; Name = $cosmosDb.Name; Location = $cosmosDb.Location; Service = 'CosmosDB'; Series = 'false' })
        }
    }

    # Define Container Registry Metrics

    $ContainerRegistry = $Resources | Where-Object { $_.TYPE -eq 'microsoft.containerregistry/registries' }

    if ($ContainerRegistry)
    {
        foreach ($registry in $ContainerRegistry)
        {
            $Subscription = $SubLookup[$registry.subscriptionId]

            $MetricDefs.Add([PSCustomObject]@{ MetricIndex = $MetricCountId++; MetricName = 'StorageUsed'; StartTime = $MetricTimeOneDay; EndTime = $MetricEndTime; Interval = '01:00:00'; Aggregation = 'Maximum'; Measure = 'Largest'; Id = $registry.Id; SubName = $Subscription.Name; ResourceGroup = $registry.ResourceGroup; Name = $registry.Name; Location = $registry.Location; Service = 'ContainerRegistry'; Series = 'false' })
        }
    }


    $MetricCount = $MetricDefs.Count
    $WarningPreference = "SilentlyContinue"
    $MetricAzContext = $null

    try
    {
        $MetricAzContext = (Get-AzContext)
    }
    catch
    {
        Write-MetricsDiag "WARNING: could not capture Az context for parallel runspaces; metric calls will rely on per-runspace context autosave."
    }

    $MetricTimeoutSeconds = $MetricsCallTimeoutSeconds
    $MetricMaxRetries = 3
    # Throttling (429) has its OWN retry budget and honours the server's Retry-After: a throttle wave used to exhaust
    # the 3 generic retries in ~28s and record the metric as failed, when waiting the directed few seconds would have succeeded.
    $MetricMaxThrottleRetries = 6
    $MetricMaxRetryAfterSeconds = 120
    # Get-RdaRetryAfterSeconds (Functions/ResourceInventory.Functions.ps1) is not visible inside -Parallel runspaces; ship its definition.
    $MetricRetryAfterFnDef = if (Get-Command Get-RdaRetryAfterSeconds -CommandType Function -ErrorAction SilentlyContinue) { ${function:Get-RdaRetryAfterSeconds}.ToString() } else { $null }


    $MetricDiagnostics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()
    # Get-AzMetric request counts for the summary: [0] every request, [1] single-metric
    # fallback requests. The parallel runspaces share this array and update it under a
    # lock (Monitor) on the array itself.
    $MetricRequestCounts = [long[]]::new(2)

    # $MetricCount is the number of definitions to send, as it was when the batch
    # loop counted definitions: with none to send, no group and no call is made.
    if ($MetricCount -gt 0)
    {
        $MetricGroups = Group-MetricDefinition -MetricDefs $MetricDefs
    }
    else
    {
        $MetricGroups = [System.Collections.Generic.List[object]]::new()
    }

    # -UseMetricsBatch: which subscriptions may use the batch API, and a token
    # for the metrics data plane per tenant. A subscription left out keeps the
    # per-resource path, with one line in the debug log saying why.
    $UseBatchApi = $false
    # Batch counts for the summary: [0] requests (retries not counted),
    # [1] attempts, [2] resources asked, [3] resources answered, [4] definitions
    # answered, [5] definitions sent on to the per-resource path. Shared by the
    # parallel batch runspaces under a lock (Monitor) on the array itself.
    $MetricBatchCounts = [long[]]::new(6)
    # Subscription id -> why batch was turned off for it during the phase (the
    # data plane refused the token or the caller: 401 or 403).
    $MetricBatchOffSubs = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $MetricBatchNotes = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    # Tenants whose token was renewed after a 401 and has not worked since: a
    # second 401 for one of them turns batch off for that tenant for the rest of
    # the phase. A request that works with the renewed token clears it.
    $MetricBatchTokenRenewed = @{}
    $MetricBatchTokens = @{}
    $MetricBatchTenantOfSub = @{}
    if ($UseMetricsBatch -and $MetricGroups.Count -gt 0)
    {
        $BatchEnvironment = if ($null -ne $MetricAzContext -and $null -ne $MetricAzContext.Environment) { [string]$MetricAzContext.Environment.Name } else { '' }
        # The token is sent to this host, so only the Azure Monitor endpoint (or a
        # loopback listener, for tests) is accepted.
        $EndpointOk = $MetricsBatchEndpointFormat -ceq 'https://{0}.metrics.monitor.azure.com' -or $MetricsBatchEndpointFormat -match '^http://(127\.0\.0\.1|localhost)(:\d+)?/'
        if (-not $EndpointOk)
        {
            Write-MetricsDiag "[batch] -UseMetricsBatch: the batch endpoint is not the Azure Monitor one; every metric uses the per-resource path."
        }
        elseif ($BatchEnvironment -ne 'AzureCloud')
        {
            Write-MetricsDiag ("[batch] -UseMetricsBatch: the Azure environment is '{0}', not AzureCloud; the batch endpoint is only known for AzureCloud, so every metric uses the per-resource path." -f $BatchEnvironment)
        }
        else
        {
            $BatchSubIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($Group in $MetricGroups)
            {
                $Target = Get-MetricBatchTarget -Id ([string]$Group[0].Id)
                if ($null -ne $Target) { [void]$BatchSubIds.Add($Target.SubscriptionId) }
            }
            $SubTenant = @{}
            foreach ($subItem in $Subscriptions)
            {
                if ($null -ne $subItem -and -not [string]::IsNullOrEmpty([string]$subItem.id))
                {
                    $TenantOfSub = [string]$subItem.tenantId
                    $SubTenant[([string]$subItem.id).ToLowerInvariant()] = $TenantOfSub
                }
            }
            $AllowedBatchSubs = [System.Collections.Generic.List[string]]::new()
            $PreflightPerCall = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($PerCallId in @($MetricsBatchPerCallSubscriptionIds)) { if (-not [string]::IsNullOrEmpty([string]$PerCallId)) { [void]$PreflightPerCall.Add([string]$PerCallId) } }
            foreach ($BatchSub in $BatchSubIds)
            {
                if ($PreflightPerCall.Contains($BatchSub))
                {
                    Write-MetricsDiag ("[batch] subscription {0} was left without Microsoft.Insights at the start of the run; its metrics use the per-resource path this run." -f $BatchSub)
                    continue
                }
                # The provider must be registered: the batch API answers 403 otherwise.
                # The preflight offered to register it; this only reads the state.
                $ProviderRead = Get-RdaInsightsProviderState -SubscriptionId $BatchSub
                if ($ProviderRead.State -ne 'Registered' -and $ProviderRead.State -ne 'Unknown')
                {
                    Write-MetricsDiag ("[batch] Microsoft.Insights is '{0}' on subscription {1}; its metrics use the per-resource path. Register it to batch: {2}" -f $ProviderRead.State, $BatchSub, (Get-RdaInsightsRegisterCommand -SubscriptionId $BatchSub))
                    continue
                }
                $TenantKey = [string]$SubTenant[$BatchSub.ToLowerInvariant()]
                if (-not $MetricBatchTokens.ContainsKey($TenantKey))
                {
                    $MetricBatchTokens[$TenantKey] = $null
                    try
                    {
                        $TokenArgs = @{ ResourceUrl = 'https://metrics.monitor.azure.com'; WarningAction = 'SilentlyContinue'; ErrorAction = 'Stop' }
                        if (-not [string]::IsNullOrEmpty($TenantKey)) { $TokenArgs['TenantId'] = $TenantKey }
                        $TokenObj = Get-AzAccessToken @TokenArgs
                        $MetricBatchTokens[$TenantKey] = [pscustomobject]@{
                            Value     = $(if ($TokenObj.Token -is [securestring]) { [System.Net.NetworkCredential]::new('', $TokenObj.Token).Password } else { [string]$TokenObj.Token })
                            ExpiresOn = $TokenObj.ExpiresOn
                            Args      = $TokenArgs
                        }
                    }
                    catch
                    {
                        Write-MetricsDiag ("[batch] could not get a metrics data plane token ({0}); the subscriptions of that tenant use the per-resource path." -f $_.Exception.Message)
                    }
                }
                if ($null -eq $MetricBatchTokens[$TenantKey]) { continue }
                $MetricBatchTenantOfSub[$BatchSub.ToLowerInvariant()] = $TenantKey
                $AllowedBatchSubs.Add($BatchSub)
            }
            if ($AllowedBatchSubs.Count -gt 0 -and -not ('RdaBatchMetricPoint' -as [type]))
            {
                # One point of a batch answer. A compiled type, so the parallel runspaces
                # can make it (a PowerShell class does not resolve there), and far smaller
                # than a [PSCustomObject] per point.
                try
                {
                    Add-Type -TypeDefinition 'public sealed class RdaBatchMetricPoint { public System.Nullable<double> Average { get; set; } public System.Nullable<double> Minimum { get; set; } public System.Nullable<double> Maximum { get; set; } public System.Nullable<double> Total { get; set; } public System.Nullable<double> Count { get; set; } }' -ErrorAction Stop
                }
                catch
                {
                    # For example Constrained Language Mode, where Add-Type is not allowed.
                    Write-MetricsDiag ("[batch] -UseMetricsBatch: could not load the batch point type ({0}); every metric uses the per-resource path." -f $_.Exception.Message)
                    $AllowedBatchSubs.Clear()
                }
            }
            if ($AllowedBatchSubs.Count -gt 0)
            {
                $UseBatchApi = $true
                $MetricGroups = New-MetricBatchPlan -MetricGroups $MetricGroups -AllowedSubscriptionIds $AllowedBatchSubs
                $BatchUnitCount = @($MetricGroups | Where-Object { $_ -isnot [System.Array] }).Count
                Write-MetricsDiag ("[batch] -UseMetricsBatch: {0} batch request(s) planned for {1} subscription(s); {2} group(s) keep the per-resource path." -f $BatchUnitCount, $AllowedBatchSubs.Count, ($MetricGroups.Count - $BatchUnitCount))
            }
        }
    }

    # The one copy of Add-MetricRecord, defined in each parallel runspace that builds
    # records (the per-resource requests and, with -UseMetricsBatch, the batch
    # requests), so both write exactly the same records. It reads $DiagBag and
    # $MetricBag from the runspace that defines it.
    $AddMetricRecordSource = @'
# Adds the result record and the diagnostics record for one definition.
# $MetricQuery is the response for this metric alone, whether it was
# requested on its own or together with other metrics of the resource.
# The reported time is $ExtraSeconds plus, when given, the time on
# $CallStopwatch when the record is added.
function Add-MetricRecord
{
    param($Def, $Request, $MetricQuery, [System.Diagnostics.Stopwatch]$CallStopwatch, [double]$ExtraSeconds = 0)

    $ElapsedSeconds = $ExtraSeconds
    $MetricError = $false
    $CallOutcome = $Request.Outcome
    $CallErrorMsg = $null
    $MetricTimeSeries = $null

    try
    {
        if (-not $Request.Succeeded)
        {
            throw $Request.ErrorMessage
        }

        $MetricTotalCount = @($MetricQuery.Data).Count

        $MetricQueryResults = 0
        $MetricTimeSeries = 0

        switch ($Def.Aggregation)
        {
            'Average'
            {
                $MetricQueryResults = $MetricQuery.Data.Average
            }
            'Maximum'
            {
                $MetricQueryResults = $MetricQuery.Data.Maximum
            }
            'Count'
            {
                # .Data has a Count of its own, the number of data points, so read the
                # property of each point. A point without one reads as $null, not as 1.
                $MetricQueryResults = foreach ($DataPoint in $MetricQuery.Data) { $DataPoint.PSObject.Properties['Count'].Value }
            }
            'Total'
            {
                $MetricQueryResults = $MetricQuery.Data.Total
            }
            'Minimum'
            {
                $MetricQueryResults = $MetricQuery.Data.Minimum
            }
        }

        $MetricQueryResultsCount = ($MetricQueryResults.Where({ $_ -ne $null }).Count)

        if ($MetricQueryResultsCount -eq 0)
        {
            $MetricQueryResults = 0
            $MetricQueryResultsCount = 0
            $MetricPercentileIndex = 0
            $MetricPercentile = 0
        }
        else
        {
            $MetricQueryResultsSorted = $MetricQueryResults | Sort-Object
            $MetricPercentileIndex = [math]::Ceiling(0.95 * $MetricQueryResultsSorted.Count) - 1
            $MetricPercentile = $MetricQueryResultsSorted[$MetricPercentileIndex]

            if ($Def.Series -eq 'true')
            {
                $MetricTimeSeries = $MetricQueryResults.Where({ $_ -ne $null })
            }

            switch ($Def.Measure)
            {
                'Average' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Average).Average }
                'Maximum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Maximum).Maximum }
                'Sum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Sum).Sum }
                'Minimum' { $MetricQueryResults = ($MetricQueryResults | Measure-Object -Minimum).Minimum }
                'Largest' { $MetricQueryResults = ($MetricQueryResults | Sort-Object -Descending)[0] }
            }
        }
    }
    catch
    {
        $MetricQueryResults = 0
        $MetricQueryResultsCount = 0
        $MetricTotalCount = 0
        $MetricPercentileIndex = 0
        $MetricPercentile = 0

        $MetricError = $true
        if ($CallOutcome -eq 'Success') { $CallOutcome = 'Error' }
        $CallErrorMsg = $_.Exception.Message
    }

    if ($null -ne $CallStopwatch)
    {
        $ElapsedSeconds += $CallStopwatch.Elapsed.TotalSeconds
    }

    $DiagBag.Add([PSCustomObject]@{
            MetricIndex = $Def.MetricIndex
            Service     = $Def.Service
            Name        = $Def.Name
            Metric      = $Def.MetricName
            Interval    = $Def.Interval
            Outcome     = $CallOutcome
            Attempts    = $Request.Attempts
            ElapsedSec  = [math]::Round($ElapsedSeconds, 2)
            Error       = $CallErrorMsg
            # For the summary only: a 404 on a resource Resource Graph lists as being deleted is said so in plain words.
            Id          = $Def.Id
            NotFound    = [bool]$Request.NotFound
        })


    $Obj = @{
        'ID'                   = $Def.Id;
        'Subscription'         = $Def.SubName;
        'ResourceGroup'        = $Def.ResourceGroup;
        'Name'                 = $Def.Name;
        'Location'             = $Def.Location;
        'Service'              = $Def.Service;
        'Metric'               = $Def.MetricName;
        'MetricAggregate'      = $Def.Aggregation;
        'MetricTimeGrain'      = $Def.Interval;
        'MetricMeasure'        = $Def.Measure;
        'MetricPercentile'     = $MetricPercentile;
        'MetricValue'          = $MetricQueryResults;
        'MetricCount'          = $MetricQueryResultsCount;
        'MetricTotalCount'     = $MetricTotalCount;
        'MetricSeries'         = $MetricTimeSeries;
        'MetricError'          = $MetricError;
    }

    $MetricBag.Add($Obj)
}
'@

    $PhaseStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-MetricsDiag ("Starting metrics collection: {0} metric definition(s), ThrottleLimit={1}, per-call timeout={2}s, max retries={3}, throttle retries={5} (honours Retry-After up to {6}s), lookback={4} day(s)." -f $MetricCount, $ConcurrencyLimit, $MetricTimeoutSeconds, $MetricMaxRetries, [math]::Abs($MetricsLookbackPeriodDays), $MetricMaxThrottleRetries, $MetricMaxRetryAfterSeconds)

    $RangeBatch = [math]::Min($MetricCount , 250)
    $RangeIdx = 1
    $MetricsProcessed = 0
    $BatchGroups = [System.Collections.Generic.List[object]]::new()
    $BatchDefCount = 0

    # A batch is made of whole groups, so one call's metrics never land in different
    # Metrics_*.json files. A batch closes once it holds at least $RangeBatch
    # definitions, so it can exceed that by less than one group and there are never
    # more batches than with one definition at a time.
    for ($i = 0; $i -lt $MetricGroups.Count; $i++)
    {
        $BatchGroups.Add($MetricGroups[$i])
        $ItemDefCount = Get-MetricWorkItemDefCount -Item $MetricGroups[$i]
        $BatchDefCount += $ItemDefCount
        $MetricsProcessed += $ItemDefCount

        if ($BatchDefCount -ge $RangeBatch -or ($i + 1) -ge $MetricGroups.Count)
        {
            $BatchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            Write-RdaProgress -Activity 'Metrics collection' -CurrentItem ("batch {0} ({1} call(s))" -f $RangeIdx, $BatchGroups.Count) -Index $MetricsProcessed -Total $MetricCount -BarOnly
            Write-Verbose ("[Metrics] Batch {0}: dispatching {1} metric call(s) (processed {2}/{3})." -f $RangeIdx, $BatchGroups.Count, $MetricsProcessed, $MetricCount)

            $DispatchItems = $BatchGroups
            if ($UseBatchApi)
            {
                # Renew a token that ends within 10 minutes, on this thread, before the batch.
                foreach ($TenantKey in @($MetricBatchTokens.Keys))
                {
                    $Held = $MetricBatchTokens[$TenantKey]
                    if ($null -ne $Held -and $null -ne $Held.ExpiresOn -and $Held.ExpiresOn -lt [DateTimeOffset]::UtcNow.AddMinutes(10))
                    {
                        try
                        {
                            $RenewArgs = $Held.Args
                            $TokenObj = Get-AzAccessToken @RenewArgs
                            $Held.Value = if ($TokenObj.Token -is [securestring]) { [System.Net.NetworkCredential]::new('', $TokenObj.Token).Password } else { [string]$TokenObj.Token }
                            $Held.ExpiresOn = $TokenObj.ExpiresOn
                            # A new token: a 401 for it gets its own renewal.
                            $MetricBatchTokenRenewed.Remove($TenantKey)
                        }
                        catch
                        {
                            Write-MetricsDiag ("[batch] could not renew a metrics data plane token ({0}); the batch requests that use it fall back to the per-resource path when Azure refuses it." -f $_.Exception.Message)
                        }
                    }
                }
                $BatchUnits = @($BatchGroups | Where-Object { $_ -isnot [System.Array] })
                $DispatchItems = [System.Collections.Generic.List[object]]::new()
                foreach ($Item in $BatchGroups) { if ($Item -is [System.Array]) { $DispatchItems.Add($Item) } }
                $BatchOutcomes = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

                # At most two passes. A request whose token is refused (401) on the first
                # pass is held back; its tenant's token is renewed once and the request is
                # sent again in the second pass. A 401 on the second pass, or for a tenant
                # renewed earlier whose new token has not worked since, sends its groups to
                # the per-resource path and stops batching that tenant this phase.
                $PassUnits = $BatchUnits
                for ($BatchPass = 1; $BatchPass -le 2 -and @($PassUnits).Count -gt 0; $BatchPass++)
                {
                    $LastBatchPass = ($BatchPass -eq 2)
                    $RenewedTenants = @{} + $MetricBatchTokenRenewed
                    $BatchTokenValues = @{}
                    foreach ($TenantKey in @($MetricBatchTokens.Keys)) { if ($null -ne $MetricBatchTokens[$TenantKey]) { $BatchTokenValues[$TenantKey] = $MetricBatchTokens[$TenantKey].Value } }
                    $HeldBack = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
                    $TokenWorked = [System.Collections.Concurrent.ConcurrentDictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $TenantsOff = [System.Collections.Concurrent.ConcurrentDictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)

                    # One getBatch request per unit, in parallel. A unit answers each of its
                    # definitions, or hands it (or its whole group) to the per-resource path
                    # below; it never drops one.
                    $PassUnits | ForEach-Object -Parallel {
                        $Unit = $_
                        $Outcomes = $using:BatchOutcomes
                        $Counts = $using:MetricBatchCounts
                        $OffSubs = $using:MetricBatchOffSubs
                        $Notes = $using:MetricBatchNotes
                        $Tokens = $using:BatchTokenValues
                        $TenantOfSub = $using:MetricBatchTenantOfSub
                        $HeldBackUnits = $using:HeldBack
                        $Worked = $using:TokenWorked
                        $Off = $using:TenantsOff
                        $IsLastPass = $using:LastBatchPass
                        $Renewed = $using:RenewedTenants
                        $EndpointFormat = $using:MetricsBatchEndpointFormat
                        $CallTimeoutSeconds = $using:MetricTimeoutSeconds
                        $CallMaxRetries = $using:MetricMaxRetries
                        $ThreadJobLimit = $using:ConcurrencyLimit
                        $DiagBag = $using:MetricDiagnostics
                        $MetricBag = ($using:Tmp).Metrics
                        # Add-MetricRecord, defined by the source text below, reads these two.
                        $null = $DiagBag, $MetricBag
                        . ([scriptblock]::Create($using:AddMetricRecordSource))

                        function Add-BatchCount([int]$Index, [long]$By)
                        {
                            [System.Threading.Monitor]::Enter($Counts)
                            try { $Counts[$Index] += $By } finally { [System.Threading.Monitor]::Exit($Counts) }
                        }

                        # Every group of the unit to the per-resource path, as without -UseMetricsBatch.
                        function Send-AllGroupsOn
                        {
                            foreach ($Group in $Unit.Groups)
                            {
                                $Outcomes.Add([pscustomobject]@{ Kind = 'Fallback'; Group = $Group })
                                Add-BatchCount 5 @($Group).Count
                            }
                        }

                        # The seconds a 429 answer asks to wait (Retry-After), or 0.
                        function Get-BatchRetryAfter([System.Exception]$Exception)
                        {
                            try
                            {
                                # Retry-After is either a number of seconds or an HTTP date.
                                $Header = $Exception.Response.Headers.RetryAfter
                                if ($null -ne $Header.Delta) { return [math]::Max(0, $Header.Delta.TotalSeconds) }
                                if ($null -ne $Header.Date) { return [math]::Max(0, ($Header.Date - [DateTimeOffset]::UtcNow).TotalSeconds) }
                            }
                            catch { }
                            return 0
                        }

                        # The HTTP status of a failed request, or $null.
                        function Get-BatchStatusCode([System.Exception]$Exception)
                        {
                            $Ex = $Exception
                            $Depth = 0
                            while ($null -ne $Ex -and $Depth -lt 10)
                            {
                                $Depth++
                                if ($null -ne $Ex.PSObject.Properties['Response'] -and $null -ne $Ex.Response -and $null -ne $Ex.Response.PSObject.Properties['StatusCode'])
                                {
                                    try { return [int]$Ex.Response.StatusCode } catch { }
                                }
                                if ($null -ne $Ex.PSObject.Properties['StatusCode'] -and $null -ne $Ex.StatusCode)
                                {
                                    try { return [int]$Ex.StatusCode } catch { }
                                }
                                $Ex = $Ex.InnerException
                            }
                            return $null
                        }

                        # Reads one batch answer with System.Text.Json into small objects: per resource
                        # its id and its metrics, per metric its name, its errorCode ($null when the API
                        # leaves it out) and Data, the first time series' points as RdaBatchMetricPoint
                        # (every aggregation field a double or null), or $null when there is no time
                        # series, as PSMetric.Data is. A point field is read as Azure writes it (lower
                        # case). Parsing this way keeps memory low: a 50-resource answer holds tens of
                        # thousands of points.
                        # The value of one key of a JSON object, matched without regard to case (as
                        # Invoke-RestMethod reads keys), or $null when the key is not there.
                        function Get-BatchJsonValue($Object, [string]$Name)
                        {
                            if ($Object -isnot [System.Text.Json.JsonElement] -or $Object.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
                            foreach ($Property in $Object.EnumerateObject())
                            {
                                if ([string]::Equals($Property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $Property.Value }
                            }
                            return $null
                        }

                        function ConvertFrom-BatchAnswer([System.IO.Stream]$Stream)
                        {
                            $Answer = [System.Collections.Generic.List[object]]::new()
                            $Doc = [System.Text.Json.JsonDocument]::Parse($Stream)
                            try
                            {
                                $Kind = [System.Text.Json.JsonValueKind]
                                $Values = Get-BatchJsonValue $Doc.RootElement 'values'
                                if ($null -eq $Values -or $Values.ValueKind -ne $Kind::Array) { return , $Answer }
                                foreach ($Entry in $Values.EnumerateArray())
                                {
                                    if ($Entry.ValueKind -ne $Kind::Object) { continue }
                                    $Field = Get-BatchJsonValue $Entry 'resourceid'
                                    $EntryId = if ($null -ne $Field -and $Field.ValueKind -eq $Kind::String) { $Field.GetString() } else { '' }
                                    $Metrics = [System.Collections.Generic.List[object]]::new()
                                    $List = Get-BatchJsonValue $Entry 'value'
                                    if ($null -ne $List -and $List.ValueKind -eq $Kind::Array)
                                    {
                                        foreach ($Metric in $List.EnumerateArray())
                                        {
                                            $NameValue = Get-BatchJsonValue (Get-BatchJsonValue $Metric 'name') 'value'
                                            if ($null -eq $NameValue -or $NameValue.ValueKind -ne $Kind::String) { continue }
                                            $Field = Get-BatchJsonValue $Metric 'errorCode'
                                            $Code = if ($null -ne $Field -and $Field.ValueKind -eq $Kind::String) { $Field.GetString() } else { $null }
                                            # Data as PSMetric gives it: the FIRST time series' points, $null
                                            # when there is none or it has no data (null entries are not skipped,
                                            # as Timeseries.FirstOrDefault() does not skip them).
                                            $Data = $null
                                            $Series = Get-BatchJsonValue $Metric 'timeseries'
                                            if ($null -ne $Series -and $Series.ValueKind -eq $Kind::Array -and $Series.GetArrayLength() -gt 0)
                                            {
                                                $Points = Get-BatchJsonValue $Series.get_Item(0) 'data'
                                                if ($null -ne $Points -and $Points.ValueKind -eq $Kind::Array)
                                                {
                                                    $Data = [System.Collections.Generic.List[object]]::new()
                                                    foreach ($Point in $Points.EnumerateArray())
                                                    {
                                                        if ($Point.ValueKind -ne $Kind::Object) { continue }
                                                        $Value = [RdaBatchMetricPoint]::new()
                                                        foreach ($Property in $Point.EnumerateObject())
                                                        {
                                                            if ($Property.Value.ValueKind -ne $Kind::Number) { continue }
                                                            switch ($Property.Name)
                                                            {
                                                                # switch compares without case; the first key of a
                                                                # name wins, as in Get-BatchJsonValue.
                                                                'average' { if ($null -eq $Value.Average) { $Value.Average = $Property.Value.GetDouble() } }
                                                                'minimum' { if ($null -eq $Value.Minimum) { $Value.Minimum = $Property.Value.GetDouble() } }
                                                                'maximum' { if ($null -eq $Value.Maximum) { $Value.Maximum = $Property.Value.GetDouble() } }
                                                                'total' { if ($null -eq $Value.Total) { $Value.Total = $Property.Value.GetDouble() } }
                                                                'count' { if ($null -eq $Value.Count) { $Value.Count = $Property.Value.GetDouble() } }
                                                            }
                                                        }
                                                        $Data.Add($Value)
                                                    }
                                                }
                                            }
                                            $Metrics.Add([pscustomobject]@{ Name = $NameValue.GetString(); ErrorCode = $Code; Data = $Data })
                                        }
                                    }
                                    $Answer.Add([pscustomobject]@{ ResourceId = $EntryId; Metrics = $Metrics })
                                }
                            }
                            finally
                            {
                                $Doc.Dispose()
                            }
                            return , $Answer
                        }

                        $Reason = $null
                        if ($OffSubs.TryGetValue($Unit.SubscriptionId, [ref]$Reason))
                        {
                            Send-AllGroupsOn
                            return
                        }
                        $TenantKey = [string]$TenantOfSub[$Unit.SubscriptionId]
                        $Token = $Tokens[$TenantKey]
                        if ([string]::IsNullOrEmpty($Token))
                        {
                            Send-AllGroupsOn
                            return
                        }

                        $Uri = ('{0}/subscriptions/{1}/metrics:getBatch?api-version=2023-10-01&metricnamespace={2}&metricnames={3}&aggregation={4}&interval={5}&starttime={6}&endtime={7}' -f
                            ($EndpointFormat -f $Unit.Region), $Unit.SubscriptionId, [uri]::EscapeDataString($Unit.Namespace),
                            ((@($Unit.MetricNames) | ForEach-Object { [uri]::EscapeDataString($_) }) -join ','),
                            $Unit.Aggregation.ToLowerInvariant(), $Unit.Interval, $Unit.StartTime, $Unit.EndTime)
                        # The doc's rule: resource ids in the body in lower case.
                        $Body = ConvertTo-Json -InputObject @{ resourceids = [string[]]@($Unit.ResourceIds) } -Compress

                        # A request sent again after a 401 is not counted again.
                        if (-not $IsLastPass)
                        {
                            Add-BatchCount 0 1
                            Add-BatchCount 2 $Unit.ResourceIds.Count
                        }
                        $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $Response = $null
                        $Attempt = 0
                        $LastError = $null
                        $Kind = $null
                        $RetryAfter = 0
                        # Same rules as one Get-AzMetric request: at most 1 + $CallMaxRetries
                        # attempts, each bounded by $CallTimeoutSeconds; 401, 403, 400 and 404 end
                        # at once (the same request is refused the same way again).
                        while ($Attempt -le $CallMaxRetries)
                        {
                            Add-BatchCount 1 1
                            # The whole request, body included, runs in a thread job bounded by Wait-Job, as
                            # one Get-AzMetric request is: -TimeoutSec alone does not cover reading the body.
                            $Failure = $null
                            $Job = Start-ThreadJob -ScriptBlock { param($RequestArgs) Invoke-WebRequest @RequestArgs } -ArgumentList @{ Method = 'Post'; Uri = $Uri; Headers = @{ Authorization = 'Bearer ' + $Token }; ContentType = 'application/json'; Body = $Body; TimeoutSec = $CallTimeoutSeconds; ErrorAction = 'Stop' } -ThrottleLimit $ThreadJobLimit
                            if (Wait-Job -Job $Job -Timeout $CallTimeoutSeconds)
                            {
                                try { $Response = Receive-Job -Job $Job -ErrorAction Stop } catch { $Failure = $_ }
                                Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
                                if ($null -eq $Failure)
                                {
                                    $Kind = $null
                                    break
                                }
                                $LastError = [string]$Failure.Exception.Message
                                $Status = Get-BatchStatusCode -Exception $Failure.Exception
                                $RetryAfter = Get-BatchRetryAfter -Exception $Failure.Exception
                                $Kind = if ($Status -eq 401) { 'TokenRefused' }
                                elseif ($Status -eq 403) { 'Refused' }
                                elseif ($Status -in 400, 404) { 'BadRequest' }
                                elseif ($Status -in 429, 529 -or $LastError -match '(?i)throttl|TooManyRequests|rate limit') { 'Throttled' }
                                else { 'Error' }
                                if ($null -ne $Status) { $LastError = ('HTTP {0}: {1}' -f $Status, $LastError) }
                            }
                            else
                            {
                                Stop-Job -Job $Job -ErrorAction SilentlyContinue
                                Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
                                $Kind = 'Error'
                                $LastError = ('Timed out after {0}s' -f $CallTimeoutSeconds)
                            }
                            if ($Kind -in 'Refused', 'TokenRefused', 'BadRequest') { break }
                            if ($Attempt -lt $CallMaxRetries)
                            {
                                $Backoff = [math]::Min([math]::Pow(2, $Attempt), 30)
                                if ($Kind -eq 'Throttled') { $Backoff = [math]::Min([math]::Max($Backoff * 2, $RetryAfter), 60) }
                                Start-Sleep -Seconds ([math]::Round($Backoff + (Get-Random -Minimum 0 -Maximum 1000) / 1000.0, 2))
                            }
                            $Attempt++
                        }
                        $Seconds = $Stopwatch.Elapsed.TotalSeconds
                        $Attempts = [math]::Min($Attempt, $CallMaxRetries) + 1

                        if ($null -ne $Kind)
                        {
                            if ($Kind -eq 'TokenRefused')
                            {
                                if (-not $IsLastPass -and -not $Renewed.ContainsKey($TenantKey))
                                {
                                    # The token may have ended: renewed once, then this request is sent again.
                                    $HeldBackUnits.Add($Unit)
                                    return
                                }
                                if ($Off.TryAdd($TenantKey, 1))
                                {
                                    $Notes.Add(('The metrics data plane refused a renewed token (401) for subscription {0}; batch is off for its tenant for the rest of the phase.' -f $Unit.SubscriptionId))
                                }
                            }
                            if ($Kind -eq 'Refused' -and $OffSubs.TryAdd($Unit.SubscriptionId, $LastError))
                            {
                                $Notes.Add(('Batch turned off for subscription {0}: the data plane refused the request ({1}). Its metrics use the per-resource path. The batch API needs Monitoring Reader on the subscription itself (not only on its resource groups) and Microsoft.Insights registered there.' -f $Unit.SubscriptionId, $LastError))
                            }
                            $Notes.Add(('Batch request failed after {0} attempt(s) ({1}) for {2} resource(s) of {3} in {4}; their metrics use the per-resource path.' -f $Attempts, $LastError, $Unit.ResourceIds.Count, $Unit.Namespace, $Unit.Region))
                            Send-AllGroupsOn
                            return
                        }

                        [void]$Worked.TryAdd($TenantKey, 1)

                        # Each answer back to its resource, ids compared without case.
                        $Entries = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        try
                        {
                            # The raw bytes, not the Content string, so the answer is not copied again.
                            $Response.RawContentStream.Position = 0
                            $Parsed = ConvertFrom-BatchAnswer -Stream $Response.RawContentStream
                        }
                        catch
                        {
                            # Not readable JSON: the whole request goes per resource.
                            $Notes.Add(('Batch answer for {0} resource(s) of {1} in {2} could not be read ({3}); their metrics use the per-resource path.' -f $Unit.ResourceIds.Count, $Unit.Namespace, $Unit.Region, $_.Exception.Message))
                            Send-AllGroupsOn
                            return
                        }
                        $Response = $null
                        foreach ($Entry in $Parsed)
                        {
                            $EntryId = ([string]$Entry.ResourceId).TrimEnd('/')
                            if (-not [string]::IsNullOrEmpty($EntryId) -and -not $Entries.ContainsKey($EntryId)) { $Entries[$EntryId] = $Entry }
                        }
                        $Parsed = $null
                        $AnsweredIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        $AnsweredDefs = 0
                        # The answer of a request that worked, for the records of the definitions it answered.
                        $Answered = [PSCustomObject]@{ Succeeded = $true; Query = $null; Outcome = 'Success'; Attempts = $Attempts; ErrorMessage = $null; BadRequest = $false; NotFound = $false }
                        foreach ($Group in $Unit.Groups)
                        {
                            $GroupKey = ([string]$Group[0].Id).TrimEnd('/')
                            if (-not $Entries.ContainsKey($GroupKey))
                            {
                                $Outcomes.Add([pscustomobject]@{ Kind = 'Fallback'; Group = $Group })
                                Add-BatchCount 5 @($Group).Count
                                continue
                            }
                            [void]$AnsweredIds.Add($GroupKey)
                            $ByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
                            foreach ($Metric in $Entries[$GroupKey].Metrics)
                            {
                                $MetricName = [string]$Metric.Name
                                if (-not [string]::IsNullOrEmpty($MetricName) -and -not $ByName.ContainsKey($MetricName)) { $ByName[$MetricName] = $Metric }
                            }
                            $Missing = [System.Collections.Generic.List[object]]::new()
                            $GroupAnswers = [System.Collections.Generic.List[object]]::new()
                            foreach ($Def in $Group)
                            {
                                $Metric = $null
                                # The live API leaves errorCode out of a metric it answered (the doc's
                                # sample shows 'Success'), so no code is a success too; any other code
                                # is not, and that metric gets a request of its own.
                                if ($ByName.TryGetValue([string]$Def.MetricName, [ref]$Metric) -and ([string]::IsNullOrEmpty([string]$Metric.ErrorCode) -or [string]$Metric.ErrorCode -eq 'Success'))
                                {
                                    $GroupAnswers.Add([pscustomobject]@{ Def = $Def; Metric = $Metric })
                                }
                                else
                                {
                                    $Missing.Add($Def)
                                }
                            }
                            if ($GroupAnswers.Count -eq 0)
                            {
                                # Nothing usable for this resource: its group as without -UseMetricsBatch.
                                $Outcomes.Add([pscustomobject]@{ Kind = 'Fallback'; Group = $Group })
                                Add-BatchCount 5 @($Group).Count
                                continue
                            }
                            # Each record is built now, so only this request's answer is held, never
                            # the answers of every request of the batch.
                            foreach ($Answer in $GroupAnswers)
                            {
                                Add-MetricRecord -Def $Answer.Def -Request $Answered -MetricQuery ([pscustomobject]@{ Name = [pscustomobject]@{ Value = $Answer.Metric.Name }; Data = $Answer.Metric.Data }) -ExtraSeconds $Seconds
                                $AnsweredDefs++
                            }
                            foreach ($Def in $Missing)
                            {
                                # A metric with an errorCode other than Success, or not in the answer: one request of its own.
                                $Outcomes.Add([pscustomobject]@{ Kind = 'Fallback'; Group = [object[]]@($Def) })
                                Add-BatchCount 5 1
                            }
                        }
                        Add-BatchCount 3 $AnsweredIds.Count
                        Add-BatchCount 4 $AnsweredDefs
                        $Response = $null
                        $Entries = $null
                    } -ThrottleLimit $ConcurrencyLimit

                    foreach ($TenantKey in @($TokenWorked.Keys)) { $MetricBatchTokenRenewed.Remove($TenantKey) }
                    foreach ($TenantKey in @($TenantsOff.Keys)) { $MetricBatchTokens[$TenantKey] = $null }
                    $PassUnits = @($HeldBack)
                    if ($PassUnits.Count -gt 0)
                    {
                        $RefusedTenants = @($PassUnits | ForEach-Object { [string]$MetricBatchTenantOfSub[$_.SubscriptionId] } | Sort-Object -Unique)
                        Write-MetricsDiag ("[batch] the metrics data plane refused the token (401) for {0} request(s); renewing the token of {1} tenant(s) once and sending them again." -f $PassUnits.Count, $RefusedTenants.Count)
                        foreach ($TenantKey in $RefusedTenants)
                        {
                            $MetricBatchTokenRenewed[$TenantKey] = $true
                            $Held = $MetricBatchTokens[$TenantKey]
                            if ($null -eq $Held) { continue }
                            try
                            {
                                $RenewArgs = $Held.Args
                                $TokenObj = Get-AzAccessToken @RenewArgs
                                $Held.Value = if ($TokenObj.Token -is [securestring]) { [System.Net.NetworkCredential]::new('', $TokenObj.Token).Password } else { [string]$TokenObj.Token }
                                $Held.ExpiresOn = $TokenObj.ExpiresOn
                            }
                            catch
                            {
                                Write-MetricsDiag ("[batch] could not renew a metrics data plane token ({0}); those requests are sent again with the token held." -f $_.Exception.Message)
                            }
                        }
                    }
                }

                foreach ($Outcome in $BatchOutcomes) { $DispatchItems.Add($Outcome.Group) }
                $BatchOutcomes = $null
                $BatchUnits = $null
            }

            # Each parallel item is one group of definitions (with -UseMetricsBatch: one the
            # batch requests did not answer, or could not express).
            $DispatchItems | ForEach-Object -Parallel {
                $AzContext = $using:MetricAzContext
                $CallTimeoutSeconds = $using:MetricTimeoutSeconds
                $CallMaxRetries = $using:MetricMaxRetries
                $CallMaxThrottleRetries = $using:MetricMaxThrottleRetries
                $CallMaxRetryAfterSeconds = $using:MetricMaxRetryAfterSeconds
                $RetryAfterFnDef = $using:MetricRetryAfterFnDef
                if ($RetryAfterFnDef) { Set-Item -Path function:Get-RdaRetryAfterSeconds -Value ([scriptblock]::Create($RetryAfterFnDef)) }
                $DiagBag = $using:MetricDiagnostics
                $MetricBag = ($using:Tmp).Metrics
                $RequestCounts = $using:MetricRequestCounts

                # Retry decision for one failed Get-AzMetric attempt. Pure (no sleeping) so it is unit-testable.
                # Throttled attempts draw on their own budget and wait at least the server's Retry-After (bounded); every
                # other failure uses the generic budget and 2^attempt backoff. Returns @{ Retry; SleepSeconds } (no jitter).
                function Get-RdaMetricRetryPlan
                {
                    param(
                        [int]$Attempt, [bool]$Throttled, [int]$ThrottledAttempts, [double]$RetryAfterSeconds, [bool]$Permanent,
                        [int]$MaxRetries, [int]$MaxThrottleRetries, [double]$MaxRetryAfterSeconds
                    )
                    if ($Permanent) { return @{ Retry = $false; SleepSeconds = 0 } }
                    $Retry = if ($Throttled) { $ThrottledAttempts -le $MaxThrottleRetries } else { $Attempt -lt $MaxRetries }
                    if (-not $Retry) { return @{ Retry = $false; SleepSeconds = 0 } }
                    $Backoff = [math]::Min([math]::Pow(2, $Attempt), 30)
                    if ($Throttled)
                    {
                        $Backoff = [math]::Min($Backoff * 2, 60)
                        if ($RetryAfterSeconds -gt 0) { $Backoff = [math]::Min([math]::Max($RetryAfterSeconds, $Backoff), $MaxRetryAfterSeconds) }
                    }
                    return @{ Retry = $true; SleepSeconds = $Backoff }
                }

                # The exception and the ones it wraps (inner exceptions and a wrapped error
                # record's exception), outermost first, at most 10.
                function Get-MetricExceptionChain
                {
                    param([System.Exception]$Exception)

                    $Chain = [System.Collections.Generic.List[object]]::new()
                    $Pending = [System.Collections.Generic.Queue[object]]::new()
                    $Pending.Enqueue($Exception)
                    while ($Pending.Count -gt 0 -and $Chain.Count -lt 10)
                    {
                        $Ex = $Pending.Dequeue()
                        if ($null -eq $Ex) { continue }
                        $Chain.Add($Ex)
                        $Pending.Enqueue($Ex.InnerException)
                        if ($null -ne $Ex.PSObject.Properties['ErrorRecord'] -and $null -ne $Ex.ErrorRecord -and -not [object]::ReferenceEquals($Ex.ErrorRecord.Exception, $Ex))
                        {
                            $Pending.Enqueue($Ex.ErrorRecord.Exception)
                        }
                    }
                    return , $Chain
                }

                # The HTTP status an exception carries itself (its response's, else its own), as
                # text ('404' or 'NotFound' style), or $null when it carries none.
                function Get-MetricExceptionStatus
                {
                    param($Ex)

                    $StatusCode = $null
                    if ($null -ne $Ex.PSObject.Properties['Response'] -and $null -ne $Ex.Response -and $null -ne $Ex.Response.PSObject.Properties['StatusCode'])
                    {
                        $StatusCode = $Ex.Response.StatusCode
                    }
                    elseif ($null -ne $Ex.PSObject.Properties['StatusCode'])
                    {
                        $StatusCode = $Ex.StatusCode
                    }
                    if ($null -eq $StatusCode) { return $null }
                    return [string]$StatusCode
                }

                # True when Azure answered HTTP 400 (BadRequest), as it does when a requested
                # metric name is not valid for the resource. The status code and the message
                # of the exception and of every exception it wraps are checked, because an
                # outer exception can report a different status than the 400 it wraps.
                function Test-MetricBadRequest
                {
                    param([System.Exception]$Exception)

                    foreach ($Ex in (Get-MetricExceptionChain -Exception $Exception))
                    {
                        if ((Get-MetricExceptionStatus -Ex $Ex) -in @('400', 'BadRequest'))
                        {
                            return $true
                        }
                        if ([string]$Ex.Message -match 'BadRequest')
                        {
                            return $true
                        }
                    }
                    return $false
                }

                # True when Azure answered HTTP 404 (NotFound): the resource is not there any more
                # (deleted, or being deleted, after discovery) or is not in this subscription. The
                # same request is refused the same way on every retry, so it gets one attempt.
                # A status code decides: the outermost exception in the chain that carries one is
                # read, so a 5xx that wraps or quotes a 404 keeps its retries. Only when no
                # exception carries a status is the text read: Get-AzMetric reports a 404 as
                # "invalid status code 'NotFound'" with no status code on the exception (quotes
                # optional, the literal 'invalid status code ' prefix is the anchor), and a newer
                # SDK may give the error code 'ResourceNotFound' instead. Ported from fork old-main.
                function Test-MetricNotFound
                {
                    param([System.Exception]$Exception)

                    $Chain = Get-MetricExceptionChain -Exception $Exception
                    foreach ($Ex in $Chain)
                    {
                        $Status = Get-MetricExceptionStatus -Ex $Ex
                        if ($null -ne $Status) { return ($Status -in @('404', 'NotFound')) }
                    }
                    foreach ($Ex in $Chain)
                    {
                        if ([string]$Ex.Message -match "invalid status code '?NotFound\b|^\s*\[ResourceNotFound\]")
                        {
                            return $true
                        }
                        if ($null -ne $Ex.PSObject.Properties['Body'] -and $null -ne $Ex.Body -and $null -ne $Ex.Body.PSObject.Properties['Code'] -and [string]$Ex.Body.Code -eq 'ResourceNotFound')
                        {
                            return $true
                        }
                    }
                    return $false
                }

                # One Get-AzMetric request with the per-call timeout and retry/backoff.
                # Returns the outcome rather than throwing, so the caller decides how a
                # failure is recorded for each definition. With -StopOnBadRequest a
                # BadRequest answer ends the request at once: the same name set is
                # rejected the same way on every retry.
                function Invoke-MetricRequest
                {
                    param($Def, $MetricNames, [string]$Kind, [switch]$StopOnBadRequest)

                    [System.Threading.Monitor]::Enter($RequestCounts)
                    try
                    {
                        $RequestCounts[0]++
                        if ($Kind -eq 'Fallback') { $RequestCounts[1]++ }
                    }
                    finally
                    {
                        [System.Threading.Monitor]::Exit($RequestCounts)
                    }
                    $CallOutcome = 'Success'
                    $CallAttempts = 0
                    $Request = [PSCustomObject]@{ Succeeded = $false; Query = $null; Outcome = $null; Attempts = 0; ErrorMessage = $null; BadRequest = $false; NotFound = $false }

                    $MetricArgs = @{
                        ResourceId      = $Def.Id
                        MetricName      = $MetricNames
                        StartTime       = $Def.StartTime
                        EndTime         = $Def.EndTime
                        TimeGrain       = $Def.Interval
                        AggregationType = $Def.Aggregation
                        ErrorAction     = 'Stop'
                        WarningAction   = 'SilentlyContinue'
                    }
                    if ($null -ne $AzContext)
                    {
                        $MetricArgs['DefaultProfile'] = $AzContext
                    }

                    try
                    {
                        $Attempt = 0
                        $ThrottledAttempts = 0
                        $Succeeded = $false
                        $LastError = $null
                        $MetricQuery = $null

                        while (-not $Succeeded)
                        {
                            $CallAttempts = $Attempt + 1
                            $AttemptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                            $TimedOut = $false
                            $Throttled = $false
                            $RetryAfterSeconds = 0
                            $BadRequest = $false
                            $NotFound = $false

                            $Job = Start-ThreadJob -ScriptBlock {
                                param($mArgs)
                                Get-AzMetric @mArgs
                            } -ArgumentList $MetricArgs

                            if (Wait-Job -Job $Job -Timeout $CallTimeoutSeconds)
                            {
                                try
                                {
                                    $MetricQuery = Receive-Job -Job $Job -ErrorAction Stop
                                    $Succeeded = $true
                                }
                                catch
                                {
                                    $LastError = $_.Exception.Message
                                    # NotFound first: the throttle match below is a loose substring
                                    # test that text inside a 404 message could meet by chance.
                                    if (Test-MetricNotFound -Exception $_.Exception)
                                    {
                                        $NotFound = $true
                                    }
                                    elseif ($LastError -match '429|throttl|TooManyRequests|rate limit')
                                    {
                                        $Throttled = $true
                                        $ThrottledAttempts++
                                        # Server-directed wait (Retry-After header) when present; 0 means fall back to our own backoff.
                                        if (Get-Command Get-RdaRetryAfterSeconds -ErrorAction SilentlyContinue)
                                        {
                                            try { $RetryAfterSeconds = [double](Get-RdaRetryAfterSeconds -ErrorRecord $_) } catch { $RetryAfterSeconds = 0 }
                                        }
                                    }
                                    elseif ($StopOnBadRequest)
                                    {
                                        $BadRequest = Test-MetricBadRequest -Exception $_.Exception
                                    }
                                }
                                finally
                                {
                                    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
                                }
                            }
                            else
                            {
                                # Timed out: stop the hung job and treat as a failed attempt.
                                $TimedOut = $true
                                $LastError = ("Timed out after {0}s" -f $CallTimeoutSeconds)
                                Stop-Job -Job $Job -ErrorAction SilentlyContinue
                                Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
                            }

                            $AttemptStopwatch.Stop()

                            if ($Succeeded)
                            {
                                break
                            }

                            if ($BadRequest)
                            {
                                $CallOutcome = 'Error'
                                $Request.BadRequest = $true
                                break
                            }

                            # A BadRequest under -StopOnBadRequest has already left the loop above. A
                            # NotFound (404) is permanent: no retry can find the resource, so it ends
                            # after this attempt and is recorded as an Error, as before.
                            $Plan = Get-RdaMetricRetryPlan -Attempt $Attempt -Throttled $Throttled -ThrottledAttempts $ThrottledAttempts -RetryAfterSeconds $RetryAfterSeconds -Permanent $NotFound `
                                -MaxRetries $CallMaxRetries -MaxThrottleRetries $CallMaxThrottleRetries -MaxRetryAfterSeconds $CallMaxRetryAfterSeconds
                            if ($Plan.Retry)
                            {
                                # Jitter so a wave of throttled calls does not retry in lockstep.
                                $Jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
                                $SleepSeconds = [math]::Round($Plan.SleepSeconds + $Jitter, 2)
                                Start-Sleep -Seconds $SleepSeconds
                            }
                            else
                            {
                                $CallOutcome = if ($TimedOut) { 'Timeout' } elseif ($Throttled) { 'Throttled' } else { 'Error' }
                                # Budget exhausted: leave the loop; the throw below records the metric as having no data.
                                break
                            }

                            $Attempt++
                        }

                        if (-not $Succeeded)
                        {
                            $Request.NotFound = $NotFound
                            throw ("Get-AzMetric failed after {0} attempt(s): {1}" -f $CallAttempts, $LastError)
                        }

                        $Request.Succeeded = $true
                        $Request.Query = $MetricQuery
                    }
                    catch
                    {
                        if ($CallOutcome -eq 'Success') { $CallOutcome = 'Error' }
                        $Request.ErrorMessage = $_.Exception.Message
                    }

                    $Request.Outcome = $CallOutcome
                    $Request.Attempts = $CallAttempts
                    return $Request
                }

                # Add-MetricRecord, defined by the source text below, reads these two.
                $null = $DiagBag, $MetricBag
                . ([scriptblock]::Create($using:AddMetricRecordSource))

                $GroupDefs = @($_)
                $CallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

                if ($GroupDefs.Count -eq 1)
                {
                    $Request = Invoke-MetricRequest -Def $GroupDefs[0] -MetricNames $GroupDefs[0].MetricName -Kind 'Request'
                    Add-MetricRecord -Def $GroupDefs[0] -Request $Request -MetricQuery $Request.Query -CallStopwatch $CallStopwatch
                }
                else
                {
                    $MetricNames = [string[]]@($GroupDefs | ForEach-Object { [string]$_.MetricName } | Select-Object -Unique)
                    $Request = Invoke-MetricRequest -Def $GroupDefs[0] -MetricNames $MetricNames -Kind 'Request' -StopOnBadRequest
                    # The group request's own duration, read once: a metric answered by it
                    # reports this time even when it is recorded after a fallback request
                    # for another metric of the group.
                    $GroupSeconds = $CallStopwatch.Elapsed.TotalSeconds

                    # Index the response by metric name so each definition gets its own metric.
                    $ReturnedMetrics = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    if ($Request.Succeeded)
                    {
                        foreach ($ReturnedMetric in $Request.Query)
                        {
                            $ReturnedName = [string]$ReturnedMetric.Name.Value
                            if (-not [string]::IsNullOrEmpty($ReturnedName) -and -not $ReturnedMetrics.ContainsKey($ReturnedName))
                            {
                                $ReturnedMetrics[$ReturnedName] = $ReturnedMetric
                            }
                        }
                    }

                    foreach ($Def in $GroupDefs)
                    {
                        if ($Request.Succeeded -and $ReturnedMetrics.ContainsKey([string]$Def.MetricName))
                        {
                            Add-MetricRecord -Def $Def -Request $Request -MetricQuery $ReturnedMetrics[[string]$Def.MetricName] -ExtraSeconds $GroupSeconds
                        }
                        elseif (-not $Request.Succeeded -and -not $Request.BadRequest)
                        {
                            # The group failed after its retries for a reason that does not depend
                            # on the metric names (throttling, timeout, server error). Requesting
                            # each metric again would repeat the same failure once per metric, so
                            # every metric of the group records the group request's outcome.
                            Add-MetricRecord -Def $Def -Request $Request -MetricQuery $null -ExtraSeconds $GroupSeconds
                        }
                        else
                        {
                            # One invalid metric name makes Azure reject the whole request with
                            # BadRequest, so a rejected group is not retried and falls back to one
                            # request per metric; only a metric that also fails on its own is
                            # marked as an error. A metric missing from a successful response is
                            # requested on its own too. Its elapsed time includes the group request.
                            $SingleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                            $SingleRequest = Invoke-MetricRequest -Def $Def -MetricNames $Def.MetricName -Kind 'Fallback'
                            Add-MetricRecord -Def $Def -Request $SingleRequest -MetricQuery $SingleRequest.Query -CallStopwatch $SingleStopwatch -ExtraSeconds $GroupSeconds
                        }
                    }
                }

                $Request = $null
                $ReturnedMetrics = $null
                $SingleRequest = $null

            } -ThrottleLimit $ConcurrencyLimit

            $BatchGroups.Clear()
            $BatchDefCount = 0

            $BatchStopwatch.Stop()
            Write-Verbose ("[Metrics] Batch {0} complete in {1}s. Cumulative diagnostics: {2} call record(s) so far." -f $RangeIdx, [math]::Round($BatchStopwatch.Elapsed.TotalSeconds, 1), $MetricDiagnostics.Count)

            if ($Obfuscate)
            {
                foreach ($metric in $Tmp.Metrics)
                {
                    $OriginalId = $metric.ID
                    if (![string]::IsNullOrEmpty($OriginalId) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0 -and $ResourceIdDictionary.ContainsKey($OriginalId))
                    {
                        $metric.ID = $ResourceIdDictionary[$OriginalId]
                        $metric.Name = $ResourceNameDictionary[$OriginalId]
                        $metric.Subscription = $ResourceSubDictionary[$OriginalId]
                        $metric.ResourceGroup = $ResourceGroupDictionary[$OriginalId]
                    }
                    else
                    {
                        if (![string]::IsNullOrEmpty($OriginalId))
                        {
                            $FbPrefix = if ($OriginalId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b') { 'nonprod_' } else { 'prod_' }

                            if (-not $script:MetricsFallbackSubCache) { $script:MetricsFallbackSubCache = @{} }
                            if (-not $script:MetricsFallbackRgCache) { $script:MetricsFallbackRgCache = @{} }
                            if (-not $script:MetricsFallbackNameCache) { $script:MetricsFallbackNameCache = @{} }

                            $ObfuscatedId = Build-ObfuscatedResourceUri -RawUri $OriginalId -Prefix $FbPrefix -SubscriptionDictionary $ResourceSubDictionary -ResourceGroupDictionary $ResourceGroupDictionary -NameDictionary $ResourceNameDictionary -SubCache $script:MetricsFallbackSubCache -RgCache $script:MetricsFallbackRgCache -NameCache $script:MetricsFallbackNameCache

                            $ResourceIdDictionary[$OriginalId] = $ObfuscatedId
                            if (-not $ResourceNameDictionary.ContainsKey($OriginalId)) { $ResourceNameDictionary[$OriginalId] = $FbPrefix + [guid]::NewGuid().ToString() }
                            if (-not $ResourceSubDictionary.ContainsKey($OriginalId)) { $ResourceSubDictionary[$OriginalId] = $FbPrefix + 'sub_' + [guid]::NewGuid().ToString() }
                            if (-not $ResourceGroupDictionary.ContainsKey($OriginalId)) { $ResourceGroupDictionary[$OriginalId] = $FbPrefix + 'rg_' + [guid]::NewGuid().ToString() }

                            $metric.ID = $ObfuscatedId
                            $metric.Name = $ResourceNameDictionary[$OriginalId]
                            $metric.Subscription = $ResourceSubDictionary[$OriginalId]
                            $metric.ResourceGroup = $ResourceGroupDictionary[$OriginalId]
                        }
                    }
                }
            }

            $OutputPath = $FilePath + "_" + $RangeIdx + ".json"
            $Tmp | ConvertTo-Json -depth 5 -compress | Out-File $OutputPath -Encoding utf8
            $Tmp.Metrics.Clear()

            $RangeIdx++
        }
    }

    # Clear the progress bar now that every batch has been dispatched.
    Write-RdaProgress -Activity 'Metrics collection' -Completed

    $PhaseStopwatch.Stop()
    $DiagRecords = @($MetricDiagnostics)
    $OkCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Success' }).Count
    $TimeoutCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Timeout' }).Count
    $ThrottledCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Throttled' }).Count
    $ErrorCount = @($DiagRecords | Where-Object { $_.Outcome -eq 'Error' }).Count

    Write-MetricsDiag ("===== Metrics phase summary =====")
    # Outcomes are recorded per metric definition; one request can answer several,
    # so the request count is reported on the next line.
    Write-MetricsDiag ("Metric definitions: {0} | Success: {1} | Timeout: {2} | Throttled: {3} | Error: {4} | Elapsed: {5}s" -f $DiagRecords.Count, $OkCount, $TimeoutCount, $ThrottledCount, $ErrorCount, [math]::Round($PhaseStopwatch.Elapsed.TotalSeconds, 1))
    Write-MetricsDiag ("Azure Monitor requests: {0} for {1} metric definition(s), of which {2} single-metric fallback request(s); retries not counted" -f $MetricRequestCounts[0], $MetricCount, $MetricRequestCounts[1])
    if ($UseMetricsBatch)
    {
        # The per-resource requests above include those made for what the batch could not answer.
        Write-MetricsDiag ("Metrics batch (-UseMetricsBatch): {0} getBatch request(s) ({1} attempt(s)) for {2} resource(s); {3} resource(s) answered, {4} metric definition(s) answered, {5} sent on to the per-resource path." -f $MetricBatchCounts[0], $MetricBatchCounts[1], $MetricBatchCounts[2], $MetricBatchCounts[3], $MetricBatchCounts[4], $MetricBatchCounts[5])
        foreach ($Note in @($MetricBatchNotes | Sort-Object))
        {
            Write-MetricsDiag ('[batch] ' + $Note)
        }
    }

    if (($TimeoutCount + $ThrottledCount + $ErrorCount) -gt 0)
    {
        Write-MetricsDiag ("Non-success calls (where it got stuck):")
        $DiagNonSuccess = @($DiagRecords | Where-Object { $_.Outcome -ne 'Success' })
        # A 404 (NotFound, not retried) on a resource Resource Graph lists as being deleted is said so.
        $DeletingStates = Get-MetricDeletingState -Resources $Resources -Ids @($DiagNonSuccess | Where-Object { $_.NotFound } | ForEach-Object { [string]$_.Id } | Select-Object -Unique)
        foreach ($rec in ($DiagNonSuccess | Sort-Object ElapsedSec -Descending))
        {
            $Line = "  {0} idx={1} {2}/{3}/{4} interval={5} attempts={6} {7}s {8}" -f $rec.Outcome, $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Attempts, $rec.ElapsedSec, $rec.Error
            if ($rec.NotFound -and $DeletingStates.ContainsKey([string]$rec.Id))
            {
                $Line += (" - not found because the resource is being deleted (its state is '{0}'); not retried" -f $DeletingStates[[string]$rec.Id])
            }
            Write-MetricsDiag $Line
        }
    }

    if ($DiagRecords.Count -gt 0)
    {
        $Slowest = $DiagRecords | Sort-Object ElapsedSec -Descending | Select-Object -First 5
        Write-MetricsDiag ("Slowest 5 calls:")
        foreach ($rec in $Slowest)
        {
            Write-MetricsDiag ("  {0}s idx={1} {2}/{3}/{4} interval={5} ({6})" -f $rec.ElapsedSec, $rec.MetricIndex, $rec.Service, $rec.Name, $rec.Metric, $rec.Interval, $rec.Outcome)
        }
    }

    $WarningPreference = "Continue"

    $MetricDefs = $null;
    $MetricGroups = $null
    $MetricBatchTokens = $null
    $BatchTokenValues = $null
}
