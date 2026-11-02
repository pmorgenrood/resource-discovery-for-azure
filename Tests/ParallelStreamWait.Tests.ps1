# Parallel-streams wait tests
#
# The parallel wrapper waits for its stream jobs and then reads each stream's
# summary. These tests hold one stream's job in a state other than Running once
# the other stream has finished:
#   - Blocked: the stream's run shows a prompt (three in a row). The wrapper's
#     Receive-Job answers each one (this process is non-interactive, so each
#     Read-Host fails), and the stream goes on. The wrapper must wait for it and
#     collect every subscription.
#   - Worker gone: the stream's worker process is killed, as by the out-of-memory
#     killer. PowerShell keeps that job Running for about 60 seconds and then
#     fails it. The run must end and report the stream as failed.
#
# Every run is Run-AllSubscriptions.ps1 itself, started as its own pwsh process
# (stdin closed) from a copy of the tool whose ResourceInventory.ps1 is a
# stand-in. Azure is a set of stand-in Az modules and an az.ps1, found first on
# the module path and PATH of that process. The process's home is a scratch
# folder, so the run writes its inventory root under it. On Windows the wrapper
# writes to C:\InventoryReports instead, so these tests do not run there.
#
# Run with: Invoke-Pester ./Tests/ParallelStreamWait.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('ParallelStreamWait_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
    $script:Tenant = '12345678-1234-1234-1234-123456789012'
    $script:Pwsh = Join-Path $PSHOME 'pwsh'

    # --- The tool: the wrapper and its helpers as they are, and a stand-in
    # ResourceInventory.ps1 that writes one report folder and zip per call.
    $script:ToolRoot = Join-Path $script:TestBase 'tool'
    New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
    foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Version.json', 'Functions', 'Extension'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:ToolRoot -Recurse -Force
    }
    $script:Wrapper = Join-Path $script:ToolRoot 'Run-AllSubscriptions.ps1'
    @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
# Once stream 1 has written its summary, this stream either prompts three times
# (its job is Blocked until the wrapper answers) or its worker process is killed.
if (@($Scenario.PromptIds) -contains $SubscriptionID -or @($Scenario.DieIds) -contains $SubscriptionID)
{
    $OtherDone = Join-Path (Join-Path $HOME 'InventoryReports') '.rda-stream-1-summary.json'
    $Deadline = (Get-Date).AddSeconds(240)
    while (-not (Test-Path -LiteralPath $OtherDone) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 100 }
    if (@($Scenario.DieIds) -contains $SubscriptionID) { Stop-Process -Id $PID -Force }
    foreach ($N in 1..3)
    {
        try { $null = Read-Host 'stand-in prompt' }
        catch { Add-Content -LiteralPath (Join-Path $HOME ('answered-' + $SubscriptionID)) -Value $_.Exception.Message }
        Start-Sleep -Seconds 2
    }
}
$Root = Join-Path $HOME 'InventoryReports'
$Stamp = (Get-Date -Format 'yyyyMMddHHmmssfff') + $SubscriptionID
$Folder = Join-Path $Root ('ResourcesReport' + $Stamp)
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Folder ('Inventory_ResourcesReport_{0}.json' -f $Stamp)) -Value ('{"VirtualMachines":[{"Name":"vm","Subscription":"' + $SubscriptionID + '"}]}') -Encoding utf8
$Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
Compress-Archive -Path (Join-Path $Folder '*.json') -DestinationPath $Zip -Force
$Global:ZipOutputFile = $Zip
$Global:Resources = @(1)
$Global:ResourceCount = 1
'@ | Set-Content -LiteralPath (Join-Path $script:ToolRoot 'ResourceInventory.ps1') -Encoding utf8

    # --- Stand-in Azure: sign-in, context, token and subscription calls, the
    # Resource Manager paths a run reads, and the az CLI sign-in checks.
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
function Get-AzContextAutosaveSetting { [CmdletBinding()] param($Scope) [pscustomobject]@{ Mode = 'Process'; ContextFile = 'None'; CacheFile = 'None' } }
function Connect-AzAccount { [CmdletBinding()] param($Tenant, [switch]$UseDeviceAuthentication) throw 'stand-in: no sign-in expected' }
function Get-AzAccessToken
{
    [CmdletBinding()] param($TenantId, $ResourceUrl, [switch]$AsSecureString)
    # The token names the caller's object id, which the up-front role check reads.
    $Claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"stand-in-caller"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [pscustomobject]@{ Token = ('e30.{0}.c2ln' -f $Claims); Type = 'Bearer'; ExpiresOn = (Get-Date).AddHours(1) }
}
function Get-AzSubscription
{
    [CmdletBinding()] param($TenantId, $SubscriptionId)
    $Scenario = Get-RdaStandInScenario
    @($Scenario.Subscriptions | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SubscriptionId = $_.Id; Name = $_.Name; State = 'Enabled'; TenantId = $Scenario.Tenant } })
}
function Invoke-AzRestMethod
{
    [CmdletBinding()] param([string]$Method = 'GET', [string]$Path, [string]$Payload)
    $Answer = { param([int]$Status, $Body) [pscustomobject]@{ StatusCode = $Status; Content = (ConvertTo-Json -InputObject $Body -Depth 8 -Compress); Headers = @{} } }
    if ($Path -match '^/subscriptions/([^/?]+)/resourcegroups\?') { return & $Answer 200 @{ value = @() } }
    # The up-front access and usage checks: Reader at every subscription for the
    # caller, one resource each, and one usage row above zero.
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
    $script:Bin = Join-Path $script:TestBase 'bin'
    New-Item -ItemType Directory -Path $script:Bin -Force | Out-Null
    @'
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'show') { [pscustomobject]@{ tenantId = $Scenario.Tenant } | ConvertTo-Json -Compress; exit 0 }
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'get-access-token') { exit 0 }
exit 1
'@ | Set-Content -LiteralPath (Join-Path $script:Bin 'az.ps1') -Encoding utf8

    # A fresh home (its InventoryReports folder is the run's inventory root) and
    # scenario for each test: subscriptions A, B and C, so stream 0 holds A and C
    # and stream 1 holds B.
    function script:New-Case
    {
        param([string[]]$PromptIds = @(), [string[]]$DieIds = @())
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseHome -Force | Out-Null
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        [pscustomobject]@{
            Tenant        = $script:Tenant
            Subscriptions = @('A', 'B', 'C' | ForEach-Object { [pscustomobject]@{ Id = ('sub-' + $_.ToLowerInvariant()); Name = ('Sub ' + $_) } })
            PromptIds     = @($PromptIds)
            DieIds        = @($DieIds)
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One run of the wrapper as its own process, stdin closed. A run that has not
    # ended after $TimeoutSeconds is stopped and the test fails.
    function script:Invoke-Wrapper
    {
        param([int]$TimeoutSeconds = 180)
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($Arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper, '-TenantID', $script:Tenant, '-ParallelStreams', '2')) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
        $Info.Environment['PATH'] = $script:Bin + [IO.Path]::PathSeparator + $env:PATH
        $Info.Environment['RDA_STANDIN_AZURE'] = $script:Scenario
        $Info.Environment['NO_COLOR'] = '1'
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $Out = $Proc.StandardOutput.ReadToEndAsync()
        $Err = $Proc.StandardError.ReadToEndAsync()
        if (-not $Proc.WaitForExit($TimeoutSeconds * 1000))
        {
            $Proc.Kill($true)
            throw ('The wrapper run did not end within {0} seconds.' -f $TimeoutSeconds)
        }
        $Proc.WaitForExit()
        $Text = @(([string]$Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        return [pscustomobject]@{ ExitCode = $Proc.ExitCode; Text = $Text; Error = [string]$Err.Result }
    }

    # The ids of the subscriptions a run started to collect, sorted.
    function script:Get-Collected
    {
        param($Run)
        @($Run.Text | ForEach-Object { if ($_ -match '^\[stream-\d+\] processing \(\d+ of \d+\): .+ \((sub-[a-z]+)\)$') { $Matches[1] } } | Sort-Object)
    }
    function script:Get-NoSummaryLines { param($Run) @($Run.Text | Where-Object { $_ -like '`[stream-*`] WARNING: no summary file at *' }) }
}

AfterAll {
    if ($script:TestBase -and (Test-Path -LiteralPath $script:TestBase)) { Remove-Item -LiteralPath $script:TestBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'The parallel wrapper waits for every stream job to finish' -Skip:$IsWindows {
    It 'waits for a stream whose job is Blocked on a prompt, and collects every subscription' {
        script:New-Case -PromptIds 'sub-a'
        $Run = script:Invoke-Wrapper
        script:Get-Collected $Run | Should -Be @('sub-a', 'sub-b', 'sub-c')
        script:Get-NoSummaryLines $Run | Should -BeNullOrEmpty
        # Each prompt was shown by the wrapper's Receive-Job and failed there.
        @(Get-Content -LiteralPath (Join-Path $script:CaseHome 'answered-sub-a')) | Should -HaveCount 3
        @($Run.Text | Where-Object { $_ -like 'Subscriptions Failed:*' }) | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath (Join-Path $script:CaseHome 'InventoryReports') -Recurse -File -Filter 'ResourcesReport_*.zip') | Should -HaveCount 3
        $Run.ExitCode | Should -Be 0
    }

    It 'ends when a stream''s worker process dies, and reports that stream as failed' {
        script:New-Case -DieIds 'sub-a'
        # PowerShell fails the job about 60 seconds after its worker died.
        $Run = script:Invoke-Wrapper -TimeoutSeconds 180
        script:Get-Collected $Run | Should -Be @('sub-a', 'sub-b')
        script:Get-NoSummaryLines $Run | Should -HaveCount 1
        script:Get-NoSummaryLines $Run | Should -BeLike '`[stream-0`] WARNING: no summary file at *'
        # The job line names the stream, as the [stream-N] lines around it do.
        @($Run.Text | Where-Object { $_ -like '`[stream-*`] job ended in state *' }) | Should -Be @('[stream-0] job ended in state Failed')
        @($Run.Text | Where-Object { $_ -like 'Subscriptions Failed:*stream-0 (no summary)*' }) | Should -HaveCount 1
    }
}
