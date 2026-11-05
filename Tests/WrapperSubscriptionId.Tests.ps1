# End to end: Run-AllSubscriptions.ps1 -SubscriptionID <id>.
#
#   - The run collects only that subscription, and its consolidated zip has
#     the same entries as a run on a tenant that holds only that subscription.
#   - An id that is not a GUID (or is empty) stops the run with exit 1 before
#     it creates any file; an id the tenant does not list, a subscription that
#     is not Enabled (without -IncludeDisabled) or one that cannot be read stop
#     it with exit 1 before it collects anything.
#   - Its resume state is its own file (key: tenant and subscription), so it
#     never marks other subscriptions completed, never takes them off a retry
#     list, never touches the per-stream state files of a run of the whole
#     tenant, and a run of the whole tenant never touches its state. Traced:
#     (a) one-subscription run, then a whole run; (b) whole run interrupted,
#     then one-subscription runs with -Resume, then the whole run; (c) the
#     one-subscription run twice, and four times while it fails (retry limit,
#     then -Fresh as the way out).
#   - Its printed commands carry -SubscriptionID; a run without it prints none.
# The helpers are also tested on their own.
#
# Every end-to-end run is Run-AllSubscriptions.ps1 itself, as its own pwsh
# process, from a copy of the tool whose ResourceInventory.ps1 is a stand-in,
# with stand-in Az modules answering from a scenario file (the harness of
# ResumeByDefault.Tests.ps1). On Windows the wrapper writes to
# C:\InventoryReports instead, so the end-to-end tests do not run there.
#
# Run with: Invoke-Pester ./Tests/WrapperSubscriptionId.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('WrapperSubscriptionIdTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
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
    # The stream summary is named with the run's key: .rda-stream-<run key>-<N>-summary.json.
    $Done = '.rda-stream-*-{0}-summary.json' -f $Cut.Stream
    $Deadline = (Get-Date).AddSeconds(240)
    while (@(Get-ChildItem -LiteralPath $Root -Force -File -Filter $Done -ErrorAction SilentlyContinue).Count -eq 0 -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 100 }
    $Target = Join-Path $Root ('.resume-state-{0}-stream-{1}.json' -f ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes(([string]$TenantID).Trim().ToLowerInvariant()))).Substring(0, 12).ToLowerInvariant()), $Cut.Stream)
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



    # Subscriptions by letter. Their ids are GUIDs, as -SubscriptionID takes.
    $script:Subs = @{}
    $N = 0
    foreach ($Letter in 'A', 'B', 'C', 'D')
    {
        $N++
        $script:Subs[$Letter] = @{ Id = ('{0}{0}{0}{0}{0}{0}{0}{0}-0000-4000-8000-00000000000{1}' -f $Letter.ToLowerInvariant(), $N); Name = ('Sub ' + $Letter) }
    }
    $script:GuidPattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

    # The file key of a text, as Get-TenantFileKey makes it.
    function script:Get-Key
    {
        param([string]$Text)
        [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text.Trim().ToLowerInvariant()))).Substring(0, 12).ToLowerInvariant()
    }

    function script:New-Case
    {
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseHome -Force | Out-Null
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        # The resume state file of a run of the whole tenant.
        $script:State = Join-Path $script:Root ('.resume-state-{0}.json' -f (script:Get-Key $script:Tenant))
        $script:CaseRuns = [System.Collections.Generic.List[object]]::new()
        $script:ErrorMark = $Error.Count
    }

    # The resume state file of a -SubscriptionID run of the subscription $Letter.
    function script:Get-OneState
    {
        param([string]$Letter)
        Join-Path $script:Root ('.resume-state-{0}.json' -f (script:Get-Key ('{0}/subscriptions/{1}' -f $script:Tenant, $script:Subs[$Letter].Id)))
    }

    function script:Write-FailedCaseRuns
    {
        if ($null -eq $script:CaseRuns -or $script:CaseRuns.Count -eq 0) { return }
        $New = @($Error | Select-Object -First ([math]::Max(0, $Error.Count - $script:ErrorMark)))
        if (@($New | Where-Object { $_.FullyQualifiedErrorId -eq 'PesterAssertionFailed' -or $_.CategoryInfo.Category -eq 'OperationStopped' }).Count -eq 0) { return }
        Write-Host ('--- The wrapper runs of this test ({0}), in order:' -f $script:CaseRuns.Count)
        $I = 0
        foreach ($Run in $script:CaseRuns)
        {
            $I++
            Write-Host ('--- run {0}: {1} | exit {2} | ended by the test: {3}' -f $I, $Run.Arguments, $Run.ExitCode, $Run.Ended)
            foreach ($Line in @($Run.Text)) { Write-Host ('  | ' + $Line) }
            foreach ($Line in @(([string]$Run.Error) -split "`r?`n" | Where-Object { $_ })) { Write-Host ('  ! ' + $Line) }
        }
    }

    function script:Set-Scenario
    {
        param([string[]]$Subs, [string[]]$Fail = @(), [string[]]$Hang = @(), [string[]]$Disabled = @(), [string[]]$Denied = @(), [string]$SignedInTenant)
        $Id = { param($L) $script:Subs[$L].Id }
        [pscustomobject]@{
            Tenant        = $(if ($SignedInTenant) { $SignedInTenant } else { $script:Tenant })
            Subscriptions = @($Subs | ForEach-Object { [pscustomobject]@{ Id = $script:Subs[$_].Id; Name = $script:Subs[$_].Name; State = $(if ($Disabled -contains $_) { 'Disabled' } else { 'Enabled' }) } })
            FailIds       = @($Fail | ForEach-Object { & $Id $_ })
            HangIds       = @($Hang | ForEach-Object { & $Id $_ })
            NoZipIds      = @()
            ReadOnlyAfterIds = @()
            DeniedIds     = @($Denied | ForEach-Object { & $Id $_ })
            RoleUnknownIds = @()
            FailReason    = $null
            BlockStateWrite = $false
            ConsumptionDenied = $false
            LoseZipOnFold = $false
            CutStreamFile = $null
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One run of the wrapper as its own process, stdin closed (as in
    # ResumeByDefault.Tests.ps1). -EndWhen is polled; once true the process tree
    # is killed and its run lock removed, as a user would after a closed window.
    function script:Invoke-Wrapper
    {
        param([string[]]$Arguments = @(), [int]$Streams = 1, [scriptblock]$EndWhen, [int]$TimeoutSeconds = 300, [string]$ModulePath, [switch]$StrictMode)
        $All = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper, '-TenantID', $script:Tenant)
        if ($Streams -gt 0) { $All += @('-ParallelStreams', [string]$Streams) }
        $All += @($Arguments)
        $Label = ((@($All | Select-Object -Skip 7) + @(if ($StrictMode) { '(strict mode)' })) -join ' ')
        # With -StrictMode the wrapper runs under Set-StrictMode -Version Latest,
        # set by the shell that starts it (as in ResumeByDefault.Tests.ps1).
        if ($StrictMode) { $All = @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', ("Set-StrictMode -Version Latest; & '{0}' {1}; exit `$LASTEXITCODE" -f $script:Wrapper, (@($All | Select-Object -Skip 5 | ForEach-Object { if ($_ -match '^-') { $_ } else { "'" + $_ + "'" } }) -join ' '))) }
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($Arg in @($All)) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $(if ($ModulePath) { $ModulePath } else { $script:Modules })
        $Info.Environment['RDA_STANDIN_AZURE'] = $script:Scenario
        $Info.Environment['NO_COLOR'] = '1'
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
            throw ('The wrapper run did not end within {0} seconds.' -f $TimeoutSeconds)
        }
        $Proc.WaitForExit()
        if ($Ended)
        {
            foreach ($Lock in @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*.json' -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $Lock.FullName -Force }
        }
        $Text = @(([string]$Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        $script:CaseRuns.Add([pscustomobject]@{ Arguments = $Label; ExitCode = $Proc.ExitCode; Ended = $Ended; Text = $Text; Error = [string]$Err.Result })
        if ($EndWhen -and -not $Ended) { throw 'The run ended before the point at which the test ends it.' }
        return [pscustomobject]@{ ExitCode = $Proc.ExitCode; Text = $Text; Error = [string]$Err.Result }
    }

    function script:Test-Hanging
    {
        param([string[]]$Letters)
        @($Letters | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:CaseHome ('hang-' + $script:Subs[$_].Id))) }).Count -eq 0
    }

    # A resume state file as { Completed; Failed; FailedCount (by id); TenantID }, or $null.
    function script:Read-StateAt
    {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $Raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $Counts = @{}
        foreach ($Entry in @($Raw.FailedAttempts | Where-Object { $_ })) { $Counts[[string]$Entry.Id] = $Entry }
        return [pscustomobject]@{
            Completed = @($Raw.CompletedSubscriptionIds | Where-Object { $_ } | Sort-Object)
            Failed    = @($Raw.FailedAttempts | Where-Object { $_ } | ForEach-Object { [string]$_.Id } | Sort-Object)
            Entries   = $Counts
            TenantID  = [string]$Raw.TenantID
        }
    }

    # The ids of the subscriptions a run started collecting, sorted.
    function script:Get-Collected
    {
        param($Run)
        @($Run.Text | ForEach-Object { if ($_ -match ('^(?:\[stream-\d+\] processing \(\d+ of \d+\): |Processing subscription: ).+ \((' + $script:GuidPattern + ')\)$')) { $Matches[1] } } | Sort-Object)
    }
    function script:Get-Ids { param([string[]]$Letters) @($Letters | ForEach-Object { $script:Subs[$_].Id } | Sort-Object) }

    # The subscription ids of the per-subscription reports inside the newest
    # consolidated zip, sorted.
    function script:Get-NewestBundleReportIds
    {
        $Newest = @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'AllSubscriptions_*.zip' | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)
        if ($Newest.Count -eq 0) { return @() }
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Newest[0].FullName)
        try { @($Archive.Entries | Where-Object { $_.FullName -like 'ResourcesReport_*.zip' } | ForEach-Object { $_.FullName -replace ('^.*\d(' + $script:GuidPattern + ')\.zip$'), '$1' } | Sort-Object) }
        finally { $Archive.Dispose() }
    }
    # The entry names of the newest consolidated zip, with the timestamps and
    # ids in them replaced, so two runs' zips can be compared by shape.
    function script:Get-NewestBundleShape
    {
        $Newest = @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'AllSubscriptions_*.zip' | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)
        if ($Newest.Count -eq 0) { return @() }
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Newest[0].FullName)
        try { @($Archive.Entries | ForEach-Object { ($_.FullName -replace $script:GuidPattern, '<id>') -replace '\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}', '<time>' -replace '\d{17}', '<stamp>' } | Sort-Object) }
        finally { $Archive.Dispose() }
    }
    function script:Get-Calls { @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'call-*.log' | ForEach-Object { (Get-Content -LiteralPath $_.FullName) -replace '\|.*$', '' }) }
    function script:Clear-Calls { Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'call-*.log' | Remove-Item -Force }
    # Every file and folder under the inventory root with its size, time and
    # hash, so a run that changes nothing there leaves the same list.
    function script:Get-RootSnapshot
    {
        if (-not (Test-Path -LiteralPath $script:Root)) { return @('(no inventory folder)') }
        $Lines = @('root|{0}' -f (Get-Item -LiteralPath $script:Root -Force).LastWriteTimeUtc.Ticks)
        foreach ($Item in @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force | Sort-Object FullName))
        {
            if ($Item.PSIsContainer) { $Lines += 'dir|{0}|{1}' -f $Item.FullName, $Item.LastWriteTimeUtc.Ticks }
            else { $Lines += 'file|{0}|{1}|{2}|{3}' -f $Item.FullName, $Item.Length, $Item.LastWriteTimeUtc.Ticks, (Get-FileHash -LiteralPath $Item.FullName -Algorithm SHA256).Hash }
        }
        return $Lines
    }
    function script:Get-FileHashOrNone { param([string]$Path) if (Test-Path -LiteralPath $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } else { 'none' } }
}

AfterAll {
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'The -SubscriptionID helpers' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
        . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    }

    It 'takes a GUID, with spaces around it and in any letter case' {
        Get-SubscriptionIdProblem -Value 'aaaaaaaa-0000-4000-8000-000000000001' | Should -BeNullOrEmpty
        Get-SubscriptionIdProblem -Value ' AAAAAAAA-0000-4000-8000-000000000001 ' | Should -BeNullOrEmpty
    }

    It 'gives a reason for <Value>' -ForEach @(
        @{ Value = ''; Reason = 'it is empty' }
        @{ Value = '   '; Reason = 'it is empty' }
        @{ Value = 'my-subscription'; Reason = 'it is not a subscription id*' }
        @{ Value = '{aaaaaaaa-0000-4000-8000-000000000001}'; Reason = 'it is not a subscription id*' }
        @{ Value = 'aaaaaaaa00004000800000000000001'; Reason = 'it is not a subscription id*' }
        @{ Value = 'aaaaaaaa-0000-4000-8000-000000000001,bbbbbbbb-0000-4000-8000-000000000002'; Reason = 'it is not a subscription id*' }
    ) {
        Get-SubscriptionIdProblem -Value $Value | Should -BeLike $Reason
    }

    It 'keys the resume state of a run of the whole tenant by the tenant, as before' {
        Get-ResumeStateScope -Tenant $script:Tenant -SubscriptionID '' | Should -BeExactly $script:Tenant
        Get-ResumeStateScope -Tenant $script:Tenant | Should -BeExactly $script:Tenant
    }

    It 'keys the resume state of a -SubscriptionID run by the tenant and the subscription, in small letters, never as the tenant' {
        $Scope = Get-ResumeStateScope -Tenant $script:Tenant.ToUpperInvariant() -SubscriptionID 'AAAAAAAA-0000-4000-8000-000000000001'
        $Scope | Should -BeExactly ('{0}/subscriptions/aaaaaaaa-0000-4000-8000-000000000001' -f $script:Tenant)
        Get-ResumeStatePath -InventoryRoot '/x' -Tenant $Scope | Should -Not -Be (Get-ResumeStatePath -InventoryRoot '/x' -Tenant $script:Tenant)
        (Get-ResumeStateScope -Tenant $script:Tenant -SubscriptionID 'aaaaaaaa-0000-4000-8000-000000000001') | Should -Not -Be (Get-ResumeStateScope -Tenant $script:Tenant -SubscriptionID 'bbbbbbbb-0000-4000-8000-000000000002')
    }

    It 'picks the listed subscription, whatever the letter case of the id' {
        $List = @([pscustomobject]@{ Id = 'aaaaaaaa-0000-4000-8000-000000000001'; Name = 'Sub A'; State = 'Enabled' }, [pscustomobject]@{ Id = 'bbbbbbbb-0000-4000-8000-000000000002'; Name = 'Sub B'; State = 'Enabled' })
        $Pick = Select-OneSubscription -Subscriptions $List -SubscriptionID 'BBBBBBBB-0000-4000-8000-000000000002' -Tenant $script:Tenant
        $Pick.Stop | Should -BeFalse
        $Pick.Subscription.Name | Should -Be 'Sub B'
        @($Pick.Lines).Text | Should -Be @('Only subscription Sub B (bbbbbbbb-0000-4000-8000-000000000002) is collected (-SubscriptionID); the tenant lists 2.')
    }

    It 'stops for an id the list does not hold, and names the listing''s warnings when it gave some' {
        $List = @([pscustomobject]@{ Id = 'aaaaaaaa-0000-4000-8000-000000000001'; Name = 'Sub A'; State = 'Enabled' })
        $Pick = Select-OneSubscription -Subscriptions $List -SubscriptionID 'cccccccc-0000-4000-8000-000000000003' -Tenant $script:Tenant
        $Pick.Stop | Should -BeTrue
        $Pick.Subscription | Should -BeNullOrEmpty
        @($Pick.Lines)[0].Text | Should -BeLike 'ERROR: -SubscriptionID cccccccc-0000-4000-8000-000000000003 is not among the 1 subscription(s) Get-AzSubscription lists for tenant *, so this run stopped before collecting anything (exit 1).'
        $Warned = Select-OneSubscription -Subscriptions $List -SubscriptionID 'cccccccc-0000-4000-8000-000000000003' -Tenant $script:Tenant -ListingProblems @('Unable to acquire token for tenant x')
        @($Warned.Lines).Text | Should -Contain '    - Unable to acquire token for tenant x'
        $Empty = Select-OneSubscription -Subscriptions @() -SubscriptionID 'cccccccc-0000-4000-8000-000000000003' -Tenant $script:Tenant
        $Empty.Stop | Should -BeTrue
    }

    It 'stops for a subscription that is not Enabled, unless -IncludeDisabled' {
        $List = @([pscustomobject]@{ Id = 'aaaaaaaa-0000-4000-8000-000000000001'; Name = 'Sub A'; State = 'Disabled' })
        $Pick = Select-OneSubscription -Subscriptions $List -SubscriptionID 'aaaaaaaa-0000-4000-8000-000000000001' -Tenant $script:Tenant
        $Pick.Stop | Should -BeTrue
        @($Pick.Lines).Text | Should -Contain '  Next: to collect it anyway, run the same command with -IncludeDisabled.'
        $With = Select-OneSubscription -Subscriptions $List -SubscriptionID 'aaaaaaaa-0000-4000-8000-000000000001' -IncludeDisabled $true -Tenant $script:Tenant
        $With.Stop | Should -BeFalse
        $With.Subscription.Id | Should -Be 'aaaaaaaa-0000-4000-8000-000000000001'
    }

    It 'puts -SubscriptionID in the printed wrapper commands of a -SubscriptionID run, and only there' {
        $Settings = Get-RetryCommandSettings -Settings ([ordered]@{ Obfuscate = $true; SkipMetrics = $false }) -DeviceLogin $false -SubscriptionID 'aaaaaaaa-0000-4000-8000-000000000001'
        Get-WrapperRunCommand -TenantID $script:Tenant -Mode '-Resume' -Settings $Settings | Should -BeExactly ('./Run-AllSubscriptions.ps1 -TenantID {0} -SubscriptionID aaaaaaaa-0000-4000-8000-000000000001 -Resume -Obfuscate' -f $script:Tenant)
        Get-DirectRunRetryCommand -TenantID $script:Tenant -SubscriptionID 'aaaaaaaa-0000-4000-8000-000000000001' -Settings $Settings | Should -BeExactly ('./ResourceInventory.ps1 -TenantID {0} -SubscriptionID aaaaaaaa-0000-4000-8000-000000000001 -Obfuscate' -f $script:Tenant)
        $Whole = Get-RetryCommandSettings -Settings ([ordered]@{ Obfuscate = $true; SkipMetrics = $false }) -DeviceLogin $false
        $Whole.Contains('SubscriptionID') | Should -BeFalse
        Get-WrapperRunCommand -TenantID $script:Tenant -Mode '-Fresh' -Settings $Whole | Should -BeExactly ('./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh -Obfuscate' -f $script:Tenant)
    }

    It 'keeps -SubscriptionID and then -PreflightOnly as the last parameters of the wrapper, after every earlier one' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $Names = @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $Names.IndexOf('SubscriptionID') | Should -Be ($Names.IndexOf('ResumeMaxAgeDays') + 1)
        $Names[($Names.IndexOf('SubscriptionID') + 1)..($Names.Count - 1)] | Should -Be @('PreflightOnly')
        $Names[0..($Names.IndexOf('ResumeMaxAgeDays'))] | Should -Be @('TenantID', 'DeviceLogin', 'Obfuscate', 'SkipMetrics', 'SkipConsumption', 'IncludeNetworkResources', 'Resume', 'ResumeFailedOnly', 'Fresh', 'IncludeDisabled', 'AllowPartialAccess', 'MainSummary', 'Detailed', 'ConcurrencyLimit', 'ParallelStreams', 'ResumeMaxAgeDays')
    }
}

Describe 'A run with -SubscriptionID' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'collects only that subscription, and its zip has the shape of a run on a tenant that holds only it (-ParallelStreams <Streams>)' -ForEach @(@{ Streams = 1 }, @{ Streams = 3 }) {
        script:Set-Scenario -Subs 'A', 'B', 'C'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id) -Streams $Streams
        $R.ExitCode | Should -Be 0
        $R.Text | Should -Contain ('Only subscription Sub B ({0}) is collected (-SubscriptionID); the tenant lists 3.' -f $script:Subs['B'].Id)
        $R.Text | Should -Contain 'Subscriptions visible: 1'
        script:Get-Collected $R | Should -Be (script:Get-Ids 'B')
        script:Get-Calls | Should -Be @($script:Subs['B'].Id)
        script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids 'B')
        $Shape = script:Get-NewestBundleShape

        # The same run on a tenant that holds only B.
        script:New-Case
        script:Set-Scenario -Subs 'B'
        $Plain = script:Invoke-Wrapper -Streams $Streams
        $Plain.ExitCode | Should -Be 0
        script:Get-NewestBundleShape | Should -Be $Shape
    }

    It 'stops with exit 1 before creating any file for an id that is not a GUID (<Value>)' -ForEach @(@{ Value = 'not-a-guid' }, @{ Value = '' }) {
        script:Set-Scenario -Subs 'A', 'B'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $Value)
        $R.ExitCode | Should -Be 1
        ($R.Text | Where-Object { $_ -like 'ERROR: -SubscriptionID*' }) | Should -BeLike ('ERROR: -SubscriptionID ''{0}'' cannot be used: *. The run stopped before creating or writing any file (exit 1).' -f $Value)
        Test-Path -LiteralPath $script:Root | Should -BeFalse
        script:Get-Calls | Should -BeNullOrEmpty
    }

    It 'stops with exit 1 and collects nothing when the tenant does not list the subscription' {
        script:Set-Scenario -Subs 'A', 'B'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['C'].Id)
        $R.ExitCode | Should -Be 1
        ($R.Text | Where-Object { $_ -like 'ERROR: -SubscriptionID*' }) | Should -BeLike ('ERROR: -SubscriptionID {0} is not among the 2 subscription(s) Get-AzSubscription lists for tenant *' -f $script:Subs['C'].Id)
        script:Get-Calls | Should -BeNullOrEmpty
        script:Read-StateAt (script:Get-OneState 'C') | Should -BeNullOrEmpty
        script:Read-StateAt $script:State | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.run-lock-*') | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'AllSubscriptions_*.zip') | Should -BeNullOrEmpty
    }

    It 'stops with exit 1 for a subscription that is not Enabled, and collects it with -IncludeDisabled' {
        script:Set-Scenario -Subs 'A', 'B' -Disabled 'B'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $R.ExitCode | Should -Be 1
        $R.Text | Should -Contain ('ERROR: Subscription Sub B ({0}) is Disabled, not Enabled, so this run stopped before collecting anything (exit 1). A subscription that is not Enabled returns little or no data.' -f $script:Subs['B'].Id)
        script:Get-Calls | Should -BeNullOrEmpty

        $R2 = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-IncludeDisabled')
        $R2.ExitCode | Should -Be 0
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B')
    }

    It 'stops with exit 1 when the subscription cannot be read, and collects nothing' {
        script:Set-Scenario -Subs 'A', 'B' -Denied 'B'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $R.ExitCode | Should -Be 1
        $R.Text | Should -Contain 'Verifying subscription access up front for 1 subscription(s)...' -Because 'only B is checked, not A'
        script:Get-Calls | Should -BeNullOrEmpty
        script:Read-StateAt $script:State | Should -BeNullOrEmpty
    }
}

Describe 'The resume state of a -SubscriptionID run is its own' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It '(a) a one-subscription run, then a run of the whole tenant: the whole run collects every subscription, B included' {
        script:Set-Scenario -Subs 'A', 'B', 'C'
        $R1 = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $R1.ExitCode | Should -Be 0
        script:Read-StateAt (script:Get-OneState 'B') | Should -BeNullOrEmpty -Because 'a clean run clears its own state'
        script:Clear-Calls

        $R2 = script:Invoke-Wrapper
        $R2.ExitCode | Should -Be 0
        $R2.Text | Should -Contain 'Starting a new run.'
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids 'A', 'B', 'C')
    }

    It '(a) a one-subscription run that fails, then a run of the whole tenant: the whole run is a new run of every subscription and leaves the one-subscription retry list as it was' {
        script:Set-Scenario -Subs 'A', 'B', 'C' -Fail 'B'
        $R1 = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $R1.ExitCode | Should -Not -Be 0
        $One = script:Read-StateAt (script:Get-OneState 'B')
        $One.Failed | Should -Be (script:Get-Ids 'B')
        $One.TenantID | Should -BeExactly ('{0}/subscriptions/{1}' -f $script:Tenant, $script:Subs['B'].Id)
        script:Read-StateAt $script:State | Should -BeNullOrEmpty -Because 'the one-subscription run writes only its own state'
        $OneHash = script:Get-FileHashOrNone (script:Get-OneState 'B')

        script:Set-Scenario -Subs 'A', 'B', 'C'
        script:Clear-Calls
        $R2 = script:Invoke-Wrapper
        $R2.ExitCode | Should -Be 0
        $R2.Text | Should -Contain 'Starting a new run.'
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        script:Get-FileHashOrNone (script:Get-OneState 'B') | Should -Be $OneHash -Because 'a run of the whole tenant never touches a one-subscription run''s state'

        # The run after: the one-subscription run continues its own run and clears it.
        $R3 = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $R3.ExitCode | Should -Be 0
        @($R3.Text | Where-Object { $_ -like 'Continuing the run started*' }).Count | Should -Be 1
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'B')
        script:Read-StateAt (script:Get-OneState 'B') | Should -BeNullOrEmpty
    }

    It '(b) a run of the whole tenant interrupted, then a one-subscription run with -Resume: the whole run''s state is left as it was, and the whole run then continues where it stopped' {
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'C' -Fail 'B'
        $null = script:Invoke-Wrapper -EndWhen { (script:Test-Hanging 'C') -and ((script:Read-StateAt $script:State).Completed -join ',') -eq $script:Subs['A'].Id }
        $Whole = script:Read-StateAt $script:State
        $Whole.Completed | Should -Be (script:Get-Ids 'A')
        $Whole.Failed | Should -Be (script:Get-Ids 'B')
        $WholeHash = script:Get-FileHashOrNone $script:State

        # D, which the whole run never reached, and then A, which it completed.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        foreach ($Letter in 'D', 'A', 'B')
        {
            script:Clear-Calls
            $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs[$Letter].Id, '-Resume')
            $R.ExitCode | Should -Be 0
            script:Get-Collected $R | Should -Be (script:Get-Ids $Letter) -Because 'a one-subscription run collects its subscription whatever the whole run did'
            script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids $Letter)
            script:Get-FileHashOrNone $script:State | Should -Be $WholeHash -Because 'it does not mark A, B or D completed, nor take B off the retry list'
            script:Read-StateAt (script:Get-OneState $Letter) | Should -BeNullOrEmpty
        }

        script:Clear-Calls
        $R2 = script:Invoke-Wrapper
        $R2.ExitCode | Should -Be 0
        @($R2.Text | Where-Object { $_ -like 'Continuing the run started*(1 of 4 subscriptions done)*' }).Count | Should -Be 1
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B', 'C', 'D')
        script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
        script:Read-StateAt $script:State | Should -BeNullOrEmpty
    }

    It '(b) an interrupted parallel run of the whole tenant keeps its per-stream state files through a one-subscription run' {
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Hang 'C', 'D'
        $StreamFilter = '.resume-state-{0}-stream-*.json' -f (script:Get-Key $script:Tenant)
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { (script:Test-Hanging 'C', 'D') -and @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter $StreamFilter | Where-Object { $Raw = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue; $Raw -and @(($Raw | ConvertFrom-Json -ErrorAction SilentlyContinue).Completed | Where-Object { $_ }).Count -gt 0 }).Count -eq 2 }
        $Before = @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter $StreamFilter | ForEach-Object { '{0}={1}' -f $_.Name, (script:Get-FileHashOrNone $_.FullName) } | Sort-Object)
        $Before.Count | Should -Be 2

        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['C'].Id, '-Resume') -Streams 2
        $R.ExitCode | Should -Be 0
        @($R.Text | Where-Object { $_ -like 'Recovered per-stream state from an interrupted parallel run*' }) | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter $StreamFilter | ForEach-Object { '{0}={1}' -f $_.Name, (script:Get-FileHashOrNone $_.FullName) } | Sort-Object) | Should -Be $Before

        script:Clear-Calls
        $R2 = script:Invoke-Wrapper -Streams 2
        $R2.ExitCode | Should -Be 0
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'C', 'D')
        script:Get-NewestBundleReportIds | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
    }

    It '(c) a one-subscription run twice: a failed run is continued once by the next, which clears the state' {
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $R1 = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $R1.ExitCode | Should -Not -Be 0
        (script:Read-StateAt (script:Get-OneState 'B')).Failed | Should -Be (script:Get-Ids 'B')

        script:Set-Scenario -Subs 'A', 'B'
        $R2 = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $R2.ExitCode | Should -Be 0
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B')
        script:Read-StateAt (script:Get-OneState 'B') | Should -BeNullOrEmpty
        script:Read-StateAt $script:State | Should -BeNullOrEmpty

        # Twice clean: each starts a new run, so nothing is skipped or kept.
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
            $R.ExitCode | Should -Be 0
            $R.Text | Should -Contain 'Starting a new run.'
            script:Get-Collected $R | Should -Be (script:Get-Ids 'B')
        }
    }

    It '(c) a one-subscription run that keeps failing stops retrying at the retry limit, and -Fresh starts over' {
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $Codes = @()
        $CollectedAt = @()
        foreach ($N in 1..4)
        {
            script:Clear-Calls
            $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-Resume')
            $Codes += $R.ExitCode
            $CollectedAt += @(script:Get-Calls).Count
        }
        $CollectedAt | Should -Be @(1, 1, 1, 0) -Because 'three failed runs in a row reach the retry limit, and the fourth run does not collect B again'
        $Codes[3] | Should -Not -Be 0
        # The fourth run prints the command that starts over: it carries -SubscriptionID.
        $Commands = @($R.Text | Where-Object { $_ -like '*./Run-AllSubscriptions.ps1 -TenantID*' })
        $Commands.Count | Should -BeGreaterThan 0
        $Commands | ForEach-Object { $_ | Should -BeLike ('*./Run-AllSubscriptions.ps1 -TenantID {0} -SubscriptionID {1} -Fresh*' -f $script:Tenant, $script:Subs['B'].Id) }
        script:Read-StateAt $script:State | Should -BeNullOrEmpty

        script:Set-Scenario -Subs 'A', 'B'
        script:Clear-Calls
        $F = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-Fresh')
        $F.ExitCode | Should -Be 0
        script:Get-Calls | Should -Be @($script:Subs['B'].Id)
        script:Read-StateAt (script:Get-OneState 'B') | Should -BeNullOrEmpty
    }
}

Describe 'Run-AllSubscriptions.ps1 -PreflightOnly' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'passes every check for one subscription, exits 0 and creates no inventory folder' {
        script:Set-Scenario -Subs 'A', 'B'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-PreflightOnly')
        $R.ExitCode | Should -Be 0
        $R.Text | Should -Contain 'Every check passed.'
        $R.Text | Should -Contain ('  Subscription Sub B ({0}) is listed and Enabled: ok.' -f $script:Subs['B'].Id)
        $R.Text | Should -Contain 'Verifying subscription access up front for 1 subscription(s)...'
        $R.Text | Should -Contain '  Access verified: all 1 in-scope subscription(s) are readable.'
        Test-Path -LiteralPath $script:Root | Should -BeFalse -Because 'a preflight creates nothing in the inventory folder'
        script:Get-Calls | Should -BeNullOrEmpty
    }

    It 'passes every check for the whole tenant without -SubscriptionID' {
        script:Set-Scenario -Subs 'A', 'B', 'C' -Disabled 'C'
        $R = script:Invoke-Wrapper -Arguments @('-PreflightOnly')
        $R.ExitCode | Should -Be 0
        $R.Text | Should -Contain '  Subscriptions listed: 3, of which 2 in scope: ok.'
        $R.Text | Should -Contain 'Every check passed.'
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }

    It 'leaves an inventory folder, its reports, resume state and lock files exactly as they were (<Case>)' -ForEach @(
        @{ Case = 'pass'; Denied = @(); Code = 0; Last = 'Every check passed.' }
        @{ Case = 'fail'; Denied = @('B'); Code = 1; Last = 'Preflight failed: read access. Nothing was collected or written to the inventory folder (exit 1).' }
    ) {
        # An unfinished run of the whole tenant and of one subscription, as on disk.
        script:Set-Scenario -Subs 'A', 'B', 'C' -Hang 'B'
        $null = script:Invoke-Wrapper -EndWhen { (script:Test-Hanging 'B') -and ((script:Read-StateAt $script:State).Completed -join ',') -eq $script:Subs['A'].Id }
        Set-Content -LiteralPath (Join-Path $script:Root 'note.txt') -Value 'kept'
        Set-Content -LiteralPath (script:Get-OneState 'C') -Value '{"TenantID":"x"}'
        Start-Sleep -Milliseconds 50
        $Before = script:Get-RootSnapshot
        $Before.Count | Should -BeGreaterThan 3

        script:Set-Scenario -Subs 'A', 'B', 'C' -Denied $Denied
        script:Clear-Calls
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-PreflightOnly')
        $R.ExitCode | Should -Be $Code
        $R.Text | Should -Contain $Last
        $R2 = script:Invoke-Wrapper -Arguments @('-PreflightOnly')
        $R2.ExitCode | Should -Be $Code
        $R2.Text | Should -Contain $Last
        script:Get-RootSnapshot | Should -Be $Before
        script:Get-Calls | Should -BeNullOrEmpty -Because 'a preflight collects nothing'
    }

    It 'fails with exit 1 naming the subscription when the tenant does not list it' {
        script:Set-Scenario -Subs 'A'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['C'].Id, '-PreflightOnly')
        $R.ExitCode | Should -Be 1
        ($R.Text | Where-Object { $_ -like 'ERROR: -SubscriptionID*' }) | Should -BeLike ('ERROR: -SubscriptionID {0} is not among the 1 subscription(s) Get-AzSubscription lists for tenant *.' -f $script:Subs['C'].Id)
        $R.Text | Should -Contain 'Preflight failed: the subscription. Nothing was collected or written to the inventory folder (exit 1).'
        $R.Text | Should -Not -Contain 'Every check passed.'
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }

    It 'fails with exit 1 for a subscription that is not Enabled, and passes with -IncludeDisabled' {
        script:Set-Scenario -Subs 'A', 'B' -Disabled 'B'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-PreflightOnly')
        $R.ExitCode | Should -Be 1
        $R.Text | Should -Contain ('ERROR: Subscription Sub B ({0}) is Disabled, not Enabled. A subscription that is not Enabled returns little or no data.' -f $script:Subs['B'].Id)
        $R.Text | Should -Contain 'Preflight failed: the subscription. Nothing was collected or written to the inventory folder (exit 1).'
        $R2 = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-PreflightOnly', '-IncludeDisabled')
        $R2.ExitCode | Should -Be 0
        $R2.Text | Should -Contain 'Every check passed.'
    }

    It 'fails with exit 1 naming read access when a subscription cannot be read (<Mode>)' -ForEach @(
        @{ Mode = 'one subscription'; One = $true }
        @{ Mode = 'whole tenant'; One = $false }
    ) {
        script:Set-Scenario -Subs 'A', 'B' -Denied 'B'
        $Arguments = if ($One) { @('-SubscriptionID', $script:Subs['B'].Id, '-PreflightOnly') } else { @('-PreflightOnly') }
        $R = script:Invoke-Wrapper -Arguments $Arguments
        $R.ExitCode | Should -Be 1
        @($R.Text | Where-Object { $_ -like ('    - Sub B ({0}) - *' -f $script:Subs['B'].Id) }).Count | Should -Be 1
        $R.Text | Should -Contain 'Preflight failed: read access. Nothing was collected or written to the inventory folder (exit 1).'
        @($R.Text | Where-Object { $_ -like '*Skipping them and continuing*' }) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }

    It 'fails with exit 1 naming the sign-in when there is no usable sign-in for the tenant' {
        script:Set-Scenario -Subs 'A' -SignedInTenant '99999999-9999-9999-9999-999999999999'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['A'].Id, '-PreflightOnly')
        $R.ExitCode | Should -Be 1
        $R.Text | Should -Contain 'Preflight failed: the sign-in. Nothing was collected or written to the inventory folder (exit 1).'
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }

    It 'fails with exit 1 when an Az module is missing, before it signs in, and creates no inventory folder' {
        $Partial = Join-Path $script:CaseHome 'partial-modules'
        Copy-Item -LiteralPath $script:Modules -Destination $Partial -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $Partial 'Az.Billing') -Recurse -Force
        script:Set-Scenario -Subs 'A'
        $R = script:Invoke-Wrapper -Arguments @('-PreflightOnly') -ModulePath $Partial
        $R.ExitCode | Should -Be 1
        @($R.Text | Where-Object { $_ -like 'Required Az submodule(s) not found or too old (Az.Billing)*' }).Count | Should -Be 1
        $R.Text | Should -Not -Contain 'Every check passed.'
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }

    It 'runs under Set-StrictMode -Version Latest with no strict-mode error: <Case>' -ForEach @(
        @{ Case = 'a passing preflight'; Arguments = @('-SubscriptionID', 'B', '-PreflightOnly'); Code = 0; Line = 'Every check passed.' }
        @{ Case = 'a passing preflight of the whole tenant'; Arguments = @('-PreflightOnly'); Code = 0; Line = 'Every check passed.' }
        @{ Case = 'a failing preflight'; Arguments = @('-SubscriptionID', 'C', '-PreflightOnly'); Code = 1; Line = 'Preflight failed: the subscription. Nothing was collected or written to the inventory folder (exit 1).' }
        @{ Case = 'an id that is not a GUID'; Arguments = @('-SubscriptionID', 'not-a-guid'); Code = 1; Line = $null }
        @{ Case = 'an id the tenant does not list'; Arguments = @('-SubscriptionID', 'C'); Code = 1; Line = $null }
    ) {
        script:Set-Scenario -Subs 'A', 'B'
        $Resolved = @($Arguments | ForEach-Object { if ($script:Subs.ContainsKey($_)) { $script:Subs[$_].Id } else { $_ } })
        $R = script:Invoke-Wrapper -Arguments $Resolved -StrictMode
        $R.ExitCode | Should -Be $Code
        $R.Error | Should -BeNullOrEmpty -Because 'these paths print no strict-mode error'
        if ($Line) { $R.Text | Should -Contain $Line }
    }

    It 'a one-subscription run under Set-StrictMode -Version Latest prints no strict-mode error outside the older-code list of ResumeByDefault.Tests.ps1, and collects only that subscription' {
        # The strict-mode errors older code prints on a run (the role check, the
        # consumption check, the end-of-run summary), as listed in
        # ResumeByDefault.Tests.ps1: '<file>|<start of the source line>'.
        $Known = @(
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
        script:Set-Scenario -Subs 'A', 'B'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id) -StrictMode
        $Found = [System.Collections.Generic.List[string]]::new()
        $File = $null
        foreach ($Line in @(([string]$R.Error) -split "`r?`n"))
        {
            $Plain = $Line -replace "`e\[[0-9;]*m", ''
            if ($Plain -match '^\S+Exception: (.+):(\d+)\s*$' -or $Plain -match '^\S+: (/.+\.ps1):(\d+)\s*$') { $File = Split-Path -Path $Matches[1] -Leaf; continue }
            if ($null -ne $File -and $Plain -match '^\s*\d+ \|\s(.*)$') { $Found.Add(('{0}|{1}' -f $File, $Matches[1].Trim().TrimEnd([char]0x2026).TrimEnd())); $File = $null }
        }
        foreach ($Line in @($R.Text | Where-Object { $_ -match '^ERROR processing subscription ' })) { if ($Line -notmatch "The variable '\`$LASTEXITCODE' cannot be retrieved because it has not been set\.$") { $Found.Add('stdout|' + $Line) } }
        @($Found | Where-Object { $E = $_; @($Known | Where-Object { $E -eq $_ -or $E.StartsWith($_) -or $_.StartsWith($E) }).Count -eq 0 }) | Should -BeNullOrEmpty
        script:Get-Collected $R | Should -Be (script:Get-Ids 'B')
    }

    It 'fails with exit 1 naming the run lock when another run of the tenant holds it, and leaves the lock as it is' {
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        # A lock as a run that is going holds it: its process is alive.
        $Holder = Start-Process -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120') -PassThru
        try
        {
            $LockPath = Join-Path $script:Root ('.run-lock-{0}.json' -f (script:Get-Key $script:Tenant))
            $Record = [ordered]@{ InvocationId = [guid]::NewGuid().ToString(); MachineName = [Environment]::MachineName; ProcessId = $Holder.Id; ProcessStartTimeUtc = $Holder.StartTime.ToUniversalTime().ToString('o'); RunStartTimeUtc = [datetime]::UtcNow.ToString('o'); HeartbeatUtc = [datetime]::UtcNow.ToString('o') }
            $Record | ConvertTo-Json | Set-Content -LiteralPath $LockPath -Encoding utf8
            $Before = script:Get-FileHashOrNone $LockPath
            script:Set-Scenario -Subs 'A', 'B'
            $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-PreflightOnly')
            $R.ExitCode | Should -Be 1
            $R.Text | Should -Contain 'Preflight failed: the run lock. Nothing was collected or written to the inventory folder (exit 1).'
            script:Get-FileHashOrNone $LockPath | Should -Be $Before
        }
        finally { Stop-Process -Id $Holder.Id -Force -ErrorAction SilentlyContinue }
    }

    It 'fails with exit 1 when the run could not start: <Case>' -ForEach @(
        @{ Case = '-Fresh with -Resume'; Extra = @('-Fresh', '-Resume'); Seed = $false }
        @{ Case = 'settings that differ from the unfinished one-subscription run'; Extra = @('-Obfuscate'); Seed = $true }
    ) {
        if ($Seed)
        {
            script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
            $null = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
            (script:Read-StateAt (script:Get-OneState 'B')).Failed | Should -Be (script:Get-Ids 'B')
        }
        script:Set-Scenario -Subs 'A', 'B'
        $Before = script:Get-RootSnapshot
        $R = script:Invoke-Wrapper -Arguments (@('-SubscriptionID', $script:Subs['B'].Id, '-PreflightOnly') + $Extra)
        $R.ExitCode | Should -Be 1
        $R.Text | Should -Contain 'Preflight failed: how the run would start. Nothing was collected or written to the inventory folder (exit 1).'
        @($R.Text | Where-Object { $_ -like '*This run stops here*' }) | Should -BeNullOrEmpty -Because 'a preflight says what a run would do'
        @($R.Text | Where-Object { $_ -like '  A run would say: *A run stops here (exit 1)*' }).Count | Should -BeGreaterThan 0
        script:Get-RootSnapshot | Should -Be $Before
        # The same command without -PreflightOnly stops the same way.
        $Run = script:Invoke-Wrapper -Arguments (@('-SubscriptionID', $script:Subs['B'].Id) + $Extra)
        $Run.ExitCode | Should -Be 1
    }
}

Describe 'A -SubscriptionID run whose subscription is gone' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'names its kept resume state file and how to remove it, and leaves the file as it is' {
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $null = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $File = script:Get-OneState 'B'
        $Hash = script:Get-FileHashOrNone $File
        $Hash | Should -Not -Be 'none'
        script:Set-Scenario -Subs 'A'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $R.ExitCode | Should -Be 1
        @($R.Text | Where-Object { $_ -like ("  This subscription's resume state file {0} is kept for the next run of this command. If the subscription is gone for good, remove it with: *" -f $File) }).Count | Should -Be 1
        script:Get-FileHashOrNone $File | Should -Be $Hash
    }

    It 'says its resume state is its own on every run' {
        script:Set-Scenario -Subs 'A', 'B'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-Resume')
        $R.ExitCode | Should -Be 0
        $R.Text | Should -Contain ('-SubscriptionID: this run collects only subscription {0} and keeps its own resume state ({1}); the resume state of a run of the whole tenant is neither read nor changed.' -f $script:Subs['B'].Id, (Split-Path -Path (script:Get-OneState 'B') -Leaf))
        $W = script:Invoke-Wrapper
        @($W.Text | Where-Object { $_ -like '-SubscriptionID: *' }) | Should -BeNullOrEmpty
    }

    It 'checks access only for what the run would collect: <Case>' -ForEach @(
        @{ Case = 'a continued run leaves out a completed subscription that is now unreadable'; Extra = @(); Denied = 'A'; Code = 0 }
        @{ Case = '-ResumeFailedOnly leaves out a subscription not on the retry list'; Extra = @('-ResumeFailedOnly'); Denied = 'C'; Code = 0 }
        @{ Case = '-ResumeFailedOnly still checks the subscription on the retry list'; Extra = @('-ResumeFailedOnly'); Denied = 'B'; Code = 1 }
    ) {
        # An unfinished run of the whole tenant: A completed, B failed, C never reached.
        script:Set-Scenario -Subs 'A', 'B', 'C' -Fail 'B' -Hang 'C'
        $null = script:Invoke-Wrapper -EndWhen { (script:Test-Hanging 'C') -and ((script:Read-StateAt $script:State).Failed -join ',') -eq $script:Subs['B'].Id }
        $State = script:Read-StateAt $script:State
        $State.Completed | Should -Be (script:Get-Ids 'A')
        $Before = script:Get-RootSnapshot
        script:Set-Scenario -Subs 'A', 'B', 'C' -Denied $Denied
        $R = script:Invoke-Wrapper -Arguments (@('-PreflightOnly') + $Extra)
        $R.ExitCode | Should -Be $Code
        @($R.Text | Where-Object { $_ -like '  The run would collect * of these 3 subscription(s)*' }).Count | Should -Be 1
        script:Get-RootSnapshot | Should -Be $Before
        # The run itself gets past its access check the same way.
        $Run = script:Invoke-Wrapper -Arguments $Extra
        if ($Code -eq 0) { @($Run.Text | Where-Object { $_ -like '*NOT readable*' }) | Should -BeNullOrEmpty }
        else { @($Run.Text | Where-Object { $_ -like '*NOT readable*' }).Count | Should -BeGreaterThan 0 }
    }
}

Describe 'An early stop of the wrapper releases only its own run lock' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'leaves a run lock that the calling session holds when the wrapper stops before taking its own' {
        script:Set-Scenario -Subs 'A'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $Lock = Join-Path $script:Root 'session-held.lock.json'
        $Functions = Join-Path $script:ToolRoot 'Functions/RunAllSubscriptions.Functions.ps1'
        $Command = ". '{0}'; `$RunLock = Request-RunLock -Path '{1}' -RunStartTime (Get-Date); if (-not `$RunLock.Acquired) {{ exit 9 }}; & '{2}' -TenantID '{3}' -SubscriptionID 'not-a-guid'; exit `$LASTEXITCODE" -f $Functions, $Lock, $script:Wrapper, $script:Tenant
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($Arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $Command)) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['RDA_STANDIN_AZURE'] = $script:Scenario
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $Out = $Proc.StandardOutput.ReadToEndAsync()
        $null = $Proc.StandardError.ReadToEndAsync()
        $Proc.WaitForExit(120000) | Should -BeTrue
        $Proc.ExitCode | Should -Be 1 -Because $Out.Result
        Test-Path -LiteralPath $Lock | Should -BeTrue -Because 'the lock is the calling session''s, not the wrapper''s'
    }
}

Describe 'Run-AllSubscriptions.ps1 -PreflightOnly reads the state a run would read' -Skip:$IsWindows {
    BeforeEach { script:New-Case }
    AfterEach { script:Write-FailedCaseRuns }

    It 'after an interrupted parallel run, checks what the run would collect from the per-stream state: <Case>' -ForEach @(
        @{ Case = '-ResumeFailedOnly checks the subscription only a per-stream file has on its retry list'; Extra = @('-ResumeFailedOnly'); Denied = 'B'; Code = 1; Collect = 1 }
        @{ Case = 'a continued run leaves out the subscription only a per-stream file has completed'; Extra = @(); Denied = 'A'; Code = 0; Collect = 3 }
    ) {
        # Two streams: A then C, and B then D. A completes, B fails, C and D hang.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B' -Hang 'C', 'D'
        $StreamFilter = '.resume-state-{0}-stream-*.json' -f (script:Get-Key $script:Tenant)
        $null = script:Invoke-Wrapper -Streams 2 -EndWhen { script:Test-Hanging 'C', 'D' }
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter $StreamFilter).Count | Should -Be 2
        $Main = script:Read-StateAt $script:State
        @($Main.Failed) | Should -Not -Contain $script:Subs['B'].Id -Because 'the retry list is only in a per-stream file'
        $Before = script:Get-RootSnapshot
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Denied $Denied
        $R = script:Invoke-Wrapper -Arguments (@('-PreflightOnly') + $Extra) -Streams 2
        $R.ExitCode | Should -Be $Code
        @($R.Text | Where-Object { $_ -like ('  The run would collect {0} of these 4 subscription(s)*' -f $Collect) }).Count | Should -Be 1
        script:Get-RootSnapshot | Should -Be $Before
    }

    It 'fails -ResumeFailedOnly naming the retry list when everything on it is past the retry limit, and a continued run with nothing left passes' {
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        foreach ($N in 1..3) { $null = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-Resume') }
        (script:Read-StateAt (script:Get-OneState 'B')).Failed | Should -Be (script:Get-Ids 'B')
        script:Set-Scenario -Subs 'A', 'B' -Denied 'B'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-ResumeFailedOnly', '-PreflightOnly')
        $R.ExitCode | Should -Be 1
        $R.Text | Should -Contain 'Preflight failed: the retry list. Nothing was collected or written to the inventory folder (exit 1).'
        $Run = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-ResumeFailedOnly')
        $Run.ExitCode | Should -Be 2 -Because 'the run retries nothing either'
        # Past the limit, a continued run leaves B out: nothing to collect, and B's denied access is not checked.
        $C = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-Resume', '-PreflightOnly')
        $C.ExitCode | Should -Be 0
        $C.Text | Should -Contain '  Nothing is left for the run to collect, so no access check is needed.'
    }

    It 'words the run-start lines of a -SubscriptionID run for that one subscription' {
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $null = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        script:Set-Scenario -Subs 'A', 'B'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-Fresh')
        $R.ExitCode | Should -Be 0
        @($R.Text | Where-Object { $_ -like 'Starting a new run (-Fresh). The unfinished run * is not continued: this run collects the subscription again.' }).Count | Should -Be 1
        @($R.Text | Where-Object { $_ -like '*every subscription*' }) | Should -BeNullOrEmpty
    }
}

