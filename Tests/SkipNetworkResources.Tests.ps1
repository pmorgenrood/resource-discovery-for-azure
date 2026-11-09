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

    BeforeAll {
        # What a collector's text says about the resource types it reads:
        # every type comparison (.type / TYPE with -eq, -like, -match, -in,
        # -contains and their case forms, with the type on either side), every
        # spelled-out provider type, and every skipped type named by its id
        # segment ('/networkinterfaces/'). A -like or -match pattern counts as
        # reading each skip-list type it matches. A comparison that cannot be
        # checked is reported on its own: a negated one (-ne, -notlike,
        # -notmatch, -notin, -notcontains reads every type but the named ones),
        # or one whose other side is not a quoted literal or a list of them (a
        # variable, an expression, an interpolated string, a joined string).
        function script:Get-CollectorTypeRead
        {
            param([string]$Text, [string[]]$SkipList)
            $Hits = [System.Collections.Generic.List[string]]::new()
            $Unchecked = [System.Collections.Generic.List[string]]::new()
            $Literals = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $Ops = 'eq|ne|like|notlike|match|notmatch|in|notin|contains|notcontains'
            # The other side: an @( ) list, a quoted string, or any one word.
            $Side = '(@\((?:[^()]|\([^()]*\))*\)|''[^'']*''|"[^"]*"|\S+)'
            # The quoted strings of the other side, or $null when it is
            # anything else (a variable, an expression, a string with $ in it,
            # a list with any of those in it).
            $GetQuoted = {
                param([string]$S)
                if ($S -match '^''[^'']*''$' -or $S -match '^"[^"$]*"$') { return , @($S.Substring(1, $S.Length - 2)) }
                if ($S -match '^@\((?<Inner>[\s\S]*)\)$')
                {
                    $Inner = $Matches['Inner']
                    if (($Inner -replace '''[^'']*''|"[^"$]*"', '') -notmatch '^[\s,]*$') { return $null }
                    return , @([regex]::Matches($Inner, '''([^'']*)''|"([^"]*)"') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })
                }
                return $null
            }
            $Compare = '(?i)\btype\b[''"]?(?:\.ToLower(?:Invariant)?\(\))?(?:\s*\))?[''"]?\s*-[ic]?(' + $Ops + ')\s*' + $Side + '(\s*\+)?'
            $Reverse = '(?i)' + $Side + '\s*-[ic]?(' + $Ops + ')\s*\(?\s*"?\$\(?[\w:]*(?:\.\w+)*\.type\b'
            foreach ($M in [regex]::Matches($Text, $Compare))
            {
                $Op = $M.Groups[1].Value.ToLowerInvariant()
                $Values = & $GetQuoted $M.Groups[2].Value
                if ($Op -match '^(ne|not)' -or $M.Groups[3].Success -or $null -eq $Values)
                {
                    $Unchecked.Add($M.Value)
                    continue
                }
                foreach ($Value in $Values)
                {
                    switch ($Op)
                    {
                        'like' { foreach ($T in $SkipList) { if ($T -like $Value) { $Hits.Add("$T (by -like '$Value')") } } }
                        'match' { foreach ($T in $SkipList) { if ($T -match $Value) { $Hits.Add("$T (by -match '$Value')") } } }
                        default { [void]$Literals.Add($Value) }
                    }
                }
            }
            # The type on the right: only a quoted literal or a quoted list on
            # the left, with -eq, -in or -contains, can be checked.
            foreach ($M in [regex]::Matches($Text, $Reverse))
            {
                $Op = $M.Groups[2].Value.ToLowerInvariant()
                $Values = & $GetQuoted $M.Groups[1].Value
                if ($Op -notin @('eq', 'in', 'contains') -or $null -eq $Values)
                {
                    $Unchecked.Add($M.Value)
                    continue
                }
                foreach ($Value in $Values) { [void]$Literals.Add($Value) }
            }
            # A skipped type named by its id segment in any quoted string with
            # a / in it ('*/providers/microsoft.network/networkinterfaces/*',
            # '/networkinterfaces/'). In an id the child type comes two parts
            # after the parent (parent/name/child), in a type one part after.
            # A parent segment followed by a child type reads only that child:
            # a kept one ('/networkwatchers/*/connectionmonitors/') is fine, a
            # skipped one ('/flowlogs/') is a hit on its own segment.
            $Segments = @{}
            foreach ($T in $SkipList) { $P = $T.Split('/'); $Segments[$P[$P.Count - 1]] = $T }
            foreach ($M in [regex]::Matches($Text, '''[^''\r\n]*/[^''\r\n]*''|"[^"\r\n]*/[^"\r\n]*"'))
            {
                $Lit = $M.Value.Substring(1, $M.Value.Length - 2).ToLowerInvariant()
                $Parts = @($Lit.Split('/') | ForEach-Object { $_.TrimEnd('*', '?', '$') })
                $Step = if ($Parts[0] -match '^\^?microsoft') { 1 } else { 2 }
                for ($i = 0; $i -lt $Parts.Count; $i++)
                {
                    if (-not $Segments.ContainsKey($Parts[$i])) { continue }
                    $T = $Segments[$Parts[$i]]
                    $Child = if ($i + $Step -lt $Parts.Count) { $Parts[$i + $Step] } else { '' }
                    if ($T.Split('/').Count -eq 2 -and $Child -match '^[a-z0-9]+$') { continue }
                    $Hits.Add("$T (by the id segment in '$Lit')")
                }
            }
            foreach ($M in [regex]::Matches($Text, '(?i)[''"](microsoft\.[a-z0-9]+/[a-z0-9./]+)[''"]'))
            {
                [void]$Literals.Add($M.Groups[1].Value)
            }
            # A provider type literal with a wildcard (a switch -Wildcard
            # case, a pattern kept in a variable): read as -like.
            foreach ($M in [regex]::Matches($Text, '(?i)[''"](microsoft\.[a-z0-9]*[*?][a-z0-9./*?]*|microsoft\.[a-z0-9]+/[a-z0-9./]*[*?][a-z0-9./*?]*)[''"]'))
            {
                foreach ($T in $SkipList) { if ($T -like $M.Groups[1].Value) { $Hits.Add("$T (by wildcard literal '$($M.Groups[1].Value)')") } }
            }
            # A switch on the type, and a method call on it (.StartsWith and
            # the like), cannot be checked as a comparison.
            foreach ($M in [regex]::Matches($Text, '(?i)\bswitch\b(\s+-\w+)*\s*\([^)]*\btype\b[^)]*\)')) { $Unchecked.Add($M.Value) }
            foreach ($M in [regex]::Matches($Text, '(?i)\.type\.(?!ToLower(Invariant)?\(\)\s*-)[a-z]+\s*\(')) { $Unchecked.Add($M.Value) }
            # The type in brackets with a method call on it, and a -split of it.
            foreach ($M in [regex]::Matches($Text, '(?i)\.type\s*\)\s*\.\s*[a-z]+\s*\(')) { $Unchecked.Add($M.Value) }
            foreach ($M in [regex]::Matches($Text, '(?i)\btype\b(?:\.ToLower(?:Invariant)?\(\))?\s*-[ic]?split\b')) { $Unchecked.Add($M.Value) }
            foreach ($T in $SkipList) { if ($Literals.Contains($T)) { $Hits.Add($T) } }
            [pscustomobject]@{ Literals = $Literals; Hits = @($Hits); Unchecked = @($Unchecked) }
        }
    }

    It 'holds no type that any collector reads (a new collector must not be starved silently)' {
        $Files = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'Services'), (Join-Path $script:RepoRoot 'Extension') -Recurse -Filter '*.ps1')
        $Skip = @(Get-RdaNetworkSkipList)
        $AllLiterals = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Hits = [System.Collections.Generic.List[string]]::new()
        $Unchecked = [System.Collections.Generic.List[string]]::new()
        foreach ($File in $Files)
        {
            $Read = script:Get-CollectorTypeRead -Text (Get-Content -Path $File.FullName -Raw) -SkipList $Skip
            foreach ($L in $Read.Literals) { [void]$AllLiterals.Add($L) }
            foreach ($H in $Read.Hits) { $Hits.Add("$($File.Name): $H") }
            foreach ($U in $Read.Unchecked) { $Unchecked.Add("$($File.Name): $U") }
        }
        # Guard against a regex that silently matches nothing.
        $AllLiterals.Count | Should -BeGreaterThan 50
        $AllLiterals.Contains('microsoft.network/publicipaddresses') | Should -BeTrue

        @($Hits) | Should -BeNullOrEmpty -Because 'a collector reads these types, so they must not be skipped'
        @($Unchecked) | Should -BeNullOrEmpty -Because 'a type comparison against a variable or expression cannot be checked against the skip list'
    }

    It 'the collector check catches a skipped type read <Label>' -TestCases @(
        @{ Label = 'by a literal'; Text = '$Resources | Where-Object { $_.TYPE -eq ''microsoft.network/routetables'' }'; Expect = 'hit' }
        @{ Label = 'by a -like wildcard'; Text = '$Resources | Where-Object { $_.TYPE -like ''microsoft.network/*'' }'; Expect = 'hit' }
        @{ Label = 'by a -match pattern'; Text = '$Resources | Where-Object { $_.type -imatch ''^microsoft\.network/route'' }'; Expect = 'hit' }
        @{ Label = 'by a variable'; Text = '$T = ''microsoft.net'' + ''work/routetables''; $Resources | Where-Object { $_.TYPE -eq $T }'; Expect = 'unchecked' }
        @{ Label = 'in a -in list held in a variable'; Text = '$Resources | Where-Object { $_.type -in $NetTypes }'; Expect = 'unchecked' }
        @{ Label = 'by a switch -Wildcard on the type'; Text = 'switch -Wildcard ($_.type) { ''microsoft.network/*'' { $N++ } }'; Expect = 'hit' }
        @{ Label = 'by a switch -Regex on the type'; Text = 'switch -Regex ($_.TYPE) { ''^microsoft\.network/'' { $N++ } }'; Expect = 'unchecked' }
        @{ Label = 'by a .type method call'; Text = '$Resources | Where-Object { $_.type.StartsWith(''microsoft.network/route'') }'; Expect = 'unchecked' }
        @{ Label = 'by Where-Object -Property type'; Text = '$Resources | Where-Object -Property type -EQ ''microsoft.network/routetables'''; Expect = 'hit' }
        @{ Label = 'by a method call on the type in brackets'; Text = '$Resources | Where-Object { ($_.type).StartsWith(''microsoft.network/'') }'; Expect = 'unchecked' }
        @{ Label = 'by .ToLower() and -match'; Text = '$Resources | Where-Object { $_.type.ToLower() -match ''^microsoft\.network/route'' }'; Expect = 'hit' }
        @{ Label = 'by .ToLowerInvariant() and -in a variable'; Text = '$Resources | Where-Object { $_.type.ToLowerInvariant() -in $Net }'; Expect = 'unchecked' }
        @{ Label = 'by -split on the type'; Text = '$Resources | Where-Object { ($_.type -split ''/'')[1] -eq ''routetables'' }'; Expect = 'unchecked' }
        @{ Label = 'by the type in brackets and -match'; Text = '$Resources | Where-Object { ($_.type) -match ''^microsoft\.network/route'' }'; Expect = 'hit' }
        @{ Label = 'by the type in a string and -match'; Text = '$Resources | Where-Object { "$($_.type)" -match ''^microsoft\.network/route'' }'; Expect = 'hit' }
        # A negated comparison reads every type but the ones it names.
        @{ Label = 'by -ne a kept type'; Text = '$Resources | Where-Object { $_.type -ne ''microsoft.compute/virtualmachines'' }'; Expect = 'unchecked' }
        @{ Label = 'by -notlike a kept pattern'; Text = '$Resources | Where-Object { $_.TYPE -notlike ''microsoft.compute/*'' }'; Expect = 'unchecked' }
        @{ Label = 'by -notmatch a kept pattern'; Text = '$Resources | Where-Object { $_.type -notmatch ''^microsoft\.compute/'' }'; Expect = 'unchecked' }
        @{ Label = 'by -notin kept types'; Text = '$Resources | Where-Object { $_.type -notin ''microsoft.compute/virtualmachines'', ''microsoft.compute/disks'' }'; Expect = 'unchecked' }
        @{ Label = 'by -notcontains a kept type'; Text = '$Resources | Where-Object { $_.type -notcontains ''microsoft.compute/disks'' }'; Expect = 'unchecked' }
        # The type on the right of the comparison.
        @{ Label = 'by a list variable -contains the type'; Text = '$Resources | Where-Object { $NetworkTypes -contains $_.type }'; Expect = 'unchecked' }
        @{ Label = 'by a function''s list -contains the type'; Text = '$Resources | Where-Object { (Get-NetTypes) -contains $_.TYPE }'; Expect = 'unchecked' }
        @{ Label = 'by a list variable -notcontains the type'; Text = '$Resources | Where-Object { $Kept -notcontains $_.type }'; Expect = 'unchecked' }
        @{ Label = 'by a kept literal -ne the type'; Text = '$Resources | Where-Object { ''microsoft.compute/disks'' -ne $_.type }'; Expect = 'unchecked' }
        @{ Label = 'by a literal list -contains the type'; Text = '$Resources | Where-Object { @(''microsoft.compute/disks'', ''microsoft.network/routetables'') -contains $_.type }'; Expect = 'hit' }
        # Selection by id, an interpolated type and a joined type.
        @{ Label = 'by id with -like'; Text = '$Resources | Where-Object { $_.id -like ''*/providers/microsoft.network/networkinterfaces/*'' }'; Expect = 'hit' }
        @{ Label = 'by id with -match'; Text = '$Resources | Where-Object { $_.id -match ''/networkinterfaces/'' }'; Expect = 'hit' }
        @{ Label = 'by a skipped child type in an id'; Text = '$Resources | Where-Object { $_.ID -like ''*/networkwatchers/*/flowlogs/*'' }'; Expect = 'hit' }
        @{ Label = 'by an id in a double-quoted string'; Text = '$Nic = $Resources | Where-Object { $_.id -eq "$VmId/../networkinterfaces/$Name" }'; Expect = 'hit' }
        @{ Label = 'by an interpolated type'; Text = '$Resources | Where-Object { $_.type -eq "microsoft.network/$Kind" }'; Expect = 'unchecked' }
        @{ Label = 'by a joined type'; Text = '$Resources | Where-Object { $_.TYPE -eq ''microsoft.network/'' + ''routetables'' }'; Expect = 'unchecked' }
        # A quoted list on the right is read as literals.
        @{ Label = 'by -in a quoted list'; Text = '$Resources | Where-Object { $_.type -in @(''microsoft.compute/virtualmachines'', ''microsoft.network/routetables'') }'; Expect = 'hit' }
        @{ Label = 'by -in a list with a variable'; Text = '$Resources | Where-Object { $_.type -in @(''microsoft.compute/virtualmachines'', $Other) }'; Expect = 'unchecked' }
    ) {
        $Read = script:Get-CollectorTypeRead -Text $Text -SkipList @(Get-RdaNetworkSkipList)
        if ($Expect -eq 'hit') { @($Read.Hits) | Should -Not -BeNullOrEmpty }
        else { @($Read.Unchecked) | Should -Not -BeNullOrEmpty }
    }

    It 'the collector check passes a collector that reads only kept types <Label>' -TestCases @(
        @{ Label = 'by literals and a pattern'; Text = '$Resources | Where-Object { $_.TYPE -eq ''microsoft.network/publicipaddresses'' -or $_.TYPE -like ''microsoft.compute/*'' }' }
        @{ Label = 'by -in a quoted list'; Text = '$Resources | Where-Object { $_.type -in @(''microsoft.compute/virtualmachines'') }' }
        @{ Label = 'by -in a quoted list over lines'; Text = "`$Resources | Where-Object { `$_.type -in @(`n    'microsoft.compute/virtualmachines'`n    'microsoft.compute/disks'`n) }" }
        @{ Label = 'by a quoted list -contains the type'; Text = '$Resources | Where-Object { @(''microsoft.compute/virtualmachines'', ''microsoft.compute/disks'') -contains $_.type }' }
        @{ Label = 'by the id of a kept child of a skipped parent'; Text = '$Resources | Where-Object { $_.id -like ''*/networkwatchers/*/connectionmonitors/*'' }' }
        @{ Label = 'by the type of a kept child of a skipped parent'; Text = '$Resources | Where-Object { $_.TYPE -eq ''microsoft.network/networkwatchers/connectionmonitors'' }' }
    ) {
        $Read = script:Get-CollectorTypeRead -Text $Text -SkipList @(Get-RdaNetworkSkipList)
        @($Read.Hits) | Should -BeNullOrEmpty
        @($Read.Unchecked) | Should -BeNullOrEmpty
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
        @($Queries | Where-Object { $_ -match 'order by tolower\(id\) asc$' }).Count | Should -Be 1
        @($Global:Resources).Count | Should -Be 1
        $Global:SkippedResourceCount | Should -BeNullOrEmpty
        Should -Invoke -CommandName Write-Log -Times 1 -Exactly -ParameterFilter { $Severity -eq 'Warning' }
    }

    It 'reads a bad count answer (<Label>) as unknown: one warning, never a partial total' -TestCases @(
        @{ Label = 'a count that is not a number'; Rows = @(@{ type = 'microsoft.network/virtualnetworks'; count_ = 3 }, @{ type = 'microsoft.network/routetables'; count_ = 'abc' }) }
        @{ Label = 'a row with no type'; Rows = @(@{ type = 'microsoft.network/virtualnetworks'; count_ = 3 }, @{ count_ = 4 }) }
        @{ Label = 'a row with no count'; Rows = @(@{ type = 'microsoft.network/virtualnetworks'; count_ = 3 }, @{ type = 'microsoft.network/routetables' }) }
        @{ Label = 'a fraction'; Rows = @(@{ type = 'microsoft.network/virtualnetworks'; count_ = 2.5 }) }
        @{ Label = 'a negative count'; Rows = @(@{ type = 'microsoft.network/virtualnetworks'; count_ = 3 }, @{ type = 'microsoft.network/routetables'; count_ = -1 }) }
        @{ Label = 'a count too large for a whole number'; Rows = @(@{ type = 'microsoft.network/virtualnetworks'; count_ = '99999999999999999999' }) }
        @{ Label = 'a total too large for a whole number'; Rows = @(@{ type = 'microsoft.network/virtualnetworks'; count_ = [long]::MaxValue }, @{ type = 'microsoft.network/routetables'; count_ = 1 }) }
        @{ Label = 'an empty row'; Rows = @(@{ type = 'microsoft.network/virtualnetworks'; count_ = 3 }, $null) }
    ) {
        param($Label, $Rows)
        $script:BadRows = @($Rows | ForEach-Object { if ($null -eq $_) { $null } else { [pscustomobject]$_ } })
        Mock -CommandName Invoke-AzGraphQuerySafe -MockWith { [pscustomobject]@{ data = $script:BadRows } }
        Mock -CommandName Write-Log -MockWith { }
        # The inner script runs with this preference, which hides a failed cast.
        $Preference = $ErrorActionPreference
        try
        {
            $ErrorActionPreference = 'SilentlyContinue'
            $Result = Get-RdaSkippedNetworkCount -Where 'true' -SubscriptionId @($script:Sub)
        }
        finally { $ErrorActionPreference = $Preference }
        $Result | Should -BeNullOrEmpty -Because "$Label makes the count unknown"
        Should -Invoke -CommandName Write-Log -Times 1 -Exactly -ParameterFilter { $Severity -eq 'Warning' }
    }

    It 'reads no answer at all as unknown, not as 0 skipped' {
        Mock -CommandName Invoke-AzGraphQuerySafe -MockWith { $null }
        Mock -CommandName Write-Log -MockWith { }
        Get-RdaSkippedNetworkCount -Where 'true' -SubscriptionId @($script:Sub) | Should -BeNullOrEmpty
        Should -Invoke -CommandName Write-Log -Times 1 -Exactly -ParameterFilter { $Severity -eq 'Warning' }
    }

    It 'adds up good rows, a whole count given as text too' {
        $script:GoodRows = @([pscustomobject]@{ type = 'Microsoft.Network/VirtualNetworks'; count_ = 3 }, [pscustomobject]@{ type = 'microsoft.network/virtualnetworks'; count_ = '4' }, [pscustomobject]@{ type = 'microsoft.network/routetables'; count_ = 0 })
        Mock -CommandName Invoke-AzGraphQuerySafe -MockWith { [pscustomobject]@{ data = $script:GoodRows } }
        Mock -CommandName Write-Log -MockWith { }
        $Result = Get-RdaSkippedNetworkCount -Where 'true' -SubscriptionId @($script:Sub)
        $Result.Total | Should -Be 7
        $Result.ByType['microsoft.network/virtualnetworks'] | Should -Be 7
        $Result.ByType['microsoft.network/routetables'] | Should -Be 0
        Should -Invoke -CommandName Write-Log -Times 0 -Exactly
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

    It 'collected 0 and skipped > 0 with -SkipConsumption: does not say the costs come from consumption data' {
        $ByType = [ordered]@{ 'microsoft.network/virtualnetworks' = 12; 'microsoft.network/networksecuritygroups' = 20; 'microsoft.network/routetables' = 8 }
        $M = Get-RdaResourceCountMessage -Collected 0 -Skipped 40 -SkippedByType $ByType -SkipConsumption
        $M.Kind | Should -Be 'NetworkOnly'
        $M.Text | Should -Be '0 resources collected. 40 network resources skipped (20 networksecuritygroups, 12 virtualnetworks, 8 routetables).'
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
        $script:WrapperAst = [System.Management.Automation.Language.Parser]::ParseInput($script:Wrapper, [ref]$null, [ref]$null)
        $script:StreamAst = [System.Management.Automation.Language.Parser]::ParseInput($script:Stream, [ref]$null, [ref]$null)

        # Each per-subscription count line of a script, lifted so the real
        # code runs: the '$CountMessage = Get-RdaResourceCountMessage ...'
        # statement and the if after it that writes the line.
        function script:Get-CountLineBlock
        {
            param($Ast)
            $Assigns = @($Ast.FindAll({
                        param($Node)
                        $Node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $Node.Left.Extent.Text -eq '$CountMessage' -and $Node.Right.Extent.Text -match '^Get-RdaResourceCountMessage\b'
                    }, $true))
            foreach ($A in $Assigns)
            {
                $Statements = @($A.Parent.Statements)
                $At = [array]::IndexOf($Statements, $A)
                [scriptblock]::Create($A.Extent.Text + "`n" + $Statements[$At + 1].Extent.Text)
            }
        }

        # The wrapper's run-summary statements, from '$EmptySubs = ...' to the
        # if that writes the totals, lifted so the real code runs.
        $Empty = $script:WrapperAst.Find({
                param($Node)
                $Node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $Node.Left.Extent.Text -eq '$EmptySubs'
            }, $true)
        if ($null -eq $Empty) { throw 'The $EmptySubs statement was not found in Run-AllSubscriptions.ps1.' }
        $Statements = @($Empty.Parent.Statements)
        $From = [array]::IndexOf($Statements, $Empty)
        $To = -1
        for ($i = $From; $i -lt $Statements.Count; $i++)
        {
            if ($Statements[$i] -is [System.Management.Automation.Language.IfStatementAst] -and $Statements[$i].Clauses[0].Item1.Extent.Text -eq '$SubResourceCounts.Count -gt 0') { $To = $i; break }
        }
        if ($To -lt 0) { throw 'The run-summary totals were not found in Run-AllSubscriptions.ps1.' }
        $script:RunSummary = [scriptblock]::Create((@($Statements[$From..$To] | ForEach-Object { $_.Extent.Text }) -join "`n"))
    }

    It 'every per-subscription count line (2 in the wrapper, 1 in the stream worker) shows <Label>' -TestCases @(
        @{ Label = 'a network-only subscription as not empty'; Collected = 0; Skipped = 5; Expect = '*0 resources collected. 5 network resources skipped (5 networkinterfaces).*'; Warn = $false }
        @{ Label = 'an empty subscription as a warning'; Collected = 0; Skipped = 0; Expect = '*WARNING*'; Warn = $true }
        @{ Label = 'an unknown skipped count with 0 rows as a warning'; Collected = 0; Skipped = $null; Expect = '*WARNING*'; Warn = $true }
        @{ Label = 'the skipped count next to the collected one'; Collected = 3; Skipped = 2; Expect = '*Resources collected: 3 (2 network resources skipped)'; Warn = $false }
    ) {
        param($Label, $Collected, $Skipped, $Expect, $Warn)
        $Blocks = @{ Wrapper = @(script:Get-CountLineBlock $script:WrapperAst); Stream = @(script:Get-CountLineBlock $script:StreamAst) }
        $Blocks.Wrapper.Count | Should -Be 2 -Because 'the sequential and the one-subscription branch each write the line'
        $Blocks.Stream.Count | Should -Be 1
        $script:Out = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Host -MockWith { $script:Out.Add([string]$Object) }
        function Write-Stream { param($Message, $Color) $script:Out.Add([string]$Message) }
        # The lifted line reads these through dynamic scope.
        Set-Variable -Name ResCount -Value $Collected
        $Sub = [pscustomobject]@{ Name = 'sub-a'; Id = $script:Sub }
        Set-Variable -Name SubName -Value 'sub-a'
        $Global:SkippedResourceCount = $Skipped
        $Global:SkippedResourceTypes = if ($Skipped -gt 0 -and $Collected -eq 0) { [ordered]@{ 'microsoft.network/networkinterfaces' = $Skipped } } else { [ordered]@{} }
        foreach ($Block in @($Blocks.Wrapper + $Blocks.Stream))
        {
            $script:Out.Clear()
            . $Block
            $script:Out.Count | Should -Be 1 -Because "one line from: $Block"
            $script:Out[0] | Should -BeLike $Expect
            if (-not $Warn) { $script:Out[0] | Should -Not -BeLike '*WARNING*' }
        }
    }

    It 'every count line (wrapper, stream worker, direct run) names the consumption data only when it is collected (-SkipConsumption <Skip>)' -TestCases @(
        @{ Skip = $false }, @{ Skip = $true }
    ) {
        param($Skip)
        $Blocks = @(@(script:Get-CountLineBlock $script:WrapperAst) + @(script:Get-CountLineBlock $script:StreamAst) + @(script:Get-CountLineBlock $script:InventoryAst))
        $Blocks.Count | Should -Be 4
        $script:Out = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Host -MockWith { $script:Out.Add([string]$Object) }
        Mock -CommandName Write-Log -MockWith { $script:Out.Add([string]$Message) }
        function Write-Stream { param($Message, $Color) $script:Out.Add([string]$Message) }
        # The lifted lines read these through dynamic scope.
        Set-Variable -Name SkipConsumption -Value ([switch]$Skip)
        Set-Variable -Name ResCount -Value 0
        Set-Variable -Name SubName -Value 'sub-a'
        $Sub = [pscustomobject]@{ Name = 'sub-a'; Id = $script:Sub }
        $Global:Resources = @()
        $Global:SkippedResourceCount = 5
        $Global:SkippedResourceTypes = [ordered]@{ 'microsoft.network/networkinterfaces' = 5 }
        foreach ($Block in $Blocks)
        {
            $script:Out.Clear()
            . $Block
            $script:Out.Count | Should -Be 1 -Because "one line from: $Block"
            $script:Out[0] | Should -BeLike '*0 resources collected. 5 network resources skipped (5 networkinterfaces).*'
            if ($Skip) { $script:Out[0] | Should -Not -Match '(?i)consumption' -Because '-SkipConsumption collects no consumption data' }
            else { $script:Out[0] | Should -BeLike '*Network costs still come from the consumption data.' }
        }
    }

    It 'the run summary names the consumption data only when it is collected (-SkipConsumption <Skip>)' -TestCases @(
        @{ Skip = $false }, @{ Skip = $true }
    ) {
        param($Skip)
        $script:Out = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Host -MockWith { $script:Out.Add([string]$Object) }
        # The lifted summary reads these through dynamic scope.
        Set-Variable -Name SkipConsumption -Value ([switch]$Skip)
        Set-Variable -Name SubResourceCounts -Value @([pscustomobject]@{ Name = 'collected'; Id = 'id-a'; Count = 5; Skipped = 3 })
        . $script:RunSummary
        $Line = @($script:Out | Where-Object { $_ -like 'Network resources skipped:*' })
        $Line.Count | Should -Be 1
        $Line[0] | Should -BeLike '*-IncludeNetworkResources keeps them)'
        if ($Skip) { $Line[0] | Should -Be 'Network resources skipped: 3 (-IncludeNetworkResources keeps them)' }
        else { $Line[0] | Should -Be 'Network resources skipped: 3 (network costs still come from the consumption data; -IncludeNetworkResources keeps them)' }
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

    It 'the README''s wrapper summary names every switch the wrapper forwards' {
        $Readme = Get-Content -Path (Join-Path $script:RepoRoot 'README.md') -Raw
        $Summary = [regex]::Match($Readme, '(?s)The wrapper forwards (.*?) to the inner')
        $Summary.Success | Should -BeTrue -Because 'the README has a wrapper-forwarding summary'
        # The wrapper's own switches; -Debug is a common parameter with its
        # own README section.
        $Forwarded = @([regex]::Matches($script:Wrapper, "InventoryPassthrough\['(\w+)'\]") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notin @('Debug', 'Verbose') } | Select-Object -Unique)
        $Forwarded | Should -Contain 'IncludeNetworkResources'
        foreach ($Name in $Forwarded) { $Summary.Groups[1].Value | Should -Match ([regex]::Escape("``-$Name``")) -Because "the wrapper forwards -$Name" }
    }

    It 'the run summary lists a network-only subscription apart from the empty ones' {
        $script:Out = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Host -MockWith { $script:Out.Add([string]$Object) }
        # Collected, empty, network-only, and an older stream summary's row
        # with no Skipped (read as 0 by the wrapper).
        # The lifted summary reads this through dynamic scope.
        Set-Variable -Name SubResourceCounts -Value @(
            [pscustomobject]@{ Name = 'collected'; Id = 'id-a'; Count = 5; Skipped = 0 }
            [pscustomobject]@{ Name = 'empty'; Id = 'id-b'; Count = 0; Skipped = 0 }
            [pscustomobject]@{ Name = 'network-only'; Id = 'id-c'; Count = 0; Skipped = 7 }
            [pscustomobject]@{ Name = 'older-empty'; Id = 'id-d'; Count = 0; Skipped = [long]0 }
        )
        . $script:RunSummary
        @($EmptySubs.Name) | Should -Be @('empty', 'older-empty')
        @($NetworkOnlySubs.Name) | Should -Be @('network-only')
        @($NonEmptySubs.Name) | Should -Be @('collected')
        $script:Out | Should -Contain 'Total Resources:         5 across 1 subscription(s)'
        @($script:Out | Where-Object { $_ -like 'Network resources skipped: 7 (*' }).Count | Should -Be 1
        $script:Out | Should -Contain 'Subscriptions with only skipped network resources: 1'
        $script:Out | Should -Contain '    - network-only (id-c) - 7 network resources skipped'
    }

    It 'the run summary writes no skipped lines when nothing was skipped' {
        $script:Out = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Write-Host -MockWith { $script:Out.Add([string]$Object) }
        Set-Variable -Name SubResourceCounts -Value @([pscustomobject]@{ Name = 'collected'; Id = 'id-a'; Count = 5; Skipped = 0 }, [pscustomobject]@{ Name = 'empty'; Id = 'id-b'; Count = 0; Skipped = 0 })
        . $script:RunSummary
        @($NetworkOnlySubs) | Should -BeNullOrEmpty
        @($EmptySubs.Name) | Should -Be @('empty')
        @($script:Out | Where-Object { $_ -match '(?i)skipped' }) | Should -BeNullOrEmpty
    }
}

Describe 'Under -Obfuscate the skipped rows keep their masked ids (id-only query)' {

    BeforeAll {
        # The function that sets up the dictionaries, and the statements of
        # RunInventorySetup after discovery (count line, token loop), lifted
        # from ResourceInventory.ps1 so the real code is what runs.
        foreach ($Name in @('Variables'))
        {
            $Fn = $script:InventoryAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name }, $true) | Select-Object -First 1
            if ($null -eq $Fn) { throw "$Name was not found in ResourceInventory.ps1." }
            . ([scriptblock]::Create($Fn.Extent.Text))
        }
        function GetLocalVersion { '0.0.0-test' }
        $Setup = $script:InventoryAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'RunInventorySetup' }, $true) | Select-Object -First 1
        $Statements = @($Setup.Body.EndBlock.Statements)
        $AvdAt = -1
        for ($i = 0; $i -lt $Statements.Count; $i++) { if ($Statements[$i].Extent.Text -eq 'ResourceInventoryAvd') { $AvdAt = $i } }
        if ($AvdAt -lt 0) { throw 'The ResourceInventoryAvd call was not found in RunInventorySetup.' }
        $script:AfterDiscovery = [scriptblock]::Create((@($Statements[($AvdAt + 1)..($Statements.Count - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n"))
        $script:LoopText = $LoopFn.Extent.Text

        $script:SubA = '11111111-1111-1111-1111-111111111111'
        $script:SubB = '22222222-2222-2222-2222-222222222222'
        $script:NetTypes = @(Get-RdaNetworkSkipList)
        function script:New-Row
        {
            param([string]$Sub, [string]$Rg, [string]$Type, [string]$Name, [string]$Child)
            $Id = '/subscriptions/{0}/resourcegroups/{1}/providers/{2}/{3}' -f $Sub, $Rg, $Type, $Name
            if ($Child) { $Id += $Child; $Name = ($Child -split '/')[-1]; $Type = $Type + '/' + ($Child -split '/')[1] }
            [pscustomobject]@{ id = $Id; name = $Name; type = $Type; resourceGroup = $Rg; subscriptionId = $Sub; location = 'westeurope'; properties = [pscustomobject]@{ big = 'x' * 50 }; tags = [pscustomobject]@{ owner = 'team' } }
        }
        # Kept rows, skipped rows, a kept child of a skipped parent, a resource
        # group that holds only skipped types, a dev-named skipped row in a
        # prod group, and a second subscription.
        $script:AllRows = @(
            script:New-Row -Sub $script:SubA -Rg 'prod-app' -Type 'microsoft.compute/virtualmachines' -Name 'vm1'
            script:New-Row -Sub $script:SubA -Rg 'prod-app' -Type 'microsoft.network/networkinterfaces' -Name 'vm1-nic'
            script:New-Row -Sub $script:SubA -Rg 'prod-app' -Type 'microsoft.network/privateendpoints' -Name 'dev-pe1'
            script:New-Row -Sub $script:SubA -Rg 'prod-app' -Type 'microsoft.network/virtualnetworks' -Name 'corevnet'
            script:New-Row -Sub $script:SubA -Rg 'prod-net' -Type 'microsoft.network/networksecuritygroups' -Name 'nsg1'
            script:New-Row -Sub $script:SubA -Rg 'prod-net' -Type 'microsoft.network/routetables' -Name 'rt1'
            script:New-Row -Sub $script:SubA -Rg 'networkwatcherrg' -Type 'microsoft.network/networkwatchers' -Name 'nw-westeurope'
            script:New-Row -Sub $script:SubA -Rg 'networkwatcherrg' -Type 'microsoft.network/networkwatchers' -Name 'nw-westeurope' -Child '/connectionmonitors/cm1'
            script:New-Row -Sub $script:SubA -Rg 'prod-app' -Type 'microsoft.network/publicipaddresses' -Name 'pip1'
            script:New-Row -Sub $script:SubB -Rg 'test-data' -Type 'microsoft.storage/storageaccounts' -Name 'st1'
            script:New-Row -Sub $script:SubB -Rg 'test-data' -Type 'microsoft.network/privatednszones' -Name 'privatelink.blob.core.windows.net'
            script:New-Row -Sub $script:SubB -Rg 'test-data' -Type 'microsoft.network/privatednszones' -Name 'privatelink.blob.core.windows.net' -Child '/virtualnetworklinks/link1'
        ) | Sort-Object { $_.id.ToLowerInvariant() }

        # Runs discovery and the token loop once. Resource Graph is a stand-in
        # that answers from AllRows by the query's type filter.
        function script:Invoke-Discovery
        {
            # The lifted Variables, ResourceInventoryLoop and RunInventorySetup
            # code reads these through dynamic scope, which the analyzer cannot
            # follow.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ReportName', Justification = 'Read by the lifted Variables through dynamic scope.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'IncludeNetworkResources', Justification = 'Read by the lifted ResourceInventoryLoop through dynamic scope.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'RunAllSubs', Justification = 'Read by the lifted ResourceInventoryLoop through dynamic scope.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ResourceGroup', Justification = 'Read by the lifted ResourceInventoryLoop through dynamic scope.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ObfuscationDictionary', Justification = 'Read by the lifted RunInventorySetup statements through dynamic scope.')]
            param([switch]$Obfuscate, [switch]$Include, [string]$FailToken = '')
            $script:Sent = [System.Collections.Generic.List[object]]::new()
            $script:FailTokenMode = $FailToken
            Mock -CommandName Invoke-AzGraphQuerySafe -MockWith {
                $script:Sent.Add([pscustomobject]@{ Query = $Query; Lowercase = [bool]$Lowercase; HideRawOutput = [bool]$HideRawOutput; SubscriptionId = @($SubscriptionId) })
                $IsNet = { param($R) $script:NetTypes -contains $R.type }
                $Rows = if ($Query -match ' \| where type !in~ \(') { @($script:AllRows | Where-Object { -not (& $IsNet $_) }) }
                elseif ($Query -match ' \| where type in~ \(') { @($script:AllRows | Where-Object { & $IsNet $_ }) }
                else { @($script:AllRows) }
                $Rows = @($Rows | Where-Object { @($SubscriptionId) -contains $_.subscriptionId })
                if ($Query -match 'summarize count\(\) by type$')
                {
                    return [pscustomobject]@{ data = @($Rows | Group-Object type | ForEach-Object { [pscustomobject]@{ type = $_.Group[0].type; count_ = $_.Count } }) }
                }
                if ($Query -match 'summarize count\(\)$') { return [pscustomobject]@{ data = @([pscustomobject]@{ count_ = $Rows.Count }) } }
                if ($Query -match '\| project id,name,resourceGroup,subscriptionId \|')
                {
                    if ($script:FailTokenMode -eq 'throw') { throw "Resource Graph query failed: status 429 after 5 tries`nQuery: $Query" }
                    if ($script:FailTokenMode -eq 'null') { return $null }
                    return [pscustomobject]@{ data = @($Rows | Select-Object id, name, resourceGroup, subscriptionId) }
                }
                return [pscustomobject]@{ data = @($Rows | ForEach-Object { $_.PSObject.Copy() }) }
            }
            Mock -CommandName Write-Log -MockWith { }

            $ReportName = 'ResourcesReport'
            $IncludeNetworkResources = [switch]$Include.IsPresent
            $RunAllSubs = [switch]$true
            $SubscriptionID = ''
            $ResourceGroup = ''
            $ObfuscationDictionary = ''
            Variables
            $Global:Subscriptions = @([pscustomobject]@{ id = $script:SubA; name = 'Contoso Prod' }, [pscustomobject]@{ id = $script:SubB; name = 'Contoso Test' })
            ResourceInventoryLoop
            . $script:AfterDiscovery
            return [pscustomobject]@{
                Resources = @($Global:Resources); Count = @($Global:Resources).Count; Sent = @($script:Sent)
                Ids = $Global:ResourceIdDictionary; Names = $Global:ResourceNameDictionary; Subs = $Global:ResourceSubscriptionDictionary; Rgs = $Global:ResourceResourceGroupDictionary
                TokenRowsLeft = $script:NetworkTokenRows
            }
        }

        # A token without its random GUID: prefix and type hint only.
        function script:Get-TokenShape { param([string]$Token) $Token -replace '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<g>' }
        # Each masked id with every token named by the real segment it stands
        # for (prefix kept), so two runs compare equal when their tokens differ
        # only in the random GUIDs. Also checks one token per real segment.
        function script:Get-CanonicalIdMap
        {
            param($Ids)
            $Seen = @{}
            $Out = [ordered]@{}
            foreach ($Real in @($Ids.Keys | Sort-Object))
            {
                $R = $Real.Split('/'); $M = ([string]$Ids[$Real]).Split('/')
                $M.Count | Should -Be $R.Count -Because "the masked id of $Real keeps its ARM path"
                $Parts = for ($i = 0; $i -lt $R.Count; $i++)
                {
                    if ($R[$i] -ceq $M[$i]) { $R[$i]; continue }
                    $Key = '{0}|{1}' -f $i, ($R[0..$i] -join '/')
                    if ($i -eq 2) { $Key = 'sub|' + $R[2] } elseif ($i -eq 4) { $Key = 'rg|' + $R[4] }
                    if ($Seen.ContainsKey($Key)) { $Seen[$Key] | Should -Be $M[$i] -Because "one token for $Key" } else { $Seen[$Key] = $M[$i] }
                    '{0}[{1}]' -f (script:Get-TokenShape $M[$i]), $R[$i]
                }
                $Out[$Real] = $Parts -join '/'
            }
            return $Out
        }
        function script:Get-CanonicalValueMap { param($Dict) $O = [ordered]@{}; foreach ($K in @($Dict.Keys | Sort-Object)) { $O[$K] = script:Get-TokenShape $Dict[$K] }; $O }
        # A failed id query says what is lost (the skipped rows' masked ids
        # and dictionary entries, not inventory rows) and the ways round it.
        function script:Test-TokenFailureText
        {
            param([string]$Text)
            $Text | Should -Not -BeNullOrEmpty
            $Text | Should -Match 'masked ids'
            $Text | Should -Match 'dictionary entries'
            $Text | Should -Match 'inventory rows themselves are complete'
            $Text | Should -Not -Match 'inventory would be incomplete'
            $Text | Should -Match '-IncludeNetworkResources'
            $Text | Should -Match 'without -Obfuscate'
        }
    }

    AfterAll {
        Remove-Variable -Scope Global -Name ResourceIdDictionary, ResourceNameDictionary, ResourceSubscriptionDictionary, ResourceResourceGroupDictionary, TagValueDictionary, FreeTextDictionary, ResourceContainers, ReportName, Version, RawRepo, TableStyle -ErrorAction SilentlyContinue
    }

    It 'gives every id, name, subscription and resource group entry the run without the skip gave, with the same token shapes' {
        $Before = script:Invoke-Discovery -Obfuscate -Include
        $After = script:Invoke-Discovery -Obfuscate
        $BeforeIds = script:Get-CanonicalIdMap $Before.Ids
        $AfterIds = script:Get-CanonicalIdMap $After.Ids
        @($AfterIds.Keys) | Should -Be @($BeforeIds.Keys)
        foreach ($K in $BeforeIds.Keys) { $AfterIds[$K] | Should -Be $BeforeIds[$K] }
        foreach ($Pair in @(@('Names', 'name'), @('Subs', 'subscription'), @('Rgs', 'resource group')))
        {
            $B = script:Get-CanonicalValueMap $Before.($Pair[0]); $A = script:Get-CanonicalValueMap $After.($Pair[0])
            @($A.Keys) | Should -Be @($B.Keys) -Because "every $($Pair[1]) entry is kept"
            foreach ($K in $B.Keys) { $A[$K] | Should -Be $B[$K] }
        }
        # The kept child of a skipped parent keeps its masked id, and its
        # parent's id stays in the dictionary.
        @($After.Ids.Keys | Where-Object { $_ -like '*/connectionmonitors/cm1' }).Count | Should -Be 1
        @($After.Ids.Keys | Where-Object { $_ -like '*/networkwatchers/nw-westeurope' }).Count | Should -Be 1
    }

    It 'leaves the skipped rows out of the pull, the count and everything the collectors read' {
        $After = script:Invoke-Discovery -Obfuscate
        @($After.Resources | Where-Object { $script:NetTypes -contains $_.type }) | Should -BeNullOrEmpty
        $After.Count | Should -Be @($After.Resources).Count
        # vm1, pip1, the connection monitor and the storage account.
        $After.Count | Should -Be 4
        $After.TokenRowsLeft | Should -BeNullOrEmpty -Because 'the id rows are dropped after the token loop'
        # Only the token loop reads the id rows.
        $script:InventoryAst.Extent.Text | Should -Not -Match '\$Global:Resources\s*\+=\s*\$script:NetworkTokenRows'
        $script:InventoryAst.Extent.Text | Should -Not -Match '\$Global:Resources\s*\+=\s*\$TokenResult'
    }

    It 'asks for the id and only the fields the token loop reads, with the pull''s scope, paging order and lower case' {
        $After = script:Invoke-Discovery -Obfuscate
        $Token = @($After.Sent | Where-Object { $_.Query -match '\| project id,name,resourceGroup,subscriptionId \|' })
        $Token.Count | Should -Be 1
        $Page = @($After.Sent | Where-Object { $_.Query -match '\| project id,name,type,' })[0]
        $Token[0].Query | Should -Match '\| order by tolower\(id\) asc$'
        $Token[0].Query | Should -Not -Match 'properties \|'
        $Token[0].Lowercase | Should -BeTrue
        $Token[0].HideRawOutput | Should -BeTrue
        @($Token[0].SubscriptionId) | Should -Be @($Page.SubscriptionId)
        # Same where as the pull, the opposite type filter.
        ($Token[0].Query -replace ' \| where type in~ .*$', '') | Should -Be ($Page.Query -replace ' \| where type !in~ .*$', '')
        @(Get-RdaNetworkTokenField) | Should -Be @('id', 'name', 'resourceGroup', 'subscriptionId')
    }

    It 'is not sent without -Obfuscate' {
        $Plain = script:Invoke-Discovery
        @($Plain.Sent | Where-Object { $_.Query -match 'project id,name,resourceGroup,subscriptionId' }) | Should -BeNullOrEmpty
    }

    It 'is not sent with -IncludeNetworkResources, which brings the full pull back' {
        $Full = script:Invoke-Discovery -Obfuscate -Include
        @($Full.Sent | Where-Object { $_.Query -match 'project id,name,resourceGroup,subscriptionId' }) | Should -BeNullOrEmpty
        @($Full.Sent | Where-Object { $_.Query -match 'in~' }) | Should -BeNullOrEmpty
        $Full.Count | Should -Be $script:AllRows.Count
    }

    It 'under -Obfuscate counts the skipped rows from the id rows with no count query, and gets what the count query gets' {
        $null = script:Invoke-Discovery
        $QueryTotal = $Global:SkippedResourceCount
        $QueryTypes = [ordered]@{}; foreach ($K in @($Global:SkippedResourceTypes.Keys | Sort-Object)) { $QueryTypes[$K] = [long]$Global:SkippedResourceTypes[$K] }
        $Obf = script:Invoke-Discovery -Obfuscate
        @($Obf.Sent | Where-Object { $_.Query -match 'summarize count\(\) by type$' }) | Should -BeNullOrEmpty -Because 'the id rows already hold every skipped row'
        $QueryTotal | Should -BeGreaterThan 0
        $Global:SkippedResourceCount | Should -Be $QueryTotal
        $ObfTypes = [ordered]@{}; foreach ($K in @($Global:SkippedResourceTypes.Keys | Sort-Object)) { $ObfTypes[$K] = [long]$Global:SkippedResourceTypes[$K] }
        @($ObfTypes.Keys) | Should -Be @($QueryTypes.Keys)
        foreach ($K in $QueryTypes.Keys) { $ObfTypes[$K] | Should -Be $QueryTypes[$K] -Because $K }
    }

    It 'reads the resource type from an ARM id, child types included' {
        Get-RdaResourceTypeFromId -Id '/subscriptions/s/resourceGroups/r/providers/Microsoft.Network/privateDnsZones/z.example/virtualNetworkLinks/l1' | Should -Be 'microsoft.network/privatednszones/virtualnetworklinks'
        Get-RdaResourceTypeFromId -Id '/subscriptions/s/resourcegroups/r/providers/microsoft.network/networkinterfaces/nic1' | Should -Be 'microsoft.network/networkinterfaces'
        Get-RdaResourceTypeFromId -Id '/subscriptions/s/resourcegroups/r' | Should -BeNullOrEmpty
        Get-RdaResourceTypeFromId -Id '' | Should -BeNullOrEmpty
    }

    It 'a failed id query (<Mode>) stops the subscription under -RunAllSubs; it is never read as 0 rows' -TestCases @(@{ Mode = 'throw' }, @{ Mode = 'null' }) {
        { script:Invoke-Discovery -Obfuscate -FailToken $Mode } | Should -Throw
        $Global:ResourceIdDictionary.Count | Should -Be 0 -Because 'the token loop did not run'
        $Reason = $null
        try { script:Invoke-Discovery -Obfuscate -FailToken $Mode } catch { $Reason = $_.Exception.Message }
        script:Test-TokenFailureText -Text $Reason
    }

    It 'a failed id query (<Mode>) ends a direct run with exit 1 before the token loop' -TestCases @(@{ Mode = 'throw' }, @{ Mode = 'null' }) {
        $Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-netskip-exit-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        try
        {
            $Answer = if ($Mode -eq 'throw') { 'throw "Resource Graph query failed: status 429 after 5 tries"' } else { 'return $null' }
            $Probe = @(
                '$ErrorActionPreference = ''SilentlyContinue'''
                ('. ''{0}''' -f (Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1'))
                'function Write-Log { param($Message, $Severity) if ($Severity -eq ''Error'') { Write-Output (''LOGGED-ERROR '' + $Message) } }'
                ('function Invoke-AzGraphQuerySafe {{ param($Query, $SubscriptionId, [switch]$Lowercase, [switch]$HideRawOutput) if ($Query -match ''project id,name,resourceGroup,subscriptionId'') {{ {0} }}; if ($Query -match ''summarize count'') {{ return [pscustomobject]@{{ data = @([pscustomobject]@{{ count_ = 1 }}) }} }}; return [pscustomobject]@{{ data = @() }} }}' -f $Answer)
                $script:LoopText
                '$Obfuscate = [switch]$true; $IncludeNetworkResources = [switch]$false; $RunAllSubs = [switch]$false; $SubscriptionID = ''11111111-1111-1111-1111-111111111111''; $ResourceGroup = '''''
                '$Global:Resources = @(); $Global:Subscriptions = @([pscustomobject]@{ id = $SubscriptionID; name = ''s'' })'
                'ResourceInventoryLoop'
                'Write-Output ''REACHED-TOKEN-LOOP'''
            ) -join "`n"
            $File = Join-Path $Dir 'probe.ps1'
            Set-Content -LiteralPath $File -Value $Probe -Encoding utf8
            $Pwsh = (Get-Process -Id $PID).Path
            $Out = @(& $Pwsh -NoProfile -NonInteractive -File $File 2>&1 | ForEach-Object { [string]$_ })
            $LASTEXITCODE | Should -Be 1
            $Out | Should -Not -Contain 'REACHED-TOKEN-LOOP'
            @($Out | Where-Object { $_ -like 'LOGGED-ERROR Resource discovery failed*' }).Count | Should -Be 1
            script:Test-TokenFailureText -Text (@($Out | Where-Object { $_ -like 'LOGGED-ERROR Resource discovery failed*' })[0])
        }
        finally { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'its time goes into the phase timings of the diagnostics log, and only when it ran' {
        # The statements of ExecuteInventoryProcessing that start the phase
        # timings, lifted so the real code runs.
        $Exec = $script:InventoryAst.Find({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'ExecuteInventoryProcessing' }, $true)
        $Statements = @($Exec.Body.EndBlock.Statements)
        $Start = @($Statements | Where-Object { $_.Extent.Text -match '^\$script:PhaseTimings\s*=' })
        $Start.Count | Should -Be 1
        $At = [array]::IndexOf($Statements, $Start[0])
        $Timing = [scriptblock]::Create($Statements[$At].Extent.Text + "`n" + $Statements[$At + 1].Extent.Text)

        $script:NetworkTokenQueryTime = [TimeSpan]::FromMilliseconds(1500)
        . $Timing
        $script:PhaseTimings['Network id query for masked ids (-Obfuscate)'] | Should -Be ([TimeSpan]::FromMilliseconds(1500))

        $script:NetworkTokenQueryTime = $null
        . $Timing
        $script:PhaseTimings.Contains('Network id query for masked ids (-Obfuscate)') | Should -BeFalse
    }

    It 'Variables clears the last run''s skipped count' {
        $ReportName = 'ResourcesReport'
        $Global:SkippedResourceCount = 99
        $Global:SkippedResourceTypes = [ordered]@{ 'microsoft.network/virtualnetworks' = 99 }
        Variables
        $Global:SkippedResourceCount | Should -Be 0
        $Global:SkippedResourceTypes.Count | Should -Be 0
        $Global:ReportName | Should -Be $ReportName
    }
}
