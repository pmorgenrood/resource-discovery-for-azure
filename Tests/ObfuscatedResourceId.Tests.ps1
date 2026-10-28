# Get-ObfuscatedResourceId tests
# Run with: Invoke-Pester ./Tests/ObfuscatedResourceId.Tests.ps1 -Output Detailed
#
# Get-ObfuscatedResourceId (ResourceInventory.ps1) builds the masked id that
# -Obfuscate writes for a resource. Every name segment must be masked,
# including a parent's name inside a child's id (SQL databases and elastic
# pools, managed instance databases, automation runbooks, NetApp capacity pools
# and volumes), and a parent segment must carry the parent's own token so ids
# still join. The functions are taken from ResourceInventory.ps1 with the
# PowerShell AST and run against the run's dictionaries set up here. Generic
# names and the documentation placeholder subscription id only.

BeforeAll {
    $Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
    foreach ($Name in @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken', 'Get-ObfuscatedResourceId'))
    {
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $false))
        if ($Fn.Count -ne 1) { throw "$Name was not found in ResourceInventory.ps1." }
        . ([scriptblock]::Create($Fn[0].Extent.Text))
    }

    $script:Sub = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $script:Base = "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers"
    $script:Token = '(?:prod|nonprod)_(?:[a-z0-9]+_)*[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

    function Reset-ObfuscationState
    {
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ObfuscationSubscriptionTokens = @{}
        $Global:ObfuscationResourceGroupTokens = @{}
    }
}

AfterAll {
    foreach ($Name in @('Subscriptions', 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens'))
    {
        Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Get-ObfuscatedResourceId' {
    BeforeEach { Reset-ObfuscationState }

    It 'masks every name segment of a <Label> id and keeps its shape' -ForEach @(
        @{ Label = 'SQL database'; Id = '/microsoft.sql/servers/srv-a/databases/db-a'; Names = @('srv-a', 'db-a') }
        @{ Label = 'SQL elastic pool'; Id = '/microsoft.sql/servers/srv-a/elasticpools/pool-a'; Names = @('srv-a', 'pool-a') }
        @{ Label = 'managed instance database'; Id = '/microsoft.sql/managedinstances/mi-a/databases/midb-a'; Names = @('mi-a', 'midb-a') }
        @{ Label = 'automation runbook'; Id = '/microsoft.automation/automationaccounts/aa-a/runbooks/rb-a'; Names = @('aa-a', 'rb-a') }
        @{ Label = 'NetApp volume'; Id = '/microsoft.netapp/netappaccounts/na-a/capacitypools/cp-a/volumes/vol-a'; Names = @('na-a', 'cp-a', 'vol-a') }
        @{ Label = 'extension resource'; Id = '/microsoft.compute/virtualmachines/vm-a/providers/microsoft.insights/diagnosticsettings/ds-a'; Names = @('vm-a', 'ds-a') }
    ) {
        $Real = $script:Base + $Id
        $Masked = Get-ObfuscatedResourceId -ResourceId $Real
        foreach ($N in @($Names + @('rg-demo', $script:Sub))) { $Masked | Should -Not -Match ([regex]::Escape($N)) }
        $RealParts = $Real -split '/'
        $MaskedParts = $Masked -split '/'
        $MaskedParts.Count | Should -Be $RealParts.Count
        for ($i = 0; $i -lt $RealParts.Count; $i++)
        {
            if ($RealParts[$i] -in @($Names + @('rg-demo', $script:Sub))) { $MaskedParts[$i] | Should -Match ('^' + $script:Token + '$') }
            else { $MaskedParts[$i] | Should -BeExactly $RealParts[$i] }
        }
    }

    It 'uses the parent resource''s own name token for the parent segment' {
        $Server = "$script:Base/microsoft.sql/servers/srv-a"
        $Global:ResourceNameDictionary[$Server] = 'prod_' + [guid]::NewGuid().ToString()
        $Masked = Get-ObfuscatedResourceId -ResourceId "$Server/databases/db-a"
        ($Masked -split '/')[8] | Should -BeExactly $Global:ResourceNameDictionary[$Server]
        (Get-ObfuscatedResourceId -ResourceId $Server) | Should -BeExactly ($Masked -replace '/databases/[^/]+$', '')
    }

    It 'gives two children of one parent that is not in the inventory the same parent token, and records it for the dictionary' {
        $A = Get-ObfuscatedResourceId -ResourceId "$script:Base/microsoft.sql/servers/srv-gone/databases/db-1"
        $B = Get-ObfuscatedResourceId -ResourceId "$script:Base/microsoft.sql/servers/srv-gone/databases/db-2"
        ($A -split '/')[8] | Should -BeExactly ($B -split '/')[8]
        $Global:ResourceNameDictionary["$script:Base/microsoft.sql/servers/srv-gone"] | Should -BeExactly ($A -split '/')[8]
        $Global:ResourceNameDictionary["$script:Base/microsoft.sql/servers/srv-gone/databases/db-1"] | Should -BeExactly ($A -split '/')[10]
    }

    It 'uses the inventory''s subscription and resource group tokens, and records them for an id outside the inventory' {
        $Global:ObfuscationSubscriptionTokens['Demo Subscription'] = 'prod_' + [guid]::NewGuid().ToString()
        $Global:ObfuscationResourceGroupTokens['rg-demo'] = 'prod_' + [guid]::NewGuid().ToString()
        $Id = "$script:Base/microsoft.compute/disks/disk-gone"
        $Masked = Get-ObfuscatedResourceId -ResourceId $Id
        ($Masked -split '/')[2] | Should -BeExactly $Global:ObfuscationSubscriptionTokens['Demo Subscription']
        ($Masked -split '/')[4] | Should -BeExactly $Global:ObfuscationResourceGroupTokens['rg-demo']
        $Global:ResourceSubscriptionDictionary[$Id] | Should -BeExactly $Global:ObfuscationSubscriptionTokens['Demo Subscription']
        $Global:ResourceResourceGroupDictionary[$Id] | Should -BeExactly $Global:ObfuscationResourceGroupTokens['rg-demo']
    }

    It 'masks a subscription-level id, keeps the name ''$system'', and gives an AKS-managed resource the aks_ hint' {
        $SubLevel = Get-ObfuscatedResourceId -ResourceId "/subscriptions/$script:Sub/providers/microsoft.insights/components/ai-a"
        $SubLevel | Should -Match ('^/subscriptions/' + $script:Token + '/providers/microsoft.insights/components/' + $script:Token + '$')
        $System = Get-ObfuscatedResourceId -ResourceId "$script:Base/microsoft.servicebus/namespaces/sb-a/topics/`$system"
        ($System -split '/')[-1] | Should -BeExactly '$system'
        $Aks = Get-ObfuscatedResourceId -ResourceId "/subscriptions/$script:Sub/resourcegroups/mc_rg_aks_eastus/providers/microsoft.compute/disks/osdisk-a"
        ($Aks -split '/')[-1] | Should -Match '^(prod|nonprod)_aks_'
    }

    It 'returns ''obfuscated'' for an empty id and one token for an id that is not subscription-scoped' {
        Get-ObfuscatedResourceId -ResourceId '' | Should -BeExactly 'obfuscated'
        Get-ObfuscatedResourceId -ResourceId 'not-an-arm-id' | Should -Match ('^' + $script:Token + '$')
    }
}
