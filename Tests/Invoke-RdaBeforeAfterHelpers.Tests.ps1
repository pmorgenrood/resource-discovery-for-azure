#Requires -Version 7.2
# Pester 5 tests for the helpers of Invoke-RdaBeforeAfter.ps1 (code download, Azure CLI scan, zip counts), on fake zips.
# Run: pwsh -NoProfile -NonInteractive -Command "Invoke-Pester -Path ./Tests/Invoke-RdaBeforeAfterHelpers.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Customer = Join-Path $Root 'Invoke-RdaBeforeAfter.ps1'
    $script:Pwsh = (Get-Process -Id $PID).Path
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:S1 = '11111111-1111-1111-1111-111111111111'

    function Get-FakeId([string]$Type, [string]$Name, [string]$Rg = 'rg1', [string]$Sub = $script:S1)
    {
        return "/subscriptions/$Sub/resourceGroups/$Rg/providers/$Type/$Name"
    }

    # A fake run: inventory sections, consumption rows, metrics rows.
    function Get-FakeRun
    {
        param([switch]$Masked, [int]$Vms = 2, [int]$Disks = 1, [int]$ConsRows = 3, [int]$Metrics = 2,
            [switch]$NegativeQuantity, [switch]$DropConsLink, [switch]$CloudServiceRoles, [string]$Salt = 'a',
            [switch]$SwapOneVm, [double]$Qty = 1.5, [string[]]$Header, [string[]]$FailedCollector = @())
        $Sub = if ($Masked) { "prod_sub-$Salt" } else { $script:S1 }
        $Rg = if ($Masked) { "prod_rg-$Salt" } else { 'rg1' }
        $VmIds = @(for ($i = 1; $i -le $Vms; $i++) { $N = if ($Masked) { "prod_vm$i-$Salt" } else { "vm$i" }; if ($SwapOneVm -and $i -eq 1) { $N = 'vmX' }; Get-FakeId -Type 'Microsoft.Compute/virtualMachines' -Name $N -Rg $Rg -Sub $Sub })
        $DiskIds = @(for ($i = 1; $i -le $Disks; $i++) { $N = if ($Masked) { "nonprod_d$i-$Salt" } else { "d$i" }; Get-FakeId -Type 'Microsoft.Compute/disks' -Name $N -Rg $Rg -Sub $Sub })
        $Inv = [ordered]@{
            Version = '3.2.3'
            VirtualMachines = @($VmIds | ForEach-Object { [ordered]@{ ID = $_; Name = ($_ -split '/')[-1]; Subscription = $Sub; ResourceGroup = $Rg; SKU = 'Standard_B2s'; CPU = 2 } })
            VMDisk = @($DiskIds | ForEach-Object { [ordered]@{ ID = $_; Name = ($_ -split '/')[-1]; Subscription = $Sub; ResourceGroup = $Rg; SKU = 'Premium_LRS' } })
            CloudServices = @(if ($CloudServiceRoles) { 1..3 | ForEach-Object { [ordered]@{ ID = (Get-FakeId -Type 'Microsoft.Compute/cloudServices' -Name $(if ($Masked) { "prod_cs-$Salt" } else { 'cs1' }) -Rg $Rg -Sub $Sub); Name = 'cs1'; Subscription = $Sub; ResourceGroup = $Rg } } } else { [ordered]@{ ID = (Get-FakeId -Type 'Microsoft.Compute/cloudServices' -Name $(if ($Masked) { "prod_cs-$Salt" } else { 'cs1' }) -Rg $Rg -Sub $Sub); Name = 'cs1'; Subscription = $Sub; ResourceGroup = $Rg } })
            PublicIP = @()
        }
        $Hdr = if ($Header) { $Header } else { @('InstanceData', 'MeterCategory', 'MeterId', 'MeterName', 'MeterSubCategory', 'Quantity', 'UsageStartTime', 'UsageEndTime', 'ResourceId') }
        $Lines = [System.Collections.Generic.List[string]]::new()
        $Lines.Add(($Hdr | ForEach-Object { '"' + $_ + '"' }) -join ',')
        for ($i = 0; $i -lt $ConsRows; $i++)
        {
            $Rid = if ($DropConsLink) { Get-FakeId -Type 'Microsoft.Compute/virtualMachines' -Name $(if ($Masked) { "prod_gone-$Salt" } else { 'gone' }) -Rg $Rg -Sub $Sub } else { $VmIds[$i % $VmIds.Count] }
            $Q = if ($NegativeQuantity -and $i -eq 0) { -1 } else { $Qty }
            $Vals = @{ InstanceData = '{"a":1,"b":"x, y"}'; MeterCategory = $(if ($i % 2) { 'Storage' } else { 'Virtual Machines' }); MeterId = "m$i"; Quantity = ([string]$Q); UsageStartTime = '2026-10-01T00:00:00Z'; UsageEndTime = '2026-10-31T00:00:00Z'; ResourceId = $Rid; Cost = '0.5' }
            $Lines.Add(($Hdr | ForEach-Object { '"' + ([string]$Vals[$_]).Replace('"', '""') + '"' }) -join ',')
        }
        $Met = @{ Metrics = @(for ($i = 0; $i -lt $Metrics; $i++) { [ordered]@{ ID = $VmIds[$i % $VmIds.Count]; Name = ($VmIds[$i % $VmIds.Count] -split '/')[-1]; Subscription = $Sub; ResourceGroup = $Rg; Service = 'VM'; Metric = 'Percentage CPU'; MetricAggregate = 'Average'; MetricValue = 1.5; MetricCount = 10; MetricPercentile = 2.0; MetricError = $false } }) }
        $Diag = @('Resource Discovery for Azure - diagnostics', '', ('Collector failures: {0}' -f $FailedCollector.Count)) + @($FailedCollector | ForEach-Object { '  [sub <guid>] {0}: Cannot convert null to type "System.DateTime".' -f $_ }) + @('', 'Metrics auth-skipped subscriptions: 0', '', 'Consumption failed/incomplete subscriptions: 0')
        if ($FailedCollector -contains 'VMDisk') { $Inv.VMDisk = @() }
        return [pscustomobject]@{ Inventory = ($Inv | ConvertTo-Json -Depth 10); Consumption = ($Lines -join "`n"); Metrics = ($Met | ConvertTo-Json -Depth 10); Diagnostics = ($Diag -join "`n") }
    }

    function Add-ZipText($Archive, [string]$Name, [string]$Text)
    {
        $E = $Archive.CreateEntry($Name)
        $W = [IO.StreamWriter]::new($E.Open(), [Text.UTF8Encoding]::new($false))
        try { $W.Write($Text) } finally { $W.Dispose() }
    }

    # Writes a per-subscription zip; with -Wrap, a wrapper zip holding it.
    function Write-FakeZip([string]$Path, $Run, [switch]$Wrap)
    {
        $Ms = [IO.MemoryStream]::new()
        $z = [IO.Compression.ZipArchive]::new($Ms, [IO.Compression.ZipArchiveMode]::Create, $true)
        Add-ZipText -Archive $z -Name 'Inventory_ResourcesReport_1.json' -Text $Run.Inventory
        Add-ZipText -Archive $z -Name 'Consumption_ResourcesReport_1.csv' -Text $Run.Consumption
        Add-ZipText -Archive $z -Name 'Metrics_ResourcesReport_1.json' -Text $Run.Metrics
        Add-ZipText -Archive $z -Name 'Diagnostics_ResourcesReport_1.log' -Text $Run.Diagnostics
        $z.Dispose()
        if ($Wrap)
        {
            $Fs = [IO.File]::Create($Path)
            $O = [IO.Compression.ZipArchive]::new($Fs, [IO.Compression.ZipArchiveMode]::Create)
            $E = $O.CreateEntry('ResourcesReport_1.zip'); $S = $E.Open(); $Ms.Position = 0; $Ms.CopyTo($S); $S.Dispose()
            Add-ZipText -Archive $O -Name 'RunSummary.log' -Text 'ok'
            $O.Dispose(); $Fs.Dispose()
        }
        else { [IO.File]::WriteAllBytes($Path, $Ms.ToArray()) }
        return $Path
    }
}

Describe 'Invoke-RdaBeforeAfter helpers' {
    BeforeAll { . $script:Customer }

    It 'finds Azure CLI calls but not comments or messages' {
        $T = Join-Path $TestDrive 'tree1'; New-Item -ItemType Directory (Join-Path $T 'Functions') -Force | Out-Null
        Set-Content (Join-Path $T 'ResourceInventory.ps1') "# az login is old`nWrite-Host 'run az login first'"
        Test-RdaTreeNeedsAzCli -TreePath $T | Should -BeFalse
        Set-Content (Join-Path $T 'Functions/X.ps1') '    $Raw = az account show --output json 2>$null'
        Test-RdaTreeNeedsAzCli -TreePath $T | Should -BeTrue
        Set-Content (Join-Path $T 'Functions/X.ps1') '    $Secret | az login --service-principal'
        Test-RdaTreeNeedsAzCli -TreePath $T | Should -BeTrue
        Set-Content (Join-Path $T 'Functions/X.ps1') '            $Global:Subscriptions = @(az account list --output json | ConvertFrom-Json)'
        Test-RdaTreeNeedsAzCli -TreePath $T | Should -BeTrue
    }

    It 'reads the commit id from a zip comment, and empty when there is none' {
        $P = Join-Path $TestDrive 'c.zip'
        $Fs = [IO.File]::Create($P); $z = [IO.Compression.ZipArchive]::new($Fs, [IO.Compression.ZipArchiveMode]::Create); $null = $z.CreateEntry('x'); $z.Dispose(); $Fs.Dispose()
        Get-RdaZipComment -Path $P | Should -Be ''
        # Append a comment by hand: the last 2 bytes of the end record hold its length.
        $Bytes = [IO.File]::ReadAllBytes($P)
        $C = [Text.Encoding]::ASCII.GetBytes('0123456789abcdef0123456789abcdef01234567')
        $Bytes[$Bytes.Length - 2] = $C.Length; $Bytes[$Bytes.Length - 1] = 0
        [IO.File]::WriteAllBytes($P, $Bytes + $C)
        Get-RdaZipComment -Path $P | Should -Be '0123456789abcdef0123456789abcdef01234567'
    }

    It 'counts rows of a report zip, quoted line breaks included' {
        $Run = Get-FakeRun -ConsRows 5
        $Run.Consumption = $Run.Consumption + "`n" + '"{""a"":""line1' + "`n" + 'line2""}","Storage","m9","1","2026-10-01","2026-10-02","/x"'
        $P = Write-FakeZip (Join-Path $TestDrive 'cnt.zip') $Run -Wrap
        $C = Get-RdaZipCount -Path $P
        $C.reports | Should -Be 1
        $C.inventoryRows | Should -Be 4
        $C.inventoryBySection.VirtualMachines | Should -Be 2
        $C.consumptionRows | Should -Be 6
        $C.metricsRows | Should -Be 2
        ($C | ConvertTo-Json -Depth 5) | Should -Not -Match $script:S1
    }

    It 'rejects a bad tenant id before doing anything' {
        $Out = & $script:Pwsh -NoProfile -NonInteractive -File $script:Customer -TenantID 'nope' -SubscriptionID $script:S1 -OutputDirectory (Join-Path $TestDrive 'o1') 2>&1
        $LASTEXITCODE | Should -Be 1
        ($Out -join "`n") | Should -Match 'TenantID'
        Test-Path (Join-Path $TestDrive 'o1') | Should -BeFalse
    }

    It 'refuses an output folder that is not empty' {
        $D = Join-Path $TestDrive 'o2'; New-Item -ItemType Directory $D | Out-Null; Set-Content (Join-Path $D 'x') 'x'
        $Out = & $script:Pwsh -NoProfile -NonInteractive -File $script:Customer -TenantID $script:S1 -SubscriptionID $script:S1 -OutputDirectory $D 2>&1
        $LASTEXITCODE | Should -Be 1
        ($Out -join "`n") | Should -Match 'not empty'
    }

    It 'stops with advice when the After branch is not on GitHub, and deletes the code folder' {
        $D = Join-Path $TestDrive 'o3'
        $Bz = Join-Path $TestDrive 'before-code.zip'
        $T = Join-Path $TestDrive 'bt'; New-Item -ItemType Directory $T | Out-Null; Set-Content (Join-Path $T 'ResourceInventory.ps1') '# stand-in'
        Compress-Archive -Path (Join-Path $T '*') -DestinationPath $Bz
        $Out = & $script:Pwsh -NoProfile -NonInteractive -File $script:Customer -TenantID $script:S1 -SubscriptionID $script:S1 -OutputDirectory $D -BeforeCodePath $Bz -AfterBranch 'no-such-branch-for-this-test' 2>&1
        $LASTEXITCODE | Should -Be 1
        ($Out -join "`n") | Should -Match 'all-fixes-2026-11-02'
        Test-Path (Join-Path $D 'code') | Should -BeFalse
    }
}
