# Consumption Obfuscation null-URI regression tests
# Run with: Invoke-Pester ./Tests/ConsumptionObfuscation.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The obfuscate-mode consumption path in ResourceInventory.ps1
# (GetResorceConsumption) rebuilds each usage record's resourceUri. Some Azure
# meter types legitimately have a NULL resourceUri (marketplace purchases,
# certain reservations, tenant-level charges). The original code fed that value
# straight into [hashtable].ContainsKey($rawUri); ContainsKey($null) THROWS
# (ArgumentNullException), and the per-subscription try/catch swallowed it -
# aborting the rest of that subscription's consumption collection. Net effect:
# inventory completed but consumption was silently truncated, ONLY under
# -Obfuscate.
#
# The test runs the run's own row masking, Protect-RdaUsageRow, and the id
# masking it calls, taken from ResourceInventory.ps1 with the PowerShell AST
# (as ObfuscateSystemName.Tests.ps1 does), so it tests the code and not a copy.
# It proves a null/empty resourceUri does not throw and yields the 'obfuscated'
# fallback token, while a normal ARM-shaped uri still obfuscates
# deterministically, with the run's own tokens. It also reads the masking section of
# docs/consumption-data.md, so the doc says what these tests prove. It does NOT need
# a live Azure run or an output zip.

BeforeAll {
    $Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
    foreach ($Name in @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken', 'Get-ObfuscationSubscriptionIndex', 'Test-RdaTenantScopeIdMaskable', 'Get-ObfuscatedResourceId', 'Protect-RdaUsageRow'))
    {
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $false))
        if ($Fn.Count -ne 1) { throw "$Name was not found in ResourceInventory.ps1." }
        . ([scriptblock]::Create($Fn[0].Extent.Text))
    }

    # The run's globals, as ResourceInventory.ps1 sets them, empty.
    function Initialize-TestObfuscationState
    {
        Set-Variable -Scope Global -Name Subscriptions -Value @()
        Set-Variable -Scope Global -Name ObfuscationSubscriptionIndex -Value $null
        foreach ($D in 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary')
        {
            Set-Variable -Scope Global -Name $D -Value (New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase))
        }
        foreach ($D in 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens') { Set-Variable -Scope Global -Name $D -Value @{} }
    }

    # One usage record as the consumption loop builds it, masked by the run's
    # Protect-RdaUsageRow; returns the row's masked ResourceId.
    function Get-ObfuscatedConsumptionUriForTest
    {
        param($RawUri)
        $Row = [pscustomobject]@{ ResourceId = $RawUri; ReservationId = ''; ReservationOrderId = '' }
        $Instance = [pscustomobject]@{ 'Microsoft.Resources' = [pscustomobject]@{ resourceUri = $RawUri; location = 'eastus' } }
        Protect-RdaUsageRow -Row $Row -InstanceObject $Instance
        return $Row.ResourceId
    }
}

AfterAll {
    foreach ($Name in @('Subscriptions', 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'ObfuscationSubscriptionIndex'))
    {
        Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe "Consumption obfuscation null/empty resourceUri handling" {

    BeforeEach {
        # Reset the run's dictionaries so determinism assertions are independent.
        Initialize-TestObfuscationState
    }

    Context "null and empty URIs (the regression)" {

        It "does NOT throw on a null resourceUri" {
            { Get-ObfuscatedConsumptionUriForTest -RawUri $null } | Should -Not -Throw
        }

        It "does NOT throw on an empty-string resourceUri" {
            { Get-ObfuscatedConsumptionUriForTest -RawUri '' } | Should -Not -Throw
        }

        It "returns the 'obfuscated' fallback token for a null resourceUri" {
            Get-ObfuscatedConsumptionUriForTest -RawUri $null | Should -BeExactly 'obfuscated'
        }

        It "returns the 'obfuscated' fallback token for an empty resourceUri" {
            Get-ObfuscatedConsumptionUriForTest -RawUri '' | Should -BeExactly 'obfuscated'
        }

        It "processes a full record set containing a null URI without aborting (mirrors the per-sub loop)" {
            $Uris = @(
                '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1',
                $null,
                '/subscriptions/aaaa/resourcegroups/rg2/providers/microsoft.storage/storageaccounts/sa1'
            )
            $Processed = 0
            $Threw = $false
            try
            {
                foreach ($u in $Uris)
                {
                    $null = Get-ObfuscatedConsumptionUriForTest -RawUri $u
                    $Processed++
                }
            }
            catch { $Threw = $true }

            $Threw    | Should -BeFalse
            $Processed | Should -Be 3
        }
    }

    Context "normal ARM URIs still obfuscate correctly" {

        It "never emits the real subscription / resource-group / resource name" {
            $Real = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/myrealrg/providers/microsoft.compute/virtualmachines/myrealvm'
            $Obf = Get-ObfuscatedConsumptionUriForTest -RawUri $Real
            $Obf | Should -Not -Match '12345678-1234-1234-1234-123456789012'
            $Obf | Should -Not -Match 'myrealrg'
            $Obf | Should -Not -Match 'myrealvm'
        }

        It "preserves ARM path STRUCTURE and the resource provider/type for categorisation" {
            $Real = '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'
            $Obf = Get-ObfuscatedConsumptionUriForTest -RawUri $Real
            $Obf | Should -Match '^/subscriptions/'
            $Obf | Should -Match '/resourcegroups/'
            $Obf | Should -Match '/providers/microsoft.compute/virtualmachines/'
        }

        It "is deterministic within a run (same real value -> same obfuscated value)" {
            $Real = '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'
            $First = Get-ObfuscatedConsumptionUriForTest -RawUri $Real
            $Second = Get-ObfuscatedConsumptionUriForTest -RawUri $Real
            $Second | Should -BeExactly $First
        }

        It "gives a resource of an AKS-managed group (mc_) the aks_ hint on its name token, and its group token no hint, so AKS rows stay categorisable" {
            # The run carries the marker on the resource's name token (its aks_ hint,
            # New-ObfuscatedNameToken); the group token itself is prod_/nonprod_ + GUID.
            $Real = '/subscriptions/aaaa/resourcegroups/mc_aksrg_cluster_eastus/providers/microsoft.compute/virtualmachinescalesets/aks-nodepool'
            $Obf = Get-ObfuscatedConsumptionUriForTest -RawUri $Real
            ($Obf -split '/')[-1] | Should -Match '^(prod|nonprod)_aks_[0-9a-f-]{36}$'
            ($Obf -split '/')[4] | Should -Match '^(prod|nonprod)_[0-9a-f-]{36}$' -Because 'a group token carries no mc_ or other hint'
            $Obf | Should -Not -Match 'mc_aksrg_cluster_eastus|aks-nodepool'
        }

        It "gives a usage row of a resource the run already masked that resource's masked id, letter for letter, in any case" {
            # An inventory row's or metric record's id, masked first by the run.
            $Real = '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'
            $Masked = '/subscriptions/prod_11111111-1111-1111-1111-111111111111/resourcegroups/prod_22222222-2222-2222-2222-222222222222/providers/microsoft.compute/virtualmachines/prod_33333333-3333-3333-3333-333333333333'
            (Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly)[$Real] = $Masked
            Get-ObfuscatedConsumptionUriForTest -RawUri $Real | Should -BeExactly $Masked
            Get-ObfuscatedConsumptionUriForTest -RawUri $Real.ToUpperInvariant() | Should -BeExactly $Masked
        }

        It "gives a resource only billing names the subscription and group tokens the run already holds, and records its masked id for the dictionary" {
            $SubTok = 'prod_44444444-4444-4444-4444-444444444444'; $RgTok = 'nonprod_55555555-5555-5555-5555-555555555555'
            (Get-Variable -Scope Global -Name ObfuscationSubscriptionTokens -ValueOnly)['aaaa'] = $SubTok
            (Get-Variable -Scope Global -Name ObfuscationResourceGroupTokens -ValueOnly)['rg-dev'] = $RgTok
            $Real = '/subscriptions/aaaa/resourcegroups/rg-dev/providers/microsoft.storage/storageaccounts/billedonly'
            $Obf = Get-ObfuscatedConsumptionUriForTest -RawUri $Real
            ($Obf -split '/')[2] | Should -BeExactly $SubTok
            ($Obf -split '/')[4] | Should -BeExactly $RgTok
            (Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly)[$Real] | Should -BeExactly $Obf -Because 'the dictionary file''s ResourceIdMap is built from it, so Reveal maps the row back'
        }
    }

    Context "a consumption id is masked as the run's own code masks it" {

        It "gives a `$system name part a token, as every name" {
            $Obf = Get-ObfuscatedConsumptionUriForTest -RawUri '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.servicebus/namespaces/$system/topics/$system'
            $Obf | Should -Not -Match ([regex]::Escape('$system'))
            $Obf | Should -Match '^/subscriptions/(prod|nonprod)_[0-9a-f-]{36}/resourcegroups/(prod|nonprod)_[0-9a-f-]{36}/providers/microsoft\.servicebus/namespaces/(prod|nonprod)_[0-9a-f-]{36}/topics/(prod|nonprod)_[0-9a-f-]{36}$'
        }

        It "gives two resources of one name in two groups two name tokens (a name is keyed by its id, not by the bare name)" {
            $A = Get-ObfuscatedConsumptionUriForTest -RawUri '/subscriptions/aaaa/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'
            $B = Get-ObfuscatedConsumptionUriForTest -RawUri '/subscriptions/aaaa/resourcegroups/rg2/providers/microsoft.compute/virtualmachines/vm1'
            ($A -split '/')[-1] | Should -Not -BeExactly ($B -split '/')[-1]
        }
    }
}

# The doc's section on consumption masking must say what the tests above prove the
# run does, so it is read for the two claims it once made that the run does not do.
Describe 'docs/consumption-data.md on how a usage row is masked' {
    BeforeAll {
        $Doc = [System.IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'docs/consumption-data.md'))
        $Start = $Doc.IndexOf('## Obfuscation of consumption data')
        if ($Start -lt 0) { throw 'docs/consumption-data.md has no "Obfuscation of consumption data" section.' }
        $End = $Doc.IndexOf("`n## ", $Start + 1)
        $script:MaskDoc = if ($End -gt $Start) { $Doc.Substring($Start, $End - $Start) } else { $Doc.Substring($Start) }
    }

    It 'says a usage row takes the run''s own masked id and tokens, which the dictionary maps back, not tokens of its own' {
        $script:MaskDoc | Should -Not -Match '(?i)independent of|separate from the inventory|not\W+equal the inventory' -Because 'a usage row of a resource the run masked takes that masked id (the test above)'
        $script:MaskDoc | Should -Match 'ResourceIdMap' -Because 'every masked usage id is in the dictionary the run writes'
    }

    It 'puts the AKS hint on the name token, and claims no mc_ marker on the group token' {
        $script:MaskDoc | Should -Not -Match '(?i)mc_`?\s+AKS-managed-RG marker' -Because 'a group token carries no hint (the test above)'
        $script:MaskDoc | Should -Match 'aks_'
    }
}
