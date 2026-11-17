# =============================================================================
# DatabricksManagedGroupObfuscation.Tests.ps1
#
# Under -Obfuscate a Databricks workspace's ManagedResourceGroup must hold the
# token its managed group has in the masked ids of the resources in it (the
# workspace's worker VMs and disks, in the inventory and in the consumption
# file), so the workers still link to their workspace. A plain run keeps the
# group's real name.
#
# The collector (Services/Analytics/Databricks.ps1) runs as is. The masking of
# each collector's rows (Protect-RdaCollectorRow, which a run and
# Protect-RdaReport.ps1 both use) is taken from ResourceInventory.ps1 with the
# PowerShell AST. Generic names and the documentation placeholder
# subscription id only.
#
# Run with: Invoke-Pester ./Tests/DatabricksManagedGroupObfuscation.Tests.ps1 -Output Detailed
# =============================================================================

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The lifted script code keeps its state in globals.')]
param()

BeforeAll {
    $Root = Split-Path $PSScriptRoot -Parent
    $script:Collector = Join-Path $Root 'Services/Analytics/Databricks.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
    foreach ($Name in @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken', 'Get-ObfuscationSubscriptionIndex', 'Test-RdaTenantScopeIdMaskable', 'Get-ObfuscatedResourceId', 'New-ObfuscatedRowIdWithoutId'))
    {
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $false))
        if ($Fn.Count -eq 1) { . ([scriptblock]::Create($Fn[0].Extent.Text)) }
    }
    . (Join-Path $Root 'Functions/RevealObfuscation.Functions.ps1')
    # The masking of a collector's rows (a -Obfuscate run, and Protect-RdaReport.ps1
    # on a finished plain report).
    $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Protect-RdaCollectorRow' }, $false))
    if ($Fn.Count -ne 1) { throw 'Protect-RdaCollectorRow was not found in ResourceInventory.ps1.' }
    . ([scriptblock]::Create($Fn[0].Extent.Text))
    function Invoke-RowMasking { param($Result) Protect-RdaCollectorRow -Rows $Result; return $Result }
    . (Join-Path $Root 'Functions/OfflineObfuscation.Functions.ps1')

    $script:Sub = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $script:SubName = 'Demo Subscription'
    $script:Ws = "/subscriptions/$script:Sub/resourceGroups/rg-analytics/providers/Microsoft.Databricks/workspaces/ws-a"
    $script:Worker = "/subscriptions/$script:Sub/resourcegroups/databricks-rg-ws-a-x1/providers/microsoft.compute/virtualmachines/worker-1"

    function Initialize-ObfuscationState
    {
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = $script:SubName })
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ObfuscationSubscriptionTokens = @{}
        $Global:ObfuscationResourceGroupTokens = @{}
        $Global:ObfuscationSubscriptionIndex = $null
    }

    # The workspace as Resource Graph gives it.
    function Get-FakeWorkspace
    {
        param([string]$ManagedGroupId = "/subscriptions/$script:Sub/resourceGroups/databricks-rg-ws-a-x1")
        [pscustomobject]@{
            id             = $script:Ws
            NAME           = 'ws-a'
            TYPE           = 'microsoft.databricks/workspaces'
            subscriptionId = $script:Sub
            RESOURCEGROUP  = 'rg-analytics'
            LOCATION       = 'westeurope'
            SKU            = [pscustomobject]@{ name = 'premium' }
            PROPERTIES     = [pscustomobject]@{
                createdDateTime        = '2026-01-02T03:04:05Z'
                managedResourceGroupId = $ManagedGroupId
                parameters             = [pscustomobject]@{ storageAccountName = [pscustomobject]@{ value = 'dbstoragea' }; storageAccountSkuName = [pscustomobject]@{ value = 'Standard_GRS' } }
            }
        }
    }

    # The collector's rows, then the row masking, as a -Obfuscate run does them.
    function Get-MaskedWorkspaceRow
    {
        param($Workspace = (Get-FakeWorkspace))
        $Global:ResourceIdDictionary[$script:Ws] = Get-ObfuscatedResourceId -ResourceId $script:Ws
        $Rows = @(& $script:Collector -Sub $Global:Subscriptions -Resources @($Workspace) -Task 'Processing' -ResourceIdDictionary $Global:ResourceIdDictionary)
        @(Invoke-RowMasking -Result $Rows)[0]
    }
}

AfterAll {
    foreach ($Name in @('Subscriptions', 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'ObfuscationSubscriptionIndex'))
    {
        Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Databricks ManagedResourceGroup under -Obfuscate' {
    BeforeEach { Initialize-ObfuscationState }

    It 'holds the group token of a worker VM the inventory already masked' {
        $WorkerMasked = Get-ObfuscatedResourceId -ResourceId $script:Worker
        $Row = Get-MaskedWorkspaceRow
        $Row.ManagedResourceGroup | Should -BeExactly ($WorkerMasked -split '/')[4]
    }

    It 'holds the group token a worker billed later gets (worker gone from the inventory), in any casing' {
        $Row = Get-MaskedWorkspaceRow
        # The consumption step masks a billing-only id after the inventory rows.
        $Billed = Get-ObfuscatedResourceId -ResourceId ($script:Worker.ToUpperInvariant() -replace '^/SUBSCRIPTIONS/[^/]+', "/subscriptions/$script:Sub")
        $Row.ManagedResourceGroup | Should -BeExactly ($Billed -split '/')[4]
    }

    It 'leaves no real text and records the token for Reveal' {
        $Row = Get-MaskedWorkspaceRow
        $Row.ManagedResourceGroup | Should -Not -BeNullOrEmpty
        $Row.ManagedResourceGroup | Should -Not -BeExactly 'obfuscated'
        $Row.ManagedResourceGroup | Should -Not -Match '(?i)databricks|ws-a|x1'
        $Keys = @($Global:ResourceResourceGroupDictionary.Keys | Where-Object { $Global:ResourceResourceGroupDictionary[$_] -ceq $Row.ManagedResourceGroup })
        $Keys.Count | Should -BeGreaterThan 0
        # Reveal turns the token back into the group name from the recorded key.
        @($Keys | ForEach-Object { Get-RgNameFromResourceId $_ } | Sort-Object -Unique) | Should -Be @('databricks-rg-ws-a-x1')
    }

    It 'masks a managed group whose real name is the word obfuscated, in any casing, with its token' {
        $WorkerMasked = Get-ObfuscatedResourceId -ResourceId "/subscriptions/$script:Sub/resourcegroups/ObFuScAtEd/providers/microsoft.compute/virtualmachines/worker-1"
        $Row = Get-MaskedWorkspaceRow -Workspace (Get-FakeWorkspace -ManagedGroupId "/subscriptions/$script:Sub/resourceGroups/ObFuScAtEd")
        $Row.ManagedResourceGroup | Should -BeExactly ($WorkerMasked -split '/')[4]
    }

    It 'is ''obfuscated'', never the real name, on a row whose id is no workspace id or empty' {
        foreach ($Id in @('not-an-arm-id', '', $null))
        {
            Initialize-ObfuscationState
            $Row = @(Invoke-RowMasking -Result @(@{ ID = $Id; Name = 'ws-a'; Subscription = $script:SubName; ResourceGroup = 'rg-analytics'; ManagedResourceGroup = 'databricks-rg-ws-a-x1' }))[0]
            $Row.ManagedResourceGroup | Should -BeExactly 'obfuscated' -Because "id '$Id'"
        }
    }

    It 'stays empty for a workspace with no managed group' {
        $Row = Get-MaskedWorkspaceRow -Workspace (Get-FakeWorkspace -ManagedGroupId '')
        $Row.ManagedResourceGroup | Should -BeNullOrEmpty
    }

    It 'leaves another collector''s ManagedResourceGroup as that collector wrote it (Synapse)' {
        $Id = "/subscriptions/$script:Sub/resourcegroups/rg-analytics/providers/microsoft.synapse/workspaces/syn-a"
        $Row = @(Invoke-RowMasking -Result @(@{ ID = $Id; Name = 'syn-a'; Subscription = $script:SubName; ResourceGroup = 'rg-analytics'; ManagedResourceGroup = 'obfuscated' }))[0]
        $Row.ManagedResourceGroup | Should -BeExactly 'obfuscated'
    }
}

Describe 'Databricks ManagedResourceGroup in a plain run' {
    It 'is the managed group''s real name' {
        $Rows = @(& $script:Collector -Sub @([pscustomobject]@{ id = $script:Sub; name = $script:SubName }) -Resources @(Get-FakeWorkspace) -Task 'Processing' -ResourceIdDictionary $null)
        $Rows[0].ManagedResourceGroup | Should -BeExactly 'databricks-rg-ws-a-x1'
    }

    It 'reads a managed group id that is not a string without failing the collector' {
        $Ws = Get-FakeWorkspace
        $Ws.PROPERTIES.managedResourceGroupId = [pscustomobject]@{ odd = 1 }
        { & $script:Collector -Sub @([pscustomobject]@{ id = $script:Sub; name = $script:SubName }) -Resources @($Ws) -Task 'Processing' -ResourceIdDictionary $null } | Should -Not -Throw
    }
}

Describe 'Databricks ManagedResourceGroup when a finished plain report is masked offline' {
    BeforeEach { Initialize-ObfuscationState }

    It 'has no offline field rule, so the row masking gives it the group token, as in a run' {
        @(Get-RdaOfflineFieldRule | Where-Object { $_.Section -eq 'Databricks' -and $_.Field -eq 'ManagedResourceGroup' }).Count | Should -Be 0
        $WorkerMasked = Get-ObfuscatedResourceId -ResourceId $script:Worker
        $Global:ResourceIdDictionary[$script:Ws] = Get-ObfuscatedResourceId -ResourceId $script:Ws
        $Plain = @(& $script:Collector -Sub $Global:Subscriptions -Resources @(Get-FakeWorkspace) -Task 'Processing' -ResourceIdDictionary $null)
        $Row = @(Invoke-RowMasking -Result $Plain)[0]
        $Row.ManagedResourceGroup | Should -BeExactly ($WorkerMasked -split '/')[4]
    }

    It 'keeps the plain managed group name on the offline leak check''s list (not exempt)' {
        $Exempt = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $Rows = @{ Databricks = @(@{ ID = $script:Ws; Name = 'ws-a'; ManagedResourceGroup = 'databricks-rg-ws-a-x1'; Sku = 'premium' }) }
        Add-RdaExemptValue -Rows $Rows -Metrics @() -Rules @(Get-RdaOfflineFieldRule) -Exempt $Exempt
        $Exempt.Contains('databricks-rg-ws-a-x1') | Should -BeFalse
        $Exempt.Contains('premium') | Should -BeTrue -Because 'a field no one masks stays exempt (control)'
    }
}
