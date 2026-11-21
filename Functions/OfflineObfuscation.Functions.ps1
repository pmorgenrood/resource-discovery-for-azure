#Requires -Version 7.0
# =============================================================================
# OfflineObfuscation.Functions.ps1
#
# The parts of Protect-RdaReport.ps1 (mask a finished plain report offline) that
# are not the live run's own code. The token loop, the row, metric and
# consumption masking and the dictionary are the live run's functions, loaded
# from ResourceInventory.ps1 and Extension/Metrics.ps1 (Get-RdaLiveMaskFunction),
# so an offline mask and a live -Obfuscate run mask the same way.
#
# What is here:
#   - a JSON reader that keeps every string as written (ConvertFrom-Json turns
#     ISO date strings into dates, which would change the text written back);
#   - the collector field rules: the fields a collector writes differently under
#     -Obfuscate, read from the plain value. Tests/ProtectRdaReport.Tests.ps1
#     reads every collector and fails when a collector masks a field this table
#     does not name, so a collector change cannot leave a field unmasked here;
#   - the checks that refuse: a report that is already masked, a file that cannot
#     be read whole, and any real value left in the output (Test-RdaMaskedOutputLeak).
# Definitions only - no top-level code.
# =============================================================================

# Read a JSON file with every string kept as text. Objects become hashtables (the
# collectors' row type, which the live row masking expects), or [pscustomobject]
# with -AsObject (key order kept). Numbers keep their JSON type: whole numbers are
# [long], others [double]. A file that is not one complete JSON value throws.
function Read-RdaJsonFile
{
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$AsObject)

    $Text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    return (ConvertFrom-RdaJsonText -Text $Text -AsObject:$AsObject)
}

# -OrderedRoot: the root object as an [ordered] dictionary (its key order kept),
# its values read as without it.
function ConvertFrom-RdaJsonText
{
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text, [switch]$AsObject, [switch]$OrderedRoot)

    # Strict JSON only, as ConvertTo-Json writes it: no comment, no single quote, no bare key,
    # no trailing comma, no NaN or Infinity (Newtonsoft alone accepts all of these).
    $Strict = [System.Text.Json.JsonDocumentOptions]::new()
    $Strict.MaxDepth = 1024
    [System.Text.Json.JsonDocument]::Parse($Text, $Strict).Dispose()
    $Reader = [Newtonsoft.Json.JsonTextReader]::new([System.IO.StringReader]::new($Text))
    $Reader.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
    $Reader.FloatParseHandling = [Newtonsoft.Json.FloatParseHandling]::Double
    try
    {
        # A key given twice is an error, not the last one kept.
        $Load = [Newtonsoft.Json.Linq.JsonLoadSettings]::new()
        $Load.DuplicatePropertyNameHandling = [Newtonsoft.Json.Linq.DuplicatePropertyNameHandling]::Error
        $Token = [Newtonsoft.Json.Linq.JToken]::ReadFrom($Reader, $Load)
        # Anything after the value (a second value, a cut-off tail) is an error.
        if ($Reader.Read()) { throw 'more text after the JSON value' }
    }
    finally
    {
        $Reader.Close()
    }
    if ($OrderedRoot)
    {
        if ($Token.get_Type() -ne 'Object') { throw 'not a JSON object' }
        $Root = [ordered]@{}
        foreach ($Prop in $Token.Properties()) { if ($Root.Contains($Prop.Name)) { throw 'a key twice (in any case)' }; $Root[$Prop.Name] = ConvertFrom-RdaJToken -Token $Prop.Value -AsObject:$AsObject }
        return $Root
    }
    return (ConvertFrom-RdaJToken -Token $Token -AsObject:$AsObject)
}

function ConvertFrom-RdaJToken
{
    param($Token, [switch]$AsObject)

    # get_Type(), not .Type: PowerShell reads .Type on a JObject as its key 'Type'.
    switch ($Token.get_Type())
    {
        'Object'
        {
            if ($AsObject)
            {
                $Out = [ordered]@{}
                foreach ($Prop in $Token.Properties()) { if ($Out.Contains($Prop.Name)) { throw 'a key twice (in any case)' }; $Out[$Prop.Name] = ConvertFrom-RdaJToken -Token $Prop.Value -AsObject }
                return [pscustomobject]$Out
            }
            # A key given twice, in any case, would be merged into one by the hashtable (no run
            # writes one), so it is refused.
            $Out = @{}
            foreach ($Prop in $Token.Properties()) { if ($Out.ContainsKey($Prop.Name)) { throw 'a key twice (in any case)' }; $Out[$Prop.Name] = ConvertFrom-RdaJToken -Token $Prop.Value }
            return $Out
        }
        'Array'
        {
            $List = [System.Collections.Generic.List[object]]::new()
            foreach ($Item in $Token) { $List.Add((ConvertFrom-RdaJToken -Token $Item -AsObject:$AsObject)) }
            # The comma keeps a list of one (or none) a list.
            return , $List.ToArray()
        }
        'Integer' { return [long]$Token.Value }
        'Float' { return [double]$Token.Value }
        'String' { return [string]$Token.Value }
        'Boolean' { return [bool]$Token.Value }
        'Null' { return $null }
        default { throw ('JSON value of type {0} is not read' -f $Token.get_Type()) }
    }
}

# Load the live run's masking functions from the tool's own scripts into the
# caller's scope (by their definitions, not a copy), so the offline mask runs the
# same code a -Obfuscate run runs. Returns the script blocks to dot-source.
function Get-RdaLiveMaskFunction
{
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $Wanted = [ordered]@{
        'ResourceInventory.ps1' = @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken', 'Get-ObfuscationSubscriptionIndex', 'Test-RdaTenantScopeIdMaskable', 'Get-ObfuscatedResourceId', 'Test-ObfuscatedIdShape', 'New-ObfuscatedRowIdWithoutId', 'Add-RdaObfuscationToken', 'Protect-RdaCollectorRow', 'Protect-RdaUsageRow', 'Get-RdaObfuscationDictionary')
        'Extension/Metrics.ps1' = @('Protect-RdaMetricRecord')
    }
    $Blocks = [System.Collections.Generic.List[scriptblock]]::new()
    foreach ($File in $Wanted.Keys)
    {
        $Path = Join-Path $RepoRoot $File
        $Tokens = $null; $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
        if (@($Errors).Count -gt 0) { throw ('{0} does not parse.' -f $File) }
        foreach ($Name in $Wanted[$File])
        {
            # Top-level definitions only: a nested function of the same name is not the one the run calls.
            $Found = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $Name })
            if ($Found.Count -ne 1) { throw ('{0} defines {1} {2} time(s); expected once.' -f $File, $Name, $Found.Count) }
            $Blocks.Add([scriptblock]::Create($Found[0].Extent.Text))
        }
    }
    return $Blocks.ToArray()
}

# The collector fields a -Obfuscate run writes differently, by inventory section
# (the collector file's name) and field, with how the masked value follows from the
# plain one. The kinds:
#   Value      always this value (the collector writes it whatever Azure sent).
#   FreeText   Protect-FreeTextValue of the plain text.
#   IdRef      the plain value is a full resource id: the id's masked form when the
#              run knows the id, else 'obfuscated'; an empty value stays as it is.
#              NoneIs: the plain value that means "no id" and the masked value for it.
#   NameOfId   the name token of the id in the row's field IdField (plain value),
#              else 'obfuscated'; empty when that id is empty.
#   ParentRef  the masked id of the row's own id cut at Cut, else 'obfuscated'.
#   PoolRef    SQLDB ElasticPoolID: 'None' stays; else the masked id of the pool
#              under the database's server, else 'obfuscated'.
#   NameRef    the plain value is the name of a resource in one of Sections: the
#              masked id of the one row of that name in the subscription (SameGroup:
#              in the resource group), else 'obfuscated' (Resolve-RdaNameRef).
#              Null/empty: EmptyIs, or kept when EmptyIs is not given.
#   PublicIpRef / WafList  the two fields whose plain value needs one more step (below).
# Within: the field is one of the records the row holds in that list field.
# Target: the section whose rows the id points at. When the plain run's collector of
# that section failed, the report lacks rows the run's pull held, so the ids such a
# field points at are taken as pulled (Get-RdaReferencedId), as the run had them.
# Each line names the collector line it follows (collector file and the masked branch).
function Get-RdaOfflineFieldRule
{
    @(
        @{ Section = 'DataExplorerCluster'; Field = 'StateReason'; Kind = 'Value'; Value = $null }
        @{ Section = 'VMDisk'; Field = 'AssociatedResource'; Kind = 'NameRef'; Sections = @('VirtualMachines'); Also = @('VMSS') }
        @{ Section = 'ComputeSnapshots'; Field = 'SourceResourceId'; Kind = 'IdRef'; Target = 'VMDisk' }
        @{ Section = 'NetApp'; Field = 'NetAppAccount'; Kind = 'Value'; Value = 'obfuscated' }
        @{ Section = 'NetApp'; Field = 'CapacityPool'; Kind = 'Value'; Value = 'obfuscated' }
        @{ Section = 'NetApp'; Field = 'Volume'; Kind = 'Value'; Value = 'obfuscated' }
        @{ Section = 'ExpressRoute'; Field = 'Provider'; Kind = 'Value'; Value = 'obfuscated' }
        @{ Section = 'PublicIP'; Field = 'AssociatedResource'; Kind = 'PublicIpRef' }
        @{ Section = 'VirtualWAN'; Field = 'HUBName'; Kind = 'Value'; Value = 'obfuscated' }
        @{ Section = 'VirtualWAN'; Field = 'LinkProviderName'; Kind = 'Value'; Value = 'obfuscated' }
        @{ Section = 'AppServices'; Field = 'SiteProperties'; Kind = 'Walk' }
        @{ Section = 'AutomationAcc'; Field = 'AutomationAccountName'; Kind = 'FreeText' }
        @{ Section = 'AutomationAcc'; Field = 'RunbookName'; Kind = 'FreeText' }
        @{ Section = 'AutomationAcc'; Field = 'RunbookDescription'; Kind = 'FreeText' }
        @{ Section = 'Frontdoor'; Field = 'WebApplicationFirewall'; Kind = 'WafList' }
        @{ Section = 'AvSet'; Field = 'VirtualMachines'; Kind = 'NameRef'; Sections = @('VirtualMachines'); SameGroup = $true }
        @{ Section = 'AVD'; Field = 'HostId'; Kind = 'IdRef'; Target = 'VirtualMachines' }
        @{ Section = 'AVD'; Field = 'Hostname'; Kind = 'NameOfId'; IdField = 'HostId' }
        @{ Section = 'ARCServers'; Field = 'DomainName'; Kind = 'Value'; Value = 'obfuscated' }
        @{ Section = 'AppServices'; Field = 'ServerFarmId'; Kind = 'IdRef'; Target = 'AppServicePlan' }
        @{ Section = 'ARO'; Field = 'Clusters'; Kind = 'Value'; Value = 'obfuscated' }
        @{ Section = 'VirtualMachines'; Field = 'Set'; Kind = 'IdRef'; Target = 'VMSS' }
        @{ Section = 'CloudServices'; Field = 'RoleName'; Kind = 'FreeText'; Within = 'Roles' }
        @{ Section = 'SQLMI'; Field = 'InstancePoolName'; Kind = 'IdRef' }
        @{ Section = 'Purview'; Field = 'CreatedBy'; Kind = 'FreeText' }
        @{ Section = 'Purview'; Field = 'FriendlyName'; Kind = 'FreeText' }
        @{ Section = 'SQLVM'; Field = 'ParentVirtualMachine'; Kind = 'IdRef'; NoneIs = @('None', 'obfuscated'); Target = 'VirtualMachines' }
        @{ Section = 'SQLMIDB'; Field = 'ManagedInstance'; Kind = 'ParentRef'; Cut = '/databases/'; Target = 'SQLMI' }
        @{ Section = 'SQLDB'; Field = 'DatabaseServer'; Kind = 'ParentRef'; Cut = '/databases/'; Target = 'SQLSERVER' }
        @{ Section = 'SQLDB'; Field = 'ElasticPoolID'; Kind = 'PoolRef'; Target = 'SQLPOOL' }
        @{ Section = 'IOTHubs'; Field = 'EventsPath'; Kind = 'FreeText' }
        @{ Section = 'IOTHubs'; Field = 'HostName'; Kind = 'FreeText' }
        @{ Section = 'Databricks'; Field = 'StorageAccount'; Kind = 'Value'; Value = 'obfuscated' }
        @{ Section = 'MachineLearning'; Field = 'StorageAccount'; Kind = 'NameRef'; Sections = @('StorageAcc'); EmptyIs = 'obfuscated' }
        @{ Section = 'MachineLearning'; Field = 'KeyVault'; Kind = 'NameRef'; Sections = @('Vault'); EmptyIs = 'obfuscated' }
        # An insights name is unique only in its group, and the workspace's may be in another
        # subscription: the plain name cannot prove which one, so it is always 'obfuscated'.
        @{ Section = 'MachineLearning'; Field = 'ApplicationInsight'; Kind = 'Value'; Value = 'obfuscated' }
        @{ Section = 'MachineLearning'; Field = 'ContainerRegistry'; Kind = 'NameRef'; Sections = @('REGISTRIES'); EmptyIs = 'obfuscated' }
        @{ Section = 'MachineLearning'; Field = 'FriendlyName'; Kind = 'FreeText' }
        @{ Section = 'MachineLearning'; Field = 'Description'; Kind = 'FreeText' }
        @{ Section = 'Synapse'; Field = 'ManagedResourceGroup'; Kind = 'Value'; Value = 'obfuscated' }
        @{ Section = 'CONTAINER'; Field = 'ContainerName'; Kind = 'FreeText' }
        @{ Section = 'CONTAINER'; Field = 'ContainerImage'; Kind = 'FreeText' }
        @{ Section = 'CONTAINER'; Field = 'Command'; Kind = 'FreeText' }
        @{ Section = 'AKS'; Field = 'NodePoolName'; Kind = 'FreeText' }
        # VMSS.ps1 names an AKS cluster here, or a Service Fabric cluster no section holds:
        # only a scale set in an AKS node group (mc_) is taken to be an AKS cluster's.
        @{ Section = 'VMSS'; Field = 'AKS'; Kind = 'NameRef'; Sections = @('AKS'); GroupPrefix = 'mc_' }
    )
}

# The full id a rule field of $Row points at ($null when none): the plain value for
# IdRef, the row's own id cut for ParentRef, the pool under the row's server for PoolRef.
function Get-RdaReferencedId
{
    param([hashtable]$Rule, [hashtable]$Row)

    $V = [string]$Row[$Rule.Field]
    switch ($Rule.Kind)
    {
        'IdRef' { if ($null -ne $Rule.NoneIs -and $V -eq $Rule.NoneIs[0]) { return $null }; if ([string]::IsNullOrEmpty($V)) { return $null }; return $V }
        'ParentRef' { return (([string]$Row['ID']) -split [regex]::Escape($Rule.Cut))[0] }
        'PoolRef' { if ($V -in '', 'None') { return $null }; return ((([string]$Row['ID']) -split '/databases/')[0] + '/elasticpools/' + $V) }
    }
    return $null
}

# The rows of $Inventory's sections by lower-case Name, for NameRef: one entry per
# distinct row id (the AKS section has one row per node pool, all with the cluster's id).
# The subscription id and resource group of a row, read from its own id (a display
# name need not be unique across subscriptions); lower case.
function Get-RdaIdScope
{
    param([string]$Id)
    $Sub = if ($Id -match '(?i)^/subscriptions/([^/]+)') { $Matches[1].ToLowerInvariant() } else { '' }
    $Group = if ($Id -match '(?i)^/subscriptions/[^/]+/resourcegroups/([^/]+)') { $Matches[1].ToLowerInvariant() } else { '' }
    return [pscustomobject]@{ Subscription = $Sub; ResourceGroup = $Group }
}

function New-RdaNameIndex
{
    param($Inventory, [string[]]$Sections)

    $Index = @{}
    foreach ($Section in $Sections)
    {
        if (-not $Inventory.ContainsKey($Section)) { continue }
        foreach ($Row in @($Inventory[$Section]))
        {
            if ($Row -isnot [hashtable] -or [string]::IsNullOrEmpty([string]$Row['Name']) -or [string]::IsNullOrEmpty([string]$Row['ID'])) { continue }
            $Key = ([string]$Row['Name']).ToLowerInvariant()
            if (-not $Index.ContainsKey($Key)) { $Index[$Key] = [System.Collections.Generic.List[object]]::new() }
            if (-not @($Index[$Key] | Where-Object { $_.ID -ieq [string]$Row['ID'] }).Count)
            {
                $Scope = Get-RdaIdScope -Id ([string]$Row['ID'])
                $Index[$Key].Add([pscustomobject]@{ ID = [string]$Row['ID']; Subscription = $Scope.Subscription; ResourceGroup = $Scope.ResourceGroup })
            }
        }
    }
    return $Index
}

# The one row a name points at: the one row of that name in the referencing row's
# subscription (with -SameGroup, in its resource group: Azure keeps an availability
# set's VMs in the set's group). None or several: $null, and the caller writes
# 'obfuscated', as a run does for an id it does not know. A name that also names a
# row of $AlsoIndex (a disk's owner may be a scale set, whose name the plain field
# holds too) points at no one row either.
function Resolve-RdaNameRef
{
    param([hashtable]$NameIndex, [string]$Name, [string]$Subscription, [string]$ResourceGroup, [switch]$SameGroup, [hashtable]$AlsoIndex)

    $Key = $Name.ToLowerInvariant()
    $Candidates = @($NameIndex[$Key] | Where-Object { $null -ne $_ -and $_.Subscription -eq $Subscription -and (-not $SameGroup -or $_.ResourceGroup -eq $ResourceGroup) })
    if ($null -ne $AlsoIndex -and @($AlsoIndex[$Key] | Where-Object { $null -ne $_ -and $_.Subscription -eq $Subscription }).Count -gt 0) { return $null }
    if ($Candidates.Count -eq 1) { return $Candidates[0].ID }
    return $null
}

# The masked value of a full id the run may know: its masked form, else 'obfuscated'.
function Get-RdaKnownIdToken
{
    param([string]$Id)
    if (-not [string]::IsNullOrEmpty($Id) -and $ResourceIdDictionary.ContainsKey($Id)) { return $ResourceIdDictionary[$Id] }
    return 'obfuscated'
}

# Mask the collector fields of one plain row (a hashtable, changed in place), by
# the rules of its section. Run before Protect-RdaCollectorRow, while the row
# still holds its real id, subscription and resource group, as a collector does.
function Protect-RdaOfflineField
{
    param([hashtable]$Row, [object[]]$Rules, [hashtable]$NameIndexes)

    $Plain = @{}
    foreach ($Key in @($Row.Keys)) { $Plain[$Key] = $Row[$Key] }
    $RowScope = Get-RdaIdScope -Id ([string]$Plain['ID'])
    foreach ($Rule in $Rules)
    {
        $Field = $Rule.Field
        if ($Rule.Within)
        {
            # A field of the records a row holds in a list (a cloud service's roles).
            foreach ($Item in @($Row[$Rule.Within] | Where-Object { $_ -is [hashtable] -and $_.ContainsKey($Field) }))
            {
                if ($Rule.Kind -ne 'FreeText') { throw ('a field rule within {0} must be FreeText' -f $Rule.Within) }
                $Item[$Field] = Protect-FreeTextValue ([string]$Item[$Field])
            }
            continue
        }
        if (-not $Row.ContainsKey($Field)) { continue }
        $Value = $Plain[$Field]
        $Text = [string]$Value
        $Masked = switch ($Rule.Kind)
        {
            'Value' { $Rule.Value }
            'FreeText' { Protect-FreeTextValue $Text }
            # Every text value of the object masked part by part, as the collector masks it.
            'Walk' { , (Protect-SitePropertiesValue $Value) }
            'IdRef'
            {
                if ($null -ne $Rule.NoneIs -and $Text -eq $Rule.NoneIs[0]) { $Rule.NoneIs[1] }
                elseif ([string]::IsNullOrEmpty($Text)) { $Value }
                else { Get-RdaKnownIdToken -Id $Text }
            }
            'NameOfId'
            {
                $IdText = [string]$Plain[$Rule.IdField]
                if ([string]::IsNullOrEmpty($IdText)) { $Value }
                elseif ($null -ne $Global:ResourceNameDictionary -and $Global:ResourceNameDictionary.ContainsKey($IdText)) { $Global:ResourceNameDictionary[$IdText] }
                else { 'obfuscated' }
            }
            'ParentRef' { Get-RdaKnownIdToken -Id (([string]$Plain['ID']) -split [regex]::Escape($Rule.Cut))[0] }
            'PoolRef'
            {
                if ($Text -eq 'None') { 'None' }
                elseif ([string]::IsNullOrEmpty($Text)) { 'obfuscated' }
                else { Get-RdaKnownIdToken -Id ((([string]$Plain['ID']) -split '/databases/')[0] + '/elasticpools/' + $Text) }
            }
            'NameRef'
            {
                if ([string]::IsNullOrEmpty($Text)) { if ($Rule.ContainsKey('EmptyIs')) { $Rule.EmptyIs } else { $Value } }
                elseif ($Rule.GroupPrefix -and -not $RowScope.ResourceGroup.StartsWith($Rule.GroupPrefix)) { 'obfuscated' }
                else
                {
                    $Id = Resolve-RdaNameRef -NameIndex $NameIndexes[$Rule.Section + '.' + $Field] -Name $Text -Subscription $RowScope.Subscription -ResourceGroup $RowScope.ResourceGroup -SameGroup:([bool]$Rule.SameGroup) -AlsoIndex $NameIndexes[$Rule.Section + '.' + $Field + '.also']
                    Get-RdaKnownIdToken -Id $Id
                }
            }
            'PublicIpRef'
            {
                # PublicIP.ps1: an ipConfiguration id (a NIC's, a load balancer's and
                # the like) is a child id no run's dictionary holds, so it is always
                # 'obfuscated'; a NAT gateway id is the gateway's own; 'None' stays.
                $Type = [string]$Plain['AssociatedResourceType']
                if ($null -eq $Value) { $null }
                elseif ($Text -eq 'None' -and $Type -eq 'None') { 'None' }
                elseif ($Type -eq 'natgateways')
                {
                    $Id = Resolve-RdaNameRef -NameIndex $NameIndexes['PublicIP.AssociatedResource'] -Name $Text -Subscription $RowScope.Subscription -ResourceGroup $RowScope.ResourceGroup
                    Get-RdaKnownIdToken -Id $Id
                }
                else { 'obfuscated' }
            }
            'WafList'
            {
                # Frontdoor.ps1: 'False' (no policy read) and 'Unknown' stay; else one
                # name per policy, joined with ', ', and an optional count of the
                # endpoints without one. A policy is not an inventory row, so its
                # name is written 'obfuscated', as a run writes an id it does not know.
                if ($null -eq $Value -or $Text -in @('', 'False', 'Unknown')) { $Value }
                else
                {
                    $Tail = ''
                    $Names = $Text
                    if ($Text -match '^(.*?)( \(\d+ of \d+ endpoints without WAF\))$') { $Names = $Matches[1]; $Tail = $Matches[2] }
                    (@($Names -split ', ' | ForEach-Object { 'obfuscated' }) -join ', ') + $Tail
                }
            }
            default { throw ('unknown field rule kind {0}' -f $Rule.Kind) }
        }
        $Row[$Field] = $Masked
    }
}

# A token as -Obfuscate writes it, from the one pattern the reports and the page
# renderer share (Get-RdaObfuscationTokenPattern, Functions/AllSubHtmlSummary.Functions.ps1,
# which the caller loads), so a change to the token form is made in one place.
function Get-RdaTokenRegex
{
    if ($null -eq $script:RdaTokenRegex) { $script:RdaTokenRegex = '(?i)(?<![a-z0-9])' + (Get-RdaObfuscationTokenPattern) }
    return $script:RdaTokenRegex
}

# True when a report's inventory already holds masked values (ids, names, groups or
# subscriptions written as tokens), so it is not masked a second time.
function Test-RdaReportMasked
{
    param($Inventory)

    $TokenRegex = Get-RdaTokenRegex
    foreach ($Section in @($Inventory.Keys))
    {
        foreach ($Row in @($Inventory[$Section]))
        {
            if ($Row -isnot [hashtable]) { continue }
            foreach ($Field in 'ID', 'Name', 'ResourceGroup', 'Subscription')
            {
                $V = [string]$Row[$Field]
                if ($V -match $TokenRegex -or $V -match '^obfuscated(_|$)') { return $true }
            }
        }
    }
    return $false
}

# The real values a masked report must not hold, from the run's dictionaries (each
# real id's subscription, group and name parts, subscription and group names, tag
# values and free text) and from $ExtraValue (the plain values the field rules
# replaced, ids and GUIDs the plain report's other files hold).
function Get-RdaRealValueSet
{
    param([string[]]$ExtraValue = @())

    $Set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $Add = { param($V) if (-not [string]::IsNullOrWhiteSpace([string]$V)) { [void]$Set.Add(([string]$V).Trim()) } }
    foreach ($Map in @($Global:ResourceIdDictionary, $Global:ResourceNameDictionary, $Global:ResourceSubscriptionDictionary, $Global:ResourceResourceGroupDictionary))
    {
        if ($null -eq $Map) { continue }
        foreach ($Id in $Map.Keys)
        {
            $Parts = ([string]$Id).Split('/')
            & $Add $Id
            # A subscription-scope id: its subscription and group are real values. A
            # tenant-scope id ('/providers/<namespace>/<type>/<name>...', a reservation
            # or a management group) has no subscription or group; its names are real
            # values all the same. Any other key is taken whole only.
            if ($Parts.Count -ge 3 -and $Parts[1] -ieq 'subscriptions')
            {
                & $Add $Parts[2]
                if ($Parts.Count -gt 4 -and $Parts[3] -ieq 'resourcegroups') { & $Add $Parts[4] }
                $From = 3
            }
            elseif ($Parts.Count -ge 3 -and $Parts[0] -eq '' -and $Parts[1] -ieq 'providers') { $From = 1 }
            else { continue }
            # After each 'providers' come the namespace and the type (Azure's words),
            # then the name, then a child type and its name, and so on. Every name is
            # a real value, Azure's fixed name '$system' too: a run gives it a token.
            # Only a 'providers' in a word place (an odd segment: a path pairs a word
            # with a value from segment 1 on, as Get-ObfuscatedResourceId pairs it)
            # starts that count again; a name 'providers' (a storage account may be
            # named so) is a name.
            $Providers = -1
            for ($i = $From; $i -lt $Parts.Count; $i++)
            {
                if (($i % 2) -eq 1 -and $Parts[$i] -ieq 'providers') { $Providers = $i; continue }
                if ($Providers -ge 0 -and ($i - $Providers) -ge 3 -and (($i - $Providers) % 2) -eq 1) { & $Add $Parts[$i] }
            }
        }
    }
    foreach ($Map in @($Global:ObfuscationSubscriptionTokens, $Global:ObfuscationResourceGroupTokens))
    {
        if ($null -eq $Map) { continue }
        foreach ($K in $Map.Keys) { if ($K -ne '__none__') { & $Add $K } }
    }
    foreach ($Map in @($Global:TagValueDictionary, $Global:FreeTextDictionary))
    {
        if ($null -eq $Map) { continue }
        # A free-text part that is a number alone (a masked account id in an app's
        # siteProperties) is not looked for: the same digits are Azure's numbers elsewhere (a
        # quantity, a metric value). Every other real value of digits only still is.
        foreach ($K in $Map.Keys) { if (-not ([object]::ReferenceEquals($Map, $Global:FreeTextDictionary) -and $K -match '^[0-9]+$')) { & $Add $K } }
    }
    foreach ($V in $ExtraValue)
    {
        & $Add $V
        # A full id: its subscription, group and name parts are real values too; a
        # tenant-scope id ('/providers/...') has name parts only.
        $Parts = ([string]$V).Split('/')
        if ($Parts.Count -ge 3 -and $Parts[0] -eq '' -and $Parts[1] -ieq 'subscriptions')
        {
            & $Add $Parts[2]
            if ($Parts.Count -gt 4 -and $Parts[3] -ieq 'resourcegroups') { & $Add $Parts[4] }
            $From = 3
        }
        elseif ($Parts.Count -ge 3 -and $Parts[0] -eq '' -and $Parts[1] -ieq 'providers') { $From = 1 }
        else { continue }
        # Counted again only from a 'providers' in a word place, as above.
        $Providers = -1
        for ($i = $From; $i -lt $Parts.Count; $i++)
        {
            if (($i % 2) -eq 1 -and $Parts[$i] -ieq 'providers') { $Providers = $i; continue }
            if ($Providers -ge 0 -and ($i - $Providers) -ge 3 -and (($i - $Providers) % 2) -eq 1) { & $Add $Parts[$i] }
        }
    }
    return $Set
}

# $Text with its URL escapes decoded until nothing changes (at most 32 levels, as the leak scan).
function ConvertFrom-RdaUrlEscape([string]$Text)
{
    for ($i = 0; $i -lt 32 -and $Text.IndexOf('%') -ge 0; $i++) { $Next = [uri]::UnescapeDataString($Text); if ($Next -ceq $Text) { break }; $Text = $Next }
    return $Text
}

# The form of a full id inside a text: a '/subscriptions/...' path, or a tenant-scope path
# ('/providers/<namespace>/<type>/<name>...', a management group or a reservation, which has
# no subscription), each with or without its first '/'. The namespace is Azure's dotted
# word and the type has a name after it, so the word 'providers' alone, or a provider path
# with no name, is not an id. One pattern with both forms, so the '/providers/...' part of a
# subscription id is read in that id, not again as an id of its own. An id ends at
# whitespace, a quote or a mark no id holds (<>,;|[]{}?#&=).
function Get-RdaFullIdPattern
{
    return '(?i)(?<![A-Za-z0-9_])/?(?:subscriptions/[^\s"''<>,;|\[\]{}?#&=]+|providers/[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)+/[^/\s"''<>,;|\[\]{}?#&=]+/[^\s"''<>,;|\[\]{}?#&=]+)'
}

# Every full id (Get-RdaFullIdPattern: '/subscriptions/...' or '/providers/...', with or
# without its first '/', or URL-encoded) in any text inside $Value (strings, dictionaries and
# lists, walked with a stack, not by recursion: a metric series holds hundreds of numbers per
# record, which are skipped). An id also ends at a ')' with no '(' of its own (a group name
# may hold both).
function Get-RdaFullIdInValue
{
    param($Value)
    $Ids = [System.Collections.Generic.List[string]]::new()
    $Stack = [System.Collections.Generic.Stack[object]]::new()
    $Stack.Push($Value)
    $Pattern = Get-RdaFullIdPattern
    while ($Stack.Count -gt 0)
    {
        $V = $Stack.Pop()
        if ($V -is [string])
        {
            if ($V.IndexOf('subscriptions', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $V.IndexOf('providers', [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $V.IndexOf('%') -lt 0) { continue }
            # The text as is, and each level of it decoded until nothing changes (at most 32, as the leak scan).
            $Texts = [System.Collections.Generic.List[string]]::new()
            $Texts.Add($V)
            $D = $V
            for ($i = 0; $i -lt 32 -and $D.IndexOf('%') -ge 0; $i++) { $Next = [uri]::UnescapeDataString($D); if ($Next -ceq $D) { break }; $D = $Next; $Texts.Add($D) }
            foreach ($Text in $Texts)
            {
                foreach ($M in [regex]::Matches($Text, $Pattern))
                {
                    # A group name may hold '(' and ')'; a ')' with no '(' of its own closes the text around the id.
                    $Id = $M.Value
                    while ($Id.EndsWith(')') -and ($Id.Split('(').Count -lt $Id.Split(')').Count)) { $Id = $Id.Substring(0, $Id.Length - 1) }
                    $Ids.Add($(if ($Id.StartsWith('/')) { $Id } else { '/' + $Id }))
                }
            }
        }
        elseif ($V -is [System.Collections.IDictionary]) { foreach ($X in @($V.Keys) + @($V.Values)) { if ($X -is [System.Collections.IEnumerable]) { $Stack.Push($X) } } }
        elseif ($V -is [System.Collections.IEnumerable]) { foreach ($X in $V) { if ($X -is [System.Collections.IEnumerable]) { $Stack.Push($X) } } }
    }
    return $Ids.ToArray()
}

# The real values of $RealValue found in the masked output's text: in any file
# (JSON, CSV, HTML, logs) and in any file name. A value is looked for inside the
# text when it is long enough to be one thing only: a GUID, a value of 5 or more
# characters with a digit or one of - _ . / in it, or a value of 12 or more letters.
# A shorter value of letters only (such as 'linux' or 'basic', which are also
# Azure's own words) is looked for only where a masked report never holds Azure's
# words: the masked fields themselves, which Test-RdaMaskedSlot checks.
# shortcut: a short all-letter real name in a field a -Obfuscate run does not mask
# either is not found; upgrade by listing Azure's fixed words per field.
# Returns the files with a hit and the hit count, never the value.
# $Exempt: values the plain report holds in a field neither a run nor this script
# masks (a location, a SKU, a meter, a date): a real value equal to one of them is
# also Azure's own word there, so it is looked for only in the masked fields
# (Test-RdaMaskedSlot), where tag and free-text values are looked for too.
function Test-RdaMaskedOutputLeak
{
    param([Parameter(Mandatory = $true)][string[]]$Path, [Parameter(Mandatory = $true)]$RealValue, $Exempt)

    # A full id is not looked for whole: its subscription, group and name parts are
    # real values of their own, so a leaked id is found by its parts.
    $Strong = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($V in $RealValue)
    {
        if ($V.Length -lt 5 -or $V -eq 'obfuscated' -or $V -match '^/subscriptions/' -or -not ($V -match '[0-9\-_./]' -or $V.Length -ge 12)) { continue }
        if ($null -ne $Exempt -and $Exempt.Contains($V)) { continue }
        # The value as each kind of file writes it: as is, JSON-escaped (the quote and backslash,
        # and as ConvertTo-Json writes it: \n, \uXXXX), CSV-quoted, HTML-encoded, URL-decoded as
        # the scan's decoded reading reads it (so a URL form needs no entry), and form-encoded
        # (a space as '+').
        foreach ($Form in @($V, ($V.Replace('\', '\\').Replace('"', '\"')), $V.Replace('"', '""'), [System.Net.WebUtility]::HtmlEncode($V), (ConvertFrom-RdaUrlEscape $V), (ConvertTo-Json -InputObject $V -Compress).Trim('"'), $V.Replace(' ', '+')))
        {
            [void]$Strong.Add($Form)
        }
        if (Get-Command -Name 'ConvertTo-HtmlSafe' -ErrorAction SilentlyContinue) { [void]$Strong.Add((ConvertTo-HtmlSafe $V)) }
    }
    Initialize-RdaOfflineType
    $Values = [string[]]@($Strong)
    if ($null -ne $Exempt -and $Exempt.Count -gt 0 -and $Values.Count -gt 0)
    {
        # A real value inside one of those Azure words (a name 'ws2019' in an image
        # 'sql2019-ws2019') is there because Azure wrote it: it too is looked for in
        # the masked fields only.
        $InWords = [System.Collections.Generic.HashSet[int]]::new()
        $Probe = [RdaOfflineLeakScan]::new($Values)
        foreach ($Word in $Exempt) { foreach ($I in $Probe.Find($Word)) { [void]$InWords.Add($I) } }
        $Values = [string[]]@(for ($I = 0; $I -lt $Values.Count; $I++) { if (-not $InWords.Contains($I)) { $Values[$I] } })
    }
    $Scanner = [RdaOfflineLeakScan]::new($Values)
    $Hits = [System.Collections.Generic.List[object]]::new()
    foreach ($File in $Path)
    {
        # The file's path below the output folder counts too: a name a file is given is shared with it.
        $Count = $Scanner.CountFile($File) + $Scanner.CountText((Split-Path -Path $File -Leaf))
        if ($Count -gt 0) { $Hits.Add([pscustomobject]@{ File = (Split-Path -Path $File -Leaf); Hits = $Count }) }
    }
    return $Hits.ToArray()
}

# The C# parts: the leak scan, and the CRC-32 check of a zip member.
# The scan is an Aho-Corasick matcher (time linear in the text, whatever the number
# of values), because a report can hold millions of consumption rows and one or
# more real values per resource. The text is read as a stream and lower-cased (a
# one-line inventory can be large). Tokens are not taken out: a token is prod_ or
# nonprod_, a tool word and a new GUID, so it holds no real value the scan looks for.
function Initialize-RdaOfflineType
{
    if ('RdaOfflineLeakScan' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text.RegularExpressions;

public sealed class RdaOfflineLeakScan
{
    // Aho-Corasick: each node's outputs are the indexes of the values that end there
    // (its own and its fail chain's). A value counts only as a whole word: the
    // characters on both sides of it are not letters or digits, so 'dc-01' is not
    // found inside a GUID such as 'a1dc-01b2...'. A value of digits only is also not
    // found inside a number: a '.' or ',' beside it with a digit on its far side, and no
    // letter in the run of letters, digits, '.' and ',' around it ('0.1234567',
    // '1,1234567', '1234567.5'). Otherwise ('4500123.blob...', 'storage1.4500123.blob',
    // '4500123, failed', a sentence end) it is found.
    readonly List<Dictionary<char, int>> next = new List<Dictionary<char, int>>();
    readonly List<int> fail = new List<int>();
    readonly List<List<int>> outputs = new List<List<int>>();
    readonly string[] values;
    readonly bool[] digits;
    readonly int longest;

    public RdaOfflineLeakScan(string[] values)
    {
        // Lower-cased by code point (a letter outside the Basic Multilingual Plane too), as
        // Feed reads the text, so a value matches in any case.
        var low = new string[values.Length];
        for (int vi = 0; vi < values.Length; vi++) low[vi] = values[vi] == null ? null : Normalize(values[vi]);
        values = low;
        this.values = values;
        digits = new bool[values.Length];
        for (int vi = 0; vi < values.Length; vi++)
        {
            var v = values[vi];
            bool all = !string.IsNullOrEmpty(v);
            if (all) foreach (var c in v) if (c < '0' || c > '9') { all = false; break; }
            digits[vi] = all;
        }
        next.Add(new Dictionary<char, int>()); fail.Add(0); outputs.Add(new List<int>());
        for (int vi = 0; vi < values.Length; vi++)
        {
            var v = values[vi];
            if (string.IsNullOrEmpty(v)) continue;
            if (v.Length > longest) longest = v.Length;
            int s = 0;
            foreach (var c in v)
            {
                int t;
                if (!next[s].TryGetValue(c, out t)) { t = next.Count; next.Add(new Dictionary<char, int>()); fail.Add(0); outputs.Add(new List<int>()); next[s][c] = t; }
                s = t;
            }
            outputs[s].Add(vi);
        }
        var queue = new Queue<int>();
        foreach (var kv in next[0]) queue.Enqueue(kv.Value);
        while (queue.Count > 0)
        {
            int s = queue.Dequeue();
            foreach (var kv in next[s])
            {
                int t = kv.Value, f = fail[s];
                while (f > 0 && !next[f].ContainsKey(kv.Key)) f = fail[f];
                int g;
                fail[t] = (next[f].TryGetValue(kv.Key, out g) && g != t) ? g : 0;
                outputs[t].AddRange(outputs[fail[t]]);
                queue.Enqueue(t);
            }
        }
    }

    // A surrogate half is part of a letter or digit outside the Basic Multilingual Plane (Fold
    // turns any other pair into two U+FFFD), as the masking reads it.
    static bool Word(char c) { return char.IsLetterOrDigit(c) || char.IsSurrogate(c); }
    static bool Mark(char c) { return c == '.' || c == ','; }
    static bool Digit(char c) { return c >= '0' && c <= '9'; }

    static bool Letter(char c) { return Word(c) && !Digit(c); }

    // A digit-only value found as a whole word, waiting to know whether it stands inside a
    // number: a '.' or ',' beside it with a digit beyond, and no letter in the whole run of
    // letters, digits, '.' and ',' around it (0.4500123, 1,4500123.5). Then it is Azure's
    // number, not the value; with a letter in that run (storage1.4500123.blob, 4500123.25abc)
    // or no such mark it is found.
    sealed class Cand
    {
        public int Vi;
        public bool LeftMark;
        public bool LeftLetter;
        public Cand(int vi, bool leftMark, bool leftLetter) { Vi = vi; LeftMark = leftMark; LeftLetter = leftLetter; }
    }

    // Runs the text through the matcher. found receives the index of each value
    // found as a whole word (null: only counted). The last 'longest + 2' characters
    // are kept to read the two before a match, so the memory is fixed.
    sealed class Run
    {
        public int State;
        public bool Held;
        public char High;
        public long Hits;
        public readonly char[] Ring;
        public long Position;
        // The last letter and the last character that is none of letter, digit, '.', ','.
        public long LastLetter = -1, LastBreak = -1;
        // Matches that ended on the character before.
        public List<Cand> Pending = new List<Cand>();
        // Digit-only matches followed by '.' or ',': is the next character a digit?
        public List<Cand> AfterMark = new List<Cand>();
        // Digit-only matches beside a number's mark: does a letter come before the run ends?
        public List<Cand> Watch = new List<Cand>();
        public Run(int size) { Ring = new char[size]; }

        // The run as it stands, its hits not counted again: a new decoding level starts from
        // it, so the words and numbers that began before the escape read as they did.
        public Run Snapshot()
        {
            var c = new Run(Ring.Length);
            Array.Copy(Ring, c.Ring, Ring.Length);
            c.State = State; c.Held = Held; c.High = High; c.Position = Position;
            c.LastLetter = LastLetter; c.LastBreak = LastBreak;
            c.Pending = new List<Cand>(Pending); c.AfterMark = new List<Cand>(AfterMark); c.Watch = new List<Cand>(Watch);
            return c;
        }
    }

    static void Hit(Run r, Cand k, HashSet<int> found) { r.Hits++; if (found != null) found.Add(k.Vi); }

    internal static int HexValue(char c)
    {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    // The text is read as written (one run), and with its URL escapes decoded level by level,
    // as [uri]::UnescapeDataString decodes one level, up to MaxLevels levels: each level has
    // its own run, so a value is found at whichever level it reads plain (a real value after
    // a literal '%' can read plain at one level and be decoded away at the next).
    internal const int MaxLevels = 32;

    void Feed(Run r, char raw, HashSet<int> found) { Fold(r, raw, found); }

    // The call's result set, shared by every level's run.
    sealed class Shared { public HashSet<int> Found; }

    // One level of URL decoding, streamed: '%XX' of an ASCII byte is that character; the
    // escapes of one valid UTF-8 character (strict: no overlong form, no surrogate, no byte
    // over F4) are that character; anything else stays as written, as UnescapeDataString
    // leaves it, so a deeper level can still decode it (%C3%25A9 is %C3%A9 one level down).
    sealed class UrlStage
    {
        readonly RdaOfflineLeakScan owner;
        readonly Shared shared;
        readonly int level;
        internal Run Run;
        UrlStage next;
        readonly System.Text.StringBuilder esc = new System.Text.StringBuilder(3);
        readonly List<byte> bytes = new List<byte>(4);
        readonly System.Text.StringBuilder bytesText = new System.Text.StringBuilder(12);
        int need;
        // This level's output not yet known to need the next level: a '%' and up to two
        // characters after it (pend), and this level's run as it stood before that '%'
        // (beforePercent), from which a new next level starts.
        readonly System.Text.StringBuilder pend = new System.Text.StringBuilder(3);
        Run beforePercent;
        static readonly System.Text.Encoding Strict = new System.Text.UTF8Encoding(false, true);

        public UrlStage(RdaOfflineLeakScan owner, Shared shared, int level)
        {
            this.owner = owner; this.shared = shared; this.level = level;
            Run = new Run(owner.longest + 3);
        }

        internal IEnumerable<UrlStage> Chain() { for (var st = this; st != null; st = st.next) yield return st; }

        // Each character this level writes is matched at this level, and goes on to the
        // next level, made only when this level writes an escape ('%' and two hex digits).
        void emit(char c)
        {
            if (next == null && c == '%' && level < MaxLevels - 1) beforePercent = Run.Snapshot();
            owner.Fold(Run, c, shared.Found);
            if (next != null) { next.Put(c); return; }
            if (level < MaxLevels - 1) Track(c);
        }

        void Track(char c)
        {
            if (pend.Length == 0)
            {
                if (c == '%') pend.Append(c);
                return;
            }
            pend.Append(c);
            if (HexValue(c) < 0)
            {
                // Not an escape: the '%' is text; a '%' that ended it may start the next one.
                pend.Clear();
                if (c == '%') pend.Append(c);
                return;
            }
            if (pend.Length < 3) return;
            next = new UrlStage(owner, shared, level + 1);
            next.Run = beforePercent;
            beforePercent = null;
            foreach (var ch in pend.ToString()) next.Put(ch);
            pend.Clear();
        }

        // An escape that is no character stays as written.
        void Undecodable(string text) { foreach (var h in text) emit(h); }

        public void Put(char c)
        {
            if (esc.Length == 0)
            {
                if (c == '%') { esc.Append(c); return; }
                FlushBytes();
                emit(c);
                return;
            }
            if (HexValue(c) >= 0 && esc.Length == 1) { esc.Append(c); return; }
            if (HexValue(c) >= 0 && esc.Length == 2)
            {
                string text = esc.ToString() + c;
                int b = HexValue(esc[1]) * 16 + HexValue(c);
                esc.Clear();
                Byte(b, text);
                return;
            }
            // Not an escape: what was held is text.
            FlushBytes();
            var held = esc.ToString();
            esc.Clear();
            foreach (var h in held) emit(h);
            Put(c);
        }

        void Byte(int b, string text)
        {
            if (need > 0)
            {
                if (b >= 0x80 && b < 0xC0)
                {
                    bytes.Add((byte)b); bytesText.Append(text);
                    if (--need == 0)
                    {
                        string decoded = null;
                        try { decoded = Strict.GetString(bytes.ToArray()); } catch (System.Text.DecoderFallbackException) { }
                        var raw = bytesText.ToString();
                        bytes.Clear(); bytesText.Clear();
                        if (decoded == null) Undecodable(raw); else foreach (var ch in decoded) emit(ch);
                    }
                    return;
                }
                FlushBytes();
            }
            if (b < 0x80) { emit((char)b); return; }
            int n = b >= 0xC2 && b <= 0xDF ? 1 : b >= 0xE0 && b <= 0xEF ? 2 : b >= 0xF0 && b <= 0xF4 ? 3 : -1;
            if (n < 0) { Undecodable(text); return; }
            need = n; bytes.Add((byte)b); bytesText.Append(text);
        }

        // A UTF-8 character cut short is no character: its escapes stay as written.
        void FlushBytes()
        {
            if (bytes.Count == 0) return;
            var raw = bytesText.ToString();
            need = 0; bytes.Clear(); bytesText.Clear();
            Undecodable(raw);
        }

        // Flushes this level, then the next, then ends this level's run.
        public void End()
        {
            FlushBytes();
            var held = esc.ToString();
            esc.Clear();
            foreach (var h in held) emit(h);
            if (next != null) next.End();
            owner.End(Run, shared.Found);
        }
    }

    // Lower-cases by code point, as Normalize does the values: a surrogate pair is held
    // until its second half comes; a letter or digit outside the Basic Multilingual Plane is
    // lower-cased as one letter, any other (a symbol) reads as two non-word characters.
    void Fold(Run r, char raw, HashSet<int> found)
    {
        if (r.Held)
        {
            r.Held = false;
            if (char.IsLowSurrogate(raw))
            {
                foreach (var lc in Pair(r.High, raw)) Step(r, lc, found);
                return;
            }
            Step(r, r.High, found);
        }
        if (char.IsHighSurrogate(raw)) { r.Held = true; r.High = raw; return; }
        Step(r, char.ToLowerInvariant(raw), found);
    }

    static string Pair(char high, char low)
    {
        var p = new string(new[] { high, low });
        return char.IsLetterOrDigit(p, 0) ? p.ToLowerInvariant() : "\uFFFD\uFFFD";
    }

    // A value read as Fold reads the text.
    static string Normalize(string v)
    {
        var sb = new System.Text.StringBuilder(v.Length);
        for (int i = 0; i < v.Length; i++)
        {
            if (char.IsHighSurrogate(v[i]) && i + 1 < v.Length && char.IsLowSurrogate(v[i + 1])) { sb.Append(Pair(v[i], v[i + 1])); i++; }
            else sb.Append(char.ToLowerInvariant(v[i]));
        }
        return sb.ToString();
    }

    void Step(Run r, char c, HashSet<int> found)
    {
        if (r.Watch.Count > 0)
        {
            var keep = new List<Cand>();
            foreach (var k in r.Watch) { if (Letter(c)) Hit(r, k, found); else if (Digit(c) || Mark(c)) keep.Add(k); }
            r.Watch = keep;
        }
        if (r.AfterMark.Count > 0)
        {
            foreach (var k in r.AfterMark)
            {
                if (Digit(c)) { if (k.LeftLetter) Hit(r, k, found); else r.Watch.Add(k); }
                else if (Letter(c) || !k.LeftMark || k.LeftLetter) Hit(r, k, found);
            }
            r.AfterMark = new List<Cand>();
        }
        if (r.Pending.Count > 0)
        {
            foreach (var k in r.Pending)
            {
                // A whole word only: a letter or digit after it is part of a longer word.
                if (Word(c)) continue;
                if (!digits[k.Vi]) { Hit(r, k, found); continue; }
                if (Mark(c)) { r.AfterMark.Add(k); continue; }
                if (!k.LeftMark || k.LeftLetter) Hit(r, k, found);
            }
            r.Pending = new List<Cand>();
        }
        if (Letter(c)) r.LastLetter = r.Position;
        else if (!Digit(c) && !Mark(c)) r.LastBreak = r.Position;
        r.Ring[r.Position % r.Ring.Length] = c;
        int t;
        while (r.State > 0 && !next[r.State].ContainsKey(c)) r.State = fail[r.State];
        r.State = next[r.State].TryGetValue(c, out t) ? t : 0;
        foreach (var vi in outputs[r.State])
        {
            long start = r.Position - values[vi].Length + 1;
            if (start > 0 && Word(r.Ring[(start - 1) % r.Ring.Length])) continue;
            bool leftMark = digits[vi] && start >= 2 && Mark(r.Ring[(start - 1) % r.Ring.Length]) && Digit(r.Ring[(start - 2) % r.Ring.Length]);
            r.Pending.Add(new Cand(vi, leftMark, r.LastLetter > r.LastBreak));
        }
        r.Position++;
    }

    void End(Run r, HashSet<int> found)
    {
        if (r.Held) { r.Held = false; Step(r, r.High, found); }
        // A digit-only value watched to the end stood inside a number with no letter.
        foreach (var k in r.Pending) if (!digits[k.Vi] || !k.LeftMark || k.LeftLetter) Hit(r, k, found);
        foreach (var k in r.AfterMark) if (!k.LeftMark || k.LeftLetter) Hit(r, k, found);
        r.Pending = new List<Cand>(); r.AfterMark = new List<Cand>(); r.Watch = new List<Cand>();
    }

    // Reads text as written and decoded at every level; the hits of every reading.
    long Read(IEnumerable<char> text, HashSet<int> found)
    {
        var plain = new Run(longest + 3);
        var shared = new Shared { Found = found };
        var decoded = new UrlStage(this, shared, 0);
        foreach (var c in text) { Feed(plain, c, found); decoded.Put(c); }
        End(plain, found);
        decoded.End();
        long hits = plain.Hits;
        foreach (var st in decoded.Chain()) hits += st.Run.Hits;
        return hits;
    }

    public long CountText(string text) { return Read(text, null); }

    // The values found in text as whole words.
    public int[] Find(string text)
    {
        var found = new HashSet<int>();
        Read(text, found);
        return new List<int>(found).ToArray();
    }

    static IEnumerable<char> FileChars(string path)
    {
        var buf = new char[1 << 16];
        using (var reader = new StreamReader(path, true))
        {
            int n;
            while ((n = reader.Read(buf, 0, buf.Length)) > 0) for (int i = 0; i < n; i++) yield return buf[i];
        }
    }

    // The file as a stream of characters, in constant memory whatever its line length.
    public long CountFile(string path) { return Read(FileChars(path), null); }
}

public static class RdaZipCheck
{
    static readonly uint[] Table = MakeTable();
    static uint[] MakeTable()
    {
        var t = new uint[256];
        for (uint i = 0; i < 256; i++) { uint c = i; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; t[i] = c; }
        return t;
    }

    // The members whose bytes do not match the CRC-32 and size the zip recorded for them
    // (a cut-off or damaged member); none when every member reads back whole.
    public static string[] BadMembers(string zipPath)
    {
        var bad = new List<string>();
        ZipArchive archive;
        try { archive = ZipFile.OpenRead(zipPath); }
        catch (InvalidDataException) { return new[] { "(the zip itself)" }; }
        using (archive)
        {
            foreach (var e in archive.Entries)
            {
                uint crc = 0xFFFFFFFFu; long n = 0;
                try
                {
                    using (var st = e.Open())
                    {
                        var buf = new byte[81920]; int r;
                        while ((r = st.Read(buf, 0, buf.Length)) > 0) { n += r; for (int i = 0; i < r; i++) crc = Table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8); }
                    }
                }
                catch (InvalidDataException) { bad.Add(e.FullName); continue; }
                if ((crc ^ 0xFFFFFFFFu) != e.Crc32 || n != e.Length) bad.Add(e.FullName);
            }
        }
        return bad.ToArray();
    }
}

public static class RdaCsvCheck
{
    // The 1-based number of the first data record (after the header) whose cell count is
    // not $cells, or that is not written as Export-Csv writes (a quote only around a whole
    // cell, "" for a quote inside, a line break inside quotes kept, CRLF or LF between
    // records, never a bare CR outside quotes, every cell quoted or empty, no blank line
    // between records); 0 when every record is so.
    public static long FirstBadRecord(string path, int cells)
    {
        using (var r = new StreamReader(path, true))
        {
            long record = 0; int count = 1; bool inQuotes = false, any = false, cellStart = true, closed = false; int c;
            while ((c = r.Read()) != -1)
            {
                if (inQuotes)
                {
                    if (c == '"') { if (r.Peek() == '"') r.Read(); else { inQuotes = false; closed = true; } }
                    continue;
                }
                if (c == ',') { count++; any = true; cellStart = true; closed = false; continue; }
                if (c == '\r') { if (r.Peek() != '\n') return record > 0 ? record : 1; continue; }
                if (c == '\n')
                {
                    if (any || count > 1) { if (record > 0 && count != cells) return record; record++; }
                    // A blank line between records: Export-Csv writes none (only a last line break).
                    else if (r.Peek() != -1) return record > 0 ? record : 1;
                    count = 1; any = false; cellStart = true; closed = false;
                    continue;
                }
                // Text after a closing quote, a quote inside a cell, or a cell not in quotes
                // (Export-Csv quotes every cell but an empty one): not as Export-Csv writes.
                if (closed || !cellStart || c != '"') return record > 0 ? record : 1;
                if (c == '"') inQuotes = true;
                any = true; cellStart = false;
            }
            if (inQuotes) return record > 0 ? record : 1;
            if ((any || count > 1) && record > 0 && count != cells) return record;
            return 0;
        }
    }

    // For each data record (after the header), in order, a mask of its cells that are
    // empty with no quotes: bit i set for cell i (the first 31 cells). Export-Csv writes a
    // null value so and an empty string as "", and Import-Csv reads both as "", so the
    // mask lets a rewrite give each such cell back as written. Read FirstBadRecord first:
    // this reads a file Export-Csv wrote.
    public static int[] BareEmptyCells(string path)
    {
        var masks = new List<int>();
        using (var r = new StreamReader(path, true))
        {
            long record = 0; int cell = 0, mask = 0, c; bool inQuotes = false, hadText = false, any = false;
            while ((c = r.Read()) != -1)
            {
                if (inQuotes)
                {
                    if (c == '"') { if (r.Peek() == '"') r.Read(); else inQuotes = false; }
                    continue;
                }
                if (c == ',') { if (!hadText && cell < 31) mask |= 1 << cell; cell++; hadText = false; any = true; continue; }
                if (c == '\r') continue;
                if (c == '\n')
                {
                    if (any || hadText)
                    {
                        if (!hadText && cell < 31) mask |= 1 << cell;
                        if (record > 0) masks.Add(mask);
                        record++;
                    }
                    cell = 0; mask = 0; hadText = false; any = false;
                    continue;
                }
                if (c == '"') inQuotes = true;
                hadText = true; any = true;
            }
            if (any || hadText)
            {
                if (!hadText && cell < 31) mask |= 1 << cell;
                if (record > 0) masks.Add(mask);
            }
        }
        return masks.ToArray();
    }
}
'@ -ReferencedAssemblies System.IO.Compression, System.IO.Compression.ZipFile, System.Text.RegularExpressions, System.Collections, System.Runtime.Extensions, System.Text.Encoding.Extensions
}

# The values in a masked row's masked fields that are neither a token, a masked id
# whose name parts are all tokens, nor a fixed value a run writes there
# ('obfuscated', 'obfuscated_<guid>', 'None', empty). Returns the field names,
# never the values. A tag list is read as its values.
function Test-RdaMaskedSlot
{
    param([hashtable]$Row, [string[]]$Field, $RealValue)

    $TokenRegex = Get-RdaTokenRegex
    $Bad = [System.Collections.Generic.List[string]]::new()
    foreach ($F in $Field)
    {
        if (-not $Row.ContainsKey($F) -or $null -eq $Row[$F]) { continue }
        $Items = if ($F -eq 'Tags') { @($Row[$F] | Where-Object { $null -ne $_ } | ForEach-Object { $_.Value }) } else { @($Row[$F]) }
        foreach ($Item in $Items)
        {
            $T = [string]$Item
            if ($T -in @('', 'obfuscated', 'None') -or $T -match '^obfuscated_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { continue }
            if ($T -notmatch $TokenRegex) { [void]$Bad.Add($F); continue }
            # What is left once the tokens are out may hold only Azure's words: a masked id's
            # namespace and type words, and the fixed words of a shape-kept name. Each part of
            # a name slot (cut on - _ . as mask-keep-shape.md cuts a name) must be no real value.
            $Segments = ($T -replace $TokenRegex, '').Split('/')
            $Providers = -1
            for ($i = 0; $i -lt $Segments.Count; $i++)
            {
                $Seg = $Segments[$i]
                if ($Seg -eq '') { continue }
                # The words of the path: subscriptions, resourcegroups, providers, and after
                # providers the namespace and each type word (namespace and every other one after).
                # Counted again from each 'providers' in a word place (an odd segment, as
                # Get-RdaRealValueSet reads an id): in an extension id
                # ('.../<name>/providers/microsoft.insights/<type>/<name>') the namespace after
                # the second one is Azure's word, not a name. A name 'providers' is a name.
                if (($i % 2) -eq 1 -and $Seg -ieq 'providers') { $Providers = $i; continue }
                if ($Seg -in 'subscriptions', 'resourcegroups') { continue }
                # After providers: the namespace (1), then type words (2, 4, ...) between the names (3, 5, ...).
                if ($Providers -ge 0 -and $i -gt $Providers -and (($i - $Providers) -eq 1 -or (($i - $Providers) % 2) -eq 0)) { continue }
                if (@($Seg -split '[-_.]' | Where-Object { $_ -ne '' -and $RealValue.Contains($_) }).Count -gt 0 -or $RealValue.Contains($Seg)) { [void]$Bad.Add($F); break }
            }
        }
    }
    return @($Bad | Select-Object -Unique)
}

# Whether $MaskedId is the id a -Obfuscate run writes for the plain consumption id
# $PlainId: 'obfuscated' for an empty id; for an id the run masks part by part (a
# '/subscriptions/<id>/...' path, or a tenant-scope id Test-RdaTenantScopeIdMaskable
# takes) the same path with its subscription, its group and every name a token, as the
# run's own Test-ObfuscatedIdShape reads it (a seeded run keeps an id by the same
# check); for any other id one flat token, as Get-ObfuscatedResourceId writes it. So a
# masked id that keeps a name part as written fails, whatever the name: Azure's fixed
# name '$system', or a short name of letters only, neither of which the last leak scan
# looks for inside a text. An id that ends on the word '$system' with no name after it
# fails too (Test-RdaTrailingSystemTypeId), and so does a subscription id that ends on any
# other type word with no name after it (Test-RdaTrailingTypeWordId): this tool does not
# support those forms.
# Apart from that shape check, which mirrors the run's masking, every name slot of a
# masked path must differ, in any case, from the plain id's segment there (the
# subscription, the group and every name; the namespace and type words are kept): a
# change that keeps a name both in the masking and in its mirror fails here too.
function Test-RdaMaskedUsageId
{
    param([string]$PlainId, [string]$MaskedId)

    if ([string]::IsNullOrEmpty($PlainId)) { return $MaskedId -ceq 'obfuscated' }
    if ($PlainId -match '(?i)^/subscriptions/[^/]' -or (Test-RdaTenantScopeIdMaskable -ResourceId $PlainId))
    {
        # An id that ends on the word '$system', or a subscription id that ends on any other
        # type word, with no name after it is a form this tool does not support
        # (Test-RdaTrailingSystemTypeId, Test-RdaTrailingTypeWordId), whatever its other parts are.
        if ((Test-RdaTrailingSystemTypeId $PlainId) -or (Test-RdaTrailingSystemTypeId ([string]$MaskedId)) -or (Test-RdaTrailingTypeWordId $PlainId) -or (Test-RdaTrailingTypeWordId ([string]$MaskedId))) { return $false }
        $P = $PlainId.Split('/')
        $M = ([string]$MaskedId).Split('/')
        if ($P.Count -ne $M.Count) { return $false }
        # The path pairs a word with a value from segment 1 on: subscriptions, resourcegroups,
        # each type, with a name; providers with its namespace. An empty name is kept as written.
        for ($i = 1; $i + 1 -lt $P.Count; $i += 2)
        {
            if ($P[$i] -ieq 'providers' -or [string]::IsNullOrEmpty($P[$i + 1])) { continue }
            if ($M[$i + 1] -ieq $P[$i + 1]) { return $false }
        }
        return [bool](Test-ObfuscatedIdShape -RealId $PlainId -MaskedId $MaskedId)
    }
    return $MaskedId -ine $PlainId -and $MaskedId -cmatch '^(?:prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
}

function Test-RdaStrictUtf8File
{
    param([Parameter(Mandatory = $true)][string]$Path, [ValidateRange(1, 67108864)][int]$ChunkBytes = 1048576)

    # Read in fixed-size chunks through one decoder, which keeps a character cut by a chunk edge, so a file of
    # any size is checked in bounded memory. True when every byte is valid UTF-8.
    $Decoder = [System.Text.UTF8Encoding]::new($false, $true).GetDecoder()
    $Bytes = [byte[]]::new($ChunkBytes)
    $Chars = [char[]]::new($ChunkBytes + 8)
    $Stream = [System.IO.File]::OpenRead($Path)
    try
    {
        try
        {
            while (($Read = $Stream.Read($Bytes, 0, $Bytes.Length)) -gt 0) { [void]$Decoder.GetChars($Bytes, 0, $Read, $Chars, 0, $false) }
            [void]$Decoder.GetChars($Bytes, 0, 0, $Chars, 0, $true)
        }
        catch [System.Text.DecoderFallbackException] { return $false }
    }
    finally { $Stream.Dispose() }
    return $true
}

# A plain run's Diagnostics_*.log (Write-RdaShareableDiagnosticsLog) read back into
# what that function was given: the tool version, the phase times and the failure
# entries, each tied to $ReportFolder. Write-RdaShareableDiagnosticsLog -Obfuscated
# then writes the log a -Obfuscate run writes: no failure text, only the facts the log holds. A line the log does not have is an error.
function ConvertFrom-RdaDiagnosticsText
{
    param([string[]]$Lines, [string]$ReportFolder)

    $Lines = @($Lines | ForEach-Object { [string]$_ })
    $Out = [pscustomobject]@{
        Obfuscated            = ($Lines.Count -gt 0 -and $Lines[0] -like '*(obfuscated run)*')
        Version               = $null
        PhaseTimings          = [ordered]@{}
        CollectorFailures     = [System.Collections.Generic.List[object]]::new()
        MetricsFailedSubs     = [System.Collections.Generic.List[object]]::new()
        ConsumptionFailedSubs = [System.Collections.Generic.List[object]]::new()
    }
    $Headers = @('Resource Discovery for Azure - diagnostics (default/non-obfuscated run)', 'Resource Discovery for Azure - shareable diagnostics (obfuscated run)')
    if ($Lines.Count -eq 0 -or $Headers -cnotcontains $Lines[0]) { throw 'the diagnostics log does not start as the run writes it' }

    # The writer's fixed shape: the head (to Tool version), then five sections in this
    # order, each after a blank line; the four failure sections state their entry count.
    # A failure message is printed as given, so it can hold a blank line and a line that
    # reads like a section header. The sections are therefore found as the one way of
    # placing the five headers (each after a blank line, in order) under which every
    # failure section holds exactly the entries it states; none or more than one is refused.
    $Patterns = @('^Phase timings:$', '^Collector failures: (\d+)$', '^Metrics auth-skipped subscriptions: (\d+)$', '^Metrics incomplete subscriptions: (\d+)$', '^Consumption failed/incomplete subscriptions: (\d+)$')
    $Candidates = @(foreach ($P in $Patterns) { , @(for ($i = 1; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -cmatch $P -and $Lines[$i - 1] -eq '') { $i } }) })
    $EntryStart = '^  \[sub (.*?)\] '
    # The lines of a section: from its header to the blank line before the next one.
    $Block = { param([int]$From, [int]$To) if ($To -lt $From) { , @() } else { , @($Lines[$From..$To]) } }
    $Fits = { param([int[]]$At)
        for ($Si = 1; $Si -lt 5; $Si++)
        {
            $Stated = [int]([regex]::Match($Lines[$At[$Si]], '(\d+)$').Value)
            $End = if ($Si -lt 4) { $At[$Si + 1] - 2 } else { $Lines.Count - 1 }
            if ($Si -lt 4 -and $Lines[$At[$Si + 1] - 1] -ne '') { return $false }
            $Body = & $Block ($At[$Si] + 1) $End
            if ($Si -eq 4) { while ($Body.Count -gt 0 -and $Body[-1] -eq '') { $Body = @($Body | Select-Object -SkipLast 1) } }
            $Starts = @($Body | Where-Object { $_ -cmatch $EntryStart }).Count
            if ($Starts -ne $Stated -or ($Body.Count -gt 0 -and $Body[0] -cnotmatch $EntryStart)) { return $false }
        }
        return $true
    }
    $Found = [System.Collections.Generic.List[object]]::new()
    # Every ordered placing of the five headers among their candidates.
    $Placings = [System.Collections.Generic.List[object]]::new()
    $Placings.Add(@())
    foreach ($Options in $Candidates)
    {
        $Longer = [System.Collections.Generic.List[object]]::new()
        foreach ($Placed in $Placings)
        {
            foreach ($At in $Options)
            {
                if ($Placed.Count -gt 0 -and $At -le $Placed[-1]) { continue }
                if ($Longer.Count -ge 100000) { throw 'the diagnostics log cannot be read back: too many ways to read it' }
                $Longer.Add(@($Placed) + $At)
            }
        }
        $Placings = $Longer
    }
    foreach ($Placed in $Placings) { if (& $Fits $Placed) { $Found.Add($Placed) } }
    if ($Found.Count -ne 1) { throw 'the diagnostics log is cut off or cannot be read back one way only' }
    $At = $Found[0]

    # The head is the writer's fixed lines, its time, and the tool version once: Version.json's
    # three numbers (GetLocalVersion); no other text is copied on. The time's separators are
    # the host culture's (':' or '.', as fi-FI and da-DK write them).
    $Fixed = if ($Out.Obfuscated) { @('Safe to share: identifiers are obfuscated/masked. Human-readable', 'troubleshooting log - NOT report data, do not ingest into tables.') } else { @('NOTE: this bundle is NOT obfuscated - the report itself contains real', 'identifiers. This log masks GUIDs/emails but treat the whole bundle as', 'sensitive. Human-readable troubleshooting log - NOT report data, do not', 'ingest into tables.') }
    $Head = @($Lines[1..($At[0] - 1)])
    if ($Head.Count -ne $Fixed.Count + 3 -or $Head[-1] -ne '' -or $Head[$Fixed.Count] -cnotmatch '^Generated \(UTC\) : \d{4}-\d{2}-\d{2}T\d{2}([:.])\d{2}\1\d{2}Z\z' -or $Head[$Fixed.Count + 1] -cnotmatch '^Tool version    : (\d+\.\d+\.\d+)\z') { throw 'the head of the diagnostics log is not as the run writes it' }
    $Out.Version = $Matches[1]
    for ($Hi = 0; $Hi -lt $Fixed.Count; $Hi++) { if ($Head[$Hi] -cne $Fixed[$Hi]) { throw 'the head of the diagnostics log is not as the run writes it' } }
    if ($null -eq $Out.Version) { throw 'the diagnostics log is cut off: it has no tool version' }
    foreach ($Line in (& $Block ($At[0] + 1) ($At[1] - 2)))
    {
        # The writer's form: '(none recorded)' alone, else each phase once, '{0}min {1:D2} sec'.
        if ($Line -ceq '  (none recorded)') { if (@($Lines[($At[0] + 1)..($At[1] - 2)]).Count -ne 1) { throw 'a phase time line of the diagnostics log is not understood' }; continue }
        if ($Line -cnotmatch '^  (.+): (\d+)min ([0-5]\d) sec\z' -or $Out.PhaseTimings.Contains($Matches[1])) { throw 'a phase time line of the diagnostics log is not understood' }
        $Out.PhaseTimings[$Matches[1]] = [TimeSpan]::FromSeconds([int]$Matches[2] * 60 + [int]$Matches[3])
    }
    # A log's failure line holds '(message not kept)' or '(message not kept: <facts>)': the facts are
    # read back only when they are in the closed grammar (Test-RdaDiagnosticFacts). A log from a run
    # that wrote the message text has no facts: its text is dropped, never read.
    # The page and record count belong to a consumption entry (section 4) only.
    $ReadFacts = { param([string]$Text, [int]$Section)
        if ($Text -cmatch '^\(message not kept: ([^\r\n]+)\)\z' -and (Test-RdaDiagnosticFacts $Matches[1]) -and ($Section -eq 4 -or $Matches[1] -cnotmatch 'page=')) { return $Matches[1] }
        return ''
    }
    for ($Si = 1; $Si -lt 5; $Si++)
    {
        $End = if ($Si -lt 4) { $At[$Si + 1] - 2 } else { $Lines.Count - 1 }
        $Last = $null
        foreach ($Line in (& $Block ($At[$Si] + 1) $End))
        {
            if ($Line -cmatch $EntryStart)
            {
                $Id = $Matches[1]
                # The writer gives a subscription as '<guid>' or its token (Get-RdaDiagnosticSubLabel): a subscription is
                # '<guid>', a consumption sign-in skip '(auth)'; no other text is copied on.
                # Per section, the labels its writers give: a collector or metrics-incomplete
                # entry its subscription; a metrics sign-in skip '(unknown)' when the run had none
                # (ResourceInventory.ps1); a consumption sign-in skip '(auth)'.
                $Labels = switch ($Si) { 1 { '<guid>', '' } 2 { '<guid>', '(unknown)' } 3 { '<guid>', '' } 4 { '<guid>', '(auth)', '' } }
                if ($Id -cnotin $Labels) { throw 'a failure entry of the diagnostics log names a subscription as a run does not' }
                $Rest = $Line.Substring($Matches[0].Length)
                if ($Si -eq 1)
                {
                    if ($Rest -notmatch '^([^:]+): (.*)$') { throw 'a collector failure line of the diagnostics log is not understood' }
                    $Last = [pscustomobject]@{ Id = $Id; Module = $Matches[1]; Message = $Matches[2] }
                    $Last | Add-Member -NotePropertyName Facts -NotePropertyValue (& $ReadFacts $Matches[2] $Si)
                    $Out.CollectorFailures.Add($Last)
                }
                else
                {
                    $Last = [pscustomobject]@{ Id = $Id; Name = $null; Message = $Rest; ReportFolder = $ReportFolder }
                    $Last | Add-Member -NotePropertyName Facts -NotePropertyValue (& $ReadFacts $Rest $Si)
                    if ($Si -eq 3) { $Last | Add-Member -NotePropertyName Complete -NotePropertyValue $false }
                    if ($Si -eq 4) { $Out.ConsumptionFailedSubs.Add($Last) } else { $Out.MetricsFailedSubs.Add($Last) }
                }
            }
            else { $Last.Message += "`n" + $Line }
        }
        if ($Si -eq 4 -and $null -ne $Last) { $Last.Message = $Last.Message.TrimEnd("`n") }
    }
    return $Out
}

# Every line Get-WrapperExitCodeSummary writes, but a stream's (which holds numbers; the
# reader matches it by its form): each cause on or off, with no other reason and with
# every reason the wrapper gives ($ExitTwoReasons in Run-AllSubscriptions.ps1, read from
# its code). A reason's line does not depend on the others, so this is every line.
function Get-RdaExitCodeLineSet
{
    if ($null -ne $script:RdaExitCodeLineSet) { return $script:RdaExitCodeLineSet }
    $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
    $Reasons = @($WrapperAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -ceq '$ExitTwoReasons' -and $N.Operator -eq 'PlusEquals' }, $true) | ForEach-Object {
            $Value = $_.Right.Find({ param($N) $N -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
            if ($null -eq $Value) { throw 'Run-AllSubscriptions.ps1 gives an exit code reason that is not fixed text.' }
            [string]$Value.Value
        })
    $Set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($Bits = 0; $Bits -lt 256; $Bits++)
    {
        $On = { param($n) ($Bits -band (1 -shl $n)) -ne 0 }
        $Other = if (& $On 7) { $Reasons } else { @() }
        foreach ($L in @(Get-WrapperExitCodeSummary -AuthSkipped (& $On 0) -CollectorsFailed (& $On 1) -SubscriptionsFailed (& $On 2) -VerificationGap (& $On 3) -ReportMade (& $On 4) -ConsumptionFailed (& $On 5) -MetricsIncomplete (& $On 6) -OtherReasons $Other)) { [void]$Set.Add([string]$L) }
    }
    $script:RdaExitCodeLineSet = $Set
    return $Set
}

# A plain run's RunSummary.log (Get-RunSummaryLogContent) read back into the
# arguments that function takes, so Get-RunSummaryLogContent -Obfuscated writes the
# log a -Obfuscate run writes. Counts become lists of that many entries (an
# obfuscated log prints counts only); the per-subscription detail is not read.
# The coverage lines' reasons are read back to their kinds (Get-RunReportCoverage),
# which an obfuscated log counts. A line the log does not have is an error.
function ConvertFrom-RdaRunSummaryText
{
    param([string[]]$Lines)

    $Kinds = [ordered]@{
        'retry limit reached ('             = 'retry limit reached'
        'report missing ('                  = 'report missing'
        'skipped by the up-front role check' = 'skipped by the role check'
        'completed earlier in the run;'     = 'completed earlier in the run'
        'not enabled or excluded ('         = 'not enabled or excluded'
        'collection failed: '               = 'collection failed'
        'not collected by this run'         = 'not collected'
    }
    $Count = { param($N, $Make) @(for ($i = 0; $i -lt [int]$N; $i++) { & $Make $i }) }
    $Plain = { param($i) [pscustomobject]@{ Name = 'entry'; Id = ('entry-{0}' -f $i) } }
    $Params = [ordered]@{}
    $A = @{ InvocationParameters = $Params }
    $Coverage = [System.Collections.Generic.List[string]]::new()
    $Without = [System.Collections.Generic.List[string]]::new()
    $Unnamed = $null
    $Counts = @{}
    if (@($Lines).Count -lt 2 -or [string]$Lines[0] -ne 'Resource Discovery for Azure - run summary' -or [string]$Lines[1] -ne 'Non-obfuscated run: contains real subscription names/ids.') { throw 'the run summary does not start as a plain run writes it' }
    $Seen = @{}
    $Section = 'header'
    # The detail list the writer adds below Health for each of these counts above 0 (the
    # count it is written for). 'Report missing (detail; ...)' is not here: it names only
    # the reports it can, so its count can be above its entries.
    $Detail = [ordered]@{
        'Failed subscriptions (detail):'                                                                                 = 'Health Failed subscriptions'
        'Retry limit reached (detail; to try them again, run the same command with -Resume -RetryLimitReached in place of -Fresh or -ResumeFailedOnly (it keeps what the unfinished run completed), or start a new run with -Fresh):' = 'Retry limit reached'
        'Report missing, retry limit reached (detail; not in this zip; to try them again, run the same command with -Resume -RetryLimitReached in place of -Fresh or -ResumeFailedOnly (it keeps what the unfinished run completed), or start a new run with -Fresh):' = 'Report missing, retry limit reached'
        '0-resource subscriptions with NO ACCESS (grant Reader, re-run -Resume):'                                       = '0 resources - no access'
        'Collector failures (detail):'                                                                                   = 'Health Collector failures'
        'Metrics auth-skipped subscriptions (detail):'                                                                   = 'Health Metrics auth-skipped subs'
        'Metrics incomplete subscriptions (detail):'                                                                     = 'Health Metrics incomplete subs'
        'Consumption failed subscriptions (detail):'                                                                     = 'Health Consumption failed subs'
    }
    # The wrapper's own parameter names, from its param block.
    if ($null -eq $script:RdaWrapperParams)
    {
        $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        # Not the optional ones (-WhatIf, -Confirm): the wrapper does not support ShouldProcess.
        # ProgressAction by name too: a run on 7.4+ can pass it, a mask on 7.0-7.3 does not know it.
        $script:RdaWrapperParams = [string[]](@($WrapperAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) + [System.Management.Automation.PSCmdlet]::CommonParameters + 'ProgressAction')
    }
    $WrapperParams = $script:RdaWrapperParams
    if ($null -eq $script:RdaWrapperSwitches)
    {
        $SwitchAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $script:RdaWrapperSwitches = [string[]](@($SwitchAst.ParamBlock.Parameters | Where-Object { $_.StaticType -eq [switch] } | ForEach-Object { $_.Name.VariablePath.UserPath }) + 'Debug', 'Verbose')
    }
    $WrapperSwitches = $script:RdaWrapperSwitches
    $Order = @('Parameters:', 'Host / parallelism:', 'Subscriptions:', 'Reports in this zip:', 'Health:')
    $LastRank = -1
    # The lists in the writer's order (Get-RunSummaryLogContent): a header starts a list only if it is exact (case for
    # case), is later in this order than the list being read and not seen yet. A line of a failure message that
    # reads as an earlier or repeated header is a message line.
    $DetailKeys = @($Detail.Keys)
    $DetailOrder = @($DetailKeys[0], $DetailKeys[1], 'Report missing (detail; not in this zip, the next run collects them):') + @($DetailKeys[2..($DetailKeys.Count - 1)])
    $HeadRank = -1
    $DetailListed = @{}
    # The head, as the writer writes it, in its order: Generated, Tool version (Version.json's
    # numbers; an empty one, Version.json unread, is refused), Run started and Run finished
    # when the run had them, Total duration when it had both (and from them), then one blank.
    # A time's separators are the host culture's (':' or '.', as fi-FI and da-DK write them).
    $ParamAt = [array]::IndexOf([string[]]$Lines, 'Parameters:')
    if ($ParamAt -lt 3) { throw 'the run summary is cut off: a section the run writes is missing' }
    $Head = @($Lines[2..($ParamAt - 1)])
    # One separator through the time; the date in the host culture's calendar (Gregorian, or
    # Persian, Hijri or Thai on a host whose default calendar is one of those). This host's
    # culture first: a mask on the host that collected reads the times as written.
    # shortcut: a log written on another host in another calendar whose dates are also dates
    # here is read in this host's calendar (the times are display only; nothing reads the
    # run summary); upgrade by recording the writer's culture in the log.
    $Time = '(\d{4}-\d{2}-\d{2} \d{2}([:.])\d{2}\2\d{2})'
    # This host's culture as it is (a user's calendar choice kept), then the others by name.
    $Calendars = [System.Collections.Generic.List[cultureinfo]]::new()
    $Calendars.Add([cultureinfo]::CurrentCulture)
    foreach ($Name in @('', 'fa-IR', 'ar-SA', 'th-TH'))
    {
        # A host in invariant globalization mode builds only the invariant culture.
        try { $C = [cultureinfo]::GetCultureInfo($Name); if (-not ($Calendars | Where-Object { $_.Name -eq $C.Name })) { $Calendars.Add($C) } } catch { continue }
    }
    $ReadTime = { param([string]$Text, $Culture) $D = [datetime]::MinValue; if ([datetime]::TryParseExact(($Text -replace '\.', ':'), 'yyyy-MM-dd HH:mm:ss', $Culture, [System.Globalization.DateTimeStyles]::None, [ref]$D)) { $D } else { $null } }
    $Hi = 0
    $HeadOk = $Head.Count -ge 3 -and $Head[0] -cmatch '^Generated \(UTC\) : \d{4}-\d{2}-\d{2}T\d{2}([:.])\d{2}\1\d{2}Z\z'
    $GenSep = if ($HeadOk) { $Matches[1] } else { $null }
    $HeadOk = $HeadOk -and $Head[1] -cmatch '^Tool version    : (\d+\.\d+\.\d+)\z'
    if ($HeadOk)
    {
        $A.Version = $Matches[1]
        $Hi = 2
        $StartText = $null; $EndText = $null; $Seps = @($GenSep)
        if ($Head[$Hi] -cmatch ('^Run started     : {0}\z' -f $Time)) { $StartText = $Matches[1]; $Seps += $Matches[2]; $Hi++ }
        if ($Head[$Hi] -cmatch ('^Run finished    : {0}\z' -f $Time)) { $EndText = $Matches[1]; $Seps += $Matches[2]; $Hi++ }
        # One culture wrote them all (the time it was generated too): one separator.
        if (@($Seps | Select-Object -Unique).Count -gt 1) { $HeadOk = $false }
        # The duration, in the writer's form: hours only from an hour on, minutes and seconds below 60.
        $Said = $null
        if ($Head[$Hi] -cmatch '^Total duration  : (?:([1-9]\d*)h ([0-5]\d)m ([0-5]\d)s|([1-5]?\d)m ([0-5]\d)s)\z')
        {
            $Said = if ($Matches[1]) { [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3] } else { [int]$Matches[4] * 60 + [int]$Matches[5] }
        }
        # Each time read in the first calendar it is a date of in which the two give the duration
        # (the writer takes it from the full times, printed cut to the second: within a second).
        $Read = $false
        foreach ($Culture in $Calendars)
        {
            $S = if ($null -ne $StartText) { & $ReadTime $StartText $Culture } else { $null }
            $E = if ($null -ne $EndText) { & $ReadTime $EndText $Culture } else { $null }
            if (($null -ne $StartText -and $null -eq $S) -or ($null -ne $EndText -and $null -eq $E)) { continue }
            $Both = $null -ne $S -and $null -ne $E -and $E -ge $S
            if ($Both -and ($null -eq $Said -or [math]::Abs($Said - ($E - $S).TotalSeconds) -gt 1)) { continue }
            if (-not $Both -and $Head[$Hi] -like 'Total duration*') { continue }
            $A.StartTime = $S; $A.EndTime = $E; $Read = $true
            if ($Both) { $Hi++ }
            break
        }
        if (-not $Read) { $HeadOk = $false }
        if ($Hi -ne $Head.Count - 1 -or $Head[$Hi] -ne '') { $HeadOk = $false }
    }
    if (-not $HeadOk) { throw 'the head of the run summary is not as the run writes it' }
    $Head = $null
    $InEntry = $false
    foreach ($Line in $Lines)
    {
        # Below Health only the writer's own list headers start a list: a message, which can
        # run over lines, may hold any text. Its entries are counted at least once each.
        if ($Section -eq 'detail')
        {
            $LineRank = [array]::IndexOf([string[]]$DetailOrder, $Line)
            if ($LineRank -gt $HeadRank -and $DetailOrder[$LineRank] -ceq $Line) { $Head = $Line; $HeadRank = $LineRank; $DetailListed[$Head] = 0 }
            elseif ($null -ne $Head -and $Line.StartsWith('  - ')) { $DetailListed[$Head]++ }
            continue
        }
        if ($Section -eq 'header' -and $Line -cnotin $Order) { continue }
        if ($Line -in $Order)
        {
            # The writer writes each section once, in this order: a header seen again or
            # out of order is a reason line that reads as one, refused (never read as data).
            $Rank = [array]::IndexOf($Order, $Line)
            if ($Seen.ContainsKey($Line) -or $Rank -le $LastRank) { throw 'a line of the run summary reads as a section out of order' }
            $Section = $Line; $Seen[$Line] = $true; $LastRank = $Rank; continue
        }
        if ($Line -eq '') { if ($Section -eq 'Health:') { $Section = 'detail' }; continue }
        switch ($Section)
        {
            'header' { continue }
            'Parameters:'
            {
                if ($Line -eq '  (defaults - no switches or values passed)') { continue }
                if ($Line -notmatch '^  -(\w+)(?: (.*))?$') { throw 'a parameter line of the run summary is not understood' }
                # The masked log prints each name, and the value of the two tuning numbers: a
                # name must be one of the wrapper's parameters (PowerShell's common ones too,
                # such as -Debug, which $PSBoundParameters holds), those two values whole numbers.
                $PName = $Matches[1]; $PValue = $Matches[2]
                if ($WrapperParams -cnotcontains $PName) { throw 'the run summary names a parameter the wrapper does not have' }
                # A switch is written bare, any other parameter with its value.
                if (($WrapperSwitches -ccontains $PName) -ne ($null -eq $PValue)) { throw 'a parameter line of the run summary is not as the run writes it' }
                if ($PName -cin 'ParallelStreams', 'ConcurrencyLimit' -and [string]$PValue -cnotmatch '^\d+\z') { throw 'a tuning parameter of the run summary is not a number' }
                $Params[$PName] = if ($null -eq $PValue) { [switch]::Present } else { $PValue }
            }
            'Host / parallelism:'
            {
                if ($Line -match '^  Host vCPU\s*: (\d+)$') { $A.HostVCpu = [int]$Matches[1] }
                elseif ($Line -match '^  Host RAM \(GB\)\s*: (\d+)(?:[.,/\u066B](\d+))?$') { $A.HostRamGB = [double]::Parse(('{0}.{1}' -f $Matches[1], $(if ($Matches[2]) { $Matches[2] } else { '0' })), [cultureinfo]::InvariantCulture) } # written in the host's culture (61.4, 61,4, fa-IR and ar-SA 61\u066B4, Windows fa-IR 61/4)
                # The source is one of the wrapper's words (Run-AllSubscriptions.ps1, $StreamsSrc).
                elseif ($Line -cmatch '^  Parallel streams\s*: (\d+)(?: \((auto|explicit|nothing left to collect)\))?$') { $A.Streams = [int]$Matches[1]; $A.StreamsSource = $Matches[2] }
                elseif ($Line -cmatch '^  Concurrency limit : (\d+)(?: \((auto|explicit)\))?$') { $A.Concurrency = [int]$Matches[1]; $A.ConcurrencySource = $Matches[2] }
                else { throw 'a host line of the run summary is not understood' }
            }
            'Subscriptions:'
            {
                if ($Line -notmatch '^  ([^:]+?)\s*: ?(\d+)') { throw 'a subscription line of the run summary is not understood' }
                $Counts[$Matches[1].Trim()] = [int]$Matches[2]
            }
            'Reports in this zip:'
            {
                if ($Coverage.Count -eq 0)
                {
                    # Counts only (Get-RunReportCoverageLines): any other text is not copied on.
                    if ($Line -cnotmatch '^  \d+ subscription\(s\) in this run \(\d+ visible to the tenant\), \d+ report\(s\) in this zip\.\z') { throw 'the coverage line of the run summary is not understood' }
                    $Coverage.Add($Line.Substring(2)); continue
                }
                if ($Coverage.Count -eq 1 -and $Line -cmatch '^  \d+ subscription\(s\) without a report in this zip:\z') { $Coverage.Add($Line.Substring(2)); continue }
                # Entries come only under the 'without a report' line.
                if ($Coverage.Count -lt 2) { throw 'a coverage line of the run summary is not understood' }
                # The writer's own text after the count; only the count is kept.
                if ($Line -cmatch '^    - (\d+) report missing that could not be named') { if ($null -ne $Unnamed -or $Line -cnotmatch '^    - ([1-9]\d*) report missing that could not be named \(see Per-subscription output verification on the console\)\z') { throw 'a coverage line of the run summary is not understood' }; $Unnamed = '  - {0} report missing that could not be named (see Per-subscription output verification on the console)' -f $Matches[1]; $InEntry = $false; continue }
                # An entry is '<name> (<id>): <kind>...', or '<name>: skipped by the up-front role
                # check (not readable)'; any other line (a raw reason's own lines) is the entry's.
                $Guid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
                $KindAlt = (@($Kinds.Keys) | ForEach-Object { [regex]::Escape($_) }) -join '|'
                $IsEntry = $Line -match ('^    - .*\({0}\): (?:{1})' -f $Guid, $KindAlt) -or $Line -match '^    - .*: skipped by the up-front role check \(not readable\)$'
                if (-not $IsEntry)
                {
                    # A failed collection's reason is raw error text, which can run over lines.
                    if ($InEntry) { continue }
                    throw 'a coverage line of the run summary is not understood'
                }
                # '<name> (<id>): <reason>' (or '<name>: <reason>' for the role check): the
                # reason is the first ': <kind>' after an id, else the last on the line (a
                # name can hold the same words; a failed collection's reason any text).
                $Kind = $null
                $KindsSeen = 0
                foreach ($M in [regex]::Matches($Line, ('\({0}\): ' -f $Guid)))
                {
                    $Rest = $Line.Substring($M.Index + $M.Length)
                    foreach ($Start in $Kinds.Keys) { if ($Rest.StartsWith($Start)) { if ($null -eq $Kind) { $Kind = $Kinds[$Start] }; $KindsSeen++; break } }
                }
                # A name and a reason that both read as '(<id>): <kind>' cannot be told apart: refused.
                if ($KindsSeen -gt 1) { throw 'a coverage line of the run summary can be read more than one way' }
                if ($null -eq $Kind)
                {
                    $At = -1
                    foreach ($Start in $Kinds.Keys) { $I = $Line.LastIndexOf(': ' + $Start); if ($I -gt $At) { $At = $I; $Kind = $Kinds[$Start] } }
                }
                if ($null -eq $Kind) { throw 'a coverage line of the run summary is not understood' }
                $Without.Add($Kind)
                $InEntry = $true
            }
            'Health:'
            {
                # The sign-in skip count is the one written with its unit.
                if ($Line -cmatch '^  Consumption sign-in skipped   : (\d+) subscription\(s\)\z') { $Counts['Health Consumption sign-in skipped'] = [int]$Matches[1]; continue }
                if ($Line -notmatch '^  ([^:]+?)\s*: (\d+)$') { throw 'a health line of the run summary is not understood' }
                $Counts['Health ' + $Matches[1].Trim()] = [int]$Matches[2]
            }
            default { throw 'a line of the run summary is not understood' }
        }
    }
    # Every section and count the writer always writes, so a log cut off after any line is refused.
    foreach ($Need in 'Parameters:', 'Subscriptions:', 'Health:') { if (-not $Seen.ContainsKey($Need)) { throw 'the run summary is cut off: a section the run writes is missing' } }
    # The writer writes its tool version once.
    if ($null -eq $A.Version) { throw 'the run summary is cut off: it has no tool version' }
    # The writer writes this section only with its count line.
    if ($Seen.ContainsKey('Reports in this zip:') -and $Coverage.Count -eq 0) { throw 'the run summary is cut off: its coverage section has no count line' }
    foreach ($Need in 'Visible', 'Excluded', 'Eligible', 'Skipped', 'Processed', 'Failed', 'Retry limit reached', '0 resources - no access', '0 resources - empty', '0 resources - undetermined', 'Health Consumption records collected', 'Health Failed subscriptions', 'Health Collector failures', 'Health Metrics auth-skipped subs', 'Health Metrics incomplete subs', 'Health Consumption failed subs', 'Health Consumption sign-in skipped')
    {
        if (-not $Counts.ContainsKey($Need)) { throw 'the run summary is cut off: a count the run writes is missing' }
    }
    # A message can run over several lines, so a list holds at least its count of entries.
    foreach ($H in $Detail.Keys)
    {
        $N = [int]$Counts[$Detail[$H]]
        if ($N -gt 0 -and (-not $DetailListed.ContainsKey($H) -or $DetailListed[$H] -lt $N)) { throw 'the run summary is cut off: a detail list holds fewer entries than its count' }
    }
    if ($Coverage.Count -gt 1)
    {
        $Stated = [int]($Coverage[1] -replace '^(\d+) .*$', '$1')
        $Listed = $Without.Count + $(if ($null -ne $Unnamed) { [int]($Unnamed -replace '^  - (\d+) .*$', '$1') } else { 0 })
        if ($Stated -ne $Listed) { throw 'the run summary is cut off: the coverage list holds fewer subscriptions than it states' }
    }
    # The 'Which flag to use' guide (written when work is left): its commands carry the run's switches and,
    # for a -SubscriptionID run, a placeholder. They are read from the first command and the whole guide is
    # written again from them and must read the same, so the guide is only ever the writer's own text.
    # Fail-safe rule: a log with the guide gives the guide again (WorkLeft), one without it none that the
    # counts do not give.
    $GuideHead = 'Which flag to use (this run is not complete):'
    $PlainCommandSettings = $null
    # The guide stands where the writer puts it: right after the Health lines and one blank line. The same
    # words in a failure message further down (a message can hold any text) are not the guide.
    $GuideAt = -1
    $HealthAt = [array]::IndexOf([string[]]@($Lines), 'Health:')
    if ($HealthAt -ge 0)
    {
        $HealthEnd = $HealthAt + 1
        while ($HealthEnd -lt @($Lines).Count -and $Lines[$HealthEnd] -ne '') { $HealthEnd++ }
        if ($HealthEnd + 1 -lt @($Lines).Count -and $Lines[$HealthEnd + 1] -ceq $GuideHead) { $GuideAt = $HealthEnd + 1 }
    }
    if ($GuideAt -ge 0)
    {
        if ($GuideAt -lt 1 -or $Lines[$GuideAt - 1] -ne '' -or $GuideAt + 1 -ge @($Lines).Count) { throw 'the guide of the run summary is not as the run writes it' }
        if ([string]$Lines[$GuideAt + 1] -cnotmatch '^  Run stopped part way, or not everything done: \./Run-AllSubscriptions\.ps1 -TenantID <tenant id>( -SubscriptionID <subscription id>)? -Resume((?: -[A-Za-z]+)*) \(it continues') { throw 'the guide of the run summary is not as the run writes it' }
        $GuideSub = $Matches[1]; $GuideOn = @([regex]::Matches($Matches[2], '-([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value })
        # The run's own switches, in the order the wrapper builds them ($RetryCommandSettings): the run settings, -DeviceLogin, then -UseMetricsBatch.
        $GuideNames = @(Get-RunDataSettingNames) + 'DeviceLogin', 'UseMetricsBatch'
        $Last = -1
        foreach ($On in $GuideOn) { $At = [array]::IndexOf($GuideNames, $On); if ($At -le $Last) { throw 'the guide of the run summary is not as the run writes it' }; $Last = $At }
        # The wrapper builds the guide's switches from the run's own switches, so each is on in the guide
        # exactly when it was passed (the Parameters: section) and -Obfuscate never (a plain log). The
        # -SubscriptionID of a run is not in that section (the log never records the target), so its placeholder is not checked.
        foreach ($Name in $GuideNames) { if ($Name -cne 'Obfuscate' -and ($GuideOn -ccontains $Name) -ne $Params.Contains($Name)) { throw 'the guide of the run summary does not carry the switches the run was given' } }
        if ($GuideOn -ccontains 'Obfuscate') { throw 'the guide of the run summary does not carry the switches the run was given' }
        $RunSet = Get-RunDataSettings -Obfuscate ($GuideOn -contains 'Obfuscate') -SkipMetrics ($GuideOn -contains 'SkipMetrics') -SkipConsumption ($GuideOn -contains 'SkipConsumption') -IncludeDisabled ($GuideOn -contains 'IncludeDisabled') -IncludeNetworkResources ($GuideOn -contains 'IncludeNetworkResources')
        $A.WorkLeft = [switch]::Present
        $PlainCommandSettings = Get-RetryCommandSettings -Settings $RunSet -DeviceLogin ($GuideOn -contains 'DeviceLogin') -SubscriptionID $(if ($GuideSub) { '<subscription id>' } else { '' })
        if ($GuideOn -contains 'UseMetricsBatch') { $PlainCommandSettings['UseMetricsBatch'] = $true }
        # The same settings as a -Obfuscate run holds them: the masked guide's commands carry -Obfuscate.
        $MaskedSet = Get-RunDataSettings -Obfuscate $true -SkipMetrics ($GuideOn -contains 'SkipMetrics') -SkipConsumption ($GuideOn -contains 'SkipConsumption') -IncludeDisabled ($GuideOn -contains 'IncludeDisabled') -IncludeNetworkResources ($GuideOn -contains 'IncludeNetworkResources')
        $A.CommandSettings = Get-RetryCommandSettings -Settings $MaskedSet -DeviceLogin ($GuideOn -contains 'DeviceLogin') -SubscriptionID $(if ($GuideSub) { '<subscription id>' } else { '' })
        if ($GuideOn -contains 'UseMetricsBatch') { $A.CommandSettings['UseMetricsBatch'] = $true }
    }
    # The exit code section (Get-WrapperExitCodeSummary's lines, written in both modes): it stands
    # right after the Health lines, or after the guide when there is one, and one blank line.
    # Only a line that function writes is taken; each is written again as given.
    $ExitHead = 'Exit code:'
    $ExitLines = [System.Collections.Generic.List[string]]::new()
    if ($HealthAt -ge 0)
    {
        $ExitFrom = $HealthEnd
        if ($GuideAt -ge 0) { $ExitFrom = $GuideAt + 1; while ($ExitFrom -lt @($Lines).Count -and $Lines[$ExitFrom] -ne '') { $ExitFrom++ } }
        if ($ExitFrom + 1 -lt @($Lines).Count -and $Lines[$ExitFrom] -eq '' -and $Lines[$ExitFrom + 1] -ceq $ExitHead)
        {
            $Known = Get-RdaExitCodeLineSet
            $At = $ExitFrom + 2
            while ($At -lt @($Lines).Count -and $Lines[$At] -ne '')
            {
                $Text = [string]$Lines[$At]
                if (-not $Text.StartsWith('  ') -or -not ($Known.Contains($Text.Substring(2)) -or $Text.Substring(2) -cmatch '^Exit code 2: the summary of stream \d+ (?:is missing|could not be read); its \d+ subscription\(s\) are not confirmed; (?:check the consolidated zip for their reports|no consolidated zip was made)\.\z'))
                {
                    throw 'the exit code section of the run summary is not as the run writes it'
                }
                $ExitLines.Add($Text.Substring(2))
                $At++
            }
            if ($ExitLines.Count -eq 0) { throw 'the exit code section of the run summary is not as the run writes it' }
        }
    }
    if ($ExitLines.Count -gt 0) { $A.ExitCodeLines = [string[]]$ExitLines.ToArray() }
    $Params['Obfuscate'] = [switch]::Present
    foreach ($Group in @($Without | Group-Object | Sort-Object -Property Name)) { $Coverage.Add(('  - {0} {1}' -f $Group.Count, $Group.Name)) }
    if ($null -ne $Unnamed) { $Coverage.Add($Unnamed) }
    $A.CoverageLines = $Coverage.ToArray()

    $A.Visible = [int]$Counts['Visible']; $A.Excluded = [int]$Counts['Excluded']; $A.Eligible = [int]$Counts['Eligible']
    $A.Skipped = [int]$Counts['Skipped']; $A.Processed = [int]$Counts['Processed']
    $A.FailedSubscriptions = & $Count $Counts['Failed'] { param($i) 'failed' }
    $A.EmptyNoAccess = & $Count $Counts['0 resources - no access'] $Plain
    $A.EmptyGenuinelyEmpty = & $Count $Counts['0 resources - empty'] $Plain
    $A.EmptyUndetermined = & $Count $Counts['0 resources - undetermined'] $Plain
    $AtLimitMissing = [int]$Counts['Report missing, retry limit reached']
    $A.RetryLimited = @(& $Count $Counts['Retry limit reached'] { param($i) [pscustomobject]@{ Name = 'entry'; Id = ('limit-{0}' -f $i); Attempts = 3; Reason = '' } })
    $A.MissingReports = @(& $Count $AtLimitMissing { param($i) [pscustomobject]@{ Name = 'entry'; Id = ('limit-{0}' -f $i) } })
    $A.MissingReportCount = [int]$Counts['Report missing'] + $AtLimitMissing
    $A.ConsumptionRecordCount = [int]$Counts['Health Consumption records collected']
    $A.CollectorFailures = & $Count $Counts['Health Collector failures'] $Plain
    $A.MetricsFailedSubs = @(& $Count $Counts['Health Metrics auth-skipped subs'] $Plain) + @(& $Count $Counts['Health Metrics incomplete subs'] { param($i) [pscustomobject]@{ Name = 'entry'; Id = ('m-{0}' -f $i); Complete = $false } })
    # A sign-in skip is an '(auth)' row, one per subscription (Get-ConsumptionFailureView).
    $A.ConsumptionFailedSubs = @(& $Count $Counts['Health Consumption failed subs'] $Plain) + @(& $Count $Counts['Health Consumption sign-in skipped'] { param($i) [pscustomobject]@{ Name = 'entry'; Id = '(auth)'; SubscriptionId = ('auth-{0}' -f $i) } })
    # The sections whose every line the read-back holds (parameters, host, counts, health) are
    # written again as the plain run writes them and must read the same, line for line: so a
    # line twice, out of order, or with a word or count the writer does not write is refused.
    $PlainArgs = @{}
    foreach ($K in @($A.Keys)) { if ($null -ne $A[$K]) { $PlainArgs[$K] = $A[$K] } }
    $PlainArgs.InvocationParameters = [ordered]@{}
    if ($null -ne $PlainCommandSettings) { $PlainArgs.CommandSettings = $PlainCommandSettings }
    foreach ($K in @($Params.Keys)) { if ($K -cne 'Obfuscate') { $PlainArgs.InvocationParameters[$K] = $Params[$K] } }
    $Again = @(Get-RunSummaryLogContent @PlainArgs)
    # The Host RAM figure's decimal mark is the writer's culture: read as one mark on both sides.
    $Section = { param($All, $Name) $From = [array]::IndexOf([string[]]$All, $Name); if ($From -lt 0) { return , @() }; $To = $From + 1; while ($To -lt $All.Count -and $All[$To] -ne '') { $To++ }; , @(@($All[($From + 1)..($To - 1)]) | ForEach-Object { $_ -creplace '^(  Host RAM \(GB\)     : \d+)[.,/\u066B](\d+)\z', '$1.$2' }) }
    foreach ($Name in 'Parameters:', 'Host / parallelism:', 'Subscriptions:', 'Health:')
    {
        if (((& $Section @($Lines) $Name) -join "`n") -cne ((& $Section $Again $Name) -join "`n")) { throw 'a section of the run summary is not as the run writes it' }
    }
    # The guide: the lines at its place in the log, against the lines the writer gives for these settings.
    $GuideLines = @()
    if ($GuideAt -ge 0) { $GuideEnd = $GuideAt + 1; while ($GuideEnd -lt @($Lines).Count -and $Lines[$GuideEnd] -ne '') { $GuideEnd++ }; $GuideLines = @($Lines[($GuideAt + 1)..($GuideEnd - 1)]) }
    if (($GuideLines -join "`n") -cne ((& $Section $Again $GuideHead) -join "`n")) { throw 'a section of the run summary is not as the run writes it' }
    if (($ExitLines -join "`n") -cne ((& $Section $Again $ExitHead) -join "`n" -replace '(?m)^  ', '')) { throw 'a section of the run summary is not as the run writes it' }
    return [pscustomobject]@{ Arguments = $A; Failed = [int]$Counts['Failed']; CoverageLines = $A.CoverageLines }
}

# The shape a run writes, read from the run's own code, so a plain report holding
# anything else (a section, a field, a column, a key no collector writes) is
# refused instead of being copied through unmasked:
#   Sections         collector name -> the field names its output records can have
#                    (every hashtable key in Services/<group>/<name>.ps1);
#   MetricFields     the keys a metric record can have (Extension/Metrics.ps1);
#   ConsumptionColumns  the Consumption CSV header, in order (the Select-Object of
#                    the consumption loop in ResourceInventory.ps1);
#   InstanceInfo     the additionalInfo keys of the InstanceData column (the same loop).
function Get-RdaReportShape
{
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    # A collector's output records are the hashtables it assigns to $Obj (each
    # collector then adds $Obj to its result); its other hashtables are its own
    # working data, whose keys no record has.
    # Names are kept case for case: sections and fields are read by their exact names.
    $Sections = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $Raw = @{}
    $Nested = @{}
    foreach ($File in Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'Services') -Recurse -Filter '*.ps1' -File)
    {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$null, [ref]$null)
        $Records = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $N.Left.VariablePath.UserPath -ieq 'Obj' }, $true) | ForEach-Object { $_.Right.FindAll({ param($N) $N -is [System.Management.Automation.Language.HashtableAst] }, $false) } | Select-Object -First 1000)
        $Fields = @($Records | ForEach-Object { $_.KeyValuePairs } | ForEach-Object { $_.Item1.Extent.Text.Trim("'", '"') })
        # A field set on $Obj after it is built: $Obj['Roles'] = ... or $Obj.Roles = ...
        $Fields += @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and (($N.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and $N.Left.Target.Extent.Text -ieq '$Obj') -or ($N.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and $N.Left.Expression.Extent.Text -ieq '$Obj')) }, $true) | ForEach-Object { if ($_.Left -is [System.Management.Automation.Language.IndexExpressionAst]) { $_.Left.Index.Extent.Text.Trim("'", '"') } else { $_.Left.Member.Extent.Text.Trim("'", '"') } })
        $Sections[$File.BaseName] = [System.Collections.Generic.HashSet[string]]::new([string[]]$Fields, [System.StringComparer]::Ordinal)
        # The records a field holds in a list ($Obj.Roles.Add($Role)): that field's nested
        # keys are the keys of the hashtables assigned to the added variable. No other
        # field may hold a record (Tags aside, checked as Name and Value).
        $Nested[$File.BaseName] = @{}
        # The fields a collector copies one level straight from Azure ('X' = $Data.x, one member
        # of a variable): such a field may hold an object as Azure gave it (an app's
        # siteProperties), as a run copies it. A deeper path ($Data.a.b) is Azure's leaf value.
        # A plain run's value: the field's own, or the else branch of 'if (masking) {...} else {...}'.
        $OneHop = {
            param($E)
            # Only where the masking branch walks the object (Protect-SitePropertiesValue).
            if ($E -is [System.Management.Automation.Language.IfStatementAst] -and $null -ne $E.ElseClause -and $E.ElseClause.Statements.Count -eq 1 -and $E.Clauses[0].Item2.Extent.Text -match 'Protect-SitePropertiesValue') { $E = $E.ElseClause.Statements[0] }
            $E -is [System.Management.Automation.Language.PipelineAst] -and $E.PipelineElements.Count -eq 1 -and $E.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and $E.PipelineElements[0].Expression -is [System.Management.Automation.Language.MemberExpressionAst] -and $E.PipelineElements[0].Expression.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $E.PipelineElements[0].Expression.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }
        $Raw[$File.BaseName] = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Records | ForEach-Object { $_.KeyValuePairs } | Where-Object { & $OneHop $_.Item2 } | ForEach-Object { $_.Item1.Extent.Text.Trim("'", '"') }), [System.StringComparer]::Ordinal)
        foreach ($Add in @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Member.Extent.Text -eq 'Add' -and $N.Expression -is [System.Management.Automation.Language.MemberExpressionAst] -and $N.Expression.Expression.Extent.Text -ieq '$Obj' -and @($N.Arguments).Count -eq 1 -and $N.Arguments[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)))
        {
            $Into = $Add.Expression.Member.Extent.Text
            $Var = $Add.Arguments[0].VariablePath.UserPath
            $Keys = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $N.Left.VariablePath.UserPath -ieq $Var }, $true) | ForEach-Object { $_.Right.FindAll({ param($N) $N -is [System.Management.Automation.Language.HashtableAst] }, $false) } | ForEach-Object { $_.KeyValuePairs } | ForEach-Object { $_.Item1.Extent.Text.Trim("'", '"') })
            $Nested[$File.BaseName][$Into] = [System.Collections.Generic.HashSet[string]]::new([string[]]$Keys, [System.StringComparer]::Ordinal)
        }
    }
    # The metric record is built inside a script block the parallel workers run, which the
    # parser reads as text, so its keys are read from the text: the one hashtable with MetricTotalCount.
    $MetricsText = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'Extension/Metrics.ps1'))
    $Records = @([regex]::Matches($MetricsText, "@\{(?<b>[^{}]*'MetricTotalCount'\s*=[^{}]*)\}"))
    if ($Records.Count -ne 1) { throw 'The metric record was not found once in Extension/Metrics.ps1.' }
    $MetricKeys = @([regex]::Matches($Records[0].Groups['b'].Value, "'(\w+)'\s*=") | ForEach-Object { $_.Groups[1].Value })
    $InvAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
    $Select = @($InvAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Select-Object' -and $N.Extent.Text -match 'InstanceData, MeterCategory' -and $N.Parent.Extent.Text -match 'Export-Csv' }, $true))
    if ($Select.Count -ne 1) { throw 'The Consumption CSV columns were not found once in ResourceInventory.ps1.' }
    $Columns = @($Select[0].CommandElements | Select-Object -Skip 1 | Where-Object { $_ -is [System.Management.Automation.Language.ArrayLiteralAst] } | ForEach-Object { $_.Elements } | ForEach-Object { $_.Extent.Text })
    $Info = @($InvAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.HashtableAst] -and @($N.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'IsHAEnabled' }).Count -gt 0 -and @($N.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'ConsumptionMeter' }).Count -gt 0 }, $true))
    if ($Info.Count -ne 1 -or $Columns.Count -eq 0) { throw 'The InstanceData fields were not found once in ResourceInventory.ps1.' }
    return [pscustomobject]@{
        Sections           = $Sections
        Nested             = $Nested
        Raw                = $Raw
        MetricFields       = [System.Collections.Generic.HashSet[string]]::new([string[]]$MetricKeys, [System.StringComparer]::Ordinal)
        ConsumptionColumns = [string[]]$Columns
        InstanceInfo       = [string[]]@($Info[0].KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text })
        # The phase names a run times (the diagnostics log prints them as given).
        PhaseNames         = [string[]]@([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $RepoRoot 'ResourceInventory.ps1')), '\$script:PhaseTimings\[''([^'']+)''\]') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    }
}

# The first thing in a plain inventory that a run of this code does not write: a
# section no collector has, a record field its collector does not write, or a tag
# that is not a Name and a Value. $null when there is none. Names the section only.
function Get-RdaUnknownInventoryShape
{
    param($Rows, $Shape)

    # The fields that hold one value each.
    $OneValue = @('ID', 'Name', 'ResourceGroup', 'Subscription', 'Location', 'Size', 'CPU', 'Memory', 'PowerState', 'HybridBenefit', 'SKU', 'Sku', 'DiskIOPS', 'DiskMBps', 'State', 'Tier', 'Capacity', 'Status', 'VCores', 'LicenseType', 'StorageSizeInGB', 'SqlServerLicenseType', 'SqlImageSku', 'ElasticPoolID', 'Set', 'AssociatedResource')
    foreach ($Section in @($Rows.Keys))
    {
        if (-not $Shape.Sections.ContainsKey($Section)) { return 'a section no collector writes' }
        $Fields = $Shape.Sections[$Section]
        foreach ($Row in @($Rows[$Section]))
        {
            # These are text, and a resource is found by its ARM id: a number, or an id
            # of another form, breaks the report.
            foreach ($K in 'ID', 'Name', 'ResourceGroup', 'Subscription', 'SKU', 'Location')
            {
                if ($Row.ContainsKey($K) -and $null -ne $Row[$K] -and $Row[$K] -isnot [string]) { return ('a {0} in the {1} section that is not text' -f $K, $Section) }
            }
            # Every collected resource is in a group. A run's pull lower-cases Resource Graph's
            # text, but keeps a row whose lower-cased text does not parse as Azure gave it
            # (ConvertFrom-AzGraphPage), so the id's case is not checked.
            $RowId = [string]$Row['ID']
            # Whole type and name pairs to its end: an odd segment after a name would be kept
            # as a type word by the id masking (Get-ObfuscatedResourceId).
            if ([string]::IsNullOrEmpty($RowId) -or ($RowId -notmatch '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/[^/]+(?:/[^/]+/[^/]+)+\z' -or -not (Test-RdaIdPathWord $RowId))) { return ('an id in the {0} section that is not an Azure resource id as a run writes it' -f $Section) }
            foreach ($K in @($Row.Keys))
            {
                if (-not $Fields.Contains($K)) { return ('a field the {0} collector does not write' -f $Section) }
                if ($K -ne 'Tags')
                {
                    $Allowed = $Shape.Nested[$Section][$K]
                    # A field the collector adds records to is a list of records: plain text there
                    # would pass every check that reads records only.
                    if ($null -ne $Allowed -and $null -ne $Row[$K] -and ($Row[$K] -isnot [array] -or @($Row[$K] | Where-Object { $_ -isnot [hashtable] }).Count -gt 0)) { return ('a nested field the {0} collector does not write' -f $Section) }
                    # Any other field holds one value. The one list a collector writes there is a
                    # SQL server's zones (Services/Data/SQLSERVER.ps1, 'ZoneRedundant' = $1.zones), zone
                    # numbers only: a list is taken there only, of numbers only.
                    if ($null -eq $Allowed -and $Row[$K] -is [array] -and (-not ($Section -ceq 'SQLSERVER' -and $K -ceq 'ZoneRedundant') -or @($Row[$K] | Where-Object { -not ($_ -is [long] -or ($_ -is [string] -and $_ -cmatch '^[0-9]+\z')) }).Count -gt 0)) { return ('a list in a field the {0} collector writes one value in' -f $Section) }
                    # An object as Azure gave it, in a field the collector copies straight from Azure,
                    # and never in a field that holds one value. Its values are not taken as
                    # Azure words: the leak scan looks for every real value in them.
                    if ($null -eq $Allowed -and $Row[$K] -is [hashtable])
                    {
                        if (-not $Shape.Raw[$Section].Contains($K) -or $K -cin $OneValue) { return ('a nested field the {0} collector does not write' -f $Section) }
                        continue
                    }
                    foreach ($Inner in @($Row[$K] | Where-Object { $_ -is [hashtable] -or $_ -is [array] }))
                    {
                        # A record only where the collector adds records, holding only their keys and plain values.
                        if ($null -eq $Allowed -or $Inner -isnot [hashtable] -or @($Inner.Keys | Where-Object { -not $Allowed.Contains($_) }).Count -gt 0 -or @($Inner.Values | Where-Object { $_ -is [hashtable] -or $_ -is [array] }).Count -gt 0) { return ('a nested field the {0} collector does not write' -f $Section) }
                    }
                }
            }
            if ($Row.ContainsKey('Tags') -and $null -ne $Row['Tags'])
            {
                foreach ($Tag in @($Row['Tags']))
                {
                    if ($Tag -isnot [hashtable] -or @($Tag.Keys | Where-Object { $_ -cnotin 'Name', 'Value' }).Count -gt 0) { return ('a tag the {0} collector does not write' -f $Section) }
                }
            }
        }
    }
    return $null
}

# True when a metric record is the shape a run writes and the output contract
# needs: every field of the run's record and no other, the four numbers numbers,
# MetricError true or false, the series one number or a list of numbers, the
# other fields text (or empty). A run writes a null series on a call that failed
# (MetricError true, Extension/Metrics.ps1), so that record is read as the run
# writes it; text, a null inside a list, or a null series with MetricError false
# is still not a record a run writes.
function Test-RdaMetricRecordShape
{
    param($Record, $Shape)

    if ($Record -isnot [hashtable] -or $Record.Count -ne $Shape.MetricFields.Count) { return $false }
    # Each key case for case (a hashtable finds a key in any case).
    foreach ($K in @($Record.Keys)) { if (-not $Shape.MetricFields.Contains([string]$K)) { return $false } }
    # A record is asked for a pulled resource: its id is that resource's ARM id (in the
    # pull's case), which the masked id keeps the shape of.
    if ([string]$Record['ID'] -notmatch '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/[^/]+(?:/[^/]+/[^/]+)+\z' -or -not (Test-RdaIdPathWord ([string]$Record['ID']))) { return $false }
    $IsNumber = { param($V) $V -is [long] -or $V -is [double] }
    foreach ($K in $Shape.MetricFields)
    {
        if (-not $Record.ContainsKey($K)) { return $false }
        $V = $Record[$K]
        switch ($K)
        {
            { $_ -in 'MetricCount', 'MetricValue', 'MetricPercentile', 'MetricTotalCount' } { if (-not (& $IsNumber $V)) { return $false } }
            'MetricError' { if ($V -isnot [bool]) { return $false } }
            # Each point is checked in a loop, not a pipeline with a script block
            # per point: that took about 35 s on a file of 1,440,000 points (the
            # offline mask reads every record of a metrics file with this check).
            'MetricSeries'
            {
                if ($null -eq $V) { if (-not ($Record['MetricError'] -is [bool] -and $Record['MetricError'])) { return $false } }
                elseif ($V -is [array]) { foreach ($Point in $V) { if (-not ($Point -is [long] -or $Point -is [double])) { return $false } } }
                elseif (-not (& $IsNumber $V)) { return $false }
            }
            default { if ($null -ne $V -and $V -isnot [string]) { return $false } }
        }
    }
    return $true
}

# An id or a GUID is never one of Azure's words: a value holding one (a planted id in a
# field no one masks, a tenant-scope id too: Get-RdaFullIdPattern), URL-encoded too, is
# scanned like any text.
function Test-RdaAzureWordCandidate([string]$Text)
{
    $Plain = ConvertFrom-RdaUrlEscape $Text
    $Text -match '[a-z]' -and $Plain -notmatch '(?i)/subscriptions/|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -and $Plain -notmatch (Get-RdaFullIdPattern)
}

# Adds to $Exempt (Test-RdaMaskedOutputLeak) the values a plain report holds in fields
# neither a run nor this script masks: every inventory field but the masked ones (ID,
# Name, ResourceGroup, Subscription, Tags, a Databricks workspace's ManagedResourceGroup
# (the row masking gives it its group token), each rule's field and a list a rule masks
# inside), and the metric fields that name Azure's own things.
function Add-RdaExemptValue
{
    param($Rows, $Metrics, $Rules, $Exempt)

    $Add = {
        param($Value)
        if ($Value -is [string]) { if (-not $Exempt.Contains($Value) -and (Test-RdaAzureWordCandidate $Value)) { [void]$Exempt.Add($Value) } }
        # Only text is taken: an object (a record, or one as Azure gave it) and a list are not
        # read, so every real value in them stays looked for.
    }
    $Masked = @('ID', 'Name', 'ResourceGroup', 'Subscription', 'Tags')
    foreach ($Section in @($Rows.Keys))
    {
        $RuleFields = @($Rules | Where-Object { $_.Section -eq $Section } | ForEach-Object { $_.Field; if ($_.Within) { $_.Within } })
        if ($Section -eq 'Databricks') { $RuleFields += 'ManagedResourceGroup' }
        foreach ($Row in @($Rows[$Section])) { foreach ($K in @($Row.Keys)) { if ($Masked -notcontains $K -and $RuleFields -notcontains $K) { & $Add $Row[$K] } } }
    }
    foreach ($MObj in @($Metrics)) { foreach ($Rec in @($MObj['Metrics'])) { foreach ($K in 'Location', 'Service', 'Metric', 'MetricAggregate', 'MetricMeasure', 'MetricTimeGrain') { & $Add $Rec[$K] } } }
}

# The collectors a plain report page (Extension/Summary.ps1) names as failed in its
# 'Incomplete collection' banner. Throws when the page does not end as the writer ends
# it, or its banner is cut or lists fewer collectors than it counts.
function Get-RdaPageFailedCollector
{
    param([string]$Html)

    if ($Html.TrimEnd() -notmatch '</script>\s*</body>\s*</html>$') { throw 'the report page is cut off' }
    if ($Html -notmatch '<b>Incomplete collection:</b>') { return @() }
    if ($Html -notmatch '<b>Incomplete collection:</b> (\d+) resource type\(s\) could not be collected and are MISSING from this report - not empty because there are none, but because the collector errored: (.*?)\. See the Diagnostics log in this bundle for the underlying error, then re-run\.</div></div>') { throw 'the report page''s collector banner is cut off' }
    $Stated = [int]$Matches[1]
    $Names = @([regex]::Matches($Matches[2], '<code>([^<]+)</code>') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })
    if ($Names.Count -ne $Stated) { throw 'the report page''s collector banner lists fewer collectors than it counts' }
    return $Names
}

# The metrics and consumption failure entries a plain main summary (New-RdaAllSubHtmlSummary)
# was built with, read back from what it shows: the banner counts (consumption issues,
# metrics auth-skipped, metrics incomplete) and the report folders whose row it marks
# 'consumption' or 'metrics incomplete'. Entries carry no name: under -Obfuscate the
# summary prints counts and marks only. Throws when the page is cut off (the writer
# always ends it the same way, with at least one table row), or (with -RunSummary, the
# run summary's Health counts) when its counts do not fit the run summary's.
function ConvertFrom-RdaMainSummaryMark
{
    param([string]$Html, $RunSummary)

    # The page is written whole; one that does not end as the writer ends it is cut off.
    if ($Html -notmatch '<tr><td' -or $Html -notmatch '</tbody></table>' -or $Html.TrimEnd() -notmatch '</div></body></html>$') { throw 'the main summary is cut off' }
    $Count = { param($Pattern) if ($Html -match $Pattern) { [int]$Matches[1] } else { 0 } }
    $ConsumpN = & $Count '<b>(\d+) subscription\(s\) had consumption \(billing\) issues\.</b>'
    $AuthN = & $Count '<b>Metrics auth-skipped: (\d+) subscription\(s\)\.</b>'
    $IncompleteN = & $Count '<b>Metrics incomplete: (\d+) subscription\(s\)\.</b>'
    $ConsumpFolders = [System.Collections.Generic.List[string]]::new()
    $MetricsFolders = [System.Collections.Generic.List[string]]::new()
    foreach ($Row in [regex]::Matches($Html, '<tr><td>.*?</tr>'))
    {
        # The link is Join-Path's, so it holds a '\' on Windows.
        if ($Row.Value -notmatch 'href="(?:HTML|ResourcesReport)([^/\\"]+)[/\\]') { continue }
        $Folder = 'ResourcesReport' + $Matches[1]
        if ($Row.Value -match '<span class="tag warn">([a-z ]+) incomplete</span>')
        {
            $What = $Matches[1]
            if ($What -match 'consumption') { $ConsumpFolders.Add($Folder) }
            if ($What -match 'metrics') { $MetricsFolders.Add($Folder) }
        }
    }
    if ($null -ne $RunSummary)
    {
        # The run summary counts metrics as the page does (sign-in skips each, incomplete
        # ones distinct), so each kind must be equal. It counts every consumption entry, a
        # sign-in skip ('(auth)') too, which the page does not count: the page's count can
        # only be lower. A count of 0 is read back as $null, which @() would count as one.
        $RsConsump = @(@($RunSummary.ConsumptionFailedSubs) | Where-Object { $null -ne $_ }).Count
        $RsMetrics = @(@($RunSummary.MetricsFailedSubs) | Where-Object { $null -ne $_ })
        $RsIncomplete = @($RsMetrics | Where-Object { $null -ne $_.PSObject.Properties['Complete'] -and $_.Complete -eq $false }).Count
        $RsAuth = $RsMetrics.Count - $RsIncomplete
        if ($ConsumpN -gt $RsConsump -or $AuthN -ne $RsAuth -or $IncompleteN -ne $RsIncomplete) { throw 'the main summary does not show the failures the run summary counts' }
    }
    # The banner counts entries; a sign-in skip ('(auth)') marks its row without counting.
    $Consumption = @(for ($i = 0; $i -lt [math]::Max($ConsumpN, $ConsumpFolders.Count); $i++) { [pscustomobject]@{ Id = $(if ($i -lt $ConsumpN) { 'c-{0}' -f $i } else { '(auth)' }); Name = $null; Message = ''; ReportFolder = $(if ($i -lt $ConsumpFolders.Count) { $ConsumpFolders[$i] } else { '' }) } })
    # The incomplete banner counts distinct entries (Get-MetricsIncompleteEntries), so each
    # has its own id. A row marked past the counted entries holds a repeat of an incomplete
    # entry (a sign-in skip is counted every time): it gets the first one's id, so the
    # banner still counts it once.
    if ($MetricsFolders.Count -gt $AuthN + $IncompleteN -and $IncompleteN -eq 0) { throw 'the main summary marks more metrics rows than it counts' }
    $Metrics = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt [math]::Max($AuthN + $IncompleteN, $MetricsFolders.Count); $i++)
    {
        $Id = if ($i -lt $AuthN + $IncompleteN) { 'm-{0}' -f $i } else { 'm-{0}' -f $AuthN }
        $Entry = [pscustomobject]@{ Id = $Id; Name = $null; Message = ''; ReportFolder = $(if ($i -lt $MetricsFolders.Count) { $MetricsFolders[$i] } else { '' }) }
        if ($i -ge $AuthN) { $Entry | Add-Member -NotePropertyName Complete -NotePropertyValue $false }
        $Metrics.Add($Entry)
    }
    return [pscustomobject]@{ ConsumptionFailedSubs = $Consumption; MetricsFailedSubs = $Metrics.ToArray() }
}

# Moves each item of the work folder $From into $To (a rename: the work folder is beside
# it), recording in $Published each item this mask put there, so a stop removes those
# only. An item is recorded before its move, so a stop during it still removes it, and
# dropped if the move fails; a name another process made in $To meanwhile stops the mask
# and is not removed.
# shortcut: a stop that lands between the record and the move while another process makes
# that same name removes it (a window of microseconds); upgrade with a lock file if needed.
function Publish-RdaOfflineOutput
{
    param([string]$From, [string]$To, [System.Collections.Generic.List[string]]$Published)

    foreach ($Item in @(Get-ChildItem -LiteralPath $From -Force))
    {
        $Dest = Join-Path $To $Item.Name
        if (Test-Path -LiteralPath $Dest) { Stop-RdaOfflineMask '-OutputDirectory was written to while the mask ran. Nothing was written.' }
        $Published.Add($Dest)
        try { Move-Item -LiteralPath $Item.FullName -Destination $To -ErrorAction Stop }
        catch { [void]$Published.Remove($Dest); throw }
    }
}

# True when every segment the id masking keeps as written (Get-ObfuscatedResourceId: each odd
# segment, and the segment after 'providers') is in the form Azure writes such words: a
# namespace (microsoft.compute, 84codes.cloudamqp) after 'providers', a type word
# (virtualmachines) elsewhere. In a '/subscriptions/<id>/...' id the words are read from
# index 3 on. A tenant-scope id that Test-RdaTenantScopeIdMaskable takes
# ('/providers/<namespace>/<type>/<name>...') keeps its path, its namespace and type words
# as written, so its words are read from index 1 on: 'providers', its dotted namespace, then
# each type word. Names are masked and not looked at; any other id is masked whole (a flat
# token) and keeps nothing.
# shortcut: these words are Azure's, copied unmasked as a run copies them, like a Size. A
# letters-and-digits word that is a real name passes here; the leak scan still finds it when
# it is a report value it looks for (5 characters or more, and 12 or more or holding a digit,
# and not equal to or inside a value of a field no run masks), not otherwise (a group 'rg1' or 'finance' as a type word). Not refused outright: a
# real name may equal an Azure type word (a group 'servers'). Upgrade to a list of Azure's
# types if a report ever holds such a word.
# A last segment '$system' with no name after it ('.../namespaces/<name>/$system') is
# refused like any other word that is not of that form: it is an id form this tool does not
# support (Test-RdaTrailingSystemTypeId). No fixture or captured billing row shows Azure
# billing it, and downstream reads an id's last segment as the resource's name, so how to
# mask it is with the owner. A run keeps such a last type word as written (not changed here).
function Test-RdaIdPathWord([string]$Id)
{
    $Parts = $Id.Split('/')
    if ($Parts.Count -ge 3 -and $Parts[0] -eq '' -and $Parts[1] -ieq 'subscriptions' -and -not [string]::IsNullOrEmpty($Parts[2])) { $Start = 3 }
    elseif (Test-RdaTenantScopeIdMaskable -ResourceId $Id) { $Start = 1 }
    else { return $true }
    for ($I = $Start; $I -lt $Parts.Count; $I += 2)
    {
        $Segment = $Parts[$I]
        if ($Segment -notmatch '^[A-Za-z][A-Za-z0-9]*\z') { return $false }
        if ($I + 1 -ge $Parts.Count) { break }
        $Next = $Parts[$I + 1]
        if ($I -ne 3 -or $Segment -ine 'resourcegroups')
        {
            if ($Segment -ieq 'providers' -and $Next -notmatch '^[A-Za-z0-9]+(\.[A-Za-z0-9]+)+\z') { return $false }
        }
    }
    return $true
}

# True when an id ('/subscriptions/...' or '/providers/...', plain or masked) ends on the word
# '$system' (any case) with no name after it, as in '.../namespaces/<name>/$system': an id form
# this tool does not support. A path pairs a word with a value from segment 1 on, so its last
# segment is a word when it has an even number of segments. No fixture or captured billing
# row shows Azure billing such an id, and downstream reads the last segment as the resource's
# name, so the offline mask refuses it (Protect-RdaReport.ps1, Test-RdaMaskedUsageId) and the
# question of how to mask it is with the owner.
# A tenant-scope id ('/providers/...') is counted too, unlike in Test-RdaTrailingTypeWordId, on
# purpose. A run writes one that holds '$system' as one flat token (Test-RdaTenantScopeIdMaskable
# takes no id with a '$system' part), so nothing of it is kept as written and refusing it is not
# needed to stop a leak. But that flat token is itself an open question with the owner: a path
# form for it would be an id shape change, and in that form the last '$system' would be a word
# kept as written, as in a subscription id. So the offline mask refuses a last '$system' in both
# forms until the owner rules, failing closed, and one ruling covers both. The test of this
# function in Tests/ProtectRdaReport.Tests.ps1 holds the tenant-scope case.
function Test-RdaTrailingSystemTypeId([string]$Id)
{
    if ([string]::IsNullOrEmpty($Id) -or -not $Id.EndsWith('/$system', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    $Parts = $Id.Split('/')
    return $Parts[0] -eq '' -and ($Parts[1] -ieq 'subscriptions' -or $Parts[1] -ieq 'providers') -and ($Parts.Count % 2) -eq 0
}

# True when a subscription id ('/subscriptions/...', plain or masked) ends on a word with no
# value after it, as in '.../namespaces/<name>/topics': a path pairs a word with a value from
# segment 1 on, so its last segment is a word when it has an even number of segments. (A
# last segment that is empty, an id that ends on '/', is not counted here: Test-RdaIdPathWord
# refuses it.) A run keeps such a last word as written, and its shape check
# (Test-ObfuscatedIdShape) takes it; that is not changed here. Downstream reads an id's last
# segment as the resource's name, and no fixture or captured billing row shows Azure billing
# such an id, so the offline mask refuses it (Protect-RdaReport.ps1, Test-RdaMaskedUsageId), as
# it refuses a last word '$system', and how to mask it is with the owner. A run gives a
# tenant-scope id of that form one flat token (Test-RdaTenantScopeIdMaskable), which holds no
# word, so such an id is not counted.
function Test-RdaTrailingTypeWordId([string]$Id)
{
    if ([string]::IsNullOrEmpty($Id)) { return $false }
    $Parts = $Id.Split('/')
    return $Parts.Count -ge 4 -and ($Parts.Count % 2) -eq 0 -and $Parts[0] -eq '' -and $Parts[1] -ieq 'subscriptions' -and $Parts[-1] -ne ''
}

# The path where $Path really is: each part that is a link or junction followed (its target
# read, relative to its folder), up to 40 links; parts that do not exist yet are kept.
function Resolve-RdaRealPath([string]$Path)
{
    $Full = [IO.Path]::GetFullPath($Path)
    for ($Hop = 0; $Hop -lt 40; $Hop++)
    {
        $Root = [IO.Path]::GetPathRoot($Full)
        $Parts = $Full.Substring($Root.Length).Split([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries)
        $At = $Root
        $Changed = $false
        for ($I = 0; $I -lt $Parts.Count; $I++)
        {
            $Next = Join-Path $At $Parts[$I]
            $Item = Get-Item -LiteralPath $Next -Force -ErrorAction SilentlyContinue
            if ($null -eq $Item) { $At = Join-Path $At (($Parts[$I..($Parts.Count - 1)]) -join [IO.Path]::DirectorySeparatorChar); break }
            if ($Item.LinkType -and $Item.Target)
            {
                $Target = @($Item.Target)[0]
                $Rest = if ($I + 1 -lt $Parts.Count) { ($Parts[($I + 1)..($Parts.Count - 1)]) -join [IO.Path]::DirectorySeparatorChar } else { '' }
                $Full = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($Target, $At)) $Rest))
                $Changed = $true
                break
            }
            $At = $Next
        }
        if (-not $Changed) { return $At }
    }
    throw 'a path holds too many links'
}

# ConvertFrom-RdaCsvHeaderLine, the reader of a consumption file's header line, is in
# Functions/CsvHeader.Functions.ps1, which Protect-RdaReport.ps1 loads.

# True for a consumption time as the run writes it ('M/d/yyyy h:mm:ss tt', invariant) or an
# ISO 8601 time.
function Test-RdaUsageTime([string]$Text)
{
    $D = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text, 'M/d/yyyy h:mm:ss tt', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$D)) { return $true }
    return $Text -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?\z' -and [datetime]::TryParse($Text, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$D)
}

# True when a masked siteProperties object holds nothing the masking would not keep: each
# token is put back as a word the masking never keeps, the object is masked again into a
# scratch dictionary, and the only part that may become a token is that word. So a part
# kept out of its place (a list word, a number in a host) is found the way it is masked.
function Test-RdaSitePropertiesMasked($Value)
{
    if ($null -eq $Value) { return $true }
    # The mark words are made for this value: letters no text of it holds, so a plain value can
    # never equal one.
    $Json = (ConvertTo-Json -InputObject $Value -Depth 20 -Compress).ToLowerInvariant()
    do { $Base = 'zz' + -join (1..12 | ForEach-Object { [char](97 + (Get-Random -Maximum 26)) }) } while ($Json.Contains($Base))
    $Mark = $Base + 'zz'
    # A token in a key gets a mark word of its own (letters only), so two masked keys of one
    # object stay two entries and each value is checked.
    $KeyMark = @{ N = 0; Issued = [System.Collections.Generic.List[string]]::new() }
    $PutKey = {
        param([string]$K)
        [regex]::Replace($K, '(?:non)?prod_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', {
                param($M)
                $KeyMark.N++
                $N = $KeyMark.N; $Letters = ''
                while ($N -gt 0) { $Letters = [char](97 + (($N - 1) % 26)) + $Letters; $N = [math]::Floor(($N - 1) / 26) }
                $Word = $Base + 'k' + $Letters + 'zz'
                $KeyMark.Issued.Add($Word)
                $Word
            })
    }
    $Put = {
        param($V)
        if ($V -is [string]) { return ($V -replace '(?:non)?prod_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', $Mark) }
        if ($V -is [System.Collections.IDictionary]) { $O = @{}; foreach ($K in @($V.Keys)) { $O[(& $PutKey ([string]$K))] = & $Put $V[$K] }; return $O }
        if ($V -is [System.Management.Automation.PSCustomObject]) { $O = @{}; foreach ($P in $V.PSObject.Properties) { $O[(& $PutKey $P.Name)] = & $Put $P.Value }; return $O }
        if ($V -is [System.Collections.IEnumerable]) { return , @(foreach ($I in $V) { , (& $Put $I) }) }
        return $V
    }
    $Saved = $Global:FreeTextDictionary
    try
    {
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $null = Protect-SitePropertiesValue (& $Put $Value)
        # Only the mark words given out count (a plain 'jazz' after a token does not).
        $Marks = '^(?:' + ((@($Mark) + @($KeyMark.Issued) | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')+\z'
        return @($Global:FreeTextDictionary.Keys | Where-Object { $_ -cnotmatch $Marks }).Count -eq 0
    }
    finally { $Global:FreeTextDictionary = $Saved }
}
