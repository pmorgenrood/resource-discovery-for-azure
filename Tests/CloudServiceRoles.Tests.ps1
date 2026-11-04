# Cloud Services (extended support) role tests
# Run with: Invoke-Pester ./Tests/CloudServiceRoles.Tests.ps1 -Output Detailed
#
# Services/Compute/CloudServices.ps1 walked properties.roleProfile, an object,
# instead of properties.roleProfile.roles, the list of roles, so every cloud
# service got one role with no name or SKU. The roles were also stored under a
# NoteProperty that hid the hashtable key from the JSON writer, so the
# Inventory JSON had no Roles at all. The REAL collector runs on synthetic
# records shaped as Resource Graph returns them, and its output goes through
# the real Write-InventoryJson; no live Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    . (Join-Path $script:Root 'Functions/ResourceInventory.Functions.ps1')
    # Write-InventoryJson lives in its own file.
    . (Join-Path $script:Root 'Functions/InventoryJson.Functions.ps1')
    # The Azure documentation placeholder; not a real subscription id.
    $script:Guid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:Guid; Name = 'sub-placeholder' })
    $script:Rg = "/subscriptions/$($script:Guid)/resourceGroups/rg-a/providers"

    function Invoke-Collector
    {
        param($Records, $Dictionary = $null)
        return , @(& (Join-Path $script:Root 'Services/Compute/CloudServices.ps1') -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $Dictionary)
    }

    function New-Role
    {
        param($Name, $Sku = 'Standard_D1_v2', $Capacity = 1)
        return [pscustomobject]@{ name = $Name; sku = [pscustomobject]@{ name = $Sku; tier = 'Standard'; capacity = $Capacity } }
    }

    # -RoleProfile is properties.roleProfile; -NoRoleProfile leaves it out.
    function New-CloudService
    {
        param($RoleProfile, [switch]$NoRoleProfile)
        $Props = [ordered]@{ provisioningState = 'Succeeded' }
        if (-not $NoRoleProfile) { $Props['roleProfile'] = $RoleProfile }
        return [pscustomobject]@{
            TYPE           = 'microsoft.compute/cloudservices'
            id             = "$($script:Rg)/Microsoft.Compute/cloudServices/cs-a"
            name           = 'cs-a'
            RESOURCEGROUP  = 'rg-a'
            location       = 'eastus'
            subscriptionId = $script:Guid
            PROPERTIES     = [pscustomobject]$Props
        }
    }

    # Writes the collector output the way ResourceInventory.ps1 does and reads
    # the Inventory JSON back.
    function Write-AndRead
    {
        param($Rows)
        $Inventory = [pscustomobject]@{}
        $Inventory | Add-Member -MemberType NoteProperty -Name 'CloudServices' -Value NotSet
        $Inventory.CloudServices = @($Rows)
        $Path = Join-Path $TestDrive ('Inventory_{0}.json' -f [guid]::NewGuid().ToString('N'))
        Write-InventoryJson -InputObject $Inventory -Path $Path
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }
}

AfterAll {
    $Global:FreeTextDictionary = $null
}

Describe 'Cloud Services roles' {
    It 'writes one role per entry of roleProfile.roles, with name and SKU' {
        $Rows = Invoke-Collector @(New-CloudService -RoleProfile ([pscustomobject]@{ roles = @((New-Role -Name 'WebRole1' -Sku 'Standard_D1_v2' -Capacity 2), (New-Role -Name 'WorkerRole1' -Sku 'Standard_D2_v2' -Capacity 3)) }))
        $Rows.Count | Should -Be 1
        $Roles = @($Rows[0].Roles)
        $Roles.Count | Should -Be 2
        $Roles[0].RoleName | Should -BeExactly 'WebRole1'
        $Roles[0].SkuName | Should -BeExactly 'Standard_D1_v2'
        $Roles[0].SkuTier | Should -BeExactly 'Standard'
        $Roles[0].SkuCapacity | Should -Be 2
        $Roles[1].RoleName | Should -BeExactly 'WorkerRole1'
        $Roles[1].SkuName | Should -BeExactly 'Standard_D2_v2'
        $Roles[1].SkuCapacity | Should -Be 3
    }

    It 'writes the one role of a single-role service given as an object, not an array' {
        $Roles = @((Invoke-Collector @(New-CloudService -RoleProfile ([pscustomobject]@{ roles = (New-Role 'WebRole1') })))[0].Roles)
        $Roles.Count | Should -Be 1
        $Roles[0].RoleName | Should -BeExactly 'WebRole1'
    }

    It 'writes no roles when <Case>, and keeps the row' -ForEach @(
        @{ Case = 'roles is empty'; NoProfile = $false; RP = [pscustomobject]@{ roles = @() } }
        @{ Case = 'roles is null'; NoProfile = $false; RP = [pscustomobject]@{ roles = $null } }
        @{ Case = 'roleProfile has no roles'; NoProfile = $false; RP = [pscustomobject]@{} }
        @{ Case = 'roleProfile is null'; NoProfile = $false; RP = $null }
        @{ Case = 'roleProfile is missing'; NoProfile = $true; RP = $null }
        @{ Case = 'roleProfile is a bare string'; NoProfile = $false; RP = 'WebRole1' }
    ) {
        $Rows = Invoke-Collector @(New-CloudService -RoleProfile $RP -NoRoleProfile:$NoProfile)
        $Rows.Count | Should -Be 1
        $Rows[0].Name | Should -BeExactly 'cs-a'
        @($Rows[0].Roles).Count | Should -Be 0
    }

    It 'skips a null entry in roles' {
        $Roles = @((Invoke-Collector @(New-CloudService -RoleProfile ([pscustomobject]@{ roles = @((New-Role 'WebRole1'), $null) })))[0].Roles)
        $Roles.Count | Should -Be 1
    }

    It 'skips an entry in roles that is not an object (<Case>)' -ForEach @(
        @{ Case = 'a string'; Entry = 'WebRole2' }
        @{ Case = 'a number'; Entry = 5 }
    ) {
        $Roles = @((Invoke-Collector @(New-CloudService -RoleProfile ([pscustomobject]@{ roles = @((New-Role 'WebRole1'), $Entry) })))[0].Roles)
        $Roles.Count | Should -Be 1
        $Roles[0].RoleName | Should -BeExactly 'WebRole1'
    }

    It 'keeps a role given as a dictionary' {
        $Role = @{ name = 'WebRole1'; sku = @{ name = 'Standard_D1_v2'; tier = 'Standard'; capacity = 2 } }
        $Roles = @((Invoke-Collector @(New-CloudService -RoleProfile ([pscustomobject]@{ roles = @($Role) })))[0].Roles)
        $Roles.Count | Should -Be 1
        $Roles[0].RoleName | Should -BeExactly 'WebRole1'
        $Roles[0].SkuName | Should -BeExactly 'Standard_D1_v2'
        $Roles[0].SkuCapacity | Should -Be 2
    }

    It 'writes a role with no sku with empty SKU fields' {
        $Roles = @((Invoke-Collector @(New-CloudService -RoleProfile ([pscustomobject]@{ roles = @([pscustomobject]@{ name = 'WebRole1' }) })))[0].Roles)
        $Roles.Count | Should -Be 1
        $Roles[0].RoleName | Should -BeExactly 'WebRole1'
        $Roles[0].SkuName | Should -BeNullOrEmpty
        $Roles[0].SkuCapacity | Should -BeNullOrEmpty
    }

    It 'tokenizes role names in an obfuscated run' {
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        try
        {
            $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
            $Dict["$($script:Rg)/Microsoft.Compute/cloudServices/cs-a"] = 'prod_cs-token'
            $Roles = @((Invoke-Collector @(New-CloudService -RoleProfile ([pscustomobject]@{ roles = @((New-Role 'WebRole1')) })) -Dictionary $Dict)[0].Roles)
            $Roles[0].RoleName | Should -Match '^prod_[0-9a-f-]{36}$'
            $Roles[0].SkuName | Should -BeExactly 'Standard_D1_v2'
        }
        finally { $Global:FreeTextDictionary = $null }
    }

    It 'leaves the other columns unchanged' {
        $Row = (Invoke-Collector @(New-CloudService -RoleProfile ([pscustomobject]@{ roles = @((New-Role 'WebRole1')) })))[0]
        $Row.ID | Should -BeExactly "$($script:Rg)/Microsoft.Compute/cloudServices/cs-a"
        $Row.Subscription | Should -BeExactly 'sub-placeholder'
        $Row.ResourceGroup | Should -BeExactly 'rg-a'
        $Row.Name | Should -BeExactly 'cs-a'
        $Row.Location | Should -BeExactly 'eastus'
        @($Row.Keys | Sort-Object) | Should -Be @('ID', 'Location', 'Name', 'ResourceGroup', 'Roles', 'Subscription')
    }
}

Describe 'Cloud Services roles in the Inventory JSON' {
    It 'writes every role under Roles on the row' {
        $Rows = Invoke-Collector @(New-CloudService -RoleProfile ([pscustomobject]@{ roles = @((New-Role -Name 'WebRole1' -Sku 'Standard_D1_v2' -Capacity 2), (New-Role -Name 'WorkerRole1' -Sku 'Standard_D2_v2' -Capacity 3)) }))
        $Json = Write-AndRead $Rows
        $Row = @($Json.CloudServices)[0]
        $Row.PSObject.Properties.Name | Should -Contain 'Roles'
        $Roles = @($Row.Roles)
        $Roles.Count | Should -Be 2
        $Roles[0].RoleName | Should -BeExactly 'WebRole1'
        $Roles[0].SkuName | Should -BeExactly 'Standard_D1_v2'
        $Roles[0].SkuTier | Should -BeExactly 'Standard'
        $Roles[0].SkuCapacity | Should -Be 2
        $Roles[1].RoleName | Should -BeExactly 'WorkerRole1'
        $Roles[1].SkuCapacity | Should -Be 3
        $Row.Name | Should -BeExactly 'cs-a'
    }

    It 'writes Roles as an empty list when the service has none' {
        $Json = Write-AndRead (Invoke-Collector @(New-CloudService -RoleProfile ([pscustomobject]@{ roles = @() })))
        $Row = @($Json.CloudServices)[0]
        $Row.PSObject.Properties.Name | Should -Contain 'Roles'
        @($Row.Roles).Count | Should -Be 0
    }
}
