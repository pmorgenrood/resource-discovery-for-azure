# Made-up usage pages for the consumption phase tests (ConsumptionDaySplit.Tests.ps1).
# Placeholder ids and generic names only; nothing here comes from a real tenant.
#
# New-ConsumptionTestRows gives whole-window rows shaped as Get-UsageAggregates
# gives them (Quantity a decimal made from a double, UsageStartTime and
# UsageEndTime UTC DateTimes), each with the one-day pieces the usage API would
# report it in (Pieces: the reported day and the double quantity of each piece).
# Rows are in the order of their first reported day, so the day-split join gives
# them back in the same order. The rows cover the cases the billing row loop
# treats apart: no InstanceData, InstanceData that is not JSON, JSON without
# 'Microsoft.Resources', no additionalInfo, a reservation row, a null resource
# URI, every additionalInfo key the loop reads (some in other letter case),
# text with commas, quotes and accents, three resource groups, and quantities
# such as 1.5E-05 and 0.0833333333333334.

function New-ConsumptionTestRows
{
    param([int]$Count = 2437, [datetime]$WindowStart = [datetime]::SpecifyKind([datetime]'2026-10-01', [System.DateTimeKind]::Utc), [int]$Days = 31)
    $Groups = @('rg-one', 'RG-TWO', 'rg-three')
    $QuantityText = @('0.0833333333333334', '2.0', '0.001344', '1.5E-05', '123456.789', '0', '1e-10', '0.369', '24')
    $Inv = [System.Globalization.CultureInfo]::InvariantCulture
    $Rows = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Count; $i++)
    {
        $Rg = $Groups[$i % 3]
        $Uri = switch ($i % 4)
        {
            0 { '/subscriptions/sub-a/resourceGroups/{0}/providers/Microsoft.Compute/virtualMachines/VM-{1}' -f $Rg, ($i % 40) }
            1 { '/subscriptions/sub-a/resourceGroups/{0}/providers/Microsoft.Compute/disks/DISK-{1}' -f $Rg, ($i % 30) }
            2 { '/subscriptions/sub-a/resourceGroups/{0}/providers/Microsoft.Sql/servers/SQL-1/databases/DB-{1}' -f $Rg, ($i % 9) }
            default { '/subscriptions/sub-a/resourceGroups/{0}/providers/Microsoft.Network/publicIPAddresses/IP-{1}' -f $Rg, ($i % 12) }
        }
        $Info = [ordered]@{
            ConsumptionMeter = ('00000000-0000-0000-0000-{0:D12}' -f ($i % 17))
            ImageType        = $(if ($i % 2) { 'Canonical' } else { $null })
            ServiceType      = ('Standard_D2s_v3, "quoted" {0}' -f [char]0xE9)
            VCPUs            = ($i % 8)
            vCores           = $(if ($i % 3 -eq 0) { 4 } else { $null })
            AHB              = $(if ($i % 5 -eq 0) { 'True' } else { $null })
            OS               = $(if ($i % 2) { 'Linux' } else { 'Windows' })
            IsVM             = $(if ($i % 4 -eq 0) { 'true' } else { $null })
            NumberOfCores    = ($i % 6)
            Edition          = $(if ($i % 4 -eq 2) { 'Standard' } else { $null })
            LicenseType      = $(if ($i % 7 -eq 0) { 'LicenseIncluded' } else { $null })
        }
        if ($i % 11 -eq 0) { $Info.Remove('ImageType'); $Info['imagetype'] = 'Lower Case Key' }
        if ($i % 13 -eq 0) { $Info['HostLicenseType'] = 'Windows_Server'; $Info['NumberOfLogicalProcessors'] = 8; $Info['SLO'] = 'GP_Gen5_2'; $Info['ServerSku'] = 'Standard'; $Info['ServerEdition'] = 'Enterprise'; $Info['IsHAEnabled'] = 'False' }
        $Instance = (@{ 'Microsoft.Resources' = [ordered]@{ resourceUri = $Uri; location = 'westeurope'; additionalInfo = $Info } } | ConvertTo-Json -Compress -Depth 5)
        if ($i % 50 -eq 1) { $Instance = $null }
        elseif ($i % 53 -eq 2) { $Instance = 'not json {' }
        elseif ($i % 59 -eq 3) { $Instance = '{"other":1}' }
        elseif ($i % 61 -eq 4) { $Instance = ('{{"Microsoft.Resources":{{"resourceUri":"{0}","location":"eastus"}}}}' -f $Uri) }
        elseif ($i % 67 -eq 5) { $Instance = '{"Microsoft.Resources":{"resourceUri":"/providers/Microsoft.Capacity/reservationOrders/ORDER-1/reservations/RES-1","location":"global","additionalInfo":{"ReservationId":"RES-1","ReservationOrderId":"ORDER-1","ConsumptionMeter":"meter-r"}}}' }
        elseif ($i % 71 -eq 6) { $Instance = '{"Microsoft.Resources":{"resourceUri":null,"location":"westeurope","additionalInfo":{"ServiceType":"x"}}}' }

        # One to three pieces, on consecutive reported days from the first.
        $FirstDay = [int][math]::Floor($i * $Days / $Count)
        $PieceCount = if ($i % 6 -eq 0) { 3 } elseif ($i % 3 -eq 0) { 2 } else { 1 }
        $Pieces = @(for ($p = 0; $p -lt $PieceCount; $p++)
            {
                $Text = $QuantityText[($i + $p) % $QuantityText.Count]
                [pscustomobject]@{ Day = [math]::Min($FirstDay + $p, $Days - 1); Quantity = [double]::Parse($Text, $Inv) }
            })
        $Sum = [double]0
        foreach ($Piece in $Pieces) { $Sum += $Piece.Quantity }
        $UsageDay = $WindowStart.AddDays([math]::Max(0, $FirstDay - 1))
        $Rows.Add([pscustomobject]@{
                InstanceData     = $Instance
                MeterCategory    = @('Virtual Machines', 'Storage', 'SQL Database', 'Networking')[$i % 4]
                MeterId          = ('meter-{0}' -f $i)
                MeterName        = ('D2s v3, "name" {0}' -f [char]0xFC)
                MeterRegion      = $(switch ($i % 5) { 0 { $null } 1 { '' } default { 'EU West' } })
                MeterSubCategory = 'Sub'
                Quantity         = [decimal]$Sum
                Unit             = '1 Hour'
                UsageStartTime   = $UsageDay
                UsageEndTime     = $UsageDay.AddDays(1)
                Pieces           = $Pieces
            })
    }
    return , $Rows.ToArray()
}

# The whole-window rows as Get-UsageAggregates pages of $PageSize: fresh objects
# on every call (the phase changes the rows it is given), with a null row now
# and then, as an answer can hold.
function New-ConsumptionTestPages
{
    param([object[]]$Rows, [int]$PageSize = 1000)
    $Pages = [System.Collections.Generic.List[object]]::new()
    for ($First = 0; $First -lt $Rows.Count; $First += $PageSize)
    {
        $Last = [math]::Min($First + $PageSize, $Rows.Count) - 1
        $Aggregations = @(for ($i = $First; $i -le $Last; $i++)
            {
                $R = $Rows[$i]
                $Properties = if ($i % 97 -eq 96) { $null } else
                {
                    [pscustomobject]@{ InstanceData = $R.InstanceData; MeterCategory = $R.MeterCategory; MeterId = $R.MeterId; MeterName = $R.MeterName; MeterRegion = $R.MeterRegion; MeterSubCategory = $R.MeterSubCategory; Quantity = $R.Quantity; Unit = $R.Unit; UsageStartTime = $R.UsageStartTime; UsageEndTime = $R.UsageEndTime; InfoFields = $null }
                }
                [pscustomobject]@{ Properties = $Properties }
            })
        $Pages.Add([pscustomobject]@{ UsageAggregations = $Aggregations; ContinuationToken = $(if ($Last + 1 -lt $Rows.Count) { 'page-{0}' -f ($Pages.Count + 2) } else { $null }) })
    }
    return , $Pages.ToArray()
}

# The same rows as the usage API reports them one day at a time, shaped as
# Get-UsageAggregatesPage gives them (ConvertFrom-Json of the REST answer):
# camelCase properties, a double quantity, local DateTimes. Returns a hashtable
# 'yyyy-MM-dd' -> list of pages ({ UsageAggregations; ContinuationToken }), with
# $PageSize rows a page and at least one (maybe empty) page a day. The null rows
# of New-ConsumptionTestPages are left out (they have no pieces).
function New-ConsumptionTestDayPages
{
    param([object[]]$Rows, [datetime]$WindowStart = [datetime]'2026-10-01', [int]$Days = 31, [int]$PageSize = 50)
    $ByDay = @{}
    for ($d = 0; $d -lt $Days; $d++) { $ByDay[$d] = [System.Collections.Generic.List[object]]::new() }
    for ($i = 0; $i -lt $Rows.Count; $i++)
    {
        if ($i % 97 -eq 96) { continue }
        $R = $Rows[$i]
        foreach ($Piece in $R.Pieces)
        {
            $ByDay[[int]$Piece.Day].Add([pscustomobject]@{ Properties = [pscustomobject]@{
                        meterId = $R.MeterId; meterName = $R.MeterName; meterCategory = $R.MeterCategory; meterSubCategory = $R.MeterSubCategory; unit = $R.Unit
                        meterRegion = $R.MeterRegion; usageStartTime = $R.UsageStartTime.ToLocalTime(); usageEndTime = $R.UsageEndTime.ToLocalTime()
                        instanceData = $R.InstanceData; quantity = $Piece.Quantity
                    }
                })
        }
    }
    $Result = @{}
    for ($d = 0; $d -lt $Days; $d++)
    {
        $Key = $WindowStart.AddDays($d).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $All = $ByDay[$d]
        $Pages = [System.Collections.Generic.List[object]]::new()
        $First = 0
        do
        {
            $Last = [math]::Min($First + $PageSize, $All.Count) - 1
            $Slice = @(for ($i = $First; $i -le $Last; $i++) { $All[$i] })
            $First += $PageSize
            $Pages.Add([pscustomobject]@{ UsageAggregations = $Slice; ContinuationToken = $(if ($First -lt $All.Count) { '{0}-page-{1}' -f $Key, ($Pages.Count + 2) } else { $null }) })
        } while ($First -lt $All.Count)
        $Result[$Key] = $Pages.ToArray()
    }
    return $Result
}
