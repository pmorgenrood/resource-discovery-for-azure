# Requires -Modules Pester
# =============================================================================
# MetricsCountAggregation.Tests.ps1
#
# Tests for how Extension/Metrics.ps1 reads a metric requested with the 'Count'
# aggregation (Cosmos DB 'TotalRequests'):
#   - the value is taken from each data point's own Count, not from the length
#     of the data-point collection;
#   - points without a value are left out of MetricCount and the percentile,
#     as for the other aggregations, and a point without a Count property reads
#     as no value rather than as 1;
#   - a response with no data points gives 0;
#   - the Total and Maximum definitions of the same account are unchanged;
#   - the -UseMetricsBatch reader (New-RdaMetricObject) reads a getBatch data
#     point that has no field for the aggregation as no value, not as 1.
#
# Get-AzMetric runs inside ForEach-Object -Parallel and the metric worker pool's
# runspaces, which Pester mocks do not reach. The tests therefore put a stand-in
# Az.Monitor module first on PSModulePath. Like the real cmdlet, it returns .Data
# as a typed collection with a Count property of its own (the number of points),
# filled with points that carry TimeStamp, Average, Minimum, Maximum, Total and
# Count. The points of each resource and metric come from a JSON file.
#
# No live Azure. Run with:
#   Invoke-Pester ./Tests/MetricsCountAggregation.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:MetricsScript = Join-Path $script:RepoRoot 'Extension/Metrics.ps1'
    if (-not (Test-Path $script:MetricsScript)) { throw "Metrics.ps1 not found at $script:MetricsScript" }
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    # Metrics.ps1 reads the current Az context once. Returning none keeps the run
    # offline and independent of any saved login on the machine.
    function Get-AzContext { return $null }

    $script:SubscriptionId = '12345678-1234-1234-1234-123456789012'
    $script:Subscriptions = @([PSCustomObject]@{ id = $script:SubscriptionId; Name = 'test-subscription' })

    $script:ModuleRoot = Join-Path $TestDrive 'modules'
    $FakeModuleDir = Join-Path $script:ModuleRoot 'Az.Monitor'
    New-Item -ItemType Directory -Path $FakeModuleDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $FakeModuleDir 'Az.Monitor.psm1') -Encoding utf8 -Value @'
function Get-AzMetric
{
    [CmdletBinding()]
    param(
        [string]$ResourceId,
        [string[]]$MetricName,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [timespan]$TimeGrain,
        [string]$AggregationType,
        $DefaultProfile,
        [switch]$DetailedOutput
    )

    # Maps 'resource name|metric name' to a list of points; a field a point does
    # not list is null, and a field named in its 'Omit' is left off the point.
    # A metric with no entry gets one point with every field 1.
    $Spec = Get-Content -LiteralPath $env:RDA_TEST_COUNT_SPEC -Raw | ConvertFrom-Json -AsHashtable
    $ResourceName = ($ResourceId -split '/')[-1]
    foreach ($Name in @($MetricName))
    {
        $Key = $ResourceName + '|' + $Name
        $PointSpecs = if ($Spec.ContainsKey($Key)) { @($Spec[$Key]) } else { @(@{ Average = 1; Minimum = 1; Maximum = 1; Total = 1; Count = 1 }) }

        $Data = [System.Collections.Generic.List[object]]::new()
        $Minute = 0
        foreach ($Fields in $PointSpecs)
        {
            $Point = [ordered]@{ TimeStamp = $StartTime.AddMinutes($Minute++) }
            foreach ($Field in 'Average', 'Minimum', 'Maximum', 'Total', 'Count')
            {
                if (@($Fields['Omit']) -notcontains $Field) { $Point[$Field] = $Fields[$Field] }
            }
            $Data.Add([PSCustomObject]$Point)
        }

        [PSCustomObject]@{
            Id   = $ResourceId + '/providers/Microsoft.Insights/metrics/' + $Name
            Name = [PSCustomObject]@{ Value = $Name; LocalizedValue = $Name }
            Data = $Data
        }
    }
}
Export-ModuleMember -Function Get-AzMetric
'@

    $script:OriginalModulePath = $env:PSModulePath
    $script:OriginalDebugLogFile = $Global:DebugLogFile
    $env:PSModulePath = $script:ModuleRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath

    function New-TestCosmosDb
    {
        param([string]$Name)

        return [PSCustomObject]@{
            TYPE           = 'microsoft.documentdb/databaseaccounts'
            Id             = '/subscriptions/{0}/resourceGroups/rg-metrics-test/providers/Microsoft.DocumentDB/databaseAccounts/{1}' -f $script:SubscriptionId, $Name
            subscriptionId = $script:SubscriptionId
            ResourceGroup  = 'rg-metrics-test'
            Name           = $Name
            Location       = 'westeurope'
            kind           = 'GlobalDocumentDB'
            ManagedBy      = ''
        }
    }

    # Runs Metrics.ps1 against the stand-in module with the given points and
    # returns the records it wrote.
    function Invoke-MetricsRun
    {
        param([object[]]$Resources, [string]$RunName, [hashtable]$Spec)

        $RunDir = Join-Path $TestDrive $RunName
        New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
        $SpecFile = Join-Path $RunDir 'points.json'
        $Spec | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SpecFile -Encoding utf8

        $env:RDA_TEST_COUNT_SPEC = $SpecFile
        $Global:DebugLogFile = Join-Path $RunDir 'debug.log'

        try
        {
            $null = & $script:MetricsScript -Subscriptions $script:Subscriptions -Resources $Resources -Task 'Processing' -ConcurrencyLimit 16 -FilePath (Join-Path $RunDir 'Metrics_test') -Obfuscate $false *>&1
        }
        finally
        {
            $Global:DebugLogFile = $script:OriginalDebugLogFile
        }

        return @(Get-ChildItem -LiteralPath $RunDir -Filter 'Metrics_test_*.json' |
                ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Metrics })
    }

    function Get-TestRecord
    {
        param([object[]]$Records, [string]$Name, [string]$Metric)

        $Found = @($Records | Where-Object { $_.ID -like ('*/' + $Name) -and $_.Metric -eq $Metric })
        if ($Found.Count -ne 1) { throw ("expected one record for {0}/{1}, found {2}" -f $Name, $Metric, $Found.Count) }
        return $Found[0]
    }
}

AfterAll {
    $env:PSModulePath = $script:OriginalModulePath
    $Global:DebugLogFile = $script:OriginalDebugLogFile
    Remove-Item -Path 'Env:RDA_TEST_COUNT_SPEC' -ErrorAction SilentlyContinue
}

Describe 'Metrics.ps1 Count aggregation' {

    BeforeAll {
        # 21 one-minute points: counts 0..19 and one point without a value.
        $DayPoints = @(0..9 | ForEach-Object { @{ Count = $_ } }) + @(@{ Count = $null }) + @(10..19 | ForEach-Object { @{ Count = $_ } })

        $Spec = @{
            'cosmos-mixed|TotalRequests'         = @(@{ Count = 3 }, @{ Count = $null }, @{ Count = 7 }, @{ Count = 0 })
            'cosmos-mixed|TotalRequestUnits'     = @(@{ Total = 10 }, @{ Total = $null }, @{ Total = 20 }, @{ Total = 5 })
            'cosmos-mixed|DataUsage'             = @(@{ Total = 1000 }, @{ Total = 3000 }, @{ Total = 2000 })
            'cosmos-mixed|ProvisionedThroughput' = @(@{ Maximum = 400 }, @{ Maximum = 400 }, @{ Maximum = $null }, @{ Maximum = 1000 })
            'cosmos-day|TotalRequests'           = $DayPoints
            'cosmos-empty|TotalRequests'         = @()
            'cosmos-single|TotalRequests'        = @(@{ Count = 5 })
            'cosmos-nofield|TotalRequests'       = @(@{ Omit = 'Count' }, @{ Omit = 'Count' }, @{ Count = 0 })
        }
        $Accounts = @('cosmos-mixed', 'cosmos-day', 'cosmos-empty', 'cosmos-single', 'cosmos-nofield') | ForEach-Object { New-TestCosmosDb -Name $_ }

        $script:Records = Invoke-MetricsRun -Resources $Accounts -RunName 'count' -Spec $Spec
    }

    It 'reads each data point''s Count, not the number of data points' {
        $Record = Get-TestRecord -Records $script:Records -Name 'cosmos-mixed' -Metric 'TotalRequests'

        # Measure 'Largest' over the per-point counts 3, null, 7, 0.
        $Record.MetricValue | Should -Be 7
        $Record.MetricCount | Should -Be 3
        $Record.MetricTotalCount | Should -Be 4
        $Record.MetricPercentile | Should -Be 7
        $Record.MetricError | Should -BeFalse
    }

    It 'takes the 95th percentile over the per-point counts' {
        $Record = Get-TestRecord -Records $script:Records -Name 'cosmos-day' -Metric 'TotalRequests'

        $Record.MetricPercentile | Should -Be 18
        $Record.MetricValue | Should -Be 19
        $Record.MetricCount | Should -Be 20
        $Record.MetricTotalCount | Should -Be 21
    }

    It 'records 0 and no counted point when the response has no data points' {
        $Record = Get-TestRecord -Records $script:Records -Name 'cosmos-empty' -Metric 'TotalRequests'

        $Record.MetricCount | Should -Be 0
        $Record.MetricValue | Should -Be 0
        $Record.MetricPercentile | Should -Be 0
        $Record.MetricTotalCount | Should -Be 0
        $Record.MetricError | Should -BeFalse
    }

    It 'reads the Count of a single data point' {
        $Record = Get-TestRecord -Records $script:Records -Name 'cosmos-single' -Metric 'TotalRequests'

        $Record.MetricValue | Should -Be 5
        $Record.MetricCount | Should -Be 1
        $Record.MetricPercentile | Should -Be 5
        $Record.MetricTotalCount | Should -Be 1
    }

    It 'reads a data point without a Count property as no value, not as 1' {
        $Record = Get-TestRecord -Records $script:Records -Name 'cosmos-nofield' -Metric 'TotalRequests'

        $Record.MetricValue | Should -Be 0
        $Record.MetricCount | Should -Be 1
        $Record.MetricTotalCount | Should -Be 3
        $Record.MetricError | Should -BeFalse
    }

    It 'keeps the Total and Maximum definitions of the account as they were while its Count definition is read per point' {
        # Total, Measure 'Sum' over 10, null, 20, 5.
        $Units = Get-TestRecord -Records $script:Records -Name 'cosmos-mixed' -Metric 'TotalRequestUnits'
        $Units.MetricValue | Should -Be 35
        $Units.MetricCount | Should -Be 3
        $Units.MetricTotalCount | Should -Be 4
        $Units.MetricPercentile | Should -Be 20

        # Total, Measure 'Largest' over 1000, 3000, 2000.
        $Usage = Get-TestRecord -Records $script:Records -Name 'cosmos-mixed' -Metric 'DataUsage'
        $Usage.MetricValue | Should -Be 3000
        $Usage.MetricCount | Should -Be 3
        $Usage.MetricTotalCount | Should -Be 3
        $Usage.MetricPercentile | Should -Be 3000

        # Maximum, Measure 'Largest' over 400, 400, null, 1000.
        $Throughput = Get-TestRecord -Records $script:Records -Name 'cosmos-mixed' -Metric 'ProvisionedThroughput'
        $Throughput.MetricValue | Should -Be 1000
        $Throughput.MetricCount | Should -Be 3
        $Throughput.MetricTotalCount | Should -Be 4
        $Throughput.MetricPercentile | Should -Be 1000

        @($script:Records | Where-Object { $_.MetricError }).Count | Should -Be 0
        (Get-TestRecord -Records $script:Records -Name 'cosmos-mixed' -Metric 'TotalRequests').MetricValue | Should -Be 7
    }
}

Describe 'New-RdaMetricObject reads the aggregation field of each getBatch data point' {

    BeforeAll {
        # The function lives inside the metrics phase, so it is lifted from the source.
        $Source = Get-Content -LiteralPath $script:MetricsScript -Raw
        $Tokens = $null; $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$Tokens, [ref]$Errors)
        if (@($Errors).Count -gt 0) { throw ('Extension/Metrics.ps1 does not parse: {0}' -f $Errors[0].Message) }
        $FnAst = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'New-RdaMetricObject' }, $true) | Select-Object -First 1
        if (-not $FnAst) { throw 'New-RdaMetricObject was not found in Extension/Metrics.ps1' }
        . ([scriptblock]::Create($FnAst.Extent.Text))

        $script:CountDef = [PSCustomObject]@{
            Id = '/subscriptions/{0}/resourceGroups/rg-metrics-test/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-batch' -f $script:SubscriptionId
            MetricName = 'TotalRequests'; Aggregation = 'Count'; Measure = 'Largest'; Interval = '00:01:00'; Series = 'false'
            SubName = 'test-subscription'; ResourceGroup = 'rg-metrics-test'; Name = 'cosmos-batch'; Location = 'westeurope'; Service = 'CosmosDB'
        }

        # One getBatch metric result, parsed from JSON as Invoke-RestMethod does.
        function ConvertTo-TestMetricResult
        {
            param([string]$DataJson)

            return ('{{"name":{{"value":"TotalRequests"}},"timeseries":[{{"data":{0}}}]}}' -f $DataJson) | ConvertFrom-Json
        }
    }

    It 'reads a data point without a count field as no value, not as 1' {
        $Result = ConvertTo-TestMetricResult -DataJson '[{"timeStamp":"2026-10-01T00:00:00Z","count":3},{"timeStamp":"2026-10-01T00:01:00Z"},{"timeStamp":"2026-10-01T00:02:00Z","count":0}]'

        $Record = New-RdaMetricObject -Def $script:CountDef -MetricResult $Result

        $Record.MetricCount | Should -Be 2
        $Record.MetricValue | Should -Be 3
        $Record.MetricTotalCount | Should -Be 3
        $Record.MetricPercentile | Should -Be 3
        $Record.MetricError | Should -BeFalse
    }

    It 'records 0 when no data point has a count field' {
        $Result = ConvertTo-TestMetricResult -DataJson '[{"timeStamp":"2026-10-01T00:00:00Z"}]'

        $Record = New-RdaMetricObject -Def $script:CountDef -MetricResult $Result

        $Record.MetricValue | Should -Be 0
        $Record.MetricCount | Should -Be 0
        $Record.MetricTotalCount | Should -Be 1
        $Record.MetricPercentile | Should -Be 0
    }
}
