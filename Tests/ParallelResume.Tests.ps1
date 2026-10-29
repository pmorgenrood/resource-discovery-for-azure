# End to end: -Resume and -ResumeFailedOnly after a parallel run.
#
#   - A parallel -Resume collects only the subscriptions no earlier run
#     completed, whether the earlier run finished, was interrupted, or used a
#     different stream count, and on the one-subscription path too. The
#     completed ones are listed as skipped, as the sequential loop lists them.
#   - A -Resume or -ResumeFailedOnly run with one stream that clears the resume
#     state also deletes the per-stream state files it folded in, so the next
#     run neither recovers them nor skips or retries from them. One that keeps
#     the state deletes them once the resume state file holds their records,
#     and keeps them with a warning while it cannot be written.
#   - A per-stream state file the end-of-run merge cannot read is named on
#     screen, moved aside where no later run reads it, and none of the
#     subscriptions it lists counts as completed; that run does not report a
#     clean run, and the next -Resume collects what is still missing.
#   - The recovery line counts real failure records only.
# Each scenario is followed by the next two runs, which end without a repeated
# recovery line, without collecting a completed subscription again, and with
# no resume state once nothing is left. The reader, the move-aside helper and
# the read-back of the resume state are also tested on their own, a rename that
# fails included.
#
# Every run is Run-AllSubscriptions.ps1 itself, started as its own pwsh process
# from a copy of the tool whose ResourceInventory.ps1 is a stand-in. Azure is a
# set of stand-in Az modules and an az command, found first on the module path
# and PATH of that process, which answer from a scenario file: the
# subscriptions, the ones that fail, and the ones whose collection hangs until
# the run is ended. An interrupted run is ended by killing the wrapper's
# process tree once the streams have recorded what the test needs. The
# process's home is a scratch folder, so the run writes its inventory root
# under it. On Windows the wrapper writes to C:\InventoryReports instead, so
# these tests do not run there.
#
# Run with: Invoke-Pester ./Tests/ParallelResume.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('ParallelResumeTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
    $script:Tenant = '12345678-1234-1234-1234-123456789012'
    $script:Pwsh = Join-Path $PSHOME 'pwsh'

    # --- The tool: the wrapper and its helpers as they are, and a stand-in
    # ResourceInventory.ps1 that writes one report folder and zip per call, as
    # the real one does under the inventory root.
    $script:ToolRoot = Join-Path $script:TestBase 'tool'
    New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
    foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Version.json', 'Functions', 'Extension'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:ToolRoot -Recurse -Force
    }
    $script:Wrapper = Join-Path $script:ToolRoot 'Run-AllSubscriptions.ps1'
    $StandInInner = @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
if (@($Scenario.FailIds) -contains $SubscriptionID) { throw 'stand-in failure for this subscription' }
# Collection of this subscription hangs; the marker file tells the test it started.
if (@($Scenario.HangIds) -contains $SubscriptionID) { Set-Content -LiteralPath (Join-Path $HOME ('hang-' + $SubscriptionID)) -Value $PID; Start-Sleep -Seconds 600 }
$Root = Join-Path $HOME 'InventoryReports'
$Stamp = (Get-Date -Format 'yyyyMMddHHmmssfff') + $SubscriptionID
$Folder = Join-Path $Root ('ResourcesReport' + $Stamp)
$Stage = Join-Path $Root ('stage-' + $Stamp)
New-Item -ItemType Directory -Path $Folder, $Stage -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Stage ('Inventory_ResourcesReport_{0}.json' -f $Stamp)) -Value ('{"VirtualMachines":[{"Name":"vm","Subscription":"' + $SubscriptionID + '"}]}') -Encoding utf8
Set-Content -LiteralPath (Join-Path $Stage ('ResourcesReport_{0}.html' -f $Stamp)) -Value '<html></html>' -Encoding utf8
$Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
Copy-Item -Path (Join-Path $Stage '*') -Destination $Folder
Remove-Item -LiteralPath $Stage -Recurse -Force
$Global:ZipOutputFile = $Zip
$Global:Resources = @(1)
$Global:ResourceCount = 1
'@
    Set-Content -LiteralPath (Join-Path $script:ToolRoot 'ResourceInventory.ps1') -Value $StandInInner -Encoding utf8

    # --- Stand-in Azure ------------------------------------------------------
    # Az.Accounts answers sign-in, context, token and subscription calls, and
    # the Resource Manager paths a run reads: the resource group list, role
    # assignments and their definitions, caller permissions, Resource Graph
    # resource counts and usage aggregates (one row above zero). Every
    # subscription can be read.
    $script:Modules = Join-Path $script:TestBase 'modules'
    $Accounts = @'
function Get-RdaStandInScenario { Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json }
function Get-RdaStandInContext
{
    [pscustomobject]@{
        Account      = [pscustomobject]@{ Id = 'operator@example.com'; Type = 'User' }
        Tenant       = [pscustomobject]@{ Id = (Get-RdaStandInScenario).Tenant }
        Subscription = $null
        Environment  = [pscustomobject]@{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/' }
    }
}
function Get-AzContext { [CmdletBinding()] param() Get-RdaStandInContext }
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context) Get-RdaStandInContext }
function Import-AzContext { [CmdletBinding()] param($Path) Get-RdaStandInContext }
function Save-AzContext { [CmdletBinding()] param($Path, [switch]$Force) Set-Content -LiteralPath $Path -Value '{}' }
function Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function Connect-AzAccount { [CmdletBinding()] param($Tenant, [switch]$UseDeviceAuthentication) throw 'stand-in: no sign-in expected' }
function Get-AzAccessToken
{
    [CmdletBinding()] param($TenantId, $ResourceUrl, [switch]$AsSecureString)
    $Claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"stand-in-caller"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [pscustomobject]@{ Token = ('e30.{0}.c2ln' -f $Claims); Type = 'Bearer'; ExpiresOn = (Get-Date).AddHours(1) }
}
function Get-AzSubscription
{
    [CmdletBinding()] param($TenantId, $SubscriptionId)
    $Scenario = Get-RdaStandInScenario
    @($Scenario.Subscriptions | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SubscriptionId = $_.Id; Name = $_.Name; State = $_.State; TenantId = $Scenario.Tenant } })
}
function Invoke-AzRestMethod
{
    [CmdletBinding()] param([string]$Method = 'GET', [string]$Path, [string]$Payload)
    $Answer = { param([int]$Status, $Body) [pscustomobject]@{ StatusCode = $Status; Content = (ConvertTo-Json -InputObject $Body -Depth 8 -Compress); Headers = @{} } }
    if ($Path -match '^/subscriptions/([^/?]+)/resourcegroups\?') { return & $Answer 200 @{ value = @() } }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/roleAssignments\?')
    {
        $Id = $Matches[1]
        return & $Answer 200 @{ value = @(@{ properties = @{ scope = "/subscriptions/$Id"; principalId = 'stand-in-caller'; roleDefinitionId = "/subscriptions/$Id/providers/Microsoft.Authorization/roleDefinitions/stand-in-reader" } }) }
    }
    if ($Path -match '/providers/Microsoft\.Authorization/roleDefinitions/[^/?]+\?')
    {
        return & $Answer 200 @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } }
    }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/permissions\?') { return & $Answer 200 @{ value = @(@{ actions = @('*/read'); notActions = @() }) } }
    if ($Method -eq 'POST' -and $Path -like '/providers/Microsoft.ResourceGraph/resources*')
    {
        $Ids = @(($Payload | ConvertFrom-Json).subscriptions)
        return & $Answer 200 @{ data = @($Ids | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 1 } }) }
    }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Commerce/UsageAggregates\?')
    {
        return & $Answer 200 @{ value = @(@{ properties = @{ quantity = 1.5; meterCategory = 'Stand-in'; instanceData = '' } }) }
    }
    return & $Answer 404 @{ error = @{ code = 'NotFound'; message = 'stand-in: no answer for this path' } }
}
'@
    $Billing = @'
function Get-UsageAggregates
{
    [CmdletBinding()] param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, [switch]$ShowDetails, $ContinuationToken)
    [pscustomobject]@{ UsageAggregations = @(); ContinuationToken = $null }
}
'@
    foreach ($Module in @(@{ Name = 'Az.Accounts'; Body = $Accounts }, @{ Name = 'Az.Billing'; Body = $Billing }, @{ Name = 'Az.Compute'; Body = '' }, @{ Name = 'Az.Monitor'; Body = '' }))
    {
        $Dir = Join-Path $script:Modules (Join-Path $Module.Name '99.0.0')
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psm1')) -Value $Module.Body -Encoding utf8
        Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psd1')) -Value ("@{{ ModuleVersion = '99.0.0'; RootModule = '{0}.psm1'; FunctionsToExport = '*' }}" -f $Module.Name) -Encoding utf8
    }

    # The az command: signed in to the scenario's tenant, with a token.
    $script:Bin = Join-Path $script:TestBase 'bin'
    New-Item -ItemType Directory -Path $script:Bin -Force | Out-Null
    $Az = @'
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'show') { [pscustomobject]@{ tenantId = $Scenario.Tenant } | ConvertTo-Json -Compress; exit 0 }
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'get-access-token') { exit 0 }
exit 1
'@
    Set-Content -LiteralPath (Join-Path $script:Bin 'az.ps1') -Value $Az -Encoding utf8

    $script:Subs = @{}
    foreach ($Letter in 'A', 'B', 'C', 'D', 'E', 'F') { $script:Subs[$Letter] = @{ Id = ('sub-' + $Letter.ToLowerInvariant()); Name = ('Sub ' + $Letter) } }
    # The automatic stream count is 2 on a host with 4 logical processors.
    $script:FourCpu = @{ DOTNET_PROCESSOR_COUNT = '4' }

    # A fresh home (its InventoryReports folder is the run's inventory root) and
    # scenario for each test.
    function script:New-Case
    {
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseHome -Force | Out-Null
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        $script:State = Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Tenant)
    }

    # The scenario: subscriptions by letter, and which of them fail, hang or are disabled.
    function script:Set-Scenario
    {
        param([string[]]$Subs, [string[]]$Fail = @(), [string[]]$Hang = @(), [string[]]$Disabled = @())
        $Id = { param($L) $script:Subs[$L].Id }
        [pscustomobject]@{
            Tenant        = $script:Tenant
            Subscriptions = @($Subs | ForEach-Object { [pscustomobject]@{ Id = $script:Subs[$_].Id; Name = $script:Subs[$_].Name; State = $(if ($Disabled -contains $_) { 'Disabled' } else { 'Enabled' }) } })
            FailIds       = @($Fail | ForEach-Object { & $Id $_ })
            HangIds       = @($Hang | ForEach-Object { & $Id $_ })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One run of the wrapper as its own process, stdin closed. -Streams 0 leaves
    # -ParallelStreams out, so the run picks the automatic value. -EndWhen is
    # polled while the run is going; once it is true the process tree is killed,
    # as when a session ends. A run that has not ended after $TimeoutSeconds is
    # stopped and the test fails.
    function script:Invoke-Wrapper
    {
        param([string[]]$Arguments = @(), [int]$Streams = 1, [hashtable]$Environment = @{}, [scriptblock]$EndWhen, [int]$TimeoutSeconds = 300)
        $All = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper, '-TenantID', $script:Tenant)
        if ($Streams -gt 0) { $All += @('-ParallelStreams', [string]$Streams) }
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($Arg in @($All) + @($Arguments)) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['PATH'] = $script:Bin + [IO.Path]::PathSeparator + $env:PATH
        $Info.Environment['RDA_STANDIN_AZURE'] = $script:Scenario
        $Info.Environment['NO_COLOR'] = '1'
        foreach ($Key in $Environment.Keys) { $Info.Environment[$Key] = [string]$Environment[$Key] }
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $Out = $Proc.StandardOutput.ReadToEndAsync()
        $Err = $Proc.StandardError.ReadToEndAsync()
        $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $Ended = $false
        if ($EndWhen)
        {
            while (-not $Proc.HasExited -and (Get-Date) -lt $Deadline)
            {
                if (& $EndWhen) { $Proc.Kill($true); $Ended = $true; break }
                Start-Sleep -Milliseconds 250
            }
        }
        if (-not $Proc.WaitForExit([int][math]::Max(1000, ($Deadline - (Get-Date)).TotalMilliseconds)))
        {
            $Proc.Kill($true)
            throw ('The wrapper run did not end within {0} seconds.' -f $TimeoutSeconds)
        }
        $Proc.WaitForExit()
        if ($EndWhen -and -not $Ended) { throw 'The run ended before the point at which the test ends it.' }
        $Text = @(([string]$Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        return [pscustomobject]@{ ExitCode = $Proc.ExitCode; Text = $Text; Error = [string]$Err.Result }
    }

    # True once each listed subscription's collection has started to hang.
    function script:Test-Hanging
    {
        param([string[]]$Letters)
        @($Letters | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:CaseHome ('hang-' + $script:Subs[$_].Id))) }).Count -eq 0
    }

    # The resume state as written, or $null when there is none.
    function script:Read-State
    {
        if (-not (Test-Path -LiteralPath $script:State)) { return $null }
        $Raw = Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json
        return [pscustomobject]@{
            Completed = @($Raw.CompletedSubscriptionIds | Where-Object { $_ } | Sort-Object)
            Failed    = @($Raw.FailedAttempts | Where-Object { $_ } | ForEach-Object { $_.Id } | Sort-Object)
        }
    }

    # The per-stream state files, and every other file whose name starts like one.
    function script:Get-StreamFiles
    {
        if (-not (Test-Path -LiteralPath $script:Root)) { return @() }
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter ('.resume-state-{0}-stream-*.json' -f $script:Tenant))
    }
    function script:Get-StreamLikeFiles
    {
        if (-not (Test-Path -LiteralPath $script:Root)) { return @() }
        @(Get-ChildItem -LiteralPath $script:Root -Force -File | Where-Object { $_.Name -like ('.resume-state-{0}-stream-*' -f $script:Tenant) })
    }
    # The ids the per-stream state files record as completed, and as failed.
    function script:Get-StreamCompletedIds
    {
        @(script:Get-StreamFiles | ForEach-Object { $Raw = Get-Content -LiteralPath $_.FullName -Raw; if ($Raw) { @(($Raw | ConvertFrom-Json).Completed) } } | Where-Object { $_ } | Sort-Object -Unique)
    }
    function script:Get-StreamFailedIds
    {
        @(script:Get-StreamFiles | ForEach-Object { $Raw = Get-Content -LiteralPath $_.FullName -Raw; if ($Raw) { @(($Raw | ConvertFrom-Json).FailedAttempts | Where-Object { $_ } | ForEach-Object { $_.Id }) } } | Where-Object { $_ } | Sort-Object -Unique)
    }

    # The ids of the subscriptions a run collected, sorted.
    function script:Get-Collected
    {
        param($Run)
        @($Run.Text | ForEach-Object { if ($_ -match '^(?:\[stream-\d+\] processing \(\d+ of \d+\): |Processing subscription: ).+ \((sub-[a-z]+)\)$') { $Matches[1] } } | Sort-Object)
    }
    function script:Get-RecoveryLines { param($Run) @($Run.Text | Where-Object { $_ -like 'Recovered per-stream state*' }) }
    function script:Get-StreamWarningLines { param($Run) @($Run.Text | Where-Object { $_ -like 'WARNING: The per-stream state file*' }) }
    function script:Test-CleanLine { param($Run) @($Run.Text | Where-Object { $_ -eq 'Resume state cleared (clean run).' }).Count -eq 1 }
    function script:Get-Ids { param([string[]]$Letters) @($Letters | ForEach-Object { $script:Subs[$_].Id } | Sort-Object) }
    # The ids the resume state lists as completed, split where an id was joined
    # onto the one before it, or none when there is no state.
    function script:Get-StateCompleted { $S = script:Read-State; if ($null -eq $S) { return @() } @($S.Completed | ForEach-Object { [regex]::Matches([string]$_, 'sub-[a-f]') | ForEach-Object { $_.Value } } | Sort-Object -Unique) }

    # Every entry of every zip under the inventory root, the zips inside them
    # included: { Zip; Name; Text }.
    function script:Get-ZipEntries
    {
        $Found = [System.Collections.Generic.List[object]]::new()
        $ReadArchive = {
            param([System.IO.Compression.ZipArchive]$Archive, [string]$Label)
            foreach ($Entry in @($Archive.Entries))
            {
                $Buffer = [System.IO.MemoryStream]::new()
                $Stream = $Entry.Open()
                try { $Stream.CopyTo($Buffer) } finally { $Stream.Dispose() }
                $Found.Add([pscustomobject]@{ Zip = $Label; Name = $Entry.FullName; Text = [System.Text.Encoding]::UTF8.GetString($Buffer.ToArray()) })
                if ($Entry.FullName -like '*.zip')
                {
                    $Buffer.Position = 0
                    $Inner = [System.IO.Compression.ZipArchive]::new($Buffer, [System.IO.Compression.ZipArchiveMode]::Read)
                    try { & $ReadArchive $Inner ($Label + '!' + $Entry.FullName) } finally { $Inner.Dispose() }
                }
            }
        }
        foreach ($Zip in @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force -File -Filter '*.zip'))
        {
            $Archive = [System.IO.Compression.ZipFile]::OpenRead($Zip.FullName)
            try { & $ReadArchive $Archive $Zip.Name } finally { $Archive.Dispose() }
        }
        return $Found.ToArray()
    }

    # The subscription ids of the per-subscription reports inside the newest
    # consolidated zip, sorted.
    function script:Get-NewestBundleReportIds
    {
        $Newest = @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'AllSubscriptions_*.zip' | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)
        if ($Newest.Count -eq 0) { return @() }
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Newest[0].FullName)
        try { @($Archive.Entries | Where-Object { $_.FullName -like 'ResourcesReport_*.zip' } | ForEach-Object { $_.FullName -replace '^.*\d(sub-[a-z]+)\.zip$', '$1' } | Sort-Object) }
        finally { $Archive.Dispose() }
    }

    # Interrupted 3-stream run over A to F: streams 0, 1 and 2 hold A and D, B
    # and E, C and F; A, B and C complete, then D, E and F hang and the run is
    # ended. -Fail makes the listed ones of A, B and C fail instead.
    function script:Invoke-InterruptedThreeStreamRun
    {
        param([string[]]$Fail = @())
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F' -Fail $Fail -Hang 'D', 'E', 'F'
        $Expected = @('A', 'B', 'C' | Where-Object { $Fail -notcontains $_ } | ForEach-Object { $script:Subs[$_].Id }) -join ','
        $null = script:Invoke-Wrapper -Streams 3 -EndWhen { (script:Test-Hanging 'D', 'E', 'F') -and ((script:Get-StreamCompletedIds) -join ',') -eq $Expected }
        @(script:Get-StreamFiles).Count | Should -Be 3
    }
}

AfterAll {
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'Parallel -Resume collects only what no earlier run completed' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    It 'after a parallel run that finished with failures (-ParallelStreams <Streams>)' -ForEach @(@{ Streams = 2 }, @{ Streams = 0 }) {
        # Finished 2-stream run: A and B complete, C and D fail. Its merge folds
        # the per-stream files into the resume state and deletes them.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'C', 'D'
        $null = script:Invoke-Wrapper -Streams 2
        (script:Read-State).Completed | Should -Be (script:Get-Ids 'A', 'B')

        # Run 1: D still fails.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'D'
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams -Environment $script:FourCpu
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'C', 'D')
        $R1.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        $R1.Text | Should -Contain 'Skipping (already completed): Sub B (sub-b)'
        $R1.Text | Should -Contain 'Parallel-streams mode: 2 streams across 2 subscription(s) to process'
        $R1.Text | Should -Contain 'Subscriptions Skipped:   2 (already completed)'
        $R1.Text | Should -Contain 'Subscriptions Processed: 2'
        (script:Read-State).Completed | Should -Be (script:Get-Ids 'A', 'B', 'C')
        (script:Read-State).Failed | Should -Be (script:Get-Ids 'D')

        # Run 2: only D is left; it goes on the one-subscription path and the state clears.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams -Environment $script:FourCpu
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'D')
        $R2.Text | Should -Contain 'Only one subscription to process; running sequentially.'
        $R2.Text | Should -Contain 'Subscriptions Skipped:   3 (already completed)'
        script:Test-CleanLine $R2 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
        $R2.ExitCode | Should -Be 0
        # The consolidated zip of run 2 holds D's report, collected by this run.
        @(script:Get-NewestBundleReportIds | Where-Object { $_ -eq 'sub-d' }).Count | Should -Be 1
    }

    It 'after an interrupted run with more streams than the -Resume uses, and the next two runs end clean' {
        script:Invoke-InterruptedThreeStreamRun
        # The stream files hold real failure records only.
        foreach ($File in script:Get-StreamFiles)
        {
            @((Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json).FailedAttempts).Count | Should -Be 0 -Because ('{0} records no failure' -f $File.Name)
        }

        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F'
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-RecoveryLines $R1 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 3 completed, 0 failed subscription record(s).')
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'D', 'E', 'F')
        $R1.Text | Should -Contain 'Skipping (already completed): Sub C (sub-c)'
        $R1.Text | Should -Contain 'Subscriptions Skipped:   3 (already completed)'
        script:Test-CleanLine $R1 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        # Run 2 finds no state: a new collection of everything, with nothing recovered.
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-RecoveryLines $R2 | Should -BeNullOrEmpty
        $R2.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D', 'E', 'F')
        script:Test-CleanLine $R2 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
    }

    It 'on the one-subscription path, which collects a completed subscription no more' {
        # Interrupted 2-stream run: A completes, B hangs.
        script:Set-Scenario -Subs 'A', 'B' -Hang 'B'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { (script:Test-Hanging 'B') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-a' }

        # Run 1: B is disabled now, so A is the one eligible subscription.
        script:Set-Scenario -Subs 'A', 'B' -Disabled 'B'
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-Collected $R1 | Should -BeNullOrEmpty
        $R1.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        $R1.Text | Should -Contain 'Nothing left to process: every eligible subscription was completed by an earlier run.'
        script:Test-CleanLine $R1 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty -Because 'the state cleared, so the stream file folded in at startup is deleted'

        # Run 2: nothing is recovered; with no state, A is collected as a new run.
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-RecoveryLines $R2 | Should -BeNullOrEmpty
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A')
        script:Test-CleanLine $R2 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
    }
}

Describe 'A one-stream run that clears the resume state deletes the per-stream files it folded in' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    It 'one-stream -Resume, then <Next>' -ForEach @(@{ Next = '-Resume' }, @{ Next = '-ResumeFailedOnly' }) {
        # Interrupted 2-stream run: stream 0 completes A, stream 1 fails B, then C and D hang.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { script:Test-Hanging 'C', 'D' }
        @(script:Get-StreamFiles).Count | Should -Be 2

        # Run 1, one stream: B succeeds now, everything left is collected, the state clears.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R1 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'B', 'C', 'D')
        script:Test-CleanLine $R1 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        # Run 2 recovers nothing: -Resume skips nothing, -ResumeFailedOnly has nothing to retry.
        $R2 = script:Invoke-Wrapper -Arguments $Next -Streams 1
        script:Get-RecoveryLines $R2 | Should -BeNullOrEmpty
        $R2.Text | Should -Not -Contain 'Skipping (already completed): Sub A (sub-a)'
        if ($Next -eq '-Resume')
        {
            script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
            script:Test-CleanLine $R2 | Should -BeTrue
        }
        else
        {
            $R2.Text | Should -Contain 'ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry.'
            script:Get-Collected $R2 | Should -BeNullOrEmpty
        }
        $R2.ExitCode | Should -Be 0
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
    }

    It '-ResumeFailedOnly with the automatic stream count, then -Resume twice' {
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { script:Test-Hanging 'C', 'D' }

        # Run 1: only B is retried (one subscription, so one stream), and it
        # succeeds. Whether the state is cleared or kept, the per-stream files go.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 0 -Environment $script:FourCpu
        script:Get-RecoveryLines $R1 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'B')
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        # Runs 2 and 3 recover nothing and collect exactly what the state does
        # not list as completed, with two streams when that is more than one.
        foreach ($Run in 1..2)
        {
            $Done = @(script:Get-StateCompleted)
            $R = script:Invoke-Wrapper -Arguments '-Resume' -Streams 0 -Environment $script:FourCpu
            script:Get-RecoveryLines $R | Should -BeNullOrEmpty
            script:Get-Collected $R | Should -Be @(script:Get-Ids 'A', 'B', 'C', 'D' | Where-Object { $Done -notcontains $_ })
            script:Test-CleanLine $R | Should -BeTrue
            script:Read-State | Should -BeNullOrEmpty
        }
    }
}

Describe 'A run that keeps the resume state deletes the per-stream files it folded in, once the state holds their records' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    It 'one-stream <Mode> that keeps the state, then the same twice: the recovery line prints in the first run only' -ForEach @(@{ Mode = '-Resume' }, @{ Mode = '-ResumeFailedOnly' }) {
        # Interrupted 2-stream run: stream 0 completes A, stream 1 fails B, then C and D hang.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { script:Test-Hanging 'C', 'D' }
        @(script:Get-StreamFiles).Count | Should -Be 2

        # Run 1: B fails again, so the state is kept.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B'
        $R1 = script:Invoke-Wrapper -Arguments $Mode -Streams 1
        script:Get-RecoveryLines $R1 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        script:Test-CleanLine $R1 | Should -BeFalse
        (script:Read-State).Failed | Should -Be (script:Get-Ids 'B')
        (script:Read-State).Completed | Should -Contain 'sub-a'
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty -Because 'the resume state holds the records of both per-stream files'
        @($R1.Text | Where-Object { $_ -like 'WARNING: The resume state file*' }) | Should -BeNullOrEmpty

        # Runs 2 and 3: no recovery line, and nothing the state lists as completed is collected.
        foreach ($Run in 1..2)
        {
            $Done = @(script:Get-StateCompleted)
            $R = script:Invoke-Wrapper -Arguments $Mode -Streams 1
            script:Get-RecoveryLines $R | Should -BeNullOrEmpty
            @(script:Get-Collected $R | Where-Object { $Done -contains $_ }) | Should -BeNullOrEmpty
            @(script:Get-Collected $R) | Should -Not -Contain 'sub-a'
            @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
        }
    }

    It '-ResumeFailedOnly with nothing to retry, then the same and -Resume: the recovery line prints in the first run only' {
        # Interrupted 2-stream run in which nothing fails: A and B complete, then C and D hang.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { (script:Test-Hanging 'C', 'D') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-a,sub-b' }
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'

        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        script:Get-RecoveryLines $R1 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 2 completed, 0 failed subscription record(s).')
        script:Get-Collected $R1 | Should -BeNullOrEmpty
        $R1.ExitCode | Should -Be 0
        (script:Read-State).Completed | Should -Be (script:Get-Ids 'A', 'B')
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        $R2 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        script:Get-RecoveryLines $R2 | Should -BeNullOrEmpty
        script:Get-Collected $R2 | Should -BeNullOrEmpty

        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R3 | Should -BeNullOrEmpty
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'C', 'D')
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
    }

    It 'keeps them, with a warning naming them, while the resume state cannot be written; the next run recovers their records' {
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { script:Test-Hanging 'C', 'D' }
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        $Names.Count | Should -Be 2
        # The resume state is written through <state>.tmp; a folder of that name
        # (not empty) makes every write of it fail.
        $Block = $script:State + '.tmp'
        New-Item -ItemType Directory -Path $Block -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Block 'keep') -Value 'x'

        # Run 1: B fails again, so the state would be kept, but it cannot be written.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B'
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R1 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        @($R1.Text | Where-Object { $_ -like 'WARNING: Failed to persist resume state to*' }).Count | Should -BeGreaterThan 0
        $Warning = @($R1.Text | Where-Object { $_ -like 'WARNING: The resume state file*' })
        $Warning.Count | Should -Be 1
        $Warning[0] | Should -Be ('WARNING: The resume state file .resume-state-{0}.json could not be written or read back with every record of the per-stream state files this run read at startup, so they are kept and a later -Resume reads them again: {1}' -f $script:Tenant, ($Names -join ', '))
        script:Test-CleanLine $R1 | Should -BeFalse
        @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $Names

        # Run 2: the state can be written again. The kept files are recovered,
        # A is skipped, B succeeds and the state clears with the files.
        Remove-Item -LiteralPath $Block -Recurse -Force
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R2 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        $R2.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B', 'C', 'D')
        script:Test-CleanLine $R2 | Should -BeTrue
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        # Run 3 finds no state.
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R3 | Should -BeNullOrEmpty
        $R3.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Test-CleanLine $R3 | Should -BeTrue
    }
}

Describe 'A per-stream state file the end-of-run merge cannot read' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    It 'is named, moved aside and never reported as a clean run (stream file <Kind>, run 1 <Run1>)' -ForEach @(
        @{ Kind = 'cut short'; Run1 = 'without -Resume' }
        @{ Kind = 'empty'; Run1 = 'without -Resume' }
        @{ Kind = 'cut short'; Run1 = '-Resume' }
        @{ Kind = 'empty'; Run1 = '-Resume' }
    ) {
        script:Invoke-InterruptedThreeStreamRun
        # A write of the stream 2 file that was cut short.
        $Bad = Join-Path $script:Root ('.resume-state-{0}-stream-2.json' -f $script:Tenant)
        if ($Kind -eq 'empty') { [System.IO.File]::WriteAllBytes($Bad, [byte[]]@()) }
        else { $Raw = Get-Content -LiteralPath $Bad -Raw; Set-Content -LiteralPath $Bad -Value $Raw.Substring(0, [int]($Raw.Length / 2)) -NoNewline -Encoding utf8 }

        # Run 1 uses 2 streams, so no stream of it rewrites the stream 2 file. A
        # run without -Resume collects everything and reads the per-stream files
        # only in its end-of-run merge.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F'
        $Resuming = $Run1 -eq '-Resume'
        $R1 = script:Invoke-Wrapper -Arguments @(if ($Resuming) { '-Resume' }) -Streams 2
        # On -Resume, C was recorded only in the unreadable file, so it is collected.
        script:Get-Collected $R1 | Should -Be $(if ($Resuming) { script:Get-Ids 'C', 'D', 'E', 'F' } else { script:Get-Ids 'A', 'B', 'C', 'D', 'E', 'F' })
        $Warnings = @(script:Get-StreamWarningLines $R1)
        $Warnings.Count | Should -Be 1
        script:Test-CleanLine $R1 | Should -BeFalse
        $Moved = @(script:Get-StreamLikeFiles)
        $Moved.Count | Should -Be 1
        $Moved[0].Name | Should -Match ('^\.resume-state-{0}-stream-2\.json\.unreadable-\d{{8}}-\d{{6}}$' -f [regex]::Escape($script:Tenant))
        @(script:Get-StreamFiles) | Should -BeNullOrEmpty
        $Name = '.resume-state-{0}-stream-2.json' -f $script:Tenant
        # The warning names the file and where it went, whichever step found it.
        $Warnings[0] | Should -BeLike ('WARNING: The per-stream state file {0}*could not be read, so its records are not used: the subscriptions it lists are not counted as completed* It was moved aside to {1}.' -f $Name, $Moved[0].Name)
        if (-not $Resuming)
        {
            $Warnings[0] | Should -Be ('WARNING: The per-stream state file {0} could not be read, so its records are not used: the subscriptions it lists are not counted as completed, and a later -Resume collects them again. It was moved aside to {1}.' -f $Name, $Moved[0].Name)
        }
        $R1.Text | Should -Contain ('Resume state cleared, but not a clean run: the per-stream state file {0} could not be read and was moved aside to {1}; its records were not used.' -f $Name, $Moved[0].Name)
        script:Read-State | Should -BeNullOrEmpty
        $R1.ExitCode | Should -Be 0
        # No zip holds a resume state file, the moved one included.
        @(script:Get-ZipEntries | Where-Object { $_.Name -like '*resume-state*' -or $_.Text -like '*resume-state*' }) | Should -BeNullOrEmpty

        # Runs 2 and 3: nothing is recovered or reported again, and each ends clean.
        foreach ($Run in 1..2)
        {
            $R = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
            script:Get-StreamWarningLines $R | Should -BeNullOrEmpty
            script:Get-RecoveryLines $R | Should -BeNullOrEmpty
            $R.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
            script:Test-CleanLine $R | Should -BeTrue
            script:Read-State | Should -BeNullOrEmpty
            @(script:Get-StreamLikeFiles).Count | Should -Be 1 -Because 'the moved file is kept for inspection and read by no run'
        }
    }

    It 'keeps the state while a failure is left, and the next -Resume collects what only that file recorded' {
        # Interrupted 3-stream run: streams 0, 1 and 2 hold A and D, B and E, C
        # and F. C completes, A, B and E fail, then D and F hang.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F' -Fail 'A', 'B', 'E' -Hang 'D', 'F'
        $null = script:Invoke-Wrapper -Streams 3 -EndWhen { (script:Test-Hanging 'D', 'F') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-c' -and ((script:Get-StreamFailedIds) -join ',') -eq 'sub-a,sub-b,sub-e' }
        $Bad = Join-Path $script:Root ('.resume-state-{0}-stream-2.json' -f $script:Tenant)
        $Raw = Get-Content -LiteralPath $Bad -Raw
        Set-Content -LiteralPath $Bad -Value $Raw.Substring(0, [int]($Raw.Length / 2)) -NoNewline -Encoding utf8

        # Run 1: -ResumeFailedOnly retries A, B and E with two streams; B fails again.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F' -Fail 'B'
        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 2
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'E')
        @(script:Get-StreamWarningLines $R1).Count | Should -Be 1
        script:Test-CleanLine $R1 | Should -BeFalse
        $R1.Text | Where-Object { $_ -like 'Resume state kept, but not a clean run: the per-stream state file .resume-state-*-stream-2.json could not be read and was moved aside to *' } | Should -Not -BeNullOrEmpty
        (script:Read-State).Completed | Should -Be (script:Get-Ids 'A', 'E') -Because 'C was recorded as completed only in the unreadable file'
        (script:Read-State).Failed | Should -Be (script:Get-Ids 'B')
        @(script:Get-StreamFiles) | Should -BeNullOrEmpty

        # Run 2: -Resume collects C and what was never reached; B succeeds now.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-StreamWarningLines $R2 | Should -BeNullOrEmpty
        script:Get-RecoveryLines $R2 | Should -BeNullOrEmpty
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B', 'C', 'D', 'F')
        script:Test-CleanLine $R2 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty

        # Run 3 finds no state.
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-RecoveryLines $R3 | Should -BeNullOrEmpty
        $R3.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Test-CleanLine $R3 | Should -BeTrue
    }
}

Describe 'Read-StreamResumeStateFile, Move-UnreadableStreamStateFile and Get-ResumeStateRecordMismatch' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
        $script:UnitDir = Join-Path $script:TestBase ('unit-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:UnitDir -Force | Out-Null
    }

    It 'reads a stream file as written, and returns $null for content that is <Case>' -ForEach @(
        @{ Case = 'cut short'; Content = '{"Tenant":"t","StreamId":"0","Completed":["sub-a"' }
        @{ Case = 'empty'; Content = '' }
        @{ Case = 'whitespace'; Content = "  `n" }
        @{ Case = 'not an object'; Content = '["sub-a"]' }
    ) {
        $Good = Join-Path $script:UnitDir 'good.json'
        Set-Content -LiteralPath $Good -Value '{"Tenant":"t","StreamId":"0","Completed":["sub-a"],"FailedAttempts":[]}' -Encoding utf8
        (Read-StreamResumeStateFile -Path $Good).Completed | Should -Be @('sub-a')
        $Bad = Join-Path $script:UnitDir ('bad-' + [guid]::NewGuid().ToString().Substring(0, 8) + '.json')
        [System.IO.File]::WriteAllText($Bad, $Content)
        Read-StreamResumeStateFile -Path $Bad | Should -BeNullOrEmpty
        Read-StreamResumeStateFile -Path (Join-Path $script:UnitDir 'missing.json') | Should -BeNullOrEmpty
    }

    It 'renames the file with the UTC time and names it in the warning' {
        $Path = Join-Path $script:UnitDir '.resume-state-t-stream-3.json'
        Set-Content -LiteralPath $Path -Value '{' -Encoding utf8
        $Out = Move-UnreadableStreamStateFile -File (Get-Item -Force -LiteralPath $Path) -Now ([datetime]'2026-01-02T03:04:05Z').ToUniversalTime() 6>&1
        $Result = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        $Result.Name | Should -Be '.resume-state-t-stream-3.json'
        $Result.MovedTo | Should -Be '.resume-state-t-stream-3.json.unreadable-20260102-030405'
        Test-Path -LiteralPath $Path | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:UnitDir $Result.MovedTo) | Should -BeTrue
        $Warning = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ })
        $Warning.Count | Should -Be 1
        $Warning[0] | Should -BeLike 'WARNING: The per-stream state file .resume-state-t-stream-3.json*could not be read, so its records are not used: * It was moved aside to .resume-state-t-stream-3.json.unreadable-20260102-030405.'
    }

    It 'Get-ResumeStateRecordMismatch names the ids whose record on disk is not the run''s' {
        $Path = Join-Path $script:UnitDir '.resume-state-t.json'
        $Run = @{ CompletedIds = @('sub-a', 'sub-c'); FailedAttempts = @([pscustomobject]@{ Id = 'sub-b'; Attempts = 2 }) }
        $Ids = @('sub-a', 'sub-b')
        # No file, or one that cannot be read or is for another tenant: every id.
        Get-ResumeStateRecordMismatch -Path $Path -Tenant 't' -Ids $Ids @Run | Should -Be @('sub-a', 'sub-b')
        Set-Content -LiteralPath $Path -Value '{"TenantID":"t","Compl' -Encoding utf8
        Get-ResumeStateRecordMismatch -Path $Path -Tenant 't' -Ids $Ids @Run | Should -Be @('sub-a', 'sub-b')
        Set-Content -LiteralPath $Path -Value '{"TenantID":"other","CompletedSubscriptionIds":["sub-a","sub-c"],"FailedAttempts":[{"Id":"sub-b","Attempts":2}]}' -Encoding utf8
        Get-ResumeStateRecordMismatch -Path $Path -Tenant 't' -Ids $Ids @Run | Should -Be @('sub-a', 'sub-b')
        # The same records: none.
        Set-Content -LiteralPath $Path -Value '{"TenantID":"t","CompletedSubscriptionIds":["sub-a","sub-c"],"FailedAttempts":[{"Id":"sub-b","Attempts":2}]}' -Encoding utf8
        @(Get-ResumeStateRecordMismatch -Path $Path -Tenant 't' -Ids $Ids @Run) | Should -BeNullOrEmpty
        # An older count, a missing completed id, a record the run no longer has.
        Set-Content -LiteralPath $Path -Value '{"TenantID":"t","CompletedSubscriptionIds":["sub-c"],"FailedAttempts":[{"Id":"sub-b","Attempts":1}]}' -Encoding utf8
        Get-ResumeStateRecordMismatch -Path $Path -Tenant 't' -Ids $Ids @Run | Should -Be @('sub-a', 'sub-b')
        Set-Content -LiteralPath $Path -Value '{"TenantID":"t","CompletedSubscriptionIds":["sub-a","sub-c"],"FailedAttempts":[{"Id":"sub-b","Attempts":2},{"Id":"sub-d","Attempts":1}]}' -Encoding utf8
        Get-ResumeStateRecordMismatch -Path $Path -Tenant 't' -Ids @('sub-a', 'sub-d') @Run | Should -Be @('sub-d')
        # No ids: nothing to hold.
        @(Get-ResumeStateRecordMismatch -Path (Join-Path $script:UnitDir 'missing.json') -Tenant 't' -Ids @() @Run) | Should -BeNullOrEmpty
    }

    It 'leaves the file in place and says so when it cannot be renamed' {
        $Path = Join-Path $script:UnitDir '.resume-state-t-stream-4.json'
        Set-Content -LiteralPath $Path -Value '{' -Encoding utf8
        # A folder already has the new name, so the rename fails.
        New-Item -ItemType Directory -Path (Join-Path $script:UnitDir '.resume-state-t-stream-4.json.unreadable-20260102-030405') -Force | Out-Null
        $Out = Move-UnreadableStreamStateFile -File (Get-Item -Force -LiteralPath $Path) -Now ([datetime]'2026-01-02T03:04:05Z').ToUniversalTime() 6>&1
        $Result = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        $Result.MovedTo | Should -BeNullOrEmpty
        Test-Path -LiteralPath $Path | Should -BeTrue
        $Warning = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ })
        $Warning.Count | Should -Be 1
        $Warning[0] | Should -BeLike 'WARNING: The per-stream state file .resume-state-t-stream-4.json*could not be read, * It could not be moved aside (*), so a later * finds it again.'
        $Summary = @(Write-UnreadableStreamStateSummary -Unreadable @($Result) -StateKept $true 6>&1 | ForEach-Object { [string]$_ })
        $Summary | Should -Be @('Resume state kept, but not a clean run: the per-stream state file .resume-state-t-stream-4.json could not be read and was left in place (it could not be moved aside); its records were not used.')
    }
}

Describe 'The recovery line after an interrupted parallel run' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    It 'counts no failure for the null entry a stream file written by an older worker holds' {
        # Stream files as an older worker wrote them when nothing had failed.
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        foreach ($Stream in @(@{ N = '0'; Id = 'sub-a' }, @{ N = '1'; Id = 'sub-b' }))
        {
            Set-Content -LiteralPath (Join-Path $script:Root ('.resume-state-{0}-stream-{1}.json' -f $script:Tenant, $Stream.N)) -Encoding utf8 -Value (@{ Tenant = $script:Tenant; StreamId = $Stream.N; Completed = @($Stream.Id); FailedAttempts = @($null) } | ConvertTo-Json -Depth 4)
        }
        script:Set-Scenario -Subs 'A', 'B', 'C'
        $R = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R | Should -Be @('Recovered per-stream state from an interrupted parallel run: 2 completed, 0 failed subscription record(s).')
        script:Get-Collected $R | Should -Be (script:Get-Ids 'C')
        script:Test-CleanLine $R | Should -BeTrue
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
    }
}
