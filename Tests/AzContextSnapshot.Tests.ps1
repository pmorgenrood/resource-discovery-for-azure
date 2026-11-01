# The Az context snapshot a parallel run writes for its stream workers.
#
#   - Each stream gets its own snapshot file, written just before its job
#     starts and readable and writable by the owner only (mode 600 on Linux
#     and macOS) from the moment it exists. Its name holds the machine, the
#     id and the start time of the process that wrote it.
#   - A stream deletes its file once it has read it, before it collects any
#     subscription, so none is left when the run ends.
#   - A stream imports its file only once Az context autosave is confirmed off
#     for its process. Otherwise it deletes the file, imports nothing and is
#     reported as failed.
#   - When the workers die before reading their files and the run is then
#     interrupted (Ctrl+C), the run deletes the files at once, before it stops
#     the jobs; stopping a job whose worker has died takes about a minute.
#   - At the start of a run, a snapshot is removed, with one line, only when
#     the process on this machine that wrote it has ended. The snapshots of a
#     run that is still going are kept however old they are, whatever its
#     tenant. A snapshot from another machine or with a name in another form
#     is kept and named, with the command that removes it.
#   - The consolidated zip and the -PackageZip bundle never hold a snapshot.
#   - When a snapshot cannot be written, the run stops with exit 1, names
#     -ParallelStreams 1 as the way to run without stream workers, and leaves
#     no snapshot.
# Each end-to-end case is followed by the next two runs.
#
# The end-to-end runs are Run-AllSubscriptions.ps1 itself, each started as its
# own pwsh process (umask 022) from a copy of the tool whose ResourceInventory.ps1
# is a stand-in, with Azure answered by stand-in Az modules and an az command
# found first on the module path and PATH of that process. The stand-in
# Import-AzContext can hold a worker before it opens its file, until the test
# releases it, and then records the path and mode of the file it was given.
# The process's home is a scratch folder, so the inventory root is under it.
# On Windows the wrapper writes to C:\InventoryReports and files have no mode,
# so the end-to-end tests and the mode checks do not run there; the Windows
# access-list check is tested on its rules only.
#
# One case loads the installed Az.Accounts and turns its autosave setting on
# and off for the CurrentUser scope of a scratch home folder. Loading the real
# module can reach the network, so that case is skipped unless
# RDA_TEST_REAL_AZ_ACCOUNTS=1 is set. It is always skipped on Windows, where
# Az.Accounts ignores the HOME and USERPROFILE redirect and would change the
# Az profile of the user running the tests. Elsewhere it first checks that
# Az.Accounts puts the CurrentUser files in the scratch home folder, and
# changes nothing if it does not.
#
# Run with: Invoke-Pester ./Tests/AzContextSnapshot.Tests.ps1 -Output Detailed
# With the real Az.Accounts case (Linux and macOS):
#   $env:RDA_TEST_REAL_AZ_ACCOUNTS = '1'; Invoke-Pester ./Tests/AzContextSnapshot.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('AzContextSnapshotTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
    $script:Tenant = '12345678-1234-1234-1234-123456789012'
    $script:OtherTenant = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $script:Pwsh = Join-Path $PSHOME 'pwsh'
    $script:Started = [System.Collections.Generic.List[object]]::new()
    $script:SnapshotFilter = '.rda-stream-azcontext-*.json'
    $script:Utc = [System.Globalization.CultureInfo]::InvariantCulture

    # --- The tool: the wrapper and its helpers as they are, and a stand-in
    # ResourceInventory.ps1 that writes one report folder and zip per call and
    # records whether the stream's own snapshot file was still there.
    $script:ToolRoot = Join-Path $script:TestBase 'tool'
    New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
    foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Version.json', 'Functions', 'Extension'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:ToolRoot -Recurse -Force
    }
    $script:Wrapper = Join-Path $script:ToolRoot 'Run-AllSubscriptions.ps1'
    $StandInInner = @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
$Imported = Join-Path $HOME ('imported-{0}.json' -f $PID)
$SnapshotPresent = if (Test-Path -LiteralPath $Imported) { Test-Path -LiteralPath ((Get-Content -LiteralPath $Imported -Raw | ConvertFrom-Json).Path) } else { $null }
[pscustomobject]@{ Subscription = $SubscriptionID; ProcessId = $PID; SnapshotPresent = $SnapshotPresent } | ConvertTo-Json -Compress |
    Set-Content -LiteralPath (Join-Path $HOME ('collected-{0}-{1}.json' -f $SubscriptionID, [guid]::NewGuid().ToString('N').Substring(0, 6)))
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

    # --- Stand-in Azure. Save-AzContext writes a placeholder token cache in
    # place, as the real cmdlet does, and throws while a file named
    # save-fails is in the run's home folder. Import-AzContext, when
    # RDA_STANDIN_HOLD_IMPORT is set, waits before it opens the file until the
    # test releases it, then records the path and mode of the file. Autosave
    # is on (CurrentUser) until Disable-AzContextAutosave turns it off for the
    # process; RDA_STANDIN_AUTOSAVE=fail makes that call throw, =stuck makes
    # it return without effect, and =throw-after-off makes it turn autosave
    # off and then throw; =setting-fails makes Get-AzContextAutosaveSetting
    # throw. The token carries an object id, and the role,
    # permission, resource count and usage reads answer as for a Reader, so
    # the wrapper's up-front checks pass wherever they run. The scenario file
    # is $Global:RdaStandInAzure when set (one per runspace, for two runs in
    # one process), else RDA_STANDIN_AZURE.
    $script:Modules = Join-Path $script:TestBase 'modules'
    $Accounts = @'
$script:AutosaveOff = $false
function Get-RdaStandInScenario { Get-Content -LiteralPath $(if ($Global:RdaStandInAzure) { $Global:RdaStandInAzure } else { $env:RDA_STANDIN_AZURE }) -Raw | ConvertFrom-Json }
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
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context, $Scope) Get-RdaStandInContext }
function Save-AzContext
{
    [CmdletBinding()] param($Path, [switch]$Force)
    if (Test-Path -LiteralPath (Join-Path $HOME 'save-fails')) { throw 'stand-in: the context cannot be saved' }
    [System.IO.File]::WriteAllText($Path, '{"Contexts":{"placeholder":{"TokenCache":{"CacheData":"cGxhY2Vob2xkZXI="}}}}')
}
function Import-AzContext
{
    [CmdletBinding()] param($Path)
    if ($env:RDA_STANDIN_HOLD_IMPORT)
    {
        Set-Content -LiteralPath (Join-Path $HOME ('import-held-{0}' -f $PID)) -Value $PID
        $Deadline = (Get-Date).AddSeconds(240)
        while (-not (Test-Path -LiteralPath (Join-Path $HOME 'release-import')) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 100 }
    }
    $Mode = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).UnixFileMode
    [pscustomobject]@{ Path = $Path; Mode = [Convert]::ToString([int]$Mode, 8) } | ConvertTo-Json -Compress |
        Set-Content -LiteralPath (Join-Path $HOME ('imported-{0}.json' -f $PID))
    Get-RdaStandInContext
}
function Disable-AzContextAutosave
{
    [CmdletBinding()] param($Scope)
    if ($env:RDA_STANDIN_AUTOSAVE -eq 'fail') { throw 'stand-in: the autosave setting cannot be changed' }
    if ($env:RDA_STANDIN_AUTOSAVE -ne 'stuck') { $script:AutosaveOff = $true }
    if ($env:RDA_STANDIN_AUTOSAVE -eq 'throw-after-off') { throw 'stand-in: the setting was changed, then the call failed' }
}
function Get-AzContextAutosaveSetting
{
    [CmdletBinding()] param($Scope)
    if ($env:RDA_STANDIN_AUTOSAVE -eq 'setting-fails') { throw 'stand-in: the autosave setting cannot be read' }
    if ($script:AutosaveOff) { return [pscustomobject]@{ Mode = 'Process'; ContextFile = 'None'; CacheFile = 'None' } }
    [pscustomobject]@{ Mode = 'CurrentUser'; ContextFile = 'AzureRmContext.json'; CacheFile = 'msal.cache' }
}
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
    @($Scenario.Subscriptions | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SubscriptionId = $_.Id; Name = $_.Name; State = 'Enabled'; TenantId = $Scenario.Tenant } })
}
function Invoke-AzRestMethod
{
    [CmdletBinding()] param([string]$Method = 'GET', [string]$Path, [string]$Payload, [string]$Uri)
    $Answer = { param([int]$Status, $Body) [pscustomobject]@{ StatusCode = $Status; Content = (ConvertTo-Json -InputObject $Body -Depth 8 -Compress); Headers = @{} } }
    if ($Path -match '^/subscriptions/([^/?]+)/resourcegroups\?') { return & $Answer 200 @{ value = @() } }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/roleAssignments\?')
    {
        $Id = $Matches[1]
        return & $Answer 200 @{ value = @(@{ properties = @{ scope = "/subscriptions/$Id"; principalId = 'stand-in-caller'; principalType = 'User'; roleDefinitionId = "/subscriptions/$Id/providers/Microsoft.Authorization/roleDefinitions/stand-in-reader" } }) }
    }
    if ($Path -match '/providers/Microsoft\.Authorization/roleDefinitions/[^/?]+\?') { return & $Answer 200 @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } } }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/permissions\?') { return & $Answer 200 @{ value = @(@{ actions = @('*/read'); notActions = @() }) } }
    if ($Method -eq 'POST' -and $Path -like '/providers/Microsoft.ResourceGraph/resources*') { return & $Answer 200 @{ data = @(@(($Payload | ConvertFrom-Json).subscriptions) | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 1 } }) } }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Commerce/UsageAggregates\?') { return & $Answer 200 @{ value = @(@{ properties = @{ quantity = 1.5; meterCategory = 'Stand-in'; instanceData = '' } }) } }
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
$Scenario = Get-Content -LiteralPath $(if ($Global:RdaStandInAzure) { $Global:RdaStandInAzure } else { $env:RDA_STANDIN_AZURE }) -Raw | ConvertFrom-Json
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'show') { [pscustomobject]@{ tenantId = $Scenario.Tenant } | ConvertTo-Json -Compress; exit 0 }
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'get-access-token') { exit 0 }
exit 1
'@
    Set-Content -LiteralPath (Join-Path $script:Bin 'az.ps1') -Value $Az -Encoding utf8

    # A fresh home (its InventoryReports folder is the inventory root) per test.
    function script:New-Case
    {
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
    }

    # A scenario file for one tenant with two subscriptions.
    function script:New-Scenario
    {
        param([string]$Tenant = $script:Tenant)
        $Path = Join-Path $script:CaseHome ('scenario-{0}.json' -f $Tenant.Substring(0, 8))
        [pscustomobject]@{
            Tenant        = $Tenant
            Subscriptions = @(
                [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' },
                [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B' })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding utf8
        return $Path
    }

    # One run of the wrapper as its own process (umask 022, stdin closed),
    # started and left running. A test runner started in the background by a
    # non-interactive shell ignores Ctrl+C (SIGINT), and its child processes
    # inherit that, so the run is started through perl, which sets it back to
    # the default before it starts pwsh. Without perl, /bin/sh sets the umask.
    $script:Perl = Get-Command -Name perl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    function script:Start-Wrapper
    {
        param([int]$Streams = 2, [string]$Tenant = $script:Tenant, [switch]$HoldImport, [string]$Autosave = '', [string[]]$Script = @(), [switch]$Resume)
        $Scenario = script:New-Scenario -Tenant $Tenant
        $Command = if ($Script.Count -gt 0) { @($script:Pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-File') + $Script }
        else { @($script:Pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper, '-TenantID', $Tenant, '-ParallelStreams', [string]$Streams, '-SkipMetrics', '-SkipConsumption') + @(if ($Resume) { '-Resume' }) }
        if ($script:Perl)
        {
            $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Perl.Source)
            $Launcher = @('-e', 'umask 022; $SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or die "exec: $!"')
        }
        else
        {
            $Info = [System.Diagnostics.ProcessStartInfo]::new('/bin/sh')
            $Launcher = @('-c', 'umask 022; exec "$@"', 'sh')
        }
        foreach ($Arg in @($Launcher + $Command)) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
        $Info.Environment['PATH'] = $script:Bin + [IO.Path]::PathSeparator + $env:PATH
        $Info.Environment['RDA_STANDIN_AZURE'] = $Scenario
        $Info.Environment['RDA_STANDIN_HOLD_IMPORT'] = $(if ($HoldImport) { '1' } else { '' })
        $Info.Environment['RDA_STANDIN_AUTOSAVE'] = $Autosave
        $Info.Environment['NO_COLOR'] = '1'
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $script:Started.Add($Proc)
        return [pscustomobject]@{ Process = $Proc; Out = $Proc.StandardOutput.ReadToEndAsync(); Err = $Proc.StandardError.ReadToEndAsync() }
    }

    function script:Wait-Wrapper
    {
        param([Parameter(Mandatory = $true)]$Started, [int]$TimeoutSeconds = 180)
        if (-not $Started.Process.WaitForExit($TimeoutSeconds * 1000))
        {
            $Started.Process.Kill($true)
            throw ('The wrapper run did not end within {0} seconds.' -f $TimeoutSeconds)
        }
        $Started.Process.WaitForExit()
        $Text = @(([string]$Started.Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        return [pscustomobject]@{ ExitCode = $Started.Process.ExitCode; Text = $Text; Error = [string]$Started.Err.Result; ProcessId = $Started.Process.Id }
    }

    function script:Invoke-Wrapper
    {
        param([int]$Streams = 2, [string]$Tenant = $script:Tenant, [string]$Autosave = '', [switch]$Resume)
        script:Wait-Wrapper -Started (script:Start-Wrapper -Streams $Streams -Tenant $Tenant -Autosave $Autosave -Resume:$Resume)
    }

    # Waits until Count workers are held in the stand-in Import-AzContext and
    # returns their process ids.
    function script:Wait-ImportHeld
    {
        param([int]$Count, [int]$TimeoutSeconds = 120)
        $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $Deadline)
        {
            $Held = @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'import-held-*' -ErrorAction SilentlyContinue)
            if ($Held.Count -ge $Count) { return @($Held | ForEach-Object { [int]($_.Name -replace '^import-held-', '') }) }
            Start-Sleep -Milliseconds 200
        }
        throw ('{0} workers did not reach Import-AzContext within {1} seconds.' -f $Count, $TimeoutSeconds)
    }

    function script:Get-Snapshot
    {
        @(Get-ChildItem -LiteralPath $script:Root -File -Force -Filter $script:SnapshotFilter -ErrorAction SilentlyContinue)
    }

    # A snapshot name in the form the wrapper writes, written out here rather
    # than taken from the code under test.
    function script:Get-OwnedSnapshotName
    {
        param([string]$Machine = [Environment]::MachineName, [int]$ProcessId, [datetime]$StartUtc)
        '.rda-stream-azcontext-{0}-{1}-{2}-{3}.json' -f [uri]::EscapeDataString($Machine), $ProcessId, $StartUtc.ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ', $script:Utc), [guid]::NewGuid().ToString('N')
    }

    # A snapshot file as another run would leave it, AgeMinutes old.
    function script:New-LeftoverSnapshot
    {
        param([string]$Name, [double]$AgeMinutes = 30)
        $Path = Join-Path $script:Root $Name
        Set-Content -LiteralPath $Path -Value '{"Contexts":{}}'
        (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-$AgeMinutes)
        return $Path
    }

    # The id of a process that has ended.
    function script:Get-EndedProcessId
    {
        $Ended = [System.Diagnostics.Process]::Start($script:Pwsh, @('-NoProfile', '-NonInteractive', '-Command', 'exit'))
        $Ended.WaitForExit()
        $Id = $Ended.Id
        if ($null -ne (Get-Process -Id $Id -ErrorAction SilentlyContinue)) { throw 'The ended process id is in use again.' }
        return $Id
    }

    # A running pwsh process the test owns, with its start time.
    function script:Start-Sleeper
    {
        $Proc = [System.Diagnostics.Process]::Start($script:Pwsh, @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 300'))
        $script:Started.Add($Proc)
        return [pscustomobject]@{ Process = $Proc; StartUtc = $Proc.StartTime.ToUniversalTime() }
    }

    function script:Get-RemovedLine
    {
        param([string[]]$Text)
        @($Text | Where-Object { $_ -match '^Removed \d+ Az context snapshot file' })
    }

    function script:Get-KeptLine
    {
        param([string[]]$Text)
        @($Text | Where-Object { $_ -like 'Kept the Az context snapshot *' })
    }

    # The lines the wrapper prints for the snapshots it removes and keeps.
    function script:Format-RemovedLine
    {
        param([int]$Count)
        'Removed {0} Az context snapshot file(s) that an earlier parallel run left in {1}; the process on this machine that wrote them has ended (each held an Azure token cache).' -f $Count, $script:Root
    }

    function script:Format-KeptLine
    {
        param([string]$Path, [string]$Why)
        "Kept the Az context snapshot {0}: {1}, so this run cannot tell whether it is still in use. It holds an Azure token cache; if no run is using it, remove it with: Remove-Item -LiteralPath '{0}' -Force" -f $Path, $Why
    }

    # A clean end: exit 0, no snapshot left, no snapshot line.
    function script:Assert-CleanRun
    {
        param([Parameter(Mandatory = $true)]$Result, [string]$Because)
        $Result.ExitCode | Should -Be 0 -Because ('{0}: {1}' -f $Because, ($Result.Text -join ' | '))
        @(script:Get-Snapshot).Count | Should -Be 0 -Because $Because
        @(script:Get-RemovedLine -Text $Result.Text).Count | Should -Be 0 -Because $Because
        @(script:Get-KeptLine -Text $Result.Text).Count | Should -Be 0 -Because $Because
    }

    # The entry names of a zip.
    function script:Get-ZipEntry
    {
        param([string]$Zip)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
        try { @($Archive.Entries | ForEach-Object { $_.FullName }) } finally { $Archive.Dispose() }
    }

    # Ends every process the test started, with its workers. -Hold kills them
    # where they are; otherwise held workers are released first.
    function script:Stop-Started
    {
        param([switch]$Hold)
        if (-not $script:CaseHome) { return }
        if (-not $Hold) { Set-Content -LiteralPath (Join-Path $script:CaseHome 'release-import') -Value 'go' -ErrorAction SilentlyContinue }
        foreach ($Proc in @($script:Started))
        {
            try { if (-not $Proc.HasExited) { $Proc.Kill($true); $null = $Proc.WaitForExit(10000) } }
            catch { Write-Verbose ('process already gone: {0}' -f $_.Exception.Message) }
        }
        $script:Started.Clear()
    }
}

AfterAll {
    script:Stop-Started
    if ($script:TestBase -and (Test-Path -LiteralPath $script:TestBase))
    {
        Remove-Item -LiteralPath $script:TestBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Az context snapshot names, owners and files' {
    BeforeEach { script:New-Case }
    AfterEach { script:Stop-Started }

    It 'names a snapshot after this machine, process and start time, and reads the owner back' {
        $Path = New-AzContextSnapshotPath -InventoryRoot $script:Root
        Split-Path -Path $Path -Parent | Should -Be $script:Root
        $Owner = ConvertFrom-AzContextSnapshotName -Name (Split-Path -Path $Path -Leaf)
        $Owner.Valid | Should -BeTrue
        $Owner.MachineName | Should -Be ([Environment]::MachineName)
        $Owner.ProcessId | Should -Be $PID
        $Self = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime()
        [math]::Abs(($Owner.ProcessStartTimeUtc - $Self).TotalMilliseconds) | Should -BeLessThan 2
        foreach ($Machine in 'build-01.example', 'HOST 2:a/b', 'host-123')
        {
            $Read = ConvertFrom-AzContextSnapshotName -Name (script:Get-OwnedSnapshotName -Machine $Machine -ProcessId 4567 -StartUtc ([datetime]'2026-10-30T01:02:03.456Z'))
            $Read.Valid | Should -BeTrue
            $Read.MachineName | Should -Be $Machine
            $Read.ProcessId | Should -Be 4567
            $Read.ProcessStartTimeUtc.ToString('o') | Should -Be '2026-10-30T01:02:03.4560000Z'
        }
    }

    It 'reads a name in another form, or with a value that is not valid, as unreadable' {
        $Guid = [guid]::NewGuid().ToString('N')
        foreach ($Name in @(
                ('.rda-stream-azcontext-{0}.json' -f [guid]::NewGuid().ToString()),
                ('.rda-stream-azcontext-host-0-20261030T010203456Z-{0}.json' -f $Guid),
                ('.rda-stream-azcontext-host-99999999999-20261030T010203456Z-{0}.json' -f $Guid),
                ('.rda-stream-azcontext-host-123-20261330T010203456Z-{0}.json' -f $Guid),
                ('.rda-stream-azcontext-host-123-20261030T250203456Z-{0}.json' -f $Guid),
                ('.rda-stream-azcontext--123-20261030T010203456Z-{0}.json' -f $Guid)))
        {
            (ConvertFrom-AzContextSnapshotName -Name $Name).Valid | Should -BeFalse -Because $Name
            Get-AzContextSnapshotOwnerState -Owner (ConvertFrom-AzContextSnapshotName -Name $Name) | Should -Be 'Unreadable'
        }
    }

    It 'tells a running, an ended, a reused and a foreign owner apart, and keeps an owner whose start time a clock correction moved' {
        $Sleeper = script:Start-Sleeper
        $Ended = script:Get-EndedProcessId
        $Self = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime()
        $State = { param($Machine, $ProcessId, $StartUtc) Get-AzContextSnapshotOwnerState -Owner (ConvertFrom-AzContextSnapshotName -Name (script:Get-OwnedSnapshotName -Machine $Machine -ProcessId $ProcessId -StartUtc $StartUtc)) }
        & $State ([Environment]::MachineName) $Sleeper.Process.Id $Sleeper.StartUtc | Should -Be 'ProcessRunning'
        & $State ([Environment]::MachineName) $Sleeper.Process.Id $Sleeper.StartUtc.AddHours(-2) | Should -Be 'ProcessIdReused' -Because 'the process holding the id started long after the one named'
        # As after a clock correction between the two processes' starts: the
        # start time one process reads for another moves by the correction.
        & $State ([Environment]::MachineName) $Sleeper.Process.Id $Sleeper.StartUtc.AddSeconds(-5) | Should -Be 'ProcessRunning'
        & $State ([Environment]::MachineName) $Sleeper.Process.Id $Sleeper.StartUtc.AddMinutes(-50) | Should -Be 'ProcessRunning'
        & $State ([Environment]::MachineName) $Sleeper.Process.Id $Sleeper.StartUtc.AddMinutes(30) | Should -Be 'ProcessRunning' -Because 'a process that seems to have started before the one named is not a reuse'
        & $State ([Environment]::MachineName) $PID $Self.AddMinutes(-10) | Should -Be 'ThisProcess'
        & $State ([Environment]::MachineName) $Ended ([datetime]::UtcNow.AddMinutes(-5)) | Should -Be 'ProcessGone'
        & $State ([Environment]::MachineName) $PID $Self | Should -Be 'ThisProcess'
        & $State 'another-host' $Sleeper.Process.Id $Sleeper.StartUtc | Should -Be 'OtherMachine'
    }

    It 'removes only the snapshots of ended processes on this machine, keeps this process''s own, names the others, and leaves other dot-files alone' {
        $Sleeper = script:Start-Sleeper
        $Ended = script:Get-EndedProcessId
        $Gone = script:New-LeftoverSnapshot -Name (script:Get-OwnedSnapshotName -ProcessId $Ended -StartUtc ([datetime]::UtcNow.AddMinutes(-5))) -AgeMinutes 1
        $Reused = script:New-LeftoverSnapshot -Name (script:Get-OwnedSnapshotName -ProcessId $Sleeper.Process.Id -StartUtc $Sleeper.StartUtc.AddDays(-1))
        $Live = script:New-LeftoverSnapshot -Name (script:Get-OwnedSnapshotName -ProcessId $Sleeper.Process.Id -StartUtc $Sleeper.StartUtc) -AgeMinutes 600
        $Mine = script:New-LeftoverSnapshot -Name (script:Get-OwnedSnapshotName -ProcessId $PID -StartUtc ([System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime())) -AgeMinutes 600
        $Foreign = script:New-LeftoverSnapshot -Name (script:Get-OwnedSnapshotName -Machine 'another-host' -ProcessId $Ended -StartUtc ([datetime]::UtcNow.AddDays(-2))) -AgeMinutes 3000
        $Old = script:New-LeftoverSnapshot -Name ('.rda-stream-azcontext-{0}.json' -f [guid]::NewGuid().ToString()) -AgeMinutes 3000
        $Others = @('.resume-state-{0}.json' -f $script:Tenant), ('.resume-state-{0}-stream-0.json' -f $script:Tenant), '.rda-stream-0-summary.json', ('.run-lock-{0}.json' -f $script:Tenant) |
            ForEach-Object { $P = Join-Path $script:Root $_; Set-Content -LiteralPath $P -Value '{}'; (Get-Item -LiteralPath $P -Force).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-2); $P }
        $Result = Remove-OrphanedAzContextSnapshot -InventoryRoot $script:Root
        $Result.Removed | Should -Be 2
        @($Result.Failed).Count | Should -Be 0
        Test-Path -LiteralPath $Gone | Should -BeFalse
        Test-Path -LiteralPath $Reused | Should -BeFalse
        Test-Path -LiteralPath $Live | Should -BeTrue -Because 'its process is running, however old the file is'
        Test-Path -LiteralPath $Mine | Should -BeTrue -Because 'another run in this same process may still need it'
        Test-Path -LiteralPath $Foreign | Should -BeTrue
        Test-Path -LiteralPath $Old | Should -BeTrue
        @($Result.Unknown | Sort-Object Path | ForEach-Object { '{0}|{1}|{2}' -f (Split-Path -Path $_.Path -Leaf), $_.Reason, $_.MachineName }) |
            Should -Be @(@(('{0}|OtherMachine|another-host' -f (Split-Path -Path $Foreign -Leaf)), ('{0}|Unreadable|' -f (Split-Path -Path $Old -Leaf))) | Sort-Object)
        foreach ($P in $Others) { Test-Path -LiteralPath $P | Should -BeTrue }
        (Remove-OrphanedAzContextSnapshot -InventoryRoot (Join-Path $script:Root 'missing')).Removed | Should -Be 0
    }

    It 'counts a snapshot another process deleted first as deleted, and reports one that is still there' {
        $Path = Join-Path $script:Root '.rda-stream-azcontext-race.json'
        Set-Content -LiteralPath $Path -Value '{}'
        # The other process deletes it between the check and the delete.
        Mock Remove-Item -MockWith { [System.IO.File]::Delete($LiteralPath); throw [System.Management.Automation.ItemNotFoundException]::new(('Cannot find path ''{0}'' because it does not exist.' -f $LiteralPath)) }
        @(Remove-AzContextSnapshot -Path $Path).Count | Should -Be 0
        Test-Path -LiteralPath $Path | Should -BeFalse
        Set-Content -LiteralPath $Path -Value '{}'
        Mock Remove-Item -MockWith { throw [System.UnauthorizedAccessException]::new('stand-in: access denied') }
        $Failed = @(Remove-AzContextSnapshot -Path $Path)
        $Failed.Count | Should -Be 1
        $Failed[0].Path | Should -Be $Path
        $Failed[0].Message | Should -Be 'stand-in: access denied'
        Get-RemoveFileCommand -Path "/x/it's.json" | Should -Be "Remove-Item -LiteralPath '/x/it''s.json' -Force"
    }

    It 'creates the file readable by the owner only before anything is written, and refuses an existing file' -Skip:$IsWindows {
        $Path = Join-Path $script:Root '.rda-stream-azcontext-new.json'
        New-OwnerOnlyFile -Path $Path
        $Item = Get-Item -LiteralPath $Path -Force
        $Item.Length | Should -Be 0
        [Convert]::ToString([int]$Item.UnixFileMode, 8) | Should -Be '600'
        { New-OwnerOnlyFile -Path $Path } | Should -Throw
    }

    It 'writes each copy owner-only, the later ones from the first one''s bytes, and narrows a write that widened the mode' -Skip:$IsWindows {
        $Paths = @(0, 1, 2 | ForEach-Object { Join-Path $script:Root ('.rda-stream-azcontext-{0}.json' -f $_) })
        # A write that replaces the file, as a writer using a temporary file and
        # a rename would: the new file gets the default mode.
        function Save-AzContext
        {
            param($Path, [switch]$Force)
            Remove-Item -LiteralPath $Path -Force
            [System.IO.File]::WriteAllText($Path, '{"Contexts":{"placeholder":{}}}')
            & chmod 644 $Path
        }
        $Content = $null
        foreach ($Path in $Paths)
        {
            $Written = Save-StreamAzContextSnapshot -Path $Path -Content $Content
            $Written.OwnerOnly | Should -BeTrue
            $Content = $Written.Content
            [Convert]::ToString([int](Get-Item -LiteralPath $Path -Force).UnixFileMode, 8) | Should -Be '600'
            Get-Content -LiteralPath $Path -Raw | Should -Be '{"Contexts":{"placeholder":{}}}'
        }
        Remove-Item -LiteralPath $Paths[0] -Force
        $Written = Save-StreamAzContextSnapshot -Path $Paths[0] -Content $Content
        Get-Content -LiteralPath $Paths[0] -Raw | Should -Be '{"Contexts":{"placeholder":{}}}' -Because 'a later copy does not need the first file'
    }

    It 'accepts a Windows access list only when it does not inherit and allows no one else' {
        $Allowed = @('S-1-5-21-1-2-3-1001', 'S-1-5-18', 'S-1-5-32-544')
        $Own = @($Allowed | ForEach-Object { [pscustomobject]@{ Sid = $_; Type = 'Allow' } })
        Test-OwnerOnlyAccessList -Protected $true -Rules $Own -AllowedSids $Allowed | Should -BeTrue
        Test-OwnerOnlyAccessList -Protected $false -Rules $Own -AllowedSids $Allowed | Should -BeFalse -Because 'it inherits from the folder'
        Test-OwnerOnlyAccessList -Protected $true -Rules ($Own + [pscustomobject]@{ Sid = 'S-1-5-32-545'; Type = 'Allow' }) -AllowedSids $Allowed | Should -BeFalse -Because 'Users can read it'
        Test-OwnerOnlyAccessList -Protected $true -Rules ($Own + [pscustomobject]@{ Sid = 'S-1-5-11'; Type = 'Allow' }) -AllowedSids $Allowed | Should -BeFalse -Because 'Authenticated Users can change it'
        Test-OwnerOnlyAccessList -Protected $true -Rules ($Own + [pscustomobject]@{ Sid = 'S-1-1-0'; Type = 'Deny' }) -AllowedSids $Allowed | Should -BeTrue -Because 'a Deny entry lets no one in'
    }

    It 'confirms Az context autosave is off only when the process setting says so, and says what it read or why it could not' {
        function Get-AzContextAutosaveSetting { param($Scope) }
        $Check = { $C = Get-AzContextAutosaveCheck; '{0}|{1}' -f $C.Disabled, $C.Detail }
        Mock Get-AzContextAutosaveSetting -MockWith { [pscustomobject]@{ Mode = 'Process'; ContextFile = 'None'; CacheFile = 'None' } }
        & $Check | Should -Be 'True|'
        Mock Get-AzContextAutosaveSetting -MockWith { [pscustomobject]@{ Mode = 'Process'; ContextFile = ''; CacheFile = $null } }
        & $Check | Should -Be 'True|'
        Mock Get-AzContextAutosaveSetting -MockWith { [pscustomobject]@{ Mode = 'CurrentUser'; ContextFile = 'AzureRmContext.json'; CacheFile = 'msal.cache.cae' } }
        & $Check | Should -Be 'False|Get-AzContextAutosaveSetting reports Mode=CurrentUser, ContextFile=AzureRmContext.json, CacheFile=msal.cache.cae'
        Mock Get-AzContextAutosaveSetting -MockWith { [pscustomobject]@{ Mode = 'Process'; ContextFile = 'AzureRmContext.json'; CacheFile = 'None' } }
        & $Check | Should -Be 'False|Get-AzContextAutosaveSetting reports Mode=Process, ContextFile=AzureRmContext.json, CacheFile=None'
        Mock Get-AzContextAutosaveSetting -MockWith { throw 'stand-in: not available' }
        & $Check | Should -Be 'False|Get-AzContextAutosaveSetting failed: stand-in: not available'
        Mock Get-AzContextAutosaveSetting -MockWith { $null }
        & $Check | Should -Be 'False|Get-AzContextAutosaveSetting returned nothing'
    }

    It 'reads the real Az.Accounts autosave setting right, with autosave on for the user and with it off' {
        if ($IsWindows)
        {
            Set-ItResult -Skipped -Because 'on Windows Az.Accounts ignores the HOME and USERPROFILE redirect, so this case would change the Az autosave setting of the user running the tests'
            return
        }
        if ($env:RDA_TEST_REAL_AZ_ACCOUNTS -ne '1')
        {
            Set-ItResult -Skipped -Because 'it loads the installed Az.Accounts, which can reach the network; set RDA_TEST_REAL_AZ_ACCOUNTS=1 to run it'
            return
        }
        $Real = @(Get-Module -ListAvailable -Name Az.Accounts | Where-Object { $_.Version -lt [version]'99.0' })
        if ($Real.Count -eq 0)
        {
            Set-ItResult -Skipped -Because 'Az.Accounts is not installed'
            return
        }
        $UserHome = Join-Path $script:CaseHome 'az-home'
        New-Item -ItemType Directory -Path $UserHome -Force | Out-Null
        $Functions = Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1'
        # The probe changes the CurrentUser autosave setting only after Az.Accounts
        # reports its CurrentUser files inside the scratch home; otherwise it
        # prints 'outside=' and changes nothing.
        $InHome = "`$Home_ = [IO.Path]::GetFullPath(`$env:HOME).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar; `$User = Get-AzContextAutosaveSetting -Scope CurrentUser; foreach (`$Dir in @(`$User.ContextDirectory, `$User.CacheDirectory)) { if (-not `$Dir -or -not ([IO.Path]::GetFullPath(`$Dir) + [IO.Path]::DirectorySeparatorChar).StartsWith(`$Home_, [StringComparison]::Ordinal)) { 'outside=' + `$Dir; exit 1 } }"
        $Probe = {
            param([string]$Before)
            $Script = ". '{0}'; Import-Module Az.Accounts -ErrorAction Stop; {1}; {2}; 'before=' + (Get-AzContextAutosaveCheck).Disabled; Disable-AzContextAutosave -Scope Process | Out-Null; 'after=' + (Get-AzContextAutosaveCheck).Disabled" -f $Functions.Replace("'", "''"), $InHome, $Before
            $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
            foreach ($Arg in @('-NoProfile', '-NonInteractive', '-Command', $Script)) { $Info.ArgumentList.Add($Arg) }
            $Info.UseShellExecute = $false
            $Info.RedirectStandardInput = $true
            $Info.RedirectStandardOutput = $true
            $Info.Environment['HOME'] = $UserHome
            $Info.Environment['USERPROFILE'] = $UserHome
            $Info.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
            $Proc = [System.Diagnostics.Process]::Start($Info)
            $Proc.StandardInput.Close()
            $Out = $Proc.StandardOutput.ReadToEnd()
            $null = $Proc.WaitForExit(120000)
            @($Out -split "`r?`n" | Where-Object { $_ -match '^(before|after|outside)=' })
        }
        & $Probe 'Enable-AzContextAutosave -Scope CurrentUser | Out-Null' | Should -Be @('before=False', 'after=True') -Because 'autosave on for the user: only the Process-scope switch turns it off'
        & $Probe 'Disable-AzContextAutosave -Scope CurrentUser | Out-Null' | Should -Be @('before=True', 'after=True') -Because 'autosave already off for the user'
    }

    It 'leaves every snapshot out of the -PackageZip bundle, also where the folder''s wildcard lists dot-files (as on Windows)' {
        $Folder = Join-Path $script:Root 'bundle'
        New-Item -ItemType Directory -Path (Join-Path $Folder 'ResourcesReport1'), (Join-Path $Folder 'Nested/InventoryReports') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Folder 'MainSummary.html') -Value '<html></html>'
        Set-Content -LiteralPath (Join-Path $Folder 'ResourcesReport1/report.html') -Value '<html></html>'
        Set-Content -LiteralPath (Join-Path $Folder '.rda-stream-azcontext-top.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $Folder '.other-dot-file.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $Folder 'Nested/InventoryReports/.rda-stream-azcontext-deep.json') -Value '{}'
        # The listing a Windows wildcard gives: dot-files included.
        Mock Get-ChildItem -ParameterFilter { $null -ne $Path } -MockWith { Get-ChildItem -LiteralPath $Folder -Force }
        $Items = @(Get-RdaPackageZipItem -Directory $Folder -WarningVariable Warned -WarningAction SilentlyContinue | ForEach-Object { Split-Path -Path $_ -Leaf } | Sort-Object)
        $Items | Should -Be @('.other-dot-file.json', 'MainSummary.html', 'ResourcesReport1')
        @($Warned).Count | Should -Be 1
        [string]$Warned[0] | Should -BeLike ('Left {0} out of the bundle: it holds an Az context snapshot*' -f (Join-Path $Folder 'Nested'))
    }

    It 'runs -PackageZip where wildcards list dot-files (as on Windows) and puts no snapshot in the bundle' {
        # One per-subscription report, inside a consolidated zip.
        $Report = Join-Path $script:CaseHome 'src/ResourcesReport_20261030'
        New-Item -ItemType Directory -Path $Report, (Join-Path $script:CaseHome 'inner') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Report 'Inventory_ResourcesReport_20261030.json') -Value '{"VirtualMachines":[{"Name":"vm","Subscription":"sub-a"}]}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $Report 'ResourcesReport_20261030.html') -Value '<html></html>' -Encoding utf8
        Compress-Archive -Path (Join-Path $Report '*') -DestinationPath (Join-Path $script:CaseHome 'inner/ResourcesReport_20261030.zip') -Force
        $Outer = Join-Path $script:CaseHome 'AllSubscriptions_ResourcesReport_test.zip'
        Compress-Archive -Path (Join-Path $script:CaseHome 'inner/*') -DestinationPath $Outer -Force
        # The bundle's folder holds a live run's snapshot, as the inventory folder does.
        $Out = Join-Path $script:Root 'summary'
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        $Out = (Resolve-Path -LiteralPath $Out).Path
        Set-Content -LiteralPath (Join-Path $Out '.rda-stream-azcontext-live.json') -Value '{}'
        # As on Windows: a wildcard over the folder lists dot-files, in the
        # bundle's own listing and in Compress-Archive -Path alike.
        Mock Get-ChildItem -ParameterFilter { $Path -eq (Join-Path $Out '*') } -MockWith { Get-ChildItem -LiteralPath $Out -Force }
        $RealCompress = Get-Command -Name Compress-Archive -Module Microsoft.PowerShell.Archive -CommandType Function, Cmdlet
        Mock Compress-Archive -ParameterFilter { $DestinationPath -eq ($Out + '.zip') } -MockWith {
            $Items = if ($LiteralPath) { @($LiteralPath) } else { @(Get-ChildItem -LiteralPath (Split-Path -Path @($Path)[0] -Parent) -Force | ForEach-Object { $_.FullName }) }
            & $RealCompress -LiteralPath $Items -DestinationPath $DestinationPath -Force
        }
        $null = New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer -OutputDirectory $Out -KeepOriginalReports -PackageZip
        Should -Invoke Compress-Archive -ParameterFilter { $DestinationPath -eq ($Out + '.zip') } -Times 1 -Exactly
        $Entries = @(script:Get-ZipEntry -Zip ($Out + '.zip'))
        $Entries | Should -Contain 'MainSummary.html'
        @($Entries | Where-Object { $_ -like 'ResourcesReport_20261030/*' }).Count | Should -BeGreaterThan 0
        @($Entries | Where-Object { $_ -like '*azcontext*' }).Count | Should -Be 0 -Because 'the bundle must not hold a token cache'
    }

    It 'builds the -PackageZip bundle from that selection with the folder layout kept' {
        $Folder = Join-Path $script:Root 'bundle'
        New-Item -ItemType Directory -Path (Join-Path $Folder 'ResourcesReport1'), (Join-Path $Folder 'Nested/InventoryReports') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Folder 'MainSummary.html') -Value '<html></html>'
        Set-Content -LiteralPath (Join-Path $Folder 'ResourcesReport1/report.html') -Value '<html></html>'
        Set-Content -LiteralPath (Join-Path $Folder '.rda-stream-azcontext-top.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $Folder 'Nested/InventoryReports/.rda-stream-azcontext-deep.json') -Value '{}'
        $Zip = Join-Path $script:Root 'bundle.zip'
        Compress-Archive -LiteralPath @(Get-RdaPackageZipItem -Directory $Folder -WarningAction SilentlyContinue) -DestinationPath $Zip -Force
        @(script:Get-ZipEntry -Zip $Zip | Sort-Object) | Should -Be @('MainSummary.html', 'ResourcesReport1/report.html')
    }
}

Describe 'The Az context snapshots of a parallel run' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Stop-Started }

    It 'gives each stream its own owner-only file named after the run, which the stream deletes before it collects; none is left at the end' {
        $Result = script:Invoke-Wrapper -Streams 2
        $Result.ExitCode | Should -Be 0 -Because ($Result.Text -join ' | ')
        $Imported = @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'imported-*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
        $Imported.Count | Should -Be 2
        foreach ($Read in $Imported)
        {
            Split-Path -Path $Read.Path -Parent | Should -Be $script:Root
            $Read.Mode | Should -Be '600' -Because 'the file holds a token cache and was written under umask 022'
            Split-Path -Path $Read.Path -Leaf | Should -Match ('^\.rda-stream-azcontext-{0}-{1}-\d{{8}}T\d{{9}}Z-[0-9a-f]{{32}}\.json$' -f [regex]::Escape([uri]::EscapeDataString([Environment]::MachineName)), $Result.ProcessId) -Because 'the name holds the machine and the wrapper process'
        }
        @($Imported.Path | Sort-Object -Unique).Count | Should -Be 2 -Because 'each stream reads its own file'
        $Collected = @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'collected-*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
        $Collected.Count | Should -Be 2
        foreach ($Row in $Collected) { $Row.SnapshotPresent | Should -BeFalse -Because 'a stream needs its file only to import the context' }
        script:Assert-CleanRun -Result $Result -Because 'the run'

        # The next two runs.
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the next run'
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the run after it'
    }

    It 'removes the files at once when the workers died before reading them and the run is interrupted, before stopping the jobs returns' {
        if (-not $script:Perl -and -not $IsMacOS -and ((Get-Content -LiteralPath '/proc/self/status' | Where-Object { $_ -like 'SigIgn:*' }) -replace '^SigIgn:\s*', '' | ForEach-Object { ([Convert]::ToUInt64($_, 16) -band 2) -ne 0 }))
        {
            Set-ItResult -Skipped -Because 'this test process ignores Ctrl+C (SIGINT), so the run it starts would too, and perl is not there to set it back'
            return
        }
        $Run = script:Start-Wrapper -Streams 2 -HoldImport
        $Workers = script:Wait-ImportHeld -Count 2
        # Kill the workers once the wrapper is in its polling loop (its
        # transcript shows their first lines), as in a run interrupted mid-way.
        $Deadline = (Get-Date).AddSeconds(60)
        do
        {
            Start-Sleep -Milliseconds 200
            $Transcript = Get-ChildItem -LiteralPath $script:Root -File -Filter 'RunAllSubscriptions_transcript_*' | Select-Object -First 1
            $Seen = if ($Transcript) { @(0, 1 | Where-Object { (Get-Content -LiteralPath $Transcript.FullName -Raw) -match ('\[stream-{0}\] starting' -f $_) }).Count } else { 0 }
        } while ($Seen -lt 2 -and (Get-Date) -lt $Deadline)
        $Seen | Should -Be 2 -Because 'the wrapper reads the output of both workers'
        @(script:Get-Snapshot).Count | Should -BeGreaterThan 0 -Because 'the workers have not read their files yet'
        foreach ($Worker in $Workers) { Stop-Process -Id $Worker -Force }
        Start-Sleep -Seconds 2
        # Ctrl+C, as the terminal sends it. Stopping the dead workers' jobs then
        # takes about a minute; a run ended in that minute (its terminal window
        # closed) would keep any file not deleted by then.
        & kill -INT $Run.Process.Id
        $Deadline = (Get-Date).AddSeconds(30)
        while (@(script:Get-Snapshot).Count -gt 0 -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 200 }
        $Left = @(script:Get-Snapshot).Count
        $Running = -not $Run.Process.HasExited
        Write-Host ('After Ctrl+C: snapshot files left: {0}; wrapper still running: {1}' -f $Left, $Running)
        script:Stop-Started
        $null = $Run.Process.WaitForExit(10000)
        $Left | Should -Be 0 -Because ('the interrupted run deletes the files within 30 s, before stopping the jobs returns (about a minute after the workers died). Run output: {0}' -f ([string]$Run.Out.Result -replace '\s+', ' '))

        # A run still in that minute was killed above (Stop-Started), as a closed
        # terminal would end it, so it left its run lock, which no run takes
        # over: the next run stops on it with the command that removes it, and
        # that command is run, as a user would run it.
        $LockPath = if (Get-Command -Name Get-RunLockPath -ErrorAction SilentlyContinue) { Get-RunLockPath -InventoryRoot $script:Root -Tenant $script:Tenant } else { $null }
        if ($Running -and $LockPath -and (Test-Path -LiteralPath $LockPath))
        {
            $Stopped = script:Invoke-Wrapper -Streams 2
            $Stopped.ExitCode | Should -Be 1 -Because 'a lock left by a killed run stops the next run'
            $Remove = @($Stopped.Text | Where-Object { $_ -match '^    Remove-Item -LiteralPath ' })
            $Remove.Count | Should -Be 1 -Because 'the stop prints the command that removes the lock of a run that is no longer running'
            & ([scriptblock]::Create($Remove[0].Trim()))
        }

        # The next two runs.
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the next run'
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the run after it'
    }

    It 'keeps its run lock through the clean-up after Ctrl+C while the workers read their files, then releases it with no snapshot left' {
        if (-not (Get-Command -Name Get-RunLockPath -ErrorAction SilentlyContinue))
        {
            Set-ItResult -Skipped -Because 'this version takes no run lock'
            return
        }
        if (-not $script:Perl -and -not $IsMacOS -and ((Get-Content -LiteralPath '/proc/self/status' | Where-Object { $_ -like 'SigIgn:*' }) -replace '^SigIgn:\s*', '' | ForEach-Object { ([Convert]::ToUInt64($_, 16) -band 2) -ne 0 }))
        {
            Set-ItResult -Skipped -Because 'this test process ignores Ctrl+C (SIGINT), so the run it starts would too, and perl is not there to set it back'
            return
        }
        $LockPath = Get-RunLockPath -InventoryRoot $script:Root -Tenant $script:Tenant
        $Run = script:Start-Wrapper -Streams 2 -HoldImport
        $null = script:Wait-ImportHeld -Count 2
        Test-Path -LiteralPath $LockPath | Should -BeTrue -Because 'the run holds its lock while the streams start'
        @(script:Get-Snapshot).Count | Should -BeGreaterThan 0 -Because 'the workers are still reading their files'
        # Ctrl+C, as the terminal sends it, while both workers are inside
        # Import-AzContext. Then watch the lock and the snapshots until the
        # wrapper has ended.
        & kill -INT $Run.Process.Id
        $Samples = [System.Collections.Generic.List[object]]::new()
        $Deadline = (Get-Date).AddSeconds(120)
        while (-not $Run.Process.HasExited -and (Get-Date) -lt $Deadline)
        {
            $Samples.Add([pscustomobject]@{ Lock = (Test-Path -LiteralPath $LockPath); Snapshots = @(script:Get-Snapshot).Count })
            Start-Sleep -Milliseconds 100
        }
        $Ended = $Run.Process.HasExited
        $LockLeft = Test-Path -LiteralPath $LockPath
        $Left = @(script:Get-Snapshot).Count
        script:Stop-Started
        $Ended | Should -BeTrue -Because ('the interrupted run ends. Run output: {0}' -f ([string]$Run.Out.Result -replace '\s+', ' '))
        @($Samples | Where-Object { -not $_.Lock -and $_.Snapshots -gt 0 }) | Should -BeNullOrEmpty -Because 'the lock is released only after the clean-up has deleted the snapshots'
        $LockLeft | Should -BeFalse -Because 'the lock is released once the clean-up has finished'
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*').Count | Should -Be 0
        $Left | Should -Be 0 -Because 'the interrupted run deletes every snapshot'

        # The next two runs find no lock left, take their own and end clean.
        foreach ($Because in 'the next run', 'the run after it')
        {
            $Next = script:Invoke-Wrapper -Streams 2
            script:Assert-CleanRun -Result $Next -Because $Because
            @($Next.Text | Where-Object { $_ -match 'holds the lock on this inventory folder' }) | Should -BeNullOrEmpty -Because ('{0}: the interrupted run left no lock' -f $Because)
            Test-Path -LiteralPath $LockPath | Should -BeFalse -Because $Because
        }
    }

    It 'keeps the snapshots of a live run of another tenant whose workers have not opened them, however old, and removes them once that run has ended' {
        $null = script:Start-Wrapper -Streams 2 -Tenant $script:OtherTenant -HoldImport
        $LiveWorkers = script:Wait-ImportHeld -Count 2
        $LiveFiles = @(script:Get-Snapshot | ForEach-Object { $_.FullName })
        $LiveFiles.Count | Should -BeGreaterThan 0
        foreach ($File in $LiveFiles) { (Get-Item -LiteralPath $File -Force).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-2) }
        $Result = script:Invoke-Wrapper -Streams 1
        $Result.ExitCode | Should -Be 0 -Because ($Result.Text -join ' | ')
        @(script:Get-RemovedLine -Text $Result.Text).Count | Should -Be 0
        @(script:Get-KeptLine -Text $Result.Text).Count | Should -Be 0 -Because 'a live run on this machine needs no line'
        foreach ($File in $LiveFiles) { Test-Path -LiteralPath $File | Should -BeTrue -Because 'the live run''s workers still need them' }

        # The live run is killed outright, workers first (a worker whose wrapper
        # ends first stops its script, and that deletes its file), so its files
        # stay. The next run removes them with one line, the two after it say
        # nothing.
        foreach ($Worker in $LiveWorkers) { Stop-Process -Id $Worker -Force }
        script:Stop-Started -Hold
        @(script:Get-Snapshot).Count | Should -Be $LiveFiles.Count
        $Next = script:Invoke-Wrapper -Streams 1
        $Next.ExitCode | Should -Be 0
        @(script:Get-Snapshot).Count | Should -Be 0
        @(script:Get-RemovedLine -Text $Next.Text) | Should -Be @(script:Format-RemovedLine -Count $LiveFiles.Count)
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the next run'
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the run after it'
    }

    It 'removes at the next start the snapshots of an ended process and of a reused process id, with one line, and keeps a live owner''s whose start time a clock correction moved' {
        $Sleeper = script:Start-Sleeper
        $Gone = script:New-LeftoverSnapshot -Name (script:Get-OwnedSnapshotName -ProcessId (script:Get-EndedProcessId) -StartUtc ([datetime]::UtcNow.AddMinutes(-3))) -AgeMinutes 1
        $Reused = script:New-LeftoverSnapshot -Name (script:Get-OwnedSnapshotName -ProcessId $Sleeper.Process.Id -StartUtc $Sleeper.StartUtc.AddHours(-3))
        $Live = script:New-LeftoverSnapshot -Name (script:Get-OwnedSnapshotName -ProcessId $Sleeper.Process.Id -StartUtc $Sleeper.StartUtc)
        # The same live owner, its start time moved 30 s by a clock correction.
        $Moved = script:New-LeftoverSnapshot -Name (script:Get-OwnedSnapshotName -ProcessId $Sleeper.Process.Id -StartUtc $Sleeper.StartUtc.AddSeconds(-30))
        $Result = script:Invoke-Wrapper -Streams 2
        $Result.ExitCode | Should -Be 0 -Because ($Result.Text -join ' | ')
        Test-Path -LiteralPath $Gone | Should -BeFalse
        Test-Path -LiteralPath $Reused | Should -BeFalse
        Test-Path -LiteralPath $Live | Should -BeTrue
        Test-Path -LiteralPath $Moved | Should -BeTrue -Because 'its owner is still running'
        @(script:Get-RemovedLine -Text $Result.Text) | Should -Be @(script:Format-RemovedLine -Count 2)
        @(script:Get-KeptLine -Text $Result.Text).Count | Should -Be 0

        # The next two runs, with the live owner ended before the second.
        $Next = script:Invoke-Wrapper -Streams 2
        $Next.ExitCode | Should -Be 0
        @(script:Get-RemovedLine -Text $Next.Text).Count | Should -Be 0
        Test-Path -LiteralPath $Live | Should -BeTrue
        Test-Path -LiteralPath $Moved | Should -BeTrue
        script:Stop-Started
        $After = script:Invoke-Wrapper -Streams 2
        $After.ExitCode | Should -Be 0
        @(script:Get-RemovedLine -Text $After.Text) | Should -Be @(script:Format-RemovedLine -Count 2)
        @(script:Get-Snapshot).Count | Should -Be 0
    }

    It 'keeps and names a snapshot from another machine and one whose name does not say its owner, on every run' {
        $Foreign = script:New-LeftoverSnapshot -Name (script:Get-OwnedSnapshotName -Machine 'another-host' -ProcessId 4242 -StartUtc ([datetime]::UtcNow.AddDays(-1))) -AgeMinutes 1440
        $Old = script:New-LeftoverSnapshot -Name ('.rda-stream-azcontext-{0}.json' -f [guid]::NewGuid().ToString()) -AgeMinutes 1440
        $Expected = @((script:Format-KeptLine -Path $Foreign -Why 'it was written by a run on another machine (another-host)'), (script:Format-KeptLine -Path $Old -Why 'its name does not say which run wrote it')) | Sort-Object
        foreach ($Which in 'the run', 'the next run', 'the run after it')
        {
            $Result = script:Invoke-Wrapper -Streams 2
            $Result.ExitCode | Should -Be 0 -Because ('{0}: {1}' -f $Which, ($Result.Text -join ' | '))
            @(script:Get-KeptLine -Text $Result.Text | Sort-Object) | Should -Be $Expected -Because $Which
            @(script:Get-RemovedLine -Text $Result.Text).Count | Should -Be 0 -Because $Which
            Test-Path -LiteralPath $Foreign | Should -BeTrue -Because $Which
            Test-Path -LiteralPath $Old | Should -BeTrue -Because $Which
        }
    }

    It 'keeps the snapshots of a run in this same process (thread jobs, another tenant) whose workers have not opened them, and removes them once that process has ended' {
        # One pwsh process runs two wrapper invocations as thread jobs. The
        # first, for another tenant, holds its workers before they open their
        # snapshots; the second, a sequential run, sweeps the folder meanwhile.
        $SecondScenario = script:New-Scenario -Tenant $script:Tenant
        $Out = Join-Path $script:CaseHome 'second-run.txt'
        $HostScript = Join-Path $script:CaseHome 'two-runs.ps1'
        Set-Content -LiteralPath $HostScript -Encoding utf8 -Value @'
param([string]$Wrapper, [string]$FirstTenant, [string]$SecondTenant, [string]$SecondScenario, [string]$Out)
$First = Start-ThreadJob -ScriptBlock { & $using:Wrapper -TenantID $using:FirstTenant -ParallelStreams 2 -SkipMetrics -SkipConsumption *>&1 | ForEach-Object { [string]$_ } }
$Deadline = (Get-Date).AddSeconds(180)
while (@(Get-ChildItem -LiteralPath $HOME -File -Filter 'import-held-*').Count -lt 2 -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 200 }
$Second = Start-ThreadJob -ScriptBlock { $Global:RdaStandInAzure = $using:SecondScenario; & $using:Wrapper -TenantID $using:SecondTenant -ParallelStreams 1 -SkipMetrics -SkipConsumption *>&1 | ForEach-Object { [string]$_ } }
$Text = @($Second | Wait-Job -Timeout 180 | Receive-Job)
Set-Content -LiteralPath $Out -Value ($Text -join "`n")
Set-Content -LiteralPath ($Out + '.done') -Value $First.State
Start-Sleep -Seconds 600
'@
        $null = script:Start-Wrapper -Tenant $script:OtherTenant -HoldImport -Script @($HostScript, '-Wrapper', $script:Wrapper, '-FirstTenant', $script:OtherTenant, '-SecondTenant', $script:Tenant, '-SecondScenario', $SecondScenario, '-Out', $Out)
        $Workers = script:Wait-ImportHeld -Count 2
        $FirstFiles = @(script:Get-Snapshot | ForEach-Object { $_.FullName })
        $FirstFiles.Count | Should -BeGreaterThan 0
        $Deadline = (Get-Date).AddSeconds(180)
        while (-not (Test-Path -LiteralPath ($Out + '.done')) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 200 }
        Test-Path -LiteralPath ($Out + '.done') | Should -BeTrue -Because 'the second run ends'
        (Get-Content -LiteralPath ($Out + '.done') -Raw).Trim() | Should -Be 'Running' -Because 'the first run is still going'
        $Second = @((Get-Content -LiteralPath $Out -Raw) -replace "`e\[[0-9;]*m", '' -split "`r?`n")
        @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'collected-*.json').Count | Should -Be 2 -Because ('the second run collects its two subscriptions: {0}' -f ($Second -join ' | '))
        @(script:Get-RemovedLine -Text $Second).Count | Should -Be 0 -Because ($Second -join ' | ')
        @(script:Get-KeptLine -Text $Second).Count | Should -Be 0 -Because 'a run in this process needs no line'
        foreach ($File in $FirstFiles) { Test-Path -LiteralPath $File | Should -BeTrue -Because 'the first run in the same process still needs it' }

        # The process is killed outright, workers first, so the first run's
        # files stay. The next run removes them with one line, the run after
        # it says nothing.
        foreach ($Worker in $Workers) { Stop-Process -Id $Worker -Force }
        script:Stop-Started -Hold
        @(script:Get-Snapshot).Count | Should -Be $FirstFiles.Count
        $Next = script:Invoke-Wrapper -Streams 1
        $Next.ExitCode | Should -Be 0
        @(script:Get-RemovedLine -Text $Next.Text) | Should -Be @(script:Format-RemovedLine -Count $FirstFiles.Count)
        @(script:Get-Snapshot).Count | Should -Be 0
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the run after it'
    }

    It 'imports a stream''s snapshot when Disable-AzContextAutosave throws but the process setting then reads off' {
        # The stop depends only on what Get-AzContextAutosaveSetting reports
        # after the call. main has no such stop and imports here too.
        $Result = script:Invoke-Wrapper -Streams 2 -Autosave 'throw-after-off'
        $Result.ExitCode | Should -Be 0 -Because ($Result.Text -join ' | ')
        @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'imported-*.json').Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'collected-*.json').Count | Should -Be 2
        @($Result.Text | Where-Object { $_ -like '*FATAL*' }).Count | Should -Be 0
        script:Assert-CleanRun -Result $Result -Because 'the run'
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the next run'
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the run after it'
    }

    It 'does not import a stream''s snapshot when Az context autosave <Case>, deletes it and reports the stream as failed' -ForEach @(
        @{ Case = 'cannot be turned off'; Autosave = 'fail'; Detail = 'Disable-AzContextAutosave failed: stand-in: the autosave setting cannot be changed; Get-AzContextAutosaveSetting reports Mode=CurrentUser, ContextFile=AzureRmContext.json, CacheFile=msal.cache' },
        @{ Case = 'stays on after it was turned off'; Autosave = 'stuck'; Detail = 'Get-AzContextAutosaveSetting reports Mode=CurrentUser, ContextFile=AzureRmContext.json, CacheFile=msal.cache' },
        @{ Case = 'cannot be read'; Autosave = 'setting-fails'; Detail = 'Get-AzContextAutosaveSetting failed: stand-in: the autosave setting cannot be read' }) {
        $Result = script:Invoke-Wrapper -Streams 2 -Autosave $Autosave
        @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'imported-*.json').Count | Should -Be 0 -Because 'no stream imports its snapshot'
        @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'collected-*.json').Count | Should -Be 0 -Because 'no stream collects'
        @(script:Get-Snapshot).Count | Should -Be 0 -Because 'each stream deletes its snapshot'
        $Fatal = @($Result.Text | Where-Object { $_ -like '`[stream-?`] FATAL: Az context autosave could not be turned off for this stream*' })
        $Fatal.Count | Should -Be 2 -Because ($Result.Text -join ' | ')
        foreach ($Line in $Fatal)
        {
            $Line | Should -BeLike ('*({0}), so its Az context snapshot was not imported: importing it would write the token cache to the user''s Az profile files. Its subscriptions are reported as failed; run with -ParallelStreams 1 to collect them without stream workers.' -f $Detail)
        }
        @($Result.Text | Where-Object { $_ -like '`[stream-?`] stream status: failed-to-start - Az context autosave could not be turned off*' }).Count | Should -Be 2

        # The next two runs, with autosave turned off as usual.
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the next run'
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the run after it'
    }

    It 'keeps the subscriptions of a stream that did not load its snapshot on the retry list without counting a failed run, on every -Resume run, until the cause is fixed' {
        $State = Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Tenant)
        $Read = {
            $Entries = @((Get-Content -LiteralPath $State -Raw | ConvertFrom-Json).FailedAttempts | Where-Object { $null -ne $_ })
            @($Entries | Sort-Object -Property Id | ForEach-Object { '{0}={1}' -f $_.Id, $_.Attempts })
        }
        # The cause stays: the first run and the next four -Resume runs (one more
        # than the retry limit) each fail both streams, collect nothing, exit 2
        # with the reason, and leave both subscriptions on the retry list at 0.
        foreach ($Which in 'the first run', '-Resume 1', '-Resume 2', '-Resume 3', '-Resume 4')
        {
            $Result = script:Invoke-Wrapper -Streams 2 -Autosave 'stuck' -Resume:($Which -ne 'the first run')
            $Result.ExitCode | Should -Be 2 -Because ('{0}: {1}' -f $Which, ($Result.Text -join ' | '))
            @($Result.Text | Where-Object { $_ -like '`[stream-?`] FATAL: Az context autosave could not be turned off for this stream*' }).Count | Should -Be 2 -Because $Which
            @($Result.Text | Where-Object { $_ -like 'Not retried:*' -or $_ -like 'Retry Limit Reached:*' }).Count | Should -Be 0 -Because ('{0}: the cause is the stream''s sign-in, not the subscriptions' -f $Which)
            @($Result.Text | Where-Object { $_ -like 'Not counted toward the retry limit: 2 (Sub A, Sub B) - *' }).Count | Should -Be 1 -Because $Which
            @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'collected-*.json').Count | Should -Be 0 -Because $Which
            & $Read | Should -Be @('sub-a=0', 'sub-b=0') -Because $Which
            Write-Host ('{0}: exit {1}, retry list {2}' -f $Which, $Result.ExitCode, ((& $Read) -join ', '))
        }
        # The cause fixed: the next -Resume collects both and clears the entries;
        # the run after it is a clean run.
        $Fixed = script:Invoke-Wrapper -Streams 2 -Resume
        $Fixed.ExitCode | Should -Be 0 -Because ($Fixed.Text -join ' | ')
        @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'collected-*.json').Count | Should -Be 2
        Test-Path -LiteralPath $State | Should -BeFalse -Because 'every subscription is collected, so the resume state is cleared'
        Write-Host ('cause fixed, -Resume: exit {0}, resume state left: {1}' -f $Fixed.ExitCode, (Test-Path -LiteralPath $State))
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the run after it'
    }

    It 'stops with exit 1 when a snapshot cannot be written, names -ParallelStreams 1 as the way out, and leaves no snapshot' {
        # Without -ParallelStreams a host with enough vCPUs and memory still
        # runs parallel streams, so only -ParallelStreams 1 avoids the stop.
        $Marker = Join-Path $script:CaseHome 'save-fails'
        Set-Content -LiteralPath $Marker -Value 'x'
        $Result = script:Invoke-Wrapper -Streams 2
        $Result.ExitCode | Should -Be 1 -Because ($Result.Text -join ' | ')
        $At = [array]::IndexOf($Result.Text, 'ERROR: could not snapshot Az context for stream workers: stand-in: the context cannot be saved')
        $At | Should -BeGreaterOrEqual 0 -Because ($Result.Text -join ' | ')
        $Result.Text[$At + 1] | Should -Be 'Re-run with -ParallelStreams 1 to use the sequential code path.'
        @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'collected-*.json').Count | Should -Be 0 -Because 'no stream started'
        @(script:Get-Snapshot).Count | Should -Be 0 -Because 'the run deletes a file whose write failed'

        # The next two runs, with the context saved as usual.
        Remove-Item -LiteralPath $Marker -Force
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the next run'
        script:Assert-CleanRun -Result (script:Invoke-Wrapper -Streams 2) -Because 'the run after it'
    }

    It 'never puts a snapshot in the consolidated zip or the -PackageZip bundle (on Linux the wildcard leaves dot-files out; see the bundle test above)' {
        $Sleeper = script:Start-Sleeper
        $Kept = script:New-LeftoverSnapshot -Name (script:Get-OwnedSnapshotName -ProcessId $Sleeper.Process.Id -StartUtc $Sleeper.StartUtc) -AgeMinutes 1
        foreach ($Which in 'the run', 'the next run', 'the run after it')
        {
            Get-ChildItem -LiteralPath $script:Root -File -Filter 'AllSubscriptions_ResourcesReport_*' | Remove-Item -Force
            $Result = script:Invoke-Wrapper -Streams 2
            $Result.ExitCode | Should -Be 0 -Because ('{0}: {1}' -f $Which, ($Result.Text -join ' | '))
            Test-Path -LiteralPath $Kept | Should -BeTrue -Because 'a live run''s snapshot is in the inventory folder while the zips are built'
            $Outer = @(Get-ChildItem -LiteralPath $script:Root -File -Filter 'AllSubscriptions_ResourcesReport_*.zip')
            $Outer.Count | Should -Be 1
            # -PackageZip with the default output folder, next to the zip, and
            # with the inventory folder itself as the output folder.
            $null = New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer[0].FullName -KeepOriginalReports -PackageZip
            $Default = Join-Path $script:Root ($Outer[0].BaseName + '_MainSummary.zip')
            $null = New-RdaAllSubHtmlSummaryFromZip -InputZip $Outer[0].FullName -OutputDirectory $script:Root -KeepOriginalReports -PackageZip
            $InRoot = $script:Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + '.zip'
            foreach ($Zip in @($Outer[0].FullName, $Default, $InRoot))
            {
                Test-Path -LiteralPath $Zip | Should -BeTrue
                $Names = @(script:Get-ZipEntry -Zip $Zip)
                $Names.Count | Should -BeGreaterThan 0
                @($Names | Where-Object { $_ -like '*azcontext*' }).Count | Should -Be 0 -Because ('{0}, {1}, must not hold a token cache' -f (Split-Path -Path $Zip -Leaf), $Which)
            }
            Remove-Item -LiteralPath $Default, $InRoot -Force
            Get-ChildItem -LiteralPath $script:Root -Directory -Filter '*_MainSummary' | Remove-Item -Recurse -Force
        }
    }
}
