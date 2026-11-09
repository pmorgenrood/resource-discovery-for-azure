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
# shortcut: on Windows only the helper and parse-level tests run (the wrapper's
# Windows inventory folder is fixed at C:\InventoryReports, a shared folder a
# test must not write to, and the stand-in az is a sh script); upgrade when the
# harness rewrites that path in its copy of the tool and ships an az.cmd
# stand-in, run on a Windows host.
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
        # Each subscription the read access check asks about, for the tests
        # that compare the preflight's check with the run's.
        Add-Content -LiteralPath (Join-Path $env:HOME 'access-probes.log') -Value $Matches[1]
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
    $Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
    if ($Scenario.PSObject.Properties['ConsumptionDenied'] -and $Scenario.ConsumptionDenied) { throw 'AuthorizationFailed: stand-in: the client does not have authorization to read usage' }
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
        param([string[]]$Subs, [string[]]$Fail = @(), [string[]]$Disabled = @(), [string[]]$Denied = @(), [switch]$ConsumptionDenied)
        [pscustomobject]@{
            Tenant        = $script:Tenant
            Subscriptions = @($Subs | ForEach-Object { [pscustomobject]@{ Id = $script:Subs[$_].Id; Name = $script:Subs[$_].Name; State = $(if ($Disabled -contains $_) { 'Disabled' } else { 'Enabled' }) } })
            FailIds       = @($Fail | ForEach-Object { $script:Subs[$_].Id })
            DeniedIds     = @($Denied | ForEach-Object { $script:Subs[$_].Id })
            ConsumptionDenied = [bool]$ConsumptionDenied
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
    # The entry names of the newest consolidated zip with ids and times
    # replaced, so two runs' zips can be compared by shape; and the inner
    # per-subscription reports it holds.
    function script:Get-NewestBundleShape
    {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Newest = @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'AllSubscriptions_*.zip' | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)
        if ($Newest.Count -eq 0) { return @() }
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Newest[0].FullName)
        try { @($Archive.Entries | ForEach-Object { ($_.FullName -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<id>') -replace '\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}', '<time>' -replace '\d{8,}', '<stamp>' } | Sort-Object) }
        finally { $Archive.Dispose() }
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

Describe 'Resume state in a folder with brackets in its name' {
    BeforeAll { . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1') }

    It 'writes, reads and finds the state files there' {
        $Dir = Join-Path $TestDrive 'home[1]'
        [void][System.IO.Directory]::CreateDirectory($Dir)
        $T = 'tenant-a'
        $Path = Join-Path $Dir (".resume-state-{0}.json" -f $T)
        Save-CompletedSubscriptionIds -Path $Path -Tenant $T -Ids @('sub-1') -FailedAttempts @([pscustomobject]@{ Id = 'sub-2'; Name = 'n'; Attempts = 1; LastError = 'x'; LastAttempt = '2026-01-01T00:00:00Z' })
        [System.IO.File]::Exists($Path) | Should -BeTrue
        @(Get-CompletedSubscriptionIds -Path $Path -Tenant $T) | Should -Be @('sub-1')
        @(Get-FailedAttempts -Path $Path -Tenant $T).Count | Should -Be 1
        [System.IO.File]::WriteAllText((Join-Path $Dir (".resume-state-{0}-stream-0.json" -f $T)), '{}')
        @(Get-StreamResumeStateFiles -InventoryRoot $Dir -Tenant $T).Count | Should -Be 1
    }

    It 'passes the pre-flight write probe there' {
        $Dir = Join-Path $TestDrive 'probe[1]'
        [void][System.IO.Directory]::CreateDirectory($Dir)
        function Exit-Wrapper { param($Code) throw "exit $Code" }
        $Said = Invoke-PreFlightChecks -InventoryRoot $Dir 6>&1 | Out-String
        $Said | Should -BeLike '*Write probe: OK*'
        @([System.IO.Directory]::GetFiles($Dir, '.write-probe-*')).Count | Should -Be 0
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
        # Its zip has the entries of a run on a tenant that holds only B.
        $Shape = script:Get-NewestBundleShape
        @($Shape | Where-Object { $_ -like '*.zip' }).Count | Should -Be 1
        script:New-Case
        script:Set-Scenario -Subs 'B'
        $Plain = script:Invoke-Wrapper
        $Plain.ExitCode | Should -Be 0
        script:Get-NewestBundleShape | Should -Be $Shape
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
        # runs on the sequential path, and its state write uses the run's own key.
        $Run = script:Invoke-Wrapper -Streams 4 -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        @($Run.Text | Where-Object { $_ -like 'Parallel-streams mode*' }) | Should -BeNullOrEmpty
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

    It 'says its resume state is its own, and names -SubscriptionID in the re-run hints of a failed one-subscription run' {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $Id = $script:Subs['B'].Id
        $Run = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $Id)
        @($Run.Text | Where-Object { $_ -eq ('-SubscriptionID: this run keeps its own resume state ({0}); the resume state of a run of the whole tenant is neither read nor changed.' -f (Split-Path -Leaf (script:Get-OneState 'B'))) }).Count | Should -Be 1
        @($Run.Text | Where-Object { $_ -eq ('Re-run with -SubscriptionID {0} -Resume to retry failed and any unprocessed subscriptions.' -f $Id) }).Count | Should -Be 1
        @($Run.Text | Where-Object { $_ -eq ('Or re-run with -SubscriptionID {0} -ResumeFailedOnly to retry ONLY the failed subscriptions.' -f $Id) }).Count | Should -Be 1
        # A run of the whole tenant keeps the hints as they were.
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $Whole = script:Invoke-Wrapper
        @($Whole.Text | Where-Object { $_ -eq 'Re-run with -Resume to retry failed and any unprocessed subscriptions.' }).Count | Should -Be 1
        @($Whole.Text | Where-Object { $_ -like '-SubscriptionID: this run keeps its own resume state*' }).Count | Should -Be 0
    }

    It 'names its kept resume state file and how to remove it when its subscription is gone, and leaves the file as it is' {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $null = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $Kept = script:Get-OneState 'B'
        $Hash = script:Get-FileHashOrNone $Kept
        $Hash | Should -Not -BeNullOrEmpty
        script:Set-Scenario -Subs 'A'
        $Run = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id)
        $Run.ExitCode | Should -Be 1
        @($Run.Text | Where-Object { $_ -eq ("  This subscription's resume state file {0} is kept for the next run of this command. If the subscription is gone for good, remove it with: Remove-Item -LiteralPath '{0}'" -f $Kept) }).Count | Should -Be 1
        script:Get-FileHashOrNone $Kept | Should -Be $Hash
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
        @{ Label = 'fail'; Denied = @('B'); Code = 1 }
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

    It 'checks access only for what the run would collect: <Case>' -ForEach @(
        @{ Case = '-Resume leaves out a completed subscription that is now unreadable'; Extra = @('-Resume'); Denied = 'A'; Code = 0 }
        @{ Case = '-ResumeFailedOnly leaves out a subscription not on the retry list'; Extra = @('-ResumeFailedOnly'); Denied = 'C'; Code = 0 }
        @{ Case = '-ResumeFailedOnly still checks the subscription on the retry list'; Extra = @('-ResumeFailedOnly'); Denied = 'B'; Code = 1 }
    ) {
        script:New-Case
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        [pscustomobject]@{
            TenantID                 = $script:Tenant
            CompletedSubscriptionIds = @($script:Subs['A'].Id)
            FailedAttempts           = @([pscustomobject]@{ Id = $script:Subs['B'].Id; Name = 'Sub B'; LastFailedAt = '2026-11-01T00:00:00.0000000Z'; Reason = 'earlier failure'; Attempts = 1 })
            LastUpdated              = '2026-11-01T00:00:00.0000000Z'
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:State -Encoding utf8
        $Before = script:Get-RootSnapshot
        script:Set-Scenario -Subs 'A', 'B', 'C' -Denied $Denied
        $R = script:Invoke-Wrapper -Arguments (@('-PreflightOnly') + $Extra)
        $R.ExitCode | Should -Be $Code
        @($R.Text | Where-Object { $_ -like '  The run would collect * of these 3 subscription(s)*' }).Count | Should -Be 1
        script:Get-RootSnapshot | Should -Be $Before
    }

    It 'after an interrupted parallel run, checks what the run would collect from the per-stream state: <Case>' -ForEach @(
        @{ Case = '-ResumeFailedOnly checks the subscription only a per-stream file has on its retry list'; Extra = @('-ResumeFailedOnly'); Denied = 'B'; Code = 1; Collect = 1 }
        @{ Case = '-Resume leaves out the subscription only a per-stream file has completed'; Extra = @('-Resume'); Denied = 'A'; Code = 0; Collect = 2 }
    ) {
        script:New-Case
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        [pscustomobject]@{ TenantID = $script:Tenant; CompletedSubscriptionIds = @(); FailedAttempts = @(); LastUpdated = '2026-11-01T00:00:00.0000000Z' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:State -Encoding utf8
        [pscustomobject]@{ Tenant = $script:Tenant; StreamId = '0'; Completed = @($script:Subs['A'].Id); FailedAttempts = @([pscustomobject]@{ Id = $script:Subs['B'].Id; Name = 'Sub B'; LastFailedAt = '2026-11-01T00:00:00.0000000Z'; Reason = 'earlier failure'; Attempts = 1 }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:Root ('.resume-state-{0}-stream-0.json' -f $script:Tenant)) -Encoding utf8
        $Before = script:Get-RootSnapshot
        script:Set-Scenario -Subs 'A', 'B', 'C' -Denied $Denied
        $R = script:Invoke-Wrapper -Arguments (@('-PreflightOnly') + $Extra)
        $R.ExitCode | Should -Be $Code
        @($R.Text | Where-Object { $_ -like ('  The run would collect {0} of these 3 subscription(s)*' -f $Collect) }).Count | Should -Be 1
        script:Get-RootSnapshot | Should -Be $Before
    }

    It 'stops an id that is not a GUID with exit 1 under Set-StrictMode -Version Latest, with no strict-mode error' -ForEach @(@{ Value = 'not-a-guid' }) {
        script:New-Case
        script:Set-Scenario -Subs 'A'
        $Command = "Set-StrictMode -Version Latest; & '{0}' -TenantID '{1}' -SubscriptionID '{2}'; exit `$LASTEXITCODE" -f $script:Wrapper, $script:Tenant, $Value
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($Arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $Command)) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['PATH'] = $script:Bin + [System.IO.Path]::PathSeparator + $env:PATH
        $Info.Environment['RDA_STANDIN_AZURE'] = $script:Scenario
        $Info.Environment['RDA_STANDIN_TENANT'] = $script:Tenant
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        $Out = $Proc.StandardOutput.ReadToEndAsync()
        $Err = $Proc.StandardError.ReadToEndAsync()
        $Proc.WaitForExit(120000) | Should -BeTrue
        $Proc.ExitCode | Should -Be 1
        [string]$Err.Result | Should -BeNullOrEmpty
        ([string]$Out.Result) | Should -BeLike ("*ERROR: -SubscriptionID '{0}' cannot be used*" -f $Value)
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }

    It 'probes consumption access as the run does, also when -Resume leaves nothing to collect' {
        script:New-Case
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        [pscustomobject]@{ TenantID = $script:Tenant; CompletedSubscriptionIds = @($script:Subs['A'].Id, $script:Subs['B'].Id); FailedAttempts = @(); LastUpdated = '2026-11-01T00:00:00.0000000Z' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:State -Encoding utf8
        script:Set-Scenario -Subs 'A', 'B' -ConsumptionDenied
        $R = script:Invoke-Wrapper -Arguments @('-PreflightOnly', '-Resume')
        $R.ExitCode | Should -Be 1
        @($R.Text | Where-Object { $_ -like 'Preflight failed: consumption access.*' }).Count | Should -Be 1
        $Skip = script:Invoke-Wrapper -Arguments @('-PreflightOnly', '-Resume', '-SkipConsumption')
        $Skip.ExitCode | Should -Be 0
    }

    It 'does not probe consumption for -ResumeFailedOnly with nothing to retry, as the run stops before it' {
        script:New-Case
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        [pscustomobject]@{ TenantID = $script:Tenant; CompletedSubscriptionIds = @($script:Subs['A'].Id); FailedAttempts = @([pscustomobject]@{ Id = 'cccccccc-0000-4000-8000-00000000000c'; Name = 'Gone'; LastFailedAt = '2026-11-01T00:00:00.0000000Z'; Reason = 'x'; Attempts = 1 }); LastUpdated = '2026-11-01T00:00:00.0000000Z' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:State -Encoding utf8
        script:Set-Scenario -Subs 'A', 'B' -ConsumptionDenied
        $Pf = script:Invoke-Wrapper -Arguments @('-PreflightOnly', '-ResumeFailedOnly')
        $Run = script:Invoke-Wrapper -Arguments @('-ResumeFailedOnly')
        $Pf.ExitCode | Should -Be $Run.ExitCode -Because 'the preflight ends as the run does'
        $Pf.ExitCode | Should -Be 0
    }

    It 'with -Resume and -ResumeFailedOnly, leaves a retry that an earlier run completed out of the read check, as the run does' {
        script:New-Case
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $Failed = @('A', 'B' | ForEach-Object { [pscustomobject]@{ Id = $script:Subs[$_].Id; Name = ('Sub ' + $_); LastFailedAt = '2026-11-01T00:00:00.0000000Z'; Reason = 'x'; Attempts = 1 } })
        [pscustomobject]@{ TenantID = $script:Tenant; CompletedSubscriptionIds = @($script:Subs['A'].Id); FailedAttempts = $Failed; LastUpdated = '2026-11-01T00:00:00.0000000Z' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:State -Encoding utf8
        script:Set-Scenario -Subs 'A', 'B' -Denied 'A'
        $Pf = script:Invoke-Wrapper -Arguments @('-PreflightOnly', '-Resume', '-ResumeFailedOnly')
        $Run = script:Invoke-Wrapper -Arguments @('-Resume', '-ResumeFailedOnly')
        $Pf.ExitCode | Should -Be $Run.ExitCode -Because 'the preflight checks what the run checks'
        $Pf.ExitCode | Should -Be 0
    }

    It 'ends as the run does when no subscription of the tenant is Enabled' {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B' -Disabled 'A', 'B'
        $Pf = script:Invoke-Wrapper -Arguments @('-PreflightOnly')
        $Run = script:Invoke-Wrapper
        $Pf.ExitCode | Should -Be $Run.ExitCode -Because 'the preflight ends as the run does'
        @($Pf.Text | Where-Object { $_ -like 'WARNING: None of the 2 subscription(s) the tenant lists is Enabled, so a run would collect nothing.*' }).Count | Should -Be 1
        script:Get-Calls | Should -BeNullOrEmpty
    }

    It 'checks a -ResumeFailedOnly retry that is also listed as completed when no per-stream state is there, as the run collects it' {
        script:New-Case
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        [pscustomobject]@{ TenantID = $script:Tenant; CompletedSubscriptionIds = @($script:Subs['A'].Id); FailedAttempts = @([pscustomobject]@{ Id = $script:Subs['A'].Id; Name = 'Sub A'; LastFailedAt = '2026-11-01T00:00:00.0000000Z'; Reason = 'x'; Attempts = 1 }); LastUpdated = '2026-11-01T00:00:00.0000000Z' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:State -Encoding utf8
        script:Set-Scenario -Subs 'A', 'B' -Denied 'A'
        $Pf = script:Invoke-Wrapper -Arguments @('-PreflightOnly', '-ResumeFailedOnly')
        $Run = script:Invoke-Wrapper -Arguments @('-ResumeFailedOnly')
        $Run.ExitCode | Should -Be 1 -Because 'the run retries A and stops at its read access check'
        $Pf.ExitCode | Should -Be $Run.ExitCode -Because 'the preflight checks the subscription the run would collect'
        @($Pf.Text | Where-Object { $_ -like 'Preflight failed: *' }).Count | Should -Be 1
    }
}

Describe 'The preflight and the run check the same subscriptions' -Skip:($IsWindows) {
    # A guard: the preflight works out which subscriptions the run would
    # collect on its own (the run's selection is inline in the wrapper). When a
    # change to the run's selection is not made to the preflight too, these
    # cases see the two check different subscriptions and fail.
    BeforeAll {
        function script:Get-Probes
        {
            $Log = Join-Path $script:CaseHome 'access-probes.log'
            if (-not (Test-Path -LiteralPath $Log)) { return @() }
            @(Get-Content -LiteralPath $Log | Where-Object { $_ } | Sort-Object -Unique)
        }
        function script:Write-State
        {
            param([string[]]$Completed = @(), [string[]]$Failed = @(), [string]$Path = $script:State, [switch]$Stream)
            New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
            $FailedAttempts = @($Failed | ForEach-Object { [pscustomobject]@{ Id = $script:Subs[$_].Id; Name = ('Sub ' + $_); LastFailedAt = '2026-11-01T00:00:00.0000000Z'; Reason = 'x'; Attempts = 1 } })
            $Ids = @($Completed | ForEach-Object { $script:Subs[$_].Id })
            $Obj = if ($Stream) { [pscustomobject]@{ Completed = $Ids; FailedAttempts = $FailedAttempts } } else { [pscustomobject]@{ TenantID = $script:Tenant; CompletedSubscriptionIds = $Ids; FailedAttempts = $FailedAttempts; LastUpdated = '2026-11-01T00:00:00.0000000Z' } }
            $Obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding utf8
        }
    }
    AfterEach {
        if ($script:CaseRuns.Count -gt 0 -and $____Pester.CurrentTest.ErrorRecord.Count -gt 0) { script:Write-CaseRuns }
    }

    It '<Case>' -ForEach @(
        @{ Case = 'a fresh run'; Extra = @(); Completed = @(); Failed = @(); StreamCompleted = @(); StreamFailed = @() }
        @{ Case = '-Resume after an earlier run completed one'; Extra = @('-Resume'); Completed = @('A'); Failed = @('B'); StreamCompleted = @(); StreamFailed = @() }
        @{ Case = '-ResumeFailedOnly with one on the retry list'; Extra = @('-ResumeFailedOnly'); Completed = @('A'); Failed = @('B'); StreamCompleted = @(); StreamFailed = @() }
        @{ Case = '-Resume -ResumeFailedOnly with a retry also completed'; Extra = @('-Resume', '-ResumeFailedOnly'); Completed = @('A'); Failed = @('A', 'B'); StreamCompleted = @(); StreamFailed = @() }
        @{ Case = '-ResumeFailedOnly with a retry also completed, no per-stream state'; Extra = @('-ResumeFailedOnly'); Completed = @('A'); Failed = @('A'); StreamCompleted = @(); StreamFailed = @() }
        @{ Case = '-Resume after an interrupted parallel run'; Extra = @('-Resume'); Completed = @('A'); Failed = @(); StreamCompleted = @('C'); StreamFailed = @('B') }
        @{ Case = '-ResumeFailedOnly after an interrupted parallel run'; Extra = @('-ResumeFailedOnly'); Completed = @(); Failed = @('A'); StreamCompleted = @('A'); StreamFailed = @('B') }
    ) {
        script:New-Case
        script:Set-Scenario -Subs 'A', 'B', 'C'
        script:Write-State -Completed $Completed -Failed $Failed
        if ($StreamCompleted.Count -gt 0 -or $StreamFailed.Count -gt 0)
        {
            script:Write-State -Completed $StreamCompleted -Failed $StreamFailed -Stream -Path (Join-Path $script:Root ('.resume-state-{0}-stream-0.json' -f $script:Tenant))
        }
        $Pf = script:Invoke-Wrapper -Arguments (@('-PreflightOnly', '-SkipConsumption') + $Extra)
        $Pf.ExitCode | Should -Be 0
        $PfProbes = @(script:Get-Probes)
        Remove-Item -LiteralPath (Join-Path $script:CaseHome 'access-probes.log') -Force -ErrorAction SilentlyContinue
        $Run = script:Invoke-Wrapper -Arguments (@('-SkipConsumption', '-SkipMetrics') + $Extra)
        $Run.ExitCode | Should -Be 0
        $RunProbes = @(script:Get-Probes)
        ($PfProbes -join ',') | Should -Be ($RunProbes -join ',') -Because 'the preflight checks the subscriptions the run checks'
    }
}

Describe 'A home folder with brackets in its name' -Skip:($IsWindows) {
    AfterEach {
        if ($script:CaseRuns.Count -gt 0 -and $____Pester.CurrentTest.ErrorRecord.Count -gt 0) { script:Write-CaseRuns }
    }

    It 'stops <Label> with exit 1 before writing anything' -ForEach @(
        @{ Label = 'a preflight'; Arguments = @('-PreflightOnly', '-Resume') }
        @{ Label = 'a run'; Arguments = @('-Resume') }
    ) {
        script:New-Case
        # The same case under a home whose name holds brackets.
        $script:CaseHome = Join-Path $script:TestBase ('home[' + [guid]::NewGuid().ToString().Substring(0, 4) + ']')
        [void][System.IO.Directory]::CreateDirectory($script:CaseHome)
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        script:Set-Scenario -Subs 'A', 'B'
        $Run = script:Invoke-Wrapper -Arguments $Arguments
        $Run.ExitCode | Should -Be 1
        @($Run.Text | Where-Object { $_ -eq ('ERROR: The inventory folder {0} has [ or ] in its path, which this script cannot use. Set HOME to a folder without them and run again.' -f $script:Root) }).Count | Should -Be 1
        [System.IO.Directory]::Exists($script:Root) | Should -BeFalse
        script:Get-Calls | Should -BeNullOrEmpty
    }
}

Describe 'A one-subscription -Resume run asked for more than one stream' -Skip:($IsWindows) {
    AfterEach {
        if ($script:CaseRuns.Count -gt 0 -and $____Pester.CurrentTest.ErrorRecord.Count -gt 0) { script:Write-CaseRuns }
    }

    It 'does not collect again a subscription its state lists as completed (<Label>)' -ForEach @(
        @{ Label = '-SubscriptionID'; One = $true }
        @{ Label = 'a tenant of one'; One = $false }
    ) {
        script:New-Case
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        if ($One)
        {
            script:Set-Scenario -Subs 'A', 'B'
            $StateFile = script:Get-OneState 'B'
            $Tenant = ('{0}-subscription-{1}' -f $script:Tenant, $script:Subs['B'].Id)
            $Arguments = @('-SubscriptionID', $script:Subs['B'].Id, '-Resume')
        }
        else
        {
            script:Set-Scenario -Subs 'B'
            $StateFile = $script:State
            $Tenant = $script:Tenant
            $Arguments = @('-Resume')
        }
        # An earlier run completed B; a failure of another kept the state.
        [pscustomobject]@{ TenantID = $Tenant; CompletedSubscriptionIds = @($script:Subs['B'].Id); FailedAttempts = @([pscustomobject]@{ Id = 'cccccccc-0000-4000-8000-00000000000c'; Name = 'Gone'; LastFailedAt = '2026-11-01T00:00:00.0000000Z'; Reason = 'x'; Attempts = 1 }); LastUpdated = '2026-11-01T00:00:00.0000000Z' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StateFile -Encoding utf8
        $Run = script:Invoke-Wrapper -Arguments $Arguments -Streams 2
        script:Get-Calls | Should -BeNullOrEmpty
        @($Run.Text | Where-Object { $_ -like 'Skipping (already completed): Sub B (*' }).Count | Should -Be 1
        @($Run.Text | Where-Object { $_ -like 'Parallelism: -ParallelStreams 1 (one eligible subscription)*' }).Count | Should -Be 1
    }
}

Describe 'A one-subscription retry that succeeds, asked for four streams' -Skip:($IsWindows) {
    It 'takes the subscription off the retry list when it was also listed as completed, and clears the state' {
        script:New-Case
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $One = script:Get-OneState 'B'
        [pscustomobject]@{ TenantID = ('{0}-subscription-{1}' -f $script:Tenant, $script:Subs['B'].Id); CompletedSubscriptionIds = @($script:Subs['B'].Id); FailedAttempts = @([pscustomobject]@{ Id = $script:Subs['B'].Id; Name = 'Sub B'; LastFailedAt = '2026-11-01T00:00:00.0000000Z'; Reason = 'earlier failure'; Attempts = 1 }); LastUpdated = '2026-11-01T00:00:00.0000000Z' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $One -Encoding utf8
        script:Set-Scenario -Subs 'A', 'B'
        $R = script:Invoke-Wrapper -Arguments @('-SubscriptionID', $script:Subs['B'].Id, '-ResumeFailedOnly') -Streams 4
        $R.ExitCode | Should -Be 0
        script:Get-Calls | Should -Be (script:Get-Ids 'B')
        Test-Path -LiteralPath $One | Should -BeFalse -Because 'a clean retry clears the state, so the next run does not retry it again'
    }
}


Describe 'The Windows PowerShell re-launch of Run-AllSubscriptions.ps1' {
    BeforeAll {
        # The statements of the Windows PowerShell 5.1 block that matter here,
        # run as a script of their own under the wrapper's param block (this
        # host has no Windows PowerShell): the empty -SubscriptionID stop and
        # the loop that rebuilds the arguments for the PowerShell 7 run.
        $Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $Block = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -match 'PSVersion\.Major -lt 7' })[0]
        $Body = @($Block.Clauses[0].Item2.Statements)
        # The id check, the first statement of the script (before the 5.1 block).
        $EmptyStop = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq "`$PSBoundParameters.ContainsKey('SubscriptionID')" })
        $Forward = @($Body | Where-Object { $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and $_.Extent.Text -match 'PSBoundParameters\.GetEnumerator' })
        $script:Found = @($EmptyStop.Count, $Forward.Count)
        $script:Probe = Join-Path ([System.IO.Path]::GetTempPath()) ('ps51-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $Text = $Ast.ParamBlock.Extent.Text + "`n" + $EmptyStop[0].Extent.Text + "`n`$ForwardArgs = @()`n" + $Forward[0].Extent.Text + "`nWrite-Output ('ARGS ' + (`$ForwardArgs -join '|'))`n"
        Set-Content -LiteralPath $script:Probe -Value $Text -Encoding utf8
        $script:Pwsh = Join-Path $PSHOME 'pwsh'
    }
    AfterAll { Remove-Item -LiteralPath $script:Probe -Force -ErrorAction SilentlyContinue }

    It 'finds the -SubscriptionID check as the first statement of the script, before the PowerShell 7, Azure CLI and Az module set-up, and the forwarding loop' {
        $script:Found | Should -Be @(1, 1)
        $Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        @($Ast.EndBlock.Statements)[0].Extent.Text | Should -Match "ContainsKey\('SubscriptionID'\)"
        $First = @($Ast.EndBlock.Statements)[0].Extent.EndOffset
        foreach ($Setup in 'Get-Command az', 'Install-Module', 'Import-Module', 'PSVersion.Major -lt 7') { $Ast.Extent.Text.IndexOf($Setup) | Should -BeGreaterThan $First -Because "$Setup comes after the id check" }
    }

    It 'stops a non-GUID -SubscriptionID with exit 1 before re-launching, giving the reason (<Value>)' -ForEach @(
        @{ Value = 'my-subscription' }
        @{ Value = '{aaaaaaaa-0000-4000-8000-000000000001}' }
        @{ Value = 'aaaaaaaa00004000800000000000001' }
        @{ Value = 'aaaaaaaa-0000-4000-8000-000000000001,bbbbbbbb-0000-4000-8000-000000000002' }
    ) {
        $Out = & $script:Pwsh -NoProfile -NonInteractive -File $script:Probe -TenantID 't' -SubscriptionID $Value
        $LASTEXITCODE | Should -Be 1
        ($Out -join "`n") | Should -BeLike ("*ERROR: -SubscriptionID '{0}' cannot be used: it is not a subscription id*" -f $Value)
        @($Out | Where-Object { $_ -like 'ARGS *' }) | Should -BeNullOrEmpty
    }

    It 'takes a GUID with spaces around it and in any letter case' {
        $Out = & $script:Pwsh -NoProfile -NonInteractive -File $script:Probe -TenantID 't' -SubscriptionID ' AAAAAAAA-0000-4000-8000-000000000001 '
        $LASTEXITCODE | Should -Be 0
        # Accepted: the run goes on with it.
        @($Out | Where-Object { $_ -like 'ARGS *-SubscriptionID*' }).Count | Should -Be 1
    }

    It 'forwards -SubscriptionID with its value and -PreflightOnly as a bare switch' {
        $Out = & $script:Pwsh -NoProfile -NonInteractive -File $script:Probe -TenantID 't' -SubscriptionID 'aaaaaaaa-0000-4000-8000-000000000001' -PreflightOnly
        $LASTEXITCODE | Should -Be 0
        @($Out | Where-Object { $_ -like 'ARGS *' }) | Should -Be @('ARGS -TenantID|t|-SubscriptionID|aaaaaaaa-0000-4000-8000-000000000001|-PreflightOnly')
    }

    It 'stops an empty or blank -SubscriptionID with exit 1 before re-launching, naming the value' -ForEach @(@{ Value = '' }, @{ Value = '  ' }) {
        $Out = & $script:Pwsh -NoProfile -NonInteractive -File $script:Probe -TenantID 't' -SubscriptionID $Value
        $LASTEXITCODE | Should -Be 1
        ($Out -join "`n") | Should -BeLike ("*ERROR: -SubscriptionID '{0}' cannot be used: it is empty.*" -f $Value)
        @($Out | Where-Object { $_ -like 'ARGS *' }) | Should -BeNullOrEmpty
    }
}

Describe 'Run-AllSubscriptions.ps1 -PreflightOnly free-space check' {
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $If = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '-not $PreflightOnly' -and $_.Extent.Text.Contains('Invoke-PreFlightChecks') })
        if ($If.Count -ne 1 -or $null -eq $If[0].ElseClause) { throw 'the -PreflightOnly else block was not found in Run-AllSubscriptions.ps1' }
        $script:DiskBlock = [scriptblock]::Create((@($If[0].ElseClause.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"))
        # Invoke-PreFlightChecks, which the block calls with -ReadOnly.
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1')
        function script:Invoke-DiskCheck
        {
            param([long]$FreeBytes)
            $script:Exited = $null
            # Set by the run before the block, as it is for a preflight.
            Set-Variable -Name InventoryRoot -Value $(if ($PSVersionTable.Platform -eq 'Unix') { "$HOME/InventoryReports" } else { 'C:\InventoryReports' })
            Mock Get-FolderFreeSpaceBytes { $FreeBytes }
            Mock Set-Content { throw 'a preflight must write nothing' }
            Mock Exit-Wrapper { param($Code) $script:Exited = $Code }
            @(. $script:DiskBlock 6>&1 | ForEach-Object { [string]$_ })
        }
        function Exit-Wrapper { param($Code) }
    }

    It 'stops with exit 1 naming free disk space when less than 100 MB is free, as a run does, and writes nothing' {
        $Lines = Invoke-DiskCheck -FreeBytes (50MB)
        $script:Exited | Should -Be 1
        $script:PreflightCheck | Should -Be 'free disk space'
        @($Lines | Where-Object { $_ -like 'ERROR: Free disk space at * is 50 MB. The script needs at least 100 MB to start.*' }).Count | Should -Be 1
        Should -Invoke Get-FolderFreeSpaceBytes -Times 1 -Exactly
        Should -Invoke Set-Content -Times 0 -Exactly
    }

    It 'passes with enough free space' {
        $Lines = Invoke-DiskCheck -FreeBytes (2GB)
        $script:Exited | Should -BeNullOrEmpty
        @($Lines | Where-Object { $_ -like 'Free disk space: * MB at *' }).Count | Should -Be 1
        Should -Invoke Set-Content -Times 0 -Exactly
    }
}

Describe 'Every resume state read and write of the wrapper uses the run''s own key' {
    # A -SubscriptionID run keeps its own resume state, keyed by $ResumeKey. A
    # state helper called with -Tenant $TenantID would read a one-subscription
    # run's file as another tenant's (and write the tenant back into it). This
    # also catches such a call that a later merge brings in.
    It 'passes -Tenant $ResumeKey to every helper of Functions/RunAllSubscriptions.Functions.ps1 that reads or writes a state file' {
        $Root = Split-Path $PSScriptRoot -Parent
        $FnAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'Functions/RunAllSubscriptions.Functions.ps1'), [ref]$null, [ref]$null)
        $StateHelpers = @($FnAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object {
                $Names = @($_.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                $Names -contains 'Tenant' -and ($Names -contains 'Path' -or $Names -contains 'InventoryRoot')
            } | ForEach-Object { $_.Name })
        $StateHelpers | Should -Contain 'Get-CompletedSubscriptionIds'
        $StateHelpers | Should -Contain 'Save-CompletedSubscriptionIds'
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$null)
        $Calls = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $StateHelpers -contains $args[0].GetCommandName() }, $true))
        $Calls.Count | Should -BeGreaterThan 5
        $Wrong = foreach ($Call in $Calls)
        {
            $E = @($Call.CommandElements)
            $Arg = $null
            for ($i = 0; $i -lt $E.Count; $i++) { if ($E[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $E[$i].ParameterName -eq 'Tenant') { $Arg = if ($E[$i].Argument) { $E[$i].Argument.Extent.Text } elseif ($i + 1 -lt $E.Count) { $E[$i + 1].Extent.Text } } }
            if ($Arg -ne '$ResumeKey') { '{0} (line {1}): -Tenant {2}' -f $Call.GetCommandName(), $Call.Extent.StartLineNumber, $Arg }
        }
        @($Wrong) | Should -BeNullOrEmpty
    }
}

Describe 'Select-OneSubscription -Preflight' {
    BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1') }

    It 'words a stop for a preflight without speaking of a run, and for a run as before (<Case>)' -ForEach @(
        @{ Case = 'not listed'; Subs = @(); Like = 'ERROR: -SubscriptionID * is not among the 0 subscription(s) Get-AzSubscription lists for tenant t' }
        @{ Case = 'not Enabled'; Subs = @([pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012'; Name = 'S'; State = 'Disabled' }); Like = 'ERROR: Subscription S (*) is Disabled, not Enabled' }
    ) {
        $Pf = Select-OneSubscription -Subscriptions $Subs -SubscriptionID '12345678-1234-1234-1234-123456789012' -Tenant 't' -Preflight
        $Run = Select-OneSubscription -Subscriptions $Subs -SubscriptionID '12345678-1234-1234-1234-123456789012' -Tenant 't'
        $Pf.Stop | Should -BeTrue
        $Pf.Lines[0].Text | Should -BeLike ($Like + '*')
        $Pf.Lines[0].Text | Should -Not -BeLike '*this run stopped*'
        $Run.Lines[0].Text | Should -BeLike ($Like + ', so this run stopped before collecting anything (exit 1)*')
    }
}

Describe 'Invoke-PreFlightChecks -ReadOnly in Cloud Shell without storage' {
    BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1') }

    It 'does not say a preflight continues or writes a zip' {
        function Get-CloudDrive { $null }
        Mock Get-FolderFreeSpaceBytes { 2GB }
        $Lines = @(Invoke-PreFlightChecks -InventoryRoot $TestDrive -ReadOnly 6>&1 | ForEach-Object { [string]$_ })
        @($Lines | Where-Object { $_ -like '*Cloud Shell detected, but no storage account is mounted.*' }).Count | Should -Be 1
        @($Lines | Where-Object { $_ -like '*Continuing in ephemeral mode*' }) | Should -BeNullOrEmpty
        @($Lines | Where-Object { $_ -like '*A run here would keep its report ZIP only until the shell closes*' }).Count | Should -Be 1
    }
}

Describe 'Get-FolderFreeSpaceBytes' {
    BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1') }

    It 'reads the free space of the volume that holds the folder, not of the drive root (on Linux and macOS)' -Skip:($IsWindows) {
        # PowerShell's drive / would give the root volume's: it is not read.
        Mock Get-Item { [pscustomobject]@{ PSDrive = [pscustomobject]@{ Free = 1 } } }
        $Free = Get-FolderFreeSpaceBytes -Path $TestDrive
        $Free | Should -BeGreaterThan 1
        Should -Invoke Get-Item -Times 0 -Exactly
    }
}

Describe 'ResourceInventory.ps1 reads free space as the wrapper does' {
    It 'reads the folder''s own volume on Linux and macOS in its own pre-flight copy' {
        $Text = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1') -Raw
        $Text | Should -Match '\[System\.IO\.DriveInfo\]::new\(\$RootItem\.FullName\)\.AvailableFreeSpace'
        $Text | Should -Not -Match '\[math\]::Round\(\$Drive\.Free / 1MB, 0\)'
    }

    It 'reads the folder''s own volume, not the drive''s free figure, on Linux and macOS' -Skip:($IsWindows) {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $If = @($Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '-not $RunAllSubs.IsPresent' })
        $Space = @($If[0].Clauses[0].Item2.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Extent.Text.Contains('$PreFlightInventoryRoot -ErrorAction Stop') })
        $Space.Count | Should -Be 1
        # Set-Variable: read only by the lifted block.
        Set-Variable -Name PreFlightInventoryRoot -Value $TestDrive
        # A drive whose free figure is 1 byte: read, it would stop the run.
        Mock Get-Item { [pscustomobject]@{ PSDrive = [pscustomobject]@{ Free = 1 }; FullName = $TestDrive } }
        $Said = @(. ([scriptblock]::Create($Space[0].Extent.Text)) 6>&1 | ForEach-Object { [string]$_ })
        @($Said | Where-Object { $_ -like 'Free disk space: * MB at *' -or $_ -like 'WARNING: Free disk space at *' }).Count | Should -Be 1
        @($Said | Where-Object { $_ -like 'WARNING: Could not determine free disk space*' }) | Should -BeNullOrEmpty
    }
}
