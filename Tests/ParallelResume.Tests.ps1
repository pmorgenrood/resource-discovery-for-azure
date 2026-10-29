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
# the run is ended, the ones whose run writes no zip, and the ones after which
# the inventory root is made read-only (so a removal there fails). An interrupted run is ended by killing the wrapper's
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
if (@($Scenario.FailIds) -contains $SubscriptionID) { throw 'stand-in failure for this subscription' }
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
# end-of-run merge finds it unreadable. With Pin, a folder takes each name the
# merge could move it aside to for the next 10 minutes, so that rename fails.
if ($Scenario.CutStreamFile -and $Scenario.CutStreamFile.AfterId -eq $SubscriptionID)
{
    $Cut = $Scenario.CutStreamFile
    $Done = Join-Path $Root ('.rda-stream-{0}-summary.json' -f $Cut.Stream)
    $Deadline = (Get-Date).AddSeconds(240)
    while (-not (Test-Path -LiteralPath $Done) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 100 }
    $Target = Join-Path $Root ('.resume-state-{0}-stream-{1}.json' -f $TenantID, $Cut.Stream)
    if ($Cut.Kind -eq 'empty') { [System.IO.File]::WriteAllBytes($Target, [byte[]]@()) }
    else { $Raw = Get-Content -LiteralPath $Target -Raw; Set-Content -LiteralPath $Target -Value $Raw.Substring(0, [int]($Raw.Length / 2)) -NoNewline -Encoding utf8 }
    if ($Cut.Pin)
    {
        $Now = [datetime]::UtcNow
        foreach ($Second in 0..600) { New-Item -ItemType Directory -Force -Path ('{0}.unreadable-{1}' -f $Target, $Now.AddSeconds($Second).ToString('yyyyMMdd-HHmmss')) | Out-Null }
    }
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
function Import-AzContext { [CmdletBinding()] param($Path) if ((Get-RdaStandInScenario).StreamStartFails) { throw 'stand-in: the context snapshot cannot be imported' }; Get-RdaStandInContext }
function Save-AzContext { [CmdletBinding()] param($Path, [switch]$Force) Set-Content -LiteralPath $Path -Value '{}' }
function Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
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

    # A fresh home (its InventoryReports folder is the run's inventory root) and
    # scenario for each test.
    function script:New-Case
    {
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseHome -Force | Out-Null
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        $script:State = Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Tenant)
    }

    # The scenario: subscriptions by letter, and which of them fail, hang or are disabled.
    function script:Set-Scenario
    {
        param([string[]]$Subs, [string[]]$Fail = @(), [string[]]$Hang = @(), [string[]]$Disabled = @(), [string[]]$NoZip = @(), [string[]]$ReadOnlyAfter = @(), [switch]$LoseZipOnFold, [switch]$StreamStartFails, [string]$CutAfter, [int]$CutStream = 1, [string]$CutKind = 'cut short', [switch]$PinCut)
        $Id = { param($L) $script:Subs[$L].Id }
        [pscustomobject]@{
            Tenant        = $script:Tenant
            Subscriptions = @($Subs | ForEach-Object { [pscustomobject]@{ Id = $script:Subs[$_].Id; Name = $script:Subs[$_].Name; State = $(if ($Disabled -contains $_) { 'Disabled' } else { 'Enabled' }) } })
            FailIds       = @($Fail | ForEach-Object { & $Id $_ })
            HangIds       = @($Hang | ForEach-Object { & $Id $_ })
            NoZipIds      = @($NoZip | ForEach-Object { & $Id $_ })
            ReadOnlyAfterIds = @($ReadOnlyAfter | ForEach-Object { & $Id $_ })
            LoseZipOnFold = [bool]$LoseZipOnFold
            StreamStartFails = [bool]$StreamStartFails
            CutStreamFile = $(if ($CutAfter) { [pscustomobject]@{ AfterId = (& $Id $CutAfter); Stream = $CutStream; Kind = $CutKind; Pin = [bool]$PinCut } } else { $null })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One run of the wrapper as its own process, stdin closed. -Streams 0 leaves
    # -ParallelStreams out, so the run picks the automatic value. -EndWhen is
    # polled while the run is going; once it is true the process tree is killed,
    # as when a session ends. A run that has not ended after $TimeoutSeconds is
    # stopped and the test fails.
    function script:Invoke-Wrapper
    {
        param([string[]]$Arguments = @(), [int]$Streams = 1, [hashtable]$Environment = @{}, [scriptblock]$EndWhen, [int]$TimeoutSeconds = 300)
        $All = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper, '-TenantID', $script:Tenant)
        if ($Streams -gt 0) { $All += @('-ParallelStreams', [string]$Streams) }
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($Arg in @($All) + @($Arguments)) { $Info.ArgumentList.Add($Arg) }
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
            throw ('The wrapper run did not end within {0} seconds.' -f $TimeoutSeconds)
        }
        $Proc.WaitForExit()
        if ($EndWhen -and -not $Ended) { throw 'The run ended before the point at which the test ends it.' }
        $Text = @(([string]$Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        return [pscustomobject]@{ ExitCode = $Proc.ExitCode; Text = $Text; Error = [string]$Err.Result }
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
    function script:Get-StreamWarningLines { param($Run) @($Run.Text | Where-Object { $_ -like 'WARNING: The per-stream state file*' }) }
    function script:Test-CleanLine { param($Run) @($Run.Text | Where-Object { $_ -eq 'Resume state cleared (clean run).' }).Count -eq 1 }
    function script:Get-Ids { param([string[]]$Letters) @($Letters | ForEach-Object { $script:Subs[$_].Id } | Sort-Object) }
    # The ids the resume state lists as completed, split where an id was joined
    # onto the one before it, or none when there is no state.
    function script:Get-StateCompleted { $S = script:Read-State; if ($null -eq $S) { return @() } @($S.Completed | ForEach-Object { [regex]::Matches([string]$_, 'sub-[a-f]') | ForEach-Object { $_.Value } } | Sort-Object -Unique) }

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

    # The per-stream state an interrupted parallel run leaves, written directly
    # (no run is started and ended): for each stream number, the letters it
    # completed, each with its report folder and zip as the stand-in writes them.
    # -Name sets the file name of one stream (a stream number of any length).
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
    # A stream file name too long to take the '.unreadable-<time>' or
    # '.stranded-<time>' suffix (a file name holds at most 255 bytes), so the
    # rename that moves it aside fails.
    $script:LongStreamName = '.resume-state-{0}-stream-{1}.json' -f $script:Tenant, ('9' * 185)

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
}

AfterAll {
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'Parallel -Resume collects only what no earlier run completed' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

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

Describe 'A one-stream run that clears the resume state deletes the per-stream files it folded in' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

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

        # Run 2 recovers nothing: -Resume skips nothing, -ResumeFailedOnly has nothing to retry.
        $R2 = script:Invoke-Wrapper -Arguments $Next -Streams 1
        script:Get-RecoveryLines $R2 | Should -BeNullOrEmpty
        $R2.Text | Should -Not -Contain 'Skipping (already completed): Sub A (sub-a)'
        if ($Next -eq '-Resume')
        {
            script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B', 'C', 'D')
            script:Test-CleanLine $R2 | Should -BeTrue
        }
        else
        {
            $R2.Text | Should -Contain 'ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry.'
            script:Get-Collected $R2 | Should -BeNullOrEmpty
        }
        $R2.ExitCode | Should -Be 0
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
        # The resume state is written through <state>.tmp; a folder of that name
        # (not empty) makes every write of it fail.
        $Block = $script:State + '.tmp'
        New-Item -ItemType Directory -Path $Block -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Block 'keep') -Value 'x'

        # Run 1: B fails again, so the state would be kept, but it cannot be written.
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D' -Fail 'B'
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 1
        script:Get-RecoveryLines $R1 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).')
        @($R1.Text | Where-Object { $_ -like 'WARNING: Failed to persist resume state to*' }).Count | Should -BeGreaterThan 0
        $Warning = @($R1.Text | Where-Object { $_ -like 'WARNING: The resume state file*' })
        $Warning.Count | Should -Be 1
        $Warning[0] | Should -Be ('WARNING: The resume state file .resume-state-{0}.json could not be written or read back with every record of the per-stream state files this run read at startup, so they are kept and a later -Resume reads them again: {1}' -f $script:Tenant, ($Names -join ', '))
        script:Test-CleanLine $R1 | Should -BeFalse
        @(script:Get-StreamFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $Names

        # Run 2: the state can be written again. The kept files are recovered,
        # A is skipped, B succeeds and the state clears with the files.
        Remove-Item -LiteralPath $Block -Recurse -Force
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
    AfterEach { if (Test-Path -LiteralPath $script:Root) { & chmod 755 $script:Root } }

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

        # Run 2, writable: the stream files are recovered, nothing is left to collect, everything is removed.
        & chmod 755 $script:Root
        script:Set-Scenario -Subs 'A', 'B', 'C', 'D'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-RecoveryLines $R2 | Should -Be @('Recovered per-stream state from an interrupted parallel run: 4 completed, 0 failed subscription record(s).')
        script:Get-Collected $R2 | Should -BeNullOrEmpty
        $R2.Text | Should -Contain 'Nothing left to process: every eligible subscription was completed by an earlier run.'
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

    # Deterministic: no run is ended from outside. Under -Resume the per-stream
    # files an interrupted run left are written directly and found by the
    # startup fold; without -Resume (which moves such files aside at startup)
    # the run's own stream 1 file is cut short after that stream finished, so
    # its end-of-run merge finds it.
    It 'is named, moved aside and never reported as a clean run (stream file <Kind>, run 1 <Run1>)' -ForEach @(
        @{ Kind = 'cut short'; Run1 = 'without -Resume' }
        @{ Kind = 'empty'; Run1 = 'without -Resume' }
        @{ Kind = 'cut short'; Run1 = '-Resume' }
        @{ Kind = 'empty'; Run1 = '-Resume' }
    ) {
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
            # Once B's stream has finished, C's run cuts its state file short.
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

Describe 'A per-stream state file that can be neither used nor moved aside stops the run' -Skip:(-not ($IsLinux -or $IsMacOS)) {
    BeforeEach { script:New-Case }

    # The lines of the STOPPED banner, and the command it prints.
    BeforeAll {
        function script:Get-StopLines { param($Run) @($Run.Text | Where-Object { $_ -like '*STOPPED (per-stream state file left in place)*' -or $_ -like 'The per-stream state file * and could not be moved aside, so every run would find it again.' }) }
        function script:Get-RemoveCommand { param($Run) @($Run.Text | Where-Object { $_ -like "  Remove-Item -LiteralPath '*' -Force" }) }
    }

    # Run 1 stops before collecting, run 2 stops again (never a warning and
    # going on), the printed command removes the file, and run 3 collects
    # everything and ends clean. Exit: the file is removed.
    It 'at startup (<Mode>): exit 1 with the file and the command to remove it; the next run stops again until it is removed' -ForEach @(
        @{ Mode = '-Resume'; Content = '{'; Why = 'could not be read' }
        @{ Mode = 'without -Resume'; Content = $null; Why = 'was left by an interrupted parallel run' }
    ) {
        script:New-InterruptedStreamState -Streams @{ 0 = @('A') }
        $Path = Join-Path $script:Root $script:LongStreamName
        if ($Content) { Set-Content -LiteralPath $Path -Value $Content -NoNewline }
        else { Copy-Item -LiteralPath (Join-Path $script:Root ('.resume-state-{0}-stream-0.json' -f $script:Tenant)) -Destination $Path }
        script:Set-Scenario -Subs 'A', 'B'
        $Arguments = @(if ($Mode -eq '-Resume') { '-Resume' })
        foreach ($Run in 1..2)
        {
            $R = script:Invoke-Wrapper -Arguments $Arguments -Streams 2
            $R.ExitCode | Should -Be 1
            script:Get-Collected $R | Should -BeNullOrEmpty
            $R.Text | Should -Contain ('The per-stream state file {0} {1} and could not be moved aside, so every run would find it again.' -f $Path, $Why)
            script:Get-RemoveCommand $R | Should -Be @("  Remove-Item -LiteralPath '{0}' -Force" -f $Path)
            Test-Path -LiteralPath $Path | Should -BeTrue
        }
        & $script:Pwsh -NoProfile -NonInteractive -Command (@(script:Get-RemoveCommand $R)[0]).Trim()
        Test-Path -LiteralPath $Path | Should -BeFalse

        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        $R3.ExitCode | Should -Be 0
        script:Get-StopLines $R3 | Should -BeNullOrEmpty
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
    }

    It 'at the end-of-run merge: exit 1 with the file and the command; the next run stops at startup until it is removed, then ends clean' {
        # 2 streams over A, B and C: stream 0 holds A and C, stream 1 holds B.
        # Once B's stream has finished, C's run cuts its state file short, and
        # every name it could be moved aside to is taken.
        script:Set-Scenario -Subs 'A', 'B', 'C' -CutAfter 'C' -CutStream 1 -PinCut
        $Path = Join-Path $script:Root ('.resume-state-{0}-stream-1.json' -f $script:Tenant)
        $R1 = script:Invoke-Wrapper -Streams 2
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        $R1.ExitCode | Should -Be 1
        script:Test-CleanLine $R1 | Should -BeFalse
        $R1.Text | Should -Contain ('The per-stream state file {0} could not be read and could not be moved aside, so every run would find it again.' -f $Path)
        script:Get-RemoveCommand $R1 | Should -Be @("  Remove-Item -LiteralPath '{0}' -Force" -f $Path)

        script:Set-Scenario -Subs 'A', 'B', 'C'
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        $R2.ExitCode | Should -Be 1
        script:Get-Collected $R2 | Should -BeNullOrEmpty
        script:Get-RemoveCommand $R2 | Should -Be @("  Remove-Item -LiteralPath '{0}' -Force" -f $Path)

        & $script:Pwsh -NoProfile -NonInteractive -Command (@(script:Get-RemoveCommand $R2)[0]).Trim()
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        $R3.ExitCode | Should -Be 0
        script:Get-StopLines $R3 | Should -BeNullOrEmpty
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
    }
}

Describe 'A stream that fails to start puts its subscriptions on the retry list' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    # Each run counts one failed run per subscription; the fourth -Resume
    # skips them for the retry limit and exits 2; a run without -Resume, once
    # the cause is gone, collects them and clears the state. Exit: the retry
    # limit, then a run without -Resume.
    It 'counts each run, the retry limit ends it, and a run without -Resume clears it' {
        script:Set-Scenario -Subs 'A', 'B' -StreamStartFails
        $Attempts = { $Raw = Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json; @($Raw.FailedAttempts | Where-Object { $_ } | Sort-Object Id | ForEach-Object { '{0}={1}' -f $_.Id, $_.Attempts }) }
        $R1 = script:Invoke-Wrapper -Streams 2
        $R1.ExitCode | Should -Be 2
        (script:Read-State).Failed | Should -Be (script:Get-Ids 'A', 'B')
        & $Attempts | Should -Be @('sub-a=1', 'sub-b=1')
        # -ResumeFailedOnly has them to retry.
        $R2 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams 2
        $R2.Text | Should -Not -Contain 'Nothing to retry'
        $R2.ExitCode | Should -Be 2
        & $Attempts | Should -Be @('sub-a=2', 'sub-b=2')
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        $R3.ExitCode | Should -Be 2
        & $Attempts | Should -Be @('sub-a=3', 'sub-b=3')

        $R4 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        script:Get-Collected $R4 | Should -BeNullOrEmpty
        @($R4.Text | Where-Object { $_ -like 'Not retried: Sub A (sub-a) failed 3 runs in a row*' }).Count | Should -Be 1
        @($R4.Text | Where-Object { $_ -like 'Not retried: Sub B (sub-b) failed 3 runs in a row*' }).Count | Should -Be 1
        $R4.ExitCode | Should -Be 2
        & $Attempts | Should -Be @('sub-a=3', 'sub-b=3')

        script:Set-Scenario -Subs 'A', 'B'
        $R5 = script:Invoke-Wrapper -Streams 2
        script:Get-Collected $R5 | Should -Be (script:Get-Ids 'A', 'B')
        script:Test-CleanLine $R5 | Should -BeTrue
        script:Read-State | Should -BeNullOrEmpty
        $R5.ExitCode | Should -Be 0
    }
}

Describe 'A run without -Resume moves aside the per-stream files an interrupted run left' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    # Run 1 moves them aside (never deleted, never zipped) and keeps only the
    # newest set; runs 2 and 3 (-Resume) recover nothing from them and end clean.
    It 'run 1 moves them aside and keeps only the newest set; the next two -Resume runs recover nothing' {
        script:New-InterruptedStreamState -Streams @{ 0 = @('A'); 1 = @('B') }
        $Older = Join-Path $script:Root ('.resume-state-{0}-stream-0.json.stranded-20250101-000000' -f $script:Tenant)
        Set-Content -LiteralPath $Older -Value '{}'
        script:Set-Scenario -Subs 'A', 'B', 'C'
        $R1 = script:Invoke-Wrapper -Streams 2
        @($R1.Text | Where-Object { $_ -like 'Moved aside 2 per-stream state file(s) an interrupted parallel run left*' }).Count | Should -Be 1
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        @(script:Get-StreamFiles) | Should -BeNullOrEmpty
        $Kept = @(script:Get-StreamLikeFiles | ForEach-Object { $_.Name } | Sort-Object)
        $Kept.Count | Should -Be 2
        $Kept | ForEach-Object { $_ | Should -Match ('^\.resume-state-{0}-stream-[01]\.json\.stranded-\d{{8}}-\d{{6}}$' -f [regex]::Escape($script:Tenant)) }
        Test-Path -LiteralPath $Older | Should -BeFalse -Because 'only the newest set is kept'
        script:Test-CleanLine $R1 | Should -BeTrue
        $R1.ExitCode | Should -Be 0
        @(script:Get-ZipEntries | Where-Object { $_.Name -like '*resume-state*' -or $_.Name -like '*stranded*' }) | Should -BeNullOrEmpty

        foreach ($Run in 1..2)
        {
            $R = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
            script:Get-RecoveryLines $R | Should -BeNullOrEmpty
            $R.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
            script:Get-Collected $R | Should -Be (script:Get-Ids 'A', 'B', 'C')
            script:Test-CleanLine $R | Should -BeTrue
            @(script:Get-StreamLikeFiles | ForEach-Object { $_.Name } | Sort-Object) | Should -Be $Kept -Because 'the moved-aside set is never deleted or read'
        }
    }
}

Describe 'Read-StreamResumeStateFile, Move-UnreadableStreamStateFile and Get-ResumeStateRecordMismatch' {
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

    It 'leaves the file in place and says so when it cannot be renamed' {
        $Path = Join-Path $script:UnitDir '.resume-state-t-stream-4.json'
        Set-Content -LiteralPath $Path -Value '{' -Encoding utf8
        # A folder already has the new name, so the rename fails.
        New-Item -ItemType Directory -Path (Join-Path $script:UnitDir '.resume-state-t-stream-4.json.unreadable-20260102-030405') -Force | Out-Null
        $Out = Move-UnreadableStreamStateFile -File (Get-Item -Force -LiteralPath $Path) -Now ([datetime]'2026-01-02T03:04:05Z').ToUniversalTime() 6>&1
        $Result = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        $Result.MovedTo | Should -BeNullOrEmpty
        Test-Path -LiteralPath $Path | Should -BeTrue
        $Warning = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ })
        $Warning.Count | Should -Be 1
        $Warning[0] | Should -BeLike 'WARNING: The per-stream state file .resume-state-t-stream-4.json*could not be read, * It could not be moved aside (*), so a later * finds it again.'
        $Summary = @(Write-UnreadableStreamStateSummary -Unreadable @($Result) -StateKept $true 6>&1 | ForEach-Object { [string]$_ })
        $Summary | Should -Be @('Resume state kept, but not a clean run: the per-stream state file .resume-state-t-stream-4.json could not be read and was left in place (it could not be moved aside); its records were not used.')
    }
}

Describe 'Move-StrandedStreamStateFiles and Write-StreamStateFileStop' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    }
    BeforeEach {
        $script:UnitDir = Join-Path $script:TestBase ('unit-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:UnitDir -Force | Out-Null
    }

    It 'renames each file with the UTC time, says so, removes older moved-aside sets only, and returns the ones it cannot rename' {
        foreach ($n in 0, 1) { Set-Content -LiteralPath (Join-Path $script:UnitDir ".resume-state-t-stream-$n.json") -Value '{}' }
        Set-Content -LiteralPath (Join-Path $script:UnitDir '.resume-state-t-stream-0.json.stranded-20250101-000000') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:UnitDir '.resume-state-other-stream-0.json.stranded-20250101-000000') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:UnitDir '.resume-state-t-stream-2.json.unreadable-20250101-000000') -Value '{'
        $Long = Join-Path $script:UnitDir ('.resume-state-t-stream-{0}.json' -f ('9' * 220))
        Set-Content -LiteralPath $Long -Value '{}'
        $Files = @(Get-StreamResumeStateFiles -InventoryRoot $script:UnitDir -Tenant 't')
        $Out = @(Move-StrandedStreamStateFiles -Files $Files -InventoryRoot $script:UnitDir -Tenant 't' -Now ([datetime]'2026-01-02T03:04:05') 6>&1)
        $Lines = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ })
        $Stuck = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        $Lines | Should -Be @('Moved aside 2 per-stream state file(s) an interrupted parallel run left: this run collects every subscription again, so their records are not used. Kept as: .resume-state-t-stream-0.json.stranded-20260102-030405, .resume-state-t-stream-1.json.stranded-20260102-030405')
        $Stuck.Count | Should -Be 1
        $Stuck[0].Path | Should -Be $Long
        @(Get-ChildItem -LiteralPath $script:UnitDir -Force -File | ForEach-Object { $_.Name } | Where-Object { $_ -notlike '*-stream-999*' } | Sort-Object) | Should -Be @(
            '.resume-state-other-stream-0.json.stranded-20250101-000000'
            '.resume-state-t-stream-0.json.stranded-20260102-030405'
            '.resume-state-t-stream-1.json.stranded-20260102-030405'
            '.resume-state-t-stream-2.json.unreadable-20250101-000000'
        )
    }

    It 'names each file it cannot move and prints the command that removes it, quoted' {
        $Lines = @(Write-StreamStateFileStop -Files @([pscustomobject]@{ Name = 'x'; Path = "/inv/it's/.resume-state-t-stream-0.json" }) 6>&1 | ForEach-Object { [string]$_ })
        $Lines | Should -Contain "The per-stream state file /inv/it's/.resume-state-t-stream-0.json could not be read and could not be moved aside, so every run would find it again."
        $Lines | Should -Contain "  Remove-Item -LiteralPath '/inv/it''s/.resume-state-t-stream-0.json' -Force"
        @(Write-StreamStateFileStop -Files @() 6>&1) | Should -BeNullOrEmpty
    }
}

Describe 'The recovery line after an interrupted parallel run' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

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
