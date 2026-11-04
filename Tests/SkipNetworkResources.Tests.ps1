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

# The script code lifted from ResourceInventory.ps1 reads the run's switches
# through dynamic scope and keeps its state in globals, as it does in a run, so
# the tests set both; stand-ins keep the real functions' parameters.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The lifted script code keeps its state in globals.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'The lifted script code reads these through dynamic scope.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins keep the real functions'' parameters; the lifted code reads switches through dynamic scope.')]
param()

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:InventoryScript = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    . (Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    # Lift ResourceInventoryLoop and Invoke-DiscoveryGraphQuery (every
    # discovery query goes through it) out of ResourceInventory.ps1 so the
    # real query text and the real query path are what get checked.
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
    $QueryFn = $script:InventoryAst.FindAll({
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Invoke-DiscoveryGraphQuery'
        }, $true) | Select-Object -First 1
    if ($null -eq $QueryFn) { throw 'Invoke-DiscoveryGraphQuery was not found in ResourceInventory.ps1.' }
    . ([scriptblock]::Create($QueryFn.Extent.Text))

    # Something for Mock to replace.
    function Invoke-AzGraphQuerySafe { param($Query, $SubscriptionId, [switch]$Lowercase, [switch]$HideRawOutput) }

    $script:Sub = '12345678-1234-1234-1234-123456789012'
    # A subscription the access check skipped; its rows are not counted.
    $script:OtherSub = '87654321-4321-4321-4321-210987654321'
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
        param([ValidateSet('ResourceGroup', 'Subscription', 'Tenant')][string]$Scope, [switch]$Include, [switch]$FailSkippedCount, [string[]]$AccessSkippedIds = @())

        $script:Queries = [System.Collections.Generic.List[string]]::new()
        $script:FailSkipped = $FailSkippedCount.IsPresent
        Mock -CommandName Invoke-AzGraphQuerySafe -MockWith {
            $script:Queries.Add($Query)
            if ($Query -match 'summarize count\(\) by type')
            {
                if ($script:FailSkipped) { throw "Resource Graph query failed: status 500`nQuery: $Query" }
                return [pscustomobject]@{ data = @(
                        [pscustomobject]@{ type = 'microsoft.network/networksecuritygroups'; subscriptionId = $script:Sub; count_ = 20 },
                        [pscustomobject]@{ type = 'microsoft.network/virtualnetworks'; subscriptionId = $script:Sub; count_ = 12 },
                        [pscustomobject]@{ type = 'microsoft.network/networksecuritygroups'; subscriptionId = $script:Sub; count_ = 5 },
                        [pscustomobject]@{ type = 'microsoft.network/routetables'; subscriptionId = $script:OtherSub; count_ = 7 }
                    )
                }
            }
            if ($Query -match 'summarize count\(\)') { return [pscustomobject]@{ data = @([pscustomobject]@{ count_ = 2 }) } }
            return [pscustomobject]@{ data = @([pscustomobject]@{ id = '/subscriptions/x/resourcegroups/rg/providers/microsoft.compute/virtualmachines/a'; type = 'microsoft.compute/virtualmachines' }) }
        }
        Mock -CommandName Write-Log -MockWith { }

        $Global:Resources = @()
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; Name = 'sub' })
        # The access check's skipped subscriptions, as RunInventorySetup sets them.
        $script:AccessSkipped = if (@($AccessSkippedIds).Count -gt 0) { [pscustomobject]@{ InaccessibleIds = @($AccessSkippedIds) } } else { $null }
        $script:RunAllSubs = [switch]$false
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
        $Page = @($Queries | Where-Object { $_ -match '\| order by tolower\(id\) asc$' })
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
        $Skip = @($Queries | Where-Object { $_ -match 'summarize count\(\) by type, subscriptionId$' })
        $Skip.Count | Should -Be 1
        $Skip[0] | Should -Match 'where type in~ \('
        if ($Scope -eq 'ResourceGroup') { $Skip[0] | Should -Match "resourceGroup == 'rg1'" }

        # Two batches' rows for one type are added up. The other
        # subscription's row counts here, since the access check skipped none.
        $Global:SkippedResourceCount | Should -Be 44
        $Global:SkippedResourceTypes['microsoft.network/networksecuritygroups'] | Should -Be 25
        $Global:SkippedResourceTypes['microsoft.network/virtualnetworks'] | Should -Be 12
    }

    It 'leaves the subscriptions the access check skipped out of the skipped count' {
        $null = Invoke-LoopAtScope -Scope 'Tenant' -AccessSkippedIds @($script:OtherSub)
        $Global:SkippedResourceCount | Should -Be 37
        $Global:SkippedResourceTypes.Contains('microsoft.network/routetables') | Should -BeFalse
    }

    It 'sends every count and page query through Invoke-DiscoveryGraphQuery, never straight to Invoke-AzGraphQuerySafe' {
        $LoopText = ($script:InventoryAst.FindAll({
                    param($Node)
                    $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'ResourceInventoryLoop'
                }, $true) | Select-Object -First 1).Extent.Text
        $LoopText | Should -Not -Match 'Invoke-AzGraphQuerySafe'
        ([regex]::Matches($LoopText, 'Invoke-DiscoveryGraphQuery -Query \$GraphQuery')).Count | Should -Be 6
        ([regex]::Matches($LoopText, 'where \$Where\$SkipFilter \|')).Count | Should -Be 6
    }
}

Describe 'Skipped-count query failure' {

    It 'warns once and still collects the resources' {
        $Queries = Invoke-LoopAtScope -Scope 'Subscription' -FailSkippedCount
        @($Queries | Where-Object { $_ -match 'by type' }).Count | Should -Be 1 -Because 'it is tried once, never retried in a loop'
        @($Queries | Where-Object { $_ -match 'order by tolower\(id\) asc$' }).Count | Should -Be 1
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

    It 'every caller counts from $Global:ResourceCount, never from $Global:Resources, which is released once the inventory is written' {
        foreach ($Text in @($script:Wrapper, $script:Stream))
        {
            $Text | Should -Not -Match '@\(\$Global:Resources\)\.Count'
            $Text | Should -Match '\$ResCount = if \(\$null -ne \$Global:ResourceCount\)'
        }
        $script:Inventory | Should -Match 'Get-RdaResourceCountMessage -Collected \$Global:ResourceCount '
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

Describe '-IncludeNetworkResources in the stored run settings' {

    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
        $script:Tenant = '12345678-1234-1234-1234-123456789012'
        $script:Now = [datetime]::new(2026, 11, 4, 12, 0, 0, [System.DateTimeKind]::Utc)
        $script:StateDir = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-netskip-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null

        # A resume state file as a run writes it, with RunSettings as given
        # (an older run's record has no IncludeNetworkResources key).
        function script:Write-StateFile
        {
            param([Parameter(Mandatory = $true)]$RunSettings)
            $File = Join-Path $script:StateDir ([guid]::NewGuid().ToString() + '.json')
            $Window = ConvertTo-ConsumptionWindowArgument -Window (Get-ConsumptionWindow -Now $script:Now)
            [pscustomobject]@{
                TenantID = $script:Tenant; CompletedSubscriptionIds = @()
                RunStartedAt = $script:Now.AddHours(-2).ToString('o', [cultureinfo]::InvariantCulture)
                RunSettings = $RunSettings
                ConsumptionWindowStart = $Window.ConsumptionWindowStart; ConsumptionWindowEnd = $Window.ConsumptionWindowEnd
            } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $File -Encoding utf8
            return $File
        }
        $script:OlderSettings = [pscustomobject]@{ Obfuscate = $true; SkipMetrics = $false; SkipConsumption = $false; IncludeDisabled = $false }
        function script:Resolve-Next
        {
            param([string]$File, [bool]$Include, [bool]$Resume, [bool]$Fresh)
            $Info = Read-ResumeRunInfo -Path $File -Tenant $script:Tenant
            $Settings = Get-RunDataSettings -Obfuscate $true -IncludeNetworkResources $Include
            return (Resolve-RunStart -Info $Info -Resume $Resume -Fresh $Fresh -Settings $Settings -Now $script:Now)
        }
    }

    AfterAll { Remove-Item -LiteralPath $script:StateDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'is one of the run settings, recorded off by default and on when given' {
        @(Get-RunDataSettingNames) | Should -Contain 'IncludeNetworkResources'
        (Get-RunDataSettings).IncludeNetworkResources | Should -BeFalse
        (Get-RunDataSettings -IncludeNetworkResources $true).IncludeNetworkResources | Should -BeTrue
        Format-RunDataSettings -Settings (Get-RunDataSettings -IncludeNetworkResources $true) | Should -Be '-IncludeNetworkResources'
    }

    It 'the wrapper records it and passes it on to the stream worker and the inner script' {
        $Wrapper = Get-Content -Path (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Wrapper | Should -Match 'Get-RunDataSettings [^\r\n]*-IncludeNetworkResources \(\[bool\]\$IncludeNetworkResources\)'
    }

    It 'printed retry commands carry it, the wrapper''s and the direct run''s' {
        $S = Get-RetryCommandSettings -Settings (Get-RunDataSettings -IncludeNetworkResources $true) -DeviceLogin $false
        Get-WrapperRunCommand -TenantID $script:Tenant -Mode '-Resume' -Settings $S | Should -Be ('./Run-AllSubscriptions.ps1 -TenantID {0} -Resume -IncludeNetworkResources' -f $script:Tenant)
        Get-DirectRunRetryCommand -TenantID $script:Tenant -SubscriptionID 'sub-a' -Settings $S | Should -Be ('./ResourceInventory.ps1 -TenantID {0} -SubscriptionID sub-a -IncludeNetworkResources' -f $script:Tenant)
    }

    It 'an older run''s record with no such key reads as off, not as unreadable settings' {
        $File = script:Write-StateFile -RunSettings $script:OlderSettings
        $Info = Read-ResumeRunInfo -Path $File -Tenant $script:Tenant
        $Info.SettingsProblem | Should -BeNullOrEmpty
        $Info.Settings['IncludeNetworkResources'] | Should -BeFalse
        $Info.Settings['Obfuscate'] | Should -BeTrue
    }

    It 'any other setting left out of a record is still unreadable' {
        $File = script:Write-StateFile -RunSettings ([pscustomobject]@{ Obfuscate = $true; SkipMetrics = $false; SkipConsumption = $false })
        (Read-ResumeRunInfo -Path $File -Tenant $script:Tenant).SettingsProblem | Should -Be 'IncludeDisabled is not recorded'
    }

    It 'a key that is not true or false is unreadable, and -Fresh is the way out' {
        $File = script:Write-StateFile -RunSettings ([pscustomobject]@{ Obfuscate = $true; SkipMetrics = $false; SkipConsumption = $false; IncludeDisabled = $false; IncludeNetworkResources = 'yes' })
        $D = script:Resolve-Next -File $File -Include $false
        $D.Mode | Should -Be 'Stop'; $D.Reason | Should -Be 'settings-unreadable'; $D.ExitCode | Should -Be 1
        (script:Resolve-Next -File $File -Include $false -Fresh $true).Mode | Should -Be 'New'
    }

    It 'the next two runs after an older unfinished run: without the switch both continue, -Resume too' {
        $File = script:Write-StateFile -RunSettings $script:OlderSettings
        $Run2 = script:Resolve-Next -File $File -Include $false
        $Run2.Mode | Should -Be 'Continue'; $Run2.ExitCode | Should -Be 0
        # Run 2 is interrupted in turn: the file keeps the stored record as it was.
        $Run3 = script:Resolve-Next -File $File -Include $false -Resume $true
        $Run3.Mode | Should -Be 'Continue'; $Run3.ExitCode | Should -Be 0
    }

    It 'with the switch on an older unfinished run: exit 1 that names the way out, which then continues or starts a new run' {
        $File = script:Write-StateFile -RunSettings $script:OlderSettings
        $Run2 = script:Resolve-Next -File $File -Include $true -Resume $true
        $Run2.Mode | Should -Be 'Stop'; $Run2.Reason | Should -Be 'settings-differ'; $Run2.ExitCode | Should -Be 1
        @($Run2.Lines | ForEach-Object Text) | Should -Contain '  -IncludeNetworkResources: off in the unfinished run, on in this run.'
        @($Run2.Lines | ForEach-Object Text)[-1] | Should -BeLike '*settings (-Obfuscate) to continue it, or pass -Fresh*'
        # Run 3a takes the first way out (same settings, no switch): continues.
        (script:Resolve-Next -File $File -Include $false -Resume $true).Mode | Should -Be 'Continue'
        # Run 3b takes the second (-Fresh with the switch): a new run.
        (script:Resolve-Next -File $File -Include $true -Fresh $true).Mode | Should -Be 'New'
    }

    It 'a new run''s record keeps the switch, so its next run continues only with it' {
        $Info = New-ResumeRunInfo -StartedAt $script:Now.AddHours(-1) -Settings (Get-RunDataSettings -Obfuscate $true -IncludeNetworkResources $true) -Window (Get-ConsumptionWindow -Now $script:Now)
        $Info.RunSettings.IncludeNetworkResources | Should -BeTrue
        $File = script:Write-StateFile -RunSettings $Info.RunSettings
        (script:Resolve-Next -File $File -Include $true).Mode | Should -Be 'Continue'
        $D = script:Resolve-Next -File $File -Include $false
        $D.Mode | Should -Be 'Stop'; $D.Reason | Should -Be 'settings-differ'
        @($D.Lines | ForEach-Object Text)[-1] | Should -BeLike '*settings (-Obfuscate -IncludeNetworkResources) to continue it*'
    }

    It 'a per-stream record without the key matches a main record with it off' {
        $Main = Read-ResumeRunInfo -Path (script:Write-StateFile -RunSettings ([pscustomobject](Get-RunDataSettings -Obfuscate $true))) -Tenant $script:Tenant
        $Older = Read-ResumeRunInfo -Path (script:Write-StateFile -RunSettings $script:OlderSettings) -Tenant $script:Tenant
        @(Get-ResumeRunRecordDifferences -Main $Main -Other $Older | Where-Object { $_.What -ne 'the start time' }) | Should -BeNullOrEmpty
    }
}
