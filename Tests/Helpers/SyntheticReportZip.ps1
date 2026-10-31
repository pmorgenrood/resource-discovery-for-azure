# The report zip the zip-reading test files (DataIntegrity, Frontdoor,
# Obfuscation, OutputCompleteness, ProdNonprodPrefix, ReferentialIntegrity,
# ReportSchema) check.
#
#   . (Join-Path $PSScriptRoot 'Helpers/SyntheticReportZip.ps1')
#   $script:Fixture = Get-RdaTestReportZip
#   ...
#   AfterAll { Remove-RdaTestReportZip $script:Fixture }
#
# Get-RdaTestReportZip returns, in this order of preference:
#   1. $env:TEST_ZIP_PATH, when set;
#   2. the newest Tests/ResourcesReport_*.zip, when one exists (a real report
#      someone copied in);
#   3. a report it generates: the REAL ResourceInventory.ps1 run offline with
#      -Obfuscate, metrics and consumption on, in a child pwsh, over a synthetic
#      estate, the way ObfuscationRoundTrip.Tests.ps1 runs it. The run's local
#      ObfuscationDictionary_*.json is returned with it.
# The result has ZipPath, DictionaryPath ($null when there is none to offer),
# Generated, WorkDir and, for a generated zip, the run's Exit code and Console.
# A generated zip lives in a temp dir of its own, which Remove-RdaTestReportZip
# deletes; a zip the caller supplied is never touched.
#
# The synthetic estate covers what those files check: VMs with managed disks
# (disk managedBy -> AssociatedResource), a SQL server with a database in an
# elastic pool, a SQL VM on its parent VM, a classic Front Door with a WAF
# policy and a Standard Front Door profile, an AVD host pool with a session host
# on a VM, an AKS cluster with its scale set in the 'MC_' node resource group
# (aks_ hint), a scale set outside it (vmss_ hint), a Databricks workspace
# (databricks_ hint), a storage account, tagged resources, a non-production
# (nonprod_) VM, and usage rows for resources in and out of the inventory; and,
# for the cross-reference checks, a VM in an availability set and one in a scale
# set, a snapshot of a disk, a public IP on a NIC, an App Service on its plan, a
# Purview account, a Machine Learning workspace with its storage account and key
# vault, a SQL managed instance with a database, and a Traffic Manager profile.
# Placeholder ids and generic names only. No live Azure.

# The two shapes -Obfuscate writes, for the tests to match:
#   - a token: 'prod_' or 'nonprod_', a type hint on a resource name of a
#     Databricks, AKS-managed ('MC_' group) or scale set resource, and a GUID
#     (Name, Subscription and ResourceGroup values, tag values, free text);
#   - a masked resource id (ID values and every cross-reference to another
#     resource's id, consumption ResourceIds): the ARM id with its subscription,
#     resource group and each resource name replaced by a token. Namespace and
#     type segments are kept, the subscription and resource group tokens carry no
#     type hint, and the fixed name '$system' is kept (Get-ObfuscatedResourceId
#     in ResourceInventory.ps1).
function Get-RdaTokenPattern
{
    '^(prod|nonprod)_(databricks_|aks_|vmss_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

function Get-RdaMaskedIdPattern
{
    $Guid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    $Scope = '(?:prod|nonprod)_' + $Guid
    $Name = '(?:prod|nonprod)_(?:databricks_|aks_|vmss_)?' + $Guid
    '^/subscriptions/' + $Scope + '(?:/resourcegroups/' + $Scope + ')?(?:/providers/[^/]+(?:/[^/]+/(?:' + $Name + '|\$system))+)*$'
}

# A masked resource id, or a token (an id that is not an ARM id is masked to a
# single token).
function Get-RdaObfuscatedIdPattern
{
    '(?:' + (Get-RdaMaskedIdPattern) + ')|(?:' + (Get-RdaTokenPattern) + ')'
}

function Get-RdaTestReportZip
{
    [CmdletBinding()]
    param([string]$TestsRoot = (Split-Path -Path $PSScriptRoot -Parent))

    if (-not [string]::IsNullOrEmpty($env:TEST_ZIP_PATH))
    {
        return [pscustomobject]@{ ZipPath = $env:TEST_ZIP_PATH; DictionaryPath = $null; Generated = $false; WorkDir = $null; Exit = $null; Console = $null }
    }
    $Real = Get-ChildItem -Path $TestsRoot -Filter 'ResourcesReport_*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -ne $Real)
    {
        return [pscustomobject]@{ ZipPath = $Real.FullName; DictionaryPath = $null; Generated = $false; WorkDir = $null; Exit = $null; Console = $null }
    }
    return (New-RdaSyntheticReportZip -RepoRoot (Split-Path -Path $TestsRoot -Parent) -TestsRoot $TestsRoot)
}

function Remove-RdaTestReportZip
{
    param($Fixture)
    if ($null -ne $Fixture -and $Fixture.Generated -and $Fixture.WorkDir -and (Test-Path -LiteralPath $Fixture.WorkDir))
    {
        Remove-Item -LiteralPath $Fixture.WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-RdaSyntheticReportZip
{
    param([string]$RepoRoot, [string]$TestsRoot, [switch]$Plain)

    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RdaSyntheticReport_' + $PID + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $Tree = Join-Path $WorkDir 'tree'
    $Out = Join-Path $WorkDir 'out'
    New-Item -ItemType Directory -Path $Tree -Force | Out-Null
    New-Item -ItemType Directory -Path $Out -Force | Out-Null
    foreach ($Item in @('ResourceInventory.ps1', 'Reveal.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $RepoRoot $Item) -Destination $Tree -Recurse -Force
    }

    # Stand-in Az.Monitor: Get-AzMetric runs in ForEach-Object -Parallel and
    # thread-job runspaces, which only a module on PSModulePath reaches.
    $MonitorDir = Join-Path $WorkDir 'modules/Az.Monitor'
    New-Item -ItemType Directory -Path $MonitorDir -Force | Out-Null
    @'
function Get-AzMetric
{
    [CmdletBinding()]
    param([string]$ResourceId, [string[]]$MetricName, [datetime]$StartTime, [datetime]$EndTime, [timespan]$TimeGrain, [string]$AggregationType, $DefaultProfile, [switch]$DetailedOutput)
    foreach ($Name in @($MetricName))
    {
        $Data = [System.Collections.Generic.List[object]]::new()
        $Data.Add([pscustomobject]@{ TimeStamp = $StartTime; Average = 2; Minimum = 1; Maximum = 3; Total = 6; Count = 3 })
        [pscustomobject]@{ Id = $ResourceId + '/providers/Microsoft.Insights/metrics/' + $Name; Name = [pscustomobject]@{ Value = $Name; LocalizedValue = $Name }; Data = $Data }
    }
}
Export-ModuleMember -Function Get-AzMetric
'@ | Set-Content -Path (Join-Path $MonitorDir 'Az.Monitor.psm1') -Encoding utf8

    $Harness = Join-Path $WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [string]$Modules, [string]$StandIns, [switch]$Plain)
$PSStyle.OutputRendering = 'PlainText'
$env:PSModulePath = $Modules + [System.IO.Path]::PathSeparator + $env:PSModulePath
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$SubId = '12345678-1234-1234-1234-123456789012'
$TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$Rg = "/subscriptions/$SubId/resourceGroups/rg-demo"
$Base = "$Rg/providers"
$AksBase = "/subscriptions/$SubId/resourceGroups/rg-aks-demo/providers"
$NodeRg = 'MC_rg-aks-demo_aks-demo_eastus'
$NodeBase = "/subscriptions/$SubId/resourceGroups/$NodeRg/providers"
$Global:StandInSubs = @([pscustomobject]@{ id = $SubId; name = 'Demo Subscription'; tenantId = $TenantId; state = 'Enabled' })

function New-Vm([string]$Name, [string]$Os, [hashtable]$Tags)
{
    @{ id = "$Base/Microsoft.Compute/virtualMachines/$Name"; name = $Name; type = 'microsoft.compute/virtualmachines'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; tags = $Tags
        properties = @{ hardwareProfile = @{ vmSize = 'Standard_D2s_v3' }; timeCreated = '2024-03-15T09:41:27Z'
            storageProfile = @{ osDisk = @{ osType = $Os; managedDisk = @{ id = "$Base/Microsoft.Compute/disks/osdisk-$Name"; storageAccountType = 'Premium_LRS' } }; imageReference = @{ publisher = 'publisher-demo'; offer = 'ubuntu-24_04-lts'; sku = 'server'; exactVersion = '24.04.202409120' } }
            extended = @{ instanceView = @{ powerState = @{ displayStatus = 'VM running' }; osName = 'ubuntu'; osVersion = '24.04' } } } }
}
function New-Disk([string]$Vm)
{
    @{ id = "$Base/Microsoft.Compute/disks/osdisk-$Vm"; name = "osdisk-$Vm"; type = 'microsoft.compute/disks'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; managedBy = "$Base/Microsoft.Compute/virtualMachines/$Vm"
        sku = @{ name = 'Premium_LRS'; tier = 'Premium' }; properties = @{ diskSizeGB = 32; diskState = 'Attached'; osType = 'Linux'; timeCreated = '2024-03-15T09:41:27Z'; diskIOPSReadWrite = 120; diskMBpsReadWrite = 25 } }
}

$Global:StandInRows = @(
    (New-Vm 'vm-demo' 'Linux' @{ Environment = 'production'; CostCenter = 'cc-demo' } | ForEach-Object { $_.properties.availabilitySet = @{ id = "$Base/Microsoft.Compute/availabilitySets/avset-demo" }; $_ })
    (New-Vm 'vm-vmss-demo-0' 'Linux' $null | ForEach-Object { $_.properties.virtualMachineScaleSet = @{ id = "$Base/Microsoft.Compute/virtualMachineScaleSets/vmss-demo" }; $_ })
    (New-Disk 'vm-vmss-demo-0')
    @{ id = "$Base/Microsoft.Compute/availabilitySets/avset-demo"; name = 'avset-demo'; type = 'microsoft.compute/availabilitysets'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; sku = @{ name = 'Aligned' }
        properties = @{ platformFaultDomainCount = 2; platformUpdateDomainCount = 5; virtualMachines = @(@{ id = "$Base/Microsoft.Compute/virtualMachines/vm-demo" }) } }
    @{ id = "$Base/Microsoft.Compute/snapshots/snap-demo"; name = 'snap-demo'; type = 'microsoft.compute/snapshots'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; sku = @{ name = 'Standard_LRS' }
        properties = @{ diskSizeGB = 32; provisioningState = 'Succeeded'; osType = 'Linux'; incremental = $true; timeCreated = '2024-03-16T09:41:27Z'; creationData = @{ createOption = 'Copy'; sourceResourceId = "$Base/Microsoft.Compute/disks/osdisk-vm-demo" } } }
    @{ id = "$Base/Microsoft.Network/networkInterfaces/nic-demo"; name = 'nic-demo'; type = 'microsoft.network/networkinterfaces'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ ipConfigurations = @(@{ id = "$Base/Microsoft.Network/networkInterfaces/nic-demo/ipConfigurations/ipconfig1"; name = 'ipconfig1' }) } }
    @{ id = "$Base/Microsoft.Network/publicIPAddresses/pip-demo"; name = 'pip-demo'; type = 'microsoft.network/publicipaddresses'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; sku = @{ name = 'Standard' }
        properties = @{ publicIPAllocationMethod = 'Static'; publicIPAddressVersion = 'IPv4'; provisioningState = 'Succeeded'; ipConfiguration = @{ id = "$Base/Microsoft.Network/networkInterfaces/nic-demo/ipConfigurations/ipconfig1" } } }
    @{ id = "$Base/Microsoft.Web/serverFarms/plan-demo"; name = 'plan-demo'; type = 'microsoft.web/serverfarms'; kind = 'app'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; sku = @{ name = 'P1v3'; tier = 'PremiumV3'; capacity = 1 }
        properties = @{ status = 'Ready'; numberOfSites = 1 } }
    @{ id = "$Base/Microsoft.Web/sites/app-demo"; name = 'app-demo'; type = 'microsoft.web/sites'; kind = 'app'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ enabled = $true; state = 'Running'; sku = 'PremiumV3'; availabilityState = 'Normal'; containerSize = 0; serverFarmId = "$Base/Microsoft.Web/serverFarms/plan-demo" } }
    @{ id = "$Base/Microsoft.Purview/accounts/pview-demo"; name = 'pview-demo'; type = 'microsoft.purview/accounts'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ sku = @{ name = 'Standard'; capacity = 1 }; createdBy = 'creator-demo'; friendlyName = 'Purview Demo'; createdAt = '2024-03-15T09:41:27Z' } }
    @{ id = "$Base/Microsoft.KeyVault/vaults/kv-demo"; name = 'kv-demo'; type = 'microsoft.keyvault/vaults'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ sku = @{ family = 'A'; name = 'standard' }; tenantId = $TenantId; enableSoftDelete = $true; enableRbacAuthorization = $true } }
    @{ id = "$Base/Microsoft.MachineLearningServices/workspaces/mlw-demo"; name = 'mlw-demo'; type = 'microsoft.machinelearningservices/workspaces'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; sku = @{ name = 'Basic' }
        properties = @{ friendlyName = 'ML Demo'; description = 'demo workspace'; storageAccount = "$Base/Microsoft.Storage/storageAccounts/stdemo"; keyVault = "$Base/Microsoft.KeyVault/vaults/kv-demo"; creationTime = '2024-03-15T09:41:27Z' } }
    @{ id = "$Base/Microsoft.Sql/managedInstances/sqlmi-demo"; name = 'sqlmi-demo'; type = 'microsoft.sql/managedinstances'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; sku = @{ name = 'GP_Gen5'; tier = 'GeneralPurpose'; family = 'Gen5'; capacity = 4 }
        properties = @{ vCores = 4; storageSizeInGB = 256; licenseType = 'LicenseIncluded'; state = 'Ready'; zoneRedundant = $false; instancePoolId = "$Base/Microsoft.Sql/instancePools/ipool-demo" } }
    @{ id = "$Base/Microsoft.Sql/managedInstances/sqlmi-demo/databases/midb-demo"; name = 'midb-demo'; type = 'microsoft.sql/managedinstances/databases'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ collation = 'SQL_Latin1_General_CP1_CI_AS'; creationDate = '2024-03-15T09:41:27Z'; status = 'Online' } }
    (New-Disk 'vm-demo')
    (New-Vm 'vm-test-demo' 'Linux' @{ Environment = 'test' })
    (New-Disk 'vm-test-demo')
    (New-Vm 'vm-sql-demo' 'Windows' $null)
    (New-Disk 'vm-sql-demo')
    (New-Vm 'vm-avd-demo-0' 'Windows' $null)
    (New-Disk 'vm-avd-demo-0')
    @{ id = "$Base/Microsoft.SqlVirtualMachine/SqlVirtualMachines/vm-sql-demo"; name = 'vm-sql-demo'; type = 'microsoft.sqlvirtualmachine/sqlvirtualmachines'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ virtualMachineResourceId = "$Base/Microsoft.Compute/virtualMachines/vm-sql-demo"; sqlServerLicenseType = 'PAYG'; sqlImageOffer = 'SQL2022-WS2022'; sqlManagement = 'Full'; sqlImageSku = 'Standard' } }
    @{ id = "$Base/Microsoft.Sql/servers/sqlsrv-demo"; name = 'sqlsrv-demo'; type = 'microsoft.sql/servers'; kind = 'v12.0'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; properties = @{ state = 'Ready'; version = '12.0' } }
    @{ id = "$Base/Microsoft.Sql/servers/sqlsrv-demo/databases/sqldb-demo"; name = 'sqldb-demo'; type = 'microsoft.sql/servers/databases'; kind = 'v12.0,user,vcore'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ status = 'Online'; maxSizeBytes = 34359738368; currentSku = @{ tier = 'GeneralPurpose'; capacity = 2 }; currentBackupStorageRedundancy = 'Geo'; elasticPoolId = "$Base/Microsoft.Sql/servers/sqlsrv-demo/elasticPools/pool-demo" } }
    @{ id = "$Base/Microsoft.Sql/servers/sqlsrv-demo/elasticPools/pool-demo"; name = 'pool-demo'; type = 'microsoft.sql/servers/elasticpools'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'; properties = @{ state = 'Ready' } }
    @{ id = "$Base/Microsoft.Network/frontdoors/fd-demo"; name = 'fd-demo'; type = 'microsoft.network/frontdoors'; location = 'global'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ enabledState = 'Enabled'; provisioningState = 'Succeeded'; frontendEndpoints = @(
                @{ name = 'fe-demo'; properties = @{ hostName = 'fd-demo.example.test'; webApplicationFirewallPolicyLink = @{ id = "$Base/Microsoft.Network/FrontDoorWebApplicationFirewallPolicies/wafdemo" } } }
            ) } }
    @{ id = "$Base/Microsoft.Network/FrontDoorWebApplicationFirewallPolicies/wafdemo"; name = 'wafdemo'; type = 'microsoft.network/frontdoorwebapplicationfirewallpolicies'; location = 'global'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        sku = @{ name = 'Classic_AzureFrontDoor' }; properties = @{ policySettings = @{ enabledState = 'Enabled'; mode = 'Prevention' } } }
    @{ id = "$Base/Microsoft.Cdn/profiles/afd-demo"; name = 'afd-demo'; type = 'microsoft.cdn/profiles'; kind = 'frontdoor'; location = 'global'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        sku = @{ name = 'Standard_AzureFrontDoor' }; properties = @{ provisioningState = 'Succeeded'; resourceState = 'Active' } }
    @{ id = "$Base/Microsoft.DesktopVirtualization/hostpools/hp-demo"; name = 'hp-demo'; type = 'microsoft.desktopvirtualization/hostpools'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ hostPoolType = 'Pooled'; loadBalancerType = 'BreadthFirst'; maxSessionLimit = 10; preferredAppGroupType = 'Desktop' } }
    @{ id = "$AksBase/Microsoft.ContainerService/managedClusters/aks-demo"; name = 'aks-demo'; type = 'microsoft.containerservice/managedclusters'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-aks-demo'
        sku = @{ name = 'Base'; tier = 'Free' }; tags = @{ Environment = 'production' }
        properties = @{ kubernetesVersion = '1.29.4'; nodeResourceGroup = $NodeRg; networkProfile = @{ loadBalancerSku = 'Standard' }
            agentPoolProfiles = @(@{ name = 'nodepool1'; type = 'VirtualMachineScaleSets'; mode = 'System'; osType = 'Linux'; vmSize = 'Standard_D2s_v3'; osDiskSizeGB = 128; count = 2; maxPods = 30; orchestratorVersion = '1.29.4'; enableAutoScaling = $false }) } }
    @{ id = "$NodeBase/Microsoft.Compute/virtualMachineScaleSets/aks-nodepool1-vmss"; name = 'aks-nodepool1-vmss'; type = 'microsoft.compute/virtualmachinescalesets'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = $NodeRg
        sku = @{ name = 'Standard_D2s_v3'; tier = 'Standard'; capacity = 2 }
        properties = @{ timeCreated = '2024-03-15T09:41:27Z'; virtualMachineProfile = @{ storageProfile = @{ osDisk = @{ osType = 'Linux'; diskSizeGB = 128; managedDisk = @{ storageAccountType = 'Premium_LRS' } }; imageReference = @{ offer = 'aks'; version = 'latest' } } } } }
    @{ id = "$Base/Microsoft.Compute/virtualMachineScaleSets/vmss-demo"; name = 'vmss-demo'; type = 'microsoft.compute/virtualmachinescalesets'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        sku = @{ name = 'Standard_D2s_v3'; tier = 'Standard'; capacity = 1 }
        properties = @{ timeCreated = '2024-03-15T09:41:27Z'; virtualMachineProfile = @{ storageProfile = @{ osDisk = @{ osType = 'Linux'; diskSizeGB = 64; managedDisk = @{ storageAccountType = 'Standard_LRS' } }; imageReference = @{ offer = 'ubuntu-24_04-lts'; version = 'latest' } } } } }
    @{ id = "$Base/Microsoft.Databricks/workspaces/dbw-demo"; name = 'dbw-demo'; type = 'microsoft.databricks/workspaces'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        sku = @{ name = 'premium' }; properties = @{ createdDateTime = '2024-03-15T09:41:27Z'; managedResourceGroupId = "/subscriptions/$SubId/resourceGroups/rg-dbw-demo-managed"; parameters = @{ storageAccountName = @{ value = 'dbstoragedemo' }; storageAccountSkuName = @{ value = 'Standard_GRS' } } } }
    @{ id = "$Base/Microsoft.Network/trafficManagerProfiles/tm-demo"; name = 'tm-demo'; type = 'microsoft.network/trafficmanagerprofiles'; location = 'global'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ profileStatus = 'Enabled'; trafficRoutingMethod = 'Priority'; monitorConfig = @{ profileMonitorStatus = 'Online' } } }
    @{ id = "$Base/Microsoft.Storage/storageAccounts/stdemo"; name = 'stdemo'; type = 'microsoft.storage/storageaccounts'; kind = 'StorageV2'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        sku = @{ name = 'Standard_LRS'; tier = 'Standard' }; properties = @{ accessTier = 'Hot'; primaryLocation = 'eastus'; statusOfPrimary = 'available'; creationTime = '2024-03-15T09:41:27Z' } }
)
# desktopvirtualizationresources rows: the session host on vm-avd-demo-0.
$Global:StandInAvdRows = @(
    @{ id = "$Base/Microsoft.DesktopVirtualization/hostpools/hp-demo/sessionhosts/vm-avd-demo-0"; name = 'hp-demo/vm-avd-demo-0'; type = 'microsoft.desktopvirtualization/hostpools/sessionhosts'; location = 'eastus'; subscriptionId = $SubId; resourceGroup = 'rg-demo'
        properties = @{ resourceId = "$Base/Microsoft.Compute/virtualMachines/vm-avd-demo-0"; agentVersion = '1.0.0.0'; allowNewSession = $true; updateState = 'Succeeded'; status = 'Available'; osVersion = '10.0.22631' } }
)
# Usage rows: resources in the inventory, and resources that are not in it.
$Global:StandInUsage = @(
    @{ Uri = "$Base/Microsoft.Compute/virtualMachines/vm-demo"; Category = 'Virtual Machines' }
    @{ Uri = "$Base/Microsoft.Compute/disks/osdisk-vm-demo"; Category = 'Storage' }
    @{ Uri = "$Base/Microsoft.Sql/servers/sqlsrv-demo/databases/sqldb-demo"; Category = 'SQL Database' }
    @{ Uri = "$Base/Microsoft.Sql/servers/sqlsrv-demo/databases/sqldb-gone"; Category = 'SQL Database' }
    @{ Uri = "$Base/Microsoft.Network/frontdoors/fd-demo"; Category = 'Azure Front Door Service' }
    @{ Uri = "/subscriptions/$SubId/resourceGroups/$NodeRg/providers/Microsoft.Compute/disks/osdisk-aks-gone"; Category = 'Storage' }
    @{ Uri = "/subscriptions/$SubId/providers/Microsoft.Insights/components/insights-gone"; Category = 'Application Insights' }
) | ForEach-Object {
    [pscustomobject]@{
        InstanceData     = (@{ 'Microsoft.Resources' = @{ resourceUri = $_.Uri; location = 'eastus'; additionalInfo = @{ ServiceType = 'Standard'; ConsumptionMeter = 'meter-demo' } } } | ConvertTo-Json -Depth 5 -Compress)
        MeterCategory    = $_.Category; MeterId = 'meter-demo'; MeterName = 'Hours'; MeterRegion = 'US East'; MeterSubCategory = 'General'
        Quantity         = [decimal]24; Unit = '1 Hour'
        UsageStartTime   = [datetime]::SpecifyKind([datetime]'2026-10-01T00:00:00', 'Utc'); UsageEndTime = [datetime]::SpecifyKind([datetime]'2026-10-02T00:00:00', 'Utc')
    }
}
function global:Invoke-StandInGraph
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'account show*') { return ('{"user":{"name":"tester"},"tenantId":"' + $TenantId + '"}') }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -InputObject @($Global:StandInSubs) -Compress) }
    if ($Joined -like 'graph*')
    {
        $Rows = @(if ($Joined -match 'desktopvirtualizationresources') { $Global:StandInAvdRows } else { $Global:StandInRows })
        if ($Joined -match 'summarize count\(\)') { return ('{{"data":[{{"count_":{0}}}],"count":1}}' -f $Rows.Count) }
        return (@{ data = $Rows; count = $Rows.Count } | ConvertTo-Json -Depth 10 -Compress)
    }
    return $null
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }; Subscription = [pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012'; Name = 'Demo Subscription' }; Account = [pscustomobject]@{ Id = 'tester' } } }
function global:Set-AzContext { [CmdletBinding()] param($Subscription, $Scope, $Context) $null }
function global:Connect-AzAccount { throw 'no sign-in in this harness' }
function global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
function global:Get-AzComputeResourceSku
{
    param($Location)
    [pscustomobject]@{ Name = 'Standard_D2s_v3'; ResourceType = 'virtualMachines'; Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '2' }, [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' }) }
}
function global:Get-UsageAggregates
{
    [CmdletBinding()]
    param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken)
    [pscustomobject]@{ UsageAggregations = @($Global:StandInUsage | ForEach-Object { [pscustomobject]@{ Properties = $_.PSObject.Copy() } }); ContinuationToken = $null }
}
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Json = { param($Obj) [pscustomobject]@{ StatusCode = 200; Content = ($Obj | ConvertTo-Json -Depth 10) } }
    if ($Target -match '/roleAssignments\?') { return (& $Json @{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$SubId/providers/Microsoft.Authorization/roleDefinitions/reader"; scope = "/subscriptions/$SubId"; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) }) }
    if ($Target -match '/roleDefinitions/') { return (& $Json @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } }) }
    if ($Target -match '/providers/Microsoft\.Authorization/permissions\?') { return (& $Json @{ value = @(@{ actions = @('*/read'); notActions = @() }) }) }
    if ($Target -match '/UsageAggregates\?') { return (& $Json @{ value = @(@{ properties = @{ quantity = 24; instanceData = $Global:StandInUsage[0].InstanceData } }) }) }
    if ($Target -match 'Microsoft\.ResourceGraph/resources') { return (& $Json @{ data = @(@{ subscriptionId = $SubId; ResourceCount = @($Global:StandInRows).Count }) }) }
    throw ('no stand-in for {0} {1}' -f $Method, $Target)
}

# Az PowerShell sign-in, subscription list and Resource Graph paging on top of the stand-ins above.
$env:RDA_AZPS_STANDINS = $StandIns
. $StandIns
Set-Location $Tree
$Params = @{ SubscriptionID = $SubId; OutputDirectory = $Out }
if (-not $Plain) { $Params.Obfuscate = $true }
& (Join-Path $Tree 'ResourceInventory.ps1') @Params
exit $LASTEXITCODE
'@ | Set-Content -Path $Harness -Encoding utf8

    $Pwsh = (Get-Process -Id $PID).Path
    $ArgList = @('-NoProfile', '-NonInteractive', '-File', $Harness, '-Tree', $Tree, '-Out', $Out, '-Modules', (Join-Path $WorkDir 'modules'), '-StandIns', (Join-Path $TestsRoot 'Helpers/AzPsStandIns.ps1'))
    if ($Plain) { $ArgList += '-Plain' }
    $Console = @(& $Pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
    $Exit = $LASTEXITCODE
    $Zip = Get-ChildItem -Path $Out -Filter 'ResourcesReport_*.zip' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $Dict = Get-ChildItem -Path $Out -Filter 'ObfuscationDictionary_*.json' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    return [pscustomobject]@{
        ZipPath        = $(if ($null -ne $Zip) { $Zip.FullName } else { $null })
        DictionaryPath = $(if ($null -ne $Dict) { $Dict.FullName } else { $null })
        Generated      = $true
        WorkDir        = $WorkDir
        Exit           = $Exit
        Console        = ($Console -join "`n")
    }
}
