# Prod/nonprod rule tests
# Run with: Invoke-Pester ./Tests/ProdNonprodRule.Tests.ps1 -Output Detailed
#
# Under -Obfuscate each masked token starts with prod_ or nonprod_. A zip with
# only prod resources cannot show the nonprod words, so these tests take the
# rule from ResourceInventory.ps1 itself: its shared classifier function
# Get-ObfuscationPrefix when it has one (run as it is), else the rule lines
# that pick 'nonprod_'. They check that every place that picks a prefix
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
        # The shared classifier, when the product has one, is run as it is.
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Get-ObfuscationPrefix' }, $true))
        $script:HasClassifier = $Fn.Count -eq 1
        if ($script:HasClassifier) { . ([scriptblock]::Create($Fn[0].Extent.Text)) }
        if (-not $script:HasClassifier -and ($script:WordPatterns.Count -eq 0 -or $script:HintPatterns.Count -eq 0)) { throw 'No prod/nonprod rule was found in ResourceInventory.ps1.' }
        function script:Get-ExpectedObfuscationPrefix([string]$Value)
        {
            if ($script:HasClassifier) { return (Get-ObfuscationPrefix $Value) }
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
        # rule, calls the shared classifier, uses the flag the rule set, or
        # keeps the prefix of a token already made. A line that writes a fixed
        # 'prod_' would let one kind of token skip the rule.
        $Source = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1')
        $Assignments = @($Source | Where-Object { $_ -match '^\s*\$\w*Prefix\s*=' })
        $Assignments.Count | Should -BeGreaterOrEqual 1
        foreach ($Line in $Assignments)
        {
            ($Line -match "-match '\\b\(" -or $Line -match 'Get-ObfuscationPrefix' -or $Line -match '\$IsNonProd' -or $Line -match "\.Split\('_'\)\[0\]") | Should -BeTrue -Because "'$($Line.Trim())' must pick the prefix with the rule"
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
