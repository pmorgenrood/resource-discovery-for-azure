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
#     and keeps them with a warning while it cannot be written. A run that ends
#     early, with any exit code, does the same. A per-stream or resume state
#     file that cannot be removed is named in a warning, the run does not say
#     it cleared the state, and the next run removes it.
#   - A per-stream state file the end-of-run merge cannot read is named on
#     screen, moved aside where no later run reads it, and none of the
#     subscriptions it lists counts as completed; that run does not report a
#     clean run, and the next -Resume collects what is still missing.
#   - The recovery line counts real failure records only.
#   - A resume state that lists one completed subscription stays a list of ids
#     when the next one completes, so the next -Resume skips both.
#   - Per-stream files are kept while the resume state on disk holds an older
#     record for one of their ids, compared as a whole record (a failure reason,
#     a report path where the state records reports), or lacks a list the run
#     holds; a per-stream file holding a list this version does not keep gives
#     its completed and failed subscriptions, then is moved aside with a warning.
#   - An exit before the startup fold prints no error under strict mode.
#   - A run without -Resume starts a new run id, every save of the resume state
#     keeps it, and the startup fold and the end-of-run merge use only the
#     per-stream files that carry it: an earlier run's file is left by a run
#     that does not end clean, which names the ones still on disk, and removed
#     by one that does, and a later -Resume collects what the run without
#     -Resume failed. When the resume state cannot be written from the start of
#     such a run, its warnings say that a later -Resume may not see its results
#     and that the next run should start without -Resume; a folder with content
#     where the state's temporary file goes makes the run warn with the command
#     that removes it, not prompt, and an empty one is removed. A run that
#     stops early names another run's files still on disk too.
# When an end-to-end test fails, the full output of each wrapper run it made is
# printed after the failure.
# Each scenario is followed by the next two runs, which end without a repeated
# recovery line, without collecting a completed subscription again, and with
# no resume state once nothing is left. The reader, the move-aside helper and
# the read-back of the resume state are also tested on their own, a rename that
# fails included.
#
# Every run is Run-AllSubscriptions.ps1 itself, started as its own pwsh process
# from a copy of the tool whose ResourceInventory.ps1 is a stand-in. Azure is a
# set of stand-in Az modules (the tool uses Az PowerShell only), found first on
# the module path of that process, which answer from a scenario file: the
# subscriptions, the ones that fail, the ones whose collection hangs until
# the run is ended, the ones whose run writes no zip, the ones after which
# the inventory root is made read-only (so a removal there fails), and whether
# every write of the resume state file fails as it does on a full disk. An
# interrupted run is ended by killing the wrapper's
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
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
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
        return & $Answer 200 @{ value = @(@{ properties = @{ scope = "/subscriptions/$Id"; principalId = 'stand-in-caller'; roleDefinitionId = "/subscriptions/$Id/providers/Microsoft.Authorization/roleDefinitions/stand-in-reader" } }) }
    }
    if ($Path -match '/providers/Microsoft\.Authorization/roleDefinitions/[^/?]+\?')
    {
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
        param([string[]]$Subs, [string[]]$Fail = @(), [string[]]$Hang = @(), [string[]]$Disabled = @(), [string[]]$NoZip = @(), [string[]]$ReadOnlyAfter = @(), [string]$FailReason, [switch]$BlockStateWrite, [string[]]$Denied = @(), [switch]$ConsumptionDenied, [switch]$LoseZipOnFold, [string]$CutAfter, [int]$CutStream = 1, [string]$CutKind = 'cut short')
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
        param([string[]]$Arguments = @(), [int]$Streams = 1, [hashtable]$Environment = @{}, [scriptblock]$EndWhen, [int]$TimeoutSeconds = 300, [switch]$StrictMode)
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
        # A run ended this way is killed, so it leaves its run lock, which no
        # run takes over: the next run would stop on it and print the command
        # that removes it. That command is run here, as a user would run it.
        if ($Ended)
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
    # The strict-mode errors older code prints on the paths these tests run: the
    # file and the start of the source line each error quotes. Any other
    # error fails the strict-mode test (Get-UnknownStrictErrors). The same list
    # as Tests/ResumeByDefault.Tests.ps1.
    $script:KnownStrictErrors = @(
        'Common.Functions.ps1|if ($RoleRecord.Failed)'
        'Common.Functions.ps1|if ($CheckResult.Failed)'
        'Run-AllSubscriptions.ps1|if ($ConsumptionRecords -gt 0 -or $ConsumptionFailures.Count -gt 0)'
        'Run-AllSubscriptions.ps1|if ($ConsumptionFailures.Count -gt 0)'
        'Run-AllSubscriptions.ps1|if ($MetricsFailures.Count -gt 0)'
        'Run-AllSubscriptions.ps1|if ($CollectorFailuresList.Count -gt 0)'
        'Run-AllSubscriptions.ps1|if ($ConsumptionAuthSkipped.Count -gt 0)'
        'Run-AllSubscriptions.ps1|if ($MetricsAuthSkipped.Count -gt 0)'
        'Run-AllSubscriptions.ps1|if ($FailedAttempts.Count -eq 0)'
        'Run-AllSubscriptions.ps1|if ($ScopeForProbe.Count -gt 0)'
        'Run-AllSubscriptions.ps1|if (-not $SkipConsumption -and $ConsumptionCheckScope.Count -gt 0)'
        'Run-AllSubscriptions.ps1|elseif (($FailedAttempts.Count - $RetryLimited.Count) -gt 0)'
    )
    # Every strict-mode error a run printed on stderr, as '<file>|<source line>',
    # and every collection error on stdout other than the exit code read after
    # each subscription (older code), that is not on the known list.
    function script:Get-UnknownStrictErrors
    {
        param($Run)
        $Found = [System.Collections.Generic.List[string]]::new()
        $File = $null
        foreach ($Line in @(([string]$Run.Error) -split "`r?`n"))
        {
            $Plain = $Line -replace "`e\[[0-9;]*m", ''
            if ($Plain -match '^\S+Exception: (.+):(\d+)\s*$' -or $Plain -match '^\S+: (/.+\.ps1):(\d+)\s*$') { $File = Split-Path -Path $Matches[1] -Leaf; continue }
            if ($null -ne $File -and $Plain -match '^\s*\d+ \|\s(.*)$') { $Found.Add(('{0}|{1}' -f $File, $Matches[1].Trim().TrimEnd([char]0x2026).TrimEnd())); $File = $null }
        }
        foreach ($Line in @($Run.Text | Where-Object { $_ -match '^(\[stream-\d+\] )?ERROR processing subscription ' }))
        {
            if ($Line -notmatch "The variable '\`$LASTEXITCODE' cannot be retrieved because it has not been set\.$") { $Found.Add('stdout|' + $Line) }
        }
        @($Found | Where-Object { $E = $_; @($script:KnownStrictErrors | Where-Object { $E -eq $_ -or $E.StartsWith($_) -or $_.StartsWith($E) }).Count -eq 0 })
    }
}

AfterAll {
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'Parallel -Resume collects only what no earlier run completed' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

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
        # The automatic count follows the host (its memory caps it; 4 logical
        # processors are set), so the parallel-path lines are expected only when
        # the run printed two or more streams. The rest holds on either path.
        $Count = script:Get-StreamCount $R1
        if ($Streams -gt 0) { $Count | Should -Be $Streams }
        if ($Count -ge 2) { $R1.Text | Should -Contain 'Parallel-streams mode: 2 streams across 2 subscription(s) to process' }
        $R1.Text | Should -Contain 'Subscriptions Skipped:   2 (already completed)'
        $R1.Text | Should -Contain 'Subscriptions Processed: 2'
        (script:Read-State).Completed | Should -Be (script:Get-Ids 'A', 'B', 'C')
        (script:Read-State).Failed | Should -Be (script:Get-Ids 'D')
        # The consolidated zip carries the earlier reports of the skipped A and B
        # next to C's, collected by this run.
        @(script:Get-NewestBundleReportIds | Sort-Object -Unique) | Should -Be (script:Get-Ids 'A', 'B', 'C')

        # Run 2: only D is left; it goes on the one-subscription path and the state clears.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams -Environment $script:FourCpu
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'D')
        if ((script:Get-StreamCount $R2) -ge 2) { $R2.Text | Should -Contain 'Only one subscription to process; running sequentially.' }
        $R2.Text | Should -Contain 'Subscriptions Skipped:   3 (already completed)'
        script:Test-CleanLine $R2 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
        $R2.ExitCode | Should -Be 0
        # The consolidated zip of run 2 holds D's report, collected by this run,
        # and the earlier reports of the three subscriptions it skipped.
        @(script:Get-NewestBundleReportIds | Where-Object { $_ -eq 'sub-d' }).Count | Should -Be 1
        @(script:Get-NewestBundleReportIds | Sort-Object -Unique) | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
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

    It 'on a -Resume whose stream files list earlier completions, each stream''s end line counts only its slice, and the next run''s lines too' {
        # Streams 0 and 1 of the interrupted run list Sub A and Sub B as completed;
        # the -Resume gives stream 0 Sub D and Sub F, and stream 1 Sub E.
        script:Invoke-InterruptedThreeStreamRun
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F'
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'D', 'E', 'F')
        @($R1.Text | Where-Object { $_ -match '^\[stream-\d+\] complete: ' } | Sort-Object) | Should -Be @(
            '[stream-0] complete: 2/2 succeeded, 0 failed',
            '[stream-1] complete: 1/1 succeeded, 0 failed'
        )
        script:Test-CleanLine $R1 | Should -BeTrue

        # Run 2 finds no state: three subscriptions in each slice.
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        $R2.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        @($R2.Text | Where-Object { $_ -match '^\[stream-\d+\] complete: ' } | Sort-Object) | Should -Be @(
            '[stream-0] complete: 3/3 succeeded, 0 failed',
            '[stream-1] complete: 3/3 succeeded, 0 failed'
        )
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

Describe 'A resume state that lists one completed subscription' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'stays a list of ids when the next one completes, and the next -Resume collects neither (-ParallelStreams <Streams>)' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        # A one-stream run: A completes and B fails, so the state lists one completed id.
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $null = script:Invoke-Wrapper -Streams 1
        @((Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json).CompletedSubscriptionIds) | Should -Be @('sub-a')

        # Run 1: B completes now, and C fails, which keeps the state.
        script:Set-Scenario -Subs 'A', 'B', 'C' -Fail 'C'
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'B', 'C')
        $Stored = @((Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json).CompletedSubscriptionIds)
        $Stored.Count | Should -Be 2 -Because 'each completed id is its own entry, not joined onto the one before it'
        @($Stored | Sort-Object) | Should -Be (script:Get-Ids 'A', 'B')
        (script:Read-State).Failed | Should -Be (script:Get-Ids 'C')

        # Run 2 collects neither A nor B.
        script:Set-Scenario -Subs 'A', 'B', 'C'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'C')
        $R2.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        $R2.Text | Should -Contain 'Skipping (already completed): Sub B (sub-b)'
        script:Test-CleanLine $R2 | Should -BeTrue
    }
}

Describe 'An exit before the startup fold of per-stream state' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'prints no error under Set-StrictMode -Version Latest' {
        # No subscriptions in the tenant: the run ends at its first checks.
        script:Set-Scenario -Subs @()
        $R = script:Invoke-Wrapper -Streams 1 -StrictMode
        $R.ExitCode | Should -Be 1
        $R.Text | Should -Contain ('ERROR: Get-AzSubscription returned no subscriptions for tenant {0}.' -f $script:Tenant)
        $R.Error | Should -BeNullOrEmpty
    }
}

Describe 'A one-stream run that clears the resume state deletes the per-stream files it folded in' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

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

        # Run 2 recovers nothing: -Resume skips nothing, -ResumeFailedOnly has no
        # unfinished run to retry, so it stops with exit 1.
        $R2 = script:Invoke-Wrapper -Arguments $Next -Streams 1
        script:Get-RecoveryLines $R2 | Should -BeNullOrEmpty
        $R2.Text | Should -Not -Contain 'Skipping (already completed): Sub A (sub-a)'
        if ($Next -eq '-Resume')
        {
            script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
            script:Test-CleanLine $R2 | Should -BeTrue
            $R2.ExitCode | Should -Be 0
        }
        else
        {
            $R2.Text | Should -Contain 'ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry. No resume state file for this tenant is in the inventory folder, so there is no retry list. It did not sign in, collect anything or write the resume state.'
            script:Get-Collected $R2 | Should -BeNullOrEmpty
            $R2.ExitCode | Should -Be 1
        }
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
    AfterEach { script:Write-FailedCaseRuns }

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

    It 'keeps them, with a warning naming them, while the resume state on disk holds <Disk>' -ForEach @(
        @{ Disk = 'an older record with the same run count (a failure reason)' }
        @{ Disk = 'no retry list' }
    ) {
        # Run 1, two streams, interrupted, with no resume state yet: stream 0
        # hangs on A; stream 1 fails B with a newer reason, its first failure,
        # then hangs on D.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -FailReason 'newer reason' -Hang 'A', 'D'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { (script:Test-Hanging 'A', 'D') -and ((script:Get-StreamFailedIds) -join ',') -eq 'sub-b' }
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        $InStream = @(script:Get-StreamFiles | ForEach-Object { @((Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).FailedAttempts) } | Where-Object { $_ -and $_.Id -eq 'sub-b' })
        $InStream.Count | Should -Be 1
        $InStream[0].Reason | Should -Be 'newer reason'
        [int]$InStream[0].Attempts | Should -Be 1
        # The resume state as an earlier run left it: B's earlier failure with the
        # same run count, or (written by a version without a retry list) none.
        $Earlier = [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2020-01-01T00:00:00.0000000+00:00'; Reason = 'earlier reason'; Attempts = 1 }
        $State = [ordered]@{ TenantID = $script:Tenant; CompletedSubscriptionIds = @() }
        if ($Disk -ne 'no retry list') { $State.FailedAttempts = @($Earlier) }
        $State.LastUpdated = '2020-01-01T00:00:00.0000000+00:00'
        # The id of the run that wrote the per-stream files, where the state holds one.
        $Existing = script:Read-StateFile
        if ($null -ne $Existing -and $null -ne $Existing.PSObject.Properties['RunId']) { $State.RunId = $Existing.RunId }
        [pscustomobject]$State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:State -Encoding utf8
        $Before = Get-Content -LiteralPath $script:State -Raw
        if ($Disk -ne 'no retry list') { [int]@((script:Read-StateFile).FailedAttempts)[0].Attempts | Should -Be 1 }

        # Run 2: every write of the resume state fails. B fails again, so it
        # keeps the state; A, C and D complete. (A subscription that is not
        # enabled is taken off the retry list, so it cannot keep the state.)
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -FailReason 'newer reason' -BlockStateWrite
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        script:Get-ErrorLines $R2 | Should -Be @('ERROR processing subscription Sub B: newer reason')
        $R2.Error | Should -BeNullOrEmpty
        @($R2.Text | Where-Object { $_ -like 'WARNING: Failed to persist resume state to*' }).Count | Should -BeGreaterThan 0
        script:Get-RecoveryLines $R2 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 0 completed, 1 failed subscription record(s).')
        Get-Content -LiteralPath $script:State -Raw | Should -Be $Before -Because 'no write of the resume state went through'
        @($R2.Text | Where-Object { $_ -like 'WARNING: The resume state file*' }) | Should -Be @(('WARNING: The resume state file .resume-state-{0}.json could not be written or read back with every record of the per-stream state files this run read at startup, so they are kept and a later -Resume reads them again: {1}' -f $script:Tenant, ($Names -join ', ')))
        script:Test-CleanLine $R2 | Should -BeFalse
        @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $Names -Because 'only they hold the newer record'

        # Run 3, writes work again and B succeeds: recovered once more, then
        # everything cleared. A, C and D are collected again, since run 2 could
        # not record them.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R3 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 0 completed, 1 failed subscription record(s).')
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        script:Get-ErrorLines $R3 | Should -BeNullOrEmpty
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        # Run 4 finds no state.
        $R4 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R4 | Should -BeNullOrEmpty
        $R4.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Test-CleanLine $R4 | Should -BeTrue
    }

    It 'uses the completed and failed subscriptions of a per-stream file holding a list this version does not keep, then moves it aside (the state <State>)' -ForEach @(@{ State = 'kept' }, @{ State = 'cleared' }) {
        # Run 1, two streams, interrupted: stream 0 completes A and fails B;
        # stream 1 hangs on D.
        script:Set-Scenario -Subs 'A', 'D', 'B', 'C' -Fail 'B' -Hang 'D'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { (script:Test-Hanging 'D') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-a' -and ((script:Get-StreamFailedIds) -join ',') -eq 'sub-b' }
        # The stream 0 file also holds a list of per-id records of a kind this version does not keep.
        $Name = '.resume-state-{0}-stream-0.json' -f $script:Tenant
        $File = Join-Path $script:Root $Name
        $Obj = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json
        @($Obj.Completed) | Should -Be @('sub-a')
        @($Obj.FailedAttempts | ForEach-Object { $_.Id }) | Should -Be @('sub-b')
        $Obj | Add-Member -NotePropertyName 'Notes' -NotePropertyValue @([pscustomobject]@{ Id = 'sub-a'; Text = 'kept by another version' })
        $Obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $File -Encoding utf8

        # Run 2: A is skipped as completed and B is retried; B fails again (the
        # state is kept) or succeeds (the state clears).
        if ($State -eq 'kept') { script:Set-Scenario -Subs 'A', 'D', 'B', 'C' -Fail 'B' } else { script:Set-Scenario -Subs 'A', 'D', 'B', 'C' }
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R2 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        $R2.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B', 'C', 'D')
        $Moved = @(Get-ChildItem -LiteralPath $script:Root -Force -File | Where-Object { $_.Name -match ('^{0}\.unused-\d{{8}}-\d{{6}}$' -f [regex]::Escape($Name)) })
        $Moved.Count | Should -Be 1
        @($R2.Text | Where-Object { $_ -like 'WARNING: The per-stream state file*' }) | Should -Be @(('WARNING: The per-stream state file {0} holds records this version does not keep (Notes); its completed and failed subscriptions were used. It was moved aside to {1}.' -f $Name, $Moved[0].Name))
        @($R2.Text | Where-Object { $_ -like 'WARNING: The resume state file*' }) | Should -BeNullOrEmpty
        script:Test-CleanLine $R2 | Should -BeFalse
        @(script:Get-StreamFiles) | Should -BeNullOrEmpty
        if ($State -eq 'kept')
        {
            (script:Read-State).Completed | Should -Be (script:Get-Ids 'A', 'C', 'D')
            (script:Read-State).Failed | Should -Be (script:Get-Ids 'B')
        }
        else { script:Read-State | Should -BeNullOrEmpty }
        @(script:Get-ZipEntries | Where-Object { $_.Name -like '*resume-state*' -or $_.Name -like '*.unused-*' -or $_.Text -like '*resume-state*' }) | Should -BeNullOrEmpty

        # Run 3 reads nothing of it and ends clean.
        script:Set-Scenario -Subs 'A', 'D', 'B', 'C'
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R3 | Should -BeNullOrEmpty
        script:Get-Collected $R3 | Should -Be $(if ($State -eq 'kept') { script:Get-Ids 'B' } else { script:Get-Ids 'A', 'B', 'C', 'D' })
        @($R3.Text | Where-Object { $_ -like 'WARNING:*' }) | Should -BeNullOrEmpty
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Root -Force -File | Where-Object { $_.Name -like '*.unused-*' }).Count | Should -Be 1 -Because 'the moved file is kept for inspection and read by no run'

        # Run 4 finds no state.
        $R4 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $R4.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Test-CleanLine $R4 | Should -BeTrue
    }

    It 'keeps them, with a warning naming them, while the resume state on disk holds an older report of a completed subscription' {
        # Only where the resume state records each completed subscription's report.
        if ((Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1') -Raw) -notmatch '(?m)^function Get-CompletedReports\b')
        {
            Set-ItResult -Skipped -Because 'this version does not record the report of each completed subscription in the resume state'
            return
        }
        # Run 0, one stream: A completes with a report, B fails.
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $null = script:Invoke-Wrapper -Streams 1
        $EarlierRecord = @((script:Read-StateFile).CompletedReports)[0]
        $Earlier = [string]$EarlierRecord.Zip
        # Run 1, a new run (-Fresh), two streams, interrupted (B disabled): stream
        # 0 collects A again, with a newer report, then D hangs; stream 1 hangs on C.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Disabled 'B' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 2 -EndWhen { (script:Test-Hanging 'C', 'D') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-a' }
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        $Newer = [string]@((Get-Content -LiteralPath (Join-Path $script:Root $Names[0]) -Raw | ConvertFrom-Json).Reports)[0].Zip
        $Newer | Should -Not -Be $Earlier
        # A new run starts with an empty completed list; the resume state on disk
        # is given A's earlier record back, so it holds an older report than the
        # per-stream file.
        $Obj = script:Read-StateFile
        $Obj.CompletedSubscriptionIds = @('sub-a')
        $Obj.CompletedReports = @($EarlierRecord)
        $Obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:State -Encoding utf8
        [string]@((script:Read-StateFile).CompletedReports)[0].Zip | Should -Be $Earlier

        # Run 2: every write of the resume state fails. B fails, which keeps
        # the state; C and D complete. (A subscription that is not enabled is
        # taken off the retry list, so it cannot keep the state.)
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -BlockStateWrite
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B', 'C', 'D')
        script:Get-ErrorLines $R2 | Should -Be @('ERROR processing subscription Sub B: stand-in failure for this subscription')
        $R2.Error | Should -BeNullOrEmpty
        @($R2.Text | Where-Object { $_ -like 'WARNING: The resume state file*' }) | Should -Be @(('WARNING: The resume state file .resume-state-{0}.json could not be written or read back with every record of the per-stream state files this run read at startup, so they are kept and a later -Resume reads them again: {1}' -f $script:Tenant, ($Names -join ', ')))
        @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $Names -Because 'only it holds the newer report'

        # Run 3, writes work again and B succeeds: the bundle carries A's newer report.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'B', 'C', 'D')
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
        $Bundle = @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'AllSubscriptions_*.zip' | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Bundle[0].FullName)
        try { $Entries = @($Archive.Entries | ForEach-Object { $_.FullName }) } finally { $Archive.Dispose() }
        $Entries | Should -Contain (Split-Path -Path $Newer -Leaf)
        $Entries | Should -Not -Contain (Split-Path -Path $Earlier -Leaf)

        # Run 4 finds no state.
        $R4 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R4 | Should -BeNullOrEmpty
        $R4.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
    }

    It 'keeps them while the resume state on disk was written without report records, and the next run writes the newer report into it' {
        # Only where the resume state records each completed subscription's report.
        if ((Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1') -Raw) -notmatch '(?m)^function Get-CompletedReports\b')
        {
            Set-ItResult -Skipped -Because 'this version does not record the report of each completed subscription in the resume state'
            return
        }
        # Run 0, one stream: A completes, B fails. Run 1, a new run (-Fresh), two
        # streams, interrupted (B disabled): stream 0 collects A again, with a
        # newer report, then D hangs; stream 1 hangs on C.
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $null = script:Invoke-Wrapper -Streams 1
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Disabled 'B' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 2 -EndWhen { (script:Test-Hanging 'C', 'D') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-a' }
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        $Newer = [string]@((Get-Content -LiteralPath (Join-Path $script:Root $Names[0]) -Raw | ConvertFrom-Json).Reports)[0].Zip
        # The resume state as a version without report records wrote it, listing
        # A as completed (run 1 was a new run, which starts with an empty list).
        $Obj = script:Read-StateFile
        $Obj.CompletedSubscriptionIds = @('sub-a')
        $Obj.PSObject.Properties.Remove('CompletedReports')
        $Obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:State -Encoding utf8
        @($Obj.CompletedSubscriptionIds) | Should -Be @('sub-a')

        # Run 2: every write of the resume state fails; B fails and keeps the state, C and D complete.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -BlockStateWrite
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B', 'C', 'D')
        script:Get-ErrorLines $R2 | Should -Be @('ERROR processing subscription Sub B: stand-in failure for this subscription')
        @($R2.Text | Where-Object { $_ -like 'WARNING: The resume state file*' }) | Should -Be @(('WARNING: The resume state file .resume-state-{0}.json could not be written or read back with every record of the per-stream state files this run read at startup, so they are kept and a later -Resume reads them again: {1}' -f $script:Tenant, ($Names -join ', ')))
        @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $Names -Because 'only it holds the newer report'
        $null -eq (script:Read-StateFile).PSObject.Properties['CompletedReports'] | Should -BeTrue

        # Run 3, writes work again and B still fails: the newer report is written into the state, and the stream files go.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B'
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $R3.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'B', 'C', 'D')
        @($R3.Text | Where-Object { $_ -like 'WARNING: The resume state file*' }) | Should -BeNullOrEmpty
        @(@((script:Read-StateFile).CompletedReports) | Where-Object { $_.Id -eq 'sub-a' } | ForEach-Object { [string]$_.Zip }) | Should -Be @($Newer)
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        # Run 4, B succeeds: the state clears and the bundle carries A's newer report.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R4 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R4 | Should -BeNullOrEmpty
        script:Get-Collected $R4 | Should -Be (script:Get-Ids 'B')
        script:Test-CleanLine $R4 | Should -BeTrue
        $Bundle = @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'AllSubscriptions_*.zip' | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Bundle[0].FullName)
        try { $Entries = @($Archive.Entries | ForEach-Object { $_.FullName }) } finally { $Archive.Dispose() }
        $Entries | Should -Contain (Split-Path -Path $Newer -Leaf)
    }

    It '-ResumeFailedOnly with nothing to retry, then the same and -Resume: the recovery line prints in the first run only' {
        # Interrupted 2-stream run in which nothing fails: A and B complete, then C and D hang.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { (script:Test-Hanging 'C', 'D') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-a,sub-b' }
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'

        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        script:Get-RecoveryLines $R1 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 2 completed, 0 failed subscription record(s).')
        script:Get-Collected $R1 | Should -BeNullOrEmpty
        $R1.ExitCode | Should -Be 2 -Because 'C and D are still owed'
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

        # Run 1: B fails again, so the state would be kept, but every write of it
        # fails; C and D complete.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -BlockStateWrite
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R1 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'B', 'C', 'D')
        script:Get-ErrorLines $R1 | Should -Be @('ERROR processing subscription Sub B: stand-in failure for this subscription')
        $R1.Error | Should -BeNullOrEmpty
        @($R1.Text | Where-Object { $_ -like 'WARNING: Failed to persist resume state to*' }).Count | Should -BeGreaterThan 0
        $Warning = @($R1.Text | Where-Object { $_ -like 'WARNING: The resume state file*' })
        $Warning.Count | Should -Be 1
        $Warning[0] | Should -Be ('WARNING: The resume state file .resume-state-{0}.json could not be written or read back with every record of the per-stream state files this run read at startup, so they are kept and a later -Resume reads them again: {1}' -f $script:Tenant, ($Names -join ', '))
        script:Test-CleanLine $R1 | Should -BeFalse
        @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $Names

        # Run 2: the state can be written again. The kept files are recovered,
        # A is skipped, B succeeds, C and D are collected again (run 1 could not
        # record them), and the state clears with the files.
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

Describe 'A run that ends early leaves no per-stream file it folded in' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'a -Resume run that stops with exit 2 deletes them, and the next two runs recover nothing' {
        # Interrupted 2-stream run: stream 0 completes A, stream 1 fails B, then C and D hang.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { script:Test-Hanging 'C', 'D' }
        @(script:Get-StreamFiles).Count | Should -Be 2

        # Run 1: C runs without writing its zip, so the output check stops the run with exit 2.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -NoZip 'C'
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $R1.ExitCode | Should -Be 2
        script:Get-RecoveryLines $R1 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty -Because 'the resume state holds their records, so the early exit deletes them'
        script:Get-RemoveWarningLines $R1 | Should -BeNullOrEmpty

        # Runs 2 and 3: no recovery line.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        foreach ($Run in 1..2)
        {
            $R = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
            script:Get-RecoveryLines $R | Should -BeNullOrEmpty
            @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
        }
    }
}

Describe 'A consolidated zip lost while the run summary is added to it keeps the resume state' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    # Run 1 loses the zip in the fold (the last write to it), after every report
    # was written. Its state must survive, so run 2 (-Resume) collects nothing,
    # carries the reports on disk into a new zip and clears the state; run 3
    # (-Resume, no state left) is an ordinary full run that ends clean. Exit:
    # the state clears in run 2, once a zip holds every report.
    It 'run 1 exits 2 and keeps the state, run 2 rebuilds the zip from the reports on disk, run 3 ends clean (-ParallelStreams <Streams>)' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        script:Set-Scenario -Subs 'A', 'B', 'C' -LoseZipOnFold
        $R1 = script:Invoke-Wrapper -Streams $Streams -Environment $script:LoseZipEnv
        $R1.ExitCode | Should -Be 2
        @($R1.Text | Where-Object { $_ -like 'ERROR: *AllSubscriptions_ResourcesReport_*.zip was lost while the run summary was added to it: the zip is not on disk.' }).Count | Should -Be 1
        script:Test-CleanLine $R1 | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Root -File -Filter 'AllSubscriptions_*.zip') | Should -BeNullOrEmpty
        (script:Read-State).Completed | Should -Be (script:Get-Ids 'A', 'B', 'C')
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
        $R1.Text | Should -Contain 'Fix the cause (for example, free up disk space), then run again with -Resume: it puts these reports into a new consolidated zip without collecting them again.'

        script:Set-Scenario -Subs 'A', 'B', 'C'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams -Environment $script:LoseZipEnv
        script:Get-Collected $R2 | Should -BeNullOrEmpty
        $R2.Text | Should -Contain 'Subscriptions Skipped:   3 (already completed)'
        script:Test-CleanLine $R2 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        $R2.ExitCode | Should -Be 0
        @(script:Get-NewestBundleReportIds | Sort-Object -Unique) | Should -Be (script:Get-Ids 'A', 'B', 'C')

        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams -Environment $script:LoseZipEnv
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        $R3.ExitCode | Should -Be 0
    }
}

Describe 'A per-stream or resume state file that cannot be removed' -Skip:(-not ($IsLinux -or $IsMacOS)) {
    BeforeAll {
        # A folder without write permission stops a removal in it, except for
        # root, which this test then cannot use.
        $Probe = Join-Path $script:TestBase ('ro-probe-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Probe -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Probe 'f') -Value 'x'
        & chmod 555 $Probe
        try { Remove-Item -LiteralPath (Join-Path $Probe 'f') -Force -ErrorAction Stop } catch { }
        $script:ReadOnlyHolds = Test-Path -LiteralPath (Join-Path $Probe 'f')
        & chmod 755 $Probe
    }
    BeforeEach { script:New-Case }
    AfterEach { if (Test-Path -LiteralPath $script:Root) { & chmod 755 $script:Root }; script:Write-FailedCaseRuns }

    It 'is named while the resume state is cleared; the state is kept, and the next run removes everything (one stream)' {
        if (-not $script:ReadOnlyHolds) { Set-ItResult -Skipped -Because 'a read-only folder does not stop a removal for this user'; return }
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { script:Test-Hanging 'C', 'D' }
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        $Names.Count | Should -Be 2

        # Run 1: B, C and D are collected, then the inventory root becomes read-only.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -ReadOnlyAfter 'D'
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'B', 'C', 'D')
        script:Test-CleanLine $R1 | Should -BeFalse
        $State = Split-Path -Path $script:State -Leaf
        $Lines = @(script:Get-RemoveWarningLines $R1)
        $Lines.Count | Should -Be 3
        @($Lines[0..1] | Sort-Object) | Should -Be @($Names | ForEach-Object { 'WARNING: Could not remove the per-stream state file {0}: Access to the path ''{1}'' is denied.' -f $_, (Join-Path $script:Root $_) })
        $Lines[2] | Should -Be ('  The resume state file {0} is kept, so the next -Resume reads the same state and the per-stream state file(s) above again. Once the folder can be written, remove the file(s) named above.' -f $State)
        @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $Names
        Test-Path -LiteralPath $script:State | Should -BeTrue

        # Run 2, the folder writable again: recovered once more, D collected
        # again (its completion could not be written), everything removed.
        & chmod 755 $script:Root
        # The read-only folder also refused the removal of R1's own run lock, and
        # R1 printed the command that removes it. The lock is never taken over,
        # so that command is run now that the folder can be written.
        $Remove = @(foreach ($Line in $R1.Text) { if ($Line -match 'To remove it now: (Remove-Item -LiteralPath .+ -Force)$') { $Matches[1] } })
        $Remove.Count | Should -Be 1 -Because 'the run says it could not remove its run lock, with the command that does'
        & ([scriptblock]::Create($Remove[0]))
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R2 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'D')
        script:Get-RemoveWarningLines $R2 | Should -BeNullOrEmpty
        script:Test-CleanLine $R2 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        # Run 3 finds no state.
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R3 | Should -BeNullOrEmpty
        $R3.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Test-CleanLine $R3 | Should -BeTrue
    }

    It 'is named while the resume state is kept, and the next run removes it (one stream)' {
        if (-not $script:ReadOnlyHolds) { Set-ItResult -Skipped -Because 'a read-only folder does not stop a removal for this user'; return }
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { script:Test-Hanging 'C', 'D' }
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)

        # Run 1: B fails again, so the state is kept; then the root becomes read-only.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -ReadOnlyAfter 'D'
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $Lines = @(script:Get-RemoveWarningLines $R1)
        $Lines.Count | Should -Be 3
        @($Lines[0..1] | Sort-Object) | Should -Be @($Names | ForEach-Object { 'WARNING: Could not remove the per-stream state file {0}: Access to the path ''{1}'' is denied.' -f $_, (Join-Path $script:Root $_) })
        $Lines[2] | Should -Be ('  The resume state file {0} is kept, so the next -Resume reads the same state and the per-stream state file(s) above again. Once the folder can be written, remove the file(s) named above.' -f (Split-Path -Path $script:State -Leaf))
        script:Test-CleanLine $R1 | Should -BeFalse
        @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $Names

        # Run 2, writable, B succeeds: recovered once more, everything removed.
        & chmod 755 $script:Root
        # The read-only folder also refused the removal of R1's own run lock, and
        # R1 printed the command that removes it. The lock is never taken over,
        # so that command is run now that the folder can be written.
        $Remove = @(foreach ($Line in $R1.Text) { if ($Line -match 'To remove it now: (Remove-Item -LiteralPath .+ -Force)$') { $Matches[1] } })
        $Remove.Count | Should -Be 1 -Because 'the run says it could not remove its run lock, with the command that does'
        & ([scriptblock]::Create($Remove[0]))
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R2 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B', 'D')
        script:Test-CleanLine $R2 | Should -BeTrue
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        # Run 3 finds no state.
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R3 | Should -BeNullOrEmpty
        script:Test-CleanLine $R3 | Should -BeTrue
    }

    It 'keeps the files of a parallel run''s streams while the resume state cannot be written, and the next run recovers them' {
        if (-not $script:ReadOnlyHolds) { Set-ItResult -Skipped -Because 'a read-only folder does not stop a removal for this user'; return }
        # Each stream writes its summary over a file that is already there, so it
        # can still write it once the root is read-only.
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        foreach ($N in 0, 1) { Set-Content -LiteralPath (Join-Path $script:Root ('.rda-stream-{0}-summary.json' -f $N)) -Value '{}' }
        # Run 1, two streams (A and C; B and D): once C and D are written, the root becomes read-only.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -ReadOnlyAfter 'C', 'D'
        $R1 = script:Invoke-Wrapper -Streams 2
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        $Names.Count | Should -Be 2 -Because 'the resume state could not be written, so the stream files hold the only record'
        $Lead = 'WARNING: The resume state file {0} could not be written or read back with every record of the per-stream state files this run''s streams wrote, so they are kept and a later -Resume reads them again: ' -f (Split-Path -Path $script:State -Leaf)
        $Lines = @(script:Get-RemoveWarningLines $R1)
        $Lines.Count | Should -Be 1
        $Lines[0] | Should -BeIn @(($Lead + ($Names -join ', ')), ($Lead + ($Names[1], $Names[0] -join ', ')))
        script:Test-CleanLine $R1 | Should -BeFalse

        # A stream writes its state file through a temporary file in the same
        # folder, so a stream whose last write came after the root became
        # read-only could not record its last subscription: that file keeps the
        # earlier record, whole, and the stream named the failed write.
        $InFiles = @(script:Get-StreamCompletedIds)
        $Missing = @(script:Get-Ids 'A', 'B', 'C', 'D' | Where-Object { $InFiles -notcontains $_ })
        @($R1.Text | Where-Object { $_ -match '^\[stream-\d+\] WARNING: failed to persist stream state to ' }).Count | Should -Be $Missing.Count

        # Run 2, writable: the stream files are recovered, what they do not record is collected, everything is removed.
        & chmod 755 $script:Root
        # The read-only folder also refused the removal of R1's own run lock, and
        # R1 printed the command that removes it. The lock is never taken over,
        # so that command is run now that the folder can be written.
        $Remove = @(foreach ($Line in $R1.Text) { if ($Line -match 'To remove it now: (Remove-Item -LiteralPath .+ -Force)$') { $Matches[1] } })
        $Remove.Count | Should -Be 1 -Because 'the run says it could not remove its run lock, with the command that does'
        & ([scriptblock]::Create($Remove[0]))
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-RecoveryLines $R2 | Should -Be @(('Recovered per-stream state from an interrupted parallel run: {0} completed, 0 failed subscription record(s).' -f $InFiles.Count))
        script:Get-Collected $R2 | Should -Be $Missing
        if ($Missing.Count -eq 0) { $R2.Text | Should -Contain 'Nothing left to process: every eligible subscription was completed by an earlier run.' }
        script:Test-CleanLine $R2 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        # Run 3 finds no state and collects all four with two streams.
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-RecoveryLines $R3 | Should -BeNullOrEmpty
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        script:Test-CleanLine $R3 | Should -BeTrue
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
    }

    It 'Remove-ResumeStateFiles and Remove-StreamStateFiles name what they cannot remove, keep the state file while a per-stream file is left, and remove all once they can' {
        if (-not $script:ReadOnlyHolds) { Set-ItResult -Skipped -Because 'a read-only folder does not stop a removal for this user'; return }
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
        $Dir = Join-Path $script:TestBase ('ro-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Stream = Join-Path $Dir '.resume-state-t-stream-0.json'
        $State = Join-Path $Dir '.resume-state-t.json'
        Set-Content -LiteralPath $Stream -Value '{}'
        Set-Content -LiteralPath $State -Value '{}'
        $Denied = 'WARNING: Could not remove the per-stream state file .resume-state-t-stream-0.json: Access to the path ''{0}'' is denied.' -f $Stream
        $Kept = '  The resume state file {0} is kept, so the next -Resume reads the same state and the per-stream state file(s) above again. Once the folder can be written, remove the file(s) named above.' -f '.resume-state-t.json'
        & chmod 555 $Dir
        try
        {
            $Out = @(Remove-ResumeStateFiles -StreamFiles @($Stream) -StateFile $State 6>&1)
            @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }) | Should -Be @($Stream, $State)
            @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ }) | Should -Be @($Denied, $Kept)
            $Out = @(Remove-StreamStateFiles -StreamFiles @($Stream) -StateFile $State 6>&1)
            @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }) | Should -Be @($Stream)
            @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ }) | Should -Be @($Denied, $Kept) -Because 'the stream-only removal prints the same lines'
            $Out = @(Remove-ResumeStateFiles -StateFile $State 6>&1)
            @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ }) | Should -Be @(
                ('WARNING: Could not remove the resume state file .resume-state-t.json: Access to the path ''{0}'' is denied.' -f $State)
                '  The next run reads it again and retries the removal.'
            )
        }
        finally { & chmod 755 $Dir }
        @(Remove-StreamStateFiles -StreamFiles @($Stream) -StateFile $State 6>&1) | Should -BeNullOrEmpty
        @(Remove-ResumeStateFiles -StateFile $State 6>&1) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $Stream | Should -BeFalse
        Test-Path -LiteralPath $State | Should -BeFalse
    }
}

Describe 'A per-stream state file the end-of-run merge cannot read' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'is named, moved aside and never reported as a clean run (stream file <Kind>, run 1 <Run1>)' -ForEach @(
        @{ Kind = 'cut short'; Run1 = 'without -Resume' }
        @{ Kind = 'empty'; Run1 = 'without -Resume' }
        @{ Kind = 'cut short'; Run1 = '-Resume' }
        @{ Kind = 'empty'; Run1 = '-Resume' }
    ) {
        # No run is killed: the stream files are written directly, or cut short by
        # the stand-in once the stream that wrote it has finished.
        $Resuming = $Run1 -eq '-Resume'
        if ($Resuming)
        {
            # An interrupted 3-stream run over A to F: A, B and C completed, D, E
            # and F were never reached. The write of the stream 2 file was cut short.
            script:New-InterruptedStreamState -Streams @{ 0 = @('A'); 1 = @('B'); 2 = @('C') }
            $Bad = Join-Path $script:Root ('.resume-state-{0}-stream-2.json' -f $script:Tenant)
            if ($Kind -eq 'empty') { [System.IO.File]::WriteAllBytes($Bad, [byte[]]@()) }
            else { $Raw = Get-Content -LiteralPath $Bad -Raw; Set-Content -LiteralPath $Bad -Value $Raw.Substring(0, [int]($Raw.Length / 2)) -NoNewline -Encoding utf8 }
            script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F'
            $Name = '.resume-state-{0}-stream-2.json' -f $script:Tenant
        }
        else
        {
            # 2 streams over A, B and C: stream 0 holds A and C, stream 1 holds B.
            # Once B's stream has finished, C's run cuts its state file short, so
            # the run reads it only in its end-of-run merge.
            script:Set-Scenario -Subs 'A', 'B', 'C' -CutAfter 'C' -CutStream 1 -CutKind $Kind
            $Name = '.resume-state-{0}-stream-1.json' -f $script:Tenant
        }

        $R1 = script:Invoke-Wrapper -Arguments @(if ($Resuming) { '-Resume' }) -Streams 2
        # On -Resume, C was recorded only in the unreadable file, so it is collected.
        script:Get-Collected $R1 | Should -Be $(if ($Resuming) { script:Get-Ids 'C', 'D', 'E', 'F' } else { script:Get-Ids 'A', 'B', 'C' })
        $Warnings = @(script:Get-StreamWarningLines $R1)
        $Warnings.Count | Should -Be 1
        script:Test-CleanLine $R1 | Should -BeFalse
        $Moved = @(script:Get-StreamLikeFiles)
        $Moved.Count | Should -Be 1
        $Moved[0].Name | Should -Match ('^{0}\.unreadable-\d{{8}}-\d{{6}}$' -f [regex]::Escape($Name))
        @(script:Get-StreamFiles) | Should -BeNullOrEmpty
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
        script:Set-Scenario -Subs 'A', 'B', 'C'
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

Describe 'The run id ties per-stream state files to the run that wrote them' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'a new run (-Fresh) after an interrupted parallel run: the next <Next> collects what that run failed (-ParallelStreams <Streams>)' -ForEach @(
        @{ Streams = 1; Next = '-Resume' }, @{ Streams = 2; Next = '-Resume' },
        @{ Streams = 1; Next = '-ResumeFailedOnly' }, @{ Streams = 2; Next = '-ResumeFailedOnly' }) {
        # Run 1, interrupted 3-stream run: A, B and C complete in their stream files, D, E and F hang.
        script:Invoke-InterruptedThreeStreamRun
        $FirstId = [string](script:Read-StateFile).RunId
        $FirstId | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        @(script:Get-StreamFiles | ForEach-Object { [string](Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).RunId } | Sort-Object -Unique) | Should -Be @($FirstId)

        # Run 2, -Fresh: C fails now. It starts a new id; with two
        # streams, its end-of-run merge leaves the stream 2 file of run 1 alone.
        # It does not end clean, so it names run 1's files still on disk.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F' -Fail 'C'
        $R2 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams $Streams
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D', 'E', 'F')
        $SecondId = [string](script:Read-StateFile).RunId
        $SecondId | Should -Not -Be $FirstId
        (script:Read-State).Failed | Should -Be (script:Get-Ids 'C')
        (script:Read-State).Completed | Should -Not -Contain 'sub-c'
        script:Get-RecoveryLines $R2 | Should -BeNullOrEmpty
        $Others = @(script:Get-StreamFiles | Where-Object { [string](Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).RunId -eq $FirstId } | ForEach-Object { $_.Name } | Sort-Object)
        $Others.Count | Should -Be $(if ($Streams -eq 1) { 3 } else { 1 })
        $Line = 'The per-stream state files {0} were written by another run, so this run does not use them; they are left in place.' -f ($Others -join ', ')
        @($R2.Text | Where-Object { $_ -like 'The per-stream state files * were written by another run*' }) | Should -Be @($Line)

        # Run 2 did not end clean, so they are left.
        @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $Others

        # Run 3: C is collected, not skipped; run 1's files are not used, and
        # since run 3 ends clean it removes them.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F'
        $R3 = script:Invoke-Wrapper -Arguments $Next -Streams $Streams
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'C')
        $R3.Text | Should -Not -Contain 'Skipping (already completed): Sub C (sub-c)'
        script:Get-RecoveryLines $R3 | Should -BeNullOrEmpty
        script:Test-CleanLine $R3 | Should -BeTrue
        @($R3.Text | Where-Object { $_ -like 'The per-stream state files * were written by another run*' }) | Should -BeNullOrEmpty
        @($R3.Text | Where-Object { $_ -like 'Removed the per-stream state files*' }) | Should -Be @(('Removed the per-stream state files {0}, which another run wrote and no run can resume.' -f ($Others -join ', ')))
        script:Read-State | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        # Runs 4 and 5 find no state and end clean.
        foreach ($Run in 1..2)
        {
            $R = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams
            $R.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
            script:Get-RecoveryLines $R | Should -BeNullOrEmpty
            script:Test-CleanLine $R | Should -BeTrue
            @($R.Text | Where-Object { $_ -like 'Removed the per-stream state files*' -or $_ -like 'The per-stream state files*' }) | Should -BeNullOrEmpty
        }
    }

    It 'an interrupted -Resume keeps the id, so the next -Resume folds both runs'' files' {
        # Run 1, two streams, interrupted after A. Run 2, -Resume with two streams, interrupted after B.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'B', 'C'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { (script:Test-Hanging 'B', 'C') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-a' }
        $Id = [string](script:Read-StateFile).RunId
        Get-ChildItem -LiteralPath $script:CaseHome -Filter 'hang-*' -File | Remove-Item -Force
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'C', 'D'
        $null = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2 -EndWhen { (script:Test-Hanging 'C', 'D') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-a,sub-b' }
        [string](script:Read-StateFile).RunId | Should -Be $Id
        @(script:Get-StreamFiles | ForEach-Object { [string](Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).RunId } | Sort-Object -Unique) | Should -Be @($Id)

        # Run 3 folds both, collects C and D, and clears.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R3 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 2 completed, 0 failed subscription record(s).')
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'C', 'D')
        @($R3.Text | Where-Object { $_ -like 'The per-stream state files*' }) | Should -BeNullOrEmpty
        script:Test-CleanLine $R3 | Should -BeTrue
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        foreach ($Run in 1..2)
        {
            $R = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
            $R.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
            script:Test-CleanLine $R | Should -BeTrue
        }
    }

    It 'every save of the resume state keeps the id (-Resume, then -ResumeFailedOnly)' {
        # Run 1, without -Resume: B fails, which keeps the state.
        script:Set-Scenario -Subs 'A', 'B', 'C' -Fail 'B'
        $null = script:Invoke-Wrapper -Streams 1
        $Id = [string](script:Read-StateFile).RunId
        $Id | Should -Not -BeNullOrEmpty
        # Run 2, -Resume with two streams, interrupted: B completes, D hangs.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'D'
        $null = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2 -EndWhen { (script:Test-Hanging 'D') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-b' }
        [string](script:Read-StateFile).RunId | Should -Be $Id
        # Run 3, -Resume with one stream: the files are folded in, D fails.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'D'
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R3 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 0 failed subscription record(s).')
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'D')
        [string](script:Read-StateFile).RunId | Should -Be $Id
        # Run 4, -ResumeFailedOnly: D fails again.
        $R4 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        script:Get-Collected $R4 | Should -Be (script:Get-Ids 'D')
        [string](script:Read-StateFile).RunId | Should -Be $Id
        # Run 5, -ResumeFailedOnly: D succeeds and the state clears.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R5 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        script:Get-Collected $R5 | Should -Be (script:Get-Ids 'D')
        script:Test-CleanLine $R5 | Should -BeTrue
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
    }

    It 'a start-of-run write that fails says what a later run may not see; with no resume state file, the next -Resume continues the run from its per-stream record' {
        # Run 1, two streams, interrupted after A, while every write of the resume state fails.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'B', 'C' -BlockStateWrite
        $R1 = script:Invoke-Wrapper -Streams 2 -EndWhen { (script:Test-Hanging 'B', 'C') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-a' }
        @($R1.Text | Where-Object { $_ -like 'WARNING: The resume state file*could not be written at the start*' }) | Should -Be @(($script:StartWriteWarning -f $script:Tenant))
        script:Read-StateFile | Should -BeNullOrEmpty
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)

        # Run 2, writes work: there is no resume state file, and each stream file
        # carries run 1's id and record, so run 2 continues run 1 from them: A is
        # skipped, the rest is collected, and run 2 ends clean, removing them.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $R2.Text | Should -Contain ('The resume state file is not in the inventory folder, so this run checks the start time, settings and cost window that the per-stream state files of the unfinished run record ({0}).' -f ($Names -join ', '))
        script:Get-RecoveryLines $R2 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 0 failed subscription record(s).')
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B', 'C', 'D')
        script:Test-CleanLine $R2 | Should -BeTrue
        @($R2.Text | Where-Object { $_ -like 'Removed the per-stream state files*' }) | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty

        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $R3.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Test-CleanLine $R3 | Should -BeTrue
    }

    It 'a run that does not end clean names only the files of another run still on disk (-Resume with two streams)' {
        # Run 1, interrupted 3-stream run: A, B and C complete in stream files 0, 1 and 2.
        script:Invoke-InterruptedThreeStreamRun
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        # Run 2, -Fresh, one stream: C and D fail. Run 1's three files are left and named.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F' -Fail 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        @($R2.Text | Where-Object { $_ -like 'The per-stream state files * were written by another run*' }) | Should -Be @(('The per-stream state files {0} were written by another run, so this run does not use them; they are left in place.' -f ($Names -join ', ')))
        # Run 3, -Resume with two streams: C fails again, D completes. Its
        # streams write over the stream 0 and 1 files and its merge removes
        # them, so only run 1's stream 2 file is left, and only it is named.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F' -Fail 'C'
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'C', 'D')
        script:Test-CleanLine $R3 | Should -BeFalse
        @(script:Get-StreamFiles | ForEach-Object { $_.Name }) | Should -Be @($Names[2])
        @($R3.Text | Where-Object { $_ -like 'The per-stream state files * were written by another run*' }) | Should -Be @(('The per-stream state files {0} were written by another run, so this run does not use them; they are left in place.' -f $Names[2]))
        # Run 4, -Resume: C completes, the run ends clean and removes that file; run 5 finds no state.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F'
        $R4 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-Collected $R4 | Should -Be (script:Get-Ids 'C')
        script:Test-CleanLine $R4 | Should -BeTrue
        @($R4.Text | Where-Object { $_ -like 'Removed the per-stream state files*' }) | Should -Be @(('Removed the per-stream state files {0}, which another run wrote and no run can resume.' -f $Names[2]))
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
        $R5 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        $R5.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Test-CleanLine $R5 | Should -BeTrue
    }

    It 'a folder with content at the resume state''s temporary path: the run warns with the command that removes it, collects and prints nothing on stderr' {
        # A non-empty folder where every write of the resume state puts its temporary file.
        New-Item -ItemType Directory -Path ($script:State + '.tmp') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path ($script:State + '.tmp') 'kept') -Value 'x'
        script:Set-Scenario -Subs 'A', 'B'
        $R1 = script:Invoke-Wrapper -Streams 1
        $R1.ExitCode | Should -Be 0
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B')
        script:Get-ErrorLines $R1 | Should -BeNullOrEmpty
        $R1.Error | Should -BeNullOrEmpty
        @($R1.Text | Where-Object { $_ -like 'WARNING: The resume state file*could not be written at the start*' }) | Should -Be @(($script:StartWriteWarning -f $script:Tenant))
        @($R1.Text | Where-Object { $_ -like 'WARNING: Failed to persist resume state to*' }).Count | Should -BeGreaterThan 0
        # Each failed write names the folder and the command that removes it.
        $Folder = @($R1.Text | Where-Object { $_ -like 'WARNING: * is a folder with content*' } | Sort-Object -Unique)
        $Folder | Should -Be @(("WARNING: {0} is a folder with content, so no write of the resume state can succeed while it is there. Check what it holds, then remove it: rm -r '{0}'" -f ($script:State + '.tmp')))
        # The folder is left as it was.
        Test-Path -LiteralPath (Join-Path ($script:State + '.tmp') 'kept') -PathType Leaf | Should -BeTrue
        script:Test-CleanLine $R1 | Should -BeFalse

        # Once the folder is gone, -Fresh (the next step the warning names)
        # writes the state and ends clean; the next -Resume finds no state.
        Get-ChildItem -LiteralPath ($script:State + '.tmp') -Force | Remove-Item -Force
        Remove-Item -LiteralPath ($script:State + '.tmp') -Force
        $R2 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B')
        $R2.Error | Should -BeNullOrEmpty
        script:Test-CleanLine $R2 | Should -BeTrue
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $R3.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Test-CleanLine $R3 | Should -BeTrue
    }

    It 'an empty folder at the resume state''s temporary path is removed by the first failed write, and later writes succeed' {
        New-Item -ItemType Directory -Path ($script:State + '.tmp') -Force | Out-Null
        # Run 1, without -Resume: A and B complete, C fails.
        script:Set-Scenario -Subs 'A', 'B', 'C' -Fail 'C'
        $R1 = script:Invoke-Wrapper -Streams 1
        # A failed subscription is exit 2.
        $R1.ExitCode | Should -Be 2
        $R1.Error | Should -BeNullOrEmpty
        script:Get-ErrorLines $R1 | Should -Be @('ERROR processing subscription Sub C: stand-in failure for this subscription')
        # The start-of-run write fails on the folder and removes it; every later write succeeds.
        @($R1.Text | Where-Object { $_ -like 'WARNING: The resume state file*could not be written at the start*' }) | Should -Be @(($script:StartWriteWarning -f $script:Tenant))
        @($R1.Text | Where-Object { $_ -like 'WARNING: Failed to persist resume state to*' -or $_ -like 'WARNING: * is a folder with content*' }) | Should -BeNullOrEmpty
        Test-Path -LiteralPath ($script:State + '.tmp') | Should -BeFalse
        [string](script:Read-StateFile).RunId | Should -Not -BeNullOrEmpty
        (script:Read-State).Completed | Should -Be (script:Get-Ids 'A', 'B')
        (script:Read-State).Failed | Should -Be (script:Get-Ids 'C')
        # Run 2, -Resume: A and B are skipped, C completes, the run ends clean; run 3 finds no state.
        script:Set-Scenario -Subs 'A', 'B', 'C'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'C')
        script:Test-CleanLine $R2 | Should -BeTrue
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $R3.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Test-CleanLine $R3 | Should -BeTrue
    }

    It 'a run that stops early names the files of another run still on disk, and the next clean -Resume removes them' {
        # Run 1, interrupted 3-stream run: A, B and C complete in stream files 0, 1 and 2.
        script:Invoke-InterruptedThreeStreamRun
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        # Run 2, -Fresh, one stream: D writes no zip, so the output check stops the run with exit 2.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F' -NoZip 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $R2.ExitCode | Should -Be 2
        $R2.Error | Should -BeNullOrEmpty
        @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $Names
        @($R2.Text | Where-Object { $_ -like 'The per-stream state files * were written by another run*' }) | Should -Be @(('The per-stream state files {0} were written by another run, so this run does not use them; they are left in place.' -f ($Names -join ', ')))
        # Run 3, -Resume: the run ends clean and removes run 1's files; run 4 finds no state.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F'
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R3 | Should -BeNullOrEmpty
        script:Test-CleanLine $R3 | Should -BeTrue
        @($R3.Text | Where-Object { $_ -like 'Removed the per-stream state files*' }) | Should -Be @(('Removed the per-stream state files {0}, which another run wrote and no run can resume.' -f ($Names -join ', ')))
        @($R3.Text | Where-Object { $_ -like 'The per-stream state files * were written by another run*' }) | Should -BeNullOrEmpty
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
        $R4 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $R4.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Test-CleanLine $R4 | Should -BeTrue
    }

    It 'a new run (-Fresh) whose every resume state write fails, after an interrupted run: its warnings say a later run may not see its results' {
        # Run 1, interrupted 3-stream run: A, B and C complete in stream files 0, 1 and 2; the resume state holds run 1's id.
        script:Invoke-InterruptedThreeStreamRun
        $Names = @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object)
        # Run 2, -Fresh, two streams, every write of the resume state fails: C fails.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F' -Fail 'C' -BlockStateWrite
        $R2 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 2
        $R2.Error | Should -BeNullOrEmpty
        @($R2.Text | Where-Object { $_ -like 'WARNING: The resume state file*could not be written at the start*' }) | Should -Be @(($script:StartWriteWarning -f $script:Tenant))
        $Lead = 'WARNING: The resume state file .resume-state-{0}.json could not be written or read back with every record of the per-stream state files this run''s streams wrote, so they are kept: ' -f $script:Tenant
        $Tail = '. The resume state file does not hold this run''s id, so a later run does not read them and may not see what this run completed or failed. Once the file can be written, start the next run with -Fresh.'
        $Lines = @($R2.Text | Where-Object { $_ -like 'WARNING: The resume state file*could not be written or read back*' })
        $Lines.Count | Should -Be 1
        $Lines[0] | Should -BeIn @(($Lead + ($Names[0], $Names[1] -join ', ') + $Tail), ($Lead + ($Names[1], $Names[0] -join ', ') + $Tail))
        @($R2.Text | Where-Object { $_ -like 'The per-stream state files * were written by another run*' }) | Should -Be @(('The per-stream state files {0} were written by another run, so this run does not use them; they are left in place.' -f $Names[2]))
        script:Test-CleanLine $R2 | Should -BeFalse

        # Run 3, the next step the warnings name: -Fresh, writes working. It
        # collects all six, ends clean and removes every earlier run's
        # per-stream file; the next -Resume finds no state.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D', 'E', 'F'
        $R3 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D', 'E', 'F')
        script:Test-CleanLine $R3 | Should -BeTrue
        @($R3.Text | Where-Object { $_ -like 'Removed the per-stream state files*' }) | Should -Be @(('Removed the per-stream state files {0}, which another run wrote and no run can resume.' -f ($Names -join ', ')))
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
        $R4 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        $R4.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Test-CleanLine $R4 | Should -BeTrue
    }

    It 'a new run (-Fresh) after an interrupted parallel run ships the report it made, not the earlier stream file''s' {
        if ((Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1') -Raw) -notmatch '(?m)^function Get-CompletedReports\b')
        {
            Set-ItResult -Skipped -Because 'this version does not record the report of each completed subscription in the resume state'
            return
        }
        # Run 1, two streams, interrupted: stream 0 completes A with a report, then hangs on C; stream 1 hangs on B.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'B', 'C'
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { (script:Test-Hanging 'B', 'C') -and ((script:Get-StreamCompletedIds) -join ',') -eq 'sub-a' }
        $Old = [string]@((Get-Content -LiteralPath (Join-Path $script:Root ('.resume-state-{0}-stream-0.json' -f $script:Tenant)) -Raw | ConvertFrom-Json).Reports)[0].Zip
        # Run 2, -Fresh, one stream: A completes with a new report, B fails.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B'
        $null = script:Invoke-Wrapper -Arguments '-Fresh' -Streams 1
        $New = [string]@(@((script:Read-StateFile).CompletedReports) | Where-Object { $_.Id -eq 'sub-a' })[0].Zip
        $New | Should -Not -Be $Old
        # Run 3, -Resume: B succeeds; A is skipped and its report from run 2 is carried.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'B')
        script:Test-CleanLine $R3 | Should -BeTrue
        $Bundle = @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'AllSubscriptions_*.zip' | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Bundle[0].FullName)
        try { $Entries = @($Archive.Entries | ForEach-Object { $_.FullName }) } finally { $Archive.Dispose() }
        $Entries | Should -Contain (Split-Path -Path $New -Leaf)
        $Entries | Should -Not -Contain (Split-Path -Path $Old -Leaf)
    }

    It 'a run without -Resume adds no strict-mode error with its run id: every error it prints is on a known line of older code (-ParallelStreams <Streams>)' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        script:Set-Scenario -Subs 'A', 'B'
        $R = script:Invoke-Wrapper -Streams $Streams -StrictMode
        # Older code on this path prints strict-mode errors (the role check, the
        # exit code read after each subscription, the end-of-run summary), which
        # also change the exit code, so the exit code is not asserted here.
        script:Get-Collected $R | Should -Be (script:Get-Ids 'A', 'B')
        script:Get-UnknownStrictErrors $R | Should -BeNullOrEmpty
    }

    It 'the strict-mode check reports an error on a line it does not know, and not one on a known line' {
        $Unknown = [pscustomobject]@{ Text = @(); Error = "PropertyNotFoundException: /x/tool/Run-AllSubscriptions.ps1:661`nLine |`n 661 |  if (`$RunId.Missing) { }`n     |      ~~~~~~`n" }
        @(script:Get-UnknownStrictErrors $Unknown) | Should -Be @('Run-AllSubscriptions.ps1|if ($RunId.Missing) { }')
        $Known = [pscustomobject]@{ Text = @(); Error = "PropertyNotFoundException: /x/tool/Functions/Common.Functions.ps1:942`nLine |`n 942 |          if (`$RoleRecord.Failed)`n     |              ~~~~~`n" }
        script:Get-UnknownStrictErrors $Known | Should -BeNullOrEmpty
        $Stdout = [pscustomobject]@{ Text = @('ERROR processing subscription Sub A: The property ''RunId'' cannot be found on this object.'); Error = '' }
        @(script:Get-UnknownStrictErrors $Stdout).Count | Should -Be 1
    }
}

Describe 'A run that stops before it starts collecting keeps the earlier run id' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'a new run (-Fresh) stopped by <Label> leaves the resume state as it was; the next -ResumeFailedOnly recovers the earlier run''s per-stream file and retries what it failed' -ForEach @(
        @{ Label = 'the up-front access check'; Stop = 'Access'; Streams = 1 },
        @{ Label = 'the up-front consumption check'; Stop = 'Consumption'; Streams = 2 },
        @{ Label = 'a missing parallel worker script'; Stop = 'Worker'; Streams = 2 }
    ) {
        # An earlier interrupted run (id run-earlier): Sub A completed in the
        # resume state, and its stream 1 holds Sub B completed and Sub C failed.
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $Now = (Get-Date).ToUniversalTime().ToString('o')
        Set-Content -LiteralPath $script:State -Value ('{"TenantID": "' + $script:Tenant + '", "CompletedSubscriptionIds": ["sub-a"], "FailedAttempts": [], "RunId": "run-earlier", "LastUpdated": "' + $Now + '"}') -Encoding utf8
        $Before = [System.IO.File]::ReadAllBytes($script:State)
        $Stream1 = Join-Path $script:Root ('.resume-state-{0}-stream-1.json' -f $script:Tenant)
        Set-Content -LiteralPath $Stream1 -Value ('{"Tenant": "' + $script:Tenant + '", "StreamId": "1", "RunId": "run-earlier", "Completed": ["sub-b"], "FailedAttempts": [{"Id": "sub-c", "Name": "Sub C", "LastFailedAt": "' + $Now + '", "Reason": "stand-in failure", "Attempts": 1}]}') -Encoding utf8
        $Worker = Join-Path (Split-Path -Path $script:Wrapper -Parent) 'Run-AllSubscriptions.Stream.ps1'
        switch ($Stop)
        {
            # #38 stops a run only when no subscription it checks can be read.
            'Access' { script:Set-Scenario -Subs 'A', 'B', 'C' -Denied 'A', 'B', 'C' }
            'Consumption' { script:Set-Scenario -Subs 'A', 'B', 'C' -ConsumptionDenied }
            'Worker' { script:Set-Scenario -Subs 'A', 'B', 'C'; Rename-Item -LiteralPath $Worker -NewName 'Run-AllSubscriptions.Stream.ps1.away' }
        }
        try
        {
            $R1 = script:Invoke-Wrapper -Arguments '-Fresh' -Streams $Streams
        }
        finally
        {
            if ($Stop -eq 'Worker') { Rename-Item -LiteralPath ($Worker + '.away') -NewName 'Run-AllSubscriptions.Stream.ps1' }
        }
        $R1.ExitCode | Should -Be 1
        $R1.Error | Should -BeNullOrEmpty
        if ($Stop -eq 'Worker') { $R1.Text | Should -Contain ('ERROR: parallel worker script not found at {0}.' -f $Worker) }
        script:Get-Collected $R1 | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllBytes($script:State) | Should -Be $Before
        @($R1.Text | Where-Object { $_ -like 'The per-stream state files * were written by another run*' }) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $Stream1 | Should -BeTrue
        script:Set-Scenario -Subs 'A', 'B', 'C'
        $R2 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 1
        $R2.ExitCode | Should -Be 0
        $R2.Error | Should -BeNullOrEmpty
        script:Get-RecoveryLines $R2 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'C')
        script:Test-CleanLine $R2 | Should -BeTrue
        @(script:Get-StreamLikeFiles) | Should -BeNullOrEmpty
    }
}

Describe 'The per-stream and resume state helpers' {
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

    It 'Get-ResumeStateRecordMismatch compares whole records: a retry entry with the same run count' {
        $Path = Join-Path $script:UnitDir '.resume-state-t2.json'
        $Earlier = [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = '2026-01-01T00:00:00.0000000+00:00'; Reason = 'earlier reason'; Attempts = 1 }
        $Newer = [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; LastFailedAt = (Get-Date).ToString('o'); Reason = 'newer reason'; Attempts = 1 }
        [pscustomobject]@{
            TenantID                 = 't'
            CompletedSubscriptionIds = @('sub-a')
            FailedAttempts           = @($Earlier)
            LastUpdated              = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding utf8
        # The same run count with another reason and time: not held.
        Get-ResumeStateRecordMismatch -Path $Path -Tenant 't' -Ids @('sub-a', 'sub-b') -CompletedIds @('sub-a') -FailedAttempts @($Newer) | Should -Be @('sub-b')
        # The record as it was written (its time reads back as a date): held.
        @(Get-ResumeStateRecordMismatch -Path $Path -Tenant 't' -Ids @('sub-a', 'sub-b') -CompletedIds @('sub-a') -FailedAttempts @($Earlier)) | Should -BeNullOrEmpty
        # Under strict mode, a file without a retry list compares as none.
        '{"TenantID":"t","CompletedSubscriptionIds":["sub-a"]}' | Set-Content -LiteralPath $Path -Encoding utf8
        & { Set-StrictMode -Version Latest; Get-ResumeStateRecordMismatch -Path $Path -Tenant 't' -Ids @('sub-a', 'sub-b') -CompletedIds @('sub-a') -FailedAttempts @($Earlier) } | Should -Be @('sub-b')
    }

    It 'Get-ResumeStateRecordMismatch compares every list of per-id records either side holds' {
        $Path = Join-Path $script:UnitDir '.resume-state-t3.json'
        $Write = { param($State) $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding utf8 }
        $Report = { param($Zip) [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; Zip = $Zip; Obfuscated = $false } }
        $Run = @{ Path = $Path; Tenant = 't'; Ids = @('sub-a'); CompletedIds = @('sub-a'); FailedAttempts = @() }
        # A list in the file that this version does not keep: the run holds none of it.
        & $Write ([pscustomobject]@{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a'); FailedAttempts = @(); Notes = @([pscustomobject]@{ Id = 'sub-a'; Text = 'x' }) })
        Get-ResumeStateRecordMismatch @Run | Should -Be @('sub-a')
        # A key that reads as a name pattern matches no variable of the run either.
        & $Write ([pscustomobject]@{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a'); FailedAttempts = @(); 'Completed*' = @([pscustomobject]@{ Id = 'sub-a'; Text = 'x' }) })
        Get-ResumeStateRecordMismatch @Run | Should -Be @('sub-a')
        # Lists of ids, and lists without records, are not compared.
        & $Write ([pscustomobject]@{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a'); FailedAttempts = @(); NotReadableSubscriptionIds = @('sub-a'); Empty = @() })
        @(Get-ResumeStateRecordMismatch @Run) | Should -BeNullOrEmpty

        # A list this version keeps in a script variable, as a version that
        # records each completed subscription's report does.
        function Get-ResumeStateRecordLists
        {
            @(
                [pscustomobject]@{ State = 'CompletedSubscriptionIds'; Stream = 'Completed'; Run = 'CompletedIds'; CompletedOnly = $false }
                [pscustomobject]@{ State = 'FailedAttempts'; Stream = 'FailedAttempts'; Run = 'FailedAttempts'; CompletedOnly = $false }
                [pscustomobject]@{ State = 'CompletedReports'; Stream = 'Reports'; Run = 'CompletedReports'; CompletedOnly = $true }
            )
        }
        try
        {
            $script:CompletedReports = @(& $Report 'newer/report.zip')
            # The file has no such list: the record only the run holds is not held.
            & $Write ([pscustomobject]@{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a'); FailedAttempts = @() })
            Get-ResumeStateRecordMismatch @Run | Should -Be @('sub-a')
            # An older record: not held. The same record: held.
            & $Write ([pscustomobject]@{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a'); FailedAttempts = @(); CompletedReports = @(& $Report 'earlier/report.zip') })
            Get-ResumeStateRecordMismatch @Run | Should -Be @('sub-a')
            $script:CompletedReports = @(& $Report 'earlier/report.zip')
            @(Get-ResumeStateRecordMismatch @Run) | Should -BeNullOrEmpty
            # Two records for the id: the last one wins on each side.
            $script:CompletedReports = @((& $Report 'other/report.zip'), (& $Report 'earlier/report.zip'))
            @(Get-ResumeStateRecordMismatch @Run) | Should -BeNullOrEmpty
            # Such a list is compared for the ids the run holds as completed only.
            & $Write ([pscustomobject]@{ TenantID = 't'; CompletedSubscriptionIds = @(); FailedAttempts = @(); CompletedReports = @(& $Report 'other/report.zip') })
            @(Get-ResumeStateRecordMismatch -Path $Path -Tenant 't' -Ids @('sub-a') -CompletedIds @() -FailedAttempts @()) | Should -BeNullOrEmpty
            # The script's list is read, not a local of the same name in a calling function.
            & $Write ([pscustomobject]@{ TenantID = 't'; CompletedSubscriptionIds = @('sub-a'); FailedAttempts = @(); CompletedReports = @(& $Report 'earlier/report.zip') })
            $script:CompletedReports = @(& $Report 'newer/report.zip')
            function Invoke-WithLocalList { New-Variable -Name 'CompletedReports' -Value @(& $Report 'earlier/report.zip'); Get-ResumeStateRecordMismatch @Run }
            Invoke-WithLocalList | Should -Be @('sub-a')
        }
        finally
        {
            Remove-Variable -Name 'CompletedReports' -Scope Script -ErrorAction SilentlyContinue
        }
    }

    It 'Get-ResumeStateRunList reads the script variable of exactly that name' {
        try
        {
            $script:RdaTestList = @('script value')
            function Invoke-WithLocalValue { New-Variable -Name 'RdaTestList' -Value @('local value'); Get-ResumeStateRunList -Name 'RdaTestList' }
            Invoke-WithLocalValue | Should -Be @('script value')
            Get-ResumeStateRunList -Name 'RdaTest*' | Should -BeNullOrEmpty
            Get-ResumeStateRunList -Name 'NoSuchList' | Should -BeNullOrEmpty
        }
        finally
        {
            Remove-Variable -Name 'RdaTestList' -Scope Script -ErrorAction SilentlyContinue
        }
    }

    It 'Get-StreamStateUntrackedLists names the lists with entries that this version does not keep' {
        $Tracked = @(Get-ResumeStateRecordLists | ForEach-Object { $_.Stream })
        $State = [ordered]@{ Tenant = 't'; StreamId = '0'; LastUpdated = 'x'; Notes = @([pscustomobject]@{ Id = 'sub-a'; Text = 'x' }); Labels = @('one'); Empty = @() }
        foreach ($Name in $Tracked) { $State[$Name] = @([pscustomobject]@{ Id = 'sub-b' }) }
        Get-StreamStateUntrackedLists -State ([pscustomobject]$State | ConvertTo-Json -Depth 4 | ConvertFrom-Json) | Should -Be @('Notes', 'Labels')
        @(Get-StreamStateUntrackedLists -State ('{"Tenant":"t","StreamId":"0","Completed":["sub-a"],"FailedAttempts":[]}' | ConvertFrom-Json)) | Should -BeNullOrEmpty
        @(Get-StreamStateUntrackedLists -State $null) | Should -BeNullOrEmpty
        # The report records a stream worker writes ('Reports') are a list this
        # version keeps, so a per-stream file holding them is not renamed aside.
        @(Get-ResumeStateRecordLists | Where-Object { $_.Stream -eq 'Reports' } | ForEach-Object { $_.State }) | Should -Be @('CompletedReports')
        @(Get-StreamStateUntrackedLists -State ('{"Tenant":"t","StreamId":"0","Completed":["sub-a"],"FailedAttempts":[],"Reports":[{"Id":"sub-a","Name":"Sub A","Zip":"a.zip","Obfuscated":false}]}' | ConvertFrom-Json)) | Should -BeNullOrEmpty
    }

    It 'Get-ResumeStateRunId, Set-ResumeStateRunId, Test-StreamStateRunId and Save-CompletedSubscriptionIds carry the run id' {
        $Path = Join-Path $script:UnitDir '.resume-state-t4.json'
        Get-ResumeStateRunId -Path $Path -Tenant 't' | Should -BeNullOrEmpty
        try
        {
            # A save given no id writes the script's $RunId.
            $script:RunId = 'run-one'
            Save-CompletedSubscriptionIds -Path $Path -Tenant 't' -Ids @('sub-a')
            Get-ResumeStateRunId -Path $Path -Tenant 't' | Should -Be 'run-one'
            Get-ResumeStateRunId -Path $Path -Tenant 'other' | Should -BeNullOrEmpty
            Save-CompletedSubscriptionIds -Path $Path -Tenant 't' -Ids @('sub-a') -RunId 'run-two'
            Get-ResumeStateRunId -Path $Path -Tenant 't' | Should -Be 'run-two'
            Remove-Variable -Name 'RunId' -Scope Script
            # No id at all: the file holds none.
            Save-CompletedSubscriptionIds -Path $Path -Tenant 't' -Ids @('sub-a')
            Get-ResumeStateRunId -Path $Path -Tenant 't' | Should -BeNullOrEmpty
            $null -eq (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).PSObject.Properties['RunId'] | Should -BeTrue
        }
        finally
        {
            Remove-Variable -Name 'RunId' -Scope Script -ErrorAction SilentlyContinue
        }
        $With = '{"Tenant":"t","StreamId":"0","RunId":"x","Completed":["sub-a"],"FailedAttempts":[]}' | ConvertFrom-Json
        $Without = '{"Tenant":"t","StreamId":"0","Completed":["sub-a"],"FailedAttempts":[]}' | ConvertFrom-Json
        Test-StreamStateRunId -State $With -RunId 'x' | Should -BeTrue
        Test-StreamStateRunId -State $With -RunId 'y' | Should -BeFalse
        Test-StreamStateRunId -State $With -RunId '' | Should -BeFalse
        Test-StreamStateRunId -State $Without -RunId '' | Should -BeTrue
        Test-StreamStateRunId -State $Without -RunId 'x' | Should -BeFalse
        Test-StreamStateRunId -State $null -RunId '' | Should -BeFalse
        # Only a text RunId is compared: the number 5 is not the run id '5'. A
        # null RunId reads as none.
        $Numeric = '{"Tenant":"t","StreamId":"0","RunId":5,"Completed":["sub-a"],"FailedAttempts":[]}' | ConvertFrom-Json
        Test-StreamStateRunId -State $Numeric -RunId '5' | Should -BeFalse
        Test-StreamStateRunId -State $Numeric -RunId '' | Should -BeFalse
        $NullId = '{"Tenant":"t","StreamId":"0","RunId":null,"Completed":["sub-a"],"FailedAttempts":[]}' | ConvertFrom-Json
        Test-StreamStateRunId -State $NullId -RunId '' | Should -BeTrue
        Test-StreamStateRunId -State $NullId -RunId 'x' | Should -BeFalse
        # The start-of-run write keeps every other key of the file, and writes a
        # bare state when there is none or it is for another tenant.
        '{"TenantID":"t","CompletedSubscriptionIds":["sub-a"],"FailedAttempts":[],"Extra":[{"Id":"sub-a","Zip":"r.zip"}]}' | Set-Content -LiteralPath $Path -Encoding utf8
        Set-ResumeStateRunId -Path $Path -Tenant 't' -RunId 'run-three'
        $Kept = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $Kept.RunId | Should -Be 'run-three'
        @($Kept.CompletedSubscriptionIds) | Should -Be @('sub-a')
        @($Kept.Extra)[0].Zip | Should -Be 'r.zip'
        Set-ResumeStateRunId -Path $Path -Tenant 'other' -RunId 'run-four'
        $Bare = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $Bare.TenantID | Should -Be 'other'
        @($Bare.CompletedSubscriptionIds) | Should -BeNullOrEmpty
        $Bare.RunId | Should -Be 'run-four'
        # The worker's own read takes only its run's file.
        $Stream = Join-Path $script:UnitDir '.resume-state-t-stream-6.json'
        Set-Content -LiteralPath $Stream -Value '{"Tenant":"t","StreamId":"6","RunId":"x","Completed":["sub-a"],"FailedAttempts":[]}' -Encoding utf8
        @((Read-StreamState -Path $Stream -RunId 'x').Completed) | Should -Be @('sub-a')
        @((Read-StreamState -Path $Stream -RunId 'y').Completed) | Should -BeNullOrEmpty
    }

    It 'Remove-OtherRunStreamStateFiles removes only other runs'' readable files, and names one it cannot remove' {
        $Dir = Join-Path $script:UnitDir ('other-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Write = { param($N, $Body) Set-Content -LiteralPath (Join-Path $Dir ('.resume-state-t-stream-{0}.json' -f $N)) -Value $Body -Encoding utf8 }
        & $Write 0 '{"Tenant":"t","StreamId":"0","RunId":"run-one","Completed":["sub-a"],"FailedAttempts":[]}'
        & $Write 1 '{"Tenant":"t","StreamId":"1","RunId":"run-two","Completed":["sub-b"],"FailedAttempts":[]}'
        & $Write 2 '{"Tenant":"t","StreamId":"2","Completed":["sub-c"],"FailedAttempts":[]}'
        & $Write 3 '{"Tenant":"t","Stre'
        $Out = @(Remove-OtherRunStreamStateFiles -InventoryRoot $Dir -Tenant 't' -RunId 'run-two' 6>&1)
        @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ }) | Should -Be @('Removed the per-stream state files .resume-state-t-stream-0.json, .resume-state-t-stream-2.json, which another run wrote and no run can resume.')
        @(Get-ChildItem -LiteralPath $Dir -Force -File | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('.resume-state-t-stream-1.json', '.resume-state-t-stream-3.json')
        if ($IsLinux -or $IsMacOS)
        {
            & $Write 4 '{"Tenant":"t","StreamId":"4","RunId":"run-one","Completed":[],"FailedAttempts":[]}'
            & chmod 555 $Dir
            try
            {
                $Out = @(Remove-OtherRunStreamStateFiles -InventoryRoot $Dir -Tenant 't' -RunId 'run-two' 6>&1)
                if (Test-Path -LiteralPath (Join-Path $Dir '.resume-state-t-stream-4.json'))
                {
                    @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ }) | Should -Be @(('WARNING: Could not remove the per-stream state file .resume-state-t-stream-4.json, which another run wrote: Access to the path ''{0}'' is denied.' -f (Join-Path $Dir '.resume-state-t-stream-4.json')))
                    @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0].Left | Should -Be @('.resume-state-t-stream-4.json')
                }
            }
            finally { & chmod 755 $Dir }
        }
    }

    It 'Move-UntrackedStreamStateFiles renames a file holding a list this version does not keep, and says so when it cannot' {
        $Dir = Join-Path $script:UnitDir ('unused-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $With = Join-Path $Dir '.resume-state-t-stream-0.json'
        $Without = Join-Path $Dir '.resume-state-t-stream-1.json'
        Set-Content -LiteralPath $With -Value '{"Tenant":"t","StreamId":"0","Completed":["sub-a"],"FailedAttempts":[],"Notes":[{"Id":"sub-a"}]}' -Encoding utf8
        Set-Content -LiteralPath $Without -Value '{"Tenant":"t","StreamId":"1","Completed":["sub-b"],"FailedAttempts":[]}' -Encoding utf8
        $Now = [datetime]::new(2026, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
        $Out = @(Move-UntrackedStreamStateFiles -Files @($With, $Without) -Now $Now 6>&1)
        @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ }) | Should -Be @('WARNING: The per-stream state file .resume-state-t-stream-0.json holds records this version does not keep (Notes); its completed and failed subscriptions were used. It was moved aside to .resume-state-t-stream-0.json.unused-20260102-030405.')
        $Result = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        $Result.Left | Should -Be @($Without)
        $Result.Moved[0].MovedTo | Should -Be '.resume-state-t-stream-0.json.unused-20260102-030405'
        Test-Path -LiteralPath ($With + '.unused-20260102-030405') | Should -BeTrue
        # A rename that fails leaves the file and says so.
        Set-Content -LiteralPath $With -Value '{"Tenant":"t","StreamId":"0","Completed":[],"FailedAttempts":[],"Notes":[{"Id":"sub-a"}]}' -Encoding utf8
        Remove-Item -LiteralPath ($With + '.unused-20260102-030405') -Force
        New-Item -ItemType Directory -Path ($With + '.unused-20260102-030405') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path ($With + '.unused-20260102-030405') 'keep') -Value 'x'
        $Out = @(Move-UntrackedStreamStateFiles -Files @($With) -Now $Now 6>&1)
        @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ })[0] | Should -BeLike 'WARNING: The per-stream state file .resume-state-t-stream-0.json holds records this version does not keep (Notes); its completed and failed subscriptions were used. It could not be moved aside (*), so a later -Resume reads it again.'
        @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0].NotMoved | Should -Be @($With)
        Test-Path -LiteralPath $With | Should -BeTrue
    }

    It 'Get-StreamStateRecordIds lists every id a per-stream state file holds a record for' {
        $State = '{"Tenant":"t","StreamId":"0","Completed":["sub-a"],"FailedAttempts":[{"Id":"sub-b","Attempts":1}],"Reports":[{"Id":"sub-c","Zip":"r.zip"}]}' | ConvertFrom-Json
        Get-StreamStateRecordIds -State $State | Should -Be @('sub-a', 'sub-b', 'sub-c')
        @(Get-StreamStateRecordIds -State ('{"Tenant":"t","StreamId":"0","Completed":[],"FailedAttempts":[]}' | ConvertFrom-Json)) | Should -BeNullOrEmpty
    }

    It 'adds -2 to the name when it is taken, and -3 when that is taken too; the files already there are kept' {
        $Path = Join-Path $script:UnitDir '.resume-state-t-stream-7.json'
        $Base = '.resume-state-t-stream-7.json.unreadable-20260102-030405'
        Set-Content -LiteralPath (Join-Path $script:UnitDir $Base) -Value 'an earlier one' -Encoding utf8
        Set-Content -LiteralPath $Path -Value '{' -Encoding utf8
        $Now = ([datetime]'2026-01-02T03:04:05Z').ToUniversalTime()
        $Out = @(Move-UnreadableStreamStateFile -File (Get-Item -Force -LiteralPath $Path) -Now $Now 6>&1)
        $Result = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        $Result.MovedTo | Should -Be ($Base + '-2')
        $Result.NotMoved | Should -BeFalse
        @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ }) | Should -BeLike ('* It was moved aside to {0}-2.' -f $Base)
        # A second unreadable file of the same stream in the same second.
        Set-Content -LiteralPath $Path -Value '{"Tenant"' -Encoding utf8
        (Move-UnreadableStreamStateFile -File (Get-Item -Force -LiteralPath $Path) -Now $Now 6>$null).MovedTo | Should -Be ($Base + '-3')
        Get-Content -LiteralPath (Join-Path $script:UnitDir $Base) -Raw | Should -Be ('an earlier one' + [Environment]::NewLine)
        Get-Content -LiteralPath (Join-Path $script:UnitDir ($Base + '-2')) -Raw | Should -Be ('{' + [Environment]::NewLine)
        Get-Content -LiteralPath (Join-Path $script:UnitDir ($Base + '-3')) -Raw | Should -Be ('{"Tenant"' + [Environment]::NewLine)
        Test-Path -LiteralPath $Path | Should -BeFalse
    }

    It 'leaves the file in place and returns it for the stop when it cannot be renamed' {
        $Path = Join-Path $script:UnitDir '.resume-state-t-stream-4.json'
        Set-Content -LiteralPath $Path -Value '{' -Encoding utf8
        # The new name and -2 to -100 are all taken, so the rename fails.
        $Base = '.resume-state-t-stream-4.json.unreadable-20260102-030405'
        New-Item -ItemType Directory -Path (Join-Path $script:UnitDir $Base) -Force | Out-Null
        foreach ($N in 2..100) { New-Item -ItemType File -Path (Join-Path $script:UnitDir ('{0}-{1}' -f $Base, $N)) -Force | Out-Null }
        # At startup it prints nothing: the wrapper stops with exit 1 and names it.
        $Out = Move-UnreadableStreamStateFile -File (Get-Item -Force -LiteralPath $Path) -Now ([datetime]'2026-01-02T03:04:05Z').ToUniversalTime() 6>&1
        $Result = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        $Result.MovedTo | Should -BeNullOrEmpty
        $Result.NotMoved | Should -BeTrue
        $Result.Path | Should -Be $Path
        $Result.Reason | Should -Be ('every name from {0} to {0}-100 is taken' -f $Base)
        Test-Path -LiteralPath $Path | Should -BeTrue
        @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) | Should -BeNullOrEmpty
        # At the end of a run it names the file and says the run ends with the stop.
        $End = @(Move-UnreadableStreamStateFile -File (Get-Item -Force -LiteralPath $Path) -Now ([datetime]'2026-01-02T03:04:05Z').ToUniversalTime() -AtRunEnd 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ })
        $End[0] | Should -BeLike 'ERROR: The per-stream state file .resume-state-t-stream-4.json could not be read, and it could not be moved aside: *'
        $End[1] | Should -BeLike '*ends with exit 1 (exit 2 when a report is missing or a subscription failed), with what to do next at its end.'
        $Summary = @(Write-UnreadableStreamStateSummary -Unreadable @($Result) -StateKept $true 6>&1 | ForEach-Object { [string]$_ })
        $Summary | Should -Be @('Resume state kept, but not a clean run: the per-stream state file .resume-state-t-stream-4.json could not be read and was left in place (it could not be moved aside); its records were not used.')
    }

    It 'Remove-ResumeStateTempPath leaves a folder with content, and the command it prints removes it from a path holding a single quote' {
        $Folder = Join-Path (Join-Path $script:UnitDir "it's here") '.resume-state-t.json.tmp'
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Folder 'kept') -Value 'x' -Encoding utf8
        $Lines = @(Remove-ResumeStateTempPath -Path $Folder 6>&1 | ForEach-Object { [string]$_ })
        $Lines.Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $Folder 'kept') -PathType Leaf | Should -BeTrue
        $Lines[0] | Should -BeLike ('WARNING: {0} is a folder with content, so no write of the resume state can succeed while it is there. Check what it holds, then remove it: *' -f $Folder)
        $Command = $Lines[0].Substring($Lines[0].IndexOf(', then remove it: ') + ', then remove it: '.Length)
        if ($IsWindows)
        {
            $Command | Should -Be ("Remove-Item -LiteralPath '{0}' -Recurse" -f $Folder.Replace("'", "''"))
            & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command $Command
        }
        else
        {
            $Command | Should -Be ("rm -r '{0}'" -f $Folder.Replace("'", "'\''"))
            & /bin/sh -c $Command
        }
        Test-Path -LiteralPath $Folder | Should -BeFalse
        Test-Path -LiteralPath (Split-Path -Path $Folder -Parent) -PathType Container | Should -BeTrue
    }
}

Describe 'The recovery line after an interrupted parallel run' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

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
