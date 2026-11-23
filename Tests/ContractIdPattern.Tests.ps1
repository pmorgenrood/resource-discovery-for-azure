# =============================================================================
# ContractIdPattern.Tests.ps1
#
# Offline tests of Get-RdaContractIdPattern (Tests/Helpers/SyntheticReportZip.ps1),
# the masked id shape the zip-backed tests check inventory ids, cross-
# references, metric ids and ResourceIdMap keys against. The contract shape
# is the only one taken by default; the parked G2 shape and the metric
# fallback's sub_/rg_ tokens (F2) only when a test names them. The G1 shape (a
# Service Bus '$system' name kept as written) is masked now and never taken,
# and an id that ends on the type word '$system' with no name after it is an
# id form this tool does not support, which no switch takes.
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
        G1Nested     = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.servicebus/namespaces/prod_$G/topics/`$system"
        G2NoRg       = "/subscriptions/prod_$G/providers/microsoft.insights/pricings/prod_$G"
        F2Fallback   = "/subscriptions/prod_sub_$G/resourcegroups/prod_rg_$G/providers/microsoft.compute/virtualmachines/prod_$G"
        SystemOther  = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.storage/storageaccounts/`$system"
        SubTokenOnly = "/subscriptions/prod_sub_$G/resourcegroups/prod_$G/providers/microsoft.compute/virtualmachines/prod_$G"
        Flat         = "prod_$G"
        TokenHint    = "nonprod_vmss_$G"
        RealName     = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.compute/virtualmachines/vm-web-01"
        NoProvider   = "/subscriptions/prod_$G/resourcegroups/prod_$G"
        SubOnly      = "/subscriptions/prod_$G"
        Extension    = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.compute/virtualmachines/prod_$G/providers/microsoft.insights/diagnosticsettings/prod_$G"
        FlatSentinel = "obfuscated_$G"
        # A run keeps a last type word with no name after it as written, so it
        # would write this one for a billed '.../namespaces/<namespace>/$system'.
        # No captured billing row shows that form, and downstream reads the last
        # segment as the name: it is an id form this tool does not support (the
        # offline mask refuses it), and no pattern takes it.
        TypeSystem   = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.servicebus/namespaces/prod_$G/`$system"
        TypeOther    = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.servicebus/namespaces/prod_$G/topics"
        TypeSystemX  = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.servicebus/namespaces/prod_$G/`$systemx"
        TypeSystemOn = "/subscriptions/prod_$G/resourcegroups/prod_$G/providers/microsoft.servicebus/namespaces/prod_$G/`$system/topics"
        SystemNoName = "/subscriptions/prod_$G/resourcegroups/prod_$G/`$system"
    }
}

Describe 'An id that ends on the type word $system after a name token, in both id patterns' {

    It 'refuses TypeSystem by default in both patterns, with the other named shapes allowed too: the contract''s id ends in a name token' {
        $script:Ids.TypeSystem | Should -Not -Match (Get-RdaContractIdPattern)
        $script:Ids.TypeSystem | Should -Not -Match (Get-RdaContractIdPattern -AllowParked -AllowMetricFallback)
        $script:Ids.TypeSystem | Should -Not -Match (Get-RdaMaskedIdPattern)
    }

    It 'has no switch that takes an id ending on the type word $system: <_>' -ForEach @('Get-RdaContractIdPattern', 'Get-RdaMaskedIdPattern') {
        @((Get-Command $_).Parameters.Keys) | Should -Not -Contain 'AllowTrailingSystemType' -Because 'that id form is not supported, so no test may let it in'
    }

    It 'still refuses <_> in both patterns, with the other named shapes allowed too: no id may end on a type word' -ForEach @('TypeSystem', 'TypeOther', 'TypeSystemX', 'TypeSystemOn', 'SystemNoName', 'G1System', 'G1Nested') {
        $script:Ids[$_] | Should -Not -Match (Get-RdaContractIdPattern)
        $script:Ids[$_] | Should -Not -Match (Get-RdaContractIdPattern -AllowParked -AllowMetricFallback)
        $script:Ids[$_] | Should -Not -Match (Get-RdaMaskedIdPattern)
    }
}

Describe 'Get-RdaContractIdPattern' {

    It 'takes the contract shape <_> by default' -ForEach @('Contract', 'ContractMc', 'ContractKid') {
        $script:Ids[$_] | Should -Match (Get-RdaContractIdPattern)
    }

    It 'refuses <_> by default' -ForEach @('G1System', 'G2NoRg', 'F2Fallback', 'SystemOther', 'SubTokenOnly', 'Flat', 'RealName', 'NoProvider', 'FlatSentinel') {
        $script:Ids[$_] | Should -Not -Match (Get-RdaContractIdPattern)
    }

    It 'takes G2 only with -AllowParked' {
        $script:Ids.G2NoRg | Should -Match (Get-RdaContractIdPattern -AllowParked)
        $script:Ids.G2NoRg | Should -Not -Match (Get-RdaContractIdPattern)
    }

    It 'takes the F2 fallback tokens only with -AllowMetricFallback' {
        $script:Ids.F2Fallback | Should -Match (Get-RdaContractIdPattern -AllowMetricFallback)
        $script:Ids.F2Fallback | Should -Not -Match (Get-RdaContractIdPattern -AllowParked)
    }

    It 'still refuses <_> with every named shape allowed' -ForEach @('G1System', 'G1Nested', 'SystemOther', 'SubTokenOnly', 'Flat', 'RealName', 'NoProvider', 'FlatSentinel') {
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

Describe 'Get-RdaMaskedIdPattern' {

    It 'takes a masked id whose every name is a token, and refuses <_>' -ForEach @('G1System', 'G1Nested', 'SystemOther', 'RealName', 'Flat', 'FlatSentinel') {
        $script:Ids.Contract | Should -Match (Get-RdaMaskedIdPattern)
        $script:Ids.ContractKid | Should -Match (Get-RdaMaskedIdPattern)
        $script:Ids[$_] | Should -Not -Match (Get-RdaMaskedIdPattern)
    }

    It 'writes a name slot as the name token itself, with no group of one alternative around it' {
        (Get-RdaMaskedIdPattern) | Should -Not -Match ([regex]::Escape('/(?:(?:prod|nonprod)_'))
    }

    It 'refuses <_>, which names no resource: a masked id holds at least one provider, type and name token' -ForEach @('SubOnly', 'NoProvider') {
        $script:Ids[$_] | Should -Not -Match (Get-RdaMaskedIdPattern)
        $script:Ids[$_] | Should -Not -Match (Get-RdaObfuscatedIdPattern)
        $script:Ids[$_] | Should -Not -Match (Get-RdaContractIdPattern -AllowParked -AllowMetricFallback)
    }

    It 'still takes <_>: the subscription-scope id with no resourcegroups segment, a child id and an extension id' -ForEach @('G2NoRg', 'Contract', 'ContractKid', 'Extension') {
        $script:Ids[$_] | Should -Match (Get-RdaMaskedIdPattern)
        $script:Ids[$_] | Should -Match (Get-RdaObfuscatedIdPattern)
    }
}

# Each pattern ends at '\z', the end of the text. '$' also matches just before a last
# line feed, so it would take a token or an id with a line feed after it, which is no
# token or id that downstream joins on. The run's own token checks end at '\z' too
# (Test-ObfuscatedIdShape in ResourceInventory.ps1).
Describe 'The token and id patterns end at the end of the text, not before a last line feed' {

    It 'refuses <Id> with a line feed after it, in <Command> <Switches>, and takes it without' -ForEach @(
        @{ Id = 'Flat'; Command = 'Get-RdaTokenPattern'; Switches = @() }
        @{ Id = 'TokenHint'; Command = 'Get-RdaTokenPattern'; Switches = @() }
        @{ Id = 'Contract'; Command = 'Get-RdaMaskedIdPattern'; Switches = @() }
        @{ Id = 'ContractKid'; Command = 'Get-RdaMaskedIdPattern'; Switches = @() }
        @{ Id = 'G2NoRg'; Command = 'Get-RdaMaskedIdPattern'; Switches = @() }
        @{ Id = 'Contract'; Command = 'Get-RdaObfuscatedIdPattern'; Switches = @() }
        @{ Id = 'Flat'; Command = 'Get-RdaObfuscatedIdPattern'; Switches = @() }
        @{ Id = 'Contract'; Command = 'Get-RdaContractIdPattern'; Switches = @() }
        @{ Id = 'ContractMc'; Command = 'Get-RdaContractIdPattern'; Switches = @() }
        @{ Id = 'ContractKid'; Command = 'Get-RdaContractIdPattern'; Switches = @() }
        @{ Id = 'G2NoRg'; Command = 'Get-RdaContractIdPattern'; Switches = @('AllowParked') }
        @{ Id = 'F2Fallback'; Command = 'Get-RdaContractIdPattern'; Switches = @('AllowMetricFallback') }
        @{ Id = 'Contract'; Command = 'Get-RdaContractIdPattern'; Switches = @('AllowParked', 'AllowMetricFallback') }
    ) {
        $Splat = @{}
        foreach ($Name in $Switches) { $Splat[$Name] = $true }
        $Pattern = & $Command @Splat
        $script:Ids[$Id] | Should -Match $Pattern
        ($script:Ids[$Id] + "`n") | Should -Not -Match $Pattern -Because 'a line feed is no part of a token or an id'
    }

    It 'refuses, in the copy in Tests/Helpers/ContractIdPattern.ps1, <_> with a line feed after it, and takes it without' -ForEach @('Contract', 'ContractMc', 'ContractKid') {
        # The copy is loaded in a child scope, so it does not replace this file's function.
        $Copy = & {
            . (Join-Path $PSScriptRoot 'Helpers/ContractIdPattern.ps1')
            [pscustomobject]@{ File = (Get-Command -Name 'Get-RdaContractIdPattern').ScriptBlock.File; Pattern = Get-RdaContractIdPattern }
        }
        Split-Path -Leaf $Copy.File | Should -BeExactly 'ContractIdPattern.ps1'
        $script:Ids[$_] | Should -Match $Copy.Pattern
        ($script:Ids[$_] + "`n") | Should -Not -Match $Copy.Pattern -Because 'a line feed is no part of an id'
    }

    It 'gives the token form with no anchors with -Unanchored, for a test that puts a token inside a larger pattern' {
        $Body = Get-RdaTokenPattern -Unanchored
        ('^' + $Body + '\z') | Should -BeExactly (Get-RdaTokenPattern)
        ('DOCKER|{0}.azurecr.io/{1}:1.2.3' -f $script:Ids.Flat, $script:Ids.TokenHint) | Should -Match ('^DOCKER\|{0}\.azurecr\.io/{0}:1\.2\.3\z' -f $Body)
    }
}

# A doc check, not a behaviour test: it reads comments only, so it passes on
# code with or without the fix. The behaviour tests of the '$system' token are
# in Tests/ObfuscateSystemName.Tests.ps1 and Tests/ObfuscatedResourceId.Tests.ps1.
Describe 'Doc check (comments only, not behaviour): what the tests say about $system' {
    BeforeAll {
        # Whether a line is a stale comment about the fixed name (the test below):
        # one that calls a subscription-scope id with that name flat. A line that
        # speaks of a tenant-scope id is true and is left alone: such an id
        # ('/providers/...', no subscription) with that name in it is still one
        # flat token, which is known and not changed here.
        function script:Test-StaleSystemFlatComment([string]$Line)
        {
            $Line -match '^\s*#' -and $Line.Contains('$system') -and $Line -match '\bflat\b' -and $Line -notmatch '(?i)\btenant\b'
        }
        # The files whose comments described the fixed name before it got a token
        # (kept as written, or its id written flat). Only these are looked at, so a
        # true comment about another id elsewhere cannot trip the check.
        $script:SystemRuleFiles = @('ResourceInventory.ps1', 'Tests/Obfuscation.Tests.ps1', 'Tests/ObfuscationRoundTrip.Tests.ps1', 'Tests/Helpers/SyntheticReportZip.ps1')
        # Each stale comment line in those files under $Root, as '<file>: <line>'.
        # A file that is not there throws, so a renamed file cannot pass unread.
        function script:Find-StaleSystemFlatComment([string]$Root, [string[]]$Files)
        {
            foreach ($File in $Files)
            {
                foreach ($Line in [System.IO.File]::ReadAllLines((Join-Path $Root $File)))
                {
                    if (script:Test-StaleSystemFlatComment $Line) { '{0}: {1}' -f $File, $Line.Trim() }
                }
            }
        }
    }

    It 'takes a comment line as stale only when it calls a $system id flat and does not speak of tenant scope: <Line>' -ForEach @(
        @{ Line = '    #   - flat: prod_<guid>            (legacy / non-ARM uris like $system)'; Stale = $true }
        @{ Line = '# A Service Bus namespace id named $system is written as one flat token.'; Stale = $true }
        @{ Line = '# A tenant-scope ''/providers/...'' id with a ''$system'' part is still one flat token.'; Stale = $false }
        @{ Line = '    # Tenant scope: /providers/microsoft.servicebus/namespaces/$system stays flat (not changed here).'; Stale = $false }
        @{ Line = '$Label = ''a $system id is flat'''; Stale = $false }
    ) {
        script:Test-StaleSystemFlatComment $Line | Should -Be $Stale
    }

    It 'has no comment that says a $system id is written as a flat token, in the files that described the fixed name before it got a token' {
        # A '$system' name gets a token in its id's own path (Get-ObfuscatedResourceId);
        # only a tenant-scope '/providers/...' id is ever flat, and a comment may say so.
        $Hits = @(script:Find-StaleSystemFlatComment -Root (Split-Path $PSScriptRoot -Parent) -Files $script:SystemRuleFiles)
        $Hits | Should -BeNullOrEmpty
    }

    It 'looks for a stale comment only in the files it is given, and stops on one that is not there' {
        $Root = Join-Path $TestDrive 'stale-comment'
        $null = New-Item -ItemType Directory -Path (Join-Path $Root 'Tests') -Force
        $Stale = '# A Service Bus namespace id named $system is written as one flat token.'
        Set-Content -LiteralPath (Join-Path $Root 'Named.ps1') -Value @('$x = 1', $Stale)
        Set-Content -LiteralPath (Join-Path $Root 'Tests/Other.Tests.ps1') -Value @($Stale)
        @(script:Find-StaleSystemFlatComment -Root $Root -Files @('Named.ps1')) | Should -Be @("Named.ps1: $Stale")
        @(script:Find-StaleSystemFlatComment -Root $Root -Files @('Tests/Other.Tests.ps1')).Count | Should -Be 1
        { script:Find-StaleSystemFlatComment -Root $Root -Files @('Missing.ps1') } | Should -Throw
    }
}
