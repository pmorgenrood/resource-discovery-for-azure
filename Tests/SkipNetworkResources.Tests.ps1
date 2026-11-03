# Requires -Modules Pester
# =============================================================================
# SkipNetworkResources.Tests.ps1
#
# The Resource Graph pull leaves out the network resource types that no
# collector reads (virtual networks, NSGs, NICs and the like). They have no
# Inventory section, and network costs come from the consumption data, so
# they only cost time and memory. -IncludeNetworkResources brings them back.
#
# What is checked here, with no live Azure:
#   - the count query and the page query carry the same type filter at all
#     three scopes (resource group, subscription, tenant), so paging stays in
#     step, and -IncludeNetworkResources removes it from both;
#   - the skip list holds no type that any collector reads. A future
#     collector for a skipped type fails this test instead of silently
#     getting no rows;
#   - one extra query counts the skipped rows by type; if it fails the run
#     warns once and carries on;
#   - the per-subscription log line in its three cases, and that the wrapper,
#     the stream worker and the direct run use it.
#
# Run with: Invoke-Pester ./Tests/SkipNetworkResources.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:InventoryScript = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    . (Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    # Lift ResourceInventoryLoop out of ResourceInventory.ps1 so the real
    # query text is what gets checked.
    $Tokens = $null
    $ParseErrors = $null
    $script:InventoryAst = [System.Management.Automation.Language.Parser]::ParseFile($script:InventoryScript, [ref]$Tokens, [ref]$ParseErrors)
    if (@($ParseErrors).Count -gt 0) { throw ("ResourceInventory.ps1 does not parse: {0}" -f $ParseErrors[0].Message) }
    $LoopFn = $script:InventoryAst.FindAll({
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'ResourceInventoryLoop'
        }, $true) | Select-Object -First 1
    if ($null -eq $LoopFn) { throw 'ResourceInventoryLoop was not found in ResourceInventory.ps1.' }
    . ([scriptblock]::Create($LoopFn.Extent.Text))

    # Something for Mock to replace.
    function Invoke-AzGraphQuerySafe { param($Query, $SubscriptionId, [switch]$Lowercase, [switch]$HideRawOutput) }

    $script:Sub = '12345678-1234-1234-1234-123456789012'
    $script:ExpectedSkip = @(
        'microsoft.network/virtualnetworks'
        'microsoft.network/networksecuritygroups'
        'microsoft.network/networkinterfaces'
        'microsoft.network/privateendpoints'
        'microsoft.network/privatednszones'
        'microsoft.network/privatednszones/virtualnetworklinks'
        'microsoft.network/routetables'
        'microsoft.network/networkwatchers'
        'microsoft.network/networkwatchers/flowlogs'
        'microsoft.network/applicationsecuritygroups'
        'microsoft.network/ddosprotectionplans'
        'microsoft.network/ipgroups'
        'microsoft.network/connections'
        'microsoft.network/localnetworkgateways'
        'microsoft.network/firewallpolicies'
        'microsoft.network/networkintentpolicies'
        'microsoft.network/privatelinkservices'
    )

    # Runs the lifted loop at one scope and returns every query it sent.
    function Invoke-LoopAtScope
    {
        param([ValidateSet('ResourceGroup', 'Subscription', 'Tenant')][string]$Scope, [switch]$Include, [switch]$FailSkippedCount)

        $script:Queries = [System.Collections.Generic.List[string]]::new()
        $script:FailSkipped = $FailSkippedCount.IsPresent
        Mock -CommandName Invoke-AzGraphQuerySafe -MockWith {
            $script:Queries.Add($Query)
            if ($Query -match 'summarize count\(\) by type')
            {
                if ($script:FailSkipped) { throw "Resource Graph query failed: status 500`nQuery: $Query" }
                return [pscustomobject]@{ data = @(
                        [pscustomobject]@{ type = 'microsoft.network/networksecuritygroups'; count_ = 20 },
                        [pscustomobject]@{ type = 'microsoft.network/virtualnetworks'; count_ = 12 },
                        [pscustomobject]@{ type = 'microsoft.network/networksecuritygroups'; count_ = 5 }
                    )
                }
            }
            if ($Query -match 'summarize count\(\)') { return [pscustomobject]@{ data = @([pscustomobject]@{ count_ = 2 }) } }
            return [pscustomobject]@{ data = @([pscustomobject]@{ id = '/subscriptions/x/resourcegroups/rg/providers/microsoft.compute/virtualmachines/a'; type = 'microsoft.compute/virtualmachines' }) }
        }
        Mock -CommandName Write-Log -MockWith { }

        $Global:Resources = @()
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; Name = 'sub' })
        $script:IncludeNetworkResources = [switch]$Include.IsPresent
        $script:Obfuscate = [switch]$false
        switch ($Scope)
        {
            'ResourceGroup' { $script:SubscriptionID = $script:Sub; $script:ResourceGroup = 'rg1' }
            'Subscription' { $script:SubscriptionID = $script:Sub; $script:ResourceGroup = '' }
            'Tenant' { $script:SubscriptionID = ''; $script:ResourceGroup = '' }
        }
        # The loop reads these through dynamic scope, as it does inside
        # RunInventorySetup.
        $SubscriptionID = $script:SubscriptionID
        $ResourceGroup = $script:ResourceGroup
        $IncludeNetworkResources = $script:IncludeNetworkResources
        $Obfuscate = $script:Obfuscate
        ResourceInventoryLoop
        return , @($script:Queries)
    }
}

AfterAll {
    Remove-Variable -Scope Global -Name Resources, Subscriptions, SkippedResourceCount, SkippedResourceTypes -ErrorAction SilentlyContinue
}

Describe 'The skip list' {

    It 'holds exactly the network types that have no collector' {
        $List = @(Get-RdaNetworkSkipList)
        ($List | Sort-Object) -join ',' | Should -Be (($script:ExpectedSkip | Sort-Object) -join ',')
    }

    It 'holds no type that any collector reads (a new collector must not be starved silently)' {
        $Files = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'Services'), (Join-Path $script:RepoRoot 'Extension') -Recurse -Filter '*.ps1')
        $Read = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($File in $Files)
        {
            $Text = Get-Content -Path $File.FullName -Raw
            foreach ($M in [regex]::Matches($Text, '(?i)\.type\s*-[ic]?(eq|like|match|contains|in)\s*[''"]([a-z0-9./*]+)[''"]'))
            {
                [void]$Read.Add($M.Groups[2].Value)
            }
            # Any spelled-out provider type, wherever it appears in a collector.
            foreach ($M in [regex]::Matches($Text, '(?i)[''"](microsoft\.[a-z0-9]+/[a-z0-9./]+)[''"]'))
            {
                [void]$Read.Add($M.Groups[1].Value)
            }
        }
        # Guard against a regex that silently matches nothing.
        $Read.Count | Should -BeGreaterThan 50
        $Read.Contains('microsoft.network/publicipaddresses') | Should -BeTrue

        $Overlap = @(Get-RdaNetworkSkipList | Where-Object { $Read.Contains($_) })
        $Overlap | Should -BeNullOrEmpty -Because 'a collector reads these types, so they must not be skipped'
    }

    It 'is lowercase, with no duplicates' {
        $List = @(Get-RdaNetworkSkipList)
        @($List | Where-Object { $_ -cne $_.ToLowerInvariant() }) | Should -BeNullOrEmpty
        @($List | Select-Object -Unique).Count | Should -Be $List.Count
    }

    It 'gives a filter that names every type, and none with -IncludeNetworkResources' {
        $Filter = Get-RdaNetworkSkipFilter
        $Filter | Should -Match '^ \| where type !in~ \('
        foreach ($T in $script:ExpectedSkip) { $Filter | Should -Match ([regex]::Escape("'$T'")) }
        Get-RdaNetworkSkipFilter -IncludeNetworkResources | Should -Be ''
    }
}

Describe 'Query text at every scope' {

    It 'carries the filter on both the count and the page query at <Scope> scope' -TestCases @(
        @{ Scope = 'ResourceGroup' }, @{ Scope = 'Subscription' }, @{ Scope = 'Tenant' }
    ) {
        param($Scope)
        $Queries = Invoke-LoopAtScope -Scope $Scope
        $Filter = Get-RdaNetworkSkipFilter

        $Count = @($Queries | Where-Object { $_ -match '\| summarize count\(\)$' })
        $Page = @($Queries | Where-Object { $_ -match '\| order by id asc$' })
        $Count.Count | Should -Be 1
        $Page.Count | Should -Be 1
        $Count[0] | Should -BeLike ('*' + $Filter + ' | summarize count()')
        $Page[0] | Should -BeLike ('*' + $Filter + ' | project *')
        # Same where on both, so the paging matches the count.
        ($Count[0] -replace ' \| summarize count\(\)$', '') | Should -Be ($Page[0] -replace ' \| project .*$', '')
    }

    It 'drops the filter from both queries with -IncludeNetworkResources at <Scope> scope' -TestCases @(
        @{ Scope = 'ResourceGroup' }, @{ Scope = 'Subscription' }, @{ Scope = 'Tenant' }
    ) {
        param($Scope)
        $Queries = Invoke-LoopAtScope -Scope $Scope -Include
        @($Queries | Where-Object { $_ -match '!in~' }) | Should -BeNullOrEmpty
        @($Queries | Where-Object { $_ -match 'by type' }) | Should -BeNullOrEmpty -Because 'nothing is skipped, so nothing is counted'
        $Global:SkippedResourceCount | Should -Be 0
    }

    It 'counts the skipped rows by type with the same scope at <Scope> scope' -TestCases @(
        @{ Scope = 'ResourceGroup' }, @{ Scope = 'Subscription' }, @{ Scope = 'Tenant' }
    ) {
        param($Scope)
        $Queries = Invoke-LoopAtScope -Scope $Scope
        $Skip = @($Queries | Where-Object { $_ -match 'summarize count\(\) by type$' })
        $Skip.Count | Should -Be 1
        $Skip[0] | Should -Match 'where type in~ \('
        if ($Scope -eq 'ResourceGroup') { $Skip[0] | Should -Match "resourceGroup == 'rg1'" }

        # Two batches' rows for one type are added up.
        $Global:SkippedResourceCount | Should -Be 37
        $Global:SkippedResourceTypes['microsoft.network/networksecuritygroups'] | Should -Be 25
        $Global:SkippedResourceTypes['microsoft.network/virtualnetworks'] | Should -Be 12
    }
}

Describe 'Skipped-count query failure' {

    It 'warns once and still collects the resources' {
        $Queries = Invoke-LoopAtScope -Scope 'Subscription' -FailSkippedCount
        @($Queries | Where-Object { $_ -match 'by type' }).Count | Should -Be 1 -Because 'it is tried once, never retried in a loop'
        @($Queries | Where-Object { $_ -match 'order by id asc$' }).Count | Should -Be 1
        @($Global:Resources).Count | Should -Be 1
        $Global:SkippedResourceCount | Should -BeNullOrEmpty
        Should -Invoke -CommandName Write-Log -Times 1 -Exactly -ParameterFilter { $Severity -eq 'Warning' }
    }
}

Describe 'Per-subscription count message' {

    It 'collected 0 and skipped 0: the caller keeps its empty-subscription warning' {
        $M = Get-RdaResourceCountMessage -Collected 0 -Skipped 0
        $M.Kind | Should -Be 'Empty'
    }

    It 'collected 0 and skipped unknown: still the empty-subscription warning' {
        $M = Get-RdaResourceCountMessage -Collected 0 -Skipped $null
        $M.Kind | Should -Be 'Empty'
    }

    It 'collected 0 and skipped > 0: not a warning, names the types' {
        $ByType = [ordered]@{ 'microsoft.network/virtualnetworks' = 12; 'microsoft.network/networksecuritygroups' = 20; 'microsoft.network/routetables' = 8 }
        $M = Get-RdaResourceCountMessage -Collected 0 -Skipped 40 -SkippedByType $ByType
        $M.Kind | Should -Be 'NetworkOnly'
        $M.Text | Should -Be '0 resources collected. 40 network resources skipped (20 networksecuritygroups, 12 virtualnetworks, 8 routetables). Network costs still come from the consumption data.'
        $M.Text | Should -Not -Match '(?i)billable'
    }

    It 'collected > 0 and skipped > 0' {
        $M = Get-RdaResourceCountMessage -Collected 120 -Skipped 35
        $M.Kind | Should -Be 'Collected'
        $M.Text | Should -Be 'Resources collected: 120 (35 network resources skipped)'
    }

    It 'collected > 0 and nothing skipped: the line as it was' {
        (Get-RdaResourceCountMessage -Collected 1234 -Skipped 0).Text | Should -Be 'Resources collected: 1,234'
        (Get-RdaResourceCountMessage -Collected 5 -Skipped $null).Text | Should -Be 'Resources collected: 5'
    }

    It 'says resource, not resources, for one' {
        (Get-RdaResourceCountMessage -Collected 3 -Skipped 1).Text | Should -Be 'Resources collected: 3 (1 network resource skipped)'
        (Get-RdaResourceCountMessage -Collected 0 -Skipped 1 -SkippedByType @{ 'microsoft.network/networkwatchers' = 1 }).Text |
            Should -Be '0 resources collected. 1 network resource skipped (1 networkwatchers). Network costs still come from the consumption data.'
    }
}

Describe 'Callers use the message and the switch' {

    BeforeAll {
        $script:Wrapper = Get-Content -Path (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $script:Stream = Get-Content -Path (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') -Raw
        $script:Inventory = Get-Content -Path $script:InventoryScript -Raw
    }

    It 'the wrapper builds both per-subscription lines from it' {
        ([regex]::Matches($script:Wrapper, 'Get-RdaResourceCountMessage')).Count | Should -BeGreaterOrEqual 2
    }

    It 'the stream worker builds its line from it, loads Common.Functions.ps1 and reports the skipped count' {
        $script:Stream | Should -Match 'Get-RdaResourceCountMessage'
        $script:Stream | Should -Match "Functions/Common\.Functions\.ps1"
        $script:Stream | Should -Match 'Skipped\s*=\s*\$'
    }

    It 'the direct run logs it' {
        $script:Inventory | Should -Match 'Get-RdaResourceCountMessage'
    }

    It '-IncludeNetworkResources is a switch on all three scripts and is passed on' {
        foreach ($Text in @($script:Inventory, $script:Wrapper, $script:Stream))
        {
            $Text | Should -Match '\[switch\]\s*\$IncludeNetworkResources'
        }
        $script:Wrapper | Should -Match "InventoryPassthrough\['IncludeNetworkResources'\]"
        $script:Wrapper | Should -Match 'WorkerArgs\.IncludeNetworkResources'
        $script:Stream | Should -Match "InventoryPassthrough\['IncludeNetworkResources'\]"
    }

    It 'the inner script clears the skipped count at the start of every run' {
        $VarFn = $script:InventoryAst.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Variables'
            }, $true) | Select-Object -First 1
        $VarFn.Extent.Text | Should -Match '\$Global:SkippedResourceCount\s*=\s*0'
    }

    It 'a network-only subscription is not listed as empty in the run summary' {
        $script:Wrapper | Should -Match '\$EmptySubs = @\(\$SubResourceCounts \| Where-Object \{ \$_\.Count -eq 0 -and -not \(\[long\]\$_\.Skipped -gt 0\) \}\)'
    }
}
