# Prod/nonprod rule tests
# Run with: Invoke-Pester ./Tests/ProdNonprodRule.Tests.ps1 -Output Detailed
#
# Under -Obfuscate each masked token starts with prod_ or nonprod_. A zip with
# only prod resources cannot show the nonprod words, so these tests take the
# rule from the product itself: the shared classifier function when it has
# one (the command its subscription token prefix line calls, or
# Get-ObfuscationPrefix, defined in ResourceInventory.ps1 or Functions/, run
# as it is), else the rule lines of ResourceInventory.ps1 that pick 'nonprod_'. They check that every place that picks a prefix
# (resource name, subscription, resource group, fallback id, tag value,
# consumption id) uses that rule, and run sample values through it. The
# samples are words every version of the rule treats alike (dev, test, qa,
# uat, nonprod, non-prod, and plain names as prod). No zip and no live Azure.

Describe "Classifier fidelity: nonprod words and prod default" {
    BeforeAll {
        # Each line of ResourceInventory.ps1 that chooses the nonprod_ prefix
        # tests a value with two -match patterns: the nonprod words, then the
        # segment hints. Both are read from the source, not copied here.
        $Source = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1')
        $script:RuleLines = @($Source | Where-Object { ($_ -match 'nonprod_' -or $_ -match '\$IsNonProd =') -and $_ -match "-match '\\b\(" })
        $script:WordPatterns = @($script:RuleLines | ForEach-Object { if ($_ -match "-match '(\\b\([^']+)'") { $Matches[1] } } | Select-Object -Unique)
        $script:HintPatterns = @($script:RuleLines | ForEach-Object { if ($_ -match "-match '(\(\^[^']+)'") { $Matches[1] } } | Select-Object -Unique)
        # The product's functions, from ResourceInventory.ps1 and Functions/:
        # name (without a Global: scope) -> its definition.
        $Root = Split-Path $PSScriptRoot -Parent
        $script:ProductFunctions = @{}
        foreach ($File in @((Join-Path $Root 'ResourceInventory.ps1')) + @(Get-ChildItem -Path (Join-Path $Root 'Functions') -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }))
        {
            $FileAst = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
            $Defs = @($FileAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            foreach ($Def in $Defs) { $script:ProductFunctions[($Def.Name -replace '^(?i)global:', '')] = [pscustomobject]@{ Ast = $Def; File = $File } }
        }
        # The shared classifier: the command the subscription token prefix
        # line calls, when the product defines it, else Get-ObfuscationPrefix.
        $SubLine = @($Source | Where-Object { $_ -match '^\s*\$SubPrefix\s*=\s*([A-Za-z]+-[A-Za-z]+)\b' } | Select-Object -First 1)
        $Called = if ($SubLine.Count -eq 1 -and $SubLine[0] -match '^\s*\$SubPrefix\s*=\s*([A-Za-z]+-[A-Za-z]+)\b') { $Matches[1] } else { $null }
        $script:ClassifierName = if ($Called -and $script:ProductFunctions.ContainsKey($Called)) { $Called } elseif ($script:ProductFunctions.ContainsKey('Get-ObfuscationPrefix')) { 'Get-ObfuscationPrefix' } else { $null }
        $script:HasClassifier = $null -ne $script:ClassifierName
        if ($script:HasClassifier)
        {
            # Run as it is: its definition and the product functions it calls.
            $Load = [System.Collections.Generic.List[string]]::new(); $Queue = [System.Collections.Generic.Queue[string]]::new(); $Queue.Enqueue($script:ClassifierName)
            while ($Queue.Count -gt 0)
            {
                $Name = $Queue.Dequeue(); if ($Load.Contains($Name)) { continue }; $Load.Add($Name)
                foreach ($Cmd in $script:ProductFunctions[$Name].Ast.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] }, $true)) { $C = $Cmd.GetCommandName(); if ($C -and $script:ProductFunctions.ContainsKey($C) -and -not $Load.Contains($C)) { $Queue.Enqueue($C) } }
            }
            foreach ($Name in $Load) { . ([scriptblock]::Create(($script:ProductFunctions[$Name].Ast.Extent.Text -replace '^(?i)(function|filter)\s+global:', '$1 '))) }
        }
        if (-not $script:HasClassifier -and ($script:WordPatterns.Count -eq 0 -or $script:HintPatterns.Count -eq 0)) { throw 'No prod/nonprod rule was found in the product source.' }
        # The product functions that pick a prefix through the classifier.
        $script:PrefixFunctions = @($script:ProductFunctions.Keys | Where-Object { $_ -eq $script:ClassifierName -or ($script:HasClassifier -and $script:ProductFunctions[$_].Ast.Body.Extent.Text -match ('\b' + [regex]::Escape($script:ClassifierName) + '\b')) })
        function script:Get-ExpectedObfuscationPrefix([string]$Value)
        {
            if ($script:HasClassifier) { return (& $script:ClassifierName $Value) }
            if ($Value -match $script:WordPatterns[0] -or $Value -match $script:HintPatterns[0]) { return 'nonprod_' }
            return 'prod_'
        }
    }

    It "reads one nonprod rule for every place that picks a prefix in the product source" {
        # Each class picks its prefix on a line of its own or through one shared
        # function, so the number of lines is not fixed; there is at least one.
        $script:RuleLines.Count | Should -BeGreaterOrEqual ([int](-not $script:HasClassifier)) -Because 'without a shared classifier, ResourceInventory.ps1 picks the nonprod_ prefix on rule lines'
        $script:WordPatterns.Count | Should -BeLessOrEqual 1 -Because 'every rule line uses the same nonprod words'
        # The consumption id rule tests the whole id, so it may also read a hint
        # right after '/'; with that one difference every class reads one hint.
        @($script:HintPatterns | ForEach-Object { $_.Replace('/|', '') } | Select-Object -Unique).Count | Should -BeLessOrEqual 1 -Because 'every class uses the same segment hint'
    }

    It "picks every masked token prefix with the rule, never a fixed prefix" {
        # Every '$<name>Prefix =' line of ResourceInventory.ps1 either runs the
        # rule, calls the shared classifier or a product function that calls
        # it, uses the flag the rule set, or keeps the prefix of a token
        # already made. A line that writes a fixed
        # 'prod_' would let one kind of token skip the rule.
        $Source = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1')
        $Assignments = @($Source | Where-Object { $_ -match '^\s*\$\w*Prefix\s*=' })
        $Assignments.Count | Should -BeGreaterOrEqual 1
        foreach ($Line in $Assignments)
        {
            $ViaClassifier = @($script:PrefixFunctions | Where-Object { $Line -match ('=\s*' + [regex]::Escape($_) + '\b') }).Count -gt 0
            ($Line -match "-match '\\b\(" -or $ViaClassifier -or $Line -match '\$IsNonProd' -or $Line -match "\.Split\('_'\)\[0\]") | Should -BeTrue -Because "'$($Line.Trim())' must pick the prefix with the rule"
        }
    }

    It "classifies nonprod word '<Keyword>' as nonprod_" -ForEach @(
        @{ Keyword = 'dev'; Sample = 'app-dev-01' }
        @{ Keyword = 'test'; Sample = 'test-db-01' }
        @{ Keyword = 'qa'; Sample = 'qa-web-01' }
        @{ Keyword = 'non-prod'; Sample = 'non-prod' }
        @{ Keyword = 'uat'; Sample = 'uat-app-01' }
        @{ Keyword = 'nonprod'; Sample = 'nonprod-app' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $Sample) | Should -Be 'nonprod_' -Because "'$Sample' matches the non-prod set member '$Keyword'"
    }

    It "classifies neutral value '<Sample>' as prod_" -ForEach @(
        @{ Sample = 'webapp01' }
        @{ Sample = 'storageacct' }
        @{ Sample = 'sqlserver1' }
        @{ Sample = 'contosoapp' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $Sample) | Should -Be 'prod_' -Because "'$Sample' matches no non-prod set member or segment hint"
    }
}
