# VMSS collector creation-time tests
# Run with: Invoke-Pester ./Tests/VMSSCreationTime.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Virtual machine scale sets created with Flexible orchestration do not return
# properties.timeCreated, and an empty Flexible scale set returns no sku either.
# Casting the missing creation time with [datetime] throws "Cannot convert null
# to type System.DateTime", and looking up a null sku name in the size map
# throws "Index operation failed; the array index evaluated to null". Either
# throw fails the whole VMSS collector and drops every scale set from the
# inventory, not only the one with the missing value.
#
# This test invokes the REAL Services/Containers/VMSS.ps1 collector with
# synthetic scale-set records whose timeCreated is absent, null, or a valid
# timestamp, plus an empty Flexible scale set, and asserts that CreatedTime
# falls back to 'Unknown' (the same convention as
# Services/Compute/VirtualMachines.ps1) while every other column is unchanged.
# Get-AzComputeResourceSku is mocked, so no live Azure is needed.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Containers', 'VMSS.ps1' | Resolve-Path | Select-Object -ExpandProperty Path

    # All GUIDs below are the canonical Azure documentation placeholder; they
    # are not real subscription or resource identifiers.
    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:DocGuid; Name = 'sub-placeholder' })

    # Offline-portability shim: Mock needs a command to intercept even on a box
    # without the Az.Compute module installed.
    function Get-AzComputeResourceSku { }

    # Build one scale-set record in the shape the collector consumes.
    # -TimeCreatedMode: 'Absent' omits the property, 'Null' sets it to $null,
    # 'Value' sets it to -TimeCreated.
    function New-VmssRecord
    {
        param(
            [string]$Name,
            [ValidateSet('Absent', 'Null', 'Value')][string]$TimeCreatedMode,
            [string]$TimeCreated
        )

        $Props = [ordered]@{
            orchestrationMode     = 'Flexible'
            virtualMachineProfile = [pscustomobject]@{
                licenseType    = 'Windows_Server'
                storageProfile = [pscustomobject]@{
                    osDisk         = [pscustomobject]@{
                        osType      = 'Windows'
                        diskSizeGB  = 128
                        managedDisk = [pscustomobject]@{ storageAccountType = 'Premium_LRS' }
                    }
                    imageReference = [pscustomobject]@{ offer = 'WindowsServer'; sku = '2022-datacenter' }
                }
                networkProfile = [pscustomobject]@{
                    networkInterfaceConfigurations = @(
                        [pscustomobject]@{ properties = [pscustomobject]@{ enableAcceleratedNetworking = $true } }
                    )
                }
            }
        }
        if ($TimeCreatedMode -eq 'Null') { $Props['timeCreated'] = $null }
        if ($TimeCreatedMode -eq 'Value') { $Props['timeCreated'] = $TimeCreated }

        return [pscustomobject]@{
            TYPE           = 'microsoft.compute/virtualmachinescalesets'
            id             = "/subscriptions/$($script:DocGuid)/resourcegroups/rg-vmss/providers/microsoft.compute/virtualmachinescalesets/$Name"
            NAME           = $Name
            RESOURCEGROUP  = 'rg-vmss'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
            sku            = [pscustomobject]@{ name = 'Standard_D2s_v3'; tier = 'Standard'; capacity = 3 }
            PROPERTIES     = [pscustomobject]$Props
        }
    }

    # An empty Flexible scale set (no instances yet): Azure returns no sku, no
    # virtualMachineProfile and no timeCreated for it.
    function New-EmptyFlexibleVmssRecord
    {
        param([string]$Name)
        return [pscustomobject]@{
            TYPE           = 'microsoft.compute/virtualmachinescalesets'
            id             = "/subscriptions/$($script:DocGuid)/resourcegroups/rg-vmss/providers/microsoft.compute/virtualmachinescalesets/$Name"
            NAME           = $Name
            RESOURCEGROUP  = 'rg-vmss'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
            PROPERTIES     = [pscustomobject]@{
                orchestrationMode        = 'Flexible'
                platformFaultDomainCount = 1
                provisioningState        = 'Succeeded'
            }
        }
    }

    # Every column except CreatedTime, as the collector should emit it for a
    # record built by New-VmssRecord with the mocked SKU below.
    function Get-ExpectedColumns
    {
        param([string]$Name)
        return [ordered]@{
            'ID'                           = "/subscriptions/$($script:DocGuid)/resourcegroups/rg-vmss/providers/microsoft.compute/virtualmachinescalesets/$Name"
            'Subscription'                 = 'sub-placeholder'
            'ResourceGroup'                = 'rg-vmss'
            'AKS'                          = $null
            'Name'                         = $Name
            'Location'                     = 'eastus'
            'SKUTier'                      = 'Standard'
            'VMSize'                       = 'Standard_D2s_v3'
            'Instances'                    = 3
            'AutoscaleEnabled'             = $false
            'License'                      = 'Windows_Server'
            'vCPUs'                        = 2
            'RAM'                          = 8
            'VMOS'                         = 'Windows'
            'OSImage'                      = 'WindowsServer'
            'ImageVersion'                 = '2022-datacenter'
            'DiskSizeGB'                   = 128
            'StorageAccountType'           = 'Premium_LRS'
            'AcceleratedNetworkingEnabled' = $true
        }
    }

    function Invoke-VmssCollector
    {
        param($Resources)
        return @(& $script:Collector -Sub $script:Subs -Resources $Resources -Task 'Processing' -ResourceIdDictionary $null)
    }
}

Describe 'VMSS collector CreatedTime' {

    BeforeAll {
        Mock -CommandName Get-AzComputeResourceSku -MockWith {
            [pscustomobject]@{
                Name         = 'Standard_D2s_v3'
                ResourceType = 'virtualMachines'
                Capabilities = @(
                    [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                    [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' }
                )
            }
        }

        # A fixed timestamp with no offset formats the same in every time zone.
        $script:AbsentRec = New-VmssRecord -Name 'vmss-absent' -TimeCreatedMode Absent
        $script:NullRec = New-VmssRecord -Name 'vmss-null' -TimeCreatedMode Null
        $script:ValidRec = New-VmssRecord -Name 'vmss-valid' -TimeCreatedMode Value -TimeCreated '2024-03-15T09:41:27.1234567'
    }

    It "writes 'Unknown' when properties.timeCreated is absent" {
        $script:AbsentRec.PROPERTIES.PSObject.Properties.Name | Should -Not -Contain 'timeCreated'
        $Rec = @(Invoke-VmssCollector -Resources @($script:AbsentRec))[0]
        $Rec.CreatedTime | Should -BeExactly 'Unknown'
    }

    It "writes 'Unknown' when properties.timeCreated is null" {
        $script:NullRec.PROPERTIES.PSObject.Properties.Name | Should -Contain 'timeCreated'
        $Rec = @(Invoke-VmssCollector -Resources @($script:NullRec))[0]
        $Rec.CreatedTime | Should -BeExactly 'Unknown'
    }

    It "formats a valid timeCreated as 'yyyy-MM-dd HH:mm'" {
        $Rec = @(Invoke-VmssCollector -Resources @($script:ValidRec))[0]
        $Rec.CreatedTime | Should -BeExactly '2024-03-15 09:41'
    }

    It 'formats a UTC timeCreated (as Azure returns it) in local time' {
        $Iso = '2024-03-15T09:41:27.1234567Z'
        $Rec = @(Invoke-VmssCollector -Resources @(New-VmssRecord -Name 'vmss-utc' -TimeCreatedMode Value -TimeCreated $Iso))[0]
        $Expected = [System.DateTimeOffset]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
        $Rec.CreatedTime | Should -BeExactly $Expected
    }

    It 'emits a record for an empty Flexible scale set with no sku, profile or timeCreated' {
        $Rec = @(Invoke-VmssCollector -Resources @(New-EmptyFlexibleVmssRecord -Name 'vmss-empty'))[0]
        $Rec.Name | Should -BeExactly 'vmss-empty'
        $Rec.CreatedTime | Should -BeExactly 'Unknown'
        $Rec.VMSize | Should -BeNullOrEmpty
        $Rec.vCPUs | Should -Be '0'
        $Rec.RAM | Should -Be '0'
    }

    It 'emits one record per scale set when only some lack timeCreated or sku' {
        $Recs = @(Invoke-VmssCollector -Resources @($script:AbsentRec, $script:NullRec, $script:ValidRec, (New-EmptyFlexibleVmssRecord -Name 'vmss-empty')))
        $Recs.Count | Should -Be 4
        ($Recs | ForEach-Object { $_.Name }) | Should -Be @('vmss-absent', 'vmss-null', 'vmss-valid', 'vmss-empty')
        ($Recs | ForEach-Object { $_.CreatedTime }) | Should -Be @('Unknown', 'Unknown', '2024-03-15 09:41', 'Unknown')
        ($Recs | ForEach-Object { $_.vCPUs }) | Should -Be @(2, 2, 2, '0')
    }

    It 'leaves every other column unchanged for <Name>' -ForEach @(
        @{ Name = 'vmss-absent' }
        @{ Name = 'vmss-null' }
        @{ Name = 'vmss-valid' }
    ) {
        $Record = @($script:AbsentRec, $script:NullRec, $script:ValidRec) | Where-Object { $_.NAME -eq $Name }
        $Rec = @(Invoke-VmssCollector -Resources @($Record))[0]
        $Expected = Get-ExpectedColumns -Name $Name

        @($Rec.Keys | Sort-Object) | Should -Be @(@($Expected.Keys) + 'CreatedTime' | Sort-Object)
        foreach ($Key in $Expected.Keys)
        {
            $Rec[$Key] | Should -Be $Expected[$Key] -Because "column '$Key' must not depend on timeCreated"
        }
    }
}
