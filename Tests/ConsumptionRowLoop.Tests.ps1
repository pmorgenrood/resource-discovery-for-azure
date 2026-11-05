#Requires -Version 7.0
# =============================================================================
# ConsumptionRowLoop.Tests.ps1
#
# The billing row loop (GetResorceConsumption in ResourceInventory.ps1)
# builds each row and its JSON column as object literals. The Consumption CSV
# it writes must stay byte for byte what the earlier loop (Add-Member per
# column) wrote. Two checks, on the same made-up pages:
# 1. The current function and the earlier one (Helpers/ConsumptionRowLoop.Base.ps1,
#    a frozen copy) are both run, and their CSV files must be the same bytes:
#    plain, under -Obfuscate and with -ResourceGroup, on a 3-page answer and on
#    pages with one row, no row, or no row list at all.
# 2. The 3-page CSV must also have the SHA-256 values below, which were taken
#    from the earlier loop. They may only be taken again from the earlier loop
#    (RDA_CONSUMPTION_TEST_SOURCE pointing at a ResourceInventory.ps1 that has
#    it, with RDA_CONSUMPTION_TEST_PRINT set), never from the current one.
# The hash is of the raw file bytes, with the platform's line end (Export-Csv
# writes [Environment]::NewLine) made LF so one value fits every platform; a
# line end other than the platform's fails the test.
#
# Offline: Azure is replaced by Pester mocks and made-up pages
# (Helpers/ConsumptionTestPages.ps1). Placeholder ids and generic names only.
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $PSScriptRoot 'Helpers/ConsumptionTestPages.ps1')
    . (Join-Path $PSScriptRoot 'Helpers/ConsumptionRowLoop.Base.ps1')

    # The billing phase function, from this tree or (to take the expected
    # values from another build) from the file RDA_CONSUMPTION_TEST_SOURCE names.
    $Source = if ($env:RDA_CONSUMPTION_TEST_SOURCE) { $env:RDA_CONSUMPTION_TEST_SOURCE } else { Join-Path $script:RepoRoot 'ResourceInventory.ps1' }
    $Tokens = $null
    $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$Tokens, [ref]$Errors)
    $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'GetResorceConsumption' }, $true))
    if ($Fn.Count -ne 1) { throw 'GetResorceConsumption was not found.' }
    . ([scriptblock]::Create($Fn[0].Extent.Text))

    function Get-UsageAggregates { param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken) }
    function Set-AzContext { param($Subscription, $Context, $Scope) }
    function Get-AzContext { param() }
    function Get-ObfuscatedResourceId { param($ResourceId) }
    function Test-DataPlaneAuthReady { param($Phase) $true }

    $script:Rows = New-ConsumptionTestRows
    # Row 402 is in resource group rg-one, has a resource URI and is not in the
    # dictionary the -Obfuscate runs preload (rows 0-399), so a one-row page of
    # it takes the row replace, the -ResourceGroup keep and the masking call.
    $script:OneRow = $script:Rows[402]
    # Rows whose values take the loop's less common branches: dates that are
    # text or missing, and 'Microsoft.Resources' or additionalInfo that is an
    # array, text or holds a nested object.
    $Odd = { param($Instance, $Start, $End) $R = $script:Rows[402].PSObject.Copy(); $R.InstanceData = $Instance; $R.UsageStartTime = $Start; $R.UsageEndTime = $End; $R }
    $Uri = '/subscriptions/sub-a/resourceGroups/rg-one/providers/Microsoft.Compute/disks/DISK-ODD'
    $script:OddRows = @(
        (& $Odd $script:Rows[402].InstanceData '10/1/2026 12:00:00 AM' $null)
        (& $Odd ('{{"Microsoft.Resources":[{{"resourceUri":"{0}","location":"westeurope"}},{{"resourceUri":"{0}-2","location":"eastus"}}]}}' -f $Uri) $script:Rows[402].UsageStartTime $script:Rows[402].UsageEndTime)
        (& $Odd '{"Microsoft.Resources":"just text"}' $script:Rows[402].UsageStartTime $script:Rows[402].UsageEndTime)
        (& $Odd ('{{"Microsoft.Resources":{{"resourceUri":"{0}","location":"westeurope","additionalInfo":[{{"ImageType":"a"}},{{"ImageType":"b"}}]}}}}' -f $Uri) $script:Rows[402].UsageStartTime $script:Rows[402].UsageEndTime)
        (& $Odd ('{{"Microsoft.Resources":{{"resourceUri":"{0}","location":"westeurope","additionalInfo":"text info"}}}}' -f $Uri) $script:Rows[402].UsageStartTime $script:Rows[402].UsageEndTime)
        (& $Odd ('{{"Microsoft.Resources":{{"resourceUri":"{0}","location":"westeurope","additionalInfo":{{"ImageType":{{"Publisher":"p","Offer":"o"}},"vCores":2}}}}}}' -f $Uri) $script:Rows[402].UsageStartTime $script:Rows[402].UsageEndTime)
    )
    $script:Window = [pscustomobject]@{ Start = [datetime]'2026-10-01'; End = [datetime]'2026-11-01' }

    # Runs one billing phase function for one subscription on $script:Pages
    # (fresh rows each run: the phase changes the rows it is given). Returns
    # the CSV's raw bytes, their SHA-256 (platform line end made LF), the row
    # count, whether every line end is the platform's, and the text.
    function script:Invoke-Phase
    {
        param([string]$Mode = 'Plain', [switch]$Base, [object[]]$Rows = $script:Rows, [int]$PageSize = 1000, [scriptblock]$Shape)
        $script:Pages = New-ConsumptionTestPages -Rows $Rows -PageSize $PageSize
        if ($null -ne $Shape) { $script:Pages = & $Shape $script:Pages }
        $Global:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' })
        $Global:ConsumptionFileCsv = Join-Path $TestDrive ('consumption-{0}.csv' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Global:ConsumptionRecordCount = $null
        $Global:ConsumptionFailedSubs = $null
        $script:SubscriptionID = 'sub-a'
        $script:ConsumptionWindow = $script:Window
        $script:ResourceGroup = if ($Mode -eq 'ResourceGroup') { 'rg-one' } else { $null }
        $script:Obfuscate = [switch]($Mode -eq 'Obfuscate')
        $script:ResourceIdDictionary = @{}
        if ($Mode -eq 'Obfuscate')
        {
            # Half the resources as the inventory masked them, the rest masked by the phase.
            foreach ($R in $Rows | Select-Object -First 400) { if ($R.InstanceData -match '"resourceUri":"([^"]+)"') { $script:ResourceIdDictionary[$Matches[1].ToLowerInvariant()] = '/subscriptions/prod_s1/resourcegroups/prod_r1/providers/microsoft.compute/virtualmachines/prod_' + $Matches[1].Length } }
        }
        if ($Base) { GetResorceConsumptionBase } else { GetResorceConsumption }
        $Bytes = [byte[]]::new(0)
        $Written = Test-Path -LiteralPath $Global:ConsumptionFileCsv
        if ($Written) { $Bytes = [System.IO.File]::ReadAllBytes($Global:ConsumptionFileCsv) }
        $Text = [System.Text.Encoding]::UTF8.GetString($Bytes)
        $NewLine = [Environment]::NewLine
        $Lf = if ($NewLine -eq "`n") { $Text } else { $Text.Replace($NewLine, "`n") }
        $Hasher = [System.Security.Cryptography.SHA256]::Create()
        $Hash = [System.BitConverter]::ToString($Hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Lf))).Replace('-', '')
        $Hasher.Dispose()
        $Lines = if ($Lf.Length -eq 0) { @() } else { @($Lf.TrimEnd("`n") -split "`n") }
        [pscustomobject]@{
            Bytes       = $Bytes
            Text        = $Lf
            Hash        = $Hash
            Rows        = [math]::Max(0, $Lines.Count - 1)
            # Every line end is the platform's: no lone CR or LF of another kind.
            LineEndsOk  = ($NewLine -eq "`n" -and -not $Text.Contains("`r")) -or ($NewLine -eq "`r`n" -and -not ($Text -replace "`r`n", '').Contains("`n") -and -not ($Text -replace "`r`n", '').Contains("`r"))
            Bom         = ($Bytes.Count -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
            Written     = $Written
            FailedSubs  = @($Global:ConsumptionFailedSubs).Count
            RecordCount = $Global:ConsumptionRecordCount
        }
    }
}

Describe 'Billing row loop: the Consumption CSV byte for byte' {
    BeforeEach {
        $script:SavedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        $script:SavedUICulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture
        Mock Write-Log { }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } }
        Mock Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-a' } } }
        Mock Get-UsageAggregates {
            $Index = if ([string]::IsNullOrEmpty($ContinuationToken)) { 0 } else { [int]($ContinuationToken -replace '^page-', '') - 1 }
            $script:Pages[$Index]
        }
        Mock Get-ObfuscatedResourceId { if ([string]::IsNullOrEmpty($ResourceId)) { '' } else { '/subscriptions/prod_s2/resourcegroups/prod_r2/providers/masked/prod_' + $ResourceId.Length } }
    }

    AfterEach {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
        [System.Threading.Thread]::CurrentThread.CurrentUICulture = $script:SavedUICulture
    }

    # SHA-256 the Add-Member loop's CSV has on the 3-page answer (2,437 rows).
    It 'writes the bytes the Add-Member loop wrote, <Mode>' -ForEach @(
        @{ Mode = 'Plain'; Rows = 2412; Hash = '445993E63BFB4C08C25B64213F0882E239218DFA96479361C4B0493FD7BB960C' }
        @{ Mode = 'Obfuscate'; Rows = 2412; Hash = 'EB674CDD4D95401E978E40F910ECC35BCE47933616C4C78D7E58A0451DC7FE1A' }
        @{ Mode = 'ResourceGroup'; Rows = 738; Hash = '0F2A0DCBEA315C71EC4F30D9A361CF329CEF8B015FA77AAC399A0A1F1E57E61A' }
    ) {
        $Run = Invoke-Phase -Mode $Mode
        if ($env:RDA_CONSUMPTION_TEST_PRINT) { Write-Information -InformationAction Continue ('EXPECTED {0} Rows={1} Hash={2} Bom={3}' -f $Mode, $Run.Rows, $Run.Hash, $Run.Bom) }
        $Run.Rows | Should -Be $Rows
        $Run.Hash | Should -Be $Hash
        $Run.LineEndsOk | Should -BeTrue
    }

    It 'writes the same bytes as the frozen Add-Member loop, <Mode>, <Case>' -ForEach @(
        foreach ($Mode in 'Plain', 'Obfuscate', 'ResourceGroup')
        {
            @{ Mode = $Mode; Case = '3 pages of up to 1,000 rows'; Count = 2437; PageSize = 1000; Shape = $null; Pick = $null }
            @{ Mode = $Mode; Case = 'a last page of one row (row 402)'; Count = 0; PageSize = 1000; Shape = $null; Pick = { @($script:Rows | Select-Object -First 2000) + @($script:OneRow) } }
            @{ Mode = $Mode; Case = 'a single page of one row (row 402)'; Count = 0; PageSize = 1000; Shape = $null; Pick = { @($script:OneRow) } }
            @{ Mode = $Mode; Case = 'rows with text or missing dates, and Microsoft.Resources or additionalInfo as an array, text or nested object'; Count = 0; PageSize = 1000; Shape = $null; Pick = { $script:OddRows } }
            @{ Mode = $Mode; Case = 'each of those odd rows on a page of its own'; Count = 0; PageSize = 1; Shape = $null; Pick = { $script:OddRows } }
            @{ Mode = $Mode; Case = 'an empty page between two pages'; Count = 1500; PageSize = 1000; Pick = $null; Shape = {
                    param($Pages)
                    @($Pages[0], [pscustomobject]@{ UsageAggregations = @(); ContinuationToken = 'page-3' }, [pscustomobject]@{ UsageAggregations = $Pages[1].UsageAggregations; ContinuationToken = $null })
                }
            }
            @{ Mode = $Mode; Case = 'a page with no row list after a page'; Count = 1500; PageSize = 1000; Pick = $null; Shape = {
                    param($Pages)
                    @([pscustomobject]@{ UsageAggregations = $Pages[0].UsageAggregations; ContinuationToken = 'page-2' }, [pscustomobject]@{ UsageAggregations = $null; ContinuationToken = $null })
                }
            }
            @{ Mode = $Mode; Case = 'an answer with no rows'; Count = 1; PageSize = 1000; Pick = $null; Shape = { param($Pages) @([pscustomobject]@{ UsageAggregations = @(); ContinuationToken = $null }) } }
        }
    ) {
        $Rows = if ($null -ne $Pick) { @(& $Pick) } else { @($script:Rows | Select-Object -First $Count) }
        $Old = Invoke-Phase -Mode $Mode -Base -Rows $Rows -PageSize $PageSize -Shape $Shape
        $New = Invoke-Phase -Mode $Mode -Rows $Rows -PageSize $PageSize -Shape $Shape
        [System.Convert]::ToBase64String($New.Bytes) | Should -BeExactly ([System.Convert]::ToBase64String($Old.Bytes))
        $New.RecordCount | Should -Be $Old.RecordCount
        $New.FailedSubs | Should -Be $Old.FailedSubs
        $New.FailedSubs | Should -Be 0
        $New.Written | Should -Be $Old.Written
        # An answer with no rows leaves an empty file (Export-Csv -Append on no input), in both loops.
        if ($Case -eq 'an answer with no rows') { $New.Bytes.Count | Should -Be 0 } else { $New.RecordCount | Should -BeGreaterThan 0 }
        # No page shape adds a row of its own (a page with no row list writes
        # nothing): every data row has its meter id.
        @($New.Text | ConvertFrom-Csv | Where-Object { [string]::IsNullOrEmpty($_.MeterId) }).Count | Should -Be 0
    }

    It 'covers a row with no additionalInfo, a reservation row and a row of another resource group' {
        $Run = Invoke-Phase -Mode Plain
        $Run.Text | Should -Match ([regex]::Escape('"additionalInfo"":{""ConsumptionMeter"":"""",""ImageType"":"""",""AHB"":"""",""vCores"":0'))
        $Run.Text | Should -Match 'reservationorders/order-1/reservations/res-1'
        $Run.Text | Should -Match '"res-1","order-1"'
        $Run.Text | Should -Match 'resourcegroups/rg-two/'
        (Invoke-Phase -Mode ResourceGroup).Text | Should -Not -Match 'resourcegroups/rg-two/'
        (Invoke-Phase -Mode Obfuscate).Text | Should -Match '"obfuscated","obfuscated"'
    }
}
