# =============================================================================
# ContractIdPattern.Tests.ps1
#
# Offline tests of Get-RdaContractIdPattern (Tests/Helpers/SyntheticReportZip.ps1),
# the masked id shape the zip-backed tests check inventory ids, cross-
# references, metric ids and ResourceIdMap keys against. The contract shape
# is the only one taken by default; the parked G1/G2 shapes and the metric
# fallback's sub_/rg_ tokens (F2) only when a test names them.
#
# Run with: Invoke-Pester ./Tests/ContractIdPattern.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/SyntheticReportZip.ps1')
    $G = '0f0e0d0c-0b0a-4908-8706-050403020100'
    $script:Ids = @{
        Contract     = "/subscriptions/prod_$G/resourcegroups/nonprod_$G/providers/microsoft.compute/virtualmachines/prod_$G"
        ContractMc   = "/subscriptions/prod_$G/resourcegroups/prod_mc_$G/providers/microsoft.compute/virtualmachinescalesets/prod_vmss_$G"
        ContractKid  = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.sql/servers/prod_$G/databases/prod_$G"
        G1System     = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.servicebus/namespaces/`$system"
        G2NoRg       = "/subscriptions/prod_$G/providers/microsoft.insights/pricings/prod_$G"
        F2Fallback   = "/subscriptions/prod_sub_$G/resourcegroups/prod_rg_$G/providers/microsoft.compute/virtualmachines/prod_$G"
        SystemOther  = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.storage/storageaccounts/`$system"
        SubTokenOnly = "/subscriptions/prod_sub_$G/resourcegroups/prod_$G/providers/microsoft.compute/virtualmachines/prod_$G"
        Flat         = "prod_$G"
        RealName     = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.compute/virtualmachines/vm-web-01"
        NoProvider   = "/subscriptions/prod_$G/resourcegroups/prod_$G"
        FlatSentinel = "obfuscated_$G"
    }
}

Describe 'Get-RdaContractIdPattern' {

    It 'takes the contract shape <_> by default' -ForEach @('Contract', 'ContractMc', 'ContractKid') {
        $script:Ids[$_] | Should -Match (Get-RdaContractIdPattern)
    }

    It 'refuses <_> by default' -ForEach @('G1System', 'G2NoRg', 'F2Fallback', 'SystemOther', 'SubTokenOnly', 'Flat', 'RealName', 'NoProvider', 'FlatSentinel') {
        $script:Ids[$_] | Should -Not -Match (Get-RdaContractIdPattern)
    }

    It 'takes G1 and G2 only with -AllowParked' {
        $script:Ids.G1System | Should -Match (Get-RdaContractIdPattern -AllowParked)
        $script:Ids.G2NoRg | Should -Match (Get-RdaContractIdPattern -AllowParked)
        $script:Ids.G1System | Should -Not -Match (Get-RdaContractIdPattern -AllowMetricFallback)
    }

    It 'takes the F2 fallback tokens only with -AllowMetricFallback' {
        $script:Ids.F2Fallback | Should -Match (Get-RdaContractIdPattern -AllowMetricFallback)
        $script:Ids.F2Fallback | Should -Not -Match (Get-RdaContractIdPattern -AllowParked)
    }

    It 'still refuses <_> with every named shape allowed' -ForEach @('SystemOther', 'SubTokenOnly', 'Flat', 'RealName', 'NoProvider', 'FlatSentinel') {
        $script:Ids[$_] | Should -Not -Match (Get-RdaContractIdPattern -AllowParked -AllowMetricFallback)
    }

    It 'is what the zip-backed tests use, by name' {
        $Dict = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'DictionaryValidation.Tests.ps1')
        $Ref = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'ReferentialIntegrity.Tests.ps1')
        $Dict | Should -Match ([regex]::Escape('$script:MaskedIdPattern = Get-RdaContractIdPattern -AllowParked -AllowMetricFallback'))
        $Ref | Should -Match ([regex]::Escape('$script:MaskedIdPattern = Get-RdaContractIdPattern') + '\r?\n')
        $Ref | Should -Match ([regex]::Escape('$script:MetricFallbackIdPattern = Get-RdaContractIdPattern -AllowMetricFallback'))
    }
}
