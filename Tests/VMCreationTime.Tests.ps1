# VM collector creation-time tests
# Run with: Invoke-Pester ./Tests/VMCreationTime.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Services/Compute/VirtualMachines.ps1 casts properties.timeCreated with
# [datetime]. A missing or null value is written as 'Unknown', but a value that
# is present and does not convert to a date (for example an empty string)
# throws "Cannot convert value ... to type System.DateTime". The throw fails the
# whole VM collector and drops every virtual machine from the inventory, not
# only the one with the bad value.
#
# This test invokes the REAL Services/Compute/VirtualMachines.ps1 collector with
# synthetic VM records whose timeCreated is absent, null, a valid timestamp, an
# empty string or 'not-a-date', and asserts that every VM is written, that
# CreatedTime is 'Unknown' when the value is missing or not a date, and that
# every other column is unchanged. Get-AzComputeResourceSku is mocked, so no
# live Azure is needed.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Compute', 'VirtualMachines.ps1' | Resolve-Path | Select-Object -ExpandProperty Path

    # All GUIDs below are the canonical Azure documentation placeholder; they
    # are not real subscription or resource identifiers.
    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:DocGuid; Name = 'sub-placeholder' })
    $script:RgPath = "/subscriptions/$($script:DocGuid)/resourcegroups/rg-vm/providers/microsoft.compute"

    # Offline-portability shim: Mock needs a command to intercept even on a box
    # without the Az.Compute module installed.
    function Get-AzComputeResourceSku { }

    # The OS disk every VM record points at.
    $script:OsDisk = [pscustomobject]@{
        TYPE       = 'microsoft.compute/disks'
        id         = "$($script:RgPath)/disks/disk-os"
        sku        = [pscustomobject]@{ name = 'Premium_LRS' }
        Properties = [pscustomobject]@{ diskSizeGB = 128 }
    }

    # Build one VM record in the shape the collector consumes.
    # -TimeCreatedMode: 'Absent' omits the property, 'Null' sets it to $null,
    # 'Value' sets it to -TimeCreated.
    function New-VmRecord
    {
        param(
            [string]$Name,
            [ValidateSet('Absent', 'Null', 'Value')][string]$TimeCreatedMode,
            [string]$TimeCreated
        )

        $Props = [ordered]@{
            licenseType     = 'Windows_Server'
            hardwareProfile = [pscustomobject]@{ vmSize = 'Standard_D2s_v3' }
            storageProfile  = [pscustomobject]@{
                osDisk         = [pscustomobject]@{
                    osType      = 'Windows'
                    managedDisk = [pscustomobject]@{ id = $script:OsDisk.id }
                }
                imageReference = [pscustomobject]@{
                    publisher    = 'MicrosoftWindowsServer'
                    offer        = 'WindowsServer'
                    sku          = '2022-datacenter'
                    exactVersion = '20348.1.1'
                }
            }
            extended        = [pscustomobject]@{
                instanceView = [pscustomobject]@{
                    osname     = 'Windows Server 2022 Datacenter'
                    osversion  = '10.0.20348'
                    powerState = [pscustomobject]@{ displayStatus = 'VM running' }
                }
            }
        }
        if ($TimeCreatedMode -eq 'Null') { $Props['timeCreated'] = $null }
        if ($TimeCreatedMode -eq 'Value') { $Props['timeCreated'] = $TimeCreated }

        return [pscustomobject]@{
            TYPE           = 'microsoft.compute/virtualmachines'
            id             = "$($script:RgPath)/virtualmachines/$Name"
            NAME           = $Name
            RESOURCEGROUP  = 'rg-vm'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
            PROPERTIES     = [pscustomobject]$Props
        }
    }

    # Every column except CreatedTime, as the collector should emit it for a
    # record built by New-VmRecord with the mocked SKU below.
    function Get-ExpectedColumns
    {
        param([string]$Name)
        return [ordered]@{
            'ID'              = "$($script:RgPath)/virtualmachines/$Name"
            'Subscription'    = 'sub-placeholder'
            'ResourceGroup'   = 'rg-vm'
            'Name'            = $Name
            'Location'        = 'eastus'
            'AvailabilitySet' = 'false'
            'Size'            = 'Standard_D2s_v3'
            'CPU'             = 2
            'Memory'          = 8
            'Set'             = $null
            'ImageReference'  = 'MicrosoftWindowsServer'
            'ImageVersion'    = '20348.1.1'
            'ImageSku'        = '2022-datacenter'
            'ImageOffer'      = 'WindowsServer'
            'HybridBenefit'   = 'AHUB for Windows'
            'OSName'          = 'Windows Server 2022 Datacenter'
            'OSType'          = 'Windows'
            'OSVersion'       = '10.0.20348'
            'OSDisk'          = 'Premium_LRS'
            'OSDiskSizeGB'    = 128
            'PowerState'      = 'VM running'
            'Zones'           = 0
            'Tags'            = $null
        }
    }

    function Invoke-VmCollector
    {
        param($Resources)
        return @(& $script:Collector -Sub $script:Subs -Resources (@($Resources) + $script:OsDisk) -Task 'Processing' -ResourceIdDictionary $null)
    }
}

Describe 'VM collector CreatedTime' {

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
        $script:Records = [ordered]@{
            'vm-absent'    = New-VmRecord -Name 'vm-absent' -TimeCreatedMode Absent
            'vm-null'      = New-VmRecord -Name 'vm-null' -TimeCreatedMode Null
            'vm-valid'     = New-VmRecord -Name 'vm-valid' -TimeCreatedMode Value -TimeCreated '2024-03-15T09:41:27.1234567'
            'vm-empty'     = New-VmRecord -Name 'vm-empty' -TimeCreatedMode Value -TimeCreated ''
            'vm-malformed' = New-VmRecord -Name 'vm-malformed' -TimeCreatedMode Value -TimeCreated 'not-a-date'
        }
    }

    It "writes 'Unknown' when properties.timeCreated is absent" {
        $script:Records['vm-absent'].PROPERTIES.PSObject.Properties.Name | Should -Not -Contain 'timeCreated'
        $Rec = @(Invoke-VmCollector -Resources $script:Records['vm-absent'])[0]
        $Rec.CreatedTime | Should -BeExactly 'Unknown'
    }

    It "writes 'Unknown' when properties.timeCreated is null" {
        $script:Records['vm-null'].PROPERTIES.PSObject.Properties.Name | Should -Contain 'timeCreated'
        $Rec = @(Invoke-VmCollector -Resources $script:Records['vm-null'])[0]
        $Rec.CreatedTime | Should -BeExactly 'Unknown'
    }

    It "formats a valid timeCreated as 'yyyy-MM-dd HH:mm'" {
        $Rec = @(Invoke-VmCollector -Resources $script:Records['vm-valid'])[0]
        $Rec.CreatedTime | Should -BeExactly '2024-03-15 09:41'
    }

    It 'formats a UTC timeCreated (as Azure returns it) in local time' {
        $Iso = '2024-03-15T09:41:27.1234567Z'
        $Rec = @(Invoke-VmCollector -Resources (New-VmRecord -Name 'vm-utc' -TimeCreatedMode Value -TimeCreated $Iso))[0]
        $Expected = [System.DateTimeOffset]::Parse($Iso, [System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
        $Rec.CreatedTime | Should -BeExactly $Expected
    }

    It "writes 'Unknown' when properties.timeCreated is present but not a date (<Name>)" -ForEach @(
        @{ Name = 'vm-empty' }
        @{ Name = 'vm-malformed' }
    ) {
        $Rec = @(Invoke-VmCollector -Resources $script:Records[$Name])[0]
        $Rec.Name | Should -BeExactly $Name
        $Rec.CreatedTime | Should -BeExactly 'Unknown'
    }

    It 'writes every virtual machine when some have a timeCreated that is not a date' {
        $Recs = @(Invoke-VmCollector -Resources @($script:Records.Values))
        $Recs.Count | Should -Be 5
        ($Recs | ForEach-Object { $_.Name }) | Should -Be @('vm-absent', 'vm-null', 'vm-valid', 'vm-empty', 'vm-malformed')
        ($Recs | ForEach-Object { $_.CreatedTime }) | Should -Be @('Unknown', 'Unknown', '2024-03-15 09:41', 'Unknown', 'Unknown')
    }

    It 'leaves every other column unchanged for <Name>' -ForEach @(
        @{ Name = 'vm-absent' }
        @{ Name = 'vm-null' }
        @{ Name = 'vm-valid' }
        @{ Name = 'vm-empty' }
        @{ Name = 'vm-malformed' }
    ) {
        $Rec = @(Invoke-VmCollector -Resources $script:Records[$Name])[0]
        $Expected = Get-ExpectedColumns -Name $Name

        @($Rec.Keys | Sort-Object) | Should -Be @(@($Expected.Keys) + 'CreatedTime' | Sort-Object)
        foreach ($Key in $Expected.Keys)
        {
            $Rec[$Key] | Should -Be $Expected[$Key] -Because "column '$Key' must not depend on timeCreated"
        }
    }
}
