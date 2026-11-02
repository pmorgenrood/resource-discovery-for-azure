# End to end: resume by default.
#
#   - A run without -Resume continues the unfinished run the resume state file
#     holds, as -Resume does, and its start line says so: when that run
#     started, how many subscriptions are done and its settings. With no
#     unfinished run, or with -Fresh, it starts a new run, which collects every
#     subscription; a new run that is interrupted in turn is continued without
#     the earlier run's completed subscriptions.
#   - A run whose settings (-Obfuscate, -SkipMetrics, -SkipConsumption,
#     -IncludeDisabled) differ from the unfinished run's, or whose recorded
#     settings cannot be read, stops with exit 1 before it signs in, collects
#     anything or writes the resume state (it leaves only its transcript, and
#     releases its run lock), and stops the same way again; the same settings
#     continue it and -Fresh starts over.
#   - The age is checked before the settings: an unfinished run older than
#     -ResumeMaxAgeDays (7 by default), or whose start time cannot be read, is
#     not continued by a run without -Resume, which starts a new run; -Resume
#     continues it with a warning.
#   - A continued run uses the cost window the run recorded at its start, for
#     the up-front check and every subscription; a window that cannot be read
#     is replaced by today's, with a warning, and recorded.
#   - -ResumeFailedOnly with no unfinished run stops with exit 1; -Fresh with
#     -Resume or -ResumeFailedOnly stops with exit 1.
#   - A file from before runs recorded their start time and settings is
#     continued once with a line that says so, and the run records both.
#   - None of it adds a strict-mode error. Resolve-RunStart and the readers are
#     also tested on their own, with present but malformed values.
# Each scenario is followed by the next run or two, with the exit of each.
#
# Every run is Run-AllSubscriptions.ps1 itself, started as its own pwsh process
# from a copy of the tool whose ResourceInventory.ps1 is a stand-in (it logs the
# settings and the cost window each call is given), with stand-in Az modules
# answering from a scenario file, as in ParallelResume.Tests.ps1. An interrupted
# run is ended by killing the wrapper's process tree. On Windows the wrapper
# writes to C:\InventoryReports instead, so the end-to-end tests do not run there.
#
# Run with: Invoke-Pester ./Tests/ResumeByDefault.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('ResumeByDefaultTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
    $script:CaseRuns = [System.Collections.Generic.List[object]]::new()
    $script:ErrorMark = $Error.Count
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
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit, [string]$ConsumptionWindowStart, [string]$ConsumptionWindowEnd)
# One file per call (streams run at once, so one shared file could lose a line):
# the subscription, the settings and the cost window it was given.
Set-Content -LiteralPath (Join-Path $HOME ('call-' + [guid]::NewGuid().ToString() + '.log')) -Value ('{0}|Obfuscate={1}|SkipMetrics={2}|SkipConsumption={3}|Window={4}..{5}' -f $SubscriptionID, [bool]$Obfuscate, [bool]$SkipMetrics, [bool]$SkipConsumption, $ConsumptionWindowStart, $ConsumptionWindowEnd)
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
if (@($Scenario.FailIds) -contains $SubscriptionID) { throw $(if ($Scenario.FailReason) { [string]$Scenario.FailReason } else { 'stand-in failure for this subscription' }) }
# A run of this subscription that ends without writing its zip.
if (@($Scenario.NoZipIds) -contains $SubscriptionID) { $Global:ZipOutputFile = $null; $Global:Resources = @(1); $Global:ResourceCount = 1; return }
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
# After the report of this subscription is written, the inventory root is made
# read-only, so a later removal or new file there fails. With several ids (one
# per stream) each waits for the others first, and the first one listed does it.
if (@($Scenario.ReadOnlyAfterIds) -contains $SubscriptionID)
{
    Set-Content -LiteralPath (Join-Path $HOME ('ro-' + $SubscriptionID)) -Value $PID
    $Deadline = (Get-Date).AddSeconds(120)
    while (@($Scenario.ReadOnlyAfterIds | Where-Object { -not (Test-Path -LiteralPath (Join-Path $HOME ('ro-' + $_))) }).Count -gt 0 -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 100 }
    if (@($Scenario.ReadOnlyAfterIds)[0] -eq $SubscriptionID) { & chmod 555 $Root }
}
# After the report of this subscription is written, the state file of another
# stream is cut short (or emptied) once that stream has finished, so the
# end-of-run merge finds it unreadable.
if ($Scenario.CutStreamFile -and $Scenario.CutStreamFile.AfterId -eq $SubscriptionID)
{
    $Cut = $Scenario.CutStreamFile
    $Done = Join-Path $Root ('.rda-stream-{0}-summary.json' -f $Cut.Stream)
    $Deadline = (Get-Date).AddSeconds(240)
    while (-not (Test-Path -LiteralPath $Done) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 100 }
    $Target = Join-Path $Root ('.resume-state-{0}-stream-{1}.json' -f $TenantID, $Cut.Stream)
    if ($Cut.Kind -eq 'empty') { [System.IO.File]::WriteAllBytes($Target, [byte[]]@()) }
    else { $Raw = Get-Content -LiteralPath $Target -Raw; Set-Content -LiteralPath $Target -Value $Raw.Substring(0, [int]($Raw.Length / 2)) -NoNewline -Encoding utf8 }
}
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
    @($Scenario.Subscriptions | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SubscriptionId = $_.Id; Name = $_.Name; State = $_.State; TenantId = $Scenario.Tenant } })
}
function Invoke-AzRestMethod
{
    [CmdletBinding()] param([string]$Method = 'GET', [string]$Path, [string]$Payload)
    $Answer = { param([int]$Status, $Body) [pscustomobject]@{ StatusCode = $Status; Content = (ConvertTo-Json -InputObject $Body -Depth 8 -Compress); Headers = @{} } }
    if ($Path -match '^/subscriptions/([^/?]+)/resourcegroups\?')
    {
        if (@((Get-RdaStandInScenario).DeniedIds) -contains $Matches[1]) { return & $Answer 403 @{ error = @{ code = 'AuthorizationFailed'; message = 'stand-in: no role on the subscription' } } }
        return & $Answer 200 @{ value = @() }
    }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/roleAssignments\?')
    {
        $Id = $Matches[1]
        # A denied subscription: no role for the caller, as #38's read-access check reads it.
        if (@((Get-RdaStandInScenario).DeniedIds) -contains $Id) { return & $Answer 200 @{ value = @() } }
        # A subscription whose role check cannot finish holds a role whose definition cannot be read.
        $Role = if (@((Get-RdaStandInScenario).RoleUnknownIds) -contains $Id) { 'stand-in-unreadable' } else { 'stand-in-reader' }
        return & $Answer 200 @{ value = @(@{ properties = @{ scope = "/subscriptions/$Id"; principalId = 'stand-in-caller'; roleDefinitionId = "/subscriptions/$Id/providers/Microsoft.Authorization/roleDefinitions/$Role" } }) }
    }
    if ($Path -match '/providers/Microsoft\.Authorization/roleDefinitions/[^/?]+\?')
    {
        # The role of a subscription whose role check cannot finish: its definition cannot be read.
        if ($Path -like '*/roleDefinitions/stand-in-unreadable?*') { return & $Answer 403 @{ error = @{ code = 'AuthorizationFailed'; message = 'stand-in: the role definition cannot be read' } } }
        return & $Answer 200 @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } }
    }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/permissions\?')
    {
        if (@((Get-RdaStandInScenario).DeniedIds) -contains $Matches[1]) { return & $Answer 200 @{ value = @() } }
        return & $Answer 200 @{ value = @(@{ actions = @('*/read'); notActions = @() }) }
    }
    if ($Method -eq 'POST' -and $Path -like '/providers/Microsoft.ResourceGraph/resources*')
    {
        $Ids = @(($Payload | ConvertFrom-Json).subscriptions)
        return & $Answer 200 @{ data = @($Ids | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 1 } }) }
    }
    if ($Path -match '^/subscriptions/([^/?]+)/providers/Microsoft\.Commerce/UsageAggregates\?')
    {
        Set-Content -LiteralPath (Join-Path $HOME ('usage-' + [guid]::NewGuid().ToString() + '.log')) -Value $Path
        # No usage access: #38's consumption check reads this path, as the billing phase's cmdlet does.
        if ((Get-RdaStandInScenario).ConsumptionDenied) { return & $Answer 403 @{ error = @{ code = 'AuthorizationFailed'; message = 'stand-in: the client does not have authorization to read usage' } } }
        return & $Answer 200 @{ value = @(@{ properties = @{ quantity = 1.5; meterCategory = 'Stand-in'; instanceData = '' } }) }
    }
    return & $Answer 404 @{ error = @{ code = 'NotFound'; message = 'stand-in: no answer for this path' } }
}
# With BlockStateWrite in the scenario, every write of the resume state file
# fails as it does on a full disk: Set-Content throws on its temporary file.
# Every other Set-Content call goes through unchanged.
if ((Get-RdaStandInScenario).BlockStateWrite)
{
    $Meta = [System.Management.Automation.CommandMetadata]::new((Get-Command -Name 'Microsoft.PowerShell.Management\Set-Content' -CommandType Cmdlet))
    $Check = "foreach (`$P in @(`$PSBoundParameters['Path']) + @(`$PSBoundParameters['LiteralPath'])) { if ([string]`$P -match '[\\/]\.resume-state-[^\\/]+\.json\.tmp$' -and [string]`$P -notmatch '-stream-') { throw [System.IO.IOException]::new('No space left on device') } }"
    $Body = [regex]::new('(?m)^begin\r?\n\{').Replace([System.Management.Automation.ProxyCommand]::Create($Meta), [System.Text.RegularExpressions.MatchEvaluator]{ param($M) $M.Value + "`n" + $Check }, 1)
    Set-Item -Path 'Function:global:Set-Content' -Value ([scriptblock]::Create($Body))
}
'@
    $Billing = @'
function Get-UsageAggregates
{
    [CmdletBinding()] param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, [switch]$ShowDetails, $ContinuationToken)
    if ((Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json).ConsumptionDenied) { throw 'AuthorizationFailed: stand-in: the client does not have authorization to read usage' }
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


    # For the runs that ask for it, a copy of these modules whose Az.Accounts
    # (which the wrapper and each stream import) also defines a global
    # Compress-Archive in place of the real one: Compress-Archive -Update, the call that
    # adds the run summary to the consolidated zip, removes the zip and fails,
    # as on a full disk, while the scenario says LoseZipOnFold. Every other call
    # goes to the real cmdlet.
    $script:LoseZipModules = Join-Path $script:TestBase 'lose-zip-modules'
    Copy-Item -LiteralPath $script:Modules -Destination $script:LoseZipModules -Recurse -Force
    $LoseZip = @'

# Compress-Archive is itself a function of Microsoft.PowerShell.Archive, so that
# module is loaded first and this one defined after it; the real one is then
# called through its command object, which loads nothing again.
Import-Module Microsoft.PowerShell.Archive -Global
$global:RdaRealCompressArchive = (Get-Module Microsoft.PowerShell.Archive | Select-Object -First 1).ExportedCommands['Compress-Archive']
function global:Compress-Archive
{
    [CmdletBinding()]
    param([string[]]$Path, [string[]]$LiteralPath, [string]$DestinationPath, [string]$CompressionLevel, [switch]$Update, [switch]$Force, [switch]$PassThru)
    if ($Update -and (Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json).LoseZipOnFold)
    {
        Remove-Item -LiteralPath $DestinationPath -Force
        throw 'stand-in: No space left on device'
    }
    & $global:RdaRealCompressArchive @PSBoundParameters
}
'@
    Add-Content -LiteralPath (Join-Path $script:LoseZipModules 'Az.Accounts/99.0.0/Az.Accounts.psm1') -Value $LoseZip -Encoding utf8
    $script:LoseZipEnv = @{ PSModulePath = $script:LoseZipModules }

    $script:Subs = @{}
    foreach ($Letter in 'A', 'B', 'C', 'D', 'E', 'F') { $script:Subs[$Letter] = @{ Id = ('sub-' + $Letter.ToLowerInvariant()); Name = ('Sub ' + $Letter) } }
    # The automatic stream count is 2 on a host with 4 logical processors.
    $script:FourCpu = @{ DOTNET_PROCESSOR_COUNT = '4' }
    # The warning of a run without -Resume whose first write of the resume state fails ({0}: the tenant).
    $script:StartWriteWarning = 'WARNING: The resume state file .resume-state-{0}.json could not be written at the start of this run, so it does not hold this run''s id. Unless a later write of it in this run succeeds, a later run may not see what this run completed or failed: when an earlier run''s resume state file is there, it continues that run and does not use this run''s per-stream state files. Once the file can be written, start the next run with -Fresh.'

    # A fresh home (its InventoryReports folder is the run's inventory root) and
    # scenario for each test.
    function script:New-Case
    {
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseHome -Force | Out-Null
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        $script:State = Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Tenant)
        # Every wrapper run of the test, kept whole for Write-FailedCaseRuns.
        $script:CaseRuns = [System.Collections.Generic.List[object]]::new()
        $script:ErrorMark = $Error.Count
    }

    # After a test that failed (an assertion, or an error the test threw), print
    # the full output of each wrapper run it made, so a failure that does not
    # repeat can still be read. Changes nothing that is asserted.
    function script:Write-FailedCaseRuns
    {
        if ($null -eq $script:CaseRuns -or $script:CaseRuns.Count -eq 0) { return }
        $New = @($Error | Select-Object -First ([math]::Max(0, $Error.Count - $script:ErrorMark)))
        if (@($New | Where-Object { $_.FullyQualifiedErrorId -eq 'PesterAssertionFailed' -or $_.CategoryInfo.Category -eq 'OperationStopped' }).Count -eq 0) { return }
        Write-Host ('--- The wrapper runs of this test ({0}), in order:' -f $script:CaseRuns.Count)
        $N = 0
        foreach ($Run in $script:CaseRuns)
        {
            $N++
            Write-Host ('--- run {0}: {1} | exit {2} | ended by the test: {3}' -f $N, $Run.Arguments, $Run.ExitCode, $Run.Ended)
            foreach ($Line in @($Run.Text)) { Write-Host ('  | ' + $Line) }
            foreach ($Line in @(([string]$Run.Error) -split "`r?`n" | Where-Object { $_ })) { Write-Host ('  ! ' + $Line) }
        }
        Write-Host ('--- per-stream and resume state files now: ' + (@(Get-ChildItem -LiteralPath $script:Root -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.resume-state*' } | ForEach-Object { $_.Name } | Sort-Object) -join ', '))
    }

    # The scenario: subscriptions by letter, and which of them fail, hang or are disabled.
    function script:Set-Scenario
    {
        param([string[]]$Subs, [string[]]$Fail = @(), [string[]]$Hang = @(), [string[]]$Disabled = @(), [string[]]$NoZip = @(), [string[]]$ReadOnlyAfter = @(), [string]$FailReason, [switch]$BlockStateWrite, [string[]]$Denied = @(), [string[]]$RoleUnknown = @(), [switch]$ConsumptionDenied, [switch]$LoseZipOnFold, [string]$CutAfter, [int]$CutStream = 1, [string]$CutKind = 'cut short')
        $Id = { param($L) $script:Subs[$L].Id }
        [pscustomobject]@{
            Tenant        = $script:Tenant
            Subscriptions = @($Subs | ForEach-Object { [pscustomobject]@{ Id = $script:Subs[$_].Id; Name = $script:Subs[$_].Name; State = $(if ($Disabled -contains $_) { 'Disabled' } else { 'Enabled' }) } })
            FailIds       = @($Fail | ForEach-Object { & $Id $_ })
            HangIds       = @($Hang | ForEach-Object { & $Id $_ })
            NoZipIds      = @($NoZip | ForEach-Object { & $Id $_ })
            ReadOnlyAfterIds = @($ReadOnlyAfter | ForEach-Object { & $Id $_ })
            FailReason    = $FailReason
            BlockStateWrite = [bool]$BlockStateWrite
            DeniedIds     = @($Denied | ForEach-Object { & $Id $_ })
            RoleUnknownIds = @($RoleUnknown | ForEach-Object { & $Id $_ })
            ConsumptionDenied = [bool]$ConsumptionDenied
            LoseZipOnFold = [bool]$LoseZipOnFold
            CutStreamFile = $(if ($CutAfter) { [pscustomobject]@{ AfterId = (& $Id $CutAfter); Stream = $CutStream; Kind = $CutKind } } else { $null })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One run of the wrapper as its own process, stdin closed. -Streams 0 leaves
    # -ParallelStreams out, so the run picks the automatic value. -EndWhen is
    # polled while the run is going; once it is true the process tree is killed,
    # as when a session ends. A run that has not ended after $TimeoutSeconds is
    # stopped and the test fails.
    function script:Invoke-Wrapper
    {
        param([string[]]$Arguments = @(), [int]$Streams = 1, [hashtable]$Environment = @{}, [scriptblock]$EndWhen, [int]$TimeoutSeconds = 300, [switch]$StrictMode, [switch]$KeepLock)
        $All = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper, '-TenantID', $script:Tenant)
        if ($Streams -gt 0) { $All += @('-ParallelStreams', [string]$Streams) }
        $All += @($Arguments)
        $Label = ((@($All | Select-Object -Skip 7) + @(if ($StrictMode) { '(strict mode)' })) -join ' ')
        # With -StrictMode the wrapper runs under Set-StrictMode -Version Latest,
        # set by the shell that starts it.
        if ($StrictMode) { $All = @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', ("Set-StrictMode -Version Latest; & '{0}' {1}; exit `$LASTEXITCODE" -f $script:Wrapper, (@($All | Select-Object -Skip 5) -join ' '))) }
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($Arg in @($All)) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
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
            $Proc.WaitForExit()
            $script:CaseRuns.Add([pscustomobject]@{ Arguments = $Label; ExitCode = 'none (stopped after the timeout)'; Ended = $Ended; Text = @(([string]$Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n"); Error = [string]$Err.Result })
            throw ('The wrapper run did not end within {0} seconds.' -f $TimeoutSeconds)
        }
        $Proc.WaitForExit()
        # A run ended this way is killed, so it leaves its run lock, which no run
        # takes over: the next run would stop on it and print the command that
        # removes it. Unless the case is about that stop (-KeepLock), that
        # command is run here, as a user would run it.
        if ($Ended -and -not $KeepLock)
        {
            foreach ($Lock in @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*.json' -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $Lock.FullName -Force }
        }
        $Text = @(([string]$Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        $Run = [pscustomobject]@{ ExitCode = $Proc.ExitCode; Text = $Text; Error = [string]$Err.Result }
        $script:CaseRuns.Add([pscustomobject]@{ Arguments = $Label; ExitCode = $Proc.ExitCode; Ended = $Ended; Text = $Text; Error = $Run.Error })
        if ($EndWhen -and -not $Ended) { throw 'The run ended before the point at which the test ends it.' }
        return $Run
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
    # The stream count the run printed ('Parallelism: -ParallelStreams <n> ...').
    function script:Get-StreamCount { param($Run) foreach ($Line in $Run.Text) { if ($Line -match '^Parallelism: -ParallelStreams (\d+) ') { return [int]$Matches[1] } }; return 0 }
    function script:Get-RemoveWarningLines { param($Run) @($Run.Text | Where-Object { $_ -like 'WARNING: Could not remove the *' -or $_ -like '  The resume state file * is kept, so the next -Resume*' -or $_ -like '  The next run reads it again*' -or $_ -like 'WARNING: The resume state file * could not be written or read back*' }) }
    # The ERROR lines of a run, a stream's included.
    function script:Get-ErrorLines { param($Run) @($Run.Text | Where-Object { $_ -match '^(\[stream-\d+\] )?ERROR' }) }
    # The resume state file as written, or $null.
    function script:Read-StateFile { if (Test-Path -LiteralPath $script:State) { Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json } }
    function script:Get-StreamWarningLines { param($Run) @($Run.Text | Where-Object { $_ -like 'WARNING: The per-stream state file*' }) }
    function script:Test-CleanLine { param($Run) @($Run.Text | Where-Object { $_ -eq 'Resume state cleared (clean run).' }).Count -eq 1 }
    function script:Get-Ids { param([string[]]$Letters) @($Letters | ForEach-Object { $script:Subs[$_].Id } | Sort-Object) }
    # The ids the resume state lists as completed, or none when there is no state.
    function script:Get-StateCompleted { $S = script:Read-State; if ($null -eq $S) { return @() } @($S.Completed | Sort-Object -Unique) }

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
    function script:New-InterruptedStreamState
    {
        param([hashtable]$Streams, [hashtable]$Names = @{})
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        foreach ($Stream in $Streams.Keys)
        {
            $Completed = @()
            $Reports = @()
            foreach ($Letter in @($Streams[$Stream]))
            {
                $Id = $script:Subs[$Letter].Id
                $Stamp = '20260101000000000' + $Id
                $Folder = Join-Path $script:Root ('ResourcesReport' + $Stamp)
                New-Item -ItemType Directory -Path $Folder -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $Folder ('Inventory_ResourcesReport_{0}.json' -f $Stamp)) -Value ('{"VirtualMachines":[{"Name":"vm","Subscription":"' + $Id + '"}]}') -Encoding utf8
                Set-Content -LiteralPath (Join-Path $Folder ('ResourcesReport_{0}.html' -f $Stamp)) -Value '<html></html>' -Encoding utf8
                $Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
                Compress-Archive -Path (Join-Path $Folder '*') -DestinationPath $Zip -Force
                (Get-Item -LiteralPath $Folder).LastWriteTime = (Get-Date).AddHours(-1)
                Get-ChildItem -LiteralPath $Folder -File | ForEach-Object { $_.LastWriteTime = (Get-Date).AddHours(-1) }
                $Completed += $Id
                $Reports += [pscustomobject]@{ Id = $Id; Name = $script:Subs[$Letter].Name; Zip = [System.IO.Path]::GetRelativePath($script:Root, $Zip); Obfuscated = $false }
            }
            $Name = if ($Names.ContainsKey($Stream)) { $Names[$Stream] } else { '.resume-state-{0}-stream-{1}.json' -f $script:Tenant, $Stream }
            [pscustomobject]@{ Tenant = $script:Tenant; StreamId = [string]$Stream; Completed = @($Completed); FailedAttempts = @(); Reports = @($Reports) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:Root $Name) -Encoding utf8
        }
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

    # --- Resume by default ---------------------------------------------------
    # The calls the stand-in ResourceInventory.ps1 logged ('<id>|Obfuscate=..|
    # SkipMetrics=..|SkipConsumption=..|Window=<start>..<end>'), and the usage
    # paths the up-front consumption check read, since the last Clear-Calls.
    function script:Get-Calls { @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'call-*.log' | ForEach-Object { Get-Content -LiteralPath $_.FullName }) }
    function script:Get-UsagePaths { @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'usage-*.log' | ForEach-Object { Get-Content -LiteralPath $_.FullName }) }
    function script:Clear-Calls { Get-ChildItem -LiteralPath $script:CaseHome -File | Where-Object { $_.Name -like 'call-*.log' -or $_.Name -like 'usage-*.log' } | Remove-Item -Force }

    # Set (or, with a $null value, remove) keys of the resume state file. A run
    # record key (start time, settings, cost window) is set the same way in the
    # per-stream state files of the same run that carry a record, as the run
    # would have written them, unless -MainOnly.
    function script:Set-StateKeys
    {
        param([hashtable]$Keys, [switch]$MainOnly)
        $Raw = Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json
        $Apply = {
            param($Obj, [string[]]$Only)
            foreach ($Key in $Keys.Keys)
            {
                if ($Only -and $Only -notcontains $Key) { continue }
                if ($null -eq $Keys[$Key]) { $Obj.PSObject.Properties.Remove($Key) }
                else { $Obj | Add-Member -NotePropertyName $Key -NotePropertyValue $Keys[$Key] -Force }
            }
        }
        & $Apply $Raw $null
        $Raw | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:State -Encoding utf8
        if ($MainOnly) { return }
        $RecordKeys = @('RunStartedAt', 'RunSettings', 'ConsumptionWindowStart', 'ConsumptionWindowEnd')
        foreach ($File in @(script:Get-StreamFiles))
        {
            $Obj = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
            if ([string]$Obj.RunId -ne [string]$Raw.RunId -or $null -eq $Obj.PSObject.Properties['RunSettings']) { continue }
            & $Apply $Obj $RecordKeys
            $Obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $File.FullName -Encoding utf8
        }
    }

    # The start time the resume state file records, as the start line shows it.
    function script:Get-StateStartText
    {
        $Raw = Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json
        $When = $Raw.PSObject.Properties['RunStartedAt']
        # A version that records no start time: a text no start line holds, so
        # the test goes on to the run and fails on what the run does.
        if ($null -eq $When) { return '(no start time recorded)' }
        $When = $When.Value
        if ($When -isnot [datetime]) { $When = [datetime]::Parse([string]$When, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
        return ($When.ToUniversalTime().ToString('d MMM yyyy HH:mm', [cultureinfo]::InvariantCulture) + ' UTC')
    }

    # The lines a test reads to tell how a run started.
    function script:Get-StartLines
    {
        param($Run)
        @($Run.Text | Where-Object { $_ -like 'Starting a new run*' -or $_ -like 'Continuing the *' -or $_ -like 'The unfinished run*' -or $_ -like 'WARNING: The unfinished run*' -or $_ -like 'WARNING: The start time*' -or $_ -like 'The start time of the unfinished run*' -or $_ -like 'The resume state file was written by an earlier version*' })
    }

    # Today's cost window as '<start>..<end>' (Get-ConsumptionWindow's rule, UTC).
    function script:Get-ConsumptionWindowText
    {
        $Now = [datetime]::UtcNow
        return ('{0}..{1}' -f $Now.AddDays(-31).ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture), $Now.AddDays(-1).ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture))
    }

    $script:DefaultSettingsText = 'none of -Obfuscate, -SkipMetrics, -SkipConsumption, -IncludeDisabled'

    # An interrupted run over A to D. One stream: A and B complete, then C
    # hangs. Two streams (A and C, B and D): A and B complete, then C and D hang.
    function script:Invoke-InterruptedRun
    {
        param([int]$Streams = 1, [string[]]$Arguments = @(), [switch]$KeepLock)
        $script:HangLetters = if ($Streams -gt 1) { @('C', 'D') } else { @('C') }
        $script:InterruptStreams = $Streams
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang $script:HangLetters
        $EndWhen = {
            $Done = if ($script:InterruptStreams -gt 1) { script:Get-StreamCompletedIds } else { script:Get-StateCompleted }
            (script:Test-Hanging $script:HangLetters) -and ((@($Done) -join ',') -eq 'sub-a,sub-b')
        }
        $null = script:Invoke-Wrapper -Arguments $Arguments -Streams $Streams -EndWhen $EndWhen -KeepLock:$KeepLock
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
    }
}

AfterAll {
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'A run without -Resume continues the unfinished run' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'skips what it completed and says so; after a clean end the next run starts a new run (-ParallelStreams <Streams>)' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        script:Invoke-InterruptedRun -Streams $Streams
        $Started = script:Get-StateStartText

        $R1 = script:Invoke-Wrapper -Streams $Streams
        $R1.ExitCode | Should -Be 0
        script:Get-StartLines $R1 | Should -Be @(('Continuing the run started {0} (2 of 4 subscriptions done). Settings: {1}. Pass -Fresh to start over.' -f $Started, $script:DefaultSettingsText))
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'C', 'D')
        script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        script:Test-CleanLine $R1 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty

        # The next two runs: nothing is unfinished, so each starts a new run.
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Streams $Streams
            $R.ExitCode | Should -Be 0
            script:Get-StartLines $R | Should -Be @('Starting a new run.')
            script:Get-Collected $R | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
            script:Read-State | Should -BeNullOrEmpty
        }
    }

    It 'with -Fresh starts a new run that collects everything again, and the next run starts a new run (-ParallelStreams <Streams>)' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        script:Invoke-InterruptedRun -Streams $Streams
        $Started = script:Get-StateStartText
        $EarlierReports = @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force | Where-Object { $_.FullName -like '*ResourcesReport*' } | ForEach-Object { $_.FullName })

        $R1 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams $Streams
        $R1.ExitCode | Should -Be 0
        script:Get-StartLines $R1 | Should -Be @(('Starting a new run (-Fresh). The unfinished run started {0} is not continued: this run collects every subscription again.' -f $Started))
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        $R1.Text | Should -Not -Contain 'Skipping (already completed): Sub A (sub-a)'
        script:Read-State | Should -BeNullOrEmpty
        foreach ($Path in $EarlierReports) { Test-Path -LiteralPath $Path | Should -BeTrue -Because ('-Fresh does not delete or move {0}' -f $Path) }

        $R2 = script:Invoke-Wrapper -Streams $Streams
        $R2.ExitCode | Should -Be 0
        script:Get-StartLines $R2 | Should -Be @('Starting a new run.')
    }

    It 'a new run that is interrupted in turn drops the earlier run''s completed list, so the run that continues it collects what it did not' {
        # Run 1 completes A and B; -Fresh then completes A and is interrupted at B.
        script:Invoke-InterruptedRun -Streams 1
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'B'
        $null = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1 -EndWhen { (script:Test-Hanging 'B') -and ((script:Get-StateCompleted) -join ',') -eq 'sub-a' }
        script:Get-StateCompleted | Should -Be @('sub-a')
        $FreshStarted = script:Get-StateStartText
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'

        $R = script:Invoke-Wrapper -Streams 1
        $R.ExitCode | Should -Be 0
        script:Get-StartLines $R | Should -Be @(('Continuing the run started {0} (1 of 4 subscriptions done). Settings: {1}. Pass -Fresh to start over.' -f $FreshStarted, $script:DefaultSettingsText)) -Because 'only the -Fresh run''s completion counts'
        script:Get-Collected $R | Should -Be (script:Get-Ids 'B', 'C', 'D')
        script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
    }
}

Describe 'A run whose settings differ from the unfinished run''s stops before it collects' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'names the setting, does not sign in, collect or write the resume state, leaves only its transcript and releases its lock, and stops the same way again; the same settings continue (-ParallelStreams <Streams>)' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        script:Invoke-InterruptedRun -Streams $Streams -Arguments '-Obfuscate'
        $Started = script:Get-StateStartText
        $Before = Get-Content -LiteralPath $script:State -Raw
        # Every file but a run lock, with its content: the killed run's lock was removed with the command its stop prints, and each run here releases its own.
        $Snapshot = { @(Get-ChildItem -LiteralPath $script:Root -Force -Recurse -File | Where-Object { $_.Name -notlike '.run-lock-*' } | ForEach-Object { '{0}|{1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Sort-Object) }
        $FilesBefore = & $Snapshot
        script:Clear-Calls

        $Expected = @(
            ('ERROR: This run stops here (exit 1), before it signs in, collects anything or writes the resume state: the unfinished run started {0} used other settings than this run, and one consolidated zip must not mix them.' -f $Started)
            '  -Obfuscate: on in the unfinished run, off in this run.'
            '  Next: run the same command with the unfinished run''s settings (-Obfuscate) to continue it, or pass -Fresh to start a new run that collects every subscription again.'
        )
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Streams $Streams
            $R.ExitCode | Should -Be 1
            @($R.Text | Where-Object { $_ -like 'ERROR: This run stops here*' -or $_ -like '  -Obfuscate: *' -or $_ -like '  Next: run the same command with*' }) | Should -Be $Expected
            script:Get-Calls | Should -BeNullOrEmpty
            script:Get-UsagePaths | Should -BeNullOrEmpty -Because 'the stop comes before the up-front checks'
            Get-Content -LiteralPath $script:State -Raw | Should -Be $Before
            # What the stop leaves out: no sign-in, no collection, no resume-state
            # write. What it writes, as every run does: its transcript, and the
            # run lock, released at the stop.
            @($R.Text | Where-Object { $_ -like 'Existing session detected*' -or $_ -like 'Subscriptions visible:*' }) | Should -BeNullOrEmpty
            $FilesNow = & $Snapshot
            @($FilesBefore | Where-Object { $FilesNow -notcontains $_ }) | Should -BeNullOrEmpty -Because 'no file is changed or removed'
            $Added = @($FilesNow | Where-Object { $FilesBefore -notcontains $_ })
            $Added.Count | Should -Be 1
            $Added[0] | Should -BeLike '*RunAllSubscriptions_transcript_*'
            $FilesBefore = $FilesNow
            @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*') | Should -BeNullOrEmpty
        }

        # With -Obfuscate it continues: every subscription collected masked.
        $R3 = script:Invoke-Wrapper -Arguments '-Obfuscate' -Streams $Streams
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @(('Continuing the run started {0} (2 of 4 subscriptions done). Settings: -Obfuscate. Pass -Fresh to start over.' -f $Started))
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'C', 'D')
        @(script:Get-Calls | Where-Object { $_ -notlike '*|Obfuscate=True|*' }) | Should -BeNullOrEmpty
        script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        script:Read-State | Should -BeNullOrEmpty

        $R4 = script:Invoke-Wrapper -Streams $Streams
        $R4.ExitCode | Should -Be 0
        script:Get-StartLines $R4 | Should -Be @('Starting a new run.')
    }

    It 'with -Fresh starts a new unmasked run whose zip holds only its own reports, and the next run starts a new run' {
        script:Invoke-InterruptedRun -Streams 1 -Arguments '-Obfuscate'
        script:Clear-Calls
        $R1 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R1.ExitCode | Should -Be 0
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        @(script:Get-Calls | Where-Object { $_ -notlike '*|Obfuscate=False|*' }) | Should -BeNullOrEmpty
        @($R1.Text | Where-Object { $_ -like 'Skipping (already completed)*' }) | Should -BeNullOrEmpty
        script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        $R2 = script:Invoke-Wrapper -Streams 1
        $R2.ExitCode | Should -Be 0
        script:Get-StartLines $R2 | Should -Be @('Starting a new run.')
    }

    It 'stops for settings it cannot read (<Case>), and -Fresh starts a new run' -ForEach @(
        @{ Case = 'not an object'; Value = 'yes'; Problem = 'they are not a JSON object' }
        @{ Case = 'a value that is text'; Value = [pscustomobject]@{ Obfuscate = 'true'; SkipMetrics = $false; SkipConsumption = $false; IncludeDisabled = $false }; Problem = 'Obfuscate is not true or false' }
        @{ Case = 'a setting left out'; Value = [pscustomobject]@{ Obfuscate = $false; SkipMetrics = $false; SkipConsumption = $false }; Problem = 'IncludeDisabled is not recorded' }
    ) {
        script:Invoke-InterruptedRun -Streams 1
        script:Set-StateKeys @{ RunSettings = $Value }
        $Before = Get-Content -LiteralPath $script:State -Raw
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Streams 1
            $R.ExitCode | Should -Be 1
            $R.Text | Should -Contain ('ERROR: This run stops here (exit 1), before it signs in, collects anything or writes the resume state: the resume state file records the settings of the unfinished run, but they cannot be read ({0}), so this run cannot check that it collects the same way.' -f $Problem)
            Get-Content -LiteralPath $script:State -Raw | Should -Be $Before
        }
        $R3 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
    }
}

Describe 'The age of the unfinished run' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It '<Days> days old, <Label>: <Outcome>' -ForEach @(
        @{ Days = 6; Label = 'no switch'; Arguments = @(); Outcome = 'continues' }
        @{ Days = 8; Label = 'no switch'; Arguments = @(); Outcome = 'starts a new run' }
        @{ Days = 8; Label = '-Resume'; Arguments = @('-Resume'); Outcome = 'continues with a warning' }
        @{ Days = 8; Label = '-ResumeMaxAgeDays 10'; Arguments = @('-ResumeMaxAgeDays', '10'); Outcome = 'continues' }
        @{ Days = 8; Label = 'no switch and -Obfuscate'; Arguments = @('-Obfuscate'); Outcome = 'starts a new run' }
    ) {
        script:Invoke-InterruptedRun -Streams 1
        script:Set-StateKeys @{ RunStartedAt = ([datetime]::UtcNow.AddDays(-$Days).ToString('o', [cultureinfo]::InvariantCulture)) }
        $Started = script:Get-StateStartText
        $EarlierReports = @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force | Where-Object { $_.FullName -like '*ResourcesReport*' } | ForEach-Object { $_.FullName })
        $EarlierReports.Count | Should -BeGreaterThan 5 -Because 'the interrupted run wrote the folders and zips of A and B'
        $R = script:Invoke-Wrapper -Arguments $Arguments -Streams 1
        $R.ExitCode | Should -Be 0
        $Continue = 'Continuing the run started {0} (2 of 4 subscriptions done). Settings: {1}. Pass -Fresh to start over.' -f $Started, $script:DefaultSettingsText
        switch ($Outcome)
        {
            'continues'
            {
                script:Get-StartLines $R | Should -Be @($Continue)
                script:Get-Collected $R | Should -Be (script:Get-Ids 'C', 'D')
            }
            'starts a new run'
            {
                script:Get-StartLines $R | Should -Be @(('The unfinished run started {0}, more than 7 days ago; starting a new run. Pass -Resume to continue it anyway.' -f $Started))
                script:Get-Collected $R | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
                # The earlier run's report folders and zips stay on disk.
                foreach ($Path in $EarlierReports) { Test-Path -LiteralPath $Path | Should -BeTrue -Because ('the new run does not delete or move {0}' -f $Path) }
            }
            'continues with a warning'
            {
                script:Get-StartLines $R | Should -Be @(
                    ('WARNING: The unfinished run started {0}, more than 7 days ago. This run continues it because -Resume was passed; the metrics of the subscriptions it collects cover a later period than those collected earlier in that run.' -f $Started)
                    $Continue
                )
                script:Get-Collected $R | Should -Be (script:Get-Ids 'C', 'D')
            }
        }
        script:Read-State | Should -BeNullOrEmpty
        $Next = script:Invoke-Wrapper -Streams 1
        $Next.ExitCode | Should -Be 0
        script:Get-StartLines $Next | Should -Be @('Starting a new run.')
    }

    It 'a start time that is <Case> is treated as past the limit: a run without -Resume starts a new run, -Resume continues with a warning' -ForEach @(
        @{ Case = 'not a date'; Value = 'yesterday'; Problem = 'The start time of the unfinished run cannot be read from the resume state file (it is not a date), so its age is not known' }
        @{ Case = 'a number'; Value = 12; Problem = 'The start time of the unfinished run cannot be read from the resume state file (it is not a date), so its age is not known' }
        @{ Case = 'missing'; Value = $null; Problem = 'The start time of the unfinished run cannot be read from the resume state file (it is not recorded), so its age is not known' }
    ) {
        foreach ($Given in '-Resume', 'none')
        {
            script:New-Case
            script:Invoke-InterruptedRun -Streams 1
            script:Set-StateKeys @{ RunStartedAt = $Value }
            $Arguments = if ($Given -eq 'none') { @() } else { @($Given) }
            $R = script:Invoke-Wrapper -Arguments $Arguments -Streams 1
            $R.ExitCode | Should -Be 0
            if ($Given -eq 'none')
            {
                script:Get-StartLines $R | Should -Be @(('{0}; starting a new run. Pass -Resume to continue it anyway.' -f $Problem))
                script:Get-Collected $R | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
            }
            else
            {
                script:Get-StartLines $R | Should -Be @(
                    ('WARNING: {0}. This run continues it because -Resume was passed; the metrics of the subscriptions it collects cover a later period than those collected earlier in that run.' -f $Problem)
                    ('Continuing the unfinished run (its start time cannot be read; 2 of 4 subscriptions done). Settings: {0}. Pass -Fresh to start over.' -f $script:DefaultSettingsText)
                )
                script:Get-Collected $R | Should -Be (script:Get-Ids 'C', 'D')
            }
            script:Read-State | Should -BeNullOrEmpty
        }
    }
}

Describe 'The cost window of a continued run' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'is the one the run recorded at its start, for the up-front check and every subscription (-ParallelStreams <Streams>)' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        script:Invoke-InterruptedRun -Streams $Streams
        $Raw = Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json
        $Today = script:Get-ConsumptionWindowText
        "$($Raw.ConsumptionWindowStart)..$($Raw.ConsumptionWindowEnd)" | Should -Be $Today -Because 'a new run records its window at its start'
        # As if the run had started three days ago, and is continued now.
        script:Set-StateKeys @{ RunStartedAt = [datetime]::UtcNow.AddDays(-3).ToString('o', [cultureinfo]::InvariantCulture); ConsumptionWindowStart = '2026-01-01'; ConsumptionWindowEnd = '2026-01-31' }
        script:Clear-Calls
        $R = script:Invoke-Wrapper -Streams $Streams
        $R.ExitCode | Should -Be 0
        $R.Text | Should -Contain 'Cost window: 2026-01-01 to 2026-01-31, recorded when the run started.'
        script:Get-Collected $R | Should -Be (script:Get-Ids 'C', 'D')
        @(script:Get-Calls | ForEach-Object { ($_ -split '\|')[-1] } | Sort-Object -Unique) | Should -Be @('Window=2026-01-01..2026-01-31')
        @(script:Get-Calls).Count | Should -Be 2
        @(script:Get-UsagePaths).Count | Should -BeGreaterThan 0
        @(script:Get-UsagePaths | Where-Object { $_ -notmatch 'reportedStartTime=2026-01-01' -or $_ -notmatch 'reportedEndTime=2026-01-31' }) | Should -BeNullOrEmpty
    }

    It 'that is <Case> is replaced by today''s, with a warning, and recorded for the runs after it' -ForEach @(
        @{ Case = 'not a date'; Start = '2026-13-01'; End = '2026-01-31'; Problem = 'it is not two yyyy-MM-dd dates, the start not after the end' }
        @{ Case = 'the wrong way round'; Start = '2026-02-01'; End = '2026-01-01'; Problem = 'it is not two yyyy-MM-dd dates, the start not after the end' }
        @{ Case = 'missing'; Start = $null; End = $null; Problem = 'it is not recorded' }
    ) {
        script:Invoke-InterruptedRun -Streams 1
        script:Set-StateKeys @{ ConsumptionWindowStart = $Start; ConsumptionWindowEnd = $End }
        script:Clear-Calls
        # Stop the continued run once C is collected, so the next run reads what it recorded.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'D'
        $Today = script:Get-ConsumptionWindowText
        $R = script:Invoke-Wrapper -Streams 1 -EndWhen { (script:Test-Hanging 'D') -and ((script:Get-StateCompleted) -join ',') -eq 'sub-a,sub-b,sub-c' }
        $R.Text | Should -Contain ('WARNING: The resume state file holds no cost window this run can use ({0}), so this run uses today''s: {1}. Subscriptions collected earlier in the run may cover other days.' -f $Problem, ($Today -replace '\.\.', ' to '))
        $Raw = Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json
        "$($Raw.ConsumptionWindowStart)..$($Raw.ConsumptionWindowEnd)" | Should -Be $Today
        $Raw.RunSettings.Obfuscate | Should -BeFalse
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Streams 1
        $R2.ExitCode | Should -Be 0
        $R2.Text | Should -Contain ('Cost window: {0}, recorded when the run started.' -f ($Today -replace '\.\.', ' to '))
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'D')
    }
}

Describe '-ResumeFailedOnly with no unfinished run, and -Fresh with -Resume' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It '-ResumeFailedOnly stops with exit 1 and starts nothing, twice; then a run without it starts a new run' {
        script:Set-Scenario -Subs 'A', 'B'
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
            $R.ExitCode | Should -Be 1
            $R.Text | Should -Contain 'ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry. No resume state file for this tenant is in the inventory folder, so there is no retry list. It did not sign in, collect anything or write the resume state.'
            $R.Text | Should -Contain '  Next: run the same command without -ResumeFailedOnly. It starts a new run that collects every subscription.'
            $R.Text | Should -Not -Contain 'ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry.'
            script:Get-Collected $R | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:State | Should -BeFalse
            @($R.Text | Where-Object { $_ -like 'Existing session detected*' -or $_ -like 'Subscriptions visible:*' }) | Should -BeNullOrEmpty -Because 'the stop comes before sign-in'
        }
        $R3 = script:Invoke-Wrapper -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @('Starting a new run.')
    }

    It '-ResumeFailedOnly with a resume state file that is <Case> stops with exit 1 and says the file cannot be read' -ForEach @(@{ Case = 'empty'; Content = '' }, @{ Case = 'not JSON'; Content = '{ cut' }) {
        script:Set-Scenario -Subs 'A', 'B'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-Content -LiteralPath $script:State -Value $Content -NoNewline
        $R = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        $R.ExitCode | Should -Be 1
        $R.Text | Should -Contain 'ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry. The resume state file for this tenant cannot be read (it is empty, not JSON, or for another tenant), so there is no retry list. It did not sign in, collect anything or write the resume state.'
        script:Get-Collected $R | Should -BeNullOrEmpty
    }

    It '-Fresh with <Other> stops with exit 1 before it signs in, collects anything or writes the resume state' -ForEach @(@{ Other = '-Resume' }, @{ Other = '-ResumeFailedOnly' }) {
        script:Invoke-InterruptedRun -Streams 1
        $Before = Get-Content -LiteralPath $script:State -Raw
        $R = script:Invoke-Wrapper -Arguments '-Fresh', $Other -Streams 1
        $R.ExitCode | Should -Be 1
        $R.Text | Should -Contain ('ERROR: -Fresh starts a new run and {0} continues the unfinished one, so they cannot be used together. This run stops here (exit 1), before it signs in, collects anything or writes the resume state.' -f $Other)
        script:Get-Collected $R | Should -BeNullOrEmpty
        Get-Content -LiteralPath $script:State -Raw | Should -Be $Before
    }

    It '-ResumeFailedOnly continues the unfinished run, with its start line, and retries only its retry list' {
        script:Set-Scenario -Subs 'A', 'B', 'C' -Fail 'B' -Hang 'C'
        $null = script:Invoke-Wrapper -Streams 1 -EndWhen { (script:Test-Hanging 'C') -and (script:Read-State).Failed -contains 'sub-b' }
        $Started = script:Get-StateStartText
        script:Set-Scenario -Subs 'A', 'B', 'C'
        $R = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        script:Get-StartLines $R | Should -Be @(('Continuing the run started {0} (1 of 3 subscriptions done). Settings: {1}. To start over, run the same command without -ResumeFailedOnly, with -Fresh.' -f $Started, $script:DefaultSettingsText))
        script:Get-Collected $R | Should -Be (script:Get-Ids 'B')
    }
}

Describe 'A resume state file written before runs recorded their start time and settings' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'is continued with a line that says neither can be checked, and the run records both for the runs after it' {
        script:Invoke-InterruptedRun -Streams 1
        script:Set-StateKeys @{ RunStartedAt = $null; RunSettings = $null; ConsumptionWindowStart = $null; ConsumptionWindowEnd = $null }
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'D'
        $R1 = script:Invoke-Wrapper -Streams 1 -EndWhen { (script:Test-Hanging 'D') -and ((script:Get-StateCompleted) -join ',') -eq 'sub-a,sub-b,sub-c' }
        script:Get-StartLines $R1 | Should -Be @(
            'The resume state file was written by an earlier version, which did not record when its run started, with which settings or which cost window, so this run cannot check them. It continues that run, as -Resume does, uses its own cost window, and records its own start time, settings and cost window in the file once it starts collecting.'
            ('Continuing the unfinished run (its start time is not recorded; 2 of 4 subscriptions done). Settings: {0}. Pass -Fresh to start over.' -f $script:DefaultSettingsText)
        )
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'C', 'D')
        $Raw = Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json
        $Raw.RunSettings.Obfuscate | Should -BeFalse
        $Raw.PSObject.Properties['RunStartedAt'] | Should -Not -BeNullOrEmpty
        # The next run checks them: other settings stop it.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Obfuscate' -Streams 1
        $R2.ExitCode | Should -Be 1
        $R2.Text | Should -Contain '  -Obfuscate: off in the unfinished run, on in this run.'
        $R3 = script:Invoke-Wrapper -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'D')
    }
}

Describe 'Resume by default under strict mode' -Skip:$IsWindows {
    BeforeAll {
        # The strict-mode errors that older code on these paths prints (the role
        # check, the consumption check, the end-of-run summary): each is the file
        # and the start of the source line the error quotes. Any other error,
        # whatever variable it names, fails the test.
        $script:KnownStrictErrors = @(
            'Common.Functions.ps1|if ($RoleRecord.Failed)'
            'Common.Functions.ps1|if ($CheckResult.Failed)'
            'Run-AllSubscriptions.ps1|if ($ConsumptionRecords -gt 0 -or $ConsumptionFailures.Count -gt 0)'
            'Run-AllSubscriptions.ps1|if ($ConsumptionFailures.Count -gt 0)'
            'Run-AllSubscriptions.ps1|if ($MetricsFailures.Count -gt 0)'
            'Run-AllSubscriptions.ps1|if ($CollectorFailuresList.Count -gt 0)'
            'Run-AllSubscriptions.ps1|if ($ConsumptionAuthSkipped.Count -gt 0)'
            'Run-AllSubscriptions.ps1|if ($MetricsAuthSkipped.Count -gt 0)'
            # Reached by the one-subscription, two-stream and empty-retry-list runs below.
            'Run-AllSubscriptions.ps1|if ($FailedAttempts.Count -eq 0)'
            'Run-AllSubscriptions.ps1|if ($ScopeForProbe.Count -gt 0)'
            'Run-AllSubscriptions.ps1|if (-not $SkipConsumption -and $ConsumptionCheckScope.Count -gt 0)'
            'Run-AllSubscriptions.ps1|elseif (($FailedAttempts.Count - $RetryLimited.Count) -gt 0)'
        )
        # Every strict-mode error a run printed on stderr, as '<file>|<source line>',
        # and every collection error it printed on stdout.
        function script:Get-StrictErrors
        {
            param($Run)
            $Found = [System.Collections.Generic.List[string]]::new()
            $File = $null
            foreach ($Line in @(([string]$Run.Error) -split "`r?`n"))
            {
                $Plain = $Line -replace "`e\[[0-9;]*m", ''
                if ($Plain -match '^\S+Exception: (.+):(\d+)\s*$' -or $Plain -match '^\S+: (/.+\.ps1):(\d+)\s*$') { $File = Split-Path -Path $Matches[1] -Leaf; continue }
                if ($null -ne $File -and $Plain -match '^\s*\d+ \|\s(.*)$')
                {
                    $Found.Add(('{0}|{1}' -f $File, $Matches[1].Trim().TrimEnd([char]0x2026).TrimEnd()))
                    $File = $null
                }
            }
            foreach ($Line in @($Run.Text | Where-Object { $_ -match '^(\[stream-\d+\] )?ERROR processing subscription ' }))
            {
                # The exit code read after each subscription, older code.
                if ($Line -notmatch "The variable '\`$LASTEXITCODE' cannot be retrieved because it has not been set\.$") { $Found.Add('stdout|' + $Line) }
            }
            return $Found.ToArray()
        }
        function script:Get-UnknownStrictErrors
        {
            param($Run)
            @(script:Get-StrictErrors $Run | Where-Object { $E = $_; @($script:KnownStrictErrors | Where-Object { $E -eq $_ -or $E.StartsWith($_) -or $_.StartsWith($E) }).Count -eq 0 })
        }
    }
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'the paths this change adds print no strict-mode error outside the known older-code list: a stop for settings, a continued run, -Fresh, -ResumeFailedOnly with nothing owed, and a continued wrongly shaped state file' {
        script:Invoke-InterruptedRun -Streams 1
        $Started = script:Get-StateStartText
        $Stop = script:Invoke-Wrapper -Arguments '-Obfuscate' -Streams 1 -StrictMode
        $Stop.ExitCode | Should -Be 1
        # Older code on these paths still prints strict-mode errors (above), so
        # the exit codes of the runs that pass it are not asserted here.
        $Continue = script:Invoke-Wrapper -Streams 1 -StrictMode
        script:Get-StartLines $Continue | Should -Be @(('Continuing the run started {0} (2 of 4 subscriptions done). Settings: {1}. Pass -Fresh to start over.' -f $Started, $script:DefaultSettingsText))
        # The continued run ends clean and removes the state, so an interrupted
        # run comes first: -Fresh is then given an unfinished run to start over.
        script:Invoke-InterruptedRun -Streams 1
        $New = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1 -StrictMode
        @(script:Get-StartLines $New)[0] | Should -BeLike 'Starting a new run (-Fresh).*'
        $NoRun = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1 -StrictMode
        # A state file that is not the right shape, continued.
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-Content -LiteralPath $script:State -Value ('{"TenantID": "' + $script:Tenant + '", "CompletedSubscriptionIds": "sub-x", "FailedAttempts": []}') -Encoding utf8
        $Shape = script:Invoke-Wrapper -Streams 1 -StrictMode
        @($Shape.Text | Where-Object { $_ -like 'WARNING: The resume state file*is not the right shape*' }).Count | Should -Be 1
        # A continued run with two streams; a run over one subscription; and
        # -ResumeFailedOnly over a kept state with an empty retry list.
        script:New-Case
        script:Invoke-InterruptedRun -Streams 2
        $Two = script:Invoke-Wrapper -Streams 2 -StrictMode
        script:New-Case
        script:Set-Scenario -Subs 'A'
        $One = script:Invoke-Wrapper -Streams 2 -StrictMode
        script:New-Case
        script:Invoke-InterruptedRun -Streams 1
        $EmptyList = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1 -StrictMode
        foreach ($R in $Stop, $Continue, $New, $NoRun, $Shape, $Two, $One, $EmptyList)
        {
            script:Get-UnknownStrictErrors $R | Should -BeNullOrEmpty
        }
    }

    It 'the check finds an error on a line it does not know' {
        $Fake = [pscustomobject]@{ Text = @('ERROR processing subscription Sub A: The property ''Removed'' cannot be found on this object.'); Error = "PropertyNotFoundException: /x/tool/Run-AllSubscriptions.ps1:1020`nLine |`n1020 |      foreach (`$Entry in `$NoRole.Removed)`n     |                         ~~~~~~~~`n" }
        @(script:Get-UnknownStrictErrors $Fake).Count | Should -Be 2
        $Known = [pscustomobject]@{ Text = @(); Error = "PropertyNotFoundException: /x/tool/Functions/Common.Functions.ps1:942`nLine |`n 942 |          if (`$RoleRecord.Failed)`n     |              ~~~~~`n" }
        script:Get-UnknownStrictErrors $Known | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-RunStart and its readers' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
        $script:Now = [datetime]::new(2026, 10, 30, 12, 0, 0, [System.DateTimeKind]::Utc)
        $script:Default = Get-RunDataSettings
        function script:New-Info { param($StartedAt = $script:Now.AddDays(-1), $Settings = $script:Default, [switch]$Legacy, [switch]$Missing, $SettingsProblem)
            [pscustomobject]@{ Exists = -not $Missing; Legacy = [bool]$Legacy; StartedAt = $StartedAt; StartedAtProblem = $(if ($null -eq $StartedAt) { 'it is not a date' }); Settings = $Settings; SettingsProblem = $SettingsProblem; Window = $null; WindowProblem = 'it is not recorded'; Values = [ordered]@{} } }
    }

    It '<Label> -> <Mode>' -ForEach @(
        @{ Label = 'no file, no switch'; Info = { script:New-Info -Missing }; Switches = @{}; Mode = 'New'; Reason = 'none' }
        @{ Label = 'only per-stream files, no switch'; Info = { $I = script:New-Info -Missing -Legacy; $I | Add-Member -NotePropertyName StreamOnly -NotePropertyValue $true -Force; $I }; Switches = @{}; Mode = 'Continue'; Reason = 'stream-only' }
        @{ Label = 'only per-stream files, -ResumeFailedOnly'; Info = { $I = script:New-Info -Missing -Legacy; $I | Add-Member -NotePropertyName StreamOnly -NotePropertyValue $true -Force; $I }; Switches = @{ ResumeFailedOnly = $true }; Mode = 'Continue'; Reason = 'stream-only' }
        @{ Label = 'only per-stream files, -Fresh'; Info = { $I = script:New-Info -Missing -Legacy; $I | Add-Member -NotePropertyName StreamOnly -NotePropertyValue $true -Force; $I }; Switches = @{ Fresh = $true }; Mode = 'New'; Reason = 'none' }
        @{ Label = 'no file, -Resume'; Info = { script:New-Info -Missing }; Switches = @{ Resume = $true }; Mode = 'New'; Reason = 'none' }
        @{ Label = 'no file, -ResumeFailedOnly'; Info = { script:New-Info -Missing }; Switches = @{ ResumeFailedOnly = $true }; Mode = 'Stop'; Reason = 'nothing-to-retry' }
        @{ Label = 'a run, no switch'; Info = { script:New-Info }; Switches = @{}; Mode = 'Continue'; Reason = 'continue' }
        @{ Label = 'a run, -Fresh'; Info = { script:New-Info }; Switches = @{ Fresh = $true }; Mode = 'New'; Reason = 'fresh' }
        @{ Label = 'a run, -Fresh -Resume'; Info = { script:New-Info }; Switches = @{ Fresh = $true; Resume = $true }; Mode = 'Stop'; Reason = 'fresh-with-resume' }
        @{ Label = 'no file, -Fresh -ResumeFailedOnly'; Info = { script:New-Info -Missing }; Switches = @{ Fresh = $true; ResumeFailedOnly = $true }; Mode = 'Stop'; Reason = 'fresh-with-resume' }
        @{ Label = 'exactly 7 days old'; Info = { script:New-Info -StartedAt $script:Now.AddDays(-7) }; Switches = @{}; Mode = 'Continue'; Reason = 'continue' }
        @{ Label = '7 days and a minute old'; Info = { script:New-Info -StartedAt $script:Now.AddDays(-7).AddMinutes(-1) }; Switches = @{}; Mode = 'New'; Reason = 'too-old' }
        @{ Label = 'two days in the future'; Info = { script:New-Info -StartedAt $script:Now.AddDays(2) }; Switches = @{}; Mode = 'New'; Reason = 'too-old' }
        @{ Label = 'an hour in the future'; Info = { script:New-Info -StartedAt $script:Now.AddHours(1) }; Switches = @{}; Mode = 'Continue'; Reason = 'continue' }
        @{ Label = 'old, -ResumeFailedOnly'; Info = { script:New-Info -StartedAt $script:Now.AddDays(-9) }; Switches = @{ ResumeFailedOnly = $true }; Mode = 'Continue'; Reason = 'old-explicit' }
        @{ Label = 'old, -Resume, other settings'; Info = { script:New-Info -StartedAt $script:Now.AddDays(-9) }; Switches = @{ Resume = $true; Obfuscate = $true }; Mode = 'Stop'; Reason = 'settings-differ' }
        @{ Label = 'old, no switch, other settings'; Info = { script:New-Info -StartedAt $script:Now.AddDays(-9) }; Switches = @{ Obfuscate = $true }; Mode = 'New'; Reason = 'too-old' }
        @{ Label = 'other settings, -ResumeFailedOnly'; Info = { script:New-Info }; Switches = @{ ResumeFailedOnly = $true; SkipMetrics = $true }; Mode = 'Stop'; Reason = 'settings-differ' }
        @{ Label = 'unreadable settings'; Info = { script:New-Info -Settings $null -SettingsProblem 'they are not a JSON object' }; Switches = @{}; Mode = 'Stop'; Reason = 'settings-unreadable' }
        @{ Label = 'a file that is not the right shape, other settings'; Info = { $I = script:New-Info -Settings $null -SettingsProblem 'they are not recorded'; $I | Add-Member -NotePropertyName ShapeProblem -NotePropertyValue 'FailedAttempts is not a list' -Force; $I }; Switches = @{ Obfuscate = $true }; Mode = 'Continue'; Reason = 'wrong-shape' }
        @{ Label = 'an earlier version''s file, other settings'; Info = { script:New-Info -Legacy -StartedAt $null -Settings $null -SettingsProblem 'they are not recorded' }; Switches = @{ Obfuscate = $true }; Mode = 'Continue'; Reason = 'legacy' }
    ) {
        $Settings = Get-RunDataSettings -Obfuscate ([bool]$Switches.Obfuscate) -SkipMetrics ([bool]$Switches.SkipMetrics)
        $D = Resolve-RunStart -Info (& $Info) -Resume ([bool]$Switches.Resume) -ResumeFailedOnly ([bool]$Switches.ResumeFailedOnly) -Fresh ([bool]$Switches.Fresh) -Settings $Settings -Now $script:Now
        $D.Mode | Should -Be $Mode
        $D.Reason | Should -Be $Reason
        $D.ExitCode | Should -Be $(if ($Mode -eq 'Stop') { 1 } else { 0 })
    }

    It 'names every differing setting with the stored and the given value' {
        $Stored = Get-RunDataSettings -Obfuscate $true -IncludeDisabled $true
        $D = Resolve-RunStart -Info (script:New-Info -Settings $Stored) -Settings (Get-RunDataSettings -SkipConsumption $true) -Now $script:Now
        @($D.Lines | ForEach-Object Text | Where-Object { $_ -like '  -*' }) | Should -Be @(
            '  -Obfuscate: on in the unfinished run, off in this run.'
            '  -SkipConsumption: off in the unfinished run, on in this run.'
            '  -IncludeDisabled: on in the unfinished run, off in this run.'
        )
        @($D.Lines | ForEach-Object Text)[-1] | Should -Be '  Next: run the same command with the unfinished run''s settings (-Obfuscate -IncludeDisabled) to continue it, or pass -Fresh to start a new run that collects every subscription again.'
    }

    It 'ConvertFrom-ResumeRunStartTime reads <Case>' -ForEach @(
        @{ Case = 'a UTC date'; Value = [datetime]::new(2026, 10, 1, 8, 30, 0, [System.DateTimeKind]::Utc); Expected = '2026-10-01T08:30:00Z' }
        @{ Case = 'a text with an offset'; Value = '2026-10-01T10:30:00+02:00'; Expected = '2026-10-01T08:30:00Z' }
        @{ Case = 'a text with no offset, as UTC'; Value = '2026-10-01T08:30:00'; Expected = '2026-10-01T08:30:00Z' }
        @{ Case = 'a text that is not a date'; Value = 'soon'; Expected = $null }
        @{ Case = 'a number'; Value = 5; Expected = $null }
        @{ Case = 'nothing'; Value = $null; Expected = $null }
    ) {
        $When = ConvertFrom-ResumeRunStartTime -Value $Value
        if ($null -eq $Expected) { $When | Should -BeNullOrEmpty }
        else { $When.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture) | Should -Be $Expected; $When.Kind | Should -Be 'Utc' }
    }

    It 'Read-ResumeRunInfo reads a file with every key, and tells an earlier version''s file and a malformed window apart' {
        $Dir = Join-Path $script:TestBase ('unit-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $File = Join-Path $Dir 'state.json'
        $Tenant = '12345678-1234-1234-1234-123456789012'
        $Info = New-ResumeRunInfo -StartedAt $script:Now -Settings (Get-RunDataSettings -Obfuscate $true) -Window (Get-ConsumptionWindow -Now $script:Now)
        ([pscustomobject](@{ TenantID = $Tenant; CompletedSubscriptionIds = @() } + $Info)) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $File
        $R = Read-ResumeRunInfo -Path $File -Tenant $Tenant
        $R.Exists | Should -BeTrue
        $R.Legacy | Should -BeFalse
        $R.StartedAt | Should -Be $script:Now
        $R.Settings.Obfuscate | Should -BeTrue
        Format-ConsumptionWindow -Window $R.Window | Should -Be '2026-09-29 to 2026-10-29'
        (Read-ResumeRunInfo -Path $File -Tenant 'another-tenant').Exists | Should -BeFalse

        @{ TenantID = $Tenant; CompletedSubscriptionIds = @() } | ConvertTo-Json | Set-Content -LiteralPath $File
        $R = Read-ResumeRunInfo -Path $File -Tenant $Tenant
        $R.Legacy | Should -BeTrue
        $R.WindowProblem | Should -Be 'it is not recorded'

        ([pscustomobject](@{ TenantID = $Tenant; CompletedSubscriptionIds = @(); ConsumptionWindowStart = 20260101; ConsumptionWindowEnd = '2026-01-31' } + @{ RunStartedAt = $Info.RunStartedAt; RunSettings = $Info.RunSettings })) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $File
        $R = Read-ResumeRunInfo -Path $File -Tenant $Tenant
        $R.Window | Should -BeNullOrEmpty
        $R.WindowProblem | Should -Be 'it is not two yyyy-MM-dd dates, the start not after the end'

        Set-Content -LiteralPath $File -Value '{ not json'
        (Read-ResumeRunInfo -Path $File -Tenant $Tenant).Exists | Should -BeFalse
    }

    It 'Write-StreamState writes through a temporary file: a write cut short leaves the earlier per-stream file whole' {
        $Dir = Join-Path $script:TestBase ('unit-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $File = Join-Path $Dir '.resume-state-t-stream-0.json'
        $TenantID = 't'; $StreamId = '0'; $RunId = 'run-1'
        $StreamRunRecord = [pscustomobject]@{ RunStartedAt = '2026-10-30T12:00:00.0000000Z'; RunSettings = [pscustomobject]@{ Obfuscate = $false; SkipMetrics = $true; SkipConsumption = $false; IncludeDisabled = $false }; ConsumptionWindowStart = '2026-09-29'; ConsumptionWindowEnd = '2026-10-29' }
        Write-StreamState -Path $File -Completed @('sub-a') -FailedAttempts @() -Reports @()
        $Earlier = [System.IO.File]::ReadAllBytes($File)
        $Written = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json
        $Written.RunSettings.SkipMetrics | Should -BeTrue
        $Written.ConsumptionWindowEnd | Should -Be '2026-10-29'
        # A write that puts '{' where it writes and then fails, as on a full disk.
        function Set-Content { param([string]$Path, $Value, $Encoding, $ErrorAction) [System.IO.File]::WriteAllText($Path, '{'); throw [System.IO.IOException]::new('No space left on device') }
        Write-StreamState -Path $File -Completed @('sub-a', 'sub-b') -FailedAttempts @() -Reports @() 6>$null
        [System.IO.File]::ReadAllBytes($File) | Should -Be $Earlier
        Test-Path -LiteralPath "$File.tmp" | Should -BeFalse
    }

    It 'every save of the resume state keeps the start time, settings and cost window the file holds' {
        $Dir = Join-Path $script:TestBase ('unit-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $File = Join-Path $Dir 'state.json'
        $Tenant = '12345678-1234-1234-1234-123456789012'
        Set-ResumeStateRunId -Path $File -Tenant $Tenant -RunId 'run-1' -RunInfo (New-ResumeRunInfo -StartedAt $script:Now -Settings (Get-RunDataSettings -SkipMetrics $true) -Window (Get-ConsumptionWindow -Now $script:Now)) -NewRun
        Save-CompletedSubscriptionIds -Path $File -Tenant $Tenant -Ids @('sub-a') -RunId 'run-1'
        Update-ResumeStateRetryList -Path $File -Tenant $Tenant -Ids @('sub-a') -FailedAttempts @()
        $R = Read-ResumeRunInfo -Path $File -Tenant $Tenant
        $R.StartedAt | Should -Be $script:Now
        $R.Settings.SkipMetrics | Should -BeTrue
        Format-ConsumptionWindow -Window $R.Window | Should -Be '2026-09-29 to 2026-10-29'
        # A new run's start-of-run write empties the completed list and its reports.
        Set-ResumeStateRunId -Path $File -Tenant $Tenant -RunId 'run-2' -NewRun
        (Get-Content -LiteralPath $File -Raw | ConvertFrom-Json).CompletedSubscriptionIds | Should -BeNullOrEmpty
    }
}

Describe 'The next runs after each case, with the exit of every run' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'a subscription past the retry limit: every run that continues ends with exit 2 and names -Fresh; -Fresh collects it' {
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $Exits = @()
        # Runs 1 to 3: B fails each time (the third makes it past the limit).
        foreach ($N in 1, 2, 3) { $Exits += (script:Invoke-Wrapper -Streams 1).ExitCode }
        $Exits | Should -Be @(2, 2, 2)
        $Started = script:Get-StateStartText
        # Runs 4 and 5 continue the same run, skip B and end with exit 2.
        foreach ($N in 4, 5)
        {
            $R = script:Invoke-Wrapper -Streams 1
            $R.ExitCode | Should -Be 2
            script:Get-StartLines $R | Should -Be @(('Continuing the run started {0} (1 of 2 subscriptions done, 1 past the retry limit). Settings: {1}. Pass -Fresh to start over.' -f $Started, $script:DefaultSettingsText))
            script:Get-Collected $R | Should -BeNullOrEmpty
            $R.Text | Should -Contain 'Not retried: Sub B (sub-b) failed 3 runs in a row; last reason: stand-in failure for this subscription. To try it again, start a new run with -Fresh (it collects every subscription again); a run that continues this one, with or without -Resume, does not collect it.'
            $R.Text | Should -Contain '  To try them again, start a new run with -Fresh (it collects every subscription again), for example:'
            $R.Text | Should -Contain ('    ./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh' -f $script:Tenant)
            Test-Path -LiteralPath $script:State | Should -BeTrue
        }
        # Run 6: -Fresh with B fixed collects both and ends clean; run 7 starts a new run.
        script:Set-Scenario -Subs 'A', 'B'
        $R6 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R6.ExitCode | Should -Be 0
        script:Get-Collected $R6 | Should -Be (script:Get-Ids 'A', 'B')
        script:Read-State | Should -BeNullOrEmpty
        $R7 = script:Invoke-Wrapper -Streams 1
        $R7.ExitCode | Should -Be 0
        script:Get-StartLines $R7 | Should -Be @('Starting a new run.')
    }

    It 'a subscription the signed-in identity cannot read: each run is a new run that skips it and ends with exit 0, with no state kept' {
        script:Set-Scenario -Subs 'A', 'B' -Denied 'B'
        foreach ($N in 1, 2, 3)
        {
            $R = script:Invoke-Wrapper -Streams 1
            $R.ExitCode | Should -Be 0
            script:Get-StartLines $R | Should -Be @('Starting a new run.')
            script:Get-Collected $R | Should -Be (script:Get-Ids 'A')
            $R.Text | Should -Contain '  To include them, fix the access as the start of the run says, then re-run.'
            script:Read-State | Should -BeNullOrEmpty
        }
    }

    It 'a run lock left by a killed run stops the next run with exit 1 and the remove command; after it the run continues, and the next run starts a new run' {
        script:Invoke-InterruptedRun -Streams 1 -KeepLock
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*').Count | Should -Be 1
        $Started = script:Get-StateStartText
        $Before = Get-Content -LiteralPath $script:State -Raw
        $R0 = script:Invoke-Wrapper -Streams 1
        $R0.ExitCode | Should -Be 1
        @($R0.Text | Where-Object { $_ -like 'ERROR: Another run for tenant * holds the lock on this inventory folder*' }).Count | Should -Be 1
        @($R0.Text | Where-Object { $_ -like '  That run is no longer running*' }).Count | Should -Be 1
        script:Get-Collected $R0 | Should -BeNullOrEmpty
        script:Get-StartLines $R0 | Should -BeNullOrEmpty -Because 'the lock is taken before the resume state is read'
        Get-Content -LiteralPath $script:State -Raw | Should -Be $Before
        $Remove = @($R0.Text | Where-Object { $_ -match '^    Remove-Item -LiteralPath ' })
        $Remove.Count | Should -Be 1
        & ([scriptblock]::Create($Remove[0].Trim()))
        $R1 = script:Invoke-Wrapper -Streams 1
        $R1.ExitCode | Should -Be 0
        script:Get-StartLines $R1 | Should -Be @(('Continuing the run started {0} (2 of 4 subscriptions done). Settings: {1}. Pass -Fresh to start over.' -f $Started, $script:DefaultSettingsText))
        $R2 = script:Invoke-Wrapper -Streams 1
        $R2.ExitCode | Should -Be 0
        script:Get-StartLines $R2 | Should -Be @('Starting a new run.')
    }

    It 'two runs at once: the second is refused by the run lock with exit 1 and changes nothing; once the first has ended the next run continues' {
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'C'
        $script:Second = $null
        $script:SecondState = $null
        $EndWhen = {
            if (-not ((script:Test-Hanging 'C') -and ((script:Get-StateCompleted) -join ',') -eq 'sub-a,sub-b')) { return $false }
            $script:SecondState = Get-Content -LiteralPath $script:State -Raw
            $script:Second = script:Invoke-Wrapper -Streams 1
            return $true
        }
        $null = script:Invoke-Wrapper -Streams 1 -EndWhen $EndWhen
        $script:Second.ExitCode | Should -Be 1
        script:Get-Collected $script:Second | Should -BeNullOrEmpty
        script:Get-StartLines $script:Second | Should -BeNullOrEmpty -Because 'the lock is taken before the resume state is read'
        Get-Content -LiteralPath $script:State -Raw | Should -Be $script:SecondState
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R3 = script:Invoke-Wrapper -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'C', 'D')
        $R4 = script:Invoke-Wrapper -Streams 1
        $R4.ExitCode | Should -Be 0
        script:Get-StartLines $R4 | Should -Be @('Starting a new run.')
    }
}

Describe 'The next runs after more cases, with the exit of every run' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'a role check that could not finish: runs 1 to 3 keep the state, runs 1 and 2 end with exit 0 and run 3, which reaches the retry limit, with exit 2, then each continued run skips it with exit 2 and names -Fresh' {
        script:Set-Scenario -Subs 'A', 'B' -RoleUnknown 'B'
        $Started = $null
        foreach ($N in 1, 2, 3)
        {
            $R = script:Invoke-Wrapper -Streams 1
            if ($N -lt 3) { $R.ExitCode | Should -Be 0 -Because 'skipping a subscription the role check could not finish does not change the exit code' }
            else { $R.ExitCode | Should -Be 2 -Because 'the run in which its role check fails a third time reaches the retry limit' }
            if ($N -eq 1) { script:Get-Collected $R | Should -Be (script:Get-Ids 'A'); $Started = script:Get-StateStartText }
            else
            {
                script:Get-StartLines $R | Should -Be @(('Continuing the run started {0} (1 of 2 subscriptions done). Settings: {1}. Pass -Fresh to start over.' -f $Started, $script:DefaultSettingsText))
                script:Get-Collected $R | Should -BeNullOrEmpty
            }
            @($R.Text | Where-Object { $_ -like 'Pending Retries:*' -or $_ -like 'Retry Limit Reached:*' }).Count | Should -BeGreaterThan 0
            if ($N -lt 3) { $R.Text | Should -Contain 'Until their role check passes, every later run that continues this run checks them again. A run without -Resume continues it until it started more than 7 days ago (-ResumeMaxAgeDays), then starts a new run, which keeps them on the retry list; once one has failed 3 runs in a row it is no longer retried. To start over instead, start a new run with -Fresh.' }
            @((script:Read-StateFile).FailedAttempts | Where-Object { $_.Id -eq 'sub-b' } | ForEach-Object { [int]$_.Attempts }) | Should -Be @($N)
        }
        foreach ($N in 4, 5)
        {
            $R = script:Invoke-Wrapper -Streams 1
            $R.ExitCode | Should -Be 2
            script:Get-StartLines $R | Should -Be @(('Continuing the run started {0} (1 of 2 subscriptions done, 1 past the retry limit). Settings: {1}. Pass -Fresh to start over.' -f $Started, $script:DefaultSettingsText))
            @($R.Text | Where-Object { $_ -like 'Not retried: Sub B (sub-b) failed 3 runs in a row;*To try it again, start a new run with -Fresh*' }).Count | Should -Be 1
            $R.Text | Should -Contain ('    ./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh' -f $script:Tenant)
        }
        # The role check can finish again: -Fresh collects both and ends clean; the next run is a new run.
        script:Set-Scenario -Subs 'A', 'B'
        $R6 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R6.ExitCode | Should -Be 0
        script:Get-Collected $R6 | Should -Be (script:Get-Ids 'A', 'B')
        script:Read-State | Should -BeNullOrEmpty
        $R7 = script:Invoke-Wrapper -Streams 1
        $R7.ExitCode | Should -Be 0
        script:Get-StartLines $R7 | Should -Be @('Starting a new run.')
    }

    It '-Fresh while a subscription past the retry limit still fails: -Fresh collects it and ends with exit 2, and the next two runs skip it with exit 2 and name -Fresh' {
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $Exits = @(foreach ($N in 1, 2, 3) { (script:Invoke-Wrapper -Streams 1).ExitCode })
        $Exits | Should -Be @(2, 2, 2)
        $R4 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R4.ExitCode | Should -Be 2
        script:Get-Collected $R4 | Should -Be (script:Get-Ids 'A', 'B')
        $Started = script:Get-StateStartText
        @((script:Read-StateFile).FailedAttempts | Where-Object { $_.Id -eq 'sub-b' } | ForEach-Object { [int]$_.Attempts }) | Should -Be @(4) -Because '-Fresh keeps the retry list and its counts'
        $R4.Text | Should -Contain '  To try them again, start a new run with -Fresh (it collects every subscription again), for example:'
        foreach ($N in 5, 6)
        {
            $R = script:Invoke-Wrapper -Streams 1
            $R.ExitCode | Should -Be 2
            script:Get-StartLines $R | Should -Be @(('Continuing the run started {0} (1 of 2 subscriptions done, 1 past the retry limit). Settings: {1}. Pass -Fresh to start over.' -f $Started, $script:DefaultSettingsText))
            script:Get-Collected $R | Should -BeNullOrEmpty
            @($R.Text | Where-Object { $_ -like 'Not retried: Sub B (sub-b) failed 4 runs in a row;*start a new run with -Fresh*' }).Count | Should -Be 1
        }
    }

    It 'a subscription on the retry list that loses its read role is taken off it: the run ends clean with exit 0, and the next two runs are new runs with exit 0' {
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $R1 = script:Invoke-Wrapper -Streams 1
        $R1.ExitCode | Should -Be 2
        (script:Read-State).Failed | Should -Be (script:Get-Ids 'B')
        script:Set-Scenario -Subs 'A', 'B' -Denied 'B'
        $R2 = script:Invoke-Wrapper -Streams 1
        $R2.ExitCode | Should -Be 0
        $R2.Text | Should -Contain 'Taken off the retry list: Sub B (sub-b): the signed-in identity has no read role on it, so no run can retry it. It is listed with the subscriptions skipped as not readable; once the role is granted, the next run collects it.'
        @($R2.Text | Where-Object { $_ -like 'Subscriptions skipped (not readable by the signed-in identity): 1*' }).Count | Should -Be 1
        @($R2.Text | Where-Object { $_ -like 'Pending Retries:*' }) | Should -BeNullOrEmpty
        script:Test-CleanLine $R2 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        foreach ($N in 3, 4)
        {
            $R = script:Invoke-Wrapper -Streams 1
            $R.ExitCode | Should -Be 0
            script:Get-StartLines $R | Should -Be @('Starting a new run.')
            script:Get-Collected $R | Should -Be (script:Get-Ids 'A')
            script:Read-State | Should -BeNullOrEmpty
        }
        # The role is granted again: the next run collects it.
        script:Set-Scenario -Subs 'A', 'B'
        $R5 = script:Invoke-Wrapper -Streams 1
        $R5.ExitCode | Should -Be 0
        script:Get-Collected $R5 | Should -Be (script:Get-Ids 'A', 'B')
    }

    It 'the state kept because the consolidated zip was lost: -ResumeFailedOnly ends with exit 2 twice and changes nothing; a run without it builds the zip and ends clean' {
        script:Set-Scenario -Subs 'A', 'B' -LoseZipOnFold
        $R1 = script:Invoke-Wrapper -Streams 1 -Environment $script:LoseZipEnv
        $R1.ExitCode | Should -Be 2
        (script:Read-State).Completed | Should -Be (script:Get-Ids 'A', 'B')
        $Before = Get-Content -LiteralPath $script:State -Raw
        script:Set-Scenario -Subs 'A', 'B'
        foreach ($N in 2, 3)
        {
            $R = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
            $R.ExitCode | Should -Be 2 -Because 'the state is kept, so the consolidated zip is owed'
            $R.Text | Should -Contain 'ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry.'
            $R.Text | Should -Contain ('Not finished: the run has not ended clean (the resume state file {0} is kept), so its consolidated zip is owed. This mode retries only the retry list and does not build one.' -f $script:State)
            $R.Text | Should -Contain '  Next: run the same command without -ResumeFailedOnly. It collects no completed subscription again, puts their reports into a new consolidated zip and clears the state once it ends clean.'
            script:Get-Collected $R | Should -BeNullOrEmpty
            Get-Content -LiteralPath $script:State -Raw | Should -Be $Before
        }
        $R4 = script:Invoke-Wrapper -Streams 1
        $R4.ExitCode | Should -Be 0
        script:Get-Collected $R4 | Should -BeNullOrEmpty
        script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids 'A', 'B')
        script:Read-State | Should -BeNullOrEmpty
        # Nothing is owed now: -ResumeFailedOnly has no run to retry.
        $R5 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        $R5.ExitCode | Should -Be 1
    }

    It 'a new run stopped by the access check records its start time and settings with the retry list it writes, so the next run continues it and does not read it as an earlier version''s' {
        # Every subscription's role check cannot finish, so the access check stops the run.
        script:Set-Scenario -Subs 'A', 'B' -RoleUnknown 'A', 'B'
        $R1 = script:Invoke-Wrapper -Streams 1
        $R1.ExitCode | Should -Be 1
        $Raw = script:Read-StateFile
        $Raw.RunSettings.Obfuscate | Should -BeFalse
        $Raw.PSObject.Properties['RunStartedAt'] | Should -Not -BeNullOrEmpty
        $Started = script:Get-StateStartText
        script:Set-Scenario -Subs 'A', 'B'
        $R2 = script:Invoke-Wrapper -Streams 1
        $R2.ExitCode | Should -Be 0
        script:Get-StartLines $R2 | Should -Be @(('Continuing the run started {0} (0 of 2 subscriptions done). Settings: {1}. Pass -Fresh to start over.' -f $Started, $script:DefaultSettingsText))
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B')
        $R3 = script:Invoke-Wrapper -Streams 1
        script:Get-StartLines $R3 | Should -Be @('Starting a new run.')
    }
}

Describe 'The run record in every per-stream state file' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'each stream writes the run''s start time, settings and cost window with its run id' {
        script:Invoke-InterruptedRun -Streams 2 -Arguments '-SkipMetrics'
        $Main = script:Read-StateFile
        $Files = @(script:Get-StreamFiles)
        $Files.Count | Should -Be 2
        foreach ($File in $Files)
        {
            $Obj = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
            [string]$Obj.RunId | Should -Be ([string]$Main.RunId)
            $Obj.RunSettings.SkipMetrics | Should -BeTrue
            $Obj.RunSettings.Obfuscate | Should -BeFalse
            ([datetime]$Obj.RunStartedAt).ToUniversalTime() | Should -Be ([datetime]$Main.RunStartedAt).ToUniversalTime()
            "$($Obj.ConsumptionWindowStart)..$($Obj.ConsumptionWindowEnd)" | Should -Be "$($Main.ConsumptionWindowStart)..$($Main.ConsumptionWindowEnd)"
        }
    }

    It 'the resume state file <Case>: a run with other settings stops on the per-stream record (exit 1, twice) and leaves the files; the same settings continue (exit 0); then a new run (exit 0)' -ForEach @(
        @{ Case = 'is not the right shape'; Damage = 'shape' }
        @{ Case = 'is missing'; Damage = 'missing' }
    ) {
        script:Invoke-InterruptedRun -Streams 2 -Arguments '-SkipMetrics'
        $Started = script:Get-StateStartText
        if ($Damage -eq 'shape') { script:Set-StateKeys @{ CompletedSubscriptionIds = 'sub-x' } } else { Remove-Item -LiteralPath $script:State -Force }
        $Snapshot = { @(Get-ChildItem -LiteralPath $script:Root -Force -Recurse -File | Where-Object { $_.Name -notlike '.run-lock-*' -and $_.Name -notlike 'RunAllSubscriptions_transcript_*' } | ForEach-Object { '{0}|{1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Sort-Object) }
        $Before = & $Snapshot
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        $Why = if ($Damage -eq 'shape') { 'is not the right shape (it is moved aside below)' } else { 'is not in the inventory folder' }
        script:Clear-Calls
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Streams 1
            $R.ExitCode | Should -Be 1
            $R.Text | Should -Contain ('The resume state file {0}, so this run checks the start time, settings and cost window that the per-stream state files of the unfinished run record ({1}).' -f $Why, ($Names -join ', '))
            $R.Text | Should -Contain '  -SkipMetrics: on in the unfinished run, off in this run.'
            script:Get-Calls | Should -BeNullOrEmpty
            & $Snapshot | Should -Be $Before -Because 'the stop leaves every file as it was'
        }
        $R3 = script:Invoke-Wrapper -Arguments '-SkipMetrics' -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @(('Continuing the run started {0} (2 of 4 subscriptions done). Settings: -SkipMetrics. Pass -Fresh to start over.' -f $Started))
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'C', 'D')
        @(script:Get-Calls | Where-Object { $_ -notlike '*|SkipMetrics=True|*' }) | Should -BeNullOrEmpty
        script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamFiles) | Should -BeNullOrEmpty
        $R4 = script:Invoke-Wrapper -Streams 1
        $R4.ExitCode | Should -Be 0
        script:Get-StartLines $R4 | Should -Be @('Starting a new run.')
    }

    It 'per-stream files of one run that disagree, all started past the age limit: -Resume stops (exit 1); a run without -Resume starts a new run and says why (exit 0), the old files are another run''s; then a new run (exit 0)' {
        # No resume state file; two stream files of one run that started 9 days ago, -Obfuscate differing.
        script:Invoke-InterruptedRun -Streams 2
        Remove-Item -LiteralPath $script:State -Force
        $Old = [datetime]::UtcNow.AddDays(-9)
        $Files = @(script:Get-StreamFiles | Sort-Object Name)
        foreach ($N in 0, 1)
        {
            $Obj = Get-Content -LiteralPath $Files[$N].FullName -Raw | ConvertFrom-Json
            $Obj.RunStartedAt = $Old.ToString('o', [cultureinfo]::InvariantCulture)
            if ($N -eq 1) { $Obj.RunSettings.Obfuscate = $true }
            $Obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Files[$N].FullName -Encoding utf8
        }
        $Started = $Old.ToString('d MMM yyyy HH:mm', [cultureinfo]::InvariantCulture) + ' UTC'
        $Names = @($Files | ForEach-Object { $_.Name })
        # Run 1, -Resume asks to continue it: the conflict stops it.
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $R1.ExitCode | Should -Be 1
        $R1.Text | Should -Contain ('ERROR: This run stops here (exit 1), before it signs in, collects anything or writes the resume state: the per-stream state files of the unfinished run record different start times, settings or cost windows ({0}), so this run cannot check that it collects the same way.' -f ($Names -join ', '))
        @($R1.Text | Where-Object { $_ -like '*This run continues it*' }) | Should -BeNullOrEmpty
        # Run 2, without -Resume: the age comes first, so a new run, and it says why.
        script:Clear-Calls
        $R2 = script:Invoke-Wrapper -Streams 1
        $R2.ExitCode | Should -Be 0
        $R2.Text | Should -Contain ('The unfinished run started {0}, more than 7 days ago; starting a new run. Pass -Resume to continue it anyway.' -f $Started)
        @($R2.Text | Where-Object { $_ -like 'ERROR: This run stops here*' -or $_ -like 'Recovered per-stream state*' }) | Should -BeNullOrEmpty
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        @(script:Get-Calls | Where-Object { $_ -notlike '*|Obfuscate=False|*' }) | Should -BeNullOrEmpty
        @($R2.Text | Where-Object { $_ -like 'Removed the per-stream state files*' }) | Should -Be @(('Removed the per-stream state files {0}, which another run wrote and no run can resume.' -f ($Names -join ', ')))
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamFiles) | Should -BeNullOrEmpty
        $R3 = script:Invoke-Wrapper -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @('Starting a new run.')
    }

    It 'a usable resume state file within the age limit whose per-stream files of the same run record other settings stops the run before it folds them (exit 1, twice; continued with -ParallelStreams <Streams>); -Fresh starts a new run (exit 0); then a new run (exit 0)' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        # A two-stream -SkipMetrics run interrupted after A and B; then only the
        # resume state file's record is changed to SkipMetrics off.
        script:Invoke-InterruptedRun -Streams 2 -Arguments '-SkipMetrics'
        $Settings = (script:Read-StateFile).RunSettings
        $Settings.SkipMetrics = $false
        script:Set-StateKeys @{ RunSettings = $Settings } -MainOnly
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        $Names.Count | Should -Be 2
        $Snapshot = { @(Get-ChildItem -LiteralPath $script:Root -Force -Recurse -File | Where-Object { $_.Name -notlike '.run-lock-*' -and $_.Name -notlike 'RunAllSubscriptions_transcript_*' } | ForEach-Object { '{0}|{1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Sort-Object) }
        $Before = & $Snapshot
        script:Clear-Calls
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Streams $Streams
            $R.ExitCode | Should -Be 1
            $R.Text | Should -Contain ('ERROR: This run stops here (exit 1), before it signs in, collects anything or writes the resume state: the resume state file and the per-stream state files of the unfinished run no longer record the same start time, settings and cost window ({0}). Only a file that was changed or damaged after the run wrote it can cause this, so this run cannot check that it collects the same way.' -f ($Names -join ', '))
            foreach ($Name in $Names) { $R.Text | Should -Contain ('  {0}: -SkipMetrics is on there, off in the resume state file.' -f $Name) }
            $R.Text | Should -Contain '  Next: pass -Fresh to start a new run that collects every subscription again.'
            @($R.Text | Where-Object { $_ -like 'Continuing *' -or $_ -like 'Recovered per-stream state*' -or $_ -like 'Existing session detected*' }) | Should -BeNullOrEmpty
            script:Get-Calls | Should -BeNullOrEmpty
            & $Snapshot | Should -Be $Before -Because 'the stop leaves every file as it was'
        }
        # -Fresh: a new run that collects all four, unmasked metrics included, and ends clean.
        $R3 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams $Streams
        $R3.ExitCode | Should -Be 0
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        @(script:Get-Calls | Where-Object { $_ -notlike '*|SkipMetrics=False|*' }) | Should -BeNullOrEmpty
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamFiles) | Should -BeNullOrEmpty
        $R4 = script:Invoke-Wrapper -Streams $Streams
        $R4.ExitCode | Should -Be 0
        script:Get-StartLines $R4 | Should -Be @('Starting a new run.')
    }

    It 'the same files past the age limit: a run without -Resume starts a new run and says why (exit 0), the old per-stream files are another run''s and are removed; then a new run (exit 0)' {
        script:Invoke-InterruptedRun -Streams 2 -Arguments '-SkipMetrics'
        $Settings = (script:Read-StateFile).RunSettings
        $Settings.SkipMetrics = $false
        script:Set-StateKeys @{ RunSettings = $Settings; RunStartedAt = [datetime]::UtcNow.AddDays(-8).ToString('o', [cultureinfo]::InvariantCulture) } -MainOnly
        $Started = script:Get-StateStartText
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        script:Clear-Calls
        $R1 = script:Invoke-Wrapper -Streams 1
        $R1.ExitCode | Should -Be 0
        script:Get-StartLines $R1 | Should -Be @(('The unfinished run started {0}, more than 7 days ago; starting a new run. Pass -Resume to continue it anyway.' -f $Started))
        @($R1.Text | Where-Object { $_ -like 'ERROR: This run stops here*' -or $_ -like 'Recovered per-stream state*' }) | Should -BeNullOrEmpty
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        @(script:Get-Calls | Where-Object { $_ -notlike '*|SkipMetrics=False|*' }) | Should -BeNullOrEmpty
        @($R1.Text | Where-Object { $_ -like 'Removed the per-stream state files*' }) | Should -Be @(('Removed the per-stream state files {0}, which another run wrote and no run can resume.' -f ($Names -join ', ')))
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamFiles) | Should -BeNullOrEmpty
        $R2 = script:Invoke-Wrapper -Streams 1
        $R2.ExitCode | Should -Be 0
        script:Get-StartLines $R2 | Should -Be @('Starting a new run.')
    }

    It 'per-stream files that record the same run as the resume state file are folded in as before' {
        script:Invoke-InterruptedRun -Streams 2 -Arguments '-SkipMetrics'
        $Started = script:Get-StateStartText
        $R = script:Invoke-Wrapper -Arguments '-SkipMetrics' -Streams 1
        $R.ExitCode | Should -Be 0
        @($R.Text | Where-Object { $_ -like 'ERROR: This run stops here*' }) | Should -BeNullOrEmpty
        script:Get-StartLines $R | Should -Be @(('Continuing the run started {0} (2 of 4 subscriptions done). Settings: -SkipMetrics. Pass -Fresh to start over.' -f $Started))
        script:Get-Collected $R | Should -Be (script:Get-Ids 'C', 'D')
    }

    It 'per-stream files of one run within the age limit that record different settings stop the run (exit 1, twice, naming them); -Fresh starts a new run (exit 0); then a new run (exit 0)' {
        script:Invoke-InterruptedRun -Streams 2
        Remove-Item -LiteralPath $script:State -Force
        $Files = @(script:Get-StreamFiles | Sort-Object Name)
        $Obj = Get-Content -LiteralPath $Files[1].FullName -Raw | ConvertFrom-Json
        $Obj.RunSettings.Obfuscate = $true
        $Obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Files[1].FullName -Encoding utf8
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Streams 1
            $R.ExitCode | Should -Be 1
            $R.Text | Should -Contain ('ERROR: This run stops here (exit 1), before it signs in, collects anything or writes the resume state: the per-stream state files of the unfinished run record different start times, settings or cost windows ({0}, {1}), so this run cannot check that it collects the same way.' -f $Files[0].Name, $Files[1].Name)
            $R.Text | Should -Contain '  Next: pass -Fresh to start a new run that collects every subscription again.'
            script:Get-Collected $R | Should -BeNullOrEmpty
        }
        $R3 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        $R4 = script:Invoke-Wrapper -Streams 1
        $R4.ExitCode | Should -Be 0
        script:Get-StartLines $R4 | Should -Be @('Starting a new run.')
    }
}

Describe 'One run record in every write, and advice that runs as stated' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It '-Fresh whose first write of the resume state fails leaves the earlier run''s state whole, says so, and the next runs act on that state' {
        script:Invoke-InterruptedRun -Streams 1 -Arguments '-Obfuscate'
        $Before = Get-Content -LiteralPath $script:State -Raw
        # An empty folder where the write puts its temporary file: the first write fails and removes it.
        New-Item -ItemType Directory -Path ($script:State + '.tmp') -Force | Out-Null
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -RoleUnknown 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R2.ExitCode | Should -Be 1
        @($R2.Text | Where-Object { $_ -like ('WARNING: Failed to persist resume state to *{0}*' -f (Split-Path -Path $script:State -Leaf)) }).Count | Should -Be 1
        Get-Content -LiteralPath $script:State -Raw | Should -Be $Before -Because 'no write pairs the -Fresh run''s retry list with the earlier run''s record'
        Test-Path -LiteralPath ($script:State + '.tmp') | Should -BeFalse
        # Run 3, plain: the earlier run is still the unfinished one, so its settings apply.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R3 = script:Invoke-Wrapper -Streams 1
        $R3.ExitCode | Should -Be 1
        $R3.Text | Should -Contain '  -Obfuscate: on in the unfinished run, off in this run.'
        # Run 4, -Fresh as that stop advises: a new run that ends clean; run 5: a new run.
        $R4 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R4.ExitCode | Should -Be 0
        script:Get-Collected $R4 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        script:Read-State | Should -BeNullOrEmpty
        $R5 = script:Invoke-Wrapper -Streams 1
        $R5.ExitCode | Should -Be 0
        script:Get-StartLines $R5 | Should -Be @('Starting a new run.')
    }

    It 'a continued state file that is not the right shape, stopped by the access check, writes its retry list with this run''s start time and settings; the next two runs check them' {
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-Content -LiteralPath $script:State -Value ('{"TenantID": "' + $script:Tenant + '", "CompletedSubscriptionIds": "sub-x", "FailedAttempts": []}') -Encoding utf8
        script:Set-Scenario -Subs 'A', 'B' -RoleUnknown 'A', 'B'
        $R1 = script:Invoke-Wrapper -Arguments '-SkipMetrics' -Streams 1
        $R1.ExitCode | Should -Be 1
        $Raw = script:Read-StateFile
        $Raw.RunSettings.SkipMetrics | Should -BeTrue
        $Raw.PSObject.Properties['RunStartedAt'] | Should -Not -BeNullOrEmpty
        "$($Raw.ConsumptionWindowStart)..$($Raw.ConsumptionWindowEnd)" | Should -Be (script:Get-ConsumptionWindowText)
        @($Raw.FailedAttempts | ForEach-Object { $_.Id } | Sort-Object) | Should -Be (script:Get-Ids 'A', 'B')
        $Started = script:Get-StateStartText
        script:Set-Scenario -Subs 'A', 'B'
        $R2 = script:Invoke-Wrapper -Streams 1
        $R2.ExitCode | Should -Be 1
        $R2.Text | Should -Contain '  -SkipMetrics: on in the unfinished run, off in this run.'
        @($R2.Text | Where-Object { $_ -like 'The resume state file was written by an earlier version*' }) | Should -BeNullOrEmpty
        $R3 = script:Invoke-Wrapper -Arguments '-SkipMetrics' -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @(('Continuing the run started {0} (0 of 2 subscriptions done). Settings: -SkipMetrics. Pass -Fresh to start over.' -f $Started))
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B')
        script:Read-State | Should -BeNullOrEmpty
    }

    It '-Fresh that writes its state and is then refused by the consumption check names -Fresh -SkipConsumption and -Fresh -IncludeDisabled; each advised command runs as stated' {
        script:Invoke-InterruptedRun -Streams 1 -Arguments '-Obfuscate'
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E' -Disabled 'E' -RoleUnknown 'B' -ConsumptionDenied
        $R2 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R2.ExitCode | Should -Be 1
        (script:Read-StateFile).RunSettings.Obfuscate | Should -BeFalse -Because 'the -Fresh run wrote its own record with the retry list'
        $R2.Text | Should -Contain ('  3. Or start a new run with -Fresh -SkipConsumption to inventory without consumption data: the resume state file .resume-state-{0}.json is kept, and a run that continues it keeps its settings.' -f $script:Tenant)
        $R2.Text | Should -Contain 'Excluded 1 non-Enabled subscription(s) [Disabled: 1]. To inventory them anyway, start a new run with -Fresh -IncludeDisabled.'
        @($R2.Text | Where-Object { $_ -like '*re-run with -SkipConsumption*' -or $_ -like '*Use -IncludeDisabled*' }) | Should -BeNullOrEmpty
        # Run 3, the advised -Fresh -SkipConsumption (role checks pass now): a new run, exit 0, clean.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E' -Disabled 'E' -ConsumptionDenied
        $R3 = script:Invoke-Wrapper -Arguments '-Fresh', '-SkipConsumption' -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        script:Read-State | Should -BeNullOrEmpty
        # Run 4, the advised -Fresh -IncludeDisabled (with -SkipConsumption, as consumption is still refused): collects E too.
        $R4 = script:Invoke-Wrapper -Arguments '-Fresh', '-IncludeDisabled', '-SkipConsumption' -Streams 1
        $R4.ExitCode | Should -Be 0
        script:Get-Collected $R4 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D', 'E')
    }

    It 'a new run that ends with its state kept names -Fresh -IncludeDisabled in its summary; that command collects the disabled subscription and the next run is a new run' {
        script:Set-Scenario -Subs 'A', 'B', 'C' -Disabled 'B' -Fail 'C'
        $R1 = script:Invoke-Wrapper -Streams 1
        $R1.ExitCode | Should -Be 2
        Test-Path -LiteralPath $script:State | Should -BeTrue
        $R1.Text | Should -Contain 'Subscriptions Excluded:  1 (non-Enabled; start a new run with -Fresh -IncludeDisabled to inventory them)'
        script:Set-Scenario -Subs 'A', 'B', 'C' -Disabled 'B'
        $R2 = script:Invoke-Wrapper -Arguments '-Fresh', '-IncludeDisabled' -Streams 1
        $R2.ExitCode | Should -Be 0
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        script:Read-State | Should -BeNullOrEmpty
        $R3 = script:Invoke-Wrapper -Arguments '-IncludeDisabled' -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @('Starting a new run.')
    }

    It 'an explicit <Switch> of a run past the age limit with -SkipMetrics <Stored> in the unfinished run and <Given> in this run stops without claiming to continue; the matching settings continue, then a new run' -ForEach @(
        @{ Switch = '-Resume'; Stored = 'on'; Given = 'off'; First = @('-SkipMetrics'); Mismatch = @('-Resume'); Match = @('-Resume', '-SkipMetrics'); Next = @('-SkipMetrics'); Metrics = $false }
        @{ Switch = '-Resume'; Stored = 'off'; Given = 'on'; First = @(); Mismatch = @('-Resume', '-SkipMetrics'); Match = @('-Resume'); Next = @(); Metrics = $true }
        @{ Switch = '-ResumeFailedOnly'; Stored = 'on'; Given = 'off'; First = @('-SkipMetrics'); Mismatch = @('-ResumeFailedOnly'); Match = $null; Next = $null; Metrics = $false }
    ) {
        script:Invoke-InterruptedRun -Streams 1 -Arguments $First
        script:Set-StateKeys @{ RunStartedAt = [datetime]::UtcNow.AddDays(-9).ToString('o', [cultureinfo]::InvariantCulture) }
        $Started = script:Get-StateStartText
        $Before = Get-Content -LiteralPath $script:State -Raw
        $R1 = script:Invoke-Wrapper -Arguments $Mismatch -Streams 1
        $R1.ExitCode | Should -Be 1
        $R1.Text | Should -Contain ('  -SkipMetrics: {0} in the unfinished run, {1} in this run.' -f $Stored, $Given)
        @($R1.Text | Where-Object { $_ -like '*This run continues it*' -or $_ -like '*metrics of the subscriptions*' -or $_ -like 'Continuing *' }) | Should -BeNullOrEmpty
        Get-Content -LiteralPath $script:State -Raw | Should -Be $Before
        if ($null -eq $Match) { return }
        $R2 = script:Invoke-Wrapper -Arguments $Match -Streams 1
        $R2.ExitCode | Should -Be 0
        $Tail = if ($Metrics) { '; the metrics of the subscriptions it collects cover a later period than those collected earlier in that run.' } else { '.' }
        $R2.Text | Should -Contain ('WARNING: The unfinished run started {0}, more than 7 days ago. This run continues it because {1} was passed{2}' -f $Started, $Switch, $Tail)
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'C', 'D')
        $R3 = script:Invoke-Wrapper -Arguments $Next -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @('Starting a new run.')
    }

    It 'a role check that could not finish: past the age limit a run without -Resume starts a new run that keeps it on the retry list, as the line says' {
        script:Set-Scenario -Subs 'A', 'B' -RoleUnknown 'B'
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Streams 1
            $R.ExitCode | Should -Be 0
            @($R.Text | Where-Object { $_ -like 'Until their role check passes, every later run that continues this run checks them again. A run without -Resume continues it until it started more than 7 days ago*' }).Count | Should -Be 1
        }
        $OldId = [string](script:Read-StateFile).RunId
        script:Set-StateKeys @{ RunStartedAt = [datetime]::UtcNow.AddDays(-8).ToString('o', [cultureinfo]::InvariantCulture) }
        $R3 = script:Invoke-Wrapper -Streams 1
        # Its role check could not finish a third run in a row: the retry limit
        # is reached in this run, which ends with exit 2.
        $R3.ExitCode | Should -Be 2
        @(script:Get-StartLines $R3)[0] | Should -BeLike 'The unfinished run started *, more than 7 days ago; starting a new run.*'
        [string](script:Read-StateFile).RunId | Should -Not -Be $OldId
        @((script:Read-StateFile).FailedAttempts | Where-Object { $_.Id -eq 'sub-b' } | ForEach-Object { [int]$_.Attempts }) | Should -Be @(3)
    }

    It '-ResumeFailedOnly with the zip owed and a report-record list that lacks the completed subscriptions names -Fresh (exit 2); -Fresh collects them, and the next run is a new run' {
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $Window = (script:Get-ConsumptionWindowText) -split '\.\.'
        [pscustomobject]@{
            TenantID = $script:Tenant; RunId = 'run-earlier'; CompletedSubscriptionIds = @('sub-a', 'sub-b'); CompletedReports = @(); FailedAttempts = @()
            RunStartedAt = [datetime]::UtcNow.AddHours(-1).ToString('o', [cultureinfo]::InvariantCulture)
            RunSettings = [pscustomobject]@{ Obfuscate = $false; SkipMetrics = $false; SkipConsumption = $false; IncludeDisabled = $false }
            ConsumptionWindowStart = $Window[0]; ConsumptionWindowEnd = $Window[1]
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:State -Encoding utf8
        script:Set-Scenario -Subs 'A', 'B'
        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        $R1.ExitCode | Should -Be 2
        $R1.Text | Should -Contain '  Next: run the same command without -ResumeFailedOnly, with -Fresh. The resume state records no report for 2 completed subscription(s), so a run that continues this one cannot put them into a consolidated zip and ends with exit 2; a new run collects every subscription again.'
        $R2 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R2.ExitCode | Should -Be 0
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B')
        script:Read-State | Should -BeNullOrEmpty
        $R3 = script:Invoke-Wrapper -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @('Starting a new run.')
    }

    It '-ResumeFailedOnly with only a per-stream file that is not the right shape says it stops, not that it continues (exit 1); then no run to retry (exit 1); then a new run' {
        script:Set-Scenario -Subs 'A', 'B'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root ('.resume-state-{0}-stream-0.json' -f $script:Tenant)) -Value '{"Completed": 5, "FailedAttempts": "x"}' -Encoding utf8
        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        $R1.ExitCode | Should -Be 1
        @($R1.Text | Where-Object { $_ -like '*It continues that run*' -or $_ -like 'Continuing *' }) | Should -BeNullOrEmpty
        @($R1.Text | Where-Object { $_ -like 'Per-stream state files of an interrupted parallel run*when one is not the right shape, the retry list is not complete and it stops (see below).' }).Count | Should -Be 1
        $R1.Text | Should -Contain 'ResumeFailedOnly: stopped before retrying anything (exit 1). The retry list is not complete: a resume state file was not the right shape (see the warning above).'
        $R2 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        $R2.ExitCode | Should -Be 1
        @($R2.Text | Where-Object { $_ -like 'ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry.*' }).Count | Should -Be 1
        $R3 = script:Invoke-Wrapper -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @('Starting a new run.')
    }
}

Describe 'Resume by default: the state each run records, and the advice it prints' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'a continued state file that is not the right shape records this run''s start time and settings, so the next run checks them (-ParallelStreams <Streams>)' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-Content -LiteralPath $script:State -Value ('{"TenantID": "' + $script:Tenant + '", "CompletedSubscriptionIds": "sub-x", "FailedAttempts": []}') -Encoding utf8
        # Run 1, -SkipMetrics: the file is moved aside; A and B complete, then the run is ended.
        script:Invoke-InterruptedRun -Streams $Streams -Arguments '-SkipMetrics'
        $Raw = script:Read-StateFile
        $Raw.RunSettings.SkipMetrics | Should -BeTrue
        $Raw.PSObject.Properties['RunStartedAt'] | Should -Not -BeNullOrEmpty
        "$($Raw.ConsumptionWindowStart)..$($Raw.ConsumptionWindowEnd)" | Should -Be (script:Get-ConsumptionWindowText)
        $Started = script:Get-StateStartText
        # Run 2, without -SkipMetrics: stops (exit 1), and does not read the file as an earlier version's.
        $R2 = script:Invoke-Wrapper -Streams $Streams
        $R2.ExitCode | Should -Be 1
        $R2.Text | Should -Contain '  -SkipMetrics: on in the unfinished run, off in this run.'
        @($R2.Text | Where-Object { $_ -like 'The resume state file was written by an earlier version*' }) | Should -BeNullOrEmpty
        # Run 3, -SkipMetrics: continues, collects C and D the same way; run 4: a new run.
        script:Clear-Calls
        $R3 = script:Invoke-Wrapper -Arguments '-SkipMetrics' -Streams $Streams
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @(('Continuing the run started {0} (2 of 4 subscriptions done). Settings: -SkipMetrics. Pass -Fresh to start over.' -f $Started))
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'C', 'D')
        @(script:Get-Calls | Where-Object { $_ -notlike '*|SkipMetrics=True|*' }) | Should -BeNullOrEmpty
        script:Read-State | Should -BeNullOrEmpty
        $R4 = script:Invoke-Wrapper -Streams $Streams
        $R4.ExitCode | Should -Be 0
        script:Get-StartLines $R4 | Should -Be @('Starting a new run.')
    }

    It '-Fresh stopped by the role check writes its retry list with its own run id, start time and settings; the next two runs continue it (-ParallelStreams <Streams>)' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        script:Invoke-InterruptedRun -Streams $Streams -Arguments '-Obfuscate'
        $OldId = [string](script:Read-StateFile).RunId
        # Run 2, -Fresh without -Obfuscate: every role check cannot finish, so the run stops (exit 1) after it writes the retry list.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -RoleUnknown 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams $Streams
        $R2.ExitCode | Should -Be 1
        $Raw = script:Read-StateFile
        [string]$Raw.RunId | Should -Not -Be $OldId
        $Raw.RunSettings.Obfuscate | Should -BeFalse
        @($Raw.CompletedSubscriptionIds | Where-Object { $_ }) | Should -BeNullOrEmpty
        @($Raw.FailedAttempts | ForEach-Object { $_.Id } | Sort-Object) | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        $Started = script:Get-StateStartText
        # Runs 3 and 4, the role checks pass: run 3 continues the -Fresh run and collects all four; run 4 is a new run.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R3 = script:Invoke-Wrapper -Streams $Streams
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @(('Continuing the run started {0} (0 of 4 subscriptions done). Settings: {1}. Pass -Fresh to start over.' -f $Started, $script:DefaultSettingsText))
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        script:Read-State | Should -BeNullOrEmpty
        $R4 = script:Invoke-Wrapper -Streams $Streams
        $R4.ExitCode | Should -Be 0
        script:Get-StartLines $R4 | Should -Be @('Starting a new run.')
    }

    It '-ResumeFailedOnly with no resume state file and only a per-stream file that cannot be parsed has no run to retry: exit 1, twice; then a new run' {
        script:Set-Scenario -Subs 'A', 'B'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root ('.resume-state-{0}-stream-0.json' -f $script:Tenant)) -Value '{ cut' -NoNewline
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
            $R.ExitCode | Should -Be 1
            $R.Text | Should -Contain 'ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry. No resume state file for this tenant is in the inventory folder, so there is no retry list. It did not sign in, collect anything or write the resume state.'
            @($R.Text | Where-Object { $_ -like 'Continuing *' -or $_ -like '*Nothing to retry*' }) | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:State | Should -BeFalse
        }
        $R3 = script:Invoke-Wrapper -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @('Starting a new run.')
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B')
    }

    It 'a continued run refused by the consumption check says to start a new run with -Fresh -SkipConsumption, and names -Fresh -IncludeDisabled for a disabled subscription; exit 1, twice; then that command ends clean' {
        script:Invoke-InterruptedRun -Streams 1
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E' -Disabled 'E' -ConsumptionDenied
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Streams 1
            $R.ExitCode | Should -Be 1
            $R.Text | Should -Contain ('  3. Or start a new run with -Fresh -SkipConsumption to inventory without consumption data: the resume state file .resume-state-{0}.json is kept, and a run that continues it keeps its settings.' -f $script:Tenant)
            $R.Text | Should -Not -Contain '  3. Or re-run with -SkipConsumption to inventory without consumption data.'
            $R.Text | Should -Contain 'Excluded 1 non-Enabled subscription(s) [Disabled: 1]. To inventory them anyway, start a new run with -Fresh -IncludeDisabled.'
        }
        $R3 = script:Invoke-Wrapper -Arguments '-Fresh', '-SkipConsumption' -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        script:Read-State | Should -BeNullOrEmpty
    }

    It '-ResumeFailedOnly with other settings says to start over without -ResumeFailedOnly, with -Fresh; exit 1, twice; then -Fresh ends clean' {
        script:Invoke-InterruptedRun -Streams 1 -Arguments '-Obfuscate'
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
            $R.ExitCode | Should -Be 1
            $R.Text | Should -Contain '  Next: run the same command with the unfinished run''s settings (-Obfuscate) to continue it, or run the same command without -ResumeFailedOnly, with -Fresh, to start a new run that collects every subscription again.'
        }
        $R3 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
    }

    It 'the consolidated zip owed by a run past the age limit: -ResumeFailedOnly says to run with -Resume (exit 2, twice); -Resume builds the zip and ends clean' {
        script:Set-Scenario -Subs 'A', 'B' -LoseZipOnFold
        $R1 = script:Invoke-Wrapper -Streams 1 -Environment $script:LoseZipEnv
        $R1.ExitCode | Should -Be 2
        script:Set-StateKeys @{ RunStartedAt = [datetime]::UtcNow.AddDays(-8).ToString('o', [cultureinfo]::InvariantCulture) }
        script:Set-Scenario -Subs 'A', 'B'
        foreach ($N in 2, 3)
        {
            $R = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
            $R.ExitCode | Should -Be 2
            $R.Text | Should -Contain '  Next: run the same command with -Resume in place of -ResumeFailedOnly (the unfinished run is past -ResumeMaxAgeDays, or its start time cannot be read, so a run without either switch would start a new run). It collects no completed subscription again, puts their reports into a new consolidated zip and clears the state once it ends clean.'
        }
        $R4 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $R4.ExitCode | Should -Be 0
        script:Get-Collected $R4 | Should -BeNullOrEmpty
        script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids 'A', 'B')
        script:Read-State | Should -BeNullOrEmpty
        $R5 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        $R5.ExitCode | Should -Be 1
    }

    It 'a state file from an earlier version with every subscription completed and no report records: -ResumeFailedOnly says a run without it collects them again (exit 2, twice); that run does, and ends clean' {
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-Content -LiteralPath $script:State -Value ('{"TenantID": "' + $script:Tenant + '", "CompletedSubscriptionIds": ["sub-a", "sub-b"], "FailedAttempts": []}') -Encoding utf8
        script:Set-Scenario -Subs 'A', 'B'
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
            $R.ExitCode | Should -Be 2
            $R.Text | Should -Contain '  Next: run the same command without -ResumeFailedOnly. It collects again the 2 subscription(s) whose report the resume state does not record (it was written by an earlier version), puts every report into a new consolidated zip and clears the state once it ends clean.'
        }
        $R3 = script:Invoke-Wrapper -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B')
        script:Read-State | Should -BeNullOrEmpty
        $R4 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        $R4.ExitCode | Should -Be 1
    }

    It 'an explicit -Resume of a run past the age limit with -SkipMetrics does not speak of metrics; the next run is a new run' {
        script:Invoke-InterruptedRun -Streams 1 -Arguments '-SkipMetrics'
        script:Set-StateKeys @{ RunStartedAt = [datetime]::UtcNow.AddDays(-9).ToString('o', [cultureinfo]::InvariantCulture) }
        $Started = script:Get-StateStartText
        $R1 = script:Invoke-Wrapper -Arguments '-Resume', '-SkipMetrics' -Streams 1
        $R1.ExitCode | Should -Be 0
        $R1.Text | Should -Contain ('WARNING: The unfinished run started {0}, more than 7 days ago. This run continues it because -Resume was passed.' -f $Started)
        @($R1.Text | Where-Object { $_ -like '*metrics of the subscriptions*' }) | Should -BeNullOrEmpty
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'C', 'D')
        $R2 = script:Invoke-Wrapper -Arguments '-SkipMetrics' -Streams 1
        $R2.ExitCode | Should -Be 0
        script:Get-StartLines $R2 | Should -Be @('Starting a new run.')
    }
}

Describe 'A retry-list subscription that is not enabled' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'is taken off the retry list by <Run2>, which ends clean with exit 0; the next two runs are new runs with exit 0, and -Fresh -IncludeDisabled collects it' -ForEach @(@{ Run2 = 'a run without a switch'; Arguments = @() }, @{ Run2 = '-Fresh'; Arguments = @('-Fresh') }) {
        # Run 1: B fails (exit 2, on the retry list). Then B is disabled.
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        (script:Invoke-Wrapper -Streams 1).ExitCode | Should -Be 2
        script:Set-Scenario -Subs 'A', 'B' -Disabled 'B'
        $R2 = script:Invoke-Wrapper -Arguments $Arguments -Streams 1
        $R2.ExitCode | Should -Be 0
        $R2.Text | Should -Contain 'Taken off the retry list: Sub B (sub-b) is Disabled, and this run leaves out subscriptions that are not enabled (no -IncludeDisabled), so no run with these settings can retry it. To collect it, start a new run with -Fresh -IncludeDisabled.'
        @($R2.Text | Where-Object { $_ -like 'Pending Retries:*' }) | Should -BeNullOrEmpty
        script:Test-CleanLine $R2 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        foreach ($N in 3, 4)
        {
            $R = script:Invoke-Wrapper -Streams 1
            $R.ExitCode | Should -Be 0
            script:Get-StartLines $R | Should -Be @('Starting a new run.')
            script:Get-Collected $R | Should -Be (script:Get-Ids 'A')
            script:Read-State | Should -BeNullOrEmpty
        }
        $R5 = script:Invoke-Wrapper -Arguments '-Fresh', '-IncludeDisabled' -Streams 1
        $R5.ExitCode | Should -Be 0
        script:Get-Collected $R5 | Should -Be (script:Get-Ids 'A', 'B')
    }

    It 'a continued run that takes it off keeps the state for the subscriptions still owed, and the next run continues' {
        script:Set-Scenario -Subs 'A', 'B', 'C' -Fail 'B' -Hang 'C'
        $null = script:Invoke-Wrapper -Streams 1 -EndWhen { (script:Test-Hanging 'C') -and (script:Read-State).Failed -contains 'sub-b' }
        $Started = script:Get-StateStartText
        script:Set-Scenario -Subs 'A', 'B', 'C' -Disabled 'B' -Fail 'C'
        $R2 = script:Invoke-Wrapper -Streams 1
        $R2.ExitCode | Should -Be 2
        @($R2.Text | Where-Object { $_ -like 'Taken off the retry list: Sub B (sub-b) is Disabled*' }).Count | Should -Be 1
        (script:Read-State).Failed | Should -Be (script:Get-Ids 'C')
        script:Set-Scenario -Subs 'A', 'B', 'C' -Disabled 'B'
        $R3 = script:Invoke-Wrapper -Streams 1
        $R3.ExitCode | Should -Be 0
        script:Get-StartLines $R3 | Should -Be @(('Continuing the run started {0} (1 of 2 subscriptions done). Settings: {1}. Pass -Fresh to start over.' -f $Started, $script:DefaultSettingsText))
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'C')
        script:Read-State | Should -BeNullOrEmpty
    }
}
