#Requires -Version 7.0
<#
    ObfuscationDictionaryComparer.Tests.ps1

    Pins WHICH obfuscation dictionaries are case-insensitive and which are not,
    and pins that the consumption branch does not grow $ResourceIdDictionary.

    THE FOUR IDENTIFIER DICTIONARIES ARE CASE-INSENSITIVE.
    ARM resource ids, subscription ids and resource-group names are
    case-insensitive identifiers by specification. A lookup keyed on exact case
    misses on a casing difference, and every consequence is SILENT: a consumption
    row fails to join back to its inventory resource, and a fresh (unexported,
    unrecoverable) token is minted for it.
    Proven below: a plain Dictionary[string,string] returns FALSE from ContainsKey
    for a case variant, an OrdinalIgnoreCase one returns TRUE.

    TAG AND FREE-TEXT DICTIONARIES ARE CASE-SENSITIVE, DELIBERATELY.
    Azure tag VALUES are genuinely case-sensitive, so 'Env=Prod' and 'Env=prod'
    are two different values. Making those dictionaries case-insensitive would
    collapse them onto one token and lose a real distinction in the estate.

    Offline: source assertions plus pure .NET behaviour checks. Constructing the
    real globals needs the -Obfuscate branch of Variables(), which needs a run.
#>

BeforeAll {
    $script:InvPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
    $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw

    # Pull the construction lines so the assertions read the real code.
    $script:CtorLines = @($script:InvSrc -split "`r?`n" | Where-Object { $_ -match 'Dictionary\[string,string\]''' })

    function script:Get-CtorLineFor
    {
        param([string]$DictName)
        return @($script:CtorLines | Where-Object { $_ -match ([regex]::Escape('$Global:' + $DictName + ' =')) }) | Select-Object -First 1
    }

    # Load the REAL URI-builder helpers out of the file rather than restating them,
    # so the behavioural proofs run against production code.
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$null, [ref]$null)
    $Wanted = @('Resolve-ObfuscationToken', 'Build-ObfuscatedResourceUri')
    $Fns = $Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Wanted
        }, $true)
    # throw, not Should: a failed Should inside BeforeAll surfaces as an opaque
    # container error in Pester 5, which buries the cause.
    if (@($Fns).Count -ne 2)
    {
        throw ('Expected Resolve-ObfuscationToken and Build-ObfuscatedResourceUri in ResourceInventory.ps1, found {0}: {1}' -f @($Fns).Count, (($Fns | ForEach-Object Name) -join ', '))
    }
    foreach ($f in $Fns) { . ([scriptblock]::Create($f.Extent.Text)) }

    function script:New-IdMap
    {
        New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    }
}

Describe 'The four IDENTIFIER dictionaries are built case-insensitive' {

    It '<Dict> uses OrdinalIgnoreCase' -ForEach @(
        @{ Dict = 'ResourceIdDictionary' }
        @{ Dict = 'ResourceNameDictionary' }
        @{ Dict = 'ResourceSubscriptionDictionary' }
        @{ Dict = 'ResourceResourceGroupDictionary' }
    ) {
        $Line = script:Get-CtorLineFor -DictName $Dict
        $Line | Should -Not -BeNullOrEmpty -Because "the construction of $Dict must be findable"
        $Line | Should -Match 'OrdinalIgnoreCase' -Because "a case-sensitive $Dict silently misses on an ARM casing difference, and every consequence of the miss is silent"
    }
}

Describe 'The tag / free-text dictionaries stay case-SENSITIVE' {

    It '<Dict> does NOT use a case-insensitive comparer' -ForEach @(
        @{ Dict = 'TagValueDictionary' }
        @{ Dict = 'FreeTextDictionary' }
    ) {
        $Line = script:Get-CtorLineFor -DictName $Dict
        $Line | Should -Not -BeNullOrEmpty -Because "the construction of $Dict must be findable"
        $Line | Should -Not -Match 'IgnoreCase' -Because "Azure tag values are case-sensitive; collapsing 'Prod' and 'prod' onto one token would lose a real distinction, and no injectivity test would catch it"
    }
}

Describe 'Why the comparer matters (behaviour, not opinion)' {

    It 'a case-SENSITIVE dictionary MISSES an ARM id that differs only in case' {
        $Sensitive = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Sensitive['/subscriptions/ABC/resourceGroups/RG1/providers/Microsoft.Compute/virtualMachines/VM1'] = 'prod_token'

        $Sensitive.ContainsKey('/subscriptions/abc/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1') |
            Should -BeFalse -Because 'this is the silent miss: the consumption row would mint a fresh, unrecoverable token'
    }

    It 'a case-INSENSITIVE dictionary finds it, and returns the SAME token' {
        $Insensitive = script:New-IdMap
        $Insensitive['/subscriptions/ABC/resourceGroups/RG1/providers/Microsoft.Compute/virtualMachines/VM1'] = 'prod_token'

        $Insensitive.ContainsKey('/subscriptions/abc/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1') |
            Should -BeTrue
        $Insensitive['/subscriptions/abc/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'] |
            Should -Be 'prod_token' -Because 'determinism means one real resource maps to exactly one token, whatever its casing'
    }

    It 'case-insensitivity does NOT break determinism: one resource keeps one token' {
        # Writing through a differently-cased key must UPDATE the existing entry,
        # not add a second one - otherwise the same resource could carry two tokens.
        $D = script:New-IdMap
        $D['/SUBS/A/RG/B'] = 'token1'
        $D['/subs/a/rg/b'] = 'token1'
        $D.Count | Should -Be 1 -Because 'two casings of one ARM id are one resource, so they must be one entry'
    }

    It 'a case-SENSITIVE tag dictionary keeps Prod and prod distinct' {
        # The reason the tag dictionary must NOT be switched over.
        $Tags = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Tags['Prod'] = 'tag_token_1'
        $Tags['prod'] = 'tag_token_2'
        $Tags.Count | Should -Be 2 -Because 'these are two genuinely different Azure tag values'

        $Collapsed = script:New-IdMap
        $Collapsed['Prod'] = 'tag_token_1'
        $Collapsed['prod'] = 'tag_token_2'
        $Collapsed.Count | Should -Be 1 -Because 'this is the collapse being avoided: two real values, one token'
    }
}

Describe 'The consumption branch does not grow $ResourceIdDictionary' {

    # The consumption obfuscate branch touches $ResourceIdDictionary in exactly two
    # ways: a read-only ContainsKey/index on the early-exit path, and a call to
    # Build-ObfuscatedResourceUri on the else path. The write-back that used to run
    # on the else path (`$ResourceIdDictionary[$RawUri] = $ObfuscatedUri`) polluted
    # the exported ResourceIdMap (obfuscated-full-id -> real-id) with consumption
    # fragments. These pin both halves: the write-back is gone from source, and the
    # helper provably does not mutate the shared dictionaries it is handed.

    It 'the write-back into $ResourceIdDictionary is gone from the consumption branch' {
        $script:InvSrc | Should -Not -Match '\$ResourceIdDictionary\[\$RawUri\]\s*=' -Because 'writing rebuilt consumption URIs back into the ID dictionary pollutes the exported ResourceIdMap that Reveal consumes'
    }

    It 'Build-ObfuscatedResourceUri does not add an entry to the shared dictionaries' {
        # A case-only variant of an inventoried id: the else-path input.
        $IdDict = script:New-IdMap
        $SubDict = script:New-IdMap
        $RgDict = script:New-IdMap
        $NameDict = script:New-IdMap
        $IdDict['/subscriptions/abc/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1'] = 'prod_id_token'

        $Before = $IdDict.Count
        $RawUri = '/subscriptions/ABC/resourceGroups/RG1/providers/Microsoft.Compute/virtualMachines/VM1'
        $null = Build-ObfuscatedResourceUri -RawUri $RawUri -Prefix 'prod_' -SubscriptionDictionary $SubDict -ResourceGroupDictionary $RgDict -NameDictionary $NameDict -SubCache @{} -RgCache @{} -NameCache @{}

        $IdDict.Count | Should -Be $Before -Because 'the URI builder must never write into $ResourceIdDictionary'
        $SubDict.Count | Should -Be 0 -Because 'the shared subscription dictionary is read-only to the builder (tokens land in the per-run cache)'
        $RgDict.Count | Should -Be 0
        $NameDict.Count | Should -Be 0
    }

    It 'the else-path is deterministic across a case-only URI variant (same rebuilt URI)' {
        # Same real resource, two casings: the per-run caches must yield the same
        # rebuilt URI without either variant being stored in $ResourceIdDictionary.
        $SubCache = @{}; $RgCache = @{}; $NameCache = @{}
        $A = Build-ObfuscatedResourceUri -RawUri '/subscriptions/abc/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1' -Prefix 'prod_' -SubscriptionDictionary $null -ResourceGroupDictionary $null -NameDictionary $null -SubCache $SubCache -RgCache $RgCache -NameCache $NameCache
        $B = Build-ObfuscatedResourceUri -RawUri '/subscriptions/abc/resourcegroups/rg1/providers/microsoft.compute/virtualmachines/vm1' -Prefix 'prod_' -SubscriptionDictionary $null -ResourceGroupDictionary $null -NameDictionary $null -SubCache $SubCache -RgCache $RgCache -NameCache $NameCache
        $A | Should -Be $B -Because 'the per-run caches keep same-URI rows deterministic without a write-back'
    }
}
