# Reveal-Obfuscation.ps1 unit tests
# =============================================================================
# Offline, self-contained tests for the partial-reveal helper. They build a
# synthetic obfuscated report bundle (Inventory JSON + Consumption CSV) and a
# matching ObfuscationDictionary fixture in a temp dir, zip it like an
# -Obfuscate run would, then run Reveal-Obfuscation.ps1 against it and assert:
#   - selected dimensions (Resource Group, Subscription name) are revealed,
#     including the Resource-Group-name parsing edge cases (AKS MC_ managed
#     groups, casing preserved) that the reveal tool shares
#   - UNSELECTED dimensions (Resource Id, Resource Name, and tag values unless
#     -Fields Tag is passed) stay masked
#   - the rewritten members are still valid (JSON parses, CSV columns intact
#     even when a revealed value contains a comma), and the literal 'obfuscated'
#     sentinel is left untouched
#   - older dictionaries (no SubscriptionNameMap) fall back to the sub GUID, and
#     -Fields Tag is a no-op when the dictionary has no TagMap
#   - the dictionary auto-discovers via -SearchDirectory, and the source zip is
#     never mutated
#
# The obfuscated tokens are generated at runtime as 'prod_'/'nonprod_' + a fresh
# GUID, so the tool's token regex matches them while no real GUID literal lives
# in this source file. The only literal GUID is the Azure docs placeholder used
# inside the synthetic ARM paths. No customer data.
# =============================================================================

BeforeAll {
    # The single-report reveal engine now lives in Reveal.ps1 (single mode), which
    # delegates to Invoke-RdaReveal. Reveal.ps1's single param set accepts the same
    # arguments the former standalone Reveal-Obfuscation.ps1 did (-InputZip,
    # -DictionaryPath, -SearchDirectory, -Fields, -All, -OutputZip), so every
    # invocation below drives it unchanged.
    $script:RevealScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Reveal.ps1'
    if (-not (Test-Path $script:RevealScript))
    {
        throw "Reveal.ps1 not found at $script:RevealScript"
    }

    $SubGuid = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $Base = "/subscriptions/$SubGuid/resourceGroups"

    # Runtime-generated obfuscated tokens (GUID-shaped so the tool matches them).
    $script:TokId = 'prod_' + [guid]::NewGuid().ToString()
    $script:TokName = 'prod_' + [guid]::NewGuid().ToString()
    $script:TokSub = 'prod_' + [guid]::NewGuid().ToString()
    $script:TokRg = 'nonprod_' + [guid]::NewGuid().ToString()
    $script:TokRgAks = 'prod_' + [guid]::NewGuid().ToString()
    $script:TokRgCase = 'prod_' + [guid]::NewGuid().ToString()
    $script:TokTag = 'prod_' + [guid]::NewGuid().ToString()
    $script:TokFree = 'prod_' + [guid]::NewGuid().ToString()
    $script:TokFabName = 'prod_' + [guid]::NewGuid().ToString()

    # Real values behind the tokens. Subscription name deliberately contains a
    # comma and an ampersand to exercise CSV quoting and HTML encoding.
    $script:RealRgName = 'rg-app'
    $script:RealRgAks = 'MC_rg-aks_aks01_eastus'   # AKS managed RG
    $script:RealRgCase = 'RG-APP'                   # casing must be preserved
    $script:RealSubName = 'Contoso, Inc. (Prod) & Co'
    $script:RealTagVal = 'payments'
    $script:RealFreeText = 'data-platform workspace for the analytics team'

    $IdVm = "$Base/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"
    $IdAks = "$Base/$($script:RealRgAks)/providers/Microsoft.Compute/virtualMachines/aksnode0"
    $IdCase = "$Base/$($script:RealRgCase)/providers/Microsoft.Storage/storageAccounts/sa01"
    $script:IdFabric = "$Base/$($script:RealRgName)/providers/Microsoft.Fabric/capacities/capdata01"

    # ---- Dictionary fixture (current shape: has SubscriptionNameMap + TagMap) ----
    $Dict = [ordered]@{
        GeneratedAt         = '2026-06-30 00:00:00'
        ResourceIdMap       = [ordered]@{ $script:TokId = $IdVm }
        ResourceNameMap     = [ordered]@{ $script:TokName = $IdVm; $script:TokFabName = $script:IdFabric }
        SubscriptionMap     = [ordered]@{ $script:TokSub = $IdVm }
        ResourceGroupMap    = [ordered]@{
            $script:TokRg     = $IdVm
            $script:TokRgAks  = $IdAks
            $script:TokRgCase = $IdCase
        }
        SubscriptionNameMap = [ordered]@{ $script:TokSub = $script:RealSubName }
        TagMap              = [ordered]@{ $script:TokTag = $script:RealTagVal }
        FreeTextMap         = [ordered]@{ $script:TokFree = $script:RealFreeText }
    }

    # ---- Synthetic obfuscated report members ----
    # vm01 carries the full set of dimensions; vmAks/vmCase exercise the two RG
    # name-parsing edge cases. A literal 'obfuscated' sentinel (out-of-scope
    # cross-ref) sits on vm01 and must survive untouched.
    $Inventory = [ordered]@{
        VirtualMachines = @(
            [ordered]@{
                ID            = $script:TokId
                Name          = $script:TokName
                Subscription  = $script:TokSub
                ResourceGroup = $script:TokRg
                Set           = 'obfuscated'
                Description   = $script:TokFree
                Tags          = @( [ordered]@{ Name = 'environment'; Value = $script:TokTag } )
            }
            [ordered]@{
                ID            = $script:TokId
                Name          = $script:TokName
                Subscription  = $script:TokSub
                ResourceGroup = $script:TokRgAks
            }
            [ordered]@{
                ID            = $script:TokId
                Name          = $script:TokName
                Subscription  = $script:TokSub
                ResourceGroup = $script:TokRgCase
            }
        )
        # A Microsoft Fabric capacity row: its nested AirflowJobs hold only fixed words and numbers.
        FabricCapacities = @(
            [ordered]@{
                # An ARM-shaped masked id, as -Obfuscate writes it (the contract's shape): token parts in a real path.
                ID            = "/subscriptions/$($script:TokSub)/resourcegroups/$($script:TokRg)/providers/microsoft.fabric/capacities/$($script:TokFabName)"
                Name          = $script:TokFabName
                Subscription  = $script:TokSub
                ResourceGroup = $script:TokRg
                Location      = 'northeurope'
                SKU           = 'F64'
                ActiveHours   = 696
                AirflowStatus = 'Collected'
                AirflowJobs   = @( [ordered]@{ NodeSize = 'Large'; ShutdownPolicy = 'AlwaysOn'; MinNodeCount = 5; MaxNodeCount = 5 } )
            }
        )
    }

    # Consumption CSV with the sub + rg tokens embedded inside an ARM-path field
    # (where the subscription token stands for the subscription id) and the sub
    # token on its own (the comma-bearing display name), so revealing it must
    # not break columns.
    $ConsumptionRows = @(
        [pscustomobject]@{
            InstanceId   = "/subscriptions/$($script:TokSub)/resourceGroups/$($script:TokRg)/providers/Microsoft.Compute/virtualMachines/vm01"
            Subscription = $script:TokSub
            Cost         = '12.34'
        }
    )

    $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("RevealTest_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null

    $StageDir = Join-Path $script:TmpDir 'stage'
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
    $Inventory | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $StageDir 'Inventory_Test.json') -Encoding utf8
    $ConsumptionRows | Export-Csv -Path (Join-Path $StageDir 'Consumption_Test.csv') -NoTypeInformation -Encoding utf8
    # A tiny HTML member so the tool's HTML-encode escape branch is exercised:
    # the revealed subscription name carries an '&', which must come out as the
    # entity '&amp;' (matching the report's own encoding), not a raw '&'.
    "<html><body><table><tr><td>$($script:TokSub)</td></tr></table></body></html>" |
        Set-Content -Path (Join-Path $StageDir 'ResourcesReport_Test.html') -Encoding utf8

    $script:InputZip = Join-Path $script:TmpDir 'ResourcesReport_Test.zip'
    Compress-Archive -Path (Join-Path $StageDir '*') -DestinationPath $script:InputZip -Force
    $script:InputZipHashBefore = (Get-FileHash -Path $script:InputZip -Algorithm SHA256).Hash

    $script:DictPath = Join-Path $script:TmpDir 'ObfuscationDictionary_Test.json'
    $Dict | ConvertTo-Json -Depth 6 | Set-Content -Path $script:DictPath -Encoding utf8

    # Helper: run reveal into a fresh output zip, extract, return parsed members.
    # -DictPath / -SearchDir let individual tests point at alternate fixtures.
    function Invoke-Reveal
    {
        param([string[]]$Fields, [string]$DictPath = $script:DictPath, [string]$SearchDir, [switch]$All)
        $Out = Join-Path $script:TmpDir ("out_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".zip")
        $Splat = @{ InputZip = $script:InputZip; OutputZip = $Out }
        if ($SearchDir) { $Splat['SearchDirectory'] = $SearchDir } else { $Splat['DictionaryPath'] = $DictPath }
        if ($Fields) { $Splat['Fields'] = $Fields }
        if ($All) { $Splat['All'] = $true }
        & $script:RevealScript @Splat *>&1 | Out-Null
        $Ex = Join-Path $script:TmpDir ("ex_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Expand-Archive -Path $Out -DestinationPath $Ex -Force
        $InvFile = Get-ChildItem $Ex -Filter 'Inventory_*.json' | Select-Object -First 1
        $CsvFile = Get-ChildItem $Ex -Filter 'Consumption_*.csv' | Select-Object -First 1
        $HtmlFile = Get-ChildItem $Ex -Filter '*.html' | Select-Object -First 1
        return [pscustomobject]@{
            OutputZip = $Out
            Inventory = (Get-Content $InvFile.FullName -Raw | ConvertFrom-Json)
            Csv       = @(Import-Csv -Path $CsvFile.FullName)
            Html      = (Get-Content $HtmlFile.FullName -Raw)
        }
    }
}

AfterAll {
    if ($script:TmpDir -and (Test-Path $script:TmpDir))
    {
        Remove-Item -Path $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Reveal-Obfuscation default fields (ResourceGroup + Subscription)" {

    BeforeAll { $Script:R = Invoke-Reveal }

    It "produces valid JSON that re-parses" {
        $Script:R.Inventory | Should -Not -BeNullOrEmpty
        @($Script:R.Inventory.VirtualMachines).Count | Should -Be 3
    }

    It "reveals the resource group name" {
        $Script:R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
    }

    It "reveals an AKS managed (MC_) resource group name" {
        $Script:R.Inventory.VirtualMachines[1].ResourceGroup | Should -Be $script:RealRgAks
    }

    It "preserves resource-group name casing exactly as it appears in the Id" {
        $Script:R.Inventory.VirtualMachines[2].ResourceGroup | Should -Be $script:RealRgCase
    }

    It "reveals the subscription friendly name (offline from SubscriptionNameMap)" {
        $Script:R.Inventory.VirtualMachines[0].Subscription | Should -Be $script:RealSubName
    }

    It "leaves the Resource Id masked" {
        $Script:R.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
    }

    It "leaves the Resource Name masked" {
        $Script:R.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
    }

    It "leaves tag values masked when Tag is not selected" {
        $Script:R.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
    }

    It "keeps the tag key verbatim" {
        $Script:R.Inventory.VirtualMachines[0].Tags[0].Name | Should -Be 'environment'
    }

    It "leaves the literal 'obfuscated' sentinel untouched" {
        $Script:R.Inventory.VirtualMachines[0].Set | Should -Be 'obfuscated'
    }

    It "leaves free-text fields masked when FreeText is not selected" {
        $Script:R.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
    }

    It "HTML-encodes a revealed value containing special characters in the HTML report" {
        # RealSubName has an '&'; the HTML branch must emit the '&amp;' entity.
        $Script:R.Html | Should -Match 'Contoso, Inc\. \(Prod\) &amp; Co'
        $Script:R.Html | Should -Not -Match ([regex]::Escape($script:TokSub))
    }

    It "keeps the Consumption CSV columns intact despite a comma in the revealed subscription name" {
        @($Script:R.Csv).Count | Should -Be 1
        $Script:R.Csv[0].Cost | Should -Be '12.34'
        $Script:R.Csv[0].Subscription | Should -BeExactly $script:RealSubName
        $Script:R.Csv[0].InstanceId | Should -Match ([regex]::Escape($script:RealRgName))
    }

    It "reveals the subscription id, not the display name, inside an ARM path" {
        $Script:R.Csv[0].InstanceId | Should -BeExactly "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"
    }
}

Describe "Reveal-Obfuscation with -Fields Tag" {

    BeforeAll { $script:RT = Invoke-Reveal -Fields @('ResourceGroup', 'Subscription', 'Tag') }

    It "reveals the tag value when Tag is selected" {
        $script:RT.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
    }

    It "still leaves the Resource Id masked" {
        $script:RT.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
    }
}

Describe "Reveal-Obfuscation opt-in ResourceName / ResourceId" {

    It "reveals the resource short name when ResourceName is selected" {
        $R = Invoke-Reveal -Fields @('ResourceName')
        $R.Inventory.VirtualMachines[0].Name | Should -Be 'vm01'
    }

    It "leaves the Resource Id masked when only ResourceName is selected" {
        $R = Invoke-Reveal -Fields @('ResourceName')
        $R.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
    }

    It "reveals the full ARM resource Id when ResourceId is selected" {
        $R = Invoke-Reveal -Fields @('ResourceId')
        $R.Inventory.VirtualMachines[0].ID | Should -Be "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"
    }

    It "leaves the resource Name masked when only ResourceId is selected" {
        $R = Invoke-Reveal -Fields @('ResourceId')
        $R.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
    }
}

Describe "Reveal-Obfuscation -All full reveal" {

    BeforeAll { $script:RA = Invoke-Reveal -All }

    It "reveals the resource group name" {
        $script:RA.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
    }

    It "reveals the subscription friendly name" {
        $script:RA.Inventory.VirtualMachines[0].Subscription | Should -Be $script:RealSubName
    }

    It "reveals the resource short name" {
        $script:RA.Inventory.VirtualMachines[0].Name | Should -Be 'vm01'
    }

    It "reveals the full ARM resource Id" {
        $script:RA.Inventory.VirtualMachines[0].ID | Should -Be "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"
    }

    It "reveals the tag value" {
        $script:RA.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
    }

    It "reveals free-text fields" {
        $script:RA.Inventory.VirtualMachines[0].Description | Should -Be $script:RealFreeText
    }

    It "leaves the lossy 'obfuscated' sentinel untouched (not recoverable)" {
        $script:RA.Inventory.VirtualMachines[0].Set | Should -Be 'obfuscated'
    }

    It "reveals a Fabric capacity row and keeps its Airflow jobs as written" {
        $Row = $script:RA.Inventory.FabricCapacities[0]
        # Every token of the masked path is revealed. The subscription part is not checked here: on awslabs main
        # Reveal writes the subscription's display name there (pre-existing, the same for every section's id).
        $Row.ID | Should -Match ('(?i)^/subscriptions/[^/]+/resourcegroups/{0}/providers/microsoft\.fabric/capacities/capdata01$' -f [regex]::Escape($script:RealRgName))
        $Row.ID | Should -Not -Match '(?:prod|nonprod)_[0-9a-f]{8}-'
        $Row.Name | Should -Be 'capdata01'
        $Row.ResourceGroup | Should -Be $script:RealRgName
        $Row.Subscription | Should -Be $script:RealSubName
        $Row.SKU | Should -Be 'F64'
        $Row.ActiveHours | Should -Be 696
        $Row.AirflowJobs[0].NodeSize | Should -Be 'Large'
        $Row.AirflowJobs[0].MinNodeCount | Should -BeOfType [long]
        $Row.AirflowJobs[0].MinNodeCount | Should -Be 5
    }
}

Describe "Reveal-Obfuscation -Fields FreeText" {

    It "reveals free-text fields when FreeText is selected" {
        $R = Invoke-Reveal -Fields @('FreeText')
        $R.Inventory.VirtualMachines[0].Description | Should -Be $script:RealFreeText
    }

    It "leaves the resource group masked when only FreeText is selected" {
        $R = Invoke-Reveal -Fields @('FreeText')
        $R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:TokRg
    }

    It "is a no-op for free-text when the dictionary has no FreeTextMap" {
        $NoFreeDir = Join-Path $script:TmpDir ("nofree_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $NoFreeDir -Force | Out-Null
        $NoFreeDict = Join-Path $NoFreeDir 'ObfuscationDictionary_NoFree.json'
        [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ $script:TokId = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceNameMap  = [ordered]@{ $script:TokName = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            SubscriptionMap  = [ordered]@{ $script:TokSub = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceGroupMap = [ordered]@{ $script:TokRg = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $NoFreeDict -Encoding utf8

        # Pair FreeText with a resolvable dimension so the run has something to do;
        # FreeText must be a no-op (Description stays a token) when no FreeTextMap.
        $R = Invoke-Reveal -Fields @('ResourceGroup', 'FreeText') -DictPath $NoFreeDict
        $R.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        $R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
    }
}

Describe "Reveal-Obfuscation older / partial dictionaries" {

    It "falls back to the subscription GUID when the dictionary has no SubscriptionNameMap" {
        # A dictionary written before SubscriptionNameMap existed: the friendly
        # name is unrecoverable, so the subscription reveals to its GUID instead.
        $LegacyDir = Join-Path $script:TmpDir ("legacy_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $LegacyDir -Force | Out-Null
        $LegacyDict = Join-Path $LegacyDir 'ObfuscationDictionary_Legacy.json'
        [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ $script:TokId = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceNameMap  = [ordered]@{ $script:TokName = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            SubscriptionMap  = [ordered]@{ $script:TokSub = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceGroupMap = [ordered]@{ $script:TokRg = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $LegacyDict -Encoding utf8

        $R = Invoke-Reveal -DictPath $LegacyDict
        $R.Inventory.VirtualMachines[0].Subscription | Should -Be '12345678-1234-1234-1234-123456789012'
    }

    It "reveals the name of a collector row with no id without its stand-in suffix" {
        # A row with no id is filed under a stand-in path whose last segment is <name>~<hash>.
        $NoIdDir = Join-Path $script:TmpDir ("noid_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $NoIdDir -Force | Out-Null
        $NoIdDict = Join-Path $NoIdDir 'ObfuscationDictionary_NoId.json'
        [ordered]@{
            GeneratedAt     = '2026-06-30 00:00:00'
            ResourceNameMap = [ordered]@{ $script:TokName = "/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-app/providers/rda.noid/virtualmachines/vm01~0a1b2c3d" }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $NoIdDict -Encoding utf8

        $R = Invoke-Reveal -Fields @('ResourceName') -DictPath $NoIdDict
        $R.Inventory.VirtualMachines[0].Name | Should -Be 'vm01'
    }

    It "reveals a no-id row's name whose stand-in carries a second-row count, and leaves a row with no name masked" {
        $NoIdDir = Join-Path $script:TmpDir ("noid2_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $NoIdDir -Force | Out-Null
        $NoIdDict = Join-Path $NoIdDir 'ObfuscationDictionary_NoId2.json'
        [ordered]@{
            GeneratedAt     = '2026-06-30 00:00:00'
            ResourceNameMap = [ordered]@{ $script:TokName = "/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-app/providers/rda.noid/virtualmachines/vm01~0a1b2c3d-2" }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $NoIdDict -Encoding utf8
        $R = Invoke-Reveal -Fields @('ResourceName') -DictPath $NoIdDict
        $R.Inventory.VirtualMachines[0].Name | Should -Be 'vm01'

        $NoNameDict = Join-Path $NoIdDir 'ObfuscationDictionary_NoName.json'
        [ordered]@{
            GeneratedAt     = '2026-06-30 00:00:00'
            ResourceNameMap = [ordered]@{ $script:TokName = "/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-app/providers/rda.noid/virtualmachines/~noname~0a1b2c3d" }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $NoNameDict -Encoding utf8
        $R = Invoke-Reveal -Fields @('ResourceName') -DictPath $NoNameDict
        $R.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
    }

    # A tenant-scope row ('/providers/...') has no resource group: a run gives it
    # a group token of its own, mapped to its id in ResourceGroupMap, and a
    # 'resourceGroups' segment in such an id is a type word. Only a subscription
    # id's group slot is read as a group, as the masking reads it.
    It "leaves a group token masked whose ResourceGroupMap id is a tenant-scope id with a type word resourceGroups, and still reveals a subscription id's group" {
        $TenDir = Join-Path $script:TmpDir ("tenant_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $TenDir -Force | Out-Null
        $TenDict = Join-Path $TenDir 'ObfuscationDictionary_Tenant.json'
        [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceGroupMap = [ordered]@{
                $script:TokRg    = '/providers/Microsoft.Example/resourceGroups/grp-a'
                $script:TokRgAks = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/$($script:RealRgAks)/providers/Microsoft.Compute/virtualMachines/aksnode0"
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $TenDict -Encoding utf8

        $R = Invoke-Reveal -Fields @('ResourceGroup') -DictPath $TenDict
        $R.Inventory.VirtualMachines[0].ResourceGroup | Should -BeExactly $script:TokRg -Because 'a tenant-scope id has no group to reveal'
        $R.Inventory.VirtualMachines[1].ResourceGroup | Should -BeExactly $script:RealRgAks -Because 'a subscription id''s group is still revealed'
        $R.Csv[0].InstanceId | Should -Not -Match 'grp-a' -Because 'the token is not a group in an ARM path either'
    }

    It "leaves tag values masked when -Fields Tag is requested but the dictionary has no TagMap" {
        $NoTagDir = Join-Path $script:TmpDir ("notag_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $NoTagDir -Force | Out-Null
        $NoTagDict = Join-Path $NoTagDir 'ObfuscationDictionary_NoTag.json'
        [ordered]@{
            GeneratedAt         = '2026-06-30 00:00:00'
            ResourceIdMap       = [ordered]@{ $script:TokId = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceNameMap     = [ordered]@{ $script:TokName = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            SubscriptionMap     = [ordered]@{ $script:TokSub = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceGroupMap    = [ordered]@{ $script:TokRg = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            SubscriptionNameMap = [ordered]@{ $script:TokSub = $script:RealSubName }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $NoTagDict -Encoding utf8

        $R = Invoke-Reveal -Fields @('ResourceGroup', 'Subscription', 'Tag') -DictPath $NoTagDict
        $R.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
    }
}

Describe "Reveal-Obfuscation dictionary handling and source safety" {

    It "auto-discovers the newest dictionary in -SearchDirectory" {
        $R = Invoke-Reveal -SearchDir $script:TmpDir
        $R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
    }

    It "does not mutate the input zip" {
        $null = Invoke-Reveal
        (Get-FileHash -Path $script:InputZip -Algorithm SHA256).Hash | Should -Be $script:InputZipHashBefore
    }

    It "throws when neither -DictionaryPath nor a discoverable dictionary exists" {
        $EmptyDir = Join-Path $script:TmpDir ("empty_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $EmptyDir -Force | Out-Null
        { & $script:RevealScript -InputZip $script:InputZip -SearchDirectory $EmptyDir -OutputZip (Join-Path $EmptyDir 'o.zip') } |
            Should -Throw -ExpectedMessage '*ObfuscationDictionary*'
    }
}

# Reveal puts a token's value wherever the token stands: in any field, and in a subscription,
# group or name segment of an id. A dictionary that gives one token to two maps (changed or
# merged by hand) would write one map's value into the other's fields, and -Fields would reveal
# a field it does not name. A run gives each value a token of its own; SubscriptionMap and
# SubscriptionNameMap hold one subscription's token by design. So Reveal checks every map,
# ignoring case, whatever -Fields selects, and stops on a shared token before it writes anything.
Describe "Reveal-Obfuscation stops on a dictionary that gives one token to two maps" {

    BeforeAll {
        $script:ClashId = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-other/providers/Microsoft.Compute/virtualMachines/vm-other'
    }

    It "stops with <Mode> on a token that <Case> share, names the token and both maps, and writes nothing" -ForEach @(
        foreach ($Mode in '-Fields Tag', '-All')
        {
            @{ Mode = $Mode; Case = 'a tag value and a resource name'; Map = 'TagMap'; Tok = 'TokName'; Upper = $false; Value = 'real-tag'; Other = 'ResourceNameMap' }
            @{ Mode = $Mode; Case = 'a tag value and a free-text value'; Map = 'TagMap'; Tok = 'TokFree'; Upper = $false; Value = 'real-tag'; Other = 'FreeTextMap' }
            @{ Mode = $Mode; Case = 'a tag value and a resource group'; Map = 'TagMap'; Tok = 'TokRg'; Upper = $false; Value = 'real-tag'; Other = 'ResourceGroupMap' }
            @{ Mode = $Mode; Case = 'a tag value and a subscription'; Map = 'TagMap'; Tok = 'TokSub'; Upper = $false; Value = 'real-tag'; Other = 'SubscriptionMap' }
            @{ Mode = $Mode; Case = 'a subscription name and a tag value'; Map = 'SubscriptionNameMap'; Tok = 'TokTag'; Upper = $false; Value = 'real-sub-name'; Other = 'TagMap' }
            @{ Mode = $Mode; Case = 'a free-text value and a resource name'; Map = 'FreeTextMap'; Tok = 'TokName'; Upper = $false; Value = 'real-free'; Other = 'ResourceNameMap' }
            @{ Mode = $Mode; Case = 'a resource group and a resource name'; Map = 'ResourceGroupMap'; Tok = 'TokName'; Upper = $false; Value = 'ClashId'; Other = 'ResourceNameMap' }
            @{ Mode = $Mode; Case = 'a subscription and a resource group'; Map = 'SubscriptionMap'; Tok = 'TokRg'; Upper = $false; Value = 'ClashId'; Other = 'ResourceGroupMap' }
            @{ Mode = $Mode; Case = 'a resource name and a flat id'; Map = 'ResourceNameMap'; Tok = 'TokId'; Upper = $false; Value = 'ClashId'; Other = 'ResourceIdMap' }
            @{ Mode = $Mode; Case = 'a tag value and a resource name (written in another case)'; Map = 'TagMap'; Tok = 'TokName'; Upper = $true; Value = 'real-tag'; Other = 'ResourceNameMap' }
        }
    ) {
        $Token = (Get-Variable -Scope Script -Name $Tok -ValueOnly)
        if ($Upper) { $Token = $Token.ToUpperInvariant() }
        $Real = if ($Value -eq 'ClashId') { $script:ClashId } else { $Value }
        $Dir = Join-Path $script:TmpDir ("clash_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $D = Get-Content -LiteralPath $script:DictPath -Raw | ConvertFrom-Json -AsHashtable
        $D[$Map][$Token] = $Real
        $DictFile = Join-Path $Dir 'ObfuscationDictionary_Clash.json'
        $D | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $DictFile -Encoding utf8
        $Out = Join-Path $Dir 'out.zip'
        $Splat = @{ InputZip = $script:InputZip; DictionaryPath = $DictFile; OutputZip = $Out }
        if ($Mode -eq '-All') { $Splat['All'] = $true } else { $Splat['Fields'] = @('Tag') }

        $Err = $null
        try { & $script:RevealScript @Splat *>&1 | Out-Null }
        catch { $Err = $_ }
        $Err | Should -Not -BeNullOrEmpty -Because 'Reveal stops on a token two maps hold'
        $Msg = $Err.Exception.Message
        $Msg | Should -Match 'more than one map'
        $Msg | Should -Match ([regex]::Escape($Token)) -Because 'the message names the token'
        $Msg | Should -Match "\b$Map\b" -Because 'the message names the map'
        $Msg | Should -Match "\b$Other\b" -Because 'the message names the other map'
        $Msg | Should -Match ([regex]::Escape('Nothing was written.'))
        $Msg | Should -Not -Match ([regex]::Escape($Real)) -Because 'the message holds no real value'
        Test-Path -LiteralPath $Out | Should -BeFalse -Because 'no output zip is written'
        Test-Path -LiteralPath (($Out -replace '\.zip$', '') + '.partial.zip') | Should -BeFalse -Because 'no partial zip is left'
        (Get-FileHash -Path $script:InputZip -Algorithm SHA256).Hash | Should -Be $script:InputZipHashBefore
    }

    It "reveals, with <Mode>, a dictionary whose one shared token is the subscription's, in SubscriptionMap and SubscriptionNameMap, as a run writes it" -ForEach @(
        @{ Mode = '-Fields Tag' }
        @{ Mode = '-All' }
    ) {
        $R = if ($Mode -eq '-All') { Invoke-Reveal -All } else { Invoke-Reveal -Fields @('Tag') }
        Test-Path -LiteralPath $R.OutputZip | Should -BeTrue
        $R.Inventory.VirtualMachines[0].Tags[0].Value | Should -BeExactly $script:RealTagVal
        if ($Mode -eq '-All')
        {
            $R.Inventory.VirtualMachines[0].Subscription | Should -BeExactly $script:RealSubName
            $R.Inventory.VirtualMachines[0].Name | Should -BeExactly 'vm01'
            $R.Csv[0].InstanceId | Should -BeExactly "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"
        }
        else
        {
            $R.Inventory.VirtualMachines[0].Subscription | Should -BeExactly $script:TokSub
            $R.Inventory.VirtualMachines[0].Name | Should -BeExactly $script:TokName
        }
    }
}

# A path-shaped ResourceIdMap key (a masked id) holds a token in its subscription slot, its group
# slot ('/subscriptions/<id>/resourceGroups/<x>' only) and each name slot. Reveal puts a token's
# path value in a slot and its map value in every field that holds it. So a token an id holds as
# another kind of value (a group's token as a resource's name) would reveal a field -Fields does
# not name and write the group into the id, and a token an id holds for another real value would
# write the wrong value into the id. A run gives each slot the token of its own subscription, group
# or name. So Reveal reads every such key slot by slot against its real id, ignoring case, and
# stops before it writes anything.
Describe "Reveal-Obfuscation stops on a dictionary whose ids hold a token for another kind of value or another real value" {

    BeforeAll {
        $script:SlotRealSub = '12345678-1234-1234-1234-123456789012'
        $script:SlotOtherSub = [guid]::NewGuid().ToString()
        $script:SlotTok = @{}
        foreach ($K in 'New', 'Child', 'Sa', 'Ns', 'Topic', 'Ts', 'Ro', 'Disk') { $script:SlotTok[$K] = 'prod_' + [guid]::NewGuid().ToString() }
        # '{Name}' in a case's text -> the token or value it stands for, at run time.
        function Expand-SlotText
        {
            param([string]$Text, [switch]$Upper)
            $Values = @{
                Sub = $script:TokSub; Rg = $script:TokRg; RgAks = $script:TokRgAks; RgCase = $script:TokRgCase; Name = $script:TokName; Fab = $script:TokFabName
                Tag = $script:TokTag; Free = $script:TokFree; Id = $script:TokId; RealSub = $script:SlotRealSub; OtherSub = $script:SlotOtherSub
                UpperRgAks = $script:TokRgAks.ToUpperInvariant()
            }
            foreach ($K in $script:SlotTok.Keys) { $Values[$K] = $script:SlotTok[$K] }
            foreach ($K in $Values.Keys) { $Text = $Text.Replace('{' + $K + '}', $Values[$K]) }
            return $Text
        }
        # The test dictionary with the case's ids added to ResourceIdMap (and names to ResourceNameMap).
        function New-SlotDictionary
        {
            param([object[]]$Ids, [object[]]$Names)
            $Dir = Join-Path $script:TmpDir ("slot_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $D = Get-Content -LiteralPath $script:DictPath -Raw | ConvertFrom-Json -AsHashtable
            foreach ($E in @($Ids)) { if ($null -ne $E) { $D['ResourceIdMap'][(Expand-SlotText $E.M)] = (Expand-SlotText $E.R) } }
            foreach ($E in @($Names)) { if ($null -ne $E) { $D['ResourceNameMap'][(Expand-SlotText $E.T)] = (Expand-SlotText $E.R) } }
            $File = Join-Path $Dir 'ObfuscationDictionary_Slot.json'
            $D | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $File -Encoding utf8
            return [pscustomobject]@{ Dir = $Dir; File = $File }
        }
    }

    It "stops with <Mode> on <Case>, names the token and both places, and writes nothing" -ForEach @(
        foreach ($Mode in '-Fields ResourceGroup', '-All')
        {
            $Fab = '/subscriptions/{Sub}/resourcegroups/{Rg}/providers/microsoft.fabric/capacities/'
            $FabReal = '/subscriptions/{RealSub}/resourceGroups/rg-app/providers/Microsoft.Fabric/capacities/capdata01'
            $Kinds = 'for two kinds of value'
            $Values = 'for two real values'
            $NameSlot = 'a name slot of a ResourceIdMap id'
            $GroupSlot = 'the group slot of a ResourceIdMap id'
            $SubSlot = 'the subscription slot of a ResourceIdMap id'
            @{ Mode = $Mode; Case = 'a group''s token that an id holds only as a resource''s name'; Tok = '{RgAks}'; Ids = @(@{ M = $Fab + '{RgAks}'; R = $FabReal }); Places = @('ResourceGroupMap', $NameSlot); Why = $Kinds }
            @{ Mode = $Mode; Case = 'a resource name''s token that an id holds as its group'; Tok = '{Fab}'; Ids = @(@{ M = '/subscriptions/{Sub}/resourcegroups/{Fab}/providers/microsoft.fabric/capacities/{New}'; R = '/subscriptions/{RealSub}/resourceGroups/rg-app/providers/Microsoft.Fabric/capacities/cap-new' }); Places = @('ResourceNameMap', $GroupSlot); Why = $Kinds }
            @{ Mode = $Mode; Case = 'a subscription''s token that an id holds as a resource''s name'; Tok = '{Sub}'; Ids = @(@{ M = $Fab + '{Sub}'; R = $FabReal }); Places = @('SubscriptionMap', $NameSlot); Why = $Kinds }
            @{ Mode = $Mode; Case = 'a group''s token that an id holds as its subscription'; Tok = '{RgAks}'; Ids = @(@{ M = '/subscriptions/{RgAks}/resourcegroups/{Rg}/providers/microsoft.fabric/capacities/{Fab}'; R = $FabReal }); Places = @('ResourceGroupMap', $SubSlot); Why = $Kinds }
            @{ Mode = $Mode; Case = 'a tag value''s token that an id holds as a resource''s name'; Tok = '{Tag}'; Ids = @(@{ M = $Fab + '{Tag}'; R = $FabReal }); Places = @('TagMap', $NameSlot); Why = $Kinds }
            @{ Mode = $Mode; Case = 'a free-text value''s token that an id holds as its group'; Tok = '{Free}'; Ids = @(@{ M = '/subscriptions/{Sub}/resourcegroups/{Free}/providers/microsoft.fabric/capacities/{Fab}'; R = $FabReal }); Places = @('FreeTextMap', $GroupSlot); Why = $Kinds }
            @{ Mode = $Mode; Case = 'a flat id''s token that an id holds as a resource''s name'; Tok = '{Id}'; Ids = @(@{ M = $Fab + '{Id}'; R = $FabReal }); Places = @('ResourceIdMap', $NameSlot); Why = $Kinds }
            @{ Mode = $Mode; Case = 'a group''s token that a tenant-scope id holds after its type word resourceGroups'; Tok = '{RgAks}'; Ids = @(@{ M = '/providers/Microsoft.Example/resourceGroups/{RgAks}'; R = '/providers/Microsoft.Example/resourceGroups/grp-a' }); Places = @('ResourceGroupMap', $NameSlot); Why = $Kinds }
            @{ Mode = $Mode; Case = 'a token in no map that one id holds as its group and another as a name'; Tok = '{New}'; Ids = @(@{ M = '/subscriptions/{Sub}/resourcegroups/{New}/providers/microsoft.fabric/capacities/{Fab}'; R = '/subscriptions/{RealSub}/resourceGroups/rg-new/providers/Microsoft.Fabric/capacities/capdata01' }, @{ M = '/subscriptions/{Sub}/resourcegroups/{Rg}/providers/microsoft.storage/storageaccounts/{New}'; R = '/subscriptions/{RealSub}/resourceGroups/rg-app/providers/Microsoft.Storage/storageAccounts/sa-two' }); Places = @($GroupSlot, $NameSlot); Why = $Kinds }
            @{ Mode = $Mode; Case = 'a group''s token, written in another case, that an id holds as a resource''s name'; Tok = '{UpperRgAks}'; Ids = @(@{ M = $Fab + '{UpperRgAks}'; R = $FabReal }); Places = @('ResourceGroupMap', $NameSlot); Why = $Kinds }
            @{ Mode = $Mode; Case = 'a group''s token that an id holds as a name, where the real id has another number of parts'; Tok = '{RgAks}'; Ids = @(@{ M = $Fab + '{RgAks}'; R = $FabReal + '/extra' }); Places = @('ResourceGroupMap', $NameSlot); Why = $Kinds }
            @{ Mode = $Mode; Case = 'a resource name''s token that an id holds for another name'; Tok = '{Name}'; Ids = @(@{ M = $Fab + '{Name}'; R = $FabReal }); Places = @('ResourceNameMap', $NameSlot); Why = $Values }
            @{ Mode = $Mode; Case = 'a group''s token that an id holds for another group'; Tok = '{RgAks}'; Ids = @(@{ M = '/subscriptions/{Sub}/resourcegroups/{RgAks}/providers/microsoft.fabric/capacities/{Fab}'; R = $FabReal }); Places = @('ResourceGroupMap', $GroupSlot); Why = $Values }
            @{ Mode = $Mode; Case = 'a subscription''s token that an id holds for another subscription'; Tok = '{Sub}'; Ids = @(@{ M = $Fab + '{Fab}'; R = '/subscriptions/{OtherSub}/resourceGroups/rg-app/providers/Microsoft.Fabric/capacities/capdata01' }); Places = @('SubscriptionMap', $SubSlot); Why = $Values }
            @{ Mode = $Mode; Case = 'a token in no map that two ids hold as the names of two resources'; Tok = '{New}'; Ids = @(@{ M = $Fab + '{New}'; R = '/subscriptions/{RealSub}/resourceGroups/rg-app/providers/Microsoft.Fabric/capacities/cap-one' }, @{ M = '/subscriptions/{Sub}/resourcegroups/{Rg}/providers/microsoft.storage/storageaccounts/{New}'; R = '/subscriptions/{RealSub}/resourceGroups/rg-app/providers/Microsoft.Storage/storageAccounts/sa-two' }); Places = @($NameSlot, $NameSlot); Why = $Values }
        }
    ) {
        $Token = Expand-SlotText $Tok
        $Dict = New-SlotDictionary -Ids $Ids
        $Out = Join-Path $Dict.Dir 'out.zip'
        $Splat = @{ InputZip = $script:InputZip; DictionaryPath = $Dict.File; OutputZip = $Out }
        if ($Mode -eq '-All') { $Splat['All'] = $true } else { $Splat['Fields'] = @('ResourceGroup') }

        $Err = $null
        try { & $script:RevealScript @Splat *>&1 | Out-Null }
        catch { $Err = $_ }
        $Err | Should -Not -BeNullOrEmpty -Because 'Reveal stops on a token an id holds for another kind of value or another real value'
        $Msg = $Err.Exception.Message
        $Msg | Should -Match ([regex]::Escape($Token)) -Because 'the message names the token'
        foreach ($P in $Places) { $Msg | Should -Match ([regex]::Escape($P)) -Because 'the message names both places' }
        $Msg | Should -Match ([regex]::Escape($Why))
        $Msg | Should -Match ([regex]::Escape('Nothing was written.'))
        # No real part of the case's ids, and no real value of the fixture, is in the message.
        $Reals = [System.Collections.Generic.List[string]]::new()
        foreach ($E in $Ids) { foreach ($Part in (Expand-SlotText $E.R).Split('/')) { if ($Part -and $Part -notin @('subscriptions', 'resourceGroups', 'providers')) { $Reals.Add($Part) } } }
        $Reals.AddRange([string[]]@($script:RealRgName, $script:RealRgAks, $script:RealRgCase, $script:RealSubName, $script:RealTagVal, $script:RealFreeText, 'vm01'))
        foreach ($Real in $Reals) { $Msg | Should -Not -Match ([regex]::Escape($Real)) -Because 'the message holds no real value' }
        Test-Path -LiteralPath $Out | Should -BeFalse -Because 'no output zip is written'
        Test-Path -LiteralPath (($Out -replace '\.zip$', '') + '.partial.zip') | Should -BeFalse -Because 'no partial zip is left'
        (Get-FileHash -Path $script:InputZip -Algorithm SHA256).Hash | Should -Be $script:InputZipHashBefore
    }

    It "reveals, with <Mode>, a dictionary whose ids hold each subscription, group and name token in its own slot for its own value, as a run writes it" -ForEach @(
        @{ Mode = '-Fields ResourceGroup' }
        @{ Mode = '-All' }
        @{ Mode = 'the default fields' }
    ) {
        $FabId = '/subscriptions/{Sub}/resourcegroups/{Rg}/providers/microsoft.fabric/capacities/{Fab}'
        $FabRealId = '/subscriptions/{RealSub}/resourceGroups/rg-app/providers/Microsoft.Fabric/capacities/capdata01'
        $Ids = @(
            # The Fabric row's own id: each token in its own slot.
            @{ M = $FabId; R = $FabRealId }
            # A child id holds its parent's name token.
            @{ M = $FabId + '/workspaces/{Child}'; R = $FabRealId + '/workspaces/ws01' }
            # A group and a name written in other casings than their maps' ids.
            @{ M = '/subscriptions/{Sub}/resourcegroups/{RgCase}/providers/microsoft.storage/storageaccounts/{Sa}'; R = '/subscriptions/{RealSub}/resourceGroups/rg-App/providers/Microsoft.Storage/storageAccounts/SA01' }
            # A later word subscriptions is a type word: the token after it is a name.
            @{ M = '/subscriptions/{Sub}/resourcegroups/{Rg}/providers/microsoft.servicebus/namespaces/{Ns}/topics/{Topic}/subscriptions/{Ts}'; R = '/subscriptions/{RealSub}/resourceGroups/rg-app/providers/Microsoft.ServiceBus/namespaces/ns01/topics/orders/subscriptions/audit' }
            # A tenant-scope id: every token is a name.
            @{ M = '/providers/Microsoft.Capacity/reservationOrders/{Ro}'; R = '/providers/Microsoft.Capacity/reservationOrders/ro01' }
            # A token in no map, in its own name slot.
            @{ M = '/subscriptions/{Sub}/resourcegroups/{Rg}/providers/microsoft.compute/disks/{Disk}'; R = '/subscriptions/{RealSub}/resourceGroups/rg-app/providers/Microsoft.Compute/disks/disk01' }
        )
        $Names = @(
            @{ T = '{Child}'; R = $FabRealId + '/workspaces/ws01' }
            @{ T = '{Sa}'; R = '/subscriptions/{RealSub}/resourceGroups/RG-APP/providers/Microsoft.Storage/storageAccounts/sa01' }
            @{ T = '{Ns}'; R = '/subscriptions/{RealSub}/resourceGroups/rg-app/providers/Microsoft.ServiceBus/namespaces/ns01' }
            @{ T = '{Topic}'; R = '/subscriptions/{RealSub}/resourceGroups/rg-app/providers/Microsoft.ServiceBus/namespaces/ns01/topics/orders' }
            @{ T = '{Ts}'; R = '/subscriptions/{RealSub}/resourceGroups/rg-app/providers/Microsoft.ServiceBus/namespaces/ns01/topics/orders/subscriptions/audit' }
            @{ T = '{Ro}'; R = '/providers/Microsoft.Capacity/reservationOrders/ro01' }
        )
        $Dict = New-SlotDictionary -Ids $Ids -Names $Names
        $R = switch ($Mode) { '-All' { Invoke-Reveal -All -DictPath $Dict.File } '-Fields ResourceGroup' { Invoke-Reveal -Fields @('ResourceGroup') -DictPath $Dict.File } default { Invoke-Reveal -DictPath $Dict.File } }
        Test-Path -LiteralPath $R.OutputZip | Should -BeTrue
        $Fabric = @($R.Inventory.FabricCapacities)[0]
        $Masked = Expand-SlotText $FabId
        if ($Mode -eq '-All')
        {
            $Fabric.ID | Should -BeExactly (Expand-SlotText $FabRealId)
            $Fabric.Name | Should -BeExactly 'capdata01'
            $Fabric.ResourceGroup | Should -BeExactly $script:RealRgName
        }
        else
        {
            # The group is revealed in the id, and with the default fields the subscription too
            # (as its id there); the name stays masked.
            $Expected = $Masked.Replace("/$($script:TokRg)/", "/$($script:RealRgName)/")
            if ($Mode -eq 'the default fields') { $Expected = $Expected.Replace("/subscriptions/$($script:TokSub)/", "/subscriptions/$($script:SlotRealSub)/") }
            $Fabric.ID | Should -BeExactly $Expected
            $Fabric.Name | Should -BeExactly $script:TokFabName -Because 'the name stays masked'
            $Fabric.ResourceGroup | Should -BeExactly $script:RealRgName
        }
    }
}

# Older builds key a subscription's token by its display name: the upstream main branch's
# ResourceInventory.ps1 ($SubLookup[$RealSub], $RealSub the subscription's name), and this fork's
# builds before the token was keyed by the subscription id. So two subscriptions with one display
# name share one token. Every id of either holds it in its subscription slot, SubscriptionMap keeps
# the one id the writer met last for it, and SubscriptionNameMap gives it that one name. Reveal
# writes the name in subscription fields, and a whole id that ResourceIdMap holds as its real id,
# and leaves the token masked in any other id path, as it cannot tell which subscription id the
# token stands for there. It warns once. Any other clash of that token still stops it.
Describe "Reveal-Obfuscation reads an older dictionary whose one subscription token stands for two subscriptions with one display name" {

    BeforeAll {
        $script:OldSub1 = [guid]::NewGuid().ToString()
        $script:OldSub2 = [guid]::NewGuid().ToString()
        $script:OldSubName = 'Pay-As-You-Go'
        $script:OldTok = @{}
        foreach ($K in 'Sub', 'Rg', 'Vm1', 'Vm2', 'Set', 'Tag', 'Disk', 'Sa') { $script:OldTok[$K] = 'prod_' + [guid]::NewGuid().ToString() }
        # Build-ObfuscatedResourceUri's tokens for a consumption id no inventory row holds: its own
        # subscription token (keyed by the subscription id) and group token, with type hints.
        $script:OldTok['CSub'] = 'prod_sub_' + [guid]::NewGuid().ToString()
        $script:OldTok['CRg'] = 'prod_rg_' + [guid]::NewGuid().ToString()
        $T = $script:OldTok
        $script:OldR1 = "/subscriptions/$($script:OldSub1)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm-one"
        $script:OldR2 = "/subscriptions/$($script:OldSub2)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm-two"
        $script:OldRDisk = "/subscriptions/$($script:OldSub2)/resourceGroups/rg-app/providers/Microsoft.Compute/disks/disk-two"
        # Masked as that writer masks an inventory id: the subscription, the first group and the
        # last segment replaced, the group word written 'resourcegroups'.
        $script:OldM1 = "/subscriptions/$($T.Sub)/resourcegroups/$($T.Rg)/providers/Microsoft.Compute/virtualMachines/$($T.Vm1)"
        $script:OldM2 = "/subscriptions/$($T.Sub)/resourcegroups/$($T.Rg)/providers/Microsoft.Compute/virtualMachines/$($T.Vm2)"
        $script:OldMDisk = "/subscriptions/$($T.CSub)/resourcegroups/$($T.CRg)/providers/Microsoft.Compute/disks/$($T.Disk)"
        # A scale set id that the dictionary does not hold whole.
        $script:OldSetId = "/subscriptions/$($T.Sub)/resourcegroups/$($T.Rg)/providers/Microsoft.Compute/virtualMachineScaleSets/$($T.Set)"

        # The dictionary as that writer builds it from its token tables.
        function New-OldDictionary
        {
            [ordered]@{
                GeneratedAt         = '2026-06-30 00:00:00'
                ResourceIdMap       = [ordered]@{ $script:OldM1 = $script:OldR1; $script:OldM2 = $script:OldR2; $script:OldMDisk = $script:OldRDisk }
                ResourceNameMap     = [ordered]@{ $script:OldTok.Vm1 = $script:OldR1; $script:OldTok.Vm2 = $script:OldR2 }
                # Keyed by token, so it keeps the last id the writer met for the shared token.
                SubscriptionMap     = [ordered]@{ $script:OldTok.Sub = $script:OldR2 }
                ResourceGroupMap    = [ordered]@{ $script:OldTok.Rg = $script:OldR2 }
                SubscriptionNameMap = [ordered]@{ $script:OldTok.Sub = $script:OldSubName }
                TagMap              = [ordered]@{ $script:OldTok.Tag = 'payments' }
                FreeTextMap         = [ordered]@{}
            }
        }

        $script:OldDir = Join-Path $script:TmpDir ("older_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Stage = Join-Path $script:OldDir 'stage'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        [ordered]@{
            VirtualMachines = @(
                [ordered]@{ ID = $script:OldM1; Name = $T.Vm1; Subscription = $T.Sub; ResourceGroup = $T.Rg; Set = $script:OldSetId; Tags = @([ordered]@{ Name = 'environment'; Value = $T.Tag }) }
                [ordered]@{ ID = $script:OldM2; Name = $T.Vm2; Subscription = $T.Sub; ResourceGroup = $T.Rg; Tags = @([ordered]@{ Name = 'environment'; Value = $T.Tag }) }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Stage 'Inventory_Older.json') -Encoding utf8
        @(
            [pscustomobject]@{ ResourceId = $script:OldM1; Subscription = $T.Sub; Cost = '1.00' }
            [pscustomobject]@{ ResourceId = $script:OldM2; Subscription = $T.Sub; Cost = '2.00' }
            [pscustomobject]@{ ResourceId = $script:OldMDisk; Subscription = $T.CSub; Cost = '3.00' }
        ) | Export-Csv -LiteralPath (Join-Path $Stage 'Consumption_Older.csv') -NoTypeInformation -Encoding utf8
        $script:OldZip = Join-Path $script:OldDir 'ResourcesReport_Older.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $script:OldZip -Force
        $script:OldZipHash = (Get-FileHash -LiteralPath $script:OldZip -Algorithm SHA256).Hash

        # Runs Reveal.ps1 on the older report with $Dict; returns the error, the warnings, the
        # output zip, and the revealed inventory, consumption rows and all member text.
        function Invoke-OldReveal
        {
            param([System.Collections.IDictionary]$Dict, [string]$Mode)
            $Dir = Join-Path $script:OldDir ("run_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $File = Join-Path $Dir 'ObfuscationDictionary_Older.json'
            $Dict | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $File -Encoding utf8
            $Out = Join-Path $Dir 'out.zip'
            $Splat = @{ InputZip = $script:OldZip; DictionaryPath = $File; OutputZip = $Out }
            switch ($Mode)
            {
                '-All' { $Splat['All'] = $true }
                '-Fields Tag' { $Splat['Fields'] = @('Tag') }
                '-Fields Subscription' { $Splat['Fields'] = @('Subscription') }
                default { }
            }
            $Err = $null
            $Stream = @()
            try { $Stream = @(& $script:RevealScript @Splat *>&1) }
            catch { $Err = $_ }
            $Result = [pscustomobject]@{
                Error     = $Err
                Warnings  = @($Stream | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { [string]$_.Message })
                OutputZip = $Out
                Inventory = $null
                Csv       = $null
                Text      = $null
            }
            if (Test-Path -LiteralPath $Out)
            {
                $Ex = Join-Path $Dir 'ex'
                Expand-Archive -LiteralPath $Out -DestinationPath $Ex -Force
                $Result.Inventory = Get-Content -LiteralPath (Join-Path $Ex 'Inventory_Older.json') -Raw | ConvertFrom-Json
                $Result.Csv = @(Import-Csv -LiteralPath (Join-Path $Ex 'Consumption_Older.csv'))
                $Result.Text = (Get-ChildItem -LiteralPath $Ex -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
            }
            return $Result
        }
    }

    It "reveals, with <Mode>, the report of two subscriptions with one display name and one token, keeps that token in an id path the dictionary does not hold whole, and warns <Warn> time(s)" -ForEach @(
        @{ Mode = '-All'; Warn = 1 }
        @{ Mode = '-Fields Tag'; Warn = 0 }
        @{ Mode = '-Fields Subscription'; Warn = 1 }
        @{ Mode = 'the default fields'; Warn = 1 }
    ) {
        $T = $script:OldTok
        $R = Invoke-OldReveal -Dict (New-OldDictionary) -Mode $Mode
        $R.Error | Should -BeNullOrEmpty -Because 'Reveal reads the dictionary an older build wrote'
        Test-Path -LiteralPath $R.OutputZip | Should -BeTrue
        $Vm = @($R.Inventory.VirtualMachines)
        $Rg = if ($Mode -in '-All', 'the default fields') { 'rg-app' } else { $T.Rg }
        $Sub = if ($Mode -eq '-Fields Tag') { $T.Sub } else { $script:OldSubName }
        $Tag = if ($Mode -in '-All', '-Fields Tag') { 'payments' } else { $T.Tag }
        foreach ($Row in $Vm)
        {
            $Row.Subscription | Should -BeExactly $Sub -Because 'the subscription field gets the one display name both subscriptions have'
            $Row.ResourceGroup | Should -BeExactly $Rg
            $Row.Tags[0].Value | Should -BeExactly $Tag
        }
        # The set's id is not in ResourceIdMap: the shared token stays masked in its subscription
        # slot, whatever is revealed, and only the group is revealed in it with the group.
        $Vm[0].Set | Should -BeExactly ("/subscriptions/$($T.Sub)/resourcegroups/$Rg/providers/Microsoft.Compute/virtualMachineScaleSets/$($T.Set)")
        if ($Mode -eq '-All')
        {
            # Each whole id comes back from ResourceIdMap with its own subscription id.
            $Vm[0].ID | Should -BeExactly $script:OldR1
            $Vm[1].ID | Should -BeExactly $script:OldR2
            $Vm[0].Name | Should -BeExactly 'vm-one'
            $Vm[1].Name | Should -BeExactly 'vm-two'
            @($R.Csv.ResourceId) | Should -Be @($script:OldR1, $script:OldR2, $script:OldRDisk)
        }
        else
        {
            # No subscription id is written anywhere: the token keeps its place in every id.
            $Vm[0].ID | Should -BeExactly $script:OldM1.Replace("/$($T.Rg)/", "/$Rg/")
            $Vm[1].ID | Should -BeExactly $script:OldM2.Replace("/$($T.Rg)/", "/$Rg/")
            $Vm[0].Name | Should -BeExactly $T.Vm1
            @($R.Csv.ResourceId) | Should -Be @($script:OldM1.Replace("/$($T.Rg)/", "/$Rg/"), $script:OldM2.Replace("/$($T.Rg)/", "/$Rg/"), $script:OldMDisk)
            $R.Text | Should -Not -Match ([regex]::Escape($script:OldSub1))
            $R.Text | Should -Not -Match ([regex]::Escape($script:OldSub2))
            $R.Text | Should -Not -Match ([regex]::Escape("/subscriptions/$($script:OldSubName)")) -Because 'the display name is not written in an id path'
        }
        $Mine = @($R.Warnings | Where-Object { $_ -match 'display name' -and $_ -match 'subscription id' })
        $Mine.Count | Should -Be $Warn
        foreach ($W in $Mine)
        {
            $W | Should -Match ([regex]::Escape($T.Sub)) -Because 'the warning names the token'
            $W | Should -Match 'leaves it masked in any other id path'
            foreach ($Real in $script:OldSub1, $script:OldSub2, $script:OldSubName, 'vm-one', 'rg-app') { $W | Should -Not -Match ([regex]::Escape($Real)) -Because 'the warning holds no real value' }
        }
        (Get-FileHash -LiteralPath $script:OldZip -Algorithm SHA256).Hash | Should -Be $script:OldZipHash
    }

    It "still stops with <Mode> when <Case>, names the token and both places, and writes nothing" -ForEach @(
        foreach ($Mode in '-All', '-Fields Tag')
        {
            @{ Mode = $Mode; Case = 'SubscriptionNameMap gives the token no name'; Change = 'NoName'; Places = @('SubscriptionMap', 'the subscription slot of a ResourceIdMap id'); Why = 'for two real values' }
            @{ Mode = $Mode; Case = 'an id also holds the token as a resource''s name'; Change = 'AsName'; Places = @('SubscriptionMap', 'a name slot of a ResourceIdMap id'); Why = 'for two kinds of value' }
            @{ Mode = $Mode; Case = 'a subscription slot holds the token for a value that is not a subscription id'; Change = 'NotGuid'; Places = @('SubscriptionMap', 'the subscription slot of a ResourceIdMap id'); Why = 'for two real values' }
        }
    ) {
        $T = $script:OldTok
        $D = New-OldDictionary
        switch ($Change)
        {
            'NoName' { $D.Remove('SubscriptionNameMap') }
            'AsName' { $D.ResourceIdMap["/subscriptions/$($T.Sub)/resourcegroups/$($T.Rg)/providers/Microsoft.Storage/storageAccounts/$($T.Sub)"] = "/subscriptions/$($script:OldSub1)/resourceGroups/rg-app/providers/Microsoft.Storage/storageAccounts/sa-one" }
            'NotGuid' { $D.ResourceIdMap["/subscriptions/$($T.Sub)/resourcegroups/$($T.Rg)/providers/Microsoft.Storage/storageAccounts/$($T.Sa)"] = '/subscriptions/not-a-subscription-id/resourceGroups/rg-app/providers/Microsoft.Storage/storageAccounts/sa-one' }
        }
        $R = Invoke-OldReveal -Dict $D -Mode $Mode
        $R.Error | Should -Not -BeNullOrEmpty -Because 'any other clash of the shared token still stops Reveal'
        $Msg = $R.Error.Exception.Message
        $Msg | Should -Match ([regex]::Escape($T.Sub)) -Because 'the message names the token'
        foreach ($P in $Places) { $Msg | Should -Match ([regex]::Escape($P)) -Because 'the message names both places' }
        $Msg | Should -Match ([regex]::Escape($Why))
        $Msg | Should -Match ([regex]::Escape('Nothing was written.'))
        $Msg | Should -Match ([regex]::Escape('A run of this build gives each value a token of its own')) -Because 'older builds wrote one token for two subscription ids'
        foreach ($Real in $script:OldSub1, $script:OldSub2, $script:OldSubName, 'not-a-subscription-id', 'sa-one', 'vm-one', 'rg-app') { $Msg | Should -Not -Match ([regex]::Escape($Real)) -Because 'the message holds no real value' }
        Test-Path -LiteralPath $R.OutputZip | Should -BeFalse -Because 'no output zip is written'
        Test-Path -LiteralPath (($R.OutputZip -replace '\.zip$', '') + '.partial.zip') | Should -BeFalse -Because 'no partial zip is left'
        (Get-FileHash -LiteralPath $script:OldZip -Algorithm SHA256).Hash | Should -Be $script:OldZipHash
    }
}

# Older builds of this fork read a segment 3 'resourceGroups' as a group slot in a tenant-scope id
# too, so '/providers/<namespace>/resourceGroups/<x>' got the token of group <x> (keyed by the
# group's name), and its masked id went into ResourceIdMap like every id the run masked.
# ResourceGroupMap keeps the last id the writer met for that token: the group's own subscription
# id, or the tenant-scope id. Reveal takes that token in that one name slot when its real value
# there is the group's, and still stops on any other kind clash.
Describe "Reveal-Obfuscation reads an older dictionary that gave a tenant-scope id after the type word resourceGroups a group's token" {

    BeforeAll {
        $script:TgSub = '12345678-1234-1234-1234-123456789012'
        $script:TgTok = @{}
        foreach ($K in 'Sub', 'Rg', 'Vm', 'Rg2', 'Vm2') { $script:TgTok[$K] = 'prod_' + [guid]::NewGuid().ToString() }
        $T = $script:TgTok
        $script:TgRVm = "/subscriptions/$($script:TgSub)/resourceGroups/grp-a/providers/Microsoft.Compute/virtualMachines/vm-a"
        $script:TgMVm = "/subscriptions/$($T.Sub)/resourceGroups/$($T.Rg)/providers/Microsoft.Compute/virtualMachines/$($T.Vm)"
        # A second group, so -Fields ResourceGroup always has a group to reveal.
        $script:TgRVm2 = "/subscriptions/$($script:TgSub)/resourceGroups/grp-b/providers/Microsoft.Compute/virtualMachines/vm-b"
        $script:TgMVm2 = "/subscriptions/$($T.Sub)/resourceGroups/$($T.Rg2)/providers/Microsoft.Compute/virtualMachines/$($T.Vm2)"
        $script:TgRTen = '/providers/Microsoft.Example/resourceGroups/grp-a'
        $script:TgMTen = "/providers/Microsoft.Example/resourceGroups/$($T.Rg)"

        function New-TgDictionary
        {
            param([string]$GroupMapId, [System.Collections.IDictionary]$Extra)
            $Ids = [ordered]@{ $script:TgMVm = $script:TgRVm; $script:TgMVm2 = $script:TgRVm2; $script:TgMTen = $script:TgRTen }
            if ($Extra) { foreach ($K in $Extra.Keys) { $Ids[$K] = $Extra[$K] } }
            [ordered]@{
                GeneratedAt         = '2026-06-30 00:00:00'
                ResourceIdMap       = $Ids
                ResourceNameMap     = [ordered]@{ $script:TgTok.Vm = $script:TgRVm; $script:TgTok.Vm2 = $script:TgRVm2 }
                SubscriptionMap     = [ordered]@{ $script:TgTok.Sub = $script:TgRVm }
                ResourceGroupMap    = [ordered]@{ $script:TgTok.Rg = $GroupMapId; $script:TgTok.Rg2 = $script:TgRVm2 }
                SubscriptionNameMap = [ordered]@{ $script:TgTok.Sub = 'Contoso' }
            }
        }

        $script:TgDir = Join-Path $script:TmpDir ("tenant_group_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Stage = Join-Path $script:TgDir 'stage'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        [ordered]@{
            VirtualMachines = @(
                [ordered]@{ ID = $script:TgMVm; Name = $T.Vm; Subscription = $T.Sub; ResourceGroup = $T.Rg }
                [ordered]@{ ID = $script:TgMVm2; Name = $T.Vm2; Subscription = $T.Sub; ResourceGroup = $T.Rg2 }
            )
            Examples        = @([ordered]@{ ID = $script:TgMTen })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Stage 'Inventory_TenantGroup.json') -Encoding utf8
        @(
            [pscustomobject]@{ ResourceId = $script:TgMVm; Cost = '1.00' }
            [pscustomobject]@{ ResourceId = $script:TgMTen; Cost = '2.00' }
        ) | Export-Csv -LiteralPath (Join-Path $Stage 'Consumption_TenantGroup.csv') -NoTypeInformation -Encoding utf8
        $script:TgZip = Join-Path $script:TgDir 'ResourcesReport_TenantGroup.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $script:TgZip -Force
        $script:TgZipHash = (Get-FileHash -LiteralPath $script:TgZip -Algorithm SHA256).Hash

        function Invoke-TgReveal
        {
            param([System.Collections.IDictionary]$Dict, [string]$Mode)
            $Dir = Join-Path $script:TgDir ("run_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $File = Join-Path $Dir 'ObfuscationDictionary_TenantGroup.json'
            $Dict | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $File -Encoding utf8
            $Out = Join-Path $Dir 'out.zip'
            $Splat = @{ InputZip = $script:TgZip; DictionaryPath = $File; OutputZip = $Out }
            if ($Mode -eq '-All') { $Splat['All'] = $true } else { $Splat['Fields'] = @('ResourceGroup') }
            $Err = $null
            try { & $script:RevealScript @Splat *>&1 | Out-Null }
            catch { $Err = $_ }
            $Result = [pscustomobject]@{ Error = $Err; OutputZip = $Out; Inventory = $null; Csv = $null }
            if (Test-Path -LiteralPath $Out)
            {
                $Ex = Join-Path $Dir 'ex'
                Expand-Archive -LiteralPath $Out -DestinationPath $Ex -Force
                $Result.Inventory = Get-Content -LiteralPath (Join-Path $Ex 'Inventory_TenantGroup.json') -Raw | ConvertFrom-Json
                $Result.Csv = @(Import-Csv -LiteralPath (Join-Path $Ex 'Consumption_TenantGroup.csv'))
            }
            return $Result
        }
    }

    It "reveals, with <Mode>, the dictionary whose ResourceGroupMap gives the token <Variant>, and gives the tenant-scope id back" -ForEach @(
        foreach ($Mode in '-Fields ResourceGroup', '-All')
        {
            @{ Mode = $Mode; Variant = 'the group''s subscription id'; GroupMapId = 'Vm' }
            @{ Mode = $Mode; Variant = 'the tenant-scope id'; GroupMapId = 'Ten' }
        }
    ) {
        $T = $script:TgTok
        $MapId = if ($GroupMapId -eq 'Vm') { $script:TgRVm } else { $script:TgRTen }
        $R = Invoke-TgReveal -Dict (New-TgDictionary -GroupMapId $MapId) -Mode $Mode
        $R.Error | Should -BeNullOrEmpty -Because 'the token stands for the one real value grp-a in the group slot and in the tenant-scope id'
        Test-Path -LiteralPath $R.OutputZip | Should -BeTrue
        $Vm = @($R.Inventory.VirtualMachines)[0]
        $Ten = @($R.Inventory.Examples)[0]
        # A ResourceGroupMap id that is a tenant-scope id gives no group, so the token stays
        # masked in fields and paths; a whole id still comes back from ResourceIdMap.
        $Group = if ($GroupMapId -eq 'Vm') { 'grp-a' } else { $T.Rg }
        $Vm.ResourceGroup | Should -BeExactly $Group
        @($R.Inventory.VirtualMachines)[1].ResourceGroup | Should -BeExactly 'grp-b' -Because 'the other group is revealed in every mode'
        if ($Mode -eq '-All')
        {
            $Vm.ID | Should -BeExactly $script:TgRVm
            $Ten.ID | Should -BeExactly $script:TgRTen
            @($R.Csv.ResourceId) | Should -Be @($script:TgRVm, $script:TgRTen)
        }
        else
        {
            $Vm.ID | Should -BeExactly $script:TgMVm.Replace("/$($T.Rg)/", "/$Group/")
            # The token's value in the tenant-scope id is the group's, so writing it there is right.
            $Ten.ID | Should -BeExactly ('/providers/Microsoft.Example/resourceGroups/' + $Group)
            @($R.Csv.ResourceId) | Should -Be @($script:TgMVm.Replace("/$($T.Rg)/", "/$Group/"), ('/providers/Microsoft.Example/resourceGroups/' + $Group))
        }
        (Get-FileHash -LiteralPath $script:TgZip -Algorithm SHA256).Hash | Should -Be $script:TgZipHash
    }

    It "still stops with <Mode> when <Case>, and writes nothing" -ForEach @(
        foreach ($Mode in '-Fields ResourceGroup', '-All')
        {
            @{ Mode = $Mode; Case = 'the tenant-scope id holds the group''s token for another name'; Extra = 'OtherName' }
            @{ Mode = $Mode; Case = 'a tenant-scope id holds the group''s token after another type word'; Extra = 'OtherType' }
            @{ Mode = $Mode; Case = 'the group''s token is in no map'; Extra = 'NoMap' }
        }
    ) {
        $T = $script:TgTok
        $D = New-TgDictionary -GroupMapId $script:TgRVm
        switch ($Extra)
        {
            'OtherName' { $D.ResourceIdMap[$script:TgMTen] = '/providers/Microsoft.Example/resourceGroups/grp-other' }
            'OtherType' { $D.ResourceIdMap["/providers/Microsoft.Example/widgets/$($T.Rg)"] = '/providers/Microsoft.Example/widgets/grp-a' }
            'NoMap' { $D.Remove('ResourceGroupMap') }
        }
        $R = Invoke-TgReveal -Dict $D -Mode $Mode
        $R.Error | Should -Not -BeNullOrEmpty -Because 'only that one form, with the group''s own value, is taken'
        $Msg = $R.Error.Exception.Message
        $Msg | Should -Match ([regex]::Escape($T.Rg)) -Because 'the message names the token'
        $Msg | Should -Match ([regex]::Escape('a name slot of a ResourceIdMap id'))
        $Msg | Should -Match ([regex]::Escape('for two kinds of value'))
        $Msg | Should -Match ([regex]::Escape('Nothing was written.'))
        foreach ($Real in 'grp-a', 'grp-other', 'vm-a', $script:TgSub) { $Msg | Should -Not -Match ([regex]::Escape($Real)) -Because 'the message holds no real value' }
        Test-Path -LiteralPath $R.OutputZip | Should -BeFalse -Because 'no output zip is written'
        (Get-FileHash -LiteralPath $script:TgZip -Algorithm SHA256).Hash | Should -Be $script:TgZipHash
    }
}

# With -Fields ResourceId, a whole masked id that ResourceIdMap holds is replaced by its real id
# first, so an id comes back even when the dictionary does not hold its parts one by one (an older
# or partial dictionary). A tenant-scope id ('/providers/<namespace>/<type>/<name>...', a
# reservation order) is a whole id there too.
Describe "Reveal-Obfuscation reveals a tenant-scope id whole from ResourceIdMap" {

    BeforeAll {
        $script:TenSub = '12345678-1234-1234-1234-123456789012'
        $script:TenTok = @{}
        foreach ($K in 'Ro', 'R', 'Other', 'Sub', 'Rg', 'Vm') { $script:TenTok[$K] = 'prod_' + [guid]::NewGuid().ToString() }
        $T = $script:TenTok
        $script:TenIds = [ordered]@{
            Order     = @{ M = "/providers/Microsoft.Capacity/reservationOrders/$($T.Ro)"; R = '/providers/Microsoft.Capacity/reservationOrders/ro-0001' }
            Child     = @{ M = "/providers/Microsoft.Capacity/reservationOrders/$($T.Ro)/reservations/$($T.R)"; R = '/providers/Microsoft.Capacity/reservationOrders/ro-0001/reservations/r-0001' }
            Vm        = @{ M = "/subscriptions/$($T.Sub)/resourcegroups/$($T.Rg)/providers/Microsoft.Compute/virtualMachines/$($T.Vm)"; R = "/subscriptions/$($script:TenSub)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
        }
        # Not in the dictionary: it stays as written.
        $script:TenUnknown = "/providers/Microsoft.Capacity/reservationOrders/$($T.Other)"

        # A report zip of the given ids (inventory rows, consumption rows and their InstanceData)
        # and a dictionary that holds only their ResourceIdMap entries.
        function New-TenantReport
        {
            param([string[]]$Keys)
            $Dir = Join-Path $script:TmpDir ("tenant_whole_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $Stage = Join-Path $Dir 'stage'
            New-Item -ItemType Directory -Path $Stage -Force | Out-Null
            $Rows = @(foreach ($K in $Keys) { [ordered]@{ ID = $script:TenIds[$K].M } })
            $Rows += [ordered]@{ ID = $script:TenUnknown }
            [ordered]@{ Reservations = $Rows } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Stage 'Inventory_Tenant.json') -Encoding utf8
            @(foreach ($K in $Keys)
                {
                    $M = $script:TenIds[$K].M
                    [pscustomobject]@{ ResourceId = $M; InstanceData = (@{ 'Microsoft.Resources' = @{ resourceUri = $M } } | ConvertTo-Json -Compress); Cost = '1.00' }
                }) | Export-Csv -LiteralPath (Join-Path $Stage 'Consumption_Tenant.csv') -NoTypeInformation -Encoding utf8
            $Zip = Join-Path $Dir 'ResourcesReport_Tenant.zip'
            Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
            $Map = [ordered]@{}
            foreach ($K in $Keys) { $Map[$script:TenIds[$K].M] = $script:TenIds[$K].R }
            $DictFile = Join-Path $Dir 'ObfuscationDictionary_Tenant.json'
            [ordered]@{ GeneratedAt = '2026-06-30 00:00:00'; ResourceIdMap = $Map } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $DictFile -Encoding utf8
            return [pscustomobject]@{ Dir = $Dir; Zip = $Zip; Dict = $DictFile }
        }
    }

    It "reveals, with <Mode>, every id of a <Report> report from a dictionary that holds only ResourceIdMap, and leaves an id it does not hold as written" -ForEach @(
        foreach ($Mode in '-Fields ResourceId', '-All')
        {
            @{ Mode = $Mode; Report = 'tenant-scope only'; Keys = @('Order', 'Child') }
            @{ Mode = $Mode; Report = 'mixed tenant-scope and subscription'; Keys = @('Vm', 'Order', 'Child') }
        }
    ) {
        $Rep = New-TenantReport -Keys $Keys
        $Out = Join-Path $Rep.Dir 'out.zip'
        $Splat = @{ InputZip = $Rep.Zip; DictionaryPath = $Rep.Dict; OutputZip = $Out }
        if ($Mode -eq '-All') { $Splat['All'] = $true } else { $Splat['Fields'] = @('ResourceId') }
        & $script:RevealScript @Splat *>&1 | Out-Null
        Test-Path -LiteralPath $Out | Should -BeTrue
        $Ex = Join-Path $Rep.Dir 'ex'
        Expand-Archive -LiteralPath $Out -DestinationPath $Ex -Force
        $Inv = Get-Content -LiteralPath (Join-Path $Ex 'Inventory_Tenant.json') -Raw | ConvertFrom-Json
        $Csv = @(Import-Csv -LiteralPath (Join-Path $Ex 'Consumption_Tenant.csv'))
        $Want = @(foreach ($K in $Keys) { $script:TenIds[$K].R })
        @($Inv.Reservations.ID) | Should -Be @($Want + $script:TenUnknown)
        @($Csv.ResourceId) | Should -Be $Want
        @($Csv | ForEach-Object { ($_.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri }) | Should -Be $Want -Because 'an id inside a JSON cell is revealed too'
    }
}

Describe "Reveal's doc on a dictionary it refuses" {

    It "says that Reveal refuses a dictionary that gives one token to two maps, or whose ids hold a token for another kind of value or real value, writes nothing, and that the fix is the dictionary the run wrote" {
        $Doc = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs/obfuscation-and-unmask.md') -Raw
        $Flat = $Doc -replace '\s+', ' '
        $Flat | Should -Match ([regex]::Escape('stops with an error and writes no output zip when the dictionary gives one token to two maps'))
        $Flat | Should -Match ([regex]::Escape('other than a subscription''s token, which `SubscriptionMap` and `SubscriptionNameMap` both hold'))
        $Flat | Should -Match ([regex]::Escape('when an id in `ResourceIdMap` holds a token as another kind of value'))
        $Flat | Should -Match ([regex]::Escape('or for another real value'))
        $Flat | Should -Match ([regex]::Escape('use the dictionary the run wrote with the report, not one edited or merged by hand'))
    }

    It "says that older builds gave two subscriptions with one display name one token, what Reveal does with that token, and that only a run of this build never writes a dictionary Reveal refuses" {
        $Doc = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs/obfuscation-and-unmask.md') -Raw
        $Flat = $Doc -replace '\s+', ' '
        $Flat | Should -Not -Match ([regex]::Escape('A run never writes such a dictionary')) -Because 'older builds wrote one token for two subscription ids'
        $Flat | Should -Match ([regex]::Escape('A run of this build never writes such a dictionary'))
        $Flat | Should -Match ([regex]::Escape('Older builds keyed a subscription''s token by its display name'))
        $Flat | Should -Match ([regex]::Escape('writes the display name in subscription fields and each whole id that `ResourceIdMap` holds, leaves the token masked in any other id path, and warns'))
    }

    It "says that Reveal takes an older build's group token in a tenant-scope id after the type word resourceGroups only when the name there is the group's" {
        $Doc = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs/obfuscation-and-unmask.md') -Raw
        $Flat = $Doc -replace '\s+', ' '
        $Flat | Should -Match ([regex]::Escape('Older builds also gave the name in a tenant-scope id `/providers/<namespace>/resourceGroups/<x>` the token of group `<x>`.'))
        $Flat | Should -Match ([regex]::Escape('takes a group''s token in that one place when the id''s real name there is that group''s name, and stops on any other use of a group''s token as a name'))
    }
}

# =============================================================================
# FreeText round-trip via FreeTextMap (P3) — fixture-independent
# -----------------------------------------------------------------------------
# Task 5.2 | Requirements 5.2, 5.3 | Property: P3
#
# Closes a coverage gap. The live-dictionary determinism block in
# Obfuscation.Tests.ps1 ("FreeText: each real free-text value maps to exactly
# one token", P1 / Req 5.3) SKIPS whenever the run's FreeTextMap is empty —
# which it is for the current obfuscated fixture — and the reveal FreeText
# tests above exercise only a single token occurrence. These assertions depend
# on neither: they build a self-contained obfuscated bundle whose FreeText
# tokens model a deterministic Protect-FreeTextValue output (a real value seen
# twice yields ONE shared token, a distinct value gets a distinct token) plus a
# matching FreeTextMap, then run the real Reveal-Obfuscation substitution path
# and prove the round-trip:
#   - the tokens are present in the obfuscated ZIP and resolve to real values
#     via FreeTextMap (Req 5.2), each stored value being a real value — not a
#     token, null, or the 'obfuscated' sentinel (lossless intent);
#   - a real value that appears more than once carries a single shared token
#     (Req 5.3) and every occurrence round-trips back to that same real value,
#     i.e. reveal(obfuscate(x)) == x (P3).
# The real->token determinism itself is asserted against a live dictionary by
# the P1 FreeTextMap block in Obfuscation.Tests.ps1; this block is its
# fixture-independent round-trip counterpart and does not duplicate it. No
# customer data: tokens are runtime GUIDs, the only literal GUID is the Azure
# docs placeholder, and the free-text values are synthetic.
# =============================================================================
Describe "Reveal-Obfuscation FreeText round-trip via FreeTextMap (P3)" {

    BeforeAll {
        $SubGuid = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
        $Base = "/subscriptions/$SubGuid/resourceGroups/rg-p3/providers/Microsoft.Compute/virtualMachines"

        # Tokens modelling a deterministic obfuscator run: vmA and vmB shared the
        # SAME real free-text value, so Protect-FreeTextValue would have emitted a
        # single shared token for both; vmC had a distinct value -> distinct token.
        $script:P3TokShared = 'prod_' + [guid]::NewGuid().ToString()
        $script:P3TokOther = 'nonprod_' + [guid]::NewGuid().ToString()

        $script:P3RealShared = 'created-by: platform-team (owner of record)'
        $script:P3RealOther = 'runbook: nightly-maintenance, stage=qa'

        # vmA and vmB carry the shared token in a free-text field; vmC the other.
        $script:P3Inventory = [ordered]@{
            VirtualMachines = @(
                [ordered]@{ Name = 'a'; ResourceGroup = 'rg-p3'; CreatedBy = $script:P3TokShared }
                [ordered]@{ Name = 'b'; ResourceGroup = 'rg-p3'; CreatedBy = $script:P3TokShared }
                [ordered]@{ Name = 'c'; ResourceGroup = 'rg-p3'; RoleName = $script:P3TokOther }
            )
        }

        $VmId = "$Base/vm-p3"
        $script:P3Dict = [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $VmId }
            ResourceNameMap  = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $VmId }
            SubscriptionMap  = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $VmId }
            ResourceGroupMap = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $VmId }
            FreeTextMap      = [ordered]@{
                $script:P3TokShared = $script:P3RealShared
                $script:P3TokOther  = $script:P3RealOther
            }
        }

        $script:P3Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("RevealP3_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:P3Dir -Force | Out-Null

        $StageDir = Join-Path $script:P3Dir 'stage'
        New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
        $InvPath = Join-Path $StageDir 'Inventory_P3.json'
        $script:P3Inventory | ConvertTo-Json -Depth 8 | Set-Content -Path $InvPath -Encoding utf8

        $script:P3InputZip = Join-Path $script:P3Dir 'ResourcesReport_P3.zip'
        Compress-Archive -Path (Join-Path $StageDir '*') -DestinationPath $script:P3InputZip -Force

        $script:P3DictPath = Join-Path $script:P3Dir 'ObfuscationDictionary_P3.json'
        $script:P3Dict | ConvertTo-Json -Depth 6 | Set-Content -Path $script:P3DictPath -Encoding utf8

        # Raw pre-reveal obfuscated inventory (proves the tokens are IN the ZIP).
        $script:P3RawObfuscated = Get-Content -Path $InvPath -Raw

        # Run the real reveal substitution path for FreeText only.
        $Out = Join-Path $script:P3Dir 'ResourcesReport_P3_revealed.zip'
        & $script:RevealScript -InputZip $script:P3InputZip -DictionaryPath $script:P3DictPath -Fields FreeText -OutputZip $Out *>&1 | Out-Null
        $Ex = Join-Path $script:P3Dir 'ex'
        Expand-Archive -Path $Out -DestinationPath $Ex -Force
        $InvFile = Get-ChildItem $Ex -Filter 'Inventory_*.json' | Select-Object -First 1
        $script:P3Revealed = Get-Content $InvFile.FullName -Raw | ConvertFrom-Json

        $script:P3TokenRegex = '^(?:prod|nonprod)_(?:[a-z0-9]+_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    }

    AfterAll {
        if ($script:P3Dir -and (Test-Path $script:P3Dir))
        {
            Remove-Item -Path $script:P3Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "the free-text tokens are present in the obfuscated ZIP (pre-reveal)" {
        $script:P3RawObfuscated | Should -Match ([regex]::Escape($script:P3TokShared))
        $script:P3RawObfuscated | Should -Match ([regex]::Escape($script:P3TokOther))
    }

    It "FreeTextMap resolves each token to a real value (not a token, null, or the 'obfuscated' sentinel)" {
        foreach ($tok in @($script:P3TokShared, $script:P3TokOther))
        {
            $Real = $script:P3Dict.FreeTextMap[$tok]
            $Real | Should -Not -BeNullOrEmpty
            $Real | Should -Not -Match $script:P3TokenRegex
            $Real | Should -Not -Be 'obfuscated'
        }
    }

    It "a real value seen more than once carries a single shared token in the obfuscated ZIP (Req 5.3)" {
        # vmA and vmB shared one real free-text value -> one shared token.
        $script:P3Inventory.VirtualMachines[0].CreatedBy | Should -Be $script:P3Inventory.VirtualMachines[1].CreatedBy
        $script:P3Inventory.VirtualMachines[0].CreatedBy | Should -Be $script:P3TokShared
    }

    It "every occurrence of the shared token round-trips to the same real value (P3)" {
        $script:P3Revealed.VirtualMachines[0].CreatedBy | Should -Be $script:P3RealShared
        $script:P3Revealed.VirtualMachines[1].CreatedBy | Should -Be $script:P3RealShared
        # both came back to the SAME real value from a single shared token
        $script:P3Revealed.VirtualMachines[0].CreatedBy | Should -Be $script:P3Revealed.VirtualMachines[1].CreatedBy
    }

    It "a distinct free-text value round-trips to its own real value (P3)" {
        $script:P3Revealed.VirtualMachines[2].RoleName | Should -Be $script:P3RealOther
    }

    It "no free-text token survives the round-trip reveal" {
        $script:P3Revealed.VirtualMachines[0].CreatedBy | Should -Not -Match $script:P3TokenRegex
        $script:P3Revealed.VirtualMachines[1].CreatedBy | Should -Not -Match $script:P3TokenRegex
        $script:P3Revealed.VirtualMachines[2].RoleName  | Should -Not -Match $script:P3TokenRegex
    }
}

# =============================================================================
# Explicit -Fields subset reveal isolation (P4) — Task 7.2 | Requirements 7.2, 7.3
# -----------------------------------------------------------------------------
# Task 7.1 (the "default fields" Describe near the top) covers the no--Fields
# default (ResourceGroup + Subscription). These blocks close the EXPLICIT-subset
# gap for Property P4 (selective isolation / no bleed): for each single dimension
# named explicitly on its own via -Fields, and for a multi-dimension subset,
# assert the named dimension(s) round-trip to the real value AND every OTHER
# dimension's token is left unchanged (still masked).
#
# The synthetic vm01 (VirtualMachines[0]) built in the top-level BeforeAll carries
# all six revealable dimensions at once (ID, Name, Subscription, ResourceGroup,
# Tags[0].Value, Description), so a single reveal per field set proves both the
# reveal and the no-bleed for the remaining dimensions. Reuses that fixture, its
# $script:Tok*/Real* vars and the Invoke-Reveal helper; no new fixture, no
# customer data (tokens are runtime GUIDs; the only literal GUID is the Azure docs
# placeholder inside the synthetic ARM paths).
#
# Non-duplication: the single-dimension ResourceName, ResourceId and FreeText
# reveals (plus one no-bleed check each) are already asserted by the "opt-in
# ResourceName / ResourceId" and "-Fields FreeText" Describes above, so the
# corresponding contexts here add ONLY the remaining previously-unchecked
# no-bleed dimensions for those three. The ResourceGroup-only, Subscription-only,
# Tag-only single-dimension cases and the two-dimension subset are entirely new.
# =============================================================================
Describe "Reveal-Obfuscation explicit -Fields subset isolation (P4)" {

    Context "single dimension: -Fields ResourceGroup" {

        BeforeAll { $script:P4Rg = Invoke-Reveal -Fields @('ResourceGroup') }

        It "reveals the resource group name" {
            $script:P4Rg.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
        }
        It "leaves Subscription masked (no bleed)" {
            $script:P4Rg.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves Resource Name masked (no bleed)" {
            $script:P4Rg.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
        }
        It "leaves Resource Id masked (no bleed)" {
            $script:P4Rg.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
        }
        It "leaves the tag value masked (no bleed)" {
            $script:P4Rg.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Rg.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }

    Context "single dimension: -Fields Subscription" {

        BeforeAll { $script:P4Sub = Invoke-Reveal -Fields @('Subscription') }

        It "reveals the subscription friendly name" {
            $script:P4Sub.Inventory.VirtualMachines[0].Subscription | Should -Be $script:RealSubName
        }
        It "leaves Resource Group masked (no bleed)" {
            $script:P4Sub.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:TokRg
        }
        It "leaves Resource Name masked (no bleed)" {
            $script:P4Sub.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
        }
        It "leaves Resource Id masked (no bleed)" {
            $script:P4Sub.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
        }
        It "leaves the tag value masked (no bleed)" {
            $script:P4Sub.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Sub.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }

    Context "single dimension: -Fields Tag" {

        BeforeAll { $script:P4Tag = Invoke-Reveal -Fields @('Tag') }

        It "reveals the tag value" {
            $script:P4Tag.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
        }
        It "keeps the tag key verbatim" {
            $script:P4Tag.Inventory.VirtualMachines[0].Tags[0].Name | Should -Be 'environment'
        }
        It "leaves Resource Group masked (no bleed)" {
            $script:P4Tag.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:TokRg
        }
        It "leaves Subscription masked (no bleed)" {
            $script:P4Tag.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves Resource Name masked (no bleed)" {
            $script:P4Tag.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
        }
        It "leaves Resource Id masked (no bleed)" {
            $script:P4Tag.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Tag.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }

    Context "single dimension: -Fields ResourceName (no-bleed completion)" {
        # The reveal (Name -> 'vm01') and the ID-masked no-bleed check are already
        # asserted by the "opt-in ResourceName / ResourceId" Describe; assert ONLY
        # the remaining previously-unchecked no-bleed dimensions here.
        BeforeAll { $script:P4Name = Invoke-Reveal -Fields @('ResourceName') }

        It "leaves Subscription masked (no bleed)" {
            $script:P4Name.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves Resource Group masked (no bleed)" {
            $script:P4Name.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:TokRg
        }
        It "leaves the tag value masked (no bleed)" {
            $script:P4Name.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Name.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }

    Context "single dimension: -Fields ResourceId (no-bleed completion)" {
        # The reveal (ID -> full ARM path) and the Name-masked no-bleed check are
        # already asserted by the "opt-in ResourceName / ResourceId" Describe;
        # assert ONLY the remaining previously-unchecked no-bleed dimensions here.
        BeforeAll { $script:P4Id = Invoke-Reveal -Fields @('ResourceId') }

        It "leaves Subscription masked (no bleed)" {
            $script:P4Id.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves the Resource Group token masked (no bleed)" {
            # VM[0].ResourceGroup holds the RG *token*, which is distinct from the
            # RG name embedded inside the revealed ResourceId ARM path.
            $script:P4Id.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:TokRg
        }
        It "leaves the tag value masked (no bleed)" {
            $script:P4Id.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Id.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }

    Context "single dimension: -Fields FreeText (no-bleed completion)" {
        # The reveal (Description -> real value) and the RG-masked no-bleed check
        # are already asserted by the "-Fields FreeText" Describe; assert ONLY the
        # remaining previously-unchecked no-bleed dimensions here.
        BeforeAll { $script:P4Free = Invoke-Reveal -Fields @('FreeText') }

        It "leaves Subscription masked (no bleed)" {
            $script:P4Free.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves Resource Name masked (no bleed)" {
            $script:P4Free.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
        }
        It "leaves Resource Id masked (no bleed)" {
            $script:P4Free.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
        }
        It "leaves the tag value masked (no bleed)" {
            $script:P4Free.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
        }
    }

    Context "multi-dimension subset: -Fields ResourceGroup,Tag" {

        BeforeAll { $script:P4Multi = Invoke-Reveal -Fields @('ResourceGroup', 'Tag') }

        It "reveals the resource group name (named dimension)" {
            $script:P4Multi.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
        }
        It "reveals the tag value (named dimension)" {
            $script:P4Multi.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
        }
        It "leaves Subscription masked (no bleed)" {
            $script:P4Multi.Inventory.VirtualMachines[0].Subscription | Should -Be $script:TokSub
        }
        It "leaves Resource Name masked (no bleed)" {
            $script:P4Multi.Inventory.VirtualMachines[0].Name | Should -Be $script:TokName
        }
        It "leaves Resource Id masked (no bleed)" {
            $script:P4Multi.Inventory.VirtualMachines[0].ID | Should -Be $script:TokId
        }
        It "leaves free-text masked (no bleed)" {
            $script:P4Multi.Inventory.VirtualMachines[0].Description | Should -Be $script:TokFree
        }
    }
}

# =============================================================================
# Full reveal -All: overrides -Fields + lossy-fields warning
#   Task 8 | Requirements 8.1, 8.3 | Property: P3
# -----------------------------------------------------------------------------
# The "Reveal-Obfuscation -All full reveal" Describe above already asserts that
# -All restores all six dictionary-backed dimensions in one pass (Req 8.1/8.2,
# P3) and leaves the lossy 'obfuscated' sentinel unrecovered (Req 8.3). These
# blocks close the two remaining Req 8 gaps, reusing the top-level synthetic
# fixture (vm01 carries all six revealable dimensions plus an 'obfuscated'
# sentinel) and the Invoke-Reveal helper:
#   - Req 8.1 (override): passing '-All -Fields Subscription' must STILL reveal
#     every dimension, not just Subscription. If -Fields had won, RG / Name / Id
#     / Tag / FreeText would remain tokenized; asserting they are all revealed
#     proves -All clobbered the explicit -Fields value. Invoke-Reveal forwards
#     both switches, so this exercises the real precedence path.
#   - Req 8.3 (warning): on completion under -All the reveal script surfaces a
#     lossy-fields notice (a yellow host line naming values nulled at
#     obfuscation time / stamped 'obfuscated' as unrecoverable). This captures
#     the script's merged output stream (*>&1 - the same capture the rest of
#     this file uses to invoke the script, and the stream Write-Host lands on
#     under PowerShell 7) and asserts the notice is present, then confirms the
#     'obfuscated' sentinel indeed survives unrecovered in that same -All output.
# No production/reveal-logic change - assertions only. No customer data: reuses
# runtime-GUID tokens and the Azure docs placeholder GUID from the fixture.
# =============================================================================
Describe "Reveal-Obfuscation -All overrides -Fields and warns of lossy fields (Req 8.1, 8.3, P3)" {

    Context "-All overrides an explicit -Fields value" {

        BeforeAll { $script:AllOverride = Invoke-Reveal -All -Fields @('Subscription') }

        It "still reveals the resource group name (RG not named in -Fields)" {
            $script:AllOverride.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
        }
        It "reveals the subscription friendly name (the one dimension -Fields named)" {
            $script:AllOverride.Inventory.VirtualMachines[0].Subscription | Should -Be $script:RealSubName
        }
        It "still reveals the resource short name (not named in -Fields)" {
            $script:AllOverride.Inventory.VirtualMachines[0].Name | Should -Be 'vm01'
        }
        It "still reveals the full ARM resource Id (not named in -Fields)" {
            $script:AllOverride.Inventory.VirtualMachines[0].ID | Should -Be "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"
        }
        It "still reveals the tag value (not named in -Fields)" {
            $script:AllOverride.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
        }
        It "still reveals free-text fields (not named in -Fields)" {
            $script:AllOverride.Inventory.VirtualMachines[0].Description | Should -Be $script:RealFreeText
        }
    }

    Context "-All emits the lossy-fields warning" {

        BeforeAll {
            $script:AllWarnOut = Join-Path $script:TmpDir ("allwarn_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".zip")
            # Capture the script's merged output stream (*>&1), matching how this
            # file already invokes the reveal script; the lossy-fields notice is
            # surfaced on completion when -All is supplied.
            $script:AllWarnStream = & $script:RevealScript -InputZip $script:InputZip -DictionaryPath $script:DictPath -All -OutputZip $script:AllWarnOut *>&1
            $script:AllWarnText = ($script:AllWarnStream | Out-String)
        }

        It "warns that fields are lossy and remain unrecoverable" {
            $script:AllWarnText | Should -Match 'lossy'
            $script:AllWarnText | Should -Match '(?i)remain'
        }

        It "names the 'obfuscated' sentinel as unrecovered in the warning" {
            $script:AllWarnText | Should -Match 'obfuscated'
        }

        It "leaves the 'obfuscated' sentinel unrecovered in the -All output" {
            $Ex = Join-Path $script:TmpDir ("allwarn_ex_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            Expand-Archive -Path $script:AllWarnOut -DestinationPath $Ex -Force
            $InvFile = Get-ChildItem $Ex -Filter 'Inventory_*.json' | Select-Object -First 1
            $Inv = Get-Content $InvFile.FullName -Raw | ConvertFrom-Json
            $Inv.VirtualMachines[0].Set | Should -Be 'obfuscated'
        }
    }
}

# =============================================================================
# Structural preservation (P5) — Task 9.1 | Requirements 7.4 | Property: P5
# -----------------------------------------------------------------------------
# Reveal-Obfuscation.ps1 preserves structure by extracting the input ZIP
# (Expand-Archive, line 304), rewriting each member IN PLACE under its original
# filename through the format-correct writer (CSV via Export-Csv line 365,
# JSON/HTML via Set-Content line 385 after the escapeMode switch at line 374),
# and re-zipping the same temp tree (Compress-Archive line 397) — so member
# names never change and every member stays valid in its own format.
#
# These assertions close the P5 gap left by the rest of this file: the default
# "produces valid JSON that re-parses" check is incidental (it only inspects the
# Inventory object the helper already parsed), and the CSV/HTML checks above are
# value/escaping (P9) assertions, not structure-parity ones. NONE of them (a)
# compare the revealed ZIP's member SET/filenames to the input ZIP's, (b) assert
# every JSON member re-parses with no error, (c) compare revealed CSV column
# headers to the INPUT's headers, or (d) check the HTML member is well-formed.
# This block adds exactly those four, reusing the top-level synthetic fixture
# (Inventory JSON + Consumption CSV + HTML report members), the Invoke-Reveal
# helper, and the top-level AfterAll (the two extraction dirs live under
# $script:TmpDir, so they are cleaned with it). No production/reveal-logic
# change — assertions only. No customer data: reuses runtime-GUID tokens and the
# Azure docs placeholder GUID from the fixture; revealed values are synthetic.
# =============================================================================
Describe "Reveal-Obfuscation structural preservation (P5, Req 7.4)" {

    BeforeAll {
        # Reveal with the default fields (ResourceGroup + Subscription) into a
        # fresh output zip; then extract BOTH the input and revealed zips
        # independently so member sets and per-member content can be compared
        # without depending on the reveal helper's internal extraction.
        $script:P5Result = Invoke-Reveal
        $script:P5RevealedZip = $script:P5Result.OutputZip

        $script:P5InExtract = Join-Path $script:TmpDir ("p5_in_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:P5OutExtract = Join-Path $script:TmpDir ("p5_out_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Expand-Archive -Path $script:InputZip      -DestinationPath $script:P5InExtract  -Force
        Expand-Archive -Path $script:P5RevealedZip -DestinationPath $script:P5OutExtract -Force

        $script:P5InNames = @(Get-ChildItem -Path $script:P5InExtract  -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
        $script:P5OutNames = @(Get-ChildItem -Path $script:P5OutExtract -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
    }

    It "the revealed ZIP has the same member set/filenames as the input ZIP" {
        # Join to a stable string so the comparison is order-independent (both
        # sides are sorted) and unambiguous for array equality.
        ($script:P5OutNames -join '|') | Should -Be ($script:P5InNames -join '|')
    }

    It "the revealed ZIP has the same member count as the input ZIP" {
        $script:P5OutNames.Count | Should -Be $script:P5InNames.Count
    }

    It "every revealed JSON member re-parses via ConvertFrom-Json without error" {
        $JsonFiles = @(Get-ChildItem -Path $script:P5OutExtract -Recurse -File -Filter '*.json')
        $JsonFiles.Count | Should -BeGreaterThan 0
        foreach ($JsonFile in $JsonFiles)
        {
            { Get-Content -Path $JsonFile.FullName -Raw | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    It "every revealed CSV member re-imports with the same column headers and row count as the input" {
        $OutCsvFiles = @(Get-ChildItem -Path $script:P5OutExtract -Recurse -File -Filter '*.csv')
        $OutCsvFiles.Count | Should -BeGreaterThan 0
        foreach ($OutCsvFile in $OutCsvFiles)
        {
            $InCsvPath = Join-Path $script:P5InExtract $OutCsvFile.Name
            Test-Path -Path $InCsvPath | Should -BeTrue

            $InRows = @(Import-Csv -Path $InCsvPath)
            $OutRows = @(Import-Csv -Path $OutCsvFile.FullName)

            $InHeaders = @($InRows[0].PSObject.Properties.Name)
            $OutHeaders = @($OutRows[0].PSObject.Properties.Name)

            ($OutHeaders -join '|') | Should -Be ($InHeaders -join '|')
            $OutRows.Count | Should -Be $InRows.Count
        }
    }

    It "every revealed HTML member is well-formed (loads without error)" {
        $HtmlFiles = @(Get-ChildItem -Path $script:P5OutExtract -Recurse -File | Where-Object { $_.Extension -in '.html', '.htm' })
        $HtmlFiles.Count | Should -BeGreaterThan 0
        foreach ($HtmlFile in $HtmlFiles)
        {
            # Lightweight well-formedness check: the synthetic report member has a
            # single root element with balanced tags and entity-encoded values
            # (the reveal HTML branch emits '&amp;' etc.), so it loads as XML.
            # This proves the revealed member stayed structurally intact rather
            # than being corrupted by a raw substitution.
            $Raw = Get-Content -Path $HtmlFile.FullName -Raw
            { [xml]$Raw } | Should -Not -Throw
        }
    }
}

# =============================================================================
# No-op byte equality (P6) — Task 9.2 | Requirements 9.4 | Property: P6
# -----------------------------------------------------------------------------
# Reveal-Obfuscation.ps1 leaves a member with NO selected tokens byte-for-byte
# unchanged: it re-writes a member only when that member's per-file hit counter
# is greater than zero. CSV members are re-exported only under
# `if ($script:fileHits -gt 0)` (Export-Csv, line 363-366); JSON/HTML/other
# members are re-written only under the same guard (Set-Content, line 383-386).
# A zero-hit member is therefore never opened for write on disk, so it survives
# the extract -> (no change) -> re-zip -> extract round-trip with identical
# bytes.
#
# This closes the P6 gap the rest of this file leaves open. The nearest existing
# checks assert something different:
#   - "does not mutate the input zip" hashes the INPUT zip (input immutability,
#     not an output member being unchanged);
#   - the P5 structural block compares member SET/filenames, JSON re-parse, CSV
#     header/row parity, and HTML well-formedness — none of which is a byte
#     comparison (a re-quoted or re-encoded member can pass all four yet differ
#     byte-for-byte);
#   - the FreeText/Tag "no-op" checks assert a token value is unchanged in the
#     PARSED object, not that the raw member bytes are identical.
#
# Approach: reveal ONLY the Tag dimension against the top-level synthetic
# fixture. The Tag token ($script:TokTag) lives EXCLUSIVELY in the Inventory
# JSON member, so:
#   - Inventory_Test.json       -> has Tag hits  -> rewritten (proves reveal ran)
#   - Consumption_Test.csv      -> zero Tag hits -> must be byte-identical
#   - ResourcesReport_Test.html -> zero Tag hits -> must be byte-identical
# (The CSV/HTML carry only Subscription/ResourceGroup tokens, which are NOT in
# the replacement map when -Fields is Tag, so their hit counters stay zero.)
# Byte equality is proved with a SHA256 hash of each member extracted from the
# input ZIP vs the revealed ZIP. Reuses the top-level fixture, its
# $script:Tok*/Real* vars, and the Invoke-Reveal helper; the two extraction dirs
# live under $script:TmpDir, so the top-level AfterAll cleans them. No
# production/reveal-logic change — assertions only. No customer data: reuses
# runtime-GUID tokens and the Azure docs placeholder GUID from the fixture.
# =============================================================================
Describe "Reveal-Obfuscation no-op byte equality (P6, Req 9.4)" {

    BeforeAll {
        # Reveal ONLY Tag: the tag token is present only in the Inventory JSON,
        # leaving the CSV and HTML members with zero selected-token hits.
        $script:P6Result = Invoke-Reveal -Fields @('Tag')

        $script:P6InExtract = Join-Path $script:TmpDir ("p6_in_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:P6OutExtract = Join-Path $script:TmpDir ("p6_out_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Expand-Archive -Path $script:InputZip           -DestinationPath $script:P6InExtract  -Force
        Expand-Archive -Path $script:P6Result.OutputZip -DestinationPath $script:P6OutExtract -Force
    }

    It "reveals the Tag token in the member that DOES contain it (guards against a vacuous no-op)" {
        # If the reveal had done nothing at all, a byte-identical CSV/HTML would
        # prove nothing. Confirm the Tag value was actually revealed in Inventory.
        $script:P6Result.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:RealTagVal
    }

    It "leaves a CSV member with no selected tokens byte-for-byte identical (SHA256)" {
        $InCsv = Join-Path $script:P6InExtract  'Consumption_Test.csv'
        $OutCsv = Join-Path $script:P6OutExtract 'Consumption_Test.csv'
        Test-Path -Path $InCsv  | Should -BeTrue
        Test-Path -Path $OutCsv | Should -BeTrue
        (Get-FileHash -Path $OutCsv -Algorithm SHA256).Hash | Should -Be (Get-FileHash -Path $InCsv -Algorithm SHA256).Hash
    }

    It "leaves an HTML member with no selected tokens byte-for-byte identical (SHA256)" {
        $InHtml = Join-Path $script:P6InExtract  'ResourcesReport_Test.html'
        $OutHtml = Join-Path $script:P6OutExtract 'ResourcesReport_Test.html'
        Test-Path -Path $InHtml  | Should -BeTrue
        Test-Path -Path $OutHtml | Should -BeTrue
        (Get-FileHash -Path $OutHtml -Algorithm SHA256).Hash | Should -Be (Get-FileHash -Path $InHtml -Algorithm SHA256).Hash
    }
}

# =============================================================================
# Per-format escaping safety (P9) — Task 10 | Requirements 9.1, 9.2, 9.3
# -----------------------------------------------------------------------------
# Reveal-Obfuscation.ps1 escapes each revealed value to match its destination
# member's format so a real value carrying format-significant characters cannot
# corrupt the file:
#   - .json  -> Get-JsonEscaped (ConvertTo-Json -Compress then strip the
#               wrapping quotes) so the value is a valid JSON string literal
#               (Reveal-Obfuscation.ps1 lines 290-298; invoked at line 327).
#   - .csv   -> per-field raw reveal (Convert-RevealString -EscapeMode 'None',
#               line 359) then re-emit through Export-Csv (line 366), which
#               re-quotes any field containing a comma/quote/newline so columns
#               stay intact.
#   - .html  -> [System.Net.WebUtility]::HtmlEncode (line 328) so '&', '<', '>'
#               and '"' become entities, matching the report's own encoding.
#
# This closes the P9 gap the rest of this file leaves open. The existing
# escaping checks in the "default fields" Describe exercise only a SUBSET of the
# format-significant characters and only two of the three formats:
#   - the HTML check uses $RealSubName ('Contoso, Inc. (Prod) & Co'), so only
#     '&' is exercised for HTML — never '<' or '"';
#   - the CSV check exercises only the embedded comma from the same value —
#     never an embedded quote or newline;
#   - no assertion anywhere feeds a JSON member a value bearing the
#     JSON-significant characters ('"', backslash, newline) and proves the
#     member re-parses to the exact real value.
#
# This block builds a DEDICATED synthetic obfuscated bundle whose single
# revealable (FreeText) value carries ALL of { '"', ',', '&', '<', newline }
# (plus '>'), embeds the SAME token in a JSON member, a CSV member and an HTML
# member, runs the real Reveal-Obfuscation.ps1 FreeText substitution path, and
# asserts per format:
#   - JSON  (Req 9.1): the member re-parses via ConvertFrom-Json AND the revealed
#     field equals the exact real value (proving proper string-literal escaping
#     of the quote/backslash/newline/'<'/'&').
#   - CSV   (Req 9.2): Import-Csv yields the SAME column set, the row count is
#     unchanged, the neighbouring column is untouched (columns did not split on
#     the embedded comma/quote/newline) and the revealed field round-trips to the
#     exact real value.
#   - HTML  (Req 9.3): the member is well-formed ([xml] load) AND the raw member
#     contains the value entity-encoded exactly as [System.Net.WebUtility]::HtmlEncode
#     produces (matching the report's own encoding), with the token consumed.
#
# No production/reveal-logic change — assertions only. No customer data: the
# token is a runtime GUID, the only literal GUID is the Azure docs placeholder
# inside the synthetic ARM paths, and the free-text value is synthetic. The
# dedicated fixture lives under its own temp dir and is removed in AfterAll.
# =============================================================================
Describe "Reveal-Obfuscation per-format escaping safety (P9, Req 9.1/9.2/9.3)" {

    BeforeAll {
        $SubGuid = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
        $VmId = "/subscriptions/$SubGuid/resourceGroups/rg-p9/providers/Microsoft.Compute/virtualMachines/vm-p9"

        # One FreeText token whose real value carries every format-significant
        # character: a double quote, a comma, an ampersand, a less-than (and a
        # greater-than), and an embedded newline. Synthetic, no customer data.
        $script:P9Tok = 'prod_' + [guid]::NewGuid().ToString()
        $script:P9Real = "owner `"ops`", team A & B <primary>`nsecond line"

        # Independently computed expected encodings (NOT reusing the production
        # code path) so the format assertions verify behaviour, not tautology.
        $script:P9HtmlExpected = [System.Net.WebUtility]::HtmlEncode($script:P9Real)

        # ---- Synthetic obfuscated members: SAME token in JSON, CSV and HTML ----
        $script:P9Inventory = [ordered]@{
            VirtualMachines = @(
                [ordered]@{ Name = 'vm-p9'; ResourceGroup = 'rg-p9'; Description = $script:P9Tok }
            )
        }

        # Two columns: the token-bearing FreeText field plus a neighbour marker.
        # If the embedded comma/quote/newline broke quoting, the marker column
        # would shift/split — so asserting Marker survives proves columns intact.
        $script:P9CsvRows = @(
            [pscustomobject]@{ FreeText = $script:P9Tok; Marker = 'KEEP' }
        )

        $script:P9Dict = [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $VmId }
            ResourceNameMap  = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $VmId }
            SubscriptionMap  = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $VmId }
            ResourceGroupMap = [ordered]@{ ('prod_' + [guid]::NewGuid().ToString()) = $VmId }
            FreeTextMap      = [ordered]@{ $script:P9Tok = $script:P9Real }
        }

        $script:P9Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("RevealP9_" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:P9Dir -Force | Out-Null

        $StageDir = Join-Path $script:P9Dir 'stage'
        New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
        $script:P9Inventory | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $StageDir 'Inventory_P9.json') -Encoding utf8
        $script:P9CsvRows | Export-Csv -Path (Join-Path $StageDir 'Consumption_P9.csv') -NoTypeInformation -Encoding utf8
        "<html><body><table><tr><td>$($script:P9Tok)</td></tr></table></body></html>" |
            Set-Content -Path (Join-Path $StageDir 'ResourcesReport_P9.html') -Encoding utf8

        $script:P9InputZip = Join-Path $script:P9Dir 'ResourcesReport_P9.zip'
        Compress-Archive -Path (Join-Path $StageDir '*') -DestinationPath $script:P9InputZip -Force

        $script:P9DictPath = Join-Path $script:P9Dir 'ObfuscationDictionary_P9.json'
        $script:P9Dict | ConvertTo-Json -Depth 6 | Set-Content -Path $script:P9DictPath -Encoding utf8

        # Run the real reveal substitution path for FreeText only, then extract.
        $Out = Join-Path $script:P9Dir 'ResourcesReport_P9_revealed.zip'
        & $script:RevealScript -InputZip $script:P9InputZip -DictionaryPath $script:P9DictPath -Fields FreeText -OutputZip $Out *>&1 | Out-Null

        $script:P9Extract = Join-Path $script:P9Dir 'ex'
        Expand-Archive -Path $Out -DestinationPath $script:P9Extract -Force

        $script:P9JsonFile = (Get-ChildItem $script:P9Extract -Filter 'Inventory_*.json'   | Select-Object -First 1).FullName
        $script:P9CsvFile = (Get-ChildItem $script:P9Extract -Filter 'Consumption_*.csv'   | Select-Object -First 1).FullName
        $script:P9HtmlFile = (Get-ChildItem $script:P9Extract -Filter '*.html'              | Select-Object -First 1).FullName

        $script:P9TokenRegex = '(?:prod|nonprod)_(?:[a-z0-9]+_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    }

    AfterAll {
        if ($script:P9Dir -and (Test-Path $script:P9Dir))
        {
            Remove-Item -Path $script:P9Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "JSON member (Req 9.1: string-literal escaped, stays valid)" {

        It "re-parses via ConvertFrom-Json without error" {
            { Get-Content -Path $script:P9JsonFile -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It "round-trips the revealed field to the exact real value (quote/backslash/newline/'<'/'&' escaped)" {
            $Parsed = Get-Content -Path $script:P9JsonFile -Raw | ConvertFrom-Json
            $Parsed.VirtualMachines[0].Description | Should -Be $script:P9Real
        }

        It "leaves no FreeText token behind in the JSON member" {
            $Parsed = Get-Content -Path $script:P9JsonFile -Raw | ConvertFrom-Json
            $Parsed.VirtualMachines[0].Description | Should -Not -Match $script:P9TokenRegex
        }
    }

    Context "CSV member (Req 9.2: re-quoted, columns stay intact)" {

        BeforeAll { $script:P9Csv = @(Import-Csv -Path $script:P9CsvFile) }

        It "preserves the column set exactly" {
            $Headers = @($script:P9Csv[0].PSObject.Properties.Name)
            ($Headers -join '|') | Should -Be 'FreeText|Marker'
        }

        It "preserves the row count (embedded comma/quote/newline did not split rows)" {
            $script:P9Csv.Count | Should -Be 1
        }

        It "leaves the neighbouring column untouched (columns did not bleed)" {
            $script:P9Csv[0].Marker | Should -Be 'KEEP'
        }

        It "round-trips the revealed field to the exact real value" {
            $script:P9Csv[0].FreeText | Should -Be $script:P9Real
        }
    }

    Context "HTML member (Req 9.3: entity-encoded, stays well-formed)" {

        BeforeAll { $script:P9Html = Get-Content -Path $script:P9HtmlFile -Raw }

        It "is well-formed (loads as XML without error)" {
            { [xml]$script:P9Html } | Should -Not -Throw
        }

        It "entity-encodes the revealed value exactly as the report's own encoder does" {
            $script:P9Html | Should -Match ([regex]::Escape($script:P9HtmlExpected))
        }

        It "emits less-than, ampersand and double-quote as entities, not raw markup-significant characters" {
            $script:P9Html | Should -Match '&lt;primary&gt;'
            $script:P9Html | Should -Match 'A &amp; B'
            $script:P9Html | Should -Match '&quot;ops&quot;'
        }

        It "leaves no FreeText token behind in the HTML member" {
            $script:P9Html | Should -Not -Match $script:P9TokenRegex
        }
    }
}

# =============================================================================
# Input / dictionary resolution and failure paths — Task 11
# Requirements 10.1, 10.2, 10.3, 7.6, 12.4
# -----------------------------------------------------------------------------
# Purely-additive coverage for the reveal tool's resolution and failure
# contract. These close gaps left by the existing "dictionary handling and
# source safety" Describe (which asserts single-dictionary auto-discovery,
# input-zip immutability, and the unresolvable-dictionary throw / Req 10.3),
# without duplicating any of them:
#
#   - Req 10.1  auto-discovery picks the NEWEST ObfuscationDictionary_*.json
#               among SEVERAL of differing timestamps under -SearchDirectory
#               (the existing test proves discovery works with a lone file; it
#               does NOT prove "newest wins"). Reveal-Obfuscation.ps1:122-123
#               sorts by LastWriteTime -Descending and takes -First 1.
#   - Req 10.2  a missing input ZIP throws an error that NAMES the file
#               (Reveal-Obfuscation.ps1:115-119).
#   - Req 7.6   a field selection yielding zero token mappings throws
#               "Nothing to reveal" (Reveal-Obfuscation.ps1:277-280) AND emits
#               NO output ZIP (the throw precedes temp-dir creation:299,
#               extraction:304 and Compress-Archive:397).
#   - Req 12.4  the temp extraction dir (Reveal_<guid> under the system temp
#               path, Reveal-Obfuscation.ps1:299) is removed by the finally
#               block (410) on BOTH a successful reveal and a failed one.
#
# All fixtures live under $script:TmpDir so the top-level AfterAll removes them.
# Synthetic values only; the sole literal GUID is the Azure docs placeholder
# inside the synthetic ARM paths, and reveal tokens are runtime GUIDs (reusing
# $script:TokRg from the top-level fixture). No customer data.
# =============================================================================
Describe "Reveal-Obfuscation input/dictionary resolution and failure paths (Task 11)" {

    Context "auto-discovery picks the newest dictionary (Req 10.1)" {

        BeforeAll {
            $Base = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups'   # Azure docs placeholder

            $script:NewestDir = Join-Path $script:TmpDir ("newest_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $script:NewestDir -Force | Out-Null

            # Two discoverable dictionaries mapping the SAME token to DIFFERENT
            # resource-group names. The newer one carries the distinctive winning
            # value; if the tool wrongly picked the older it would reveal the
            # loser instead.
            $StaleDict = Join-Path $script:NewestDir 'ObfuscationDictionary_Stale.json'
            [ordered]@{
                GeneratedAt      = '2026-06-01 00:00:00'
                ResourceGroupMap = [ordered]@{ $script:TokRg = "$Base/rg-stale-loser/providers/Microsoft.Compute/virtualMachines/vm01" }
            } | ConvertTo-Json -Depth 6 | Set-Content -Path $StaleDict -Encoding utf8

            $FreshDict = Join-Path $script:NewestDir 'ObfuscationDictionary_Fresh.json'
            [ordered]@{
                GeneratedAt      = '2026-06-30 00:00:00'
                ResourceGroupMap = [ordered]@{ $script:TokRg = "$Base/rg-fresh-winner/providers/Microsoft.Compute/virtualMachines/vm01" }
            } | ConvertTo-Json -Depth 6 | Set-Content -Path $FreshDict -Encoding utf8

            # Make the timestamp ordering explicit and deterministic.
            (Get-Item $StaleDict).LastWriteTime = (Get-Date).AddMinutes(-30)
            (Get-Item $FreshDict).LastWriteTime = (Get-Date)

            $script:Newest = Invoke-Reveal -Fields @('ResourceGroup') -SearchDir $script:NewestDir
        }

        It "reveals the resource group from the NEWEST dictionary" {
            $script:Newest.Inventory.VirtualMachines[0].ResourceGroup | Should -Be 'rg-fresh-winner'
        }

        It "does not use the older dictionary's mapping" {
            $script:Newest.Inventory.VirtualMachines[0].ResourceGroup | Should -Not -Be 'rg-stale-loser'
        }
    }

    Context "auto-discovery and a folder named like a dictionary" {

        It "picks the newest dictionary file, not a newer folder whose name matches ObfuscationDictionary_*.json" {
            $Search = Join-Path $script:TmpDir ("dirdict_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $Search -Force | Out-Null
            $FileDict = Join-Path $Search 'ObfuscationDictionary_Valid.json'
            [ordered]@{
                GeneratedAt      = '2026-06-30 00:00:00'
                ResourceGroupMap = [ordered]@{ $script:TokRg = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-file-dict/providers/Microsoft.Compute/virtualMachines/vm01" }
            } | ConvertTo-Json -Depth 6 | Set-Content -Path $FileDict -Encoding utf8
            $FolderDict = Join-Path $Search 'ObfuscationDictionary_Folder.json'
            New-Item -ItemType Directory -Path $FolderDict -Force | Out-Null
            (Get-Item -LiteralPath $FileDict).LastWriteTime = (Get-Date).AddMinutes(-30)
            (Get-Item -LiteralPath $FolderDict).LastWriteTime = (Get-Date)

            $R = Invoke-Reveal -Fields @('ResourceGroup') -SearchDir $Search
            $R.Inventory.VirtualMachines[0].ResourceGroup | Should -BeExactly 'rg-file-dict' -Because 'a folder is not a dictionary, however new and whatever its name'
        }
    }

    Context "missing input ZIP (Req 10.2)" {

        It "throws an error that names the missing input file" {
            $MissingZip = Join-Path $script:TmpDir 'no-such-report_doesnotexist.zip'
            $Err = { & $script:RevealScript -InputZip $MissingZip -DictionaryPath $script:DictPath -OutputZip (Join-Path $script:TmpDir 'unused.zip') } |
                Should -Throw -PassThru
            $Err.Exception.Message | Should -BeLike '*Input zip not found*'
            $Err.Exception.Message | Should -BeLike '*no-such-report_doesnotexist.zip*'
        }
    }

    Context "zero-mapping field selection (Req 7.6)" {

        BeforeAll {
            # Core-maps-only dictionary (no TagMap), so selecting ONLY Tag yields
            # zero token mappings and the tool must fail rather than emit a ZIP.
            $script:ZeroDir = Join-Path $script:TmpDir ("zeromap_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $script:ZeroDir -Force | Out-Null
            $script:ZeroDict = Join-Path $script:ZeroDir 'ObfuscationDictionary_NoTag.json'
            [ordered]@{
                GeneratedAt      = '2026-06-30 00:00:00'
                ResourceGroupMap = [ordered]@{ $script:TokRg = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            } | ConvertTo-Json -Depth 6 | Set-Content -Path $script:ZeroDict -Encoding utf8
        }

        It "throws 'Nothing to reveal' and emits no output ZIP" {
            $Out = Join-Path $script:ZeroDir 'should-never-be-written.zip'
            { & $script:RevealScript -InputZip $script:InputZip -DictionaryPath $script:ZeroDict -Fields Tag -OutputZip $Out } |
                Should -Throw -ExpectedMessage '*Nothing to reveal*'
            Test-Path -Path $Out | Should -BeFalse
        }
    }

    Context "temp extraction dir cleanup (Req 12.4)" {

        BeforeAll { $script:SysTemp = [System.IO.Path]::GetTempPath() }

        It "leaves no Reveal_* temp dir behind after a successful reveal" {
            $Before = @(Get-ChildItem -Path $script:SysTemp -Directory -Filter 'Reveal_*' -ErrorAction SilentlyContinue | ForEach-Object Name)
            $null = Invoke-Reveal
            $After = @(Get-ChildItem -Path $script:SysTemp -Directory -Filter 'Reveal_*' -ErrorAction SilentlyContinue | ForEach-Object Name)
            @($After | Where-Object { $_ -notin $Before }) | Should -BeNullOrEmpty
        }

        It "leaves no Reveal_* temp dir behind after a failed reveal (post-extraction failure)" {
            # A file that exists (so the input-zip guard passes) but is not a real
            # archive, so Expand-Archive fails INSIDE the try block, exercising the
            # finally cleanup on the failure path.
            $CorruptZip = Join-Path $script:TmpDir ("corrupt_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
            Set-Content -Path $CorruptZip -Value 'this is not a zip archive' -Encoding utf8

            $Before = @(Get-ChildItem -Path $script:SysTemp -Directory -Filter 'Reveal_*' -ErrorAction SilentlyContinue | ForEach-Object Name)
            { & $script:RevealScript -InputZip $CorruptZip -DictionaryPath $script:DictPath -OutputZip (Join-Path $script:TmpDir 'corrupt_out.zip') } |
                Should -Throw
            $After = @(Get-ChildItem -Path $script:SysTemp -Directory -Filter 'Reveal_*' -ErrorAction SilentlyContinue | ForEach-Object Name)
            @($After | Where-Object { $_ -notin $Before }) | Should -BeNullOrEmpty
        }
    }
}

# =============================================================================
# Backward compatibility with older / partial dictionaries — Task 12
# Requirements 11.1, 11.2, 11.3
# -----------------------------------------------------------------------------
# Purely-additive coverage for graceful degradation against older-shaped
# dictionaries. Reveal-Obfuscation.ps1 confirms the contract:
#   - Req 11.1  Subscription reveal prefers SubscriptionNameMap; when a token
#               has no friendly name it falls back to the /subscriptions/<guid>
#               GUID (Reveal-Obfuscation.ps1:219-221) and, once the pass
#               completes, emits a Write-Warning naming the missing
#               SubscriptionNameMap (272-274).
#   - Req 11.2  -Fields Tag against a dictionary with no TagMap emits a
#               Write-Warning and skips Tag (empty TagMap loop adds nothing,
#               229-235) WITHOUT throwing - the run still succeeds for the other
#               selected dimensions. (Tag alone would hit the "Nothing to
#               reveal" throw at 277-280, so it is asserted alongside a
#               resolvable dimension, matching the tool's real behavior.)
#   - Req 11.3  with the four core maps present but the optional maps
#               (SubscriptionNameMap / TagMap / FreeTextMap) absent, the tool
#               proceeds and reverses the dimensions it can - ResourceGroup
#               (196-203) and ResourceId (234-241) still resolve off the core
#               maps.
#
# Non-duplication: the existing "older / partial dictionaries" Describe already
# asserts (a) Subscription falls back to the GUID (Req 11.1 value) and (b) tag
# values stay masked with no TagMap (Req 11.2 skip). This block adds ONLY the
# previously-unasserted pieces: the Req 11.1 WARNING, the Req 11.2 WARNING plus
# an explicit does-NOT-throw, and the Req 11.3 proceed-with-reversible-dimensions
# assertions (ResourceGroup + ResourceId revealed from a core-maps-only dict).
#
# Warnings are captured off the script's warning stream (3>&1, filtered to
# WarningRecord); Write-Host status lines land on the information stream and are
# not captured. Value assertions reuse the top-level Invoke-Reveal helper. All
# synthetic older-shaped dictionaries are built here (not read from the real
# fixture) and live under $script:TmpDir, so the top-level AfterAll removes them.
# Synthetic values only: reveal tokens are runtime GUIDs reused from the
# top-level fixture ($script:TokSub / $script:TokRg / $script:TokId /
# $script:TokName / $script:TokTag), and the only literal GUID is the Azure docs
# placeholder inside the synthetic ARM paths. No customer data.
# =============================================================================
Describe "Reveal-Obfuscation backward compatibility with older dictionaries (Req 11.1, 11.2, 11.3)" {

    BeforeAll {
        $BcBase = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups'   # Azure docs placeholder
        $script:BcVmId = "$BcBase/$($script:RealRgName)/providers/Microsoft.Compute/virtualMachines/vm01"

        # Capture ONLY the warning stream (3>&1); Write-Host status lines are on
        # the information stream and are intentionally excluded.
        function Get-RevealWarning
        {
            param([string]$DictPath, [string[]]$Fields)
            $Out = Join-Path $script:TmpDir ("bcwarn_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".zip")
            $Streamed = & $script:RevealScript -InputZip $script:InputZip -DictionaryPath $DictPath -Fields $Fields -OutputZip $Out 3>&1
            return @($Streamed | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        }

        # ---- Older-shaped dictionary: NO SubscriptionNameMap (predates it) ----
        $script:BcLegacyDir = Join-Path $script:TmpDir ("bc_legacy_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:BcLegacyDir -Force | Out-Null
        $script:BcLegacyDict = Join-Path $script:BcLegacyDir 'ObfuscationDictionary_LegacyNoSubName.json'
        [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ $script:TokId = $script:BcVmId }
            ResourceNameMap  = [ordered]@{ $script:TokName = $script:BcVmId }
            SubscriptionMap  = [ordered]@{ $script:TokSub = $script:BcVmId }
            ResourceGroupMap = [ordered]@{ $script:TokRg = $script:BcVmId }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $script:BcLegacyDict -Encoding utf8

        # ---- Older-shaped dictionary: NO TagMap (tags not obfuscated) ----
        # Keeps SubscriptionNameMap so the Tag-skip warning is asserted in
        # isolation (no subscription-fallback warning noise).
        $script:BcNoTagDir = Join-Path $script:TmpDir ("bc_notag_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:BcNoTagDir -Force | Out-Null
        $script:BcNoTagDict = Join-Path $script:BcNoTagDir 'ObfuscationDictionary_NoTag.json'
        [ordered]@{
            GeneratedAt         = '2026-06-30 00:00:00'
            ResourceIdMap       = [ordered]@{ $script:TokId = $script:BcVmId }
            ResourceNameMap     = [ordered]@{ $script:TokName = $script:BcVmId }
            SubscriptionMap     = [ordered]@{ $script:TokSub = $script:BcVmId }
            ResourceGroupMap    = [ordered]@{ $script:TokRg = $script:BcVmId }
            SubscriptionNameMap = [ordered]@{ $script:TokSub = $script:RealSubName }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $script:BcNoTagDict -Encoding utf8

        # ---- Older-shaped dictionary: core maps ONLY, all optional maps absent ----
        $script:BcCoreOnlyDir = Join-Path $script:TmpDir ("bc_coreonly_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:BcCoreOnlyDir -Force | Out-Null
        $script:BcCoreOnlyDict = Join-Path $script:BcCoreOnlyDir 'ObfuscationDictionary_CoreOnly.json'
        [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ $script:TokId = $script:BcVmId }
            ResourceNameMap  = [ordered]@{ $script:TokName = $script:BcVmId }
            SubscriptionMap  = [ordered]@{ $script:TokSub = $script:BcVmId }
            ResourceGroupMap = [ordered]@{ $script:TokRg = $script:BcVmId }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $script:BcCoreOnlyDict -Encoding utf8
    }

    Context "SubscriptionNameMap absent -> GUID fallback + warning (Req 11.1)" {

        It "reveals the subscription GUID (not a friendly name) from an older dictionary" {
            $R = Invoke-Reveal -Fields @('Subscription') -DictPath $script:BcLegacyDict
            $R.Inventory.VirtualMachines[0].Subscription | Should -Be '12345678-1234-1234-1234-123456789012'
        }

        It "emits a warning about falling back to the subscription GUID / missing SubscriptionNameMap" {
            $Warnings = Get-RevealWarning -DictPath $script:BcLegacyDict -Fields @('Subscription')
            ($Warnings -join "`n") | Should -Match '(?i)SubscriptionNameMap'
            ($Warnings -join "`n") | Should -Match '(?i)GUID'
        }
    }

    Context "TagMap absent + -Fields Tag -> skip with warning, no failure (Req 11.2)" {

        It "does not throw when Tag is requested alongside a resolvable dimension but TagMap is absent" {
            $Out = Join-Path $script:TmpDir ("bc_notag_nothrow_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".zip")
            { & $script:RevealScript -InputZip $script:InputZip -DictionaryPath $script:BcNoTagDict -Fields ResourceGroup, Subscription, Tag -OutputZip $Out *>&1 | Out-Null } |
                Should -Not -Throw
        }

        It "emits a warning that Tag is skipped because the dictionary has no TagMap" {
            $Warnings = Get-RevealWarning -DictPath $script:BcNoTagDict -Fields @('ResourceGroup', 'Subscription', 'Tag')
            ($Warnings -join "`n") | Should -Match '(?i)TagMap'
            ($Warnings -join "`n") | Should -Match '(?i)Skipping Tag'
        }

        It "leaves the tag value masked while still revealing the resolvable dimensions" {
            $R = Invoke-Reveal -Fields @('ResourceGroup', 'Subscription', 'Tag') -DictPath $script:BcNoTagDict
            $R.Inventory.VirtualMachines[0].Tags[0].Value | Should -Be $script:TokTag
            $R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
            $R.Inventory.VirtualMachines[0].Subscription  | Should -Be $script:RealSubName
        }
    }

    Context "core maps present, optional maps absent -> proceed with reversible dimensions (Req 11.3)" {

        It "still reveals ResourceGroup from a core-maps-only dictionary" {
            $R = Invoke-Reveal -Fields @('ResourceGroup') -DictPath $script:BcCoreOnlyDict
            $R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
        }

        It "still reveals ResourceId from a core-maps-only dictionary" {
            $R = Invoke-Reveal -Fields @('ResourceId') -DictPath $script:BcCoreOnlyDict
            $R.Inventory.VirtualMachines[0].ID | Should -Be $script:BcVmId
        }

        It "reveals ResourceGroup + ResourceId together without requiring the optional maps" {
            $R = Invoke-Reveal -Fields @('ResourceGroup', 'ResourceId') -DictPath $script:BcCoreOnlyDict
            $R.Inventory.VirtualMachines[0].ResourceGroup | Should -Be $script:RealRgName
            $R.Inventory.VirtualMachines[0].ID | Should -Be $script:BcVmId
        }
    }
}

Describe 'Reveal atomic output packaging (F3)' {
    # The engine compresses to a sibling *.partial.zip and atomically renames it
    # to the final name on success, so a hard kill mid-compress can only truncate
    # the .partial.zip, never the final output the all-subscriptions -Resume and
    # consolidation trust. On a clean run the partial must be renamed away.
    It 'produces the final zip and leaves no *.partial.zip sibling after a successful reveal' {
        $Out = Join-Path $script:TmpDir ("atomic_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".zip")
        & $script:RevealScript -InputZip $script:InputZip -DictionaryPath $script:DictPath -Fields Subscription -OutputZip $Out *>&1 | Out-Null

        Test-Path -LiteralPath $Out | Should -BeTrue -Because 'the atomic rename must leave the completed archive at the final name'
        $Partial = ($Out -replace '\.zip$', '') + '.partial.zip'
        Test-Path -LiteralPath $Partial | Should -BeFalse -Because 'the temp .partial.zip must be renamed away, never left behind on a successful reveal'
    }
}

# A tag or free-text value can be a text that looks like a time. ConvertFrom-Json
# reads such a text as a DateTime, and a DateTime turned back into text has
# another form ('05/01/2023 08:00:00' for '2023-05-01T10:00:00.123+02:00' on a host
# at UTC). The revealed report must hold the text the dictionary holds, byte for
# byte: in the inventory (read here with System.Text.Json, which has no date
# handling), in a consumption cell and in the HTML report.
Describe 'Reveal and a dictionary value that looks like a time' {
    It 'puts back the text the dictionary holds, byte for byte: <Case>' -ForEach @(
        @{ Case = 'an ISO time with a +02:00 offset'; Value = '2023-05-01T10:00:00.123+02:00' }
        @{ Case = 'an ISO time with a -05:00 offset'; Value = '2023-05-01T10:00:00-05:00' }
        @{ Case = 'an ISO time with a +05:45 offset'; Value = '2023-05-01T10:00:00.5+05:45' }
        @{ Case = 'an ISO time with Z'; Value = '2023-05-01T10:00:00Z' }
        @{ Case = 'an ISO time with Z and seven fraction digits'; Value = '2023-05-01T10:00:00.1230000Z' }
        @{ Case = 'an ISO time with no offset'; Value = '2023-05-01T10:00:00' }
        @{ Case = 'a /Date(...)/ time'; Value = '/Date(1682935200000)/' }
        @{ Case = 'plain text'; Value = 'Contoso Production' }
    ) {
        $Dir = Join-Path $script:TmpDir ('time_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Stage = Join-Path $Dir 'stage'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        $TagTok = 'prod_' + [guid]::NewGuid().ToString()
        $FreeTok = 'prod_' + [guid]::NewGuid().ToString()
        $Inv = [ordered]@{
            VirtualMachines = @(
                [ordered]@{
                    ID            = $script:TokId
                    Name          = $script:TokName
                    Subscription  = $script:TokSub
                    ResourceGroup = $script:TokRg
                    Description   = $FreeTok
                    Tags          = @( [ordered]@{ Name = 'created'; Value = $TagTok } )
                }
            )
        }
        $Inv | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Stage 'Inventory_Time.json') -Encoding utf8
        @([pscustomobject]@{ Tag = $TagTok; Note = $FreeTok; Cost = '1.5' }) | Export-Csv -Path (Join-Path $Stage 'Consumption_Time.csv') -NoTypeInformation -Encoding utf8
        "<html><body><table><tr><td>$TagTok</td><td>$FreeTok</td></tr></table></body></html>" | Set-Content -Path (Join-Path $Stage 'ResourcesReport_Time.html') -Encoding utf8
        $Zip = Join-Path $Dir 'ResourcesReport_Time.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $DictPath = Join-Path $Dir 'ObfuscationDictionary_Time.json'
        [ordered]@{
            GeneratedAt      = '2026-06-30 00:00:00'
            ResourceIdMap    = [ordered]@{ $script:TokId = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm01" }
            ResourceGroupMap = [ordered]@{ $script:TokRg = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-app" }
            TagMap           = [ordered]@{ $TagTok = $Value }
            FreeTextMap      = [ordered]@{ $FreeTok = $Value }
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $DictPath -Encoding utf8
        $DictDoc = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($DictPath))
        try { $DictDoc.RootElement.GetProperty('TagMap').GetProperty($TagTok).GetString() | Should -BeExactly $Value -Because 'the dictionary holds the text as a run writes it' }
        finally { $DictDoc.Dispose() }

        $Out = Join-Path $Dir 'out.zip'
        & $script:RevealScript -InputZip $Zip -DictionaryPath $DictPath -Fields Tag, FreeText -OutputZip $Out *>&1 | Out-Null
        $Ex = Join-Path $Dir 'ex'
        Expand-Archive -Path $Out -DestinationPath $Ex -Force

        $InvText = [System.IO.File]::ReadAllText((Join-Path $Ex 'Inventory_Time.json'))
        $Doc = [System.Text.Json.JsonDocument]::Parse($InvText)
        try
        {
            $Vm = $Doc.RootElement.GetProperty('VirtualMachines')[0]
            $Vm.GetProperty('Tags')[0].GetProperty('Value').GetString() | Should -BeExactly $Value -Because 'a tag value in the inventory gets back the text the dictionary holds'
            $Vm.GetProperty('Description').GetString() | Should -BeExactly $Value -Because 'a free-text value in the inventory gets back the text the dictionary holds'
        }
        finally { $Doc.Dispose() }
        $Row = @(Import-Csv -Path (Join-Path $Ex 'Consumption_Time.csv'))[0]
        $Row.Tag | Should -BeExactly $Value -Because 'a tag value in a consumption cell gets back the text the dictionary holds'
        $Row.Note | Should -BeExactly $Value -Because 'a free-text value in a consumption cell gets back the text the dictionary holds'
        $Row.Cost | Should -BeExactly '1.5'
        $Html = [System.IO.File]::ReadAllText((Join-Path $Ex 'ResourcesReport_Time.html'))
        $Encoded = [System.Net.WebUtility]::HtmlEncode($Value)
        $Html | Should -BeLike ('*<td>{0}</td><td>{0}</td>*' -f [WildcardPattern]::Escape($Encoded)) -Because 'the HTML report gets back the text the dictionary holds'
    }

    # No build writes a dictionary file whose root is a list. ConvertFrom-Json
    # reads a list of one object as that object, so Reveal reveals such a file, and a value there that looks like a time gets back the
    # text the file holds, as it does in a dictionary whose root is an object.
    It 'reveals a dictionary file whose root is a list of one object that holds a value that looks like a time' {
        $Dir = Join-Path $script:TmpDir ('timelist_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Stage = Join-Path $Dir 'stage'
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        $TagTok = 'prod_' + [guid]::NewGuid().ToString()
        $FreeTok = 'prod_' + [guid]::NewGuid().ToString()
        [ordered]@{
            VirtualMachines = @(
                [ordered]@{
                    ID            = $script:TokId
                    Name          = $script:TokName
                    Subscription  = $script:TokSub
                    ResourceGroup = $script:TokRg
                    Description   = $FreeTok
                    Tags          = @( [ordered]@{ Name = 'created'; Value = $TagTok } )
                }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $Stage 'Inventory_Time.json') -Encoding utf8
        $Zip = Join-Path $Dir 'ResourcesReport_Time.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        $DictPath = Join-Path $Dir 'ObfuscationDictionary_Time.json'
        $DictText = '[' + ([ordered]@{
                GeneratedAt = '2026-06-30 00:00:00'
                TagMap      = [ordered]@{ $TagTok = '2023-05-01T10:00:00Z' }
                FreeTextMap = [ordered]@{ $FreeTok = 'Contoso Production' }
            } | ConvertTo-Json -Depth 6) + ']'
        [System.IO.File]::WriteAllText($DictPath, $DictText)

        $Out = Join-Path $Dir 'out.zip'
        & $script:RevealScript -InputZip $Zip -DictionaryPath $DictPath -Fields Tag, FreeText -OutputZip $Out *>&1 | Out-Null

        [System.IO.File]::Exists($Out) | Should -BeTrue
        $Ex = Join-Path $Dir 'ex'
        Expand-Archive -Path $Out -DestinationPath $Ex -Force
        $Doc = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText((Join-Path $Ex 'Inventory_Time.json')))
        try
        {
            $Vm = $Doc.RootElement.GetProperty('VirtualMachines')[0]
            $Vm.GetProperty('Tags')[0].GetProperty('Value').GetString() | Should -BeExactly '2023-05-01T10:00:00Z' -Because 'the tag value gets back the text the dictionary file holds'
            $Vm.GetProperty('Description').GetString() | Should -BeExactly 'Contoso Production'
        }
        finally { $Doc.Dispose() }
    }
}

# Reveal.ps1, and each of its per-folder jobs, dot-sources only
# RevealObfuscation.Functions.ps1, which loads DictionaryTimeText.Functions.ps1
# (Restore-DictionaryTimeText). A caller with no try, as an operator's own script is, runs in a child pwsh.
Describe 'RevealObfuscation.Functions.ps1 with no DictionaryTimeText.Functions.ps1 next to it' {
    It 'stops the caller when it is loaded, under ErrorActionPreference <Preference>' -ForEach @(
        @{ Preference = 'SilentlyContinue' }
        @{ Preference = 'Ignore' }
        @{ Preference = 'Continue' }
    ) {
        $LoneDir = Join-Path $script:TmpDir ('lone_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $LoneDir -Force | Out-Null
        $LoneFile = Join-Path $LoneDir 'RevealObfuscation.Functions.ps1'
        Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RevealObfuscation.Functions.ps1') -Destination $LoneFile
        $Q = { param($s) "'" + ($s -replace "'", "''") + "'" }
        $ChildFile = Join-Path $LoneDir 'child.ps1'
        Set-Content -LiteralPath $ChildFile -Encoding utf8 -Value (@(
                ('$ErrorActionPreference = {0}' -f (& $Q $Preference))
                ('. {0}' -f (& $Q $LoneFile))
                'Write-Output ''AFTER_LOAD'''
            ) -join [Environment]::NewLine)
        $ChildOutput = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $ChildFile 2>&1 | ForEach-Object { [string]$_ })
        $Because = $ChildOutput -join [Environment]::NewLine
        $ChildOutput | Should -Not -Contain 'AFTER_LOAD' -Because ('the load must stop the caller, not let it go on. Output: ' + $Because)
        $Because | Should -BeLike '*required file not found*DictionaryTimeText.Functions.ps1*Keep the Functions folder together*'
        $LASTEXITCODE | Should -Not -Be 0 -Because $Because
    }
}

# Reveal is the one caller of Restore-DictionaryTimeText, and it passes the dictionary's
# text and the values read as a time, nothing else.
Describe 'Restore-DictionaryTimeText takes what its one caller passes' {
    It 'has only the parameters Text and Times, and its file names no other one' {
        $File = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/DictionaryTimeText.Functions.ps1'
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Restore-DictionaryTimeText' }, $false))
        $Fn.Count | Should -Be 1
        @($Fn[0].Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Be @('Text', 'Times')
        [System.IO.File]::ReadAllText($File) | Should -Not -Match 'GeneratedAt' -Because 'no caller passes a GeneratedAt'
    }
}

# A folder name can hold [ or ], which -Path reads as a wildcard: '[ab]' matches
# one 'a' or 'b'. Reveal finds, reads and writes the report zip, the dictionary,
# the folder it searches for the dictionary, its temp folder and the files in it
# by their literal paths.
Describe 'Reveal with report, dictionary, search and temp folders whose paths hold [ and ]' {
    BeforeAll {
        # A dictionary that maps the fixture's resource group and tag tokens to the values given.
        function script:Write-BracketDictionary([string]$Path, [string]$RgName, [string]$TagValue)
        {
            $Text = [ordered]@{
                GeneratedAt      = '2026-06-30 00:00:00'
                ResourceGroupMap = [ordered]@{ $script:TokRg = "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/$RgName/providers/Microsoft.Compute/virtualMachines/vm01" }
                TagMap           = [ordered]@{ $script:TokTag = $TagValue }
            } | ConvertTo-Json -Depth 6
            [System.IO.File]::WriteAllText($Path, $Text)
        }
        # The first VM's resource group and tag value, and the members' text, in a revealed zip.
        function script:Read-BracketReveal([string]$Zip)
        {
            $Ex = Join-Path $script:TmpDir ('bex_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            Expand-Archive -LiteralPath $Zip -DestinationPath $Ex -Force
            $Vm = ([System.IO.File]::ReadAllText((Join-Path $Ex 'Inventory_Test.json')) | ConvertFrom-Json).VirtualMachines[0]
            [pscustomobject]@{
                ResourceGroup = $Vm.ResourceGroup
                Tag           = $Vm.Tags[0].Value
                CsvRow        = @(Import-Csv -LiteralPath (Join-Path $Ex 'Consumption_Test.csv'))[0]
                Html          = [System.IO.File]::ReadAllText((Join-Path $Ex 'ResourcesReport_Test.html'))
            }
        }
        function script:New-BracketId { [guid]::NewGuid().ToString('N').Substring(0, 8) }
    }

    It 'reads the report zip and the dictionary in such a folder, and writes the revealed zip next to them in place of a partial zip left there' {
        $Dir = Join-Path $script:TmpDir ('rep [ab] ' + (script:New-BracketId))
        [System.IO.Directory]::CreateDirectory($Dir) | Out-Null
        $Zip = Join-Path $Dir 'ResourcesReport_Test.zip'
        [System.IO.File]::Copy($script:InputZip, $Zip)
        $Dict = Join-Path $Dir 'ObfuscationDictionary_Test.json'
        script:Write-BracketDictionary -Path $Dict -RgName 'rg-bracket' -TagValue 'tag-bracket'
        $Out = Join-Path $Dir 'ResourcesReport_Test_revealed.zip'
        $Partial = Join-Path $Dir 'ResourcesReport_Test_revealed.partial.zip'
        [System.IO.File]::WriteAllText($Partial, 'left by a run that was stopped')

        & $script:RevealScript -InputZip $Zip -DictionaryPath $Dict -Fields ResourceGroup, Tag *>&1 | Out-Null

        [System.IO.File]::Exists($Out) | Should -BeTrue -Because 'with no -OutputZip the revealed zip is written next to the input'
        [System.IO.File]::Exists($Partial) | Should -BeFalse -Because 'the partial zip a stopped run left is replaced, then renamed to the final name'
        $R = script:Read-BracketReveal $Out
        $R.ResourceGroup | Should -BeExactly 'rg-bracket'
        $R.Tag | Should -BeExactly 'tag-bracket'
    }

    It 'finds the dictionary in a -SearchDirectory whose name holds [ and ]' {
        $Id = script:New-BracketId
        $Search = Join-Path $script:TmpDir ("dicts[ab] $Id")
        $Decoy = Join-Path $script:TmpDir ("dictsa $Id")
        [System.IO.Directory]::CreateDirectory($Search) | Out-Null
        [System.IO.Directory]::CreateDirectory($Decoy) | Out-Null
        script:Write-BracketDictionary -Path (Join-Path $Search 'ObfuscationDictionary_Test.json') -RgName 'rg-searched' -TagValue 'tag-searched'
        script:Write-BracketDictionary -Path (Join-Path $Decoy 'ObfuscationDictionary_Test.json') -RgName 'rg-decoy' -TagValue 'tag-decoy'
        $Out = Join-Path $script:TmpDir ("bout_$Id.zip")

        & $script:RevealScript -InputZip $script:InputZip -SearchDirectory $Search -Fields ResourceGroup, Tag -OutputZip $Out *>&1 | Out-Null

        $R = script:Read-BracketReveal $Out
        $R.ResourceGroup | Should -BeExactly 'rg-searched' -Because 'the dictionary is the one in the folder named, not one in a folder its name matches as a wildcard'
        $R.Tag | Should -BeExactly 'tag-searched'
    }

    It 'reads the -DictionaryPath it is given, not a file at a path its name matches as a wildcard' {
        $Id = script:New-BracketId
        $DictDir = Join-Path $script:TmpDir ("dict[ab] $Id")
        $Decoy = Join-Path $script:TmpDir ("dicta $Id")
        [System.IO.Directory]::CreateDirectory($DictDir) | Out-Null
        [System.IO.Directory]::CreateDirectory($Decoy) | Out-Null
        $Dict = Join-Path $DictDir 'ObfuscationDictionary_Test.json'
        script:Write-BracketDictionary -Path $Dict -RgName 'rg-given' -TagValue 'tag-given'
        script:Write-BracketDictionary -Path (Join-Path $Decoy 'ObfuscationDictionary_Test.json') -RgName 'rg-decoy' -TagValue 'tag-decoy'
        $Out = Join-Path $script:TmpDir ("bout_$Id.zip")

        & $script:RevealScript -InputZip $script:InputZip -DictionaryPath $Dict -Fields ResourceGroup, Tag -OutputZip $Out *>&1 | Out-Null

        $R = script:Read-BracketReveal $Out
        $R.ResourceGroup | Should -BeExactly 'rg-given'
        $R.Tag | Should -BeExactly 'tag-given'
    }

    It 'reveals every member file, and removes its temp folder, when the temp path holds [ and ]' {
        $Id = script:New-BracketId
        $Tmp = Join-Path $script:TmpDir ("tmp [ab] $Id")
        [System.IO.Directory]::CreateDirectory($Tmp) | Out-Null
        $Out = Join-Path $script:TmpDir ("bout_$Id.zip")
        $Saved = @{ TMPDIR = $env:TMPDIR; TMP = $env:TMP; TEMP = $env:TEMP }
        try
        {
            $env:TMPDIR = $Tmp; $env:TMP = $Tmp; $env:TEMP = $Tmp
            [System.IO.Path]::GetTempPath().TrimEnd([System.IO.Path]::DirectorySeparatorChar) | Should -BeExactly $Tmp -Because 'the reveal makes its temp folder here'
            & $script:RevealScript -InputZip $script:InputZip -DictionaryPath $script:DictPath -Fields ResourceGroup, Subscription, Tag -OutputZip $Out *>&1 | Out-Null
        }
        finally
        {
            $env:TMPDIR = $Saved.TMPDIR; $env:TMP = $Saved.TMP; $env:TEMP = $Saved.TEMP
        }

        $R = script:Read-BracketReveal $Out
        $R.ResourceGroup | Should -BeExactly $script:RealRgName -Because 'the inventory member is revealed'
        $R.Tag | Should -BeExactly $script:RealTagVal
        $R.CsvRow.Subscription | Should -BeExactly $script:RealSubName -Because 'the consumption member is revealed'
        $R.Html | Should -BeLike ('*<td>{0}</td>*' -f [WildcardPattern]::Escape([System.Net.WebUtility]::HtmlEncode($script:RealSubName))) -Because 'the HTML member is revealed'
        @([System.IO.Directory]::GetDirectories($Tmp, 'Reveal_*')) | Should -BeNullOrEmpty -Because 'the temp folder is removed after the reveal'
    }
}

# .NET reads a relative path against the process folder, and Set-Location in pwsh
# does not move that folder. Reveal checks -InputZip, -OutputZip and
# -DictionaryPath against the pwsh location, so it opens and writes them there too.
# Each case runs Reveal in a child pwsh whose process folder is not its location.
Describe 'Reveal with relative paths when the pwsh location is not the process folder' {
    BeforeAll {
        # A child pwsh: Set-Location to $Location, the process folder set to
        # $ProcessDir after that, then Reveal.ps1 with the arguments given as text.
        function script:Invoke-RelativeReveal([string]$Location, [string]$ProcessDir, [string]$RevealArgs)
        {
            $Q = { param($s) "'" + ($s -replace "'", "''") + "'" }
            $ChildFile = Join-Path $script:TmpDir ('relchild_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
            Set-Content -LiteralPath $ChildFile -Encoding utf8 -Value (@(
                    '$ErrorActionPreference = ''Stop'''
                    ('Set-Location -LiteralPath {0}' -f (& $Q $Location))
                    ('[Environment]::CurrentDirectory = {0}' -f (& $Q $ProcessDir))
                    'Write-Output (''PROCESS_DIR='' + [Environment]::CurrentDirectory)'
                    'Write-Output (''LOCATION='' + (Get-Location).ProviderPath)'
                    ('& {0} {1} *>&1 | ForEach-Object {{ [string]$_ }}' -f (& $Q $script:RevealScript), $RevealArgs)
                    'Write-Output ''REVEAL_DONE'''
                ) -join [Environment]::NewLine)
            $Lines = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $ChildFile 2>&1 | ForEach-Object { [string]$_ })
            [pscustomobject]@{ Lines = $Lines; ExitCode = $LASTEXITCODE; Text = ($Lines -join [Environment]::NewLine) }
        }
        # The first VM's resource group and tag value in a revealed zip.
        function script:Read-RelativeReveal([string]$Zip)
        {
            $Ex = Join-Path $script:TmpDir ('relex_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            Expand-Archive -LiteralPath $Zip -DestinationPath $Ex -Force
            $Vm = ([System.IO.File]::ReadAllText((Join-Path $Ex 'Inventory_Test.json')) | ConvertFrom-Json).VirtualMachines[0]
            [pscustomobject]@{
                ResourceGroup = $Vm.ResourceGroup
                Tag           = $Vm.Tags[0].Value
                Members       = @(Get-ChildItem -LiteralPath $Ex -File | ForEach-Object Name | Sort-Object)
            }
        }
        # A report folder with the fixture zip and a dictionary for it, and a
        # process folder next to it. ProcDirAsNet is the process folder as .NET
        # reads it back: on Linux and macOS it follows symlinks (getcwd), so a
        # temp path through a symlink, such as /var on macOS, comes back in
        # another spelling. It is read back here the same way the child does.
        function script:New-RelativeFolderSet
        {
            $Root = Join-Path $script:TmpDir ('rel_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $Dir = Join-Path $Root 'report'
            $ProcDir = Join-Path $Root 'process'
            [System.IO.Directory]::CreateDirectory($Dir) | Out-Null
            [System.IO.Directory]::CreateDirectory($ProcDir) | Out-Null
            $SavedProcessDir = [Environment]::CurrentDirectory
            try
            {
                [Environment]::CurrentDirectory = $ProcDir
                $ProcDirAsNet = [Environment]::CurrentDirectory
            }
            finally
            {
                [Environment]::CurrentDirectory = $SavedProcessDir
            }
            [System.IO.File]::Copy($script:InputZip, (Join-Path $Dir 'ResourcesReport_Test.zip'))
            [System.IO.File]::WriteAllText((Join-Path $Dir 'ObfuscationDictionary_Test.json'), ([ordered]@{
                        GeneratedAt      = '2026-06-30 00:00:00'
                        ResourceGroupMap = [ordered]@{ $script:TokRg = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-relative/providers/Microsoft.Compute/virtualMachines/vm01' }
                        TagMap           = [ordered]@{ $script:TokTag = 'tag-relative' }
                    } | ConvertTo-Json -Depth 6))
            [pscustomobject]@{ Dir = $Dir; ProcDir = $ProcDir; ProcDirAsNet = $ProcDirAsNet }
        }
    }

    It 'reads the zip and dictionary at the pwsh location, not a zip of the same name in the process folder, and writes the revealed zip next to the input' {
        $F = script:New-RelativeFolderSet
        # A zip of the same name in the process folder, which holds a decoy member.
        $DecoyStage = Join-Path $F.ProcDir 'stage'
        [System.IO.Directory]::CreateDirectory($DecoyStage) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $DecoyStage 'Decoy.txt'), $script:TokRg)
        Compress-Archive -LiteralPath (Join-Path $DecoyStage 'Decoy.txt') -DestinationPath (Join-Path $F.ProcDir 'ResourcesReport_Test.zip')
        Remove-Item -LiteralPath $DecoyStage -Recurse -Force

        $Run = script:Invoke-RelativeReveal -Location $F.Dir -ProcessDir $F.ProcDir -RevealArgs '-InputZip ./ResourcesReport_Test.zip -DictionaryPath ./ObfuscationDictionary_Test.json -Fields ResourceGroup, Tag'

        $Run.Lines | Should -Contain ('PROCESS_DIR=' + $F.ProcDirAsNet) -Because ('the child runs with the process folder set apart. Output: ' + $Run.Text)
        $Run.Lines | Should -Contain ('LOCATION=' + $F.Dir) -Because $Run.Text
        $Run.ExitCode | Should -Be 0 -Because $Run.Text
        $Run.Lines | Should -Contain 'REVEAL_DONE' -Because $Run.Text
        $Out = Join-Path $F.Dir 'ResourcesReport_Test_revealed.zip'
        [System.IO.File]::Exists($Out) | Should -BeTrue -Because ('with no -OutputZip the revealed zip is written next to the input at the pwsh location. Output: ' + $Run.Text)
        $R = script:Read-RelativeReveal $Out
        $R.Members | Should -Not -Contain 'Decoy.txt' -Because 'the zip revealed is the one at the pwsh location'
        $R.ResourceGroup | Should -BeExactly 'rg-relative'
        $R.Tag | Should -BeExactly 'tag-relative'
        @(Get-ChildItem -LiteralPath $F.ProcDir -Force | ForEach-Object Name) | Should -Be @('ResourcesReport_Test.zip') -Because 'nothing is written to the process folder'
    }

    It 'writes a relative -OutputZip at the pwsh location, with the dictionary found there' {
        $F = script:New-RelativeFolderSet
        [System.IO.Directory]::CreateDirectory((Join-Path $F.Dir 'out')) | Out-Null

        $Run = script:Invoke-RelativeReveal -Location $F.Dir -ProcessDir $F.ProcDir -RevealArgs '-InputZip ./ResourcesReport_Test.zip -OutputZip out/revealed.zip -Fields ResourceGroup, Tag'

        $Run.Lines | Should -Contain ('PROCESS_DIR=' + $F.ProcDirAsNet) -Because ('the child runs with the process folder set apart. Output: ' + $Run.Text)
        $Run.ExitCode | Should -Be 0 -Because $Run.Text
        $Run.Lines | Should -Contain 'REVEAL_DONE' -Because $Run.Text
        $Out = Join-Path $F.Dir 'out/revealed.zip'
        [System.IO.File]::Exists($Out) | Should -BeTrue -Because ('the revealed zip is written at the path given, read against the pwsh location. Output: ' + $Run.Text)
        @(Get-ChildItem -LiteralPath (Join-Path $F.Dir 'out') -Force | ForEach-Object Name) | Should -Be @('revealed.zip') -Because 'the partial zip is renamed to the final name'
        $R = script:Read-RelativeReveal $Out
        $R.ResourceGroup | Should -BeExactly 'rg-relative'
        $R.Tag | Should -BeExactly 'tag-relative'
        @(Get-ChildItem -LiteralPath $F.ProcDir -Force) | Should -BeNullOrEmpty -Because 'nothing is written to the process folder'
    }
}
