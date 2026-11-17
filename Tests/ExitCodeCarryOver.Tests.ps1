# =============================================================================
# ExitCodeCarryOver.Tests.ps1
#
# Offline tests that Run-AllSubscriptions.ps1 reports a subscription as failed
# only when ResourceInventory.ps1 failed for that subscription.
#
# WHY THIS TEST EXISTS
# --------------------
# The wrapper's sequential loop, its one-subscription path and the stream
# worker call ResourceInventory.ps1 with `&` and treat a non-zero
# $LASTEXITCODE afterwards as a failed subscription. The script ends with
# `exit 1` when it stops, and with no `exit` at all when it succeeds, which
# leaves $LASTEXITCODE as it was. With no native command in the run to reset
# it, the `exit 1` of one subscription marked every later subscription of the
# same loop or stream as failed with "Script exited with code 1", even though
# its report was written; a native command that failed in the session before
# the wrapper started did the same to every subscription.
#
# A clean run also has to set the code itself: inside a PowerShell session a
# run with two or more streams calls no inventory in the session, so without
# its own `exit 0` the session read the code it held before the run.
#
# HOW
# ---
# The tool is copied to a temp dir and the REAL Run-AllSubscriptions.ps1 runs
# as its own pwsh process (stdin closed), calling the REAL
# Run-AllSubscriptions.Stream.ps1 and ResourceInventory.ps1. Azure is a set of
# stand-in Az modules found first on PSModulePath; no az command is used. The
# stand-in Az.Compute does not load when the ResourceInventory.ps1 importing it
# was started for the failing subscription, so for that subscription the real
# script takes its "module present on disk but failed to load" path and ends
# with exit 1; the next subscription loads it. The run's home is a scratch
# folder, so the run writes its inventory root under it. On Windows the
# wrapper writes to C:\InventoryReports instead, so these tests do not run
# there. Placeholder ids only. No live Azure.
#
# The same runs check the Eligible and Processed counts of the summary and of
# RunSummary.log: under pwsh -File the wrapper's $Subscriptions is the global
# one, which ResourceInventory.ps1 replaces with every subscription of the tenant.
#
# Run with: Invoke-Pester ./Tests/ExitCodeCarryOver.Tests.ps1 -Output Detailed
# =============================================================================

Describe 'Run-AllSubscriptions.ps1 reports only the subscriptions that failed' -Skip:$IsWindows {
    BeforeAll {
        $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ExitCodeCarryOver_' + [guid]::NewGuid().ToString('N'))
        $script:Tenant = '12345678-1234-1234-1234-123456789012'
        # The state files are named by the tenant's key: the first 12 hex characters of its SHA-256 (Get-TenantFileKey).
        $script:TenantKey = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($script:Tenant.Trim().ToLowerInvariant()))).Substring(0, 12).ToLowerInvariant()
        # ResourceInventory.ps1 takes only a GUID as -SubscriptionID. The stand-in
        # ids are built here from 32 hex digits, so the file holds no id but the
        # documentation placeholder.
        $script:SubA = [pscustomobject]@{ Id = [guid]::new(('0' * 31) + 'a').ToString(); Name = 'Sub A' }
        $script:SubB = [pscustomobject]@{ Id = [guid]::new(('0' * 31) + 'b').ToString(); Name = 'Sub B' }
        $script:SubC = [pscustomobject]@{ Id = [guid]::new(('0' * 31) + 'c').ToString(); Name = 'Sub C' }

        $script:Tool = Join-Path $script:WorkDir 'tool'
        New-Item -ItemType Directory -Path $script:Tool -Force | Out-Null
        foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
        {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:Tool -Recurse -Force
        }
        $script:Wrapper = Join-Path $script:Tool 'Run-AllSubscriptions.ps1'

        # Az.Accounts answers the sign-in, context, token and subscription
        # calls, the role checks, the per-subscription resource count and
        # Resource Graph discovery (one public IP per subscription).
        $Accounts = @'
# Every process that runs the tool loads this stand-in first (the wrapper and
# each stream), so it skips ResourceInventory.ps1's online version check there,
# as Tests/SetupStop.Tests.ps1 does in its harness. The platform is set because
# the same flag also skips the environment check that sets it.
$Global:RdaSessionInitialized = $true
$Global:PlatformOS = 'PowerShell Unix'
function Get-RdaStandInScenario { Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json }
function Get-RdaStandInContext
{
    [pscustomobject]@{
        Account      = [pscustomobject]@{ Id = 'operator@example.com'; Type = 'User' }
        Tenant       = [pscustomobject]@{ Id = (Get-RdaStandInScenario).Tenant }
        Subscription = [pscustomobject]@{ Id = $script:ContextSub; Name = 'stand-in' }
        Environment  = [pscustomobject]@{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/' }
    }
}
$script:ContextSub = $null
# With RemoveRoot, the wrapper's own transcript cannot start (a running one
# would make the folder again on its next line), and the inventory root is
# removed when the wrapper reads the zip a subscription's inner script named,
# right after that script returned with success: as when storage is evicted
# or a mount drops at that point.
if ((Get-RdaStandInScenario).RemoveRoot -and -not $Global:RdaStandInRootBreakpoint)
{
    $Global:RdaStandInRootBreakpoint = $true
    $null = Set-PSBreakpoint -Variable ZipOutputFile -Mode Read -Action {
        $Reader = @(Get-PSCallStack)[1]
        $Root = Join-Path $HOME 'InventoryReports'
        if ($Reader.ScriptName -like '*Run-AllSubscriptions.ps1' -and (Test-Path -LiteralPath $Root))
        {
            Remove-Item -LiteralPath $Root -Recurse -Force
        }
    }
}
# With NarrationFail, the wrapper's "Resources collected" line cannot be
# written (as when the transcript's folder is gone), after its subscription
# worked.
if ((Get-RdaStandInScenario).NarrationFail)
{
    function Write-Host
    {
        if (([string]$args[0]) -like 'Resources collected:*' -and @(Get-PSCallStack)[1].ScriptName -like '*Run-AllSubscriptions.ps1')
        {
            $script:NarrationBroken = $true
            # Recorded, so a test knows the line was attempted (a 0-resource run never writes it).
            Add-Content -LiteralPath (Join-Path $env:HOME 'narration-refused.txt') -Value ([string]$args[0])
            throw 'stand-in: the transcript cannot be written'
        }
        Microsoft.PowerShell.Utility\Write-Host @args
    }
    # With VerboseFail as well (a run with -Verbose), the wrapper's next
    # verbose line after that failed write cannot be written either.
    if ((Get-RdaStandInScenario).VerboseFail)
    {
        function Write-Verbose
        {
            [CmdletBinding()] param([Parameter(Position = 0, ValueFromPipeline = $true)][string]$Message)
            if ($script:NarrationBroken -and @(Get-PSCallStack)[1].ScriptName -like '*Run-AllSubscriptions.ps1')
            {
                $script:NarrationBroken = $false
                throw 'stand-in: the transcript cannot be written (verbose)'
            }
            Microsoft.PowerShell.Utility\Write-Verbose -Message $Message
        }
    }
}
# With ResumeRemoveFail, the wrapper cannot remove the resume state file at
# the end of a clean run, with an error whose text holds braces. With
# ResumeRemoveSoftFail, the removal fails as Remove-Item itself fails on a
# locked file: with a non-terminating error, which a catch sees only when the
# call asks for -ErrorAction Stop.
if ((Get-RdaStandInScenario).ResumeRemoveFail -or (Get-RdaStandInScenario).ResumeRemoveSoftFail)
{
    function Remove-Item
    {
        [CmdletBinding()] param([Parameter(Position = 0)]$Path, $LiteralPath, [switch]$Force, [switch]$Recurse)
        # The wrapper names the file by -LiteralPath (or by -Path).
        $Target = if ($PSBoundParameters.ContainsKey('LiteralPath')) { [string]$LiteralPath } else { [string]$Path }
        # The clean-run removal is #38's Remove-ResumeStateFiles (the
        # functions file), or the wrapper itself.
        $Caller = @(Get-PSCallStack)[1]
        if ($Target -like '*.resume-state-*' -and $Target -notlike '*-stream-*' -and ($Caller.ScriptName -like '*Run-AllSubscriptions.ps1' -or $Caller.FunctionName -eq 'Remove-ResumeStateFiles'))
        {
            if ((Get-RdaStandInScenario).ResumeRemoveSoftFail)
            {
                $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new([System.IO.IOException]::new('stand-in: the file is locked by another process'), 'RemoveFileSystemItemIOError', [System.Management.Automation.ErrorCategory]::WriteError, $Target))
                return
            }
            throw 'stand-in: the file is in use by {another process}'
        }
        Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
    }
}
# With SummaryStateFail, the wrapper cannot write the stream resume state file
# for the records held only in the stream summaries (as on a full disk).
if ((Get-RdaStandInScenario).SummaryStateFail)
{
    function Set-Content
    {
        [CmdletBinding()] param([Parameter(Position = 0)]$Path, $LiteralPath, [Parameter(Position = 1, ValueFromPipeline = $true)][object[]]$Value, $Encoding, [switch]$Force, [switch]$NoNewline)
        begin { $Lines = @() }
        process { $Lines += @($Value) }
        end
        {
            $Target = if ($PSBoundParameters.ContainsKey('LiteralPath')) { [string]$LiteralPath } else { [string]$Path }
            if ($Target -like '*.resume-state-*-stream-summary-*') { throw 'stand-in: no space left on the disk' }
            $Pass = @{} + $PSBoundParameters
            $Pass['Value'] = $Lines
            Microsoft.PowerShell.Management\Set-Content @Pass
        }
    }
}
# With StreamNarrationFail, a stream worker's "done:" line cannot be written
# (as when its output cannot be written), after its subscription worked.
if ((Get-RdaStandInScenario).StreamNarrationFail)
{
    function Write-Host
    {
        if (([string]$args[0]) -match '^\[stream-\d+\] done: ')
        {
            # Recorded, so a test knows the line was attempted (a 0-resource run never writes it).
            # One file per process: two stream workers never write the same file.
            Add-Content -LiteralPath (Join-Path $env:HOME ('narration-refused-{0}.txt' -f $PID)) -Value ([string]$args[0])
            throw 'stand-in: the stream console line cannot be written'
        }
        Microsoft.PowerShell.Utility\Write-Host @args
    }
}
# With FailuresLogFail, the wrapper cannot read the size of stream 0's
# failures log while it reads that stream's summary.
if ((Get-RdaStandInScenario).FailuresLogFail)
{
    function Get-Item
    {
        # The wrapper names the file by -LiteralPath (or by position).
        if (@($args | Where-Object { ([string]$_) -like '*_stream-0.log' }).Count -gt 0 -and @(Get-PSCallStack)[1].ScriptName -like '*Run-AllSubscriptions.ps1') { throw 'stand-in: the stream failures log cannot be read' }
        Microsoft.PowerShell.Management\Get-Item @args
    }
}
# With SummaryFolderAtStart, a folder stands where stream 0's summary file
# goes when the wrapper first looks there to remove an old one (the name holds
# the run's key, so it cannot be made before the run), so the wrapper cannot
# remove it.
if ((Get-RdaStandInScenario).SummaryFolderAtStart -and -not $Global:RdaStandInSummaryBreakpoint)
{
    $Global:RdaStandInSummaryBreakpoint = $true
    $null = Set-PSBreakpoint -Variable OldSummaryPath -Mode Read -Action {
        $Path = [string](Get-Variable -Name OldSummaryPath -ValueOnly -ErrorAction SilentlyContinue)
        if ($Path -like '*.rda-stream-*-0-summary.json') { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    }
}
# With UnifiedStateOnce, the folder at the resume state's temp path makes only
# the first write of the resume state fail (as on a disk that is then fixed):
# once that write has failed, the folder is removed, so later writes work.
if ((Get-RdaStandInScenario).UnifiedStateOnce -and -not $Global:RdaStandInStateBreakpoint)
{
    $Global:RdaStandInStateBreakpoint = $true
    $null = Set-PSBreakpoint -Variable StateError -Mode Write -Action {
        # The action runs in this module's scope, so the path is read from
        # the call that failed.
        $Saver = @(Get-PSCallStack | Where-Object { $_.FunctionName -eq 'Save-CompletedSubscriptionIds' }) | Select-Object -First 1
        $StatePath = if ($null -ne $Saver) { [string]$Saver.InvocationInfo.BoundParameters['Path'] } else { '' }
        if ($StatePath -like '*.resume-state-*' -and $StatePath -notlike '*-stream-*' -and (Test-Path -LiteralPath "$StatePath.tmp" -PathType Container))
        {
            Remove-Item -LiteralPath "$StatePath.tmp" -Recurse -Force
            $Global:RdaStandInStateSaveFailed = $true
        }
    }
    # The start-of-run write of the run's id (Write-StartOfRunId) fails on the
    # folder too, and its clean-up removes the empty folder; it is put back
    # after that write, so the first save of the resume state still fails.
    $null = Set-PSBreakpoint -Variable Back -Mode Write -Action {
        $Writer = @(Get-PSCallStack | Where-Object { $_.FunctionName -eq 'Write-StartOfRunId' }) | Select-Object -First 1
        if ($null -eq $Writer -or $Global:RdaStandInStateSaveFailed) { return }
        $Tmp = [string]$Writer.InvocationInfo.BoundParameters['Path'] + '.tmp'
        if (-not (Test-Path -LiteralPath $Tmp)) { New-Item -ItemType Directory -Path $Tmp -Force | Out-Null }
    }
}
# With CarryStopStateBlocked, a folder with a file in it sits at the resume
# state's temp path from the moment the wrapper works out which skipped
# subscriptions it can carry, so the write that puts them on the retry list
# fails (as on a full disk) and the temp path cannot be cleared.
if ((Get-RdaStandInScenario).CarryStopStateBlocked -and -not $Global:RdaStandInCarryBreakpoint)
{
    $Global:RdaStandInCarryBreakpoint = $true
    $null = Set-PSBreakpoint -Variable ResumeCarry -Mode Write -Action {
        foreach ($StateFile in @(Get-ChildItem -LiteralPath (Join-Path $HOME 'InventoryReports') -Filter '.resume-state-*.json' -File -Force | Where-Object { $_.Name -notlike '*-stream-*' }))
        {
            $Blocked = New-Item -ItemType Directory -Path ($StateFile.FullName + '.tmp') -Force
            Set-Content -LiteralPath (Join-Path $Blocked.FullName 'keep') -Value 'x'
        }
    }
}
# With GoneAfterProbe, the zip GoneSub wrote is removed (as an antivirus product
# does) just after the output check has made its list of expected zips and before
# the zips are picked: the moment between the check's two looks at the folder.
if ((Get-RdaStandInScenario).GoneAfterProbe -and -not $Global:RdaStandInGoneBreakpoint)
{
    $Global:RdaStandInGoneBreakpoint = $true
    $null = Set-PSBreakpoint -Variable VerifyRows -Mode Write -Action {
        $Scenario = Get-RdaStandInScenario
        foreach ($Earlier in @(Get-ChildItem -LiteralPath (Join-Path $HOME 'InventoryReports') -Recurse -Filter '*.zip' -File -ErrorAction SilentlyContinue))
        {
            $EarlierJson = @(Get-ChildItem -LiteralPath $Earlier.DirectoryName -Filter 'Inventory_*.json' -File)
            if ($EarlierJson.Count -gt 0 -and (Get-Content -LiteralPath $EarlierJson[0].FullName -Raw) -like ('*' + [string]$Scenario.GoneSub + '*')) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Earlier.FullName -Force }
        }
    }
}
function Start-Transcript
{
    if ((Get-RdaStandInScenario).RemoveRoot -and @(Get-PSCallStack)[1].ScriptName -like '*Run-AllSubscriptions.ps1') { throw 'stand-in: the transcript cannot start' }
    Microsoft.PowerShell.Host\Start-Transcript @args
}
function Get-AzContext { [CmdletBinding()] param([switch]$ListAvailable) Get-RdaStandInContext }
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context, $Scope) if ($Subscription) { $script:ContextSub = [string]$Subscription }; Get-RdaStandInContext }
# Only a stream worker imports the context. The scenario's Plant entries for
# that stream then set what its summary file holds, once the wrapper has
# started the stream: Text (this text, read-only, so the stream cannot
# replace it), Folder (a folder, so the stream can write no summary, as when
# its job dies before the end), Freeze (a file already there is made
# read-only, else a folder) or OtherRun (another wrapper run with the same
# inventory root, at work at the same time, writes its own stream 0 summary
# and a report zip there).
function Import-AzContext
{
    [CmdletBinding()] param($Path)
    $Worker = @(Get-PSCallStack | Where-Object { $_.ScriptName -like '*Run-AllSubscriptions.Stream.ps1' -and $null -ne $_.InvocationInfo.BoundParameters -and $_.InvocationInfo.BoundParameters.ContainsKey('StreamSummaryPath') }) | Select-Object -First 1
    if ($null -ne $Worker)
    {
        $Bound = $Worker.InvocationInfo.BoundParameters
        # ImportFailStream: that stream cannot import the context, so it
        # does not start.
        if ([string](Get-RdaStandInScenario).ImportFailStream -eq [string]$Bound['StreamId']) { throw 'stand-in: the context snapshot cannot be imported' }
        $SummaryPath = [string]$Bound['StreamSummaryPath']
        foreach ($Plant in @((Get-RdaStandInScenario).Plant | Where-Object { $null -ne $_ -and [string]$_.Stream -eq [string]$Bound['StreamId'] }))
        {
            $Kind = [string]$Plant.Kind
            if ($Kind -eq 'Freeze') { $Kind = if (Test-Path -LiteralPath $SummaryPath -PathType Leaf) { 'Keep' } else { 'Folder' } }
            if ($Kind -eq 'Folder') { New-Item -ItemType Directory -Path $SummaryPath -Force | Out-Null }
            if ($Kind -eq 'Text')
            {
                # {Reports} in the text stands for this run's inventory root,
                # {RunId} for this run's id (the worker is given it).
                $ReportsText = (ConvertTo-Json -InputObject ([string]$Bound['InventoryRoot'])).Trim('"')
                Set-Content -LiteralPath $SummaryPath -Value ([string]$Plant.Text).Replace('{Reports}', $ReportsText).Replace('{RunId}', [string]$Bound['RunId']) -Encoding utf8
            }
            if ($Kind -eq 'OtherRun')
            {
                $Root = [string]$Bound['InventoryRoot']
                $OtherDir = New-Item -ItemType Directory -Path (Join-Path $Root 'ResourcesReport_otherrun') -Force
                Set-Content -LiteralPath (Join-Path $OtherDir.FullName 'ResourcesReport_otherrun.zip') -Value 'another run''s report' -Encoding utf8
                Set-Content -LiteralPath (Join-Path $Root '.rda-stream-0-99999999-0000-0000-0000-000000000000-summary.json') -Value '{"RunId":"99999999-0000-0000-0000-000000000000","StreamId":"0","Status":"ok","ResourceCounts":[],"Failed":[]}' -Encoding utf8
            }
            if ($Kind -eq 'LockedStreamState')
            {
                # Stream 7's resume state file, holding the failures named in
                # Text, written now and made unreadable (mode 000).
                $Locked = Join-Path ([string]$Bound['InventoryRoot']) ('.resume-state-{0}-stream-7.json' -f [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes(([string](Get-RdaStandInScenario).Tenant).Trim().ToLowerInvariant()))).Substring(0, 12).ToLowerInvariant())
                [pscustomobject]@{ Tenant = (Get-RdaStandInScenario).Tenant; StreamId = '7'; Completed = @(); FailedAttempts = @(([string]$Plant.Text -split ',') | ForEach-Object { [pscustomobject]@{ Id = $_; Name = 'earlier'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier failure'; Attempts = 1 } }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Locked -Encoding utf8
                [System.IO.File]::SetUnixFileMode($Locked, [System.IO.UnixFileMode]::None)
            }
            if ($Kind -eq 'Text' -or $Kind -eq 'Keep') { [System.IO.File]::SetUnixFileMode($SummaryPath, [System.IO.UnixFileMode]'UserRead, GroupRead, OtherRead') }
        }
    }
    Get-RdaStandInContext
}
function Save-AzContext
{
    [CmdletBinding()] param($Path, [switch]$Force)
    # With SnapshotPartialFail, the write stops part way (as on a full disk):
    # part of the file is there, and the call throws.
    if ((Get-RdaStandInScenario).SnapshotPartialFail)
    {
        Set-Content -LiteralPath $Path -Value '{"Contexts":' -NoNewline
        throw 'stand-in: the disk is full'
    }
    Set-Content -LiteralPath $Path -Value '{}'
}
# With SnapshotPartialFail, the wrapper also cannot remove that part of the
# context snapshot: Remove-Item fails as it does on a locked file, with a
# non-terminating error, which a catch sees only with -ErrorAction Stop.
if ((Get-RdaStandInScenario).SnapshotPartialFail)
{
    function Remove-Item
    {
        [CmdletBinding()] param([Parameter(Position = 0)]$Path, $LiteralPath, [switch]$Force, [switch]$Recurse)
        $Target = if ($PSBoundParameters.ContainsKey('LiteralPath')) { [string]$LiteralPath } else { [string]$Path }
        # The wrapper removes the snapshots through Remove-AzContextSnapshot (its functions file).
        if ($Target -like '*.rda-stream-azcontext-*' -and @(Get-PSCallStack)[1].ScriptName -like '*RunAllSubscriptions.Functions.ps1')
        {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new([System.IO.IOException]::new('stand-in: the file is locked by another process'), 'RemoveFileSystemItemIOError', [System.Management.Automation.ErrorCategory]::WriteError, $Target))
            return
        }
        Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
    }
}
# With StreamFileStuck, a per-stream resume state file cannot be removed (it is
# locked: Remove-Item fails with a non-terminating error). With
# StreamFileRewriteBlocked it cannot be rewritten either (a folder sits at its
# temp path, set up with the run).
if ((Get-RdaStandInScenario).StreamFileStuck)
{
    function Remove-Item
    {
        [CmdletBinding()] param([Parameter(Position = 0)]$Path, $LiteralPath, [switch]$Force, [switch]$Recurse)
        $Target = if ($PSBoundParameters.ContainsKey('LiteralPath')) { [string]$LiteralPath } else { [string]$Path }
        if ($Target -like '*.resume-state-*-stream-*.json')
        {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new([System.IO.IOException]::new('stand-in: the file is locked by another process'), 'RemoveFileSystemItemIOError', [System.Management.Automation.ErrorCategory]::WriteError, $Target))
            return
        }
        Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
    }
}
function Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function Get-AzContextAutosaveSetting { [CmdletBinding()] param($Scope) [pscustomobject]@{ Mode = 'Process'; ContextFile = 'None'; CacheFile = 'None' } }
function Connect-AzAccount { [CmdletBinding()] param($Tenant, [switch]$UseDeviceAuthentication) throw 'stand-in: no sign-in expected' }
function Get-AzAccessToken
{
    [CmdletBinding()] param($TenantId, $ResourceUrl, [switch]$AsSecureString, $ResourceTypeName)
    # With ConsumptionTokenFail, the token check before the consumption phase
    # gets no token, so that phase is skipped for sign-in (the '(auth)' row).
    if ((Get-RdaStandInScenario).ConsumptionTokenFail -and @(Get-PSCallStack | Where-Object { $_.FunctionName -eq 'Test-DataPlaneAuthReady' }).Count -gt 0) { throw 'stand-in: no token for the consumption phase' }
    # With MetricsTokenFail, the token check before the metrics phase gets no
    # token, so that phase is skipped for sign-in (a row per subscription).
    if ((Get-RdaStandInScenario).MetricsTokenFail -and @(Get-PSCallStack | Where-Object { $_.FunctionName -eq 'Test-DataPlaneAuthReady' -and $null -ne $_.InvocationInfo.BoundParameters -and [string]$_.InvocationInfo.BoundParameters['Phase'] -eq 'Metrics' }).Count -gt 0) { throw 'stand-in: no token for the metrics phase' }
    $Claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"stand-in-caller"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $Tenant = if ($TenantId) { [string]$TenantId } else { (Get-RdaStandInScenario).Tenant }
    [pscustomobject]@{ Token = ('e30.{0}.c2ln' -f $Claims); Type = 'Bearer'; ExpiresOn = (Get-Date).AddHours(1); TenantId = $Tenant }
}
function Get-AzSubscription
{
    [CmdletBinding()] param($TenantId, $SubscriptionId, $SubscriptionName)
    $Scenario = Get-RdaStandInScenario
    @($Scenario.Subscriptions | Where-Object { -not $SubscriptionId -or $_.Id -eq $SubscriptionId } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SubscriptionId = $_.Id; Name = $_.Name; State = $(if ($_.State) { [string]$_.State } else { 'Enabled' }); TenantId = $Scenario.Tenant; HomeTenantId = $Scenario.Tenant } })
}
function Invoke-AzRestMethod
{
    [CmdletBinding()] param([string]$Method = 'GET', [string]$Path, [string]$Payload, [string]$Uri)
    if (-not $Path) { $Path = $Uri }
    $Answer = { param([int]$Status, $Body) [pscustomobject]@{ StatusCode = $Status; Content = (ConvertTo-Json -InputObject $Body -Depth 10 -Compress); Headers = @{} } }
    if ($Path -match '/subscriptions/([^/?]+)/resourcegroups\?') { return & $Answer 200 @{ value = @() } }
    if ($Path -match '/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/roleAssignments\?')
    {
        $Id = $Matches[1]
        return & $Answer 200 @{ value = @(@{ properties = @{ scope = "/subscriptions/$Id"; principalId = 'stand-in-caller'; roleDefinitionId = "/subscriptions/$Id/providers/Microsoft.Authorization/roleDefinitions/stand-in-reader" } }) }
    }
    if ($Path -match '/providers/Microsoft\.Authorization/roleDefinitions/[^/?]+\?') { return & $Answer 200 @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } } }
    if ($Path -match '/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/permissions\?') { return & $Answer 200 @{ value = @(@{ actions = @('*/read'); notActions = @() }) } }
    # The up-front consumption data check reads the usage API by REST: no
    # usage rows, which the role check above lets through as NoUsage.
    if ($Path -match '/subscriptions/([^/?]+)/providers/Microsoft\.Commerce/UsageAggregates\?') { return & $Answer 200 @{ value = @() } }
    if ($Path -like '*Microsoft.ResourceGraph/resources*')
    {
        $Request = $Payload | ConvertFrom-Json
        $Ids = @($Request.subscriptions | ForEach-Object { [string]$_ })
        $Query = [string]$Request.query
        if ($Query -match 'ResourceCount = count\(\) by subscriptionId') { return & $Answer 200 @{ data = @($Ids | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 1 } }) } }
        if ($Query -match 'desktopvirtualizationresources') { return & $Answer 200 @{ data = @(@{ count_ = 0 }) } }
        if ($Query -match 'summarize count\(\)') { return & $Answer 200 @{ data = @(@{ count_ = $Ids.Count }) } }
        if ($Query -match '^\s*resources\b')
        {
            $Rows = @($Ids | ForEach-Object { @{ id = "/subscriptions/$_/resourceGroups/rg-demo/providers/Microsoft.Network/publicIPAddresses/pip-demo"; name = 'pip-demo'; type = 'microsoft.network/publicipaddresses'; location = 'eastus'; subscriptionId = $_; resourceGroup = 'rg-demo'; sku = @{ name = 'Standard' }; properties = @{ publicIPAllocationMethod = 'Static'; publicIPAddressVersion = 'IPv4'; provisioningState = 'Succeeded' } } })
            return & $Answer 200 @{ data = $Rows; count = $Rows.Count; totalRecords = $Rows.Count }
        }
        return & $Answer 200 @{ data = @(); count = 0; totalRecords = 0 }
    }
    return & $Answer 404 @{ error = @{ code = 'NotFound'; message = 'stand-in: no answer for this path' } }
}
'@
        # Throws while it loads when the ResourceInventory.ps1 importing it was
        # started for one of the scenario's failing subscriptions.
        $Compute = @'
$FailSub = @((Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json).FailSub | Where-Object { $_ })
if ($FailSub.Count -gt 0)
{
    foreach ($Frame in @(Get-PSCallStack))
    {
        $Bound = $Frame.InvocationInfo.BoundParameters
        if ($Frame.ScriptName -like '*ResourceInventory.ps1' -and $null -ne $Bound -and $Bound.ContainsKey('SubscriptionID') -and $FailSub -contains [string]$Bound['SubscriptionID'])
        {
            throw 'stand-in: Az.Compute could not load one of its assemblies'
        }
    }
}
'@
        # A collector, in the copy only, that fails for the scenario's
        # CollectorFailSub, so that subscription's run records a collector
        # failure and still writes its report.
        @'
param($Sub, $Resources, $Task, $ResourceIdDictionary)
$CollectorFailSub = (Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json).CollectorFailSub
if ($Task -eq 'Processing' -and $CollectorFailSub -and @($Resources | Where-Object { $_.subscriptionId -eq $CollectorFailSub }).Count -gt 0)
{
    throw 'stand-in: this collector failed'
}
'@ | Set-Content -LiteralPath (Join-Path $script:Tool 'Services/Networking/StandInCollector.ps1') -Encoding utf8

        # A second copy of the tool whose ResourceInventory.ps1 is a stand-in:
        # it writes one subscription's report folder (Inventory json, html and
        # zip) under the home's inventory root by literal path and names the
        # zip, as the real script does. Used for a home whose path holds [ or ],
        # where only the wrapper's own handling of the path is under test.
        $script:ToolStandIn = Join-Path $script:WorkDir 'tool-standin-inventory'
        Copy-Item -LiteralPath $script:Tool -Destination $script:ToolStandIn -Recurse -Force
        @'
param($TenantID, $SubscriptionID)
$StandInScenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
# The scenario's failing subscriptions end with exit 1, as the real script does.
if (@($StandInScenario.FailSub) -contains [string]$SubscriptionID) { exit 1 }
$Root = Join-Path $HOME 'InventoryReports'
# GoneBy: this subscription's run removes the zip an earlier run of GoneSub wrote (as an antivirus product does).
if ([string]$StandInScenario.GoneBy -eq [string]$SubscriptionID)
{
    foreach ($Earlier in @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.zip' -File -ErrorAction SilentlyContinue))
    {
        $EarlierJson = @(Get-ChildItem -LiteralPath $Earlier.DirectoryName -Filter 'Inventory_*.json' -File)
        if ($EarlierJson.Count -gt 0 -and (Get-Content -LiteralPath $EarlierJson[0].FullName -Raw) -like ('*' + [string]$StandInScenario.GoneSub + '*')) { Remove-Item -LiteralPath $Earlier.FullName -Force }
    }
}
$Stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
$Dir = Join-Path $Root ('ResourcesReport_{0}' -f $Stamp)
$null = [System.IO.Directory]::CreateDirectory($Dir)
$Json = Join-Path $Dir ('Inventory_{0}.json' -f $Stamp)
[System.IO.File]::WriteAllText($Json, ('{{"Subscription":"{0}"}}' -f $SubscriptionID))
[System.IO.File]::WriteAllText((Join-Path $Dir ('ResourcesReport_{0}.html' -f $Stamp)), '<!DOCTYPE html><html><body>stand-in report</body></html>')
$Zip = Join-Path $Dir ('ResourcesReport_{0}.zip' -f $Stamp)
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$Archive = [System.IO.Compression.ZipFile]::Open($Zip, [System.IO.Compression.ZipArchiveMode]::Create)
try { $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $Json, [System.IO.Path]::GetFileName($Json)) }
finally { $Archive.Dispose() }
$Global:Resources = @([pscustomobject]@{ id = 'stand-in' })
# The real script keeps the count here: it releases $Global:Resources before the report.
$Global:ResourceCount = 1
$Global:ZipOutputFile = $Zip
'@ | Set-Content -LiteralPath (Join-Path $script:ToolStandIn 'ResourceInventory.ps1') -Encoding utf8

        $script:Modules = Join-Path $script:WorkDir 'modules'
        # Az.Billing answers the wrapper's up-front consumption access check
        # (runs without -SkipConsumption only): access is confirmed.
        # With ConsumptionPageFail, every consumption page a subscription's
        # run asks for fails, so its consumption is INCOMPLETE (one row per
        # subscription in the consumption failure list).
        $Billing = @'
function Get-UsageAggregates
{
    [CmdletBinding()] param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken)
    if ((Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json).ConsumptionPageFail -and @(Get-PSCallStack | Where-Object { $_.ScriptName -like '*ResourceInventory.ps1' }).Count -gt 0) { throw 'stand-in: the consumption page cannot be read' }
}
'@
        foreach ($Module in @(@{ Name = 'Az.Accounts'; Body = $Accounts }, @{ Name = 'Az.Compute'; Body = $Compute }, @{ Name = 'Az.Monitor'; Body = '' }, @{ Name = 'Az.Billing'; Body = $Billing }))
        {
            $Dir = Join-Path $script:Modules (Join-Path $Module.Name '99.0.0')
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psm1')) -Value $Module.Body -Encoding utf8
            Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psd1')) -Value ("@{{ ModuleVersion = '99.0.0'; RootModule = '{0}.psm1'; FunctionsToExport = '*' }}" -f $Module.Name) -Encoding utf8
        }

        # One run of the wrapper as its own process with a fresh home: its exit
        # code, the lines it printed and the resume state it left. -PriorExitCode
        # starts it from a pwsh session whose $LASTEXITCODE already holds that
        # value, as when a native command failed at the prompt before the run.
        function script:Invoke-CarryOverRun
        {
            param([object[]]$Subs, [string[]]$FailSub = @(), [int]$Streams = 1, [int]$PriorExitCode = -1, [string]$CollectorFailSub = '', [switch]$CorruptStreamSummary, [string]$StreamSummaryJson = '', [switch]$MissingStreamSummary, [string]$Stream1SummaryJson = '', [switch]$Resume, [string[]]$Stream0Completed = @(), [switch]$RemoveRoot, [string]$StaleStreamSummaryJson = '', [switch]$StreamSummaryFolderBeforeRun, [string]$ImportFailStream = '', [switch]$NarrationFail, [switch]$VerboseFail, [switch]$FailuresLogFail, [switch]$OtherRun, [switch]$PinnedCompute, [switch]$StreamNarrationFail, [switch]$ResumeRemoveFail, [switch]$ConsumptionPageFail, [switch]$MetricsTokenFail, [switch]$ResumeFailedOnly, [object]$SeedState = $null, [string]$ReuseHome = '', [switch]$ConsumptionTokenFail, [switch]$StreamStateBlocked, [switch]$UnifiedStateBlocked, [string[]]$Stream1Failed = @(), [string[]]$Stream7FailedUnreadable = @(), [switch]$UnifiedStateUnreadable, [string]$HomeName = 'home', [switch]$StandInInventory, [switch]$Stream7Unparseable, [string[]]$Stream7LockedDuringRun = @(), [switch]$SummaryStateBlocked, [switch]$ResumeRemoveSoftFail, [switch]$BracketTool, [switch]$SnapshotPartialFail, [switch]$Stream0Unparseable, [string]$Stream1StateJson = '', [switch]$Fresh, [string]$GoneBy = '', [string]$GoneSub = '', [switch]$CarryStopStateBlocked, [switch]$StreamFileStuck, [switch]$StreamFileRewriteBlocked, [switch]$GoneAfterProbe)
            $CaseDir = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N').Substring(0, 8))
            # ReuseHome: the next run on the same machine, with the resume
            # state the run before left.
            # HomeName: the home folder's name, for a home whose path holds
            # [ or ] (a Unix user name such as u[1]).
            $CaseHome = if ($ReuseHome) { $ReuseHome } else { Join-Path $CaseDir $HomeName }
            New-Item -ItemType Directory -Path $CaseDir -Force | Out-Null
            New-Item -ItemType Directory -Path $CaseHome -Force | Out-Null
            # UnifiedStateBlocked: an empty folder where the resume state's
            # temp file goes, so the run's first write of the resume state
            # fails (as on a full disk). The wrapper's clean-up leaves the
            # folder, so the stand-in removes it once that write has failed
            # (see UnifiedStateOnce), and a later write in the same run works.
            # Without it, a folder an earlier run had is removed, as when the
            # disk is fixed.
            $UnifiedTmp = Join-Path $CaseHome ('InventoryReports/.resume-state-{0}.json.tmp' -f $script:TenantKey)
            if ($UnifiedStateBlocked)
            {
                New-Item -ItemType Directory -Path $UnifiedTmp -Force | Out-Null
            }
            elseif (Test-Path -LiteralPath $UnifiedTmp -PathType Container)
            {
                Remove-Item -LiteralPath $UnifiedTmp -Recurse -Force
            }
            if ($StreamStateBlocked)
            {
                # A folder where stream 0's resume state file goes, so the
                # stream cannot write its state (as when the file is locked).
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                New-Item -ItemType Directory -Path (Join-Path $Reports.FullName ('.resume-state-{0}-stream-0.json' -f $script:TenantKey)) -Force | Out-Null
            }
            if ($null -ne $SeedState)
            {
                # The unified resume state an earlier run left: Completed ids
                # and FailedAttempts ids.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                [pscustomobject]@{
                    TenantID                 = $script:Tenant
                    CompletedSubscriptionIds = @($SeedState.Completed)
                    FailedAttempts           = @(@($SeedState.Failed) | ForEach-Object { [pscustomobject]@{ Id = $_; Name = 'earlier'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier failure'; Attempts = 1 } })
                    LastUpdated              = '2026-01-01T00:00:00Z'
                } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Reports.FullName ('.resume-state-{0}.json' -f $script:TenantKey)) -Encoding utf8
            }
            # UnifiedStateUnreadable: the unified resume state is there but
            # cannot be read (mode 000, as when it is locked). Its mode is put
            # back once the run ends, as when the lock is gone, so the state
            # the run left can be checked and the next run can read it.
            $UnifiedState = Join-Path $CaseHome ('InventoryReports/.resume-state-{0}.json' -f $script:TenantKey)
            if ($UnifiedStateUnreadable)
            {
                [System.IO.File]::SetUnixFileMode($UnifiedState, [System.IO.UnixFileMode]::None)
            }
            # What the streams' summary files hold once the wrapper has
            # started the streams (see Import-AzContext in the stand-in).
            $Plant = @()
            if ($MissingStreamSummary)
            {
                # A folder where stream 0's summary file goes: the stream
                # cannot write its summary, so the wrapper finds no summary
                # file for it (as when its job dies before the end).
                $Plant += [pscustomobject]@{ Stream = '0'; Kind = 'Folder' }
            }
            if ($StaleStreamSummaryJson)
            {
                # Stream 0's summary file from an earlier run, left on disk
                # before this run starts, under that run's name ({RunId} in
                # the text is that run's id). Stream 0 then cannot write its
                # own summary: a file still there is made read-only, else a
                # folder takes its place.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                $EarlierRunId = [guid]::NewGuid().ToString()
                Set-Content -LiteralPath (Join-Path $Reports.FullName ('.rda-stream-0-{0}-summary.json' -f $EarlierRunId)) -Value $StaleStreamSummaryJson.Replace('{RunId}', $EarlierRunId) -Encoding utf8
                $Plant += [pscustomobject]@{ Stream = '0'; Kind = 'Freeze' }
            }
            # StreamSummaryFolderBeforeRun: a folder where stream 0's summary
            # file goes, there when the wrapper starts to remove old
            # summaries, so the wrapper cannot remove it (see
            # SummaryFolderAtStart in the stand-in).
            if ($OtherRun)
            {
                $Plant += [pscustomobject]@{ Stream = '0'; Kind = 'OtherRun' }
            }
            if ($Stream0Completed.Count -gt 0)
            {
                # Stream 0's resume file from an earlier run that stopped
                # before its end: under -Resume it skips these subscriptions.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                [pscustomobject]@{ Tenant = $script:Tenant; StreamId = '0'; Completed = @($Stream0Completed); FailedAttempts = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Reports.FullName ('.resume-state-{0}-stream-0.json' -f $script:TenantKey)) -Encoding utf8
            }
            if ($StreamFileRewriteBlocked)
            {
                $Stuck = New-Item -ItemType Directory -Path (Join-Path $CaseHome ('InventoryReports/.resume-state-{0}-stream-0.json.tmp' -f $script:TenantKey)) -Force
                Set-Content -LiteralPath (Join-Path $Stuck.FullName 'keep') -Value 'x'
            }
            if ($Stream1Failed.Count -gt 0)
            {
                # Stream 1's resume file from an earlier parallel run whose
                # resume state could not be written: these subscriptions
                # failed there and are held only in this file.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                [pscustomobject]@{ Tenant = $script:Tenant; StreamId = '1'; Completed = @(); FailedAttempts = @($Stream1Failed | ForEach-Object { [pscustomobject]@{ Id = $_; Name = 'earlier'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier failure'; Attempts = 1 } }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Reports.FullName ('.resume-state-{0}-stream-1.json' -f $script:TenantKey)) -Encoding utf8
            }
            if ($Stream7FailedUnreadable.Count -gt 0)
            {
                # Stream 7's resume file from an earlier run with more
                # streams: these subscriptions failed there and are held only
                # in this file. It is made unreadable (mode 000, as when it is
                # locked), so this run lists it but cannot read it.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                $Stream7 = Join-Path $Reports.FullName ('.resume-state-{0}-stream-7.json' -f $script:TenantKey)
                [pscustomobject]@{ Tenant = $script:Tenant; StreamId = '7'; Completed = @(); FailedAttempts = @($Stream7FailedUnreadable | ForEach-Object { [pscustomobject]@{ Id = $_; Name = 'earlier'; LastFailedAt = '2026-01-01T00:00:00Z'; Reason = 'earlier failure'; Attempts = 1 } }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Stream7 -Encoding utf8
                [System.IO.File]::SetUnixFileMode($Stream7, [System.IO.UnixFileMode]::None)
            }
            if ($Stream7Unparseable)
            {
                # Stream 7's resume file from an earlier run, cut short: it
                # can be read but is not valid JSON.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                Set-Content -LiteralPath (Join-Path $Reports.FullName ('.resume-state-{0}-stream-7.json' -f $script:TenantKey)) -Value '{"Tenant": "cut' -Encoding utf8
            }
            if ($Stream0Unparseable)
            {
                # Stream 0's resume file from an earlier run, cut short: it
                # can be read but is not valid JSON. This run's stream 0 then
                # writes its own state over it.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                Set-Content -LiteralPath (Join-Path $Reports.FullName ('.resume-state-{0}-stream-0.json' -f $script:TenantKey)) -Value '{"Tenant": "cut' -Encoding utf8
            }
            if ($Stream1StateJson)
            {
                # Stream 1's resume file from an earlier parallel run, as
                # this text.
                $Reports = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports') -Force
                Set-Content -LiteralPath (Join-Path $Reports.FullName ('.resume-state-{0}-stream-1.json' -f $script:TenantKey)) -Value $Stream1StateJson -Encoding utf8
            }
            if ($Stream7LockedDuringRun.Count -gt 0)
            {
                # Stream 7's resume file, holding these failures, is written
                # once stream 0 has started (after this run's start read the
                # stream files), and cannot be read (mode 000), so this run
                # meets it first when the streams are done.
                $Plant += [pscustomobject]@{ Stream = '0'; Kind = 'LockedStreamState'; Text = ($Stream7LockedDuringRun -join ',') }
            }
            if ($Stream1SummaryJson)
            {
                # Stream 1 then reports what this text says, not what it did.
                # {Reports} in the text stands for this run's inventory root.
                $Plant += [pscustomobject]@{ Stream = '1'; Kind = 'Text'; Text = $Stream1SummaryJson }
            }
            if ($CorruptStreamSummary)
            {
                # Stream 0's summary file is text that is not JSON and cannot
                # be written, so the stream cannot replace it and the wrapper
                # finds it but cannot read it.
                $Plant += [pscustomobject]@{ Stream = '0'; Kind = 'Text'; Text = 'not json' }
            }
            elseif ($StreamSummaryJson)
            {
                # The same, with a summary the wrapper can read: stream 0 then
                # reports what this text says, not what it did.
                $Plant += [pscustomobject]@{ Stream = '0'; Kind = 'Text'; Text = $StreamSummaryJson }
            }
            # StandInInventory: the copy of the tool with the stand-in
            # ResourceInventory.ps1.
            $RunTool = if ($StandInInventory) { $script:ToolStandIn } else { $script:Tool }
            # BracketTool: that copy of the tool under a folder whose name
            # holds [ and ] ([client]), as a customer may unpack it.
            if ($BracketTool)
            {
                $BracketParent = Join-Path $CaseDir '[client]'
                $null = [System.IO.Directory]::CreateDirectory($BracketParent)
                Copy-Item -LiteralPath $RunTool -Destination (Join-Path $BracketParent 'tool') -Recurse -Force
                $RunTool = Join-Path $BracketParent 'tool'
            }
            $RunWrapper = Join-Path $RunTool 'Run-AllSubscriptions.ps1'
            $Scenario = Join-Path $CaseDir 'scenario.json'
            [pscustomobject]@{ Tenant = $script:Tenant; Subscriptions = @($Subs); FailSub = @($FailSub); CollectorFailSub = $CollectorFailSub; RemoveRoot = [bool]$RemoveRoot; Plant = @($Plant); ImportFailStream = $ImportFailStream; NarrationFail = [bool]$NarrationFail; VerboseFail = [bool]$VerboseFail; FailuresLogFail = [bool]$FailuresLogFail; StreamNarrationFail = [bool]$StreamNarrationFail; ResumeRemoveFail = [bool]$ResumeRemoveFail; ResumeRemoveSoftFail = [bool]$ResumeRemoveSoftFail; SummaryFolderAtStart = [bool]$StreamSummaryFolderBeforeRun; ConsumptionPageFail = [bool]$ConsumptionPageFail; MetricsTokenFail = [bool]$MetricsTokenFail; ConsumptionTokenFail = [bool]$ConsumptionTokenFail; UnifiedStateOnce = [bool]$UnifiedStateBlocked; SummaryStateFail = [bool]$SummaryStateBlocked; SnapshotPartialFail = [bool]$SnapshotPartialFail; GoneBy = $GoneBy; GoneSub = $GoneSub; CarryStopStateBlocked = [bool]$CarryStopStateBlocked; StreamFileStuck = [bool]$StreamFileStuck; GoneAfterProbe = [bool]$GoneAfterProbe } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Scenario -Encoding utf8

            # ConsumptionPageFail runs the consumption phase (see
            # Get-UsageAggregates in the stand-in), MetricsTokenFail the
            # metrics phase (see Get-AzAccessToken). ConsumptionTokenFail runs
            # the consumption phase with no token for it (the '(auth)' row).
            $WrapperArgs = @('-TenantID', $script:Tenant)
            if (-not $MetricsTokenFail) { $WrapperArgs += '-SkipMetrics' }
            if (-not $ConsumptionPageFail -and -not $ConsumptionTokenFail) { $WrapperArgs += '-SkipConsumption' }
            $WrapperArgs += @('-ParallelStreams', [string]$Streams)
            if ($Resume) { $WrapperArgs += '-Resume' }
            if ($ResumeFailedOnly) { $WrapperArgs += '-ResumeFailedOnly' }
            if ($Fresh) { $WrapperArgs += '-Fresh' }
            # VerboseFail runs the wrapper with -Verbose.
            if ($VerboseFail) { $WrapperArgs += '-Verbose' }
            if ($PriorExitCode -ge 0)
            {
                $Launcher = Join-Path $CaseDir 'launcher.ps1'
                @(
                    ('$global:LASTEXITCODE = {0}' -f $PriorExitCode)
                    ("& '{0}' {1}" -f $RunWrapper, (($WrapperArgs | ForEach-Object { if ($_ -like '-*') { $_ } else { "'$_'" } }) -join ' '))
                    'exit $LASTEXITCODE'
                ) | Set-Content -LiteralPath $Launcher -Encoding utf8
                $Entry = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Launcher)
            }
            else
            {
                $Entry = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $RunWrapper) + $WrapperArgs
            }

            $Info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
            foreach ($Arg in $Entry) { $Info.ArgumentList.Add($Arg) }
            $Info.UseShellExecute = $false
            $Info.RedirectStandardInput = $true
            $Info.RedirectStandardOutput = $true
            $Info.RedirectStandardError = $true
            $Info.WorkingDirectory = $RunTool
            $Info.Environment['HOME'] = $CaseHome
            $ModulePath = $script:Modules
            if ($PinnedCompute)
            {
                # The stand-in modules, with an Az.Compute whose manifest asks
                # for exactly Az.Accounts 5.5.3, older than the tool supports.
                $ModulePath = Join-Path $CaseDir 'modules'
                Copy-Item -LiteralPath $script:Modules -Destination $ModulePath -Recurse -Force
                Set-Content -LiteralPath (Join-Path $ModulePath 'Az.Compute/99.0.0/Az.Compute.psd1') -Value "@{ ModuleVersion = '99.0.0'; RootModule = 'Az.Compute.psm1'; FunctionsToExport = '*'; RequiredModules = @(@{ ModuleName = 'Az.Accounts'; RequiredVersion = '5.5.3' }) }" -Encoding utf8
            }
            $Info.Environment['PSModulePath'] = $ModulePath
            $Info.Environment['RDA_STANDIN_AZURE'] = $Scenario
            $Info.Environment['NO_COLOR'] = '1'
            $Info.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
            $Proc = [System.Diagnostics.Process]::Start($Info)
            $Proc.StandardInput.Close()
            $Out = $Proc.StandardOutput.ReadToEndAsync()
            $Err = $Proc.StandardError.ReadToEndAsync()
            if (-not $Proc.WaitForExit(300000))
            {
                $Proc.Kill($true)
                throw 'The wrapper run did not end within 300 seconds.'
            }
            $Proc.WaitForExit()
            if ($UnifiedStateUnreadable -and (Test-Path -LiteralPath $UnifiedState -PathType Leaf))
            {
                [System.IO.File]::SetUnixFileMode($UnifiedState, [System.IO.UnixFileMode]'UserRead, UserWrite')
            }
            $StateFile = Join-Path $CaseHome ('InventoryReports/.resume-state-{0}.json' -f ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes(([string]$script:Tenant).Trim().ToLowerInvariant()))).Substring(0, 12).ToLowerInvariant()))
            $State = if (Test-Path -LiteralPath $StateFile) { Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } else { $null }
            # RunSummary.log from the consolidated zip, when one was made.
            $OuterZip = @(Get-ChildItem -LiteralPath (Join-Path $CaseHome 'InventoryReports') -Filter 'AllSubscriptions_ResourcesReport_*.zip' -File -ErrorAction SilentlyContinue)
            $RunSummary = $null
            $MainSummary = $null
            $InnerZips = @()
            if ($OuterZip.Count -eq 1)
            {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $Zip = [System.IO.Compression.ZipFile]::OpenRead($OuterZip[0].FullName)
                try
                {
                    $InnerZips = @($Zip.Entries | Where-Object { $_.FullName -like '*.zip' } | ForEach-Object { $_.FullName })
                    $Entry = $Zip.GetEntry('RunSummary.log')
                    if ($null -ne $Entry)
                    {
                        $Reader = [System.IO.StreamReader]::new($Entry.Open())
                        try { $RunSummary = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
                    }
                    $Entry = $Zip.GetEntry('MainSummary.html')
                    if ($null -ne $Entry)
                    {
                        $Reader = [System.IO.StreamReader]::new($Entry.Open())
                        try { $MainSummary = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
                    }
                }
                finally { $Zip.Dispose() }
            }
            return [pscustomobject]@{
                ExitCode   = $Proc.ExitCode
                Console    = ($Out.Result + $Err.Result)
                FailedIds  = @(if ($null -ne $State) { @($State.FailedAttempts) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Id } })
                StateKept  = $null -ne $State
                ZipCount   = $OuterZip.Count
                RunSummary = $RunSummary
                MainSummary = $MainSummary
                InnerZips  = $InnerZips
                Root       = Join-Path $CaseHome 'InventoryReports'
                Home       = $CaseHome
            }
        }

        # One pwsh session (`pwsh -Command -`, its lines on stdin, as typed at a
        # prompt) with a fresh home. {Run} in a line becomes the wrapper call
        # with -ParallelStreams $Streams; {RunConsumption} is the same call
        # without -SkipConsumption. {Fail} and {Clean} become scenario files
        # where the first subscription fails or none does (the session starts
        # with {Clean}). With -ConsumptionTokenFail the consumption phase gets
        # no token (see Get-AzAccessToken in the stand-in). Returns the
        # session's exit code and the lines it printed.
        function script:Invoke-SessionRun
        {
            param([object[]]$Subs, [string[]]$Lines, [int]$Streams = 2, [switch]$ConsumptionTokenFail)
            $CaseDir = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $CaseHome = Join-Path $CaseDir 'home'
            New-Item -ItemType Directory -Path $CaseHome -Force | Out-Null
            $Scenario = Join-Path $CaseDir 'scenario.json'
            [pscustomobject]@{ Tenant = $script:Tenant; Subscriptions = @($Subs); FailSub = ''; ConsumptionTokenFail = [bool]$ConsumptionTokenFail } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Scenario -Encoding utf8
            $FailScenario = Join-Path $CaseDir 'scenario-fail.json'
            [pscustomobject]@{ Tenant = $script:Tenant; Subscriptions = @($Subs); FailSub = [string]$Subs[0].Id; ConsumptionTokenFail = [bool]$ConsumptionTokenFail } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $FailScenario -Encoding utf8
            $Call = "& '{0}' -TenantID '{1}' -SkipMetrics -SkipConsumption -ParallelStreams {2}" -f ($script:Wrapper -replace "'", "''"), $script:Tenant, $Streams
            $ConsumptionCall = "& '{0}' -TenantID '{1}' -SkipMetrics -ParallelStreams {2}" -f ($script:Wrapper -replace "'", "''"), $script:Tenant, $Streams

            $Info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
            foreach ($Arg in @('-NoLogo', '-NoProfile', '-Command', '-')) { $Info.ArgumentList.Add($Arg) }
            $Info.UseShellExecute = $false
            $Info.RedirectStandardInput = $true
            $Info.RedirectStandardOutput = $true
            $Info.RedirectStandardError = $true
            $Info.WorkingDirectory = $script:Tool
            $Info.Environment['HOME'] = $CaseHome
            $Info.Environment['PSModulePath'] = $script:Modules
            $Info.Environment['RDA_STANDIN_AZURE'] = $Scenario
            $Info.Environment['NO_COLOR'] = '1'
            $Info.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
            $Proc = [System.Diagnostics.Process]::Start($Info)
            foreach ($Line in $Lines) { $Proc.StandardInput.WriteLine($Line.Replace('{RunConsumption}', $ConsumptionCall).Replace('{Run}', $Call).Replace('{Fail}', $FailScenario).Replace('{Clean}', $Scenario)) }
            $Proc.StandardInput.Close()
            $Out = $Proc.StandardOutput.ReadToEndAsync()
            $Err = $Proc.StandardError.ReadToEndAsync()
            if (-not $Proc.WaitForExit(300000))
            {
                $Proc.Kill($true)
                throw 'The session did not end within 300 seconds.'
            }
            $Proc.WaitForExit()
            $Text = @(($Out.Result + $Err.Result) -split "`r?`n" | ForEach-Object { $_.Trim() })
            return [pscustomobject]@{
                ExitCode = $Proc.ExitCode
                Console  = ($Text -join "`n")
                After    = @($Text | Where-Object { $_ -match '^after\d?: ' })
                Open     = @($Text | Where-Object { $_ -eq 'session still open' }).Count -eq 1
            }
        }
    }

    AfterAll {
        if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
        {
            Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'sequential: the subscription after one that ended with exit 1 completes and is not listed as failed' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -FailSub $script:SubA.Id
        $Run.Console | Should -Match 'ERROR processing subscription Sub A: Script exited with code 1'
        $Run.Console | Should -Not -Match 'ERROR processing subscription Sub B' -Because $Run.Console
        $Run.Console | Should -Match 'Completed subscription: Sub B'
        $Run.FailedIds | Should -Be @($script:SubA.Id)
        # Sub A's report is missing, so the run is not reported as clean.
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'one stream: the subscription after one that ended with exit 1 in the same stream is not listed as failed' {
        # Three subscriptions over two streams: stream-0 holds Sub A then Sub C.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -FailSub $script:SubA.Id -Streams 2
        $Run.Console | Should -Match '\[stream-0\] queued: 2 subscription\(s\)'
        $Run.Console | Should -Match '\[stream-0\] ERROR processing Sub A: Script exited with code 1'
        $Run.Console | Should -Not -Match 'ERROR processing Sub C' -Because $Run.Console
        $Run.Console | Should -Match '\[stream-0\] done: Sub C'
        $Run.Console | Should -Match '\[stream-1\] done: Sub B'
        $Run.FailedIds | Should -Be @($script:SubA.Id)
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'sequential: exit 2 for a failed subscription still names the collector failure it hides, on the console and in RunSummary.log' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -FailSub $script:SubA.Id -CollectorFailSub $script:SubB.Id
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.Console | Should -Match 'FAILED \(collectors\)'
        $Run.ZipCount | Should -Be 1 -Because 'Sub B''s report is still consolidated'
        $Made = 'Exit code 2: one or more subscriptions failed (see Subscriptions Failed); the consolidated zip holds the reports of the subscriptions that worked.'
        $Hidden = 'Exit code 2 takes priority over exit code 4, which this run also has: one or more collectors failed.'
        $Run.Console | Should -Match ([regex]::Escape($Made))
        $Run.Console | Should -Match ([regex]::Escape($Hidden))
        $Run.RunSummary | Should -Match ([regex]::Escape($Made))
        $Run.RunSummary | Should -Match ([regex]::Escape($Hidden))
    }

    It 'sequential: exit 2 when every subscription failed says no consolidated zip was made' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -FailSub $script:SubA.Id
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.ZipCount | Should -Be 0
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: one or more subscriptions failed (see Subscriptions Failed); no consolidated zip was made.'))
    }

    It 'two streams: a stream summary the wrapper cannot read is not counted as a failed subscription, and exit 2 names it' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -CorruptStreamSummary
        $Run.Console | Should -Match '\[stream-0\] ERROR: could not parse summary file' -Because $Run.Console
        $Run.Console | Should -Not -Match 'ERROR processing' -Because 'no inventory run failed; only the stream summary is lost'
        # Both reports are in the consolidated zip, so no subscription is
        # counted or named as failed.
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Not -Match 'subscriptions failed' -Because $Run.Console
        $Run.Console | Should -Match '2 subscription\(s\), 2 total resource\(s\), 0 empty, 0 failed' -Because $Run.Console
        $Run.Console | Should -Match 'Stream Summary Unreadable:\s+stream-0 \(1 subscription\(s\) not confirmed; check the consolidated zip\)' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.'))
        # The run cannot show that stream's results, so it is not called clean
        # and its resume state is kept.
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: the verification-gap stop prints the Exit code lines, naming the sign-in skip and collector failures it hides' {
        # Stream 0 (Sub A, Sub X, Sub Y) reports its three subscriptions as
        # worked, with a collector failure and a Metrics sign-in skip, and
        # names no zip for any of them, so reports are missing. (A summary
        # holds a row only for the subscriptions its stream ran, so Sub X and
        # Sub Y are in the run; Sub C fills stream 1.)
        $SubX = [guid]::new(('0' * 31) + 'e').ToString()
        $SubY = [guid]::new(('0' * 31) + 'f').ToString()
        $RunSubs = @($script:SubA, $script:SubB, [pscustomobject]@{ Id = $SubX; Name = 'Sub X' }, $script:SubC, [pscustomobject]@{ Id = $SubY; Name = 'Sub Y' })
        $Forged = [pscustomobject]@{
            RunId             = '{RunId}'
            StreamId          = '0'
            Status            = 'ok'
            ResourceCounts    = @([pscustomobject]@{ Name = $script:SubA.Name; Id = $script:SubA.Id; Count = 1 }, [pscustomobject]@{ Name = 'Sub X'; Id = $SubX; Count = 1 }, [pscustomobject]@{ Name = 'Sub Y'; Id = $SubY; Count = 1 })
            Failed            = @()
            CollectorFailures = @([pscustomobject]@{ Id = $SubX; Name = 'Sub X'; Module = 'StandIn'; Message = 'stand-in: this collector failed' })
            MetricsFailedSubs = @([pscustomobject]@{ Id = $SubX; Name = 'Sub X'; Message = 'stand-in: no token' })
        } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs $RunSubs -Streams 2 -StreamSummaryJson $Forged
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Gap = 'Exit code 2: a report is missing (verification gap, see Per-subscription output verification failed); no consolidated zip was made.'
        $Hidden = 'Exit code 2 takes priority over exit code 5, which this run also has: Metrics and/or Consumption were skipped for a sign-in problem and one or more collectors failed.'
        $Run.Console | Should -Match ('(?s)Per-subscription output verification failed\..*' + [regex]::Escape($Gap) + '\s+' + [regex]::Escape($Hidden)) -Because $Run.Console
        $Run.Console | Should -Not -Match 'subscriptions failed' -Because $Run.Console
    }

    It 'sequential: RunSummary.log lists the failed subscription by its name and id' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -FailSub $script:SubA.Id
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.RunSummary | Should -Match ('(?m)^  - {0} \({1}\)\s*$' -f [regex]::Escape($script:SubA.Name), [regex]::Escape($script:SubA.Id)) -Because $Run.RunSummary
        $Run.RunSummary | Should -Not -Match '(?m)^  -  \(\)' -Because $Run.RunSummary
    }

    It 'one stream: RunSummary.log lists the subscription that failed in a stream by its name and id' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -FailSub $script:SubA.Id -Streams 2
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.RunSummary | Should -Match ('(?m)^  - {0} \({1}\)\s*$' -f [regex]::Escape($script:SubA.Name), [regex]::Escape($script:SubA.Id)) -Because $Run.RunSummary
        $Run.RunSummary | Should -Not -Match '(?m)^  -  \(\)' -Because $Run.RunSummary
    }

    It 'two streams: RunSummary.log names a stream whose summary could not be read under Exit code, not as a failed subscription' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -CorruptStreamSummary
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.RunSummary | Should -Match '(?m)^  Failed subscriptions\s+: 0\s*$' -Because $Run.RunSummary
        $Run.RunSummary | Should -Not -Match 'corrupt summary' -Because $Run.RunSummary
        $Run.RunSummary | Should -Not -Match 'subscriptions failed' -Because $Run.RunSummary
        $Run.RunSummary | Should -Match ([regex]::Escape('  Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.RunSummary
        $Run.RunSummary | Should -Not -Match '(?m)^  -  \(\)' -Because $Run.RunSummary
    }

    It 'two streams: MainSummary.html names a stream whose summary could not be read, not as a failed subscription' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -CorruptStreamSummary
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.MainSummary | Should -Match ([regex]::Escape('The summary of stream 0 could not be read.</b> Its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because 'MainSummary.html must show the same signal as the console and RunSummary.log'
        $Run.MainSummary | Should -Not -Match 'failed to process' -Because 'no subscription failed'
    }

    It 'two streams with -Resume: a stream with no summary file names its 2 subscriptions as not confirmed, not as one failed subscription' {
        # Three subscriptions over two streams: stream-0 holds Sub A then Sub C.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -MissingStreamSummary -Resume
        $Run.Console | Should -Match '\[stream-0\] WARNING: no summary file' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Match 'Stream Summary Missing:\s+stream-0 \(2 subscription\(s\) not confirmed; check the consolidated zip\)' -Because $Run.Console
        $Run.Console | Should -Not -Match 'could not be read' -Because 'the summary file is missing, not unreadable'
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 is missing; its 2 subscription(s) are not confirmed; check the consolidated zip for their reports.'))
        # No subscription was skipped: all three ran this time. The run has no
        # unfinished run to continue, so it prints no Skipped line.
        $Run.Console | Should -Not -Match '(?m)^Subscriptions Skipped:' -Because $Run.Console
        $Run.Console | Should -Match '(?m)^Subscriptions Processed: 3\s*$' -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.RunSummary | Should -Match '(?m)^  Failed subscriptions\s+: 0\s*$' -Because $Run.RunSummary
        $Run.MainSummary | Should -Match ([regex]::Escape('The summary of stream 0 is missing.</b> Its 2 subscription(s) are not confirmed')) -Because $Run.Console
        $Run.MainSummary | Should -Not -Match 'failed to process' -Because 'no subscription failed'
        # The resume state is kept, and nothing is put on the retry list.
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams with -Resume: an unreadable stream summary names only the subscriptions the stream ran this time as not confirmed' {
        # Stream-0's resume file says Sub A is done. The start folds it into
        # the resume state (#38), so the wrapper skips Sub A before it slices:
        # stream-0 runs Sub B and stream-1 runs Sub C.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -CorruptStreamSummary -Resume -Stream0Completed @($script:SubA.Id)
        $Run.Console | Should -Match 'Skipping \(already completed\): Sub A' -Because $Run.Console
        # Stream-0's resume file records no report for Sub A, so it cannot be
        # carried: under ruling 1 a missing report stops the run with exit 2
        # before the consolidated zip (no zip, RunSummary.log or MainSummary),
        # and the Exit code lines still name only the subscription stream-0
        # ran this time as not confirmed.
        $Run.Console | Should -Match ('(?m)^  - {0} \({1}\): ' -f [regex]::Escape($script:SubA.Name), [regex]::Escape($script:SubA.Id)) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; no consolidated zip was made.'))
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams with -Resume: a stream that cannot start names as failed only the subscriptions it would have run, not those its resume file lists as done' {
        # Stream-0's resume file says Sub A is done; the start folds it in
        # (#38), so the wrapper skips Sub A and stream-0 holds Sub B, stream-1
        # Sub C. Stream-0's context import fails, so it runs nothing.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -Stream0Completed @($script:SubA.Id) -ImportFailStream '0'
        $Run.Console | Should -Match '\[stream-0\] FATAL: could not import Az context' -Because $Run.Console
        # The advice is the one of a stream whose autosave could not be turned off.
        $Run.Console | Should -Match ([regex]::Escape('Its subscriptions are reported as failed and stay on the retry list; the next run that continues this one collects them with one stream, which needs no Az context snapshot.')) -Because $Run.Console
        $Run.Console | Should -Match '\[stream-1\] done: Sub C' -Because $Run.Console
        # Sub A has no report to carry (the earlier run is not there): under
        # ruling 1 that is a missing report, so the run stops with exit 2
        # before the consolidated zip (no zip, RunSummary.log or MainSummary).
        # Sub A is named for its earlier report that is not carried, not as a
        # failed subscription; only Sub B is counted as failed.
        $Run.Console | Should -Match '(?m)^Subscriptions Failed:\s+1 \(see the ERROR and FATAL lines above\)\s*$' -Because $Run.Console
        $Run.Console | Should -Match ('(?m)^  - {0} \({1}\): ' -f [regex]::Escape($script:SubA.Name), [regex]::Escape($script:SubA.Id)) -Because $Run.Console
        $Run.Console | Should -Match '= FAILED \(earlier report not carried\) =' -Because $Run.Console
        $Run.Console | Should -Not -Match ('{0} \(stream-0' -f [regex]::Escape($script:SubA.Name)) -Because 'Sub A was done in an earlier run and was not run or failed this time'
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: one or more subscriptions failed (see Subscriptions Failed); no consolidated zip was made.')) -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        # Both go on the retry list: Sub B for its stream, Sub A to be collected again.
        @($Run.FailedIds | Sort-Object) | Should -Be @(@($script:SubA.Id, $script:SubB.Id) | Sort-Object) -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams with -Resume: when the state write at the earlier-report stop fails, the stop says the subscriptions are not on the retry list, not that they are' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -Stream0Completed @($script:SubA.Id) -ImportFailStream '0' -CarryStopStateBlocked
        $Run.Console | Should -Match '= FAILED \(earlier report not carried\) =' -Because $Run.Console
        $Run.Console | Should -Match 'could not be written \(see the WARNING above\), so they are not on the retry list' -Because $Run.Console
        $Run.Console | Should -Not -Match 'They are back on the retry list' -Because $Run.Console
        $Run.Console | Should -Match '(?m)^  .*-Fresh' -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams with -Resume: after the earlier-report stop the per-stream file no longer lists the subscription as completed, so the next run collects it and ends' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -Stream0Completed @($script:SubA.Id) -ImportFailStream '0' -StreamFileStuck
        $Run.Console | Should -Match 'They are back on the retry list' -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Left = @(Get-ChildItem -LiteralPath (Join-Path $Run.Home 'InventoryReports') -Filter '.resume-state-*-stream-*.json' -File -Force | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -like ('*' + $script:SubA.Id + '*') })
        $Left.Count | Should -Be 0 -Because ('a per-stream file still lists Sub A as completed: ' + (@($Left | ForEach-Object { $_.Name }) -join ', '))
        $Next = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -ReuseHome $Run.Home
        $Next.Console | Should -Not -Match '= FAILED \(earlier report not carried\) =' -Because $Next.Console
        $Next.Console | Should -Match 'Sub A' -Because $Next.Console
        $Next.ExitCode | Should -Be 0 -Because $Next.Console
    }

    It 'two streams with -Resume: a per-stream file that can be neither rewritten nor removed is named, with the state not on the retry list, and the next run stops with the same advice' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -Stream0Completed @($script:SubA.Id) -ImportFailStream '0' -StreamFileStuck -StreamFileRewriteBlocked
        $Run.Console | Should -Match '= FAILED \(earlier report not carried\) =' -Because $Run.Console
        $Run.Console | Should -Match 'per-stream state file\(s\) \.resume-state-.*-stream-0\.json still list them as completed' -Because $Run.Console
        $Run.Console | Should -Not -Match 'They are back on the retry list' -Because $Run.Console
        $Run.Console | Should -Match '(?m)^  .*-Fresh' -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        # Run 2 with the file still stuck: the same stop, with the same advice.
        $Next = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -ReuseHome $Run.Home -StreamFileStuck -StreamFileRewriteBlocked
        $Next.Console | Should -Match 'still list them as completed' -Because $Next.Console
        $Next.ExitCode | Should -Be 2 -Because $Next.Console
        # The advice ends it: the file is removed by hand (the folder can be
        # written again), and the next run collects Sub A and ends clean.
        Get-ChildItem -LiteralPath (Join-Path $Run.Home 'InventoryReports') -Filter '.resume-state-*-stream-*' -Force | Remove-Item -Recurse -Force
        $Done = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -ReuseHome $Run.Home
        $Done.Console | Should -Not -Match '= FAILED \(earlier report not carried\) =' -Because $Done.Console
        $Done.ExitCode | Should -Be 0 -Because $Done.Console
    }

    It 'two streams without -Resume: a stream that cannot start names every subscription of its slice as failed' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ImportFailStream '0'
        $Run.Console | Should -Match '(?m)^Subscriptions Failed:\s+2 \(Sub A \(stream-0: .+\), Sub C \(stream-0: .+\)\)\s*$' -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: after a run whose stream could not load its Az context snapshot, the next run uses one stream, so the loop ends' {
        # Run 1: stream-0 (Sub A, Sub C) cannot import its snapshot, so it runs
        # nothing; their retry entries are not counted (they stay at 0), so the
        # retry limit can never end them.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ImportFailStream '0'
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        @($Run.FailedIds | Sort-Object) | Should -Be @(@($script:SubA.Id, $script:SubC.Id) | Sort-Object) -Because $Run.Console
        # Run 2, -Resume, two streams asked for, and the snapshot still cannot be
        # imported: a run with one stream uses no snapshot, so it collects them.
        $Next = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -ImportFailStream '0' -ReuseHome $Run.Home
        $Next.Console | Should -Match ([regex]::Escape('Parallelism: -ParallelStreams 1 (the last run''s stream could not load its Az context snapshot for 2 subscription(s) on the retry list, so one stream instead of the 2 passed; this covers all of this run''s subscriptions, also when -ParallelStreams was passed, because one stream needs no snapshot)')) -Because $Next.Console
        $Next.Console | Should -Not -Match 'FATAL: could not import Az context' -Because $Next.Console
        @($Next.FailedIds) | Should -BeNullOrEmpty -Because $Next.Console
        $Next.StateKept | Should -BeFalse -Because $Next.Console
        $Next.ExitCode | Should -Be 0 -Because $Next.Console
        # Run 3, -Resume: no retry entry is left, so two streams again.
        $Last = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -ReuseHome $Run.Home
        $Last.Console | Should -Match ([regex]::Escape('Parallelism: -ParallelStreams 2 (explicit)')) -Because $Last.Console
        $Last.ExitCode | Should -Be 0 -Because $Last.Console
    }

    It 'two streams: the zips of a stream whose summary could not be read do not hide the missing zip of a subscription that reported success' {
        # Stream-0 (Sub A, Sub C) writes two zips but its summary cannot be
        # read; stream 1 runs Sub B and Sub X (two zips) but its summary
        # names no zip for either. Four fresh zips for two successes must not
        # pass the check. (A summary holds a row only for the subscriptions
        # its stream ran, so Sub X is in the run.)
        $SubX = [pscustomobject]@{ Name = 'Sub X'; Id = [guid]::new(('0' * 31) + 'e').ToString(); Count = 1 }
        $RowB = [pscustomobject]@{ Name = $script:SubB.Name; Id = $script:SubB.Id; Count = 1 }
        $Forged = [pscustomobject]@{ RunId = '{RunId}'; StreamId = '1'; Status = 'ok'; ResourceCounts = @($RowB, $SubX); Failed = @() } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC, [pscustomobject]@{ Id = $SubX.Id; Name = $SubX.Name }) -Streams 2 -CorruptStreamSummary -Stream1SummaryJson $Forged
        $Run.Console | Should -Match '\[stream-1\] done: Sub B' -Because $Run.Console
        $Run.Console | Should -Not -Match 'verification: OK' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Match ('(?m)^\s*- Sub X \({0}\) \[1 resources\]' -f [regex]::Escape($SubX.Id)) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: a report is missing (verification gap, see Per-subscription output verification failed); no consolidated zip was made.'))
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a subscription whose named zip is gone fails the check, though other fresh zips are present' {
        # Stream 1 runs Sub B and Sub X, and reports Sub X with the zip its
        # inner script named, and that zip is not on disk (as when antivirus
        # removes it after it was written). Stream-0's zips (Sub A, Sub C,
        # summary unreadable) and stream 1's zips are fresh, so only the path
        # match can find Sub X's gap. (A summary holds a row only for the
        # subscriptions its stream ran, so Sub X is in the run.)
        $SubX = [pscustomobject]@{ Name = 'Sub X'; Id = [guid]::new(('0' * 31) + 'e').ToString(); Count = 1; Zip = '{Reports}/SubX/ResourcesReport_gone.zip' }
        $RowB = [pscustomobject]@{ Name = $script:SubB.Name; Id = $script:SubB.Id; Count = 1 }
        $Forged = [pscustomobject]@{ RunId = '{RunId}'; StreamId = '1'; Status = 'ok'; ResourceCounts = @($RowB, $SubX); Failed = @() } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC, [pscustomobject]@{ Id = $SubX.Id; Name = $SubX.Name }) -Streams 2 -CorruptStreamSummary -Stream1SummaryJson $Forged
        $Run.Console | Should -Match '\[stream-1\] done: Sub B' -Because $Run.Console
        $Run.Console | Should -Not -Match 'verification: OK' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Match ('(?m)^\s*- Sub X \({0}\) \[1 resources\]' -f [regex]::Escape($SubX.Id)) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: a report is missing (verification gap, see Per-subscription output verification failed); no consolidated zip was made.'))
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'sequential: an inventory folder that is gone after a subscription worked is a verification gap, not a clean run' {
        # Sub A's inner script writes its report and returns with success;
        # then the whole inventory root, with that report, is gone. The
        # wrapper runs without its transcript, which would make the folder
        # again.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -RemoveRoot
        $Run.Console | Should -Match 'WARNING: Could not start wrapper transcript' -Because $Run.Console
        $Run.Console | Should -Match 'Completed subscription: Sub A' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Match 'The inventory folder .+ is gone, so every report under it is lost, with its resume state: the next run collects every subscription again\.' -Because $Run.Console
        $Run.Console | Should -Match ('(?m)^\s*- Sub A \({0}\) \[1 resources\]' -f [regex]::Escape($script:SubA.Id)) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: a report is missing (verification gap, see Per-subscription output verification failed); no consolidated zip was made.'))
        $Run.Console | Should -Not -Match 'Exit code 0' -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        # The resume state was in the folder too, so the next -Resume run
        # starts over and collects Sub A again.
        $Run.StateKept | Should -BeFalse -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It '<Case>: a console line that cannot be written after a subscription worked does not make it failed' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'one subscription with -ParallelStreams'; Streams = 2 }
    ) {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -Streams $Streams -NarrationFail
        @(Get-Content -LiteralPath (Join-Path $Run.Home 'narration-refused.txt') -ErrorAction SilentlyContinue) | Should -Be @('Resources collected: 1') -Because 'the refused line must be the one a subscription that worked writes'
        $Run.Console | Should -Not -Match 'ERROR processing subscription' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification: OK' -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0 -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
    }

    It '<Case> with -Verbose: the note about that failed line cannot make the subscription failed either' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'one subscription with -ParallelStreams'; Streams = 2 }
    ) {
        # The verbose note the guard writes about the failed line cannot be
        # written either (the same broken transcript).
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -Streams $Streams -NarrationFail -VerboseFail
        @(Get-Content -LiteralPath (Join-Path $Run.Home 'narration-refused.txt') -ErrorAction SilentlyContinue) | Should -Be @('Resources collected: 1') -Because 'the refused line must be the one a subscription that worked writes'
        $Run.Console | Should -Not -Match 'ERROR processing subscription' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification: OK' -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0 -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
    }

    It 'two streams: a console line a stream cannot write after its subscription worked does not make it failed' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamNarrationFail
        @(Get-ChildItem -LiteralPath $Run.Home -Filter 'narration-refused-*.txt' | Get-Content | Sort-Object) | Should -Be @('[stream-0] done: Sub A - Resources collected: 1', '[stream-1] done: Sub B - Resources collected: 1') -Because 'the refused lines must be the ones a subscription that worked writes'
        $Run.Console | Should -Not -Match 'ERROR processing' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification: OK \(each of the 2 successful sub\(s\) has its zip' -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0 -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
    }

    It 'two streams: the verification-gap stop does not count a stream with no summary file as a failed subscription' {
        # Stream 1 (Sub B) reports Sub B as worked, with no zip named, so
        # the run stops at the output verification. Its one success is not
        # the 2 subscriptions of stream 0, whose summary is missing. (A
        # summary holds a row only for the subscriptions its stream ran.)
        $RowB = [pscustomobject]@{ Name = $script:SubB.Name; Id = $script:SubB.Id; Count = 1 }
        $Forged = [pscustomobject]@{ RunId = '{RunId}'; StreamId = '1'; Status = 'ok'; ResourceCounts = @($RowB); Failed = @() } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -MissingStreamSummary -Stream1SummaryJson $Forged
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.Console | Should -Not -Match 'ERROR lines above' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 is missing; its 2 subscription(s) are not confirmed; no consolidated zip was made.'))
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a report zip of a stream with no summary file that is gone before the consolidated zip stops the run with the verification gap and puts it on the retry list' {
        # Stream 0 runs Sub A then Sub C and writes no summary file. Sub C's run
        # removes the zip Sub A wrote. Stream 0's own state file still holds
        # Sub A's report record, so the zip is a gap, as a success row's would be.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -MissingStreamSummary -StandInInventory -GoneBy $script:SubC.Id -GoneSub $script:SubA.Id
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape($script:SubA.Id)) -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        # The subscription is taken off the completed list and put on the retry list.
        $Run.FailedIds | Should -Contain $script:SubA.Id -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        # The lines name the gone report as a recorded report, with no resource count.
        # Expected counts the gone record row too: the found count is one lower.
        $Expected = [int]([regex]::Match($Run.Console, '  Expected zips: (\d+) ').Groups[1].Value)
        $Found = [int]([regex]::Match($Run.Console, '  Found zips:\s+(\d+) ').Groups[1].Value)
        $Gap = [int]([regex]::Match($Run.Console, '  Gap:\s+(\d+) missing').Groups[1].Value)
        $Gap | Should -Be 1 -Because $Run.Console
        ($Expected - $Found) | Should -Be $Gap -Because $Run.Console
        $Run.Console | Should -Not -Match '\[0 resources\]' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('[report recorded by a stream whose summary could not be read]')) -Because $Run.Console
    }

    It 'two streams: a report zip of a stream with no summary file that is there at the first look and gone before the zips are picked is a gap, not a smaller bundle' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -MissingStreamSummary -StandInInventory -GoneSub $script:SubA.Id -GoneAfterProbe
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape($script:SubA.Id)) -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: two subscriptions of two streams whose rows name one zip are a gap, not one report for both<Note>' -ForEach @(
        @{ Note = ''; Stuck = $false }
    ) {
        # Each stream's summary names, for its one subscription, the same report
        # zip, which is on disk: one zip would stand in for both.
        $CaseHome = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $Shared = New-Item -ItemType Directory -Path (Join-Path $CaseHome 'InventoryReports/Shared') -Force
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $Archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Shared.FullName 'ResourcesReport_shared.zip'), [System.IO.Compression.ZipArchiveMode]::Create)
        try { $W = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_shared.json').Open()); $W.Write('{}'); $W.Dispose() } finally { $Archive.Dispose() }
        $Forge = {
            param($Sub, [string]$Stream)
            [pscustomobject]@{ RunId = '{RunId}'; StreamId = $Stream; Status = 'ok'; Failed = @()
                ResourceCounts = @([pscustomobject]@{ Name = $Sub.Name; Id = $Sub.Id; Count = 1; Zip = '{Reports}/Shared/ResourcesReport_shared.zip' })
                RunReports = @([pscustomobject]@{ Id = $Sub.Id; Name = $Sub.Name; Zip = 'Shared/ResourcesReport_shared.zip'; Obfuscated = $false }) } | ConvertTo-Json -Depth 5
        }
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ReuseHome $CaseHome -StreamSummaryJson (& $Forge $script:SubA '0') -Stream1SummaryJson (& $Forge $script:SubB '1') -StreamFileStuck:$Stuck
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.Console | Should -Match ('(?m)^\s*- Sub B \({0}\) \[its zip is one another subscription''s report also names\]' -f [regex]::Escape($script:SubB.Id)) -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        # The second claim is collected again by the next run; the first is kept.
        $Run.FailedIds | Should -Contain $script:SubB.Id -Because $Run.Console
        $Run.FailedIds | Should -Not -Contain $script:SubA.Id -Because $Run.Console
        if ($Stuck)
        {
            $Left = @(Get-ChildItem -LiteralPath $Run.Root -Filter '.resume-state-*-stream-*.json' -File -Force | Where-Object { $_.Name -notlike '*-stream-summary-*' -and (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Completed -contains $script:SubB.Id })
            $Left.Count | Should -Be 0 -Because ('a per-stream file still lists Sub B as completed: ' + (@($Left | ForEach-Object { $_.Name }) -join ', '))
        }
    }

    It 'sequential with -Resume: two completed subscriptions whose records name one zip are not both carried; the second is collected again and the run after ends clean' {
        # Run 1 fails Sub A and completes Sub B and Sub C, so the state is kept.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -FailSub $script:SubA.Id
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        # The state then names Sub B's zip for Sub C too.
        $StatePath = Join-Path $Run.Root ('.resume-state-{0}.json' -f $script:TenantKey)
        $Text = Get-Content -LiteralPath $StatePath -Raw
        $State = $Text | ConvertFrom-Json
        $ZipB = @($State.CompletedReports | Where-Object { $_.Id -eq $script:SubB.Id })[0].Zip
        $ZipC = @($State.CompletedReports | Where-Object { $_.Id -eq $script:SubC.Id })[0].Zip
        $ZipB | Should -Not -BeNullOrEmpty
        $ZipC | Should -Not -BeNullOrEmpty
        $Json = { param($V) (ConvertTo-Json -InputObject ([string]$V)) }
        $Text.Contains((& $Json $ZipC)) | Should -BeTrue
        Set-Content -LiteralPath $StatePath -Value $Text.Replace((& $Json $ZipC), (& $Json $ZipB)) -Encoding utf8 -NoNewline
        # Run 2: Sub B is carried, Sub C is not (its zip is Sub B's), so it stops.
        $Next = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Resume -ReuseHome $Run.Home
        $Next.Console | Should -Match '= FAILED \(earlier report not carried\) =' -Because $Next.Console
        $Next.Console | Should -Match ('(?m)^  - Sub C \({0}\): its report zip is one another subscription already names' -f [regex]::Escape($script:SubC.Id)) -Because $Next.Console
        # No consolidated zip is made (run 1's, with Sub B and Sub C, is the one there).
        $Next.Console | Should -Match 'No consolidated zip was made' -Because $Next.Console
        $Next.ZipCount | Should -Be $Run.ZipCount -Because $Next.Console
        $Next.ExitCode | Should -Be 2 -Because $Next.Console
        # Run 3 collects Sub C and ends with one report for each subscription.
        $Done = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Resume -ReuseHome $Run.Home
        $Done.Console | Should -Match 'Processing subscription: Sub C' -Because $Done.Console
        $Done.ExitCode | Should -Be 0 -Because $Done.Console
        $Newest = @(Get-ChildItem -LiteralPath $Done.Root -Filter 'AllSubscriptions_ResourcesReport_*.zip' -File | Sort-Object LastWriteTimeUtc)[-1]
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Outer = [System.IO.Compression.ZipFile]::OpenRead($Newest.FullName)
        try { $Inner = @($Outer.Entries | Where-Object { $_.FullName -like '*.zip' } | ForEach-Object { $_.FullName }) } finally { $Outer.Dispose() }
        $Inner.Count | Should -Be 3 -Because ($Inner -join ', ')
        @($Inner | Sort-Object -Unique).Count | Should -Be 3 -Because ($Inner -join ', ')
    }

    It 'two streams: a stream summary left by an earlier run is not read as this run''s' {
        # An earlier run left stream 0's summary on disk ("ok", no rows, as
        # an interrupted -Resume run that skipped everything writes it). This
        # run's stream 0 then writes no summary.
        $Stale = [pscustomobject]@{ RunId = '{RunId}'; StreamId = '0'; Tenant = $script:Tenant; Status = 'ok'; Completed = @(); Failed = @(); ResourceCounts = @() } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StaleStreamSummaryJson $Stale
        $Run.Console | Should -Match '\[stream-0\] WARNING: no summary file' -Because $Run.Console
        # The earlier run's summary is under that run's name, which this run
        # neither reads nor removes.
        @(Get-ChildItem -LiteralPath $Run.Root -Filter '.rda-stream-0-*-summary.json' -File -Force).Count | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 is missing; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'Exit code 0' -Because $Run.Console
        # The resume state is kept, and nothing is put on the retry list.
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a summary another run wrote at this run''s stream summary path is not confirmed' {
        # Stream 0 runs Sub A. Its summary file holds a good row for Sub A,
        # but names another run.
        $Json = ('{{"RunId":"99999999-0000-0000-0000-000000000000","StreamId":"0","Status":"ok","ResourceCounts":[{{"Name":"Sub A","Id":"{0}","Count":1,"Zip":""}}],"Failed":[]}}' -f $script:SubA.Id)
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamSummaryJson $Json
        $Run.Console | Should -Match '\[stream-0\] ERROR: summary file .+ is not this run''s summary of stream 0: it is not from this run' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification: OK \(each of the 1 successful sub\(s\) has its zip' -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: another run sharing the inventory root keeps its summary, and its zip is not in this run''s consolidated zip' {
        # While this run's streams work, another run writes its stream 0
        # summary (under its own run id) and a report zip in the same
        # inventory root.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -OtherRun
        $Run.Console | Should -Not -Match 'Stream Summary' -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        @($Run.InnerZips | Where-Object { $_ -like '*otherrun*' }).Count | Should -Be 0 -Because ('the consolidated zip holds: ' + ($Run.InnerZips -join ', '))
        $Run.InnerZips.Count | Should -Be 2 -Because ('the consolidated zip holds: ' + ($Run.InnerZips -join ', '))
        # The other run's summary is not this run's to read or remove.
        Test-Path -LiteralPath (Join-Path $Run.Root '.rda-stream-0-99999999-0000-0000-0000-000000000000-summary.json') -PathType Leaf | Should -BeTrue
        @(Get-ChildItem -LiteralPath $Run.Root -Filter '.rda-stream-*-summary.json' -File -Force).Count | Should -Be 1 -Because 'this run removes its own summaries when it is done'
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
    }

    It 'two streams: a stream summary that is <Case> is not confirmed' -ForEach @(
        @{ Case = 'an empty object'; Json = '{}' }
        @{ Case = 'null'; Json = 'null' }
        @{ Case = 'a list'; Json = '[]' }
        @{ Case = 'without a row for every subscription the stream ran'; Json = '{"RunId":"{RunId}","StreamId":"0","Status":"ok","ResourceCounts":[],"Failed":[]}' }
    ) {
        # Stream 0 runs Sub A then Sub C.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -StreamSummaryJson $Json
        $Run.Console | Should -Match '\[stream-0\] ERROR: summary file .+ is not this run''s summary of stream 0' -Because $Run.Console
        $Run.Console | Should -Match 'Stream Summary Unreadable:\s+stream-0 \(2 subscription\(s\) not confirmed; check the consolidated zip\)' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 2 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a stream summary whose success row has <Case> is not confirmed' -ForEach @(
        @{ Case = 'a Zip that is not a path'; Row = '"Count":1,"Zip":"{Reports}/bad\u0000name.zip"' }
        @{ Case = 'a Count below 0'; Row = '"Count":-1' }
        @{ Case = 'a Count that is not a whole number'; Row = '"Count":1.5' }
        @{ Case = 'a Count that is text'; Row = '"Count":"many"' }
        @{ Case = 'no Count'; Row = '"Zip":""' }
    ) {
        # Stream 0 runs Sub A, and its summary names Sub A with this row.
        $Json = ('{{"RunId":"{{RunId}}","StreamId":"0","Status":"ok","ResourceCounts":[{{"Name":"Sub A","Id":"{0}",{1}}}],"Failed":[]}}' -f $script:SubA.Id, $Row)
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamSummaryJson $Json
        $Run.Console | Should -Match '\[stream-0\] ERROR: summary file .+ is not this run''s summary of stream 0: 1 of its success row\(s\) have a Count that is not a whole number of 0 or more, or a Zip that is not a path' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a stream summary whose <Case> is not confirmed, and the next stream is still read' -ForEach @(
        @{ Case = 'ConsumptionRecords is text'; Extra = '"ConsumptionRecords":"abc"'; Reason = 'its ConsumptionRecords is not a whole number of 0 or more' }
        @{ Case = 'ConsumptionRecords is below 0'; Extra = '"ConsumptionRecords":-1'; Reason = 'its ConsumptionRecords is not a whole number of 0 or more' }
        @{ Case = 'ConsumptionFailedSubs is not a list'; Extra = '"ConsumptionFailedSubs":{"Id":"x"}'; Reason = 'its ConsumptionFailedSubs is not a list' }
        @{ Case = 'MetricsFailedSubs is not a list'; Extra = '"MetricsFailedSubs":"x"'; Reason = 'its MetricsFailedSubs is not a list' }
        @{ Case = 'CollectorFailures row has no Id'; Extra = '"CollectorFailures":[{"Module":"m","Message":"x"}]'; Reason = '1 of its CollectorFailures row(s) have no Id' }
        @{ Case = 'Failed row has no Reason'; Extra = '"Failed":[{"Id":"x","Name":"Sub X"}]'; Reason = '1 of its failed row(s) have no Id or Reason text' }
    ) {
        # Stream 0 runs Sub A, and its summary names Sub A with a good row;
        # one other field holds a value the worker never writes. Stream 1
        # runs Sub B.
        $Json = ('{{"RunId":"{{RunId}}","StreamId":"0","Status":"ok","ResourceCounts":[{{"Name":"Sub A","Id":"{0}","Count":1,"Zip":""}}],{1}}}' -f $script:SubA.Id, $Extra)
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamSummaryJson $Json
        $Run.Console | Should -Match ('\[stream-0\] ERROR: summary file .+ is not this run''s summary of stream 0: ' + [regex]::Escape($Reason)) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; check the consolidated zip for their reports.')) -Because $Run.Console
        # Stream 1 is still read: Sub B is the one success the output
        # verification checks.
        $Run.Console | Should -Match 'Per-subscription output verification: OK \(each of the 1 successful sub\(s\) has its zip' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Subscriptions Failed:' -Because $Run.Console
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a throw while one stream''s summary is read keeps its results and still reads the next stream' {
        # Stream 0 runs Sub A (fails) then Sub C, so it writes a failures
        # log, and the wrapper cannot read that log's size. Stream 1 runs
        # Sub B.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -FailSub $script:SubA.Id -FailuresLogFail
        $Run.Console | Should -Match '\[stream-0\] ERROR processing Sub A' -Because $Run.Console
        # Sub C (stream 0) and Sub B (stream 1) both count as successes, and
        # Sub A as the one failure.
        $Run.Console | Should -Match 'Per-subscription output verification: OK \(each of the 2 successful sub\(s\) has its zip' -Because $Run.Console
        $Run.Console | Should -Match '\[stream-0\] WARNING: after its results were read: stand-in: the stream failures log cannot be read' -Because $Run.Console
        $Run.Console | Should -Match '(?m)^Subscriptions Failed:\s+1 \(Sub A \(stream-0: ' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Stream Summary' -Because 'both stream summaries were read'
        $Run.FailedIds | Should -Be @($script:SubA.Id)
        $Run.ZipCount | Should -Be 1 -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams with -Resume: a summary that names another stream is not confirmed, after the wrapper skipped what a stream state file lists as done' {
        # Stream-0's resume file says Sub A is done. The start folds it in
        # (#38), so the wrapper skips Sub A and no stream is left with
        # nothing to run; stream-0 runs Sub B and its summary names stream 1.
        $Wrong = '{"RunId":"{RunId}","StreamId":"1","Status":"ok","ResourceCounts":[],"Failed":[]}'
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -Stream0Completed @($script:SubA.Id) -StreamSummaryJson $Wrong
        $Run.Console | Should -Match 'Skipping \(already completed\): Sub A' -Because $Run.Console
        $Run.Console | Should -Match '\[stream-0\] ERROR: summary file .+ is not this run''s summary of stream 0' -Because $Run.Console
        # Sub A's report cannot be carried (the resume file records none), so
        # the run stops before the consolidated zip (ruling 1).
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 could not be read; its 1 subscription(s) are not confirmed; no consolidated zip was made.')) -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: the Stream Summary Missing line says no consolidated zip was made when none was' {
        # Both subscriptions fail, so no report is written; stream 0 also
        # writes no summary.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -FailSub @($script:SubA.Id, $script:SubB.Id) -MissingStreamSummary
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.Console | Should -Match 'No per-subscription zip files found' -Because $Run.Console
        $Run.Console | Should -Match 'Stream Summary Missing:\s+stream-0 \(1 subscription\(s\) not confirmed; no consolidated zip was made\)' -Because $Run.Console
        $Run.Console | Should -Not -Match 'check the consolidated zip' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 2: the summary of stream 0 is missing; its 1 subscription(s) are not confirmed; no consolidated zip was made.')) -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: an old stream summary the wrapper cannot remove stops the run with exit 1 before any stream starts' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamSummaryFolderBeforeRun
        $Run.Console | Should -Match 'ERROR: could not remove the old stream summary .+\.rda-stream-[0-9a-f]{8}-0-summary\.json' -Because $Run.Console
        $Run.Console | Should -Match 'Remove it by hand, then run again\.' -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Exit code 1: an old stream summary could not be removed; no subscription was collected and no consolidated zip was made.')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'queued:' -Because 'no stream may start while its old summary is still there'
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        # A setup stop before anything is collected: exit 1, not 2.
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
    }

    It '<Case>: a submodule that pins an older Az.Accounts stops the run once with exit 1, before any subscription' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'two streams'; Streams = 2 }
    ) {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams $Streams -PinnedCompute
        $Run.Console | Should -Match ([regex]::Escape('Az.Compute 99.0.0 asks for Az.Accounts 5.5.3')) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Install-Module -Name Az.Compute -Repository PSGallery -Scope CurrentUser -Force')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'Processing subscription|queued:' -Because 'no subscription may start'
        $Run.Console | Should -Not -Match 'ERROR processing' -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.StateKept | Should -BeFalse -Because 'nothing was collected, so no resume state was written'
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
    }

    It 'sequential: a resume state file that cannot be removed after a clean run gets its warning, though the error holds braces' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -ResumeRemoveFail
        $Run.Console | Should -Match ('WARNING: Could not remove the resume state file .+: ' + [regex]::Escape('stand-in: the file is in use by {another process}')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'Error formatting a string' -Because $Run.Console
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
    }

    It 'sequential: a resume state file whose removal fails with a non-terminating error (a locked file) is not called cleared, the warning says a later -Resume skips what it lists, and the next two runs clear it and then read none' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -ResumeRemoveSoftFail
        $Run.Console | Should -Match ('WARNING: Could not remove the resume state file .+: ' + [regex]::Escape('stand-in: the file is locked by another process')) -Because $Run.Console
        # #38's warning (Remove-ResumeStateFiles): the next run reads it again.
        $Run.Console | Should -Match 'The next run reads it again and retries the removal\.' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Resume state cleared \(clean run\)' -Because 'the file is still there'
        $Run.StateKept | Should -BeTrue -Because 'the removal failed'
        $Run.ExitCode | Should -Be 0 -Because $Run.Console

        # The next run, a -Resume once the lock is gone, reads the kept state
        # as kept (and says so), and its clean end clears it.
        $Next = Invoke-CarryOverRun -Subs @($script:SubA) -Resume -ReuseHome $Run.Home
        $Next.Console | Should -Match 'Resume mode: 1 previously completed subscription\(s\) will be skipped' -Because $Next.Console
        $Next.Console | Should -Match 'Resume state cleared \(clean run\)' -Because $Next.Console
        $Next.StateKept | Should -BeFalse -Because $Next.Console
        $Next.ExitCode | Should -Be 0 -Because $Next.Console

        # The run after that reads no state and runs the subscription.
        $After = Invoke-CarryOverRun -Subs @($script:SubA) -Resume -ReuseHome $Run.Home
        $After.Console | Should -Match 'Resume mode: no previous state found' -Because $After.Console
        $After.Console | Should -Match 'Processing subscription: Sub A' -Because $After.Console
        $After.ExitCode | Should -Be 0 -Because $After.Console
    }

    It 'sequential: a non-zero $LASTEXITCODE left in the session before the run fails no subscription' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -PriorExitCode 1
        $Run.Console | Should -Not -Match 'ERROR processing subscription' -Because $Run.Console
        $Run.Console | Should -Match 'Completed subscription: Sub A'
        $Run.Console | Should -Match 'Completed subscription: Sub B'
        $Run.FailedIds.Count | Should -Be 0
        $Run.ExitCode | Should -Be 0
    }

    It 'one subscription with -ParallelStreams: a non-zero $LASTEXITCODE left in the session before the run does not fail it' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -Streams 2 -PriorExitCode 1
        $Run.Console | Should -Match 'Only one'
        $Run.Console | Should -Not -Match 'ERROR processing subscription' -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0
        $Run.ExitCode | Should -Be 0
    }

    It 'one subscription with -ParallelStreams: a subscription that ends with exit 1 is still listed as failed' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA) -Streams 2 -FailSub $script:SubA.Id
        $Run.Console | Should -Match 'ERROR processing subscription Sub A: Script exited with code 1'
        $Run.FailedIds | Should -Be @($script:SubA.Id)
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'one subscription with -ParallelStreams and -ResumeFailedOnly: a retry that works clears its failure, though an earlier run marked it complete, and the next run has nothing to retry' {
        # An earlier run completed both; a later plain run failed Sub A and
        # left it in both lists. -ResumeFailedOnly narrows to Sub A, so two
        # streams run it inline.
        $Retry = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ResumeFailedOnly -SeedState ([pscustomobject]@{ Completed = @($script:SubA.Id, $script:SubB.Id); Failed = @($script:SubA.Id) })
        $Retry.Console | Should -Match 'Only one'
        $Retry.Console | Should -Not -Match 'ERROR processing subscription' -Because $Retry.Console
        # Sub B's report, completed earlier in the run, is not in this
        # -ResumeFailedOnly zip, so the run keeps the state and ends with exit 2
        # (7260548d); a -Resume puts every report into a new zip.
        $Retry.Console | Should -Match 'Not finished: -ResumeFailedOnly puts only the reports it collected into its consolidated zip' -Because $Retry.Console
        $Retry.ExitCode | Should -Be 2 -Because $Retry.Console
        $Retry.FailedIds.Count | Should -Be 0 -Because 'the retry worked, so nothing is left to retry'

        # The next -ResumeFailedOnly run, and the one after, retry nothing; Sub
        # B's report is still owed to a zip, so each ends with exit 2.
        foreach ($Next in 1..2)
        {
            $Again = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ResumeFailedOnly -ReuseHome $Retry.Home
            $Again.Console | Should -Match 'ResumeFailedOnly: no failed subscriptions in resume state' -Because $Again.Console
            $Again.Console | Should -Not -Match 'Processing subscription:' -Because $Again.Console
            $Again.Console | Should -Match 'Not finished: the run has not ended clean' -Because $Again.Console
            $Again.ExitCode | Should -Be 2 -Because $Again.Console
        }
        # The seeded state records no report for Sub B, so the way out it
        # names is -Fresh, which collects both and ends clean.
        $Done = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -Fresh -ReuseHome $Retry.Home
        $Done.ExitCode | Should -Be 0 -Because $Done.Console
        $Done.StateKept | Should -BeFalse -Because $Done.Console
    }

    It 'two streams: a subscription whose stream cannot save its failed-run count first is not collected, is named, counts nothing, and the next -Resume collects it' {
        # Stream 0 cannot write its state file, so it cannot save Sub A's
        # write-ahead count (#68): it does not collect Sub A, names it, and the
        # parent counts nothing for it.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -FailSub $script:SubA.Id -StreamStateBlocked
        $Run.Console | Should -Match '\[stream-0\] ERROR: could not save this stream''s state before collecting Sub A, so it is not collected this run' -Because $Run.Console
        $Run.Console | Should -Match '\[stream-1\] done: Sub B' -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0 -Because 'Sub A was not collected, so no failed run is counted'

        # The next -Resume collects Sub A (never completed), and it works.
        $Retry = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -Resume -ReuseHome $Run.Home
        $Retry.Console | Should -Match '(Processing subscription|done): Sub A' -Because $Retry.Console
        $Retry.Console | Should -Not -Match '(Processing subscription|done): Sub B' -Because $Retry.Console
        $Retry.ExitCode | Should -Be 0 -Because $Retry.Console
        $Retry.FailedIds.Count | Should -Be 0

        # The run after that has nothing to retry.
        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        # The run before ended clean and cleared the resume state, so there is no
        # unfinished run: -ResumeFailedOnly stops with exit 1 and collects
        # nothing (a run continues the unfinished run by default, eb328a35).
        $After.Console | Should -Match ([regex]::Escape('ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry.')) -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 1
    }

    It 'two streams: a retried subscription whose stream cannot save its failed-run count first keeps its entry as it was, and the next -ResumeFailedOnly retries it' {
        # An earlier run left Sub A and Sub B failed. Stream 0 cannot save Sub
        # A's write-ahead count (#68), so it does not collect it: its entry
        # stays as it was. Sub B works.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ResumeFailedOnly -SeedState ([pscustomobject]@{ Completed = @(); Failed = @($script:SubA.Id, $script:SubB.Id) }) -StreamStateBlocked
        $Run.Console | Should -Match 'ResumeFailedOnly: filtered to 2 previously-failed subscription' -Because $Run.Console
        $Run.Console | Should -Match '\[stream-0\] ERROR: could not save this stream''s state before collecting Sub A, so it is not collected this run' -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.FailedIds | Should -Be @($script:SubA.Id) -Because 'Sub B worked; Sub A was not collected'

        # The next run, with a folder it can write, retries Sub A, and it works.
        $Retry = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $Retry.Console | Should -Match 'ResumeFailedOnly: filtered to 1 previously-failed subscription' -Because $Retry.Console
        # The reports of the subscriptions completed earlier in the run are not in
        # this -ResumeFailedOnly zip, so it keeps the state and ends with exit 2
        # (7260548d); -Resume puts every report into a new zip.
        $Retry.Console | Should -Match 'Not finished: -ResumeFailedOnly puts only the reports it collected into its consolidated zip' -Because $Retry.Console
        $Retry.ExitCode | Should -Be 2 -Because $Retry.Console
        $Retry.FailedIds.Count | Should -Be 0

        # The next run has nothing to retry.
        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $After.Console | Should -Match 'ResumeFailedOnly: no failed subscriptions in resume state' -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 2 -Because 'the reports are still owed to a zip'
        # The way out it names, -Resume, collects nothing and ends clean.
        $Done = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -Resume -ReuseHome $Run.Home
        $Done.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $Done.Console
        $Done.ExitCode | Should -Be 0 -Because $Done.Console
        $Done.StateKept | Should -BeFalse -Because $Done.Console
    }

    # #66 removed every stream resume state file a clean run read, also when
    # the resume state could not be written, and named the kept ones with
    # "kept N stream resume state file(s)". The combined script keeps #38's
    # way (see REBUILD.md, "#66 behaviour left out"): a file whose records the
    # resume state on disk does not hold is kept and named, the run ends with
    # exit 2, and the next run reads it back. #66's summary-only file stays.
    It 'two streams: a clean run whose stream cannot write its state and whose resume state cannot be written keeps the stream resume state files, names them and ends with exit 2; the next plain run reads them back and clears them, and the run after skips nothing' {
        # Stream 0 cannot write its state file, so it does not collect Sub A
        # (its write-ahead count cannot be saved, #68); the resume state cannot
        # be written at the end of the run.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamStateBlocked -UnifiedStateBlocked
        $Run.Console | Should -Match '\[stream-0\] ERROR: could not save this stream''s state before collecting Sub A, so it is not collected this run' -Because $Run.Console
        $Run.Console | Should -Match 'WARNING: Failed to persist resume state to ' -Because $Run.Console
        $Run.Console | Should -Match "WARNING: The resume state file .+ does not hold every record of this run's per-stream files" -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -BeGreaterThan 0 -Because 'their records are on no resume state on disk'

        # The folder in the way of stream 0's state file goes, as a user would
        # fix the cause (the next run has to save the write-ahead counts).
        $Blocker = Join-Path $Run.Root ('.resume-state-{0}-stream-0.json' -f $script:TenantKey)
        if (Test-Path -LiteralPath $Blocker -PathType Container) { Remove-Item -LiteralPath $Blocker -Recurse -Force }
        # The next run, a plain one, reads them back and continues the run (a
        # run continues the unfinished run by default, eb328a35): it runs Sub
        # A, carries Sub B's report and, clean, leaves no stream resume state file.
        $Next = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ReuseHome $Run.Home
        $Next.Console | Should -Match '(Processing subscription|done): Sub A' -Because $Next.Console
        $Next.Console | Should -Match 'Skipping \(already completed\): Sub B' -Because $Next.Console
        $Next.Console | Should -Match ([regex]::Escape('Resume: carrying 1 report(s) of subscription(s) completed by an earlier run into the consolidated zip.')) -Because $Next.Console
        $Next.ExitCode | Should -Be 0 -Because $Next.Console
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 0 -Because $Next.Console

        # And the run after that, a sequential -Resume, skips neither.
        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Resume -ReuseHome $Run.Home
        $After.Console | Should -Not -Match 'Recovered per-stream state from an interrupted parallel run' -Because $After.Console
        $After.Console | Should -Match 'Processing subscription: Sub A' -Because $After.Console
        $After.Console | Should -Match 'Processing subscription: Sub B' -Because $After.Console
        $After.ExitCode | Should -Be 0 -Because $After.Console
    }

    It 'two streams: a run whose resume state cannot be written and that then stops at the zip check names the kept stream resume state files, which stay; the next run reads them back and clears them' {
        # As above (Sub A's success is only in stream 0's summary, and the
        # resume state cannot be written), but stream 1's summary names a
        # zip for Sub B that is not on disk, so the run stops at the zip
        # check.
        $RowB = [pscustomobject]@{ Name = $script:SubB.Name; Id = $script:SubB.Id; Count = 1; Zip = '{Reports}/SubB/ResourcesReport_gone.zip' }
        $Forged = [pscustomobject]@{ RunId = '{RunId}'; StreamId = '1'; Status = 'ok'; ResourceCounts = @($RowB); Failed = @() } | ConvertTo-Json -Depth 5
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamStateBlocked -UnifiedStateBlocked -Stream1SummaryJson $Forged
        $Run.Console | Should -Match 'WARNING: Failed to persist resume state to ' -Because $Run.Console
        $Run.Console | Should -Match 'Per-subscription output verification failed\.' -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $StreamFiles = @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force | Where-Object { $_.Name -notlike '*-stream-summary-*' })
        $Own = @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-summary-*.json' -f $script:TenantKey) -File -Force)
        $StreamFiles.Count | Should -Be 1 -Because 'stream 1 wrote its state file; stream 0 could not'
        # Stream 0 collected nothing (#68's write-ahead count could not be
        # saved), so no row is held only in the summaries.
        $Own.Count | Should -Be 0
        $Run.Console | Should -Match '\[stream-0\] ERROR: could not save this stream''s state before collecting Sub A, so it is not collected this run' -Because $Run.Console
        $Run.Console | Should -Match "WARNING: The resume state file .+ does not hold every record of this run's per-stream files" -Because $Run.Console

        # The folder in the way of stream 0's state file goes, as a user would
        # fix the cause (the next run has to save the write-ahead counts).
        $Blocker = Join-Path $Run.Root ('.resume-state-{0}-stream-0.json' -f $script:TenantKey)
        if (Test-Path -LiteralPath $Blocker -PathType Container) { Remove-Item -LiteralPath $Blocker -Recurse -Force }
        # The next run reads both back, runs every subscription and, clean,
        # clears them.
        $Next = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ReuseHome $Run.Home
        $Next.ExitCode | Should -Be 0 -Because $Next.Console
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 0 -Because $Next.Console
    }

    It 'two streams: a run whose resume state cannot be written moves aside at its start a stream resume state file it cannot parse, and keeps and names the files it read' {
        # As above, with no zip gap, and with stream 7's file from an earlier
        # run cut short: it opens but is not valid JSON, so the start moves it
        # aside (#38). Stream 1's file and the summary-only file are read, and
        # their records are on no resume state on disk, so they are kept.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -StreamStateBlocked -UnifiedStateBlocked -Stream7Unparseable
        $Stream7 = Join-Path $Run.Root ('.resume-state-{0}-stream-7.json' -f $script:TenantKey)
        $Run.Console | Should -Match 'WARNING: Failed to persist resume state to ' -Because $Run.Console
        $Run.Console | Should -Match ('WARNING: The per-stream state file {0} from an interrupted parallel run could not be read, so its records are not used' -f [regex]::Escape((Split-Path -Leaf $Stream7))) -Because $Run.Console
        Test-Path -LiteralPath $Stream7 | Should -BeFalse -Because 'it was moved aside'
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-7.json.unreadable-*' -f $script:TenantKey) -File -Force).Count | Should -Be 1
        $Run.Console | Should -Match "WARNING: The resume state file .+ does not hold every record of this run's per-stream files" -Because $Run.Console
        $Run.Console | Should -Match '\[stream-0\] ERROR: could not save this stream''s state before collecting Sub A, so it is not collected this run' -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
    }

    It 'two streams: a stream resume state file the start could not parse is moved aside; this run''s stream then writes its own, which the merge reads and keeps for the failed resume state write' {
        # Stream 0's file from an earlier run is cut short, so the start moves
        # it aside (#38). This run's stream 0 (Sub A, which fails) writes its
        # state, and the merge reads it. The resume state cannot be written,
        # so the files the merge read are kept and named.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -FailSub $script:SubA.Id -Stream0Unparseable -UnifiedStateBlocked
        $Stream0 = Join-Path $Run.Root ('.resume-state-{0}-stream-0.json' -f $script:TenantKey)
        $Run.Console | Should -Match ('WARNING: The per-stream state file {0} from an interrupted parallel run could not be read, so its records are not used' -f [regex]::Escape((Split-Path -Leaf $Stream0))) -Because 'the start could not parse it'
        $Run.Console | Should -Match 'WARNING: Failed to persist resume state to ' -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        @((Get-Content -LiteralPath $Stream0 -Raw | ConvertFrom-Json).FailedAttempts.Id) | Should -Be @($script:SubA.Id) -Because 'stream 0 wrote its own state after the cut file was moved aside'
        $Run.Console | Should -Match "WARNING: The resume state file .+ does not hold every record of this run's per-stream files" -Because $Run.Console
    }

    It 'sequential: the start reads a kept stream resume state file that holds [null] in its failures, from a stream where every subscription worked, as no failure' {
        $Json = '{{"Tenant":"{0}","StreamId":"1","Completed":["{1}"],"FailedAttempts":[null]}}' -f $script:Tenant, $script:SubB.Id
        # The start folds the stream resume state files in on -Resume or
        # -ResumeFailedOnly (#38). The [null] entry is no failure, so
        # -ResumeFailedOnly has nothing to retry.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Stream1StateJson $Json -ResumeFailedOnly
        $Run.Console | Should -Match 'Recovered per-stream state from an interrupted parallel run: 1 completed, 0 failed subscription record\(s\)\.' -Because $Run.Console
        $Run.Console | Should -Match 'ResumeFailedOnly: no failed subscriptions in resume state' -Because $Run.Console
        # Sub A was never completed, so it is named under Not Collected and the
        # run ends with exit 2 (#68).
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.FailedIds.Count | Should -Be 0
    }

    It 'two streams: a context snapshot that is cut short and cannot then be removed is named with a warning, and the run stops with exit 1' {
        # Save-AzContext writes part of the file and throws; Remove-Item on
        # that file fails with a non-terminating error. The file can hold an
        # Azure token cache, so the run must say it is still there.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -SnapshotPartialFail
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('ERROR: could not snapshot Az context for stream workers: stand-in: the disk is full')) -Because $Run.Console
        $Snapshot = @(Get-ChildItem -LiteralPath $Run.Root -Filter '.rda-stream-azcontext-*.json' -File -Force)
        $Snapshot.Count | Should -Be 1 -Because 'the removal failed, so the part of the file is still there'
        # The snapshot of each stream is removed at the end of the parallel run
        # (Remove-AzContextSnapshot), which names one it cannot remove.
        $Run.Console | Should -Match ([regex]::Escape(('WARNING: could not remove Az context snapshot at {0}: stand-in: the file is locked by another process' -f $Snapshot[0].FullName))) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('  This file contains an Azure token cache; remove it with: ')) -Because $Run.Console
        # Each stream's snapshot is written as the stream is started, after
        # its queued line, so no stream starts.
        $Run.Console | Should -Not -Match '\[stream-\d+\] starting' -Because 'no stream starts'
    }

    It 'two streams: when the resume state cannot be written, the old one is left as it was and every stream state file is kept; once it can be written, -ResumeFailedOnly retries the new failure only, and the run after has nothing to retry' {
        # An earlier run left Sub B failed. This run: Sub A fails, Sub B
        # works, and the resume state cannot be written.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -FailSub $script:SubA.Id -SeedState ([pscustomobject]@{ Completed = @(); Failed = @($script:SubB.Id) }) -UnifiedStateBlocked
        $Run.Console | Should -Match 'WARNING: Failed to persist resume state to ' -Because $Run.Console
        $Run.Console | Should -Match "WARNING: The resume state file .+ does not hold every record of this run's per-stream files" -Because $Run.Console
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        Get-Content -LiteralPath (Join-Path $Run.Root ('.resume-state-{0}.json' -f $script:TenantKey)) -Raw | Should -Match '"LastUpdated":\s*"2026-01-01T00:00:00Z"' -Because 'the old resume state is left as it was'
        $Run.FailedIds | Should -Be @($script:SubB.Id)
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Name | Sort-Object | Should -Be @(
            ('.resume-state-{0}-stream-0.json' -f $script:TenantKey), ('.resume-state-{0}-stream-1.json' -f $script:TenantKey))

        # The next run, with the disk fixed: Sub A only (Sub B worked).
        $Retry = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $Retry.Console | Should -Match 'ResumeFailedOnly: filtered to 1 previously-failed subscription' -Because $Retry.Console
        $Retry.Console | Should -Match 'Processing subscription: Sub A' -Because $Retry.Console
        $Retry.Console | Should -Not -Match 'Processing subscription: Sub B' -Because $Retry.Console
        # The reports of the subscriptions completed earlier in the run are not in
        # this -ResumeFailedOnly zip, so it keeps the state and ends with exit 2
        # (7260548d); -Resume puts every report into a new zip.
        $Retry.Console | Should -Match 'Not finished: -ResumeFailedOnly puts only the reports it collected into its consolidated zip' -Because $Retry.Console
        $Retry.ExitCode | Should -Be 2 -Because $Retry.Console
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 0 -Because 'a clean run clears the stream resume state files too'

        # The run after that has nothing to retry.
        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $After.Console | Should -Match 'ResumeFailedOnly: no failed subscriptions in resume state' -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 2 -Because 'the reports are still owed to a zip'
        # The way out it names, -Resume, collects nothing and ends clean.
        $Done = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -Resume -ReuseHome $Run.Home
        $Done.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $Done.Console
        $Done.ExitCode | Should -Be 0 -Because $Done.Console
        $Done.StateKept | Should -BeFalse -Because $Done.Console
    }

    It 'two streams: when the resume state cannot be written, and again at the start of the next -ResumeFailedOnly but not at its end, that run retries the new failure from the kept stream state files, and the run after has nothing to retry' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -FailSub $script:SubA.Id -SeedState ([pscustomobject]@{ Completed = @(); Failed = @($script:SubB.Id) }) -UnifiedStateBlocked
        $Run.ExitCode | Should -Be 2 -Because $Run.Console

        $Retry = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home -UnifiedStateBlocked
        $Retry.Console | Should -Match 'Recovered per-stream state from an interrupted parallel run' -Because $Retry.Console
        # Only the start-up write fails; the end-of-run write works, so the
        # stream state files are not kept for a failed write.
        @([regex]::Matches($Retry.Console, 'WARNING: Failed to persist resume state to ')).Count | Should -Be 1 -Because $Retry.Console
        $Retry.Console | Should -Not -Match "WARNING: The resume state file .+ does not hold every record of this run's per-stream files" -Because $Retry.Console
        $Retry.Console | Should -Match 'ResumeFailedOnly: filtered to 1 previously-failed subscription' -Because $Retry.Console
        $Retry.Console | Should -Match 'Processing subscription: Sub A' -Because $Retry.Console
        $Retry.Console | Should -Not -Match 'Processing subscription: Sub B' -Because $Retry.Console
        # The reports of the subscriptions completed earlier in the run are not in
        # this -ResumeFailedOnly zip, so it keeps the state and ends with exit 2
        # (7260548d); -Resume puts every report into a new zip.
        $Retry.Console | Should -Match 'Not finished: -ResumeFailedOnly puts only the reports it collected into its consolidated zip' -Because $Retry.Console
        $Retry.ExitCode | Should -Be 2 -Because $Retry.Console

        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home -UnifiedStateBlocked
        $After.Console | Should -Match 'ResumeFailedOnly: no failed subscriptions in resume state' -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 2 -Because 'the reports are still owed to a zip'
        # The way out it names, -Resume, collects nothing and ends clean.
        $Done = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2 -Resume -ReuseHome $Run.Home
        $Done.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $Done.Console
        $Done.ExitCode | Should -Be 0 -Because $Done.Console
        $Done.StateKept | Should -BeFalse -Because $Done.Console
    }

    It 'sequential: a plain run whose listing no longer shows a subscription drops the failure a stale stream state file held for it, and the next -ResumeFailedOnly has nothing to retry' {
        # An earlier parallel run's failure of Sub A is held only in a kept
        # stream state file. This plain run's listing shows only Sub B, which
        # works. The plain run merges the stale entry in and removes the file
        # (#38), then drops the entry of a subscription the identity no longer
        # sees (#68), so the clean run clears the state.
        $Run = Invoke-CarryOverRun -Subs @($script:SubB) -Stream1Failed $script:SubA.Id
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
        $Run.Console | Should -Match ('Dropped from the retry list: .+ \({0}\) is no longer visible to the signed-in identity' -f [regex]::Escape($script:SubA.Id)) -Because $Run.Console
        Test-Path -LiteralPath (Join-Path $Run.Root ('.resume-state-{0}-stream-1.json' -f $script:TenantKey)) -PathType Leaf | Should -BeFalse -Because $Run.Console
        $Run.StateKept | Should -BeFalse -Because 'nothing is owed, so the clean run clears the state'

        # The next -ResumeFailedOnly has nothing to retry.
        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -ResumeFailedOnly -ReuseHome $Run.Home
        # The run before ended clean and cleared the resume state, so there is no
        # unfinished run: -ResumeFailedOnly stops with exit 1 and collects
        # nothing (a run continues the unfinished run by default, eb328a35).
        $After.Console | Should -Match ([regex]::Escape('ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry.')) -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 1
    }

    It 'sequential: a plain run in which a subscription works clears its failure held in a kept stream state file, so the next -ResumeFailedOnly and the run after have nothing to retry' {
        # An earlier parallel run's failure of Sub A is held only in a kept
        # stream state file. This plain run runs Sub A, which works.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Stream1Failed $script:SubA.Id
        $Run.Console | Should -Match 'Processing subscription: Sub A' -Because $Run.Console
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
        $Run.StateKept | Should -BeFalse -Because 'a clean run clears the resume state'
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 0 -Because 'this run read the stream state file and its failure is cleared by the success'

        foreach ($Next in 1..2)
        {
            $Again = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -ResumeFailedOnly -ReuseHome $Run.Home
            # The run before ended clean and cleared the resume state, so there is no
            # unfinished run: -ResumeFailedOnly stops with exit 1 and collects
            # nothing (a run continues the unfinished run by default, eb328a35).
            $Again.Console | Should -Match ([regex]::Escape('ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry.')) -Because $Again.Console
            $Again.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $Again.Console
            $Again.ExitCode | Should -Be 1
        }
    }

    It 'two streams: a plain run whose listing no longer shows a subscription drops the failure a kept stream state file held for it, and the next -ResumeFailedOnly has nothing to retry' {
        # An earlier parallel run's failure of Sub A is held only in stream
        # 1's kept state file. This plain two-stream run's listing does not show
        # Sub A, so its entry is dropped (#68); stream 1 runs Sub C, which works.
        $Run = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -Stream1Failed $script:SubA.Id
        $Run.Console | Should -Match '\[stream-1\] done: Sub C' -Because $Run.Console
        $Run.Console | Should -Match ('Dropped from the retry list: .+ \({0}\) is no longer visible to the signed-in identity' -f [regex]::Escape($script:SubA.Id)) -Because $Run.Console
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
        $Run.StateKept | Should -BeFalse -Because 'nothing is owed, so the clean run clears the state'
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 0 -Because $Run.Console

        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        # The run before ended clean and cleared the resume state, so there is no
        # unfinished run: -ResumeFailedOnly stops with exit 1 and collects
        # nothing (a run continues the unfinished run by default, eb328a35).
        $After.Console | Should -Match ([regex]::Escape('ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry.')) -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 1
    }

    It '<Case>: a stream state file the run cannot open stops the run with exit 1 before any write, naming it and the way out; once it can be read the next -ResumeFailedOnly retries its failure, and the run after has nothing to retry' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'two streams'; Streams = 2 }
    ) {
        # An earlier run with more streams left the failure of Sub A only in
        # stream 7's state file, which this run cannot open (locked, no
        # access). Going on without it would end clean and clear the resume
        # state, so Sub A would never be retried.
        $Run = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams $Streams -Stream7FailedUnreadable $script:SubA.Id
        $Stream7 = Join-Path $Run.Root ('.resume-state-{0}-stream-7.json' -f $script:TenantKey)
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
        @([regex]::Matches($Run.Console, [regex]::Escape(('ERROR: The stream resume state file {0} exists but could not be read: ' -f $Stream7)))).Count | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match '(?i)denied' -Because 'the real read failure is named'
        $Run.Console | Should -Match ([regex]::Escape('Fix its permissions')) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('move the file away first')) -Because $Run.Console
        $Run.Console | Should -Not -Match 'Processing subscription' -Because 'the run stops before any subscription'
        $Run.Console | Should -Not -Match '\[stream-\d\]' -Because 'the run stops before any stream'
        $Run.StateKept | Should -BeFalse -Because 'the run stops before it writes the resume state'
        Test-Path -LiteralPath $Stream7 -PathType Leaf | Should -BeTrue

        # Its permissions are fixed. The next run retries Sub A only, and it
        # works.
        [System.IO.File]::SetUnixFileMode($Stream7, [System.IO.UnixFileMode]'UserRead, UserWrite')
        $Retry = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams $Streams -ResumeFailedOnly -ReuseHome $Run.Home
        $Retry.Console | Should -Match 'ResumeFailedOnly: filtered to 1 previously-failed subscription' -Because $Retry.Console
        $Retry.Console | Should -Match '(Processing subscription|done): Sub A' -Because $Retry.Console
        $Retry.Console | Should -Not -Match '(Processing subscription|done): Sub B' -Because $Retry.Console
        $Retry.Console | Should -Not -Match '(Processing subscription|done): Sub C' -Because $Retry.Console
        $Retry.ExitCode | Should -Be 0 -Because $Retry.Console
        # Sub B and Sub C were never collected, so -ResumeFailedOnly keeps the
        # state for a later -Resume to collect them, and the stream state file
        # it folded in stays with it (#38). The run after this one folds that
        # file in again and retries Sub A again: see REBUILD.md, "#66
        # behaviour left out", so that step of #66's case is left out.
        $Retry.StateKept | Should -BeTrue -Because $Retry.Console
    }

    It '<Case>: the other way out, moving the stream state file the run cannot open away, drops its records: the next run is clean, and the run after has nothing to retry' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'two streams'; Streams = 2 }
    ) {
        $Run = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams $Streams -Stream7FailedUnreadable $script:SubA.Id
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
        $Stream7 = Join-Path $Run.Root ('.resume-state-{0}-stream-7.json' -f $script:TenantKey)
        $Moved = Join-Path $Run.Home 'moved-stream-7.json'
        [System.IO.File]::Move($Stream7, $Moved)

        $Next = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams $Streams -ReuseHome $Run.Home
        $Next.Console | Should -Not -Match 'could not be read' -Because $Next.Console
        $Next.ExitCode | Should -Be 0 -Because $Next.Console
        $Next.StateKept | Should -BeFalse -Because 'a clean run clears the resume state'

        $After = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams $Streams -ResumeFailedOnly -ReuseHome $Run.Home
        # The run before ended clean and cleared the resume state, so there is no
        # unfinished run: -ResumeFailedOnly stops with exit 1 and collects
        # nothing (a run continues the unfinished run by default, eb328a35).
        $After.Console | Should -Match ([regex]::Escape('ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry.')) -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 1
        Test-Path -LiteralPath $Moved -PathType Leaf | Should -BeTrue -Because 'the moved file is left as it is'
        [System.IO.File]::SetUnixFileMode($Moved, [System.IO.UnixFileMode]'UserRead, UserWrite')
    }

    It 'two streams: a stream state file that cannot be opened when the streams are done stops the run with exit 1 before the resume state is written; once it can be read the next -ResumeFailedOnly retries its failure, and the run after has nothing to retry' {
        # Stream 7's state file, holding Sub A's failure, appears after this
        # run's start read the stream files, and cannot be opened.
        $Run = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -Stream7LockedDuringRun $script:SubA.Id
        $Stream7 = Join-Path $Run.Root ('.resume-state-{0}-stream-7.json' -f $script:TenantKey)
        $Run.Console | Should -Match '\[stream-1\] done: Sub C' -Because $Run.Console
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
        @([regex]::Matches($Run.Console, [regex]::Escape(('ERROR: The stream resume state file {0} exists but could not be read: ' -f $Stream7)))).Count | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('no consolidated zip was made')) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('Fix its permissions')) -Because $Run.Console
        # The file holds only this run's start record (Write-StartOfRunId, written
        # as collection starts): the run stops before it writes any record of it.
        $StartOnly = Get-Content -LiteralPath (Join-Path $Run.Root ('.resume-state-{0}.json' -f $script:TenantKey)) -Raw | ConvertFrom-Json
        @($StartOnly.CompletedSubscriptionIds | Where-Object { $_ }) | Should -BeNullOrEmpty -Because 'the run stops before it writes the resume state'
        @($StartOnly.FailedAttempts | Where-Object { $_ }) | Should -BeNullOrEmpty -Because 'the run stops before it writes the resume state'
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 3 -Because 'every stream state file is kept: this run''s two hold its records'
        @(Get-ChildItem -LiteralPath $Run.Root -Filter '.rda-stream-azcontext-*' -Force).Count | Should -Be 0 -Because 'the context snapshot is still removed'

        # Its permissions are fixed. The next run reads every stream state
        # file at its start and retries Sub A only, and it works.
        [System.IO.File]::SetUnixFileMode($Stream7, [System.IO.UnixFileMode]'UserRead, UserWrite')
        $Retry = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $Retry.Console | Should -Match 'ResumeFailedOnly: filtered to 1 previously-failed subscription' -Because $Retry.Console
        $Retry.Console | Should -Match 'Processing subscription: Sub A' -Because $Retry.Console
        $Retry.Console | Should -Not -Match '(Processing subscription|done): Sub B' -Because $Retry.Console
        $Retry.Console | Should -Not -Match '(Processing subscription|done): Sub C' -Because $Retry.Console
        # The reports of Sub B and Sub C, completed earlier in the run, are not
        # in this -ResumeFailedOnly zip, so the run keeps the state and ends
        # with exit 2 (7260548d).
        $Retry.Console | Should -Match 'Not finished: -ResumeFailedOnly puts only the reports it collected into its consolidated zip' -Because $Retry.Console
        $Retry.ExitCode | Should -Be 2 -Because $Retry.Console
        $Retry.FailedIds.Count | Should -Be 0 -Because 'the retry worked'
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 0 -Because 'that run read the stream state files, so they are cleared'

        # The run after that has nothing to retry; the reports are still owed.
        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $After.Console | Should -Match 'ResumeFailedOnly: no failed subscriptions in resume state' -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 2 -Because $After.Console
        # The way out it names, -Resume, collects nothing and ends clean.
        $Done = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -ReuseHome $Run.Home
        $Done.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $Done.Console
        $Done.ExitCode | Should -Be 0 -Because $Done.Console
        $Done.StateKept | Should -BeFalse -Because $Done.Console
    }

    It 'two streams: when a stream state file cannot be opened when the streams are done, the failure of a stream that could not start (held only in its summary) is written to the resume state before the stop, so the next -ResumeFailedOnly retries it, and the run after has nothing to retry' {
        # Stream 1 (Sub C) cannot import the context, so Sub C's failure is
        # only in stream 1's summary: it writes no stream state file. Stream
        # 7's state file, holding Sub A's failure, appears while the streams
        # run and cannot be opened.
        $Run = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -ImportFailStream '1' -Stream7LockedDuringRun $script:SubA.Id
        $Stream7 = Join-Path $Run.Root ('.resume-state-{0}-stream-7.json' -f $script:TenantKey)
        $Run.Console | Should -Match '\[stream-0\] done: Sub B' -Because $Run.Console
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
        @([regex]::Matches($Run.Console, [regex]::Escape(('ERROR: The stream resume state file {0} exists but could not be read: ' -f $Stream7)))).Count | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('and in the resume state, but no consolidated zip was made')) -Because $Run.Console
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Run.StateKept | Should -BeTrue -Because 'the rows only a stream summary held are written before the stop'
        $Run.FailedIds | Should -Be @($script:SubC.Id) -Because 'the failure of the stream that could not start is not lost'
        Test-Path -LiteralPath $Stream7 -PathType Leaf | Should -BeTrue -Because 'the file that could not be opened is kept'

        # While it still cannot be opened, the next run stops at its start
        # and writes nothing over the saved failure.
        $Blocked = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $Blocked.ExitCode | Should -Be 1 -Because $Blocked.Console
        $Blocked.Console | Should -Not -Match 'Processing subscription' -Because $Blocked.Console
        $Blocked.FailedIds | Should -Be @($script:SubC.Id) -Because $Blocked.Console

        # Its permissions are fixed. The next run reads it at its start and
        # retries Sub A and Sub C only, and both work.
        [System.IO.File]::SetUnixFileMode($Stream7, [System.IO.UnixFileMode]'UserRead, UserWrite')
        $Retry = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $Retry.Console | Should -Match 'ResumeFailedOnly: filtered to 2 previously-failed subscription' -Because $Retry.Console
        $Retry.Console | Should -Match '(Processing subscription|done): Sub A' -Because $Retry.Console
        $Retry.Console | Should -Match '(Processing subscription|done): Sub C' -Because $Retry.Console
        $Retry.Console | Should -Not -Match '(Processing subscription|done): Sub B' -Because $Retry.Console
        @($Retry.FailedIds) | Should -BeNullOrEmpty -Because $Retry.Console
        # Sub B's completion from the first run is kept (its per-stream file
        # survives the stop above), and its report is in no consolidated zip
        # yet: this -ResumeFailedOnly zip holds only what it collected, so it
        # keeps the state and ends with exit 2 (7260548d); -Resume puts every
        # report into a new zip.
        $Retry.Console | Should -Match ([regex]::Escape('Not finished: -ResumeFailedOnly puts only the reports it collected into its consolidated zip, so the reports of 1 subscription(s) completed earlier in this run are not in it')) -Because $Retry.Console
        $Retry.ExitCode | Should -Be 2 -Because $Retry.Console
        $Retry.StateKept | Should -BeTrue -Because 'the report of Sub B is still owed to a zip'
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 0

        # The run after that has nothing to retry.
        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $After.Console | Should -Match 'ResumeFailedOnly: no failed subscriptions in resume state' -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 2 -Because 'the report of Sub B is still owed to a zip'
        # The way out it names, -Resume, collects nothing and ends clean.
        $Done = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -ReuseHome $Run.Home
        $Done.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $Done.Console
        $Done.ExitCode | Should -Be 0 -Because $Done.Console
        $Done.StateKept | Should -BeFalse -Because 'a clean run clears the resume state'
        # The run after the clean one has no unfinished run: -ResumeFailedOnly
        # stops with exit 1 and collects nothing (eb328a35).
        $Last = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $Last.Console | Should -Match ([regex]::Escape('ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry.')) -Because $Last.Console
        $Last.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $Last.Console
        $Last.ExitCode | Should -Be 1
    }

    It 'two streams: when a stream state file cannot be opened when the streams are done and the resume state cannot be written either, the stream summaries are kept, the stop names the subscription of the stream that could not start and says a plain run runs it; that run does, and the run after has nothing to retry' {
        # As above (Sub C's failure is only in stream 1's summary, stream 7's
        # state file cannot be opened), and the write of Sub C's failure to
        # the resume state fails too, and so does its write to a stream
        # resume state file of its own (SummaryStateBlocked).
        $Run = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -ImportFailStream '1' -Stream7LockedDuringRun $script:SubA.Id -UnifiedStateBlocked -SummaryStateBlocked
        $Stream7 = Join-Path $Run.Root ('.resume-state-{0}-stream-7.json' -f $script:TenantKey)
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('WARNING: Failed to persist resume state')) -Because $Run.Console
        $Run.Console | Should -Not -Match ([regex]::Escape('and in the resume state, but no consolidated zip was made')) -Because 'the resume state could not be written'
        $Run.Console | Should -Match ([regex]::Escape(('{0} ({1}): failed in this run' -f $script:SubC.Name, $script:SubC.Id))) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('-ResumeFailedOnly does not retry them')) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('a plain run runs every subscription')) -Because $Run.Console
        $Run.StateKept | Should -BeFalse -Because 'the resume state could not be written'
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        Test-Path -LiteralPath $Stream7 -PathType Leaf | Should -BeTrue -Because 'the file that could not be opened is kept'
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-summary-*' -f $script:TenantKey) -Force).Count | Should -Be 0 -Because 'that write failed, and leaves no temp file'
        $Kept = @(Get-ChildItem -LiteralPath $Run.Root -Filter '.rda-stream-*-summary.json' -File -Force)
        $Kept.Count | Should -Be 2 -Because 'the stream summaries are the only record of Sub C''s failure, so both are kept'
        @($Kept | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match [regex]::Escape($script:SubC.Id) }).Count | Should -Be 1 -Because 'stream 1''s summary holds Sub C''s failure'
        foreach ($K in $Kept)
        {
            # Each kept summary is named, also one that holds none of the
            # unsaved rows (stream 0's), so none is said to hold them.
            $Run.Console | Should -Match ([regex]::Escape(('The stream summary {0} is kept; no run reads it.' -f $K.FullName))) -Because $Run.Console
        }
        $Run.Console | Should -Not -Match 'that holds them' -Because 'stream 0''s summary holds none of the unsaved rows'

        # While it still cannot be opened, the next plain run stops at its
        # start, before any subscription.
        $Blocked = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ReuseHome $Run.Home
        $Blocked.ExitCode | Should -Be 1 -Because $Blocked.Console
        $Blocked.Console | Should -Not -Match 'Processing subscription' -Because $Blocked.Console
        $Blocked.StateKept | Should -BeFalse -Because $Blocked.Console

        # Its permissions are fixed. The plain run the stop named continues the
        # run (a run continues the unfinished run by default, eb328a35): it runs
        # Sub A and Sub C, carries the report of Sub B, completed in the kept
        # stream state file, and all work.
        [System.IO.File]::SetUnixFileMode($Stream7, [System.IO.UnixFileMode]'UserRead, UserWrite')
        $Plain = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ReuseHome $Run.Home
        $Plain.Console | Should -Match '(Processing subscription|done): Sub A' -Because $Plain.Console
        $Plain.Console | Should -Match 'Skipping \(already completed\): Sub B' -Because $Plain.Console
        $Plain.Console | Should -Match ([regex]::Escape('Resume: carrying 1 report(s) of subscription(s) completed by an earlier run into the consolidated zip.')) -Because $Plain.Console
        $Plain.Console | Should -Match '(Processing subscription|done): Sub C' -Because $Plain.Console
        $Plain.ExitCode | Should -Be 0 -Because $Plain.Console
        $Plain.StateKept | Should -BeFalse -Because 'a clean run clears the resume state'
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $Run.Root -Filter '.rda-stream-*-summary.json' -File -Force).Count | Should -Be 2 -Because 'no run reads or removes the kept summaries: the stop says to remove them'

        # The run after that has nothing to retry.
        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        # The run before ended clean and cleared the resume state, so there is no
        # unfinished run: -ResumeFailedOnly stops with exit 1 and collects
        # nothing (a run continues the unfinished run by default, eb328a35).
        $After.Console | Should -Match ([regex]::Escape('ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry.')) -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 1
    }

    It 'two streams: when a stream state file cannot be opened when the streams are done and the resume state cannot be written either, the failure of the stream that could not start goes to a stream resume state file of its own and the summaries are removed; once the file can be opened the next -ResumeFailedOnly retries it, and the run after has nothing to retry' {
        # As above (Sub C's failure is only in stream 1's summary, stream 7's
        # state file, holding Sub A's failure, cannot be opened, and the
        # resume state cannot be written), but the stream resume state file
        # for the summary-only rows can be written.
        $Run = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -ImportFailStream '1' -Stream7LockedDuringRun $script:SubA.Id -UnifiedStateBlocked
        $Stream7 = Join-Path $Run.Root ('.resume-state-{0}-stream-7.json' -f $script:TenantKey)
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('WARNING: Failed to persist resume state')) -Because $Run.Console
        $Run.StateKept | Should -BeFalse -Because 'the resume state could not be written'
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
        $Own = @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-summary-*.json' -f $script:TenantKey) -File -Force)
        $Own.Count | Should -Be 1 -Because $Run.Console
        $Held = Get-Content -LiteralPath $Own[0].FullName -Raw | ConvertFrom-Json
        @($Held.FailedAttempts | ForEach-Object { [string]$_.Id }) | Should -Be @($script:SubC.Id)
        $Run.Console | Should -Match ([regex]::Escape(('were written to the stream resume state file {0}; the next run reads it at its start' -f $Own[0].FullName))) -Because $Run.Console
        $Run.Console | Should -Not -Match ([regex]::Escape('-ResumeFailedOnly does not retry them')) -Because $Run.Console
        @(Get-ChildItem -LiteralPath $Run.Root -Filter '.rda-stream-*-summary.json' -File -Force).Count | Should -Be 0 -Because 'their rows are held in that file'
        Test-Path -LiteralPath $Stream7 -PathType Leaf | Should -BeTrue -Because 'the file that could not be opened is kept'

        # While stream 7's file still cannot be opened, the next run stops
        # at its start, before any subscription, and keeps both files.
        $Blocked = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $Blocked.ExitCode | Should -Be 1 -Because $Blocked.Console
        $Blocked.Console | Should -Not -Match 'Processing subscription' -Because $Blocked.Console
        Test-Path -LiteralPath $Own[0].FullName -PathType Leaf | Should -BeTrue -Because $Blocked.Console

        # Its permissions are fixed: -ResumeFailedOnly retries Sub A (stream
        # 7's file) and Sub C (the file of its own), not Sub B, and all work.
        [System.IO.File]::SetUnixFileMode($Stream7, [System.IO.UnixFileMode]'UserRead, UserWrite')
        $Retry = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $Retry.Console | Should -Match '(Processing subscription|done): Sub A' -Because $Retry.Console
        $Retry.Console | Should -Match '(Processing subscription|done): Sub C' -Because $Retry.Console
        $Retry.Console | Should -Not -Match '(Processing subscription|done): Sub B' -Because $Retry.Console
        # The reports of the subscriptions completed earlier in the run are not in
        # this -ResumeFailedOnly zip, so it keeps the state and ends with exit 2
        # (7260548d); -Resume puts every report into a new zip.
        $Retry.Console | Should -Match 'Not finished: -ResumeFailedOnly puts only the reports it collected into its consolidated zip' -Because $Retry.Console
        $Retry.ExitCode | Should -Be 2 -Because $Retry.Console
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 0 -Because 'a clean run removes the stream resume state files it read, the file of its own too'

        # The run after the retry has nothing to retry.
        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $After.Console | Should -Match 'ResumeFailedOnly: no failed subscriptions in resume state' -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 2 -Because 'the reports are still owed to a zip'
        # The way out it names, -Resume, collects nothing and ends clean.
        $Done = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -Resume -ReuseHome $Run.Home
        $Done.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $Done.Console
        $Done.ExitCode | Should -Be 0 -Because $Done.Console
        $Done.StateKept | Should -BeFalse -Because $Done.Console
    }

    It 'two streams: at the end of the run, when the resume state cannot be written, the failure of a stream that could not start goes to a stream resume state file of its own, so the next -ResumeFailedOnly retries it, and the run after has nothing to retry' {
        # Sub B runs in stream 0 and works; stream 1 cannot start, so Sub C's
        # failure is only in its summary; the resume state cannot be written
        # at the end of the run.
        $Run = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -ImportFailStream '1' -UnifiedStateBlocked
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('WARNING: Failed to persist resume state')) -Because $Run.Console
        $Run.StateKept | Should -BeFalse -Because 'the resume state could not be written'
        $Own = @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-summary-*.json' -f $script:TenantKey) -File -Force)
        $Own.Count | Should -Be 1 -Because $Run.Console
        $Held = Get-Content -LiteralPath $Own[0].FullName -Raw | ConvertFrom-Json
        @($Held.FailedAttempts | ForEach-Object { [string]$_.Id }) | Should -Be @($script:SubC.Id)
        $Run.Console | Should -Match ([regex]::Escape(('were written to the stream resume state file {0}; the next run reads it at its start' -f $Own[0].FullName))) -Because $Run.Console
        @(Get-ChildItem -LiteralPath $Run.Root -Filter '.rda-stream-*-summary.json' -File -Force).Count | Should -Be 0 -Because 'their rows are held in that file'

        # The next -ResumeFailedOnly retries Sub C, not Sub B, and it works.
        $Retry = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $Retry.Console | Should -Match '(Processing subscription|done): Sub C' -Because $Retry.Console
        $Retry.Console | Should -Not -Match '(Processing subscription|done): Sub B' -Because $Retry.Console
        # The reports of the subscriptions completed earlier in the run are not in
        # this -ResumeFailedOnly zip, so it keeps the state and ends with exit 2
        # (7260548d); -Resume puts every report into a new zip.
        $Retry.Console | Should -Match 'Not finished: -ResumeFailedOnly puts only the reports it collected into its consolidated zip' -Because $Retry.Console
        $Retry.ExitCode | Should -Be 2 -Because $Retry.Console
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 0 -Because 'a clean run removes the stream resume state files it read, the file of its own too'

        # The run after the retry has nothing to retry.
        $After = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        $After.Console | Should -Match 'ResumeFailedOnly: no failed subscriptions in resume state' -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 2 -Because 'the reports are still owed to a zip'
        # The way out it names, -Resume, collects nothing and ends clean.
        $Done = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -Resume -ReuseHome $Run.Home
        $Done.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $Done.Console
        $Done.ExitCode | Should -Be 0 -Because $Done.Console
        $Done.StateKept | Should -BeFalse -Because $Done.Console
    }

    It 'two streams: at the end of the run, when neither the resume state nor the stream resume state file of its own can be written, the stream summaries are kept and the warning names the subscription they alone hold; a plain run runs it, and the run after has nothing to retry' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -ImportFailStream '1' -UnifiedStateBlocked -SummaryStateBlocked
        $Run.ExitCode | Should -Be 2 -Because $Run.Console
        $Run.StateKept | Should -BeFalse -Because 'the resume state could not be written'
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-summary-*' -f $script:TenantKey) -Force).Count | Should -Be 0 -Because 'that write failed, and leaves no temp file'
        $Run.Console | Should -Match ([regex]::Escape(('{0} ({1}): failed in this run' -f $script:SubC.Name, $script:SubC.Id))) -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape('-ResumeFailedOnly does not retry them, so run again without -Resume and -ResumeFailedOnly')) -Because $Run.Console
        $Kept = @(Get-ChildItem -LiteralPath $Run.Root -Filter '.rda-stream-*-summary.json' -File -Force)
        $Kept.Count | Should -Be 2 -Because 'the stream summaries are the only record of Sub C''s failure, so both are kept'
        foreach ($K in $Kept)
        {
            # Each kept summary is named, also one that holds none of the
            # unsaved rows (stream 0's), so none is said to hold them.
            $Run.Console | Should -Match ([regex]::Escape(('The stream summary {0} is kept; no run reads it.' -f $K.FullName))) -Because $Run.Console
        }
        $Run.Console | Should -Not -Match 'that holds them' -Because 'stream 0''s summary holds none of the unsaved rows'

        # The plain run the warning named runs every subscription, Sub C too.
        $Plain = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -ReuseHome $Run.Home
        $Plain.Console | Should -Match '(Processing subscription|done): Sub C' -Because $Plain.Console
        $Plain.ExitCode | Should -Be 0 -Because $Plain.Console
        $Plain.StateKept | Should -BeFalse -Because 'a clean run clears the resume state'
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-*.json' -f $script:TenantKey) -File -Force).Count | Should -Be 0

        $After = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams 2 -ResumeFailedOnly -ReuseHome $Run.Home
        # The run before ended clean and cleared the resume state, so there is no
        # unfinished run: -ResumeFailedOnly stops with exit 1 and collects
        # nothing (a run continues the unfinished run by default, eb328a35).
        $After.Console | Should -Match ([regex]::Escape('ResumeFailedOnly: stopped (exit 1): there is no unfinished run to retry.')) -Because $After.Console
        $After.Console | Should -Not -Match 'Processing subscription|\[stream-\d+\] done' -Because $After.Console
        $After.ExitCode | Should -Be 1
    }

    It '<Case>: a stream state file that opens but is not valid JSON is named once in a warning, saying its records are not used, and is moved aside' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'two streams'; Streams = 2 }
    ) {
        # The two-stream run reads the stream state files at its start and
        # again in its end-of-run merge; the warning is printed once.
        $Run = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams $Streams -Stream7Unparseable
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
        $Stream7 = Join-Path $Run.Root ('.resume-state-{0}-stream-7.json' -f $script:TenantKey)
        # #38's warning (Move-UnreadableStreamStateFile).
        $Warning = 'WARNING: The per-stream state file {0} from an interrupted parallel run could not be read, so its records are not used' -f (Split-Path -Leaf $Stream7)
        @([regex]::Matches($Run.Console, [regex]::Escape($Warning))).Count | Should -Be 1 -Because $Run.Console
        Test-Path -LiteralPath $Stream7 -PathType Leaf | Should -BeFalse
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-7.json.unreadable-*' -f $script:TenantKey) -File -Force).Count | Should -Be 1
    }

    It '<Case>: a resume state file the run cannot read stops the run with the read failure and is not written over, so once it can be read the next -ResumeFailedOnly retries its failure, and the run after has nothing to retry' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'two streams'; Streams = 2 }
    ) {
        # An earlier run left the failure of Sub A in the resume state, which
        # this run cannot read (locked, no access). This plain run does not
        # see Sub A.
        $Run = Invoke-CarryOverRun -Subs @($script:SubB, $script:SubC) -Streams $Streams -SeedState ([pscustomobject]@{ Completed = @(); Failed = @($script:SubA.Id) }) -UnifiedStateUnreadable
        $StatePath = Join-Path $Run.Root ('.resume-state-{0}.json' -f $script:TenantKey)
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match ([regex]::Escape(('The resume state file {0} exists but could not be read: ' -f $StatePath))) -Because $Run.Console
        $Run.Console | Should -Match '(?i)denied' -Because 'the real read failure is named'
        $Run.Console | Should -Not -Match 'different tenant' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Processing subscription' -Because 'the run stops before any subscription'
        $Run.Console | Should -Not -Match '\[stream-\d\]' -Because 'the run stops before any stream'
        $Run.FailedIds | Should -Be @($script:SubA.Id) -Because 'the saved failure is not written over'

        # The file can be read again (the lock is gone). The next run retries
        # Sub A only, and it works.
        $Retry = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams $Streams -ResumeFailedOnly -ReuseHome $Run.Home
        $Retry.Console | Should -Match 'ResumeFailedOnly: filtered to 1 previously-failed subscription' -Because $Retry.Console
        $Retry.Console | Should -Not -Match '(Processing subscription|done): Sub B' -Because $Retry.Console
        $Retry.Console | Should -Not -Match '(Processing subscription|done): Sub C' -Because $Retry.Console
        $Retry.Console | Should -Match '(Processing subscription|done): Sub A' -Because $Retry.Console
        $Retry.ExitCode | Should -Be 0 -Because $Retry.Console
        # Sub B and Sub C were never collected, so -ResumeFailedOnly keeps the
        # state for a later -Resume to collect them (#38's rule).
        $Retry.StateKept | Should -BeTrue -Because $Retry.Console

        # The run after that has nothing to retry; Sub B and Sub C are still
        # owed (Not Collected), so it ends with exit 2 (#68).
        $After = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams $Streams -ResumeFailedOnly -ReuseHome $Run.Home
        $After.Console | Should -Match 'ResumeFailedOnly: no failed subscriptions in resume state' -Because $After.Console
        $After.ExitCode | Should -Be 2
    }

    # A plain run continues the unfinished run a kept stream state file holds
    # (dc7a3098), so a new run is -Fresh.
    It '<Case>: a new run (-Fresh) skips no subscription that a kept stream state file lists as completed' -ForEach @(
        @{ Case = 'sequential'; Streams = 1; Ran = 'Processing subscription: Sub A' }
        @{ Case = 'two streams'; Streams = 2; Ran = '\[stream-0\] done: Sub A' }
    ) {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams $Streams -Stream0Completed @($script:SubA.Id) -Fresh
        $Run.Console | Should -Match $Ran -Because $Run.Console
        $Run.Console | Should -Not -Match '(?i)skipping \(already completed\)' -Because $Run.Console
        $Run.Console | Should -Not -Match '(?m)^Subscriptions Skipped:' -Because $Run.Console
        $Run.ExitCode | Should -Be 0 -Because $Run.Console
    }

    # #66 ran from a home or a tool folder whose path holds [ and ]; the
    # combined script keeps #61's stop on [ ] * or ? instead (see REBUILD.md,
    # "#66 behaviour left out"). These cases check that stop.
    It '<Case>: a home whose path holds [ and ] stops the run with exit 1 at its start, naming the folder, and leaves the kept stream state file as it was' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'two streams'; Streams = 2 }
    ) {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams $Streams -Stream1Failed $script:SubA.Id -HomeName 'u[1]' -StandInInventory
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match 'ERROR: The inventory folder .+ has \[ \] \* or \? in its path, which this script cannot use\.' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Processing subscription|\[stream-\d\] done' -Because 'the run stops before any subscription'
        @(Get-ChildItem -LiteralPath $Run.Root -Filter ('.resume-state-{0}-stream-1.json' -f $script:TenantKey) -File -Force).Count | Should -Be 1 -Because 'nothing is written or cleared'
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
    }

    It '<Case>: a copy of the tool in a folder whose name holds [ and ] stops with exit 1 at its start, naming the folder' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'two streams'; Streams = 2 }
    ) {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams $Streams -StandInInventory -BracketTool
        $Run.ExitCode | Should -Be 1 -Because $Run.Console
        $Run.Console | Should -Match 'ERROR: The script folder .+ has \[ \] \* or \? in its path, which this tool cannot run from\.' -Because $Run.Console
        $Run.Console | Should -Not -Match 'Processing subscription|\[stream-\d\] done' -Because 'the run stops before any subscription'
        $Run.ZipCount | Should -Be 0 -Because $Run.Console
    }

    # With two streams the session runs no inventory itself, so only the
    # wrapper's own exit sets $LASTEXITCODE there.
    It 'inside a PowerShell session: a clean run with 2 streams sets $LASTEXITCODE to 0 where the session held 1, and the session stays open' {
        $Session = Invoke-SessionRun -Subs @($script:SubA, $script:SubB) -Lines @('$global:LASTEXITCODE = 1', '{Run}', '"after: $LASTEXITCODE"', '"session still open"', 'exit 0')
        $Session.Console | Should -Match '2 subscription\(s\), 2 total resource\(s\), 0 empty, 0 failed'
        $Session.After | Should -Be @('after: 0') -Because $Session.Console
        $Session.Open | Should -BeTrue
        $Session.ExitCode | Should -Be 0
    }

    It 'inside a PowerShell session: after a run that stopped with exit 1, the next clean run with 2 streams reads 0' {
        # The first run finds no Az modules on the session's module path and
        # stops with exit 1 at the wrapper's module check.
        $Session = Invoke-SessionRun -Subs @($script:SubA, $script:SubB) -Lines @(
            '$Saved = $env:PSModulePath'
            '$env:PSModulePath = (New-Item -ItemType Directory -Force -Path (Join-Path $HOME "no-modules")).FullName'
            '{Run}'
            '"after1: $LASTEXITCODE"'
            '$env:PSModulePath = $Saved'
            '{Run}'
            '"after2: $LASTEXITCODE"'
            '"session still open"'
            'exit 0'
        )
        $Session.Console | Should -Match 'Required Az submodule\(s\) not found'
        $Session.After | Should -Be @('after1: 1', 'after2: 0') -Because $Session.Console
        $Session.Open | Should -BeTrue
    }

    It 'two streams: every subscription whose consumption is incomplete in one stream is named, on the console and in RunSummary.log' {
        # Stream 0 runs Sub A then Sub C, stream 1 runs Sub B; every
        # consumption page fails, so each subscription has its own row.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams 2 -ConsumptionPageFail
        $Run.Console | Should -Match 'Consumption Failures:\s+3 subscription\(s\)' -Because $Run.Console
        foreach ($Sub in @($script:SubA, $script:SubB, $script:SubC))
        {
            $Run.Console | Should -Match ('(?m)^\s*- {0} \({1}\)' -f [regex]::Escape($Sub.Name), [regex]::Escape($Sub.Id)) -Because $Run.Console
            $Run.RunSummary | Should -Match ([regex]::Escape($Sub.Id)) -Because $Run.RunSummary
        }
    }

    It 'sequential: two subscriptions with the same name whose consumption is incomplete are both named' {
        # Azure lets two subscriptions share a display name; the id tells
        # them apart.
        $Twin = [pscustomobject]@{ Id = [guid]::new(('0' * 31) + 'd').ToString(); Name = $script:SubA.Name }
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $Twin) -ConsumptionPageFail
        $Run.Console | Should -Match 'Consumption Failures:\s+2 subscription\(s\)' -Because $Run.Console
        foreach ($Sub in @($script:SubA, $Twin))
        {
            $Run.Console | Should -Match ('(?m)^\s*- {0} \({1}\)' -f [regex]::Escape($Sub.Name), [regex]::Escape($Sub.Id)) -Because $Run.Console
        }
    }

    It 'sequential: two subscriptions with the same name whose metrics were skipped for sign-in are both named' {
        $Twin = [pscustomobject]@{ Id = [guid]::new(('0' * 31) + 'd').ToString(); Name = $script:SubA.Name }
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $Twin) -MetricsTokenFail
        $Run.Console | Should -Match 'Metrics Auth Failures:\s+2 subscription\(s\)' -Because $Run.Console
        foreach ($Sub in @($script:SubA, $Twin))
        {
            $Run.Console | Should -Match ('(?m)^\s*- {0} \({1}\)' -f [regex]::Escape($Sub.Name), [regex]::Escape($Sub.Id)) -Because $Run.Console
        }
    }

    It '<Case>: consumption skipped for sign-in on every subscription is counted once per subscription, the same on the console, in RunSummary.log and in MainSummary.html' -ForEach @(
        @{ Case = 'sequential'; Streams = 1 }
        @{ Case = 'two streams'; Streams = 2 }
    ) {
        # Three subscriptions; stream 0 runs Sub A then Sub C. Each inner run
        # gets no token for the consumption phase and adds its '(auth)' row.
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $script:SubC) -Streams $Streams -ConsumptionTokenFail
        $Run.ExitCode | Should -Be 3 -Because $Run.Console
        $Run.Console | Should -Match 'Consumption Failures:\s+0 subscription\(s\)' -Because 'no subscription had a consumption failure of its own'
        $Run.Console | Should -Match 'Consumption skipped for sign-in on 3 subscription\(s\)\.' -Because $Run.Console
        $Run.RunSummary | Should -Match 'Consumption failed subs\s+: 0' -Because $Run.RunSummary
        $Run.RunSummary | Should -Match 'Consumption sign-in skipped\s+: 3 subscription\(s\)' -Because $Run.RunSummary
        $Run.MainSummary | Should -Match 'Consumption skipped for sign-in on 3 subscription\(s\)\.'
        $Run.MainSummary | Should -Not -Match 'had consumption \(billing\) issues'
    }

    It 'inside a PowerShell session: after a run whose consumption was skipped for sign-in, the next clean run reads 0 and names no consumption failure or count' {
        # The first run's consumption phase gets no token, so it records the
        # '(auth)' row and ends with exit 3. The record count it leaves is set
        # by hand to 7, as a run that collected 7 records leaves it (the
        # stand-in returns no usage rows). The second run skips consumption.
        $Session = Invoke-SessionRun -Subs @($script:SubA) -Streams 1 -ConsumptionTokenFail -Lines @(
            '{RunConsumption}'
            '"after1: $LASTEXITCODE"'
            '$Global:ConsumptionRecordCount = 7'
            '"=== second run ==="'
            # -Fresh: a run that continued the first would need its settings (-SkipConsumption is off there).
            '{Run} -Fresh'
            '"after2: $LASTEXITCODE"'
            '"session still open"'
            'exit 0'
        )
        $First, $Second = $Session.Console -split '=== second run ===', 2
        $First | Should -Match 'Consumption: SKIPPED' -Because $Session.Console
        $First | Should -Match 'Consumption Failures:' -Because $Session.Console
        $Second | Should -Match 'Completed subscription: Sub A' -Because $Session.Console
        $Second | Should -Not -Match 'Consumption Failures:' -Because 'the first run''s consumption failure is not this run''s'
        $Second | Should -Not -Match 'Consumption Records:' -Because 'the first run''s record count is not this run''s'
        $Second | Should -Not -Match 'FAILED \(auth\)' -Because $Second
        $Session.After | Should -Be @('after1: 3', 'after2: 0') -Because $Session.Console
        $Session.Open | Should -BeTrue
    }

    It 'inside a PowerShell session: a run after Remove-Module of a required Az module loads it again' {
        # The first run loads the Az modules; then one is removed from the
        # session. The next run must not take the "already loaded" shortcut.
        $Session = Invoke-SessionRun -Subs @($script:SubA) -Streams 1 -Lines @(
            '{Run}'
            '"after1: $([bool](Get-Module -Name Az.Compute))"'
            'Remove-Module -Name Az.Compute'
            '{Run}'
            '"after2: $([bool](Get-Module -Name Az.Compute))"'
            '"session still open"'
            'exit 0'
        )
        $Session.After | Should -Be @('after1: True', 'after2: True') -Because $Session.Console
        $Session.Open | Should -BeTrue
    }

    It 'pwsh -File: a clean run with 2 streams exits 0' {
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB) -Streams 2
        $Run.Console | Should -Match '\[stream-1\] done: Sub B'
        $Run.FailedIds.Count | Should -Be 0
        $Run.ExitCode | Should -Be 0
    }

    It 'inside a PowerShell session: after a run that exited 2, the next clean -Fresh run with 2 streams reads 0' {
        # The first run fails Sub A and exits 2; -Fresh then collects both
        # subscriptions again, so the run goes through the streams.
        $Session = Invoke-SessionRun -Subs @($script:SubA, $script:SubB) -Lines @(
            '$env:RDA_STANDIN_AZURE = "{Fail}"'
            '{Run}'
            '"after1: $LASTEXITCODE"'
            '$env:RDA_STANDIN_AZURE = "{Clean}"'
            '{Run} -Fresh'
            '"after2: $LASTEXITCODE"'
            '"session still open"'
            'exit 0'
        )
        $Session.Console | Should -Match 'ERROR processing Sub A: Script exited with code 1'
        $Session.After | Should -Be @('after1: 2', 'after2: 0') -Because $Session.Console
        $Session.Open | Should -BeTrue
    }

    # ResourceInventory.ps1 sets $Global:Subscriptions to every subscription of
    # the tenant, and under pwsh -File the wrapper's top level is the global
    # scope, so its own $Subscriptions is that list after the first subscription.
    It 'pwsh -File, sequential: Eligible and Processed count the subscriptions of the run, not every subscription of the tenant' {
        $SubD = [pscustomobject]@{ Id = [guid]::new(('0' * 31) + 'd').ToString(); Name = 'Sub D'; State = 'Disabled' }
        $Run = Invoke-CarryOverRun -Subs @($script:SubA, $script:SubB, $SubD)
        $Lines = @($Run.Console -split "`r?`n")
        $Lines | Should -Contain 'Subscriptions to process: 2'
        $Lines | Should -Contain 'Subscriptions Eligible:  2'
        $Lines | Should -Contain 'Subscriptions Processed: 2'
        $Summary = @($Run.RunSummary -split "`r?`n")
        $Summary | Should -Contain '  Eligible  : 2'
        $Summary | Should -Contain '  Processed : 2'
        $Run.ExitCode | Should -Be 0
    }
}

# Remove-Item fails a locked or denied file with a non-terminating error,
# which a catch never sees unless the call asks for -ErrorAction: the code
# after it then runs as if the file was gone (as "Resume state cleared" did).
# So each Remove-Item in the body of a try in the wrapper, its stream worker
# and their functions names its -ErrorAction (Stop to reach the catch, or
# SilentlyContinue where a failure is left on purpose).
Describe 'Each Remove-Item inside a try names its -ErrorAction' {
    It '<File>' -ForEach @(
        @{ File = 'Run-AllSubscriptions.ps1' }
        @{ File = 'Run-AllSubscriptions.Stream.ps1' }
        @{ File = 'Functions/RunAllSubscriptions.Functions.ps1' }
    ) {
        $Path = Join-Path (Join-Path $PSScriptRoot '..') $File
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $Missing = @()
        foreach ($Try in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true))
        {
            foreach ($Cmd in $Try.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-Item' }, $true))
            {
                $Names = @($Cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
                if (-not ($Names | Where-Object { $_ -in @('ErrorAction', 'EA') })) { $Missing += ('line {0}: {1}' -f $Cmd.Extent.StartLineNumber, $Cmd.Extent.Text) }
            }
        }
        # A nested try finds the same call twice.
        @($Missing | Select-Object -Unique) | Should -BeNullOrEmpty
    }
}
