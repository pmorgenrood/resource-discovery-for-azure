# Merge-RecoveryData unit tests
# =============================================================================
# Offline, self-contained tests for the recovery-merge splice + re-package
# helper in Functions/RecoveryMerge.Functions.ps1. Each test builds a synthetic
# "gap" bundle (the incomplete run) and a "recovery" bundle (the scoped re-run)
# in a temp dir - Inventory_*.json plus optional Consumption_*.csv,
# Metrics_*.json and ObfuscationDictionary_*.json - then calls Merge-RecoveryData
# and asserts the splice, the packaging, and the fail-loud guards.
#
# No live Azure and no external fixture zip: the function only reads/writes files
# and re-invokes Extension/Summary.ps1 to regenerate the HTML, so a temp bundle
# is enough to drive it end to end. The only literal GUID used in synthetic ARM
# paths is the Azure docs placeholder (12345678-...-123456789012); obfuscation
# tokens are minted at runtime. No customer data.
# =============================================================================

BeforeAll {
    $script:FnFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RecoveryMerge.Functions.ps1'
    if (-not (Test-Path -Path $script:FnFile))
    {
        throw "RecoveryMerge.Functions.ps1 not found at $script:FnFile"
    }
    . $script:FnFile
    if (-not (Get-Command -Name 'Merge-RecoveryData' -ErrorAction SilentlyContinue))
    {
        throw 'Merge-RecoveryData was not defined after dot-sourcing RecoveryMerge.Functions.ps1'
    }

    $script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('RecoveryMergeTest_' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null

    # Canonical empty-consumption header the function writes when no CSV exists.
    $script:CsvHeader = 'InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId,ResourceLocation,ConsumptionMeter,ReservationId,ReservationOrderId'
    $script:DocsGuid = '12345678-1234-1234-1234-123456789012'

    # Fresh, isolated gap/recovery/output folders per test case.
    function New-Case
    {
        $Id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        [pscustomobject]@{
            Gap      = Join-Path $script:TmpRoot ("gap_$Id")
            Recovery = Join-Path $script:TmpRoot ("rec_$Id")
            Output   = Join-Path $script:TmpRoot ("out_$Id")
        }
    }

    # One synthetic resource record with the common fields Summary.ps1 samples.
    function New-Record([string]$Name, [string]$Rg = 'rg-app')
    {
        [ordered]@{
            Name          = $Name
            Subscription  = 'prod_sub'
            Location      = 'eastus'
            ResourceGroup = $Rg
            ID            = ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Compute/virtualMachines/{2}' -f $script:DocsGuid, $Rg, $Name)
        }
    }

    # Masked disk records shaped as the output contract says
    # (/subscriptions/<prod_ token>/resourcegroups/<prod_ token>/providers/microsoft.compute/disks/<prod_ token>),
    # with the dictionary a masked run writes for them (token -> real value).
    # With -Seed (an earlier result), the new records reuse its subscription and
    # resource group tokens and the dictionary also holds every seed entry, as a
    # run seeded with -ObfuscationDictionary writes it.
    function Get-MaskedBundleData([int]$Count = 3, $Seed)
    {
        $Sub = if ($Seed) { $Seed.Sub } else { 'prod_' + [guid]::NewGuid().ToString() }
        $Rg = if ($Seed) { $Seed.Rg } else { 'prod_' + [guid]::NewGuid().ToString() }
        $Records = @()
        $IdMap = [ordered]@{}; $NameMap = [ordered]@{}
        if ($Seed)
        {
            foreach ($K in $Seed.Dictionary.ResourceIdMap.Keys) { $IdMap[$K] = $Seed.Dictionary.ResourceIdMap[$K] }
            foreach ($K in $Seed.Dictionary.ResourceNameMap.Keys) { $NameMap[$K] = $Seed.Dictionary.ResourceNameMap[$K] }
        }
        for ($i = 0; $i -lt $Count; $i++)
        {
            $Name = 'prod_' + [guid]::NewGuid().ToString()
            $Id = '/subscriptions/{0}/resourcegroups/{1}/providers/microsoft.compute/disks/{2}' -f $Sub, $Rg, $Name
            $Records += [ordered]@{ Name = $Name; Subscription = $Sub; ResourceGroup = $Rg; Location = 'eastus'; ID = $Id }
            $IdMap[$Id] = '/subscriptions/{0}/resourceGroups/rg-app/providers/Microsoft.Compute/disks/disk{1}' -f $script:DocsGuid, $i
            $NameMap[$Name] = 'disk' + $i
        }
        [pscustomobject]@{
            Sub        = $Sub
            Rg         = $Rg
            Records    = $Records
            Dictionary = [ordered]@{
                GeneratedAt      = '2026-01-01 00:00:00'
                ResourceIdMap    = $IdMap
                ResourceNameMap  = $NameMap
                SubscriptionMap  = [ordered]@{ $Sub = $script:DocsGuid }
                ResourceGroupMap = [ordered]@{ $Rg = 'rg-app' }
            }
        }
    }

    # One metric record with the fields and value types Extension/Metrics.ps1 writes.
    function New-MetricRecord([string]$Id = '/id', [string]$Name = 'vm01', $Series = $null)
    {
        [ordered]@{
            ID               = $Id
            Subscription     = 'prod_sub'
            ResourceGroup    = 'rg-app'
            Name             = $Name
            Location         = 'eastus'
            Service          = 'VirtualMachines'
            Metric           = 'Percentage CPU'
            MetricAggregate  = 'Average'
            MetricTimeGrain  = '01:00:00'
            MetricMeasure    = 'Average'
            MetricPercentile = 12.5
            MetricValue      = 7.25
            MetricCount      = 24
            MetricTotalCount = 24
            MetricSeries     = $Series
            MetricError      = $false
        }
    }

    # A Metrics file text holding one such record.
    function New-MetricsJson([string]$Name, [string]$Id = '/id')
    {
        @{ Metrics = @((New-MetricRecord -Id $Id -Name $Name)) } | ConvertTo-Json -Depth 5 -Compress
    }

    # Write a bundle folder. Inventory is a hashtable of service-name -> record[].
    function New-Bundle
    {
        param(
            [Parameter(Mandatory)][string]$Dir,
            [Parameter(Mandatory)][string]$Base,
            $Inventory,
            [string]$ConsumptionCsv,
            [hashtable]$MetricsFiles,
            $Dictionary
        )
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        if ($null -ne $Inventory)
        {
            ($Inventory | ConvertTo-Json -Depth 100) | Out-File -FilePath (Join-Path $Dir ('Inventory_{0}.json' -f $Base)) -Encoding utf8
        }
        if ($PSBoundParameters.ContainsKey('ConsumptionCsv') -and $null -ne $ConsumptionCsv)
        {
            $ConsumptionCsv | Out-File -FilePath (Join-Path $Dir ('Consumption_{0}.csv' -f $Base)) -Encoding utf8
        }
        if ($null -ne $MetricsFiles)
        {
            foreach ($Suffix in $MetricsFiles.Keys)
            {
                $MetricsFiles[$Suffix] | Out-File -FilePath (Join-Path $Dir ('Metrics_{0}{1}.json' -f $Base, $Suffix)) -Encoding utf8
            }
        }
        if ($null -ne $Dictionary)
        {
            ($Dictionary | ConvertTo-Json -Depth 10) | Out-File -FilePath (Join-Path $Dir ('ObfuscationDictionary_{0}.json' -f $Base)) -Encoding utf8
        }
    }

    # Expand a produced zip and return the entry file names.
    function Get-ZipEntryNames([string]$ZipPath)
    {
        $Dest = Join-Path $script:TmpRoot ('unzip_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $Dest -Force
        @(Get-ChildItem -Path $Dest -File | Select-Object -ExpandProperty Name)
    }

    $script:GapBase = 'GapReport_20260101_000000'
    $script:RecBase = 'RecReport_20260102_000000'
}

AfterAll {
    if ($script:TmpRoot -and (Test-Path -Path $script:TmpRoot))
    {
        Remove-Item -Path $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Merge-RecoveryData inventory splice' {

    It 'adds a missing service key from the recovery bundle (default = all keys)' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{
                Version         = '3.2.3'
                VirtualMachines = @((New-Record 'vm01'))
            })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{
                Version     = '3.2.3'
                AppServices = @((New-Record 'app01'))
            })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Merged = Get-Content -Path $Result.OutputInventory -Raw | ConvertFrom-Json
        $Merged.PSObject.Properties.Name | Should -Contain 'VirtualMachines' -Because 'the gap inventory key must be preserved'
        $Merged.PSObject.Properties.Name | Should -Contain 'AppServices' -Because 'the recovered key must be spliced in'
        @($Merged.AppServices).Count | Should -Be 1
    }

    It 'replaces an existing service key when the recovery bundle provides the same key' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{
                Version         = '3.2.3'
                VirtualMachines = @((New-Record 'vm-old'))
            })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{
                Version         = '3.2.3'
                VirtualMachines = @((New-Record 'vm-new-a'), (New-Record 'vm-new-b'))
            })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Merged = Get-Content -Path $Result.OutputInventory -Raw | ConvertFrom-Json
        @($Merged.VirtualMachines).Count | Should -Be 2 -Because 'the recovery key replaces the gap key, not appends to it'
        @($Merged.VirtualMachines.Name) | Should -Not -Contain 'vm-old'
    }

    It 'returns MergedServiceKeys listing exactly what was spliced' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')); StorageAcc = @((New-Record 'sa01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        @($Result.MergedServiceKeys) | Should -Contain 'AppServices'
        @($Result.MergedServiceKeys) | Should -Contain 'StorageAcc'
        @($Result.MergedServiceKeys) | Should -Not -Contain 'Version' -Because 'the Version marker is not a service key'
    }

    It 'names inventory, html and zip outputs from the gap bundle base' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Result.BundleBase | Should -Be $script:GapBase
        (Split-Path $Result.OutputInventory -Leaf) | Should -Be ('Inventory_{0}.json' -f $script:GapBase)
        (Split-Path $Result.OutputHtml -Leaf) | Should -Be ('{0}.html' -f $script:GapBase)
        Test-Path -Path $Result.OutputZip | Should -BeTrue
        Test-Path -Path $Result.OutputHtml | Should -BeTrue
    }
}

Describe 'Merge-RecoveryData -Service selection and fail-loud guards' {

    It 'splices only the named service when -Service is an explicit subset' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')); StorageAcc = @((New-Record 'sa01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -Service 'AppServices'

        @($Result.MergedServiceKeys) | Should -Be @('AppServices')
        $Merged = Get-Content -Path $Result.OutputInventory -Raw | ConvertFrom-Json
        $Merged.PSObject.Properties.Name | Should -Contain 'AppServices'
        $Merged.PSObject.Properties.Name | Should -Not -Contain 'StorageAcc' -Because 'a service not named in -Service must not be spliced'
    }

    It 'throws when a named -Service is absent from the recovery inventory (partial miss)' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -Service 'AppServices', 'Missing' } |
            Should -Throw -ExpectedMessage '*not found in the recovery inventory*'
    }

    It 'throws when the recovery inventory has no service keys and no recover switch is set' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3' })

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output } |
            Should -Throw -ExpectedMessage '*nothing to merge*'
    }
}

Describe 'Merge-RecoveryData consumption handling' {

    It 'carries the gap consumption CSV forward by default (ConsumptionSource = gap)' {
        $C = New-Case
        $GapCsv = "$script:CsvHeader`n{},Compute,m1,GAP-METER,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $GapCsv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Result.ConsumptionSource | Should -Be 'gap'
        $OutCsv = Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase)
        (Get-Content -Path $OutCsv -Raw) | Should -Match 'GAP-METER'
    }

    It 'replaces consumption with the recovery CSV under -RecoverConsumption (ConsumptionSource = recovery)' {
        $C = New-Case
        $GapCsv = "$script:CsvHeader`n{},Compute,m1,GAP-METER,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        $RecCsv = "$script:CsvHeader`n{},Compute,m1,REC-METER,eastus,vm,9,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $GapCsv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $RecCsv

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption

        $Result.ConsumptionSource | Should -Be 'recovery'
        $OutCsv = Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase)
        (Get-Content -Path $OutCsv -Raw) | Should -Match 'REC-METER'
        (Get-Content -Path $OutCsv -Raw) | Should -Not -Match 'GAP-METER'
    }

    It 'throws when -RecoverConsumption is set but the recovery bundle has no CSV' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption } |
            Should -Throw -ExpectedMessage '*has no Consumption_*'
        Test-Path -LiteralPath $C.Output | Should -BeFalse -Because 'nothing is written before the stop'
    }

    It 'refuses an -OutputPath that is the <Which> folder, before writing anything' -ForEach @(@{ Which = 'gap' }, @{ Which = 'recovery' }) {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $script:CsvHeader
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $Out = if ($Which -eq 'gap') { $C.Gap } else { $C.Recovery + [System.IO.Path]::DirectorySeparatorChar }
        $Before = @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name })
        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $Out } | Should -Throw -ExpectedMessage '*is a source bundle folder*Nothing was written*'
        @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name }) | Should -Be $Before
    }

    It 'refuses a relative -OutputPath that names the gap folder from the PowerShell location' {
        # A relative path is read against the PowerShell location, which can
        # differ from the process directory after Set-Location.
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $script:CsvHeader
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $Before = @(Get-ChildItem -LiteralPath $C.Gap -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name })
        $ProcessDir = [System.Environment]::CurrentDirectory
        Push-Location -LiteralPath (Split-Path -Parent $C.Gap)
        try
        {
            [System.Environment]::CurrentDirectory = [System.IO.Path]::GetTempPath()
            $Relative = '.' + [System.IO.Path]::DirectorySeparatorChar + (Split-Path -Leaf $C.Gap)
            { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $Relative } | Should -Throw -ExpectedMessage '*is a source bundle folder*Nothing was written*'
        }
        finally
        {
            Pop-Location
            [System.Environment]::CurrentDirectory = $ProcessDir
        }
        @(Get-ChildItem -LiteralPath $C.Gap -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name }) | Should -Be $Before
    }

    It 'refuses an -OutputPath that is a link to the <Which> folder' -ForEach @(@{ Which = 'gap' }, @{ Which = 'recovery' }) {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $script:CsvHeader
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $Target = if ($Which -eq 'gap') { $C.Gap } else { $C.Recovery }
        $Link = Join-Path (Split-Path -Parent $C.Output) ('link_' + [guid]::NewGuid().ToString('N'))
        try { $null = New-Item -ItemType SymbolicLink -Path $Link -Target $Target -ErrorAction Stop }
        catch { Set-ItResult -Skipped -Because 'this host cannot make symbolic links'; return }
        $Before = @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name })
        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $Link } | Should -Throw -ExpectedMessage '*is a source bundle folder*Nothing was written*'
        # The reverse spelling: the source given through the link, the output as the real folder.
        if ($Which -eq 'gap')
        {
            { Merge-RecoveryData -GapBundlePath $Link -RecoveryBundlePath $C.Recovery -OutputPath $C.Gap } | Should -Throw -ExpectedMessage '*is a source bundle folder*Nothing was written*'
        }
        @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name }) | Should -Be $Before
    }

    It 'never writes into the gap folder for an -OutputPath of a link, then ..' {
        # A link to a subfolder of the gap folder, then '..'. PowerShell and
        # .NET both read '..' as text, so the guard and every write agree on
        # the link's own parent; the gap folder is never reached.
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $script:CsvHeader
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $Sub = Join-Path $C.Gap 'sub'
        $null = New-Item -ItemType Directory -Path $Sub
        $LinkDir = Join-Path (Split-Path -Parent $C.Output) ('other_' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $LinkDir
        $Link = Join-Path $LinkDir 'L'
        try { $null = New-Item -ItemType SymbolicLink -Path $Link -Target $Sub -ErrorAction Stop }
        catch { Set-ItResult -Skipped -Because 'this host cannot make symbolic links'; return }
        $Before = @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name })
        $null = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath ($Link + [System.IO.Path]::DirectorySeparatorChar + '..')
        @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name }) | Should -Be $Before
        Test-Path -LiteralPath (Join-Path $LinkDir ('Inventory_{0}.json' -f $script:GapBase)) | Should -BeTrue
    }

    It 'merges into an output folder that holds a copy of the <Which> bundle, which is not the source folder' -ForEach @(@{ Which = 'gap' }, @{ Which = 'recovery' }) {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $script:CsvHeader
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $Source = if ($Which -eq 'gap') { $C.Gap } else { $C.Recovery }
        $null = New-Item -ItemType Directory -Path $C.Output
        Get-ChildItem -LiteralPath $Source -File | Copy-Item -Destination $C.Output
        $Before = @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name })
        $null = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output
        @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name }) | Should -Be $Before
        @(Get-ChildItem -LiteralPath $C.Output -Force -Filter '.rda-merge-probe-*').Count | Should -Be 0 -Because 'the folder check leaves nothing behind'
    }

    It 'refuses an existing -OutputPath whose probe file shows up in the <Which> folder' -ForEach @(@{ Which = 'gap' }, @{ Which = 'recovery' }) {
        # Stands in for a bind mount or mapped drive: the path guard sees two
        # folders, but a file made in the output shows up in the source.
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $script:CsvHeader
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $null = New-Item -ItemType Directory -Path $C.Output
        $script:ProbeSource = if ($Which -eq 'gap') { $C.Gap } else { $C.Recovery }
        Mock Test-Path -ParameterFilter { $LiteralPath -and ([string]$LiteralPath -like ((Join-Path $script:ProbeSource '.rda-merge-probe-') + '*')) } -MockWith { $true }
        $Before = @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name })
        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output } | Should -Throw -ExpectedMessage '*is a source bundle folder*Nothing was written*'
        @(Get-ChildItem -LiteralPath $C.Output -Force).Count | Should -Be 0 -Because 'the probe is removed and nothing else is written'
        @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name }) | Should -Be $Before
    }

    It 'lets a consumption-only merge run again into the same output folder' {
        # With an empty recovery inventory the merged inventory is byte for
        # byte the gap inventory, under the gap inventory's name.
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $script:CsvHeader
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3' }) -ConsumptionCsv $script:CsvHeader
        $Before = @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name })
        $null = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption
        $OutCsv = Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase)
        $OutInventory = Join-Path $C.Output ('Inventory_{0}.json' -f $script:GapBase)
        $FirstInventoryHash = (Get-FileHash -LiteralPath $OutInventory).Hash
        'stale' | Out-File -FilePath $OutCsv -Encoding utf8
        'stale' | Out-File -FilePath $OutInventory -Encoding utf8
        $Second = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption
        $Second.ConsumptionSource | Should -Be 'recovery'
        (Get-Content -LiteralPath $OutCsv -Raw) | Should -Not -Match 'stale' -Because 'the second run rewrites the consumption file'
        (Get-FileHash -LiteralPath $OutInventory).Hash | Should -Be $FirstInventoryHash -Because 'the second run rewrites the inventory file'
        @(Get-ChildItem -LiteralPath $C.Output -File -Filter 'Inventory_*.json').Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $C.Output -File -Filter 'Consumption_*.csv').Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name }) | Should -Be $Before
    }

    It 'refuses an -OutputPath under a parent link with a relative target' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $script:CsvHeader
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $Parent = Split-Path -Parent $C.Gap
        $Link = Join-Path $Parent ('plink_' + [guid]::NewGuid().ToString('N'))
        # The link's target is written as a relative path ('.'), so it is read from the link's own folder.
        try { $null = New-Item -ItemType SymbolicLink -Path $Link -Target '.' -ErrorAction Stop }
        catch { Set-ItResult -Skipped -Because 'this host cannot make symbolic links'; return }
        $Before = @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name })
        $Out = Join-Path $Link (Split-Path -Leaf $C.Gap)
        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $Out } | Should -Throw -ExpectedMessage '*is a source bundle folder*Nothing was written*'
        @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name }) | Should -Be $Before
    }

    It 'merges into a new folder whose name differs from the gap folder only in case, where the file system tells them apart' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $script:CsvHeader
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $Out = Join-Path (Split-Path -Parent $C.Gap) ((Split-Path -Leaf $C.Gap).ToUpperInvariant())
        if (Test-Path -LiteralPath $Out) { Set-ItResult -Skipped -Because 'this file system does not tell names apart by case'; return }
        $Before = @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name })
        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $Out
        Test-Path -LiteralPath $Result.OutputZip | Should -BeTrue
        (Split-Path -Parent $Result.OutputInventory) | Should -BeExactly $Out
        @(Get-ChildItem -LiteralPath $C.Gap, $C.Recovery -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash + ' ' + $_.Name }) | Should -Be $Before
    }

    It 'reads and writes only the named folders when their names hold [1] and a folder named without the brackets sits next to each (<Case>)' -ForEach @(
        @{ Case = 'gap consumption and metrics'; Recover = $false },
        @{ Case = 'recovered consumption and metrics'; Recover = $true }
    ) {
        $Id = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $Gap = Join-Path $script:TmpRoot ("gap_$Id[1]"); $GapDecoy = Join-Path $script:TmpRoot ("gap_${Id}1")
        $Rec = Join-Path $script:TmpRoot ("rec_$Id[1]"); $RecDecoy = Join-Path $script:TmpRoot ("rec_${Id}1")
        $Out = Join-Path $script:TmpRoot ("out_$Id[1]"); $OutDecoy = Join-Path $script:TmpRoot ("out_${Id}1")
        $Csv = { param($Meter) "$script:CsvHeader`n{},Compute,m1,$Meter,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,," }
        # New-Bundle writes with -FilePath, so the bracketed folders are filled with literal-path calls here.
        foreach ($Pair in @(@($Gap, $script:GapBase, 'vm-real', 'GAP-REAL'), @($Rec, $script:RecBase, 'app-real', 'REC-REAL')))
        {
            $Tmp = Join-Path $script:TmpRoot ('stage_' + [guid]::NewGuid().ToString('N'))
            $Key = if ($Pair[0] -eq $Gap) { 'VirtualMachines' } else { 'AppServices' }
            New-Bundle -Dir $Tmp -Base $Pair[1] -Inventory ([ordered]@{ Version = '3.2.3'; $Key = @((New-Record $Pair[2])) }) -ConsumptionCsv (& $Csv $Pair[3]) -MetricsFiles @{ '__0' = (New-MetricsJson $Pair[3]) }
            $null = New-Item -ItemType Directory -Path $Pair[0]
            Get-ChildItem -LiteralPath $Tmp -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Pair[0] $_.Name) }
        }
        New-Bundle -Dir $GapDecoy -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm-decoy')) }) -ConsumptionCsv (& $Csv 'GAP-DECOY') -MetricsFiles @{ '__0' = (New-MetricsJson 'GAP-DECOY') }
        New-Bundle -Dir $RecDecoy -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app-decoy')) }) -ConsumptionCsv (& $Csv 'REC-DECOY') -MetricsFiles @{ '__0' = (New-MetricsJson 'REC-DECOY') }
        $null = New-Item -ItemType Directory -Path $OutDecoy

        $Splat = @{ GapBundlePath = $Gap; RecoveryBundlePath = $Rec; OutputPath = $Out; WarningAction = 'SilentlyContinue' }
        if ($Recover) { $Splat.RecoverConsumption = $true; $Splat.RecoverMetrics = $true }
        $Result = Merge-RecoveryData @Splat

        $Want = if ($Recover) { 'REC-REAL' } else { 'GAP-REAL' }
        $Inv = Get-Content -LiteralPath (Join-Path $Out ('Inventory_{0}.json' -f $script:GapBase)) -Raw
        $Inv | Should -Match 'vm-real'
        $Inv | Should -Match 'app-real'
        $Inv | Should -Not -Match 'decoy'
        (Get-Content -LiteralPath (Join-Path $Out ('Consumption_{0}.csv' -f $script:GapBase)) -Raw) | Should -Match $Want
        (Get-Content -LiteralPath (Join-Path $Out ('Metrics_{0}__0.json' -f $script:GapBase)) -Raw) | Should -Match $Want
        Test-Path -LiteralPath (Join-Path $Out ('{0}.html' -f $script:GapBase)) | Should -BeTrue
        $Result.OutputZip | Should -Be (Join-Path $Out ('{0}.zip' -f $script:GapBase))
        $Entries = @(Get-ZipEntryNames -ZipPath $Result.OutputZip)
        $Entries | Should -Contain ('Inventory_{0}.json' -f $script:GapBase)
        $Entries | Should -Contain ('Consumption_{0}.csv' -f $script:GapBase)
        $Entries | Should -Contain ('Metrics_{0}__0.json' -f $script:GapBase)
        @(Get-ChildItem -LiteralPath $OutDecoy -Force).Count | Should -Be 0 -Because 'nothing is written to the folder named without the brackets'
    }

    It 'warns once, not twice, when the recovery bundle holds two consumption files under -RecoverConsumption' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -ConsumptionCsv $script:CsvHeader
        $script:CsvHeader | Out-File -FilePath (Join-Path $C.Recovery 'Consumption_second.csv') -Encoding utf8
        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption -WarningAction SilentlyContinue
        @($Result.Warnings | Where-Object { $_ -match "files match 'Consumption_\*\.csv'" }).Count | Should -Be 1
    }

    It 'stops before writing anything when the <Which> consumption file it would zip lacks <Missing>' -ForEach @(
        @{ Which = 'gap'; Missing = 'MeterId'; Header = 'InstanceData,MeterCategory,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceId' },
        @{ Which = 'recovery'; Missing = 'ResourceId'; Header = 'InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,UsageEndTime,ResourceUri' },
        @{ Which = 'gap'; Missing = 'any header'; Header = '' },
        @{ Which = 'gap'; Missing = 'Quantity'; Header = 'InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Unit,UsageStartTime,UsageEndTime,ResourceId' },
        @{ Which = 'recovery'; Missing = 'UsageStartTime'; Header = 'InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageEndTime,ResourceId' },
        @{ Which = 'gap'; Missing = 'UsageEndTime'; Header = 'InstanceData,MeterCategory,MeterId,MeterName,MeterRegion,MeterSubCategory,Quantity,Unit,UsageStartTime,ResourceId' }
    ) {
        $C = New-Case
        $Bad = if ($Header) { "$Header`n{},Compute,m1,MET,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id" } else { '' }
        $GapCsv = if ($Which -eq 'gap') { $Bad } else { $script:CsvHeader }
        $RecCsv = if ($Which -eq 'recovery') { $Bad } else { $script:CsvHeader }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $GapCsv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $RecCsv
        $Splat = @{ GapBundlePath = $C.Gap; RecoveryBundlePath = $C.Recovery; OutputPath = $C.Output; WarningAction = 'SilentlyContinue' }
        if ($Which -eq 'recovery') { $Splat.RecoverConsumption = $true }

        { Merge-RecoveryData @Splat } | Should -Throw -ExpectedMessage "*the $Which bundle's consumption file*has no*column*Nothing was written*"
        Test-Path -LiteralPath $C.Output | Should -BeFalse -Because 'a consumption file downstream would drop stops the merge before any file is written'
    }

    It 'stops before writing anything when the <Which> consumption file it would zip has <Case>' -ForEach @(
        @{ Which = 'gap'; Case = 'a Quantity with a decimal comma'; Header = ''; Row = '{},Compute,m1,MET,eastus,vm,"1,5",Hours,2026-01-01,2026-01-02,/id,eastus,,,'; Expect = "*row 2 has a Quantity of '1,5'*" },
        @{ Which = 'recovery'; Case = 'a Quantity with a thousands mark'; Header = ''; Row = '{},Compute,m1,MET,eastus,vm,"1,000.5",Hours,2026-01-01,2026-01-02,/id,eastus,,,'; Expect = "*row 2 has a Quantity of '1,000.5'*" },
        @{ Which = 'recovery'; Case = 'a Quantity that is text'; Header = ''; Row = '{},Compute,m1,MET,eastus,vm,one,Hours,2026-01-01,2026-01-02,/id,eastus,,,'; Expect = "*row 2 has a Quantity of 'one'*" },
        @{ Which = 'gap'; Case = 'a Quantity that is not a finite number'; Header = ''; Row = '{},Compute,m1,MET,eastus,vm,NaN,Hours,2026-01-01,2026-01-02,/id,eastus,,,'; Expect = "*row 2 has a Quantity of 'NaN'*" },
        @{ Which = 'gap'; Case = 'a UsageStartTime that is not a date'; Header = ''; Row = '{},Compute,m1,MET,eastus,vm,1,Hours,soon,2026-01-02,/id,eastus,,,'; Expect = "*row 2 has a UsageStartTime of 'soon'*" },
        @{ Which = 'recovery'; Case = 'an empty UsageEndTime'; Header = ''; Row = '{},Compute,m1,MET,eastus,vm,1,Hours,2026-01-01,,/id,eastus,,,'; Expect = '*row 2 has a UsageEndTime of*not a date*' },
        @{ Which = 'gap'; Case = 'a last row cut off by a failed pull'; Header = ''; Row = '{},Compute,m1,MET,eastus,vm,1,Ho'; Expect = '*row 2 has a UsageStartTime of*not a date*' },
        @{ Which = 'gap'; Case = 'a Cost that is not a number'; Header = ',Cost'; Row = '{},Compute,m1,MET,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,,n/a'; Expect = "*row 2 has a Cost of 'n/a'*" },
        @{ Which = 'recovery'; Case = 'an empty UnitPrice'; Header = ',UnitPrice'; Row = '{},Compute,m1,MET,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,,'; Expect = "*row 2 has a UnitPrice of ''*" }
    ) {
        $C = New-Case
        $Good = '{},Compute,m1,MET,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,' + $(if ($Header) { ',1.5' } else { '' })
        $Bad = "$script:CsvHeader$Header`n$Good`n$Row"
        $GapCsv = if ($Which -eq 'gap') { $Bad } else { $script:CsvHeader }
        $RecCsv = if ($Which -eq 'recovery') { $Bad } else { $script:CsvHeader }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $GapCsv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $RecCsv
        $Splat = @{ GapBundlePath = $C.Gap; RecoveryBundlePath = $C.Recovery; OutputPath = $C.Output; WarningAction = 'SilentlyContinue' }
        if ($Which -eq 'recovery') { $Splat.RecoverConsumption = $true }

        $Message = $null
        try { $null = Merge-RecoveryData @Splat } catch { $Message = $_.Exception.Message }

        $Message | Should -BeLike "*the $Which bundle's consumption file*cannot be used*"
        $Message | Should -BeLike $Expect
        $Message | Should -BeLike '*Downstream would drop the whole file*Nothing was written*'
        Test-Path -LiteralPath $C.Output | Should -BeFalse -Because 'a consumption file downstream would drop stops the merge before any file is written'
    }

    It 'carries a consumption file forward byte for byte when every cell parses as the tool writes it' {
        $C = New-Case
        $Rows = @(
            # Export-Csv's own form: quoted cells, invariant dates and an exponent.
            '"{}","Compute","m1","MET","eastus","vm","1E-05","Hours","01/01/2026 00:00:00","01/02/2026 00:00:00","/id","eastus","","","","0.25","12"',
            '{},Compute,m2,MET,eastus,vm,0,Hours,2026-01-01T00:00:00+00:00,2026-01-02T00:00:00Z,/id,eastus,,,,0,0',
            # Empty ResourceId and MeterId: downstream drops these rows by themselves, so they do not stop the merge.
            '{},Compute,,MET,eastus,vm,2.5,Hours,2026-01-01,2026-01-02,,eastus,,,,1.5,3'
        )
        $Csv = (@("$script:CsvHeader,Cost,UnitPrice") + $Rows) -join "`n"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $Csv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $null = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        (Get-FileHash -LiteralPath (Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase))).Hash |
            Should -Be (Get-FileHash -LiteralPath (Join-Path $C.Gap ('Consumption_{0}.csv' -f $script:GapBase))).Hash
    }

    It 'merges the <Which> consumption file with rows downstream drops one by one, and warns once with their count' -ForEach @(
        @{ Which = 'gap' },
        @{ Which = 'recovery' }
    ) {
        # The tool's own run writes such rows, so stopping on them would stop
        # the gap, the recovery and every re-run alike.
        $C = New-Case
        $Csv = @(
            $script:CsvHeader,
            '{},Compute,m1,MET,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,',
            '{},Compute,m1,MET,eastus,vm,-1,Hours,2026-01-01,2026-01-02,/id,eastus,,,',
            '{},Compute,m1,MET,eastus,vm,1,Hours,2026-01-01,2026-01-02,,eastus,,,',
            '{},Compute,,MET,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,'
        ) -join "`n"
        $GapCsv = if ($Which -eq 'gap') { $Csv } else { $script:CsvHeader }
        $RecCsv = if ($Which -eq 'recovery') { $Csv } else { $script:CsvHeader }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $GapCsv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -ConsumptionCsv $RecCsv
        $Splat = @{ GapBundlePath = $C.Gap; RecoveryBundlePath = $C.Recovery; OutputPath = $C.Output; WarningAction = 'SilentlyContinue' }
        if ($Which -eq 'recovery') { $Splat.RecoverConsumption = $true }
        $Source = if ($Which -eq 'gap') { Join-Path $C.Gap ('Consumption_{0}.csv' -f $script:GapBase) } else { Join-Path $C.Recovery ('Consumption_{0}.csv' -f $script:RecBase) }

        $Result = Merge-RecoveryData @Splat

        (Get-FileHash -LiteralPath (Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase))).Hash | Should -Be (Get-FileHash -LiteralPath $Source).Hash
        $Drop = @($Result.Warnings | Where-Object { $_ -like '*downstream drops each such row*' })
        $Drop.Count | Should -Be 1
        $Drop[0] | Should -BeLike ("*the $Which bundle's consumption file '{0}' has 3 row(s)*" -f (Split-Path -Leaf $Source))
    }

    It 'reads each consumption file in one streaming pass that keeps no row' {
        # Every Import-Csv in the merge must feed a ForEach-Object straight away;
        # @(Import-Csv ...) or $x = Import-Csv ... would hold the whole file.
        $Source = Join-Path (Split-Path -Parent $PSScriptRoot) 'Functions/RecoveryMerge.Functions.ps1'
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$null, [ref]$null)
        $Calls = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Import-Csv' }, $true))
        $Calls.Count | Should -BeGreaterThan 0
        foreach ($Call in $Calls)
        {
            $Pipeline = $Call.Parent
            $Pipeline | Should -BeOfType ([System.Management.Automation.Language.PipelineAst])
            $Pipeline.PipelineElements.Count | Should -BeGreaterThan 1 -Because ('line {0} must stream into ForEach-Object' -f $Call.Extent.StartLineNumber)
            $Pipeline.PipelineElements[0] | Should -Be $Call
            $Pipeline.PipelineElements[1].GetCommandName() | Should -Be 'ForEach-Object'
            $Pipeline.Parent | Should -Not -BeOfType ([System.Management.Automation.Language.AssignmentStatementAst]) -Because ('line {0} must not keep the rows' -f $Call.Extent.StartLineNumber)
        }
    }

    It 'merges a large masked consumption file and still finds a plain id in its last row' {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 3
        $Seeded = Get-MaskedBundleData -Count 2 -Seed $Masked
        $Id = $Masked.Records[0].ID
        $Builder = [System.Text.StringBuilder]::new()
        [void]$Builder.AppendLine($script:CsvHeader)
        for ($i = 0; $i -lt 30000; $i++) { [void]$Builder.AppendLine("{},Storage,m1,P10,eastus,disk,1,Hours,2026-01-01,2026-01-02,$Id,eastus,,,") }
        $Csv = $Builder.ToString().TrimEnd()
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VMDisk = $Masked.Records }) -ConsumptionCsv $Csv -Dictionary $Masked.Dictionary
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = $Seeded.Records }) -Dictionary $Seeded.Dictionary

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        Test-Path -LiteralPath $Result.OutputZip | Should -BeTrue
        (Get-FileHash -LiteralPath (Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase))).Hash |
            Should -Be (Get-FileHash -LiteralPath (Join-Path $C.Gap ('Consumption_{0}.csv' -f $script:GapBase))).Hash

        $C2 = New-Case
        $RealId = '/subscriptions/{0}/resourceGroups/rg-app/providers/Microsoft.Compute/disks/disk-real' -f $script:DocsGuid
        New-Bundle -Dir $C2.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VMDisk = $Masked.Records }) -ConsumptionCsv ("$Csv`n{},Storage,m1,P10,eastus,disk,1,Hours,2026-01-01,2026-01-02,$RealId,eastus,,,") -Dictionary $Masked.Dictionary
        New-Bundle -Dir $C2.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = $Seeded.Records }) -Dictionary $Seeded.Dictionary
        { Merge-RecoveryData -GapBundlePath $C2.Gap -RecoveryBundlePath $C2.Recovery -OutputPath $C2.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*row 30001 of the consumption file*has a ResourceId that is not masked*'
        Test-Path -LiteralPath $C2.Output | Should -BeFalse
    }

    It 'carries a consumption file with quoted headers forward byte for byte' {
        $C = New-Case
        $Quoted = '"' + ($script:CsvHeader -replace ',', '","') + '"' + "`n" + '"{}","Compute","m1","MET","eastus","vm","1","Hours","2026-01-01","2026-01-02","/id","eastus","","",""'
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $Quoted
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $null = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue
        (Get-FileHash -LiteralPath (Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase))).Hash |
            Should -Be (Get-FileHash -LiteralPath (Join-Path $C.Gap ('Consumption_{0}.csv' -f $script:GapBase))).Hash
    }

    It 'writes a canonical header-only CSV when neither bundle has consumption' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $OutCsv = Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase)
        Test-Path -Path $OutCsv | Should -BeTrue
        (Get-Content -Path $OutCsv -Raw).Trim() | Should -Be $script:CsvHeader -Because 'a bundle with no consumption still gets a structurally complete header-only CSV'
    }
}

Describe 'Merge-RecoveryData metrics handling' {

    It 'carries gap metrics forward verbatim by default (MetricsSource = gap)' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = (New-MetricsJson 'gap-metric') }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Result.MetricsSource | Should -Be 'gap'
        $OutMetrics = Join-Path $C.Output ('Metrics_{0}__0.json' -f $script:GapBase)
        Test-Path -Path $OutMetrics | Should -BeTrue
        (Get-Content -Path $OutMetrics -Raw) | Should -Match 'gap-metric'
    }

    It 'replaces and rebases metrics to the gap base under -RecoverMetrics (MetricsSource = recovery)' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = (New-MetricsJson 'gap-metric') }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = (New-MetricsJson 'rec-metric') }

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverMetrics

        $Result.MetricsSource | Should -Be 'recovery'
        $Rebased = Join-Path $C.Output ('Metrics_{0}__0.json' -f $script:GapBase)
        Test-Path -Path $Rebased | Should -BeTrue -Because 'recovery metrics are rebased to the output bundle base'
        (Get-Content -Path $Rebased -Raw) | Should -Match 'rec-metric'
        Test-Path -Path (Join-Path $C.Output ('Metrics_{0}__0.json' -f $script:RecBase)) | Should -BeFalse -Because 'the recovery base name must not survive into the output'
    }

    It 'stops before writing anything when a <Which> metrics file it would zip <Case>' -ForEach @(
        @{ Which = 'gap'; Case = 'has Metrics that is not a list'; Text = '{"Metrics":"one"}' },
        @{ Which = 'gap'; Case = 'is a JSON list'; Text = '[{"Metrics":[]}]' },
        @{ Which = 'recovery'; Case = 'is not valid JSON'; Text = '{"Metrics":[' },
        @{ Which = 'recovery'; Case = 'has no Metrics list'; Text = '{"Items":[]}' }
    ) {
        $C = New-Case
        $GapMetrics = if ($Which -eq 'gap') { @{ '__0' = '{"Metrics":[]}'; '__1' = $Text } } else { @{ '__0' = '{"Metrics":[]}' } }
        $RecMetrics = if ($Which -eq 'recovery') { @{ '__0' = $Text } } else { @{ '__0' = '{"Metrics":[]}' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles $GapMetrics
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles $RecMetrics
        $Splat = @{ GapBundlePath = $C.Gap; RecoveryBundlePath = $C.Recovery; OutputPath = $C.Output; WarningAction = 'SilentlyContinue' }
        if ($Which -eq 'recovery') { $Splat.RecoverMetrics = $true }

        { Merge-RecoveryData @Splat } | Should -Throw -ExpectedMessage "*the $Which bundle's metrics file*cannot be used*Nothing was written*"
        Test-Path -LiteralPath $C.Output | Should -BeFalse -Because 'a metrics file downstream would drop stops the merge before any file is written'
    }

    It 'stops before writing anything when a <Which> metrics record <Case>' -ForEach @(
        @{ Which = 'gap'; Case = 'is text, not an object'; Field = $null; Value = 'gap-metric'; Expect = '*metric 2 is not a JSON object*' },
        @{ Which = 'recovery'; Case = 'is null'; Field = $null; Value = $null; Expect = '*metric 2 is not a JSON object*' },
        @{ Which = 'gap'; Case = 'has a null MetricValue'; Field = 'MetricValue'; Value = $null; Expect = '*metric 2 has a MetricValue that is not a number*' },
        @{ Which = 'recovery'; Case = 'has a MetricCount written as text'; Field = 'MetricCount'; Value = '24'; Expect = '*metric 2 has a MetricCount that is not a number*' },
        @{ Which = 'gap'; Case = 'has no MetricPercentile'; Field = 'MetricPercentile'; Value = 'remove'; Expect = '*metric 2 has a MetricPercentile that is not a number*' },
        @{ Which = 'recovery'; Case = 'has a MetricError written as text'; Field = 'MetricError'; Value = 'false'; Expect = '*metric 2 has a MetricError that is not true or false*' },
        @{ Which = 'gap'; Case = 'has text inside MetricSeries'; Field = 'MetricSeries'; Value = @(1, 'two'); Expect = '*metric 2 has a MetricSeries with a value that is not a number*' },
        @{ Which = 'recovery'; Case = 'has null inside MetricSeries'; Field = 'MetricSeries'; Value = @(1, $null); Expect = '*metric 2 has a MetricSeries with a value that is not a number*' },
        @{ Which = 'gap'; Case = 'has a MetricSeries that is text'; Field = 'MetricSeries'; Value = '1,2'; Expect = '*metric 2 has a MetricSeries that is not a number or a list of numbers*' }
    ) {
        $C = New-Case
        if ($null -eq $Field) { $BadRecord = $Value }
        else
        {
            $BadRecord = New-MetricRecord -Name 'bad'
            if ($Value -is [string] -and $Value -eq 'remove') { $BadRecord.Remove($Field) } else { $BadRecord[$Field] = $Value }
        }
        $Text = @{ Metrics = @((New-MetricRecord -Name 'good'), $BadRecord) } | ConvertTo-Json -Depth 5 -Compress
        $GapMetrics = if ($Which -eq 'gap') { @{ '__0' = (New-MetricsJson 'gap-ok'); '__1' = $Text } } else { @{ '__0' = (New-MetricsJson 'gap-ok') } }
        $RecMetrics = if ($Which -eq 'recovery') { @{ '__0' = $Text } } else { @{ '__0' = (New-MetricsJson 'rec-ok') } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles $GapMetrics
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles $RecMetrics
        $Splat = @{ GapBundlePath = $C.Gap; RecoveryBundlePath = $C.Recovery; OutputPath = $C.Output; WarningAction = 'SilentlyContinue' }
        if ($Which -eq 'recovery') { $Splat.RecoverMetrics = $true }

        $Message = $null
        try { $null = Merge-RecoveryData @Splat } catch { $Message = $_.Exception.Message }

        $Message | Should -BeLike "*the $Which bundle's metrics file*cannot be used*Downstream would drop every metric in the zip*Nothing was written*"
        $Message | Should -BeLike $Expect
        Test-Path -LiteralPath $C.Output | Should -BeFalse -Because 'a metrics file downstream would drop stops the merge before any file is written'
    }

    It 'carries metrics forward byte for byte when every record is shaped as the tool writes it (series <Case>)' -ForEach @(
        @{ Case = 'null'; Series = $null },
        @{ Case = 'one number'; Series = 0 },
        @{ Case = 'a list of numbers'; Series = @(1, 2.5, 30) },
        @{ Case = 'a list of one number'; Series = @(4) }
    ) {
        $C = New-Case
        $Record = New-MetricRecord -Series $Series
        $Record.MetricError = $true
        $Text = @{ Metrics = @($Record) } | ConvertTo-Json -Depth 5 -Compress
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = $Text }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $null = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        (Get-FileHash -LiteralPath (Join-Path $C.Output ('Metrics_{0}__0.json' -f $script:GapBase))).Hash |
            Should -Be (Get-FileHash -LiteralPath (Join-Path $C.Gap ('Metrics_{0}__0.json' -f $script:GapBase))).Hash
    }

    It 'throws when -RecoverMetrics is set but the recovery bundle has no metrics' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":[]}' }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverMetrics } |
            Should -Throw -ExpectedMessage '*has no Metrics_*'
        Test-Path -LiteralPath $C.Output | Should -BeFalse -Because 'nothing is written before the stop'
    }
}

Describe 'Merge-RecoveryData masking guards (stop before anything is written)' {

    It 'stops when the recovery dictionary shares no ResourceIdMap token with the gap (unseeded recovery)' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_gapTok' = '/id/gap' } }
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_recTok' = '/id/rec' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $RecDict

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*share no ResourceIdMap token*-ObfuscationDictionary*'
        Test-Path -Path $C.Output | Should -BeFalse -Because 'the stop comes before the output folder is made, so nothing is left for the next run to trip on'
    }

    It 'compares two ResourceIdMaps of 20000 ids each in a few seconds' {
        $C = New-Case
        $GapMap = [ordered]@{}; $RecMap = [ordered]@{}
        for ($i = 0; $i -lt 20000; $i++) { $GapMap["prod_gap$i"] = "/id/gap$i"; $RecMap["prod_rec$i"] = "/id/rec$i" }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary ([ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = $GapMap })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary ([ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = $RecMap })

        # No id is shared, so every recovery id is looked up before the stop.
        $Watch = [System.Diagnostics.Stopwatch]::StartNew()
        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*share no ResourceIdMap token*'
        $Watch.Stop()
        $Watch.Elapsed.TotalSeconds | Should -BeLessThan 5 -Because 'the shared-token check is a set lookup, not a list scan per id'
    }

    It 'stops even under -ErrorAction SilentlyContinue when no ResourceIdMap token is shared' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_gapTok' = '/id/gap' } }
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_recTok' = '/id/rec' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $RecDict

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -ErrorAction SilentlyContinue -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*share no ResourceIdMap token*'
        Test-Path -Path $C.Output | Should -BeFalse
    }

    It 'stops when only the gap bundle has a dictionary, naming the recovery bundle' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_gapTok' = '/id/gap' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage ('*recovery bundle ''{0}'' has no ObfuscationDictionary*-Obfuscate -ObfuscationDictionary*' -f $C.Recovery)
        Test-Path -Path $C.Output | Should -BeFalse -Because 'no file may be written or zipped when real values could ship in a masked bundle'
    }

    It 'stops when only the recovery bundle has a dictionary, naming the gap bundle' {
        $C = New-Case
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_recTok' = '/id/rec' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $RecDict

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage ('*gap bundle ''{0}'' has no ObfuscationDictionary*-Obfuscate*into a new folder*' -f $C.Gap)
        Test-Path -Path $C.Output | Should -BeFalse
    }

    It 'advises, when only the recovery has a dictionary, a plain recovery re-run first and a gap re-run seeded with the recovery dictionary second' {
        $C = New-Case
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_recTok' = '/id/rec' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $RecDict
        $RecDictPath = (Get-ChildItem -LiteralPath $C.Recovery -Filter 'ObfuscationDictionary_*.json').FullName

        $Message = $null
        try { $null = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue }
        catch { $Message = $_.Exception.Message }

        $Message | Should -Not -BeNullOrEmpty
        $Message | Should -BeLike '*re-run the recovery without -Obfuscate into a new folder*'
        $Message | Should -BeLike ("*re-run the gap with -Obfuscate -ObfuscationDictionary '{0}'*" -f $RecDictPath)
        $Message.IndexOf('re-run the recovery without -Obfuscate') | Should -BeLessThan $Message.IndexOf('re-run the gap with -Obfuscate')
        $Message | Should -Not -BeLike '*re-run the gap bundle with -Obfuscate,*' -Because 'a gap re-run with -Obfuscate alone mints new tokens and leads into the shared-token stop'
    }

    It 'merges on the next run once the recovery is re-run without -Obfuscate into a new folder' {
        $C = New-Case
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_recTok' = '/id/rec' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $RecDict
        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } | Should -Throw

        # A re-run into the same folder would leave the old dictionary there and stop again; a new folder is the way out.
        $NewRecovery = $C.Recovery + '_rerun'
        New-Bundle -Dir $NewRecovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $NewRecovery -OutputPath $C.Output -WarningAction SilentlyContinue

        @($Result.Warnings).Count | Should -Be 0
        $Result.OutputDictionary | Should -BeNullOrEmpty
        Test-Path -Path $Result.OutputZip | Should -BeTrue
    }

    It 'does not stop or warn on token overlap when the gap ResourceIdMap is empty (<Case>)' -ForEach @(
        @{ Case = 'empty map'; GapIdMap = [ordered]@{} },
        @{ Case = 'no map'; GapIdMap = $null }
    ) {
        $C = New-Case
        # A masked run over a subscription with no resources writes an empty ResourceIdMap;
        # a seeded recovery that then finds resources shares no token with it, and no re-run can change that.
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; SubscriptionMap = [ordered]@{ 'prod_subtok' = 'Gap Sub' } }
        if ($null -ne $GapIdMap) { $GapDict['ResourceIdMap'] = $GapIdMap }
        $RecMasked = Get-MaskedBundleData -Count 1
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @() }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = $RecMasked.Records }) -Dictionary $RecMasked.Dictionary

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Not -Match 'share no ResourceIdMap token'
        Test-Path -Path $Result.OutputZip | Should -BeTrue
    }

    It 'stops before writing anything when the <Which> dictionary <Case>' -ForEach @(
        @{ Which = 'gap'; Case = 'is not valid JSON'; Text = '{ "ResourceIdMap": { "prod_shared": ' },
        @{ Which = 'recovery'; Case = 'is not valid JSON'; Text = '{ "ResourceIdMap": { "prod_shared": ' },
        @{ Which = 'gap'; Case = 'is empty'; Text = '' },
        @{ Which = 'recovery'; Case = 'is a JSON list, not an object'; Text = '[{ "ResourceIdMap": { "prod_shared": "/id/shared" } }]' },
        @{ Which = 'gap'; Case = 'has a map that is not an object'; Text = '{ "GeneratedAt": "2026-01-01 00:00:00", "ResourceIdMap": "prod_shared" }' },
        @{ Which = 'recovery'; Case = 'has a map value that is an object'; Text = '{ "ResourceIdMap": { "prod_shared": { "x": 1 } } }' }
    ) {
        $C = New-Case
        $Good = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_shared' = '/id/shared' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $Good
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $Good
        $Dir = if ($Which -eq 'gap') { $C.Gap } else { $C.Recovery }
        $DictFile = (Get-ChildItem -LiteralPath $Dir -Filter 'ObfuscationDictionary_*.json').FullName
        Set-Content -LiteralPath $DictFile -Value $Text -NoNewline -Encoding utf8

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage ("*the $Which bundle's dictionary*cannot be read*Nothing was written*")
        Test-Path -LiteralPath $C.Output | Should -BeFalse -Because 'a dictionary that cannot be read stops the merge before any file is written'
    }

    It 'stops when a bundle whose ResourceIdMap is empty gives the merge resources (<Case>)' -ForEach @(
        @{ Case = 'plain recovery inventory next to an old empty dictionary'; Empty = 'recovery'; Give = 'inventory' },
        @{ Case = 'plain recovery consumption next to an old empty dictionary'; Empty = 'recovery'; Give = 'consumption' },
        @{ Case = 'plain recovery metrics next to an old empty dictionary'; Empty = 'recovery'; Give = 'metrics' },
        @{ Case = 'plain gap inventory next to an old empty dictionary'; Empty = 'gap'; Give = 'inventory' },
        @{ Case = 'both maps empty'; Empty = 'both'; Give = 'inventory' }
    ) {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 3
        $EmptyDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{} }
        $RealId = '/subscriptions/{0}/resourceGroups/rg-app/providers/Microsoft.Compute/disks/disk-real' -f $script:DocsGuid
        $PlainCsv = "$script:CsvHeader`n{},Storage,m1,P10,eastus,disk,1,Hours,2026-01-01,2026-01-02,$RealId,eastus,,,"

        # The gap: masked (contract-shaped ids and a dictionary holding them), or plain next to an empty dictionary.
        if ($Empty -in 'gap', 'both')
        {
            New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VMDisk = @((New-Record 'disk-real')) }) -Dictionary $EmptyDict
        }
        else
        {
            New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VMDisk = $Masked.Records }) -Dictionary $Masked.Dictionary
        }
        # The recovery: what it gives depends on the case; it is masked when only the gap map is empty.
        $RecInventory = [ordered]@{ Version = '3.2.3' }
        $RecSplat = @{ Dir = $C.Recovery; Base = $script:RecBase }
        if ($Empty -eq 'gap')
        {
            $RecMasked = Get-MaskedBundleData -Count 3
            $RecInventory['AppServices'] = $RecMasked.Records
            $RecSplat.Dictionary = $RecMasked.Dictionary
        }
        else
        {
            $RecSplat.Dictionary = $EmptyDict
            if ($Give -eq 'inventory') { $RecInventory['AppServices'] = @((New-Record 'app-real')) }
            if ($Give -eq 'consumption') { $RecSplat.ConsumptionCsv = $PlainCsv }
            if ($Give -eq 'metrics') { $RecSplat.MetricsFiles = @{ '__0' = (New-MetricsJson -Name 'disk-real' -Id $RealId) } }
        }
        New-Bundle @RecSplat -Inventory $RecInventory
        $Splat = @{ GapBundlePath = $C.Gap; RecoveryBundlePath = $C.Recovery; OutputPath = $C.Output; WarningAction = 'SilentlyContinue' }
        if ($Give -eq 'consumption') { $Splat.RecoverConsumption = $true }
        if ($Give -eq 'metrics') { $Splat.RecoverMetrics = $true }
        $Label = if ($Empty -eq 'recovery') { 'recovery' } else { 'gap' }

        { Merge-RecoveryData @Splat } | Should -Throw -ExpectedMessage "*the $Label bundle's dictionary*has an empty ResourceIdMap*real names and ids would ship inside a masked bundle*Nothing was written*"
        Test-Path -LiteralPath $C.Output | Should -BeFalse
    }

    It 'stops when a bundle beside a dictionary that is not empty gives the merge plain data (<Case>)' -ForEach @(
        @{ Case = 'plain recovery inventory next to a seeded dictionary'; Plain = 'recovery'; Give = 'inventory' },
        @{ Case = 'one plain record among masked recovery records'; Plain = 'recovery'; Give = 'mixed' },
        @{ Case = 'plain gap inventory next to a dictionary'; Plain = 'gap'; Give = 'inventory' },
        @{ Case = 'plain consumption rows from the masked recovery'; Plain = 'recovery'; Give = 'consumption' },
        @{ Case = 'plain consumption rows carried from the masked gap'; Plain = 'gap'; Give = 'consumption' },
        @{ Case = 'plain metrics from the masked recovery'; Plain = 'recovery'; Give = 'metrics' }
    ) {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 3
        $Seeded = Get-MaskedBundleData -Count 2 -Seed $Masked
        $RealId = '/subscriptions/{0}/resourceGroups/rg-app/providers/Microsoft.Compute/disks/disk-real' -f $script:DocsGuid
        $PlainCsv = "$script:CsvHeader`n{},Storage,m1,P10,eastus,disk,1,Hours,2026-01-01,2026-01-02,$RealId,eastus,,,"
        $GapInventory = [ordered]@{ Version = '3.2.3'; VMDisk = $Masked.Records }
        $RecInventory = [ordered]@{ Version = '3.2.3'; AppServices = $Seeded.Records }
        $GapSplat = @{ Dir = $C.Gap; Base = $script:GapBase; Dictionary = $Masked.Dictionary }
        $RecSplat = @{ Dir = $C.Recovery; Base = $script:RecBase; Dictionary = $Seeded.Dictionary }
        $Splat = @{ GapBundlePath = $C.Gap; RecoveryBundlePath = $C.Recovery; OutputPath = $C.Output; WarningAction = 'SilentlyContinue' }
        switch ($Give)
        {
            'inventory' { if ($Plain -eq 'gap') { $GapInventory['VirtualMachines'] = @((New-Record 'vm-real')) } else { $RecInventory['AppServices'] = @((New-Record 'app-real')) } }
            'mixed' { $RecInventory['AppServices'] = @($Seeded.Records) + @((New-Record 'app-real')) }
            'consumption'
            {
                if ($Plain -eq 'gap') { $GapSplat.ConsumptionCsv = $PlainCsv } else { $RecSplat.ConsumptionCsv = $PlainCsv; $Splat.RecoverConsumption = $true }
            }
            'metrics'
            {
                $RecSplat.MetricsFiles = @{ '__0' = (@{ Metrics = @((New-MetricRecord -Id $RealId)) } | ConvertTo-Json -Depth 5 -Compress) }
                $Splat.RecoverMetrics = $true
            }
        }
        New-Bundle @GapSplat -Inventory $GapInventory
        New-Bundle @RecSplat -Inventory $RecInventory

        $Message = $null
        try { $null = Merge-RecoveryData @Splat } catch { $Message = $_.Exception.Message }

        $Message | Should -BeLike "*masked merge, but in the $Plain bundle*not masked*real names and ids would ship inside a masked bundle*Nothing was written*"
        $Message | Should -Not -BeLike '*disk-real*' -Because 'the error names the file and record, never the real value'
        $Message | Should -Not -BeLike '*-real*'
        Test-Path -LiteralPath $C.Output | Should -BeFalse -Because 'the stop comes before anything is written'
    }

    It 'stops when a masked id keeps a real parent name in its <Where> (<Case>)' -ForEach @(
        @{ Where = 'consumption ResourceId'; Case = 'a SQL database under a real server'; Path = 'microsoft.sql/servers/sql-real/databases/prod_{0}' },
        @{ Where = 'consumption ResourceId'; Case = 'a scale set VM under a real scale set'; Path = 'microsoft.compute/virtualmachinescalesets/vmss-real/virtualmachines/prod_{0}' },
        @{ Where = 'inventory ID'; Case = 'an elastic pool under a real server'; Path = 'microsoft.sql/servers/sql-real/elasticpools/prod_{0}' },
        @{ Where = 'metric ID'; Case = 'a resource under a real parent behind a nested provider'; Path = 'microsoft.compute/virtualmachines/vm-real/providers/microsoft.insights/diagnosticsettings/prod_{0}' }
    ) {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 3
        $Seeded = Get-MaskedBundleData -Count 2 -Seed $Masked
        $NestedId = '/subscriptions/{0}/resourcegroups/{1}/providers/{2}' -f $Masked.Sub, $Masked.Rg, ($Path -f [guid]::NewGuid())
        $GapSplat = @{ Dir = $C.Gap; Base = $script:GapBase; Dictionary = $Masked.Dictionary; Inventory = [ordered]@{ Version = '3.2.3'; VMDisk = $Masked.Records } }
        $RecRecords = @($Seeded.Records)
        $Splat = @{ GapBundlePath = $C.Gap; RecoveryBundlePath = $C.Recovery; OutputPath = $C.Output; WarningAction = 'SilentlyContinue' }
        $RecSplat = @{ Dir = $C.Recovery; Base = $script:RecBase; Dictionary = $Seeded.Dictionary }
        switch ($Where)
        {
            'consumption ResourceId' { $GapSplat.ConsumptionCsv = "$script:CsvHeader`n{},SQL Database,m1,vCore,eastus,db,1,Hours,2026-01-01,2026-01-02,$NestedId,eastus,,," }
            'inventory ID' { $RecRecords += [ordered]@{ Name = ('prod_' + [guid]::NewGuid()); Subscription = $Masked.Sub; ResourceGroup = $Masked.Rg; ID = $NestedId } }
            'metric ID'
            {
                $RecSplat.MetricsFiles = @{ '__0' = (@{ Metrics = @((New-MetricRecord -Id $NestedId)) } | ConvertTo-Json -Depth 5 -Compress) }
                $Splat.RecoverMetrics = $true
            }
        }
        New-Bundle @GapSplat
        New-Bundle @RecSplat -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = $RecRecords })

        $Message = $null
        try { $null = Merge-RecoveryData @Splat } catch { $Message = $_.Exception.Message }

        $Message | Should -BeLike '*masked merge, but in the * bundle*not masked*Nothing was written*'
        $Message | Should -Not -BeLike '*-real*' -Because 'the error names the file and record, never the value'
        Test-Path -LiteralPath $C.Output | Should -BeFalse
    }

    It 'merges masked nested ids whose every name is a token, and the flat forms this tool writes today' {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 3
        $Seeded = Get-MaskedBundleData -Count 2 -Seed $Masked
        $G = { [guid]::NewGuid().ToString() }
        $Prefix = '/subscriptions/{0}/resourcegroups/{1}/providers/' -f $Masked.Sub, $Masked.Rg
        $Rows = @(
            ($Prefix + ('microsoft.sql/servers/prod_{0}/databases/nonprod_{1}' -f (& $G), (& $G))),
            ($Prefix + ('microsoft.sql/servers/prod_{0}/elasticpools/prod_{1}' -f (& $G), (& $G))),
            ($Prefix + ('microsoft.compute/virtualmachines/prod_{0}/providers/microsoft.insights/diagnosticsettings/prod_{1}' -f (& $G), (& $G))),
            ('prod_{0}' -f (& $G)),
            ('nonprod_{0}' -f (& $G)),
            'obfuscated',
            ('obfuscated_{0}' -f (& $G))
        ) | ForEach-Object { "{},SQL Database,m1,vCore,eastus,db,1,Hours,2026-01-01,2026-01-02,$_,eastus,,," }
        $Csv = (@($script:CsvHeader) + $Rows) -join "`n"
        $RecRecords = @($Seeded.Records) + @([ordered]@{ Name = ('prod_' + (& $G)); ID = ($Prefix + ('microsoft.sql/servers/prod_{0}/databases/prod_{1}' -f (& $G), (& $G))) })
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VMDisk = $Masked.Records }) -ConsumptionCsv $Csv -Dictionary $Masked.Dictionary
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = $RecRecords }) -Dictionary $Seeded.Dictionary

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        Test-Path -LiteralPath $Result.OutputZip | Should -BeTrue
    }

    It 'merges a masked bundle whose ids take every shape the masked run writes' {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 3
        $Seeded = Get-MaskedBundleData -Count 2 -Seed $Masked
        $G = { [guid]::NewGuid().ToString() }
        # Shapes the masked run writes: an inventory id, a consumption-only path
        # with sub_/rg_mc_ hinted tokens and a child name, a '$system' name, a
        # flat token, 'obfuscated', and an empty ResourceId that downstream drops.
        $Rows = @(
            $Masked.Records[0].ID,
            ('/subscriptions/prod_sub_{0}/resourcegroups/nonprod_rg_mc_{1}/providers/microsoft.compute/virtualmachinescalesets/prod_vmss_{2}/virtualmachines/prod_{3}' -f (& $G), (& $G), (& $G), (& $G)),
            ('/subscriptions/{0}/resourcegroups/{1}/providers/microsoft.sql/servers/prod_{2}/databases/$system' -f $Masked.Sub, $Masked.Rg, (& $G)),
            ('prod_{0}' -f (& $G)),
            'obfuscated',
            ''
        ) | ForEach-Object { "{},Storage,m1,P10,eastus,disk,1,Hours,2026-01-01,2026-01-02,$_,eastus,,," }
        $Csv = (@($script:CsvHeader) + $Rows) -join "`n"
        $Metrics = @{ Metrics = @((New-MetricRecord -Id $Seeded.Records[0].ID), (New-MetricRecord -Id ('obfuscated_' + (& $G)))) } | ConvertTo-Json -Depth 5 -Compress
        $RecRecords = @($Seeded.Records) + @([ordered]@{ Name = 'obfuscated_x'; ID = ('obfuscated_' + (& $G)) })
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VMDisk = $Masked.Records }) -ConsumptionCsv $Csv -Dictionary $Masked.Dictionary
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = $RecRecords }) -MetricsFiles @{ '__0' = $Metrics } -Dictionary $Seeded.Dictionary

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverMetrics -WarningAction SilentlyContinue

        Test-Path -LiteralPath $Result.OutputZip | Should -BeTrue
        (Get-FileHash -LiteralPath (Join-Path $C.Output ('Consumption_{0}.csv' -f $script:GapBase))).Hash |
            Should -Be (Get-FileHash -LiteralPath (Join-Path $C.Gap ('Consumption_{0}.csv' -f $script:GapBase))).Hash
    }

    It 'merges a masked recovery into a masked gap whose ResourceIdMap is empty and that gives no resource' {
        $C = New-Case
        $RecMasked = Get-MaskedBundleData -Count 3
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{} }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VMDisk = @() }) -ConsumptionCsv $script:CsvHeader -MetricsFiles @{ '__0' = '{"Metrics":[]}' } -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VMDisk = $RecMasked.Records }) -Dictionary $RecMasked.Dictionary

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        Test-Path -LiteralPath $Result.OutputZip | Should -BeTrue
        $Merged = Get-Content -LiteralPath $Result.OutputInventory -Raw | ConvertFrom-Json
        @($Merged.VMDisk.ID) | Should -Be @($RecMasked.Records | ForEach-Object { $_.ID })
    }

    It 'merges a masked gap with a recovery whose ResourceIdMap is empty and that gives no resource' {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 3
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{} }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VMDisk = $Masked.Records }) -Dictionary $Masked.Dictionary
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @() }) -Dictionary $RecDict

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        Test-Path -LiteralPath $Result.OutputZip | Should -BeTrue
    }

    It 'leaves an existing output folder untouched when it stops' {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 3
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = $Masked.Records }) -Dictionary $Masked.Dictionary
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        New-Item -ItemType Directory -Path $C.Output -Force | Out-Null

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*has no ObfuscationDictionary*'
        @(Get-ChildItem -Path $C.Output -Force).Count | Should -Be 0 -Because 'no inventory, csv, metrics, html, dictionary or zip is written before the stop'
    }

    It 'merges cleanly on the next run once the recovery is re-run seeded with the gap dictionary' {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 3
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = $Masked.Records }) -Dictionary $Masked.Dictionary
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } | Should -Throw

        # The way out: the seeded recovery re-run writes masked records and its dictionary, and the same merge command now passes.
        $Seeded = Get-MaskedBundleData -Count 2 -Seed $Masked
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = $Seeded.Records }) -Dictionary $Seeded.Dictionary
        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        @($Result.Warnings).Count | Should -Be 0
        Test-Path -Path $Result.OutputZip | Should -BeTrue
    }
}

Describe 'Merge-RecoveryData guards (advisory warnings)' {

    It 'merges with no stop and no token warning when the dictionaries share ResourceIdMap tokens (seeded recovery)' {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 3
        $Seeded = Get-MaskedBundleData -Count 2 -Seed $Masked
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = $Masked.Records }) -Dictionary $Masked.Dictionary
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = $Seeded.Records }) -Dictionary $Seeded.Dictionary

        { $script:SeededResult = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Not -Throw -Because 'a recovery seeded with the gap dictionary shares its tokens, so the shared-token check passes'
        $Result = $script:SeededResult
        Test-Path -LiteralPath $Result.OutputZip | Should -BeTrue
        ($Result.Warnings -join "`n") | Should -Not -Match 'ResourceIdMap'
    }

    It 'warns when a replaced inventory key has fewer records than the gap held' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01'), (New-Record 'vm02')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm-only-one')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'REPLACED with FEWER records'
    }

    It 'warns when -RecoverConsumption replaces with fewer rows than the gap CSV' {
        $C = New-Case
        $GapCsv = "$script:CsvHeader`n{},Compute,m1,GAP1,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,`n{},Compute,m2,GAP2,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        $RecCsv = "$script:CsvHeader`n{},Compute,m1,REC1,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $GapCsv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $RecCsv

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'FEWER rows than the gap CSV'
    }

    It 'warns when -RecoverConsumption billing window differs from the gap CSV' {
        $C = New-Case
        $GapCsv = "$script:CsvHeader`n{},Compute,m1,GAP1,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        $RecCsv = "$script:CsvHeader`n{},Compute,m1,REC1,eastus,vm,1,Hours,2026-02-01,2026-02-02,/id,eastus,,,"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $GapCsv
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $RecCsv

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'billing window differs'
    }

    It 'emits the HTML-does-not-render-metrics advisory under -RecoverMetrics' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = (New-MetricsJson 'gap-metric') }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = (New-MetricsJson 'rec-metric') }

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverMetrics -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'does not render metrics'
    }

    It 'HARD FAILS when the gap dictionary does not match its inventory (wrong dictionary)' {
        $C = New-Case
        $GapInv = [ordered]@{
            Version         = '3.2.3'
            VirtualMachines = @(
                [ordered]@{ Name = 'vm01'; ID = 'prod_11111111-1111-1111-1111-111111111111' },
                [ordered]@{ Name = 'vm02'; ID = 'prod_22222222-2222-2222-2222-222222222222' },
                [ordered]@{ Name = 'vm03'; ID = 'prod_33333333-3333-3333-3333-333333333333' }
            )
        }
        # Dictionary from a DIFFERENT run: none of the gap inventory's tokens appear.
        $WrongDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_99999999-9999-9999-9999-999999999999' = '/id/x' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory $GapInv -Dictionary $WrongDict
        # The recovery carries the same dictionary (seeded from it), so only the gap's wrong dictionary is at fault.
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $WrongDict

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*does NOT match its inventory*'
    }

    It 'HARD FAILS when the recovery dictionary does not match its inventory' {
        $C = New-Case
        $RecInv = [ordered]@{
            Version         = '3.2.3'
            VirtualMachines = @(
                [ordered]@{ Name = 'vm01'; ID = 'prod_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' },
                [ordered]@{ Name = 'vm02'; ID = 'prod_bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' },
                [ordered]@{ Name = 'vm03'; ID = 'prod_cccccccc-cccc-cccc-cccc-cccccccccccc' }
            )
        }
        $WrongDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_dddddddd-dddd-dddd-dddd-dddddddddddd' = '/id/y' } }
        # The gap carries the same dictionary, so only the recovery's wrong dictionary is at fault.
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $WrongDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory $RecInv -Dictionary $WrongDict

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*recovery bundle*does NOT match its inventory*'
    }

    It 'passes when the dictionary contains all of its inventory tokens (correct dictionary)' {
        $C = New-Case
        $GapInv = [ordered]@{
            Version         = '3.2.3'
            VirtualMachines = @(
                [ordered]@{ Name = 'vm01'; ID = 'prod_11111111-1111-1111-1111-111111111111' },
                [ordered]@{ Name = 'vm02'; ID = 'prod_22222222-2222-2222-2222-222222222222' },
                [ordered]@{ Name = 'vm03'; ID = 'prod_33333333-3333-3333-3333-333333333333' }
            )
        }
        $GoodDict = [ordered]@{
            GeneratedAt   = '2026-01-01 00:00:00'
            ResourceIdMap = [ordered]@{
                'prod_11111111-1111-1111-1111-111111111111' = '/id/1'
                'prod_22222222-2222-2222-2222-222222222222' = '/id/2'
                'prod_33333333-3333-3333-3333-333333333333' = '/id/3'
            }
        }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory $GapInv -Dictionary $GoodDict
        # The recovery re-collected the same machines, seeded with the same dictionary.
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory $GapInv -Dictionary $GoodDict

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }

    It 'warns (does not fail) on partial dictionary coverage below 50 percent' {
        $C = New-Case
        $GapInv = [ordered]@{
            Version         = '3.2.3'
            VirtualMachines = @(
                [ordered]@{ Name = 'vm01'; ID = 'prod_11111111-1111-1111-1111-111111111111' },
                [ordered]@{ Name = 'vm02'; ID = 'prod_22222222-2222-2222-2222-222222222222' },
                [ordered]@{ Name = 'vm03'; ID = 'prod_33333333-3333-3333-3333-333333333333' },
                [ordered]@{ Name = 'vm04'; ID = 'prod_44444444-4444-4444-4444-444444444444' }
            )
        }
        # Only 1 of 4 tokens present -> 25% coverage -> warn, not throw.
        $PartialDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_11111111-1111-1111-1111-111111111111' = '/id/1' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory $GapInv -Dictionary $PartialDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory $GapInv -Dictionary $PartialDict

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'covers only'
    }

    It 'reports no warnings for a clean, dictionary-compatible, same-window merge' {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 3
        $Csv = "$script:CsvHeader`n{},Storage,m1,MET,eastus,disk,1,Hours,2026-01-01,2026-01-02,$($Masked.Records[0].ID),eastus,,,"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VMDisk = $Masked.Records }) -ConsumptionCsv $Csv -Dictionary $Masked.Dictionary
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VMDisk = $Masked.Records }) -ConsumptionCsv $Csv -Dictionary $Masked.Dictionary

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption -WarningAction SilentlyContinue

        @($Result.Warnings).Count | Should -Be 0
    }
}

Describe 'Merge-RecoveryData dictionary merge and packaging' {

    It 'merges the obfuscation dictionaries as a union and returns its path' {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 1
        $GapDict = $Masked.Dictionary
        $GapDict.ResourceIdMap['prod_tokA'] = '/id/a'
        $GapDict['SubscriptionNameMap'] = [ordered]@{ 'prod_subtok' = 'Gap Sub' }
        # Seeded recovery: it shares the gap's tokens and adds its own.
        $Seeded = Get-MaskedBundleData -Count 1 -Seed $Masked
        $RecDict = $Seeded.Dictionary
        $RecDict.ResourceIdMap['prod_tokB'] = '/id/b'
        $RecDict['TagMap'] = [ordered]@{ 'prod_tagtok' = 'payments' }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = $Masked.Records }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = $Seeded.Records }) -Dictionary $RecDict

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Result.OutputDictionary | Should -Not -BeNullOrEmpty
        Test-Path -Path $Result.OutputDictionary | Should -BeTrue
        $Dict = Get-Content -Path $Result.OutputDictionary -Raw | ConvertFrom-Json
        $Dict.ResourceIdMap.PSObject.Properties.Name | Should -Contain 'prod_tokA' -Because 'gap entries are retained'
        $Dict.ResourceIdMap.PSObject.Properties.Name | Should -Contain 'prod_tokB' -Because 'recovery-only entries are added (union)'
        $Dict.PSObject.Properties.Name | Should -Contain 'TagMap' -Because 'a map present only in the recovery dictionary is added'
    }

    It 'never includes the obfuscation dictionary in the output zip' {
        $C = New-Case
        $Masked = Get-MaskedBundleData -Count 2
        $Seeded = Get-MaskedBundleData -Count 1 -Seed $Masked
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = $Masked.Records }) -Dictionary $Masked.Dictionary
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = $Seeded.Records }) -Dictionary $Seeded.Dictionary

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Entries = Get-ZipEntryNames -ZipPath $Result.OutputZip
        ($Entries | Where-Object { $_ -like 'ObfuscationDictionary_*' }) | Should -BeNullOrEmpty -Because 'the dictionary maps back to real values and must never ship'
        ($Entries | Where-Object { $_ -like 'Inventory_*.json' }) | Should -Not -BeNullOrEmpty
        ($Entries | Where-Object { $_ -like '*.html' }) | Should -Not -BeNullOrEmpty
    }

    It 'does not mutate the source gap or recovery bundles' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $GapInvPath = Join-Path $C.Gap ('Inventory_{0}.json' -f $script:GapBase)
        $RecInvPath = Join-Path $C.Recovery ('Inventory_{0}.json' -f $script:RecBase)
        $GapBefore = Get-Content -Path $GapInvPath -Raw
        $RecBefore = Get-Content -Path $RecInvPath -Raw

        $null = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        (Get-Content -Path $GapInvPath -Raw) | Should -Be $GapBefore -Because 'the merge writes to OutputPath only, never back into the gap bundle'
        (Get-Content -Path $RecInvPath -Raw) | Should -Be $RecBefore -Because 'the recovery bundle is read-only input'
    }
}

Describe 'Merge-RecoveryData with no report generator next to it' {
    It 'stops before writing anything when Extension/Summary.ps1 is missing' {
        $Root = Join-Path $script:TmpRoot ('nosummary_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $Fn = Join-Path $Root 'Functions'
        New-Item -ItemType Directory -Path $Fn -Force | Out-Null
        foreach ($F in 'RecoveryMerge.Functions.ps1', 'InventoryJson.Functions.ps1') { Copy-Item -LiteralPath (Join-Path (Split-Path $script:FnFile -Parent) $F) -Destination $Fn }
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) })
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        $Pwsh = (Get-Process -Id $PID).Path
        $Cmd = ". '{0}'; try {{ Merge-RecoveryData -GapBundlePath '{1}' -RecoveryBundlePath '{2}' -OutputPath '{3}' -WarningAction SilentlyContinue | Out-Null; 'no-stop' }} catch {{ 'STOP ' + `$_.Exception.Message }}" -f (Join-Path $Fn 'RecoveryMerge.Functions.ps1'), $C.Gap, $C.Recovery, $C.Output
        $Out = (& $Pwsh -NoProfile -NonInteractive -Command $Cmd 2>&1 | Out-String)
        $Out | Should -Match 'STOP Merge-RecoveryData: report generator not found'
        Test-Path -LiteralPath $C.Output | Should -BeFalse -Because 'nothing is written before the stop'
    }
}

