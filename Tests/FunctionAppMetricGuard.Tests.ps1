# Requires -Modules Pester
# =============================================================================
# FunctionAppMetricGuard.Tests.ps1
#
# Function apps on a Flex Consumption plan (plan SKU FC1, tier FlexConsumption)
# do not offer FunctionExecutionCount or FunctionExecutionUnits, so asking for
# them only produces a failed request and an error record. Extension/Metrics.ps1
# reads each app's hosting plan from the plan rows already in $Resources and
# leaves those two metrics out for a Flex Consumption app. Every other function
# app, and any app whose plan cannot be read, keeps both metrics as before.
#
# Get-AzMetric runs inside ForEach-Object -Parallel and Start-ThreadJob
# runspaces, which Pester mocks do not reach, so a stand-in Az.Monitor module is
# put first on PSModulePath. It records every call as a file and answers
# BadRequest when an app whose name starts with 'fc1-' is asked for either
# execution metric, the answer the Flex Consumption plan gives.
#
# No live Azure. Run with:
#   Invoke-Pester ./Tests/FunctionAppMetricGuard.Tests.ps1 -Output Detailed
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
    $script:ExecutionNames = @('FunctionExecutionCount', 'FunctionExecutionUnits')
    $script:RgPath = '/subscriptions/{0}/resourceGroups/rg-func-test/providers' -f $script:SubscriptionId

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
        $DefaultProfile
    )

    $Names = @($MetricName)
    $Call = [ordered]@{ ResourceId = $ResourceId; MetricName = $Names; AggregationType = $AggregationType }
    $CallFile = Join-Path $env:RDA_TEST_METRIC_CALL_DIR ([guid]::NewGuid().ToString() + '.json')
    $Call | ConvertTo-Json -Compress | Set-Content -LiteralPath $CallFile -Encoding utf8

    # A Flex Consumption app rejects the two execution metrics.
    $AppName = ($ResourceId -split '/')[-1]
    if ($AppName -like 'fc1-*' -and @($Names | Where-Object { $_ -in @('FunctionExecutionCount', 'FunctionExecutionUnits') }).Count -gt 0)
    {
        throw "Operation returned an invalid status code 'BadRequest'"
    }

    foreach ($Name in $Names)
    {
        [PSCustomObject]@{
            Id   = $ResourceId + '/providers/Microsoft.Insights/metrics/' + $Name
            Name = [PSCustomObject]@{ Value = $Name; LocalizedValue = $Name }
            Data = @(for ($P = 0; $P -lt 3; $P++) { [PSCustomObject]@{ TimeStamp = $StartTime.AddDays($P); Total = [double](10 + $P) } })
        }
    }
}
Export-ModuleMember -Function Get-AzMetric
'@

    $script:OriginalModulePath = $env:PSModulePath
    $script:OriginalDebugLogFile = $Global:DebugLogFile
    $env:PSModulePath = $script:ModuleRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath

    # A hosting plan row as Resource Graph returns it. -Sku is passed as given, so
    # a test can hand in a malformed value.
    function New-TestPlan
    {
        param([string]$Name, $Sku)

        return [PSCustomObject]@{
            TYPE           = 'microsoft.web/serverfarms'
            id             = '{0}/Microsoft.Web/serverfarms/{1}' -f $script:RgPath, $Name
            subscriptionId = $script:SubscriptionId
            resourceGroup  = 'rg-func-test'
            name           = $Name
            location       = 'westeurope'
            kind           = 'functionapp'
            sku            = $Sku
            properties     = [PSCustomObject]@{}
        }
    }

    # A site row. -FarmId is passed as given (it can be a malformed value), and
    # -NoProperties leaves the properties bag off.
    function New-TestApp
    {
        param([string]$Name, $FarmId, [string]$Kind = 'functionapp,linux', [switch]$NoProperties)

        $Row = [ordered]@{
            TYPE           = 'microsoft.web/sites'
            id             = '{0}/Microsoft.Web/sites/{1}' -f $script:RgPath, $Name
            subscriptionId = $script:SubscriptionId
            resourceGroup  = 'rg-func-test'
            name           = $Name
            location       = 'westeurope'
            kind           = $Kind
        }
        if (-not $NoProperties) { $Row['properties'] = [PSCustomObject]@{ serverFarmId = $FarmId } }
        return [PSCustomObject]$Row
    }

    function Get-PlanId
    {
        param([string]$Name)
        return '{0}/Microsoft.Web/serverfarms/{1}' -f $script:RgPath, $Name
    }

    # Runs Metrics.ps1 against the stand-in module and returns the calls and the
    # records it wrote.
    function Invoke-MetricsRun
    {
        param([object[]]$Resources, [string]$RunName)

        $RunDir = Join-Path $TestDrive $RunName
        $CallDir = Join-Path $RunDir 'calls'
        New-Item -ItemType Directory -Path $CallDir -Force | Out-Null
        $env:RDA_TEST_METRIC_CALL_DIR = $CallDir
        $Global:DebugLogFile = Join-Path $RunDir 'debug.log'

        try
        {
            $null = & $script:MetricsScript -Subscriptions $script:Subscriptions -Resources $Resources -Task 'Processing' -ConcurrencyLimit 4 -FilePath (Join-Path $RunDir 'Metrics_test') -Obfuscate $false *>&1
        }
        finally
        {
            $Global:DebugLogFile = $script:OriginalDebugLogFile
        }

        $Records = @(Get-ChildItem -LiteralPath $RunDir -Filter 'Metrics_test_*.json' | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Metrics })
        return [PSCustomObject]@{
            Calls   = @(Get-ChildItem -LiteralPath $CallDir -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
            Records = $Records
        }
    }

    # The execution metric names asked for the named app, sorted.
    function Get-AskedMetricName
    {
        param($Run, [string]$AppName)
        return @($Run.Calls | Where-Object { $_.ResourceId.EndsWith('/' + $AppName) } | ForEach-Object { $_.MetricName } | Sort-Object)
    }
}

AfterAll {
    $env:PSModulePath = $script:OriginalModulePath
    $Global:DebugLogFile = $script:OriginalDebugLogFile
    Remove-Item -Path 'Env:RDA_TEST_METRIC_CALL_DIR' -ErrorAction SilentlyContinue
}

Describe 'Metrics.ps1 execution metrics for function apps on a Flex Consumption plan' {

    It 'does not ask a Flex Consumption app for the execution metrics and writes no error record for it' {
        $Resources = @(
            New-TestPlan -Name 'plan-flex' -Sku ([PSCustomObject]@{ name = 'FC1'; tier = 'FlexConsumption' })
            New-TestApp -Name 'fc1-app' -FarmId (Get-PlanId 'plan-flex')
        )
        $Run = Invoke-MetricsRun -Resources $Resources -RunName 'flex-only'

        @(Get-AskedMetricName -Run $Run -AppName 'fc1-app').Count | Should -Be 0
        @($Run.Records | Where-Object { $_.Name -eq 'fc1-app' }).Count | Should -Be 0
        @($Run.Records | Where-Object { $_.MetricError }).Count | Should -Be 0
    }

    It 'knows the plan by SKU name alone, by tier alone, in any letter case, and when the plan id case differs' {
        $Resources = @(
            New-TestPlan -Name 'plan-name-only' -Sku ([PSCustomObject]@{ name = 'fc1' })
            New-TestPlan -Name 'plan-tier-only' -Sku ([PSCustomObject]@{ tier = 'flexconsumption' })
            New-TestPlan -Name 'Plan-Mixed-Case' -Sku ([PSCustomObject]@{ name = 'FC1'; tier = 'FlexConsumption' })
            New-TestApp -Name 'fc1-by-name' -FarmId (Get-PlanId 'plan-name-only')
            New-TestApp -Name 'fc1-by-tier' -FarmId (Get-PlanId 'plan-tier-only')
            New-TestApp -Name 'fc1-other-case' -FarmId (Get-PlanId 'plan-mixed-case').ToUpperInvariant()
        )
        $Run = Invoke-MetricsRun -Resources $Resources -RunName 'flex-shapes'

        foreach ($App in 'fc1-by-name', 'fc1-by-tier', 'fc1-other-case')
        {
            @(Get-AskedMetricName -Run $Run -AppName $App).Count | Should -Be 0 -Because "$App is on a Flex Consumption plan"
        }
        @($Run.Records | Where-Object { $_.MetricError }).Count | Should -Be 0
    }

    It 'keeps both execution metrics, in one call, for function apps on other plans' {
        $Resources = @(
            New-TestPlan -Name 'plan-y1' -Sku ([PSCustomObject]@{ name = 'Y1'; tier = 'Dynamic' })
            New-TestPlan -Name 'plan-ep1' -Sku ([PSCustomObject]@{ name = 'EP1'; tier = 'ElasticPremium' })
            New-TestPlan -Name 'plan-b1' -Sku ([PSCustomObject]@{ name = 'B1'; tier = 'Basic' })
            New-TestApp -Name 'func-y1' -FarmId (Get-PlanId 'plan-y1') -Kind 'functionapp'
            New-TestApp -Name 'func-ep1' -FarmId (Get-PlanId 'plan-ep1')
            New-TestApp -Name 'func-b1' -FarmId (Get-PlanId 'plan-b1')
        )
        $Run = Invoke-MetricsRun -Resources $Resources -RunName 'other-plans'

        foreach ($App in 'func-y1', 'func-ep1', 'func-b1')
        {
            $AppCalls = @($Run.Calls | Where-Object { $_.ResourceId.EndsWith('/' + $App) })
            $AppCalls.Count | Should -Be 1 -Because "$App is asked once, as before"
            @($AppCalls[0].MetricName | Sort-Object) | Should -Be $script:ExecutionNames
            @($Run.Records | Where-Object { $_.Name -eq $App } | ForEach-Object { $_.Metric } | Sort-Object) | Should -Be $script:ExecutionNames
        }
    }

    It 'keeps both execution metrics when the plan cannot be read' {
        $Resources = @(
            # Plan row not in the inventory.
            New-TestApp -Name 'func-plan-missing' -FarmId (Get-PlanId 'plan-not-listed')
            # Plan row with no SKU, and with an empty SKU.
            New-TestPlan -Name 'plan-null-sku' -Sku $null
            New-TestApp -Name 'func-null-sku' -FarmId (Get-PlanId 'plan-null-sku')
            New-TestPlan -Name 'plan-empty-sku' -Sku ([PSCustomObject]@{ name = ''; tier = '' })
            New-TestApp -Name 'func-empty-sku' -FarmId (Get-PlanId 'plan-empty-sku')
            # No plan id on the site, and no properties at all.
            New-TestApp -Name 'func-no-farm' -FarmId $null
            New-TestApp -Name 'func-no-properties' -NoProperties
        )
        $Run = Invoke-MetricsRun -Resources $Resources -RunName 'plan-unreadable'

        foreach ($App in 'func-plan-missing', 'func-null-sku', 'func-empty-sku', 'func-no-farm', 'func-no-properties')
        {
            @(Get-AskedMetricName -Run $Run -AppName $App) | Should -Be $script:ExecutionNames -Because "$App has no readable plan, so it keeps today's metrics"
        }
    }

    It 'keeps both execution metrics when the plan SKU or the plan id is malformed' {
        $Resources = @(
            # SKU given as a bare string, not an object with name and tier.
            New-TestPlan -Name 'plan-string-sku' -Sku 'FC1'
            New-TestApp -Name 'func-string-sku' -FarmId (Get-PlanId 'plan-string-sku')
            # SKU name given as a list.
            New-TestPlan -Name 'plan-list-sku' -Sku ([PSCustomObject]@{ name = @('FC1', 'Y1') })
            New-TestApp -Name 'func-list-sku' -FarmId (Get-PlanId 'plan-list-sku')
            # Plan id given as a number and as a list.
            New-TestApp -Name 'func-number-farm' -FarmId 12345
            New-TestApp -Name 'func-list-farm' -FarmId @((Get-PlanId 'plan-string-sku'), (Get-PlanId 'plan-list-sku'))
        )
        $Run = Invoke-MetricsRun -Resources $Resources -RunName 'plan-malformed'

        foreach ($App in 'func-string-sku', 'func-list-sku', 'func-number-farm', 'func-list-farm')
        {
            @(Get-AskedMetricName -Run $Run -AppName $App) | Should -Be $script:ExecutionNames -Because "$App has a malformed plan value, so it keeps today's metrics"
        }
    }

    It 'leaves the other apps of a mixed estate as they were' {
        $Resources = @(
            New-TestPlan -Name 'plan-flex' -Sku ([PSCustomObject]@{ name = 'FC1'; tier = 'FlexConsumption' })
            New-TestPlan -Name 'plan-y1' -Sku ([PSCustomObject]@{ name = 'Y1'; tier = 'Dynamic' })
            New-TestApp -Name 'fc1-app-a' -FarmId (Get-PlanId 'plan-flex')
            New-TestApp -Name 'fc1-app-b' -FarmId (Get-PlanId 'plan-flex')
            New-TestApp -Name 'func-y1' -FarmId (Get-PlanId 'plan-y1') -Kind 'functionapp'
            New-TestApp -Name 'func-plan-missing' -FarmId (Get-PlanId 'plan-not-listed')
            # A web app on the Flex plan id is not a function app: no execution metrics, as before.
            New-TestApp -Name 'web-01' -FarmId (Get-PlanId 'plan-y1') -Kind 'app'
        )
        $Run = Invoke-MetricsRun -Resources $Resources -RunName 'mixed'

        @(Get-AskedMetricName -Run $Run -AppName 'fc1-app-a').Count | Should -Be 0
        @(Get-AskedMetricName -Run $Run -AppName 'fc1-app-b').Count | Should -Be 0
        @(Get-AskedMetricName -Run $Run -AppName 'func-y1') | Should -Be $script:ExecutionNames
        @(Get-AskedMetricName -Run $Run -AppName 'func-plan-missing') | Should -Be $script:ExecutionNames
        @(Get-AskedMetricName -Run $Run -AppName 'web-01').Count | Should -Be 0
        $Run.Records.Count | Should -Be 4
        @($Run.Records | Where-Object { $_.MetricError }).Count | Should -Be 0
    }
}
