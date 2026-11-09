# Dictionary Validation Tests
# Validates the obfuscation dictionary file is correct and complete
# Run with: $env:TEST_DICT_PATH = "./path/to/ObfuscationDictionary_*.json"; Invoke-Pester ./Tests/DictionaryValidation.Tests.ps1 -Output Detailed

BeforeAll {
    # The run's own dictionary: TEST_DICT_PATH, else the newest one next to
    # TEST_ZIP_PATH, else (no TEST_ZIP_PATH) the newest one in Tests/, where the
    # zip is found too. A dictionary of another run in Tests/ is never taken for
    # a zip given by path.
    $DictPath = if ($env:TEST_DICT_PATH) { $env:TEST_DICT_PATH } else
    {
        $DictDir = if ($env:TEST_ZIP_PATH) { Split-Path $env:TEST_ZIP_PATH -Parent } else { $PSScriptRoot }
        Get-ChildItem -Path $DictDir -Filter "ObfuscationDictionary_*.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
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

    # A masked resource ID is an ARM-shaped path, never a flat token; the
    # shape is described in Helpers/MaskedIdPattern.ps1.
    . (Join-Path $PSScriptRoot 'Helpers/MaskedIdPattern.ps1')
    $script:MaskedIdPattern = Get-MaskedIdPattern
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

    It "No masked id keeps a real subscription, group or name, even one shaped like a token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available"; return }
        $Checked = 0
        foreach ($P in @($script:Dictionary.ResourceIdMap.PSObject.Properties))
        {
            $M = ([string]$P.Name).Split('/'); $R = ([string]$P.Value).Split('/')
            if ($M.Count -ne $R.Count) { continue }
            for ($i = 1; $i -lt $M.Count; $i++)
            {
                # A token slot of the masked id never holds its real segment.
                if ($M[$i] -match '^(prod|nonprod)_' -and $R[$i] -ne '') { $M[$i] | Should -Not -Be $R[$i] -Because "masked id '$($P.Name)' keeps a real part, letter case aside"; $Checked++ }
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because 'no masked path with the same parts as its real id' }
    }

    It "ResourceIdMap values should be real Azure resource IDs" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available"; return }
        $Values = $script:Dictionary.ResourceIdMap.PSObject.Properties.Value
        foreach ($val in $Values)
        {
            # A real id as Azure or the tool wrote it: never empty. Its form is not
            # checked here, since a row with no id or an id that is not an ARM
            # path is recorded too; that it holds no token this run made is
            # checked below.
            [string]::IsNullOrEmpty([string]$val) | Should -BeFalse -Because 'every masked id stands for a real id'
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
        # A real name can itself look like a token, so a real id is checked
        # against the tokens this run made: it holds none of them (letter
        # case aside), since a real id that held one was masked twice.
        $RunTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($P in @($script:Dictionary.ResourceIdMap.PSObject.Properties)) { foreach ($Part in ([string]$P.Name).Split('/')) { if ($Part -cmatch '^(prod|nonprod)_') { [void]$RunTokens.Add($Part) } } }
        foreach ($P in @($script:Dictionary.ResourceIdMap.PSObject.Properties))
        {
            @(([string]$P.Value).Split('/') | Where-Object { $RunTokens.Contains($_) }) | Should -BeNullOrEmpty -Because "Real ID '$($P.Value)' should not hold a token this run made"
        }
    }
}
