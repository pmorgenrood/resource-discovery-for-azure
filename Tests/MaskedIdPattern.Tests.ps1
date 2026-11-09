# Masked id pattern tests
# Run with: Invoke-Pester ./Tests/MaskedIdPattern.Tests.ps1 -Output Detailed
#
# The zip-backed tests check every masked id against Get-MaskedIdPattern
# (Helpers/MaskedIdPattern.ps1). These tests pin that pattern on made-up ids, so
# it neither refuses a shape -Obfuscate writes nor lets a flat token or a real
# name through. No zip and no live Azure; the GUIDs are made up.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/MaskedIdPattern.ps1')
    $script:Pattern = Get-MaskedIdPattern
    $script:ScopePattern = Get-MaskedIdPattern -AllowScopeOnly
    $script:T = 'prod_11111111-2222-4333-8444-555555555555'
    $script:N = 'nonprod_66666666-7777-4888-9999-000000000000'
}

Describe 'Get-MaskedIdPattern' {
    It 'accepts a masked <Label>' -ForEach @(
        @{ Label = 'resource id'; Id = '/subscriptions/{T}/resourcegroups/{N}/providers/microsoft.compute/virtualmachines/{T}' }
        @{ Label = 'child resource id'; Id = '/subscriptions/{T}/resourcegroups/{T}/providers/microsoft.sql/servers/{T}/databases/{N}' }
        @{ Label = 'subscription-level id'; Id = '/subscriptions/{T}/providers/microsoft.security/pricings/{T}' }
        @{ Label = 'tenant-scope reservation id'; Id = '/providers/microsoft.capacity/reservationorders/{T}/reservations/{T}' }
        @{ Label = 'tenant-scope management group id'; Id = '/providers/Microsoft.Management/managementGroups/{T}' }
        @{ Label = 'extension resource id'; Id = '/subscriptions/{T}/resourcegroups/{T}/providers/microsoft.compute/virtualmachines/{T}/providers/microsoft.insights/diagnosticsettings/{T}' }
        @{ Label = 'consumption-only token'; Id = '/subscriptions/prod_sub_11111111-2222-4333-8444-555555555555/resourcegroups/prod_rg_mc_11111111-2222-4333-8444-555555555555/providers/microsoft.compute/disks/prod_aks_11111111-2222-4333-8444-555555555555' }
        @{ Label = '$system name'; Id = '/subscriptions/{T}/resourcegroups/{T}/providers/microsoft.servicebus/namespaces/{T}/topics/$system' }
        @{ Label = 'resource id with Azure keywords in mixed case'; Id = '/subscriptions/{T}/resourceGroups/{T}/providers/Microsoft.Compute/virtualMachines/{T}' }
        @{ Label = 'stand-in path of an id that is not an ARM path'; Id = '/providers/rda.noid/ids/{T}' }
        @{ Label = 'tenant-scope id with a trailing slash'; Id = '/providers/Microsoft.Capacity/reservationOrders/{T}/' }
    ) {
        $Masked = $Id.Replace('{T}', $script:T).Replace('{N}', $script:N)
        $Masked | Should -Match $script:Pattern
    }

    It 'refuses <Label>' -ForEach @(
        @{ Label = 'a flat token'; Id = '{T}' }
        @{ Label = 'a real subscription id'; Id = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/{T}/providers/microsoft.compute/virtualmachines/{T}' }
        @{ Label = 'a real resource group name'; Id = '/subscriptions/{T}/resourcegroups/rg-demo/providers/microsoft.compute/virtualmachines/{T}' }
        @{ Label = 'a real parent name'; Id = '/subscriptions/{T}/resourcegroups/{T}/providers/microsoft.sql/servers/srv-a/databases/{T}' }
        @{ Label = 'a real tenant-scope name'; Id = '/providers/microsoft.capacity/reservationorders/ro-a/reservations/{T}' }
        @{ Label = 'a real name in an extension block'; Id = '/subscriptions/{T}/resourcegroups/{T}/providers/microsoft.compute/virtualmachines/{T}/providers/microsoft.insights/diagnosticsettings/ds-a' }
        @{ Label = 'a resource id cut back to its group'; Id = '/subscriptions/{T}/resourcegroups/{T}' }
        @{ Label = 'a resource id cut back to its subscription'; Id = '/subscriptions/{T}' }
        @{ Label = 'a real name after an empty segment'; Id = '/providers/microsoft.capacity/reservationorders//reservations/res-a' }
        @{ Label = 'a real name before a trailing slash'; Id = '/providers/microsoft.capacity/reservationorders/ro-a/' }
        @{ Label = 'an empty segment inside the path'; Id = '/providers/Microsoft.Capacity/reservationOrders//reservations/{T}' }
        @{ Label = 'a token in upper case'; Id = '/subscriptions/PROD_11111111-2222-4333-8444-555555555555/resourcegroups/{T}/providers/microsoft.compute/virtualmachines/{T}' }
        @{ Label = 'a name token in upper case'; Id = '/subscriptions/{T}/resourcegroups/{T}/providers/microsoft.compute/virtualmachines/NONPROD_11111111-2222-4333-8444-555555555555' }
        @{ Label = 'a tenant-scope type with no name'; Id = '/providers/Microsoft.Capacity/reservationOrders' }
        @{ Label = 'a namespace with no type'; Id = '/providers/Microsoft.Capacity' }
        @{ Label = 'a child type with no name'; Id = '/subscriptions/{T}/resourcegroups/{T}/providers/microsoft.compute/virtualmachines/{T}/extensions' }
        @{ Label = 'an extension block with no type'; Id = '/subscriptions/{T}/resourcegroups/{T}/providers/microsoft.compute/virtualmachines/{T}/providers/microsoft.insights' }
    ) {
        $Masked = $Id.Replace('{T}', $script:T)
        $Masked | Should -Not -Match $script:Pattern
    }

    It 'with -AllowScopeOnly accepts a masked <Label>' -ForEach @(
        @{ Label = 'subscription-scope id'; Id = '/subscriptions/{T}' }
        @{ Label = 'group-scope id'; Id = '/subscriptions/{T}/resourcegroups/{N}' }
        @{ Label = 'resource id'; Id = '/subscriptions/{T}/resourcegroups/{N}/providers/microsoft.compute/virtualmachines/{T}' }
    ) {
        $Masked = $Id.Replace('{T}', $script:T).Replace('{N}', $script:N)
        $Masked | Should -Match $script:ScopePattern
    }

    It 'with -AllowScopeOnly refuses <Label>' -ForEach @(
        @{ Label = 'a real group in a group-scope id'; Id = '/subscriptions/{T}/resourcegroups/rg-demo' }
        @{ Label = 'a real subscription in a subscription-scope id'; Id = '/subscriptions/12345678-1234-1234-1234-123456789012' }
        @{ Label = 'a flat token'; Id = '{T}' }
    ) {
        $Masked = $Id.Replace('{T}', $script:T)
        $Masked | Should -Not -Match $script:ScopePattern
    }
}

Describe 'Test-ObfuscatedRun' {
    BeforeAll {
        $script:Dict = Join-Path ([System.IO.Path]::GetTempPath()) ('ObfuscationDictionary_' + [guid]::NewGuid() + '.json')
        Set-Content -LiteralPath $script:Dict -Value '{}'
        $script:Tenant = '/providers/microsoft.capacity/reservationorders/' + $script:T
    }
    AfterAll { Remove-Item -LiteralPath $script:Dict -ErrorAction SilentlyContinue }

    It 'marks a run with a masked subscription id obfuscated' {
        Test-ObfuscatedRun -Ids @('/subscriptions/' + $script:T + '/resourcegroups/' + $script:T) | Should -BeTrue
    }

    It 'marks a run with a flat token obfuscated' {
        Test-ObfuscatedRun -Ids @($script:T) | Should -BeTrue
    }

    It 'marks a run of tenant-scope ids obfuscated when it has a dictionary' {
        Test-ObfuscatedRun -Ids @($script:Tenant) -DictionaryPath $script:Dict | Should -BeTrue
    }

    It 'marks a run of tenant-scope ids obfuscated with no dictionary when every name is a token (<Case>)' -ForEach @(
        @{ Case = 'resource and child'; Ids = @('/providers/microsoft.capacity/reservationorders/{T}', '/providers/microsoft.capacity/reservationorders/{T}/reservations/{T}') }
        @{ Case = 'an extension resource'; Ids = @('/providers/Microsoft.Management/managementGroups/{T}/providers/Microsoft.Authorization/policyAssignments/{T}') }
        @{ Case = 'a $system name'; Ids = @('/providers/microsoft.capacity/reservationorders/{T}/topics/$system') }
        @{ Case = 'a $System name in another case'; Ids = @('/providers/microsoft.capacity/reservationorders/{T}/topics/$System') }
    ) {
        Test-ObfuscatedRun -Ids @($Ids | ForEach-Object { $_.Replace('{T}', $script:T) }) | Should -BeTrue
    }

    It 'leaves a run of tenant-scope ids plain with no dictionary when <Case>' -ForEach @(
        @{ Case = 'one name is real'; Ids = @('/providers/microsoft.capacity/reservationorders/{T}', '/providers/Microsoft.Capacity/reservationOrders/12345678-1234-1234-1234-123456789012') }
        @{ Case = 'a child name is real'; Ids = @('/providers/microsoft.capacity/reservationorders/{T}/reservations/res-a') }
        @{ Case = 'an id has a type and no name'; Ids = @('/providers/Microsoft.Capacity/reservationOrders') }
        @{ Case = 'a token is in upper case'; Ids = @('/providers/microsoft.capacity/reservationorders/PROD_11111111-2222-4333-8444-555555555555') }
        @{ Case = 'a real name in an extension block'; Ids = @('/providers/Microsoft.Management/managementGroups/{T}/providers/Microsoft.Authorization/policyAssignments/pa-a') }
        @{ Case = 'an extension block with no type'; Ids = @('/providers/Microsoft.Management/managementGroups/{T}/providers/Microsoft.Authorization') }
        @{ Case = 'only $system names'; Ids = @('/providers/microsoft.capacity/reservationorders/$system') }
        @{ Case = 'no namespace'; Ids = @('/providers//reservationorders/{T}') }
        @{ Case = 'a part before the path'; Ids = @('x/providers/microsoft.capacity/reservationorders/{T}') }
        @{ Case = 'an empty type'; Ids = @('/providers/microsoft.capacity//{T}') }
        @{ Case = 'two trailing slashes'; Ids = @('/providers/microsoft.capacity/reservationorders/{T}//') }
    ) {
        Test-ObfuscatedRun -Ids @($Ids | ForEach-Object { $_.Replace('{T}', $script:T) }) | Should -BeFalse
    }

    It 'leaves a run with no ids plain' {
        Test-ObfuscatedRun -Ids @() | Should -BeFalse
    }

    It 'leaves a run of real ids plain' {
        Test-ObfuscatedRun -Ids @('/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-demo/providers/Microsoft.Compute/virtualMachines/vm-a') -DictionaryPath (Join-Path $script:Dict 'missing.json') | Should -BeFalse
    }
}
