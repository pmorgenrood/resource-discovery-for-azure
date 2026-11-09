# Obfuscation Tests for Resource Discovery for Azure
# Run with: Invoke-Pester ./Tests/Obfuscation.Tests.ps1 -Output Detailed

BeforeAll {
    # Helper for the Determinism block below. Given a dictionary map
    # (token -> real-value) and a selector that derives the real value from a
    # map value, return the groups of real values that are reachable from MORE
    # THAN ONE distinct token. A non-empty result means the same real value
    # produced two different tokens within the run, which breaks obfuscation
    # determinism. Defined in BeforeAll so it is in scope for the It blocks.
    function Get-DeterminismViolation
    {
        param(
            [Parameter(Mandatory)] $Map,
            [Parameter(Mandatory)] [scriptblock] $RealValueSelector,
            # Tag and free-text values are kept apart by letter case in the
            # product's dictionaries ('Prod' and 'prod' are two values); ids,
            # groups and subscriptions are not.
            [switch] $CaseSensitive
        )

        $Pairs = foreach ($property in $Map.PSObject.Properties)
        {
            $Real = & $RealValueSelector $property.Value
            if (-not [string]::IsNullOrEmpty([string]$Real))
            {
                [PSCustomObject]@{ Real = [string]$Real; Token = $property.Name }
            }
        }

        @($Pairs | Group-Object Real -CaseSensitive:$CaseSensitive | Where-Object { @($_.Group.Token | Sort-Object -Unique).Count -gt 1 })
    }

    # Find the zip
    $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
    {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }

    if ([string]::IsNullOrEmpty($ZipPath) -or -not (Test-Path $ZipPath))
    {
        throw "No test zip found. Copy a ResourcesReport_*.zip to the Tests/ folder or set `$env:TEST_ZIP_PATH"
    }

    # Extract to temp folder
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $TmpBase ("ObfuscationTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

    # Load files
    $script:InventoryFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:MetricsFiles = @(Get-ChildItem -Path $script:ExtractPath -Filter "Metrics_*.json")
    $script:ConsumptionFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
    $script:AllFiles = Get-ChildItem -Path $script:ExtractPath -File

    # Parse inventory JSON
    if ($script:InventoryFile)
    {
        $script:Inventory = Get-Content $script:InventoryFile.FullName -Raw | ConvertFrom-Json
    }

    # Read all file contents once for PII scanning
    $script:AllContent = @{}
    foreach ($file in $script:AllFiles)
    {
        $script:AllContent[$file.Name] = Get-Content $file.FullName -Raw
    }

    # Obfuscation pattern: prod_ or nonprod_ followed by an optional type-tag
    # (databricks_, aks_, vmss_) and a GUID. The type-tagged variants are the
    # name tokens ResourceInventory.ps1 writes for Databricks resources,
    # resources in AKS-managed resource groups and scale set instances.
    $script:ObfuscationPattern = '^(prod|nonprod)_(databricks_|aks_|vmss_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    # A masked resource ID is an ARM-shaped path, never a flat token; the
    # shape is described in Helpers/MaskedIdPattern.ps1.
    . (Join-Path $PSScriptRoot 'Helpers/MaskedIdPattern.ps1')
    $script:MaskedIdPattern = Get-MaskedIdPattern

    # Helper: get all resources from inventory as flat list
    $script:AllResources = @()
    if ($script:Inventory)
    {
        $Props = $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' }
        foreach ($prop in $Props)
        {
            $script:AllResources += @($prop.Value)
        }
    }

    # Locate the reverse-lookup dictionary for the determinism checks: the
    # run's own one, as DictionaryValidation.Tests.ps1 finds it (TEST_DICT_PATH,
    # else next to TEST_ZIP_PATH, else in Tests/ when no TEST_ZIP_PATH is set).
    # The dictionary is LOCAL-ONLY and is never inside the shared zip.
    $DictPath = if ($env:TEST_DICT_PATH) { $env:TEST_DICT_PATH } else
    {
        $DictDir = if ($env:TEST_ZIP_PATH) { Split-Path $env:TEST_ZIP_PATH -Parent } else { $PSScriptRoot }
        Get-ChildItem -Path $DictDir -Filter "ObfuscationDictionary_*.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    $script:DictionaryAvailable = -not [string]::IsNullOrEmpty($DictPath) -and (Test-Path $DictPath)
    $script:Dictionary = if ($script:DictionaryAvailable) { Get-Content $DictPath -Raw | ConvertFrom-Json } else { $null }

    # The tag-value tokenizer of ResourceInventory.ps1 itself: the one
    # 'if ($resourceItem.ContainsKey('Tags') ...)' block of its resource loop,
    # taken from the source with the PowerShell parser. Invoke-TagObfuscation
    # runs it on one row, the same shape the collectors produce (a
    # case-insensitive [hashtable] whose 'Tags' value is an array of
    # { Name, Value } objects), with the given tag dictionary. A changed or
    # missing block in the product fails the tests that use it.
    $RiAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
    $TagBlocks = @($RiAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq "`$resourceItem.ContainsKey('Tags') -and `$null -ne `$resourceItem.Tags" }, $true))
    $script:TagBlock = if ($TagBlocks.Count -eq 1) { [scriptblock]::Create($TagBlocks[0].Extent.Text) } else { $null }
    function script:Invoke-TagObfuscation
    {
        param(
            [Parameter(Mandatory)] $ResourceItem,
            [Parameter(Mandatory)] $TagValueDictionary
        )
        if ($null -eq $script:TagBlock) { throw 'Expected one tag tokenizer block in ResourceInventory.ps1.' }
        $Saved = $Global:TagValueDictionary
        $Global:TagValueDictionary = $TagValueDictionary
        # PowerShell names ignore case, so the block reads $ResourceItem as its $resourceItem.
        try { . $script:TagBlock }
        finally { $Global:TagValueDictionary = $Saved }
    }
}

AfterAll {
    if (Test-Path $script:ExtractPath)
    {
        Remove-Item -Path $script:ExtractPath -Recurse -Force
    }
}

# ============================================================
# 1. Transcript excluded from zip
# ============================================================
Describe "Transcript Exclusion" {
    It "Should not contain any transcript log files in the zip" {
        $TranscriptFiles = $script:AllFiles | Where-Object { $_.Name -like "Transcript_*" }
        $TranscriptFiles | Should -BeNullOrEmpty
    }
}

# ============================================================
# 2. No email addresses in any file
# ============================================================
Describe "Email Address Leak Check" {
    It "Should not contain any email addresses in any output file" {
        $EmailPattern = '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
        foreach ($fileName in $script:AllContent.Keys)
        {
            if ([string]::IsNullOrEmpty($script:AllContent[$fileName])) { continue }
            $EmailMatches = [regex]::Matches($script:AllContent[$fileName], $EmailPattern)
            $EmailMatches.Count | Should -Be 0 -Because "File '$fileName' should not contain email addresses (found: $($EmailMatches.Value -join ', '))"
        }
    }
}

# ============================================================
# 3. No home directory paths in any file
# ============================================================
Describe "Home Directory Path Leak Check" {
    It "Should not contain Unix home directory paths" {
        foreach ($fileName in $script:AllContent.Keys)
        {
            $script:AllContent[$fileName] | Should -Not -Match '/home/[a-zA-Z]' -Because "File '$fileName' should not contain Unix home paths"
        }
    }

    It "Should not contain Windows user directory paths" {
        foreach ($fileName in $script:AllContent.Keys)
        {
            $script:AllContent[$fileName] | Should -Not -Match 'C:\\Users\\[a-zA-Z]' -Because "File '$fileName' should not contain Windows user paths"
        }
    }
}

# ============================================================
# 4. No Azure subscription ID patterns (raw GUIDs in sub context)
# ============================================================
Describe "Subscription ID Leak Check" {
    It "Should not contain raw Azure subscription ID patterns in inventory JSON" {
        # Azure resource IDs follow: /subscriptions/<guid>/resourceGroups/...
        $SubIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        if ($script:InventoryFile)
        {
            $Content = $script:AllContent[$script:InventoryFile.Name]
            $Content | Should -Not -Match $SubIdPattern -Because "Inventory JSON should not contain raw Azure resource ID paths"
        }
    }

    It "Should not contain raw Azure subscription ID patterns in consumption CSV" {
        $SubIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        if ($script:ConsumptionFile)
        {
            $Content = $script:AllContent[$script:ConsumptionFile.Name]
            $Content | Should -Not -Match $SubIdPattern -Because "Consumption CSV should not contain raw Azure resource ID paths"
        }
    }

    It "Should not contain raw Azure subscription ID patterns in metrics JSON" {
        $SubIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        foreach ($metricsFile in $script:MetricsFiles)
        {
            $Content = $script:AllContent[$metricsFile.Name]
            $Content | Should -Not -Match $SubIdPattern -Because "Metrics JSON should not contain raw Azure resource ID paths"
        }
    }
}

# ============================================================
# 5. All inventory resource IDs are obfuscated
# ============================================================
Describe "Inventory ID Obfuscation" {
    It "Should have all resource IDs matching the masked ARM path shape" {
        # A subscription with no resource writes an empty inventory; there is
        # no id to check then, which is not a pass.
        if ($script:AllResources.Count -eq 0) { Set-ItResult -Skipped -Because 'the inventory of this zip holds no resource'; return }
        foreach ($resource in $script:AllResources)
        {
            if ($null -ne $resource.ID)
            {
                $resource.ID | Should -Match $script:MaskedIdPattern -Because "Resource ID '$($resource.ID)' should be a masked ARM path"
            }
        }
    }
}

# ============================================================
# 6. All inventory resource names are obfuscated
# ============================================================
Describe "Inventory Name Obfuscation" {
    It "Should have all resource names matching the obfuscation pattern" {
        foreach ($resource in $script:AllResources)
        {
            if ($null -ne $resource.Name)
            {
                $resource.Name | Should -Match $script:ObfuscationPattern -Because "Resource Name '$($resource.Name)' should be obfuscated"
            }
        }
    }
}

# ============================================================
# 7. All inventory subscriptions are obfuscated
# ============================================================
Describe "Inventory Subscription Obfuscation" {
    It "Should have all subscription fields matching the obfuscation pattern" {
        foreach ($resource in $script:AllResources)
        {
            if ($null -ne $resource.Subscription)
            {
                $resource.Subscription | Should -Match $script:ObfuscationPattern -Because "Subscription '$($resource.Subscription)' should be obfuscated"
            }
        }
    }
}

# ============================================================
# 8. All inventory resource groups are obfuscated
# ============================================================
Describe "Inventory ResourceGroup Obfuscation" {
    It "Should have all resource group fields matching the obfuscation pattern" {
        foreach ($resource in $script:AllResources)
        {
            if ($null -ne $resource.ResourceGroup)
            {
                $resource.ResourceGroup | Should -Match $script:ObfuscationPattern -Because "ResourceGroup '$($resource.ResourceGroup)' should be obfuscated"
            }
        }
    }
}

# ============================================================
# 9. Metrics IDs are obfuscated
# ============================================================
Describe "Metrics Obfuscation" {
    It "Should have masked ARM path metric IDs and masked metric names" {
        foreach ($metricsFile in $script:MetricsFiles)
        {
            $MetricsData = Get-Content $metricsFile.FullName -Raw | ConvertFrom-Json
            foreach ($metric in @($MetricsData.Metrics))
            {
                if ($null -ne $metric.ID)
                {
                    $metric.ID | Should -Match $script:MaskedIdPattern -Because "Metric ID '$($metric.ID)' should be a masked ARM path"
                }
                if ($null -ne $metric.Name)
                {
                    $metric.Name | Should -Match $script:ObfuscationPattern -Because "Metric Name should be obfuscated"
                }
                if ($null -ne $metric.Subscription)
                {
                    $metric.Subscription | Should -Match $script:ObfuscationPattern -Because "Metric Subscription should be obfuscated"
                }
                if ($null -ne $metric.ResourceGroup)
                {
                    $metric.ResourceGroup | Should -Match $script:ObfuscationPattern -Because "Metric ResourceGroup should be obfuscated"
                }
            }
        }
    }
}

# ============================================================
# 10. Consumption ResourceIds are obfuscated
# ============================================================
Describe "Consumption Obfuscation" {
    # NOTE: the consumption ResourceId keeps the ARM path structure
    # (/subscriptions/<obf-sub>/resourcegroups/<obf-rg>/providers/<rp>/<type>/<obf-name>)
    # so rows can be told apart by provider, type and child segments, and joined
    # to the inventory ID with the same tokens. A flat prod_<guid> token loses
    # the subscription, resource group and type, so it fails here.
    # $script:MaskedIdPattern comes from the top-level BeforeAll.

    It "Should have all consumption ResourceIds matching the masked ARM path shape" {
        if ($null -eq $script:ConsumptionFile) { Set-ItResult -Skipped -Because "no consumption file in fixture"; return }
        $Csv = Import-Csv $script:ConsumptionFile.FullName
        if ($Csv.Count -eq 0) { Set-ItResult -Skipped -Because "empty consumption csv"; return }

        foreach ($row in $Csv)
        {
            if (![string]::IsNullOrEmpty($row.ResourceId))
            {
                $row.ResourceId | Should -Match $script:MaskedIdPattern -Because "Consumption ResourceId '$($row.ResourceId)' should be a masked ARM path"
                $row.ResourceId | Should -Not -Match '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}' -Because "Consumption ResourceId must not contain a real subscription GUID"
            }
        }
    }

    It "Should have obfuscated ResourceUri inside InstanceData JSON" {
        if ($null -eq $script:ConsumptionFile) { Set-ItResult -Skipped -Because "no consumption file in fixture"; return }
        $Csv = Import-Csv $script:ConsumptionFile.FullName
        if ($Csv.Count -eq 0) { Set-ItResult -Skipped -Because "empty consumption csv"; return }

        foreach ($row in $Csv)
        {
            if (![string]::IsNullOrEmpty($row.InstanceData))
            {
                $InstanceData = $row.InstanceData | ConvertFrom-Json
                $Uri = $InstanceData.'Microsoft.Resources'.ResourceUri
                if (![string]::IsNullOrEmpty($Uri))
                {
                    $Uri | Should -Match $script:MaskedIdPattern -Because "InstanceData ResourceUri '$Uri' should be a masked ARM path"
                    $Uri | Should -Not -Match '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}' -Because "InstanceData ResourceUri must not contain a real subscription GUID"
                }
            }
        }
    }
}

# ============================================================
# 11. Obfuscation prefix consistency (no plain GUIDs)
# ============================================================
Describe "Obfuscation Prefix Consistency" {
    It "Should use prod_ or nonprod_ prefix on all IDs (not plain GUIDs)" {
        $PlainGuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        foreach ($resource in $script:AllResources)
        {
            if ($null -ne $resource.ID)
            {
                $resource.ID | Should -Not -Match $PlainGuidPattern -Because "ID should have prod_/nonprod_ prefix"
            }
        }
    }
}

# ============================================================
# 12. Valid metrics JSON structure
# ============================================================
Describe "Metrics JSON Structure" {
    It "Should have valid metrics JSON with a Metrics array property" {
        foreach ($metricsFile in $script:MetricsFiles)
        {
            $Raw = Get-Content $metricsFile.FullName -Raw
            $Parsed = $Raw | ConvertFrom-Json
            $Parsed | Should -Not -BeNullOrEmpty -Because "Metrics file should be valid JSON"
            $Parsed.PSObject.Properties.Name | Should -Contain 'Metrics' -Because "Metrics JSON should have a Metrics property"
            # Downstream drops the whole file unless Metrics is a list (an empty
            # list is fine).
            ($Raw -match '"Metrics"\s*:\s*\[') | Should -BeTrue -Because "the Metrics property must be a list in '$($metricsFile.Name)'"
        }
    }
}

# ============================================================
# 13. Consumption CSV has valid headers
# ============================================================
Describe "Consumption CSV Headers" {
    It "Should have a consumption CSV with the correct header columns" {
        if ($null -eq $script:ConsumptionFile)
        {
            Set-ItResult -Skipped -Because "No consumption CSV in this report"
            return
        }
        $FirstLine = Get-Content $script:ConsumptionFile.FullName -TotalCount 1
        if ([string]::IsNullOrEmpty($FirstLine))
        {
            Set-ItResult -Skipped -Because "Consumption CSV is empty (no usage data in this subscription)"
            return
        }

        $ExpectedHeaders = @('InstanceData', 'MeterCategory', 'MeterId', 'MeterName', 'MeterRegion', 'MeterSubCategory', 'Quantity', 'Unit', 'UsageStartTime', 'UsageEndTime', 'ResourceId', 'ResourceLocation', 'ConsumptionMeter', 'ReservationId', 'ReservationOrderId')
        # Downstream finds each column by its exact name, so the header is
        # parsed and compared name by name.
        $Columns = @(($FirstLine | ConvertFrom-Csv -Header (1..200 | ForEach-Object { "c$_" })).PSObject.Properties | Where-Object { $null -ne $_.Value } | ForEach-Object { [string]$_.Value })
        foreach ($header in $ExpectedHeaders)
        {
            $Columns | Should -Contain $header -Because "CSV should contain header '$header' as a column name"
        }
    }
}

# ============================================================
# 14. No Azure tenant IDs leaked
# ============================================================
Describe "Tenant ID Leak Check" {
    It "Should not contain Azure tenant ID patterns in output files" {
        # Tenant IDs appear as: "tenantId":"<guid>" or tenantID
        $TenantPattern = '"tenant[Ii][Dd]"\s*:\s*"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'
        foreach ($fileName in $script:AllContent.Keys)
        {
            $script:AllContent[$fileName] | Should -Not -Match $TenantPattern -Because "File '$fileName' should not contain tenant IDs"
        }
    }
}

# ============================================================
# NON-OBFUSCATED MODE SAFETY NET
# This test catches guard pattern bugs where obfuscation
# logic fires even when -Obfuscate is not set.
# ============================================================
Describe "Non-Obfuscated Mode Safety" {
    BeforeAll {
        $script:NonObfZip = $env:TEST_NOOBF_ZIP_PATH
        if ($script:NonObfZip -and (Test-Path $script:NonObfZip))
        {
            $script:NoObfExtract = Join-Path ([System.IO.Path]::GetTempPath()) "NoObfTest_$([guid]::NewGuid().ToString().Substring(0,8))"
            New-Item -ItemType Directory -Path $script:NoObfExtract -Force | Out-Null
            Expand-Archive -Path $script:NonObfZip -DestinationPath $script:NoObfExtract -Force
            $script:NoObfContent = @{}
            Get-ChildItem -Path $script:NoObfExtract -File | ForEach-Object {
                $script:NoObfContent[$_.Name] = Get-Content $_.FullName -Raw
            }
        }
    }

    AfterAll {
        if ($script:NoObfExtract -and (Test-Path $script:NoObfExtract))
        {
            Remove-Item -Path $script:NoObfExtract -Recurse -Force
        }
    }

    It "Should not contain 'obfuscated' in any output file when run without -Obfuscate" {
        if (-not $script:NoObfContent)
        {
            Set-ItResult -Skipped -Because "No non-obfuscated zip provided"
            return
        }
        foreach ($file in $script:NoObfContent.Keys)
        {
            if ($file -like "Transcript_*") { continue }
            $script:NoObfContent[$file] | Should -Not -Match 'obfuscated' -Because "File '$file' should contain real data, not obfuscated placeholders"
        }
    }

    It "Should not contain obfuscation GUID patterns in non-obfuscated output" {
        if (-not $script:NoObfContent)
        {
            Set-ItResult -Skipped -Because "No non-obfuscated zip provided"
            return
        }
        $GuidPattern = '(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        foreach ($file in $script:NoObfContent.Keys)
        {
            $script:NoObfContent[$file] | Should -Not -Match $GuidPattern -Because "File '$file' should not contain obfuscation GUIDs"
        }
    }
}
Describe "Cross-Reference Field Obfuscation" {
    # Helper: field should be obfuscated, null, or a safe non-ID value like 'None' or 'obfuscated'
    BeforeAll {
        $script:SafePattern = '^((prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|None|obfuscated)$'
        $script:AzureIdPattern = '/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}'
    }

    It "AppServices: ServerFarmId should be obfuscated or null" {
        $Resources = @($script:Inventory.AppServices) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no AppServices resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ServerFarmId))
            {
                $r.ServerFarmId | Should -Not -Match $script:AzureIdPattern -Because "ServerFarmId should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AppServices had a non-null ServerFarmId in this fixture" }
    }

    It "VirtualMachines: Set (VMSS ID) should be obfuscated or null" {
        $Resources = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no VirtualMachines resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.Set))
            {
                $r.Set | Should -Match $script:MaskedIdPattern -Because "VMSS Set ID '$($r.Set)' should be a masked ARM path"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no VirtualMachines had a non-null Set (VMSS ID) in this fixture" }
    }

    It "VirtualMachines: Tags keys are preserved and values are obfuscated when obfuscated" {
        $ObfPattern = '^(prod|nonprod)_'
        $Resources = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no VirtualMachines resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and $null -ne $r.Tags)
            {
                foreach ($tag in @($r.Tags))
                {
                    if ($null -ne $tag -and -not [string]::IsNullOrEmpty([string]$tag.Value))
                    {
                        # Key (Name) is kept verbatim; value must be a prod_/nonprod_ token.
                        $tag.Name  | Should -Not -BeNullOrEmpty -Because "tag keys are preserved for analytics"
                        $tag.Value | Should -Match $ObfPattern -Because "tag values must be obfuscated, not raw"
                        $Checked++
                    }
                }
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no VirtualMachines had a tag with a non-empty value in this fixture" }
    }

    It "Purview: CreatedBy is obfuscated (tokenized, never raw identity)" {
        $Resources = @($script:Inventory.Purview) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no Purview resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.CreatedBy))
            {
                $r.CreatedBy | Should -Match '^(prod|nonprod)_' -Because "CreatedBy contains user identity and must be obfuscated to a token, never raw"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no Purview had a non-null CreatedBy in this fixture" }
    }

    It "SQLDB: DatabaseServer should not contain raw resource names" {
        $Resources = @($script:Inventory.SQLDB) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLDB resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.DatabaseServer))
            {
                $r.DatabaseServer | Should -Not -Match $script:AzureIdPattern -Because "DatabaseServer should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLDB had a non-null DatabaseServer in this fixture" }
    }

    It "SQLDB: ElasticPoolID should be obfuscated or 'None'" {
        $Resources = @($script:Inventory.SQLDB) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLDB resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ElasticPoolID))
            {
                $r.ElasticPoolID | Should -Not -Match $script:AzureIdPattern -Because "ElasticPoolID should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLDB had a non-null ElasticPoolID in this fixture" }
    }

    It "SQLMI: InstancePoolName should not contain raw resource IDs" {
        $Resources = @($script:Inventory.SQLMI) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLMI resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.InstancePoolName))
            {
                $r.InstancePoolName | Should -Not -Match $script:AzureIdPattern -Because "InstancePoolName should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLMI had a non-null InstancePoolName in this fixture" }
    }

    It "SQLMIDB: ManagedInstance should be obfuscated or null" {
        $Resources = @($script:Inventory.SQLMIDB) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLMIDB resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ManagedInstance))
            {
                $r.ManagedInstance | Should -Not -Match $script:AzureIdPattern -Because "ManagedInstance should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLMIDB had a non-null ManagedInstance in this fixture" }
    }

    It "PublicIP: AssociatedResource should not contain raw resource names" {
        $Resources = @($script:Inventory.PublicIP) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no PublicIP resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.AssociatedResource) -and $r.AssociatedResource -ne 'None')
            {
                $r.AssociatedResource | Should -Not -Match $script:AzureIdPattern -Because "AssociatedResource should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no PublicIP had a non-null/non-'None' AssociatedResource in this fixture" }
    }

    It "VMDisk: AssociatedResource should be obfuscated or null" {
        $Resources = @($script:Inventory.VMDisk) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no VMDisk resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.AssociatedResource))
            {
                $r.AssociatedResource | Should -Not -Match $script:AzureIdPattern -Because "Disk AssociatedResource should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no VMDisk had a non-null AssociatedResource in this fixture" }
    }

    It "ComputeSnapshots: SourceResourceId should be obfuscated or null" {
        $Resources = @($script:Inventory.ComputeSnapshots) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no ComputeSnapshots resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.SourceResourceId))
            {
                $r.SourceResourceId | Should -Not -Match $script:AzureIdPattern -Because "SourceResourceId should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no ComputeSnapshots had a non-null SourceResourceId in this fixture" }
    }

    It "AVD: HostId should be obfuscated or null" {
        $Resources = @($script:Inventory.AVD) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no AVD resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.HostId))
            {
                $r.HostId | Should -Not -Match $script:AzureIdPattern -Because "AVD HostId should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AVD had a non-null HostId in this fixture" }
    }

    It "AVD: Hostname should be obfuscated or null" {
        $Resources = @($script:Inventory.AVD) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no AVD resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.Hostname))
            {
                $r.Hostname | Should -Not -Match $script:AzureIdPattern -Because "AVD Hostname should not contain raw Azure resource ID"
                $r.Hostname | Should -Match $script:ObfuscationPattern -Because "AVD Hostname should be obfuscated"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AVD had a non-null Hostname in this fixture" }
    }

    It "AVD: Hostname should differ from HostId" {
        $Resources = @($script:Inventory.AVD) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no AVD resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.Hostname) -and ![string]::IsNullOrEmpty($r.HostId))
            {
                $r.Hostname | Should -Not -Be $r.HostId -Because "Hostname and HostId should be different obfuscated values"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AVD had both a non-null Hostname and HostId in this fixture" }
    }

    It "MachineLearning: StorageAccount should be obfuscated or null" {
        $Resources = @($script:Inventory.MachineLearning) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no MachineLearning resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.StorageAccount))
            {
                $r.StorageAccount | Should -Not -Match $script:AzureIdPattern -Because "ML StorageAccount should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no MachineLearning had a non-null StorageAccount in this fixture" }
    }

    It "MachineLearning: KeyVault should be obfuscated or null" {
        $Resources = @($script:Inventory.MachineLearning) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no MachineLearning resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.KeyVault))
            {
                $r.KeyVault | Should -Not -Match $script:AzureIdPattern -Because "ML KeyVault should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no MachineLearning had a non-null KeyVault in this fixture" }
    }

    It "Databricks: ManagedResourceGroup should be obfuscated or null" {
        $Resources = @($script:Inventory.Databricks) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no Databricks resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.ManagedResourceGroup))
            {
                $r.ManagedResourceGroup | Should -BeIn @('obfuscated') -Because "Databricks ManagedResourceGroup should be obfuscated"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no Databricks had a non-null ManagedResourceGroup in this fixture" }
    }

    It "Databricks: StorageAccount should be obfuscated or null" {
        $Resources = @($script:Inventory.Databricks) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no Databricks resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.StorageAccount))
            {
                $r.StorageAccount | Should -BeIn @('obfuscated') -Because "Databricks StorageAccount should be obfuscated"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no Databricks had a non-null StorageAccount in this fixture" }
    }

    It "Purview: FriendlyName is obfuscated (tokenized, never raw)" {
        $Resources = @($script:Inventory.Purview) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no Purview resources in this fixture"; return }
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.FriendlyName))
            {
                $r.FriendlyName | Should -Match '^(prod|nonprod)_' -Because "Purview FriendlyName must be obfuscated to a token, never raw"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no Purview had a non-null FriendlyName in this fixture" }
    }

    It "Frontdoor: WebApplicationFirewall should be obfuscated or a known marker" {
        $Resources = @($script:Inventory.FRONTDOOR) | Where-Object { $null -ne $_ }
        if ($Resources.Count -eq 0) { Set-ItResult -Skipped -Because "no FRONTDOOR resources in this fixture"; return }
        # Skip known non-ID markers: 'False' (Classic, no WAF), 'Unknown' (Std/Premium,
        # not detectable from the profile). Any remaining value must not leak an Azure path.
        $Checked = 0
        foreach ($r in $Resources)
        {
            if ($null -ne $r -and ![string]::IsNullOrEmpty($r.WebApplicationFirewall) -and $r.WebApplicationFirewall -notin @('False', 'Unknown'))
            {
                $r.WebApplicationFirewall | Should -Not -Match $script:AzureIdPattern -Because "Frontdoor WAF should not contain raw Azure resource ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no FRONTDOOR had a non-null WebApplicationFirewall value outside the known 'False'/'Unknown' markers in this fixture" }
    }
}

# ============================================================
# 16. Dictionary file excluded from zip
# ============================================================
Describe "Dictionary File Exclusion" {
    It "Should not contain the obfuscation dictionary in the zip" {
        $DictFiles = $script:AllFiles | Where-Object { $_.Name -like "ObfuscationDictionary_*" }
        $DictFiles | Should -BeNullOrEmpty -Because "Dictionary file should stay local, not in the zip"
    }
}

# ============================================================
# 16b. Full (raw) resource dump excluded from zip
# The -Obfuscate run also writes a LOCAL Full_<ReportName>_<timestamp>.json
# ($Global:AllResourceFile) that holds the RAW, un-obfuscated resource dump.
# The packaging step's json filter excludes BOTH ObfuscationDictionary_* and
# Full_* from the shipped ZIP (ResourceInventory.ps1). The Dictionary
# File Exclusion block above guards the dictionary; this guards the Full_*
# dump: the other local-only artifact whose presence would leak every real
# identifier for every obfuscated dimension. Count-independent; asserts the
# shared ZIP carries no Full_* member.
# ============================================================
Describe "Full Resource Dump Exclusion" {
    It "Should not contain the raw Full_* resource dump in the zip" {
        $FullDumpFiles = $script:AllFiles | Where-Object { $_.Name -like "Full_*" }
        $FullDumpFiles | Should -BeNullOrEmpty -Because "Full_* raw resource dump should stay local, not in the shared zip"
    }
}

# ============================================================
# 17. Obfuscation determinism
# Within a single run, the same real value must always map to the
# SAME token. The obfuscated zip alone carries no real values, so
# determinism is asserted against the reverse-lookup dictionary
# (token -> real value): if any real value were reachable from two
# DISTINCT tokens, the same input would have produced two outputs,
# breaking determinism. This is the "all resources in one RG share
# one RG token" invariant. Skips gracefully when no dictionary
# fixture is available; count-independent (iterates whatever tokens
# the run produced).
# ============================================================
Describe "Obfuscation Determinism" {
    It "ResourceGroup: each real resource group maps to exactly one token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.ResourceGroupMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "ResourceGroupMap absent/empty in this dictionary"; return }
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) if ($v -match '/resourceGroups/([^/]+)') { $Matches[1] } }
        $Violations | Should -BeNullOrEmpty -Because "no real resource group may yield two different tokens within a run"
    }

    It "Subscription: each real subscription maps to exactly one token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.SubscriptionMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "SubscriptionMap absent/empty in this dictionary"; return }
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) if ($v -match '/subscriptions/([0-9a-fA-F-]+)') { $Matches[1] } }
        $Violations | Should -BeNullOrEmpty -Because "no real subscription may yield two different tokens within a run"
    }

    It "ResourceId: each real resource id maps to exactly one token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.ResourceIdMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "ResourceIdMap absent/empty in this dictionary"; return }
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v }
        $Violations | Should -BeNullOrEmpty -Because "no real resource id may yield two different tokens within a run"
    }

    It "ResourceName: each real resource id maps to exactly one name token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.ResourceNameMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "ResourceNameMap absent/empty in this dictionary"; return }
        # Name tokens are keyed per real resource id (two resources sharing a
        # display name in different RGs legitimately get different name tokens),
        # so determinism is asserted against the real resource id, not the name.
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v }
        $Violations | Should -BeNullOrEmpty -Because "no real resource id may yield two different name tokens within a run"
    }

    It "Tag: each real tag value maps to exactly one token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.TagMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "TagMap absent/empty in this dictionary"; return }
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v } -CaseSensitive
        $Violations | Should -BeNullOrEmpty -Because "no real tag value may yield two different tokens within a run"
    }

    It "FreeText: each real free-text value maps to exactly one token" {
        if (-not $script:DictionaryAvailable) { Set-ItResult -Skipped -Because "No ObfuscationDictionary fixture available; set `$env:TEST_DICT_PATH"; return }
        $Map = $script:Dictionary.FreeTextMap
        if ($null -eq $Map -or @($Map.PSObject.Properties).Count -eq 0) { Set-ItResult -Skipped -Because "FreeTextMap absent/empty in this dictionary"; return }
        $Violations = Get-DeterminismViolation -Map $Map -RealValueSelector { param($v) $v } -CaseSensitive
        $Violations | Should -BeNullOrEmpty -Because "no real free-text value may yield two different tokens within a run"
    }
}

# ============================================================
# 19. Tag tokenization: keys kept, values masked, determinism,
#     and the mixed-case tag-key regression.
#
# The ZIP-content VM Tags test (above) and the TagMap determinism test
# are the
# authoritative checks WHEN the fixture carries tagged resources. They are
# DATA-DEPENDENT: this fixture's in-scope resources carried no tags, so TagMap
# is empty (those blocks skip) and the VM Tags loop has no rows to assert
# against (documented fixture limitation: the dictionary is NOT fabricated).
#
# To cover tag keys, values and their dictionary without weakening anything
# above, this block adds two fixture-independent layers:
#   1. ResourceInventory.ps1's own tag tokenizer (Invoke-TagObfuscation, taken
#      from the source) run on a representative structured Tags hashtable with
#      MIXED-CASE keys: the same shape the collectors produce
#      ($obj = @{ ...; Tags = ... }).
#      Asserts keys survive verbatim, values become prod_/nonprod_ tokens,
#      the same value yields the same token, and the structured Tags is NOT
#      nulled/dropped.
#   2. A SOURCE-AUDIT regression that genuinely fails if the lowercase /
#      case-sensitive tag scrub bug were reintroduced into ResourceInventory.ps1
#      The malformed-row scrub must clear BOTH the 'tags' and 'Tags' key
#      variants (case-insensitive), the structured-tag obfuscation must be
#      guarded by ContainsKey('Tags') and reassign only $tag.Value, and
#      $tag.Name must never be reassigned (key kept verbatim).
# ============================================================
Describe "Tag Tokenization: keys kept, values masked, mixed-case regression" {
    BeforeAll {
        $script:TagTokenPattern = '^(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        $script:RiSourcePath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'ResourceInventory.ps1'
    }

    It "keeps mixed-case tag KEYS verbatim and masks VALUES to tokens" {
        # Mixed-case keys on purpose (Environment / CostCenter / Owner) to guard
        # the case-insensitive handling. Values are synthetic only (no real ids).
        $ResourceItem = @{
            ID   = 'prod_' + [guid]::NewGuid().ToString()
            Tags = @(
                [PSCustomObject]@{ Name = 'Environment'; Value = 'production' }
                [PSCustomObject]@{ Name = 'CostCenter'; Value = 'finance-ops' }
                [PSCustomObject]@{ Name = 'Owner'; Value = 'platform-team' }
            )
        }
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'

        script:Invoke-TagObfuscation -ResourceItem $ResourceItem -TagValueDictionary $Dict

        # 4.5: structured Tags survives (not nulled / not dropped by a scrub)
        $ResourceItem.Tags | Should -Not -BeNullOrEmpty -Because "structured Tags must survive tokenization, not be nulled"
        @($ResourceItem.Tags).Count | Should -Be 3 -Because "no tag row may be dropped by a mixed-case scrub"

        $ExpectedKeys = @('Environment', 'CostCenter', 'Owner')
        for ($i = 0; $i -lt 3; $i++)
        {
            # 4.1: key kept verbatim, including its original mixed casing
            $ResourceItem.Tags[$i].Name  | Should -BeExactly $ExpectedKeys[$i] -Because "tag KEY '$($ExpectedKeys[$i])' must be preserved verbatim, casing intact"
            # 4.2: value replaced with a prod_/nonprod_ token
            $ResourceItem.Tags[$i].Value | Should -Match $script:TagTokenPattern -Because "tag VALUE must be a prod_/nonprod_ token, not raw"
        }
    }

    It "emits the SAME token for the same tag value across resources" {
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $ItemA = @{ ID = 'a'; Tags = @([PSCustomObject]@{ Name = 'Env'; Value = 'shared-value' }) }
        $ItemB = @{ ID = 'b'; Tags = @([PSCustomObject]@{ Name = 'Tier'; Value = 'shared-value' }) }

        script:Invoke-TagObfuscation -ResourceItem $ItemA -TagValueDictionary $Dict
        script:Invoke-TagObfuscation -ResourceItem $ItemB -TagValueDictionary $Dict

        $ItemA.Tags[0].Value | Should -Be $ItemB.Tags[0].Value -Because "the same real tag value must map to one token within a run"
    }

    It "derives the prod/nonprod prefix from the tag VALUE" {
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Item = @{
            ID   = 'x'
            Tags = @(
                [PSCustomObject]@{ Name = 'Stage'; Value = 'qa' }           # non-prod set member
                [PSCustomObject]@{ Name = 'Stage'; Value = 'core-billing' } # neutral -> prod
            )
        }
        script:Invoke-TagObfuscation -ResourceItem $Item -TagValueDictionary $Dict
        $Item.Tags[0].Value | Should -Match '^nonprod_' -Because "'qa' matches the non-prod set"
        $Item.Tags[1].Value | Should -Match '^prod_'    -Because "'core-billing' is neutral -> prod"
    }

    It "records each token -> real tag value mapping so TagMap can be inverted" {
        # TagMap is built by inverting $Global:TagValueDictionary
        # (ResourceInventory.ps1). Assert the dictionary this loop
        # populates carries the real value under the emitted token, which is
        # exactly what the inversion serializes into TagMap.
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Item = @{ ID = 'y'; Tags = @([PSCustomObject]@{ Name = 'Team'; Value = 'analytics-platform' }) }

        script:Invoke-TagObfuscation -ResourceItem $Item -TagValueDictionary $Dict

        $Token = $Item.Tags[0].Value
        $Dict.ContainsKey('analytics-platform') | Should -BeTrue -Because "the real tag value must be keyed in the dictionary that TagMap inverts"
        $Dict['analytics-platform'] | Should -Be $Token -Because "token <-> real value must round-trip through TagMap"
    }

    # ---- Source-audit regression: the mixed-case / lowercase-scrub bug ----
    # Reads the shipped source and fails if the case-insensitive tag handling is
    # regressed. This is the assertion that genuinely guards the already-fixed
    # bug: if a future edit reintroduced a lowercase-only / case-sensitive scrub
    # that nulled structured Tags, one of these fails.
    Context "Source case-insensitive tag handling" {
        BeforeAll {
            $script:RiSourcePresent = Test-Path $script:RiSourcePath
            $script:RiSource = if ($script:RiSourcePresent) { Get-Content $script:RiSourcePath -Raw } else { '' }
        }

        It "ResourceInventory.ps1 is present for source audit" {
            $script:RiSourcePresent | Should -BeTrue -Because "the regression audits the shipped obfuscation source"
        }

        It "malformed-row scrub clears BOTH 'tags' and 'Tags' key variants (case-insensitive)" {
            # The mixed-case bug was a case-sensitive scrub. -cmatch is
            # case-SENSITIVE, and these anchor on the SCRUB ASSIGNMENT STATEMENT
            # ($resourceItem.<case>.tags/Tags = $null), which is unique to the
            # malformed-row path: the bare ContainsKey('Tags') token
            # also appears at the tag obfuscation guard, so matching the token
            # alone would be a false guard. Dropping either case variant
            # (reintroducing a lowercase-only / case-sensitive scrub) fails here.
            ($script:RiSource -cmatch '\$resourceItem\.tags = \$null') | Should -BeTrue -Because "lowercase tag key variant must be scrubbed on the malformed-row path"
            ($script:RiSource -cmatch '\$resourceItem\.Tags = \$null') | Should -BeTrue -Because "PascalCase tag key variant must be scrubbed on the malformed-row path"
        }

        It "structured-tag obfuscation is guarded by ContainsKey('Tags') and tokenizes in place" {
            ($script:RiSource -cmatch "ContainsKey\('Tags'\) -and") | Should -BeTrue -Because "structured Tags must be tokenized in place, never scrubbed to null"
            $script:RiSource | Should -Match '\$tag\.Value = \$Global:TagValueDictionary' -Because "the tag VALUE is what gets tokenized"
        }

        It "never reassigns a tag KEY (`$tag.Name), so keys are kept verbatim" {
            $script:RiSource | Should -Not -Match '\$tag\.Name\s*=[^=]' -Because "tag KEYS must be preserved verbatim; reassigning `$tag.Name would rewrite a key"
        }
    }
}

# ============================================================
# 20. AKS multi-node-pool Tags: no shared-reference aliasing
# Regression for a real bug found in this session: Services/Containers/AKS.ps1
# emits one row per node pool for a cluster (foreach ($2 in
# $data.agentPoolProfiles)). The 'Tags' field must carry each cluster's real
# tag values into EVERY one of that cluster's rows, but if the Select-Object
# projection that builds 'Tags' were hoisted OUTSIDE that inner loop, every row
# would share the SAME Tags array/element object instances. The obfuscation
# pass in ResourceInventory.ps1 mutates $tag.Value IN PLACE
# ($tag.Value = $Global:TagValueDictionary[$realTagValue]); with aliased
# objects, row 1's mutation is visible to row 2, so row 2 re-reads an
# already-tokenized value as if it were "real" and re-keys it into
# $Global:TagValueDictionary: corrupting the dictionary (one real value
# mapped under two dictionary keys) and breaking TagMap. This test invokes
# the ACTUAL collector (not a
# mirror) against a synthetic two-node-pool cluster and proves: (a) the
# collector does not hand back the same Tags object instance across rows, and
# (b) running the real tag-obfuscation loop over the collector's output
# produces exactly ONE dictionary entry for the one real tag value, with both
# rows resolving to the SAME token.
# ============================================================
Describe "AKS Multi-Node-Pool Tags: no cross-row aliasing" {
    BeforeAll {
        # Minimal synthetic managedClusters resource with TWO node pools and
        # ONE real tag value shared by the whole cluster. No real identifiers.
        $script:AksCluster = [PSCustomObject]@{
            id             = 'prod_' + [guid]::NewGuid().ToString()
            RESOURCEGROUP  = 'rg-aks-regress'
            NAME           = 'aks-regress'
            LOCATION       = 'eastus'
            TYPE           = 'microsoft.containerservice/managedclusters'
            subscriptionId = 'sub-regress'
            sku            = [PSCustomObject]@{ name = 'Base'; tier = 'Free' }
            tags           = [PSCustomObject]@{ environment = 'dev' }
            PROPERTIES     = [PSCustomObject]@{
                kubernetesVersion = '1.29'
                networkProfile    = [PSCustomObject]@{ loadBalancerSku = 'Standard' }
                agentPoolProfiles = @(
                    [PSCustomObject]@{ name = 'nodepool1'; type = 'VirtualMachineScaleSets'; mode = 'System'; osType = 'Linux'; vmSize = 'Standard_B2s'; osDiskSizeGB = 30; count = 1; maxPods = 30; orchestratorVersion = '1.29' }
                    [PSCustomObject]@{ name = 'nodepool2'; type = 'VirtualMachineScaleSets'; mode = 'User'; osType = 'Linux'; vmSize = 'Standard_B2s'; osDiskSizeGB = 30; count = 1; maxPods = 30; orchestratorVersion = '1.29' }
                )
            }
        }
        $script:AksSub = @([PSCustomObject]@{ id = 'sub-regress'; Name = 'sub-regress' })
        $script:AksModule = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Containers', 'AKS.ps1'
    }

    It "AKS.ps1 module file is present for direct invocation" {
        Test-Path $script:AksModule | Should -BeTrue
    }

    It "emits one row per node pool, each with its OWN Tags object instance (no aliasing)" {
        $Rows = & $script:AksModule -Sub $script:AksSub -Resources @($script:AksCluster) -Task 'Processing' -ResourceIdDictionary $null
        @($Rows).Count | Should -Be 2 -Because "one row per node pool"
        [object]::ReferenceEquals($Rows[0].Tags, $Rows[1].Tags) | Should -BeFalse -Because "each node-pool row must get its own Tags object instance, not a shared reference"
    }

    It "the real tag-obfuscation loop yields exactly ONE dictionary entry and ONE shared token across both rows" {
        $Rows = & $script:AksModule -Sub $script:AksSub -Resources @($script:AksCluster) -Task 'Processing' -ResourceIdDictionary $null
        $Dict = New-Object 'System.Collections.Generic.Dictionary[string,string]'

        # Run ResourceInventory.ps1's own tag tokenizer once per row, exactly
        # as production does.
        foreach ($ResourceItem in $Rows) { Invoke-TagObfuscation -ResourceItem $ResourceItem -TagValueDictionary $Dict }

        # injectivity: exactly one real value went in, so exactly one entry
        # must come out. A count of 2 here is the aliasing bug's signature (the
        # already-tokenized value on row 2 gets misread as a second "real" value).
        $Dict.Count | Should -Be 1 -Because "one real tag value must yield exactly one dictionary entry, even across multiple node-pool rows for the same cluster"

        # determinism across rows: both rows' tag must resolve to the SAME
        # token, and that token must actually be present as a dictionary value.
        $Rows[0].Tags[0].Value | Should -Be $Rows[1].Tags[0].Value -Because "the same real tag value on two rows of the same cluster must yield the same token"
        $Dict.Values | Should -Contain $Rows[0].Tags[0].Value -Because "the shared token must be the one real dictionary entry produced, not a spurious second entry"
    }
}
