# Prod/nonprod rule tests
# Run with: Invoke-Pester ./Tests/ProdNonprodRule.Tests.ps1 -Output Detailed
#
# Under -Obfuscate each masked token starts with prod_ or nonprod_. A zip with
# only prod resources cannot show the nonprod words, so these tests read the
# rule from ResourceInventory.ps1 itself (every line that picks 'nonprod_'),
# check that every place that picks a prefix (resource name, subscription,
# resource group, fallback id, tag value, consumption id) uses one rule, and run sample values through it. The
# samples are words every version of the rule treats alike (dev, test, qa, uat,
# nonprod, non-prod, and plain names as prod), so a change to the word list
# itself is checked where it is made. No zip and no live Azure.

Describe "Classifier fidelity: nonprod words and prod default" {
    BeforeAll {
        # Each line of ResourceInventory.ps1 that chooses the nonprod_ prefix
        # tests a value with two -match patterns: the nonprod words, then the
        # segment hints. Both are read from the source, not copied here.
        $Source = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1')
        $script:RuleLines = @($Source | Where-Object { ($_ -match 'nonprod_' -or $_ -match '\$IsNonProd =') -and $_ -match "-match '\\b\(" })
        $script:WordPatterns = @($script:RuleLines | ForEach-Object { if ($_ -match "-match '(\\b\([^']+)'") { $Matches[1] } } | Select-Object -Unique)
        $script:HintPatterns = @($script:RuleLines | ForEach-Object { if ($_ -match "-match '(\(\^[^']+)'") { $Matches[1] } } | Select-Object -Unique)
        function script:Get-ExpectedObfuscationPrefix([string]$Value)
        {
            if ($Value -match $script:WordPatterns[0] -or $Value -match $script:HintPatterns[0]) { return 'nonprod_' }
            return 'prod_'
        }
    }

    It "reads one nonprod rule for every place that picks a prefix in the product source" {
        # Each class picks its prefix on a line of its own or through one shared
        # function, so the number of lines is not fixed; there is at least one.
        $script:RuleLines.Count | Should -BeGreaterOrEqual 1 -Because 'ResourceInventory.ps1 picks the nonprod_ prefix somewhere'
        $script:WordPatterns.Count | Should -Be 1 -Because 'every class uses the same nonprod words'
        # The consumption id rule tests the whole id, so it may also read a hint
        # right after '/'; with that one difference every class reads one hint.
        @($script:HintPatterns | ForEach-Object { $_.Replace('/|', '') } | Select-Object -Unique).Count | Should -BeLessOrEqual 1 -Because 'every class uses the same segment hint'
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
