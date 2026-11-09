# VM billing-coverage banner tests
# Run with: Invoke-Pester ./Tests/VmBillingGap.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The inventory (ARM/Resource Graph) lists every VM that EXISTS; the consumption
# CSV lists VMs that produced a compute-usage record in the billing window. A
# running VM with no compute-usage record is an anomaly that usually means
# consumption data was incomplete for that VM's subscription. Summary.ps1
# cross-checks the count of running VMs against the count of distinct
# 'Virtual Machines'-meter resources in the consumption CSV and, when the
# running count materially exceeds the billed count, renders a coverage banner
# at the top of the report.
#
# This test is SELF-CONTAINED: it builds a tiny Inventory JSON and a tiny
# Consumption CSV in a temp dir, invokes the REAL Extension/Summary.ps1, and
# asserts the banner is present / absent / scoped correctly. No live Azure, no
# output zip. The comparison is by counts, and by ids when the two files' ids
# meet (case aside); ids that never meet are compared by counts only.

BeforeAll {
    $script:SummaryScript = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Extension', 'Summary.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("VmBillingGap_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

    # Build an Inventory JSON with a controllable number of running/deallocated
    # VMs. Names use the obfuscated signature so the report's obfuscation
    # detection treats the run as obfuscated (the realistic shareable case).
    function New-TestInventory
    {
        param([int]$RunningVms, [int]$DeallocatedVms)

        $Vms = @()
        for ($i = 0; $i -lt $RunningVms; $i++)
        {
            $Vms += [pscustomobject]@{
                Name         = ('prod_{0}' -f [guid]::NewGuid())
                Subscription = ('prod_{0}' -f [guid]::NewGuid())
                Location     = 'eastus'
                Size         = 'Standard_D2s_v3'
                PowerState   = 'vm running'
            }
        }
        for ($i = 0; $i -lt $DeallocatedVms; $i++)
        {
            $Vms += [pscustomobject]@{
                Name         = ('prod_{0}' -f [guid]::NewGuid())
                Subscription = ('prod_{0}' -f [guid]::NewGuid())
                Location     = 'eastus'
                Size         = 'Standard_D2s_v3'
                PowerState   = 'vm deallocated'
            }
        }
        return [pscustomobject]@{ VirtualMachines = $Vms }
    }

    # Build a Consumption CSV with $BilledVms distinct 'Virtual Machines'-meter
    # resource ids (plus some non-VM rows that must be ignored).
    function New-TestConsumptionCsv
    {
        param([string]$Path, [int]$BilledVms)

        $Rows = @()
        for ($i = 0; $i -lt $BilledVms; $i++)
        {
            $Rid = ('prod_{0}' -f [guid]::NewGuid())
            # two rows per resource to prove DISTINCT counting
            $Rows += [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $Rid }
            $Rows += [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $Rid }
        }
        # Non-VM noise rows that must not be counted.
        $Rows += [pscustomobject]@{ MeterCategory = 'Storage'; ResourceId = ('prod_{0}' -f [guid]::NewGuid()) }
        $Rows += [pscustomobject]@{ MeterCategory = 'Bandwidth'; ResourceId = ('prod_{0}' -f [guid]::NewGuid()) }

        $Rows | Select-Object MeterCategory, ResourceId | Export-Csv -Path $Path -Encoding utf8 -NoTypeInformation
    }

    function Invoke-Summary
    {
        param($Inventory, [string]$ConsumptionFile, [int]$Threshold = 0)

        $JsonPath = Join-Path $script:WorkDir ('inv_{0}.json' -f [guid]::NewGuid().ToString('N'))
        $HtmlPath = Join-Path $script:WorkDir ('rpt_{0}.html' -f [guid]::NewGuid().ToString('N'))
        $Inventory | ConvertTo-Json -Depth 8 | Out-File -FilePath $JsonPath -Encoding utf8

        $Params = @{ JsonFile = $JsonPath; HtmlFile = $HtmlPath }
        if ($PSBoundParameters.ContainsKey('ConsumptionFile')) { $Params['ConsumptionFile'] = $ConsumptionFile }
        if ($PSBoundParameters.ContainsKey('Threshold')) { $Params['VmBillingGapThreshold'] = $Threshold }

        & $script:SummaryScript @Params | Out-Null
        return (Get-Content -Path $HtmlPath -Raw)
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path $script:WorkDir))
    {
        Remove-Item -Path $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'VM billing-coverage banner' {

    It 'renders the banner when running VMs exceed billed VMs' {
        $Inv = New-TestInventory -RunningVms 10 -DeallocatedVms 2
        $Csv = Join-Path $script:WorkDir 'con_gap.csv'
        New-TestConsumptionCsv -Path $Csv -BilledVms 4

        $Html = Invoke-Summary -Inventory $Inv -ConsumptionFile $Csv

        # Assert on the rendered banner DIV's text, not the CSS class name
        # ('.coverage-banner' is always present in the <style> block).
        $Html | Should -Match '<div class="coverage-banner">'
        $Html | Should -Match 'VM billing-coverage check'
        # 10 running, 4 billed -> gap 6
        $Html | Should -Match '10 running VMs'
        $Html | Should -Match 'only 4 VMs'
        $Html | Should -Match '6 running VMs'
    }

    It 'reads a consumption file in a folder with brackets in its name' {
        $Inv = New-TestInventory -RunningVms 10 -DeallocatedVms 0
        $Dir = Join-Path $script:WorkDir 'con[1]'
        [void][System.IO.Directory]::CreateDirectory($Dir)
        $Csv = Join-Path $Dir 'con_bracket.csv'
        $Rows = foreach ($i in 1..4) { [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = ('prod_{0}' -f [guid]::NewGuid()) } }
        [System.IO.File]::WriteAllLines($Csv, [string[]]@($Rows | ConvertTo-Csv -NoTypeInformation))

        $Html = Invoke-Summary -Inventory $Inv -ConsumptionFile $Csv

        $Html | Should -Match '10 running VMs'
        $Html | Should -Match 'only 4 VMs'
    }

    It 'counts one service type for a report whose inventory holds one service' {
        $Inv = New-TestInventory -RunningVms 3 -DeallocatedVms 0
        $Html = Invoke-Summary -Inventory $Inv
        $Html | Should -Match '<b>Service Types:</b> 1</div>'
    }

    It 'reports the gap percentage' {
        $Inv = New-TestInventory -RunningVms 10 -DeallocatedVms 0
        $Csv = Join-Path $script:WorkDir 'con_pct.csv'
        New-TestConsumptionCsv -Path $Csv -BilledVms 4
        # gap 6 of 10 running = 60%
        $Html = Invoke-Summary -Inventory $Inv -ConsumptionFile $Csv
        $Html | Should -Match '60%'
    }

    It 'does NOT render the banner when billed matches running' {
        $Inv = New-TestInventory -RunningVms 5 -DeallocatedVms 3
        $Csv = Join-Path $script:WorkDir 'con_match.csv'
        New-TestConsumptionCsv -Path $Csv -BilledVms 5

        $Html = Invoke-Summary -Inventory $Inv -ConsumptionFile $Csv
        $Html | Should -Not -Match '<div class="coverage-banner">'
        $Html | Should -Not -Match 'VM billing-coverage check'
    }

    It 'does NOT render the banner when billed exceeds running (no negative gap)' {
        $Inv = New-TestInventory -RunningVms 3 -DeallocatedVms 0
        $Csv = Join-Path $script:WorkDir 'con_over.csv'
        New-TestConsumptionCsv -Path $Csv -BilledVms 7

        $Html = Invoke-Summary -Inventory $Inv -ConsumptionFile $Csv
        $Html | Should -Not -Match '<div class="coverage-banner">'
        $Html | Should -Not -Match 'VM billing-coverage check'
    }

    It 'does NOT render the banner when no ConsumptionFile is supplied' {
        $Inv = New-TestInventory -RunningVms 10 -DeallocatedVms 0
        $Html = Invoke-Summary -Inventory $Inv
        $Html | Should -Not -Match '<div class="coverage-banner">'
        $Html | Should -Not -Match 'VM billing-coverage check'
    }

    It 'does NOT render the banner for a header-only (empty) consumption CSV' {
        $Inv = New-TestInventory -RunningVms 10 -DeallocatedVms 0
        $Csv = Join-Path $script:WorkDir 'con_empty.csv'
        'MeterCategory,ResourceId' | Out-File -FilePath $Csv -Encoding utf8

        $Html = Invoke-Summary -Inventory $Inv -ConsumptionFile $Csv
        $Html | Should -Not -Match '<div class="coverage-banner">'
        $Html | Should -Not -Match 'VM billing-coverage check'
    }

    It 'counts a VM whose ResourceId repeats in another letter case once' {
        $Inv = New-TestInventory -RunningVms 3 -DeallocatedVms 0
        $Csv = Join-Path $script:WorkDir 'con_case.csv'
        @(
            [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-one/providers/Microsoft.Compute/virtualMachines/vm-1' }
            [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg-one/providers/microsoft.compute/virtualmachines/vm-1' }
        ) | Export-Csv -Path $Csv -Encoding utf8 -NoTypeInformation
        $Html = Invoke-Summary -Inventory $Inv -ConsumptionFile $Csv
        $Html | Should -Match 'only 1 VMs'
    }

    It 'does not count rows with an empty or blank ResourceId, or a file without the column, as billed VMs' {
        $Inv = New-TestInventory -RunningVms 3 -DeallocatedVms 0
        $Csv = Join-Path $script:WorkDir 'con_blank.csv'
        @(
            [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = '' }
            [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = '' }
            [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = '   ' }
            [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = 'vm-a' }
        ) | Export-Csv -Path $Csv -Encoding utf8 -NoTypeInformation
        Invoke-Summary -Inventory $Inv -ConsumptionFile $Csv | Should -Match 'only 1 VMs'

        $NoColumn = Join-Path $script:WorkDir 'con_nocol.csv'
        @('"MeterCategory","Quantity"', '"Virtual Machines","1"') | Set-Content -Path $NoColumn -Encoding utf8
        Invoke-Summary -Inventory $Inv -ConsumptionFile $NoColumn | Should -Match 'only 0 VMs'
    }

    It 'shows a one-VM billing gap that a row with an empty ResourceId would hide' {
        $Inv = New-TestInventory -RunningVms 2 -DeallocatedVms 0
        $Csv = Join-Path $script:WorkDir 'con_onegap.csv'
        @(
            [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = 'vm-a' }
            [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = '' }
        ) | Export-Csv -Path $Csv -Encoding utf8 -NoTypeInformation
        $Html = Invoke-Summary -Inventory $Inv -ConsumptionFile $Csv
        $Html | Should -Match '<div class="coverage-banner">'
        $Html | Should -Match 'only 1 VMs'
    }

    # The check runs at the very end of a run, inside the inventory process; a
    # large subscription's billing file loaded whole as objects took several
    # times its size on disk (several hundred MB more at 100,000 rows).
    It 'reads a 100,000-row consumption file without holding it in memory' -Skip:(-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        $Inv = New-TestInventory -RunningVms 10 -DeallocatedVms 0
        $JsonPath = Join-Path $script:WorkDir 'inv_large.json'
        $Inv | ConvertTo-Json -Depth 8 | Out-File -FilePath $JsonPath -Encoding utf8
        $Csv = Join-Path $script:WorkDir 'con_large.csv'
        $Writer = [System.IO.StreamWriter]::new($Csv, $false, [System.Text.UTF8Encoding]::new($false))
        try
        {
            $Writer.WriteLine('"InstanceData","MeterCategory","MeterId","MeterName","MeterRegion","MeterSubCategory","Quantity","Unit","UsageStartTime","UsageEndTime","ResourceId","ResourceLocation","ConsumptionMeter","ReservationId","ReservationOrderId"')
            for ($i = 0; $i -lt 100000; $i++)
            {
                $Rid = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-{0:d2}/providers/Microsoft.Compute/disks/disk-{1:d5}' -f ($i % 50), ($i % 40000)
                $Instance = '{""Microsoft.Resources"":{""resourceUri"":""' + $Rid + '"",""location"":""eastus"",""additionalInfo"":{""ServiceType"":""Standard_D2s_v5"",""ImageType"":""Canonical"",""UsageType"":""ComputeHR""}}}'
                $Writer.WriteLine(('"{0}","Storage","00000000-0000-0000-0000-000000000000","P10 LRS Disk","US East","Premium SSD Managed Disks","{1}","1 Hour","9/1/2026 12:00:00 AM","9/2/2026 12:00:00 AM","{2}","eastus","","",""' -f $Instance, ($i % 24), $Rid))
            }
        }
        finally
        {
            $Writer.Dispose()
        }
        $HtmlPath = Join-Path $script:WorkDir 'rpt_large.html'
        $Probe = '$MaximumErrorCount = 32768; $P = [System.Diagnostics.Process]::GetCurrentProcess(); [GC]::Collect(); $P.Refresh(); $Before = $P.WorkingSet64; ' +
        ('& ''{0}'' -JsonFile ''{1}'' -HtmlFile ''{2}'' -ConsumptionFile ''{3}'' | Out-Null; ' -f $script:SummaryScript, $JsonPath, $HtmlPath, $Csv) +
        '$P.Refresh(); ''GROWTH_MB='' + [math]::Round(($P.PeakWorkingSet64 - $Before) / 1MB)'
        $Out = @(pwsh -NoProfile -NonInteractive -Command $Probe 2>&1 | ForEach-Object { [string]$_ })
        $Line = @($Out | Where-Object { $_ -like 'GROWTH_MB=*' }) | Select-Object -First 1
        $Line | Should -Not -BeNullOrEmpty -Because ($Out -join "`n")
        [int]($Line -replace '^GROWTH_MB=') | Should -BeLessThan 250
        Get-Content -Path $HtmlPath -Raw | Should -Match 'only 0 VMs'
    }

    It 'shows a running VM with no charge when another id is billed in its place and the counts are equal' {
        $Ids = @(1..3 | ForEach-Object { '/subscriptions/{0}/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm{1}' -f '12345678-1234-1234-1234-123456789012', $_ })
        $Inv = [pscustomobject]@{ VirtualMachines = @(
                [pscustomobject]@{ ID = $Ids[0]; Name = 'vm1'; Subscription = 'sub'; PowerState = 'vm running' }
                [pscustomobject]@{ ID = $Ids[1]; Name = 'vm2'; Subscription = 'sub'; PowerState = 'vm running' }
                [pscustomobject]@{ ID = $Ids[2]; Name = 'vm3'; Subscription = 'sub'; PowerState = 'vm deallocated' }) }
        $InvPath = Join-Path $script:WorkDir 'inv-swapped.json'
        $Inv | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $InvPath -Encoding utf8
        $Csv = Join-Path $script:WorkDir 'cons-swapped.csv'
        # vm1 billed (in capitals), vm2 not, vm3 (stopped) billed: 2 running, 2 billed ids.
        @([pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $Ids[0].ToUpperInvariant() }, [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $Ids[2] }) |
            Export-Csv -Path $Csv -Encoding utf8 -NoTypeInformation
        $Html = Join-Path $script:WorkDir 'swapped.html'
        & $script:SummaryScript -JsonFile $InvPath -HtmlFile $Html -ConsumptionFile $Csv -VmBillingGapThreshold 0 *> $null
        $Text = Get-Content -LiteralPath $Html -Raw
        $Text | Should -Match 'class="coverage-banner"'
        $Text | Should -Match '2 running VMs were discovered in the inventory, but only 1 VMs have compute-usage records'
    }

    It 'counts a running scale set member billed under its scale set''s id as billed' {
        $Sub = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg/providers/microsoft.compute'
        $Set = $Sub + '/virtualmachinescalesets/set1'
        $Inv = [pscustomobject]@{ VirtualMachines = @(
                [pscustomobject]@{ ID = $Sub + '/virtualmachines/vm1'; Name = 'vm1'; Subscription = 'sub'; PowerState = 'vm running' }
                [pscustomobject]@{ ID = $Set + '/virtualmachines/set1_0'; Set = $Set; Name = 'set1_0'; Subscription = 'sub'; PowerState = 'vm running' }) }
        $InvPath = Join-Path $script:WorkDir 'inv-vmss.json'
        $Inv | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $InvPath -Encoding utf8
        $Csv = Join-Path $script:WorkDir 'cons-vmss.csv'
        @([pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $Sub + '/virtualmachines/vm1' }, [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $Set }) |
            Export-Csv -Path $Csv -Encoding utf8 -NoTypeInformation
        $Html = Join-Path $script:WorkDir 'vmss.html'
        & $script:SummaryScript -JsonFile $InvPath -HtmlFile $Html -ConsumptionFile $Csv -VmBillingGapThreshold 0 *> $null
        Get-Content -LiteralPath $Html -Raw | Should -Not -Match 'class="coverage-banner"'
    }

    It 'counts two running members of one scale set billed under the set as billed' {
        $Sub = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg/providers/microsoft.compute'
        $Set = $Sub + '/virtualmachinescalesets/set1'
        $Inv = [pscustomobject]@{ VirtualMachines = @(
                [pscustomobject]@{ ID = $Sub + '/virtualmachines/vm1'; Name = 'vm1'; Subscription = 'sub'; PowerState = 'vm running' }
                [pscustomobject]@{ ID = $Set + '/virtualmachines/set1_0'; Set = $Set; Name = 'set1_0'; Subscription = 'sub'; PowerState = 'vm running' }
                [pscustomobject]@{ ID = $Set + '/virtualmachines/set1_1'; Set = $Set; Name = 'set1_1'; Subscription = 'sub'; PowerState = 'vm running' }) }
        $InvPath = Join-Path $script:WorkDir 'inv-vmss2.json'
        $Inv | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $InvPath -Encoding utf8
        $Csv = Join-Path $script:WorkDir 'cons-vmss2.csv'
        @([pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $Sub + '/virtualmachines/vm1' }, [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $Set }) |
            Export-Csv -Path $Csv -Encoding utf8 -NoTypeInformation
        $Html = Join-Path $script:WorkDir 'vmss2.html'
        & $script:SummaryScript -JsonFile $InvPath -HtmlFile $Html -ConsumptionFile $Csv -VmBillingGapThreshold 0 *> $null
        Get-Content -LiteralPath $Html -Raw | Should -Not -Match 'class="coverage-banner"'
    }

    It 'shows the gap in a plain report whose billed VM ids are all other ids, with equal counts' {
        $Sub = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg/providers/microsoft.compute/virtualmachines/'
        $Inv = [pscustomobject]@{ VirtualMachines = @(
                [pscustomobject]@{ ID = $Sub + 'vm1'; Name = 'vm1'; Subscription = 'sub'; PowerState = 'vm running' }
                [pscustomobject]@{ ID = $Sub + 'vm2'; Name = 'vm2'; Subscription = 'sub'; PowerState = 'vm running' }) }
        $InvPath = Join-Path $script:WorkDir 'inv-zero.json'
        $Inv | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $InvPath -Encoding utf8
        $Csv = Join-Path $script:WorkDir 'cons-zero.csv'
        @([pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $Sub + 'old1' }, [pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $Sub + 'old2' }) |
            Export-Csv -Path $Csv -Encoding utf8 -NoTypeInformation
        $Html = Join-Path $script:WorkDir 'zero.html'
        & $script:SummaryScript -JsonFile $InvPath -HtmlFile $Html -ConsumptionFile $Csv -VmBillingGapThreshold 0 *> $null
        Get-Content -LiteralPath $Html -Raw | Should -Match '2 running VMs were discovered in the inventory, but only 0 VMs have compute-usage records'
    }

    It 'reads an inventory without a VirtualMachines section or a Version under Set-StrictMode -Version Latest' {
        $InvPath = Join-Path $script:WorkDir 'inv-novm.json'
        # No Version key either: both may be missing.
        '{"PublicIP":[{"Name":"pip","Subscription":"sub"}]}' | Set-Content -LiteralPath $InvPath -Encoding utf8
        $Csv = Join-Path $script:WorkDir 'cons-novm.csv'
        @([pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = '/subscriptions/x/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm1' }) | Export-Csv -Path $Csv -Encoding utf8 -NoTypeInformation
        $Html = Join-Path $script:WorkDir 'novm.html'
        $Script = $script:SummaryScript
        { & { Set-StrictMode -Version Latest; & $Script -JsonFile $InvPath -HtmlFile $Html -ConsumptionFile $Csv *> $null } } | Should -Not -Throw
        Test-Path -LiteralPath $Html | Should -BeTrue
    }

    It 'counts a VM whose state is transient or empty as running, as pricing does' {
        $Sub = '/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/rg/providers/microsoft.compute/virtualmachines/'
        $Inv = [pscustomobject]@{ VirtualMachines = @(
                [pscustomobject]@{ ID = $Sub + 'vm1'; Name = 'vm1'; Subscription = 'sub'; PowerState = 'vm starting (transient)' }
                [pscustomobject]@{ ID = $Sub + 'vm2'; Name = 'vm2'; Subscription = 'sub'; PowerState = '' }
                [pscustomobject]@{ ID = $Sub + 'vm3'; Name = 'vm3'; Subscription = 'sub'; PowerState = 'vm deallocated' }) }
        $InvPath = Join-Path $script:WorkDir 'inv-states.json'
        $Inv | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $InvPath -Encoding utf8
        $Csv = Join-Path $script:WorkDir 'cons-states.csv'
        @([pscustomobject]@{ MeterCategory = 'Virtual Machines'; ResourceId = $Sub + 'vm3' }) | Export-Csv -Path $Csv -Encoding utf8 -NoTypeInformation
        $Html = Join-Path $script:WorkDir 'states.html'
        & $script:SummaryScript -JsonFile $InvPath -HtmlFile $Html -ConsumptionFile $Csv -VmBillingGapThreshold 0 *> $null
        Get-Content -LiteralPath $Html -Raw | Should -Match '2 running VMs were discovered in the inventory, but only 0 VMs have compute-usage records'
    }

    It 'respects the VmBillingGapThreshold (suppresses small gaps)' {
        $Inv = New-TestInventory -RunningVms 10 -DeallocatedVms 0
        $Csv = Join-Path $script:WorkDir 'con_thresh.csv'
        New-TestConsumptionCsv -Path $Csv -BilledVms 8   # gap = 2

        $Html = Invoke-Summary -Inventory $Inv -ConsumptionFile $Csv -Threshold 5
        $Html | Should -Not -Match '<div class="coverage-banner">'
        $Html | Should -Not -Match 'VM billing-coverage check'
    }
}
