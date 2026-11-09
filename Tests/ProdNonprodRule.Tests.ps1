# Prod/nonprod rule tests
# Run with: Invoke-Pester ./Tests/ProdNonprodRule.Tests.ps1 -Output Detailed
#
# Under -Obfuscate each masked token starts with prod_ or nonprod_. A zip with
# only prod resources cannot show the nonprod words or the d-/t-/s- segment
# hints, so these tests read the rule from ResourceInventory.ps1 itself (every
# line that picks 'nonprod_'), check that the resource name, subscription,
# resource group, fallback id, tag value and consumption id use one rule, and
# run sample values through it. A changed or missing rule in the product fails
# here. No zip and no live Azure.

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
        # The consumption id rule also reads a hint right after '/', since it
        # tests the whole id; each other class reads the same hint.
        @($script:HintPatterns | Where-Object { $_ -notin @('(^|-)([dts])-', '(^|/|-)([dts])-') }).Count | Should -Be 0
    }

    It "classifies nonprod word '<Keyword>' as nonprod_" -ForEach @(
        @{ Keyword = 'dev'; Sample = 'app-dev-01' }
        @{ Keyword = 'test'; Sample = 'test-db-01' }
        @{ Keyword = 'qa'; Sample = 'qa-web-01' }
        @{ Keyword = 'tst'; Sample = 'tst-app-01' }
        @{ Keyword = 'development'; Sample = 'development-team' }
        @{ Keyword = 'non-prod'; Sample = 'non-prod' }
        @{ Keyword = 'uat'; Sample = 'uat-app-01' }
        @{ Keyword = 'nonprod'; Sample = 'nonprod-app' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $Sample) | Should -Be 'nonprod_' -Because "'$Sample' matches the non-prod set member '$Keyword'"
    }

    It "classifies segment hint '<Hint>' as nonprod_" -ForEach @(
        @{ Hint = 'd- (start)'; Sample = 'd-app01' }
        @{ Hint = 't- (start)'; Sample = 't-svc01' }
        @{ Hint = 's- (start)'; Sample = 's-node01' }
        @{ Hint = 'd- (mid)'; Sample = 'rg-d-01' }
        @{ Hint = 't- (mid)'; Sample = 'rg-t-01' }
        @{ Hint = 's- (mid)'; Sample = 'rg-s-01' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $Sample) | Should -Be 'nonprod_' -Because "'$Sample' matches the segment hint ($Hint)"
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
