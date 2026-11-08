# Azure VMware Solution private cloud SKU tests
# Run with: Invoke-Pester ./Tests/AVSPrivateCloudSku.Tests.ps1 -Output Detailed
#
# Services/Compute/VMWare.ps1 read the SKU from properties.sku, where Azure
# does not put it: the SKU is on the resource itself (sku.name), so the column
# was empty for every private cloud. The REAL collector runs on synthetic
# records shaped as Resource Graph returns them; no live Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # The Azure documentation placeholder; not a real subscription id.
    $script:Guid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:Guid; Name = 'sub-placeholder' })
    $script:Rg = "/subscriptions/$($script:Guid)/resourceGroups/rg-a/providers"

    function Invoke-Collector
    {
        param($Records)
        return , @(& (Join-Path $script:Root 'Services/Compute/VMWare.ps1') -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $null)
    }

    function New-PrivateCloud
    {
        param($Sku, [switch]$NoSku, $PropertiesSku)
        $Props = [ordered]@{
            availability      = [pscustomobject]@{ strategy = 'SingleZone' }
            encryption        = [pscustomobject]@{ status = 'Enabled' }
            managementCluster = [pscustomobject]@{ clusterSize = 3 }
        }
        if ($null -ne $PropertiesSku) { $Props['sku'] = $PropertiesSku }
        $Cloud = [ordered]@{
            TYPE           = 'Microsoft.AVS/privateClouds'
            id             = "$($script:Rg)/Microsoft.AVS/privateClouds/avs-a"
            NAME           = 'avs-a'
            RESOURCEGROUP  = 'rg-a'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            PROPERTIES     = [pscustomobject]$Props
        }
        if (-not $NoSku) { $Cloud['sku'] = $Sku }
        return [pscustomobject]$Cloud
    }
}

Describe 'AVS private cloud SKU' {
    It 'reads the top-level sku <Name>' -ForEach @(
        @{ Name = 'av36' }
        @{ Name = 'av36p' }
        @{ Name = 'AV52' }
    ) {
        $Rows = Invoke-Collector @(New-PrivateCloud -Sku ([pscustomobject]@{ name = $Name }))
        $Rows.Count | Should -Be 1
        $Rows[0].SKU | Should -BeExactly $Name
    }

    It 'reads the top-level sku even when properties carries a different one' {
        $Rows = Invoke-Collector @(New-PrivateCloud -Sku ([pscustomobject]@{ name = 'av36' }) -PropertiesSku ([pscustomobject]@{ name = 'wrong' }))
        $Rows[0].SKU | Should -BeExactly 'av36'
    }

    It 'writes an empty SKU when the sku is <Case>' -ForEach @(
        @{ Case = 'missing'; NoSku = $true; Sku = $null }
        @{ Case = 'null'; NoSku = $false; Sku = $null }
        @{ Case = 'a bare string'; NoSku = $false; Sku = 'av36' }
        @{ Case = 'an object with no name'; NoSku = $false; Sku = [pscustomobject]@{ tier = 'x' } }
    ) {
        $Rows = Invoke-Collector @(New-PrivateCloud -Sku $Sku -NoSku:$NoSku)
        $Rows.Count | Should -Be 1
        $Rows[0].SKU | Should -BeNullOrEmpty
        $Rows[0].ClusterSize | Should -Be 3
    }

    It 'leaves the other columns unchanged' {
        $Row = (Invoke-Collector @(New-PrivateCloud -Sku ([pscustomobject]@{ name = 'av36' })))[0]
        $Row.Name | Should -BeExactly 'avs-a'
        $Row.AvailabilityStrategy | Should -BeExactly 'SingleZone'
        $Row.Encryption | Should -BeExactly 'Enabled'
        $Row.ClusterSize | Should -Be 3
        @($Row.Keys).Count | Should -Be 9
    }
}
