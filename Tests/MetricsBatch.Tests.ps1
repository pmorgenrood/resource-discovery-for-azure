# Requires -Modules Pester
# =============================================================================
# MetricsBatch.Tests.ps1
#
# Tests for -UseMetricsBatch in Extension/Metrics.ps1 (the Azure Monitor batch
# API, metrics:getBatch) and for the Microsoft.Insights provider preflight in
# Functions/Common.Functions.ps1:
#   - work items: grouped by subscription, region, namespace, metric names,
#     time window, time grain and aggregation, at most 50 resources each;
#     what the batch call cannot express keeps the per-resource path;
#   - the switch off: no batch request, no provider read, no token;
#   - the records are the same as the per-resource path's on the same data,
#     with and without -Obfuscate;
#   - answers map back to resources whatever the case of the returned id;
#   - a metric with an errorCode other than Success, a resource missing from
#     the answer, a failed request and a refused request (403) all fall back
#     to the per-resource path, never dropped;
#   - a subscription where Microsoft.Insights is not registered is not batched;
#   - the preflight registers only on a "y", says what to run otherwise, and
#     waits on one bounded deadline.
#
# The batch requests run inside ForEach-Object -Parallel runspaces, which
# Pester mocks do not reach, so the batch endpoint is a local HttpListener
# (Metrics.ps1's internal -MetricsBatchEndpointFormat points at it). It writes
# every request to a file and answers from the same deterministic data as the
# stand-in Get-AzMetric, so the two paths can be compared record by record. It
# answers the way the live API does (seen on the sandbox, 2026-11-05): no
# errorCode on an answered metric, and only the asked aggregation in a point.
#
# No live Azure. Run with:
#   Invoke-Pester ./Tests/MetricsBatch.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:MetricsScript = Join-Path $script:RepoRoot 'Extension/Metrics.ps1'
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    $script:SubscriptionId = '12345678-1234-1234-1234-123456789012'
    $script:OtherSubscriptionId = '87654321-4321-4321-4321-210987654321'
    $script:TenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $script:Subscriptions = @(
        [PSCustomObject]@{ id = $script:SubscriptionId; Name = 'test-subscription'; tenantId = $script:TenantId },
        [PSCustomObject]@{ id = $script:OtherSubscriptionId; Name = 'other-subscription'; tenantId = $script:TenantId }
    )

    # The data both paths return for a resource id and metric name: 30 points,
    # every 7th one without a value. Seeded on the lower-case id, since the
    # batch body carries ids in lower case. Some values are whole numbers, which
    # JSON carries without a fraction.
    $script:PointSource = @'
function Get-TestPoints([string]$ResourceId, [string]$Name)
{
    $Seed = 0
    foreach ($Char in ($ResourceId.ToLowerInvariant() + '|' + $Name).ToCharArray()) { $Seed = ($Seed * 31 + [int]$Char) % 100003 }
    for ($P = 0; $P -lt 30; $P++)
    {
        $Value = if ($P % 7 -eq 3) { $null } else { [double](($Seed + $P * 37) % 1000) / 10 }
        [ordered]@{
            Average = $Value
            Minimum = if ($null -ne $Value) { $Value - 0.5 } else { $null }
            Maximum = if ($null -ne $Value) { [math]::Floor($Value) } else { $null }
            Total   = if ($null -ne $Value) { $Value * 3 } else { $null }
            Count   = if ($null -ne $Value) { [double](($Seed + $P) % 50) } else { $null }
        }
    }
}
'@

    $script:ModuleRoot = Join-Path $TestDrive 'modules'
    $FakeModuleDir = Join-Path $script:ModuleRoot 'Az.Monitor'
    New-Item -ItemType Directory -Path $FakeModuleDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $FakeModuleDir 'Az.Monitor.psm1') -Encoding utf8 -Value ($script:PointSource + @'

function Get-AzMetric
{
    [CmdletBinding()]
    param([string]$ResourceId, [string[]]$MetricName, [datetime]$StartTime, [datetime]$EndTime, [timespan]$TimeGrain, [string]$AggregationType, $DefaultProfile)

    $Names = @($MetricName)
    $CallFile = Join-Path $env:RDA_TEST_METRIC_CALL_DIR ([guid]::NewGuid().ToString() + '.json')
    [ordered]@{ ResourceId = $ResourceId; MetricName = $Names; AggregationType = $AggregationType } | ConvertTo-Json -Compress | Set-Content -LiteralPath $CallFile -Encoding utf8
    foreach ($Name in $Names)
    {
        $Start = $StartTime
        $Data = [System.Collections.Generic.List[object]]::new()
        $Hour = 0
        foreach ($Fields in (Get-TestPoints -ResourceId $ResourceId -Name $Name))
        {
            $Point = [ordered]@{ TimeStamp = $Start.AddHours($Hour++) }
            foreach ($Key in $Fields.Keys) { $Point[$Key] = $Fields[$Key] }
            $Data.Add([PSCustomObject]$Point)
        }
        [PSCustomObject]@{ Id = $ResourceId + '/providers/Microsoft.Insights/metrics/' + $Name; Name = [PSCustomObject]@{ Value = $Name; LocalizedValue = $Name }; Data = $Data }
    }
}
Export-ModuleMember -Function Get-AzMetric
'@)

    $script:OriginalModulePath = $env:PSModulePath
    $script:OriginalDebugLogFile = $Global:DebugLogFile
    $env:PSModulePath = $script:ModuleRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath

    # The batch endpoint: a local HttpListener in a thread job. Control.json says
    # how to answer: Status (an HTTP status for every request), FailFirst (fail
    # the first N requests with Status), OmitNames (resource names left out of
    # every answer), ErrorMetrics ('name|metric' answered with an error code),
    # UpperIds (return resource ids in upper case).
    $script:ServerDir = Join-Path $TestDrive 'server'
    New-Item -ItemType Directory -Path (Join-Path $script:ServerDir 'calls') -Force | Out-Null
    $script:ControlFile = Join-Path $script:ServerDir 'control.json'
    '{}' | Set-Content -LiteralPath $script:ControlFile -Encoding utf8
    $Probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $Probe.Start(); $script:Port = $Probe.LocalEndpoint.Port; $Probe.Stop()
    $script:Endpoint = 'http://127.0.0.1:{0}/{{0}}' -f $script:Port
    $script:Listener = Start-ThreadJob -ArgumentList $script:Port, $script:ServerDir, $script:PointSource -ScriptBlock {
        param($Port, $ServerDir, $PointSource)
        . ([scriptblock]::Create($PointSource))
        $Http = [System.Net.HttpListener]::new()
        $Http.Prefixes.Add(('http://127.0.0.1:{0}/' -f $Port))
        $Http.Start()
        $Seen = 0
        $LastControlText = ''
        while ($Http.IsListening)
        {
            $Context = $Http.GetContext()
            $Request = $Context.Request
            if ($Request.Url.AbsolutePath -eq '/stop') { $Context.Response.Close(); $Http.Stop(); break }
            $Reader = [System.IO.StreamReader]::new($Request.InputStream)
            $BodyText = $Reader.ReadToEnd()
            $ControlText = Get-Content -LiteralPath (Join-Path $ServerDir 'control.json') -Raw
            # Each run writes its own control (with a run id), so FailFirst counts that run's requests.
            if ($ControlText -ne $LastControlText) { $Seen = 0; $LastControlText = $ControlText }
            $Control = $ControlText | ConvertFrom-Json -AsHashtable
            $Query = [System.Web.HttpUtility]::ParseQueryString($Request.Url.Query)
            $Record = [ordered]@{ Path = $Request.Url.AbsolutePath; Names = [string]$Query['metricnames']; Namespace = [string]$Query['metricnamespace']; Aggregation = [string]$Query['aggregation']; Interval = [string]$Query['interval']; Authorization = [string]$Request.Headers['Authorization']; Body = $BodyText }
            $Record | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $ServerDir ('calls/{0}.json' -f [guid]::NewGuid())) -Encoding utf8
            $Seen++
            $Status = 200
            $Out = $null
            $FailFirst = if ($Control.ContainsKey('FailFirst')) { [int]$Control['FailFirst'] } else { [int]::MaxValue }
            $Sequence = @($Control['StatusSequence'])
            if ($Control.ContainsKey('StatusSequence') -and $Seen -le $Sequence.Count -and [int]$Sequence[$Seen - 1] -ne 0)
            {
                # StatusSequence: the status of the run's nth request (0: answer it).
                $Status = [int]$Sequence[$Seen - 1]
                $Out = @{ error = @{ code = 'TestError'; message = 'test failure' } }
            }
            elseif ($Control.ContainsKey('Status') -and $Seen -le $FailFirst)
            {
                $Status = [int]$Control['Status']
                $Out = @{ error = @{ code = 'TestError'; message = 'test failure' } }
            }
            else
            {
                $Ids = @(($BodyText | ConvertFrom-Json).resourceids)
                $Names = @(([string]$Query['metricnames']) -split ',' | ForEach-Object { [uri]::UnescapeDataString($_) })
                $Values = foreach ($Id in $Ids)
                {
                    $ResName = ($Id -split '/')[-1]
                    if (@($Control['OmitNames']) -contains $ResName) { continue }
                    $Metrics = foreach ($Name in $Names)
                    {
                        if (@($Control['ErrorMetrics']) -contains ($ResName + '|' + $Name))
                        {
                            @{ name = @{ value = $Name; localizedValue = $Name }; errorCode = 'InvalidMetric'; errorMessage = 'not supported'; timeseries = @() }
                            continue
                        }
                        $Points = foreach ($Fields in (Get-TestPoints -ResourceId $Id -Name $Name))
                        {
                            $Json = [ordered]@{ timeStamp = '2026-01-01T00:00:00Z' }
                            # As the live API answers: only the asked aggregation, and no field for a point without a value.
                            $Asked = [string]$Query['aggregation']
                            foreach ($Key in $Fields.Keys) { if ($null -ne $Fields[$Key] -and $Key -eq $Asked) { $Json[$Key.ToLowerInvariant()] = $Fields[$Key] } }
                            $Json
                        }
                        $Answer = @{ name = @{ value = $Name; localizedValue = $Name }; unit = 'Count'; timeseries = @(@{ metadatavalues = @(); data = @($Points) }) }
                        # The live API leaves errorCode out of an answered metric; the doc's sample has 'Success'.
                        if ($Control['WithErrorCode']) { $Answer['errorCode'] = 'Success' }
                        $Answer
                    }
                    $ReturnId = if ($Control['UpperIds']) { $Id.ToUpperInvariant() } else { $Id }
                    @{ resourceid = $ReturnId; resourceregion = 'westeurope'; namespace = [string]$Query['metricnamespace']; value = @($Metrics) }
                }
                $Out = @{ values = @($Values) }
            }
            $Text = if ($Control['BadJson'] -and $Status -eq 200) { '{"values":[ not json' } else { $Out | ConvertTo-Json -Depth 12 -Compress }
            if ($Control['DuplicateMaximum'])
            {
                # A second "Maximum" key after each "maximum", with another value: the first must win.
                $Text = [regex]::Replace($Text, '"maximum":(-?[0-9.Ee+-]+)', { param($M) '"maximum":' + $M.Groups[1].Value + ',"Maximum":-1' })
            }
            if ($Control['PascalKeys'])
            {
                # Keys in another case than the doc's, to show they are read without case.
                $Text = [regex]::Replace($Text, '"(values|resourceid|value|name|errorCode|timeseries|data|average|minimum|maximum|total|count)":', { param($M) '"' + $M.Groups[1].Value.Substring(0, 1).ToUpperInvariant() + $M.Groups[1].Value.Substring(1) + '":' })
            }
            $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
            $Context.Response.StatusCode = $Status
            if ($Status -eq 429 -and $Control.ContainsKey('RetryAfter')) { $Context.Response.AddHeader('Retry-After', [string]$Control['RetryAfter']) }
            if ($Status -eq 429 -and $Control.ContainsKey('RetryAfterDateSeconds')) { $Context.Response.AddHeader('Retry-After', [DateTimeOffset]::UtcNow.AddSeconds([int]$Control['RetryAfterDateSeconds']).ToString('r')) }
            $Context.Response.ContentType = 'application/json'
            if ($Control['StallBodySeconds'])
            {
                # Headers and half the body, then a stall: only a timeout on the whole request ends it.
                $Context.Response.ContentLength64 = $Bytes.Length
                $Half = [int]($Bytes.Length / 2)
                $Context.Response.OutputStream.Write($Bytes, 0, $Half)
                $Context.Response.OutputStream.Flush()
                Start-Sleep -Seconds ([int]$Control['StallBodySeconds'])
                try { $Context.Response.OutputStream.Write($Bytes, $Half, $Bytes.Length - $Half) } catch { }
            }
            else
            {
                $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
            }
            try { $Context.Response.Close() } catch { }
        }
    }
    # Wait for the listener to answer.
    $Ready = $false
    for ($Try = 0; $Try -lt 50 -and -not $Ready; $Try++)
    {
        try { $null = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/ping' -f $script:Port) -Method Post -Body '{"resourceids":[]}' -SkipHttpErrorCheck -TimeoutSec 2; $Ready = $true } catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $Ready) { throw 'the test listener did not start' }

    # Main-thread stand-ins: the Az context (AzureCloud), the data plane token,
    # and the ARM reads and writes of the provider state.
    $Global:RdaTestBatchEnvironment = 'AzureCloud'
    function Get-AzContext { return [PSCustomObject]@{ Environment = [PSCustomObject]@{ Name = $Global:RdaTestBatchEnvironment } } }
    $Global:RdaTestBatchTokenCalls = [System.Collections.Generic.List[object]]::new()
    # Token options: RdaTestBatchTokenMinutes (lifetime), RdaTestBatchTokenSecure (a SecureString, as Az.Accounts 5 gives).
    $Global:RdaTestBatchTokenMinutes = 60
    $Global:RdaTestBatchTokenSecure = $false
    function Get-AzAccessToken
    {
        param([string]$ResourceUrl, [string]$TenantId)
        $Global:RdaTestBatchTokenCalls.Add([PSCustomObject]@{ ResourceUrl = $ResourceUrl; TenantId = $TenantId })
        $Value = if ($Global:RdaTestBatchTokenSecure) { ConvertTo-SecureString -String 'test-token' -AsPlainText -Force } else { 'test-token' }
        return [PSCustomObject]@{ Token = $Value; ExpiresOn = [DateTimeOffset]::UtcNow.AddMinutes($Global:RdaTestBatchTokenMinutes) }
    }
    $Global:RdaTestBatchProviderStates = @{}
    $Global:RdaTestBatchArmCalls = [System.Collections.Generic.List[object]]::new()
    # RdaTestBatchArmStallSeconds above 0: every call stalls that long (as a job
    # with -AsJob, as Az.Accounts does), so only a time limit ends it early.
    $Global:RdaTestBatchArmStallSeconds = 0
    function Invoke-AzRestMethod
    {
        param([string]$Method, [string]$Path, [string]$Payload, [switch]$AsJob)
        $Global:RdaTestBatchArmCalls.Add([PSCustomObject]@{ Method = $Method; Path = $Path; AsJob = [bool]$AsJob })
        $Sub = ($Path -split '/')[2]
        $State = if ($Global:RdaTestBatchProviderStates.ContainsKey($Sub)) { $Global:RdaTestBatchProviderStates[$Sub] } else { 'Registered' }
        $Response = [PSCustomObject]@{ StatusCode = 200; Content = (@{ namespace = 'Microsoft.Insights'; registrationState = $State } | ConvertTo-Json) }
        $Stall = [int]$Global:RdaTestBatchArmStallSeconds
        if ($AsJob) { return Start-ThreadJob -ArgumentList $Response, $Stall -ScriptBlock { param($R, $S) if ($S -gt 0) { Start-Sleep -Seconds $S }; $R } }
        if ($Stall -gt 0) { [System.Threading.Thread]::Sleep($Stall * 1000) }
        return $Response
    }

    function New-TestResource
    {
        param([string]$Type, [string]$Provider, [string]$Name, [string]$Kind = '', [string]$ManagedBy = '', [string]$SubscriptionId = $script:SubscriptionId, [string]$Location = 'westeurope')

        return [PSCustomObject]@{
            TYPE           = $Type
            Id             = '/subscriptions/{0}/resourceGroups/RG-Metrics-Test/providers/{1}/{2}' -f $SubscriptionId, $Provider, $Name
            subscriptionId = $SubscriptionId
            ResourceGroup  = 'RG-Metrics-Test'
            Name           = $Name
            Location       = $Location
            kind           = $Kind
            ManagedBy      = $ManagedBy
        }
    }

    function New-TestDisk
    {
        param([string]$Name, [string]$SubscriptionId = $script:SubscriptionId, [string]$Location = 'westeurope')
        return New-TestResource -Type 'microsoft.compute/disks' -Provider 'Microsoft.Compute/disks' -Name $Name -SubscriptionId $SubscriptionId -Location $Location -ManagedBy '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-owner'
    }

    function Get-MixedResources
    {
        return @(
            (New-TestResource -Type 'microsoft.compute/virtualmachines' -Provider 'Microsoft.Compute/virtualMachines' -Name 'VM-01'),
            (New-TestResource -Type 'microsoft.compute/virtualmachines' -Provider 'Microsoft.Compute/virtualMachines' -Name 'vm-02'),
            (New-TestDisk -Name 'Disk-01'),
            (New-TestDisk -Name 'disk-02'),
            (New-TestResource -Type 'microsoft.sql/servers/databases' -Provider 'Microsoft.Sql/servers/sql-test/databases' -Name 'db-dtu' -Kind 'v12.0,user'),
            (New-TestResource -Type 'microsoft.sql/servers/databases' -Provider 'Microsoft.Sql/servers/sql-test/databases' -Name 'db-vcore' -Kind 'v12.0,user,vcore,serverless'),
            (New-TestResource -Type 'microsoft.web/sites' -Provider 'Microsoft.Web/sites' -Name 'func-01' -Kind 'functionapp,linux'),
            (New-TestResource -Type 'microsoft.compute/virtualmachinescalesets' -Provider 'Microsoft.Compute/virtualMachineScaleSets' -Name 'vmss-01'),
            (New-TestResource -Type 'microsoft.documentdb/databaseaccounts' -Provider 'Microsoft.DocumentDB/databaseAccounts' -Name 'cosmos-01'),
            (New-TestResource -Type 'microsoft.containerregistry/registries' -Provider 'Microsoft.ContainerRegistry/registries' -Name 'acr01')
        )
    }

    # Runs Metrics.ps1 and returns the Get-AzMetric calls, the batch requests,
    # the records and the debug log lines.
    function Invoke-MetricsRun
    {
        param([object[]]$Resources, [string]$RunName, [switch]$Batch, [hashtable]$Control = @{}, [int]$Concurrency = 16, [switch]$Obfuscate, [hashtable]$Dictionaries, [string[]]$PerCallSubscriptions = @(), [object[]]$Subscriptions = $script:Subscriptions, [int]$CallTimeout = 120)

        $RunDir = Join-Path $TestDrive $RunName
        $CallDir = Join-Path $RunDir 'calls'
        New-Item -ItemType Directory -Path $CallDir -Force | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $script:ServerDir 'calls') -File | Remove-Item -Force
        $RunControl = @{ RunId = $RunName } + $Control
        ($RunControl | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $script:ControlFile -Encoding utf8
        $env:RDA_TEST_METRIC_CALL_DIR = $CallDir
        $Global:DebugLogFile = Join-Path $RunDir 'debug.log'
        $Global:RdaTestBatchTokenCalls.Clear()
        $Global:RdaTestBatchArmCalls.Clear()

        $Arguments = @{
            Subscriptions              = $Subscriptions
            Resources                  = $Resources
            Task                       = 'Processing'
            ConcurrencyLimit           = $Concurrency
            FilePath                   = (Join-Path $RunDir 'Metrics_test')
            Obfuscate                  = [bool]$Obfuscate
            UseMetricsBatch            = [bool]$Batch
            MetricsBatchEndpointFormat = $script:Endpoint
            MetricsCallTimeoutSeconds  = $CallTimeout
        }
        if ($PerCallSubscriptions.Count -gt 0) { $Arguments['MetricsBatchPerCallSubscriptionIds'] = $PerCallSubscriptions }
        if ($Obfuscate)
        {
            $Arguments['ResourceIdDictionary'] = $Dictionaries.Id
            $Arguments['ResourceNameDictionary'] = $Dictionaries.Name
            $Arguments['ResourceSubDictionary'] = $Dictionaries.Sub
            $Arguments['ResourceGroupDictionary'] = $Dictionaries.Rg
        }
        $Global:MetricsFailedSubs = @()
        $Clock = [System.Diagnostics.Stopwatch]::StartNew()
        try
        {
            $null = & $script:MetricsScript @Arguments *>&1
        }
        finally
        {
            $Global:DebugLogFile = $script:OriginalDebugLogFile
        }

        $Files = @(Get-ChildItem -LiteralPath $RunDir -Filter 'Metrics_test_*.json')
        return [PSCustomObject]@{
            Calls        = @(Get-ChildItem -LiteralPath $CallDir -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
            Posts        = @(Get-ChildItem -LiteralPath (Join-Path $script:ServerDir 'calls') -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
            Records      = @($Files | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Metrics })
            RawJson      = @($Files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw })
            DebugLines   = @(if (Test-Path -LiteralPath (Join-Path $RunDir 'debug.log')) { Get-Content -LiteralPath (Join-Path $RunDir 'debug.log') })
            TokenCalls   = @($Global:RdaTestBatchTokenCalls)
            ArmCalls     = @($Global:RdaTestBatchArmCalls)
            FailedSubs   = @($Global:MetricsFailedSubs)
            Seconds      = $Clock.Elapsed.TotalSeconds
        }
    }

    # 'ID|Metric' -> the record as canonical JSON (sorted names), types kept.
    function ConvertTo-RecordMap
    {
        param([object[]]$Records)
        $Map = @{}
        foreach ($Record in $Records)
        {
            $Sorted = [ordered]@{}
            foreach ($Property in ($Record.PSObject.Properties | Sort-Object Name)) { $Sorted[$Property.Name] = $Property.Value }
            $Map[('{0}|{1}' -f $Record.ID, $Record.Metric)] = ($Sorted | ConvertTo-Json -Depth 5 -Compress)
        }
        return $Map
    }

    function Assert-SameRecords
    {
        param($Expected, $Actual)
        $Want = ConvertTo-RecordMap -Records $Expected.Records
        $Got = ConvertTo-RecordMap -Records $Actual.Records
        $Got.Count | Should -Be $Want.Count
        @($Got.Keys | Sort-Object) | Should -Be @($Want.Keys | Sort-Object)
        foreach ($Key in $Want.Keys) { $Got[$Key] | Should -Be $Want[$Key] -Because $Key }
    }
}

AfterAll {
    try { $null = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/stop' -f $script:Port) -TimeoutSec 5 } catch { }
    $script:Listener | Stop-Job -ErrorAction SilentlyContinue
    $script:Listener | Remove-Job -Force -ErrorAction SilentlyContinue
    $env:PSModulePath = $script:OriginalModulePath
    $Global:DebugLogFile = $script:OriginalDebugLogFile
    Remove-Item -Path 'Env:RDA_TEST_METRIC_CALL_DIR' -ErrorAction SilentlyContinue
    Remove-Variable -Scope Global -Name RdaTestBatchEnvironment, RdaTestBatchTokenCalls, RdaTestBatchProviderStates, RdaTestBatchArmCalls, RdaTestBatchTokenMinutes, RdaTestBatchTokenSecure, RdaTestBatchArmStallSeconds -ErrorAction SilentlyContinue
}

Describe 'Metrics.ps1 batch work items' {

    BeforeAll {
        # With no -Task the script only defines its functions.
        . $script:MetricsScript
        $script:Start = (Get-Date).AddDays(-31)
        $script:End = Get-Date
        function New-Def([string]$Id, [string]$Name = 'm1', [string]$Location = 'westeurope', [string]$Aggregation = 'Maximum', [string]$Interval = '1:00:00')
        {
            [PSCustomObject]@{ MetricName = $Name; Id = $Id; StartTime = $script:Start; EndTime = $script:End; Interval = $Interval; Aggregation = $Aggregation; Location = $Location }
        }
        function Get-DiskId([int]$N, [string]$Sub = $script:SubscriptionId) { '/subscriptions/{0}/resourceGroups/rg/providers/Microsoft.Compute/disks/disk-{1:d3}' -f $Sub, $N }
    }

    It 'reads the subscription and the namespace of a nested resource id' {
        $Target = Get-MetricBatchTarget -Id '/subscriptions/ABC/resourceGroups/rg/providers/Microsoft.Sql/servers/s1/databases/db1'
        $Target.SubscriptionId | Should -Be 'abc'
        $Target.Namespace | Should -Be 'microsoft.sql/servers/databases'
    }

    It 'gives no target for ids the batch call cannot express' {
        Get-MetricBatchTarget -Id '/subscriptions/abc/providers/Microsoft.Capacity/reservationOrders/x' | Should -BeNullOrEmpty
        Get-MetricBatchTarget -Id '/subscriptions/abc/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm/providers/Microsoft.Insights/x/y' | Should -BeNullOrEmpty
        Get-MetricBatchTarget -Id '/subscriptions/abc/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines' | Should -BeNullOrEmpty
        Get-MetricBatchTarget -Id '' | Should -BeNullOrEmpty
    }

    It 'writes time grains the ISO 8601 way' {
        ConvertTo-MetricBatchInterval -Interval '1:00:00' | Should -Be 'PT1H'
        ConvertTo-MetricBatchInterval -Interval '01:00:00' | Should -Be 'PT1H'
        ConvertTo-MetricBatchInterval -Interval '1.00:00:00' | Should -Be 'P1D'
        ConvertTo-MetricBatchInterval -Interval '00:01:00' | Should -Be 'PT1M'
        ConvertTo-MetricBatchInterval -Interval 'soon' | Should -BeNullOrEmpty
    }

    It 'puts at most 50 resources in one request and keeps their order' {
        $Groups = [System.Collections.Generic.List[object]]::new()
        foreach ($N in 1..120) { $Groups.Add([object[]]@(New-Def -Id (Get-DiskId $N))) }

        $Items = New-MetricBatchPlan -MetricGroups $Groups -AllowedSubscriptionIds @($script:SubscriptionId)

        $Items.Count | Should -Be 3
        @($Items | ForEach-Object { $_.ResourceIds.Count }) | Should -Be @(50, 50, 20)
        $Items[0].ResourceIds[0] | Should -Be (Get-DiskId 1).ToLowerInvariant()
        $Items[2].ResourceIds[19] | Should -Be (Get-DiskId 120).ToLowerInvariant()
        @($Items | ForEach-Object { $_.DefCount }) | Should -Be @(50, 50, 20)
    }

    It 'splits by subscription, region, metric names, time grain and aggregation' {
        $Groups = [System.Collections.Generic.List[object]]::new()
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 1)))
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 2 $script:OtherSubscriptionId)))
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 3) -Location 'eastus'))
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 4) -Name 'm2'))
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 5) -Aggregation 'Minimum'))
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 6) -Interval '1.00:00:00'))
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 7)))

        $Items = New-MetricBatchPlan -MetricGroups $Groups -AllowedSubscriptionIds @($script:SubscriptionId, $script:OtherSubscriptionId)

        $Items.Count | Should -Be 6
        $Items[0].ResourceIds.Count | Should -Be 2
        $Items[0].Groups.Count | Should -Be 2
        @($Items | ForEach-Object { $_.Aggregation }) | Should -Be @('Maximum', 'Maximum', 'Maximum', 'Maximum', 'Minimum', 'Maximum')
        $Items[5].Interval | Should -Be 'P1D'
        $Items[2].Region | Should -Be 'eastus'
    }

    It 'joins a resource whose id differs only in case to the same request' {
        $Groups = [System.Collections.Generic.List[object]]::new()
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 1)))
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 1).ToUpperInvariant().Replace('SUBSCRIPTIONS', 'subscriptions')))

        $Items = New-MetricBatchPlan -MetricGroups $Groups -AllowedSubscriptionIds @($script:SubscriptionId)

        $Items.Count | Should -Be 1
        $Items[0].ResourceIds.Count | Should -Be 1
        $Items[0].Groups.Count | Should -Be 2
    }

    It 'keeps a global resource on the per-resource path' {
        $Groups = [System.Collections.Generic.List[object]]::new()
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 1) -Location 'global'))

        $Items = New-MetricBatchPlan -MetricGroups $Groups -AllowedSubscriptionIds @($script:SubscriptionId)

        $Items[0] -is [System.Array] | Should -BeTrue
    }

    It 'asks for a metric name once when two definitions differ only in its case' {
        $Groups = [System.Collections.Generic.List[object]]::new()
        $Groups.Add([object[]]@((New-Def -Id (Get-DiskId 1) -Name 'cpu_percent'), (New-Def -Id (Get-DiskId 1) -Name 'CPU_Percent')))

        $Items = New-MetricBatchPlan -MetricGroups $Groups -AllowedSubscriptionIds @($script:SubscriptionId)

        @($Items[0].MetricNames) | Should -Be @('cpu_percent')
    }

    It 'waits what Retry-After asks before a throttled batch request is sent again, up to 120 s' {
        Get-MetricBatchBackoff -Attempt 0 -Kind 'Throttled' -RetryAfter 90 | Should -Be 90
        Get-MetricBatchBackoff -Attempt 0 -Kind 'Throttled' -RetryAfter 120 | Should -Be 120
        Get-MetricBatchBackoff -Attempt 0 -Kind 'Throttled' -RetryAfter 600 | Should -Be 120
        # No Retry-After: twice the plain wait.
        Get-MetricBatchBackoff -Attempt 2 -Kind 'Throttled' | Should -Be 8
        # Not throttled: 1, 2, 4 ... s, at most 30; Retry-After is not read.
        Get-MetricBatchBackoff -Attempt 1 -Kind 'Error' -RetryAfter 90 | Should -Be 2
        Get-MetricBatchBackoff -Attempt 6 -Kind 'Error' | Should -Be 30
    }

    It 'keeps the per-resource path for what it cannot express or may not batch' {
        $Groups = [System.Collections.Generic.List[object]]::new()
        $Groups.Add([object[]]@(New-Def -Id '/subscriptions/abc/providers/Microsoft.Capacity/reservationOrders/x'))
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 1 $script:OtherSubscriptionId)))
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 2) -Location ''))
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 3) -Location 'East US'))
        $Groups.Add([object[]]@(New-Def -Id (Get-DiskId 4)))

        $Items = New-MetricBatchPlan -MetricGroups $Groups -AllowedSubscriptionIds @($script:SubscriptionId)

        $Items.Count | Should -Be 5
        @($Items | Where-Object { $_ -is [System.Array] }).Count | Should -Be 4
        $Items[4].RdaBatchUnit | Should -BeTrue
    }
}

Describe 'Metrics.ps1 without -UseMetricsBatch' {

    It 'makes no batch request, reads no provider state and gets no token' {
        $Run = Invoke-MetricsRun -Resources (Get-MixedResources) -RunName 'off'

        $Run.Posts.Count | Should -Be 0
        $Run.ArmCalls.Count | Should -Be 0
        $Run.TokenCalls.Count | Should -Be 0
        $Run.Calls.Count | Should -BeGreaterThan 0
        @($Run.DebugLines | Where-Object { $_ -match 'Metrics batch|\[batch\]' }).Count | Should -Be 0
    }
}

Describe 'Metrics.ps1 with -UseMetricsBatch' {

    BeforeAll {
        $script:Mixed = Get-MixedResources
        $script:PerResource = Invoke-MetricsRun -Resources $script:Mixed -RunName 'per-resource'
    }

    It 'writes the same records as the per-resource path, with no Get-AzMetric call' {
        $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-same' -Batch

        $Run.Calls.Count | Should -Be 0
        $Run.Posts.Count | Should -BeGreaterThan 0
        Assert-SameRecords -Expected $script:PerResource -Actual $Run
        @($Run.Records | Where-Object { $_.MetricError }).Count | Should -Be 0
    }

    It 'also takes an answer that carries errorCode Success, as the doc shows it' {
        $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-doc-shape' -Batch -Control @{ WithErrorCode = $true }

        $Run.Calls.Count | Should -Be 0
        Assert-SameRecords -Expected $script:PerResource -Actual $Run
    }

    It 'keeps whole numbers as JSON numbers with a fraction, as the per-resource path writes them' {
        $Run = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'batch-numbers' -Batch
        $PerCall = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'per-numbers'
        $Run.Posts.Count | Should -Be 1
        $Run.Calls.Count | Should -Be 0

        $Strip = { param($Text) ([regex]::Matches(($Text -join ''), '"MetricSeries":\[[^\]]*\]') | ForEach-Object { $_.Value } | Sort-Object) -join ';' }
        (& $Strip $Run.RawJson) | Should -Be (& $Strip $PerCall.RawJson)
    }

    It 'asks for lower-case ids, the namespace and one aggregation per request, with the token' {
        $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-shape' -Batch

        foreach ($Post in $Run.Posts)
        {
            $Ids = @(($Post.Body | ConvertFrom-Json).resourceids)
            foreach ($Id in $Ids) { $Id | Should -BeExactly $Id.ToLowerInvariant() }
            $Post.Aggregation | Should -Not -Match ','
            $Post.Authorization | Should -Be 'Bearer test-token'
            $Post.Path | Should -Match '^/westeurope/subscriptions/12345678-1234-1234-1234-123456789012/metrics:getBatch$'
        }
        @($Run.Posts | Where-Object { $_.Namespace -eq 'microsoft.sql/servers/databases' }).Count | Should -BeGreaterThan 0
        $Run.TokenCalls.Count | Should -Be 1
        $Run.TokenCalls[0].ResourceUrl | Should -Be 'https://metrics.monitor.azure.com'
        $Run.TokenCalls[0].TenantId | Should -Be $script:TenantId
    }

    It 'sends 120 disks in 3 requests of at most 50' {
        $Disks = @(1..120 | ForEach-Object { New-TestDisk -Name ('disk-{0:d3}' -f $_) })
        $Run = Invoke-MetricsRun -Resources $Disks -RunName 'batch-120' -Batch

        $Run.Posts.Count | Should -Be 3
        @($Run.Posts | ForEach-Object { @(($_.Body | ConvertFrom-Json).resourceids).Count } | Sort-Object) | Should -Be @(20, 50, 50)
        $Run.Records.Count | Should -Be 480
        $Run.Calls.Count | Should -Be 0
    }

    It 'maps answers back whatever the case of the returned id, and keeps the original id' {
        $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-upper' -Batch -Control @{ UpperIds = $true }

        $Run.Calls.Count | Should -Be 0
        Assert-SameRecords -Expected $script:PerResource -Actual $Run
        @($Run.Records | Where-Object { $_.ID -cmatch 'VM-01' }).Count | Should -Be 2
    }

    It 'asks Get-AzMetric for one metric the answer marks with an error, and keeps the rest' {
        $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-metric-error' -Batch -Control @{ ErrorMetrics = @('disk-02|Composite Disk Read Bytes/sec') }

        $Run.Calls.Count | Should -Be 1
        @($Run.Calls[0].MetricName) | Should -Be @('Composite Disk Read Bytes/sec')
        $Run.Calls[0].ResourceId | Should -Match 'disk-02$'
        Assert-SameRecords -Expected $script:PerResource -Actual $Run
    }

    It 'asks Get-AzMetric for a resource missing from the answer, as one grouped call' {
        $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-missing' -Batch -Control @{ OmitNames = @('disk-02') }

        $Run.Calls.Count | Should -Be 1
        @($Run.Calls[0].MetricName).Count | Should -Be 4
        Assert-SameRecords -Expected $script:PerResource -Actual $Run
    }

    It 'falls back to Get-AzMetric after the retries of a failing request, and loses nothing' {
        $Disks = @(1..3 | ForEach-Object { New-TestDisk -Name ('disk-{0:d3}' -f $_) })
        $Expected = Invoke-MetricsRun -Resources $Disks -RunName 'per-fail'
        $Run = Invoke-MetricsRun -Resources $Disks -RunName 'batch-fail' -Batch -Control @{ Status = 500 }

        $Run.Posts.Count | Should -Be 4
        $Run.Calls.Count | Should -Be 3
        Assert-SameRecords -Expected $Expected -Actual $Run
        $Run.FailedSubs.Count | Should -Be 0
        @($Run.DebugLines | Where-Object { $_ -match 'Batch request failed after 4 attempt' }).Count | Should -Be 1
    }

    It 'retries a throttled request and then uses its answer' {
        $Disks = @(New-TestDisk -Name 'disk-001')
        $Run = Invoke-MetricsRun -Resources $Disks -RunName 'batch-throttle' -Batch -Control @{ Status = 429; FailFirst = 1 }

        $Run.Posts.Count | Should -Be 2
        $Run.Calls.Count | Should -Be 0
        $Run.Records.Count | Should -Be 4
    }

    It 'turns batch off for a subscription that refuses it (403) and uses Get-AzMetric for all of it' {
        $Disks = @(1..60 | ForEach-Object { New-TestDisk -Name ('disk-{0:d3}' -f $_) })
        $Expected = Invoke-MetricsRun -Resources $Disks -RunName 'per-403'
        $Run = Invoke-MetricsRun -Resources $Disks -RunName 'batch-403' -Batch -Control @{ Status = 403 } -Concurrency 1

        # One refused request, no retry; the second request of the subscription is not sent.
        $Run.Posts.Count | Should -Be 1
        $Run.Calls.Count | Should -Be 60
        Assert-SameRecords -Expected $Expected -Actual $Run
        @($Run.DebugLines | Where-Object { $_ -match 'Batch turned off for subscription' }).Count | Should -Be 1
        # A 403 from the batch API means Microsoft.Insights is not registered there.
        $Note = @($Run.DebugLines | Where-Object { $_ -match 'Batch turned off for subscription' })[0]
        $Note | Should -Match 'A 403 means Microsoft\.Insights is not registered on the subscription'
        $Note | Should -Not -Match 'Monitoring Reader'
    }

    It 'does not batch a subscription where Microsoft.Insights is not registered' {
        $Global:RdaTestBatchProviderStates[$script:SubscriptionId] = 'NotRegistered'
        try
        {
            $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-unregistered' -Batch
        }
        finally
        {
            $Global:RdaTestBatchProviderStates.Remove($script:SubscriptionId)
        }

        $Run.Posts.Count | Should -Be 0
        @($Run.ArmCalls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 0
        Assert-SameRecords -Expected $script:PerResource -Actual $Run
        @($Run.DebugLines | Where-Object { $_ -match "Microsoft.Insights is 'NotRegistered'" }).Count | Should -Be 1
    }

    It 'gives up a provider state read that stalls, and lets the batch call decide' {
        $Disks = @(New-TestDisk -Name 'disk-001')
        $Quick = Invoke-MetricsRun -Resources $Disks -RunName 'batch-arm-quick' -Batch -CallTimeout 2
        $Global:RdaTestBatchArmStallSeconds = 10
        $JobsBefore = @(Get-Job).Count
        try
        {
            $Run = Invoke-MetricsRun -Resources $Disks -RunName 'batch-arm-stall' -Batch -CallTimeout 2
        }
        finally
        {
            $Global:RdaTestBatchArmStallSeconds = 0
        }

        # The read is given up after the 2 s limit, not held for the 10 s stall.
        $Run.Seconds | Should -BeLessThan ($Quick.Seconds + 6)
        $Run.Posts.Count | Should -Be 1
        $Run.Calls.Count | Should -Be 0
        $Run.Records.Count | Should -Be 4
        # The stalled read is stopped and removed, not left running.
        @(Get-Job).Count | Should -Be $JobsBefore
    }

    It 'sends no token to an endpoint that is not Azure Monitor' {
        $Saved = $script:Endpoint
        $script:Endpoint = 'https://{0}.example.com'
        try
        {
            $Run = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'batch-bad-endpoint' -Batch
        }
        finally
        {
            $script:Endpoint = $Saved
        }

        $Run.TokenCalls.Count | Should -Be 0
        $Run.Calls.Count | Should -Be 1
        @($Run.DebugLines | Where-Object { $_ -match 'not the Azure Monitor one' }).Count | Should -Be 1
    }

    It 'uses the per-resource path outside AzureCloud' {
        $Global:RdaTestBatchEnvironment = 'AzureUSGovernment'
        try
        {
            $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-gov' -Batch
        }
        finally
        {
            $Global:RdaTestBatchEnvironment = 'AzureCloud'
        }

        $Run.Posts.Count | Should -Be 0
        Assert-SameRecords -Expected $script:PerResource -Actual $Run
    }

    It 'keeps a subscription the preflight left unregistered on the per-resource path, even once registered' {
        # The provider reads Registered now, but the preflight decided per call for this run.
        $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-preflight-percall' -Batch -PerCallSubscriptions @($script:SubscriptionId)

        $Run.Posts.Count | Should -Be 0
        Assert-SameRecords -Expected $script:PerResource -Actual $Run
        @($Run.DebugLines | Where-Object { $_ -match 'was left without Microsoft.Insights at the start of the run' }).Count | Should -Be 1
    }

    It 'renews a token that ends within 10 minutes before a batch' {
        $Global:RdaTestBatchTokenMinutes = 5
        try
        {
            $Run = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'batch-renew' -Batch
        }
        finally
        {
            $Global:RdaTestBatchTokenMinutes = 60
        }

        $Run.TokenCalls.Count | Should -Be 2
        $Run.Posts.Count | Should -Be 1
        $Run.Calls.Count | Should -Be 0
    }

    It 'sends a SecureString token as plain text in the header' {
        $Global:RdaTestBatchTokenSecure = $true
        try
        {
            $Run = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'batch-secure' -Batch
        }
        finally
        {
            $Global:RdaTestBatchTokenSecure = $false
        }

        $Run.Posts[0].Authorization | Should -Be 'Bearer test-token'
        $Run.Calls.Count | Should -Be 0
    }

    It 'gets one token per tenant' {
        $Subs = @(
            [PSCustomObject]@{ id = $script:SubscriptionId; Name = 'a'; tenantId = 'tenant-a' },
            [PSCustomObject]@{ id = $script:OtherSubscriptionId; Name = 'b'; tenantId = 'tenant-b' }
        )
        $Resources = @((New-TestDisk -Name 'disk-a'), (New-TestDisk -Name 'disk-b' -SubscriptionId $script:OtherSubscriptionId))
        $Run = Invoke-MetricsRun -Resources $Resources -RunName 'batch-tenants' -Batch -Subscriptions $Subs

        @($Run.TokenCalls | ForEach-Object { $_.TenantId } | Sort-Object) | Should -Be @('tenant-a', 'tenant-b')
        $Run.Posts.Count | Should -Be 2
    }

    It 'renews a refused token (401) once, then stops batching that tenant' {
        $Disks = @(1..130 | ForEach-Object { New-TestDisk -Name ('disk-{0:d3}' -f $_) })
        $Expected = Invoke-MetricsRun -Resources $Disks -RunName 'per-401'
        $Run = Invoke-MetricsRun -Resources $Disks -RunName 'batch-401' -Batch -Control @{ Status = 401 }

        # First Metrics file batch: 2 requests refused; the token is renewed once and both
        # are sent again, refused again, and batch stops for the tenant: the second file
        # batch sends nothing.
        $Run.Posts.Count | Should -Be 4
        $Run.TokenCalls.Count | Should -Be 2
        Assert-SameRecords -Expected $Expected -Actual $Run
        @($Run.DebugLines | Where-Object { $_ -match 'renewing the token of 1 tenant' }).Count | Should -Be 1
        @($Run.DebugLines | Where-Object { $_ -match 'refused a renewed token' }).Count | Should -Be 1
        # A 401 that stays after a renewal means the caller has no Monitoring Reader there.
        @($Run.DebugLines | Where-Object { $_ -match 'refused a renewed token' })[0] | Should -Match 'Monitoring Reader on the subscription itself'
        @($Run.DebugLines | Where-Object { $_ -match 'Batch turned off for subscription' }).Count | Should -Be 0
    }

    It 'renews a refused token at once and uses the answer of the request sent again' {
        $Run = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'batch-401-once' -Batch -Control @{ Status = 401; FailFirst = 1 }

        $Run.Posts.Count | Should -Be 2
        $Run.TokenCalls.Count | Should -Be 2
        $Run.Calls.Count | Should -Be 0
        $Run.Records.Count | Should -Be 4
    }

    It 'gives a token renewed before a batch its own renewal on a 401' {
        # File batch 1: both requests refused (401), the token renewed, both sent again
        # and failing (500, 4 attempts each) so the renewal never worked. File batch 2:
        # the near-expiry renewal makes a new token; its 401 is renewed again and the
        # request sent again works.
        $Disks = @(1..130 | ForEach-Object { New-TestDisk -Name ('disk-{0:d3}' -f $_) })
        $Sequence = @(401, 401) + @(500) * 8 + @(401, 0)
        $Global:RdaTestBatchTokenMinutes = 5
        try
        {
            $Run = Invoke-MetricsRun -Resources $Disks -RunName 'batch-401-generation' -Batch -Control @{ StatusSequence = $Sequence } -Concurrency 1
        }
        finally
        {
            $Global:RdaTestBatchTokenMinutes = 60
        }

        $Run.Posts.Count | Should -Be 12
        # Only the 100 disks of the first file batch go per call.
        @($Run.Calls | ForEach-Object { $_.ResourceId } | Sort-Object -Unique).Count | Should -Be 100
        @($Run.DebugLines | Where-Object { $_ -match 'refused a renewed token' }).Count | Should -Be 0
    }

    It 'counts a request sent again after a 401 once' {
        $Run = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'batch-401-count' -Batch -Control @{ Status = 401; FailFirst = 1 }

        @($Run.DebugLines | Where-Object { $_ -match 'Metrics batch \(-UseMetricsBatch\): 1 getBatch request\(s\) \(2 attempt\(s\)\) for 1 resource\(s\)' }).Count | Should -Be 1
    }

    It 'reads the answer''s keys without regard to case' {
        $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-pascal' -Batch -Control @{ PascalKeys = $true }

        $Run.Calls.Count | Should -Be 0
        Assert-SameRecords -Expected $script:PerResource -Actual $Run
    }

    It 'reads an error code in another key case as an error, not as an answer' {
        $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-pascal-error' -Batch -Control @{ PascalKeys = $true; ErrorMetrics = @('disk-02|Composite Disk Read Bytes/sec') }

        $Run.Calls.Count | Should -Be 1
        @($Run.Calls[0].MetricName) | Should -Be @('Composite Disk Read Bytes/sec')
        Assert-SameRecords -Expected $script:PerResource -Actual $Run
    }

    It 'takes the first of two point keys that differ only in case' {
        $Run = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'batch-dup-keys' -Batch -Control @{ DuplicateMaximum = $true }
        $PerCall = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'per-dup-keys'

        $Run.Calls.Count | Should -Be 0
        Assert-SameRecords -Expected $PerCall -Actual $Run
    }

    It 'uses the per-resource path when the batch point type cannot be loaded' {
        # A fresh process, where the type is not loaded yet, with Add-Type failing as it
        # does under Constrained Language Mode.
        $Child = Join-Path $TestDrive 'no-add-type.ps1'
        Set-Content -LiteralPath $Child -Encoding utf8 -Value @'
param($RepoRoot, $ModuleRoot, $Endpoint, $Out)
$env:PSModulePath = $ModuleRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
. (Join-Path $RepoRoot 'Functions/Common.Functions.ps1')
function Get-AzContext { [pscustomobject]@{ Environment = [pscustomobject]@{ Name = 'AzureCloud' } } }
function Get-AzAccessToken { [pscustomobject]@{ Token = 'test-token'; ExpiresOn = [DateTimeOffset]::UtcNow.AddHours(1) } }
function Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"registrationState":"Registered"}' } }
function Add-Type { throw 'Cannot add type. Definition of new types is not supported in this language mode.' }
$env:RDA_TEST_METRIC_CALL_DIR = Join-Path $Out 'calls'
New-Item -ItemType Directory -Path $env:RDA_TEST_METRIC_CALL_DIR -Force | Out-Null
$Global:DebugLogFile = Join-Path $Out 'debug.log'
$Disk = [pscustomobject]@{ TYPE = 'microsoft.compute/disks'; Id = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg/providers/Microsoft.Compute/disks/disk-x'; subscriptionId = '12345678-1234-1234-1234-123456789012'; ResourceGroup = 'rg'; Name = 'disk-x'; Location = 'westeurope'; ManagedBy = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm' }
$null = & (Join-Path $RepoRoot 'Extension/Metrics.ps1') -Subscriptions @([pscustomobject]@{ id = '12345678-1234-1234-1234-123456789012'; Name = 's'; tenantId = 't' }) -Resources @($Disk) -Task 'Processing' -ConcurrencyLimit 4 -FilePath (Join-Path $Out 'Metrics_test') -Obfuscate $false -UseMetricsBatch -MetricsBatchEndpointFormat $Endpoint *>&1
'@
        $Out = Join-Path $TestDrive 'no-add-type'
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $script:ServerDir 'calls') -File | Remove-Item -Force
        $Pwsh = (Get-Process -Id $PID).Path
        & $Pwsh -NoProfile -NonInteractive -File $Child -RepoRoot $script:RepoRoot -ModuleRoot $script:ModuleRoot -Endpoint $script:Endpoint -Out $Out | Out-Null

        @(Get-ChildItem -LiteralPath (Join-Path $script:ServerDir 'calls') -File).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $Out 'calls') -File).Count | Should -Be 1
        @((Get-Content -LiteralPath (Join-Path $Out 'Metrics_test_1.json') -Raw | ConvertFrom-Json).Metrics).Count | Should -Be 4
        @(Get-Content -LiteralPath (Join-Path $Out 'debug.log') | Where-Object { $_ -match 'could not load the batch point type' }).Count | Should -Be 1
    }

    It 'asks Get-AzMetric for every resource of an answer that is not readable JSON' {
        $Run = Invoke-MetricsRun -Resources @($script:Mixed[2], $script:Mixed[3]) -RunName 'batch-bad-json' -Batch -Control @{ BadJson = $true }

        $Run.Posts.Count | Should -Be 1
        $Run.Calls.Count | Should -Be 2
        $Run.Records.Count | Should -Be 8
        @($Run.DebugLines | Where-Object { $_ -match 'could not be read' }).Count | Should -Be 1
    }

    It 'times out a batch answer whose body stalls, and falls back' {
        $Run = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'batch-stall' -Batch -Control @{ StallBodySeconds = 4 } -CallTimeout 2

        $Run.Calls.Count | Should -Be 1
        $Run.Records.Count | Should -Be 4
        @($Run.Records | Where-Object { $_.MetricError }).Count | Should -Be 0
        @($Run.DebugLines | Where-Object { $_ -match 'Batch request failed after 4 attempt\(s\) \(Timed out after 2s\)' }).Count | Should -Be 1
    }

    It 'hands every metric of a batch request that stops part way to the per-resource path' {
        # A stand-in Start-ThreadJob, found first by the parallel runspaces, throws for every
        # batch request (an error outside the guarded request) and passes every other call on.
        $Real = (Get-Command -Name 'Start-ThreadJob' -CommandType Cmdlet | Select-Object -First 1).ModuleName
        $FakeDir = Join-Path $script:ModuleRoot 'RdaTestStopBatch'
        New-Item -ItemType Directory -Path $FakeDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $FakeDir 'RdaTestStopBatch.psm1') -Encoding utf8 -Value (@'
function Start-ThreadJob
{
    [CmdletBinding()]
    param([scriptblock]$ScriptBlock, [object[]]$ArgumentList, [int]$ThrottleLimit)
    $First = if ($ArgumentList) { $ArgumentList[0] }
    if ($First -is [hashtable] -and [string]$First['Uri'] -match 'metrics:getBatch') { throw 'stopped by the test' }
    REAL\Start-ThreadJob @PSBoundParameters
}
Export-ModuleMember -Function Start-ThreadJob
'@).Replace('REAL', $Real)
        try
        {
            $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-unit-stops' -Batch
        }
        finally
        {
            Remove-Item -LiteralPath $FakeDir -Recurse -Force
        }

        $Run.Posts.Count | Should -Be 0
        Assert-SameRecords -Expected $script:PerResource -Actual $Run
        @($Run.DebugLines | Where-Object { $_ -match 'stopped \(stopped by the test\)' }).Count | Should -BeGreaterThan 0
    }

    It 'does not retry a request Azure rejects (400) and does not turn batch off' {
        $Disks = @(1..60 | ForEach-Object { New-TestDisk -Name ('disk-{0:d3}' -f $_) })
        $Expected = Invoke-MetricsRun -Resources $Disks -RunName 'per-400'
        $Run = Invoke-MetricsRun -Resources $Disks -RunName 'batch-400' -Batch -Control @{ Status = 400 } -Concurrency 1

        $Run.Posts.Count | Should -Be 2
        Assert-SameRecords -Expected $Expected -Actual $Run
        @($Run.DebugLines | Where-Object { $_ -match 'Batch turned off for subscription' }).Count | Should -Be 0
    }

    It 'waits at least what Retry-After asks before retrying a throttled request' {
        $Run = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'batch-retry-after' -Batch -Control @{ Status = 429; FailFirst = 1; RetryAfter = 6 }

        $Run.Posts.Count | Should -Be 2
        $Run.Calls.Count | Should -Be 0
        $Run.Seconds | Should -BeGreaterOrEqual 6
    }

    It 'waits until a Retry-After date before retrying a throttled request' {
        $Run = Invoke-MetricsRun -Resources @($script:Mixed[2]) -RunName 'batch-retry-after-date' -Batch -Control @{ Status = 429; FailFirst = 1; RetryAfterDateSeconds = 7 }

        $Run.Posts.Count | Should -Be 2
        $Run.Calls.Count | Should -Be 0
        $Run.Seconds | Should -BeGreaterOrEqual 5
    }

    It 'writes the same masked records under -Obfuscate' {
        $Dict = {
            $D = @{ Id = @{}; Name = @{}; Sub = @{}; Rg = @{} }
            $N = 0
            foreach ($R in $script:Mixed)
            {
                $N++
                $D.Id[$R.Id] = '/subscriptions/prod_sub_t/resourcegroups/prod_rg_t/providers/x/y/prod_{0}' -f $N
                $D.Name[$R.Id] = 'prod_{0}' -f $N
                $D.Sub[$R.Id] = 'prod_sub_t'
                $D.Rg[$R.Id] = 'prod_rg_t'
            }
            $D
        }
        $Plain = Invoke-MetricsRun -Resources $script:Mixed -RunName 'per-masked' -Obfuscate -Dictionaries (& $Dict)
        $Run = Invoke-MetricsRun -Resources $script:Mixed -RunName 'batch-masked' -Batch -Obfuscate -Dictionaries (& $Dict)

        $Run.Posts.Count | Should -BeGreaterThan 0
        $Run.Calls.Count | Should -Be 0
        Assert-SameRecords -Expected $Plain -Actual $Run
        @($Run.Records | Where-Object { $_.ID -notmatch '/prod_\d+$' }).Count | Should -Be 0
    }
}

Describe 'Invoke-RdaInsightsProviderPreflight' {

    BeforeEach {
        $script:States = @{ 'sub-a' = 'Registered'; 'sub-b' = 'NotRegistered'; 'sub-c' = 'NotRegistered' }
        $script:Registered = [System.Collections.Generic.List[string]]::new()
        $script:Prompts = [System.Collections.Generic.List[string]]::new()
        Mock Get-RdaInsightsProviderState { [pscustomobject]@{ SubscriptionId = $SubscriptionId; State = $script:States[$SubscriptionId]; Error = $null } }
        Mock Register-RdaInsightsProvider { $script:Registered.Add($SubscriptionId); $script:States[$SubscriptionId] = 'Registered'; $null }
        Mock Write-Host { }
        Mock Start-Sleep { }
    }

    It 'asks nothing and registers nothing when every subscription is registered' {
        $script:States['sub-b'] = 'Registered'; $script:States['sub-c'] = 'Registered'
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-a', 'sub-b', 'sub-c' -Interactive $true -ReadAnswer { param($P) $script:Prompts.Add($P); 'y' }

        $script:Prompts.Count | Should -Be 0
        Should -Invoke Register-RdaInsightsProvider -Times 0 -Exactly
        @($Result.Registered) | Should -Be @('sub-a', 'sub-b', 'sub-c')
    }

    It 'registers the missing ones on y, after one prompt that names their count' {
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-a', 'sub-b', 'sub-c' -Interactive $true -ReadAnswer { param($P) $script:Prompts.Add($P); 'Y' }

        @($script:Prompts) | Should -Be @('Register Microsoft.Insights on these 2 subscription(s) now? [Y/N]')
        @($script:Registered | Sort-Object) | Should -Be @('sub-b', 'sub-c')
        @($Result.Registered | Sort-Object) | Should -Be @('sub-a', 'sub-b', 'sub-c')
        $Result.NotRegistered.Count | Should -Be 0
    }

    It 'registers nothing on n and prints the register command per subscription' {
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-a', 'sub-b', 'sub-c' -Interactive $true -ReadAnswer { param($P) 'n' }

        Should -Invoke Register-RdaInsightsProvider -Times 0 -Exactly
        @($Result.NotRegistered | Sort-Object) | Should -Be @('sub-b', 'sub-c')
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Set-AzContext -Subscription sub-b; Register-AzResourceProvider -ProviderNamespace Microsoft.Insights*' } -Times 1 -Exactly
    }

    It 'registers nothing and does not prompt when no one can answer' {
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-a', 'sub-b' -Interactive $false -ReadAnswer { param($P) $script:Prompts.Add($P); 'y' }

        $script:Prompts.Count | Should -Be 0
        Should -Invoke Register-RdaInsightsProvider -Times 0 -Exactly
        $Result.Asked | Should -BeFalse
        @($Result.NotRegistered) | Should -Be @('sub-b')
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Register-AzResourceProvider -ProviderNamespace Microsoft.Insights*' } -Times 1 -Exactly
    }

    It 'names the permission needed when a register is refused, and keeps that subscription per call' {
        Mock Register-RdaInsightsProvider { 'HTTP 403 AuthorizationFailed' } -ParameterFilter { $SubscriptionId -eq 'sub-b' }
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-a', 'sub-b', 'sub-c' -Interactive $true -ReadAnswer { param($P) 'y' }

        @($Result.NotRegistered) | Should -Be @('sub-b')
        @($Result.Registered | Sort-Object) | Should -Be @('sub-a', 'sub-c')
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*sub-b*/register/action*Contributor and Owner*' } -Times 1 -Exactly
    }

    It 'names the permission only when a register is refused for lack of rights' {
        $script:RegisterErrors = @{ 'sub-b' = 'HTTP 403'; 'sub-c' = 'Operation failed: AuthorizationFailed for the client'; 'sub-d' = 'HTTP 500 InternalServerError'; 'sub-e' = 'Timed out after 30 s' }
        foreach ($Sub in 'sub-d', 'sub-e') { $script:States[$Sub] = 'NotRegistered' }
        Mock Register-RdaInsightsProvider { $script:RegisterErrors[$SubscriptionId] }
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b', 'sub-c', 'sub-d', 'sub-e' -Interactive $true -ReadAnswer { param($P) 'y' }

        @($Result.NotRegistered | Sort-Object) | Should -Be @('sub-b', 'sub-c', 'sub-d', 'sub-e')
        foreach ($Sub in 'sub-b', 'sub-c')
        {
            Should -Invoke Write-Host -ParameterFilter { $Object -like "*Could not register*$Sub*/register/action*Contributor and Owner*one call per resource*" } -Times 1 -Exactly
        }
        foreach ($Sub in 'sub-d', 'sub-e')
        {
            Should -Invoke Write-Host -ParameterFilter { $Object -like "*Could not register*$Sub*$($script:RegisterErrors[$Sub])*one call per resource*" } -Times 1 -Exactly
            Should -Invoke Write-Host -ParameterFilter { $Object -like "*$Sub*/register/action*" } -Times 0 -Exactly
        }
    }

    It 'stops waiting at the deadline for a registration that never completes' {
        Mock Register-RdaInsightsProvider { $null }
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b' -Interactive $true -ReadAnswer { param($P) 'y' } -DeadlineSeconds 0 -PollSeconds 0

        @($Result.NotRegistered) | Should -Be @('sub-b')
        $Result.Registered.Count | Should -Be 0
        # One read before asking, and no poll once the deadline has passed.
        Should -Invoke Get-RdaInsightsProviderState -Times 1 -Exactly
    }

    It 'shares one wait between several registrations' {
        $script:Polls = 0
        Mock Register-RdaInsightsProvider { $null }
        Mock Get-RdaInsightsProviderState {
            $State = $script:States[$SubscriptionId]
            if ($script:Registered.Count -eq 0 -and $State -eq 'NotRegistered' -and $script:Polls -ge 2) { $State = 'Registered' }
            if ($script:Prompts.Count -gt 0) { $script:Polls++ }
            [pscustomobject]@{ SubscriptionId = $SubscriptionId; State = $State; Error = $null }
        }
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b', 'sub-c' -Interactive $true -ReadAnswer { param($P) $script:Prompts.Add($P); 'y' } -DeadlineSeconds 60 -PollSeconds 10

        @($Result.Registered | Sort-Object) | Should -Be @('sub-b', 'sub-c')
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'on the next run, finds them registered and does not ask again' {
        $null = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-a', 'sub-b', 'sub-c' -Interactive $true -ReadAnswer { param($P) $script:Prompts.Add($P); 'y' }
        $Second = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-a', 'sub-b', 'sub-c' -Interactive $true -ReadAnswer { param($P) $script:Prompts.Add($P); 'y' }

        $script:Prompts.Count | Should -Be 1
        $Second.NotRegistered.Count | Should -Be 0
        Should -Invoke Register-RdaInsightsProvider -Times 2 -Exactly
    }

    It 'ends the wait at the deadline even when each read is slow' {
        $Subs = @(1..6 | ForEach-Object { 'sub-slow-{0}' -f $_ })
        foreach ($Sub in $Subs) { $script:States[$Sub] = 'NotRegistered' }
        Mock Register-RdaInsightsProvider { $null }
        $script:PollReads = 0
        $script:Answered = $false
        Mock Get-RdaInsightsProviderState {
            # The reads after the answer (the wait) are slow.
            if ($script:Answered) { $script:PollReads++; [System.Threading.Thread]::Sleep(400) }
            [pscustomobject]@{ SubscriptionId = $SubscriptionId; State = 'NotRegistered'; Error = $null }
        }
        $Clock = [System.Diagnostics.Stopwatch]::StartNew()
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds $Subs -Interactive $true -ReadAnswer { param($P) $script:Answered = $true; 'y' } -DeadlineSeconds 1 -PollSeconds 10
        $Clock.Stop()

        @($Result.NotRegistered).Count | Should -Be 6
        # 6 reads of 0.4 s would take 2.4 s; the deadline stops them after 1 s.
        $script:PollReads | Should -BeLessOrEqual 3
        $Clock.Elapsed.TotalSeconds | Should -BeLessThan 2
    }

    It 'never sleeps past the deadline' {
        $script:Slept = [System.Collections.Generic.List[double]]::new()
        Mock Register-RdaInsightsProvider { $null }
        Mock Start-Sleep { $script:Slept.Add([double]$Milliseconds + 1000 * [double]$Seconds) }
        $null = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b' -Interactive $true -ReadAnswer { param($P) 'y' } -DeadlineSeconds 1 -PollSeconds 10

        $script:Slept.Count | Should -BeGreaterThan 0
        foreach ($Ms in $script:Slept) { $Ms | Should -BeLessOrEqual 1000 }
    }

    It 'reads a prompt that cannot be shown (pwsh -NonInteractive) as no one there to answer' {
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b' -Interactive $true -ReadAnswer { param($P) Write-Error 'PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.' }

        Should -Invoke Register-RdaInsightsProvider -Times 0 -Exactly
        @($Result.NotRegistered) | Should -Be @('sub-b')
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*No one can answer a prompt*' } -Times 1 -Exactly
    }

    It 'says it asked only when the question was shown and answered' {
        $Failed = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b' -Interactive $true -ReadAnswer { param($P) Write-Error 'PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.' }
        $Failed.Asked | Should -BeFalse
        $Failed.Answer | Should -BeNullOrEmpty

        $Shown = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b' -Interactive $true -ReadAnswer { param($P) 'n' }
        $Shown.Asked | Should -BeTrue
        $Shown.Answer | Should -Be 'n'
    }

    It 'waits for a subscription already being registered only after a y' {
        $script:States['sub-b'] = 'Registering'
        Mock Get-RdaInsightsProviderState {
            # Once the question is answered, every read finds the provider registered.
            $State = if ($script:Prompts.Count -gt 0) { 'Registered' } else { $script:States[$SubscriptionId] }
            [pscustomobject]@{ SubscriptionId = $SubscriptionId; State = $State; Error = $null }
        }
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b', 'sub-c' -Interactive $true -ReadAnswer { param($P) $script:Prompts.Add($P); 'y' }

        # The question names only the one not registered.
        @($script:Prompts) | Should -Be @('Register Microsoft.Insights on these 1 subscription(s) now? [Y/N]')
        @($script:Registered) | Should -Be @('sub-c')
        @($Result.Registered | Sort-Object) | Should -Be @('sub-b', 'sub-c')
        $Result.NotRegistered.Count | Should -Be 0
    }

    It 'does not wait for a subscription already being registered after n, with no console, or with nothing to ask' {
        $Cases = @(
            @{ Subs = @('sub-b', 'sub-c'); Interactive = $true; Answer = 'n' },
            @{ Subs = @('sub-b', 'sub-c'); Interactive = $false; Answer = 'y' },
            @{ Subs = @('sub-b'); Interactive = $true; Answer = 'y' }
        )
        foreach ($Case in $Cases)
        {
            $script:States['sub-b'] = 'Registering'
            $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds $Case.Subs -Interactive $Case.Interactive -ReadAnswer ([scriptblock]::Create("param(`$P) '$($Case.Answer)'")) -DeadlineSeconds 1 -PollSeconds 10

            @($Result.NotRegistered) | Should -Contain 'sub-b' -Because ($Case | ConvertTo-Json -Compress)
            @($Result.Registered) | Should -Not -Contain 'sub-b'
        }
        # Only the first read per subscription, no wait and no register.
        Should -Invoke Get-RdaInsightsProviderState -Times 5 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Register-RdaInsightsProvider -Times 0 -Exactly
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*being registered on subscription sub-b*one call per resource this run*' } -Times 3 -Exactly
    }

    It 'reads, asks and registers nothing outside AzureCloud, where the batch API is not used' {
        foreach ($Cloud in 'AzureChinaCloud', 'AzureUSGovernment', $null)
        {
            Mock Get-AzContext { if ($Cloud) { [pscustomobject]@{ Environment = [pscustomobject]@{ Name = $Cloud } } } }
            $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-a', 'sub-b' -Interactive $true -ReadAnswer { param($P) $script:Prompts.Add($P); 'y' }

            $Result.NotRegistered.Count | Should -Be 0 -Because $Cloud
            $Result.Registered.Count | Should -Be 0 -Because $Cloud
        }
        $script:Prompts.Count | Should -Be 0
        Should -Invoke Get-RdaInsightsProviderState -Times 0 -Exactly
        Should -Invoke Register-RdaInsightsProvider -Times 0 -Exactly
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*not AzureCloud*Microsoft.Insights is not checked*' } -Times 3 -Exactly
    }

    It 'lets the batch call decide for a subscription whose state cannot be read' {
        $script:States['sub-b'] = 'Unknown'
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b' -Interactive $true -ReadAnswer { param($P) $script:Prompts.Add($P); 'y' }

        $script:Prompts.Count | Should -Be 0
        @($Result.Registered) | Should -Be @('sub-b')
    }
}

Describe 'The registration wait when one state read stalls' {

    It 'ends at the deadline and keeps the subscription per call' {
        $script:Answered = $false
        $script:WaitReads = 0
        Mock Write-Host { }
        Mock Register-RdaInsightsProvider { $null }
        Mock Invoke-AzRestMethod {
            if (-not $script:Answered)
            {
                # The first read answers at once; with -AsJob as a job, as Az.Accounts gives it.
                $Read = [pscustomobject]@{ StatusCode = 200; Content = '{"registrationState":"NotRegistered"}' }
                if ($AsJob) { return Start-ThreadJob -ArgumentList $Read -ScriptBlock { param($R) $R } }
                return $Read
            }
            # Every read while waiting stalls far past the deadline.
            $script:WaitReads++
            if ($AsJob) { return Start-ThreadJob -ScriptBlock { Start-Sleep -Seconds 30 } }
            [System.Threading.Thread]::Sleep(6000)
            [pscustomobject]@{ StatusCode = 200; Content = '{"registrationState":"Registering"}' }
        }
        $JobsBefore = @(Get-Job).Count
        $Clock = [System.Diagnostics.Stopwatch]::StartNew()
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b' -Interactive $true -ReadAnswer { param($P) $script:Answered = $true; 'y' } -DeadlineSeconds 2 -PollSeconds 10
        $Clock.Stop()

        $script:WaitReads | Should -BeGreaterOrEqual 1
        $Clock.Elapsed.TotalSeconds | Should -BeLessThan 3.5
        @($Result.NotRegistered) | Should -Be @('sub-b')
        $Result.Registered.Count | Should -Be 0
        # The stalled read is stopped and removed, not left running.
        @(Get-Job).Count | Should -Be $JobsBefore
    }
}

Describe 'The preflight when a state read or a register stalls' {

    BeforeEach {
        $script:Answered = $false
        Mock Write-Host { }
        Mock Start-Sleep { }
    }

    It 'gives up a first state read that stalls, and lets the batch call decide' {
        Mock Invoke-AzRestMethod {
            # Every read stalls far past the limit.
            if ($AsJob) { return Start-ThreadJob -ScriptBlock { Start-Sleep -Seconds 30 } }
            [System.Threading.Thread]::Sleep(6000)
            [pscustomobject]@{ StatusCode = 200; Content = '{"registrationState":"Registered"}' }
        }
        $JobsBefore = @(Get-Job).Count
        $Clock = [System.Diagnostics.Stopwatch]::StartNew()
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b' -Interactive $false -CallTimeoutSeconds 1
        $Clock.Stop()

        $Clock.Elapsed.TotalSeconds | Should -BeLessThan 3
        @($Result.Registered) | Should -Be @('sub-b')
        $Result.NotRegistered.Count | Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Could not read*sub-b*Timed out*' } -Times 1 -Exactly
        @(Get-Job).Count | Should -Be $JobsBefore
    }

    It 'gives up a register that stalls, and keeps that subscription per call' {
        Mock Invoke-AzRestMethod {
            if ($Method -eq 'POST')
            {
                if ($AsJob) { return Start-ThreadJob -ScriptBlock { Start-Sleep -Seconds 30 } }
                [System.Threading.Thread]::Sleep(6000)
                return [pscustomobject]@{ StatusCode = 200; Content = '{}' }
            }
            $Read = [pscustomobject]@{ StatusCode = 200; Content = '{"registrationState":"NotRegistered"}' }
            if ($AsJob) { return Start-ThreadJob -ArgumentList $Read -ScriptBlock { param($R) $R } }
            $Read
        }
        $JobsBefore = @(Get-Job).Count
        $Clock = [System.Diagnostics.Stopwatch]::StartNew()
        $Result = Invoke-RdaInsightsProviderPreflight -SubscriptionIds 'sub-b' -Interactive $true -ReadAnswer { param($P) 'y' } -CallTimeoutSeconds 1 -DeadlineSeconds 5
        $Clock.Stop()

        $Clock.Elapsed.TotalSeconds | Should -BeLessThan 3.5
        @($Result.NotRegistered) | Should -Be @('sub-b')
        $Result.Registered.Count | Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Could not register*sub-b*Timed out*' } -Times 1 -Exactly
        @(Get-Job).Count | Should -Be $JobsBefore
    }
}

Describe 'A direct run hands its preflight result to the metrics phase' {

    # shortcut: read from the script's syntax tree, because a direct run signs in
    # and reads Resource Graph with the Azure CLI, which no test here stands in for;
    # upgrade to a stand-in run once the direct run uses Az PowerShell only.
    It 'keeps the subscriptions the preflight left unregistered in script scope and hands them to Metrics.ps1' {
        $Text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw
        $Ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)

        @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Contain 'MetricsBatchPerCallSubscriptionIds'

        $Kept = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq '$script:MetricsBatchPerCallSubscriptionIds' }, $true))
        $Kept.Count | Should -Be 1
        $Kept[0].Right.Extent.Text | Should -Match 'Invoke-RdaInsightsProviderPreflight'
        $Kept[0].Right.Extent.Text | Should -Match '\.NotRegistered\)$'

        $Handed = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.Extent.Text -match '^& \$MetricPath ' }, $true))
        $Handed.Count | Should -Be 1
        $Handed[0].Extent.Text | Should -Match ([regex]::Escape('-MetricsBatchPerCallSubscriptionIds @($MetricsBatchPerCallSubscriptionIds | Where-Object { $_ })'))
    }
}

Describe 'A direct run with -ResourceGroup but no -SubscriptionID' {

    # The run is refused; it must stop before the preflight reads, asks or
    # registers anything. It runs in its own pwsh, with stand-ins for az, the
    # Az context, Invoke-AzRestMethod and Read-Host that log each call.
    It 'stops before the preflight reads, asks or registers anything' {
        $Work = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-rg-nosub-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Work | Out-Null
        try
        {
            $CallLog = Join-Path $Work 'calls.txt'
            $Runner = Join-Path $Work 'run.ps1'
            Set-Content -LiteralPath $Runner -Encoding utf8 -Value @'
param($Script, $CallLog, $OutDir)
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
function global:az
{
    $Line = ($args -join ' ')
    if ($Line -like 'account show*') { return '{"tenantId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","user":{"name":"tester"}}' }
    if ($Line -like 'account list*') { return '[{"id":"11111111-1111-1111-1111-111111111111","tenantId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"},{"id":"22222222-2222-2222-2222-222222222222","tenantId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]' }
    Add-Content -LiteralPath $CallLog -Value ('az ' + $Line)
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }; Environment = [pscustomobject]@{ Name = 'AzureCloud' } } }
function global:Connect-AzAccount { Add-Content -LiteralPath $CallLog -Value 'Connect-AzAccount' }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, [switch]$AsJob)
    Add-Content -LiteralPath $CallLog -Value ('Invoke-AzRestMethod {0} {1}' -f $Method, $Path)
    $Read = [pscustomobject]@{ StatusCode = 200; Content = '{"registrationState":"NotRegistered"}' }
    if ($AsJob) { return Start-ThreadJob -ArgumentList $Read -ScriptBlock { param($R) $R } }
    $Read
}
function global:Read-Host { Add-Content -LiteralPath $CallLog -Value 'Read-Host'; 'y' }
& $Script -ResourceGroup 'rg-one' -UseMetricsBatch -OutputDirectory $OutDir
exit $LASTEXITCODE
'@
            $Pwsh = Join-Path $PSHOME 'pwsh'
            $Output = & $Pwsh -NoProfile -NonInteractive -File $Runner -Script (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -CallLog $CallLog -OutDir $Work 2>&1 | Out-String
            $ExitCode = $LASTEXITCODE

            # The run got as far as the refusal, and the refusal is a failure.
            $Output | Should -Match 'Resource Group Name present, but missing Subscription ID'
            $ExitCode | Should -Be 1 -Because $Output
            $Calls = @(if (Test-Path -LiteralPath $CallLog) { Get-Content -LiteralPath $CallLog })
            @($Calls | Where-Object { $_ -like 'Invoke-AzRestMethod*' }) | Should -BeNullOrEmpty
            @($Calls | Where-Object { $_ -eq 'Read-Host' }) | Should -BeNullOrEmpty
            $Output | Should -Not -Match 'checking the Microsoft\.Insights resource provider'
        }
        finally
        {
            Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Run-AllSubscriptions.ps1 when the consumption gate stops the run' {

    # The wrapper runs in its own pwsh with a private HOME. Aliases stand in for
    # the sign-in, the subscription list and the two up-front gates (an alias wins
    # over the functions the wrapper dot-sources). Invoke-AzRestMethod and
    # Read-Host stand-ins log each provider read, register and prompt.
    BeforeAll {
        function script:Invoke-WrapperUpToRun
        {
            param([string]$Consumption)
            $Work = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-wrap-gate-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $Work | Out-Null
            try
            {
                $CallLog = Join-Path $Work 'calls.txt'
                $Runner = Join-Path $Work 'run.ps1'
                Set-Content -LiteralPath $Runner -Encoding utf8 -Value @'
param($Script, $CallLog, $Consumption)
$Global:RdaCallLog = $CallLog
$Global:RdaConsumption = $Consumption
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }; Environment = [pscustomobject]@{ Name = 'AzureCloud' } } }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, [switch]$AsJob)
    Add-Content -LiteralPath $Global:RdaCallLog -Value ('Invoke-AzRestMethod {0} {1}' -f $Method, $Path)
    $Read = [pscustomobject]@{ StatusCode = 200; Content = '{"registrationState":"NotRegistered"}' }
    if ($AsJob) { return Start-ThreadJob -ArgumentList $Read -ScriptBlock { param($R) $R } }
    $Read
}
function global:Read-Host { Add-Content -LiteralPath $Global:RdaCallLog -Value 'Read-Host'; 'y' }
function global:RdaStubNothing { }
function global:RdaStubTenant { 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
function global:RdaStubTrue { $true }
function global:RdaStubSubscriptions
{
    [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name = 'sub-one'; State = 'Enabled'; TenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
    [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; Name = 'sub-two'; State = 'Enabled'; TenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
}
function global:RdaStubAccessDecision { [pscustomobject]@{ Inaccessible = @(); InaccessibleIds = @(); ShouldBlock = $false } }
function global:RdaStubConsumption
{
    Add-Content -LiteralPath $Global:RdaCallLog -Value 'Test-ConsumptionAccess'
    [pscustomobject]@{ Outcome = $Global:RdaConsumption; Detail = '' }
}
# The first subscription of the run: stop here, so nothing is collected.
function global:RdaStubStop { Add-Content -LiteralPath $Global:RdaCallLog -Value 'run started'; exit 7 }
Set-Alias -Scope Global -Name Invoke-PreFlightChecks -Value RdaStubNothing
Set-Alias -Scope Global -Name Get-AzCliSignedInTenant -Value RdaStubTenant
Set-Alias -Scope Global -Name Get-AzPsSignedInTenant -Value RdaStubTenant
Set-Alias -Scope Global -Name Test-AzCliTokenSilent -Value RdaStubTrue
Set-Alias -Scope Global -Name Test-AzPsTokenSilent -Value RdaStubTrue
Set-Alias -Scope Global -Name Get-AzSubscription -Value RdaStubSubscriptions
Set-Alias -Scope Global -Name Test-SubscriptionAccessAll -Value RdaStubNothing
Set-Alias -Scope Global -Name Resolve-AccessPreflight -Value RdaStubAccessDecision
Set-Alias -Scope Global -Name Test-ConsumptionAccess -Value RdaStubConsumption
Set-Alias -Scope Global -Name Write-RdaProgress -Value RdaStubStop
& $Script -TenantID 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -UseMetricsBatch -ParallelStreams 1
exit $LASTEXITCODE
'@
                # The wrapper looks for an az program on PATH before anything else; the
                # stand-ins above answer every sign-in question, so it is never run.
                $Bin = Join-Path $Work 'bin'
                New-Item -ItemType Directory -Path $Bin | Out-Null
                Set-Content -LiteralPath (Join-Path $Bin 'az') -Value "#!/bin/sh`nexit 0"
                Set-Content -LiteralPath (Join-Path $Bin 'az.cmd') -Value '@exit /b 0'
                if (-not $IsWindows) { & chmod +x (Join-Path $Bin 'az') }
                $Pwsh = Join-Path $PSHOME 'pwsh'
                $OldHome = $env:HOME
                $OldPath = $env:PATH
                try
                {
                    $env:HOME = $Work
                    $env:PATH = $Bin + [System.IO.Path]::PathSeparator + $env:PATH
                    $Output = & $Pwsh -NoProfile -NonInteractive -File $Runner -Script (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -CallLog $CallLog -Consumption $Consumption 2>&1 | Out-String
                    $ExitCode = $LASTEXITCODE
                }
                finally
                {
                    $env:HOME = $OldHome
                    $env:PATH = $OldPath
                }
                [pscustomobject]@{
                    Output   = $Output
                    ExitCode = $ExitCode
                    Calls    = @(if (Test-Path -LiteralPath $CallLog) { Get-Content -LiteralPath $CallLog })
                }
            }
            finally
            {
                Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'stops before the Microsoft.Insights preflight reads, asks or registers anything' {
        $Run = Invoke-WrapperUpToRun -Consumption 'Denied'

        $Run.ExitCode | Should -Be 1 -Because $Run.Output
        $Run.Output | Should -Match 'not authorized to read consumption/billing data'
        $Run.Calls | Should -Contain 'Test-ConsumptionAccess'
        @($Run.Calls | Where-Object { $_ -like 'Invoke-AzRestMethod*' }) | Should -BeNullOrEmpty
        @($Run.Calls | Where-Object { $_ -eq 'Read-Host' }) | Should -BeNullOrEmpty
        $Run.Output | Should -Not -Match 'Microsoft\.Insights'
    }

    It 'runs the preflight after the consumption gate lets the run go on' {
        $Run = Invoke-WrapperUpToRun -Consumption 'Allowed'

        $Run.ExitCode | Should -Be 7 -Because $Run.Output
        $Gate = [array]::IndexOf($Run.Calls, 'Test-ConsumptionAccess')
        $FirstRead = @(for ($i = 0; $i -lt $Run.Calls.Count; $i++) { if ($Run.Calls[$i] -like 'Invoke-AzRestMethod GET*Microsoft.Insights*') { $i } })
        $Gate | Should -BeGreaterOrEqual 0
        $FirstRead.Count | Should -BeGreaterThan 0
        $FirstRead[0] | Should -BeGreaterThan $Gate
        $Run.Calls[-1] | Should -Be 'run started'
    }
}

Describe 'Get-RdaInsightsProviderState' {

    BeforeEach {
        $script:Answers = [System.Collections.Generic.Queue[object]]::new()
        $script:Paths = [System.Collections.Generic.List[string]]::new()
        Mock Start-Sleep { }
        Mock Invoke-AzRestMethod {
            $script:Paths.Add($Path)
            $Next = $script:Answers.Dequeue()
            if ($Next -is [string]) { throw $Next }
            $Next
        }
    }

    It 'reads the registration state with one GET' {
        $script:Answers.Enqueue([pscustomobject]@{ StatusCode = 200; Content = '{"namespace":"Microsoft.Insights","registrationState":"NotRegistered"}' })
        $Read = Get-RdaInsightsProviderState -SubscriptionId 'sub-a'

        $Read.State | Should -Be 'NotRegistered'
        $Read.Error | Should -BeNullOrEmpty
        $script:Paths.Count | Should -Be 1
        $script:Paths[0] | Should -BeLike '/subscriptions/sub-a/providers/Microsoft.Insights?api-version=*'
    }

    It 'sends the GET again after a server error or a request that throws' {
        $script:Answers.Enqueue([pscustomobject]@{ StatusCode = 503; Content = '' })
        $script:Answers.Enqueue('connection reset')
        $script:Answers.Enqueue([pscustomobject]@{ StatusCode = 200; Content = '{"registrationState":"Registered"}' })
        $Read = Get-RdaInsightsProviderState -SubscriptionId 'sub-a'

        $Read.State | Should -Be 'Registered'
        $script:Paths.Count | Should -Be 3
    }

    It 'reads Unknown at once on a refusal, and after the last retry' {
        $script:Answers.Enqueue([pscustomobject]@{ StatusCode = 403; Content = '' })
        $Refused = Get-RdaInsightsProviderState -SubscriptionId 'sub-a'
        $Refused.State | Should -Be 'Unknown'
        $Refused.Error | Should -Be 'HTTP 403'
        $script:Paths.Count | Should -Be 1

        foreach ($N in 1..2) { $script:Answers.Enqueue([pscustomobject]@{ StatusCode = 429; Content = '' }) }
        $Throttled = Get-RdaInsightsProviderState -SubscriptionId 'sub-a' -MaxRetries 1
        $Throttled.State | Should -Be 'Unknown'
        $Throttled.Error | Should -Be 'HTTP 429'
        $script:Paths.Count | Should -Be 3
    }

    It 'reads Unknown for an answer that is not JSON' {
        $script:Answers.Enqueue([pscustomobject]@{ StatusCode = 200; Content = 'not json' })
        (Get-RdaInsightsProviderState -SubscriptionId 'sub-a').State | Should -Be 'Unknown'
    }
}

Describe 'Microsoft.Insights is never registered without -UseMetricsBatch and a y' {

    BeforeAll {
        $script:ProductFiles = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' })
        $script:Calls = foreach ($File in $script:ProductFiles)
        {
            $Ast = [System.Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$null, [ref]$null)
            foreach ($Command in $Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] }, $true))
            {
                [pscustomobject]@{ File = $File.Name; Name = $Command.GetCommandName(); Ast = $Command }
            }
        }
    }

    It 'registers only through Register-RdaInsightsProvider, called only after the y check in the preflight' {
        @($script:Calls | Where-Object { $_.Name -eq 'Register-AzResourceProvider' }).Count | Should -Be 0
        $Register = @($script:Calls | Where-Object { $_.Name -eq 'Register-RdaInsightsProvider' })
        $Register.Count | Should -Be 1
        $Function = $Register[0].Ast.Parent
        while ($Function -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $Function = $Function.Parent }
        $Function.Name | Should -Be 'Invoke-RdaInsightsProviderPreflight'
        $Body = $Function.Body.Extent.Text
        $Guard = $Body.IndexOf("`$Answer -notmatch '^\s*(y|yes)\s*$'")
        $Guard | Should -BeGreaterOrEqual 0
        $Guard | Should -BeLessThan $Body.IndexOf('Register-RdaInsightsProvider -SubscriptionId')
        # Only the "y" branch fills the list of subscriptions to register.
        $Body | Should -Match 'else\r?\n\s*\{\r?\n\s*\$ToRegister = @\(\$Missing\)\r?\n\s*\}'
        @($script:Calls | Where-Object { $_.Ast.Extent.Text -match '/register\?' }).Count | Should -Be 0
    }

    It 'forwards -UseMetricsBatch and the per-call list to every inner run and to Metrics.ps1' {
        $Wrapper = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Stream = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.Stream.ps1') -Raw
        $Inner = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw
        $Wrapper | Should -Match ([regex]::Escape("if (`$UseMetricsBatch) { `$InventoryPassthrough['UseMetricsBatch'] = `$true }"))
        $Wrapper | Should -Match ([regex]::Escape("if (`$UseMetricsBatch) { `$WorkerArgs.UseMetricsBatch = `$true }"))
        $Wrapper | Should -Match ([regex]::Escape("`$InventoryPassthrough['MetricsBatchPerCallSubscriptionIds'] = [string[]]`$MetricsBatchPerCallIds"))
        $Wrapper | Should -Match ([regex]::Escape("`$WorkerArgs.MetricsBatchPerCallSubscriptionIds = [string[]]`$MetricsBatchPerCallIds"))
        $Stream | Should -Match ([regex]::Escape("if (`$UseMetricsBatch) { `$InventoryPassthrough['UseMetricsBatch'] = `$true }"))
        $Stream | Should -Match ([regex]::Escape("`$InventoryPassthrough['MetricsBatchPerCallSubscriptionIds'] = [string[]]`$MetricsBatchPerCallSubscriptionIds"))
        $Inner | Should -Match ([regex]::Escape('-UseMetricsBatch:$UseMetricsBatch.IsPresent -MetricsBatchPerCallSubscriptionIds'))
    }

    It 'keeps a direct run''s preflight result where the metrics phase reads it (script scope)' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Assignments = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $N.Left.VariablePath.UserPath -match 'MetricsBatchPerCallSubscriptionIds$' }, $true))
        $Assignments.Count | Should -Be 1
        # Set inside a function (RunInventorySetup), read in another: only script scope reaches it.
        $Assignments[0].Left.VariablePath.IsScript | Should -BeTrue
    }

    It 'asks only for subscriptions this run collects (not those a resumed run already completed)' {
        $Wrapper = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Wrapper | Should -Match ([regex]::Escape('$InsightsScope = @($RunSubscriptionIds | Where-Object { -not ($Resume -and $CompletedIds -contains $_) })'))
        $Wrapper | Should -Match ([regex]::Escape('Invoke-RdaInsightsProviderPreflight -SubscriptionIds $InsightsScope'))
    }

    It 'keeps the position of every earlier parameter of the scripts it adds parameters to' {
        $Base = 'a55dc6a94afab2891acb011a7ad4f077e385d0db'
        $HasBase = $null -ne (git -C $script:RepoRoot cat-file -t $Base 2>$null)
        if (-not $HasBase) { Set-ItResult -Skipped -Because 'the base commit is not in this clone' ; return }
        foreach ($File in 'ResourceInventory.ps1', 'Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Extension/Metrics.ps1')
        {
            $Positional = {
                param([string]$Text)
                $Ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
                @($Ast.ParamBlock.Parameters | Where-Object { $_.StaticType -ne [switch] -and $_.StaticType -ne [System.Management.Automation.SwitchParameter] } | ForEach-Object { $_.Name.VariablePath.UserPath })
            }
            $Old = & $Positional ((git -C $script:RepoRoot show ('{0}:{1}' -f $Base, $File)) -join "`n")
            $New = & $Positional (Get-Content -LiteralPath (Join-Path $script:RepoRoot $File) -Raw)
            @($New | Select-Object -First $Old.Count) | Should -Be $Old -Because $File
        }
    }

    It 'says in the README what a 403 and a 401 do, as the code does' {
        $Readme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.md') -Raw
        $Readme | Should -Not -Match ([regex]::Escape('401/403, batch is turned off for that subscription'))
        # Microsoft's batch API guide: a 401 means the token is refused or the caller has
        # no Monitoring Reader on the subscription itself; a 403 means Microsoft.Insights
        # is not registered there.
        $Lines = $Readme -split "`r?`n"
        $ReaderLine = @($Lines | Where-Object { $_ -match '^- \*\*Monitoring Reader \(or Reader\) on the subscription itself' })
        $ProviderLine = @($Lines | Where-Object { $_ -match '^- \*\*The `Microsoft\.Insights` resource provider registered' })
        $ReaderLine.Count | Should -Be 1
        $ProviderLine.Count | Should -Be 1
        $ReaderLine[0] | Should -Not -Match '\b403\b'
        $ReaderLine[0] | Should -Match 'Without it Azure answers 401'
        $ReaderLine[0] | Should -Match 'A 401 \(token refused, or no Monitoring Reader on the subscription\) renews the tenant''s token once and sends the request again; a second 401 turns batch off for that whole tenant'
        $ProviderLine[0] | Should -Not -Match '\b401\b'
        $ProviderLine[0] | Should -Match 'Without it Azure answers 403: batch is turned off for that subscription'
    }

    It 'runs the preflight only under -UseMetricsBatch' {
        $Preflight = @($script:Calls | Where-Object { $_.Name -eq 'Invoke-RdaInsightsProviderPreflight' })
        @($Preflight | ForEach-Object { $_.File } | Sort-Object) | Should -Be @('ResourceInventory.ps1', 'Run-AllSubscriptions.ps1')
        foreach ($Call in $Preflight)
        {
            $Node = $Call.Ast.Parent
            while ($null -ne $Node -and $Node -isnot [System.Management.Automation.Language.IfStatementAst]) { $Node = $Node.Parent }
            $Node.Clauses[0].Item1.Extent.Text | Should -Match 'UseMetricsBatch'
        }
    }
}

Describe 'The batch code runs on PowerShell 7.0' {

    # The scripts accept PowerShell 7.0 (#requires -Version 7.0), which runs on
    # .NET Core 3.1. ReferenceEqualityComparer came with .NET 5, so 7.0 fails on it.
    It 'uses no ReferenceEqualityComparer, which .NET Core 3.1 does not have' {
        foreach ($File in 'Extension/Metrics.ps1', 'Functions/Common.Functions.ps1')
        {
            $Lines = @(Select-String -LiteralPath (Join-Path $script:RepoRoot $File) -Pattern 'ReferenceEqualityComparer' | ForEach-Object { $_.LineNumber })
            $Lines | Should -BeNullOrEmpty -Because $File
        }
    }
}
