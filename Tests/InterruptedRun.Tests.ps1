# A run stopped by Ctrl+C before every subscription was processed.
#
#   - The wrapper prints one line (interrupted before all subscriptions were
#     processed, the resume state is kept, run the same command with -Resume),
#     on the sequential path and with 2 streams.
#   - Started with pwsh -File, the process exits 130; with pwsh -Command it
#     exits 1, PowerShell's own code for a stopped command.
#   - Started with pwsh -NoExit -File, inside a PowerShell session, or inside
#     an interactive pwsh in a terminal (a pseudo-terminal, with a real Ctrl+C
#     key), it goes back to the prompt: the session stays open and reads
#     $LASTEXITCODE 130.
#   - The resume state is kept and the run lock is released: the next run with
#     -Resume collects only what was not collected and ends clean, and the run
#     after it is a clean run. That holds for a -Resume typed into the same
#     session, and after a second Ctrl+C on a -Resume run with 2 streams.
#   - Which launches may set the process's exit code: only the process's own
#     startup script without -NoExit, in any form pwsh takes.
#
# The runs are Run-AllSubscriptions.ps1 itself, each started as its own pwsh
# process from a copy of the tool whose ResourceInventory.ps1 is a stand-in,
# with Azure answered by stand-in Az modules and an az command found first on
# the module path and PATH of that process. The stand-in holds the collection
# of the subscriptions named in RDA_STANDIN_HOLD until the test sends SIGINT
# (what a terminal sends for Ctrl+C) to the wrapper's process, or the Ctrl+C
# key to the terminal. The process's home is a scratch folder, so the
# inventory root is under it. SIGINT and the inventory root under $HOME are
# Linux and macOS only, so these tests do not run on Windows. The terminal
# case needs python3 for its pseudo-terminal and is skipped without it.
#
# Run with: Invoke-Pester ./Tests/InterruptedRun.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('InterruptedRunTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
    $script:Tenant = '12345678-1234-1234-1234-123456789012'
    $script:Pwsh = Join-Path $PSHOME 'pwsh'
    $script:Started = [System.Collections.Generic.List[object]]::new()
    $script:Line = 'Interrupted (Ctrl+C) before all subscriptions were processed.'

    # --- The tool: the wrapper and its helpers as they are, and a stand-in
    # ResourceInventory.ps1 that records each call, waits while its
    # subscription is held, and otherwise writes one report folder and zip.
    $script:ToolRoot = Join-Path $script:TestBase 'tool'
    New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
    foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Version.json', 'Functions', 'Extension'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:ToolRoot -Recurse -Force
    }
    $script:Wrapper = Join-Path $script:ToolRoot 'Run-AllSubscriptions.ps1'
    $StandInInner = @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
Set-Content -LiteralPath (Join-Path $HOME ('collecting-{0}-{1}' -f $SubscriptionID, [guid]::NewGuid().ToString('N').Substring(0, 6))) -Value $PID
if (@($env:RDA_STANDIN_HOLD -split ',') -contains $SubscriptionID)
{
    $Deadline = (Get-Date).AddSeconds(240)
    while ((Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 200 }
}
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
Set-Content -LiteralPath (Join-Path $HOME ('collected-{0}-{1}' -f $SubscriptionID, [guid]::NewGuid().ToString('N').Substring(0, 6))) -Value $PID
$Global:ZipOutputFile = $Zip
$Global:Resources = @(1)
$Global:ResourceCount = 1
'@
    Set-Content -LiteralPath (Join-Path $script:ToolRoot 'ResourceInventory.ps1') -Value $StandInInner -Encoding utf8

    # --- Stand-in Azure: signed in to the scenario's tenant with two
    # subscriptions. Save-AzContext writes a placeholder token cache; autosave
    # reads as off once Disable-AzContextAutosave has run in the process. The
    # role, permission, resource count and usage reads answer as for a Reader,
    # so the wrapper's up-front checks pass wherever they run.
    $script:Modules = Join-Path $script:TestBase 'modules'
    $Accounts = @'
$script:AutosaveOff = $false
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
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context, $Scope) Get-RdaStandInContext }
function Save-AzContext { [CmdletBinding()] param($Path, [switch]$Force) [System.IO.File]::WriteAllText($Path, '{"Contexts":{"placeholder":{"TokenCache":{"CacheData":"cGxhY2Vob2xkZXI="}}}}') }
function Import-AzContext { [CmdletBinding()] param($Path) $null = Get-Item -LiteralPath $Path -Force -ErrorAction Stop; Get-RdaStandInContext }
function Disable-AzContextAutosave { [CmdletBinding()] param($Scope) $script:AutosaveOff = $true }
function Get-AzContextAutosaveSetting
{
    [CmdletBinding()] param($Scope)
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
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'show') { [pscustomobject]@{ tenantId = $Scenario.Tenant } | ConvertTo-Json -Compress; exit 0 }
if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'get-access-token') { exit 0 }
exit 1
'@
    Set-Content -LiteralPath (Join-Path $script:Bin 'az.ps1') -Value $Az -Encoding utf8

    # A fresh home (its InventoryReports folder is the inventory root) and
    # scenario file per test: one tenant, two subscriptions.
    function script:New-Case
    {
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        [pscustomobject]@{
            Tenant        = $script:Tenant
            Subscriptions = @(
                [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' },
                [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B' })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One process (stdin kept open for -Session, else closed), started and
    # left running. A test runner started in the background by a
    # non-interactive shell ignores SIGINT, and its child processes inherit
    # that, so the process is started through perl, which sets SIGINT back to
    # the default before it starts pwsh.
    $script:Perl = Get-Command -Name perl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:SigIntIgnored = (-not $IsWindows) -and @((Get-Content -LiteralPath '/proc/self/status' -ErrorAction SilentlyContinue | Where-Object { $_ -like 'SigIgn:*' }) -replace '^SigIgn:\s*', '' | Where-Object { ([Convert]::ToUInt64($_, 16) -band 2) -ne 0 }).Count -gt 0
    function script:Get-WrapperArgs
    {
        param([int]$Streams, [switch]$Resume)
        $WrapperArgs = @('-TenantID', $script:Tenant, '-ParallelStreams', [string]$Streams, '-SkipMetrics', '-SkipConsumption')
        if ($Resume) { $WrapperArgs += '-Resume' }
        return $WrapperArgs
    }
    function script:Start-Run
    {
        param([string[]]$Command, [string]$Hold = '', [switch]$Session)
        if ($script:Perl)
        {
            $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Perl.Source)
            $Launcher = @('-e', '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or die "exec: $!"')
        }
        else
        {
            $Info = [System.Diagnostics.ProcessStartInfo]::new('/bin/sh')
            $Launcher = @('-c', 'exec "$@"', 'sh')
        }
        foreach ($Arg in @($Launcher + $Command)) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['PATH'] = $script:Bin + [IO.Path]::PathSeparator + $env:PATH
        $Info.Environment['RDA_STANDIN_AZURE'] = $script:Scenario
        $Info.Environment['RDA_STANDIN_HOLD'] = $Hold
        $Info.Environment['NO_COLOR'] = '1'
        $Proc = [System.Diagnostics.Process]::Start($Info)
        if (-not $Session) { $Proc.StandardInput.Close() }
        $script:Started.Add($Proc)
        return [pscustomobject]@{ Process = $Proc; Out = $Proc.StandardOutput.ReadToEndAsync(); Err = $Proc.StandardError.ReadToEndAsync() }
    }
    function script:Start-Wrapper
    {
        param([int]$Streams, [string]$Hold = '', [switch]$Resume)
        script:Start-Run -Hold $Hold -Command (@($script:Pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper) + (script:Get-WrapperArgs -Streams $Streams -Resume:$Resume))
    }

    # The lines a session is given after the wrapper: what it reads, and a line
    # that shows it is still open.
    $script:SessionLines = @('"after: $LASTEXITCODE"', '"session still open"', 'exit 0')
    function script:Get-SessionResult
    {
        param([string[]]$Text)
        [pscustomobject]@{
            After = @($Text | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^after: \S*$' })
            Open  = @($Text | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq 'session still open' }).Count -eq 1
        }
    }

    # An interactive pwsh in a pseudo-terminal, as in a terminal window. The
    # driver types the wrapper's command, presses Ctrl+C once Sub B is held,
    # waits for the prompt, then types the session lines. Ctrl+C there goes to
    # the whole foreground process group, so the stream workers stop too.
    $script:Python = Get-Command -Name python3 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:PtyDriver = Join-Path $script:TestBase 'pty-driver.py'
    Set-Content -LiteralPath $script:PtyDriver -Encoding utf8 -Value @'
import fcntl, glob, os, pty, re, select, signal, struct, sys, termios, time
home, pwsh, line = sys.argv[1], sys.argv[2], sys.argv[3]
rest = sys.argv[4:]
pid, fd = pty.fork()
if pid == 0:
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.environ['TERM'] = 'dumb'
    os.execv(pwsh, [pwsh, '-NoProfile', '-NoLogo'])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 500, 0, 0))
buf = b''
def pump(seconds, until=None):
    global buf
    end = time.time() + seconds
    while time.time() < end:
        if until is not None and until():
            return True
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                return False
            if not d:
                return False
            buf += d
            if b'\x1b[6n' in d:
                os.write(fd, b'\x1b[1;1R')
    return until is None
def text():
    return re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', buf.decode('utf-8', 'replace')).replace('\r', '')
pump(60, lambda: 'PS ' in text())
os.write(fd, (line + '\r').encode())
held = lambda: glob.glob(os.path.join(home, 'collecting-sub-b-*')) and glob.glob(os.path.join(home, 'collected-sub-a-*'))
pump(120, held)
pump(1)
os.write(fd, b'\x03')
interrupted = lambda: 'Interrupted (Ctrl+C)' in text() and 'PS ' in text()[text().index('Interrupted (Ctrl+C)'):]
pump(150, interrupted)
for typed in rest:
    mark = len(text())
    os.write(fd, (typed + '\r').encode())
    pump(10, lambda: 'PS ' in text()[mark:] or not os.path.exists('/proc/%d' % pid))
code = None
end = time.time() + 15
while time.time() < end:
    pump(0.5)
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        code = os.waitstatus_to_exitcode(status)
        break
if code is None:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
sys.stdout.write(text())
sys.stdout.write('\nPTY-EXIT %s\n' % code)
'@
    function script:Wait-Run
    {
        param([Parameter(Mandatory = $true)]$Started, [int]$TimeoutSeconds = 180)
        if (-not $Started.Process.WaitForExit($TimeoutSeconds * 1000))
        {
            $Started.Process.Kill($true)
            throw ('The run did not end within {0} seconds. Output: {1}' -f $TimeoutSeconds, ([string]$Started.Out.Result -replace '\s+', ' '))
        }
        $Started.Process.WaitForExit()
        $Text = @(([string]$Started.Out.Result -replace "`e\[[0-9;?]*[A-Za-z]", '') -split "`r?`n")
        return [pscustomobject]@{ ExitCode = $Started.Process.ExitCode; Text = $Text; Error = [string]$Started.Err.Result }
    }
    function script:Invoke-Wrapper
    {
        param([int]$Streams, [switch]$Resume)
        script:Wait-Run -Started (script:Start-Wrapper -Streams $Streams -Resume:$Resume)
    }

    # The stand-in's records of the subscriptions it was called for, and of
    # the ones it finished.
    function script:Get-Called { param([string]$Prefix) @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter ($Prefix + '-*') -ErrorAction SilentlyContinue | ForEach-Object { $_.Name -replace '^[a-z]+-(sub-[a-z])-.*$', '$1' } | Sort-Object) }
    function script:Clear-Called { Get-ChildItem -LiteralPath $script:CaseHome -File | Where-Object { $_.Name -like 'collecting-*' -or $_.Name -like 'collected-*' } | Remove-Item -Force }

    # Waits until the stand-in is holding Sub B and Sub A is collected.
    function script:Wait-Held
    {
        param([Parameter(Mandatory = $true)]$Started, [int]$TimeoutSeconds = 120)
        $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $Deadline -and -not $Started.Process.HasExited)
        {
            if ((script:Get-Called -Prefix 'collecting') -contains 'sub-b' -and (script:Get-Called -Prefix 'collected') -contains 'sub-a') { Start-Sleep -Seconds 1; return }
            Start-Sleep -Milliseconds 200
        }
        if (-not $Started.Process.HasExited) { $Started.Process.Kill($true) }
        $null = $Started.Process.WaitForExit(10000)
        throw ('Sub B was not held with Sub A collected within {0} seconds. Output: {1} Error: {2}' -f $TimeoutSeconds, ([string]$Started.Out.Result -replace '\s+', ' '), ([string]$Started.Err.Result -replace '\s+', ' '))
    }

    function script:Get-InterruptedLine { param([string[]]$Text) @($Text | Where-Object { $_ -like ($script:Line + '*') }) }
    function script:Format-InterruptedLine
    {
        'Interrupted (Ctrl+C) before all subscriptions were processed. The resume state is kept in {0}; to continue, run the same command again with -Resume.' -f $script:Root
    }

    # The next two runs after an interrupt: -Resume collects only Sub B and
    # ends clean; the run after it, without -Resume, collects both and ends
    # clean, and neither prints the line.
    function script:Assert-NextTwoRuns
    {
        param([int]$Streams)
        script:Clear-Called
        $Next = script:Invoke-Wrapper -Streams $Streams -Resume
        $Next.ExitCode | Should -Be 0 -Because ('the -Resume run after the interrupt: {0}' -f ($Next.Text -join ' | '))
        script:Get-Called -Prefix 'collected' | Should -Be @('sub-b') -Because 'the resume state of the interrupted run was kept: Sub A is not collected again'
        @(script:Get-InterruptedLine -Text $Next.Text).Count | Should -Be 0
        script:Clear-Called
        $After = script:Invoke-Wrapper -Streams $Streams
        $After.ExitCode | Should -Be 0 -Because ('the run after it: {0}' -f ($After.Text -join ' | '))
        script:Get-Called -Prefix 'collected' | Should -Be @('sub-a', 'sub-b')
        @(script:Get-InterruptedLine -Text $After.Text).Count | Should -Be 0
    }

    function script:Stop-Started
    {
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

Describe 'A run stopped by Ctrl+C before every subscription was processed' -Skip:$IsWindows {
    BeforeEach {
        script:New-Case
        if (-not $script:Perl -and $script:SigIntIgnored) { Set-ItResult -Skipped -Because 'this test process ignores Ctrl+C (SIGINT), so the run it starts would too, and perl is not there to set it back' }
    }
    AfterEach { script:Stop-Started }

    # The line, no end of collection, no snapshot and no run lock left.
    BeforeAll {
        function script:Assert-Interrupted
        {
            param([string[]]$Text, [string]$Because)
            script:Get-InterruptedLine -Text $Text | Should -Be @(script:Format-InterruptedLine) -Because ('{0}. Output: {1}' -f $Because, ($Text -join ' | '))
            @($Text | Where-Object { $_ -like 'All subscriptions processed!*' }).Count | Should -Be 0 -Because 'the run stopped before the end of collection'
            @(Get-ChildItem -LiteralPath $script:Root -File -Force -Filter '.rda-stream-azcontext-*' -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'the cleanup still runs first'
            @(Get-ChildItem -LiteralPath $script:Root -File -Force -Filter '.run-lock-*' -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'the run lock is released'
        }
    }

    It 'pwsh -File: exits 130 with one line, <Label>, and the next -Resume run collects only the rest' -TestCases @(
        @{ Label = 'sequential (-ParallelStreams 1)'; Streams = 1 },
        @{ Label = 'with 2 streams'; Streams = 2 }
    ) {
        param($Label, $Streams)
        $Run = script:Start-Wrapper -Streams $Streams -Hold 'sub-b'
        script:Wait-Held -Started $Run
        & kill -s INT $Run.Process.Id
        $Result = script:Wait-Run -Started $Run -TimeoutSeconds 120
        Write-Host ('RESULT -File, {0} stream(s): exit {1}, session open: n/a' -f $Streams, $Result.ExitCode)
        $Result.ExitCode | Should -Be 130 -Because ('a Ctrl+C while Sub B was collected. Output: {0}' -f ($Result.Text -join ' | '))
        script:Assert-Interrupted -Text $Result.Text -Because 'pwsh -File'
        script:Assert-NextTwoRuns -Streams $Streams
    }

    It 'a second Ctrl+C, on a -Resume run with 2 streams, keeps what that run collected: the next -Resume collects only the rest' {
        # Six subscriptions, 3 per stream. Run 1 is stopped once Sub A and Sub B
        # are collected (Sub C and Sub D held); run 2 (-Resume) once Sub C and
        # Sub D are collected (Sub E and Sub F held).
        [pscustomobject]@{
            Tenant        = $script:Tenant
            Subscriptions = @(@('a', 'b', 'c', 'd', 'e', 'f') | ForEach-Object { [pscustomobject]@{ Id = "sub-$_"; Name = ('Sub ' + $_.ToUpper()) } })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
        $WaitFor = {
            param($Started, [string[]]$Collected, [string[]]$Collecting)
            $Deadline = (Get-Date).AddSeconds(150)
            while ((Get-Date) -lt $Deadline -and -not $Started.Process.HasExited)
            {
                $Done = @(script:Get-Called -Prefix 'collected'); $Busy = @(script:Get-Called -Prefix 'collecting')
                if (@($Collected | Where-Object { $Done -notcontains $_ }).Count -eq 0 -and @($Collecting | Where-Object { $Busy -notcontains $_ }).Count -eq 0) { Start-Sleep -Seconds 2; return $true }
                Start-Sleep -Milliseconds 300
            }
            return $false
        }
        $Run1 = script:Start-Wrapper -Streams 2 -Hold 'sub-c,sub-d'
        & $WaitFor $Run1 @('sub-a', 'sub-b') @('sub-c', 'sub-d') | Should -BeTrue
        & kill -s INT $Run1.Process.Id
        $First = script:Wait-Run -Started $Run1 -TimeoutSeconds 200
        $First.ExitCode | Should -Be 130 -Because ($First.Text -join ' | ')
        script:Clear-Called

        $Run2 = script:Start-Wrapper -Streams 2 -Hold 'sub-e,sub-f' -Resume
        & $WaitFor $Run2 @('sub-c', 'sub-d') @('sub-e', 'sub-f') | Should -BeTrue
        & kill -s INT $Run2.Process.Id
        $Second = script:Wait-Run -Started $Run2 -TimeoutSeconds 200
        Write-Host ('RESULT second Ctrl+C, -Resume, 2 stream(s): exit {0}; state files left: {1}' -f $Second.ExitCode, (@(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter '.resume-state-*' | ForEach-Object { $_.Name -replace [regex]::Escape($script:Tenant), 'T' }) -join ', '))
        $Second.ExitCode | Should -Be 130 -Because ($Second.Text -join ' | ')
        script:Assert-Interrupted -Text $Second.Text -Because 'the second Ctrl+C'
        script:Clear-Called

        # The next two runs: -Resume collects only Sub E and Sub F; the run
        # after it, without -Resume, collects all six.
        $Third = script:Invoke-Wrapper -Streams 2 -Resume
        $Collected = @(script:Get-Called -Prefix 'collected')
        Write-Host ('RESULT the next -Resume: exit {0}; collected {1}' -f $Third.ExitCode, ($Collected -join ','))
        $Third.ExitCode | Should -Be 0 -Because ($Third.Text -join ' | ')
        $Collected | Should -Be @('sub-e', 'sub-f') -Because 'what the interrupted -Resume run collected is kept'
        script:Clear-Called
        $Fourth = script:Invoke-Wrapper -Streams 2
        $Fourth.ExitCode | Should -Be 0 -Because ($Fourth.Text -join ' | ')
        @(script:Get-Called -Prefix 'collected').Count | Should -Be 6
        Write-Host ('RESULT the run after it: exit {0}; collected {1}' -f $Fourth.ExitCode, @(script:Get-Called -Prefix 'collected').Count)
    }

    It 'pwsh -NoExit -File: goes back to the prompt, which reads $LASTEXITCODE 130 and stays open, <Label>' -TestCases @(
        @{ Label = 'sequential (-ParallelStreams 1)'; Streams = 1 },
        @{ Label = 'with 2 streams'; Streams = 2 }
    ) {
        param($Label, $Streams)
        $Run = script:Start-Run -Hold 'sub-b' -Session -Command (@($script:Pwsh, '-NoLogo', '-NoProfile', '-NoExit', '-File', $script:Wrapper) + (script:Get-WrapperArgs -Streams $Streams))
        foreach ($Line in $script:SessionLines) { $Run.Process.StandardInput.WriteLine($Line) }
        $Run.Process.StandardInput.Flush()
        script:Wait-Held -Started $Run
        & kill -s INT $Run.Process.Id
        $Ended = $Run.Process.WaitForExit(120000)
        $Run.Process.StandardInput.Close()
        $Result = script:Wait-Run -Started $Run -TimeoutSeconds 30
        $Session = script:Get-SessionResult -Text $Result.Text
        Write-Host ('RESULT -NoExit -File, {0} stream(s): {1}, session open: {2}, process exit {3}' -f $Streams, ($Session.After -join ' '), $Session.Open, $Result.ExitCode)
        $Ended | Should -BeTrue
        script:Assert-Interrupted -Text $Result.Text -Because 'pwsh -NoExit -File'
        $Session.After | Should -Be @('after: 130') -Because 'the prompt reads the code of the interrupted run'
        $Session.Open | Should -BeTrue -Because 'the wrapper does not end the session'
        $Result.ExitCode | Should -Be 0 -Because 'the session ends with its own exit 0'
        script:Assert-NextTwoRuns -Streams $Streams
    }

    It 'inside a PowerShell session: returns to it, which reads $LASTEXITCODE 130 and goes on, <Label>' -TestCases @(
        @{ Label = 'sequential (-ParallelStreams 1)'; Streams = 1 },
        @{ Label = 'with 2 streams'; Streams = 2 }
    ) {
        param($Label, $Streams)
        # pwsh -Command - reads its commands from stdin, one line at a time,
        # as a session does: the Ctrl+C stops the wrapper's line only, and the
        # next lines then run in the same session.
        $Run = script:Start-Run -Hold 'sub-b' -Session -Command @($script:Pwsh, '-NoLogo', '-NoProfile', '-Command', '-')
        $Run.Process.StandardInput.WriteLine(("& '{0}' -TenantID '{1}' -ParallelStreams {2} -SkipMetrics -SkipConsumption" -f ($script:Wrapper -replace "'", "''"), $script:Tenant, $Streams))
        foreach ($Line in $script:SessionLines) { $Run.Process.StandardInput.WriteLine($Line) }
        $Run.Process.StandardInput.Flush()
        script:Wait-Held -Started $Run
        & kill -s INT $Run.Process.Id
        $Ended = $Run.Process.WaitForExit(120000)
        $Run.Process.StandardInput.Close()
        $Result = script:Wait-Run -Started $Run -TimeoutSeconds 30
        $Session = script:Get-SessionResult -Text $Result.Text
        Write-Host ('RESULT session (-Command -), {0} stream(s): {1}, session open: {2}, process exit {3}' -f $Streams, ($Session.After -join ' '), $Session.Open, $Result.ExitCode)
        $Ended | Should -BeTrue
        script:Assert-Interrupted -Text $Result.Text -Because 'inside a session'
        $Session.After | Should -Be @('after: 130') -Because 'the session reads the code of the interrupted run'
        $Session.Open | Should -BeTrue -Because 'the wrapper does not end the session'
        $Result.ExitCode | Should -Be 0 -Because 'the session ends with its own exit 0'
        script:Assert-NextTwoRuns -Streams $Streams
    }

    It 'inside a PowerShell session: the -Resume the line advises, typed into the same session, collects the rest and ends 0, <Label>' -TestCases @(
        @{ Label = 'sequential (-ParallelStreams 1)'; Streams = 1 },
        @{ Label = 'with 2 streams'; Streams = 2 }
    ) {
        param($Label, $Streams)
        # The interrupt leaves $LASTEXITCODE 130 in the session; each
        # subscription's inventory run starts with it cleared, so the next run
        # in the same session does not read it as that subscription's failure.
        $Run = script:Start-Run -Hold 'sub-b' -Session -Command @($script:Pwsh, '-NoLogo', '-NoProfile', '-Command', '-')
        $Line = "& '{0}' -TenantID '{1}' -ParallelStreams {2} -SkipMetrics -SkipConsumption" -f ($script:Wrapper -replace "'", "''"), $script:Tenant, $Streams
        foreach ($Typed in @($Line, '"after1: $LASTEXITCODE"', '$env:RDA_STANDIN_HOLD = ""', ($Line + ' -Resume'), '"after2: $LASTEXITCODE"', ($Line + ' -Resume'), '"after3: $LASTEXITCODE"', 'exit 0'))
        {
            $Run.Process.StandardInput.WriteLine($Typed)
        }
        $Run.Process.StandardInput.Flush()
        script:Wait-Held -Started $Run
        & kill -s INT $Run.Process.Id
        $Ended = $Run.Process.WaitForExit(300000)
        $Run.Process.StandardInput.Close()
        $Result = script:Wait-Run -Started $Run -TimeoutSeconds 30
        $After = @($Result.Text | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^after\d: ' })
        Write-Host ('RESULT in-session -Resume, {0} stream(s): {1}; collected {2}; process exit {3}' -f $Streams, ($After -join ', '), ((script:Get-Called -Prefix 'collected') -join ','), $Result.ExitCode)
        $Ended | Should -BeTrue
        $After | Should -Be @('after1: 130', 'after2: 0', 'after3: 0') -Because ('Output: {0}' -f ($Result.Text -join ' | '))
        @($Result.Text | Where-Object { $_ -match 'Script exited with code' }).Count | Should -Be 0 -Because 'no subscription is failed for the code the interrupt left'
        script:Get-Called -Prefix 'collected' | Should -Be @('sub-a', 'sub-a', 'sub-b', 'sub-b') -Because 'the first -Resume collects Sub B only; the second, after a clean run, collects both'
        $Result.ExitCode | Should -Be 0
    }

    It 'inside a PowerShell session: after the interrupted run, a clean -Fresh run with 2 streams reads $LASTEXITCODE 0' {
        # -Fresh collects both subscriptions through the streams, so no
        # inventory runs in the session and only the wrapper's own exit sets
        # the code the interrupt left at 130.
        $Run = script:Start-Run -Hold 'sub-b' -Session -Command @($script:Pwsh, '-NoLogo', '-NoProfile', '-Command', '-')
        $Line = "& '{0}' -TenantID '{1}' -ParallelStreams 2 -SkipMetrics -SkipConsumption" -f ($script:Wrapper -replace "'", "''"), $script:Tenant
        foreach ($Typed in @($Line, '"after1: $LASTEXITCODE"', '$env:RDA_STANDIN_HOLD = ""', ($Line + ' -Fresh'), '"after2: $LASTEXITCODE"', '"session still open"', 'exit 0'))
        {
            $Run.Process.StandardInput.WriteLine($Typed)
        }
        $Run.Process.StandardInput.Flush()
        script:Wait-Held -Started $Run
        & kill -s INT $Run.Process.Id
        $Ended = $Run.Process.WaitForExit(300000)
        $Run.Process.StandardInput.Close()
        $Result = script:Wait-Run -Started $Run -TimeoutSeconds 30
        $After = @($Result.Text | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^after\d: ' })
        Write-Host ('RESULT in-session -Fresh, 2 streams: {0}; collected {1}; process exit {2}' -f ($After -join ', '), ((script:Get-Called -Prefix 'collected') -join ','), $Result.ExitCode)
        $Ended | Should -BeTrue
        $After | Should -Be @('after1: 130', 'after2: 0') -Because ('Output: {0}' -f ($Result.Text -join ' | '))
        script:Get-Called -Prefix 'collected' | Should -Be @('sub-a', 'sub-a', 'sub-b') -Because 'the -Fresh run collects both'
        @($Result.Text | Where-Object { $_.Trim() -eq 'session still open' }).Count | Should -Be 1
        $Result.ExitCode | Should -Be 0
    }

    It 'pwsh -Command: exits 1, PowerShell''s own code for a stopped command, not 0, with the line, <Label>' -TestCases @(
        @{ Label = 'sequential (-ParallelStreams 1)'; Streams = 1 },
        @{ Label = 'with 2 streams'; Streams = 2 }
    ) {
        param($Label, $Streams)
        # The wrapper does not set the process's code here: -Command can be
        # followed by a session, which that would close.
        $Command = "& '{0}' -TenantID '{1}' -ParallelStreams {2} -SkipMetrics -SkipConsumption" -f ($script:Wrapper -replace "'", "''"), $script:Tenant, $Streams
        $Run = script:Start-Run -Hold 'sub-b' -Command @($script:Pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $Command)
        script:Wait-Held -Started $Run
        & kill -s INT $Run.Process.Id
        $Result = script:Wait-Run -Started $Run -TimeoutSeconds 120
        Write-Host ('RESULT -Command, {0} stream(s): exit {1}, session open: n/a' -f $Streams, $Result.ExitCode)
        $Result.ExitCode | Should -Be 1 -Because ('Output: {0}' -f ($Result.Text -join ' | '))
        script:Assert-Interrupted -Text $Result.Text -Because 'pwsh -Command'
        script:Assert-NextTwoRuns -Streams $Streams
    }

    It 'in an interactive pwsh in a terminal, with the Ctrl+C key: back at the prompt, which reads $LASTEXITCODE 130 and stays open, <Label>' -TestCases @(
        @{ Label = 'sequential (-ParallelStreams 1)'; Streams = 1 },
        @{ Label = 'with 2 streams'; Streams = 2 }
    ) {
        param($Label, $Streams)
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'python3, which provides the pseudo-terminal, is not installed'; return }
        $Command = "& '{0}' -TenantID '{1}' -ParallelStreams {2} -SkipMetrics -SkipConsumption" -f ($script:Wrapper -replace "'", "''"), $script:Tenant, $Streams
        $Driver = script:Start-Run -Hold 'sub-b' -Command (@($script:Python.Source, $script:PtyDriver, $script:CaseHome, $script:Pwsh, $Command) + $script:SessionLines)
        $Result = script:Wait-Run -Started $Driver -TimeoutSeconds 360
        $Text = @($Result.Text | ForEach-Object { $_.TrimEnd() })
        $Exit = @($Text | Where-Object { $_ -like 'PTY-EXIT *' } | ForEach-Object { $_ -replace '^PTY-EXIT ', '' })
        $Session = script:Get-SessionResult -Text $Text
        Write-Host ('RESULT terminal (pty), {0} stream(s): {1}, session open: {2}, process exit {3}' -f $Streams, ($Session.After -join ' '), $Session.Open, ($Exit -join ' '))
        # The terminal echoes the key as ^C and pads lines with spaces.
        script:Assert-Interrupted -Text @($Text | ForEach-Object { $_ -replace '^\s*(\^C)?\s*', '' }) -Because 'an interactive pwsh in a terminal'
        $Session.After | Should -Be @('after: 130') -Because 'the prompt reads the code of the interrupted run'
        $Session.Open | Should -BeTrue -Because 'the wrapper does not end the session'
        $Exit | Should -Be @('0') -Because 'the session ends with its own exit 0'
        script:Assert-NextTwoRuns -Streams $Streams
    }
}

Describe 'Which launches may set the exit code of the pwsh process' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
        $script:Script = [System.IO.Path]::GetFullPath((Join-Path $script:TestBase 'tool/Run-AllSubscriptions.ps1'))
    }

    It 'only the startup script of a process started without -NoExit (<Case>)' -TestCases @(
        @{ Case = '-File'; Startup = $true; Arguments = @('pwsh', '-NoLogo', '-NoProfile', '-File', '<script>', '-TenantID', 't'); Expected = $true },
        @{ Case = '-f'; Startup = $true; Arguments = @('pwsh', '-f', '<script>'); Expected = $true },
        @{ Case = 'the script as the first value'; Startup = $true; Arguments = @('pwsh', '<script>', '-TenantID', 't'); Expected = $true },
        @{ Case = 'a script argument that starts with noe'; Startup = $true; Arguments = @('pwsh', '-File', '<script>', '-TenantID', '-noexit'); Expected = $true },
        @{ Case = 'not the startup script'; Startup = $false; Arguments = @('pwsh', '-File', '<script>'); Expected = $false },
        @{ Case = '-NoExit'; Startup = $true; Arguments = @('pwsh', '-NoExit', '-File', '<script>'); Expected = $false },
        @{ Case = '-noe'; Startup = $true; Arguments = @('pwsh', '-noe', '-File', '<script>'); Expected = $false },
        @{ Case = '-NOEX'; Startup = $true; Arguments = @('pwsh', '-NOEX', '-File', '<script>'); Expected = $false },
        @{ Case = '--noexit'; Startup = $true; Arguments = @('pwsh', '--noexit', '-File', '<script>'); Expected = $false },
        @{ Case = '/NoExit'; Startup = $true; Arguments = @('pwsh', '/NoExit', '-File', '<script>'); Expected = $false },
        @{ Case = 'an en dash'; Startup = $true; Arguments = @('pwsh', ([string][char]0x2013 + 'noexit'), '-File', '<script>'); Expected = $false },
        @{ Case = 'the script path as a path relative to the current folder'; Startup = $true; Arguments = @('pwsh', '-File', '<relative>'); Expected = $true },
        @{ Case = 'the script path not among the arguments'; Startup = $true; Arguments = @('pwsh', '-File', 'elsewhere.ps1', '-TenantID', 't'); Expected = $false },
        @{ Case = 'no script path found, a later value that starts with noe'; Startup = $true; Arguments = @('pwsh', '-File', 'elsewhere.ps1', 'noexample'); Expected = $false },
        @{ Case = 'Start-Job -FilePath (no script path, as measured)'; Startup = $true; Arguments = @('/opt/microsoft/powershell/7/pwsh.dll', '-s', '-NoLogo', '-NoProfile', '-wd', '/tmp'); NoPath = $true; Expected = $false },
        @{ Case = 'an empty script path'; Startup = $true; Arguments = @('pwsh', '-File', '<script>'); NoPath = $true; Expected = $false },
        @{ Case = 'one argument only'; Startup = $true; Arguments = @('pwsh'); Expected = $false },
        @{ Case = 'no arguments'; Startup = $true; Arguments = $null; Expected = $false }
    ) {
        param($Case, $Startup, $Arguments, $Expected, [switch]$NoPath)
        $Relative = [System.IO.Path]::GetRelativePath([Environment]::CurrentDirectory, $script:Script)
        $Given = if ($null -eq $Arguments) { $null } else { @($Arguments | ForEach-Object { if ($_ -eq '<script>') { $script:Script } elseif ($_ -eq '<relative>') { $Relative } else { $_ } }) }
        $Path = if ($NoPath) { '' } else { $script:Script }
        Test-WrapperOwnsProcessExit -IsStartupScript $Startup -ScriptPath $Path -ProcessArguments $Given | Should -Be $Expected
    }

    It 'gives $false in a Start-Job -FilePath job, read in the job itself' {
        $Probe = Join-Path $script:TestBase 'owns-exit-probe.ps1'
        Set-Content -LiteralPath $Probe -Encoding utf8 -Value @'
param([string]$Functions)
. $Functions
Test-WrapperOwnsProcessExit -IsStartupScript (@(Get-PSCallStack).Count -eq 1) -ScriptPath $PSCommandPath -ProcessArguments ([Environment]::GetCommandLineArgs())
'@
        $Answer = Start-Job -FilePath $Probe -ArgumentList (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1') | Receive-Job -Wait -AutoRemoveJob
        @($Answer) | Should -Be @($false)
    }
}
