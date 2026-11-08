# Requires -Modules Pester
# =============================================================================
# MetricsConcurrency.Tests.ps1
#
# Extension/Metrics.ps1 runs its metric groups with ForEach-Object -Parallel
# -ThrottleLimit $ConcurrencyLimit, and each Get-AzMetric call inside runs in a
# Start-ThreadJob job so it can be timed out. Start-ThreadJob has a throttle of
# its own (5 by default) that holds for the whole process, so without passing
# the run's limit to it no more than 5 calls were in flight whatever
# -ConcurrencyLimit said. These tests count the Get-AzMetric calls in flight at
# once and check the peak follows -ConcurrencyLimit at 1, at the default of 6
# and at 16.
#
# The Start-ThreadJob throttle is process-wide, so each run is a fresh pwsh
# process: one run's limit cannot leak into the next. The stand-in Az.Monitor
# module waits a while in every call and counts calls in flight in a static
# counter shared by all runspaces of the process.
#
# No live Azure. Run with:
#   Invoke-Pester ./Tests/MetricsConcurrency.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:MetricsScript = Join-Path $script:RepoRoot 'Extension/Metrics.ps1'
    if (-not (Test-Path $script:MetricsScript)) { throw "Metrics.ps1 not found at $script:MetricsScript" }
    $script:PwshPath = (Get-Process -Id $PID).Path

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

    [RdaInFlightProbe]::Enter()
    try
    {
        Start-Sleep -Milliseconds ([int]$env:RDA_TEST_CALL_MS)
    }
    finally
    {
        [RdaInFlightProbe]::Leave()
    }

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

    # Runs Metrics.ps1 once in a fresh process with the given -ConcurrencyLimit
    # over $DiskCount attached disks (one Get-AzMetric call each) and prints the
    # peak number of calls in flight and the number of calls made.
    $script:Runner = Join-Path $TestDrive 'run-metrics.ps1'
    Set-Content -LiteralPath $script:Runner -Encoding utf8 -Value @'
param([string]$MetricsScript, [string]$CommonFunctions, [string]$ModuleRoot, [string]$OutDir, $ConcurrencyLimit, [int]$DiskCount)

Add-Type -TypeDefinition @"
public static class RdaInFlightProbe
{
    private static int current;
    private static int peak;
    private static int calls;
    public static void Enter()
    {
        System.Threading.Interlocked.Increment(ref calls);
        int now = System.Threading.Interlocked.Increment(ref current);
        int seen;
        while (now > (seen = System.Threading.Volatile.Read(ref peak)))
        {
            if (System.Threading.Interlocked.CompareExchange(ref peak, now, seen) == seen) { break; }
        }
    }
    public static void Leave() { System.Threading.Interlocked.Decrement(ref current); }
    public static int Peak { get { return System.Threading.Volatile.Read(ref peak); } }
    public static int Calls { get { return System.Threading.Volatile.Read(ref calls); } }
}
"@

$env:PSModulePath = $ModuleRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
. $CommonFunctions
function Get-AzContext { return $null }
$Global:DebugLogFile = Join-Path $OutDir 'debug.log'
$ProgressPreference = 'SilentlyContinue'

$SubscriptionId = '12345678-1234-1234-1234-123456789012'
$VmId = '/subscriptions/{0}/resourceGroups/rg-concurrency/providers/Microsoft.Compute/virtualMachines/vm-owner' -f $SubscriptionId
$Resources = for ($D = 1; $D -le $DiskCount; $D++)
{
    [PSCustomObject]@{
        TYPE           = 'microsoft.compute/disks'
        Id             = '/subscriptions/{0}/resourceGroups/rg-concurrency/providers/Microsoft.Compute/disks/disk-{1:d2}' -f $SubscriptionId, $D
        subscriptionId = $SubscriptionId
        ResourceGroup  = 'rg-concurrency'
        Name           = 'disk-{0:d2}' -f $D
        Location       = 'westeurope'
        ManagedBy      = $VmId
    }
}

$RunError = ''
try
{
    $null = & $MetricsScript -Subscriptions @([PSCustomObject]@{ id = $SubscriptionId; Name = 'test-subscription' }) -Resources $Resources -Task 'Processing' -ConcurrencyLimit $ConcurrencyLimit -FilePath (Join-Path $OutDir 'Metrics_test') -Obfuscate $false *>&1
}
catch
{
    $RunError = $_.Exception.Message
}

[PSCustomObject]@{ Peak = [RdaInFlightProbe]::Peak; Calls = [RdaInFlightProbe]::Calls; Error = $RunError } | ConvertTo-Json -Compress
'@

    function Invoke-ConcurrencyRun
    {
        param([string]$RunName, $ConcurrencyLimit, [int]$DiskCount, [int]$CallMs = 1500)

        $OutDir = Join-Path $TestDrive $RunName
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
        $env:RDA_TEST_CALL_MS = [string]$CallMs
        try
        {
            $Output = & $script:PwshPath -NoProfile -NonInteractive -File $script:Runner -MetricsScript $script:MetricsScript -CommonFunctions (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1') -ModuleRoot $script:ModuleRoot -OutDir $OutDir -ConcurrencyLimit $ConcurrencyLimit -DiskCount $DiskCount 2>&1
        }
        finally
        {
            Remove-Item -Path 'Env:RDA_TEST_CALL_MS' -ErrorAction SilentlyContinue
        }
        $Json = @($Output | ForEach-Object { [string]$_ } | Where-Object { $_ -like '{*"Peak"*' }) | Select-Object -Last 1
        if (-not $Json) { throw ("The metrics run printed no result: {0}" -f (($Output | ForEach-Object { [string]$_ }) -join ' | ')) }
        return ($Json | ConvertFrom-Json)
    }
}

Describe 'Metrics.ps1 metric calls in flight follow -ConcurrencyLimit' {

    It 'runs one call at a time with -ConcurrencyLimit 1' {
        $Result = Invoke-ConcurrencyRun -RunName 'limit-1' -ConcurrencyLimit 1 -DiskCount 6 -CallMs 500
        $Result.Calls | Should -Be 6
        $Result.Peak | Should -Be 1
    }

    It 'runs 6 calls at once with the default -ConcurrencyLimit 6' {
        $Result = Invoke-ConcurrencyRun -RunName 'limit-6' -ConcurrencyLimit 6 -DiskCount 12
        $Result.Calls | Should -Be 12
        $Result.Peak | Should -Be 6
    }

    It 'runs 16 calls at once with -ConcurrencyLimit 16' {
        $Result = Invoke-ConcurrencyRun -RunName 'limit-16' -ConcurrencyLimit 16 -DiskCount 32
        $Result.Calls | Should -Be 32
        $Result.Peak | Should -Be 16
    }

    It 'reads a limit given as text the same as the number' {
        $Result = Invoke-ConcurrencyRun -RunName 'limit-text-8' -ConcurrencyLimit '8' -DiskCount 16
        $Result.Calls | Should -Be 16
        $Result.Peak | Should -Be 8
    }

    It 'makes no metric call when the limit is not a number' {
        $Result = Invoke-ConcurrencyRun -RunName 'limit-malformed' -ConcurrencyLimit 'many' -DiskCount 4 -CallMs 100
        $Result.Calls | Should -Be 0
    }
}
