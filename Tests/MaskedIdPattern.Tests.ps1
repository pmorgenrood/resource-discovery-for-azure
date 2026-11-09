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
        @{ Label = 'tenant-scope id with a type and no name'; Id = '/providers/Microsoft.Capacity/reservationOrders' }
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
