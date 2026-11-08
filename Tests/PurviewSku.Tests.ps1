# Purview account SKU and Capacity tests
# Run with: Invoke-Pester ./Tests/PurviewSku.Tests.ps1 -Output Detailed
#
# Services/Data/Purview.ps1 read the SKU and capacity from properties.sku,
# where Azure does not put them: the SKU is on the resource itself (sku.name
# and sku.capacity), so both columns were empty for every account. The REAL
# collector runs on synthetic records shaped as Resource Graph returns them;
# no live Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # The Azure documentation placeholder; not a real subscription id.
    $script:Guid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:Guid; Name = 'sub-placeholder' })
    $script:Rg = "/subscriptions/$($script:Guid)/resourceGroups/rg-a/providers"

    function Invoke-Collector
    {
        param($Records)
        return , @(& (Join-Path $script:Root 'Services/Data/Purview.ps1') -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $null)
    }

    function New-Account
    {
        param($Sku, [switch]$NoSku)
        $Account = [ordered]@{
            TYPE           = 'microsoft.purview/accounts'
            id             = "$($script:Rg)/Microsoft.Purview/accounts/pv-a"
            NAME           = 'pv-a'
            RESOURCEGROUP  = 'rg-a'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            PROPERTIES     = [pscustomobject]@{
                createdAt    = '2026-01-02T03:04:00Z'
                createdBy    = 'creator-a'
                friendlyName = 'pv-friendly'
            }
        }
        if (-not $NoSku) { $Account['sku'] = $Sku }
        return [pscustomobject]$Account
    }
}

Describe 'Purview SKU and Capacity' {
    It 'reads the top-level sku <Name> with capacity <Capacity>' -ForEach @(
        @{ Name = 'Standard'; Capacity = 1 }
        @{ Name = 'Standard'; Capacity = 4 }
        @{ Name = 'Free'; Capacity = 0 }
    ) {
        $Rows = Invoke-Collector @(New-Account -Sku ([pscustomobject]@{ name = $Name; capacity = $Capacity }))
        $Rows.Count | Should -Be 1
        $Rows[0].SKU | Should -BeExactly $Name
        $Rows[0].Capacity | Should -Be $Capacity
    }

    It 'writes the SKU and an empty capacity when the sku has no capacity' {
        $Row = (Invoke-Collector @(New-Account -Sku ([pscustomobject]@{ name = 'Standard' })))[0]
        $Row.SKU | Should -BeExactly 'Standard'
        $Row.Capacity | Should -BeNullOrEmpty
    }

    It 'writes empty SKU and Capacity when the sku is <Case>' -ForEach @(
        @{ Case = 'missing'; NoSku = $true; Sku = $null }
        @{ Case = 'null'; NoSku = $false; Sku = $null }
        @{ Case = 'a bare string'; NoSku = $false; Sku = 'Standard' }
    ) {
        $Rows = Invoke-Collector @(New-Account -Sku $Sku -NoSku:$NoSku)
        $Rows.Count | Should -Be 1
        $Rows[0].SKU | Should -BeNullOrEmpty
        $Rows[0].Capacity | Should -BeNullOrEmpty
        $Rows[0].CreatedTime | Should -BeExactly '2026-01-02 03:04'
    }

    It 'leaves the other columns unchanged' {
        $Row = (Invoke-Collector @(New-Account -Sku ([pscustomobject]@{ name = 'Standard'; capacity = 1 })))[0]
        $Row.Name | Should -BeExactly 'pv-a'
        $Row.CreatedBy | Should -BeExactly 'creator-a'
        $Row.FriendlyName | Should -BeExactly 'pv-friendly'
        $Row.CreatedTime | Should -BeExactly '2026-01-02 03:04'
        @($Row.Keys).Count | Should -Be 10
    }
}
