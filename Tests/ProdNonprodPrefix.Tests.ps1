# Prod/Nonprod Prefix Tests
# Validates that the prod_/nonprod_ prefix logic is consistent
# Run with: Invoke-Pester ./Tests/ProdNonprodPrefix.Tests.ps1 -Output Detailed

BeforeAll {
    $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
    {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($ZipPath) -or -not (Test-Path $ZipPath))
    {
        throw "No test zip found."
    }
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $TmpBase ("PrefixTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

    $InvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = Get-Content $InvFile.FullName -Raw | ConvertFrom-Json

    $script:AllResources = @()
    $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
        @($_.Value) | ForEach-Object { if ($null -ne $_) { $script:AllResources += $_ } }
    }

    # A masked resource ID is an ARM-shaped path, never a flat token; the
    # shape is described in Helpers/MaskedIdPattern.ps1.
    . (Join-Path $PSScriptRoot 'Helpers/MaskedIdPattern.ps1')
    $script:MaskedIdPattern = Get-MaskedIdPattern
    # A consumption row can be billed to a subscription or a group itself.
    $script:MaskedConsumptionIdPattern = Get-MaskedIdPattern -AllowScopeOnly
}

AfterAll {
    if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "Prefix Consistency Per Resource" {
    It "ID and Name should have the same prefix for each resource" {
        foreach ($r in $script:AllResources)
        {
            # Only check ID and Name: Subscription/ResourceGroup are shared across
            # resources and their prefix is derived from the subscription/RG name
            # itself, so they may differ from the resource's own prefix in mixed environments.
            # The ID is a masked ARM path, so its prefix is the one on its last
            # (name) segment.
            $IdName = if ([string]::IsNullOrEmpty($r.ID)) { $null } else { ($r.ID -split '/')[-1] }
            $Fields = @($IdName, $r.Name) | Where-Object { ![string]::IsNullOrEmpty($_) }
            $Prefixes = $Fields | ForEach-Object { if ($_ -match '^(prod|nonprod)_') { $Matches[1] } }
            $UniquePrefixes = $Prefixes | Select-Object -Unique
            if ($UniquePrefixes.Count -gt 0)
            {
                $UniquePrefixes.Count | Should -Be 1 -Because "Resource '$($r.ID)' should have consistent prefix on ID and Name (got: $($UniquePrefixes -join ', '))"
            }
        }
    }
}

Describe "Name Matches The Id's Name Token" {
    It "Each joinable row's Name is the last segment of its ID" {
        # A billed resource with no ID match is joined by Name, ResourceGroup
        # and Subscription taken from the consumption path, so in the sections
        # that join, a row's Name must be its masked ID's name token itself,
        # not only share its prefix.
        $Checked = 0
        foreach ($Section in @('VirtualMachines', 'VMDisk', 'Databricks', 'PostgreSQLflexible', 'MySQLflexible', 'SQLVM', 'SQLDB', 'SQLPool', 'SQLMI'))
        {
            foreach ($r in @($script:Inventory.$Section | Where-Object { $null -ne $_ -and ![string]::IsNullOrEmpty($_.ID) -and ![string]::IsNullOrEmpty($_.Name) }))
            {
                if ($r.ID -like '/providers/rda.noid/ids/*') { continue }
                $Checked++
                $r.Name | Should -BeExactly (($r.ID.TrimEnd('/') -split '/')[-1]) -Because "$Section row '$($r.ID)' should carry its ID's name token as Name"
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because 'no joinable row in this fixture' }
    }
}

Describe "Prefix Format Validation" {
    It "All obfuscated IDs should be masked ARM paths whose every masked segment starts with exactly 'prod_' or 'nonprod_'" {
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                # Type-tagged name tokens (databricks_, aks_, vmss_) are legitimate
                # output for Databricks, AKS-managed and scale set resources.
                $r.ID | Should -Match $script:MaskedIdPattern -Because "ID '$($r.ID)' should be a masked ARM path"
            }
        }
    }

    It "No resource should have an empty prefix (just underscore + GUID)" {
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                $r.ID | Should -Not -Match '(^|/)_[0-9a-f]{8}-' -Because "no ID segment should start with bare underscore ('$($r.ID)')"
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
        # An obfuscated consumption ResourceId is a masked ARM path whose every
        # masked segment starts with prod_ or nonprod_; a flat token is wrong.
        foreach ($row in $Csv)
        {
            if (![string]::IsNullOrEmpty($row.ResourceId))
            {
                $row.ResourceId | Should -Match $script:MaskedConsumptionIdPattern -Because "Consumption ResourceId '$($row.ResourceId)' should be a masked ARM path with prod_/nonprod_ tokens"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Type hints. The databricks/aks/vmss hints appear only on the masked name,
# the last segment of the masked ID path, never on the subscription or
# resource group token. The prod/nonprod rule itself is tested without a zip
# in ProdNonprodRule.Tests.ps1.
# ---------------------------------------------------------------------------

Describe "Type hint fidelity: name token only, never the subscription or resource group token" {
    It "obfuscated IDs never carry a databricks/aks/vmss type hint on the subscription or resource group token" {
        # The ID is a masked ARM path whose last segment is the obfuscated NAME,
        # so a hinted name shows up there. The subscription and resource group
        # tokens are built with no type hint. Assert they never pick one up.
        # Runs across every resource regardless of fixture composition.
        foreach ($r in $script:AllResources)
        {
            if ($null -ne $r.ID)
            {
                $r.ID | Should -Not -Match '(?i)/(subscriptions|resourcegroups)/(prod|nonprod)_(databricks|aks|vmss)_' -Because "type hints belong on the obfuscated Name, not the subscription or resource group token ('$($r.ID)')"
            }
        }
    }

    It "any databricks/aks/vmss type hint present in the fixture sits on the Name only" {
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
            ($r.ID -split '/')[-1] | Should -Be $r.Name -Because "the same resource's ID must end with its hinted Name token ('$($r.ID)')"
            $r.ID | Should -Not -Match '(?i)/(subscriptions|resourcegroups)/(prod|nonprod)_(databricks|aks|vmss)_' -Because "the same resource's subscription and resource group tokens must remain hint-free ('$($r.ID)')"
        }
    }
}
