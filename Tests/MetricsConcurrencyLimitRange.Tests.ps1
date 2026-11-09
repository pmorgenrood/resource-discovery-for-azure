# Requires -Modules Pester
# =============================================================================
# MetricsConcurrencyLimitRange.Tests.ps1
#
# -ConcurrencyLimit becomes ForEach-Object -ThrottleLimit in Extension/Metrics.ps1.
# A limit of 0, a negative one or one that is not a number makes that call fail
# with an error that does not stop the script, so the run wrote a Metrics file
# with no records and reported no failure. Each script that takes the limit
# must refuse such a value when its parameters are bound.
#
# The three wrapper scripts are checked by binding a copy of their own param
# block, so none of their body (sign-in, Azure calls) ever runs. Metrics.ps1 is
# run in a fresh process with a stand-in Az.Monitor module.
#
# No live Azure. Run with:
#   Invoke-Pester ./Tests/MetricsConcurrencyLimitRange.Tests.ps1 -Output Detailed
# =============================================================================

BeforeDiscovery {
    $script:LimitScripts = @(
        @{ Script = 'ResourceInventory.ps1' }
        @{ Script = 'Run-AllSubscriptions.ps1' }
        @{ Script = 'Run-AllSubscriptions.Stream.ps1' }
        @{ Script = 'Extension/Metrics.ps1' }
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:PwshPath = (Get-Process -Id $PID).Path

    # Builds a script block from the script's own -ConcurrencyLimit parameter, as
    # written, that returns the bound value. The other parameters (some of them
    # mandatory) are left out, and the script body never runs.
    function Get-LimitBinder
    {
        param([string]$Script)

        $Path = Join-Path $script:RepoRoot $Script
        $Tokens = $null
        $ParseErrors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors)
        if ($ParseErrors.Count -gt 0) { throw "Parse errors in $Script" }
        $Param = @($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ConcurrencyLimit' })
        if ($Param.Count -ne 1) { throw "No single -ConcurrencyLimit parameter in $Script" }
        return [scriptblock]::Create('param(' + $Param[0].Extent.Text + ') $ConcurrencyLimit')
    }
}

Describe '-ConcurrencyLimit is refused at binding when it is not a positive number' {

    It '<Script> refuses 0' -TestCases $script:LimitScripts {
        param($Script)
        $Binder = Get-LimitBinder -Script $Script
        { & $Binder -ConcurrencyLimit 0 } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It '<Script> refuses -1' -TestCases $script:LimitScripts {
        param($Script)
        $Binder = Get-LimitBinder -Script $Script
        { & $Binder -ConcurrencyLimit -1 } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It '<Script> refuses a limit that is not a number' -TestCases $script:LimitScripts {
        param($Script)
        $Binder = Get-LimitBinder -Script $Script
        { & $Binder -ConcurrencyLimit 'many' } | Should -Throw
    }

    It '<Script> still takes 1 and a number given as text' -TestCases $script:LimitScripts {
        param($Script)
        $Binder = Get-LimitBinder -Script $Script
        & $Binder -ConcurrencyLimit 1 | Should -Be 1
        & $Binder -ConcurrencyLimit '8' | Should -Be 8
    }
}

Describe '-ConcurrencyLimit keeps its default of 6' {

    It '<Script> defaults to 6' -TestCases @(
        @{ Script = 'ResourceInventory.ps1' }
        @{ Script = 'Run-AllSubscriptions.ps1' }
        @{ Script = 'Run-AllSubscriptions.Stream.ps1' }
    ) {
        param($Script)
        $Binder = Get-LimitBinder -Script $Script
        & $Binder | Should -Be 6
    }
}

Describe 'Metrics.ps1 with -ConcurrencyLimit 0' {

    BeforeAll {
        $ModuleRoot = Join-Path $TestDrive 'modules'
        $FakeModuleDir = Join-Path $ModuleRoot 'Az.Monitor'
        New-Item -ItemType Directory -Path $FakeModuleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $FakeModuleDir 'Az.Monitor.psm1') -Encoding utf8 -Value @'
function Get-AzMetric
{
    [CmdletBinding()]
    param([string]$ResourceId, [string[]]$MetricName, [datetime]$StartTime, [datetime]$EndTime, [timespan]$TimeGrain, [string]$AggregationType, $DefaultProfile)
    foreach ($Name in @($MetricName))
    {
        [PSCustomObject]@{
            Id   = $ResourceId + '/providers/Microsoft.Insights/metrics/' + $Name
            Name = [PSCustomObject]@{ Value = $Name; LocalizedValue = $Name }
            Data = @([PSCustomObject]@{ TimeStamp = $StartTime; Average = 1.0; Maximum = 1.0; Minimum = 1.0; Total = 1.0; Count = 1.0 })
        }
    }
}
Export-ModuleMember -Function Get-AzMetric
'@

        $Runner = Join-Path $TestDrive 'run-metrics-zero.ps1'
        Set-Content -LiteralPath $Runner -Encoding utf8 -Value @'
param([string]$MetricsScript, [string]$CommonFunctions, [string]$ModuleRoot, [string]$OutDir)

$env:PSModulePath = $ModuleRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
. $CommonFunctions
function Get-AzContext { return $null }
$Global:DebugLogFile = Join-Path $OutDir 'debug.log'
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'SilentlyContinue'

$SubscriptionId = '12345678-1234-1234-1234-123456789012'
$VmId = '/subscriptions/{0}/resourceGroups/rg-limit/providers/Microsoft.Compute/virtualMachines/vm-owner' -f $SubscriptionId
$Resources = @([PSCustomObject]@{
        TYPE           = 'microsoft.compute/disks'
        Id             = '/subscriptions/{0}/resourceGroups/rg-limit/providers/Microsoft.Compute/disks/disk-01' -f $SubscriptionId
        subscriptionId = $SubscriptionId
        ResourceGroup  = 'rg-limit'
        Name           = 'disk-01'
        Location       = 'westeurope'
        ManagedBy      = $VmId
    })

# Called the way ResourceInventory.ps1 calls it: no try, errors silenced.
$Error.Clear()
$null = & $MetricsScript -Subscriptions @([PSCustomObject]@{ id = $SubscriptionId; Name = 'test-subscription' }) -Resources $Resources -Task 'Processing' -ConcurrencyLimit 0 -FilePath (Join-Path $OutDir 'Metrics_test') -Obfuscate $false *>&1

$Binding = @($Error | Where-Object {
        $_.FullyQualifiedErrorId -like 'ParameterArgumentValidationError*' -and
        $_.InvocationInfo.MyCommand.Name -eq 'Metrics.ps1'
    })
[PSCustomObject]@{ RunError = $(if ($Binding.Count -gt 0) { $Binding[0].FullyQualifiedErrorId } else { '' }) } | ConvertTo-Json -Compress
'@

        $script:ZeroOutDir = Join-Path $TestDrive 'limit-0'
        New-Item -ItemType Directory -Path $script:ZeroOutDir -Force | Out-Null
        $Output = & $script:PwshPath -NoProfile -NonInteractive -File $Runner -MetricsScript (Join-Path $script:RepoRoot 'Extension/Metrics.ps1') -CommonFunctions (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1') -ModuleRoot $ModuleRoot -OutDir $script:ZeroOutDir 2>&1
        $Json = @($Output | ForEach-Object { [string]$_ } | Where-Object { $_ -like '{*"RunError"*' }) | Select-Object -Last 1
        if (-not $Json) { throw ("The metrics run printed no result: {0}" -f (($Output | ForEach-Object { [string]$_ }) -join ' | ')) }
        $script:ZeroResult = $Json | ConvertFrom-Json
    }

    It 'stops at the binding of Metrics.ps1 itself' {
        $script:ZeroResult.RunError | Should -BeLike 'ParameterArgumentValidationError*'
    }

    It 'writes no Metrics file' {
        @(Get-ChildItem -Path $script:ZeroOutDir -Filter 'Metrics_test*.json' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}
