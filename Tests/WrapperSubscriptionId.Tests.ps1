# Run-AllSubscriptions.ps1 -SubscriptionID <id>.
#
#   - The run collects only that subscription, as a run of a tenant that holds
#     only it.
#   - An id that is not a GUID (or is empty) stops the run with exit 1 before
#     it creates any file; an id the tenant does not list, or a subscription
#     that is not Enabled (without -IncludeDisabled), stops it with exit 1
#     before it collects anything.
#   - Its resume state is its own file (.resume-state-<tenant>-subscription-
#     <id>.json), so it never reads or changes the state of a run of the whole
#     tenant, and a run of the whole tenant never changes it.
#   - -PreflightOnly runs the checks of a run and stops: exit 0 after 'Every
#     check passed.', exit 1 after 'Preflight failed: <the check>.', and the
#     inventory folder is never created, or left exactly as it was.
# The helpers are also tested on their own.
#
# Every end-to-end run is Run-AllSubscriptions.ps1 itself, as its own pwsh
# process with HOME set to a temp folder, from a copy of the tool whose
# ResourceInventory.ps1 is a stand-in. Stand-in Az modules (on PSModulePath)
# and a stand-in `az` (first on PATH) answer from a scenario file. On Windows
# the wrapper writes to C:\InventoryReports instead, so the end-to-end tests
# do not run there.
#
# Run with: Invoke-Pester ./Tests/WrapperSubscriptionId.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('WrapperSubscriptionIdTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
    $script:Tenant = '12345678-1234-1234-1234-123456789012'
    $script:Pwsh = Join-Path $PSHOME 'pwsh'
    $script:CaseRuns = [System.Collections.Generic.List[object]]::new()

    # --- The tool: the wrapper and its helpers as they are, and a stand-in
    # ResourceInventory.ps1 that logs the subscription it was given and writes
    # one report folder and zip under $HOME/InventoryReports, as the real one does.
    $script:ToolRoot = Join-Path $script:TestBase 'tool'
    New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
    foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Version.json', 'Functions', 'Extension'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:ToolRoot -Recurse -Force
    }
    $script:Wrapper = Join-Path $script:ToolRoot 'Run-AllSubscriptions.ps1'
    $StandInInner = @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
Set-Content -LiteralPath (Join-Path $HOME ('call-' + [guid]::NewGuid().ToString() + '.log')) -Value $SubscriptionID
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
if (@($Scenario.FailIds) -contains $SubscriptionID) { throw 'stand-in failure for this subscription' }
$Root = Join-Path $HOME 'InventoryReports'
$Stamp = (Get-Date -Format 'yyyyMMddHHmmssfff') + $SubscriptionID
$Folder = Join-Path $Root ('ResourcesReport' + $Stamp)
$Stage = Join-Path $Root ('stage-' + $Stamp)
New-Item -ItemType Directory -Path $Folder, $Stage -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Stage ('Inventory_ResourcesReport_{0}.json' -f $Stamp)) -Value ('{"VirtualMachines":[{"Name":"vm","Subscription":"' + $SubscriptionID + '"}]}') -Encoding utf8
Set-Content -LiteralPath (Join-Path $Stage ('ResourcesReport_{0}.html' -f $Stamp)) -Value '<html></html>' -Encoding utf8
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath (Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)) -Force
Copy-Item -Path (Join-Path $Stage '*') -Destination $Folder
Remove-Item -LiteralPath $Stage -Recurse -Force
$Global:Resources = @(1)
'@
    Set-Content -LiteralPath (Join-Path $script:ToolRoot 'ResourceInventory.ps1') -Value $StandInInner -Encoding utf8

    # --- Stand-in Azure: Az.Accounts answers the context, token, subscription
    # list and the resource group read the access check makes; Az.Billing
    # answers the consumption access check. Connect-AzAccount throws: no run
    # here should sign in again.
    $script:Modules = Join-Path $script:TestBase 'modules'
    $Accounts = @'
function Get-RdaStandInScenario { Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json }
function Get-RdaStandInContext
{
    [pscustomobject]@{
        Account      = [pscustomobject]@{ Id = 'operator@example.com'; Type = 'User' }
        Tenant       = [pscustomobject]@{ Id = (Get-RdaStandInScenario).Tenant }
        Subscription = $null
        Environment  = [pscustomobject]@{ Name = 'AzureCloud' }
    }
}
function Get-AzContext { [CmdletBinding()] param() Get-RdaStandInContext }
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context) Get-RdaStandInContext }
function Connect-AzAccount { [CmdletBinding()] param($Tenant, [switch]$UseDeviceAuthentication) throw 'stand-in: no sign-in expected' }
function Get-AzAccessToken { [CmdletBinding()] param($TenantId, $ResourceUrl, [switch]$AsSecureString) [pscustomobject]@{ Token = 'stand-in-token'; Type = 'Bearer'; ExpiresOn = (Get-Date).AddHours(1) } }
function Get-AzSubscription
{
    [CmdletBinding()] param($TenantId, $SubscriptionId)
    $Scenario = Get-RdaStandInScenario
    @($Scenario.Subscriptions | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SubscriptionId = $_.Id; Name = $_.Name; State = $_.State; TenantId = $Scenario.Tenant } })
}
function Invoke-AzRestMethod
{
    [CmdletBinding()] param([string]$Method = 'GET', [string]$Path, [string]$Payload)
    if ($Path -match '^/subscriptions/([^/?]+)/resourcegroups\?')
    {
        if (@((Get-RdaStandInScenario).DeniedIds) -contains $Matches[1]) { return [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' } }
        return [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' }
    }
    return [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NotFound"}}' }
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

    # --- Stand-in az CLI, first on PATH: signed in to the scenario's tenant,
    # and a token comes silently.
    $script:Bin = Join-Path $script:TestBase 'bin'
    New-Item -ItemType Directory -Path $script:Bin -Force | Out-Null
    $AzPath = Join-Path $script:Bin 'az'
    Set-Content -LiteralPath $AzPath -Value @'
#!/bin/sh
case "$1 $2" in
  "account show") printf '{"tenantId":"%s"}\n' "$RDA_STANDIN_TENANT"; exit 0 ;;
  "account get-access-token") exit 0 ;;
esac
exit 0
'@ -NoNewline
    if (-not $IsWindows) { & chmod 755 $AzPath }

    # Subscriptions by letter. Their ids are GUIDs, as -SubscriptionID takes.
    $script:Subs = @{}
    $N = 0
    foreach ($Letter in 'A', 'B', 'C')
    {
        $N++
        $script:Subs[$Letter] = @{ Id = ('{0}{0}{0}{0}{0}{0}{0}{0}-0000-4000-8000-00000000000{1}' -f $Letter.ToLowerInvariant(), $N); Name = ('Sub ' + $Letter) }
    }

    function script:New-Case
    {
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseHome -Force | Out-Null
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        # The resume state file of a run of the whole tenant.
        $script:State = Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Tenant)
        $script:CaseRuns = [System.Collections.Generic.List[object]]::new()
    }

    # The resume state file of a -SubscriptionID run of the subscription $Letter.
    function script:Get-OneState
    {
        param([string]$Letter)
        Join-Path $script:Root ('.resume-state-{0}-subscription-{1}.json' -f $script:Tenant, $script:Subs[$Letter].Id)
    }

    function script:Set-Scenario
    {
        param([string[]]$Subs, [string[]]$Fail = @(), [string[]]$Disabled = @(), [string[]]$Denied = @())
        [pscustomobject]@{
            Tenant        = $script:Tenant
            Subscriptions = @($Subs | ForEach-Object { [pscustomobject]@{ Id = $script:Subs[$_].Id; Name = $script:Subs[$_].Name; State = $(if ($Disabled -contains $_) { 'Disabled' } else { 'Enabled' }) } })
            FailIds       = @($Fail | ForEach-Object { $script:Subs[$_].Id })
            DeniedIds     = @($Denied | ForEach-Object { $script:Subs[$_].Id })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One run of the wrapper as its own pwsh process, stdin closed. -Streams 0
    # leaves -ParallelStreams out, so it is sized from the host.
    function script:Invoke-Wrapper
    {
        param([string[]]$Arguments = @(), [int]$Streams = 1, [int]$TimeoutSeconds = 300)
        $All = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper, '-TenantID', $script:Tenant)
        if ($Streams -gt 0) { $All += @('-ParallelStreams', [string]$Streams) }
        $All += @($Arguments)
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($Arg in @($All)) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['PATH'] = $script:Bin + [System.IO.Path]::PathSeparator + $env:PATH
        $Info.Environment['RDA_STANDIN_AZURE'] = $script:Scenario
        $Info.Environment['RDA_STANDIN_TENANT'] = $script:Tenant
        $Info.Environment['NO_COLOR'] = '1'
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $Out = $Proc.StandardOutput.ReadToEndAsync()
        $Err = $Proc.StandardError.ReadToEndAsync()
        if (-not $Proc.WaitForExit($TimeoutSeconds * 1000))
        {
            $Proc.Kill($true)
            $Proc.WaitForExit()
            throw ('The wrapper run did not end within {0} seconds.' -f $TimeoutSeconds)
        }
        $Proc.WaitForExit()
        $Text = @(([string]$Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        $Run = [pscustomobject]@{ Arguments = (@($All | Select-Object -Skip 5) -join ' '); ExitCode = $Proc.ExitCode; Text = $Text; Error = [string]$Err.Result }
        $script:CaseRuns.Add($Run)
        return $Run
    }

    # Every run of the current test, printed when it fails.
    function script:Write-CaseRuns
    {
        foreach ($Run in @($script:CaseRuns))
        {
            Write-Host ('--- {0} | exit {1}' -f $Run.Arguments, $Run.ExitCode)
            foreach ($Line in @($Run.Text)) { Write-Host ('  | ' + $Line) }
            foreach ($Line in @(([string]$Run.Error) -split "`r?`n" | Where-Object { $_ })) { Write-Host ('  ! ' + $Line) }
        }
    }

    # The subscription ids the stand-in ResourceInventory.ps1 was called for, sorted.
    function script:Get-Calls { @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'call-*.log' | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw).Trim() } | Sort-Object) }
    function script:Clear-Calls { Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'call-*.log' | Remove-Item -Force }
    function script:Get-Ids { param([string[]]$Letters) @($Letters | ForEach-Object { $script:Subs[$_].Id } | Sort-Object) }
    # Every file and folder under the inventory root, and the root itself, with
    # name, size, time and hash, so a run that changes nothing there leaves the
    # same list.
    function script:Get-RootSnapshot
    {
        if (-not (Test-Path -LiteralPath $script:Root)) { return @('(no inventory folder)') }
        @((Get-Item -LiteralPath $script:Root -Force) | ForEach-Object { 'root|{0}' -f $_.LastWriteTimeUtc.Ticks }) + @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
                if ($_.PSIsContainer) { 'dir|{0}|{1}' -f $_.FullName, $_.LastWriteTimeUtc.Ticks }
                else { 'file|{0}|{1}|{2}|{3}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
            })
    }
    function script:Get-FileHashOrNone { param([string]$Path) if (Test-Path -LiteralPath $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } else { 'none' } }
    # The ids a resume state file lists as completed and as failed.
    function script:Read-StateAt
    {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $Raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        [pscustomobject]@{
            TenantID  = [string]$Raw.TenantID
            Completed = @($Raw.CompletedSubscriptionIds | Where-Object { $_ } | Sort-Object)
            Failed    = @($Raw.FailedAttempts | Where-Object { $_ } | ForEach-Object { [string]$_.Id } | Sort-Object)
        }
    }
}

AfterAll {
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'The -SubscriptionID helpers' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
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

    It 'keys a run of the whole tenant by the tenant as it is, and a one-subscription run by both in small letters' {
        Get-ResumeStateKey -Tenant 'ABCDEF01-1234-1234-1234-123456789012' | Should -BeExactly 'ABCDEF01-1234-1234-1234-123456789012'
        Get-ResumeStateKey -Tenant 'ABCDEF01-1234-1234-1234-123456789012' -SubscriptionID '' | Should -BeExactly 'ABCDEF01-1234-1234-1234-123456789012'
        Get-ResumeStateKey -Tenant 'ABCDEF01-1234-1234-1234-123456789012' -SubscriptionID ' AAAAAAAA-0000-4000-8000-000000000001 ' | Should -BeExactly 'abcdef01-1234-1234-1234-123456789012-subscription-aaaaaaaa-0000-4000-8000-000000000001'
    }

    It 'never lets the whole tenant and a one-subscription run find each other''s state files' {
        $Dir = Join-Path $script:TestBase ('keys-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $T = '12345678-1234-1234-1234-123456789012'
        $One = Get-ResumeStateKey -Tenant $T -SubscriptionID 'aaaaaaaa-0000-4000-8000-000000000001'
        $Other = Get-ResumeStateKey -Tenant $T -SubscriptionID 'bbbbbbbb-0000-4000-8000-000000000002'
        foreach ($Name in @(
                (".resume-state-{0}.json" -f $T), (".resume-state-{0}-stream-0.json" -f $T), (".resume-state-{0}-stream-1.json" -f $T),
                (".resume-state-{0}.json" -f $One), (".resume-state-{0}-stream-0.json" -f $One),
                (".resume-state-{0}.json" -f $Other)))
        {
            Set-Content -LiteralPath (Join-Path $Dir $Name) -Value '{}'
        }
        @(Get-StreamResumeStateFiles -InventoryRoot $Dir -Tenant $T | ForEach-Object Name | Sort-Object) | Should -Be @((".resume-state-{0}-stream-0.json" -f $T), (".resume-state-{0}-stream-1.json" -f $T))
        @(Get-StreamResumeStateFiles -InventoryRoot $Dir -Tenant $One | ForEach-Object Name) | Should -Be @((".resume-state-{0}-stream-0.json" -f $One))
        @(Get-StreamResumeStateFiles -InventoryRoot $Dir -Tenant $Other).Count | Should -Be 0
        # The one-subscription file is not a per-stream file of the tenant, and its key is no tenant's.
        (".resume-state-{0}.json" -f $One) | Should -Not -BeLike (".resume-state-{0}-stream-*.json" -f $T)
        (".resume-state-{0}.json" -f $T) | Should -Not -BeLike (".resume-state-{0}-stream-*.json" -f $One)
        $One | Should -Not -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    }

    It 'picks the subscription without regard to case' {
        $List = @([pscustomobject]@{ Id = 'aaaaaaaa-0000-4000-8000-000000000001'; Name = 'Sub A'; State = 'Enabled' }, [pscustomobject]@{ Id = 'bbbbbbbb-0000-4000-8000-000000000002'; Name = 'Sub B'; State = 'Enabled' })
        $Pick = Select-OneSubscription -Subscriptions $List -SubscriptionID 'BBBBBBBB-0000-4000-8000-000000000002' -Tenant 't'
        $Pick.Stop | Should -BeFalse
        $Pick.Subscription.Name | Should -Be 'Sub B'
        @($Pick.Lines | Where-Object { $_.Text -like 'Only subscription Sub B*the tenant lists 2.' }).Count | Should -Be 1
    }

    It 'stops for an id the list does not hold, naming the listing warnings when there are any' {
        $List = @([pscustomobject]@{ Id = 'aaaaaaaa-0000-4000-8000-000000000001'; Name = 'Sub A'; State = 'Enabled' })
        $Pick = Select-OneSubscription -Subscriptions $List -SubscriptionID 'cccccccc-0000-4000-8000-000000000003' -Tenant 't'
        $Pick.Stop | Should -BeTrue
        $Pick.Subscription | Should -BeNullOrEmpty
        $Pick.Lines[0].Text | Should -BeLike 'ERROR: -SubscriptionID cccccccc-0000-4000-8000-000000000003 is not among the 1 subscription(s)*'
        $Warned = Select-OneSubscription -Subscriptions @() -SubscriptionID 'cccccccc-0000-4000-8000-000000000003' -Tenant 't' -ListingProblems @('Unable to acquire token for tenant t')
        $Warned.Stop | Should -BeTrue
        @($Warned.Lines | Where-Object { $_.Text -eq '    - Unable to acquire token for tenant t' }).Count | Should -Be 1
    }

    It 'stops for a subscription that is not Enabled, unless -IncludeDisabled' {
        $List = @([pscustomobject]@{ Id = 'aaaaaaaa-0000-4000-8000-000000000001'; Name = 'Sub A'; State = 'Disabled' })
        $Pick = Select-OneSubscription -Subscriptions $List -SubscriptionID 'aaaaaaaa-0000-4000-8000-000000000001' -Tenant 't'
        $Pick.Stop | Should -BeTrue
        $Pick.Lines[0].Text | Should -BeLike 'ERROR: Subscription Sub A (aaaaaaaa-0000-4000-8000-000000000001) is Disabled, not Enabled*'
        $With = Select-OneSubscription -Subscriptions $List -SubscriptionID 'aaaaaaaa-0000-4000-8000-000000000001' -Tenant 't' -IncludeDisabled $true
        $With.Stop | Should -BeFalse
        $With.Subscription.Id | Should -Be 'aaaaaaaa-0000-4000-8000-000000000001'
    }

    It 'adds -SubscriptionID, then -PreflightOnly, last in the param block, so the positions of the others stay' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $Names = @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $Names[-3] | Should -Be 'ParallelStreams'
        $Names[-2] | Should -Be 'SubscriptionID'
        $Names[-1] | Should -Be 'PreflightOnly'
        @($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SubscriptionID' })[0].StaticType | Should -Be ([string])
        @($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PreflightOnly' })[0].StaticType | Should -Be ([switch])
    }
}

Describe 'Run-AllSubscriptions.ps1 -SubscriptionID, end to end' -Skip:($IsWindows) {
    AfterEach {
        if ($script:CaseRuns.Count -gt 0 -and $____Pester.CurrentTest.ErrorRecord.Count -gt 0) { script:Write-CaseRuns }
    }

    It 'collects only that subscription' {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B', 'C'
        $Run = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id.ToUpperInvariant())
        $Run.ExitCode | Should -Be 0
        script:Get-Calls | Should -Be (script:Get-Ids 'B')
        @($Run.Text | Where-Object { $_ -like 'Only subscription Sub B (*) is collected (-SubscriptionID); the tenant lists 3.' }).Count | Should -Be 1
        @($Run.Text | Where-Object { $_ -eq 'Subscriptions to process: 1' }).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:Root -File -Filter 'AllSubscriptions_ResourcesReport_*.zip').Count | Should -Be 1
        # A clean run clears its own state; none of the whole tenant was written.
        Test-Path -LiteralPath (script:Get-OneState 'B') | Should -BeFalse
        Test-Path -LiteralPath $script:State | Should -BeFalse
    }

    It 'stops a non-GUID id with exit 1 before it creates the inventory folder' -ForEach @(
        @{ Value = 'my-subscription' }
        @{ Value = '' }
    ) {
        script:New-Case
        script:Set-Scenario -Subs 'A'
        $Run = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $Value)
        $Run.ExitCode | Should -Be 1
        @($Run.Text | Where-Object { $_ -like ("ERROR: -SubscriptionID '{0}' cannot be used: *. The run stopped before creating or writing any file (exit 1)." -f $Value) }).Count | Should -Be 1
        Test-Path -LiteralPath $script:Root | Should -BeFalse
        script:Get-Calls | Should -BeNullOrEmpty
    }

    It 'stops an id the tenant does not list with exit 1, collecting nothing' {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B'
        $Run = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['C'].Id)
        $Run.ExitCode | Should -Be 1
        @($Run.Text | Where-Object { $_ -like ('ERROR: -SubscriptionID {0} is not among the 2 subscription(s) Get-AzSubscription lists for tenant {1}*' -f $script:Subs['C'].Id, $script:Tenant) }).Count | Should -Be 1
        script:Get-Calls | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.resume-state-*').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:Root -File -Filter 'AllSubscriptions_*.zip').Count | Should -Be 0
    }

    It 'stops a disabled subscription with exit 1, collecting nothing, and collects it with -IncludeDisabled' {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B' -Disabled 'B'
        $Run = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $Run.ExitCode | Should -Be 1
        @($Run.Text | Where-Object { $_ -like 'ERROR: Subscription Sub B (*) is Disabled, not Enabled*' }).Count | Should -Be 1
        script:Get-Calls | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.resume-state-*').Count | Should -Be 0
        $With = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-IncludeDisabled')
        $With.ExitCode | Should -Be 0
        script:Get-Calls | Should -Be (script:Get-Ids 'B')
    }

    It 'keeps only its own state when it fails, and a whole-tenant run after it collects every subscription and leaves that state as it is' {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B', 'C' -Fail 'B'
        # With -ParallelStreams 4: one subscription never starts streams, it
        # runs inline, and that branch's state write uses the run's own key too.
        $Run = script:Invoke-Wrapper -Streams 4 -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        @($Run.Text | Where-Object { $_ -eq 'Only one eligible subscription; running sequentially.' }).Count | Should -Be 1
        script:Get-Calls | Should -Be (script:Get-Ids 'B')
        $One = script:Read-StateAt (script:Get-OneState 'B')
        $One | Should -Not -BeNullOrEmpty
        $One.TenantID | Should -Be ('{0}-subscription-{1}' -f $script:Tenant, $script:Subs['B'].Id)
        $One.Failed | Should -Be (script:Get-Ids 'B')
        $One.Completed | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.resume-state-*' | ForEach-Object Name) | Should -Be @(Split-Path -Leaf (script:Get-OneState 'B'))
        $OneHash = script:Get-FileHashOrNone (script:Get-OneState 'B')

        script:Clear-Calls
        script:Set-Scenario -Subs 'A', 'B', 'C'
        $Whole = script:Invoke-Wrapper
        $Whole.ExitCode | Should -Be 0
        script:Get-Calls | Should -Be (script:Get-Ids 'A', 'B', 'C')
        script:Get-FileHashOrNone (script:Get-OneState 'B') | Should -Be $OneHash
        Test-Path -LiteralPath $script:State | Should -BeFalse
    }

    It 'leaves the state of an unfinished whole-tenant run as it is after a one-subscription -Resume run, and that run still continues' {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B', 'C'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        [pscustomobject]@{
            TenantID                 = $script:Tenant
            CompletedSubscriptionIds = @($script:Subs['A'].Id)
            FailedAttempts           = @([pscustomobject]@{ Id = $script:Subs['B'].Id; Name = 'Sub B'; LastFailedAt = '2026-11-01T00:00:00.0000000Z'; Reason = 'earlier failure'; Attempts = 1 })
            LastUpdated              = '2026-11-01T00:00:00.0000000Z'
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:State -Encoding utf8
        $WholeHash = script:Get-FileHashOrNone $script:State

        foreach ($Letter in 'A', 'B')
        {
            $Run = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs[$Letter].Id, '-Resume')
            $Run.ExitCode | Should -Be 0
            script:Get-FileHashOrNone $script:State | Should -Be $WholeHash
        }
        # Its own state never held the whole tenant's completed A, so A was collected.
        script:Get-Calls | Should -Be (script:Get-Ids 'A', 'B')
        Test-Path -LiteralPath (script:Get-OneState 'A') | Should -BeFalse
        Test-Path -LiteralPath (script:Get-OneState 'B') | Should -BeFalse

        script:Clear-Calls
        $Whole = script:Invoke-Wrapper -Arguments @('-Resume')
        $Whole.ExitCode | Should -Be 0
        @($Whole.Text | Where-Object { $_ -like 'Resume mode: 1 previously completed subscription(s) will be skipped.' }).Count | Should -Be 1
        script:Get-Calls | Should -Be (script:Get-Ids 'B', 'C')
    }
}

Describe 'Run-AllSubscriptions.ps1 -PreflightOnly, end to end' -Skip:($IsWindows) {
    AfterEach {
        if ($script:CaseRuns.Count -gt 0 -and $____Pester.CurrentTest.ErrorRecord.Count -gt 0) { script:Write-CaseRuns }
    }

    It 'passes with exit 0, collecting nothing and creating no inventory folder (<Label>)' -ForEach @(
        @{ Label = 'the whole tenant'; One = $false }
        @{ Label = 'one subscription'; One = $true }
    ) {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B'
        $Arguments = @('-PreflightOnly')
        if ($One) { $Arguments += @('-SubscriptionID', $script:Subs['B'].Id) }
        $Run = script:Invoke-Wrapper -Arguments $Arguments
        $Run.ExitCode | Should -Be 0
        @($Run.Text | Where-Object { $_ -eq 'Every check passed.' }).Count | Should -Be 1
        @($Run.Text | Where-Object { $_ -eq ('Subscriptions to process: {0}' -f $(if ($One) { 1 } else { 2 })) }).Count | Should -Be 1
        @($Run.Text | Where-Object { $_ -like 'Preflight failed*' }).Count | Should -Be 0
        Test-Path -LiteralPath $script:Root | Should -BeFalse
        script:Get-Calls | Should -BeNullOrEmpty
    }

    It 'fails with exit 1 at <Check>, creating no inventory folder' -ForEach @(
        @{ Check = 'the subscription id'; Arguments = @('-SubscriptionID', 'my-subscription') }
        @{ Check = 'the subscription'; Arguments = @('-SubscriptionID', 'cccccccc-0000-4000-8000-000000000003') }
        @{ Check = 'read access'; Arguments = @() }
        @{ Check = 'read access'; Arguments = @('-AllowPartialAccess') }
    ) {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B' -Denied 'B'
        $Run = script:Invoke-Wrapper -Arguments (@('-PreflightOnly') + @($Arguments))
        $Run.ExitCode | Should -Be 1
        @($Run.Text | Where-Object { $_ -eq ('Preflight failed: {0}. Nothing was collected or written to the inventory folder (exit 1).' -f $Check) }).Count | Should -Be 1
        @($Run.Text | Where-Object { $_ -eq 'Every check passed.' }).Count | Should -Be 0
        Test-Path -LiteralPath $script:Root | Should -BeFalse
        script:Get-Calls | Should -BeNullOrEmpty
    }

    It 'fails a denied subscription with read access, naming it' {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B' -Denied 'B'
        $Run = script:Invoke-Wrapper -Arguments @('-PreflightOnly', '-SubscriptionID', $script:Subs['B'].Id)
        $Run.ExitCode | Should -Be 1
        @($Run.Text | Where-Object { $_ -like ('    - Sub B ({0}) - no role on the subscription' -f $script:Subs['B'].Id) }).Count | Should -Be 1
        @($Run.Text | Where-Object { $_ -eq 'Preflight failed: read access. Nothing was collected or written to the inventory folder (exit 1).' }).Count | Should -Be 1
    }

    It 'leaves an existing inventory folder exactly as it is, on <Label>' -ForEach @(
        @{ Label = 'pass'; Denied = @(); Code = 0 }
        @{ Label = 'fail'; Denied = @('A'); Code = 1 }
    ) {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B' -Denied $Denied
        # A state file of an unfinished run, a report folder with its zip, a note.
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'ResourcesReport_earlier') -Force | Out-Null
        [pscustomobject]@{ TenantID = $script:Tenant; CompletedSubscriptionIds = @($script:Subs['A'].Id); FailedAttempts = @(); LastUpdated = '2026-11-01T00:00:00.0000000Z' } | ConvertTo-Json | Set-Content -LiteralPath $script:State -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:Root 'ResourcesReport_earlier/ResourcesReport_earlier.zip') -Value 'zip bytes'
        Set-Content -LiteralPath (Join-Path $script:Root 'note.txt') -Value 'operator note'
        $Old = (Get-Date).AddDays(-2)
        foreach ($Item in @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force) + @(Get-Item -LiteralPath $script:Root -Force)) { $Item.LastWriteTimeUtc = $Old.ToUniversalTime() }
        $Before = script:Get-RootSnapshot
        $Run = script:Invoke-Wrapper -Arguments @('-PreflightOnly', '-Resume')
        $Run.ExitCode | Should -Be $Code
        if ($Code -eq 0) { @($Run.Text | Where-Object { $_ -eq 'Every check passed.' }).Count | Should -Be 1 }
        else { @($Run.Text | Where-Object { $_ -eq 'Preflight failed: read access. Nothing was collected or written to the inventory folder (exit 1).' }).Count | Should -Be 1 }
        script:Get-RootSnapshot | Should -Be $Before
        script:Get-Calls | Should -BeNullOrEmpty
    }
}
