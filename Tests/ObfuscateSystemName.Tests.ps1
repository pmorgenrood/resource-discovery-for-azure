# A name part that holds Azure's fixed name '$system' is masked under -Obfuscate
# Run with: Invoke-Pester ./Tests/ObfuscateSystemName.Tests.ps1 -Output Detailed
#
# Service Bus bills a namespace named '$system' (in a resource group named
# '$system'). Get-ObfuscatedResourceId kept that name as written, so the
# consumption ResourceId, the ResourceUri in the row's JSON column and the
# dictionary's ResourceIdMap key held '/.../namespaces/$system' with only the
# subscription and group masked. The output contract leaves no name part as
# written, so every name slot gets a token, '$system' included, in any
# provider. The join must not move: the inventory ID, the consumption
# ResourceId and the ResourceIdMap key give one resource the same tokens.
# Functions are taken from ResourceInventory.ps1 with the PowerShell AST.
# Made-up names and the Azure docs placeholder subscription id only.

BeforeAll {
    $Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
    foreach ($Name in @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken', 'Get-ObfuscationSubscriptionIndex', 'Test-RdaTenantScopeIdMaskable', 'Get-ObfuscatedResourceId', 'Test-ObfuscatedIdShape', 'Add-RdaObfuscationToken', 'Protect-RdaCollectorRow', 'Protect-RdaUsageRow', 'Get-RdaObfuscationDictionary'))
    {
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $false))
        if ($Fn.Count -ne 1) { throw "$Name was not found in ResourceInventory.ps1." }
        . ([scriptblock]::Create($Fn[0].Extent.Text))
    }

    $script:Sub = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $script:Token = '(?-i:(?:prod|nonprod)_(?:databricks_|aks_|vmss_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'

    # The run's globals, as ResourceInventory.ps1 sets them, empty.
    function Initialize-TestObfuscationState
    {
        Set-Variable -Scope Global -Name Subscriptions -Value @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        Set-Variable -Scope Global -Name ObfuscationSubscriptionIndex -Value $null
        foreach ($D in 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary')
        {
            Set-Variable -Scope Global -Name $D -Value (New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase))
        }
        foreach ($D in 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'TagValueDictionary', 'FreeTextDictionary') { Set-Variable -Scope Global -Name $D -Value @{} }
    }

    # One consumption row as the consumption loop builds it (the loop reads
    # InstanceData in lower case), masked by Protect-RdaUsageRow. Returns the
    # row and its JSON column as the file writes it.
    function Invoke-UsageRow
    {
        param([string]$ResourceUri)
        $Row = [pscustomobject]@{ ResourceId = $ResourceUri; ReservationId = ''; ReservationOrderId = '' }
        $Instance = [pscustomobject]@{ 'Microsoft.Resources' = [pscustomobject]@{ ResourceUri = $ResourceUri; Location = 'westeurope'; additionalInfo = [pscustomobject]@{ ConsumptionMeter = '' } } }
        Protect-RdaUsageRow -Row $Row -InstanceObject $Instance
        return [pscustomobject]@{ ResourceId = $Row.ResourceId; Json = ($Instance | ConvertTo-Json -Compress -Depth 5); Uri = $Instance.'Microsoft.Resources'.ResourceUri }
    }

    # The name slots of a masked subscription-scope id: each value after a
    # type segment (not after 'subscriptions', 'resourcegroups' or 'providers').
    function Get-NameSlot
    {
        param([string]$Id)
        $P = $Id.Split('/')
        for ($i = 3; $i + 1 -lt $P.Count; $i += 2) { if ($P[$i] -notin 'resourcegroups', 'providers') { $P[$i + 1] } }
    }
}

AfterAll {
    foreach ($Name in @('Subscriptions', 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'ObfuscationSubscriptionIndex', 'TagValueDictionary', 'FreeTextDictionary'))
    {
        Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'A $system name part under -Obfuscate' {
    BeforeEach { Initialize-TestObfuscationState }

    It 'masks the $system name of a <Label> id, keeps its shape, and the shape check takes it' -ForEach @(
        @{ Label = 'Service Bus namespace in the $system group'; Path = 'resourcegroups/$system/providers/microsoft.servicebus/namespaces/$system' }
        @{ Label = 'Service Bus namespace'; Path = 'resourcegroups/rg-bus/providers/microsoft.servicebus/namespaces/$system' }
        @{ Label = 'Service Bus topic'; Path = 'resourcegroups/rg-bus/providers/microsoft.servicebus/namespaces/sb-orders/topics/$system' }
        @{ Label = 'Service Bus queue'; Path = 'resourcegroups/rg-bus/providers/microsoft.servicebus/namespaces/sb-orders/queues/$system' }
        @{ Label = 'Event Hubs namespace'; Path = 'resourcegroups/rg-bus/providers/microsoft.eventhub/namespaces/$system' }
        @{ Label = 'storage account'; Path = 'resourcegroups/rg-bus/providers/microsoft.storage/storageaccounts/$system' }
        @{ Label = 'subscription-level resource'; Path = 'providers/microsoft.servicebus/namespaces/$system' }
    ) {
        $Real = "/subscriptions/$script:Sub/$Path"
        $Masked = Get-ObfuscatedResourceId -ResourceId $Real
        $Masked | Should -Not -Match ([regex]::Escape('$system'))
        $Masked | Should -Not -Match 'sb-orders|rg-bus'
        ($Masked -split '/').Count | Should -Be ($Real -split '/').Count
        foreach ($Slot in @(Get-NameSlot $Masked)) { $Slot | Should -Match ('^' + $script:Token + '\z') }
        Test-ObfuscatedIdShape -RealId $Real -MaskedId $Masked | Should -BeTrue
    }

    It 'leaves no $system in the consumption ResourceId, the JSON column or the ResourceIdMap key of a row not in the inventory' {
        $Uri = "/subscriptions/$script:Sub/resourcegroups/`$system/providers/microsoft.servicebus/namespaces/`$system"
        $Out = Invoke-UsageRow -ResourceUri $Uri
        $Out.ResourceId | Should -Not -Match ([regex]::Escape('$system'))
        $Out.Json | Should -Not -Match ([regex]::Escape('$system'))
        $Out.Uri | Should -BeExactly $Out.ResourceId
        $Map = (Get-RdaObfuscationDictionary).ResourceIdMap
        @($Map.Keys | Where-Object { $_ -match [regex]::Escape('$system') }) | Should -BeNullOrEmpty
        $Map[$Out.ResourceId] | Should -BeExactly $Uri -Because 'the dictionary still reverses the masked id'
        (Get-RdaObfuscationDictionary).ResourceNameMap.Values | Should -Contain $Uri -Because 'the name token is recorded, so Reveal can undo it'
    }

    It 'refuses a seeded id that kept $system, so a seeded run masks it again' {
        $Real = "/subscriptions/$script:Sub/resourcegroups/rg-bus/providers/microsoft.servicebus/namespaces/`$system"
        $T = 'prod_0f0e0d0c-0b0a-4908-8706-050403020100'
        Test-ObfuscatedIdShape -RealId $Real -MaskedId "/subscriptions/$T/resourcegroups/$T/providers/microsoft.servicebus/namespaces/`$system" | Should -BeFalse
    }
}

Describe 'The inventory ID, consumption ResourceId and ResourceIdMap key of one resource' {
    BeforeEach { Initialize-TestObfuscationState }

    It 'give the same tokens, with the consumption id in lower case and a $system topic under the namespace' {
        # Resource Graph gives the id in Azure's casing; the consumption loop lower-cases it.
        $InvId = "/subscriptions/$script:Sub/resourceGroups/RG-Bus/providers/Microsoft.ServiceBus/namespaces/SB-Orders"
        $Res = [pscustomobject]@{ id = $InvId; name = 'SB-Orders'; subscriptionId = $script:Sub; resourceGroup = 'RG-Bus' }
        Add-RdaObfuscationToken -Rows @($Res)
        $Row = @{ ID = $InvId; Name = 'SB-Orders'; Subscription = 'Demo Subscription'; ResourceGroup = 'RG-Bus' }
        Protect-RdaCollectorRow -Rows @($Row) -Collector 'ServiceBUS'

        $Usage = Invoke-UsageRow -ResourceUri $InvId.ToLowerInvariant()
        $Usage.ResourceId | Should -BeExactly $Row.ID -Because 'downstream joins by the exact id string'
        $Usage.Uri | Should -BeExactly $Row.ID

        $P = $Row.ID -split '/'
        $P[2] | Should -BeExactly $Row.Subscription
        $P[4] | Should -BeExactly $Row.ResourceGroup
        $P[-1] | Should -BeExactly $Row.Name

        $Topic = Invoke-UsageRow -ResourceUri ($InvId.ToLowerInvariant() + '/topics/$system')
        $Topic.ResourceId | Should -Not -Match ([regex]::Escape('$system'))
        # The child's own path keeps its lower-case type words; its tokens are its parent's, letter for letter.
        $TP = $Topic.ResourceId -split '/'
        ($TP[0..8] -join '/') | Should -Be $Row.ID -Because 'a child holds its parent''s path, case aside'
        foreach ($i in 2, 4, 8) { $TP[$i] | Should -BeExactly $P[$i] -Because 'a child holds its parent''s tokens' }

        $Map = (Get-RdaObfuscationDictionary).ResourceIdMap
        $Map[$Row.ID] | Should -Be $InvId -Because 'the map key is the inventory ID and the consumption ResourceId'
        $Map.ContainsKey($Topic.ResourceId) | Should -BeTrue
    }
}
