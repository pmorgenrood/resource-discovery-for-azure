#Requires -Version 7.0
# =============================================================================
# ConsumptionDaySplit.Tests.ps1
#
# 1. The billing row loop (GetResorceConsumption in ResourceInventory.ps1)
#    builds each row and its JSON column as object literals. The Consumption
#    CSV it writes must stay byte for byte what the earlier loop (Add-Member
#    per column) wrote: the expected SHA-256 values below were taken from that
#    loop (fork all-fixes-optimized fe84096) on the same made-up pages, plain,
#    under -Obfuscate and with -ResourceGroup.
# 2. -UseConsumptionDaySplit (Functions/ConsumptionDaySplit.Functions.ps1):
#    one-day pieces read side by side and joined back into the whole-window
#    rows, Retry-After, the fallback to the usual read (once), and the switch
#    off leaving the usual read alone.
#
# Offline: Azure is replaced by Pester mocks and made-up pages
# (Helpers/ConsumptionTestPages.ps1). Placeholder ids and generic names only.
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $PSScriptRoot 'Helpers/ConsumptionTestPages.ps1')

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

    $script:PlainHash = '445993E63BFB4C08C25B64213F0882E239218DFA96479361C4B0493FD7BB960C'
    $script:Rows = New-ConsumptionTestRows
    $script:Window = [pscustomobject]@{ Start = [datetime]'2026-10-01'; End = [datetime]'2026-11-01' }

    # Runs the billing phase for one subscription on $Pages (serial read) and
    # returns the CSV text with line ends made LF, its SHA-256 and row count.
    function script:Invoke-Phase
    {
        param([string]$Mode = 'Plain')
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
            foreach ($R in $script:Rows | Select-Object -First 400) { if ($R.InstanceData -match '"resourceUri":"([^"]+)"') { $script:ResourceIdDictionary[$Matches[1].ToLowerInvariant()] = '/subscriptions/prod_s1/resourcegroups/prod_r1/providers/microsoft.compute/virtualmachines/prod_' + $Matches[1].Length } }
        }
        GetResorceConsumption
        if (-not (Test-Path -LiteralPath $Global:ConsumptionFileCsv)) { return [pscustomobject]@{ Text = ''; Hash = ''; Rows = 0; Bom = $false } }
        $Bytes = [System.IO.File]::ReadAllBytes($Global:ConsumptionFileCsv)
        $Text = [System.Text.Encoding]::UTF8.GetString($Bytes).Replace("`r`n", "`n")
        $Hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '')
        $Lines = @($Text.TrimEnd("`n") -split "`n")
        [pscustomobject]@{ Text = $Text; Hash = $Hash; Rows = ($Lines.Count - 1); Bom = ($Bytes.Count -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) }
    }
}

Describe 'Billing row loop: the Consumption CSV byte for byte (made-up pages, 3 pages of up to 1,000 rows)' {
    BeforeEach {
        $script:SavedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        $script:SavedUICulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture
        $script:Pages = New-ConsumptionTestPages -Rows $script:Rows
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

    # SHA-256 of the CSV (line ends as LF) the Add-Member loop wrote on these pages.
    It 'writes the same bytes as the Add-Member loop, <Mode>' -ForEach @(
        @{ Mode = 'Plain'; Rows = 2412; Hash = '445993E63BFB4C08C25B64213F0882E239218DFA96479361C4B0493FD7BB960C' }
        @{ Mode = 'Obfuscate'; Rows = 2412; Hash = 'EB674CDD4D95401E978E40F910ECC35BCE47933616C4C78D7E58A0451DC7FE1A' }
        @{ Mode = 'ResourceGroup'; Rows = 738; Hash = '0F2A0DCBEA315C71EC4F30D9A361CF329CEF8B015FA77AAC399A0A1F1E57E61A' }
    ) {
        $Run = Invoke-Phase -Mode $Mode
        if ($env:RDA_CONSUMPTION_TEST_PRINT) { Write-Information -InformationAction Continue ('EXPECTED {0} Rows={1} Hash={2} Bom={3}' -f $Mode, $Run.Rows, $Run.Hash, $Run.Bom) }
        $Run.Rows | Should -Be $Rows
        $Run.Hash | Should -Be $Hash
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

