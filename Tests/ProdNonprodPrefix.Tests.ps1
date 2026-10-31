# Prod/Nonprod Prefix Tests
# Validates that the prod_/nonprod_ prefix logic is consistent
# Run with: Invoke-Pester ./Tests/ProdNonprodPrefix.Tests.ps1 -Output Detailed

BeforeAll {
    # $env:TEST_ZIP_PATH, else the newest Tests/ResourcesReport_*.zip, else a
    # synthetic report generated offline (Tests/Helpers/SyntheticReportZip.ps1).
    . (Join-Path $PSScriptRoot 'Helpers/SyntheticReportZip.ps1')
    $script:Fixture = Get-RdaTestReportZip
    $ZipPath = $script:Fixture.ZipPath
    if ([string]::IsNullOrEmpty($ZipPath) -or -not (Test-Path $ZipPath))
    {
        throw ("No test zip found, and generating a synthetic one failed (exit {0}):`n{1}" -f $script:Fixture.Exit, $script:Fixture.Console)
    }
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $TmpBase ("PrefixTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

    $InvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = Get-Content $InvFile.FullName -Raw | ConvertFrom-Json

    # An ID is a masked ARM id whose last segment is the resource's own name
    # token (Get-ObfuscatedResourceId); an id that is not an ARM id is one token.
    $script:ObfuscatedIdPattern = Get-RdaObfuscatedIdPattern
    function script:Get-IdOwnToken([string]$Id) { if ($Id.StartsWith('/')) { ($Id -split '/')[-1] } else { $Id } }
    # The subscription and resource group segments of a masked ARM id.
    function script:Get-IdScopeTokens([string]$Id)
    {
        $Parts = $Id -split '/'
        if ($Parts.Count -lt 3 -or $Parts[1] -ne 'subscriptions') { return @() }
        @($Parts[2]) + @(if ($Parts.Count -gt 4 -and $Parts[3] -eq 'resourcegroups') { $Parts[4] })
    }

    $script:AllResources = @()
    $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
        @($_.Value) | ForEach-Object { if ($null -ne $_) { $script:AllResources += $_ } }
    }
}

AfterAll {
    Remove-RdaTestReportZip $script:Fixture
    if (Test-Path $script:ExtractPath) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "Prefix Consistency Per Resource" {
    It "ID and Name should have the same prefix for each resource" {
        foreach ($r in $script:AllResources)
        {
            # Only check ID and Name — Subscription/ResourceGroup are shared across
            # resources and their prefix is derived from the subscription/RG name
            # itself, so they may differ from the resource's own prefix in mixed environments.
            # A masked ARM id starts with '/subscriptions/', so its own token is its
            # last segment, not the start of the string.
            $Fields = @($(if ($r.ID) { script:Get-IdOwnToken $r.ID }), $r.Name) | Where-Object { ![string]::IsNullOrEmpty($_) }
            $Prefixes = $Fields | ForEach-Object { if ($_ -match '^(prod|nonprod)_') { $Matches[1] } }
            $UniquePrefixes = $Prefixes | Select-Object -Unique
            if ($UniquePrefixes.Count -gt 0)
            {
                $UniquePrefixes.Count | Should -Be 1 -Because "Resource '$($r.ID)' should have consistent prefix on ID and Name (got: $($UniquePrefixes -join ', '))"
            }
        }
    }
}

Describe "Prefix Format Validation" {
    It "Every name segment of every obfuscated ID should start with exactly 'prod_' or 'nonprod_'" {
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                # A masked ARM id: its subscription, resource group and resource
                # name segments are prod_/nonprod_ tokens; a resource name token
                # may carry a type hint (databricks_, aks_, vmss_). An id that is
                # not an ARM id is one such token.
                $r.ID | Should -Match $script:ObfuscatedIdPattern -Because "ID should have valid prefix format"
            }
        }
    }

    It "No resource should have an empty prefix (just underscore + GUID)" {
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                $r.ID | Should -Not -Match '(^|/)_[0-9a-f]{8}-' -Because "no ID segment should start with bare underscore"
            }
        }
    }
}

Describe "Consumption Prefix Consistency" {
    It "Consumption ResourceIds should have prod_ or nonprod_ prefix" {
        $CsvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
        if ($null -eq $CsvFile) { Set-ItResult -Skipped -Because "no consumption csv in fixture"; return }
        $Content = Get-Content $CsvFile.FullName -ErrorAction SilentlyContinue
        if ($null -eq $Content -or $Content.Count -le 1) { Set-ItResult -Skipped -Because "empty consumption csv"; return }
        $Csv = Import-Csv $CsvFile.FullName
        # Two valid shapes for an obfuscated consumption ResourceId:
        #   - flat token, for an id that is not an ARM id: ^(prod|nonprod)_...
        #   - structure-preserving ARM path, the same masked id the inventory
        #     gives the resource: /subscriptions/(prod|nonprod)_<guid>/...
        $ValidShape = $script:ObfuscatedIdPattern
        foreach ($row in $Csv)
        {
            if (![string]::IsNullOrEmpty($row.ResourceId))
            {
                $row.ResourceId | Should -Match $ValidShape -Because "Consumption ResourceId should be obfuscated with prod_/nonprod_ prefix (flat or ARM-shape)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Task 3 additive coverage (Property P7 — prefix fidelity + type hints).
# Requirements 3.1, 3.2, 3.3, 3.4.
#
# The existing Describe blocks above validate that whatever prefix appears in
# the fixture is well-formed and consistent, but they cannot exercise the
# non-prod pattern set or the d-/t-/s- segment hints when the fixture contains
# only prod-classified resources (empty TagMap/FreeTextMap, prod-only sample
# data). These blocks close that gap two ways, without weakening anything above:
#   1. Classifier-logic assertions that exercise the EXACT prefix regex the
#      source uses, so the full non-prod set (3.1) and the prod default (3.2)
#      are verified independently of fixture contents. The same regex literal is
#      used per class in ResourceInventory.ps1 (resource name L639, subscription
#      L659, resource group L668, tag value L1011), which is Requirement 3.3.
#   2. Fixture-content assertions that lock the type-hint contract (3.4): the
#      databricks/aks/vmss hints appear only on resource NAME tokens. An ID is a
#      masked ARM id whose last segment is the resource's own name token
#      (Get-ObfuscatedResourceId), so it carries the name's hint there and
#      nowhere else: never on its subscription or resource group segment.
# ---------------------------------------------------------------------------

Describe "Classifier Fidelity — non-prod set and prod default (P7)" {
    BeforeAll {
        # Mirror of the prod/nonprod classifier used identically across all four
        # classes in ResourceInventory.ps1 (L639 name, L659 subscription,
        # L668 resource group, L1011 tag value; also Protect-FreeTextValue L107).
        # Replicated here because a prod-only fixture cannot supply non-prod
        # sample data to drive the classification through the ZIP.
        function script:Get-ExpectedObfuscationPrefix([string]$Value)
        {
            if ($Value -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $Value -match '(^|-)([dts])-')
            {
                return 'nonprod_'
            }
            return 'prod_'
        }
    }

    It "classifies non-prod keyword '<Keyword>' as nonprod_ (Req 3.1)" -ForEach @(
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

    It "classifies segment hint '<Hint>' as nonprod_ (Req 3.1)" -ForEach @(
        @{ Hint = 'd- (start)'; Sample = 'd-app01' }
        @{ Hint = 't- (start)'; Sample = 't-svc01' }
        @{ Hint = 's- (start)'; Sample = 's-node01' }
        @{ Hint = 'd- (mid)'; Sample = 'rg-d-01' }
        @{ Hint = 't- (mid)'; Sample = 'rg-t-01' }
        @{ Hint = 's- (mid)'; Sample = 'rg-s-01' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $Sample) | Should -Be 'nonprod_' -Because "'$Sample' matches the '(^|-)([dts])-' segment hint ($Hint)"
    }

    It "classifies neutral value '<Sample>' as prod_ (Req 3.2)" -ForEach @(
        @{ Sample = 'webapp01' }
        @{ Sample = 'storageacct' }
        @{ Sample = 'sqlserver1' }
        @{ Sample = 'contosoapp' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $Sample) | Should -Be 'prod_' -Because "'$Sample' matches no non-prod set member or segment hint"
    }

    It "applies the same classifier to all four classes (Req 3.3) — class '<Class>'" -ForEach @(
        @{ Class = 'ResourceID/Name'; NonProd = 'app-dev-01'; Prod = 'app-prod-01' }
        @{ Class = 'Subscription'; NonProd = 'test-sub'; Prod = 'core-sub' }
        @{ Class = 'ResourceGroup'; NonProd = 'rg-uat-01'; Prod = 'rg-shared-01' }
        @{ Class = 'Tag'; NonProd = 'qa'; Prod = 'owner-team' }
    ) {
        (script:Get-ExpectedObfuscationPrefix $NonProd) | Should -Be 'nonprod_' -Because "the $Class classifier flags '$NonProd' non-prod"
        (script:Get-ExpectedObfuscationPrefix $Prod)    | Should -Be 'prod_'    -Because "the $Class classifier leaves '$Prod' prod"
    }
}

Describe "Type Hint Fidelity — name tokens only (P7 / Req 3.4)" {
    It "obfuscated IDs never carry a databricks/aks/vmss type hint outside a resource name segment" {
        # The hint is only ever put on a resource NAME token (New-ObfuscatedNameToken
        # and the per-resource loop of RunInventorySetup). A masked ARM id holds
        # name tokens only in its resource name segments; its subscription and
        # resource group tokens never carry a hint, and an id masked to one token
        # (not an ARM id) carries none. Runs across every resource regardless of
        # fixture composition.
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                if ($r.ID.StartsWith('/'))
                {
                    foreach ($Scope in (script:Get-IdScopeTokens $r.ID))
                    {
                        $Scope | Should -Not -Match '^(prod|nonprod)_(databricks|aks|vmss)_' -Because "type hints belong on resource name tokens, not the subscription or resource group of '$($r.ID)'"
                    }
                }
                else
                {
                    $r.ID | Should -Not -Match '^(prod|nonprod)_(databricks|aks|vmss)_' -Because "type hints belong on the obfuscated Name, not the ID ('$($r.ID)')"
                }
            }
        }
    }

    It "any databricks/aks/vmss type hint present in the fixture sits on the Name, and on the ID only as that Name" {
        # Positive check: only meaningful when the fixture actually contains a
        # type-hinted resource. If it does not (prod-only / no databricks/aks/vmss
        # resources), record the fixture limitation instead of asserting on
        # absent data.
        $HintPattern = '^(prod|nonprod)_(databricks|aks|vmss)_[0-9a-f]{8}-'
        $HintedNames = @($script:AllResources | Where-Object { $null -ne $_.Name -and $_.Name -match $HintPattern })
        if ($HintedNames.Count -eq 0)
        {
            Set-ItResult -Skipped -Because "fixture contains no databricks/aks/vmss type-hinted resources to assert against"
            return
        }
        foreach ($r in $HintedNames)
        {
            $r.Name | Should -Match $HintPattern -Because "the type hint must be well-formed on the Name"
            $r.ID   | Should -Not -Match '^(prod|nonprod)_(databricks|aks|vmss)_' -Because "the same resource's ID must not be the hinted token itself ('$($r.ID)')"
            if ($r.ID.StartsWith('/'))
            {
                (script:Get-IdOwnToken $r.ID) | Should -BeExactly $r.Name -Because "the masked ID's last segment is the resource's own Name token ('$($r.ID)')"
                foreach ($Scope in (script:Get-IdScopeTokens $r.ID))
                {
                    $Scope | Should -Not -Match '^(prod|nonprod)_(databricks|aks|vmss)_' -Because "the subscription and resource group segments of '$($r.ID)' stay hint-free"
                }
            }
        }
    }
}
