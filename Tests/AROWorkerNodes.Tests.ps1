# ARO TotalWorkerNodes tests
# Run with: Invoke-Pester ./Tests/AROWorkerNodes.Tests.ps1 -Output Detailed
#
# Services/Compute/ARO.ps1 wrote workerProfiles.count as TotalWorkerNodes: the
# number of worker pools, not the number of nodes. Each pool carries its own
# 'count', and the total is their sum. The REAL collector runs on synthetic
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
        return , @(& (Join-Path $script:Root 'Services/Compute/ARO.ps1') -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $null)
    }

    function New-Pool
    {
        param($Count, [switch]$NoCount)
        $Pool = [ordered]@{ name = 'worker'; vmSize = 'Standard_D4s_v3'; diskSizeGB = 128 }
        if (-not $NoCount) { $Pool['count'] = $Count }
        return [pscustomobject]$Pool
    }

    function New-Cluster
    {
        param($Pools, [switch]$NoPools)
        $Props = [ordered]@{
            clusterProfile    = [pscustomobject]@{ version = '4.14.16' }
            networkProfile    = [pscustomobject]@{ outboundType = 'Loadbalancer' }
            apiserverProfile  = [pscustomobject]@{ visibility = 'Public' }
            masterProfile     = [pscustomobject]@{ vmSize = 'Standard_D8s_v3' }
        }
        if (-not $NoPools) { $Props['workerProfiles'] = $Pools }
        return [pscustomobject]@{
            TYPE           = 'microsoft.redhatopenshift/openshiftclusters'
            id             = "$($script:Rg)/Microsoft.RedHatOpenShift/openShiftClusters/aro-a"
            NAME           = 'aro-a'
            RESOURCEGROUP  = 'rg-a'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            PROPERTIES     = [pscustomobject]$Props
        }
    }
}

Describe 'ARO TotalWorkerNodes' {
    It 'sums the node counts of several pools' {
        $Rows = Invoke-Collector (New-Cluster -Pools @((New-Pool 3), (New-Pool 2), (New-Pool 4)))
        $Rows.Count | Should -Be 1
        $Rows[0].TotalWorkerNodes | Should -Be 9
    }

    It 'reads one pool as its own count' {
        (Invoke-Collector (New-Cluster -Pools @((New-Pool 3))))[0].TotalWorkerNodes | Should -Be 3
    }

    It 'reads a pool given as a single object rather than an array' {
        (Invoke-Collector (New-Cluster -Pools (New-Pool 5)))[0].TotalWorkerNodes | Should -Be 5
    }

    It 'reads 64-bit counts as JSON parsing gives them' {
        (Invoke-Collector (New-Cluster -Pools @((New-Pool ([long]3)), (New-Pool ([long]3)))))[0].TotalWorkerNodes | Should -Be 6
    }

    It 'reads a count written as a whole-number string' {
        (Invoke-Collector (New-Cluster -Pools @((New-Pool '3'), (New-Pool ' 2 '))))[0].TotalWorkerNodes | Should -Be 5
    }

    It 'writes 0 when there are no pools (<Case>)' -ForEach @(
        @{ Case = 'empty array'; NoPools = $false }
        @{ Case = 'no workerProfiles'; NoPools = $true }
    ) {
        $Cluster = if ($NoPools) { New-Cluster -NoPools } else { New-Cluster -Pools @() }
        (Invoke-Collector $Cluster)[0].TotalWorkerNodes | Should -Be 0
    }

    It 'writes an empty total when a pool count is <Case>' -ForEach @(
        @{ Case = 'not a number'; Value = 'three' }
        @{ Case = 'a fraction'; Value = '2.5' }
        @{ Case = 'negative'; Value = -1 }
        @{ Case = 'null'; Value = $null }
        @{ Case = 'an object'; Value = [pscustomobject]@{ n = 3 } }
    ) {
        $Rows = Invoke-Collector (New-Cluster -Pools @((New-Pool 3), (New-Pool $Value)))
        $Rows.Count | Should -Be 1
        $Rows[0].TotalWorkerNodes | Should -BeNullOrEmpty
    }

    It 'writes an empty total when a pool has no count' {
        (Invoke-Collector (New-Cluster -Pools @((New-Pool 3), (New-Pool -NoCount))))[0].TotalWorkerNodes | Should -BeNullOrEmpty
    }

    It 'leaves the other columns unchanged' {
        $Row = (Invoke-Collector (New-Cluster -Pools @((New-Pool 3), (New-Pool 2))))[0]
        $Row.AROVersion | Should -BeExactly '4.14.16'
        $Row.OutboundType | Should -BeExactly 'Loadbalancer'
        $Row.APIServerType | Should -BeExactly 'Public'
        $Row.MasterSKU | Should -BeExactly 'Standard_D8s_v3'
        $Row.WorkerSKU | Should -BeExactly 'Standard_D4s_v3'
        $Row.WorkerDiskSize | Should -Be 128
        $Row.Clusters | Should -BeExactly 'aro-a'
        @($Row.Keys).Count | Should -Be 12
    }
}
