# Referential Integrity Tests
# Validates that cross-references between resources are consistent after obfuscation
# Run with: Invoke-Pester ./Tests/ReferentialIntegrity.Tests.ps1 -Output Detailed

BeforeAll {
    $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
    {
        Get-ChildItem -Path $PSScriptRoot -Filter "ResourcesReport_*.zip" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($ZipPath) -or -not (Test-Path $ZipPath))
    {
        throw "No test zip found. Copy a ResourcesReport_*.zip to Tests/ or set `$env:TEST_ZIP_PATH"
    }
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { "/tmp" }
    $script:ExtractPath = Join-Path $TmpBase ("RefIntTest_" + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:ExtractPath -Force | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $script:ExtractPath -Force

    $InvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Inventory_*.json" | Select-Object -First 1
    $script:Inventory = Get-Content $InvFile.FullName -Raw | ConvertFrom-Json

    $CsvFile = Get-ChildItem -Path $script:ExtractPath -Filter "Consumption_*.csv" | Select-Object -First 1
    $script:ConsumptionCsv = if ($CsvFile)
    {
        $Content = Get-Content $CsvFile.FullName -ErrorAction SilentlyContinue
        if ($null -ne $Content -and $Content.Count -gt 1) { Import-Csv $CsvFile.FullName } else { @() }
    }
    else { @() }

    # Collect all IDs across all resource types
    $script:AllIds = @()
    $script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' } | ForEach-Object {
        @($_.Value) | ForEach-Object { if ($null -ne $_.ID) { $script:AllIds += $_.ID } }
    }

    # --- Additional fixtures ------------------------------------------------
    # Metric rows back the per-resource cached-token check. Metrics
    # live in one or more Metrics_*.json members, each exposing a .Metrics array.
    $MetricRows = @()
    Get-ChildItem -Path $script:ExtractPath -Filter "Metrics_*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        $MetricData = Get-Content $_.FullName -Raw | ConvertFrom-Json
        if ($null -ne $MetricData.Metrics) { $MetricRows += @($MetricData.Metrics) }
    }
    $script:MetricRows = @($MetricRows)

    # A masked resource ID is an ARM-shaped path, never a flat token; the
    # shape is described in Helpers/MaskedIdPattern.ps1.
    . (Join-Path $PSScriptRoot 'Helpers/MaskedIdPattern.ps1')
    . (Join-Path $PSScriptRoot 'Helpers/RunDictionaryPath.ps1')
    $script:MaskedIdPattern = Get-MaskedIdPattern
}

AfterAll {
    if ($script:ExtractPath -and (Test-Path $script:ExtractPath)) { Remove-Item -Path $script:ExtractPath -Recurse -Force }
}

Describe "VM Disk to VM Cross-Reference" {
    It "Every disk AssociatedResource should match a VM ID or be null" {
        $Disks = @($script:Inventory.VMDisk) | Where-Object { $null -ne $_ }
        if ($Disks.Count -eq 0) { Set-ItResult -Skipped -Because "no VMDisk resources in this fixture"; return }
        $VmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($disk in $Disks)
        {
            if ($null -ne $disk -and ![string]::IsNullOrEmpty($disk.AssociatedResource))
            {
                $disk.AssociatedResource | Should -BeIn $VmIds -Because "Disk '$($disk.ID)' AssociatedResource should reference a known VM"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no VMDisk had a non-null AssociatedResource in this fixture" }
    }
}

Describe "AVD HostId to VM Cross-Reference" {
    It "Every AVD HostId should match a VM ID or be null" {
        $Avd = @($script:Inventory.AVD) | Where-Object { $null -ne $_ }
        if ($Avd.Count -eq 0) { Set-ItResult -Skipped -Because "no AVD resources in this fixture"; return }
        $VmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($avdItem in $Avd)
        {
            if ($null -ne $avdItem -and ![string]::IsNullOrEmpty($avdItem.HostId))
            {
                $avdItem.HostId | Should -BeIn $VmIds -Because "AVD HostId should reference a known VM"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no AVD had a non-null HostId in this fixture" }
    }
}

Describe "SQL VM to VM Cross-Reference" {
    It "Every SQL VM ParentVirtualMachine should match a VM ID (or be a tolerated sentinel)" {
        $Sqlvms = @($script:Inventory.SQLVM) | Where-Object { $null -ne $_ }
        if ($Sqlvms.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLVM resources in this fixture"; return }
        $VmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        # Sentinels the collector emits when the parent VM is out of scope or absent:
        #   'obfuscated' (obfuscation on, parent id not indexed) / 'None' (no parent id).
        $Tolerated = @('obfuscated', 'None')
        $Checked = 0
        foreach ($sqlvm in $Sqlvms)
        {
            if ($null -ne $sqlvm -and ![string]::IsNullOrEmpty($sqlvm.ParentVirtualMachine))
            {
                if ($sqlvm.ParentVirtualMachine -notin $Tolerated)
                {
                    $sqlvm.ParentVirtualMachine | Should -BeIn $VmIds -Because "SQL VM '$($sqlvm.ID)' ParentVirtualMachine should reference a known VM's obfuscated ID"
                    $Checked++
                }
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLVM had a non-sentinel ParentVirtualMachine in this fixture" }
    }
}

Describe "Obfuscated ID Uniqueness" {
    # Some collectors write one row per part of a resource, all with the
    # resource's id (a container cluster per node pool, an availability set
    # per member VM), so an id may repeat within a section. Two different
    # resources must never share a masked id: rows of one id in a section
    # share one Name, ResourceGroup, Subscription and parent, and one id
    # belongs to one section.
    It "Rows that share a masked ID in a section are rows of one resource" {
        foreach ($Section in @($script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' }))
        {
            $Groups = @(@($Section.Value) | Where-Object { $null -ne $_ -and $null -ne $_.ID } | Group-Object -Property ID | Where-Object { $_.Count -gt 1 })
            foreach ($G in $Groups)
            {
                # A child resource also names its parent (a database its server,
                # a volume its account and pool), and two children of one name
                # under two parents are two resources. An Automation row has no
                # Name: its resource is the runbook of its account.
                @($G.Group | ForEach-Object { '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f $_.Name, $_.ResourceGroup, $_.Subscription, $_.DatabaseServer, $_.ManagedInstance, $_.ParentVirtualMachine, $_.NetAppAccount, $_.CapacityPool, $_.AutomationAccountName, $_.RunbookName } | Select-Object -Unique).Count | Should -Be 1 -Because "rows of masked id '$($G.Name)' in $($Section.Name) are one resource, so they share one name, group, subscription and parent"
            }
        }
    }

    It "A masked ID belongs to one inventory section" {
        $SectionsOf = @{}
        foreach ($Section in @($script:Inventory.PSObject.Properties | Where-Object { $null -ne $_.Value -and $_.Name -ne 'Version' }))
        {
            foreach ($Row in @($Section.Value)) { if ($null -ne $Row -and $null -ne $Row.ID) { if (-not $SectionsOf.ContainsKey($Row.ID)) { $SectionsOf[$Row.ID] = @{} }; $SectionsOf[$Row.ID][$Section.Name] = $true } }
        }
        @($SectionsOf.Keys | Where-Object { $SectionsOf[$_].Count -gt 1 }) | Should -BeNullOrEmpty -Because 'two different resources never share a masked id'
    }
}

Describe "Consumption to Inventory Cross-Reference" {
    It "Consumption ResourceIds that exist in inventory should use the same obfuscated value" {
        if ($script:ConsumptionCsv.Count -eq 0) { Set-ItResult -Skipped -Because "empty consumption csv"; return }
        # Which real resource a masked id stands for comes from the run's
        # dictionary (ResourceIdMap: masked id -> real id). A consumption row
        # whose real resource is in the inventory must carry the inventory's
        # masked id for it, string for string.
        # The run's own dictionary, found by the test zip's name.
        $DictPath = Get-RunDictionaryPath -TestsRoot $PSScriptRoot
        if ([string]::IsNullOrEmpty($DictPath) -or -not (Test-Path -LiteralPath $DictPath)) { Set-ItResult -Skipped -Because "no obfuscation dictionary for this zip, so real resources cannot be matched"; return }
        $Map = (Get-Content -LiteralPath $DictPath -Raw | ConvertFrom-Json).ResourceIdMap
        $RealOf = @{}
        foreach ($P in @($Map.PSObject.Properties)) { $RealOf[$P.Name] = [string]$P.Value }
        $InventoryByReal = @{}
        # The first inventory row of a real id is the one compared.
        foreach ($Id in $script:AllIds) { if ($RealOf.ContainsKey($Id) -and -not $InventoryByReal.ContainsKey($RealOf[$Id].ToLowerInvariant())) { $InventoryByReal[$RealOf[$Id].ToLowerInvariant()] = $Id } }
        $Checked = 0
        # Every masked consumption id is in the dictionary: an id the run
        # did not record would be a second, unjoinable id for its resource.
        # The parked 'obfuscated' sentinel for an empty resource id is the
        # one value that is not.
        $Unknown = @($script:ConsumptionCsv | Where-Object { -not [string]::IsNullOrEmpty($_.ResourceId) -and $_.ResourceId -ne 'obfuscated' -and -not $RealOf.ContainsKey($_.ResourceId) } | ForEach-Object { $_.ResourceId } | Select-Object -Unique)
        $Unknown | Should -BeNullOrEmpty -Because 'every consumption ResourceId is a masked id the dictionary records'
        foreach ($row in $script:ConsumptionCsv)
        {
            if ([string]::IsNullOrEmpty($row.ResourceId) -or -not $RealOf.ContainsKey($row.ResourceId)) { continue }
            $Real = $RealOf[$row.ResourceId].ToLowerInvariant()
            if (-not $InventoryByReal.ContainsKey($Real)) { continue }
            # The two files must name the resource with one id, letter case aside.
            $row.ResourceId | Should -Be $InventoryByReal[$Real] -Because "the consumption row of an inventoried resource carries the inventory's masked id"
            $Checked++
        }
        # A zip whose consumption bills no resource its inventory lists has no
        # row to check here; every consumption id is still held to the
        # dictionary above. Skipped then, so it is never a silent pass.
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because 'no consumption row bills a resource the inventory lists' }
    }
}

Describe "Subscription and Resource Group Determinism" {
    It "One real subscription has one subscription token, and one token one real subscription" {
        $DictPath = Get-RunDictionaryPath -TestsRoot $PSScriptRoot
        if ([string]::IsNullOrEmpty($DictPath) -or -not (Test-Path -LiteralPath $DictPath)) { Set-ItResult -Skipped -Because 'no obfuscation dictionary for this zip'; return }
        $Map = (Get-Content -LiteralPath $DictPath -Raw | ConvertFrom-Json).ResourceIdMap
        $TokensOf = @{}; $RealsOf = @{}
        foreach ($P in @($Map.PSObject.Properties))
        {
            $M = ([string]$P.Name).Split('/'); $R = ([string]$P.Value).Split('/')
            if ($M.Count -lt 3 -or $R.Count -lt 3 -or $M[1] -ine 'subscriptions' -or $R[1] -ine 'subscriptions') { continue }
            $Real = $R[2].ToLowerInvariant()
            if (-not $TokensOf.ContainsKey($Real)) { $TokensOf[$Real] = @{} }; $TokensOf[$Real][$M[2]] = $true
            if (-not $RealsOf.ContainsKey($M[2])) { $RealsOf[$M[2]] = @{} }; $RealsOf[$M[2]][$Real] = $true
        }
        if ($TokensOf.Count -eq 0) { Set-ItResult -Skipped -Because 'no masked subscription path in the dictionary'; return }
        foreach ($Real in $TokensOf.Keys) { $TokensOf[$Real].Count | Should -Be 1 -Because 'a real subscription keeps one token in every id' }
        foreach ($Tok in $RealsOf.Keys) { $RealsOf[$Tok].Count | Should -Be 1 -Because 'a token stands for one real subscription' }
    }

    It "One real resource group name has one resource group token" {
        $DictPath = Get-RunDictionaryPath -TestsRoot $PSScriptRoot
        if ([string]::IsNullOrEmpty($DictPath) -or -not (Test-Path -LiteralPath $DictPath)) { Set-ItResult -Skipped -Because 'no obfuscation dictionary for this zip'; return }
        $Map = (Get-Content -LiteralPath $DictPath -Raw | ConvertFrom-Json).ResourceIdMap
        $TokensOf = @{}; $RealsOf = @{}
        foreach ($P in @($Map.PSObject.Properties))
        {
            $M = ([string]$P.Name).Split('/'); $R = ([string]$P.Value).Split('/')
            if ($M.Count -lt 5 -or $R.Count -lt 5 -or $M[3] -ine 'resourcegroups' -or $R[3] -ine 'resourcegroups') { continue }
            # Group tokens are made per group name, letter case aside, so groups
            # of one name in two subscriptions share a token on purpose; the
            # subscription token keeps them apart.
            $Real = $R[4].ToLowerInvariant()
            if (-not $TokensOf.ContainsKey($Real)) { $TokensOf[$Real] = @{} }; $TokensOf[$Real][$M[4]] = $true
            if (-not $RealsOf.ContainsKey($M[4])) { $RealsOf[$M[4]] = @{} }; $RealsOf[$M[4]][$Real] = $true
        }
        if ($TokensOf.Count -eq 0) { Set-ItResult -Skipped -Because 'no masked resource group path in the dictionary'; return }
        foreach ($Real in $TokensOf.Keys) { $TokensOf[$Real].Count | Should -Be 1 -Because 'a real resource group name keeps one token in every id' }
        foreach ($Tok in $RealsOf.Keys) { $RealsOf[$Tok].Count | Should -Be 1 -Because 'a token stands for one real resource group name' }
    }
}

# ============================================================================
# Cross-reference coverage.
# Purely additive. Closes gaps for cross-reference pairs not already asserted
# above (SQLDB server/pool, SQLMIDB managed instance, AvSet VMs, VMSS related
# cluster), the out-of-scope 'obfuscated' sentinel, and the metric
# per-resource cached token. Where the live fixture lacks a given
# pair the block skips gracefully rather than fabricating resources.
# The disk->VM (VM Disk to VM) and SQLVM->parent VM (SQL VM to VM) pairs are
# already covered by the blocks above and are intentionally NOT duplicated here.
# ============================================================================

Describe "SQLDB to SQL Server Cross-Reference" {
    It "Every SQLDB DatabaseServer carries the same token its parent SQL Server uses (or the 'obfuscated' sentinel)" {
        $SqlDbs = @($script:Inventory.SQLDB) | Where-Object { $null -ne $_ }
        if ($SqlDbs.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLDB resources in this fixture"; return }
        $ServerIds = @($script:Inventory.SQLSERVER) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($db in $SqlDbs)
        {
            if (![string]::IsNullOrEmpty($db.DatabaseServer) -and $db.DatabaseServer -ne 'obfuscated')
            {
                $db.DatabaseServer | Should -BeIn $ServerIds -Because "SQLDB '$($db.ID)' DatabaseServer should match its parent SQL Server's own obfuscated ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "all SQLDB DatabaseServer values were the out-of-scope 'obfuscated' sentinel (no in-scope parent server present)" }
    }

    It "Every SQLDB ElasticPoolID carries the same token its elastic pool uses (or a 'None'/'obfuscated' sentinel)" {
        $SqlDbs = @($script:Inventory.SQLDB) | Where-Object { $null -ne $_ }
        if ($SqlDbs.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLDB resources in this fixture"; return }
        $PoolIds = @($script:Inventory.SQLPOOL) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Tolerated = @('None', 'obfuscated')
        $Checked = 0
        foreach ($db in $SqlDbs)
        {
            if (![string]::IsNullOrEmpty($db.ElasticPoolID) -and $db.ElasticPoolID -notin $Tolerated)
            {
                $db.ElasticPoolID | Should -BeIn $PoolIds -Because "SQLDB '$($db.ID)' ElasticPoolID should match its elastic pool's own obfuscated ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no SQLDB is a member of an in-scope elastic pool in this fixture (all 'None'/sentinel)" }
    }
}

Describe "SQLMIDB to Managed Instance Cross-Reference" {
    It "Every SQLMIDB ManagedInstance carries the same token its managed instance uses (or the 'obfuscated' sentinel)" {
        $MiDbs = @($script:Inventory.SQLMIDB) | Where-Object { $null -ne $_ }
        if ($MiDbs.Count -eq 0) { Set-ItResult -Skipped -Because "no SQLMIDB resources in this fixture"; return }
        $MiIds = @($script:Inventory.SQLMI) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($midb in $MiDbs)
        {
            if (![string]::IsNullOrEmpty($midb.ManagedInstance) -and $midb.ManagedInstance -ne 'obfuscated')
            {
                $midb.ManagedInstance | Should -BeIn $MiIds -Because "SQLMIDB '$($midb.ID)' ManagedInstance should match its managed instance's own obfuscated ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "all SQLMIDB ManagedInstance values were the out-of-scope 'obfuscated' sentinel" }
    }
}

Describe "AvSet to VM Cross-Reference" {
    It "Every AvSet VirtualMachines token carries the same token the member VM uses (or the 'obfuscated' sentinel)" {
        $AvSets = @($script:Inventory.AvSet) | Where-Object { $null -ne $_ }
        if ($AvSets.Count -eq 0) { Set-ItResult -Skipped -Because "no AvSet resources in this fixture"; return }
        $VmIds = @($script:Inventory.VirtualMachines) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID }
        $Checked = 0
        foreach ($av in $AvSets)
        {
            if (![string]::IsNullOrEmpty($av.VirtualMachines) -and $av.VirtualMachines -ne 'obfuscated')
            {
                $av.VirtualMachines | Should -BeIn $VmIds -Because "AvSet '$($av.ID)' VirtualMachines should match a member VM's own obfuscated ID"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "all AvSet VirtualMachines values were empty or the out-of-scope 'obfuscated' sentinel" }
    }
}

Describe "VMSS Related-Cluster Cross-Reference" {
    It "Every VMSS related-cluster value carries the same token its AKS cluster uses, the out-of-scope sentinel, or a well-formed token for a Service-Fabric-backed scale set" {
        $VmssItems = @($script:Inventory.VMSS) | Where-Object { $null -ne $_ }
        if ($VmssItems.Count -eq 0) { Set-ItResult -Skipped -Because "no VMSS resources in this fixture"; return }
        # A scale set exposes its related cluster via the 'AKS' field. The
        # collector (Services/Containers/VMSS.ps1) resolves an AKS cluster
        # first; if none owns the node pool's resource group it falls back to
        # a Service Fabric cluster match instead. Either way it resolves the
        # cluster's real ID through $ResourceIdDictionary and emits the SAME
        # token the cluster's own row uses for its identity, or the
        # 'obfuscated' sentinel when the target is out of scope.
        # There is no dedicated Service Fabric collector/inventory bucket, so
        # a Service-Fabric-backed match can't be looked up against a known-ID
        # allowlist the way AKS can - instead we accept any well-formed masked
        # ID, which the AKS-cluster case already satisfies.
        $ClusterIds = @(@($script:Inventory.AKS) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ID })
        $Checked = 0
        foreach ($ss in $VmssItems)
        {
            if (![string]::IsNullOrEmpty($ss.AKS))
            {
                $IsKnownClusterId = $ss.AKS -in $ClusterIds
                $IsSentinel = $ss.AKS -eq 'obfuscated'
                $IsWellFormedToken = $ss.AKS -match $script:MaskedIdPattern
                ($IsKnownClusterId -or $IsSentinel -or $IsWellFormedToken) | Should -BeTrue `
                    -Because "VMSS '$($ss.ID)' related-cluster value should match its cluster's own obfuscated ID (AKS or Service Fabric), or be the out-of-scope sentinel"
                $Checked++
            }
        }
        if ($Checked -eq 0) { Set-ItResult -Skipped -Because "no VMSS carried a related-cluster value in this fixture" }
    }
}

Describe "Cross-Reference Out-of-Scope Sentinel" {
    It "Every in-scope cross-reference value is a valid target token or exactly the 'obfuscated' sentinel" {
        # Gather every known ID cross-reference field across the in-scope pairs.
        # Each value must be one of: a token that resolves to a real target ID in
        # the inventory (same token), the literal 'obfuscated' sentinel
        # for an out-of-scope target, a benign 'None'/'' placeholder,
        # or a well-formed token. It must NEVER be a raw ARM path.
        $Refs = @()
        @($script:Inventory.VMDisk)  | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.AssociatedResource) { $Refs += $_.AssociatedResource } }
        @($script:Inventory.SQLVM)   | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.ParentVirtualMachine) { $Refs += $_.ParentVirtualMachine } }
        @($script:Inventory.SQLDB)   | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.DatabaseServer) { $Refs += $_.DatabaseServer }; if ($_.ElasticPoolID) { $Refs += $_.ElasticPoolID } }
        @($script:Inventory.SQLMIDB) | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.ManagedInstance) { $Refs += $_.ManagedInstance } }
        @($script:Inventory.AvSet)   | Where-Object { $null -ne $_ } | ForEach-Object { if ($_.VirtualMachines) { $Refs += $_.VirtualMachines } }
        $Refs = @($Refs | Where-Object { ![string]::IsNullOrEmpty($_) })
        if ($Refs.Count -eq 0) { Set-ItResult -Skipped -Because "no cross-reference values present in this fixture"; return }
        $Tolerated = @('obfuscated', 'None')
        foreach ($ref in $Refs)
        {
            if ($ref -in $Tolerated) { continue }
            ($ref -in $script:AllIds -or $ref -match $script:MaskedIdPattern) | Should -BeTrue -Because "cross-reference '$ref' must be a valid target token or the 'obfuscated' sentinel, never a raw identifier"
        }
    }
}

Describe "Metric Per-Resource Cached Token" {
    It "Metric rows for the same resource carry a consistent obfuscated identity across their own metrics" {
        if ($script:MetricRows.Count -eq 0) { Set-ItResult -Skipped -Because "no metric rows in this fixture"; return }
        # A resource's obfuscated identity must be stable across all of its own
        # metric rows so the resource still correlates. Group by obfuscated ID
        # and assert Name/Subscription/ResourceGroup are constant within a group.
        $Violations = @()
        $script:MetricRows | Where-Object { ![string]::IsNullOrEmpty($_.ID) } | Group-Object ID | ForEach-Object {
            $Names = @($_.Group.Name | Sort-Object -Unique).Count
            $Subs = @($_.Group.Subscription | Sort-Object -Unique).Count
            $Rgs = @($_.Group.ResourceGroup | Sort-Object -Unique).Count
            if ($Names -gt 1 -or $Subs -gt 1 -or $Rgs -gt 1) { $Violations += $_.Name }
        }
        $Violations | Should -BeNullOrEmpty -Because "each obfuscated resource ID should map to a single Name/Subscription/ResourceGroup across its metric rows"
    }

    It "Metric rows for resources absent from the main dictionary still carry a cached per-resource token" {
        if ($script:MetricRows.Count -eq 0) { Set-ItResult -Skipped -Because "no metric rows in this fixture"; return }
        # a metric row whose resource is NOT in the main inventory
        # dictionary gets a fresh cached token so it still correlates across its
        # own metrics. In a single-run fixture every metric-bearing resource is
        # normally also inventoried, so this fallback path may be unexercised.
        $AbsentIds = @($script:MetricRows | Where-Object { ![string]::IsNullOrEmpty($_.ID) -and $_.ID -notin $script:AllIds } | Select-Object -ExpandProperty ID -Unique)
        if ($AbsentIds.Count -eq 0) { Set-ItResult -Skipped -Because "fixture does not exercise the metric fallback path (all metric-referenced resources are present in the inventory dictionary)"; return }
        foreach ($id in $AbsentIds)
        {
            $id | Should -Match $script:MaskedIdPattern -Because "a metric resource absent from the main dictionary should still receive a masked ID with cached prod_/nonprod_ tokens, not a raw id ('$id')"
            $id | Should -Not -Be 'obfuscated' -Because "the metric fallback assigns a correlatable cached token, not the lossy sentinel"
        }
    }
}
