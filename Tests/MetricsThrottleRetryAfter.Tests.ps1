# Requires -Modules Pester
# Offline coverage for the metrics throttle handling in Extension/Metrics.ps1:
# a 429 wave used to exhaust the 3 generic retries in ~14s (2s, 4s, 8s) and record the metric as
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
        # Old behaviour: 3 retries at 2 + 4 + 8 = 14 s of waiting (plus jitter), then Outcome = Throttled.
        # The bound below is twice that, so the new plan waits well past the old one.
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

Describe 'Test-MetricThrottled - the status code decides first' {
    BeforeAll {
        $Tokens = $null; $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseInput($script:MetricsSrc, [ref]$Tokens, [ref]$Errors)
        $FnAst = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Test-MetricThrottled' }, $true) | Select-Object -First 1
        if (-not $FnAst) { throw 'Test-MetricThrottled was not found in Extension/Metrics.ps1' }
        . ([scriptblock]::Create($FnAst.Extent.Text))

        function New-StatusException([string]$Message, $StatusCode, $Inner = $null)
        {
            $Ex = if ($Inner) { [System.Exception]::new($Message, $Inner) } else { [System.Exception]::new($Message) }
            $Ex | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{ StatusCode = $StatusCode })
            return $Ex
        }
    }

    It 'finds a wrapped 429 known only by its status code' {
        $Inner = New-StatusException 'The service asked the client to wait.' ([System.Net.HttpStatusCode]::TooManyRequests)
        Test-MetricThrottled -Exception ([System.Exception]::new('The operation failed.', $Inner)) | Should -BeTrue
    }

    It 'reads a numeric 429 status and a status on the exception itself' {
        Test-MetricThrottled -Exception (New-StatusException 'failed' 429) | Should -BeTrue
        Test-MetricThrottled -Exception ([System.Net.Http.HttpRequestException]::new('failed', $null, [System.Net.HttpStatusCode]::TooManyRequests)) | Should -BeTrue
    }

    It 'finds a 429 under an outer exception that reports another status' {
        $Inner = [System.Net.Http.HttpRequestException]::new('wait', $null, [System.Net.HttpStatusCode]::TooManyRequests)
        Test-MetricThrottled -Exception ([System.Net.Http.HttpRequestException]::new('The server failed.', $Inner, [System.Net.HttpStatusCode]::InternalServerError)) | Should -BeTrue
    }

    It 'finds a 429 on the ErrorRecord an exception carries' {
        $Status = [System.Net.Http.HttpRequestException]::new('wait', $null, [System.Net.HttpStatusCode]::TooManyRequests)
        $Record = [System.Management.Automation.ErrorRecord]::new($Status, 'x', 'NotSpecified', $null)
        $Outer = [System.Management.Automation.RuntimeException]::new('The operation failed.', $null, $Record)
        Test-MetricThrottled -Exception $Outer | Should -BeTrue
    }

    It 'does not treat a 403 as throttled when its message holds 429 or throttl in an id' {
        $Ex = [System.Net.Http.HttpRequestException]::new("No authorization over scope '/subscriptions/00000000-0000-0000-0000-000000004290/resourceGroups/rg-throttle-test'.", $null, [System.Net.HttpStatusCode]::Forbidden)
        Test-MetricThrottled -Exception $Ex | Should -BeFalse
    }

    It 'does not treat a wrapped 403 as throttled when the outer message names 429' {
        $Inner = New-StatusException 'denied' ([System.Net.HttpStatusCode]::Forbidden)
        Test-MetricThrottled -Exception ([System.Exception]::new('Request for vm-429 failed.', $Inner)) | Should -BeFalse
    }

    It 'matches the message only when no exception in the chain carries a status' {
        Test-MetricThrottled -Exception ([System.Exception]::new("Operation returned an invalid status code 'TooManyRequests'")) | Should -BeTrue
        Test-MetricThrottled -Exception ([System.Exception]::new('Rate limit reached, try later.')) | Should -BeTrue
        Test-MetricThrottled -Exception ([System.Exception]::new("Operation returned an invalid status code 'InternalServerError'")) | Should -BeFalse
    }

    It 'does not read 429 or throttle inside a name in a message with no status as throttled' {
        Test-MetricThrottled -Exception ([System.Exception]::new("Resource '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-429/providers/Microsoft.Compute/virtualMachines/vm1' was not found.")) | Should -BeFalse
        Test-MetricThrottled -Exception ([System.Exception]::new("Resource group 'rg-throttle-test' could not be found.")) | Should -BeFalse
        Test-MetricThrottled -Exception ([System.Exception]::new("Resource group 'rg-throttled-test' could not be found.")) | Should -BeFalse
        Test-MetricThrottled -Exception ([System.Exception]::new("Resource group 'rg-TooManyRequests' could not be found.")) | Should -BeFalse
    }

    It 'still reads the real throttling phrases in a message with no status' {
        Test-MetricThrottled -Exception ([System.Exception]::new('Operation returned an invalid status code TooManyRequests')) | Should -BeTrue
        Test-MetricThrottled -Exception ([System.Exception]::new('Service request failed. Status: 429 (Too Many Requests)')) | Should -BeTrue
        Test-MetricThrottled -Exception ([System.Exception]::new('Response status code does not indicate success: 429.')) | Should -BeTrue
        Test-MetricThrottled -Exception ([System.Exception]::new('HTTP 429 returned.')) | Should -BeTrue
        Test-MetricThrottled -Exception ([System.Exception]::new('The request is being throttled.')) | Should -BeTrue
        Test-MetricThrottled -Exception ([System.Exception]::new('Request was throttled, retry later.')) | Should -BeTrue
    }

    It 'the retry loop asks it, not a message match, whether an answer was throttled' {
        $script:MetricsSrc | Should -Match 'if \(Test-MetricThrottled -Exception \$_\.Exception\)'
        $script:MetricsSrc | Should -Not -Match '\$LastError -match ''429'
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

    It 'the comments give the old throttled backoff as 2 + 4 + 8 = 14 s' {
        # The old loop counted attempts from 0, so its throttled waits were 2^0, 2^1 and 2^2, doubled.
        $TestSrc = Get-Content -LiteralPath $PSCommandPath -Raw
        foreach ($Src in @($script:MetricsSrc, $TestSrc))
        {
            # The character class keeps this line from matching itself.
            $Src | Should -Not -Match '~2[8]s'
            $Src | Should -Not -Match '4s?\+8s?\+16s?'
        }
        $script:MetricsSrc | Should -Match '(?m)^\s*# .*3 generic retries in ~14s'
    }

    It 'the retry loop has an explicit exit when the budget is exhausted (the while is no longer bounded by attempts)' {
        $script:MetricsSrc | Should -Match '(?s)while \(-not \$Succeeded\)\s*\{.*?Budget exhausted.*?break'
    }
}
