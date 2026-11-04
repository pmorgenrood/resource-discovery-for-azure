# Dictionary Validation Tests
# Validates the obfuscation dictionary file is correct and complete
# Run with: $env:TEST_DICT_PATH = "./path/to/ObfuscationDictionary_*.json"; Invoke-Pester ./Tests/DictionaryValidation.Tests.ps1 -Output Detailed

BeforeAll {
    $DictPath = if ($env:TEST_DICT_PATH) { $env:TEST_DICT_PATH } else
    {
        # Look in Tests/ folder first
        $Found = Get-ChildItem -Path $PSScriptRoot -Filter "ObfuscationDictionary_*.json" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        if ([string]::IsNullOrEmpty($Found))
        {
            # Try next to the zip file
            $ZipDir = if ($env:TEST_ZIP_PATH) { Split-Path $env:TEST_ZIP_PATH -Parent } else { $PSScriptRoot }
            Get-ChildItem -Path $ZipDir -Filter "ObfuscationDictionary_*.json" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        else { $Found }
    }
    # No dictionary fixture is available when the test zip wasn't produced by an
    # -Obfuscate run. Mark the suite skipped instead of throwing - the rest of
    # the test framework runs in environments without a dictionary on hand.
    $script:DictionaryAvailable = -not [string]::IsNullOrEmpty($DictPath) -and (Test-Path $DictPath)
    $script:Dictionary = if ($script:DictionaryAvailable) { Get-Content $DictPath -Raw | ConvertFrom-Json } else { $null }

    # Also load inventory if available
    $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
    {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    $script:Inventory = $null
    if (![string]::IsNullOrEmpty($ZipPath) -and (Test-Path $ZipPath))
    {
        $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $script:ExtractPath = Join-Path $TmpBase ("DictTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
        Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force
        $InvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
        if ($InvFile) { $script:Inventory = Get-Content $InvFile.FullName -Raw | ConvertFrom-Json }
    }

    # A ResourceIdMap key is the masked resource ID: an ARM-shaped path, never
    # a flat token, and the same string the inventory ID and the consumption
    # ResourceId use for that resource.
    #   /subscriptions/<sub token>[/resourcegroups/<rg token>]/providers/<namespace>/<type>/<name token>[/<type>/<name token>...]
    # Every subscription, resource group and name segment is a prod_/nonprod_
    # token, so a real name left in any of them fails. Name tokens may carry
    # the databricks_/aks_/vmss_ type hint; provider and type segments stay as written.
    $MaskedGuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    $script:MaskedIdPattern = -join @(
        '^/subscriptions/(prod|nonprod)_(sub_)?' + $MaskedGuid
        '(/resourcegroups/(prod|nonprod)_(rg_)?(mc_)?' + $MaskedGuid + ')?'
        '/providers/[a-z][a-z0-9.]*(/[a-z][a-z0-9.]*/((prod|nonprod)_(databricks_|aks_|vmss_)?' + $MaskedGuid + '|\$system))+$'
    )
    # Any masked token anywhere in a value; a real Azure ID never holds one.
    $script:MaskedTokenPattern = '(^|/)(prod|nonprod)_[a-z_]*' + $MaskedGuid + '(/|$)'
    $script:AzureIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}'
}

AfterAll {
    if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "Dictionary Structure" {
    It "Should be valid JSON with all four maps" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH or run -Obfuscate first"; return }
        $script:Dictionary | Should -Not -BeNullOrEmpty
        $script:Dictionary.PSObject.Properties.Name | Should -Contain 'ResourceIdMap'
        $script:Dictionary.PSObject.Properties.Name | Should -Contain 'ResourceNameMap'
        $script:Dictionary.PSObject.Properties.Name | Should -Contain 'SubscriptionMap'
        $script:Dictionary.PSObject.Properties.Name | Should -Contain 'ResourceGroupMap'
    }

    It "Should have a GeneratedAt timestamp" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available"; return }
        $script:Dictionary.GeneratedAt | Should -Not -BeNullOrEmpty
    }

    It "ResourceIdMap keys should be masked ARM paths" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available"; return }
        $Keys = $script:Dictionary.ResourceIdMap.PSObject.Properties.Name
        foreach ($key in $Keys)
        {
            $key | Should -Match $script:MaskedIdPattern -Because "Dictionary key '$key' should be a masked ARM path"
        }
    }

    It "ResourceIdMap values should be real Azure resource IDs" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available"; return }
        $Values = $script:Dictionary.ResourceIdMap.PSObject.Properties.Value
        foreach ($val in $Values)
        {
            $val | Should -Match $script:AzureIdPattern -Because "Dictionary value should be a real Azure resource ID"
        }
    }
}

Describe "Dictionary Completeness" {
    It "Every obfuscated ID in inventory should have a dictionary entry" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available"; return }
        if ($null -eq $script:Inventory) { Set-ItResult -Skipped -Because "No inventory zip provided"; return }
        $DictKeys = $script:Dictionary.ResourceIdMap.PSObject.Properties.Name
        $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
            @($_.Value) | ForEach-Object {
                if ($null -ne $_.ID)
                {
                    $_.ID | Should -BeIn $DictKeys -Because "Inventory ID '$($_.ID)' should have a dictionary entry"
                }
            }
        }
    }
}

Describe "No Double Obfuscation" {
    It "No obfuscated value should appear as a dictionary value (real ID)" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available"; return }
        $Values = $script:Dictionary.ResourceIdMap.PSObject.Properties.Value
        foreach ($val in $Values)
        {
            $val | Should -Not -Match $script:MaskedTokenPattern -Because "Real ID '$val' should not hold an obfuscated token"
        }
    }
}
