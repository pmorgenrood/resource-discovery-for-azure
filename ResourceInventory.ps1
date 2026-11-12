# [CmdletBinding()] makes PowerShell reject a parameter name this script does not
# declare, so a misspelled switch (for example -Obfuscte) stops before any work
# instead of being ignored. It also supplies the -Debug switch read further down.
[CmdletBinding()]
param ($TenantID,
    $Appid,
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', ErrorMessage = 'Invalid SubscriptionID; must be a GUID')]
    [string]$SubscriptionID,
    [securestring]$Secret,
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$', ErrorMessage = 'Invalid resource group name; must match ^[A-Za-z0-9._()-]{1,90}$')]
    [string]$ResourceGroup,
    [string[]]$Service,
    [string]$ObfuscationDictionary,
    [switch]$SkipMetrics,
    [switch]$SkipConsumption,
    [switch]$DeviceLogin,
    [switch]$UseManagedIdentity,
    [switch]$Obfuscate,
    [switch]$RunAllSubs,
    $ConcurrencyLimit = 6,
    $MetricsLookbackDays = 31,
    $ReportName = 'ResourcesReport',
    $OutputDirectory,
    # Internal, set by Run-AllSubscriptions.ps1 (with -RunAllSubs): the
    # consumption window its up-front check queried, as 'yyyy-MM-dd' dates, so
    # this run collects the same window even after midnight. When absent (or
    # not valid) the run computes the window itself.
    [string]$ConsumptionWindowStart,
    [string]$ConsumptionWindowEnd)

# PowerShell 7 on every platform, checked first, before any module or sign-in
# step can stop the run with other advice.
if ($PSVersionTable.PSVersion.Major -lt 7)
{
    Write-Host "You must use PowerShell 7 to run the inventory script." -ForegroundColor Red
    Write-Host "https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell" -ForegroundColor Yellow
    exit 1
}

$FunctionsFile = Join-Path $PSScriptRoot 'Functions/ResourceInventory.Functions.ps1'
if (-not (Test-Path -Path $FunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $FunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $FunctionsFile

$CommonFunctionsFile = Join-Path $PSScriptRoot 'Functions/Common.Functions.ps1'
if (-not (Test-Path -Path $CommonFunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $CommonFunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $CommonFunctionsFile

$AzModulesFunctionsFile = Join-Path $PSScriptRoot 'Functions/AzModules.Functions.ps1'
if (-not (Test-Path -LiteralPath $AzModulesFunctionsFile -PathType Leaf))
{
    Write-Host "ERROR: Required functions file not found: $AzModulesFunctionsFile" -ForegroundColor Red
    Write-Host "Ensure the 'Functions' folder ships alongside this script." -ForegroundColor Yellow
    exit 1
}
. $AzModulesFunctionsFile
# -Debug:$false is bound too, so read the value, not only whether it was passed.
$DebugMode = $PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug']

if ($DebugMode) { $DebugPreference = 'Continue' }

if ($DebugMode) { $ErrorActionPreference = "Continue" }Else { $ErrorActionPreference = "silentlycontinue" }

Write-Debug ('Debugging Mode: On. ErrorActionPreference was set to "Continue", every error will be presented.')

function Variables
{
    $Global:ResourceContainers = @()
    $Global:Resources = @()
    # Discovered resource count for this run. $Global:Resources is released once the inventory
    # is written, so callers read this instead; reset here so an early exit never reports the
    # previous run's count.
    $Global:ResourceCount = 0
    $Global:Subscriptions = ''
    $Global:ReportName = $ReportName
    $Global:Version = GetLocalVersion

    $Global:ResourceIdDictionary = $null
    $Global:ResourceNameDictionary = $null
    $Global:ResourceSubscriptionDictionary = $null
    $Global:ResourceResourceGroupDictionary = $null
    $Global:TagValueDictionary = $null
    $Global:FreeTextDictionary = $null
    $Global:ObfuscationSubscriptionTokens = $null
    $Global:ObfuscationResourceGroupTokens = $null
    $Global:ObfuscationSubscriptionIndex = $null
    # New-ObfuscatedRowIdWithoutId's count of no-id rows and name index, per run.
    $script:RdaNoIdRowsSeen = $null
    $script:RdaNoIdNameIndex = $null
    # Stand-in path -> the row's real name (the path writes a '/' as '_'),
    # for the shareable diagnostics log's scrub.
    $Global:RdaNoIdRealNames = $null

    if ($Obfuscate.IsPresent)
    {
        # Keyed by real resource id, ignoring case: Azure ids are not case
        # sensitive, Resource Graph gives them in lower case and consumption
        # and metrics can give the same id in other casing. A case miss would
        # give the same resource a second name token and break the join.
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:TagValueDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        # Subscription id -> token (the prefix from its display name) and
        # resource group name -> token, shared by the inventory and the
        # consumption rows.
        $Global:ObfuscationSubscriptionTokens = @{}
        $Global:ObfuscationResourceGroupTokens = @{}
    }

    $Global:RawRepo = 'https://raw.githubusercontent.com/awslabs/resource-discovery-for-azure/main'
    $Global:TableStyle = "Medium15"
}

# 'nonprod_' when a name looks like a non-production one, else 'prod_'.
function Get-ObfuscationPrefix
{
    param([string]$Value)
    if ($Value -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $Value -match '(^|-)([dts])-') { return 'nonprod_' }
    return 'prod_'
}

# A new token for the resource name $Name of resource $ResourceId, with the type
# hint the report uses for Databricks, AKS-managed and scale set resources. This
# defines the name token format; the per-resource loop of RunInventorySetup builds
# the same token inline.
function New-ObfuscatedNameToken
{
    param([string]$ResourceId, [string]$Name)
    $Hint = if ($ResourceId -match 'databricks') { 'databricks_' } elseif ($ResourceId -match '/resourcegroups/mc_') { 'aks_' } elseif ($ResourceId -match 'virtualmachinescalesets') { 'vmss_' } else { '' }
    return (Get-ObfuscationPrefix $Name) + $Hint + [guid]::NewGuid().ToString()
}

# The $Global:Subscriptions entries by subscription id, in list order, so a lookup
# per resource does not scan the list. Built once per list, and again when the list
# is replaced. Ids compare as the -eq scans this replaces did (ignoring case,
# invariant culture); entries with no id are kept apart in NoId, the entries a
# missing subscription id matched.
function Get-ObfuscationSubscriptionIndex
{
    $Index = $Global:ObfuscationSubscriptionIndex
    if ($null -ne $Index -and [object]::ReferenceEquals($Index.Source, $Global:Subscriptions)) { return $Index }

    $ById = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::InvariantCultureIgnoreCase)
    $NoId = [System.Collections.Generic.List[object]]::new()
    foreach ($Sub in @($Global:Subscriptions))
    {
        if ($null -eq $Sub -or $null -eq $Sub.id) { $NoId.Add($Sub); continue }
        $Key = [string]$Sub.id
        if (-not $ById.ContainsKey($Key)) { $ById[$Key] = [System.Collections.Generic.List[object]]::new() }
        $ById[$Key].Add($Sub)
    }
    $Global:ObfuscationSubscriptionIndex = @{ Source = $Global:Subscriptions; ById = $ById; NoId = $NoId }
    return $Global:ObfuscationSubscriptionIndex
}

# Whether Get-ObfuscatedResourceId keeps $ResourceId as a tenant-scope path
# ('/providers/<namespace>/<type>/<name>...': each type has a name, no
# segment is empty or '$system'); any other '/providers/...' value gets one
# flat token. The seed check asks the same, so it treats a seeded value the
# way this run would write it.
function Test-RdaTenantScopeIdMaskable
{
    param([string]$ResourceId)
    if ([string]::IsNullOrEmpty($ResourceId)) { return $false }
    $Parts = $ResourceId.Split('/')
    if ($Parts.Count -lt 5 -or ($Parts.Count % 2) -ne 1 -or $Parts[0] -ne '' -or $Parts[1] -ine 'providers') { return $false }
    foreach ($Part in $Parts[1..($Parts.Count - 1)]) { if ([string]::IsNullOrEmpty($Part) -or $Part -eq '$system') { return $false } }
    return $true
}

# The masked form of a resource id. Every name segment is replaced (the
# subscription, the resource group and each resource name, a parent's
# included) and the 'subscriptions', 'resourcegroups', 'providers', namespace
# and type segments are kept, so the id keeps its ARM shape. Each segment uses
# the token its own subscription, resource group or resource already has, so a
# child's id holds its parent's masked name and ids join across the inventory,
# metrics and consumption files. A segment with no token yet gets one, recorded
# in the run's dictionaries (a name keyed by the real id up to that segment), so
# the obfuscation dictionary can reverse every segment. A caller that masks many
# ids passes the index from Get-ObfuscationSubscriptionIndex once as
# $SubscriptionIndex; without it the function gets the index itself.
function Get-ObfuscatedResourceId
{
    param([string]$ResourceId, [hashtable]$SubscriptionIndex)

    if ([string]::IsNullOrEmpty($ResourceId)) { return 'obfuscated' }
    $Parts = $ResourceId.Split('/')
    $Masked = [System.Collections.Generic.List[string]]::new()
    $Masked.Add('')
    # A tenant-scope id with no subscription (a reservation order, a
    # management group): '/providers/<namespace>/<type>/<name>...'. It keeps
    # its own path, every name segment masked as below, but only when every
    # name segment can be a token: each type has a name, and no segment is
    # empty or the fixed name '$system'. Any other '/providers/...' value
    # gets one flat token, as before (not changed here).
    $IsTenantScope = Test-RdaTenantScopeIdMaskable -ResourceId $ResourceId
    if ($IsTenantScope)
    {
        $i = 1
    }
    elseif ($Parts.Count -lt 3 -or $Parts[0] -ne '' -or $Parts[1] -ine 'subscriptions' -or [string]::IsNullOrEmpty($Parts[2]))
    {
        return (Get-ObfuscationPrefix $ResourceId) + [guid]::NewGuid().ToString()
    }
    else
    {
        if ($null -eq $SubscriptionIndex) { $SubscriptionIndex = Get-ObfuscationSubscriptionIndex }
        $SubEntries = $SubscriptionIndex.ById[$Parts[2]]
        $SubName = if ($null -ne $SubEntries) { [string]$SubEntries[0].name } else { '' }
        if ([string]::IsNullOrEmpty($SubName)) { $SubName = $Parts[2] }
        # One token per subscription id (two subscriptions may share a
        # display name); its prod_/nonprod_ prefix comes from the name.
        if (-not $Global:ObfuscationSubscriptionTokens.ContainsKey($Parts[2])) { $Global:ObfuscationSubscriptionTokens[$Parts[2]] = (Get-ObfuscationPrefix $SubName) + [guid]::NewGuid().ToString() }
        $SubToken = $Global:ObfuscationSubscriptionTokens[$Parts[2]]
        if (-not $ResourceSubscriptionDictionary.ContainsKey($ResourceId)) { $ResourceSubscriptionDictionary[$ResourceId] = $SubToken }

        $Masked.Add($Parts[1])
        $Masked.Add($SubToken)
        $i = 3
    }
    while ($i -lt $Parts.Count)
    {
        $Segment = $Parts[$i]
        $Masked.Add($Segment)
        if ($i + 1 -ge $Parts.Count) { break }
        $Next = $Parts[$i + 1]
        if ($i -eq 3 -and $Segment -ieq 'resourcegroups')
        {
            if (-not $Global:ObfuscationResourceGroupTokens.ContainsKey($Next)) { $Global:ObfuscationResourceGroupTokens[$Next] = (Get-ObfuscationPrefix $Next) + [guid]::NewGuid().ToString() }
            $Masked.Add($Global:ObfuscationResourceGroupTokens[$Next])
            if (-not $ResourceResourceGroupDictionary.ContainsKey($ResourceId)) { $ResourceResourceGroupDictionary[$ResourceId] = $Global:ObfuscationResourceGroupTokens[$Next] }
        }
        elseif ($Segment -ieq 'providers' -or [string]::IsNullOrEmpty($Next) -or $Next -eq '$system')
        {
            # A provider namespace, an empty segment, or the fixed name '$system'.
            $Masked.Add($Next)
        }
        else
        {
            $UpToName = $Parts[0..($i + 1)] -join '/'
            if (-not $ResourceNameDictionary.ContainsKey($UpToName) -or [string]::IsNullOrEmpty($ResourceNameDictionary[$UpToName])) { $ResourceNameDictionary[$UpToName] = New-ObfuscatedNameToken -ResourceId $UpToName -Name $Next }
            $Masked.Add($ResourceNameDictionary[$UpToName])
        }
        $i += 2
    }
    return ($Masked -join '/')
}

# Whether $MaskedId is the masked form of $RealId that Get-ObfuscatedResourceId
# writes: the same segments, with the subscription, the resource group and
# every name segment a prod_/nonprod_ token (a '$system' name kept), and the
# 'subscriptions', 'resourcegroups', 'providers', namespace and type segments
# as in the real id (ignoring case). A seeded id from an older dictionary
# (which masked only the last name, so a parent's real name was left) or a
# flat seeded token fails, and the run masks the real id again.
function Test-ObfuscatedIdShape
{
    param([string]$RealId, [string]$MaskedId)
    if ([string]::IsNullOrEmpty($RealId) -or [string]::IsNullOrEmpty($MaskedId)) { return $false }
    $R = $RealId.Split('/')
    $M = $MaskedId.Split('/')
    if ($R.Count -ne $M.Count -or $R.Count -lt 3 -or $R[0] -ne '' -or $M[0] -ne '') { return $false }
    # The tokens each slot takes: a subscription token has no hint, a resource
    # group token at most the older 'mc_' one, a name token at most the
    # databricks_/aks_/vmss_ hint. So the metric step's old sub_/rg_ tokens,
    # or any other word in a token, fail.
    $Guid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    $SubToken = '^(prod|nonprod)_' + $Guid + '$'
    $RgToken = '^(prod|nonprod)_(mc_)?' + $Guid + '$'
    $Token = '^(prod|nonprod)_(databricks_|aks_|vmss_)?' + $Guid + '$'
    if ($R[1] -ieq 'subscriptions')
    {
        if ($M[1] -ine 'subscriptions' -or $M[2] -cnotmatch $SubToken) { return $false }
        $i = 3
    }
    elseif ($R[1] -ieq 'providers') { $i = 1 }
    else { return $false }
    while ($i -lt $R.Count)
    {
        if ($M[$i] -ine $R[$i]) { return $false }
        if ($i + 1 -ge $R.Count) { break }
        $Next = $R[$i + 1]
        if ($R[$i] -ieq 'providers' -or [string]::IsNullOrEmpty($Next) -or $Next -eq '$system')
        {
            if ($M[$i + 1] -ine $Next) { return $false }
        }
        elseif ($i -eq 3 -and $R[$i] -ieq 'resourcegroups' -and $R[1] -ieq 'subscriptions')
        {
            if ($M[$i + 1] -cnotmatch $RgToken) { return $false }
        }
        elseif ($M[$i + 1] -cnotmatch $Token) { return $false }
        $i += 2
    }
    return $true
}

# A masked ARM path for a collector row with no resource id under -Obfuscate,
# so the inventory never holds an empty or flat ID. The row gets a stand-in
# real id, which goes through Get-ObfuscatedResourceId and into the run's
# dictionaries like any other id, so its ResourceIdMap entry reverses it:
#   real:   /subscriptions/<sub id>/resourcegroups/<group>/providers/rda.noid/<collector>/<name>~<8 hex>
#   masked: /subscriptions/<sub tok>/resourcegroups/<rg tok>/providers/rda.noid/<collector>/<name tok>
# The subscription is the row's Subscription (display name) looked up in the
# run's list, so the tokens are the ones the subscription's other rows get.
# 'rda.noid' names no Azure provider: the row has no real id. A missing
# subscription, group or name is written '~nosub', '~norg', '~noname' ('~' is
# in no Azure name, so it never meets a real one). The 8 hex are the start of
# a SHA-256 of collector, subscription, group and name, so the same row gets
# the same stand-in every run and a seeded run (-ObfuscationDictionary) reuses
# its masked id; a second row with all four the same in one run adds -2, -3...
# Returns the masked id and the three tokens, which are its own segments.
function New-ObfuscatedRowIdWithoutId
{
    param([string]$Subscription, [string]$ResourceGroup, [string]$Name, [string]$Collector)

    $SubSegment = '~nosub'
    if (-not [string]::IsNullOrEmpty($Subscription))
    {
        $SubSegment = $Subscription
        # Display name -> ids in list order, built once per subscription list.
        if ($null -eq $script:RdaNoIdNameIndex -or -not [object]::ReferenceEquals($script:RdaNoIdNameIndex.Source, $Global:Subscriptions))
        {
            $ByName = @{}
            foreach ($Sub in @($Global:Subscriptions))
            {
                if ($null -eq $Sub -or [string]::IsNullOrEmpty([string]$Sub.id) -or [string]::IsNullOrEmpty([string]$Sub.name)) { continue }
                if (-not $ByName.ContainsKey([string]$Sub.name)) { $ByName[[string]$Sub.name] = [System.Collections.Generic.List[string]]::new() }
                if (-not $ByName[[string]$Sub.name].Contains([string]$Sub.id)) { $ByName[[string]$Sub.name].Add([string]$Sub.id) }
            }
            $script:RdaNoIdNameIndex = @{ Source = $Global:Subscriptions; ByName = $ByName; Warned = @{} }
        }
        $NameIds = @(if ($script:RdaNoIdNameIndex.ByName.ContainsKey($Subscription)) { $script:RdaNoIdNameIndex.ByName[$Subscription] })
        if ($NameIds.Count -ge 1) { $SubSegment = $NameIds[0] }
        # The row names its subscription only by display name: with two
        # subscriptions of that name it is filed under the first one (said
        # once per name).
        if ($NameIds.Count -gt 1 -and -not $script:RdaNoIdNameIndex.Warned.ContainsKey($Subscription))
        {
            $script:RdaNoIdNameIndex.Warned[$Subscription] = $true
            if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)
            {
                Write-Log -Message ("A collector row with no id names subscription '{0}', which {1} subscriptions share; its masked id is filed under the first of them." -f $Subscription, $NameIds.Count) -Severity 'Warning'
            }
        }
    }
    $RgSegment = if ([string]::IsNullOrEmpty($ResourceGroup)) { '~norg' } else { $ResourceGroup }
    $Type = ([string]$Collector).ToLowerInvariant() -replace '[^a-z0-9.]', ''
    if ($Type -notmatch '^[a-z]') { $Type = 'unknown' }
    $NameBase = if ([string]::IsNullOrEmpty($Name)) { '~noname' } else { $Name -replace '/', '_' }
    $SubSegment = $SubSegment -replace '/', '_'
    $RgSegment = $RgSegment -replace '/', '_'
    $Key = ('{0}|{1}|{2}|{3}' -f $Type, $SubSegment, $RgSegment, $NameBase).ToLowerInvariant()
    # SHA256.Create() and ComputeHash, because SHA256.HashData and
    # Convert.ToHexString need .NET 5, which PowerShell 7.0 does not have.
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try { $HashBytes = $Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Key)) }
    finally { $Sha.Dispose() }
    $Hash = -join @($HashBytes[0..3] | ForEach-Object { $_.ToString('x2') })
    if ($null -eq $script:RdaNoIdRowsSeen) { $script:RdaNoIdRowsSeen = @{} }
    $script:RdaNoIdRowsSeen[$Key] = 1 + [int]$script:RdaNoIdRowsSeen[$Key]
    $Suffix = if ($script:RdaNoIdRowsSeen[$Key] -gt 1) { '{0}-{1}' -f $Hash, $script:RdaNoIdRowsSeen[$Key] } else { $Hash }
    $StandIn = '/subscriptions/{0}/resourcegroups/{1}/providers/rda.noid/{2}/{3}~{4}' -f $SubSegment, $RgSegment, $Type, $NameBase, $Suffix
    if (-not [string]::IsNullOrEmpty($Name))
    {
        if ($null -eq $Global:RdaNoIdRealNames) { $Global:RdaNoIdRealNames = @{} }
        $Global:RdaNoIdRealNames[$StandIn] = $Name
    }

    # A seeded run already holds this stand-in's masked id: keep it.
    $Masked = $null
    if (-not ($ResourceIdDictionary.TryGetValue($StandIn, [ref]$Masked) -and (Test-ObfuscatedIdShape -RealId $StandIn -MaskedId $Masked)))
    {
        $Masked = Get-ObfuscatedResourceId -ResourceId $StandIn
    }
    $ResourceIdDictionary[$StandIn] = $Masked
    $Parts = $Masked.Split('/')
    # The id's own tokens, recorded as Get-ObfuscatedResourceId records them,
    # also when a seeded id was kept, so the dictionary file reverses them.
    $ResourceNameDictionary[$StandIn] = $Parts[-1]
    $ResourceSubscriptionDictionary[$StandIn] = $Parts[2]
    $ResourceResourceGroupDictionary[$StandIn] = $Parts[4]
    return [pscustomobject]@{
        Id            = $Masked
        Name          = $Parts[-1]
        Subscription  = $Parts[2]
        ResourceGroup = $Parts[4]
    }
}

Function RunInventorySetup()
{
    function CheckVersion()
    {
        if ($Global:RdaSessionInitialized)
        {
            return
        }

        Write-Log -Message ('Checking Version') -Severity 'Info'
        Write-Log -Message ('Version: {0}' -f $Global:Version) -Severity 'Info'

        try
        {
            $VersionJson = (New-Object System.Net.WebClient).DownloadString($RawRepo + '/Version.json') | ConvertFrom-Json
        }
        catch
        {
            Write-Log -Message ("Could not reach {0}/Version.json to check for an update: {1}" -f $RawRepo, $_.Exception.Message) -Severity 'Warning'
            Write-Log -Message ('Continuing with local version {0}. If you are on a managed network, this is expected.' -f $Global:Version) -Severity 'Info'
            return
        }

        $VersionNumber = ('{0}.{1}.{2}' -f $VersionJson.MajorVersion, $VersionJson.MinorVersion, $VersionJson.BuildVersion)

        if ($VersionNumber -ne $Global:Version)
        {
            $LocalParsed = $null
            $UpstreamParsed = $null
            $HaveSemver = [version]::TryParse($Global:Version, [ref]$LocalParsed) -and `
                [version]::TryParse($VersionNumber, [ref]$UpstreamParsed)

            if ($HaveSemver -and $LocalParsed -lt $UpstreamParsed)
            {
                Write-Log -Message ('A newer version ({0}) is available; you are running {1}. Consider updating: https://github.com/awslabs/resource-discovery-for-azure' -f $VersionNumber, $Global:Version) -Severity 'Warning'
            }
            elseif ($HaveSemver -and $LocalParsed -gt $UpstreamParsed)
            {
                Write-Log -Message ('Running a local/pre-release version ({0}); latest published is {1}.' -f $Global:Version, $VersionNumber) -Severity 'Info'
            }
            else
            {
                Write-Log -Message ('Local version ({0}) differs from the latest published version ({1}).' -f $Global:Version, $VersionNumber) -Severity 'Warning'
            }
        }
    }

    function CheckCliRequirements()
    {
        $RequiredAzSubModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing')

        # An earlier run in this session loaded the modules. Skip the checks
        # only when all four are still loaded (one can have been removed
        # since, with Remove-Module) and the lowest loaded Az.Accounts is
        # still the supported version: an older build of the tool may have
        # loaded an older one. Get-Module without -ListAvailable reads the
        # session only, so this stays cheap. Otherwise the full check below
        # runs: it loads what is missing, or stops the run.
        if ($Global:AzPowerShellLoaded)
        {
            $NotLoaded = @($RequiredAzSubModules | Where-Object { $null -eq (Get-Module -Name $_ -ErrorAction SilentlyContinue | Select-Object -First 1) })
            $LoadedAzAccounts = @(Get-Module -Name Az.Accounts -ErrorAction SilentlyContinue |
                    Where-Object { $_ -and $_.Version } |
                    ForEach-Object { [version]$_.Version } |
                    Sort-Object) | Select-Object -First 1
            if ($NotLoaded.Count -eq 0 -and $LoadedAzAccounts -and $LoadedAzAccounts -ge (Get-RdaAzAccountsMinimumVersion))
            {
                return
            }
        }

        Write-Log -Message ('Checking Azure PowerShell Module...') -Severity 'Info'

        $MissingAzSubModules = @($RequiredAzSubModules | Where-Object { $null -eq (Get-Module -Name $_ -ListAvailable -ErrorAction SilentlyContinue | Select-Object -First 1) })

        if ($MissingAzSubModules.Count -gt 0)
        {
            Write-Log -Message ('Required Azure PowerShell module(s) not found: {0}' -f ($MissingAzSubModules -join ', ')) -Severity 'Error'
            Write-Log -Message ('This tool needs only these Az submodules. Install them manually before re-running. From an elevated PowerShell 7 prompt:') -Severity 'Error'
            Write-Log -Message ('  Install-Module -Name {0} -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck' -f ($RequiredAzSubModules -join ',')) -Severity 'Error'
            Write-Log -Message ('Or install the full rollup (larger, slower first import): Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            Write-Log -Message ('Or in Cloud Shell, the Az module is already preinstalled - if it is missing your shell environment is broken.') -Severity 'Error'
            # exit, not throw: the production 'SilentlyContinue' preference
            # suppresses a bare throw and the run would go on to sign in and
            # collect without the modules its collectors need.
            exit 1
        }

        # Az.Accounts must be the supported version or newer, on disk and in
        # this session (Functions/AzModules.Functions.ps1 holds the number).
        # The printed command is the way out: once it has run, the next run
        # passes this check.
        # -SubModule: Az modules an earlier run in this session loaded can
        # hold an older Az.Accounts there, and the copy of a submodule that
        # would load can pin one in its manifest; the check names the one to
        # update, before anything is loaded.
        $AzAccountsCheck = Test-RdaAzAccountsVersion -SubModule $RequiredAzSubModules
        if ($AzAccountsCheck.Status -ne 'Ok')
        {
            foreach ($Line in $AzAccountsCheck.Messages)
            {
                Write-Log -Message $Line -Severity 'Error'
            }
            # exit, not throw, for the same reason as above.
            exit 1
        }
        Write-Log -Message ('Azure PowerShell modules present (Az.Accounts {0}, {1} or newer needed); required: {2}' -f $AzAccountsCheck.Installed, $AzAccountsCheck.Required, ($RequiredAzSubModules -join ', ')) -Severity 'Success'

        try
        {
            # Az.Accounts first, with -MinimumVersion: the check above saw the
            # highest copy on disk, but a plain import takes the first copy in
            # PSModulePath order, which can be an older one.
            Write-Log -Message 'Loading Az.Accounts...' -Severity 'Info'
            Import-Module Az.Accounts -MinimumVersion (Get-RdaAzAccountsMinimumVersion) -ErrorAction Stop -DisableNameChecking | Out-Null
            foreach ($AzSubModule in @($RequiredAzSubModules | Where-Object { $_ -ne 'Az.Accounts' }))
            {
                Write-Log -Message ('Loading {0}...' -f $AzSubModule) -Severity 'Info'
                Import-Module $AzSubModule -ErrorAction Stop -DisableNameChecking | Out-Null
            }
            $Global:AzPowerShellLoaded = $true
        }
        catch
        {
            Write-Log -Message ('Azure PowerShell module is present on disk but failed to load: {0}' -f $_.Exception.Message) -Severity 'Error'
            Write-Log -Message ('This usually indicates a broken install - the module manifest is present but its bundled assemblies (MSAL, Azure.Core, etc.) are missing or unloadable.') -Severity 'Error'
            Write-Log -Message ('Reinstall with: Install-Module -Name Az -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck') -Severity 'Error'
            Write-Log -Message ('If the broken install was created by a previous run of this script, also run: Get-Module Az* -ListAvailable | Uninstall-Module -Force') -Severity 'Error'
            $Global:AzPowerShellLoaded = $false
            # exit, not throw, for the same reason as above.
            exit 1
        }

        # Check the copy that actually loaded. The import above takes 5.5.4 or
        # newer, but Az.Compute, Az.Monitor and Az.Billing load after it: one
        # whose manifest asks for an exact older Az.Accounts (RequiredVersion)
        # makes PowerShell load that older copy next to the new one, and the
        # check reads the lowest loaded copy. A new session alone loads the
        # same pair again, so -SubModule makes the advice name the submodule
        # and the command that updates it. The printed advice is the way out;
        # nothing retries.
        $AzAccountsCheck = Test-RdaAzAccountsVersion -SubModule $RequiredAzSubModules
        if ($AzAccountsCheck.Status -ne 'Ok')
        {
            foreach ($Line in $AzAccountsCheck.Messages)
            {
                Write-Log -Message $Line -Severity 'Error'
            }
            $Global:AzPowerShellLoaded = $false
            # exit, not throw, for the same reason as above.
            exit 1
        }

    }

    function CheckPowerShell()
    {
        if (-not $Global:RdaSessionInitialized)
        {
            Write-Log -Message ('Checking PowerShell...') -Severity 'Info'

            $Global:PlatformOS = 'PowerShell Desktop'
            $CloudShell = try { Get-CloudDrive }catch {}

            if ($CloudShell)
            {
                Write-Log -Message ('Identified Environment as Azure CloudShell') -Severity 'Success'
                $Global:PlatformOS = 'Azure CloudShell'
            }
            elseif ($PSVersionTable.Platform -eq 'Unix')
            {
                Write-Log -Message ('Identified Environment as PowerShell Unix') -Severity 'Success'
                $Global:PlatformOS = 'PowerShell Unix'
            }
            else
            {
                Write-Log -Message ('Identified Environment as PowerShell Desktop') -Severity 'Success'
                $Global:PlatformOS = 'PowerShell Desktop'
            }

            # PowerShell 7 is checked at the top of the script.
            Write-Log -Message ("PowerShell Version {0}" -f $PSVersionTable.PSVersion.Major) -Severity 'Info'
        }

        $ProcDiscriminator = ('{0:x4}' -f ($PID -band 0xffff))
        $Global:CurrentDateTime = ((get-date -Format "yyyyMMddHHmmssfff") + $ProcDiscriminator)
        $Global:FolderName = $Global:ReportName + $CurrentDateTime

        if ($Global:PlatformOS -eq 'Azure CloudShell' -or $Global:PlatformOS -eq 'PowerShell Unix')
        {
            $DefaultOutputDir = "$HOME/InventoryReports/" + $Global:FolderName + "/"
        }
        else
        {
            $DefaultOutputDir = "C:\InventoryReports\" + $Global:FolderName + "\"
        }

        if ($OutputDirectory)
        {
            try
            {
                $OutputDirectory = (Resolve-Path $OutputDirectory -ErrorAction Stop).Path + [IO.Path]::DirectorySeparatorChar
            }
            catch
            {
                Write-Log -Message ("The output directory {0} could not be found or made. Pass -OutputDirectory as the full path of a folder you can write to." -f $OutputDirectory) -Severity 'Error'
                exit 1
            }
        }

        $Global:DefaultPath = if ($OutputDirectory) { $OutputDirectory } else { $DefaultOutputDir }

        # Refused before sign-in, so nobody is asked to sign in or pick a
        # tenant for a run that cannot go on.
        if (![string]::IsNullOrEmpty($ResourceGroup) -and [string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ("-ResourceGroup was given without -SubscriptionID.") -Severity 'Error'
            Write-Log -Message ("Pass -SubscriptionID when you use -ResourceGroup.") -Severity 'Error'
            exit 1
        }

        # Every environment signs in through LoginSession. In Cloud Shell the
        # sign-in Cloud Shell made is a cached sign-in like any other (rule 2),
        # so -Appid, -UseManagedIdentity, -DeviceLogin and -TenantID are
        # honoured and its token and tenant are checked there too.
        if ($platformOS -in 'Azure CloudShell', 'PowerShell Unix', 'PowerShell Desktop')
        {
            LoginSession
        }
    }

    function LoginSession()
    {
        if (-not $Global:RdaSessionInitialized)
        {
            # The cloud of the Az PowerShell sign-in (Connect-AzAccount signs
            # in to AzureCloud unless it is told another environment).
            $CloudEnvName = try { (Get-AzContext -ErrorAction Stop).Environment.Name } catch { $null }
            Write-Host "Azure Cloud Environment: " -NoNewline
            if ($CloudEnvName) { Write-Host $CloudEnvName -ForegroundColor Green }
            else { Write-Host 'AzureCloud (not signed in yet)' -ForegroundColor Green }
        }

        # Direct run (not -RunAllSubs), Azure Cloud Shell included. The tool
        # signs in with Az PowerShell only, by three rules:
        #  1. -Appid/-Secret/-TenantID: always the service principal, even
        #     when a user is already signed in. If that sign-in fails, or the
        #     context is then not that service principal, the run stops with
        #     exit 1; it never goes on as whoever was signed in before. The
        #     same holds for -UseManagedIdentity and the machine's identity.
        #  2. Otherwise a cached sign-in that can acquire a token for the
        #     target tenant silently is reused, with no prompt: as it is when
        #     it is on that tenant, switched to it for this process when it is
        #     on another one. Cloud Shell's own sign-in is such a sign-in.
        #  3. Otherwise sign in once (device code with -DeviceLogin; a
        #     session with no console stops with exit 1 instead of opening a
        #     browser), then check the token; if the sign-in fails or the
        #     token still fails the run stops with exit 1 instead of prompting
        #     again or collecting an empty inventory. The next run starts from
        #     the same checks, so it cannot loop either.
        # Whatever the rule, the run goes on only when the context is on the
        # target tenant (Invoke-AzRestMethod and Get-AzSubscription use the
        # context's tenant) and the tenant lists a subscription to collect:
        # an Enabled one without -SubscriptionID, else the one it names.
        # With nothing usable and no -TenantID, the sign-in is made without a
        # tenant and the tenant is chosen afterwards. A usable sign-in is never
        # disconnected; a tenant switch applies to this process only, and so
        # do service principal and managed identity sign-ins.
        if (!$RunAllSubs.IsPresent)
        {
            function Stop-SignIn([string]$Message, [string]$Advice)
            {
                Write-Log -Message $Message -Severity 'Error'
                Write-Log -Message $Advice -Severity 'Error'
                exit 1
            }

            function Stop-UnusableSignIn([string]$Tenant, [string]$Advice)
            {
                Stop-SignIn -Message ("Az PowerShell: sign-in to tenant {0} did not give a usable token; stopping instead of prompting again." -f $Tenant) -Advice $Advice
            }

            function Get-UserSignInAdvice([string]$Tenant)
            {
                $Command = if ($Tenant) { "Connect-AzAccount -Tenant $Tenant" } else { 'Connect-AzAccount' }
                return ("Run '{0}' yourself, complete any MFA or Conditional Access prompt, then re-run (or pass -DeviceLogin, or -UseManagedIdentity on an Azure VM)." -f $Command)
            }

            # The one sign-in of a run. A failed sign-in stops the run: it is
            # not tried again, and the run does not go on with whatever was
            # signed in before it.
            function Invoke-AzPsSignIn([hashtable]$SignInArgs, [string]$What, [string]$Advice)
            {
                try { Connect-AzAccount @SignInArgs -ErrorAction Stop | Out-Null }
                catch { Stop-SignIn -Message ("Az PowerShell: {0} failed: {1}" -f $What, $_.Exception.Message) -Advice $Advice }
            }

            function Invoke-AzPsUserSignIn([string]$Tenant)
            {
                $Advice = Get-UserSignInAdvice -Tenant $Tenant
                if (-not $DeviceLogin.IsPresent -and -not (Test-RdaInteractiveSession))
                {
                    Stop-SignIn -Message 'Az PowerShell: no usable sign-in, and this session has no console to sign in from (non-interactive); stopping instead of opening a browser.' -Advice ('Sign in before the run, or pass -Appid/-Secret/-TenantID, -UseManagedIdentity on an Azure VM, or -DeviceLogin. ' + $Advice)
                }
                $SignInArgs = @{}
                if ($Tenant) { $SignInArgs.Tenant = $Tenant }
                if ($DeviceLogin.IsPresent) { $SignInArgs.UseDeviceAuthentication = $true }
                # The reconnect before metrics and consumption reads this: a
                # run prompts a person at most once.
                $script:RdaUserSignInMade = $true
                Invoke-AzPsSignIn -SignInArgs $SignInArgs -What 'sign-in' -Advice $Advice
            }

            # The tenant id (a GUID) of tenant $Tenant, given as an id or a
            # domain: a domain is resolved through the token Az PowerShell
            # acquires for it.
            function Get-AzPsTenantId([string]$Tenant)
            {
                $Id = [guid]::Empty
                if ([guid]::TryParse($Tenant, [ref]$Id)) { return $Tenant }
                try { return [string](Get-AzAccessToken -TenantId $Tenant -ErrorAction Stop -WarningAction SilentlyContinue).TenantId }
                catch { return $null }
            }

            function Test-AzPsContextOnTenant([string]$Tenant)
            {
                $Current = Get-AzPsSignedInTenant
                $Expected = Get-AzPsTenantId -Tenant $Tenant
                return ([bool]$Current -and [bool]$Expected -and $Current -eq $Expected)
            }

            # A token for the tenant does not prove the context is on it, and
            # the collectors use the context. Returns the tenant id.
            function Confirm-AzPsContextTenant([string]$Tenant, [string]$Advice)
            {
                if (-not (Test-AzPsContextOnTenant -Tenant $Tenant))
                {
                    $Current = Get-AzPsSignedInTenant
                    Stop-SignIn -Message ("Az PowerShell: the context is on tenant {0}, not on tenant {1}; stopping instead of collecting another tenant." -f $(if ($Current) { $Current } else { '(none)' }), $Tenant) -Advice $Advice
                }
                return (Get-AzPsSignedInTenant)
            }

            # After a service principal or managed identity sign-in the
            # context must be that identity, never a cached user.
            function Confirm-AzPsAccount([string]$Type, [string]$Id, [string]$What, [string]$Advice)
            {
                $Account = try { (Get-AzContext -ErrorAction Stop).Account } catch { $null }
                if ($null -eq $Account -or [string]$Account.Type -ne $Type -or ($Id -and [string]$Account.Id -ne $Id))
                {
                    Stop-SignIn -Message ("Az PowerShell: after the {0} the context is not that identity; stopping instead of running as another account." -f $What) -Advice $Advice
                }
            }

            # The run's subscriptions. A direct run with none stops instead of
            # writing an empty report. Without -SubscriptionID only Enabled
            # subscriptions are kept, as `az account list` did by default. With
            # -SubscriptionID every state is kept, so a named Disabled or Warned
            # subscription is still found; a named one the sign-in does not
            # list stops the run.
            function Set-RdaRunSubscriptions([string]$Tenant)
            {
                $script:RdaRunTenant = $Tenant
                $Listed = @(Get-RdaTenantSubscriptions -Tenant $Tenant)
                $Access = 'Check that the signed-in identity has at least Reader on a subscription of the tenant, and that -TenantID names the right tenant, then re-run.'
                $Empty = "Az PowerShell: tenant {0} lists {1} for this sign-in; stopping instead of writing an empty report."
                if ($Listed.Count -eq 0)
                {
                    Stop-SignIn -Message ($Empty -f $Tenant, 'no subscriptions') -Advice $Access
                }
                if ([string]::IsNullOrEmpty($SubscriptionID))
                {
                    $Listed = @($Listed | Where-Object { [string]$_.state -eq 'Enabled' })
                    if ($Listed.Count -eq 0)
                    {
                        Stop-SignIn -Message ($Empty -f $Tenant, 'no Enabled subscription') -Advice ('Without -SubscriptionID only Enabled subscriptions are collected. To collect a subscription that is not Enabled, pass -SubscriptionID; or pass -TenantID for a tenant with Enabled subscriptions.')
                    }
                }
                elseif (@($Listed | Where-Object { [string]$_.id -eq $SubscriptionID }).Count -eq 0)
                {
                    Stop-SignIn -Message ("Az PowerShell: tenant {0} does not list subscription {1} for this sign-in; stopping instead of writing an empty report." -f $Tenant, $SubscriptionID) -Advice 'Check that -SubscriptionID is right, that -TenantID names its tenant, and that the signed-in identity has at least Reader on it, then re-run.'
                }
                $Global:Subscriptions = $Listed
            }

            if ($Appid)
            {
                if ($UseManagedIdentity.IsPresent)
                {
                    Write-Log -Message ('-UseManagedIdentity is ignored because -Appid is given; signing in as the Service Principal.') -Severity 'Warning'
                }
                if (!$Secret -or !$TenantID)
                {
                    Write-Log -Message ("You are trying to use Service Principal Authentication Method in a wrong way.") -Severity 'Error'
                    Write-Log -Message ("It's Mandatory to specify Application ID, Secret and Tenant ID in Azure Resource Inventory") -Severity 'Error'
                    Write-Log -Message (".\ResourceInventory.ps1 -appid <SP AppID> -secret <SP Secret> -tenant <TenantID>") -Severity 'Error'
                    exit 1
                }

                Write-Log -Message ("Using Service Principal Authentication Method") -Severity 'Success'
                $SpAdvice = 'Check the -Appid, -Secret and -TenantID values and that the Service Principal can sign in to the tenant, then re-run.'
                # The secret stays a SecureString inside the credential.
                $Credential = New-Object System.Management.Automation.PSCredential($Appid, $Secret)
                # -Scope Process: not saved as the default context, so a later
                # run without -Appid does not reuse the service principal.
                Invoke-AzPsSignIn -SignInArgs @{ ServicePrincipal = $true; Credential = $Credential; Tenant = $TenantID; Scope = 'Process' } -What 'service principal sign-in' -Advice $SpAdvice
                Confirm-AzPsAccount -Type 'ServicePrincipal' -Id $Appid -What 'service principal sign-in' -Advice $SpAdvice
                if (!(Test-AzPsTokenSilent -Tenant $TenantID)) { Stop-UnusableSignIn -Tenant $TenantID -Advice $SpAdvice }

                Set-RdaRunSubscriptions -Tenant (Confirm-AzPsContextTenant -Tenant $TenantID -Advice $SpAdvice)
                return
            }

            if ($UseManagedIdentity.IsPresent)
            {
                Write-Log -Message ('Using Managed Identity Authentication Method') -Severity 'Info'
                $MiAdvice = 'Check that this machine has a managed identity with access to the tenant (and pass -TenantID for a specific tenant), then re-run.'
                # -Scope Process, as for the service principal.
                $MiArgs = @{ Identity = $true; Scope = 'Process' }
                if ($TenantID) { $MiArgs.Tenant = $TenantID }
                Invoke-AzPsSignIn -SignInArgs $MiArgs -What 'managed identity sign-in' -Advice $MiAdvice
                Confirm-AzPsAccount -Type 'ManagedService' -What 'managed identity sign-in' -Advice $MiAdvice

                $TargetTenant = if ($TenantID) { $TenantID } else { Get-AzPsSignedInTenant }
                if (!$TargetTenant) { Stop-UnusableSignIn -Tenant '(managed identity)' -Advice $MiAdvice }
                if (!(Test-AzPsTokenSilent -Tenant $TargetTenant)) { Stop-UnusableSignIn -Tenant $TargetTenant -Advice $MiAdvice }

                Set-RdaRunSubscriptions -Tenant (Confirm-AzPsContextTenant -Tenant $TargetTenant -Advice $MiAdvice)
                return
            }

            $PsTenant = Get-AzPsSignedInTenant
            $PsTokenOk = if ($PsTenant) { Test-AzPsTokenSilent -Tenant $PsTenant } else { $false }

            # Without -TenantID the target is the tenant of the cached sign-in,
            # usable or not: one that cannot acquire a token is signed in to
            # that same tenant again below.
            $TargetTenant = $null
            if ($TenantID) { $TargetTenant = $TenantID }
            elseif ($PsTenant) { $TargetTenant = $PsTenant }

            if (!$TargetTenant)
            {
                # Nothing usable and no -TenantID: sign in once without a
                # tenant, choose the tenant, then check the token on it.
                Write-Log -Message ('Tenant ID not specified. Use -TenantID parameter if you want to specify directly.') -Severity 'Warning'
                Write-Log -Message ('Authenticating Azure') -Severity 'Info'

                # No Az debug lines during the sign-in; afterwards the caller's
                # setting again (Continue only under -Debug).
                $SavedDebugPreference = $DebugPreference
                $DebugPreference = "SilentlyContinue"
                if ($DeviceLogin.IsPresent) { Write-Log -Message ('Calling Login, using device login.') -Severity 'Info' }
                # With no console, Invoke-AzPsUserSignIn stops instead of
                # opening a browser, so the line is only for a console.
                elseif (Test-RdaInteractiveSession) { Write-Log -Message ('Calling Login, the browser will open and prompt you to login.') -Severity 'Info' }

                try { Invoke-AzPsUserSignIn }
                finally { $DebugPreference = $SavedDebugPreference }

                # The tenants the sign-in reaches, by the tenant each
                # subscription is accessed through (TenantId, not
                # HomeTenantId: a subscription delegated with Azure Lighthouse
                # has the customer's tenant as its home), plus the tenant the
                # sign-in is on.
                $Tenants = @(@(@(Get-AzSubscription -WarningAction SilentlyContinue).TenantId) + @(Get-AzPsSignedInTenant) | Where-Object { $_ } | Sort-Object -Unique)

                Write-Log -Message ('Checking number of Tenants') -Severity 'Info'

                if ($Tenants.Count -eq 0)
                {
                    Stop-UnusableSignIn -Tenant '(none given)' -Advice (Get-UserSignInAdvice)
                }
                elseif ($Tenants.Count -eq 1)
                {
                    Write-Log -Message ('You have privileges only in One Tenant') -Severity 'Success'
                    $TargetTenant = $Tenants[0]
                }
                else
                {
                    Write-Log -Message ('Select the the Azure Tenant ID that you want to connect: ') -Severity 'Warning'

                    $SequenceID = 1
                    foreach ($ListedTenant in $Tenants)
                    {
                        write-host "$SequenceID)  $ListedTenant"
                        $SequenceID ++
                    }

                    if (-not (Test-RdaInteractiveSession))
                    {
                        $TargetTenant = $Tenants[0]
                        Write-Log -Message ("Non-interactive session with multiple tenants and no -TenantID: defaulting to the first tenant ({0}). Pass -TenantID to choose explicitly." -f $TargetTenant) -Severity 'Warning'
                    }
                    else
                    {
                        # Asked at most twice; an answer that is not a number
                        # of the list stops the run.
                        for ($Ask = 1; $Ask -le 2 -and !$TargetTenant; $Ask++)
                        {
                            $Answer = [string](Read-Host "Select Tenant (Default 1)")
                            $Number = 0
                            if ([string]::IsNullOrWhiteSpace($Answer)) { $Number = 1 }
                            elseif (-not [int]::TryParse($Answer.Trim(), [ref]$Number)) { $Number = 0 }
                            if ($Number -ge 1 -and $Number -le $Tenants.Count) { $TargetTenant = $Tenants[$Number - 1] }
                            else { Write-Log -Message ("'{0}' is not a number from 1 to {1}." -f $Answer, $Tenants.Count) -Severity 'Warning' }
                        }
                        if (!$TargetTenant)
                        {
                            Stop-SignIn -Message 'No tenant was chosen; stopping.' -Advice 'Re-run with -TenantID <tenant> to choose the tenant directly.'
                        }
                    }
                }

                # Point Az PowerShell at the chosen tenant (no new sign-in); this
                # process only, so the user's saved context is left alone.
                if ((Get-AzPsSignedInTenant) -ne $TargetTenant)
                {
                    Set-AzContext -Tenant $TargetTenant -Scope Process | Out-Null
                }

                $Advice = Get-UserSignInAdvice -Tenant $TargetTenant
                if (!(Test-AzPsTokenSilent -Tenant $TargetTenant)) { Stop-UnusableSignIn -Tenant $TargetTenant -Advice $Advice }
                $TargetTenant = Confirm-AzPsContextTenant -Tenant $TargetTenant -Advice $Advice

                Write-Log -Message ("Extracting from Tenant $TargetTenant") -Severity 'Info'
                Write-Log -Message ("Extracting Subscriptions") -Severity 'Info'

                Set-RdaRunSubscriptions -Tenant $TargetTenant
                return
            }

            $Reused = $false
            if ($PsTokenOk -and $PsTenant -eq $TargetTenant)
            {
                Write-Log -Message ("Az PowerShell: reusing existing sign-in for tenant {0}" -f $TargetTenant) -Severity 'Success'
                $Reused = $true
            }
            elseif ($PsTenant -and $PsTenant -ne $TargetTenant -and (Test-AzPsTokenSilent -Tenant $TargetTenant))
            {
                # The cached account reaches the target tenant without a
                # prompt: switch this process to it instead of signing in.
                Write-Log -Message ("Az PowerShell: signed in to tenant {0}; switching this process to {1} with the same sign-in." -f $PsTenant, $TargetTenant) -Severity 'Info'
                Set-AzContext -Tenant $TargetTenant -Scope Process | Out-Null
                $Reused = Test-AzPsContextOnTenant -Tenant $TargetTenant
            }

            if (-not $Reused)
            {
                if ($null -eq $PsTenant) { Write-Log -Message ('Az PowerShell: not signed in; signing in.') -Severity 'Info' }
                elseif ($PsTenant -ne $TargetTenant) { Write-Log -Message ("Az PowerShell: signed in to tenant {0}; signing in to {1}." -f $PsTenant, $TargetTenant) -Severity 'Warning' }
                else { Write-Log -Message ("Az PowerShell: session for tenant {0} cannot acquire a token silently; signing in again." -f $TargetTenant) -Severity 'Warning' }

                Invoke-AzPsUserSignIn -Tenant $TargetTenant

                if (!(Test-AzPsTokenSilent -Tenant $TargetTenant))
                {
                    Stop-UnusableSignIn -Tenant $TargetTenant -Advice (Get-UserSignInAdvice -Tenant $TargetTenant)
                }
            }

            Set-RdaRunSubscriptions -Tenant (Confirm-AzPsContextTenant -Tenant $TargetTenant -Advice (Get-UserSignInAdvice -Tenant $TargetTenant))
            return
        }

        # -RunAllSubs: Run-AllSubscriptions.ps1 has already signed Az
        # PowerShell in to -TenantID before it starts this script, so that
        # sign-in is used as it is: no sign-in here.
        $Context = try { Get-AzContext -ErrorAction Stop } catch { $null }
        $ContextTenant = if ($null -ne $Context -and $null -ne $Context.Account) { [string]$Context.Tenant.Id } else { $null }
        if ($ContextTenant -and -not $Global:RdaSessionInitialized)
        {
            Write-Log -Message ("Already authenticated as: {0}" -f $Context.Account.Id) -Severity 'Success'
        }

        $TargetTenant = if ($TenantID) { $TenantID } else { $ContextTenant }
        if ($TargetTenant -and $ContextTenant -and $ContextTenant -ne $TargetTenant)
        {
            Write-Log -Message ("Current session is for tenant {0}, but requested tenant is {1}. Switching this process to it." -f $ContextTenant, $TargetTenant) -Severity 'Warning'
            Set-AzContext -Tenant $TargetTenant -Scope Process | Out-Null
        }

        if (!$TargetTenant)
        {
            Write-Log -Message ('Tenant ID not specified. Use -TenantID parameter if you want to specify directly.') -Severity 'Warning'
            $Tenants = @((Get-AzSubscription -WarningAction SilentlyContinue).HomeTenantId | Where-Object { $_ } | Sort-Object -Unique)
            if ($Tenants.Count -gt 0)
            {
                $TargetTenant = $Tenants[0]
                if ($Tenants.Count -gt 1) { Write-Log -Message ("Non-interactive session with multiple tenants and no -TenantID: defaulting to the first tenant ({0}). Pass -TenantID to choose explicitly." -f $TargetTenant) -Severity 'Warning' }
                Write-Log -Message ("Extracting from Tenant $TargetTenant") -Severity 'Info'
            }
        }

        if (!$TargetTenant)
        {
            $Global:Subscriptions = @()
            return
        }

        # The wrapper starts this script once per subscription in the same
        # process; the tenant's subscription list is read once.
        $Cache = $Global:RdaTenantSubscriptionCache
        if ($null -ne $Cache -and $Cache.Tenant -eq $TargetTenant)
        {
            $Global:Subscriptions = @($Cache.Subscriptions)
            return
        }
        $Global:Subscriptions = @(Get-RdaTenantSubscriptions -Tenant $TargetTenant)
        if ($Global:Subscriptions.Count -gt 0)
        {
            $Global:RdaTenantSubscriptionCache = @{ Tenant = $TargetTenant; Subscriptions = @($Global:Subscriptions) }
        }
    }

    function GetSubscriptionsData()
    {
        $SubscriptionCount = $Subscriptions.Count

        if (-not $Global:RdaSessionInitialized)
        {
            Write-Log -Message ("Number of Subscriptions Found: {0}" -f $SubscriptionCount) -Severity 'Info'
        }

        Write-Log -Message ("Checking report folder: {0}" -f $DefaultPath) -Severity 'Info'

        if ((Test-Path -Path $DefaultPath -PathType Container) -eq $false)
        {
            New-Item -Type Directory -Force -Path $DefaultPath | Out-Null
        }

        $Global:RdaSessionInitialized = $true
    }

    # Every resource discovery query goes through here. Invoke-AzGraphQuerySafe
    # throws when a Resource Graph call still fails after its retries or returns
    # output that cannot be parsed. Unless -Debug is passed this script runs with
    # ErrorActionPreference SilentlyContinue, and under that preference a throw
    # that nothing catches does not stop the run: a direct run would leave the
    # page out of the inventory with no error, or retry a lasting failure without
    # end. A direct run stops here with exit 1 before any report is written.
    # Under -RunAllSubs the error is passed on, so Run-AllSubscriptions.ps1
    # records the subscription as failed with this reason and -ResumeFailedOnly
    # retries it; the other subscriptions carry on.
    function Invoke-DiscoveryGraphQuery
    {
        param(
            [Parameter(Mandatory = $true)][string]$Query,
            [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$SubscriptionId,
            [switch]$Lowercase,
            [switch]$HideRawOutput
        )

        try
        {
            return (Invoke-AzGraphQuerySafe -Query $Query -SubscriptionId $SubscriptionId -Lowercase:$Lowercase -HideRawOutput:$HideRawOutput)
        }
        catch
        {
            if ($RunAllSubs.IsPresent) { throw }

            Write-Log -Message ("Resource discovery failed, so the inventory would be incomplete. No report was written; fix the cause below and re-run. {0}" -f $_.Exception.Message) -Severity 'Error'
            exit 1
        }
    }

    # The resources are sorted by their id in lower case. Resource Graph sorts
    # text by its exact characters, upper case first, and the case of the
    # resource group in an id can change between two reads of the same resource
    # (a virtual machine that is starting or stopping switches several times).
    # Sorted by the id as returned, such a resource moves between pages while
    # they are read: it is listed twice or not at all, and the resource at a
    # page edge is lost or listed twice with it.
    function ResourceInventoryLoop()
    {
        if (![string]::IsNullOrEmpty($ResourceGroup))
        {
            # Invariant rules: on a tr-TR or az-Latn host ToLower() turns 'I'
            # into a dotless i, and the query then matches no resource group.
            $ResourceGroup = $ResourceGroup.ToLowerInvariant()
        }

        if (![string]::IsNullOrEmpty($ResourceGroup) -and ![string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ('Extracting Resources from Subscription: ' + $SubscriptionID + '. And from Resource Group: ' + $ResourceGroup) -Severity 'Success'

            $Subscri = $SubscriptionID

            $GraphQuery = "resources | where resourceGroup == '$ResourceGroup' and (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = Invoke-DiscoveryGraphQuery -Query $GraphQuery -SubscriptionId @($Subscri) -HideRawOutput:$Obfuscate.IsPresent
            $EnvSizeNum = Get-AzGraphCount -Result $EnvSize

            if ($EnvSizeNum -ge 1)
            {
                # Every page, read with the skip token.
                $GraphQuery = "resources | where resourceGroup == '$ResourceGroup' and (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by tolower(id) asc"
                $Resource = Invoke-DiscoveryGraphQuery -Query $GraphQuery -SubscriptionId @($Subscri) -Lowercase -HideRawOutput:$Obfuscate.IsPresent

                $Global:Resources += $Resource.data
            }
        }
        elseif ([string]::IsNullOrEmpty($ResourceGroup) -and ![string]::IsNullOrEmpty($SubscriptionID))
        {
            Write-Log -Message ('Extracting Resources from Subscription: ' + $SubscriptionID) -Severity 'Success'

            $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = Invoke-DiscoveryGraphQuery -Query $GraphQuery -SubscriptionId @($SubscriptionID) -HideRawOutput:$Obfuscate.IsPresent
            $EnvSizeNum = Get-AzGraphCount -Result $EnvSize

            if ($EnvSizeNum -ge 1)
            {
                # Every page, read with the skip token.
                $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by tolower(id) asc"
                $Resource = Invoke-DiscoveryGraphQuery -Query $GraphQuery -SubscriptionId @($SubscriptionID) -Lowercase -HideRawOutput:$Obfuscate.IsPresent

                $Global:Resources += $Resource.data
            }
        }
        else
        {
            # Every subscription of the run, named explicitly (in batches of
            # 1000), rather than whatever scope Resource Graph defaults to.
            $RunSubscriptionIds = @($Global:Subscriptions | ForEach-Object { [string]$_.id })
            $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | summarize count()"
            $EnvSize = Invoke-DiscoveryGraphQuery -Query $GraphQuery -SubscriptionId $RunSubscriptionIds -HideRawOutput:$Obfuscate.IsPresent
            $EnvSizeCount = Get-AzGraphCount -Result $EnvSize

            Write-Log -Message ("Resources Output: {0} Resources Identified" -f $EnvSizeCount) -Severity 'Success'

            if ($EnvSizeCount -ge 1)
            {
                # Every page, read with the skip token.
                $GraphQuery = "resources | where (isnull(properties.definition.actions) or strlen(properties.definition.actions) < 123000) | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by tolower(id) asc"
                $Resource = Invoke-DiscoveryGraphQuery -Query $GraphQuery -SubscriptionId $RunSubscriptionIds -Lowercase -HideRawOutput:$Obfuscate.IsPresent

                $Global:Resources += $Resource.Data
            }
        }
    }

    function ResourceInventoryAvd()
    {
        # The subscriptions ResourceInventoryLoop reads: -SubscriptionID alone
        # when it is given, else every subscription of the run, named explicitly
        # (in batches of 1000). Session hosts of other subscriptions never match
        # this run's host pools, and the wrapper runs one -SubscriptionID run per
        # subscription, so reading them put their real ids in every run's
        # dictionary, each run with its own tokens, and counted them as the
        # run's own resources.
        $RunSubscriptionIds = if (![string]::IsNullOrEmpty($SubscriptionID)) { @([string]$SubscriptionID) } else { @($Global:Subscriptions | ForEach-Object { [string]$_.id }) }
        # A -ResourceGroup run reads that group only, for the same reason. =~
        # matches without regard to case: only the resources table is known to
        # keep resourceGroup in lower case, other tables may keep the portal's.
        # Lower-cased without the host's culture: on a Turkish host ToLower()
        # turns I into a dotless i, which matches no group.
        $AVDGroupFilter = if (![string]::IsNullOrEmpty($ResourceGroup)) { " | where resourceGroup =~ '{0}'" -f $ResourceGroup.ToLowerInvariant() } else { '' }
        $AVDSize = Invoke-DiscoveryGraphQuery -Query ("desktopvirtualizationresources{0} | summarize count()" -f $AVDGroupFilter) -SubscriptionId $RunSubscriptionIds -HideRawOutput:$Obfuscate.IsPresent
        $AVDSizeCount = Get-AzGraphCount -Result $AVDSize

        Write-Host ("AVD Resources Output: {0} AVD Resources Identified" -f $AVDSizeCount) -BackgroundColor Black -ForegroundColor Green

        if ($AVDSizeCount -ge 1)
        {
            # Every page, read with the skip token, sorted by the id in lower
            # case for the reason given above ResourceInventoryLoop.
            $GraphQuery = "desktopvirtualizationresources$AVDGroupFilter | project id,name,type,tenantId,kind,location,resourceGroup,subscriptionId,managedBy,sku,plan,properties,identity,zones,extendedLocation,tags | order by tolower(id) asc"
            $AVD = Invoke-DiscoveryGraphQuery -Query $GraphQuery -SubscriptionId $RunSubscriptionIds -Lowercase -HideRawOutput:$Obfuscate.IsPresent

            $Global:Resources += $AVD.data
        }
    }

    CheckVersion
    CheckCliRequirements
    CheckPowerShell
    GetSubscriptionsData

    # One consumption window per run, used by the up-front consumption data
    # check below and by the consumption phase (GetResorceConsumption), so a
    # run that crosses midnight still collects the window it checked. Under
    # -RunAllSubs the wrapper passes the window its own check used.
    $script:ConsumptionWindow = ConvertFrom-ConsumptionWindowArgument -Start $ConsumptionWindowStart -End $ConsumptionWindowEnd
    if ($null -eq $script:ConsumptionWindow)
    {
        if (-not [string]::IsNullOrEmpty($ConsumptionWindowStart) -or -not [string]::IsNullOrEmpty($ConsumptionWindowEnd))
        {
            Write-Log -Message ("Ignoring -ConsumptionWindowStart '{0}' / -ConsumptionWindowEnd '{1}': both must be yyyy-MM-dd dates, start not after end. Using this run's own consumption window." -f $ConsumptionWindowStart, $ConsumptionWindowEnd) -Severity 'Warning'
        }
        $script:ConsumptionWindow = Get-ConsumptionWindow
    }

    # Direct runs check two things up front, before any inventory, collector or
    # metrics work (both in Functions/Common.Functions.ps1). Under -RunAllSubs
    # the wrapper has already checked every subscription, so neither is repeated.
    #
    # 1. The identity's roles, with or without -SkipConsumption
    #    (Test-SubscriptionRoleAccessAll). Resource Graph returns 0 rows rather
    #    than an error for a subscription the identity cannot read, so without
    #    this check such a run is exempted from the consumption check
    #    (0 resources) and finishes with an empty report. With -ResourceGroup
    #    the read verdict is for that resource group, because Reader on only
    #    that resource group is enough for such a run. -ResourceGroup without
    #    -SubscriptionID is refused by ResourceInventoryLoop, so it is not
    #    checked here. When consumption is requested the usage permission is
    #    printed too, for information. A subscription that is not readable is
    #    skipped: listed with the reason right after the check and again at
    #    the end of the run, left out of the consumption check, and its
    #    resources are left out of the inventory. When none is readable (for
    #    example the one -SubscriptionID names) the run stops with exit 1, and
    #    so does a run over every visible subscription that sees none.
    # 2. Consumption: unless -SkipConsumption, every in-scope subscription must
    #    return usage values (Invoke-ConsumptionDataCheck) for the run's
    #    window. With -ResourceGroup only that resource group's usage rows
    #    count, the rows the consumption phase keeps for such a run. The role
    #    check records are passed in: a subscription with no usage above zero
    #    passes with a warning (NoUsage, listed again at the end of the run)
    #    only when both role-check answers grant the usage permission at the
    #    subscription or above. On a refusal the role check's usage verdict is
    #    printed with the fix.
    if (-not $RunAllSubs.IsPresent)
    {
        $AccessProbed = @()
        $ConsumptionCheckScope = if (![string]::IsNullOrEmpty($SubscriptionID))
        {
            $Match = @($Global:Subscriptions | Where-Object { $_.id -eq $SubscriptionID })
            if ($Match.Count -gt 0) { $Match } else { @([pscustomobject]@{ Id = $SubscriptionID; Name = $SubscriptionID }) }
        }
        else
        {
            @($Global:Subscriptions)
        }

        if (@($ConsumptionCheckScope).Count -eq 0 -and [string]::IsNullOrEmpty($ResourceGroup))
        {
            # No subscription in scope: Resource Graph would return no rows and the run would
            # end with an empty report, so stop as for no readable subscription.
            Write-Host '  No subscription is visible to the signed-in identity. Stopping before any work. Sign in with an identity that has Reader on a subscription of this tenant, then re-run.' -ForegroundColor Red
            exit 1
        }

        if (@($ConsumptionCheckScope).Count -gt 0 -and ([string]::IsNullOrEmpty($ResourceGroup) -or ![string]::IsNullOrEmpty($SubscriptionID)))
        {
            if ([string]::IsNullOrEmpty($ResourceGroup))
            {
                Write-Host ("Verifying subscription access up front for {0} subscription(s)..." -f @($ConsumptionCheckScope).Count) -ForegroundColor Cyan
            }
            else
            {
                Write-Host ("Verifying access to resource group '{0}' up front..." -f $ResourceGroup) -ForegroundColor Cyan
            }
            $AccessProbed = @(Test-SubscriptionRoleAccessAll -Subscriptions $ConsumptionCheckScope -ResourceGroup $ResourceGroup -IncludeUsage:(-not $SkipConsumption.IsPresent))
            $AccessDecision = Resolve-AccessPreflight -Probed $AccessProbed
            Write-AccessPreflightReport -Decision $AccessDecision -ScopeCount @($ConsumptionCheckScope).Count -ResourceGroup $ResourceGroup
            if ($AccessDecision.ShouldBlock)
            {
                exit 1
            }
            if ($AccessDecision.Inaccessible.Count -gt 0)
            {
                $script:AccessSkipped = $AccessDecision
                $ConsumptionCheckScope = @($ConsumptionCheckScope | Where-Object { $AccessDecision.InaccessibleIds -notcontains [string]$_.Id })
                $Global:Subscriptions = @($Global:Subscriptions | Where-Object { $AccessDecision.InaccessibleIds -notcontains [string]$_.Id })
            }
        }

        if (-not $SkipConsumption.IsPresent)
        {
            $ConsumptionCheck = Invoke-ConsumptionDataCheck -Subscriptions $ConsumptionCheckScope -RoleCheck $AccessProbed -Window $script:ConsumptionWindow -ResourceGroup $ResourceGroup
            Write-ConsumptionDataCheckReport -Result $ConsumptionCheck
            Write-UsageRoleReport -ConsumptionResult $ConsumptionCheck -RoleCheck $AccessProbed
            if ($ConsumptionCheck.ShouldBlock)
            {
                exit 1
            }
            $script:ConsumptionCheckResult = $ConsumptionCheck
        }
    }

    ResourceInventoryLoop
    ResourceInventoryAvd

    # A run over every visible subscription queries Resource Graph tenant-wide,
    # which also returns whatever a skipped subscription's identity can partly
    # read; leave those resources out, so a skipped subscription is not half
    # reported.
    if ($null -ne $script:AccessSkipped)
    {
        $Global:Resources = @($Global:Resources | Where-Object { $script:AccessSkipped.InaccessibleIds -notcontains [string]$_.subscriptionId })
    }

    $Global:ResourceCount = @($Global:Resources).Count

    if ($Obfuscate.IsPresent)
    {
        $SubLookup = $Global:ObfuscationSubscriptionTokens
        $RgLookup = $Global:ObfuscationResourceGroupTokens
        # Ids are built once every resource has its name token, so a child's id
        # can use its parent's token (Get-ObfuscatedResourceId).
        $IdsToMask = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        if (-not [string]::IsNullOrEmpty($ObfuscationDictionary))
        {
            $SeedDictionary = Get-Content -Path $ObfuscationDictionary -Raw | ConvertFrom-Json

            if ($null -ne $SeedDictionary.ResourceIdMap)
            {
                # Ids are looked up ignoring case, so two seeded entries for one
                # real id in two casings (an older build's dictionary) become
                # one: say so now, before a recovery merge meets it.
                $SeedCaseTwice = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($SeedProp in $SeedDictionary.ResourceIdMap.PSObject.Properties)
                {
                    if ($ResourceIdDictionary.ContainsKey($SeedProp.Value) -and $ResourceIdDictionary[$SeedProp.Value] -cne $SeedProp.Name)
                    {
                        [void]$SeedCaseTwice.Add([string]$SeedProp.Value)
                        # Of two casings, keep one of the right shape if there is one.
                        if ((Test-ObfuscatedIdShape -RealId $SeedProp.Value -MaskedId $ResourceIdDictionary[$SeedProp.Value]) -and -not (Test-ObfuscatedIdShape -RealId $SeedProp.Value -MaskedId $SeedProp.Name)) { continue }
                    }
                    $ResourceIdDictionary[$SeedProp.Value] = $SeedProp.Name
                }
                if ($SeedCaseTwice.Count -gt 0)
                {
                    Write-Log -Message ("Obfuscation dictionary: it gives {0} resource(s) two masked ids by case (an older build's file); only one can be kept for each. A recovery merge (Merge-RecoveryData) of a later bundle with this run's could then give such a resource two ids: collect the gap bundle on this build, then run the recovery with that bundle's ObfuscationDictionary_*.json." -f $SeedCaseTwice.Count) -Severity 'Warning'
                }
            }
            if ($null -ne $SeedDictionary.ResourceNameMap)
            {
                foreach ($SeedProp in $SeedDictionary.ResourceNameMap.PSObject.Properties) { $ResourceNameDictionary[$SeedProp.Value] = $SeedProp.Name }
            }
            if ($null -ne $SeedDictionary.TagMap)
            {
                foreach ($SeedProp in $SeedDictionary.TagMap.PSObject.Properties) { $Global:TagValueDictionary[$SeedProp.Value] = $SeedProp.Name }
            }
            if ($null -ne $SeedDictionary.FreeTextMap)
            {
                foreach ($SeedProp in $SeedDictionary.FreeTextMap.PSObject.Properties) { $Global:FreeTextDictionary[$SeedProp.Value] = $SeedProp.Name }
            }
            # The seed's SubscriptionNameMap (token -> display name) is not read
            # for tokens: a display name can belong to two subscriptions, or to
            # another one after a rename. A subscription's token comes from the
            # seeded ids of that subscription id (the seed check below); one
            # with no seeded id gets a new token, and has no seeded id to join.
            if ($null -ne $SeedDictionary.ResourceGroupMap)
            {
                foreach ($SeedProp in $SeedDictionary.ResourceGroupMap.PSObject.Properties)
                {
                    if ($SeedProp.Value -match '(?i)/resourcegroups/([^/]+)') { $RgLookup[$Matches[1]] = $SeedProp.Name }
                }
            }

            Write-Log -Message ("Obfuscation dictionary seeded from '{0}': {1} id, {2} name, {3} resource-group, {4} tag, {5} free-text mappings preloaded; matching real values will reuse their existing tokens (subscription tokens come from the seeded ids, checked below)." -f $ObfuscationDictionary, @($ResourceIdDictionary.Keys).Count, @($ResourceNameDictionary.Keys).Count, @($RgLookup.Keys).Count, @($Global:TagValueDictionary.Keys).Count, @($Global:FreeTextDictionary.Keys).Count) -Severity 'Info'
            # The parsed seed file is not needed past here: free it before the
            # token loop (a recovery run's seed can hold every id of a tenant).
            $SeedDictionary = $null
            $SeedProp = $null
        }

        $SubIndex = Get-ObfuscationSubscriptionIndex

        # The seed's ids, checked once here, so every place that reuses a
        # seeded id (the token loop, the collector rows, consumption, metrics)
        # and the dictionary file this run writes see only good ones:
        # - an id of another shape (Test-ObfuscatedIdShape: an older
        #   dictionary's child id with a real parent name, a flat token, the
        #   metric step's old sub_/rg_ tokens) is dropped, and masked again
        #   wherever this run meets its resource;
        # - every token slot of the good ids (the subscription, the resource
        #   group, each parent and the resource's own name) wins over the
        #   seed's maps, so seeded and new rows share one token per
        #   subscription, group and parent;
        # - a subscription, group or parent that the good ids give two tokens
        #   (a seed written before this check) has every id that holds it
        #   dropped, and gets one new token. The dictionary this run writes is
        #   then consistent, so the next seeded run keeps every id: no repeat;
        # - a token that the seed gives two real subscriptions, groups or
        #   resources (in any slots) is the same: kept for none, every id
        #   holding it dropped. A SQL VM and its VM count as one resource.
        if (-not [string]::IsNullOrEmpty($ObfuscationDictionary))
        {
            # The seed's maps first: a group or name token that is not of its
            # slot's form (the metric step's old rg_ tokens, say) is not kept,
            # so no id is built from it again. (Subscription tokens come only
            # from good seeded ids, checked below.)
            $SeedGuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
            foreach ($K in @($RgLookup.Keys)) { if ([string]$RgLookup[$K] -cnotmatch ('^(prod|nonprod)_(mc_)?' + $SeedGuid + '$')) { [void]$RgLookup.Remove($K) } }
            foreach ($K in @($ResourceNameDictionary.Keys)) { if ([string]$ResourceNameDictionary[$K] -cnotmatch ('^(prod|nonprod)_(databricks_|aks_|vmss_)?' + $SeedGuid + '$')) { [void]$ResourceNameDictionary.Remove($K) } }
            $SeedSlotTokens = @{}
            $SeedSlotsOf = @{}
            $SeedSubTokenIds = @{}
            # Each token stands for one real subscription, group or resource:
            # token -> the '<kind>|<real>' values it is given, from the seed's
            # maps and the good ids' slots. A token given to two (a hand-merged
            # seed, or one token in a subscription and a group slot) would give
            # two resources one masked id. A SQL VM's id is its VM's id with
            # the provider swapped, and the two share one name token on
            # purpose, so a SQL VM path counts as its VM's path here.
            # (Inline, not a helper: this runs once per slot of every seeded id.)
            $SeedTokenReals = @{}
            foreach ($K in @($RgLookup.Keys))
            {
                $T = [string]$RgLookup[$K]
                if (-not $SeedTokenReals.ContainsKey($T)) { $SeedTokenReals[$T] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
                [void]$SeedTokenReals[$T].Add('rg|' + [string]$K)
            }
            foreach ($K in @($ResourceNameDictionary.Keys))
            {
                $T = [string]$ResourceNameDictionary[$K]
                if (-not $SeedTokenReals.ContainsKey($T)) { $SeedTokenReals[$T] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
                [void]$SeedTokenReals[$T].Add('name|' + ([string]$K -replace '(?i)/providers/microsoft\.sqlvirtualmachine/sqlvirtualmachines/', '/providers/microsoft.compute/virtualmachines/'))
            }
            $SeedDropped = 0
            foreach ($SeedRealId in @($ResourceIdDictionary.Keys))
            {
                $SeedMasked = $ResourceIdDictionary[$SeedRealId]
                # A real id that is not an ARM path has one flat token (not
                # changed here); a seeded flat token of that form is kept as
                # it is, so it stays the same across seeded runs. Any other
                # value (empty, plain text) is not kept.
                if ($SeedRealId -notmatch '(?i)^/subscriptions/[^/]' -and -not (Test-RdaTenantScopeIdMaskable -ResourceId $SeedRealId))
                {
                    if ([string]$SeedMasked -cnotmatch ('^(prod|nonprod)_' + $SeedGuid + '$'))
                    {
                        [void]$ResourceIdDictionary.Remove($SeedRealId)
                        $SeedDropped++
                    }
                    continue
                }
                if (-not (Test-ObfuscatedIdShape -RealId $SeedRealId -MaskedId $SeedMasked))
                {
                    [void]$ResourceIdDictionary.Remove($SeedRealId)
                    $SeedDropped++
                    continue
                }
                # The id's token slots: kind, the real value the token stands
                # for (subscription name, group name, or the real id up to
                # that name, as Get-ObfuscatedResourceId keys it) and token.
                $RealParts = $SeedRealId.Split('/')
                $MaskedParts = $SeedMasked.Split('/')
                $Slots = [System.Collections.Generic.List[object]]::new()
                if ($RealParts[1] -ieq 'subscriptions')
                {
                    # Keyed by subscription id, as Get-ObfuscatedResourceId keys it.
                    $Slots.Add([pscustomobject]@{ Kind = 'sub'; Real = $RealParts[2]; Token = $MaskedParts[2] })
                    $i = 3
                }
                else { $i = 1 }
                while ($i + 1 -lt $RealParts.Count)
                {
                    $Next = $RealParts[$i + 1]
                    if ($i -eq 3 -and $RealParts[1] -ieq 'subscriptions' -and $RealParts[$i] -ieq 'resourcegroups') { $Slots.Add([pscustomobject]@{ Kind = 'rg'; Real = $Next; Token = $MaskedParts[$i + 1] }) }
                    elseif (-not ($RealParts[$i] -ieq 'providers' -or [string]::IsNullOrEmpty($Next) -or $Next -eq '$system')) { $Slots.Add([pscustomobject]@{ Kind = 'name'; Real = ($RealParts[0..($i + 1)] -join '/'); Token = $MaskedParts[$i + 1] }) }
                    $i += 2
                }
                $SeedSlotsOf[$SeedRealId] = $Slots
                foreach ($Slot in $Slots)
                {
                    $SlotKey = $Slot.Kind + '|' + $Slot.Real.ToLowerInvariant()
                    if (-not $SeedSlotTokens.ContainsKey($SlotKey)) { $SeedSlotTokens[$SlotKey] = @{} }
                    $SeedSlotTokens[$SlotKey][$Slot.Token] = $true
                    $T = [string]$Slot.Token
                    if (-not $SeedTokenReals.ContainsKey($T)) { $SeedTokenReals[$T] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
                    $SlotReal = if ($Slot.Kind -eq 'name') { [string]$Slot.Real -replace '(?i)/providers/microsoft\.sqlvirtualmachine/sqlvirtualmachines/', '/providers/microsoft.compute/virtualmachines/' } else { [string]$Slot.Real }
                    [void]$SeedTokenReals[$T].Add($Slot.Kind + '|' + $SlotReal)
                    # A subscription token is one subscription's: a seed from
                    # before tokens were keyed by id can give two subscriptions
                    # with one display name the same token.
                    if ($Slot.Kind -eq 'sub')
                    {
                        if (-not $SeedSubTokenIds.ContainsKey($Slot.Token)) { $SeedSubTokenIds[$Slot.Token] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
                        [void]$SeedSubTokenIds[$Slot.Token].Add($Slot.Real)
                    }
                }
            }
            foreach ($SeedRealId in @($SeedSlotsOf.Keys))
            {
                $Conflict = $false
                foreach ($Slot in $SeedSlotsOf[$SeedRealId])
                {
                    if ($SeedSlotTokens[$Slot.Kind + '|' + $Slot.Real.ToLowerInvariant()].Count -gt 1) { $Conflict = $true; break }
                    if ($Slot.Kind -eq 'sub' -and $SeedSubTokenIds[$Slot.Token].Count -gt 1) { $Conflict = $true; break }
                    if ($SeedTokenReals[[string]$Slot.Token].Count -gt 1) { $Conflict = $true; break }
                }
                if ($Conflict)
                {
                    [void]$ResourceIdDictionary.Remove($SeedRealId)
                    $SeedDropped++
                    continue
                }
                foreach ($Slot in $SeedSlotsOf[$SeedRealId])
                {
                    switch ($Slot.Kind)
                    {
                        # The id's own subscription and group entries too, so a
                        # row or metric that reuses this seeded id outside the
                        # token loop gets the fields of its own path.
                        'sub' { $SubLookup[$Slot.Real] = $Slot.Token; $ResourceSubscriptionDictionary[$SeedRealId] = $Slot.Token }
                        'rg' { $RgLookup[$Slot.Real] = $Slot.Token; $ResourceResourceGroupDictionary[$SeedRealId] = $Slot.Token }
                        'name' { $ResourceNameDictionary[$Slot.Real] = $Slot.Token }
                    }
                }
            }
            # A slot with two tokens starts again with no token at all.
            foreach ($SlotKey in @($SeedSlotTokens.Keys))
            {
                if ($SeedSlotTokens[$SlotKey].Count -le 1) { continue }
                $Kind, $Real = $SlotKey.Split('|', 2)
                switch ($Kind)
                {
                    'rg' { foreach ($K in @($RgLookup.Keys)) { if ($K -ieq $Real) { [void]$RgLookup.Remove($K) } } }
                    'name' { [void]$ResourceNameDictionary.Remove($Real) }
                }
            }
            # A token given to two reals is kept for none of them.
            $SharedTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($T in @($SeedTokenReals.Keys)) { if ($SeedTokenReals[$T].Count -gt 1) { [void]$SharedTokens.Add($T) } }
            if ($SharedTokens.Count -gt 0)
            {
                foreach ($K in @($RgLookup.Keys)) { if ($SharedTokens.Contains([string]$RgLookup[$K])) { [void]$RgLookup.Remove($K) } }
                foreach ($K in @($ResourceNameDictionary.Keys)) { if ($SharedTokens.Contains([string]$ResourceNameDictionary[$K])) { [void]$ResourceNameDictionary.Remove($K) } }
            }
            Write-Log -Message ("Obfuscation dictionary: {0} subscription token(s) kept from the seeded ids." -f @($SubLookup.Keys).Count) -Severity 'Info'
            if ($SeedDropped -gt 0)
            {
                Write-Log -Message ("Obfuscation dictionary: {0} seeded id(s) of another shape, or holding a subscription, resource group or parent with two tokens, or a token two subscriptions, groups or resources share, were not kept; their resources get new masked ids this run." -f $SeedDropped) -Severity 'Warning'
            }
            # The slot index is only for this check: free it before the token loop.
            $SeedSlotsOf = $null
            $SeedSlotTokens = $null
            $SeedSubTokenIds = $null
            $SeedTokenReals = $null
            $SharedTokens = $null
        }

        foreach ($resourceItem in $Global:Resources)
        {
            if ($IdsToMask.Contains($resourceItem.ID)) { continue }

            # The token New-ObfuscatedNameToken writes, built inline because this loop
            # runs once per resource.
            $TokenId = [string]$resourceItem.id
            $TokenName = [string]$resourceItem.name
            $Hint = if ($TokenId -match 'databricks') { 'databricks_' } elseif ($TokenId -match '/resourcegroups/mc_') { 'aks_' } elseif ($TokenId -match 'virtualmachinescalesets') { 'vmss_' } else { '' }
            $Prefix = if ($TokenName -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $TokenName -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
            $ObfuscatedName = $Prefix + $Hint + [guid]::NewGuid().ToString()

            # The subscription is read from the id's own /subscriptions/<id>/
            # segment first, as Get-ObfuscatedResourceId reads it, so the row's
            # field matches its id; then from subscriptionId.
            $SubIdOfRow = if ([string]$resourceItem.id -match '(?i)^/subscriptions/([^/]+)') { $Matches[1] } elseif (-not [string]::IsNullOrEmpty([string]$resourceItem.subscriptionId)) { [string]$resourceItem.subscriptionId } else { $null }
            $SubEntries = if ($null -eq $SubIdOfRow) { if ($null -eq $resourceItem.subscriptionId) { $SubIndex.NoId } else { $null } } else { $SubIndex.ById[$SubIdOfRow] }
            # The first entry's name, as Get-ObfuscatedResourceId reads it: a
            # subscription listed twice would give an array here otherwise.
            # (A plain loop: this runs once per resource.)
            $RealSub = ''
            foreach ($SubEntry in @($SubEntries)) { if ($null -ne $SubEntry) { $RealSub = [string]$SubEntry.Name; break } }
            if ([string]::IsNullOrEmpty($RealSub)) { $RealSub = if ($null -ne $SubIdOfRow) { $SubIdOfRow } else { [string]$resourceItem.subscriptionId } }
            # The token is keyed by subscription id, as Get-ObfuscatedResourceId
            # keys it; the prefix comes from the display name.
            $SubKey = if ($null -ne $SubIdOfRow) { $SubIdOfRow } elseif (-not [string]::IsNullOrEmpty($RealSub)) { $RealSub } else { '~nosub' }
            if (-not $SubLookup.ContainsKey($SubKey))
            {
                $SubPrefix = if ($RealSub -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealSub -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                $SubLookup[$SubKey] = $SubPrefix + [guid]::NewGuid().ToString()
            }
            $ObfuscatedSubscription = $SubLookup[$SubKey]

            $RealRG = $resourceItem.resourceGroup
            if ([string]::IsNullOrEmpty($RealRG)) { $RealRG = '__none__' }
            if (-not $RgLookup.ContainsKey($RealRG))
            {
                $RgPrefix = if ($RealRG -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealRG -match '(^|-)([dts])-') { "nonprod_" } else { "prod_" }
                $RgLookup[$RealRG] = $RgPrefix + [guid]::NewGuid().ToString()
            }
            $ObfuscatedResourceGroup = $RgLookup[$RealRG]

            # A seeded id is kept when it has the right shape, or when the real
            # id is not an ARM path and the seed check kept its flat token.
            $SeedKept = $false
            if ($ResourceIdDictionary.ContainsKey($resourceItem.ID))
            {
                $SeedKept = (Test-ObfuscatedIdShape -RealId $resourceItem.ID -MaskedId $ResourceIdDictionary[$resourceItem.ID]) -or ([string]$resourceItem.ID -notmatch '(?i)^/subscriptions/[^/]' -and -not (Test-RdaTenantScopeIdMaskable -ResourceId $resourceItem.ID))
            }
            if ($SeedKept)
            {
                # A seeded id (-ObfuscationDictionary): the seed gives its
                # masked id but no subscription or resource group entry, so
                # reading those dictionaries gave empty values and every row
                # then got random tokens. The name, subscription and resource
                # group tokens are the seeded path's own segments, so the
                # row's fields always equal its id.
                $ObfuscatedID = $ResourceIdDictionary[$resourceItem.ID]
                $SeedParts = ([string]$ObfuscatedID).Split('/')
                if ($SeedParts.Count -ge 3 -and $SeedParts[1] -ieq 'subscriptions' -and -not [string]::IsNullOrEmpty($SeedParts[2])) { $ObfuscatedSubscription = $SeedParts[2] }
                if ($SeedParts.Count -ge 5 -and $SeedParts[3] -ieq 'resourcegroups' -and -not [string]::IsNullOrEmpty($SeedParts[4])) { $ObfuscatedResourceGroup = $SeedParts[4] }
                if ($SeedParts.Count -ge 2 -and -not [string]::IsNullOrEmpty($SeedParts[-1])) { $ObfuscatedName = $SeedParts[-1] }
                elseif ($ResourceNameDictionary.ContainsKey($resourceItem.ID) -and -not [string]::IsNullOrEmpty($ResourceNameDictionary[$resourceItem.ID])) { $ObfuscatedName = $ResourceNameDictionary[$resourceItem.ID] }
            }
            else
            {
                # Not seeded, or seeded with an id of another shape (see
                # Test-ObfuscatedIdShape): masked below like a new id, which
                # still reuses the seed's subscription, group and parent tokens.
                # A name token the seed already gave this resource (its name map
                # entry, or its slot as the parent of a kept seeded id) is kept,
                # so the resource's own id and every id under it share one token.
                $ObfuscatedID = $null
                if ($ResourceNameDictionary.ContainsKey($resourceItem.ID) -and -not [string]::IsNullOrEmpty($ResourceNameDictionary[$resourceItem.ID])) { $ObfuscatedName = $ResourceNameDictionary[$resourceItem.ID] }
                [void]$IdsToMask.Add($resourceItem.ID)
            }

            if ($null -ne $ObfuscatedID) { $ResourceIdDictionary[$resourceItem.ID] = $ObfuscatedID }
            $ResourceNameDictionary[$resourceItem.ID] = $ObfuscatedName
            $ResourceSubscriptionDictionary[$resourceItem.ID] = $ObfuscatedSubscription
            $ResourceResourceGroupDictionary[$resourceItem.ID] = $ObfuscatedResourceGroup

        }

        foreach ($MaskId in $IdsToMask)
        {
            $ResourceIdDictionary[$MaskId] = Get-ObfuscatedResourceId -ResourceId $MaskId -SubscriptionIndex $SubIndex
        }
    }
}

function ExecuteInventoryProcessing()
{
    function InitializeInventoryProcessing()
    {
        $Global:ZipOutputFile = ($DefaultPath + $Global:ReportName + "_" + $CurrentDateTime + ".zip")
        $Global:HtmlFile = ($DefaultPath + $Global:ReportName + "_" + $CurrentDateTime + ".html")
        $Global:AllResourceFile = ($DefaultPath + "Full_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:JsonFile = ($DefaultPath + "Inventory_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:MetricsJsonFile = ($DefaultPath + "Metrics_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")
        $Global:ConsumptionFileCsv = ($DefaultPath + "Consumption_" + $Global:ReportName + "_" + $CurrentDateTime + ".csv")

        if ($RunAllSubs.IsPresent)
        {
            $ErrorLogDir = Split-Path -Path ($Global:DefaultPath.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')) -Parent
            $ErrorLogSubTag = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { $Global:CurrentDateTime }
            $Global:ErrorLogFile = (Join-Path $ErrorLogDir ("ErrorLog_" + $Global:ReportName + "_" + $Global:CurrentDateTime + "_" + $ErrorLogSubTag + ".log"))
        }
        else
        {
            $Global:ErrorLogFile = ($DefaultPath + "ErrorLog_" + $Global:ReportName + "_" + $CurrentDateTime + ".log")
        }

        if ($RunAllSubs.IsPresent)
        {
            $DebugLogDir = Split-Path -Path ($Global:DefaultPath.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')) -Parent
            $DebugLogSubTag = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { $Global:CurrentDateTime }
            $Global:DebugLogFile = (Join-Path $DebugLogDir ("DebugLog_" + $Global:ReportName + "_" + $Global:CurrentDateTime + "_" + $DebugLogSubTag + ".log"))
        }
        else
        {
            $Global:DebugLogFile = ($DefaultPath + "DebugLog_" + $Global:ReportName + "_" + $CurrentDateTime + ".log")
        }

        Write-Log -Message ('Report HTML File: {0}' -f $Global:HtmlFile) -Severity 'Info'
    }

    function Test-DataPlaneAuthReady([string]$Phase)
    {
        $TokenOk = {
            $Ctx = $null
            try { $Ctx = Get-AzContext -ErrorAction Stop } catch { return $false }
            if ($null -eq $Ctx -or $null -eq $Ctx.Account) { return $false }
            try
            {
                $Tok = Get-AzAccessToken -ErrorAction Stop -WarningAction SilentlyContinue
                return ($null -ne $Tok -and -not [string]::IsNullOrWhiteSpace($Tok.Token))
            }
            catch { return $false }
        }

        if (& $TokenOk) { return $true }

        Write-Log -Message ("{0}: no usable Azure context/token detected; attempting one reconnect before collecting {0} data." -f $Phase) -Severity 'Warning'

        # At most one reconnect per run, whatever the identity: after it,
        # later phases are skipped without trying again. A user is never
        # prompted a second time in a run, and only for the run's tenant.
        if ($script:RdaReconnectTried)
        {
            Write-Log -Message ("{0}: the one reconnect of this run was already made; not trying again. Re-authenticate (Connect-AzAccount), then re-run." -f $Phase) -Severity 'Error'
            return $false
        }
        $RunTenant = if ($TenantID) { $TenantID } else { $script:RdaRunTenant }

        try
        {
            if ($Appid -and $Secret -and $TenantID)
            {
                $script:RdaReconnectTried = $true
                Write-Log -Message ("{0}: reconnecting via Service Principal." -f $Phase) -Severity 'Info'
                $Credential = New-Object System.Management.Automation.PSCredential($Appid, $Secret)
                Connect-AzAccount -ServicePrincipal -Credential $Credential -Tenant $TenantID -Scope Process -ErrorAction Stop | Out-Null
            }
            elseif ($UseManagedIdentity.IsPresent)
            {
                # Never a user sign-in for a managed identity run.
                $script:RdaReconnectTried = $true
                Write-Log -Message ("{0}: reconnecting with the managed identity." -f $Phase) -Severity 'Info'
                if ($TenantID) { Connect-AzAccount -Identity -Tenant $TenantID -Scope Process -ErrorAction Stop | Out-Null }
                else { Connect-AzAccount -Identity -Scope Process -ErrorAction Stop | Out-Null }
                if (& $TokenOk) { return $true }
                Write-Log -Message ("{0}: the managed identity reconnect did not give a usable token. Check that this machine has a managed identity with access to the tenant, then re-run." -f $Phase) -Severity 'Error'
                return $false
            }
            elseif ($RunAllSubs.IsPresent)
            {
                Write-Log -Message ("{0}: running under -RunAllSubs without Service Principal credentials - cannot prompt for interactive login in this context. Authenticate before the run (e.g. Connect-AzAccount) or supply -appid/-secret/-tenant." -f $Phase) -Severity 'Error'
                return $false
            }
            elseif ($RunTenant -and (Test-AzPsTokenSilent -Tenant $RunTenant))
            {
                # The sign-in still reaches the run's tenant without a prompt:
                # point this process back at it.
                $script:RdaReconnectTried = $true
                Write-Log -Message ("{0}: switching this process back to tenant {1} with the same sign-in." -f $Phase, $RunTenant) -Severity 'Info'
                Set-AzContext -Tenant $RunTenant -Scope Process -ErrorAction Stop | Out-Null
            }
            elseif ($script:RdaUserSignInMade)
            {
                Write-Log -Message ("{0}: reconnecting would prompt a second time in this run; not prompting again. Re-authenticate (Connect-AzAccount{1}), then re-run." -f $Phase, $(if ($RunTenant) { " -Tenant $RunTenant" })) -Severity 'Error'
                return $false
            }
            elseif (-not (Test-RdaInteractiveSession))
            {
                Write-Log -Message ("{0}: no usable Azure context and no interactive console to prompt for login (non-interactive session). Authenticate before the run (Connect-AzAccount) or supply -appid/-secret/-tenant, then re-run." -f $Phase) -Severity 'Error'
                return $false
            }
            else
            {
                $script:RdaReconnectTried = $true
                $script:RdaUserSignInMade = $true
                $SignInArgs = @{}
                if ($RunTenant) { $SignInArgs.Tenant = $RunTenant }
                if ($DeviceLogin.IsPresent)
                {
                    Write-Log -Message ("{0}: reconnecting via device login." -f $Phase) -Severity 'Info'
                    $SignInArgs.UseDeviceAuthentication = $true
                }
                else { Write-Log -Message ("{0}: reconnecting via interactive browser login." -f $Phase) -Severity 'Info' }
                Connect-AzAccount @SignInArgs -ErrorAction Stop | Out-Null
            }
        }
        catch
        {
            Write-Log -Message ("{0}: reconnect attempt failed: {1}" -f $Phase, $_.Exception.Message) -Severity 'Error'
            return $false
        }

        return (& $TokenOk)
    }

    # The name of the report folder this run writes to (the last part of
    # $Global:DefaultPath), or $null before it is set. Failure entries carry
    # it, so the wrapper's main summary marks the row of that report.
    function Get-ReportFolderName
    {
        if ($Global:DefaultPath) { return (Split-Path -Path ($Global:DefaultPath.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')) -Leaf) }
        return $null
    }

    function CreateMetricsJob()
    {
        Write-Log -Message ('Checking if Metrics Job Should be Run.') -Severity 'Info'

        if (!$SkipMetrics.IsPresent)
        {
            if (-not (Test-DataPlaneAuthReady -Phase 'Metrics'))
            {
                Write-Log -Message ('Metrics: SKIPPED - could not establish a usable Azure context/token after one reconnect attempt. Metrics were requested (no -SkipMetrics) but cannot be collected. Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run. The rest of the inventory will continue.') -Severity 'Error'

                $Global:AzMetrics = New-Object PSObject
                $Global:AzMetrics | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
                $Global:AzMetrics.Metrics = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

                if ($null -eq $Global:MetricsFailedSubs) { $Global:MetricsFailedSubs = @() }
                $MetricsSkipMsg = 'Metrics phase skipped: no usable Azure context/token after one reconnect attempt.'
                # The report folder this run writes to, as the consumption phase records it,
                # so the wrapper's main summary marks that report's row.
                $MetricsReportFolder = Get-ReportFolderName
                $AffectedSubs = @(
                    if (![string]::IsNullOrEmpty($SubscriptionID))
                    {
                        $Global:Subscriptions | Where-Object { $_.id -eq $SubscriptionID }
                    }
                    else
                    {
                        $Global:Subscriptions
                    }
                )
                if ($AffectedSubs.Count -eq 0)
                {
                    $IdLabel = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { '(unknown)' }
                    $Global:MetricsFailedSubs += [pscustomobject]@{ Name = '(subscription)'; Id = $IdLabel; Message = $MetricsSkipMsg; ReportFolder = $MetricsReportFolder }
                }
                else
                {
                    foreach ($asub in $AffectedSubs)
                    {
                        $Global:MetricsFailedSubs += [pscustomobject]@{ Name = $asub.Name; Id = $asub.Id; Message = $MetricsSkipMsg; ReportFolder = $MetricsReportFolder }
                    }
                }
                return
            }

            Write-Log -Message ('Running Metrics Jobs') -Severity 'Success'

            if ($PSScriptRoot -like '*\*')
            {
                $MetricPath = Get-ChildItem -Path ($PSScriptRoot + '\Extension\Metrics.ps1') -Recurse
            }
            else
            {
                $MetricPath = Get-ChildItem -Path ($PSScriptRoot + '/Extension/Metrics.ps1') -Recurse
            }

            $MetricsFilePath = ($DefaultPath + "Metrics_" + $Global:ReportName + "_" + $CurrentDateTime + "_")

            $Global:AzMetrics = New-Object PSObject
            $Global:AzMetrics | Add-Member -MemberType NoteProperty -Name Metrics -Value NotSet
            $Global:AzMetrics.Metrics = & $MetricPath -Subscriptions $Subscriptions -Resources $Resources -Task "Processing" -ConcurrencyLimit $ConcurrencyLimit -FilePath $MetricsFilePath -ResourceIdDictionary $(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null }) -ResourceNameDictionary $(if ($Obfuscate.IsPresent) { $ResourceNameDictionary } else { $null }) -ResourceSubDictionary $(if ($Obfuscate.IsPresent) { $ResourceSubscriptionDictionary } else { $null }) -ResourceGroupDictionary $(if ($Obfuscate.IsPresent) { $ResourceResourceGroupDictionary } else { $null }) -Obfuscate $Obfuscate.IsPresent -MetricsLookbackDays $MetricsLookbackDays
        }
    }

    function ProcessMetricsResult()
    {
        if (!$SkipMetrics.IsPresent)
        {
            $([System.GC]::GetTotalMemory($false))
            $([System.GC]::Collect())
            $([System.GC]::GetTotalMemory($true))
        }
    }

    function GetServiceName($moduleUrl)
    {
        if ($moduleUrl -like '*Services/Analytics*')
        {
            $DirectoryService = 'Analytics'
        }

        if ($moduleUrl -like '*Services/Compute*')
        {
            $DirectoryService = 'Compute'
        }

        if ($moduleUrl -like '*Services/Containers*')
        {
            $DirectoryService = 'Containers'
        }

        if ($moduleUrl -like '*Services/Data*')
        {
            $DirectoryService = 'Data'
        }

        if ($moduleUrl -like '*Services/Infrastructure*')
        {
            $DirectoryService = 'Infrastructure'
        }

        if ($moduleUrl -like '*Services/Integration*')
        {
            $DirectoryService = 'Integration'
        }

        if ($moduleUrl -like '*Services/Networking*')
        {
            $DirectoryService = 'Networking'
        }

        if ($moduleUrl -like '*Services/Storage*')
        {
            $DirectoryService = 'Storage'
        }

        return $DirectoryService
    }

    function CreateResourceJobs()
    {
        $Global:SmaResources = New-Object PSObject

        Write-Log -Message ('Starting Service Processing Jobs.') -Severity 'Info'

        if ($PSScriptRoot -like '*\*')
        {
            $Modules = Get-ChildItem -Path ($PSScriptRoot + '\Services\*.ps1') -Recurse
        }
        else
        {
            $Modules = Get-ChildItem -Path ($PSScriptRoot + '/Services/*.ps1') -Recurse
        }

        if ($Service -and @($Service).Count -gt 0)
        {
            $AvailableServices = @($Modules | ForEach-Object { $_.BaseName } | Sort-Object)
            $Modules = @($Modules | Where-Object { $_.BaseName -in $Service })

            if (@($Modules).Count -eq 0)
            {
                Write-Log -Message ("-Service matched no collectors. Requested: [{0}]. Available: [{1}]." -f ($Service -join ', '), ($AvailableServices -join ', ')) -Severity 'Error'
                throw ("-Service matched no collectors. Requested: [{0}]." -f ($Service -join ', '))
            }

            $MatchedNames = @($Modules | ForEach-Object { $_.BaseName } | Sort-Object)
            Write-Log -Message ("-Service filter active: collecting {0} of {1} collectors: [{2}]" -f @($Modules).Count, @($AvailableServices).Count, ($MatchedNames -join ', ')) -Severity 'Info'

            $UnmatchedServices = @($Service | Where-Object { $_ -notin $MatchedNames })
            if (@($UnmatchedServices).Count -gt 0)
            {
                Write-Log -Message ("-Service: these requested names matched nothing and were ignored: [{0}]. Available: [{1}]." -f ($UnmatchedServices -join ', '), ($AvailableServices -join ', ')) -Severity 'Warning'
            }
        }

        $Resource = $Resources | Select-Object -First $Resources.count

        $ConsecutiveCollectorFailures = 0
        $CollectorFailureCircuitBreakerThreshold = 5

        $ModuleTotal = @($Modules).Count
        $ModuleIndex = 0

        $HeartbeatSubLabel = if (![string]::IsNullOrEmpty($SubscriptionID)) { $SubscriptionID } else { '(all in-scope subscriptions)' }
        Write-Log -Message ("Service processing started for {0}: {1} collectors" -f $HeartbeatSubLabel, $ModuleTotal) -NoConsole -ToDebugLog

        foreach ($Module in $Modules)
        {
            $ModName = $Module.Name.Substring(0, $Module.Name.length - ".ps1".length)
            $ModuleIndex++

            Write-RdaProgress -Activity 'Service Processing' -CurrentItem $ModName -Index $ModuleIndex -Total $ModuleTotal -BarOnly

            Write-Log -Message ("START ({0}/{1}) {2}" -f $ModuleIndex, $ModuleTotal, $ModName) -NoConsole -ToDebugLog

            try
            {
                $Result = & $Module -Sub $Subscriptions -Resources $Resource -Task "Processing" -ResourceIdDictionary $(if ($Obfuscate.IsPresent) { $ResourceIdDictionary } else { $null })
                $ConsecutiveCollectorFailures = 0

                Write-Log -Message ("DONE  ({0}/{1}) {2}" -f $ModuleIndex, $ModuleTotal, $ModName) -NoConsole -ToDebugLog
            }
            catch
            {
                $ConsecutiveCollectorFailures++

                Write-Log -Message ("FAIL  ({0}/{1}) {2}: {3}" -f $ModuleIndex, $ModuleTotal, $ModName, $_.Exception.Message) -NoConsole -ToDebugLog

                if ($null -eq $Global:CollectorFailures) { $Global:CollectorFailures = @() }
                $CollectorFailure = [pscustomobject]@{
                    Id      = $SubscriptionID
                    Module  = $ModName
                    Message = $_.Exception.Message
                }
                $Global:CollectorFailures += $CollectorFailure
                # $Global:CollectorFailures is a running total across every subscription a wrapper run
                # processes; this list holds only this run's failures, for this run's HTML report.
                $script:CollectorFailuresThisRun += $CollectorFailure

                Write-Log -Message ("Collector FAILED: {0}: {1}" -f $ModName, $_.Exception.Message) -Severity 'Error'
                Write-Log -Message ("The rest of the inventory will continue, but the '{0}' resource type is MISSING from this report - not empty because there are none, but because the collector errored. Re-run to retry, or investigate the error above if it repeats." -f $ModName) -Severity 'Error'

                if ($ConsecutiveCollectorFailures -ge $CollectorFailureCircuitBreakerThreshold)
                {
                    throw ("Stopping: {0} collectors failed in a row (most recently '{1}': {2}). This pattern indicates a systemic problem (authentication dropped mid-run, network lost, or a broken Az module) rather than an issue with any single resource type. Fix the underlying problem (see the error above) and re-run rather than continuing - limping through the remaining collectors would only produce more identical failures and an incomplete report that looks like an empty environment. Total collector failures across the whole run so far (all subscriptions processed to this point): {3}." -f $ConsecutiveCollectorFailures, $ModName, $_.Exception.Message, ($Global:CollectorFailures.Count))
                }

                $Result = @()
            }

            if ($Obfuscate.IsPresent)
            {
                foreach ($resourceItem in $Result)
                {
                    $OrigID = $resourceItem.ID

                    if ([string]::IsNullOrEmpty($OrigID))
                    {
                        # No id to mask: a masked ARM path from the row's own
                        # subscription, resource group and name (never empty).
                        $NoId = New-ObfuscatedRowIdWithoutId -Subscription ([string]$resourceItem.Subscription) -ResourceGroup ([string]$resourceItem.ResourceGroup) -Name ([string]$resourceItem.Name) -Collector $ModName
                        $resourceItem.ID = $NoId.Id
                        $resourceItem.Name = $NoId.Name
                        $resourceItem.Subscription = $NoId.Subscription
                        $resourceItem.ResourceGroup = $NoId.ResourceGroup
                        if ($resourceItem.ContainsKey('tags')) { $resourceItem.tags = $null }
                        if ($resourceItem.ContainsKey('Tags')) { $resourceItem.Tags = $null }
                        continue
                    }

                    # An id the token loop did not mask (a collector row that is
                    # not a discovered resource) gets the masked ARM path
                    # Get-ObfuscatedResourceId gives it, which also records its
                    # name, subscription and resource group tokens, so the row's
                    # fields match its own id path.
                    if (-not $ResourceIdDictionary.ContainsKey($OrigID) -or [string]::IsNullOrEmpty($ResourceIdDictionary[$OrigID]))
                    {
                        $ResourceIdDictionary[$OrigID] = Get-ObfuscatedResourceId -ResourceId $OrigID
                    }
                    $resourceItem.ID = $ResourceIdDictionary[$OrigID]

                    $Prefix = Get-ObfuscationPrefix $OrigID

                    if (-not $ResourceNameDictionary.ContainsKey($OrigID) -or [string]::IsNullOrEmpty($ResourceNameDictionary[$OrigID]))
                    {
                        $ResourceNameDictionary[$OrigID] = $Prefix + [guid]::NewGuid().ToString()
                    }
                    $resourceItem.Name = $ResourceNameDictionary[$OrigID]

                    if (-not $ResourceSubscriptionDictionary.ContainsKey($OrigID) -or [string]::IsNullOrEmpty($ResourceSubscriptionDictionary[$OrigID]))
                    {
                        $ResourceSubscriptionDictionary[$OrigID] = $Prefix + [guid]::NewGuid().ToString()
                    }
                    $resourceItem.Subscription = $ResourceSubscriptionDictionary[$OrigID]

                    if (-not $ResourceResourceGroupDictionary.ContainsKey($OrigID) -or [string]::IsNullOrEmpty($ResourceResourceGroupDictionary[$OrigID]))
                    {
                        $ResourceResourceGroupDictionary[$OrigID] = $Prefix + [guid]::NewGuid().ToString()
                    }
                    $resourceItem.ResourceGroup = $ResourceResourceGroupDictionary[$OrigID]

                    if ($resourceItem.ContainsKey('Tags') -and $null -ne $resourceItem.Tags)
                    {
                        foreach ($Tag in $resourceItem.Tags)
                        {
                            if ($null -ne $Tag -and -not [string]::IsNullOrEmpty([string]$Tag.Value))
                            {
                                $RealTagValue = [string]$Tag.Value
                                if (-not $Global:TagValueDictionary.ContainsKey($RealTagValue))
                                {
                                    $TagPrefix = if ($RealTagValue -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealTagValue -match '(^|-)([dts])-') { 'nonprod_' } else { 'prod_' }
                                    $Global:TagValueDictionary[$RealTagValue] = $TagPrefix + [guid]::NewGuid().ToString()
                                }
                                $Tag.Value = $Global:TagValueDictionary[$RealTagValue]
                            }
                        }
                    }
                }
            }

            $Global:SmaResources | Add-Member -MemberType NoteProperty -Name $ModName -Value NotSet
            $Global:SmaResources.$ModName = @($Result)

            $Result = $null
            [System.GC]::Collect()
        }

        Write-RdaProgress -Activity 'Service Processing' -Completed

        Write-Log -Message ("Service processing complete: {0} collectors" -f $ModuleTotal) -NoConsole -ToDebugLog
    }

    function ProcessResourceResult()
    {
        Write-Log -Message ("Starting Reporting Phase.") -Severity 'Info'

        $Global:SmaResources | Add-Member -MemberType NoteProperty -Name 'Version' -Value NotSet
        $Global:SmaResources.Version = $Global:Version

        # Write-InventoryJson removes its temporary file and throws when the write fails (out of
        # memory on a large estate, a full disk, a value ConvertTo-Json rejects). The script runs
        # with ErrorActionPreference 'silentlycontinue', and on a direct run no caller catches
        # the throw, so nothing would show it: log the real cause here first, then throw it on.
        try
        {
            Write-InventoryJson -InputObject $Global:SmaResources -Path $Global:JsonFile
        }
        catch
        {
            # The throw skips the release below, so free the collector data here, first, so the log
            # line below has the memory it needs: the report step, and under the wrappers the next
            # subscription, must not share memory with it. As in the release, the Azure context read
            # and the handler removal let go of the rows the Azure session still holds.
            $Global:SmaResources = $null
            $Global:Resources = $null
            Write-Log -Message ("Inventory write FAILED: {0} was not written: {1}" -f $Global:JsonFile, $_.Exception.Message) -Severity 'Error' -ToDebugLog
            try
            {
                $null = Get-AzContext -ErrorAction Stop
                [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.ClientFactory.RemoveHandler([Microsoft.Azure.Commands.Common.Authentication.Models.RPRegistrationDelegatingHandler])
            }
            catch
            {
                Write-Log -Message ('Azure session read or handler removal after the failed inventory write failed: {0}.' -f $_.Exception.Message) -NoConsole -ToDebugLog
            }
            throw
        }

        Write-Log -Message ('Resource Reporting Phase Done.') -Severity 'Info'
    }

    function GetResorceConsumption()
    {
        $DebugPreference = "SilentlyContinue"
        # A usage row leaves out the InstanceData parts Azure has no value for
        # (additionalInfo, or some of its keys), and the row loop reads them as
        # properties that may be absent. Strict mode is off for this phase only, so
        # a run started from a shell with Set-StrictMode -Version Latest writes such
        # a row with its empty defaults instead of stopping the subscription's pull.
        Set-StrictMode -Off

        [System.Threading.Thread]::CurrentThread.CurrentUICulture = "en-US";
        [System.Threading.Thread]::CurrentThread.CurrentCulture = "en-US";

        # UsageStartTime / UsageEndTime are written in this format with the
        # invariant culture, so the text is the same on every host. The en-US
        # culture's own time pattern comes from the host's culture data: with
        # ICU (on Linux, for example) it can have U+202F, not a space, before AM/PM.
        $UsageDateFormat = 'M/d/yyyy h:mm:ss tt'
        $InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

        # The run's window (RunInventorySetup): the one the up-front
        # consumption data check queried, or under -RunAllSubs the wrapper's.
        $ReportedStartTime = $script:ConsumptionWindow.Start
        $ReportedEndTime = $script:ConsumptionWindow.End

        # Name of the report folder this run writes to, recorded on a consumption
        # failure (and on the sign-in skip below) so the wrapper's main summary can
        # mark that report's row.
        $ConsumptionReportFolder = Get-ReportFolderName

        if (-not (Test-DataPlaneAuthReady -Phase 'Consumption'))
        {
            Write-Log -Message ('Consumption: SKIPPED - could not establish a usable Azure context/token after one reconnect attempt. Consumption was requested (no -SkipConsumption) but cannot be collected. Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run. The rest of the inventory will continue.') -Severity 'Error'

            if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
            if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
            # SubscriptionId: the one subscription a wrapper run is for (empty
            # in a direct run of all), so the wrapper counts each skip once.
            # Only counted, never printed.
            $Global:ConsumptionFailedSubs += [pscustomobject]@{
                Name           = '(all subscriptions)'
                Id             = '(auth)'
                Message        = 'Consumption phase skipped: no usable Azure context/token after one reconnect attempt.'
                ReportFolder   = $ConsumptionReportFolder
                SubscriptionId = [string]$SubscriptionID
            }
            return
        }

        foreach ($sub in $Global:Subscriptions)
        {
            if (![string]::IsNullOrEmpty($SubscriptionID))
            {
                if (![string]::IsNullOrEmpty($ResourceGroup))
                {
                    Write-Log -Message ("Cannot filter consumption by resource group." -f $sub.Name) -Severity 'Info'
                }

                if ($SubscriptionID -ne $sub.Id)
                {
                    Write-Log -Message ("Skipping: {0}" -f $sub.Name) -Severity 'Info'
                    continue
                }
            }

            $ContextOk = $false
            $ContextSwitchError = $null
            try
            {
                # For this run only: -Scope Process keeps the switch out of the user's saved default subscription.
                $null = Set-AzContext -Subscription $sub.id -Scope Process -ErrorAction Stop
                $ContextOk = ((Get-AzContext).Subscription.Id -eq $sub.id)
            }
            catch
            {
                $ContextSwitchError = $_.Exception.Message
            }

            if (-not $ContextOk)
            {
                $SkipMessage = ("Consumption SKIPPED: could not switch the Azure context to this subscription{0}. The signed-in identity likely lacks access to it. Skipped to avoid attributing another subscription's billing data to this one." -f $(if ($ContextSwitchError) { " ($ContextSwitchError)" } else { ' (context did not match the target after Set-AzContext)' }))
                Write-Log -Message ("Consumption: {0} - {1}" -f $sub.Name, $SkipMessage) -Severity 'Error'

                if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
                if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
                $Global:ConsumptionFailedSubs += [pscustomobject]@{
                    Name             = $sub.Name
                    Id               = $sub.Id
                    Message          = $SkipMessage
                    Complete         = $false
                    PageAtFailure    = 0
                    RecordsCollected = 0
                    ReportFolder     = $ConsumptionReportFolder
                }

                continue
            }

            Write-Log -Message ("Gathering Consumption for: {0}" -f $sub.Name) -Severity 'Info'

            $ConsumptionRecordsThisSub = 0
            $ConsumptionFailedThisSub = $false
            $ConsumptionFailureMessage = $null
            $ConsumptionPageIndex = 0

            try
            {
                do
                {
                    $ConsumptionPageIndex++
                    $Params = @{
                        ReportedStartTime      = $ReportedStartTime
                        ReportedEndTime        = $ReportedEndTime
                        AggregationGranularity = 'Daily'
                        ShowDetails            = $true
                    }

                    $Params.ContinuationToken = $UsageData.ContinuationToken

                    $ConsumptionMaxRetries = 3
                    $ConsumptionAttempt = 0
                    while ($true)
                    {
                        try
                        {
                            $UsageData = Get-UsageAggregates @Params -ErrorAction Stop
                            break
                        }
                        catch
                        {
                            $ConsumptionAttempt++
                            if ($ConsumptionAttempt -gt $ConsumptionMaxRetries) { throw }
                            $ConsumptionBackoffSeconds = [int][math]::Pow(2, $ConsumptionAttempt)
                            Write-Log -Message ("Consumption page query failed for {0} (attempt {1}/{2}): {3}. Retrying in {4}s..." -f $sub.Name, $ConsumptionAttempt, $ConsumptionMaxRetries, $_.Exception.Message, $ConsumptionBackoffSeconds) -Severity 'Warning'
                            Start-Sleep -Seconds $ConsumptionBackoffSeconds
                        }
                    }
                    $UsageDataExport = $UsageData.UsageAggregations.Properties | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime

                    Write-Log -Message ("Records found: $($UsageDataExport.Count)...") -Severity 'Info'
                    $ConsumptionRecordsThisSub += $UsageDataExport.Count

                    $NewUsageDataExport = [System.Collections.ArrayList]::new()

                    for ($Item = 0; $Item -lt $UsageDataExport.Count; $Item++)
                    {
                        $InstanceInfo = ($UsageDataExport[$Item].InstanceData.tolower() | ConvertFrom-Json)

                        if (![string]::IsNullOrEmpty($ResourceGroup))
                        {
                            # Same test the up-front consumption data check counts rows by.
                            if (-not (Test-ConsumptionResourceUriInResourceGroup -ResourceUri $InstanceInfo.'Microsoft.Resources'.resourceUri -ResourceGroup $ResourceGroup))
                            {
                                continue;
                            }
                        }

                        # The clock value as Get-UsageAggregates returned it, no time-zone conversion.
                        foreach ($DateField in @('UsageStartTime', 'UsageEndTime'))
                        {
                            $DateValue = $UsageDataExport[$Item].$DateField
                            if ($DateValue -is [datetime]) { $UsageDataExport[$Item].$DateField = $DateValue.ToString($UsageDateFormat, $InvariantCulture) }
                        }

                        $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ResourceId -Value NotSet
                        $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ResourceLocation -Value NotSet

                        $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ConsumptionMeter -Value NotSet
                        $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ReservationId -Value NotSet
                        $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ReservationOrderId -Value NotSet

                        $UsageDataExport[$Item].ResourceId = $InstanceInfo.'Microsoft.Resources'.resourceUri
                        $UsageDataExport[$Item].ResourceLocation = $InstanceInfo.'Microsoft.Resources'.location
                        $UsageDataExport[$Item].ConsumptionMeter = $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter
                        $UsageDataExport[$Item].ReservationId = $InstanceInfo.'Microsoft.Resources'.additionalInfo.ReservationId
                        $UsageDataExport[$Item].ReservationOrderId = $InstanceInfo.'Microsoft.Resources'.additionalInfo.ReservationOrderId

                        $InstanceObject = [PSCustomObject]@{}

                        $AdditionalInfoInstance = [PSCustomObject]@{
                            ResourceUri = $InstanceInfo.'Microsoft.Resources'.resourceUri
                            Location = $InstanceInfo.'Microsoft.Resources'.location
                            additionalInfo = [PSCustomObject]@{
                                ConsumptionMeter = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter }
                                ImageType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ImageType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ImageType }
                                AHB = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.AHB) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.AHB }
                                vCores = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.vCores) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.vCores }
                                VCPUs = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.VCPUs) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.VCPUs }
                                ServiceType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServiceType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServiceType }
                                ResourceCategory = ""
                                Edition = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.Edition) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.Edition }
                                LicenseType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.LicenseType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.LicenseType }
                                HostLicenseType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.HostLicenseType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.HostLicenseType }
                                OS = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.OS) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.OS }
                                IsVM = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsVM) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsVM }
                                NumberOfCores = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfCores) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfCores }
                                NumberOfLogicalProcessors = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfLogicalProcessors) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfLogicalProcessors }
                                SLO = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.SLO) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.SLO }
                                ServerSku = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerSku) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerSku }
                                ServerEdition = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerEdition) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerEdition }
                                IsHAEnabled = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsHAEnabled) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsHAEnabled }
                            }
                        }

                        $InstanceObject | Add-Member -MemberType NoteProperty -Name "Microsoft.Resources" -Value $AdditionalInfoInstance

                        if ($Obfuscate.IsPresent)
                        {
                            $RawUri = $InstanceObject.'Microsoft.Resources'.resourceUri

                            if (![string]::IsNullOrEmpty($RawUri) -and $ResourceIdDictionary.ContainsKey($RawUri))
                            {
                                $ObfuscatedUri = $ResourceIdDictionary[$RawUri]
                            }
                            else
                            {
                                # A resource that is not in the inventory: its segments reuse the
                                # inventory's tokens where they exist (subscription, resource
                                # group, parent resource), and new ones go into the dictionary.
                                $ObfuscatedUri = Get-ObfuscatedResourceId -ResourceId $RawUri

                                if (![string]::IsNullOrEmpty($RawUri))
                                {
                                    $ResourceIdDictionary[$RawUri] = $ObfuscatedUri
                                }
                            }

                            $UsageDataExport[$Item].ResourceId = $ObfuscatedUri
                            $InstanceObject.'Microsoft.Resources'.resourceUri = $ObfuscatedUri

                            if (![string]::IsNullOrEmpty($UsageDataExport[$Item].ReservationId))
                            {
                                $UsageDataExport[$Item].ReservationId = 'obfuscated'
                            }
                            if (![string]::IsNullOrEmpty($UsageDataExport[$Item].ReservationOrderId))
                            {
                                $UsageDataExport[$Item].ReservationOrderId = 'obfuscated'
                            }
                        }

                        $UsageDataExport[$Item].InstanceData = $InstanceObject | ConvertTo-Json -Compress

                        $NewUsageDataExport.Add($UsageDataExport[$Item]) | Out-Null
                    }

                    $NewUsageDataExport | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime, ResourceId, ResourceLocation, ConsumptionMeter, ReservationId, ReservationOrderId | Export-Csv $Global:ConsumptionFileCsv -Encoding utf8 -Append -NoTypeInformation

                } while ('ContinuationToken' -in $UsageData.psobject.properties.name -and $UsageData.ContinuationToken)
            }
            catch
            {
                $ConsumptionFailedThisSub = $true
                $ConsumptionFailureMessage = ("{0} (stopped at consumption page {1}, after {2} record(s); this subscription's consumption is INCOMPLETE)" -f $_.Exception.Message, $ConsumptionPageIndex, $ConsumptionRecordsThisSub)
                Write-Log -Message ("Consumption query failed for {0}: {1}" -f $sub.Name, $ConsumptionFailureMessage) -Severity 'Warning'
            }

            if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
            if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
            $Global:ConsumptionRecordCount += $ConsumptionRecordsThisSub
            if ($ConsumptionFailedThisSub)
            {
                $Global:ConsumptionFailedSubs += [pscustomobject]@{
                    Name             = $sub.Name
                    Id               = $sub.Id
                    Message          = $ConsumptionFailureMessage
                    Complete         = $false
                    PageAtFailure    = $ConsumptionPageIndex
                    RecordsCollected = $ConsumptionRecordsThisSub
                    ReportFolder     = $ConsumptionReportFolder
                }
            }
        }

        $DebugPreference = "Continue"
    }

    InitializeInventoryProcessing

    $script:PhaseTimings = [ordered]@{}
    $script:CollectorFailuresThisRun = @()

    $MetricsPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
    CreateMetricsJob
    $MetricsPhaseTimer.Stop()

    $CollectorPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
    CreateResourceJobs
    $CollectorPhaseTimer.Stop()

    ProcessMetricsResult
    ProcessResourceResult

    # Nothing reads the collector output or the discovery rows after the inventory is written, and
    # on a large estate the report step needs that memory. The count stays in $Global:ResourceCount.
    $Global:SmaResources = $null
    $Global:Resources = $null
    # Setting the two globals to $null does not free the rows on its own. Az cmdlets leave their stream
    # handlers in the shared Azure session when they return, so the collector that made the last Azure
    # call piped into a filter (the VM or scale set size lookup) stays referenced, and with it the rows
    # it was given. The next Az cmdlet replaces those handlers; this read is that call, made from a
    # scope that holds no rows. The size lookup also adds a provider-registration handler to the shared
    # client factory, which keeps the same cmdlet referenced, and the read does not always remove it, so
    # it is removed by type; the next resource-manager cmdlet adds its own again. -ErrorAction Stop
    # sends any failure to the catch, so it is logged and the run goes on.
    try
    {
        $null = Get-AzContext -ErrorAction Stop
        [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.ClientFactory.RemoveHandler([Microsoft.Azure.Commands.Common.Authentication.Models.RPRegistrationDelegatingHandler])
    }
    catch
    {
        Write-Log -Message ('Azure session read or handler removal after the release failed: {0}. The collector data may stay in memory until the next Azure call.' -f $_.Exception.Message) -NoConsole -ToDebugLog
    }
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    if (!$SkipMetrics.IsPresent)
    {
        $script:PhaseTimings['Metrics collection (Azure Monitor)'] = $MetricsPhaseTimer.Elapsed
    }
    $script:PhaseTimings['Resource detail collection (service collectors)'] = $CollectorPhaseTimer.Elapsed

    if (!$SkipConsumption.IsPresent)
    {
        $ConsumptionPhaseTimer = [System.Diagnostics.Stopwatch]::StartNew()
        GetResorceConsumption
        $ConsumptionPhaseTimer.Stop()
        $script:PhaseTimings['Consumption / cost collection (billing)'] = $ConsumptionPhaseTimer.Elapsed
    }
}

function FinalizeOutputs
{
    function ProcessSummary()
    {
        # Set when Summary.ps1 fails: an HTML file left by a report step that failed part-way is
        # not a report to zip.
        $Global:HtmlReportFailed = $false
        if (-not (Test-Path -LiteralPath $Global:JsonFile))
        {
            # Summary.ps1 would only fail with 'Inventory JSON not found'; say why there is no report.
            Write-Log -Message ("No HTML report: the inventory {0} was not written. See the error above." -f $Global:JsonFile) -Severity 'Error'
            throw ("No HTML report: the inventory {0} was not written." -f $Global:JsonFile)
            # Under 'silentlycontinue' with no caller catching it (a direct run), the throw does not stop here.
            return
        }

        Write-Log -Message ('Creating Summary Report') -Severity 'Info'
        Write-Log -Message ('Starting Summary Report Processing Job.') -Severity 'Info'

        if ($PSScriptRoot -like '*\*')
        {
            $SummaryPath = Get-ChildItem -Path ($PSScriptRoot + '\Extension\Summary.ps1') -Recurse
        }
        else
        {
            $SummaryPath = Get-ChildItem -Path ($PSScriptRoot + '/Extension/Summary.ps1') -Recurse
        }

        $ReportTenantId = if ($Obfuscate.IsPresent) { $null } else { $TenantID }
        # The header's subscription, for a run of one subscription: a subscription
        # with no resources has no record for Summary.ps1 to take the name from.
        # A run without -SubscriptionID over several subscriptions says how many
        # it covers (a count, so nothing to mask under -Obfuscate); naming the
        # first record's subscription would label the whole report with one.
        # Otherwise, under -Obfuscate, Summary.ps1 keeps taking it from the
        # first record (the masked name).
        # The count is of the subscriptions such a run inventories: the list
        # 'az account list' gives (outside Cloud Shell, LoginSession narrows it
        # to -TenantID when one is given), with the same filter az applies by
        # default (state exactly 'Enabled'), so a Disabled or Warned entry is
        # never counted as covered.
        $ReportSubscriptionName = $null
        $RunSubscriptionCount = @(@($Global:Subscriptions) | Where-Object { $null -ne $_ -and [string]$_.state -ceq 'Enabled' }).Count
        if ([string]::IsNullOrEmpty($SubscriptionID) -and $RunSubscriptionCount -gt 1)
        {
            $ReportSubscriptionName = '{0} subscriptions (consolidated)' -f $RunSubscriptionCount
        }
        elseif (-not $Obfuscate.IsPresent -and -not [string]::IsNullOrEmpty($SubscriptionID))
        {
            $ReportSubscriptionName = [string](@($Global:Subscriptions) | Where-Object { $null -ne $_ -and [string]$_.id -eq $SubscriptionID } | Select-Object -First 1).name
        }
        $ReportTitle = ('Azure Resource Inventory - {0}' -f $Global:ReportName)

        try
        {
            $null = & $SummaryPath -JsonFile $Global:JsonFile -HtmlFile $Global:HtmlFile -Title $ReportTitle -SubscriptionName $ReportSubscriptionName -TenantId $ReportTenantId -Version $Global:Version -ExtractionRunTime $Runtime -ReportingRunTime $ReportingRunTime -PhaseTimings $script:PhaseTimings -PlatOS $PlatformOS -ConsumptionFile $Global:ConsumptionFileCsv -CollectorFailures $script:CollectorFailuresThisRun
        }
        catch
        {
            $Global:HtmlReportFailed = $true
            Write-Log -Message ("HTML report generation FAILED: {0}" -f $_.Exception.Message) -Severity 'Error'
            Write-Log -Message ("The data files this run did write are still in {0}, but no HTML report or zip was produced for this run." -f $Global:DefaultPath) -Severity 'Error'
            throw
        }
    }

    ProcessSummary
}

if (-not $RunAllSubs.IsPresent)
{
    # Run-wide health totals. The phases below only ever add to them, and a PowerShell
    # window keeps its globals between runs, so a direct run starts from zero: otherwise
    # its diagnostics log lists an earlier run's failures as this run's. Under -RunAllSubs
    # the wrapper (or stream worker) resets them once and adds up every subscription.
    $Global:ConsumptionRecordCount = 0
    $Global:ConsumptionFailedSubs = @()
    $Global:MetricsFailedSubs = @()
    $Global:CollectorFailures = @()

    $PreFlightInventoryRoot = if ($OutputDirectory)
    {
        try { (Resolve-Path $OutputDirectory -ErrorAction Stop).Path }
        catch { $OutputDirectory }
    }
    elseif ($PSVersionTable.Platform -eq 'Unix')
    {
        "$HOME/InventoryReports"
    }
    else
    {
        "C:\InventoryReports"
    }
    if (-not (Test-Path -Path $PreFlightInventoryRoot -PathType Container))
    {
        try { New-Item -Path $PreFlightInventoryRoot -ItemType Directory -Force | Out-Null }
        catch { Write-Verbose ("PreFlightInventoryRoot create failed at {0}: {1}" -f $PreFlightInventoryRoot, $_.Exception.Message) }
    }

    Write-Host "Running pre-flight checks..." -ForegroundColor Cyan

    if ($Service -and @($Service).Count -gt 0)
    {
        $PreFlightAvailableServices = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Services') -Filter '*.ps1' -Recurse | ForEach-Object { $_.BaseName } | Sort-Object)
        $PreFlightMatchedServices = @($Service | Where-Object { $_ -in $PreFlightAvailableServices })
        if (@($PreFlightMatchedServices).Count -eq 0)
        {
            Write-Host ("ERROR: -Service matched no collectors. Requested: [{0}]." -f ($Service -join ', ')) -ForegroundColor Red
            Write-Host ("Valid collector names: [{0}]" -f ($PreFlightAvailableServices -join ', ')) -ForegroundColor Yellow
            exit 1
        }
        Write-Host ("Pre-flight: -Service will collect {0} of {1} collectors: [{2}]" -f @($PreFlightMatchedServices).Count, @($PreFlightAvailableServices).Count, ($PreFlightMatchedServices -join ', ')) -ForegroundColor Green
    }

    if (-not [string]::IsNullOrEmpty($ObfuscationDictionary))
    {
        if (-not $Obfuscate.IsPresent)
        {
            Write-Host "ERROR: -ObfuscationDictionary requires -Obfuscate (there are no obfuscation dictionaries to seed without it)." -ForegroundColor Red
            exit 1
        }
        if (-not (Test-Path -Path $ObfuscationDictionary -PathType Leaf))
        {
            Write-Host ("ERROR: -ObfuscationDictionary file not found: {0}" -f $ObfuscationDictionary) -ForegroundColor Red
            exit 1
        }
        try
        {
            $null = Get-Content -Path $ObfuscationDictionary -Raw | ConvertFrom-Json
        }
        catch
        {
            Write-Host ("ERROR: -ObfuscationDictionary is not valid JSON: {0}" -f $ObfuscationDictionary) -ForegroundColor Red
            exit 1
        }
        Write-Host ("Pre-flight: -ObfuscationDictionary will seed obfuscation tokens from {0}" -f $ObfuscationDictionary) -ForegroundColor Green
    }

    if (Get-Command Get-CloudDrive -ErrorAction SilentlyContinue)
    {
        $CheckCloudDrive = Get-CloudDrive 3>$null 2>$null
        if ($null -eq $CheckCloudDrive)
        {
            Write-Host ""
            Write-Host "WARNING: Cloud Shell detected, but no storage account is mounted." -ForegroundColor Yellow
            Write-Host "  Outputs in $PreFlightInventoryRoot will be lost when this Cloud Shell session ends." -ForegroundColor Yellow
            Write-Host "  To persist outputs, mount a storage account first:" -ForegroundColor Yellow
            Write-Host "    clouddrive mount" -ForegroundColor Yellow
            Write-Host "  Continuing in ephemeral mode - download the report ZIP from $PreFlightInventoryRoot before closing the shell." -ForegroundColor Yellow
            Write-Host ""
        }
        else
        {
            Write-Host ("Cloud Shell drive mounted: {0}" -f $CheckCloudDrive.Name) -ForegroundColor Green
        }
    }

    try
    {
        $RootItem = Get-Item -Path $PreFlightInventoryRoot -ErrorAction Stop
        $Drive = $RootItem.PSDrive
        if ($null -ne $Drive -and $null -ne $Drive.Free)
        {
            $FreeMB = [math]::Round($Drive.Free / 1MB, 0)
            if ($FreeMB -lt 100)
            {
                # exit, not throw: the production 'SilentlyContinue' preference
                # suppresses a bare throw, and the run would go on.
                Write-Host ("ERROR: Pre-flight: free disk space at {0} is {1} MB; the script needs at least 100 MB to start. Free space and re-run." -f $PreFlightInventoryRoot, $FreeMB) -ForegroundColor Red
                exit 1
            }
            elseif ($FreeMB -lt 500)
            {
                Write-Host ("WARNING: Free disk space at {0} is {1} MB. A large multi-subscription run can exceed this. Consider freeing space before running." -f $PreFlightInventoryRoot, $FreeMB) -ForegroundColor Yellow
            }
            else
            {
                Write-Host ("Free disk space: {0:N0} MB at {1}" -f $FreeMB, $PreFlightInventoryRoot) -ForegroundColor Green
            }
        }
    }
    catch
    {
        Write-Host ("WARNING: Could not determine free disk space at {0}: {1}" -f $PreFlightInventoryRoot, $_.Exception.Message) -ForegroundColor Yellow
    }

    $ProbePath = Join-Path $PreFlightInventoryRoot (".write-probe-{0}.tmp" -f ([guid]::NewGuid()))
    try
    {
        Set-Content -Path $ProbePath -Value 'preflight write probe' -Encoding utf8 -ErrorAction Stop
        $ProbeRead = Get-Content -Path $ProbePath -Raw -ErrorAction Stop
        if ($ProbeRead -notmatch 'preflight write probe')
        {
            throw "Write probe content mismatch (read back '$ProbeRead')"
        }
        Remove-Item -Path $ProbePath -Force -ErrorAction Stop
        Write-Host ("Write probe: OK ({0})" -f $PreFlightInventoryRoot) -ForegroundColor Green
    }
    catch
    {
        $ProbeError = $_.Exception.Message
        try { if (Test-Path $ProbePath) { Remove-Item -Path $ProbePath -Force -ErrorAction SilentlyContinue } }
        catch { Write-Verbose ("Probe cleanup failed at {0}: {1}" -f $ProbePath, $_.Exception.Message) }
        # A top-level throw does not stop the run under the default SilentlyContinue
        # preference, so stop here the way the -Service and -ObfuscationDictionary checks do.
        Write-Host ("ERROR: Pre-flight: cannot write to {0}: {1}. This usually means readonly directory, denied permissions, antivirus or DLP product blocking writes, or a stale handle. Verify the directory is writable and re-run." -f $PreFlightInventoryRoot, $ProbeError) -ForegroundColor Red
        exit 1
    }

    Write-Host "Pre-flight checks passed." -ForegroundColor Green
    Write-Host ""
}

# A direct run owns the health lists, so it starts them empty: a second run in
# the same session must not report the first run's failures. Under -RunAllSubs
# the wrapper (or its stream worker) empties them once at its own start and
# gathers every subscription's entries in them, so they are left alone here.
if (-not $RunAllSubs.IsPresent)
{
    $Global:CollectorFailures = @()
    $Global:MetricsFailedSubs = @()
    $Global:ConsumptionFailedSubs = @()
    $Global:ConsumptionRecordCount = 0
}

$Global:Runtime = Measure-Command -Expression {
    Variables
    RunInventorySetup

    $Global:PowerShellTranscriptFile = ($Global:DefaultPath + "Transcript_Log_" + $Global:ReportName + "_" + $Global:CurrentDateTime + ".txt")
    Start-Transcript -Path $Global:PowerShellTranscriptFile -UseMinimalHeader
}

# Reset, so a run whose processing step stops does not show the time of an earlier run in
# the same session.
$Global:ReportingRunTime = $null
try
{
    $Global:ReportingRunTime = Measure-Command -Expression {
        ExecuteInventoryProcessing
    }
}
finally
{
    try { Stop-Transcript }
    catch { }
}

FinalizeOutputs

# Without the inventory or a finished HTML report there is no report to compress (the zip
# step below then says so), so the run does not announce it.
$ReportInputsReady = -not $Global:HtmlReportFailed -and (Test-Path -LiteralPath $Global:JsonFile) -and (Test-Path -LiteralPath $Global:HtmlFile)
if ($ReportInputsReady)
{
    Write-Log -Message ("Compressing Resources Output: {0}" -f $Global:ZipOutputFile) -Severity 'Info'
}

if ($Obfuscate.IsPresent)
{
    $Global:DictionaryFile = ($DefaultPath + "ObfuscationDictionary_" + $Global:ReportName + "_" + $CurrentDateTime + ".json")

    $Dictionary = @{
        GeneratedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        ResourceIdMap = @{}
        ResourceNameMap = @{}
        SubscriptionMap = @{}
        ResourceGroupMap = @{}
        SubscriptionNameMap = @{}
        TagMap = @{}
        FreeTextMap = @{}
    }

    foreach ($key in $ResourceIdDictionary.Keys)
    {
        $Dictionary.ResourceIdMap[$ResourceIdDictionary[$key]] = $key
    }
    foreach ($key in $ResourceNameDictionary.Keys)
    {
        $Dictionary.ResourceNameMap[$ResourceNameDictionary[$key]] = $key
    }
    foreach ($key in $ResourceSubscriptionDictionary.Keys)
    {
        $Dictionary.SubscriptionMap[$ResourceSubscriptionDictionary[$key]] = $key
    }
    foreach ($key in $ResourceResourceGroupDictionary.Keys)
    {
        $Dictionary.ResourceGroupMap[$ResourceResourceGroupDictionary[$key]] = $key
    }

    foreach ($key in $ResourceSubscriptionDictionary.Keys)
    {
        $SubToken = $ResourceSubscriptionDictionary[$key]
        if ($Dictionary.SubscriptionNameMap.ContainsKey($SubToken)) { continue }
        $SubGuid = if ($key -match '(?i)/subscriptions/([^/]+)') { $Matches[1] } else { $null }
        if (-not [string]::IsNullOrEmpty($SubGuid))
        {
            $SubName = ($Global:Subscriptions | Where-Object { $_.id -eq $SubGuid } | Select-Object -First 1).name
            if (-not [string]::IsNullOrEmpty($SubName))
            {
                $Dictionary.SubscriptionNameMap[$SubToken] = $SubName
            }
        }
    }

    if ($null -ne $Global:TagValueDictionary)
    {
        foreach ($realValue in $Global:TagValueDictionary.Keys)
        {
            $Dictionary.TagMap[$Global:TagValueDictionary[$realValue]] = $realValue
        }
    }

    if ($null -ne $Global:FreeTextDictionary)
    {
        foreach ($realValue in $Global:FreeTextDictionary.Keys)
        {
            $Dictionary.FreeTextMap[$Global:FreeTextDictionary[$realValue]] = $realValue
        }
    }

    $Dictionary | ConvertTo-Json -depth 5 | Out-File $Global:DictionaryFile -Encoding utf8
    Write-Log -Message ("Obfuscation dictionary saved locally: {0}" -f $Global:DictionaryFile) -Severity 'Success'
    Write-Log -Message ("") -Severity 'Info'
    Write-Log -Message ("=== OBFUSCATION NOTICE ===") -Severity 'Warning'
    Write-Log -Message ("The following files remain LOCAL and should NOT be shared:") -Severity 'Warning'
    Write-Log -Message ("  - Dictionary: {0}" -f $Global:DictionaryFile) -Severity 'Warning'
    Write-Log -Message ("  - Transcript: {0}" -f $Global:PowerShellTranscriptFile) -Severity 'Warning'
    if (![string]::IsNullOrEmpty($Global:ErrorLogFile) -and (Test-Path -LiteralPath $Global:ErrorLogFile))
    {
        Write-Log -Message ("  - Error log:  {0}" -f $Global:ErrorLogFile) -Severity 'Warning'
    }
    if (![string]::IsNullOrEmpty($Global:DebugLogFile) -and (Test-Path -LiteralPath $Global:DebugLogFile))
    {
        Write-Log -Message ("  - Debug log:  {0}" -f $Global:DebugLogFile) -Severity 'Warning'
    }
    Write-Log -Message ("") -Severity 'Info'
    Write-Log -Message ("Partners may ask about obfuscated names (e.g. 'prod_a1b2c3d4-...'). Use the dictionary file to look up the real resource name and respond.") -Severity 'Info'
    Write-Log -Message ("Delete the dictionary and transcript when no longer needed for security.") -Severity 'Warning'
}

if ($SkipMetrics.IsPresent)
{
    @{ Metrics = @() } | ConvertTo-Json -depth 5 -compress | Out-File $Global:MetricsJsonFile -Encoding utf8
}
else
{
    $MetricsPattern = ('Metrics_{0}_{1}*.json' -f $Global:ReportName, $CurrentDateTime)
    $MetricsAny = @(Get-ChildItem -Path $DefaultPath -Filter $MetricsPattern -ErrorAction SilentlyContinue)
    if ($MetricsAny.Count -eq 0)
    {
        @{ Metrics = @() } | ConvertTo-Json -depth 5 -compress | Out-File $Global:MetricsJsonFile -Encoding utf8
    }
}

$ConsumptionCreated = Test-Path -Path $Global:ConsumptionFileCsv

$ConsumptionEmpty = $false
if ($ConsumptionCreated)
{
    try
    {
        $ConsumptionEmpty = ((Get-Item -Path $Global:ConsumptionFileCsv -ErrorAction Stop).Length -eq 0)
    }
    catch
    {
        $ConsumptionEmpty = $true
    }
}

if ($SkipConsumption.IsPresent -or !$ConsumptionCreated -or $ConsumptionEmpty)
{
    "InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId" | Out-File $Global:ConsumptionFileCsv -Encoding utf8
}

# Only JSON files named with this run's stamp go into the zip. With -OutputDirectory
# several runs can share one folder, and an earlier run's files there (its inventory,
# or its local-only dictionary) must not ship in this run's zip.
$JsonFiles = @(Get-ChildItem -Path $DefaultPath -Filter "*.json" | Where-Object { $_.Name -like "*_$($Global:CurrentDateTime)*" -and $_.Name -notlike "ObfuscationDictionary_*" -and $_.Name -notlike "Full_*" -and $_.Name -notlike "Heartbeat_*" -and $_.Name -notlike "DebugLog_*" -and $_.Name -notlike "ErrorLog_*" } | Select-Object -ExpandProperty FullName)

if ($Obfuscate.IsPresent)
{
    $DiagnosticsFile = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPath -ReportName $Global:ReportName -RunDateTime $Global:CurrentDateTime -Version $Global:Version -PhaseTimings $script:PhaseTimings -Obfuscated:$Obfuscate.IsPresent

    $ShareableExtras = @()
    if (-not [string]::IsNullOrEmpty($DiagnosticsFile) -and (Test-Path -LiteralPath $DiagnosticsFile)) { $ShareableExtras += $DiagnosticsFile }
    $CompressionOutput = @{
        Path = @($Global:HtmlFile, $Global:ConsumptionFileCsv) + $ShareableExtras + $JsonFiles
        CompressionLevel = 'Fastest'
        DestinationPath = $Global:ZipOutputFile
    }
}
else
{
    $DiagnosticsFile = Write-RdaShareableDiagnosticsLog -DefaultPath $DefaultPath -ReportName $Global:ReportName -RunDateTime $Global:CurrentDateTime -Version $Global:Version -PhaseTimings $script:PhaseTimings
    $ShareableExtras = @()
    if (-not [string]::IsNullOrEmpty($DiagnosticsFile) -and (Test-Path -LiteralPath $DiagnosticsFile)) { $ShareableExtras += $DiagnosticsFile }

    $CompressionOutput = @{
        Path = @($Global:HtmlFile, $Global:ConsumptionFileCsv) + $ShareableExtras + $JsonFiles
        CompressionLevel = 'Fastest'
        DestinationPath = $Global:ZipOutputFile
    }
}

# Only this call finishing makes the zip this run's report: a file at the path can be
# one that was there before (Compress-RdaReportArchive then refuses to overwrite it).
# Compress-RdaReportArchive stops on any error and writes to a temp file that it moves
# into place only when done; -ErrorAction Stop keeps a stand-in for it to the same rule.
$ZipWritten = $true
try
{
    if ($ReportInputsReady) { Compress-RdaReportArchive @CompressionOutput -ErrorAction Stop } else { $ZipWritten = $false }
}
catch
{
    $ZipWritten = $false
    # Write-Log, not Write-Error: the script's 'silentlycontinue' preference hides Write-Error.
    Write-Log -Message ("Error Compressing Output File: {0}: {1}" -f $Global:ZipOutputFile, $_.Exception.Message) -Severity 'Error'
    # Only this run's files: in a reused output folder the zip's '*.json' input also matches
    # files of earlier runs, which may hold real names.
    $ManualZipFiles = @(Resolve-Path -Path $CompressionOutput.Path -ErrorAction SilentlyContinue | ForEach-Object { $_.ProviderPath } | Where-Object { (Split-Path -Leaf $_) -like "*$($Global:CurrentDateTime)*" } | Select-Object -Unique)
    Write-Log -Message ("Please zip the output files manually: {0}" -f ($ManualZipFiles -join ', ')) -Severity 'Error'
    if ($Obfuscate.IsPresent)
    {
        Write-Log -Message ("Add only those files: the obfuscation dictionary, the transcript and the logs hold real names and stay local.") -Severity 'Error'
    }
    # No removal here: Compress-RdaReportArchive moves its zip to the final name only as its
    # last step, so after a failure a file at that name is never this call's; it is left
    # alone and, like one that was there before, not named as this run's report.
}

if (-not $ReportInputsReady)
{
    Write-Log -Message ("There is no report to zip: the inventory or the HTML report was not written. See the errors above.") -Severity 'Error'
}
$ZipWritten = $ZipWritten -and (Test-Path -LiteralPath $Global:ZipOutputFile)

if ($ZipWritten)
{
    if ($Obfuscate.IsPresent)
    {
        Write-Log -Message ('Obfuscate mode: transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
        Write-Log -Message ("The ZIP file is safe to share with AWS or partners.") -Severity 'Success'
    }
    else
    {
        Write-Log -Message ('Transcript log excluded from zip (kept locally for debug)') -Severity 'Info'
    }
}
# The times are shown as a success only when the run wrote its report.
$TimeSeverity = if ($ZipWritten) { 'Success' } else { 'Info' }

Write-Log -Message ("Execution Time: {0}" -f $Runtime) -Severity $TimeSeverity
Write-Log -Message ("Reporting Time: {0}" -f $(if ($null -ne $ReportingRunTime) { $ReportingRunTime } else { 'not measured, the processing step stopped' })) -Severity $TimeSeverity
# A direct run reaches this point even when it wrote no report (collection stopped,
# or the HTML report or the zip failed), so it must not end as a success. Under
# -RunAllSubs the exit code is left alone: the wrapper treats any non-zero exit as a
# failed subscription and checks each subscription's zip itself.
if (-not $RunAllSubs.IsPresent -and -not $ZipWritten)
{
    Write-Log -Message ("No report was written: {0} was not created. See the errors above, fix the cause and re-run." -f $Global:ZipOutputFile) -Severity 'Error'
    exit 2
}

# A run can reach this line with no zip: when a step above failed, its throw does not stop
# the script under 'silentlycontinue'. So name the zip only when this run wrote it.
if ($ZipWritten)
{
    Write-Log -Message ("Reporting Data File: {0}" -f $Global:ZipOutputFile) -Severity 'Success'
}
else
{
    Write-Log -Message ("No report was written: {0} was not created. See the errors above, fix the cause and re-run." -f $Global:ZipOutputFile) -Severity 'Error'
}

# Direct runs only (the wrapper prints its own): subscriptions the up-front
# consumption data check passed with no usage values, and subscriptions the
# up-front role check skipped.
Write-NoUsageSummary -ConsumptionResult $script:ConsumptionCheckResult
Write-SkippedSubscriptionSummary -Decision $script:AccessSkipped

# A direct run that lost a collector still writes the report and zip, then exits 4.
# Under -RunAllSubs the wrapper treats any non-zero exit as a failed subscription and
# reports collector failures through its own exit code, so this is skipped there.
# The zip check keeps 4 to runs that produced their report: Compress-Archive writes no
# zip when the HTML report is missing.
$CollectorFailureCount = @(@($script:CollectorFailuresThisRun) | Where-Object { $null -ne $_ }).Count
if (-not $RunAllSubs.IsPresent -and $CollectorFailureCount -gt 0 -and (Test-Path -LiteralPath $Global:ZipOutputFile)) { exit 4 }
