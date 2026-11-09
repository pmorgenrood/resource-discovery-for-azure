# Requires -Modules Pester
# Offline coverage for the metrics throttle handling in Extension/Metrics.ps1:
# a 429 wave used to exhaust the 3 generic retries in ~28s (4s+8s+16s) and record the metric as
# Throttled/failed, ignoring the server's Retry-After. Get-RdaMetricRetryPlan now gives throttled
# attempts their own budget and waits at least Retry-After (bounded). Extracted by AST like
# MetricsErrorBodyCapture.Tests.ps1 does, because the function lives inside the -Parallel block.

BeforeAll {
    $Repo = Split-Path $PSScriptRoot -Parent
    $script:MetricsSrc = Get-Content -LiteralPath (Join-Path $Repo 'Extension/Metrics.ps1') -Raw
    $Tokens = $null; $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseInput($script:MetricsSrc, [ref]$Tokens, [ref]$Errors)
    $FnAst = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-RdaMetricRetryPlan' }, $true) | Select-Object -First 1
    if (-not $FnAst) { throw 'Get-RdaMetricRetryPlan was not found in Extension/Metrics.ps1' }
    . ([scriptblock]::Create($FnAst.Extent.Text))

    # Production defaults, read from the source so the test tracks them.
    $script:MaxRetries = [int]([regex]::Match($script:MetricsSrc, '(?m)^\s*\$MetricMaxRetries\s*=\s*(\d+)').Groups[1].Value)
    $script:MaxThrottle = [int]([regex]::Match($script:MetricsSrc, '(?m)^\s*\$MetricMaxThrottleRetries\s*=\s*(\d+)').Groups[1].Value)
    $script:MaxRetryAfter = [double]([regex]::Match($script:MetricsSrc, '(?m)^\s*\$MetricMaxRetryAfterSeconds\s*=\s*(\d+)').Groups[1].Value)
    $script:MaxThrottleWait = [double]([regex]::Match($script:MetricsSrc, '(?m)^\s*\$MetricMaxThrottleWaitSeconds\s*=\s*(\d+)').Groups[1].Value)

    function Plan([hashtable]$Over)
    {
        $P = @{ GenericFailures = 0; Throttled = $false; ThrottledAttempts = 0; RetryAfterSeconds = 0; MaxRetries = $script:MaxRetries; MaxThrottleRetries = $script:MaxThrottle; MaxRetryAfterSeconds = $script:MaxRetryAfter; ThrottleWaitedSeconds = 0; MaxThrottleWaitSeconds = $script:MaxThrottleWait; Jitter = 0 }
        foreach ($K in $Over.Keys) { $P[$K] = $Over[$K] }
        Get-RdaMetricRetryPlan @P
    }

    # The shipped Retry-After reader, exactly as the runspace receives it.
    . (Join-Path $Repo 'Functions/ResourceInventory.Functions.ps1')
    $script:RealTypesAvailable = $true
    try { Import-Module Az.Monitor -ErrorAction Stop; $null = [Microsoft.Rest.Azure.CloudException]; $null = [Microsoft.Rest.HttpResponseMessageWrapper] }
    catch { $script:RealTypesAvailable = $false }
    function New-ThrottleRecord([string]$RetryAfter)
    {
        $Msg = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
        $null = $Msg.Headers.TryAddWithoutValidation('Retry-After', $RetryAfter)
        $Ex = [Microsoft.Rest.Azure.CloudException]::new('Operation returned an invalid status code ''TooManyRequests''')
        $Ex.Response = [Microsoft.Rest.HttpResponseMessageWrapper]::new($Msg, 'throttled')
        return [System.Management.Automation.ErrorRecord]::new($Ex, 'Throttled', 'LimitsExceeded', $null)
    }
}

Describe 'Get-RdaMetricRetryPlan - production defaults' {
    It 'reads sane defaults from the source' {
        $script:MaxRetries | Should -Be 3
        $script:MaxThrottle | Should -BeGreaterOrEqual 6
        $script:MaxRetryAfter | Should -BeGreaterOrEqual 60
        $script:MaxThrottleWait | Should -Be 300
    }
}

Describe 'Get-RdaMetricRetryPlan - throttled attempts' {
    It 'waits at least the server-directed Retry-After when it exceeds the backoff' {
        $P = Plan @{ Throttled = $true; ThrottledAttempts = 1; RetryAfterSeconds = 45 }
        $P.Retry | Should -BeTrue
        $P.SleepSeconds | Should -Be 45
    }

    It 'keeps the throttled backoff (2x, capped) when Retry-After is shorter than it' {
        $P = Plan @{ Throttled = $true; ThrottledAttempts = 4; RetryAfterSeconds = 2 }
        $P.SleepSeconds | Should -Be 16 -Because '2^(4-1) = 8, doubled for throttling = 16, above the 2s the server asked'
    }

    It 'bounds an absurd Retry-After to the configured maximum' {
        (Plan @{ Throttled = $true; ThrottledAttempts = 1; RetryAfterSeconds = 3600 }).SleepSeconds | Should -Be $script:MaxRetryAfter
    }

    It 'falls back to its own backoff when no Retry-After was supplied' {
        (Plan @{ Throttled = $true; ThrottledAttempts = 2; RetryAfterSeconds = 0 }).SleepSeconds | Should -Be 4
    }

    It 'does not spend the generic budget: keeps retrying past MaxRetries while throttled' {
        $P = Plan @{ GenericFailures = $script:MaxRetries + 1; Throttled = $true; ThrottledAttempts = $script:MaxThrottle; RetryAfterSeconds = 5 }
        $P.Retry | Should -BeTrue
    }

    It 'gives up once the throttle budget is exhausted' {
        (Plan @{ Throttled = $true; ThrottledAttempts = $script:MaxThrottle + 1 }).Retry | Should -BeFalse
    }

    It 'stops retrying a throttled request once the next sleep would pass the total wait cap' {
        (Plan @{ Throttled = $true; ThrottledAttempts = 3; RetryAfterSeconds = 120; ThrottleWaitedSeconds = 180 }).Retry | Should -BeTrue -Because '180 + 120 = 300 does not pass the cap'
        (Plan @{ Throttled = $true; ThrottledAttempts = 3; RetryAfterSeconds = 120; ThrottleWaitedSeconds = 240 }).Retry | Should -BeFalse -Because '240 + 120 = 360 passes the cap'
    }

    It 'counts the jitter toward the total wait cap and returns it in the sleep' {
        $P = Plan @{ Throttled = $true; ThrottledAttempts = 1; RetryAfterSeconds = 10; Jitter = 0.25 }
        $P.SleepSeconds | Should -Be 10.25
        (Plan @{ Throttled = $true; ThrottledAttempts = 3; RetryAfterSeconds = 120; ThrottleWaitedSeconds = 180; Jitter = 0.5 }).Retry | Should -BeFalse
    }

    It 'the cap does not limit generic failures' {
        (Plan @{ GenericFailures = 1; ThrottleWaitedSeconds = 1000 }).Retry | Should -BeTrue
    }

    It 'a sustained 429 wave now waits out the directed delay instead of failing inside 30 seconds' {
        # Old behaviour: 3 retries at 4+8+16 = 28s of waiting, then Outcome = Throttled.
        $Total = 0
        for ($i = 1; $i -le $script:MaxThrottle; $i++) { $Total += (Plan @{ Throttled = $true; ThrottledAttempts = $i; RetryAfterSeconds = 20 }).SleepSeconds }
        $Total | Should -BeGreaterThan 28
    }
}

Describe 'Get-RdaMetricRetryPlan - unchanged behaviour for other failures' {
    It 'generic failures use 2^(failures-1) capped at 30 and stop after MaxRetries' {
        (Plan @{ GenericFailures = 1 }).SleepSeconds | Should -Be 1
        (Plan @{ GenericFailures = 3 }).SleepSeconds | Should -Be 4
        (Plan @{ GenericFailures = 7; MaxRetries = 10 }).SleepSeconds | Should -Be 30
        (Plan @{ GenericFailures = $script:MaxRetries }).Retry | Should -BeTrue
        (Plan @{ GenericFailures = $script:MaxRetries + 1 }).Retry | Should -BeFalse
    }
}

Describe 'Get-RdaMetricRetryPlan - throttled and generic failures keep separate budgets' {
    It 'a generic failure after 3 throttled answers still retries, with the first generic backoff' {
        $P = Plan @{ GenericFailures = 1; ThrottledAttempts = 3 }
        $P.Retry | Should -BeTrue
        $P.SleepSeconds | Should -Be 1
    }

    It 'throttled answers after 3 generic failures still get the whole throttle budget' {
        $P = Plan @{ GenericFailures = $script:MaxRetries; Throttled = $true; ThrottledAttempts = 1 }
        $P.Retry | Should -BeTrue
        $P.SleepSeconds | Should -Be 2
        (Plan @{ GenericFailures = $script:MaxRetries; Throttled = $true; ThrottledAttempts = $script:MaxThrottle }).Retry | Should -BeTrue
    }

    It 'the retry loop counts generic failures on their own and passes that count to the plan' {
        $script:MetricsSrc | Should -Match 'if \(-not \$Throttled\) \{ \$GenericFailures\+\+ \}'
        $script:MetricsSrc | Should -Match 'Get-RdaMetricRetryPlan -GenericFailures \$GenericFailures -Throttled \$Throttled'
    }

    It 'has no Permanent parameter: a BadRequest leaves the loop before the plan is asked' {
        (Get-Command Get-RdaMetricRetryPlan).Parameters.Keys | Should -Not -Contain 'Permanent'
        $script:MetricsSrc | Should -Not -Match '-Permanent \$'
    }
}

Describe 'Get-RdaRetryAfterSeconds - offline' {
    BeforeAll {
        # An exception-like object with Response.Headers, as the Az cmdlets expose it, built without Az.
        function New-FakeThrottle([hashtable]$Headers, $Inner = $null)
        {
            return [PSCustomObject]@{
                Message        = 'Operation returned an invalid status code ''TooManyRequests'''
                Response       = [PSCustomObject]@{ Headers = $Headers }
                InnerException = $Inner
            }
        }
    }

    It 'reads delta seconds' {
        Get-RdaRetryAfterSeconds -ErrorRecord (New-FakeThrottle @{ 'Retry-After' = @('17') }) | Should -Be 17
    }

    It 'reads an HTTP-date as the seconds until that time' {
        $When = [datetimeoffset]::UtcNow.AddSeconds(30).ToString('r', [System.Globalization.CultureInfo]::InvariantCulture)
        $Seconds = Get-RdaRetryAfterSeconds -ErrorRecord (New-FakeThrottle @{ 'Retry-After' = @($When) })
        $Seconds | Should -BeGreaterOrEqual 28
        $Seconds | Should -BeLessOrEqual 31
    }

    It 'gives 0 for an HTTP-date in the past' {
        $When = [datetimeoffset]::UtcNow.AddMinutes(-5).ToString('r', [System.Globalization.CultureInfo]::InvariantCulture)
        Get-RdaRetryAfterSeconds -ErrorRecord (New-FakeThrottle @{ 'Retry-After' = @($When) }) | Should -Be 0
    }

    It 'matches a lower-case header name' {
        $Headers = [System.Collections.Generic.Dictionary[string, string[]]]::new([System.StringComparer]::Ordinal)
        $Headers['retry-after'] = @('9')
        Get-RdaRetryAfterSeconds -ErrorRecord (New-FakeThrottle $Headers) | Should -Be 9
    }

    It 'finds the header on a nested InnerException' {
        $Outer = [PSCustomObject]@{ Message = 'wrapper'; InnerException = [PSCustomObject]@{ Message = 'still a wrapper'; InnerException = (New-FakeThrottle @{ 'Retry-After' = @('12') }) } }
        Get-RdaRetryAfterSeconds -ErrorRecord $Outer | Should -Be 12
    }

    It 'gives 0 for junk text' {
        Get-RdaRetryAfterSeconds -ErrorRecord (New-FakeThrottle @{ 'Retry-After' = @('soon, maybe') }) | Should -Be 0
    }

    It 'gives 0 for a negative value' {
        Get-RdaRetryAfterSeconds -ErrorRecord (New-FakeThrottle @{ 'Retry-After' = @('-5') }) | Should -Be 0
    }

    It 'gives 0 when there is no response at all' {
        Get-RdaRetryAfterSeconds -ErrorRecord ([System.Management.Automation.ErrorRecord]::new([System.Exception]::new('TooManyRequests'), 'x', 'NotSpecified', $null)) | Should -Be 0
    }
}

Describe 'Retry-After reaches the runspace' {
    It 'Get-RdaRetryAfterSeconds reads the header from a real TooManyRequests CloudException' {
        if (-not $script:RealTypesAvailable) { Set-ItResult -Skipped -Because 'Az.Monitor (Microsoft.Rest types) is not installed here' }
        Get-RdaRetryAfterSeconds -ErrorRecord (New-ThrottleRecord '17') | Should -Be 17
    }

    It 'Metrics.ps1 ships the helper definition into the -Parallel runspaces and calls the plan from the retry loop' {
        $script:MetricsSrc | Should -Match '\$MetricRetryAfterFnDef\s*=.*\$\{function:Get-RdaRetryAfterSeconds\}'
        $script:MetricsSrc | Should -Match 'Set-Item -Path function:Get-RdaRetryAfterSeconds'
        $script:MetricsSrc | Should -Match 'Get-RdaRetryAfterSeconds -ErrorRecord \$_'
            }

    It 'the comments describe the real callers and retry policies' {
        $FunctionsSrc = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1') -Raw
        # The reader serves the Azure Monitor retry loop.
        $FunctionsSrc | Should -Match '(?m)^# .*Azure Monitor.*\r?\n(# .*\r?\n)*function Get-RdaRetryAfterSeconds'
        # The Resource Graph retry no longer matches the Get-AzMetric loop, which now has its own throttle budget.
        $FunctionsSrc | Should -Not -Match 'Mirrors the Get-AzMetric wrapper'
    }

    It 'the retry loop has an explicit exit when the budget is exhausted (the while is no longer bounded by attempts)' {
        $script:MetricsSrc | Should -Match '(?s)while \(-not \$Succeeded\)\s*\{.*?Budget exhausted.*?break'
    }
}
