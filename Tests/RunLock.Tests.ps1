# One run at a time for each tenant in an inventory folder.
#
#   - A run creates the lock only when there is none; of runs that start at
#     the same moment exactly one gets it, also through two spellings of the
#     path, with a /tmp of its own each, and in runspaces of one process. The
#     lock name has the tenant id in small letters.
#   - Any lock a run finds stops it with exit 1 before it reads or writes any
#     run state, and the lock is left exactly as it was: a lock is never taken
#     over. The message names the holder (host name, process id and start, the
#     last refresh and how long ago) and then says one of four things: the
#     process is running on this machine (wait or stop it; no remove command),
#     it is not running (the remove command), another machine or a process
#     that cannot be told apart (how to check, and the remove command), or
#     the lock cannot be read (the remove command, with the same check).
#   - The lock is released on a normal end, on every exit code, on Ctrl+C,
#     on an error that ends the script, and when the command ends with an
#     error in a session that goes on (Cloud Shell runs every command in one
#     pwsh process); a killed run leaves its lock, and the next run prints the
#     command that removes it.
#   - The heartbeat rewrites only the heartbeat time, and the heartbeat and
#     the release touch the lock only while it is the run's own: a lock put in
#     its place is never overwritten or removed, with one warning. Only the run
#     that created a lock removes it; a later run in the same runspace, or
#     under a nested prompt there, leaves it alone.
# Each case is followed by the next two runs.
#
# The end-to-end runs are Run-AllSubscriptions.ps1 itself, each started as its
# own pwsh process from a copy of the tool whose ResourceInventory.ps1 is a
# stand-in, with Azure answered by stand-in Az modules and an az command found
# first on the module path and PATH of that process. A run can be held at a
# subscription until the test releases it, so two runs overlap at a known
# point. The process's home is a scratch folder, so the inventory root is
# under it. On Windows the wrapper writes to C:\InventoryReports instead, so
# the end-to-end tests do not run there. The races are tagged Race.
#
# Run with: Invoke-Pester ./Tests/RunLock.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:FunctionsFile = Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1'
    . $script:FunctionsFile

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('RunLockTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
    $script:Tenant = '12345678-1234-1234-1234-123456789012'
    $script:Pwsh = Join-Path $PSHOME 'pwsh'
    # The full host name, as the lock records it.
    $script:Machine = [System.Net.Dns]::GetHostName()
    $script:Started = [System.Collections.Generic.List[object]]::new()

    # --- The tool: the wrapper and its helpers as they are, and a stand-in
    # ResourceInventory.ps1 that writes one report folder and zip per call. A
    # subscription listed in RDA_STANDIN_HOLD is held until the test releases
    # it: a marker file says its collection started, a release file lets it go
    # on. Every collection leaves a marker naming the run and the subscription.
    $script:ToolRoot = Join-Path $script:TestBase 'tool'
    New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
    foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Version.json', 'Functions', 'Extension'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:ToolRoot -Recurse -Force
    }
    $script:Wrapper = Join-Path $script:ToolRoot 'Run-AllSubscriptions.ps1'
    $StandInInner = @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
$Scenario = Get-Content -LiteralPath $(if ($global:RdaStandInScenario) { $global:RdaStandInScenario } else { $env:RDA_STANDIN_AZURE }) -Raw | ConvertFrom-Json
$Run = if ($global:RdaStandInRun) { $global:RdaStandInRun } elseif ($env:RDA_STANDIN_RUN) { $env:RDA_STANDIN_RUN } else { 'run' }
$HoldIds = if ($null -ne $global:RdaStandInHold) { [string]$global:RdaStandInHold } else { [string]$env:RDA_STANDIN_HOLD }
if (@($HoldIds -split ',') -contains $SubscriptionID)
{
    Set-Content -LiteralPath (Join-Path $HOME ('held-{0}-{1}' -f $Run, $SubscriptionID)) -Value $PID
    $Deadline = (Get-Date).AddSeconds(240)
    while (-not (Test-Path -LiteralPath (Join-Path $HOME ('release-{0}-{1}' -f $Run, $SubscriptionID))) -and -not (Test-Path -LiteralPath (Join-Path $HOME 'release-all')) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 100 }
}
Set-Content -LiteralPath (Join-Path $HOME ('collected-{0}-{1}-{2}' -f $Run, $SubscriptionID, [guid]::NewGuid().ToString('N').Substring(0, 6))) -Value $PID
if (@($Scenario.NoZipIds) -contains $SubscriptionID) { $Global:ZipOutputFile = $null; $Global:Resources = @(1); $Global:ResourceCount = 1; return }
$Root = Join-Path $HOME 'InventoryReports'
$Stamp = (Get-Date -Format 'yyyyMMddHHmmssfff') + $SubscriptionID + $Run
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

    # --- Stand-in Azure: sign-in, context, token and subscription calls, the
    # resource group read of the access check and a usage call that answers.
    $script:Modules = Join-Path $script:TestBase 'modules'
    $Accounts = @'
function Get-RdaStandInScenario { Get-Content -LiteralPath $(if ($global:RdaStandInScenario) { $global:RdaStandInScenario } else { $env:RDA_STANDIN_AZURE }) -Raw | ConvertFrom-Json }
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
    $Claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"stand-in-caller"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [pscustomobject]@{ Token = ('e30.{0}.c2ln' -f $Claims); Type = 'Bearer'; ExpiresOn = (Get-Date).AddHours(1) }
}
function Get-AzSubscription
{
    [CmdletBinding()] param($TenantId, $SubscriptionId)
    $Scenario = Get-RdaStandInScenario
    # A run whose sign-in is fine but whose subscription list throws: an
    # error that ends the wrapper after it took the lock.
    # Whether this run held its lock when it read the subscription list.
    $Run = if ($global:RdaStandInRun) { $global:RdaStandInRun } elseif ($env:RDA_STANDIN_RUN) { $env:RDA_STANDIN_RUN } else { 'run' }
    Set-Content -LiteralPath (Join-Path $HOME ('lock-at-list-' + $Run)) -Value ([string](Test-Path -LiteralPath (Join-Path $HOME ('InventoryReports/.run-lock-{0}.json' -f $TenantId.ToLowerInvariant()))))
    if ($Scenario.ThrowAtList)
    {
        Set-Content -LiteralPath (Join-Path $HOME 'lock-at-list') -Value ([string](Test-Path -LiteralPath (Join-Path $HOME ('InventoryReports/.run-lock-{0}.json' -f $TenantId))))
        throw 'stand-in: the subscription list failed'
    }
    @($Scenario.Subscriptions | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SubscriptionId = $_.Id; Name = $_.Name; State = 'Enabled'; TenantId = $Scenario.Tenant } })
}
# The Resource Manager paths a run reads up front: the resource group list, role
# assignments and their definitions, caller permissions, Resource Graph
# resource counts and usage aggregates (one row above zero). Every
# subscription can be read.
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
$Scenario = Get-Content -LiteralPath $(if ($global:RdaStandInScenario) { $global:RdaStandInScenario } else { $env:RDA_STANDIN_AZURE }) -Raw | ConvertFrom-Json
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'show') { [pscustomobject]@{ tenantId = $Scenario.Tenant } | ConvertTo-Json -Compress; exit 0 }
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'get-access-token') { exit 0 }
exit 1
'@
    Set-Content -LiteralPath (Join-Path $script:Bin 'az.ps1') -Value $Az -Encoding utf8

    $script:Subs = @{}
    # A second tenant, for runs of two tenants in one folder.
    $script:TenantB = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

    # A pwsh process that runs the wrapper twice at once, as two thread jobs in
    # one process (Mode 'same': one tenant, the second started while the first
    # is held at sub-b; Mode 'two': two tenants, both held for over a minute).
    # Each job sets the stand-in's scenario, run name and held subscriptions
    # for its own runspace. Writes what happened to Out as JSON.
    $script:JobHostSource = @'
param([string]$Wrapper, [string]$Mode, [string]$TenantA, [string]$ScenarioA, [string]$TenantB, [string]$ScenarioB, [string]$Out)
$Job = {
    param($Wrapper, $Tenant, $Scenario, $Run, $Hold)
    $global:RdaStandInScenario = $Scenario
    $global:RdaStandInRun = $Run
    $global:RdaStandInHold = $Hold
    $global:LASTEXITCODE = 0
    $Lines = @(& $Wrapper -TenantID $Tenant -ParallelStreams 1 *>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{ Run = $Run; Exit = $global:LASTEXITCODE; Lines = $Lines }
}
function Wait-Marker([string]$Name)
{
    $Deadline = (Get-Date).AddSeconds(150)
    while (-not (Test-Path -LiteralPath (Join-Path $HOME $Name))) { if ((Get-Date) -gt $Deadline) { throw ('no ' + $Name) }; Start-Sleep -Milliseconds 100 }
}
function Get-LockPathOf([string]$Tenant) { Join-Path $HOME ('InventoryReports/.run-lock-{0}.json' -f $Tenant) }
function Read-LockValues([string]$Tenant)
{
    $Path = Get-LockPathOf $Tenant
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $Values = @{}
    $Document = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($Path))
    try { foreach ($Property in $Document.RootElement.EnumerateObject()) { $Values[$Property.Name] = $Property.Value.ToString() } }
    finally { $Document.Dispose() }
    return $Values
}
if ($Mode -eq 'gap')
{
    # The first run is paused right after it took its lock, before its
    # heartbeat starts (see the tool variant of the test); the second starts then.
    $J1 = Start-ThreadJob -ScriptBlock $Job -ArgumentList $Wrapper, $TenantA, $ScenarioA, 'j1', ''
    Wait-Marker 'gap-j1'
    $Held = Read-LockValues $TenantA
    $R2 = Start-ThreadJob -ScriptBlock $Job -ArgumentList $Wrapper, $TenantA, $ScenarioA, 'j2', '' | Wait-Job -Timeout 240 | Receive-Job
    $StillHeld = Read-LockValues $TenantA
    Set-Content -LiteralPath (Join-Path $HOME 'release-gap-j1') -Value 'go'
    $R1 = $J1 | Wait-Job -Timeout 240 | Receive-Job
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Bundles = @(Get-ChildItem -LiteralPath (Join-Path $HOME 'InventoryReports') -Filter 'AllSubscriptions_ResourcesReport_*.zip' | ForEach-Object {
            $Archive = [System.IO.Compression.ZipFile]::OpenRead($_.FullName)
            try { @($Archive.Entries | Where-Object { $_.FullName -like 'ResourcesReport_*.zip' }).Count } finally { $Archive.Dispose() }
        })
    $Result = @{ Runs = @($R1, $R2); Held = $Held; StillHeld = $StillHeld; LockAfter = (Test-Path -LiteralPath (Get-LockPathOf $TenantA)); ProcessId = $PID; Bundles = $Bundles }
}
elseif ($Mode -eq 'same')
{
    $J1 = Start-ThreadJob -ScriptBlock $Job -ArgumentList $Wrapper, $TenantA, $ScenarioA, 'j1', 'sub-b'
    Wait-Marker 'held-j1-sub-b'
    $Held = Read-LockValues $TenantA
    $R2 = Start-ThreadJob -ScriptBlock $Job -ArgumentList $Wrapper, $TenantA, $ScenarioA, 'j2', '' | Wait-Job -Timeout 240 | Receive-Job
    $StillHeld = Read-LockValues $TenantA
    Set-Content -LiteralPath (Join-Path $HOME 'release-j1-sub-b') -Value 'go'
    $R1 = $J1 | Wait-Job -Timeout 240 | Receive-Job
    $Result = @{ Runs = @($R1, $R2); Held = $Held; StillHeld = $StillHeld; LockAfter = (Test-Path -LiteralPath (Get-LockPathOf $TenantA)); ProcessId = $PID }
}
else
{
    $J1 = Start-ThreadJob -ScriptBlock $Job -ArgumentList $Wrapper, $TenantA, $ScenarioA, 'j1', 'sub-b'
    $J2 = Start-ThreadJob -ScriptBlock $Job -ArgumentList $Wrapper, $TenantB, $ScenarioB, 'j2', 'sub-y'
    Wait-Marker 'held-j1-sub-b'
    Wait-Marker 'held-j2-sub-y'
    $Before = @{ A = (Read-LockValues $TenantA); B = (Read-LockValues $TenantB) }
    Start-Sleep -Seconds 65
    $After = @{ A = (Read-LockValues $TenantA); B = (Read-LockValues $TenantB) }
    Set-Content -LiteralPath (Join-Path $HOME 'release-j1-sub-b') -Value 'go'
    Set-Content -LiteralPath (Join-Path $HOME 'release-j2-sub-y') -Value 'go'
    $R = @($J1, $J2 | Wait-Job -Timeout 240 | Receive-Job)
    $Result = @{ Runs = $R; Before = $Before; After = $After; LockAAfter = (Test-Path -LiteralPath (Get-LockPathOf $TenantA)); LockBAfter = (Test-Path -LiteralPath (Get-LockPathOf $TenantB)); ProcessId = $PID }
}
$Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Out -Encoding utf8
'@

    # Appended to a copy of the functions file: the run named j1 waits right
    # after it took its lock, before its heartbeat starts, until the test lets it go.
    $script:GapPauseSource = @'
$script:RdaOriginalStartRunLockHeartbeat = ${function:Start-RunLockHeartbeat}
function Start-RunLockHeartbeat
{
    param($Lock, [int]$IntervalSeconds = 60)
    $Run = if ($global:RdaStandInRun) { $global:RdaStandInRun } else { [string]$env:RDA_STANDIN_RUN }
    if ($Run -eq 'j1')
    {
        Set-Content -LiteralPath (Join-Path $HOME ('gap-' + $Run)) -Value $PID
        $Deadline = (Get-Date).AddSeconds(240)
        while (-not (Test-Path -LiteralPath (Join-Path $HOME ('release-gap-' + $Run))) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 100 }
    }
    & $script:RdaOriginalStartRunLockHeartbeat -Lock $Lock -IntervalSeconds $IntervalSeconds
}
'@

    # A pwsh process that runs the wrapper in one runspace, command after
    # command, as an interactive session (Cloud Shell) runs what is typed at
    # its prompt. Command 1 ends with an error; the process then waits, as at a
    # prompt, until the test writes session-go; commands 2 and 3 run the
    # wrapper again in the same runspace. Writes what happened to Out.
    $script:SessionHostSource = @'
param([string]$Wrapper, [string]$Tenant, [string]$Out, [string]$CaseHome)
$Runspace = [runspacefactory]::CreateRunspace($Host)
$Runspace.Open()
$LockPath = Join-Path $CaseHome ('InventoryReports/.run-lock-{0}.json' -f $Tenant)
$PowerShell = [powershell]::Create()
$PowerShell.Runspace = $Runspace
$null = $PowerShell.AddScript(("& '{0}' -TenantID {1} -ParallelStreams 1" -f $Wrapper, $Tenant))
$Ended = try { $null = $PowerShell.Invoke(); 'no error' } catch { if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message } }
$PowerShell.Dispose()
Set-Content -LiteralPath (Join-Path $CaseHome 'session-1-ended') -Value $Ended
$Deadline = (Get-Date).AddSeconds(180)
while (-not (Test-Path -LiteralPath (Join-Path $CaseHome 'session-go')) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 100 }
$Runs = @(foreach ($Number in 2, 3)
    {
        $PowerShell = [powershell]::Create()
        $PowerShell.Runspace = $Runspace
        $null = $PowerShell.AddScript(("`$global:LASTEXITCODE = 0; & '{0}' -TenantID {1} -ParallelStreams 1 *>&1 | ForEach-Object {{ [string]`$_ }}; 'EXIT ' + `$global:LASTEXITCODE" -f $Wrapper, $Tenant))
        $Lines = @($PowerShell.Invoke() | ForEach-Object { [string]$_ })
        $PowerShell.Dispose()
        $Exit = @($Lines | Where-Object { $_ -like 'EXIT *' })[-1] -replace '^EXIT ', ''
        [pscustomobject]@{ Number = $Number; Exit = [int]$Exit; Lines = @($Lines | Where-Object { $_ -notlike 'EXIT *' }); LockAfter = (Test-Path -LiteralPath $LockPath) }
    })
[pscustomobject]@{ Runs = $Runs; ProcessId = $PID } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Out -Encoding utf8
'@

    foreach ($Letter in 'A', 'B', 'C', 'D', 'X', 'Y') { $script:Subs[$Letter] = @{ Id = ('sub-' + $Letter.ToLowerInvariant()); Name = ('Sub ' + $Letter) } }

    # A fresh home (its InventoryReports folder is the inventory root) for each test.
    function script:New-Case
    {
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseHome -Force | Out-Null
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        $script:State = Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Tenant)
        $script:LockPath = Join-Path $script:Root ('.run-lock-{0}.json' -f $script:Tenant)
        $script:ScenarioB = Join-Path $script:CaseHome 'scenario-b.json'
        $script:LockPathB = Join-Path $script:Root ('.run-lock-{0}.json' -f $script:TenantB)
    }

    # Starts a pwsh process of this case that runs the script Source with
    # Arguments, and waits for it to end. Returns its output as text.
    function script:Start-CaseScript
    {
        param([string]$Name, [string]$Source, [string[]]$Arguments)
        $Path = Join-Path $script:CaseHome $Name
        Set-Content -LiteralPath $Path -Value $Source -Encoding utf8
        $Info = script:New-CaseProcessInfo -Arguments (@('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Path) + $Arguments)
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $script:Started.Add($Proc)
        return [pscustomobject]@{ Process = $Proc; Out = $Proc.StandardOutput.ReadToEndAsync(); Err = $Proc.StandardError.ReadToEndAsync(); Run = $Name }
    }

    function script:Set-Scenario
    {
        param([string[]]$Subs, [string[]]$NoZip = @(), [string]$Tenant = $script:Tenant, [string]$Path = $script:Scenario, [switch]$ThrowAtList)
        [pscustomobject]@{
            Tenant        = $Tenant
            Subscriptions = @($Subs | ForEach-Object { [pscustomobject]@{ Id = $script:Subs[$_].Id; Name = $script:Subs[$_].Name } })
            NoZipIds      = @($NoZip | ForEach-Object { $script:Subs[$_].Id })
            ThrowAtList   = [bool]$ThrowAtList
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding utf8
    }

    # One run of the wrapper as its own process, stdin closed, started and
    # left running. -Run names it in the stand-in's markers; -Hold lists the
    # subscriptions (by letter) it is held at until Clear-Hold.
    function script:Start-Wrapper
    {
        param([string[]]$Arguments = @(), [int]$Streams = 1, [string]$Run = 'run', [string[]]$Hold = @(), [string]$Wrapper = $script:Wrapper, [string]$Tenant = $script:Tenant)
        $All = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Wrapper, '-TenantID', $Tenant, '-ParallelStreams', [string]$Streams) + @($Arguments)
        $Info = script:New-CaseProcessInfo -Arguments $All
        $Info.Environment['RDA_STANDIN_RUN'] = $Run
        $Info.Environment['RDA_STANDIN_HOLD'] = (@($Hold | ForEach-Object { $script:Subs[$_].Id }) -join ',')
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $script:Started.Add($Proc)
        return [pscustomobject]@{ Process = $Proc; Out = $Proc.StandardOutput.ReadToEndAsync(); Err = $Proc.StandardError.ReadToEndAsync(); Run = $Run }
    }

    # A pwsh process of this case (its home, the stand-in modules and az, the
    # scenario), stdin closed. A test runner started in the background by a
    # non-interactive shell ignores Ctrl+C (SIGINT), and its child processes
    # inherit that, so the process is started through perl, which sets SIGINT
    # back to the default before it starts pwsh.
    $script:Perl = Get-Command -Name perl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:SigIntIgnored = (-not $IsWindows -and -not $IsMacOS) -and @((Get-Content -LiteralPath '/proc/self/status' -ErrorAction SilentlyContinue | Where-Object { $_ -like 'SigIgn:*' }) -replace '^SigIgn:\s*', '' | Where-Object { ([Convert]::ToUInt64($_, 16) -band 2) -ne 0 }).Count -gt 0
    function script:New-CaseProcessInfo
    {
        param([string[]]$Arguments)
        if ($script:Perl)
        {
            $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Perl.Source)
            foreach ($Arg in @('-e', '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or die "exec: $!"', $script:Pwsh)) { $Info.ArgumentList.Add($Arg) }
        }
        else
        {
            $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        }
        foreach ($Arg in $Arguments) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['PATH'] = $script:Bin + [IO.Path]::PathSeparator + $env:PATH
        $Info.Environment['RDA_STANDIN_AZURE'] = $script:Scenario
        $Info.Environment['NO_COLOR'] = '1'
        return $Info
    }

    # A copy of the tool whose functions file ends with Append (a stand-in for
    # one of its functions, or for a command it calls). Returns its wrapper.
    function script:New-ToolVariant
    {
        param([string]$Name, [string]$Append)
        $Root = Join-Path $script:TestBase ('tool-' + $Name)
        if (-not (Test-Path -LiteralPath $Root))
        {
            Copy-Item -LiteralPath $script:ToolRoot -Destination $Root -Recurse -Force
            Add-Content -LiteralPath (Join-Path $Root 'Functions/RunAllSubscriptions.Functions.ps1') -Value $Append -Encoding utf8
        }
        return (Join-Path $Root 'Run-AllSubscriptions.ps1')
    }

    function script:Wait-Wrapper
    {
        param([Parameter(Mandatory = $true)]$Started, [int]$TimeoutSeconds = 180)
        if (-not $Started.Process.WaitForExit($TimeoutSeconds * 1000))
        {
            $Started.Process.Kill($true)
            throw ('The wrapper run {0} did not end within {1} seconds.' -f $Started.Run, $TimeoutSeconds)
        }
        $Started.Process.WaitForExit()
        $Text = @(([string]$Started.Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        return [pscustomobject]@{ ExitCode = $Started.Process.ExitCode; Text = $Text; Error = [string]$Started.Err.Result; ProcessId = $Started.Process.Id }
    }

    function script:Invoke-Wrapper
    {
        param([string[]]$Arguments = @(), [int]$Streams = 1, [string]$Run = 'run', [string]$Wrapper = $script:Wrapper, [string]$Tenant = $script:Tenant)
        script:Wait-Wrapper -Started (script:Start-Wrapper -Arguments $Arguments -Streams $Streams -Run $Run -Wrapper $Wrapper -Tenant $Tenant)
    }

    # Waits until the run has reached every listed held subscription.
    function script:Wait-Held
    {
        param([string]$Run, [string[]]$Letters, [int]$TimeoutSeconds = 120)
        $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $Deadline)
        {
            if (@($Letters | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:CaseHome ('held-{0}-{1}' -f $Run, $script:Subs[$_].Id))) }).Count -eq 0) { return }
            Start-Sleep -Milliseconds 200
        }
        throw ('Run {0} did not reach {1} within {2} seconds.' -f $Run, ($Letters -join ', '), $TimeoutSeconds)
    }

    function script:Test-Held
    {
        param([string]$Run, [string]$Letter)
        Test-Path -LiteralPath (Join-Path $script:CaseHome ('held-{0}-{1}' -f $Run, $script:Subs[$Letter].Id))
    }

    function script:Clear-Hold
    {
        param([string]$Run, [string[]]$Letters)
        foreach ($Letter in $Letters) { Set-Content -LiteralPath (Join-Path $script:CaseHome ('release-{0}-{1}' -f $Run, $script:Subs[$Letter].Id)) -Value 'go' }
    }

    # The subscriptions (by letter) a run collected.
    function script:Get-Collected
    {
        param([string]$Run)
        @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter ('collected-{0}-*' -f $Run) | ForEach-Object { ($_.Name -split '-')[3].ToUpperInvariant() } | Sort-Object)
    }

    # Every file under the inventory root with its content hash, except the
    # wrapper transcripts (each run writes its own) and the lock (compared on
    # its own).
    function script:Get-RootSnapshot
    {
        @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force -File |
                Where-Object { $_.Name -notlike 'RunAllSubscriptions_transcript_*' -and $_.FullName -ne $script:LockPath } |
                Sort-Object FullName |
                ForEach-Object { '{0} {1}' -f $_.FullName.Substring($script:Root.Length), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
    }

    # A lock file as another run would leave it. Ages are in seconds before now.
    function script:Set-LockFile
    {
        param([string]$Machine = $script:Machine, [int]$ProcessId, [datetime]$ProcessStartUtc = [datetime]::UtcNow.AddHours(-1), [int]$HeartbeatAgeSeconds = 30, [string]$Raw, [int]$FileAgeSeconds = 0, [string]$InvocationId, [string]$BootId, [string]$StartTicks)
        if (-not $PSBoundParameters.ContainsKey('Raw'))
        {
            $Values = [ordered]@{
                MachineName         = $Machine
                ProcessId           = $ProcessId
                ProcessStartTimeUtc = $ProcessStartUtc.ToUniversalTime().ToString('o')
                RunStartTimeUtc     = $ProcessStartUtc.ToUniversalTime().AddSeconds(2).ToString('o')
                HeartbeatUtc        = [datetime]::UtcNow.AddSeconds(-$HeartbeatAgeSeconds).ToString('o')
            }
            if ($InvocationId) { $Values['InvocationId'] = $InvocationId; $Values['RunspaceId'] = 1 }
            if ($BootId) { $Values['BootId'] = $BootId; $Values['ProcessStartTicks'] = $StartTicks }
            $Raw = $Values | ConvertTo-Json -Compress
        }
        [System.IO.File]::WriteAllText($script:LockPath, $Raw)
        (Get-Item -LiteralPath $script:LockPath -Force).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-$FileAgeSeconds)
    }

    # The id of a process that has ended.
    function script:Get-EndedProcessId
    {
        $Ended = script:Start-Pwsh -Arguments '-Command', 'exit'
        $Ended.Process.WaitForExit()
        $Id = $Ended.Process.Id
        if ($null -ne (Get-Process -Id $Id -ErrorAction SilentlyContinue)) { throw 'The ended process id is in use again.' }
        return $Id
    }

    # Linux: the boot id and a process's start in clock ticks since boot
    # (field 22 of /proc/<id>/stat, counted after the command name).
    function script:Get-BootId { (Get-Content -LiteralPath '/proc/sys/kernel/random/boot_id' -Raw).Trim() }
    function script:Get-StartTicks
    {
        param([int]$ProcessId)
        $Text = Get-Content -LiteralPath ('/proc/{0}/stat' -f $ProcessId) -Raw
        ($Text.Substring($Text.LastIndexOf(')') + 2) -split ' ')[19]
    }

    # The lock file's values as written (text), by name.
    function script:Get-LockValues
    {
        $Values = @{}
        $Document = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($script:LockPath))
        try { foreach ($Property in $Document.RootElement.EnumerateObject()) { $Values[$Property.Name] = $Property.Value.ToString() } }
        finally { $Document.Dispose() }
        return $Values
    }

    # The time format the lock lines use, written out here rather than taken
    # from the code under test.
    function script:Format-Utc
    {
        param([Parameter(Mandatory = $true)][datetime]$Value)
        $Value.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) + ' UTC'
    }

    # A time the lock file holds, read back as UTC.
    function script:ConvertFrom-LockTime
    {
        param([Parameter(Mandatory = $true)][string]$Text)
        [datetime]::Parse($Text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }

    # A pwsh process with these arguments, its output collected.
    function script:Start-Pwsh
    {
        param([string[]]$Arguments)
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($Arg in @('-NoProfile', '-NonInteractive') + $Arguments) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $script:Started.Add($Proc)
        return [pscustomobject]@{ Process = $Proc; Out = $Proc.StandardOutput.ReadToEndAsync(); Err = $Proc.StandardError.ReadToEndAsync() }
    }

    # After each test: let every held run go on, and stop any process the test
    # started that has not ended within a minute.
    function script:Stop-Started
    {
        if ($script:CaseHome -and (Test-Path -LiteralPath $script:CaseHome)) { Set-Content -LiteralPath (Join-Path $script:CaseHome 'release-all') -Value 'go' }
        foreach ($Proc in @($script:Started))
        {
            if (-not $Proc.HasExited -and -not $Proc.WaitForExit(60000)) { $Proc.Kill($true) }
        }
        $script:Started.Clear()
    }

    # Lines a run prints about the run lock outside its stop message.
    function script:Get-LockLines
    {
        param([string[]]$Text)
        @($Text | Where-Object { $_ -match 'run lock|Took over|^Removed ' })
    }

    # Whether the run named Run held its lock when it read the subscription
    # list (the stand-in records it).
    function script:Get-LockAtList
    {
        param([string]$Run)
        $Marker = Join-Path $script:CaseHome ('lock-at-list-' + $Run)
        if (-not (Test-Path -LiteralPath $Marker)) { return 'not reached' }
        (Get-Content -LiteralPath $Marker -Raw).Trim()
    }

    # Runs the remove command a stop message printed (taken from its output).
    function script:Invoke-PrintedRemove
    {
        param([string[]]$Text)
        $Lines = @($Text | Where-Object { $_ -match '^    Remove-Item -LiteralPath ' })
        $Lines.Count | Should -Be 1 -Because 'the message prints the remove command once'
        & ([scriptblock]::Create($Lines[0].Trim()))
    }

    # A request in this process: the result and the lines it printed.
    function script:Invoke-Request
    {
        param([string]$Path = $script:LockPath)
        $All = @(& { Request-RunLock -Path $Path -RunStartTime (Get-Date) } 6>&1)
        [pscustomobject]@{
            Request = @($All | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
            Lines   = @($All | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ })
        }
    }

    function script:Get-HeldMessage
    {
        param($Request)
        @(& { Write-RunLockHeldMessage -Request $Request -Tenant $script:Tenant } 6>&1 | ForEach-Object { [string]$_ })
    }

    # The stop message lines every stop on an existing, readable lock begins with.
    function script:Get-HolderLines
    {
        param([string]$Machine, [string]$ProcessId, [datetime]$ProcessStartUtc, [datetime]$RunStartUtc)
        @(
            ('ERROR: Another run for tenant {0} holds the lock on this inventory folder, so this run stopped before reading or writing any run state.' -f $script:Tenant)
            ('  Lock file:    {0}' -f $script:LockPath)
            ('  Held by:      process {0} on {1}, started {2}; its run started {3}' -f $ProcessId, $Machine, (script:Format-Utc -Value $ProcessStartUtc), (script:Format-Utc -Value $RunStartUtc))
        )
    }

    # The four endings of a stop message.
    function script:Get-RunningLines
    {
        param([string]$ProcessId)
        @(('  Process {0} on this machine is still running, so a run is using this folder.' -f $ProcessId), '  Wait for that run to finish, or stop it, then run this command again.')
    }
    function script:Get-EndedLines
    {
        param([string]$Why)
        @(('  That run is no longer running ({0}). It ended without removing its lock, for example because it was killed or its terminal or Cloud Shell session was closed.' -f $Why), '  Remove the lock, then run this command again:', (script:Get-ExpectedRemoveLine))
    }
    function script:Get-OtherMachineLines
    {
        param([string]$Machine, [string]$ProcessId, [datetime]$ProcessStartUtc)
        @(
            ('  The lock is from another machine, {0}, so whether that run is still going cannot be checked from here.' -f $Machine)
            ("  To check, on {0}: Get-Process -Id {1} | Select-Object Id, ProcessName, @{{ Name = 'StartTimeUtc'; Expression = {{ `$_.StartTime.ToUniversalTime() }} }}" -f $Machine, $ProcessId)
            ('  Once you know that no run is using this folder (no process {0} that started at {1} is running on {2}), remove the lock, then run this command again:' -f $ProcessId, (script:Format-Utc -Value $ProcessStartUtc), $Machine)
            (script:Get-ExpectedRemoveLine)
        )
    }
    function script:Get-UnreadableLines
    {
        param([string]$Problem)
        @(
            ('ERROR: The run lock for tenant {0} cannot be read ({1}), so this run stopped before reading or writing any run state.' -f $script:Tenant, $Problem)
            ('  Lock file:    {0}' -f $script:LockPath)
            '  It was read again for about 2 seconds. Which machine and process hold it is not known; it may have been left by a run that stopped while it was writing it.'
            '  Check that no run for this tenant is going on any machine that uses this folder. Then remove the lock and run this command again:'
            (script:Get-ExpectedRemoveLine)
        )
    }

    # Asserts Text holds every line of Expected, in that order, one after another.
    function script:Assert-Lines
    {
        param([string[]]$Text, [string[]]$Expected)
        $Start = [array]::IndexOf($Text, $Expected[0])
        $Start | Should -BeGreaterOrEqual 0 -Because ('the output has "{0}": {1}' -f $Expected[0], ($Text -join ' | '))
        for ($Index = 1; $Index -lt $Expected.Count; $Index++) { $Text[$Start + $Index] | Should -Be $Expected[$Index] }
    }

    # A wrapper run that stopped on a lock: nothing collected, no remove command
    # where none is allowed.
    function script:Get-RemoveLines
    {
        param([string[]]$Text)
        @($Text | Where-Object { $_ -match 'Remove-Item' })
    }

    function script:Get-ExpectedRemoveLine
    {
        "    Remove-Item -LiteralPath '{0}' -Force" -f ($script:LockPath -replace "'", "''")
    }
}

AfterAll {
    if ($script:TestBase -and (Test-Path -LiteralPath $script:TestBase))
    {
        if (-not $IsWindows) { & chmod -R u+w $script:TestBase 2>$null }
        Remove-Item -LiteralPath $script:TestBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The run lock file' {
    BeforeAll { Set-StrictMode -Version Latest }
    AfterAll { Set-StrictMode -Off }
    BeforeEach { script:New-Case }
    AfterEach { script:Stop-Started }

    It 'is a dot-file per tenant that neither the resume state nor the per-stream state picks up' {
        $Path = Get-RunLockPath -InventoryRoot $script:Root -Tenant $script:Tenant
        Split-Path -Path $Path -Leaf | Should -Be ('.run-lock-{0}.json' -f $script:Tenant)
        $Stream = Join-Path $script:Root ('.resume-state-{0}-stream-0.json' -f $script:Tenant)
        Set-Content -LiteralPath $Path -Value '{}'
        Set-Content -LiteralPath $Stream -Value '{}'
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Root -Tenant $script:Tenant).Name | Should -Be @('.resume-state-{0}-stream-0.json' -f $script:Tenant)
        $Path | Should -Not -Be $script:State
        # The zip steps pack only files inside the per-subscription report folders.
        @(Get-ChildItem -Path $script:Root -Directory | ForEach-Object { Get-ChildItem -Path $_.FullName -Filter '*.zip' -File }).Count | Should -Be 0
    }

    It 'records the machine, the process, its start time, the run start time and a heartbeat, as UTC text' {
        $RunStart = (Get-Date).AddSeconds(-5)
        $Lock = Request-RunLock -Path $script:LockPath -RunStartTime $RunStart
        try
        {
            $Lock.Acquired | Should -BeTrue
            $Keys = @('HeartbeatUtc', 'InvocationId', 'MachineName', 'ProcessId', 'ProcessStartTimeUtc', 'RunspaceId', 'RunStartTimeUtc')
            # Linux also records which process it is in a form a clock step does not move.
            if ($IsLinux) { $Keys = @('BootId', 'HeartbeatUtc', 'InvocationId', 'MachineName', 'ProcessId', 'ProcessStartTicks', 'ProcessStartTimeUtc', 'RunspaceId', 'RunStartTimeUtc') }
            @((script:Get-LockValues).Keys | Sort-Object) | Should -Be $Keys
            $Read = Read-RunLock -Path $script:LockPath
            $Read.Valid | Should -BeTrue
            $Read.MachineName | Should -Be $script:Machine
            if ($IsLinux)
            {
                $Read.BootId | Should -Be (script:Get-BootId)
                $Read.ProcessStartTicks | Should -Be (script:Get-StartTicks -ProcessId $PID)
            }
            $Read.ProcessId | Should -Be $PID
            [math]::Abs(($Read.ProcessStartTimeUtc - (Get-Process -Id $PID).StartTime.ToUniversalTime()).TotalSeconds) | Should -BeLessThan 1
            $Read.RunStartTimeUtc | Should -Be $RunStart.ToUniversalTime()
            $Read.ProcessStartTimeUtc.Kind | Should -Be 'Utc'
        }
        finally
        {
            Remove-RunLock -Lock $Lock
        }
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
    }

    It 'says who holds each kind of lock, and the run leaves it exactly as it was: <Case>' -ForEach @(
        @{ Case = 'this machine, a process that is no longer running'; Kind = 'ended'; Holder = 'Ended'; Why = 'ProcessGone' }
        @{ Case = 'this machine, a running process that started at another time'; Kind = 'reused'; Holder = $(if ($IsLinux) { 'Unknown' } else { 'Ended' }); Why = $(if ($IsLinux) { 'StartTimeDiffers' } else { 'ProcessIdReused' }) }
        @{ Case = 'this machine, another running process that wrote it'; Kind = 'running'; Holder = 'Running'; Why = $null }
        @{ Case = 'this machine, another running process that wrote it, heartbeat 2 hours old'; Kind = 'running-old'; Holder = 'Running'; Why = $null }
        @{ Case = 'this machine, this process, a run that is no longer listed (an earlier run in this session)'; Kind = 'self'; Holder = 'Ended'; Why = 'RunEnded' }
        @{ Case = 'this machine, this process, a lock written without a run id'; Kind = 'self-no-id'; Holder = 'Running'; Why = $null }
        @{ Case = 'this machine, a running process whose start cannot be read'; Kind = 'unreadable-start'; Holder = 'Unknown'; Why = 'StartUnreadable' }
        @{ Case = 'another machine, heartbeat 2 minutes old'; Kind = 'other-2'; Holder = 'OtherMachine'; Why = $null }
        @{ Case = 'another machine, heartbeat 3 days old'; Kind = 'other-3d'; Holder = 'OtherMachine'; Why = $null }
        @{ Case = 'not JSON'; Kind = 'garbled'; Holder = 'Unreadable'; Why = $null }
        @{ Case = 'empty'; Kind = 'empty'; Holder = 'Unreadable'; Why = $null }
        @{ Case = 'a process id that is not a number and a heartbeat that is not a date'; Kind = 'invalid'; Holder = 'Unreadable'; Why = $null }
    ) {
        $SelfStart = (Get-Process -Id $PID).StartTime.ToUniversalTime()
        $Invalid = ('{{"MachineName":"{0}","ProcessId":"abc","ProcessStartTimeUtc":"{1}","RunStartTimeUtc":"{1}","HeartbeatUtc":"not a date"}}' -f $script:Machine, $SelfStart.ToString('o'))
        $Other = $null
        switch ($Kind)
        {
            'ended' { script:Set-LockFile -ProcessId (script:Get-EndedProcessId) -FileAgeSeconds 3600 }
            'reused' { script:Set-LockFile -ProcessId $PID -ProcessStartUtc $SelfStart.AddHours(-1) -FileAgeSeconds 3600 }
            'self' { script:Set-LockFile -ProcessId $PID -ProcessStartUtc $SelfStart -InvocationId ([guid]::NewGuid().ToString()) -FileAgeSeconds 3600 }
            'self-no-id' { script:Set-LockFile -ProcessId $PID -ProcessStartUtc $SelfStart -FileAgeSeconds 3600 }
            'unreadable-start'
            {
                Mock Get-RunLockProcess { [pscustomobject]@{ Running = $true; StartTimeUtc = $null; StartTicks = $null } }
                script:Set-LockFile -ProcessId 4242 -FileAgeSeconds 3600
            }
            { $_ -in 'running', 'running-old' }
            {
                $Other = (script:Start-Pwsh -Arguments '-Command', 'Start-Sleep -Seconds 60').Process
                script:Set-LockFile -ProcessId $Other.Id -ProcessStartUtc $Other.StartTime.ToUniversalTime() -HeartbeatAgeSeconds $(if ($Kind -eq 'running-old') { 7200 } else { 30 }) -FileAgeSeconds 3600
            }
            'other-2' { script:Set-LockFile -Machine 'other-machine' -ProcessId 4242 -HeartbeatAgeSeconds 120 -FileAgeSeconds 3600 }
            'other-3d' { script:Set-LockFile -Machine 'other-machine' -ProcessId 4242 -HeartbeatAgeSeconds 259200 -FileAgeSeconds 3600 }
            'garbled' { script:Set-LockFile -Raw '{not json' -FileAgeSeconds 3600 }
            'empty' { script:Set-LockFile -Raw '' -FileAgeSeconds 3600 }
            'invalid' { script:Set-LockFile -Raw $Invalid -FileAgeSeconds 3600 }
        }
        $Bytes = [System.IO.File]::ReadAllBytes($script:LockPath)
        $Written = (Get-Item -LiteralPath $script:LockPath -Force).LastWriteTimeUtc
        $Read = Read-RunLock -Path $script:LockPath
        $Found = Get-RunLockHolder -Lock $Read
        $Found.Kind | Should -Be $Holder
        $Found.Why | Should -Be $Why
        if ($Kind -eq 'invalid') { $Read.Problem | Should -Be 'ProcessId, HeartbeatUtc missing or not valid' }
        if ($Kind -eq 'garbled') { $Read.Problem | Should -Be 'it is not a JSON object' }
        if ($Kind -eq 'empty') { $Read.Problem | Should -Be 'it is empty' }

        $Asked = script:Invoke-Request
        $Asked.Request.Acquired | Should -BeFalse
        $Asked.Request.Holder.Kind | Should -Be $Holder
        $Asked.Lines | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllBytes($script:LockPath) | Should -Be $Bytes
        (Get-Item -LiteralPath $script:LockPath -Force).LastWriteTimeUtc | Should -Be $Written
        @(Get-ChildItem -LiteralPath $script:Root -Force -File).Name | Should -Be @(Split-Path -Path $script:LockPath -Leaf)
        $Message = script:Get-HeldMessage -Request $Asked.Request
        if ($Holder -eq 'Running') { script:Get-RemoveLines -Text $Message | Should -BeNullOrEmpty }
        else { script:Get-RemoveLines -Text $Message | Should -Be @((script:Get-ExpectedRemoveLine)) }
        if ($null -ne $Other) { $Other.Kill() }
    }

    It 'on Linux, a running process is told by its boot id and its start in ticks since boot, not by the wall clock: <Case>' -Skip:(-not $IsLinux) -ForEach @(
        @{ Case = 'its recorded start time is 5 seconds off (a clock step), boot id and ticks match'; Kind = 'clock-step'; Holder = 'Running'; Why = $null }
        @{ Case = 'its ticks differ: another process with that id'; Kind = 'ticks'; Holder = 'Ended'; Why = 'ProcessIdReused' }
        @{ Case = 'the boot id differs and the lock was last refreshed before this machine started: from before a restart'; Kind = 'boot'; Holder = 'Ended'; Why = 'Restarted' }
    ) {
        $Other = (script:Start-Pwsh -Arguments '-Command', 'Start-Sleep -Seconds 60').Process
        $Start = $Other.StartTime.ToUniversalTime()
        $Ticks = script:Get-StartTicks -ProcessId $Other.Id
        $Boot = script:Get-BootId
        switch ($Kind)
        {
            'clock-step' { script:Set-LockFile -ProcessId $Other.Id -ProcessStartUtc $Start.AddSeconds(-5) -BootId $Boot -StartTicks $Ticks }
            'ticks' { script:Set-LockFile -ProcessId $Other.Id -ProcessStartUtc $Start -BootId $Boot -StartTicks ([string]([long]$Ticks + 1)) }
            'boot'
            {
                # Refreshed a minute before this machine started.
                $Uptime = [int][math]::Ceiling([double]((Get-Content -LiteralPath '/proc/uptime' -Raw).Split(' ')[0]))
                script:Set-LockFile -ProcessId $Other.Id -ProcessStartUtc $Start -BootId ([guid]::NewGuid().ToString()) -StartTicks $Ticks -HeartbeatAgeSeconds ($Uptime + 60)
            }
        }
        $Bytes = [System.IO.File]::ReadAllBytes($script:LockPath)
        $Found = Get-RunLockHolder -Lock (Read-RunLock -Path $script:LockPath)
        $Found.Kind | Should -Be $Holder
        $Found.Why | Should -Be $Why
        $Asked = script:Invoke-Request
        $Asked.Request.Acquired | Should -BeFalse
        $Asked.Lines | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllBytes($script:LockPath) | Should -Be $Bytes
        $Message = script:Get-HeldMessage -Request $Asked.Request
        if ($Kind -eq 'boot') { $Message | Should -Contain (script:Get-EndedLines -Why 'this machine has restarted since')[0] }
        if ($Kind -eq 'ticks') { $Message | Should -Contain (script:Get-EndedLines -Why ('process {0} on this machine is now another process' -f $Other.Id))[0] }
        if ($Kind -eq 'clock-step') { script:Get-RemoveLines -Text $Message | Should -BeNullOrEmpty }
        # The next two runs: once that process has ended, a run still stops on
        # the lock; after the printed command the next two take it.
        $Other.Kill()
        $Other.WaitForExit()
        $After = script:Invoke-Request
        $After.Request.Acquired | Should -BeFalse
        $After.Request.Holder.Kind | Should -Be 'Ended'
        script:Invoke-PrintedRemove -Text (script:Get-HeldMessage -Request $After.Request)
        foreach ($Next in 1..2)
        {
            $Again = script:Invoke-Request
            $Again.Request.Acquired | Should -BeTrue
            $Again.Lines | Should -BeNullOrEmpty
            Remove-RunLock -Lock $Again.Request
        }
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
    }

    It 'a read that fails, or a lock that is not valid yet, is read again for about 2 seconds; failures all along make it unreadable, with the remove command' {
        script:Set-LockFile -Machine 'other-machine' -ProcessId 4242 -HeartbeatAgeSeconds 20 -FileAgeSeconds 60
        $script:Failures = 0
        Mock Read-RunLockText { $script:Failures++; if ($script:Failures -le 2) { throw [System.IO.IOException]::new('The process cannot access the file because it is being used by another process.') }; [System.IO.File]::ReadAllText($Path) }
        $Read = Read-RunLock -Path $script:LockPath
        $Read.Valid | Should -BeTrue
        $Read.MachineName | Should -Be 'other-machine'
        $script:Failures | Should -Be 3

        # A lock that a run has just created and not yet written: empty, then written.
        $script:Reads = 0
        Mock Read-RunLockText { $script:Reads++; if ($script:Reads -le 2) { '' } else { [System.IO.File]::ReadAllText($Path) } }
        $Read = Read-RunLock -Path $script:LockPath
        $Read.Valid | Should -BeTrue
        $script:Reads | Should -Be 3

        Mock Read-RunLockText { throw [System.IO.IOException]::new('The network path was not found.') }
        $Clock = [System.Diagnostics.Stopwatch]::StartNew()
        $Request = Request-RunLock -Path $script:LockPath -RunStartTime (Get-Date) -MaxAttempts 1
        $Clock.Elapsed.TotalSeconds | Should -BeGreaterThan 1.5
        $Request.Acquired | Should -BeFalse
        $Request.Held.Problem | Should -Be 'The network path was not found.'
        $Request.Holder.Kind | Should -Be 'Unreadable'
        $Lines = script:Get-HeldMessage -Request $Request
        $Lines | Should -Contain ('ERROR: The run lock for tenant {0} cannot be read (The network path was not found.), so this run stopped before reading or writing any run state.' -f $script:Tenant)
        script:Assert-Lines -Text $Lines -Expected (script:Get-UnreadableLines -Problem 'The network path was not found.')[2..4]
        # The next two runs once the share is back: the lock is read and is
        # another machine's (exit 1); after the printed command the next run
        # takes the lock.
        Mock Read-RunLockText { [System.IO.File]::ReadAllText($Path) }
        $Back = Request-RunLock -Path $script:LockPath -RunStartTime (Get-Date)
        $Back.Acquired | Should -BeFalse
        $Back.Holder.Kind | Should -Be 'OtherMachine'
        script:Invoke-PrintedRemove -Text (script:Get-HeldMessage -Request $Back)
        $Last = Request-RunLock -Path $script:LockPath -RunStartTime (Get-Date)
        $Last.Acquired | Should -BeTrue
        Remove-RunLock -Lock $Last
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
    }

    It 'the new lock is written to disk (fsync) before the run goes on' -Skip:(-not $IsLinux) {
        if (-not (Get-Command -Name strace -CommandType Application -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'strace is not installed'; return }
        $Asker = Join-Path $script:CaseHome 'take.ps1'
        Set-Content -LiteralPath $Asker -Encoding utf8 -Value @'
param($Functions, $Path)
. $Functions
$Lock = Request-RunLock -Path $Path -RunStartTime (Get-Date) 6>$null
[System.IO.File]::WriteAllText(($Path + '.acquired'), [string]$Lock.Acquired)
'@
        $Trace = Join-Path $script:CaseHome 'trace-created.txt'
        $Info = [System.Diagnostics.ProcessStartInfo]::new('strace')
        foreach ($Arg in '-f', '-e', 'trace=fsync', '-o', $Trace, $script:Pwsh, '-NoProfile', '-NonInteractive', '-File', $Asker, $script:FunctionsFile, $script:LockPath) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $null = $Proc.StandardOutput.ReadToEndAsync(); $null = $Proc.StandardError.ReadToEndAsync()
        $Proc.WaitForExit(120000) | Should -BeTrue
        Get-Content -LiteralPath ($script:LockPath + '.acquired') -Raw | Should -Be 'True'
        @(Get-Content -LiteralPath $Trace | Where-Object { $_ -match '^\d+ +fsync\(' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'an earlier run in this runspace that ended without releasing its lock: the next run stops on it, the earlier heartbeat never writes it again, and after the printed command the next two runs take the lock' {
        $First = Request-RunLock -Path $script:LockPath -RunStartTime (Get-Date).AddMinutes(-5)
        $null = Start-RunLockHeartbeat -Lock $First -IntervalSeconds 1
        $FirstText = Get-Content -LiteralPath $script:LockPath -Raw
        # The first run ends without releasing it (an error its caller caught).
        $Second = script:Invoke-Request
        $Second.Request.Acquired | Should -BeFalse
        $Second.Request.Holder.Kind | Should -Be 'Ended'
        $Second.Request.Holder.Why | Should -Be 'RunEnded'
        $Message = script:Get-HeldMessage -Request $Second.Request
        script:Assert-Lines -Text $Message -Expected (script:Get-EndedLines -Why 'it was an earlier run in this PowerShell session, and it has ended')
        script:Invoke-PrintedRemove -Text $Message
        $Third = script:Invoke-Request
        $Third.Request.Acquired | Should -BeTrue
        $Third.Lines | Should -BeNullOrEmpty
        $ThirdText = Get-Content -LiteralPath $script:LockPath -Raw
        Start-Sleep -Milliseconds 2500
        # The first run's heartbeat stopped when the third registered: the lock is the third's.
        Get-Content -LiteralPath $script:LockPath -Raw | Should -Be $ThirdText
        $ThirdText | Should -Not -Be $FirstText
        $Printed = @(& { Remove-RunLock -Lock $Third.Request; Remove-RunLock -Lock $First } 6>&1 | ForEach-Object { [string]$_ })
        $Printed | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        $Fourth = script:Invoke-Request
        $Fourth.Request.Acquired | Should -BeTrue
        Remove-RunLock -Lock $Fourth.Request
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
    }

    It 'taken by a run in another runspace of this process that has not started its heartbeat yet: the process is running, so no remove command' {
        $Runspace = [runspacefactory]::CreateRunspace()
        $Runspace.Open()
        $PowerShell = [powershell]::Create()
        $PowerShell.Runspace = $Runspace
        $null = $PowerShell.AddScript(('. ''{0}''; $Lock = Request-RunLock -Path ''{1}'' -RunStartTime (Get-Date); [System.IO.File]::WriteAllText(''{1}.taken'', [string]$Lock.Acquired); $Deadline = (Get-Date).AddSeconds(60); while (-not (Test-Path -LiteralPath ''{1}.done'') -and (Get-Date) -lt $Deadline) {{ Start-Sleep -Milliseconds 50 }}; Remove-RunLock -Lock $Lock' -f $script:FunctionsFile, $script:LockPath))
        $Handle = $PowerShell.BeginInvoke()
        try
        {
            $Deadline = (Get-Date).AddSeconds(60)
            while (-not (Test-Path -LiteralPath ($script:LockPath + '.taken')) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 50 }
            Get-Content -LiteralPath ($script:LockPath + '.taken') -Raw | Should -Be 'True'
            $Asked = script:Invoke-Request
            $Asked.Request.Acquired | Should -BeFalse
            $Asked.Request.Holder.Kind | Should -Be 'Running'
            $Message = script:Get-HeldMessage -Request $Asked.Request
            script:Assert-Lines -Text $Message -Expected (script:Get-RunningLines -ProcessId $PID)
            script:Get-RemoveLines -Text $Message | Should -BeNullOrEmpty
        }
        finally
        {
            Set-Content -LiteralPath ($script:LockPath + '.done') -Value 'go'
            $null = $PowerShell.EndInvoke($Handle)
            $PowerShell.Dispose()
            $Runspace.Dispose()
        }
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        foreach ($Next in 1..2)
        {
            $Again = script:Invoke-Request
            $Again.Request.Acquired | Should -BeTrue
            Remove-RunLock -Lock $Again.Request
        }
    }

    It 'a lock that cannot be created (a read-only folder) and is not there: the reason is printed, and no remove command' -Skip:$IsWindows {
        & chmod 555 $script:Root
        try
        {
            $Asked = script:Invoke-Request
            $Asked.Request.Acquired | Should -BeFalse
            $Asked.Request.Held | Should -BeNullOrEmpty
            $Message = script:Get-HeldMessage -Request $Asked.Request
            $Message | Should -Contain ('ERROR: Could not create the run lock for tenant {0}, so this run stopped before reading or writing any run state.' -f $script:Tenant)
            @($Message | Where-Object { $_ -like '  Reason:    *' }).Count | Should -Be 1
            script:Get-RemoveLines -Text $Message | Should -BeNullOrEmpty
        }
        finally
        {
            & chmod 755 $script:Root
        }
        foreach ($Next in 1..2)
        {
            $Again = script:Invoke-Request
            $Again.Request.Acquired | Should -BeTrue
            Remove-RunLock -Lock $Again.Request
        }
    }

    It 'a run killed while it refreshes its lock leaves the lock and a temporary file: the next run stops with the remove command; after it, the next run removes the temporary file with one line, and the run after prints nothing' -Skip:$IsWindows {
        $Killer = Join-Path $script:CaseHome 'refresh-kill.ps1'
        Set-Content -LiteralPath $Killer -Encoding utf8 -Value @'
param($Functions, $Path)
. $Functions
$Body = (Get-Command -Name Invoke-RunLockFileChange -CommandType Function).ScriptBlock.ToString()
$Move = '[System.IO.File]::Move($Temp, $Path, $true)'
$Changed = $Body.Replace($Move, ('Stop-Process -Id $PID -Force; ' + $Move))
if ($Changed -ceq $Body) { throw 'kill point not found' }
Set-Item -Path Function:Invoke-RunLockFileChange -Value ([scriptblock]::Create($Changed))
$Lock = Request-RunLock -Path $Path -RunStartTime (Get-Date)
$null = Start-RunLockHeartbeat -Lock $Lock -IntervalSeconds 1
Start-Sleep -Seconds 30
'@
        $Killed = script:Start-Pwsh -Arguments '-File', $Killer, $script:FunctionsFile, $script:LockPath
        $Killed.Process.WaitForExit(60000) | Should -BeTrue
        $Killed.Process.ExitCode | Should -Be 137
        $Temp = @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*.tmp' | ForEach-Object FullName)
        $Temp.Count | Should -Be 1
        Test-Path -LiteralPath $script:LockPath | Should -BeTrue
        $Next = script:Invoke-Request
        $Next.Request.Acquired | Should -BeFalse
        $Next.Request.Holder.Kind | Should -Be 'Ended'
        $Message = script:Get-HeldMessage -Request $Next.Request
        script:Assert-Lines -Text $Message -Expected (script:Get-EndedLines -Why ('process {0} is not running on this machine' -f $Killed.Process.Id))
        Test-Path -LiteralPath $Temp[0] | Should -BeTrue
        script:Invoke-PrintedRemove -Text $Message
        $Taken = script:Invoke-Request
        $Taken.Request.Acquired | Should -BeTrue
        $Taken.Lines | Should -Be @(('Removed {0}: a run left it when it was stopped while it refreshed its run lock.' -f $Temp[0]))
        Remove-RunLock -Lock $Taken.Request
        $Last = script:Invoke-Request
        $Last.Request.Acquired | Should -BeTrue
        $Last.Lines | Should -BeNullOrEmpty
        Remove-RunLock -Lock $Last.Request
        @(Get-ChildItem -LiteralPath $script:Root -Force -File) | Should -BeNullOrEmpty
    }
    It 'a run in another runspace of this process that reads the lock right after it was written, before the creator has finished its request: the creator is named as running, no remove command; after it releases, the next two runs take the lock' {
        $Script = Join-Path $script:CaseHome 'barrier.ps1'
        Set-Content -LiteralPath $Script -Encoding utf8 -Value @'
param($Functions, $Path)
$Reached = [System.Threading.ManualResetEventSlim]::new($false)
$Go = [System.Threading.ManualResetEventSlim]::new($false)
$SpaceA = [runspacefactory]::CreateRunspace(); $SpaceA.Open()
$SpaceB = [runspacefactory]::CreateRunspace(); $SpaceB.Open()
$First = [powershell]::Create(); $First.Runspace = $SpaceA
$null = $First.AddScript({
        param($Functions, $Path, $Reached, $Go)
        . $Functions
        $global:RdaReached = $Reached; $global:RdaGo = $Go
        # Pauses the creator right after its lock file is written to disk.
        function Remove-RunLockTemp { param($Path) $global:RdaReached.Set(); $null = $global:RdaGo.Wait(60000) }
        Request-RunLock -Path $Path -RunStartTime (Get-Date)
    }.ToString()).AddArgument($Functions).AddArgument($Path).AddArgument($Reached).AddArgument($Go)
$Handle = $First.BeginInvoke()
if (-not $Reached.Wait(60000)) { throw 'the creator did not reach the pause' }
$Before = [System.IO.File]::ReadAllText($Path)
$Second = [powershell]::Create(); $Second.Runspace = $SpaceB
$null = $Second.AddScript({
        param($Functions, $Path)
        . $Functions
        $R = Request-RunLock -Path $Path -RunStartTime (Get-Date)
        $Lines = @(& { Write-RunLockHeldMessage -Request $R -Tenant 'tenant' } 6>&1 | ForEach-Object { [string]$_ })
        [pscustomobject]@{ Acquired = [bool]$R.Acquired; Kind = $R.Holder.Kind; Why = $R.Holder.Why; Lines = $Lines }
    }.ToString()).AddArgument($Functions).AddArgument($Path)
$Asked = $Second.Invoke()[0]
$Going = -not $Handle.IsCompleted
$After = [System.IO.File]::ReadAllText($Path)
$Go.Set()
$Lock = $First.EndInvoke($Handle)[0]
$CreatorAcquired = [bool]$Lock.Acquired
$Next = [powershell]::Create(); $Next.Runspace = $SpaceB
$null = $Next.AddScript({
        param($Lock, $Path)
        Remove-RunLock -Lock $Lock
        $Gone = -not [System.IO.File]::Exists($Path)
        $Runs = @(foreach ($Number in 1, 2) { $R = Request-RunLock -Path $Path -RunStartTime (Get-Date); [bool]$R.Acquired; Remove-RunLock -Lock $R })
        [pscustomobject]@{ GoneAfterRelease = $Gone; Next = $Runs; LockLeft = [System.IO.File]::Exists($Path) }
    }.ToString()).AddArgument($Lock).AddArgument($Path)
$Tail = $Next.Invoke()[0]
'RESULT ' + ([pscustomobject]@{ CreatorAcquired = $CreatorAcquired; CreatorGoing = $Going; Asked = $Asked; Unchanged = ($Before -ceq $After); Tail = $Tail } | ConvertTo-Json -Compress -Depth 4)
'@
        $Out = @(& $script:Pwsh -NoProfile -NonInteractive -File $Script $script:FunctionsFile $script:LockPath 2>&1 | ForEach-Object { [string]$_ })
        $Line = @($Out | Where-Object { $_ -like 'RESULT *' })
        $Line.Count | Should -Be 1 -Because ($Out -join ' | ')
        $Result = $Line[0].Substring(7) | ConvertFrom-Json
        $Result.CreatorAcquired | Should -BeTrue
        $Result.CreatorGoing | Should -BeTrue -Because 'the creator was still inside its request when the other run asked'
        $Result.Asked.Acquired | Should -BeFalse
        $Result.Asked.Kind | Should -Be 'Running'
        @($Result.Asked.Lines | Where-Object { $_ -match 'Remove-Item' }) | Should -BeNullOrEmpty
        @($Result.Asked.Lines) | Should -Contain '  Wait for that run to finish, or stop it, then run this command again.'
        $Result.Unchanged | Should -BeTrue
        $Result.Tail.GoneAfterRelease | Should -BeTrue
        @($Result.Tail.Next) | Should -Be @($true, $true)
        $Result.Tail.LockLeft | Should -BeFalse
    }

    It 'a run that ends and a later run in the same command for a lock in another folder: the later run leaves the earlier lock and its heartbeat in place; a run for that folder then stops with the remove command; after it the next two runs take the lock' {
        $FolderB = Join-Path $script:CaseHome 'other-folder'
        $null = New-Item -ItemType Directory -Path $FolderB -Force
        $PathB = Join-Path $FolderB (Split-Path -Path $script:LockPath -Leaf)
        $Script = Join-Path $script:CaseHome 'two-folders.ps1'
        Set-Content -LiteralPath $Script -Encoding utf8 -Value @'
param($Functions, $PathA, $PathB)
. $Functions
$A = Request-RunLock -Path $PathA -RunStartTime (Get-Date)
$null = Start-RunLockHeartbeat -Lock $A
# The run for A ends with an error its caller catches; the command goes on.
try { throw 'run A failed' } catch { $null = $_ }
$TextA = [System.IO.File]::ReadAllText($PathA)
$Printed = @(& {
        $script:B = Request-RunLock -Path $PathB -RunStartTime (Get-Date)
        $script:AskA = Request-RunLock -Path $PathA -RunStartTime (Get-Date)
    } 6>&1 | ForEach-Object { [string]$_ })
$AAfterB = [System.IO.File]::Exists($PathA) -and ([System.IO.File]::ReadAllText($PathA) -ceq $TextA)
$BAcquired = [bool]$script:B.Acquired
$AStopped = [bool]$A.State['Stopped']
$AReleased = [bool]$A.State['Released']
$Message = @(& { Write-RunLockHeldMessage -Request $script:AskA -Tenant 'tenant' } 6>&1 | ForEach-Object { [string]$_ })
$Remove = @($Message | Where-Object { $_ -match '^    Remove-Item -LiteralPath ' })
if ($Remove.Count -eq 1) { & ([scriptblock]::Create($Remove[0].Trim())) }
$Next = @(foreach ($Number in 1, 2) { $R = Request-RunLock -Path $PathA -RunStartTime (Get-Date); [bool]$R.Acquired; Remove-RunLock -Lock $R })
$Warnings = @(& { Remove-RunLock -Lock $script:B; Remove-RunLock -Lock $A } 6>&1 | ForEach-Object { [string]$_ })
'RESULT ' + ([pscustomobject]@{ BAcquired = $BAcquired; AUnchanged = $AAfterB; AStopped = $AStopped; AReleasedByB = $AReleased; AskAcquired = [bool]$script:AskA.Acquired; Kind = $script:AskA.Holder.Kind; Why = $script:AskA.Holder.Why; Message = $Message; Removes = $Remove.Count; Printed = $Printed; Next = $Next; Warnings = $Warnings; LeftA = [System.IO.File]::Exists($PathA); LeftB = [System.IO.File]::Exists($PathB) } | ConvertTo-Json -Compress -Depth 4)
'@
        $Out = @(& $script:Pwsh -NoProfile -NonInteractive -File $Script $script:FunctionsFile $script:LockPath $PathB 2>&1 | ForEach-Object { [string]$_ })
        $Line = @($Out | Where-Object { $_ -like 'RESULT *' })
        $Line.Count | Should -Be 1 -Because ($Out -join ' | ')
        $Result = $Line[0].Substring(7) | ConvertFrom-Json
        $Result.BAcquired | Should -BeTrue
        $Result.AUnchanged | Should -BeTrue -Because 'only the run that created a lock removes it'
        $Result.AReleasedByB | Should -BeFalse
        $Result.AStopped | Should -BeFalse -Because 'the earlier run''s own heartbeat and release at process exit still remove its lock'
        $Result.AskAcquired | Should -BeFalse
        $Result.Kind | Should -Be 'Ended'
        $Result.Why | Should -Be 'RunEnded'
        @($Result.Message) | Should -Contain '  That run is no longer running (it was an earlier run in this PowerShell session, and it has ended). It ended without removing its lock, for example because it was killed or its terminal or Cloud Shell session was closed.'
        $Result.Removes | Should -Be 1
        @($Result.Printed) | Should -BeNullOrEmpty
        @($Result.Next) | Should -Be @($true, $true)
        @($Result.Warnings) | Should -BeNullOrEmpty
        $Result.LeftA | Should -BeFalse
        $Result.LeftB | Should -BeFalse
    }

    It 'a run started under a nested prompt of a run that is paused, not ended (<Case>): a lock in another folder leaves the paused run''s lock and heartbeat alone; asking for the paused run''s lock names it as running, no remove command; only the paused run removes its lock; the next two runs take both locks' -ForEach @(
        @{ Case = 'the running command can be read'; NoPipeline = 'no' }
        @{ Case = 'the running command cannot be read'; NoPipeline = 'yes' }
    ) {
        $FolderB = Join-Path $script:CaseHome 'other-folder'
        $null = New-Item -ItemType Directory -Path $FolderB -Force
        $PathB = Join-Path $FolderB (Split-Path -Path $script:LockPath -Leaf)
        $Script = Join-Path $script:CaseHome 'nested.ps1'
        Set-Content -LiteralPath $Script -Encoding utf8 -Value @'
param($Functions, $PathA, $PathB, $NoPipeline)
. $Functions
# The non-public method that reads the running command, as when it is not there.
if ($NoPipeline -eq 'yes') { function Get-RunLockCurrentPipeline { $null } }
$A = Request-RunLock -Path $PathA -RunStartTime (Get-Date)
$null = Start-RunLockHeartbeat -Lock $A
$TextA = [System.IO.File]::ReadAllText($PathA)
# A nested prompt runs its commands as nested pipelines on this runspace.
$Nested = [powershell]::Create([System.Management.Automation.RunspaceMode]::CurrentRunspace)
$null = $Nested.AddScript({
        param($Functions, $PathA, $PathB, $NoPipeline)
        . $Functions
        if ($NoPipeline -eq 'yes') { function Get-RunLockCurrentPipeline { $null } }
        $B = Request-RunLock -Path $PathB -RunStartTime (Get-Date)
        $AskA = Request-RunLock -Path $PathA -RunStartTime (Get-Date)
        $Message = @(& { Write-RunLockHeldMessage -Request $AskA -Tenant 'tenant' } 6>&1 | ForEach-Object { [string]$_ })
        $BAcquired = [bool]$B.Acquired
        Remove-RunLock -Lock $B
        [pscustomobject]@{ BAcquired = $BAcquired; AskAcquired = [bool]$AskA.Acquired; Kind = $AskA.Holder.Kind; Why = $AskA.Holder.Why; Message = $Message }
    }.ToString()).AddArgument($Functions).AddArgument($PathA).AddArgument($PathB).AddArgument($NoPipeline)
$Inner = $Nested.Invoke()[0]
$Nested.Dispose()
$AAfter = [System.IO.File]::Exists($PathA) -and ([System.IO.File]::ReadAllText($PathA) -ceq $TextA)
$AState = [pscustomobject]@{ Stopped = [bool]$A.State['Stopped']; Released = [bool]$A.State['Released'] }
Remove-RunLock -Lock $A
$Gone = -not [System.IO.File]::Exists($PathA)
$Next = @(foreach ($Number in 1, 2) { foreach ($P in $PathA, $PathB) { $R = Request-RunLock -Path $P -RunStartTime (Get-Date); [bool]$R.Acquired; Remove-RunLock -Lock $R } })
'RESULT ' + ([pscustomobject]@{ Inner = $Inner; AUnchanged = $AAfter; AState = $AState; GoneAfterRelease = $Gone; Next = $Next; LeftA = [System.IO.File]::Exists($PathA); LeftB = [System.IO.File]::Exists($PathB) } | ConvertTo-Json -Compress -Depth 4)
'@
        $Out = @(& $script:Pwsh -NoProfile -NonInteractive -File $Script $script:FunctionsFile $script:LockPath $PathB $NoPipeline 2>&1 | ForEach-Object { [string]$_ })
        $Line = @($Out | Where-Object { $_ -like 'RESULT *' })
        $Line.Count | Should -Be 1 -Because ($Out -join ' | ')
        $Result = $Line[0].Substring(7) | ConvertFrom-Json
        $Result.Inner.BAcquired | Should -BeTrue
        $Result.AUnchanged | Should -BeTrue
        $Result.AState.Stopped | Should -BeFalse
        $Result.AState.Released | Should -BeFalse
        $Result.Inner.AskAcquired | Should -BeFalse
        $Result.Inner.Kind | Should -Be 'Running'
        @($Result.Inner.Message | Where-Object { $_ -match 'Remove-Item' }) | Should -BeNullOrEmpty
        $Result.GoneAfterRelease | Should -BeTrue
        @($Result.Next) | Should -Be @($true, $true, $true, $true)
        $Result.LeftA | Should -BeFalse
        $Result.LeftB | Should -BeFalse
    }

    It 'commands fed one after another into one session: the command after one that ended with an error waits for that run''s heartbeat to remove its lock and takes it, naming no holder, in 10 of 10 tries; the next two runs take it too' {
        $Script = Join-Path $script:CaseHome 'commands.ps1'
        Set-Content -LiteralPath $Script -Encoding utf8 -Value @'
param($Functions, $Path)
$Space = [runspacefactory]::CreateRunspace(); $Space.Open()
$Load = [powershell]::Create(); $Load.Runspace = $Space
$null = $Load.AddScript(". '$Functions'").Invoke(); $Load.Dispose()
$Tries = @(foreach ($Try in 1..10)
    {
        $One = [powershell]::Create(); $One.Runspace = $Space
        $null = $One.AddScript(("`$L = Request-RunLock -Path '{0}' -RunStartTime (Get-Date); `$null = Start-RunLockHeartbeat -Lock `$L; throw 'command 1 failed'" -f $Path))
        try { $null = $One.Invoke() } catch { $null = $_ }
        $One.Dispose()
        $Two = [powershell]::Create(); $Two.Runspace = $Space
        $null = $Two.AddScript(("`$Clock = [System.Diagnostics.Stopwatch]::StartNew(); `$R = Request-RunLock -Path '{0}' -RunStartTime (Get-Date); `$Ms = `$Clock.ElapsedMilliseconds; `$Got = [bool]`$R.Acquired; `$Clean = (`$null -eq `$R.Held -and `$null -eq `$R.Holder); `$Lines = @(); if (-not `$R.Acquired) {{ `$Lines = @(& {{ Write-RunLockHeldMessage -Request `$R -Tenant 'tenant' }} 6>&1 | ForEach-Object {{ [string]`$_ }}) }}; Remove-RunLock -Lock `$R; [pscustomobject]@{{ Acquired = `$Got; Clean = `$Clean; Ms = `$Ms; Removes = @(`$Lines | Where-Object {{ `$_ -match 'Remove-Item' }}).Count }}" -f $Path))
        $Two.Invoke()[0]
        $Two.Dispose()
    })
$Next = [powershell]::Create(); $Next.Runspace = $Space
$null = $Next.AddScript(("@(foreach (`$N in 1, 2) {{ `$R = Request-RunLock -Path '{0}' -RunStartTime (Get-Date); [bool]`$R.Acquired; Remove-RunLock -Lock `$R }})" -f $Path))
$NextRuns = @($Next.Invoke())
'RESULT ' + ([pscustomobject]@{ Tries = $Tries; Next = $NextRuns; Left = [System.IO.File]::Exists($Path) } | ConvertTo-Json -Compress -Depth 4)
'@
        $Out = @(& $script:Pwsh -NoProfile -NonInteractive -File $Script $script:FunctionsFile $script:LockPath 2>&1 | ForEach-Object { [string]$_ })
        $Line = @($Out | Where-Object { $_ -like 'RESULT *' })
        $Line.Count | Should -Be 1 -Because ($Out -join ' | ')
        $Result = $Line[0].Substring(7) | ConvertFrom-Json
        @($Result.Tries).Count | Should -Be 10
        @($Result.Tries | Where-Object { -not $_.Acquired }).Count | Should -Be 0 -Because ('stops: {0}' -f (($Result.Tries | ForEach-Object { '{0}/{1}ms' -f $_.Acquired, $_.Ms }) -join ', '))
        @($Result.Tries | Where-Object { $_.Removes -gt 0 }).Count | Should -Be 0
        @($Result.Tries | Where-Object { $_.Ms -gt 1500 }).Count | Should -Be 0
        @($Result.Tries | Where-Object { $_.Acquired -and -not $_.Clean }).Count | Should -Be 0 -Because 'a request that got the lock names no holder'
        @($Result.Next) | Should -Be @($true, $true)
        $Result.Left | Should -BeFalse
    }

    It 'a lock of this host name with another boot id that was refreshed after this machine started is described as another machine''s: how to check, then the remove command; after it the next two runs take the lock' -Skip:(-not $IsLinux) {
        script:Set-LockFile -ProcessId 4242 -BootId ([guid]::NewGuid().ToString()) -StartTicks '12345' -HeartbeatAgeSeconds 30
        $Bytes = [System.IO.File]::ReadAllBytes($script:LockPath)
        $Asked = script:Invoke-Request
        $Asked.Request.Acquired | Should -BeFalse
        $Asked.Request.Holder.Kind | Should -Be 'OtherMachine'
        $Asked.Request.Holder.Why | Should -Be 'OtherBoot'
        $Message = script:Get-HeldMessage -Request $Asked.Request
        $Message | Should -Contain ('  The lock names this host name, {0}, but another start of the machine, and it was refreshed after this machine started: it is from another machine with the same name, so whether that run is still going cannot be checked from here.' -f $script:Machine)
        @($Message | Where-Object { $_ -like ('  To check, on {0}: Get-Process -Id 4242 *' -f $script:Machine) }).Count | Should -Be 1
        @($Message | Where-Object { $_ -like '*has restarted since*' }) | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllBytes($script:LockPath) | Should -Be $Bytes
        script:Invoke-PrintedRemove -Text $Message
        foreach ($Next in 1..2)
        {
            $Again = script:Invoke-Request
            $Again.Request.Acquired | Should -BeTrue
            $Again.Lines | Should -BeNullOrEmpty
            Remove-RunLock -Lock $Again.Request
        }
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
    }

}

Describe 'One lock asked for by 8 runs at the same moment' -Tag 'Race' -Skip:$IsWindows {
    BeforeAll {
        Set-StrictMode -Version Latest
        $script:CanSimulateMachines = $false
        if (Get-Command -Name unshare -CommandType Application -ErrorAction SilentlyContinue)
        {
            # .NET creates /tmp/.dotnet on first use of a named mutex.
            [System.Threading.Mutex]::new($false, 'Global\RdaRunLockTestProbe').Dispose()
            & unshare --uts --mount --map-root-user sh -c 'mount --bind /tmp/.dotnet /tmp/.dotnet && hostname rda-probe' 2>$null
            $script:CanSimulateMachines = ($LASTEXITCODE -eq 0)
        }
        $script:RaceAsker = @'
param($Functions, $Path)
. $Functions
[Console]::Out.WriteLine('READY')
[Console]::Out.Flush()
$null = [Console]::In.ReadLine()
$Clock = [System.Diagnostics.Stopwatch]::StartNew()
$Lines = @(& { $script:Lock = Request-RunLock -Path $Path -RunStartTime (Get-Date) } 6>&1 | ForEach-Object { [string]$_ })
$Seconds = $Clock.Elapsed.TotalSeconds
$Acquired = [bool]$script:Lock.Acquired
if (-not $Acquired) { $Lines += @(& { Write-RunLockHeldMessage -Request $script:Lock -Tenant 'tenant' } 6>&1 | ForEach-Object { [string]$_ }) }
$Held = $script:Lock.Held
$Answer = [ordered]@{
    Machine  = [System.Net.Dns]::GetHostName()
    Id       = $PID
    Acquired = $Acquired
    Seconds  = [math]::Round($Seconds, 2)
    Problem  = [string]$script:Lock.Problem
    Held     = $(if ($null -ne $Held -and $Held.Valid) { '{0}/{1}' -f $Held.MachineName, $Held.ProcessId } elseif ($null -ne $Held -and $Held.Exists) { 'unreadable' } else { '' })
    Kind     = $(if ($script:Lock.PSObject.Properties['Holder'] -and $null -ne $script:Lock.Holder) { $script:Lock.Holder.Kind } else { '' })
    Lines    = $Lines
}
[Console]::Out.WriteLine('ANSWER ' + ($Answer | ConvertTo-Json -Compress -Depth 3))
[Console]::Out.Flush()
# The one that got it holds it until it is told to end: 'done' releases it,
# 'kill' ends the process with the lock in place.
$Next = [Console]::In.ReadLine()
if ($Next -eq 'kill') { Stop-Process -Id $PID -Force }
Remove-RunLock -Lock $script:Lock
exit $(if ($Acquired) { 0 } else { 1 })
'@
        # Starts the asker as a run on machine Name (its host name), whose
        # /tmp/.dotnet is the folder Tmp (runs that share it share /tmp).
        function script:Start-RaceRun
        {
            param([string]$Name, [string]$Tmp, [string]$Path = $script:LockPath)
            $Dotnet = Join-Path $script:CaseHome ('tmp-{0}' -f $Tmp)
            foreach ($Folder in 'shm', 'lockfiles') { New-Item -ItemType Directory -Path (Join-Path $Dotnet $Folder) -Force | Out-Null }
            $Asker = Join-Path $script:CaseHome 'race-ask.ps1'
            if (-not (Test-Path -LiteralPath $Asker)) { Set-Content -LiteralPath $Asker -Encoding utf8 -Value $script:RaceAsker }
            $Info = [System.Diagnostics.ProcessStartInfo]::new('unshare')
            foreach ($Arg in '--uts', '--mount', '--map-root-user', 'sh', '-c', 'mount --bind "$1" /tmp/.dotnet && hostname "$2" && shift 2 && exec "$@"', 'sh', $Dotnet, $Name, $script:Pwsh, '-NoProfile', '-NonInteractive', '-File', $Asker, $script:FunctionsFile, $Path) { $Info.ArgumentList.Add($Arg) }
            $Info.UseShellExecute = $false
            $Info.RedirectStandardInput = $true
            $Info.RedirectStandardOutput = $true
            $Info.RedirectStandardError = $true
            $Proc = [System.Diagnostics.Process]::Start($Info)
            $script:Started.Add($Proc)
            return [pscustomobject]@{ Process = $Proc; Name = $Name; Pending = $null; Err = $Proc.StandardError.ReadToEndAsync() }
        }

        function script:Read-RaceLine
        {
            param($Run, [string]$Prefix, [int]$TimeoutSeconds = 180)
            $Deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
            while ($true)
            {
                if ($null -eq $Run.Pending) { $Run.Pending = $Run.Process.StandardOutput.ReadLineAsync() }
                $Left = [int][math]::Max(0, ($Deadline - [datetime]::UtcNow).TotalMilliseconds)
                if (-not $Run.Pending.Wait($Left)) { return $null }
                $Line = $Run.Pending.Result
                $Run.Pending = $null
                if ($null -eq $Line) { return $null }
                if ($Line.StartsWith($Prefix)) { return $Line }
            }
        }

        function script:Send-RaceLine
        {
            param($Run, [string]$Line)
            try { $Run.Process.StandardInput.WriteLine($Line); $Run.Process.StandardInput.Flush() }
            catch { Write-Verbose ('{0} has ended: {1}' -f $Run.Name, $_.Exception.Message) }
        }

        # Starts the runs, lets them ask at the same moment and returns each
        # answer; End is what each is told once all have answered.
        function script:Invoke-Race
        {
            param([object[]]$Runs, [string]$End = 'done')
            foreach ($Run in $Runs) { $null = script:Read-RaceLine -Run $Run -Prefix 'READY' }
            foreach ($Run in $Runs) { script:Send-RaceLine -Run $Run -Line 'go' }
            $Lines = [System.Collections.Generic.List[object]]::new()
            foreach ($Run in $Runs) { $Lines.Add((script:Read-RaceLine -Run $Run -Prefix 'ANSWER ' -TimeoutSeconds 120)) }
            foreach ($Run in $Runs) { script:Send-RaceLine -Run $Run -Line $End }
            for ($Index = 0; $Index -lt $Runs.Count; $Index++)
            {
                $Run = $Runs[$Index]
                $Ended = $Run.Process.WaitForExit(60000)
                if ($Lines[$Index]) { $Answer = $Lines[$Index].Substring(7) | ConvertFrom-Json }
                else { $Answer = [pscustomobject]@{ Machine = $Run.Name; Id = $Run.Process.Id; Acquired = $null; Seconds = 0; Problem = ''; Held = ''; Kind = ''; Lines = @('no answer: ' + $Run.Err.Result) } }
                $Answer | Add-Member -NotePropertyName ExitCode -NotePropertyValue $(if ($Ended) { $Run.Process.ExitCode } else { $null })
                $Answer
            }
        }

        function script:Invoke-One
        {
            param([string]$Name, [string]$Tmp = 'one', [string]$End = 'done')
            @(script:Invoke-Race -Runs @(script:Start-RaceRun -Name $Name -Tmp $Tmp) -End $End)[0]
        }
    }
    AfterAll { Set-StrictMode -Off }
    BeforeEach { script:New-Case }
    AfterEach { script:Stop-Started }

    It 'no lock, 8 runspaces of one pwsh process at the same moment, in each of 30 tries: exactly one takes it, every other names it as running, with no remove command; the next two runs take it' {
        $Script = Join-Path $script:CaseHome 'runspaces.ps1'
        Set-Content -LiteralPath $Script -Encoding utf8 -Value @'
param($Functions, $Path, [int]$Tries)
$Spaces = @(foreach ($Index in 1..8)
    {
        $Space = [runspacefactory]::CreateRunspace(); $Space.Open()
        $Load = [powershell]::Create(); $Load.Runspace = $Space
        $null = $Load.AddScript(". '$Functions'").Invoke(); $Load.Dispose()
        $Space
    })
$Ask = {
    param($Path, $Start, $Answered)
    $null = $Start.Wait(60000)
    $R = Request-RunLock -Path $Path -RunStartTime (Get-Date)
    $Lines = @()
    if (-not $R.Acquired) { $Lines = @(& { Write-RunLockHeldMessage -Request $R -Tenant 'tenant' } 6>&1 | ForEach-Object { [string]$_ }) }
    $Got = [bool]$R.Acquired
    $null = $Answered.Signal()
    # The one that got it holds it until every run has answered.
    if ($Got) { $null = $Answered.Wait(60000); Remove-RunLock -Lock $R }
    [pscustomobject]@{ Acquired = $Got; Kind = $(if ($null -ne $R.Holder) { [string]$R.Holder.Kind } else { '' }); Removes = @($Lines | Where-Object { $_ -match 'Remove-Item' }).Count }
}.ToString()
$Results = @(foreach ($Try in 1..$Tries)
    {
        $Start = [System.Threading.ManualResetEventSlim]::new($false)
        $Answered = [System.Threading.CountdownEvent]::new(8)
        $Runs = @(foreach ($Space in $Spaces)
            {
                $Run = [powershell]::Create(); $Run.Runspace = $Space
                $null = $Run.AddScript($Ask).AddArgument($Path).AddArgument($Start).AddArgument($Answered)
                [pscustomobject]@{ PowerShell = $Run; Handle = $Run.BeginInvoke() }
            })
        Start-Sleep -Milliseconds 200
        $Start.Set()
        $Answers = @(foreach ($Run in $Runs) { $Run.PowerShell.EndInvoke($Run.Handle)[0]; $Run.PowerShell.Dispose() })
        [pscustomobject]@{
            Try     = $Try
            Holders = @($Answers | Where-Object { $_.Acquired }).Count
            Ended   = @($Answers | Where-Object { -not $_.Acquired -and $_.Kind -ne 'Running' }).Count
            Removes = (@($Answers | ForEach-Object { $_.Removes }) | Measure-Object -Sum).Sum
            Left    = [System.IO.File]::Exists($Path)
        }
    })
$Next = [powershell]::Create(); $Next.Runspace = $Spaces[0]
$null = $Next.AddScript(("@(foreach (`$N in 1, 2) {{ `$R = Request-RunLock -Path '{0}' -RunStartTime (Get-Date); [bool]`$R.Acquired; Remove-RunLock -Lock `$R }})" -f $Path))
$NextRuns = @($Next.Invoke())
'RESULT ' + ([pscustomobject]@{ Tries = $Results; Next = $NextRuns; Left = [System.IO.File]::Exists($Path) } | ConvertTo-Json -Compress -Depth 4)
'@
        $Out = @(& $script:Pwsh -NoProfile -NonInteractive -File $Script $script:FunctionsFile $script:LockPath 30 2>&1 | ForEach-Object { [string]$_ })
        $Line = @($Out | Where-Object { $_ -like 'RESULT *' })
        $Line.Count | Should -Be 1 -Because ($Out -join ' | ')
        $Result = $Line[0].Substring(7) | ConvertFrom-Json
        @($Result.Tries).Count | Should -Be 30
        $Problems = @($Result.Tries | Where-Object { $_.Holders -ne 1 -or $_.Ended -ne 0 -or $_.Removes -ne 0 -or $_.Left } | ForEach-Object { 'try {0}: holders {1}, named as ended {2}, remove commands {3}, lock left {4}' -f $_.Try, $_.Holders, $_.Ended, $_.Removes, $_.Left })
        $Problems | Should -BeNullOrEmpty
        @($Result.Next) | Should -Be @($true, $true)
        $Result.Left | Should -BeFalse
    }

    It 'no lock, 8 runs of one machine <Case>, in each of 20 tries: exactly one takes it, every other stops with exit 1 naming it as running, with no remove command' -ForEach @(
        @{ Case = 'through one path, one /tmp'; Form = 'shared' }
        @{ Case = 'through two spellings of the path (a symbolic link)'; Form = 'alias' }
        @{ Case = 'through one path, a /tmp of its own each'; Form = 'private' }
    ) {
        if (-not $script:CanSimulateMachines) { Set-ItResult -Skipped -Because 'unshare cannot give a process its own host name and /tmp/.dotnet here'; return }
        $Alias = Join-Path $script:CaseHome 'alias'
        if ($Form -eq 'alias') { $null = New-Item -ItemType SymbolicLink -Path $Alias -Target $script:Root }
        $Problems = @()
        foreach ($Try in 1..20)
        {
            $Runs = @(for ($Index = 0; $Index -lt 8; $Index++)
                {
                    $Path = if ($Form -eq 'alias' -and $Index % 2 -eq 1) { Join-Path $Alias (Split-Path -Path $script:LockPath -Leaf) } else { $script:LockPath }
                    $Tmp = if ($Form -eq 'private') { 'p{0}' -f $Index } else { 'one' }
                    script:Start-RaceRun -Name 'rda-one' -Tmp $Tmp -Path $Path
                })
            $Answers = @(script:Invoke-Race -Runs $Runs)
            $Winners = @($Answers | Where-Object { $_.Acquired -eq $true })
            if ($Winners.Count -ne 1) { $Problems += ('try {0}: {1} holders' -f $Try, $Winners.Count); continue }
            $Winner = $Winners[0]
            if ($Winner.ExitCode -ne 0 -or @($Winner.Lines).Count -ne 0) { $Problems += ('try {0}: winner exit {1}, lines {2}' -f $Try, $Winner.ExitCode, (@($Winner.Lines) -join ' | ')) }
            foreach ($Answer in @($Answers | Where-Object { $_.Acquired -ne $true }))
            {
                $Running = '  Process {0} on this machine is still running, so a run is using this folder.' -f $Winner.Id
                if ($Answer.Acquired -ne $false -or $Answer.ExitCode -ne 1 -or $Answer.Held -ne ('rda-one/{0}' -f $Winner.Id) -or $Answer.Kind -ne 'Running' -or @($Answer.Lines) -notcontains $Running -or @(@($Answer.Lines) | Where-Object { $_ -match 'Remove-Item' }).Count -ne 0)
                {
                    $Problems += ('try {0}: {1} acquired={2} exit={3} held="{4}" kind={5} lines={6}' -f $Try, $Answer.Id, $Answer.Acquired, $Answer.ExitCode, $Answer.Held, $Answer.Kind, (@($Answer.Lines) -join ' | '))
                }
            }
            if (Test-Path -LiteralPath $script:LockPath) { $Problems += ('try {0}: the winner did not release the lock' -f $Try) }
        }
        $Problems | Should -BeNullOrEmpty
        # The next two runs, one at a time: each takes the lock with no line.
        foreach ($Next in 1..2)
        {
            $One = script:Invoke-One -Name 'rda-one'
            $One.Acquired | Should -BeTrue
            $One.ExitCode | Should -Be 0
            @($One.Lines) | Should -BeNullOrEmpty
        }
        @(Get-ChildItem -LiteralPath $script:Root -Force -File) | Should -BeNullOrEmpty
    }

    It 'the full host name: a run on build.west.example stops on a lock of build.east.example with how to check and the remove command, live or killed, and never takes it; after the command, a west run and an east run take the lock' {
        if (-not $script:CanSimulateMachines) { Set-ItResult -Skipped -Because 'unshare cannot give a process its own host name and /tmp/.dotnet here'; return }
        $East = script:Start-RaceRun -Name 'build.east.example' -Tmp 'east'
        $null = script:Read-RaceLine -Run $East -Prefix 'READY'
        script:Send-RaceLine -Run $East -Line 'go'
        $EastAnswer = (script:Read-RaceLine -Run $East -Prefix 'ANSWER ').Substring(7) | ConvertFrom-Json
        $EastAnswer.Acquired | Should -BeTrue
        $EastStart = (Read-RunLock -Path $script:LockPath).ProcessStartTimeUtc
        $Bytes = [System.IO.File]::ReadAllBytes($script:LockPath)
        $Expected = script:Get-OtherMachineLines -Machine 'build.east.example' -ProcessId $EastAnswer.Id -ProcessStartUtc $EastStart
        # Live.
        $West = script:Invoke-One -Name 'build.west.example' -Tmp 'west'
        $West.Acquired | Should -BeFalse
        $West.ExitCode | Should -Be 1
        $West.Kind | Should -Be 'OtherMachine'
        $West.Held | Should -Be ('build.east.example/{0}' -f $EastAnswer.Id)
        script:Assert-Lines -Text @($West.Lines) -Expected $Expected
        [System.IO.File]::ReadAllBytes($script:LockPath) | Should -Be $Bytes
        # Killed with the lock in place.
        script:Send-RaceLine -Run $East -Line 'kill'
        $East.Process.WaitForExit(60000) | Should -BeTrue
        foreach ($Again in 1..2)
        {
            $West = script:Invoke-One -Name 'build.west.example' -Tmp 'west'
            $West.ExitCode | Should -Be 1
            $West.Kind | Should -Be 'OtherMachine'
            script:Assert-Lines -Text @($West.Lines) -Expected $Expected
            [System.IO.File]::ReadAllBytes($script:LockPath) | Should -Be $Bytes
        }
        # On the east name the process is seen to be gone.
        $EastAfter = script:Invoke-One -Name 'build.east.example' -Tmp 'east'
        $EastAfter.ExitCode | Should -Be 1
        $EastAfter.Kind | Should -Be 'Ended'
        script:Assert-Lines -Text @($EastAfter.Lines) -Expected (script:Get-EndedLines -Why ('process {0} is not running on this machine' -f $EastAnswer.Id))
        [System.IO.File]::ReadAllBytes($script:LockPath) | Should -Be $Bytes
        script:Invoke-PrintedRemove -Text @($West.Lines)
        foreach ($Name in 'build.west.example', 'build.east.example')
        {
            $Next = script:Invoke-One -Name $Name -Tmp ($Name -replace '^build\.([a-z]+)\.example$', '$1')
            $Next.Acquired | Should -BeTrue
            $Next.ExitCode | Should -Be 0
            @($Next.Lines) | Should -BeNullOrEmpty
        }
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
    }
}

Describe 'The heartbeat' {
    BeforeAll { Set-StrictMode -Version Latest }
    AfterAll { Set-StrictMode -Off }
    BeforeEach { script:New-Case }
    AfterEach { script:Stop-Started }

    It 'rewrites only the heartbeat time, every interval' {
        $Lock = Request-RunLock -Path $script:LockPath -RunStartTime (Get-Date)
        try
        {
            $Before = script:Get-LockValues
            $null = Start-RunLockHeartbeat -Lock $Lock -IntervalSeconds 1
            Start-Sleep -Milliseconds 2600
            $After = script:Get-LockValues
            foreach ($Key in 'MachineName', 'ProcessId', 'ProcessStartTimeUtc', 'RunStartTimeUtc', 'InvocationId') { $After[$Key] | Should -Be $Before[$Key] }
            (ConvertTo-RunLockTime -Value $After.HeartbeatUtc) | Should -BeGreaterThan (ConvertTo-RunLockTime -Value $Before.HeartbeatUtc).AddSeconds(1)
            @(Get-ChildItem -LiteralPath $script:Root -Force -File).Name | Should -Be @(Split-Path -Path $script:LockPath -Leaf)
        }
        finally
        {
            Remove-RunLock -Lock $Lock
        }
    }

    It 'runs in the wrapper: a run held for over a minute has a newer heartbeat and the rest of its lock unchanged' -Skip:$IsWindows {
        script:Set-Scenario -Subs 'A', 'B'
        $First = script:Start-Wrapper -Run 'r1' -Hold 'B'
        script:Wait-Held -Run 'r1' -Letters 'B'
        $Before = script:Get-LockValues
        Start-Sleep -Seconds 65
        $After = script:Get-LockValues
        foreach ($Key in 'MachineName', 'ProcessId', 'ProcessStartTimeUtc', 'RunStartTimeUtc', 'InvocationId') { $After[$Key] | Should -Be $Before[$Key] }
        ((script:ConvertFrom-LockTime -Text $After.HeartbeatUtc) - (script:ConvertFrom-LockTime -Text $Before.HeartbeatUtc)).TotalSeconds | Should -BeGreaterThan 30
        $After.ProcessId | Should -Be ([string]$First.Process.Id)
        script:Clear-Hold -Run 'r1' -Letters 'B'
        $End = script:Wait-Wrapper -Started $First
        $End.ExitCode | Should -Be 0
        script:Get-LockLines -Text $End.Text | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
    }

    It 'that cannot write warns once and the run goes on' -Skip:$IsWindows {
        $Script = Join-Path $script:CaseHome 'beat.ps1'
        Set-Content -LiteralPath $Script -Encoding utf8 -Value @'
param($Functions, $Path, $Root)
. $Functions
$Lock = Request-RunLock -Path $Path -RunStartTime (Get-Date)
$null = Start-RunLockHeartbeat -Lock $Lock -IntervalSeconds 1
& chmod 555 $Root
Start-Sleep -Seconds 4
Write-Host 'the run went on'
& chmod 755 $Root
Remove-RunLock -Lock $Lock
'@
        $Out = & $script:Pwsh -NoProfile -NonInteractive -File $Script $script:FunctionsFile $script:LockPath $script:Root 2>&1
        $Warnings = @($Out | Where-Object { $_ -like 'WARNING: Could not refresh the run lock*' })
        $Warnings.Count | Should -Be 1
        $Warnings[0] | Should -BeLike ('WARNING: Could not refresh the run lock {0}: *. The run goes on; the lock shows the time of its last refresh.' -f $script:LockPath)
        $Out | Should -Contain 'the run went on'
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
    }

    It 'a lock put in place of the run''s own while it runs (<Case>): the heartbeat and the release never write or remove it, and the run warns once' -ForEach @(
        @{ Case = 'another machine''s lock'; Raw = '{"MachineName":"other-machine","ProcessId":4242,"ProcessStartTimeUtc":"2026-01-01T00:00:00.0000000Z","RunStartTimeUtc":"2026-01-01T00:00:01.0000000Z","HeartbeatUtc":"2026-01-01T00:00:02.0000000Z"}'; Holder = 'process 4242 on other-machine' }
        @{ Case = 'a lock of this process with another run id'; Raw = 'self'; Holder = 'another run in this process' }
        @{ Case = 'a file that is not a lock'; Raw = 'not a lock'; Holder = 'a file that is not a valid run lock' }
    ) {
        $Script = Join-Path $script:CaseHome 'beat.ps1'
        Set-Content -LiteralPath $Script -Encoding utf8 -Value @'
param($Functions, $Path, $Raw)
. $Functions
$Lock = Request-RunLock -Path $Path -RunStartTime (Get-Date)
$null = Start-RunLockHeartbeat -Lock $Lock -IntervalSeconds 1
if ($Raw -eq 'self')
{
    $Copy = [ordered]@{}
    foreach ($Key in $Lock.Record.Keys) { $Copy[$Key] = $Lock.Record[$Key] }
    $Copy['InvocationId'] = [guid]::NewGuid().ToString()
    $Raw = $Copy | ConvertTo-Json -Compress
}
[System.IO.File]::WriteAllText($Path, $Raw)
$Written = [System.IO.File]::GetLastWriteTimeUtc($Path).Ticks
Start-Sleep -Seconds 3
Remove-RunLock -Lock $Lock
Start-Sleep -Seconds 2
Write-Host ('UNCHANGED {0}' -f ([System.IO.File]::ReadAllText($Path) -ceq $Raw -and [System.IO.File]::GetLastWriteTimeUtc($Path).Ticks -eq $Written))
'@
        $Out = @(& $script:Pwsh -NoProfile -NonInteractive -File $Script $script:FunctionsFile $script:LockPath $Raw 2>&1 | ForEach-Object { [string]$_ })
        @($Out | Where-Object { $_ -like 'WARNING:*' }) | Should -Be @(('WARNING: This run no longer refreshes or removes the run lock {0}: it is now held by {1}. The run goes on.' -f $script:LockPath, $Holder))
        $Out | Should -Contain 'UNCHANGED True'
        Test-Path -LiteralPath $script:LockPath | Should -BeTrue
    }

    It 'the lock removed by hand while the run goes on: the heartbeat stops with one warning and never writes a lock again, also when a new run takes it' {
        $Script = Join-Path $script:CaseHome 'beat.ps1'
        Set-Content -LiteralPath $Script -Encoding utf8 -Value @'
param($Functions, $Path)
. $Functions
$Lock = Request-RunLock -Path $Path -RunStartTime (Get-Date)
$null = Start-RunLockHeartbeat -Lock $Lock -IntervalSeconds 1
[System.IO.File]::Delete($Path)
Start-Sleep -Seconds 2
[System.IO.File]::WriteAllText(($Path + '.gone'), 'yes')
$Deadline = (Get-Date).AddSeconds(60)
while (-not (Test-Path -LiteralPath ($Path + '.next')) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 50 }
Start-Sleep -Seconds 3
Remove-RunLock -Lock $Lock
'@
        $Beat = script:Start-Pwsh -Arguments '-File', $Script, $script:FunctionsFile, $script:LockPath
        $Deadline = (Get-Date).AddSeconds(60)
        while (-not (Test-Path -LiteralPath ($script:LockPath + '.gone')) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 50 }
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        $New = script:Invoke-Request
        $New.Request.Acquired | Should -BeTrue
        $NewText = Get-Content -LiteralPath $script:LockPath -Raw
        Set-Content -LiteralPath ($script:LockPath + '.next') -Value 'go'
        $Beat.Process.WaitForExit(60000) | Should -BeTrue
        Get-Content -LiteralPath $script:LockPath -Raw | Should -Be $NewText
        @(([string]$Beat.Out.Result -split "`r?`n") | Where-Object { $_ -like 'WARNING:*' }) | Should -Be @(('WARNING: This run no longer refreshes or removes the run lock {0}: it was removed. The run goes on.' -f $script:LockPath))
        Remove-RunLock -Lock $New.Request
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
    }
}

Describe 'Runs of the wrapper that find a lock' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Stop-Started }

    It 'the tenant id in capitals: a run stops on the lock of a live run that gave it in small letters, with no remove command, and no second lock file appears; once the first ends, a run with capitals and one with small letters proceed' {
        script:Set-Scenario -Subs 'A', 'B' -Tenant $script:TenantB
        $Capitals = $script:TenantB.ToUpperInvariant()
        $First = script:Start-Wrapper -Run 'r1' -Hold 'B' -Tenant $script:TenantB
        script:Wait-Held -Run 'r1' -Letters 'B'
        $LockText = Get-Content -LiteralPath $script:LockPathB -Raw
        $Second = script:Invoke-Wrapper -Run 'r2' -Tenant $Capitals
        $Second.ExitCode | Should -Be 1
        script:Get-Collected -Run 'r2' | Should -BeNullOrEmpty
        $Second.Text | Should -Contain ('  Process {0} on this machine is still running, so a run is using this folder.' -f $First.Process.Id)
        script:Get-RemoveLines -Text $Second.Text | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*' | ForEach-Object Name) | Should -Be @(Split-Path -Path $script:LockPathB -Leaf)
        Get-Content -LiteralPath $script:LockPathB -Raw | Should -Be $LockText
        script:Clear-Hold -Run 'r1' -Letters 'B'
        (script:Wait-Wrapper -Started $First).ExitCode | Should -Be 0
        foreach ($Next in @(@{ Run = 'r3'; Tenant = $Capitals }, @{ Run = 'r4'; Tenant = $script:TenantB }))
        {
            $Run = script:Invoke-Wrapper -Run $Next.Run -Tenant $Next.Tenant
            $Run.ExitCode | Should -Be 0
            script:Get-Collected -Run $Next.Run | Should -Be @('A', 'B')
            script:Get-LockAtList -Run $Next.Run | Should -Be 'True'
            script:Get-LockLines -Text $Run.Text | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*') | Should -BeNullOrEmpty
        }
    }

    It 'with <Streams> stream(s): a second run while the first runs stops with exit 1, writes nothing and prints no remove command; once the first ends, the next two runs proceed' -ForEach @(
        @{ Streams = 1; Held = @('B') }
        @{ Streams = 2; Held = @('C', 'D') }
    ) {
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $First = script:Start-Wrapper -Streams $Streams -Run 'r1' -Hold $Held
        script:Wait-Held -Run 'r1' -Letters $Held
        $Before = script:Get-RootSnapshot
        $LockBefore = Get-Content -LiteralPath $script:LockPath -Raw

        $Second = script:Invoke-Wrapper -Streams $Streams -Run 'r2' -Arguments '-Resume'

        $Second.ExitCode | Should -Be 1
        script:Get-Collected -Run 'r2' | Should -BeNullOrEmpty
        script:Get-RootSnapshot | Should -Be $Before
        $Holder = script:Get-LockValues
        Get-Content -LiteralPath $script:LockPath -Raw | Should -Be $LockBefore
        # The lock is the wrapper's, not a stream worker's.
        $Holder.ProcessId | Should -Be ([string]$First.Process.Id)
        script:Assert-Lines -Text $Second.Text -Expected (script:Get-HolderLines -Machine $script:Machine -ProcessId $First.Process.Id -ProcessStartUtc (script:ConvertFrom-LockTime -Text $Holder.ProcessStartTimeUtc) -RunStartUtc (script:ConvertFrom-LockTime -Text $Holder.RunStartTimeUtc))
        @($Second.Text | Where-Object { $_ -like ('  Last refresh: {0} (* seconds ago)' -f (script:Format-Utc -Value (script:ConvertFrom-LockTime -Text $Holder.HeartbeatUtc))) }).Count | Should -Be 1
        script:Assert-Lines -Text $Second.Text -Expected (script:Get-RunningLines -ProcessId $First.Process.Id)
        script:Get-RemoveLines -Text $Second.Text | Should -BeNullOrEmpty
        $Second.Text | Should -Not -Contain 'All subscriptions processed!'

        script:Clear-Hold -Run 'r1' -Letters $Held
        $FirstEnd = script:Wait-Wrapper -Started $First
        $FirstEnd.ExitCode | Should -Be 0
        script:Get-Collected -Run 'r1' | Should -Be @('A', 'B', 'C', 'D')
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse

        foreach ($Next in 'r3', 'r4')
        {
            $Run = script:Invoke-Wrapper -Streams $Streams -Run $Next
            $Run.ExitCode | Should -Be 0
            script:Get-Collected -Run $Next | Should -Be @('A', 'B', 'C', 'D')
            script:Get-LockAtList -Run $Next | Should -Be 'True'
            script:Get-LockLines -Text $Run.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }

    It 'with <Streams> stream(s): two runs started at the same moment, exactly one proceeds' -ForEach @(
        @{ Streams = 1; Held = @('A') }
        @{ Streams = 2; Held = @('A', 'B') }
    ) {
        script:Set-Scenario -Subs 'A', 'B'
        $One = script:Start-Wrapper -Streams $Streams -Run 'r1' -Hold $Held
        $Two = script:Start-Wrapper -Streams $Streams -Run 'r2' -Hold $Held
        $Deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $Deadline -and -not ($One.Process.HasExited -or $Two.Process.HasExited)) { Start-Sleep -Milliseconds 200 }
        ($One.Process.HasExited -or $Two.Process.HasExited) | Should -BeTrue -Because 'one of the two runs stops'
        $Stopped, $Going, $GoingRun = if ($One.Process.HasExited) { $One, $Two, 'r2' } else { $Two, $One, 'r1' }
        $StoppedEnd = script:Wait-Wrapper -Started $Stopped
        $StoppedEnd.ExitCode | Should -Be 1
        script:Assert-Lines -Text $StoppedEnd.Text -Expected (script:Get-RunningLines -ProcessId $Going.Process.Id)
        script:Get-RemoveLines -Text $StoppedEnd.Text | Should -BeNullOrEmpty
        script:Get-Collected -Run $Stopped.Run | Should -BeNullOrEmpty
        script:Wait-Held -Run $GoingRun -Letters $Held
        $Going.Process.HasExited | Should -BeFalse
        script:Clear-Hold -Run $GoingRun -Letters $Held
        $GoingEnd = script:Wait-Wrapper -Started $Going
        $GoingEnd.ExitCode | Should -Be 0
        script:Get-Collected -Run $GoingRun | Should -Be @('A', 'B')
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse

        foreach ($Next in 'r3', 'r4')
        {
            $Run = script:Invoke-Wrapper -Streams $Streams -Run $Next
            $Run.ExitCode | Should -Be 0
            script:Get-LockLines -Text $Run.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }

    It 'with <Streams> stream(s): a run killed while it holds the lock: the next run stops with exit 1, says that run is not running and prints the remove command; after it, the next two runs proceed and leave no lock' -ForEach @(
        @{ Streams = 1; Held = @('B'); Rest = @('B', 'C', 'D') }
        @{ Streams = 2; Held = @('C', 'D'); Rest = @('C', 'D') }
    ) {
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $First = script:Start-Wrapper -Streams $Streams -Run 'r1' -Hold $Held
        script:Wait-Held -Run 'r1' -Letters $Held
        $First.Process.Kill($true)
        $Killed = script:Wait-Wrapper -Started $First -TimeoutSeconds 60
        $Killed.ExitCode | Should -Be 137
        Test-Path -LiteralPath $script:LockPath | Should -BeTrue
        $Holder = script:Get-LockValues
        $Holder.ProcessId | Should -Be ([string]$First.Process.Id)
        $LockText = Get-Content -LiteralPath $script:LockPath -Raw
        $Before = script:Get-RootSnapshot

        $Next = script:Invoke-Wrapper -Streams $Streams -Run 'r2' -Arguments '-Resume'
        $Next.ExitCode | Should -Be 1
        script:Get-Collected -Run 'r2' | Should -BeNullOrEmpty
        script:Get-RootSnapshot | Should -Be $Before
        Get-Content -LiteralPath $script:LockPath -Raw | Should -Be $LockText
        script:Assert-Lines -Text $Next.Text -Expected (script:Get-HolderLines -Machine $script:Machine -ProcessId $First.Process.Id -ProcessStartUtc (script:ConvertFrom-LockTime -Text $Holder.ProcessStartTimeUtc) -RunStartUtc (script:ConvertFrom-LockTime -Text $Holder.RunStartTimeUtc))
        script:Assert-Lines -Text $Next.Text -Expected (script:Get-EndedLines -Why ('process {0} is not running on this machine' -f $First.Process.Id))

        script:Invoke-PrintedRemove -Text $Next.Text
        $Resumed = script:Invoke-Wrapper -Streams $Streams -Run 'r3' -Arguments '-Resume'
        $Resumed.ExitCode | Should -Be 0
        script:Get-Collected -Run 'r3' | Should -Be $Rest
        script:Get-LockAtList -Run 'r3' | Should -Be 'True'
        script:Get-LockLines -Text $Resumed.Text | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        $Last = script:Invoke-Wrapper -Streams $Streams -Run 'r4'
        $Last.ExitCode | Should -Be 0
        script:Get-LockLines -Text $Last.Text | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
    }

    It 'a running process on this machine that started at the recorded time: exit 1 with no remove command; once it ends, the next run says it is not running and prints the command; after it the next two runs proceed' {
        script:Set-Scenario -Subs 'A'
        $Sleeper = [System.Diagnostics.Process]::Start('sleep', '300')
        $script:Started.Add($Sleeper)
        $SleeperStart = $Sleeper.StartTime.ToUniversalTime()
        script:Set-LockFile -ProcessId $Sleeper.Id -ProcessStartUtc $SleeperStart -HeartbeatAgeSeconds 20
        $Lock = Get-Content -LiteralPath $script:LockPath -Raw
        $Before = script:Get-RootSnapshot

        $Run = script:Invoke-Wrapper -Run 'r1'
        $Run.ExitCode | Should -Be 1
        script:Assert-Lines -Text $Run.Text -Expected (script:Get-HolderLines -Machine $script:Machine -ProcessId $Sleeper.Id -ProcessStartUtc $SleeperStart -RunStartUtc $SleeperStart.AddSeconds(2))
        script:Assert-Lines -Text $Run.Text -Expected (script:Get-RunningLines -ProcessId $Sleeper.Id)
        script:Get-RemoveLines -Text $Run.Text | Should -BeNullOrEmpty
        Get-Content -LiteralPath $script:LockPath -Raw | Should -Be $Lock
        script:Get-RootSnapshot | Should -Be $Before

        $Sleeper.Kill()
        $Sleeper.WaitForExit()
        $Ended = script:Invoke-Wrapper -Run 'r2'
        $Ended.ExitCode | Should -Be 1
        script:Assert-Lines -Text $Ended.Text -Expected (script:Get-EndedLines -Why ('process {0} is not running on this machine' -f $Sleeper.Id))
        Get-Content -LiteralPath $script:LockPath -Raw | Should -Be $Lock
        script:Invoke-PrintedRemove -Text $Ended.Text
        foreach ($Next in 'r3', 'r4')
        {
            $After = script:Invoke-Wrapper -Run $Next
            $After.ExitCode | Should -Be 0
            script:Get-LockLines -Text $After.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }

    It 'another machine: a heartbeat 2 minutes old and 3 days old both stop every run with how to check and the remove command, the lock unchanged; after the printed command the next two runs proceed' {
        script:Set-Scenario -Subs 'A'
        $Start = [datetime]::UtcNow.AddHours(-1)
        $Before = script:Get-RootSnapshot
        foreach ($Age in 120, 259200)
        {
            script:Set-LockFile -Machine 'build.east.example' -ProcessId 4242 -ProcessStartUtc $Start -HeartbeatAgeSeconds $Age -FileAgeSeconds 60
            $Lock = Get-Content -LiteralPath $script:LockPath -Raw
            $Written = (Get-Item -LiteralPath $script:LockPath -Force).LastWriteTimeUtc
            foreach ($Attempt in 'r1', 'r2')
            {
                $Run = script:Invoke-Wrapper -Run $Attempt
                $Run.ExitCode | Should -Be 1
                script:Assert-Lines -Text $Run.Text -Expected (script:Get-HolderLines -Machine 'build.east.example' -ProcessId 4242 -ProcessStartUtc $Start -RunStartUtc $Start.AddSeconds(2))
                @($Run.Text | Where-Object { $_ -like ('  Last refresh: * ({0} ago)' -f $(if ($Age -eq 120) { '2 minutes' } else { '3 days' })) }).Count | Should -Be 1
                script:Assert-Lines -Text $Run.Text -Expected (script:Get-OtherMachineLines -Machine 'build.east.example' -ProcessId 4242 -ProcessStartUtc $Start)
                Get-Content -LiteralPath $script:LockPath -Raw | Should -Be $Lock
                (Get-Item -LiteralPath $script:LockPath -Force).LastWriteTimeUtc | Should -Be $Written
                script:Get-RootSnapshot | Should -Be $Before
                script:Get-Collected -Run $Attempt | Should -BeNullOrEmpty
            }
        }
        script:Invoke-PrintedRemove -Text $Run.Text
        foreach ($Next in 'r3', 'r4')
        {
            $After = script:Invoke-Wrapper -Run $Next
            $After.ExitCode | Should -Be 0
            script:Get-Collected -Run $Next | Should -Be @('A')
            script:Get-LockLines -Text $After.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }

    It 'a lock that cannot be read <Case>: exit 1 with the remove command and the check first, the lock unchanged; after the printed command the next two runs proceed' -ForEach @(
        @{ Case = '(not JSON)'; Raw = '{not json'; Problem = 'it is not a JSON object' }
        @{ Case = '(empty)'; Raw = ''; Problem = 'it is empty' }
        @{ Case = '(present but invalid values)'; Raw = '{"MachineName":"","ProcessId":-3,"ProcessStartTimeUtc":"2026-02-30T00:00:00Z","RunStartTimeUtc":"2026-01-01T00:00:00Z","HeartbeatUtc":12}'; Problem = 'MachineName, ProcessId, ProcessStartTimeUtc, HeartbeatUtc missing or not valid' }
    ) {
        script:Set-Scenario -Subs 'A'
        script:Set-LockFile -Raw $Raw -FileAgeSeconds 2
        $Before = script:Get-RootSnapshot
        foreach ($Attempt in 'r1', 'r2')
        {
            $Run = script:Invoke-Wrapper -Run $Attempt
            $Run.ExitCode | Should -Be 1
            script:Assert-Lines -Text $Run.Text -Expected (script:Get-UnreadableLines -Problem $Problem)[0..1]
            script:Assert-Lines -Text $Run.Text -Expected (script:Get-UnreadableLines -Problem $Problem)[2..4]
            [System.IO.File]::ReadAllText($script:LockPath) | Should -Be $Raw
            script:Get-RootSnapshot | Should -Be $Before
            script:Get-Collected -Run $Attempt | Should -BeNullOrEmpty
        }
        script:Invoke-PrintedRemove -Text $Run.Text
        foreach ($Last in 'r3', 'r4')
        {
            $After = script:Invoke-Wrapper -Run $Last
            $After.ExitCode | Should -Be 0
            script:Get-LockLines -Text $After.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }

    It 'a run whose lock is replaced by another machine''s while it runs leaves that lock in place with one warning; the next run stops on it; after the printed command the next two runs proceed' {
        script:Set-Scenario -Subs 'A', 'B'
        $First = script:Start-Wrapper -Run 'r1' -Hold 'B'
        script:Wait-Held -Run 'r1' -Letters 'B'
        script:Set-LockFile -Machine 'other-machine' -ProcessId 4242 -HeartbeatAgeSeconds 5
        $Other = Get-Content -LiteralPath $script:LockPath -Raw
        script:Clear-Hold -Run 'r1' -Letters 'B'
        $End = script:Wait-Wrapper -Started $First
        $End.ExitCode | Should -Be 0
        @($End.Text | Where-Object { $_ -like 'WARNING:*run lock*' }) | Should -Be @(('WARNING: Left the run lock {0} in place: it is now held by process 4242 on other-machine.' -f $script:LockPath))
        Get-Content -LiteralPath $script:LockPath -Raw | Should -Be $Other

        $Next = script:Invoke-Wrapper -Run 'r2'
        $Next.ExitCode | Should -Be 1
        script:Get-RemoveLines -Text $Next.Text | Should -Be @((script:Get-ExpectedRemoveLine))
        Get-Content -LiteralPath $script:LockPath -Raw | Should -Be $Other
        script:Invoke-PrintedRemove -Text $Next.Text
        foreach ($Last in 'r3', 'r4')
        {
            $After = script:Invoke-Wrapper -Run $Last
            $After.ExitCode | Should -Be 0
            script:Get-LockLines -Text $After.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }
}

Describe 'The lock is released on every way out' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Stop-Started }

    It 'exit 1 after the lock is taken (no subscriptions), and the next two runs find no lock' {
        script:Set-Scenario -Subs @()
        $Run = script:Invoke-Wrapper -Run 'r1'
        $Run.ExitCode | Should -Be 1
        script:Get-LockAtList -Run 'r1' | Should -Be 'True'
        $Run.Text | Should -Contain ('ERROR: Get-AzSubscription returned no subscriptions for tenant {0}.' -f $script:Tenant)
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        script:Set-Scenario -Subs 'A'
        foreach ($Next in 'r2', 'r3')
        {
            $After = script:Invoke-Wrapper -Run $Next
            $After.ExitCode | Should -Be 0
            script:Get-LockLines -Text $After.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }

    It 'exit 1 with no run to retry (-ResumeFailedOnly), and the next two runs find no lock' {
        script:Set-Scenario -Subs 'A'
        $Run = script:Invoke-Wrapper -Run 'r1' -Arguments '-ResumeFailedOnly'
        $Run.ExitCode | Should -Be 1
        # The run takes its lock before it decides how it starts, and this stop
        # comes before it signs in, so it never reads the subscription list.
        @($Run.Text | Where-Object { $_ -like 'ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry.*' }).Count | Should -Be 1
        script:Get-LockAtList -Run 'r1' | Should -Be 'not reached'
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        foreach ($Next in 'r2', 'r3')
        {
            $After = script:Invoke-Wrapper -Run $Next
            $After.ExitCode | Should -Be 0
            script:Get-LockLines -Text $After.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }

    It 'with <Streams> stream(s): exit 2 (a report zip missing), and the next two runs find no lock' -ForEach @(
        @{ Streams = 1 }
        @{ Streams = 2 }
    ) {
        script:Set-Scenario -Subs 'A', 'B' -NoZip 'B'
        $Run = script:Invoke-Wrapper -Streams $Streams -Run 'r1'
        $Run.ExitCode | Should -Be 2
        script:Get-LockAtList -Run 'r1' | Should -Be 'True'
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        script:Set-Scenario -Subs 'A', 'B'
        foreach ($Next in 'r2', 'r3')
        {
            $After = script:Invoke-Wrapper -Streams $Streams -Run $Next
            $After.ExitCode | Should -Be 0
            script:Get-LockLines -Text $After.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }

    It 'an error that ends the script (pwsh -File): the lock is released, and the next two runs find no lock' {
        script:Set-Scenario -Subs 'A' -ThrowAtList
        $Run = script:Invoke-Wrapper -Run 'r1'
        $Run.ExitCode | Should -Not -Be 0
        script:Get-LockAtList -Run 'r1' | Should -Be 'True'
        ($Run.Error + ($Run.Text -join "`n")) | Should -BeLike '*stand-in: the subscription list failed*'
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        script:Set-Scenario -Subs 'A'
        foreach ($Next in 'r2', 'r3')
        {
            $After = script:Invoke-Wrapper -Run $Next
            $After.ExitCode | Should -Be 0
            script:Get-LockLines -Text $After.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }

    It 'with <Streams> stream(s): an interrupted run (Ctrl+C) removes its lock and keeps its resume state; the next two runs continue it' -ForEach @(
        @{ Streams = 1; Held = @('B'); Rest = @('B', 'C', 'D') }
        @{ Streams = 2; Held = @('C', 'D'); Rest = @('C', 'D') }
    ) {
        if (-not $script:Perl -and $script:SigIntIgnored) { Set-ItResult -Skipped -Because 'this test process ignores Ctrl+C (SIGINT), so the run it starts would too, and perl is not there to set it back'; return }
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $First = script:Start-Wrapper -Streams $Streams -Run 'r1' -Hold $Held
        script:Wait-Held -Run 'r1' -Letters $Held
        Test-Path -LiteralPath $script:LockPath | Should -BeTrue
        & kill -s INT $First.Process.Id
        $null = script:Wait-Wrapper -Started $First -TimeoutSeconds 60
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*').Count | Should -Be 0

        $Next = script:Invoke-Wrapper -Streams $Streams -Run 'r2' -Arguments '-Resume'
        $Next.ExitCode | Should -Be 0
        script:Get-LockLines -Text $Next.Text | Should -BeNullOrEmpty
        script:Get-Collected -Run 'r2' | Should -Be $Rest
        $Last = script:Invoke-Wrapper -Streams $Streams -Run 'r3' -Arguments '-Resume'
        $Last.ExitCode | Should -Be 0
        script:Get-LockLines -Text $Last.Text | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
    }

    It 'in one pwsh process that goes on, as at a prompt: run 1 ends with an error, its lock is gone and the file is not written again; run 2 and run 3 in the same process take the lock and end with exit 0' {
        script:Set-Scenario -Subs 'A' -ThrowAtList
        $Out = Join-Path $script:CaseHome 'session.json'
        $Session = script:Start-CaseScript -Name 'session.ps1' -Source $script:SessionHostSource -Arguments @('-Wrapper', $script:Wrapper, '-Tenant', $script:Tenant, '-Out', $Out, '-CaseHome', $script:CaseHome)
        $Deadline = (Get-Date).AddSeconds(120)
        while (-not (Test-Path -LiteralPath (Join-Path $script:CaseHome 'session-1-ended')) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 50 }
        (Get-Content -LiteralPath (Join-Path $script:CaseHome 'session-1-ended') -Raw).Trim() | Should -Be 'stand-in: the subscription list failed'
        script:Get-LockAtList -Run 'run' | Should -Be 'True'
        # Watch the folder for 3 seconds after the command ended: the lock goes
        # within the heartbeat's next look (a quarter second) and no lock file
        # is written after that.
        $Seen = [System.Collections.Generic.List[string]]::new()
        $Clock = [System.Diagnostics.Stopwatch]::StartNew()
        $GoneAt = $null
        while ($Clock.Elapsed.TotalSeconds -lt 3)
        {
            $Here = Test-Path -LiteralPath $script:LockPath
            if (-not $Here -and $null -eq $GoneAt) { $GoneAt = $Clock.Elapsed.TotalSeconds }
            if ($Here -and $null -ne $GoneAt) { $Seen.Add(('lock back at {0:n2} s' -f $Clock.Elapsed.TotalSeconds)) }
            foreach ($File in @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*' -ErrorAction SilentlyContinue)) { if ($null -ne $GoneAt) { $Seen.Add($File.Name) } }
            Start-Sleep -Milliseconds 20
        }
        $GoneAt | Should -Not -BeNullOrEmpty
        $GoneAt | Should -BeLessThan 1
        $Seen | Should -BeNullOrEmpty
        $Session.Process.HasExited | Should -BeFalse -Because 'the session goes on'
        script:Set-Scenario -Subs 'A'
        Set-Content -LiteralPath (Join-Path $script:CaseHome 'session-go') -Value 'go'
        $null = script:Wait-Wrapper -Started $Session -TimeoutSeconds 300
        $Result = Get-Content -LiteralPath $Out -Raw | ConvertFrom-Json
        $Result.ProcessId | Should -Be $Session.Process.Id
        foreach ($Next in @($Result.Runs))
        {
            $Next.Exit | Should -Be 0
            $Next.LockAfter | Should -BeFalse
            @($Next.Lines) | Should -Contain 'All subscriptions processed!'
            script:Get-LockLines -Text @($Next.Lines) | Should -BeNullOrEmpty
        }
        @($Result.Runs).Count | Should -Be 2
        script:Get-Collected -Run 'run' | Should -Be @('A', 'A')
    }

    It 'with 2 streams, interrupted (Ctrl+C) after its workers died: the lock stays until its clean-up has finished; a run started meanwhile stops with exit 1 and no remove command; then the next two runs proceed' {
        if (-not $script:Perl -and $script:SigIntIgnored) { Set-ItResult -Skipped -Because 'this test process ignores Ctrl+C (SIGINT), so the run it starts would too, and perl is not there to set it back'; return }
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $First = script:Start-Wrapper -Streams 2 -Run 'r1' -Hold 'C', 'D'
        script:Wait-Held -Run 'r1' -Letters 'C', 'D'
        $Workers = @('C', 'D' | ForEach-Object { [int](Get-Content -LiteralPath (Join-Path $script:CaseHome ('held-r1-' + $script:Subs[$_].Id)) -Raw).Trim() })
        foreach ($Worker in $Workers) { Stop-Process -Id $Worker -Force }
        Start-Sleep -Seconds 2
        & kill -s INT $First.Process.Id
        Start-Sleep -Seconds 5
        $First.Process.HasExited | Should -BeFalse -Because 'the wrapper is still in its clean-up (Stop-Job on workers that died)'
        Test-Path -LiteralPath $script:LockPath | Should -BeTrue
        $Second = script:Invoke-Wrapper -Streams 2 -Run 'r2' -Arguments '-Resume'
        $Second.ExitCode | Should -Be 1
        script:Assert-Lines -Text $Second.Text -Expected (script:Get-RunningLines -ProcessId $First.Process.Id)
        script:Get-RemoveLines -Text $Second.Text | Should -BeNullOrEmpty
        script:Get-Collected -Run 'r2' | Should -BeNullOrEmpty
        $First.Process.HasExited | Should -BeFalse -Because 'the second run was started during the first run''s clean-up'
        $null = script:Wait-Wrapper -Started $First -TimeoutSeconds 180
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        foreach ($Next in 'r3', 'r4')
        {
            $Run = script:Invoke-Wrapper -Streams 2 -Run $Next -Arguments '-Resume'
            $Run.ExitCode | Should -Be 0
            script:Get-LockLines -Text $Run.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }
}

Describe 'Runs of the wrapper in one process' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Stop-Started }

    It 'a pwsh -File script that runs the wrapper for one tenant, catches its error, then runs it for another tenant: each run removes its own lock, so none is left once the process has ended; the next two runs for the first tenant proceed' {
        script:Set-Scenario -Subs 'A' -Path (Join-Path $script:CaseHome 'scenario-a-throw.json') -ThrowAtList
        script:Set-Scenario -Subs 'X' -Tenant $script:TenantB -Path $script:ScenarioB
        $Out = Join-Path $script:CaseHome 'tenants.json'
        $Loop = script:Start-CaseScript -Name 'tenants.ps1' -Source @'
param([string]$Wrapper, [string]$TenantA, [string]$ScenarioA, [string]$TenantB, [string]$ScenarioB, [string]$Out)
$LockA = Join-Path $HOME ('InventoryReports/.run-lock-{0}.json' -f $TenantA.ToLowerInvariant())
$LockB = Join-Path $HOME ('InventoryReports/.run-lock-{0}.json' -f $TenantB.ToLowerInvariant())
$Result = [ordered]@{}
$global:RdaStandInScenario = $ScenarioA
$global:RdaStandInRun = 'ta'
try { $null = & $Wrapper -TenantID $TenantA -ParallelStreams 1 *>&1; $Result.AError = 'none' }
catch { $Result.AError = $_.Exception.Message }
$Result.ALockAfterError = [System.IO.File]::Exists($LockA)
$global:RdaStandInScenario = $ScenarioB
$global:RdaStandInRun = 'tb'
$global:LASTEXITCODE = 0
$Lines = @(& $Wrapper -TenantID $TenantB -ParallelStreams 1 *>&1 | ForEach-Object { [string]$_ })
$Result.BExit = $global:LASTEXITCODE
$Result.BLockLines = @($Lines | Where-Object { $_ -match 'run lock' })
$Result.BProcessed = ($Lines -contains 'All subscriptions processed!')
$Result.ALockAfterB = [System.IO.File]::Exists($LockA)
$Result.BLockAfterB = [System.IO.File]::Exists($LockB)
$Result.ProcessId = $PID
$Result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Out -Encoding utf8
'@ -Arguments @('-Wrapper', $script:Wrapper, '-TenantA', $script:Tenant, '-ScenarioA', (Join-Path $script:CaseHome 'scenario-a-throw.json'), '-TenantB', $script:TenantB, '-ScenarioB', $script:ScenarioB, '-Out', $Out)
        $null = script:Wait-Wrapper -Started $Loop -TimeoutSeconds 300
        $Result = Get-Content -LiteralPath $Out -Raw | ConvertFrom-Json
        $Result.AError | Should -Be 'stand-in: the subscription list failed'
        script:Get-LockAtList -Run 'ta' | Should -Be 'True'
        $Result.ALockAfterError | Should -BeTrue -Because 'the command that started that run is still going'
        $Result.BExit | Should -Be 0
        $Result.BProcessed | Should -BeTrue
        @($Result.BLockLines) | Should -BeNullOrEmpty
        $Result.BLockAfterB | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*' | ForEach-Object Name) | Should -BeNullOrEmpty -Because 'the first tenant''s run removed its own lock when the process ended'
        script:Set-Scenario -Subs 'A'
        foreach ($Next in 'r2', 'r3')
        {
            $Run = script:Invoke-Wrapper -Run $Next
            $Run.ExitCode | Should -Be 0
            script:Get-LockLines -Text $Run.Text | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*') | Should -BeNullOrEmpty
        }
    }

    It 'as two thread jobs for one tenant: the second stops with exit 1 and no remove command; the first ends and releases its lock; the next two runs proceed' {
        script:Set-Scenario -Subs 'A', 'B'
        $Out = Join-Path $script:CaseHome 'jobs.json'
        $Host1 = script:Start-CaseScript -Name 'jobs.ps1' -Source $script:JobHostSource -Arguments @('-Wrapper', $script:Wrapper, '-Mode', 'same', '-TenantA', $script:Tenant, '-ScenarioA', $script:Scenario, '-TenantB', $script:TenantB, '-ScenarioB', $script:ScenarioB, '-Out', $Out)
        $null = script:Wait-Wrapper -Started $Host1 -TimeoutSeconds 300
        $Result = Get-Content -LiteralPath $Out -Raw | ConvertFrom-Json
        $First = @($Result.Runs | Where-Object { $_.Run -eq 'j1' })[0]
        $Second = @($Result.Runs | Where-Object { $_.Run -eq 'j2' })[0]
        $Second.Exit | Should -Be 1
        script:Assert-Lines -Text @($Second.Lines) -Expected (script:Get-RunningLines -ProcessId $Result.ProcessId)
        script:Get-RemoveLines -Text @($Second.Lines) | Should -BeNullOrEmpty
        script:Get-Collected -Run 'j2' | Should -BeNullOrEmpty
        # The second run left the first run's lock and its heartbeat alone.
        $Result.StillHeld.InvocationId | Should -Be $Result.Held.InvocationId
        $First.Lines | Should -Contain 'All subscriptions processed!'
        script:Get-LockLines -Text @($First.Lines) | Should -BeNullOrEmpty
        script:Get-Collected -Run 'j1' | Should -Be @('A', 'B')
        $Result.LockAfter | Should -BeFalse
        foreach ($Next in 'r3', 'r4')
        {
            $Run = script:Invoke-Wrapper -Run $Next
            $Run.ExitCode | Should -Be 0
            script:Get-LockLines -Text $Run.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }

    It 'as two thread jobs for one tenant, the second started while the first has its lock but not yet its heartbeat: the second stops with exit 1 and no remove command; one bundle with the two reports' {
        $Variant = script:New-ToolVariant -Name 'gap-pause' -Append $script:GapPauseSource
        script:Set-Scenario -Subs 'A', 'B'
        $Out = Join-Path $script:CaseHome 'jobs.json'
        $Host1 = script:Start-CaseScript -Name 'jobs.ps1' -Source $script:JobHostSource -Arguments @('-Wrapper', $Variant, '-Mode', 'gap', '-TenantA', $script:Tenant, '-ScenarioA', $script:Scenario, '-TenantB', $script:TenantB, '-ScenarioB', $script:ScenarioB, '-Out', $Out)
        $null = script:Wait-Wrapper -Started $Host1 -TimeoutSeconds 300
        $Result = Get-Content -LiteralPath $Out -Raw | ConvertFrom-Json
        $First = @($Result.Runs | Where-Object { $_.Run -eq 'j1' })[0]
        $Second = @($Result.Runs | Where-Object { $_.Run -eq 'j2' })[0]
        $Second.Exit | Should -Be 1
        script:Assert-Lines -Text @($Second.Lines) -Expected (script:Get-RunningLines -ProcessId $Result.ProcessId)
        script:Get-RemoveLines -Text @($Second.Lines) | Should -BeNullOrEmpty
        script:Get-Collected -Run 'j2' | Should -BeNullOrEmpty
        $Result.StillHeld.InvocationId | Should -Be $Result.Held.InvocationId
        $First.Lines | Should -Contain 'All subscriptions processed!'
        script:Get-Collected -Run 'j1' | Should -Be @('A', 'B')
        @($Result.Bundles) | Should -Be @(2)
        $Result.LockAfter | Should -BeFalse
        foreach ($Next in 'r3', 'r4')
        {
            $Run = script:Invoke-Wrapper -Run $Next
            $Run.ExitCode | Should -Be 0
            script:Get-LockLines -Text $Run.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }

    It 'as two thread jobs for two tenants: each keeps its own heartbeat for over a minute and releases its own lock' {
        script:Set-Scenario -Subs 'A', 'B'
        script:Set-Scenario -Subs 'X', 'Y' -Tenant $script:TenantB -Path $script:ScenarioB
        $Out = Join-Path $script:CaseHome 'jobs.json'
        $Host1 = script:Start-CaseScript -Name 'jobs.ps1' -Source $script:JobHostSource -Arguments @('-Wrapper', $script:Wrapper, '-Mode', 'two', '-TenantA', $script:Tenant, '-ScenarioA', $script:Scenario, '-TenantB', $script:TenantB, '-ScenarioB', $script:ScenarioB, '-Out', $Out)
        $null = script:Wait-Wrapper -Started $Host1 -TimeoutSeconds 400
        $Result = Get-Content -LiteralPath $Out -Raw | ConvertFrom-Json
        foreach ($Run in @($Result.Runs))
        {
            $Run.Lines | Should -Contain 'All subscriptions processed!'
            script:Get-LockLines -Text @($Run.Lines) | Should -BeNullOrEmpty
        }
        foreach ($Key in 'A', 'B')
        {
            $Result.After.$Key.InvocationId | Should -Be $Result.Before.$Key.InvocationId
            $Result.After.$Key.ProcessId | Should -Be ([string]$Result.ProcessId)
            ((script:ConvertFrom-LockTime -Text $Result.After.$Key.HeartbeatUtc) - (script:ConvertFrom-LockTime -Text $Result.Before.$Key.HeartbeatUtc)).TotalSeconds | Should -BeGreaterThan 30
        }
        $Result.Before.A.InvocationId | Should -Not -Be $Result.Before.B.InvocationId
        script:Get-Collected -Run 'j1' | Should -Be @('A', 'B')
        script:Get-Collected -Run 'j2' | Should -Be @('X', 'Y')
        $Result.LockAAfter | Should -BeFalse
        $Result.LockBAfter | Should -BeFalse
    }
}

Describe 'A lock this run cannot keep safely' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Stop-Started }

    It 'the heartbeat cannot start: exit 1 before any run state, the lock released; the next two runs proceed' {
        $Variant = script:New-ToolVariant -Name 'no-heartbeat' -Append "function New-RunLockHeartbeatRunspace { throw 'stand-in: no runspace for the heartbeat' }"
        script:Set-Scenario -Subs 'A'
        $Run = script:Invoke-Wrapper -Run 'r1' -Wrapper $Variant
        $Run.ExitCode | Should -Be 1
        $Run.Text | Should -Contain ('ERROR: Could not start the heartbeat of the run lock {0}: stand-in: no runspace for the heartbeat' -f $script:LockPath)
        $Run.Text | Should -Contain '  Without it, this run''s lock would not be refreshed, and would not be removed if the run ended with an error in a session that goes on, so this run stopped before reading or writing any run state.'
        @($Run.Text | Where-Object { $_ -like 'Subscriptions visible:*' }) | Should -BeNullOrEmpty
        script:Get-Collected -Run 'r1' | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:State | Should -BeFalse
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        foreach ($Next in 'r2', 'r3')
        {
            $After = script:Invoke-Wrapper -Run $Next
            $After.ExitCode | Should -Be 0
            script:Get-LockLines -Text $After.Text | Should -BeNullOrEmpty
        }
    }

    It 'the release at process exit cannot be compiled: one warning and the run goes on; an error that ends it then leaves its lock, the next run stops with the remove command, and after it the next two runs proceed' {
        $Variant = script:New-ToolVariant -Name 'no-compiler' -Append @'
function Add-Type
{
    [CmdletBinding()]
    param([string]$TypeDefinition, [string[]]$AssemblyName)
    if ($TypeDefinition) { throw 'stand-in: no compiler' }
    Microsoft.PowerShell.Utility\Add-Type -AssemblyName $AssemblyName
}
'@
        script:Set-Scenario -Subs 'A'
        $Run = script:Invoke-Wrapper -Run 'r1' -Wrapper $Variant
        $Run.ExitCode | Should -Be 0
        $Run.Text | Should -Contain ('WARNING: Could not set up the release of the run lock {0} at process exit: stand-in: no compiler. The run goes on; if it is interrupted or ends with an error, its lock stays and the next run stops with the command to remove it.' -f $script:LockPath)
        script:Get-Collected -Run 'r1' | Should -Be @('A')
        Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        script:Set-Scenario -Subs 'A' -ThrowAtList
        $Failed = script:Invoke-Wrapper -Run 'r2' -Wrapper $Variant
        $Failed.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath $script:LockPath | Should -BeTrue
        script:Set-Scenario -Subs 'A'
        $Next = script:Invoke-Wrapper -Run 'r3'
        $Next.ExitCode | Should -Be 1
        script:Assert-Lines -Text $Next.Text -Expected (script:Get-EndedLines -Why ('process {0} is not running on this machine' -f $Failed.ProcessId))
        script:Invoke-PrintedRemove -Text $Next.Text
        foreach ($Last in 'r4', 'r5')
        {
            $After = script:Invoke-Wrapper -Run $Last
            $After.ExitCode | Should -Be 0
            script:Get-LockLines -Text $After.Text | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:LockPath | Should -BeFalse
        }
    }
}
