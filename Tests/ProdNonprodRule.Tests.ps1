# Prod/nonprod rule tests
# Run with: Invoke-Pester ./Tests/ProdNonprodRule.Tests.ps1 -Output Detailed
#
# Under -Obfuscate each masked token starts with prod_ or nonprod_. A zip with
# only prod resources cannot show the nonprod words, so these tests read the
# rule from ResourceInventory.ps1 itself (every line that picks 'nonprod_'),
# check that the resource name, subscription, resource group, fallback id, tag
# value and consumption id use one rule, and run sample values through it. The
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

    It "reads one nonprod rule for every class from the product source" {
        $script:RuleLines.Count | Should -BeGreaterOrEqual 6 -Because 'the name, subscription, resource group, fallback id, tag value and consumption id each pick a prefix'
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

    It "applies the same classifier to the class '<Class>'" -ForEach @(
        @{ Class = 'ResourceID/Name'; NonProd = 'app-dev-01'; Prod = 'app-prod-01' }
        @{ Class = 'Subscription'; NonProd = 'test-sub'; Prod = 'core-sub' }
        @{ Class = 'ResourceGroup'; NonProd = 'rg-uat-01'; Prod = 'rg-shared-01' }
        @{ Class = 'Tag'; NonProd = 'qa'; Prod = 'owner-team' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $NonProd) | Should -Be 'nonprod_' -Because "the $Class classifier flags '$NonProd' non-prod"
        (script:Get-ExpectedObfuscationPrefix $Prod)    | Should -Be 'prod_'    -Because "the $Class classifier leaves '$Prod' prod"
    }
}
