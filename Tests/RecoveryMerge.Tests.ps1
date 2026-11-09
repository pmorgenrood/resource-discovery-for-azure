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
            New-Bundle -Dir $Tmp -Base $Pair[1] -Inventory ([ordered]@{ Version = '3.2.3'; $Key = @((New-Record $Pair[2])) }) -ConsumptionCsv (& $Csv $Pair[3]) -MetricsFiles @{ '__0' = ('{"Metrics":["' + $Pair[3] + '"]}') }
            $null = New-Item -ItemType Directory -Path $Pair[0]
            Get-ChildItem -LiteralPath $Tmp -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Pair[0] $_.Name) }
        }
        New-Bundle -Dir $GapDecoy -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm-decoy')) }) -ConsumptionCsv (& $Csv 'GAP-DECOY') -MetricsFiles @{ '__0' = '{"Metrics":["GAP-DECOY"]}' }
        New-Bundle -Dir $RecDecoy -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app-decoy')) }) -ConsumptionCsv (& $Csv 'REC-DECOY') -MetricsFiles @{ '__0' = '{"Metrics":["REC-DECOY"]}' }
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
        @{ Which = 'gap'; Missing = 'any header'; Header = '' }
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
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":["gap-metric"]}' }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output

        $Result.MetricsSource | Should -Be 'gap'
        $OutMetrics = Join-Path $C.Output ('Metrics_{0}__0.json' -f $script:GapBase)
        Test-Path -Path $OutMetrics | Should -BeTrue
        (Get-Content -Path $OutMetrics -Raw) | Should -Match 'gap-metric'
    }

    It 'replaces and rebases metrics to the gap base under -RecoverMetrics (MetricsSource = recovery)' {
        $C = New-Case
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":["gap-metric"]}' }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":["rec-metric"]}' }

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
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_recNew' = '/id/new' }; SubscriptionMap = [ordered]@{ 'prod_subtok' = 'Gap Sub' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @() }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $RecDict

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

    It 'leaves an existing output folder untouched when it stops' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_gapTok' = '/id/gap' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        New-Item -ItemType Directory -Path $C.Output -Force | Out-Null

        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*has no ObfuscationDictionary*'
        @(Get-ChildItem -Path $C.Output -Force).Count | Should -Be 0 -Because 'no inventory, csv, metrics, html, dictionary or zip is written before the stop'
    }

    It 'merges cleanly on the next run once the recovery is re-run seeded with the gap dictionary' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_gapTok' = '/id/gap' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) })
        { Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue } | Should -Throw

        # The way out: the seeded recovery re-run writes its dictionary, and the same merge command now passes.
        $SeededDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_gapTok' = '/id/gap'; 'prod_recNew' = '/id/new' } }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $SeededDict
        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        @($Result.Warnings).Count | Should -Be 0
        Test-Path -Path $Result.OutputZip | Should -BeTrue
    }
}

Describe 'Merge-RecoveryData guards (advisory warnings)' {

    It 'does NOT warn about token overlap when the dictionaries share ResourceIdMap tokens (seeded recovery)' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_shared' = '/id/shared' } }
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_shared' = '/id/shared'; 'prod_recNew' = '/id/new' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $RecDict

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Not -Match 'share NO ResourceIdMap tokens'
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
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":["gap-metric"]}' }
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -MetricsFiles @{ '__0' = '{"Metrics":["rec-metric"]}' }

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
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $GoodDict

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
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $PartialDict

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -WarningAction SilentlyContinue

        ($Result.Warnings -join "`n") | Should -Match 'covers only'
    }

    It 'reports no warnings for a clean, dictionary-compatible, same-window merge' {
        $C = New-Case
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_shared' = '/id/shared' } }
        $RecDict = [ordered]@{ GeneratedAt = '2026-01-02 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_shared' = '/id/shared' } }
        $Csv = "$script:CsvHeader`n{},Compute,m1,MET,eastus,vm,1,Hours,2026-01-01,2026-01-02,/id,eastus,,,"
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $Csv -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -ConsumptionCsv $Csv -Dictionary $RecDict

        $Result = Merge-RecoveryData -GapBundlePath $C.Gap -RecoveryBundlePath $C.Recovery -OutputPath $C.Output -RecoverConsumption -WarningAction SilentlyContinue

        @($Result.Warnings).Count | Should -Be 0
    }
}

Describe 'Merge-RecoveryData dictionary merge and packaging' {

    It 'merges the obfuscation dictionaries as a union and returns its path' {
        $C = New-Case
        $GapDict = [ordered]@{
            GeneratedAt         = '2026-01-01 00:00:00'
            ResourceIdMap       = [ordered]@{ 'prod_tokA' = '/id/a' }
            SubscriptionNameMap = [ordered]@{ 'prod_subtok' = 'Gap Sub' }
        }
        # Seeded recovery: it shares the gap's token and adds one of its own.
        $RecDict = [ordered]@{
            GeneratedAt   = '2026-01-02 00:00:00'
            ResourceIdMap = [ordered]@{ 'prod_tokA' = '/id/a'; 'prod_tokB' = '/id/b' }
            TagMap        = [ordered]@{ 'prod_tagtok' = 'payments' }
        }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $RecDict

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
        $GapDict = [ordered]@{ GeneratedAt = '2026-01-01 00:00:00'; ResourceIdMap = [ordered]@{ 'prod_tokA' = '/id/a' } }
        New-Bundle -Dir $C.Gap -Base $script:GapBase -Inventory ([ordered]@{ Version = '3.2.3'; VirtualMachines = @((New-Record 'vm01')) }) -Dictionary $GapDict
        New-Bundle -Dir $C.Recovery -Base $script:RecBase -Inventory ([ordered]@{ Version = '3.2.3'; AppServices = @((New-Record 'app01')) }) -Dictionary $GapDict

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

