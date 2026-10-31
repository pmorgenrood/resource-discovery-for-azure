# Resume state files that are valid JSON but not the right shape.
#
#   - Get-ResumeStateShapeProblem: the one definition of the right shape of a
#     resume state record (the resume state file and the per-stream state
#     files). Records as the wrapper and the stream worker write them pass;
#     each kind of wrong value, present but invalid as well as missing, is
#     named by its field, never by a value from the file. An empty or
#     whitespace-only file (not valid JSON) is not called the wrong shape.
#   - Move-WrongShapeResumeStateFile: renames a wrong-shaped file to
#     <name>.unreadable-<UTC time> (-2, -3 and so on when that name is taken)
#     with a warning naming the file and the field, and leaves a right-shaped,
#     absent, cut-short or empty file alone.
#   - The stream worker's reader uses nothing from a wrong-shaped file, and
#     reads an empty one as before.
#   - End to end, the wrapper itself with 1 and 2 streams: a wrong-shaped resume
#     state file or per-stream state file is moved aside, a -Resume run does not
#     use its records and does not print the clean-run line, a -ResumeFailedOnly
#     run stops with exit 1 and names the command to run next, and the next run
#     ends clean with no state left and nothing on stderr. A wrong-shaped file
#     that cannot be moved aside stops the run with exit 1 and a remove command,
#     the same on the next run, and the run after that command ends clean.
#     Empty state files and the empty completed id the tool itself writes are
#     handled as before. The moved-aside file is in no zip, with and without
#     -Obfuscate.
#
# The end-to-end runs start Run-AllSubscriptions.ps1 itself as its own pwsh
# process from a copy of the tool whose ResourceInventory.ps1 is a stand-in.
# Azure is a set of stand-in Az modules, found first on the module path of that
# process (the tool signs in with Az PowerShell only), which answer from a scenario file: the
# subscriptions, the ones that fail, and whether the inventory root becomes
# read-only once the subscriptions are listed or once given reports are written.
# The stand-in collection records each call in the home folder. The process's home is a scratch folder,
# so the run writes its inventory root under it. On Windows the wrapper writes to
# C:\InventoryReports instead, so those tests do not run there.
#
# Run with: Invoke-Pester ./Tests/ResumeStateShape.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('ResumeStateShapeTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
    $script:Tenant = '12345678-1234-1234-1234-123456789012'
    $script:Pwsh = Join-Path $PSHOME 'pwsh'
    # A text only the seeded wrong-shaped files hold, to look for in the zips.
    $script:Marker = 'garbage-shape-marker-5f3a'

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
# Every call is recorded in the home folder, outside the inventory root, one
# file per call so that streams do not write the same file.
Set-Content -LiteralPath (Join-Path $HOME ('called-{0}-{1}.txt' -f $SubscriptionID, [guid]::NewGuid().ToString('N'))) -Value $SubscriptionID
if (@($Scenario.FailIds) -contains $SubscriptionID) { throw 'stand-in failure for this subscription' }
# A run of this subscription that ends without writing its zip.
if (@($Scenario.NoZipIds) -contains $SubscriptionID) { $Global:ZipOutputFile = $null; $Global:Resources = @(1); $Global:ResourceCount = 1; return }
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

    # --- Stand-in Azure ------------------------------------------------------
    # Az.Accounts answers sign-in, context, token and subscription calls, and
    # the Resource Manager paths a run reads. Every subscription can be read.
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
# Stands in for a file another program holds open: renaming a file the scenario
# lists fails, as Rename-Item does then; every other rename, and every other
# change to that file, goes through.
function Rename-Item
{
    [CmdletBinding()] param([string]$LiteralPath, [string]$Path, [string]$NewName)
    $Target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if (@((Get-RdaStandInScenario).RenameRefused) -contains (Split-Path -Path $Target -Leaf)) { throw [System.IO.IOException]::new(("The process cannot access the file '{0}' because it is being used by another process." -f $Target)) }
    Microsoft.PowerShell.Management\Rename-Item @PSBoundParameters
}
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
    # The inventory root made read-only after the run's write probe and before
    # its state check, so a rename there fails.
    if ($Scenario.ReadOnlyRoot) { & chmod 555 (Join-Path $HOME 'InventoryReports') }
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

    $script:Subs = @{}
    foreach ($Letter in 'A', 'B', 'C') { $script:Subs[$Letter] = @{ Id = ('sub-' + $Letter.ToLowerInvariant()); Name = ('Sub ' + $Letter) } }

    # A fresh home (its InventoryReports folder is the run's inventory root) and
    # scenario for each test.
    function script:New-Case
    {
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        $script:StateName = '.resume-state-{0}.json' -f $script:Tenant
        $script:State = Join-Path $script:Root $script:StateName
        $script:Stream0Name = '.resume-state-{0}-stream-0.json' -f $script:Tenant
    }

    function script:Set-Scenario
    {
        param([string[]]$Subs = @('A', 'B', 'C'), [string[]]$Fail = @(), [switch]$ReadOnlyRoot, [string[]]$RenameRefused = @(), [string[]]$NoZip = @())
        [pscustomobject]@{
            Tenant           = $script:Tenant
            Subscriptions    = @($Subs | ForEach-Object { [pscustomobject]@{ Id = $script:Subs[$_].Id; Name = $script:Subs[$_].Name; State = 'Enabled' } })
            FailIds          = @($Fail | ForEach-Object { $script:Subs[$_].Id })
            ReadOnlyRoot     = [bool]$ReadOnlyRoot
            RenameRefused    = @($RenameRefused)
            NoZipIds         = @($NoZip | ForEach-Object { $script:Subs[$_].Id })
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One run of the wrapper as its own process, stdin closed. -Streams 0 leaves
    # -ParallelStreams out, so the run picks the stream count for the host
    # (-Environment can set DOTNET_PROCESSOR_COUNT). A run that has not ended
    # after $TimeoutSeconds is stopped and the test fails.
    function script:Invoke-Wrapper
    {
        param([string[]]$Arguments = @(), [int]$Streams = 1, [hashtable]$Environment = @{}, [int]$TimeoutSeconds = 300)
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
        if (-not $Proc.WaitForExit($TimeoutSeconds * 1000))
        {
            $Proc.Kill($true)
            throw ('The wrapper run did not end within {0} seconds.' -f $TimeoutSeconds)
        }
        $Proc.WaitForExit()
        $Text = @(([string]$Out.Result -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        return [pscustomobject]@{ ExitCode = $Proc.ExitCode; Text = $Text; Error = [string]$Err.Result }
    }

    # The ids of the subscriptions a run collected, sorted.
    function script:Get-Collected
    {
        param($Run)
        @($Run.Text | ForEach-Object { if ($_ -match '^(?:\[stream-\d+\] processing \(\d+ of \d+\): |Processing subscription: ).+ \((sub-[a-z]+)\)$') { $Matches[1] } } | Sort-Object)
    }
    function script:Get-Ids { param([string[]]$Letters) @($Letters | ForEach-Object { $script:Subs[$_].Id } | Sort-Object) }
    function script:Test-CleanLine { param($Run) @($Run.Text | Where-Object { $_ -eq 'Resume state cleared (clean run).' }).Count -eq 1 }
    function script:Get-ShapeWarnings { param($Run) @($Run.Text | Where-Object { $_ -like 'WARNING: The * is not the right shape (*' }) }

    # The state files in the inventory root: the live ones, and the ones moved
    # aside (named <name>.unreadable-<yyyyMMdd-HHmmss>, -2 and so on when taken).
    function script:Get-LiveStateFiles
    {
        @(Get-ChildItem -LiteralPath $script:Root -Force -File | Where-Object { $_.Name -like '.resume-state-*.json' } | ForEach-Object { $_.Name } | Sort-Object)
    }
    function script:Get-MovedAside
    {
        @(Get-ChildItem -LiteralPath $script:Root -Force -File | Where-Object { $_.Name -match '^\.resume-state-.+\.json\.unreadable-\d{8}-\d{6}(-\d+)?$' })
    }

    # The state a test writes: the resume state file with a right-shaped
    # completed list and the given retry list, or a per-stream state file with
    # the given text.
    function script:Write-MainState
    {
        param([object]$FailedAttempts, [string[]]$Completed = @('A'), [string]$RunId)
        $Record = [pscustomobject]@{
            TenantID                 = $script:Tenant
            CompletedSubscriptionIds = @($Completed | ForEach-Object { $script:Subs[$_].Id })
            FailedAttempts           = $FailedAttempts
            LastUpdated              = (Get-Date).ToUniversalTime().ToString('o')
        }
        if ($RunId) { $Record | Add-Member -NotePropertyName 'RunId' -NotePropertyValue $RunId }
        $Record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:State -Encoding utf8
        return (Get-Content -LiteralPath $script:State -Raw)
    }
    function script:Write-StreamText
    {
        param([string]$Text, [int]$StreamId = 0)
        $Path = Join-Path $script:Root ('.resume-state-{0}-stream-{1}.json' -f $script:Tenant, $StreamId)
        Set-Content -LiteralPath $Path -Value $Text -Encoding utf8
        return (Get-Content -LiteralPath $Path -Raw)
    }
    # The lines a run prints when a wrong-shaped file cannot be moved aside.
    $script:StopStart = "  This run stops here (exit 1), before it collects any subscription or writes any resume state. It does not use the file's records and does not write over it."
    $script:StopAfter = "  This run ends with exit 1 in place of 0 and 3-5; a run that ends with exit 2 (a report is missing) keeps exit 2. It did not use the file's records and did not write over it; the rest of the run above went as usual."
    $script:MergeNotice = "  This run does not use the file's records and does not write over it. It goes on as usual and ends with exit 1 (exit 2 when a report is missing or a subscription failed), with what to do next at its end."
    $script:LaterMain = '  While the file cannot be moved aside, every later run reads it at its start and stops the same way.'
    $script:LaterStream = "  While the file cannot be moved aside, every later -Resume or -ResumeFailedOnly run reads it at its start and stops the same way. A later run without either switch that runs one stream does not use it and leaves it as it is. One that runs more streams (set by -ParallelStreams, or chosen for this host when it is not given) stops the same way, at its start when one of its streams has this file's number and otherwise at its end."
    # The automatic stream count is 2 on a host with 4 logical processors and
    # more than 5 GB of memory.
    $script:FourCpu = @{ DOTNET_PROCESSOR_COUNT = '4' }
    function script:Get-StreamCount { param($Run) foreach ($Line in $Run.Text) { if ($Line -match '^Parallelism: -ParallelStreams (\d+) \((auto|explicit)\)') { return [int]$Matches[1] } }; return 0 }
    $script:RemoveLead = '  Once the cause shown above is fixed, remove the file with this command:'
    $script:ThenSame = '  Then run the same command again.'
    $script:ThenResume = "  Then run the same command without -ResumeFailedOnly, with -Resume: the retry list then holds none of this file's entries, so -ResumeFailedOnly would not retry them."
    # The lines a run prints when a wrong-shaped file cannot be moved aside, and
    # the remove command it prints.
    function script:Get-StopLines { param($Run) @($Run.Text | Where-Object { $_ -like 'ERROR: The * is not the right shape (*), and it could not be moved aside: *' }) }
    function script:Get-RemoveCommand { param($Run) @($Run.Text | Where-Object { $_ -like "  Remove-Item -LiteralPath '*' -Force" } | ForEach-Object { $_.Trim() }) }
    # The subscriptions the stand-in collection was called for in this case, in order.
    function script:Get-Calls
    {
        @(Get-ChildItem -LiteralPath $script:CaseHome -File -Filter 'called-*.txt' | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw).Trim() } | Sort-Object)
    }
    # Name, length and hash of every file in the inventory root but the run transcripts.
    function script:Get-RootSnapshot
    {
        # The run lock is the run's own file, not run state; in a folder made
        # read-only after the write probe the run cannot remove it, and the next
        # run takes it over.
        @(Get-ChildItem -LiteralPath $script:Root -Force -Recurse -File | Where-Object { $_.Name -notlike 'RunAllSubscriptions_transcript_*' -and $_.Name -notlike '.run-lock-*' } | Sort-Object FullName | ForEach-Object { '{0} {1} {2}' -f $_.FullName.Substring($script:Root.Length), $_.Length, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
    }
    # True when a read-only folder refuses a new file here (not the case as root).
    function script:Test-ReadOnlyRefused
    {
        $Probe = Join-Path $script:CaseHome ('ro-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $Probe | Out-Null
        & chmod 555 $Probe
        $Refused = try { Set-Content -LiteralPath (Join-Path $Probe 'x') -Value 'x' -ErrorAction Stop; $false } catch { $true }
        & chmod 755 $Probe
        Remove-Item -LiteralPath $Probe -Recurse -Force
        return $Refused
    }

    function script:Write-RawText
    {
        param([string]$Path, [string]$Text)
        [System.IO.File]::WriteAllText($Path, $Text)
    }
    function script:New-RetryEntry
    {
        param([string]$Letter, $Attempts = 1, $LastFailedAt = (Get-Date).ToUniversalTime().ToString('o'))
        [pscustomobject]@{ Id = $script:Subs[$Letter].Id; Name = $script:Subs[$Letter].Name; LastFailedAt = $LastFailedAt; Reason = 'stand-in failure'; Attempts = $Attempts }
    }

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

    # The checks every run that found a wrong-shaped file passes: one warning
    # naming the file and the field, the file moved aside with its content as
    # seeded, and nothing on stderr (no conversion error from a value in it, no
    # removal of a path already moved).
    function script:Assert-MovedAside
    {
        param($Run, [string]$FileName, [string]$Field, [string]$Content)
        $Warnings = @(script:Get-ShapeWarnings $Run)
        $Warnings.Count | Should -Be 1
        $Warnings[0] | Should -BeLike ('WARNING: The *state file {0} is not the right shape ({1}*), so its records are not used. It was moved aside to {0}.unreadable-*, kept for inspection; no run reads it again.' -f $FileName, $Field)
        $Moved = @(script:Get-MovedAside)
        $Moved.Count | Should -Be 1
        $Moved[0].Name | Should -Match ('^{0}\.unreadable-\d{{8}}-\d{{6}}$' -f [regex]::Escape($FileName))
        $Warnings[0] | Should -BeLike ('* moved aside to {0}, *' -f $Moved[0].Name)
        Get-Content -LiteralPath $Moved[0].FullName -Raw | Should -Be $Content
        $Run.Error | Should -BeNullOrEmpty
        $Run.Text | Should -Not -Contain 'Resume state cleared (clean run).'
        @($Run.Text | Where-Object { $_ -like 'Pending Retries:*' }) | Should -BeNullOrEmpty
        return $Moved[0]
    }

    # The next run after it: nothing moved aside again, the clean-run line, no
    # state left, and the moved-aside file unchanged where it was.
    function script:Assert-NextRunClean
    {
        param($Run, [System.IO.FileInfo]$Moved, [string]$Content, [string[]]$Collected)
        $Run.ExitCode | Should -Be 0
        @(script:Get-ShapeWarnings $Run) | Should -BeNullOrEmpty
        script:Get-Collected $Run | Should -Be (script:Get-Ids $Collected)
        script:Test-CleanLine $Run | Should -BeTrue
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        @(script:Get-MovedAside | ForEach-Object { $_.Name }) | Should -Be @($Moved.Name)
        Get-Content -LiteralPath $Moved.FullName -Raw | Should -Be $Content
        $Run.Error | Should -BeNullOrEmpty
    }

    function script:Assert-NotInAnyZip
    {
        $Entries = @(script:Get-ZipEntries)
        $Entries.Count | Should -BeGreaterThan 0
        @($Entries | Where-Object { $_.Name -like '*resume-state*' -or $_.Name -like '*unreadable*' }) | Should -BeNullOrEmpty
        @($Entries | Where-Object { $_.Text -like ('*{0}*' -f $script:Marker) }) | Should -BeNullOrEmpty
    }

    $script:UnitDir = Join-Path $script:TestBase 'unit'
    New-Item -ItemType Directory -Path $script:UnitDir -Force | Out-Null
    function script:ConvertTo-Record { param([string]$Json) ConvertFrom-Json -InputObject $Json }
}

AfterAll {
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe 'Get-ResumeStateShapeProblem: records as the wrapper and the stream worker write them' {
    BeforeEach {
        $script:Path = Join-Path $script:UnitDir ('{0}.json' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    }

    It 'the resume state file after <Label> has the right shape' -TestCases @(
        @{ Label = 'one completed and one failed subscription'; Steps = 'ok-a,fail-b' },
        @{ Label = 'a failed first subscription (a null completed id)'; Steps = 'fail-a' },
        @{ Label = 'a failure that later succeeded (a null retry entry)'; Steps = 'fail-a,ok-a' },
        @{ Label = 'a second failure of the same subscription'; Steps = 'fail-a,fail-a' }
    ) {
        $Ids = @()
        $Failed = @()
        foreach ($Step in $Steps -split ',')
        {
            $Id = 'sub-' + $Step.Substring($Step.Length - 1)
            if ($Step -like 'ok-*') { $Ids += $Id; $Failed = Remove-FailedAttempt -Existing $Failed -Id $Id }
            else { $Failed = Add-FailedAttempt -Existing $Failed -Id $Id -Name $Id -Reason 'x' }
            Save-CompletedSubscriptionIds -Path $script:Path -Tenant 't' -Ids $(if ($Ids.Count -gt 0) { $Ids } else { $null }) -FailedAttempts $Failed
        }
        $Record = Get-Content -LiteralPath $script:Path -Raw | ConvertFrom-Json
        Get-ResumeStateShapeProblem -Record $Record -Kind Main | Should -BeNullOrEmpty
    }

    It 'a resume state file written before the retry list existed has the right shape' {
        Get-ResumeStateShapeProblem -Record (script:ConvertTo-Record '{"TenantID":"t","CompletedSubscriptionIds":["sub-a"],"LastUpdated":"2026-05-15T00:00:00Z"}') -Kind Main | Should -BeNullOrEmpty
    }

    It 'a per-stream state file as the stream worker writes it has the right shape (<Label>)' -TestCases @(
        @{ Label = 'completed and failed'; Completed = @('sub-a'); Failed = 'sub-b' },
        @{ Label = 'nothing completed yet'; Completed = @(); Failed = '' },
        @{ Label = 'written by an older worker without a retry list'; Completed = @('sub-a'); Failed = 'none' }
    ) {
        # Write-StreamState and Write-Stream read these from the caller's scope.
        Set-Variable -Name TenantID -Value 't'
        Set-Variable -Name StreamId -Value '0'
        Set-Variable -Name Tag -Value '[stream-0]'
        $List = if ($Failed -and $Failed -ne 'none') { Add-FailedAttempt -Existing @() -Id $Failed -Name $Failed -Reason 'x' } else { @() }
        Write-StreamState -Path $script:Path -Completed $Completed -FailedAttempts $List
        $Record = Get-Content -LiteralPath $script:Path -Raw | ConvertFrom-Json
        if ($Failed -eq 'none') { $Record.PSObject.Properties.Remove('FailedAttempts') }
        Get-ResumeStateShapeProblem -Record $Record -Kind Stream | Should -BeNullOrEmpty
    }

    It 'the joined id the one-id completed list writes (two ids run together) has the right shape' {
        Get-ResumeStateShapeProblem -Record (script:ConvertTo-Record '{"TenantID":"t","CompletedSubscriptionIds":["sub-asub-b"],"FailedAttempts":[]}') -Kind Main | Should -BeNullOrEmpty
        Get-ResumeStateShapeProblem -Record (script:ConvertTo-Record '{"Completed":["sub-asub-b"],"FailedAttempts":[]}') -Kind Stream | Should -BeNullOrEmpty
    }

    It 'an empty or whitespace-only completed id, which the tool writes for a null entry, has the right shape (<Kind>, <Label>)' -TestCases @(
        @{ Kind = 'Main'; Label = 'empty, beside an id'; Json = '{"TenantID":"t","CompletedSubscriptionIds":["sub-a",""]}' },
        @{ Kind = 'Main'; Label = 'whitespace only, after a null'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[null,"   "]}' },
        @{ Kind = 'Stream'; Label = 'empty'; Json = '{"Completed":[""],"FailedAttempts":[]}' },
        @{ Kind = 'Stream'; Label = 'whitespace only'; Json = '{"Completed":["sub-a"," \t "],"FailedAttempts":[]}' }
    ) {
        Get-ResumeStateShapeProblem -Record (script:ConvertTo-Record $Json) -Kind $Kind | Should -BeNullOrEmpty
    }

    It 'the resume state file Save-CompletedSubscriptionIds writes for completed ids @($null, ''sub-a'') has the right shape' {
        Save-CompletedSubscriptionIds -Path $script:Path -Tenant 't' -Ids @($null, 'sub-a') -FailedAttempts @()
        $Record = Get-Content -LiteralPath $script:Path -Raw | ConvertFrom-Json
        # [string[]] turns the null entry into an empty text.
        @($Record.CompletedSubscriptionIds) | Should -Be @('', 'sub-a')
        Get-ResumeStateShapeProblem -Record $Record -Kind Main | Should -BeNullOrEmpty
    }

    It 'an empty or whitespace-only file, read as $null, is not called the wrong shape (<Kind>, <Label>)' -TestCases @(
        @{ Kind = 'Main'; Label = '0 bytes'; Text = '' },
        @{ Kind = 'Main'; Label = 'whitespace only'; Text = "  `n`t " },
        @{ Kind = 'Stream'; Label = '0 bytes'; Text = '' },
        @{ Kind = 'Stream'; Label = 'the JSON literal null'; Text = 'null' }
    ) {
        script:Write-RawText -Path $script:Path -Text $Text
        $Record = Get-Content -LiteralPath $script:Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $Record | Should -BeNullOrEmpty
        Get-ResumeStateShapeProblem -Record $Record -Kind $Kind | Should -BeNullOrEmpty
    }

    It 'a retry entry whose Attempts is text holding a whole number, and whose LastFailedAt is a non-ISO date text, has the right shape' {
        $Record = script:ConvertTo-Record '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[null,{"Id":"sub-a","Attempts":"2","LastFailedAt":"10/29/2026 18:00:00"}]}'
        Get-ResumeStateShapeProblem -Record $Record -Kind Main | Should -BeNullOrEmpty
    }

    It 'every Attempts and LastFailedAt value it accepts converts as Add-FailedAttempt and Merge-FailedAttempts convert it' {
        foreach ($Attempts in @('1', '2', '"3"', '1.0', '2147483647'))
        {
            foreach ($When in @('"2026-10-29T18:00:00.1234567+00:00"', '"2026-10-29T18:00:00Z"', '"2026-10-29"', '"10/29/2026 18:00:00"', '"10/29/2026"', '"2026-10-29 18:00"'))
            {
                $Record = script:ConvertTo-Record ('{{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{{"Id":"sub-a","Attempts":{0},"LastFailedAt":{1}}}]}}' -f $Attempts, $When)
                Get-ResumeStateShapeProblem -Record $Record -Kind Main | Should -BeNullOrEmpty -Because ("Attempts {0}, LastFailedAt {1}" -f $Attempts, $When)
                $Entry = $Record.FailedAttempts[0]
                { [int]$Entry.Attempts } | Should -Not -Throw
                { [datetime]($Entry.LastFailedAt) } | Should -Not -Throw
                { $null = Add-FailedAttempt -Existing @($Entry) -Id 'sub-a' -Name 'a' -Reason 'x' } | Should -Not -Throw
                $Other = [pscustomobject]@{ Id = 'sub-a'; LastFailedAt = '2026-01-01T00:00:00Z'; Attempts = 1 }
                { $null = Merge-FailedAttempts -ExistingFailedAttempts @($Entry) -StreamFailedAttempts @($Other) -CompletedIds @() } | Should -Not -Throw
            }
        }
    }
}

Describe 'Get-ResumeStateShapeProblem: wrong shapes are named by their field' {
    It '<Kind> record <Label>: <Expected>' -TestCases @(
        @{ Kind = 'Main'; Label = 'a text'; Json = '"garbage-shape-marker-5f3a"'; Expected = 'it is not a JSON object' },
        @{ Kind = 'Stream'; Label = 'a number'; Json = '5'; Expected = 'it is not a JSON object' },
        @{ Kind = 'Main'; Label = 'without TenantID'; Json = '{"CompletedSubscriptionIds":[]}'; Expected = 'TenantID is not text' },
        @{ Kind = 'Main'; Label = 'with a number for TenantID'; Json = '{"TenantID":5,"CompletedSubscriptionIds":[]}'; Expected = 'TenantID is not text' },
        @{ Kind = 'Main'; Label = 'without CompletedSubscriptionIds'; Json = '{"TenantID":"t"}'; Expected = 'CompletedSubscriptionIds is missing' },
        @{ Kind = 'Main'; Label = 'with a text for CompletedSubscriptionIds'; Json = '{"TenantID":"t","CompletedSubscriptionIds":"sub-a"}'; Expected = 'CompletedSubscriptionIds is not a list' },
        @{ Kind = 'Main'; Label = 'with a number in CompletedSubscriptionIds'; Json = '{"TenantID":"t","CompletedSubscriptionIds":["sub-a",5]}'; Expected = 'CompletedSubscriptionIds holds an entry that is not a text id' },
        @{ Kind = 'Main'; Label = 'with an object in CompletedSubscriptionIds'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[{"Id":"sub-a"}]}'; Expected = 'CompletedSubscriptionIds holds an entry that is not a text id' },
        @{ Kind = 'Stream'; Label = 'with a number in Completed'; Json = '{"Completed":[5],"FailedAttempts":[]}'; Expected = 'Completed holds an entry that is not a text id' },
        @{ Kind = 'Stream'; Label = 'without Completed'; Json = '{"FailedAttempts":[]}'; Expected = 'Completed is missing' },
        @{ Kind = 'Stream'; Label = 'with a number for Completed'; Json = '{"Completed":5,"FailedAttempts":"garbage-shape-marker-5f3a"}'; Expected = 'Completed is not a list' },
        @{ Kind = 'Main'; Label = 'with a text for FailedAttempts'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":"garbage-shape-marker-5f3a"}'; Expected = 'FailedAttempts is not a list' },
        @{ Kind = 'Stream'; Label = 'with a text for FailedAttempts'; Json = '{"Completed":[],"FailedAttempts":"garbage-shape-marker-5f3a"}'; Expected = 'FailedAttempts is not a list' },
        @{ Kind = 'Main'; Label = 'with one object for FailedAttempts'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":{"Id":"sub-a","Attempts":1,"LastFailedAt":"2026-10-29T00:00:00Z"}}'; Expected = 'FailedAttempts is not a list' },
        @{ Kind = 'Main'; Label = 'with a text retry entry'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":["sub-a"]}'; Expected = 'FailedAttempts entry 1 is not an object' },
        @{ Kind = 'Main'; Label = 'with a retry entry without Id'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{"Attempts":1,"LastFailedAt":"2026-10-29T00:00:00Z"}]}'; Expected = 'FailedAttempts entry 1 has no text Id' },
        @{ Kind = 'Main'; Label = 'with an empty retry Id'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{"Id":" ","Attempts":1,"LastFailedAt":"2026-10-29T00:00:00Z"}]}'; Expected = 'FailedAttempts entry 1 has no text Id' },
        @{ Kind = 'Main'; Label = 'with a number for a retry Id'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{"Id":5,"Attempts":1,"LastFailedAt":"2026-10-29T00:00:00Z"}]}'; Expected = 'FailedAttempts entry 1 has no text Id' },
        @{ Kind = 'Main'; Label = 'with a retry entry without Attempts'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{"Id":"sub-a","LastFailedAt":"2026-10-29T00:00:00Z"}]}'; Expected = 'FailedAttempts entry 1: Attempts is not a whole number of at least 1' },
        @{ Kind = 'Main'; Label = 'with Attempts "abc"'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{"Id":"sub-a","Attempts":"abc","LastFailedAt":"2026-10-29T00:00:00Z"}]}'; Expected = 'FailedAttempts entry 1: Attempts is not a whole number of at least 1' },
        @{ Kind = 'Main'; Label = 'with Attempts 2.5'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{"Id":"sub-a","Attempts":2.5,"LastFailedAt":"2026-10-29T00:00:00Z"}]}'; Expected = 'FailedAttempts entry 1: Attempts is not a whole number of at least 1' },
        @{ Kind = 'Main'; Label = 'with Attempts 0'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{"Id":"sub-a","Attempts":0,"LastFailedAt":"2026-10-29T00:00:00Z"}]}'; Expected = 'FailedAttempts entry 1: Attempts is not a whole number of at least 1' },
        @{ Kind = 'Stream'; Label = 'with Attempts true'; Json = '{"Completed":[],"FailedAttempts":[{"Id":"sub-a","Attempts":true,"LastFailedAt":"2026-10-29T00:00:00Z"}]}'; Expected = 'FailedAttempts entry 1: Attempts is not a whole number of at least 1' },
        @{ Kind = 'Main'; Label = 'with Attempts larger than a whole number holds'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{"Id":"sub-a","Attempts":99999999999,"LastFailedAt":"2026-10-29T00:00:00Z"}]}'; Expected = 'FailedAttempts entry 1: Attempts is not a whole number of at least 1' },
        @{ Kind = 'Main'; Label = 'with a retry entry without LastFailedAt'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{"Id":"sub-a","Attempts":1}]}'; Expected = 'FailedAttempts entry 1: LastFailedAt is not a date' },
        @{ Kind = 'Main'; Label = 'with LastFailedAt "not-a-date"'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{"Id":"sub-a","Attempts":1,"LastFailedAt":"not-a-date"}]}'; Expected = 'FailedAttempts entry 1: LastFailedAt is not a date' },
        @{ Kind = 'Stream'; Label = 'with a number for LastFailedAt'; Json = '{"Completed":[],"FailedAttempts":[{"Id":"sub-a","Attempts":1,"LastFailedAt":20261029}]}'; Expected = 'FailedAttempts entry 1: LastFailedAt is not a date' },
        @{ Kind = 'Main'; Label = 'with the bad entry second, after a null'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":[{"Id":"sub-a","Attempts":1,"LastFailedAt":"2026-10-29T00:00:00Z"},null,{"Id":"sub-b","Attempts":1,"LastFailedAt":""}]}'; Expected = 'FailedAttempts entry 3: LastFailedAt is not a date' }
    ) {
        $Record = script:ConvertTo-Record $Json
        $Problem = Get-ResumeStateShapeProblem -Record $Record -Kind $Kind
        $Problem | Should -Be $Expected
        $Problem | Should -Not -BeLike ('*{0}*' -f $script:Marker)
    }
}

Describe 'Move-WrongShapeResumeStateFile' {
    BeforeEach {
        $script:Dir = Join-Path $script:UnitDir ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:Now = [datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc)
    }

    It 'renames a wrong-shaped file to its name plus .unreadable- and the UTC time, warns with the file and the field, and keeps its content' {
        $Path = Join-Path $script:Dir '.resume-state-t.json'
        $Text = '{"TenantID":"t","CompletedSubscriptionIds":[],"FailedAttempts":"' + $script:Marker + '"}'
        Set-Content -LiteralPath $Path -Value $Text -NoNewline
        $Out = @(Move-WrongShapeResumeStateFile -Path $Path -Kind Main -Now $script:Now 6>&1)
        $Result = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        $Lines = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $Result.Count | Should -Be 1
        $Result[0].Kind | Should -Be 'Main'
        $Result[0].Name | Should -Be '.resume-state-t.json'
        $Result[0].MovedTo | Should -Be '.resume-state-t.json.unreadable-20260102-030405'
        $Lines | Should -Be @('WARNING: The resume state file .resume-state-t.json is not the right shape (FailedAttempts is not a list), so its records are not used. It was moved aside to .resume-state-t.json.unreadable-20260102-030405, kept for inspection; no run reads it again.')
        Test-Path -LiteralPath $Path | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:Dir $Result[0].MovedTo) -Raw | Should -Be $Text
        # No later run finds it as a state file.
        @(Get-StreamResumeStateFiles -InventoryRoot $script:Dir -Tenant 't') | Should -BeNullOrEmpty
        $Result[0].MovedTo | Should -Not -BeLike '*.json'
    }

    It 'with -Resume, a per-stream file also says what this run does; the resume state file line comes from the wrapper later' -TestCases @(
        @{ Kind = 'Main'; Name = '.resume-state-t.json'; Json = '{"TenantID":"t","CompletedSubscriptionIds":"x"}'; Then = @() },
        @{ Kind = 'Stream'; Name = '.resume-state-t-stream-1.json'; Json = '{"Completed":5}'; Then = @('  This run does not count the subscriptions it lists as completed.') }
    ) {
        $Path = Join-Path $script:Dir $Name
        Set-Content -LiteralPath $Path -Value $Json
        $Lines = @(Move-WrongShapeResumeStateFile -Path $Path -Kind $Kind -Resume -Now $script:Now 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $Lines.Count | Should -Be (1 + @($Then).Count)
        $Lines[0] | Should -BeLike ('WARNING: The *state file {0} is not the right shape*' -f $Name)
        @($Lines | Select-Object -Skip 1) | Should -Be @($Then)
    }

    It 'Write-WrongShapeResumeLine says the run starts fresh only when no per-stream state was folded in' {
        @(Write-WrongShapeResumeLine -UsesStreamState $false 6>&1 | ForEach-Object { [string]$_.MessageData }) | Should -Be @('  Starting fresh: this run does not use the completed list or retry list of the resume state file moved aside above.')
        @(Write-WrongShapeResumeLine -UsesStreamState $true 6>&1 | ForEach-Object { [string]$_.MessageData }) | Should -Be @('  This run does not use the completed list or retry list of the resume state file moved aside above; it uses only the per-stream state recovered above.')
    }

    It 'uses the record it is given instead of reading the file' {
        $Path = Join-Path $script:Dir '.resume-state-t-stream-0.json'
        Set-Content -LiteralPath $Path -Value '{"Completed":[],"FailedAttempts":[]}'
        $Result = Move-WrongShapeResumeStateFile -Path $Path -Kind Stream -Record (script:ConvertTo-Record '{"Completed":5}') -Now $script:Now 6>$null
        $Result.MovedTo | Should -Be '.resume-state-t-stream-0.json.unreadable-20260102-030405'
    }

    It 'leaves a <Label> file alone and returns nothing' -TestCases @(
        @{ Label = 'right-shaped'; Text = '{"TenantID":"t","CompletedSubscriptionIds":["sub-a"],"FailedAttempts":[null]}' },
        @{ Label = 'cut-short (not JSON)'; Text = '{"TenantID":"t","CompletedSubscriptionIds":["sub-a"],"Fail' },
        @{ Label = '0-byte'; Text = '' },
        @{ Label = 'whitespace-only'; Text = "  `r`n `t" }
    ) {
        $Path = Join-Path $script:Dir '.resume-state-t.json'
        script:Write-RawText -Path $Path -Text $Text
        $Out = @(Move-WrongShapeResumeStateFile -Path $Path -Kind Main -Now $script:Now 6>&1)
        $Out | Should -BeNullOrEmpty
        # The same when the caller passes the record it parsed, as the fold and the merge do.
        $Parsed = $false
        try { $Record = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop; $Parsed = $true } catch { $Record = $null }
        if ($Parsed) { @(Move-WrongShapeResumeStateFile -Path $Path -Kind Main -Record $Record -Now $script:Now 6>&1) | Should -BeNullOrEmpty }
        [System.IO.File]::ReadAllText($Path) | Should -Be $Text
        @(Get-ChildItem -LiteralPath $script:Dir -Force).Count | Should -Be 1
    }

    It 'returns nothing when there is no file' {
        @(Move-WrongShapeResumeStateFile -Path (Join-Path $script:Dir '.resume-state-t.json') -Kind Main 6>&1) | Should -BeNullOrEmpty
    }

    It 'adds -2 when the name is taken, and -3 when that is taken too; the files already there are kept' {
        $Path = Join-Path $script:Dir '.resume-state-t.json'
        $Base = '.resume-state-t.json.unreadable-20260102-030405'
        Set-Content -LiteralPath (Join-Path $script:Dir $Base) -Value 'an earlier one'
        Set-Content -LiteralPath $Path -Value '{"TenantID":"t","CompletedSubscriptionIds":5}'
        $Out = @(Move-WrongShapeResumeStateFile -Path $Path -Kind Main -Now $script:Now 6>&1)
        $Result = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        $Lines = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $Result[0].MovedTo | Should -Be ($Base + '-2')
        $Lines[0] | Should -Be ('WARNING: The resume state file .resume-state-t.json is not the right shape (CompletedSubscriptionIds is not a list), so its records are not used. It was moved aside to {0}-2, kept for inspection; no run reads it again.' -f $Base)
        # A second wrong-shaped file in the same second.
        Set-Content -LiteralPath $Path -Value '{"TenantID":"t","CompletedSubscriptionIds":6}'
        (Move-WrongShapeResumeStateFile -Path $Path -Kind Main -Now $script:Now 6>$null).MovedTo | Should -Be ($Base + '-3')
        Get-Content -LiteralPath (Join-Path $script:Dir $Base) -Raw | Should -Be ("an earlier one" + [Environment]::NewLine)
        Get-Content -LiteralPath (Join-Path $script:Dir ($Base + '-2')) -Raw | Should -BeLike '*:5}*'
        Get-Content -LiteralPath (Join-Path $script:Dir ($Base + '-3')) -Raw | Should -BeLike '*:6}*'
        Test-Path -LiteralPath $Path | Should -BeFalse
    }

    It 'when the name and -2 to -100 are all taken, stops the run with exit 1, names the file and the reason, prints the remove command and leaves the file' {
        Mock Exit-Wrapper { throw ('Exit-Wrapper {0}' -f $Code) }
        $Path = Join-Path $script:Dir '.resume-state-t.json'
        $Base = '.resume-state-t.json.unreadable-20260102-030405'
        New-Item -ItemType File -Path (Join-Path $script:Dir $Base) | Out-Null
        foreach ($N in 2..100) { New-Item -ItemType File -Path (Join-Path $script:Dir ('{0}-{1}' -f $Base, $N)) | Out-Null }
        Set-Content -LiteralPath $Path -Value '{"TenantID":"t","CompletedSubscriptionIds":5}'
        $Lines = [System.Collections.Generic.List[string]]::new()
        { Move-WrongShapeResumeStateFile -Path $Path -Kind Main -Now $script:Now 6>&1 | ForEach-Object { $Lines.Add([string]$_.MessageData) } } | Should -Throw 'Exit-Wrapper 1'
        Should -Invoke Exit-Wrapper -Times 1 -Exactly -ParameterFilter { $Code -eq 1 }
        $Lines | Should -Be @(
            ('ERROR: The resume state file .resume-state-t.json is not the right shape (CompletedSubscriptionIds is not a list), and it could not be moved aside: every name from {0} to {0}-100 is taken' -f $Base),
            $script:StopStart,
            $script:LaterMain,
            $script:RemoveLead,
            ("  Remove-Item -LiteralPath '{0}' -Force" -f $Path),
            $script:ThenSame
        )
        Test-Path -LiteralPath $Path | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:Dir -Force).Count | Should -Be 101
    }

    It 'the stop for a <Kind> file<When><Rfo> prints these lines, in this order, and exits 1' -TestCases @(
        @{ Kind = 'Main'; After = $false; Rfo = ''; When = ''; Expect = 'StopStart,LaterMain,RemoveLead,Cmd,ThenSame' },
        @{ Kind = 'Main'; After = $false; Rfo = ' under -ResumeFailedOnly'; When = ''; Expect = 'StopStart,LaterMain,RemoveLead,Cmd,ThenResume' },
        @{ Kind = 'Stream'; After = $false; Rfo = ''; When = ''; Expect = 'StopStart,LaterStream,RemoveLead,Cmd,ThenSame' },
        @{ Kind = 'Stream'; After = $false; Rfo = ' under -ResumeFailedOnly'; When = ''; Expect = 'StopStart,LaterStream,RemoveLead,Cmd,ThenResume' },
        @{ Kind = 'Stream'; After = $true; Rfo = ''; When = ' found after the collection'; Expect = 'StopAfter,LaterStream,RemoveLead,Cmd,ThenSame' },
        @{ Kind = 'Stream'; After = $true; Rfo = ' under -ResumeFailedOnly'; When = ' found after the collection'; Expect = 'StopAfter,LaterStream,RemoveLead,Cmd,ThenResume' }
    ) {
        Mock Exit-Wrapper { throw ('Exit-Wrapper {0}' -f $Code) }
        $Path = Join-Path $script:Dir '.resume-state-t-stream-3.json'
        $Lines = [System.Collections.Generic.List[string]]::new()
        $File = [pscustomobject]@{ Kind = $Kind; Name = '.resume-state-t-stream-3.json'; MovedTo = $null; Path = $Path; Problem = 'Completed is not a list'; Reason = 'stand-in reason'; NotMoved = $true }
        { Stop-WrongShapeStateNotMoved -Files @($File) -AfterCollection:$After -ResumeFailedOnly:($Rfo -ne '') 6>&1 | ForEach-Object { $Lines.Add([string]$_.MessageData) } } | Should -Throw 'Exit-Wrapper 1'
        $What = if ($Kind -eq 'Main') { 'resume state file' } else { 'per-stream state file' }
        $Want = @(('ERROR: The {0} .resume-state-t-stream-3.json is not the right shape (Completed is not a list), and it could not be moved aside: stand-in reason' -f $What)) + @($Expect -split ',' | ForEach-Object { if ($_ -eq 'Cmd') { "  Remove-Item -LiteralPath '{0}' -Force" -f $Path } else { (Get-Variable -Scope Script -Name $_).Value } })
        @($Lines) | Should -Be $Want
    }

    It 'two files after the collection: an ERROR line and a remove command for each, then one exit 1' {
        Mock Exit-Wrapper { throw ('Exit-Wrapper {0}' -f $Code) }
        $Files = @(5, 6 | ForEach-Object { [pscustomobject]@{ Kind = 'Stream'; Name = ('.resume-state-t-stream-{0}.json' -f $_); MovedTo = $null; Path = (Join-Path $script:Dir ('.resume-state-t-stream-{0}.json' -f $_)); Problem = 'Completed is not a list'; Reason = 'stand-in reason'; NotMoved = $true } })
        $Lines = [System.Collections.Generic.List[string]]::new()
        { Stop-WrongShapeStateNotMoved -Files $Files -AfterCollection 6>&1 | ForEach-Object { $Lines.Add([string]$_.MessageData) } } | Should -Throw 'Exit-Wrapper 1'
        Should -Invoke Exit-Wrapper -Times 1 -Exactly
        @($Lines | Where-Object { $_ -like 'ERROR: *' }).Count | Should -Be 2
        $Lines | Should -Contain '  Once the cause shown above is fixed, remove the files with these commands:'
        @($Lines | Where-Object { $_ -like "  Remove-Item -LiteralPath '*' -Force" }) | Should -Be @($Files | ForEach-Object { "  Remove-Item -LiteralPath '{0}' -Force" -f $_.Path })
    }

    It 'after the collection, a file that cannot be moved aside is left as it is and returned, with a notice, and the run is not stopped yet' {
        Mock Exit-Wrapper { throw ('Exit-Wrapper {0}' -f $Code) }
        $Path = Join-Path $script:Dir '.resume-state-t-stream-5.json'
        Set-Content -LiteralPath $Path -Value '{"Completed":5}'
        & chmod 555 $script:Dir
        try { $Out = @(Move-WrongShapeResumeStateFile -Path $Path -Kind Stream -AfterCollection -Now $script:Now 6>&1) }
        finally { & chmod 755 $script:Dir }
        if (-not (Test-Path -LiteralPath $Path) -or @(Get-ChildItem -LiteralPath $script:Dir -Force).Count -ne 1) { Set-ItResult -Skipped -Because 'a read-only folder can still be written here'; return }
        Should -Invoke Exit-Wrapper -Times 0
        $Result = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        $Lines = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $Result.Count | Should -Be 1
        $Result[0].NotMoved | Should -BeTrue
        $Result[0].Path | Should -Be $Path
        $Lines[0] | Should -BeLike 'ERROR: The per-stream state file .resume-state-t-stream-5.json is not the right shape (Completed is not a list), and it could not be moved aside: *'
        $Lines[1] | Should -Be $script:MergeNotice
        Get-Content -LiteralPath $Path -Raw | Should -BeLike '*"Completed":5*'
    }

    It 'quotes a path holding a single quote in the remove command, and the command removes the file' {
        Mock Exit-Wrapper { throw ('Exit-Wrapper {0}' -f $Code) }
        $Odd = Join-Path $script:Dir "it's here"
        New-Item -ItemType Directory -Path $Odd | Out-Null
        $Path = Join-Path $Odd '.resume-state-t-stream-0.json'
        Set-Content -LiteralPath $Path -Value '{"Completed":5}'
        & chmod 555 $Odd
        try
        {
            $Lines = [System.Collections.Generic.List[string]]::new()
            { Move-WrongShapeResumeStateFile -Path $Path -Kind Stream -Now $script:Now 6>&1 | ForEach-Object { $Lines.Add([string]$_.MessageData) } } | Should -Throw 'Exit-Wrapper 1'
        }
        finally { & chmod 755 $Odd }
        if (-not (Test-Path -LiteralPath $Path)) { Set-ItResult -Skipped -Because 'a read-only folder can still be written here'; return }
        $Lines[0] | Should -BeLike 'ERROR: The per-stream state file .resume-state-t-stream-0.json is not the right shape (Completed is not a list), and it could not be moved aside: *'
        $Lines[1] | Should -Be $script:StopStart
        $Command = @($Lines | Where-Object { $_ -like "  Remove-Item -LiteralPath '*" })[0].Trim()
        $Command | Should -Be ("Remove-Item -LiteralPath '{0}' -Force" -f $Path.Replace("'", "''"))
        & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command $Command
        Test-Path -LiteralPath $Path | Should -BeFalse
    }

    It 'Write-WrongShapeStateSummary names each file and never says clean run' {
        $Files = @(
            [pscustomobject]@{ Kind = 'Main'; Name = '.resume-state-t.json'; MovedTo = '.resume-state-t.json.unreadable-20260102-030405' },
            [pscustomobject]@{ Kind = 'Stream'; Name = '.resume-state-t-stream-1.json'; MovedTo = '.resume-state-t-stream-1.json.unreadable-20260102-030405-2' }
        )
        $Lines = @(Write-WrongShapeStateSummary -Files $Files -StateKept $false 6>&1 | ForEach-Object { [string]$_.MessageData })
        $Lines | Should -Be @(
            'Resume state cleared, but not a clean run: the resume state file .resume-state-t.json was not the right shape and was moved aside to .resume-state-t.json.unreadable-20260102-030405; its records were not used.',
            'Resume state cleared, but not a clean run: the per-stream state file .resume-state-t-stream-1.json was not the right shape and was moved aside to .resume-state-t-stream-1.json.unreadable-20260102-030405-2; its records were not used.'
        )
        @(Write-WrongShapeStateSummary -Files @() -StateKept $true 6>&1) | Should -BeNullOrEmpty
    }
}

Describe 'Readers' {
    BeforeEach {
        $script:Dir = Join-Path $script:UnitDir ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:Path = Join-Path $script:Dir '.resume-state-t.json'
    }

    It 'Get-FailedAttempts skips the null entry the wrapper saves when a retry list becomes empty' {
        Set-Content -LiteralPath $script:Path -Value '{"TenantID":"t","CompletedSubscriptionIds":["sub-a"],"FailedAttempts":[null,{"Id":"sub-b","Attempts":1,"LastFailedAt":"2026-10-29T00:00:00Z"}]}'
        $List = @(Get-FailedAttempts -Path $script:Path -Tenant 't')
        $List.Count | Should -Be 1
        $List[0].Id | Should -Be 'sub-b'
        @(Get-FailedAttempts -Path $script:Path -Tenant 't' | Where-Object { $null -eq $_ }) | Should -BeNullOrEmpty
    }

    It 'the stream worker reads a wrong-shaped per-stream state file as no records, with a warning' {
        Set-Variable -Name Tag -Value '[stream-0]'
        $Path = Join-Path $script:Dir '.resume-state-t-stream-0.json'
        Set-Content -LiteralPath $Path -Value '{"Completed":5,"FailedAttempts":"garbage"}'
        $Out = @(Read-StreamState -Path $Path 6>&1)
        $State = @($Out | Where-Object { $_ -is [hashtable] })[0]
        $Lines = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        @($State.Completed) | Should -BeNullOrEmpty
        @($State.Failed) | Should -BeNullOrEmpty
        $Lines | Should -Be @(('[stream-0] WARNING: could not read stream state at {0}: it is not the right shape (Completed is not a list)' -f $Path))
    }

    It 'the stream worker reads a <Label> per-stream state file as no records, without a warning, as before' -TestCases @(
        @{ Label = '0-byte'; Text = '' },
        @{ Label = 'whitespace-only'; Text = "`n  `n" }
    ) {
        Set-Variable -Name Tag -Value '[stream-0]'
        $Path = Join-Path $script:Dir '.resume-state-t-stream-0.json'
        script:Write-RawText -Path $Path -Text $Text
        $Out = @(Read-StreamState -Path $Path 6>&1)
        $State = @($Out | Where-Object { $_ -is [hashtable] })[0]
        @($State.Completed) | Should -BeNullOrEmpty
        @($State.Failed) | Should -BeNullOrEmpty
        @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) | Should -BeNullOrEmpty
    }
}

Describe 'Wrapper end to end: a wrong-shaped resume state file' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    It 'retry list as a plain string: -Resume with <Streams> stream(s)<ObfLabel> starts fresh, and the next -Resume ends clean' -ForEach @(
        @{ Streams = 1; Obfuscate = $false; ObfLabel = '' },
        @{ Streams = 1; Obfuscate = $true; ObfLabel = ' and -Obfuscate' },
        @{ Streams = 2; Obfuscate = $false; ObfLabel = '' },
        @{ Streams = 2; Obfuscate = $true; ObfLabel = ' and -Obfuscate' }
    ) {
        script:Set-Scenario
        $Seeded = script:Write-MainState -FailedAttempts $script:Marker
        $Args1 = @('-Resume') + $(if ($Obfuscate) { @('-Obfuscate') } else { @() })

        # Run 1: moved aside, starts fresh (A is collected again although the
        # file listed it as completed), not a clean run, the state cleared.
        # Nothing on stderr (Assert-MovedAside).
        $R1 = script:Invoke-Wrapper -Arguments $Args1 -Streams $Streams
        $R1.ExitCode | Should -Be 0
        $Moved = script:Assert-MovedAside -Run $R1 -FileName $script:StateName -Field 'FailedAttempts is not a list' -Content $Seeded
        $R1.Text | Should -Contain '  Starting fresh: this run does not use the completed list or retry list of the resume state file moved aside above.'
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        $R1.Text | Should -Contain ('Resume state cleared, but not a clean run: the resume state file {0} was not the right shape and was moved aside to {1}; its records were not used.' -f $script:StateName, $Moved.Name)
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        script:Assert-NotInAnyZip

        # Run 2: clean, nothing left.
        $R2 = script:Invoke-Wrapper -Arguments $Args1 -Streams $Streams
        script:Assert-NextRunClean -Run $R2 -Moved $Moved -Content $Seeded -Collected 'A', 'B', 'C'
        script:Assert-NotInAnyZip
    }

    It '-ResumeFailedOnly with <Streams> stream(s) stops with exit 1 and names the next command; that command ends clean' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        script:Set-Scenario
        $Seeded = script:Write-MainState -FailedAttempts $script:Marker

        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams $Streams
        $R1.ExitCode | Should -Be 1
        $Moved = script:Assert-MovedAside -Run $R1 -FileName $script:StateName -Field 'FailedAttempts is not a list' -Content $Seeded
        script:Get-Collected $R1 | Should -BeNullOrEmpty
        $R1.Text | Should -Contain 'ResumeFailedOnly: stopped before retrying anything (exit 1). The retry list is not complete: a resume state file was not the right shape (see the warning above).'
        $R1.Text | Should -Contain ('  {0}: moved aside to {1}; its records are not used.' -f $script:StateName, $Moved.Name)
        $R1.Text | Should -Contain '  Next: run the same command without -ResumeFailedOnly, with -Resume. It collects every subscription the remaining state does not list as completed.'
        @($R1.Text | Where-Object { $_ -like 'ResumeFailedOnly: filtered to*' -or $_ -like '*Nothing to retry*' }) | Should -BeNullOrEmpty
        script:Get-LiveStateFiles | Should -BeNullOrEmpty

        # The advised command.
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams
        script:Assert-NextRunClean -Run $R2 -Moved $Moved -Content $Seeded -Collected 'A', 'B', 'C'
    }

    It 'a retry entry whose <Field> is present but invalid, with <Streams> stream(s) and that subscription failing again: no conversion error, and the next -Resume ends clean' -ForEach @(
        @{ Field = 'Attempts'; Streams = 1; Subs = @('A', 'B'); Problem = 'FailedAttempts entry 1: Attempts is not a whole number of at least 1' },
        @{ Field = 'LastFailedAt'; Streams = 2; Subs = @('A', 'B', 'C'); Problem = 'FailedAttempts entry 1: LastFailedAt is not a date' }
    ) {
        # B fails again in run 1. With 2 streams, A and C are in stream 0 and B
        # in stream 1, so the retry list goes through the end-of-run merge.
        script:Set-Scenario -Subs $Subs -Fail 'B'
        $Entry = if ($Field -eq 'Attempts') { script:New-RetryEntry -Letter 'B' -Attempts 'abc' } else { script:New-RetryEntry -Letter 'B' -LastFailedAt 'not-a-date' }
        $Seeded = script:Write-MainState -FailedAttempts @($Entry)

        # Run 1: the new retry list holds B once, with one failed run, and the
        # state is kept for it.
        $R1 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams
        $Moved = script:Assert-MovedAside -Run $R1 -FileName $script:StateName -Field $Problem -Content $Seeded
        script:Get-Collected $R1 | Should -Be (script:Get-Ids $Subs)
        $R1.Text | Should -Contain ('Resume state kept, but not a clean run: the resume state file {0} was not the right shape and was moved aside to {1}; its records were not used.' -f $script:StateName, $Moved.Name)
        $State = Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json
        @($State.FailedAttempts | Where-Object { $_ } | ForEach-Object { '{0}:{1}' -f $_.Id, $_.Attempts }) | Should -Be @('sub-b:1')

        # Run 2: B succeeds; the state clears. A sequential -Resume skips the
        # completed A; whether a parallel -Resume skips completed subscriptions
        # is the parallel path's own concern, so with 2 streams only B is required.
        script:Set-Scenario -Subs $Subs
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams
        $Collected = if ($Streams -eq 1) { @('B') } else { @(script:Get-Collected $R2 | ForEach-Object { $_.Substring(4).ToUpperInvariant() }) }
        $Collected | Should -Contain 'B'
        script:Assert-NextRunClean -Run $R2 -Moved $Moved -Content $Seeded -Collected $Collected
    }

    It 'a run without -Resume moves it aside too, does not say clean run, and the next run ends clean' {
        script:Set-Scenario
        $Seeded = script:Write-MainState -FailedAttempts $script:Marker
        $R1 = script:Invoke-Wrapper
        $R1.ExitCode | Should -Be 0
        $Moved = script:Assert-MovedAside -Run $R1 -FileName $script:StateName -Field 'FailedAttempts is not a list' -Content $Seeded
        @($R1.Text | Where-Object { $_ -like '  Starting fresh*' }) | Should -BeNullOrEmpty
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        $R2 = script:Invoke-Wrapper
        script:Assert-NextRunClean -Run $R2 -Moved $Moved -Content $Seeded -Collected 'A', 'B', 'C'
    }

    It '-Resume and -ResumeFailedOnly together: stops with exit 1 and does not say it starts fresh' {
        script:Set-Scenario
        $Seeded = script:Write-MainState -FailedAttempts $script:Marker
        $R1 = script:Invoke-Wrapper -Arguments '-Resume', '-ResumeFailedOnly'
        $R1.ExitCode | Should -Be 1
        $null = script:Assert-MovedAside -Run $R1 -FileName $script:StateName -Field 'FailedAttempts is not a list' -Content $Seeded
        @($R1.Text | Where-Object { $_ -like '  Starting fresh*' }) | Should -BeNullOrEmpty
        script:Get-Collected $R1 | Should -BeNullOrEmpty
        $R1.Text | Should -Contain 'ResumeFailedOnly: stopped before retrying anything (exit 1). The retry list is not complete: a resume state file was not the right shape (see the warning above).'
        $R1.Text | Should -Contain '  Next: run the same command without -ResumeFailedOnly, with -Resume. It collects every subscription the remaining state does not list as completed.'
    }

    It 'beside a right-shaped per-stream file of the same run (<Label>), -Resume says only that it does not use the moved file, and still skips what the stream file lists; the next -Resume finds no state' -ForEach @(
        @{ Label = 'files written before run ids'; RunId = '' },
        @{ Label = 'both with the run id run-earlier'; RunId = 'run-earlier' }
    ) {
        # The moved file lists B as completed; the per-stream file lists A.
        script:Set-Scenario
        $Seeded = script:Write-MainState -FailedAttempts $script:Marker -Completed 'B' -RunId $RunId
        $IdPart = if ($RunId) { '"RunId": "' + $RunId + '", ' } else { '' }
        $null = script:Write-StreamText -Text ('{"Tenant": "' + $script:Tenant + '", "StreamId": "0", ' + $IdPart + '"Completed": ["sub-a"], "FailedAttempts": []}')
        $R1 = script:Invoke-Wrapper -Arguments '-Resume'
        # The exit code is not checked beyond "not the stop": it also depends on
        # whether the report of a subscription skipped as completed can be put in
        # this run's zip.
        $R1.ExitCode | Should -Not -Be 1
        $R1.Error | Should -BeNullOrEmpty
        $null = script:Assert-MovedAside -Run $R1 -FileName $script:StateName -Field 'FailedAttempts is not a list' -Content $Seeded
        $Lines = @($R1.Text | Where-Object { $_ -like '  Starting fresh*' -or $_ -like '  This run does not use*' -or $_ -like 'Recovered per-stream state*' -or $_ -like 'Resume mode:*' -or $_ -like 'Skipping (already completed):*' })
        $Lines | Should -Be @(
            'Recovered per-stream state from an interrupted parallel run: 1 completed, 0 failed subscription record(s).',
            'Resume mode: 1 previously completed subscription(s) will be skipped.',
            '  This run does not use the completed list or retry list of the resume state file moved aside above; it uses only the per-stream state recovered above.',
            'Skipping (already completed): Sub A (sub-a)'
        )
        # B, listed as completed only in the moved file, is collected.
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'B', 'C')
        @($R1.Text | Where-Object { $_ -like '*were written by another run*' }) | Should -BeNullOrEmpty
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        $R2 = script:Invoke-Wrapper -Arguments '-Resume'
        $R2.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        script:Test-CleanLine $R2 | Should -BeTrue
    }

    It 'beside a right-shaped per-stream file of the same run (<Label>), -ResumeFailedOnly stops and the -Resume it names skips what that file lists, with <Streams> stream(s); the -Resume after that finds no state' -ForEach @(
        @{ Label = 'files written before run ids'; RunId = ''; Streams = 1 },
        @{ Label = 'both with the run id run-earlier'; RunId = 'run-earlier'; Streams = 1 },
        @{ Label = 'both with the run id run-earlier'; RunId = 'run-earlier'; Streams = 2 }
    ) {
        script:Set-Scenario
        $null = script:Write-MainState -FailedAttempts $script:Marker -Completed 'B' -RunId $RunId
        $IdPart = if ($RunId) { '"RunId": "' + $RunId + '", ' } else { '' }
        $null = script:Write-StreamText -Text ('{"Tenant": "' + $script:Tenant + '", "StreamId": "0", ' + $IdPart + '"Completed": ["sub-a"], "FailedAttempts": []}')
        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams $Streams
        $R1.ExitCode | Should -Be 1
        $R1.Error | Should -BeNullOrEmpty
        $R1.Text | Should -Contain 'Recovered per-stream state from an interrupted parallel run: 1 completed, 0 failed subscription record(s).'
        $R1.Text | Should -Contain 'ResumeFailedOnly: stopped before retrying anything (exit 1). The retry list is not complete: a resume state file was not the right shape (see the warning above).'
        $R1.Text | Should -Contain '  Next: run the same command without -ResumeFailedOnly, with -Resume. It collects every subscription the remaining state does not list as completed.'
        script:Get-Calls | Should -BeNullOrEmpty
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams
        $R2.ExitCode | Should -Not -Be 1
        $R2.Error | Should -BeNullOrEmpty
        $R2.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B', 'C')
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams
        $R3.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        script:Test-CleanLine $R3 | Should -BeTrue
    }

    It 'a <Label> resume state file is handled as before: -ResumeFailedOnly has nothing to retry and, with subscriptions no run has completed, exits 2; nothing is moved' -TestCases @(
        @{ Label = '0-byte'; Text = '' },
        @{ Label = 'whitespace-only'; Text = "  `n`t`n " }
    ) {
        script:Set-Scenario
        script:Write-RawText -Path $script:State -Text $Text
        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly'
        # Nothing to retry while subscriptions no run has completed remain is exit 2.
        $R1.ExitCode | Should -Be 2
        $R1.Error | Should -BeNullOrEmpty
        @(script:Get-ShapeWarnings $R1) | Should -BeNullOrEmpty
        script:Get-MovedAside | Should -BeNullOrEmpty
        $R1.Text | Should -Contain 'ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry.'
        @($R1.Text | Where-Object { $_ -like 'ResumeFailedOnly: stopped*' }) | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllText($script:State) | Should -Be $Text
    }

    It 'a wrong-shaped resume state file that cannot be moved aside stops <Switch> with exit 1 before any work, the same on the next run; after the printed command the run starts fresh and ends clean' -ForEach @(
        @{ Switch = '-Resume'; Streams = 1 },
        @{ Switch = '-ResumeFailedOnly'; Streams = 1 },
        @{ Switch = '-Resume'; Streams = 2 }
    ) {
        # The inventory root becomes read-only after the run's write probe, so the
        # rename fails. Skipped where a read-only folder can still be written (root).
        if (-not (script:Test-ReadOnlyRefused)) { Set-ItResult -Skipped -Because 'a read-only folder can still be written here'; return }
        script:Set-Scenario -ReadOnlyRoot
        $Seeded = script:Write-MainState -FailedAttempts $script:Marker -Completed 'A'
        $Before = script:Get-RootSnapshot
        $Commands = @()
        foreach ($N in 1, 2)
        {
            try { $R = script:Invoke-Wrapper -Arguments $Switch -Streams $Streams }
            finally { & chmod 755 $script:Root }
            # The read-only folder also refused the removal of this run's own lock,
            # and the run printed the command that removes it. The lock is never
            # taken over, so that command is run now that the folder can be written.
            $LockRemove = @(foreach ($Line in $R.Text) { if ($Line -match 'To remove it now: (Remove-Item -LiteralPath .+ -Force)$') { $Matches[1] } })
            $LockRemove.Count | Should -Be 1 -Because 'the run says it could not remove its run lock, with the command that does'
            & ([scriptblock]::Create($LockRemove[0]))
            $R.ExitCode | Should -Be 1
            script:Get-StopLines $R | Should -BeLike ('ERROR: The resume state file {0} is not the right shape (FailedAttempts is not a list), and it could not be moved aside: Access to the path *' -f $script:StateName)
            $R.Text | Should -Contain $script:StopStart
            $R.Text | Should -Contain $script:LaterMain
            $R.Text | Should -Contain $script:RemoveLead
            $R.Text | Should -Contain $(if ($Switch -eq '-ResumeFailedOnly') { $script:ThenResume } else { $script:ThenSame })
            $Commands += @(script:Get-RemoveCommand $R)
            @(script:Get-ShapeWarnings $R) | Should -BeNullOrEmpty
            @($R.Text | Where-Object { $_ -like '  Starting fresh*' -or $_ -like 'Resume mode:*' -or $_ -like 'ResumeFailedOnly:*' }) | Should -BeNullOrEmpty
            # Nothing collected, nothing else written: the file as seeded, every
            # other file in the inventory root (the run transcripts aside) unchanged.
            script:Get-Calls | Should -BeNullOrEmpty
            Get-Content -LiteralPath $script:State -Raw | Should -Be $Seeded
            script:Get-RootSnapshot | Should -Be $Before
            $R.Error | Should -BeNullOrEmpty
        }
        $Commands | Should -Be @(("Remove-Item -LiteralPath '{0}' -Force" -f $script:State), ("Remove-Item -LiteralPath '{0}' -Force" -f $script:State))

        # The cause is fixed (the folder can be written); the printed command, then the same run.
        script:Set-Scenario
        & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command $Commands[0]
        Test-Path -LiteralPath $script:State | Should -BeFalse
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams
        $R3.ExitCode | Should -Be 0
        $R3.Error | Should -BeNullOrEmpty
        $R3.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        script:Get-MovedAside | Should -BeNullOrEmpty
    }

    It 'state the tool writes after every subscription fails, on one stream and then two, is used: -ResumeFailedOnly retries all of it, and the next -Resume ends clean' {
        # Run 1 saves a null completed id; run 2, a parallel -Resume, saves what
        # that becomes. Neither file may be called the wrong shape.
        script:Set-Scenario -Fail 'A', 'B', 'C'
        $R1 = script:Invoke-Wrapper
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        # Every subscription failed, so both runs end with exit 2.
        foreach ($R in $R1, $R2) { @(script:Get-ShapeWarnings $R) | Should -BeNullOrEmpty; $R.ExitCode | Should -Be 2 }
        @((Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json).FailedAttempts | Where-Object { $_ } | ForEach-Object { $_.Id } | Sort-Object) | Should -Be (script:Get-Ids 'A', 'B', 'C')
        script:Set-Scenario
        $R3 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly'
        $R3.ExitCode | Should -Not -Be 1
        $R3.ExitCode | Should -Be 0
        @(script:Get-ShapeWarnings $R3) | Should -BeNullOrEmpty
        script:Get-MovedAside | Should -BeNullOrEmpty
        $R3.Text | Should -Contain 'ResumeFailedOnly: filtered to 3 previously-failed subscription(s) (was 3).'
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        # Whether this run already clears the state depends on how the completed
        # list is seeded from an empty id (a list of one id can become a text that
        # later ids are joined onto), which is not this check; the next run's end is.
        $R4 = script:Invoke-Wrapper -Arguments '-Resume'
        $R4.ExitCode | Should -Be 0
        @(script:Get-ShapeWarnings $R4) | Should -BeNullOrEmpty
        script:Test-CleanLine $R4 | Should -BeTrue
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        script:Get-MovedAside | Should -BeNullOrEmpty
    }

    It 'right-shaped state as the wrapper writes it (a null completed id, a null retry entry) is used, not moved aside' {
        script:Set-Scenario -Subs 'A', 'B'
        $null = script:Write-MainState -FailedAttempts @($null, (script:New-RetryEntry -Letter 'B'))
        $Raw = Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json
        $Raw.CompletedSubscriptionIds = @($null, $script:Subs['A'].Id)
        $Raw | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:State -Encoding utf8
        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly'
        $R1.ExitCode | Should -Be 0
        @(script:Get-ShapeWarnings $R1) | Should -BeNullOrEmpty
        script:Get-MovedAside | Should -BeNullOrEmpty
        $R1.Text | Should -Contain 'ResumeFailedOnly: filtered to 1 previously-failed subscription(s) (was 2).'
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'B')
        script:Test-CleanLine $R1 | Should -BeTrue
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
    }
}

Describe 'Wrapper end to end: a wrong-shaped per-stream state file' -Skip:$IsWindows {
    BeforeEach { script:New-Case }

    It '{"Completed": 5, "FailedAttempts": "garbage"}: -Resume with <Streams> stream(s)<ObfLabel> collects again, and the next -Resume ends clean' -ForEach @(
        @{ Streams = 1; Obfuscate = $false; ObfLabel = '' },
        @{ Streams = 2; Obfuscate = $false; ObfLabel = '' },
        @{ Streams = 2; Obfuscate = $true; ObfLabel = ' and -Obfuscate' }
    ) {
        script:Set-Scenario
        $Seeded = script:Write-StreamText -Text ('{"Completed": 5, "FailedAttempts": "' + $script:Marker + '"}')
        $Args1 = @('-Resume') + $(if ($Obfuscate) { @('-Obfuscate') } else { @() })

        $R1 = script:Invoke-Wrapper -Arguments $Args1 -Streams $Streams
        $R1.ExitCode | Should -Be 0
        $Moved = script:Assert-MovedAside -Run $R1 -FileName $script:Stream0Name -Field 'Completed is not a list' -Content $Seeded
        $R1.Text | Should -Contain '  This run does not count the subscriptions it lists as completed.'
        @($R1.Text | Where-Object { $_ -like 'Recovered per-stream state*' }) | Should -BeNullOrEmpty
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        $R1.Text | Should -Contain ('Resume state cleared, but not a clean run: the per-stream state file {0} was not the right shape and was moved aside to {1}; its records were not used.' -f $script:Stream0Name, $Moved.Name)
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        script:Assert-NotInAnyZip

        $R2 = script:Invoke-Wrapper -Arguments $Args1 -Streams $Streams
        script:Assert-NextRunClean -Run $R2 -Moved $Moved -Content $Seeded -Collected 'A', 'B', 'C'
        script:Assert-NotInAnyZip
    }

    It 'beside a right-shaped resume state, only the per-stream file''s records are dropped: the completed subscription stays skipped' {
        # Run 0 writes the resume state: A completes, B and C fail.
        script:Set-Scenario -Fail 'B', 'C'
        $null = script:Invoke-Wrapper
        script:Set-Scenario
        $Seeded = script:Write-StreamText -Text ('{"Completed": ["sub-b"], "FailedAttempts": "' + $script:Marker + '"}')
        $R1 = script:Invoke-Wrapper -Arguments '-Resume'
        $Moved = script:Assert-MovedAside -Run $R1 -FileName $script:Stream0Name -Field 'FailedAttempts is not a list' -Content $Seeded
        # B, listed as completed only in the moved file, is collected again.
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'B', 'C')
        $R1.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        $R2 = script:Invoke-Wrapper -Arguments '-Resume'
        script:Assert-NextRunClean -Run $R2 -Moved $Moved -Content $Seeded -Collected 'A', 'B', 'C'
    }

    It 'a <Label> per-stream file beside a right-shaped resume state is handled as before: -ResumeFailedOnly retries the retry list' -TestCases @(
        @{ Label = '0-byte'; Text = '' },
        @{ Label = 'whitespace-only'; Text = "  `n " }
    ) {
        script:Set-Scenario -Subs 'A', 'B'
        $null = script:Write-MainState -FailedAttempts @((script:New-RetryEntry -Letter 'B')) -Completed 'A'
        $StreamPath = Join-Path $script:Root $script:Stream0Name
        script:Write-RawText -Path $StreamPath -Text $Text
        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly'
        # Not the wrong shape and no new stop. Whether the empty file itself is
        # kept or moved aside as unreadable belongs to the handling of
        # per-stream files that cannot be read, so it is not checked here.
        $R1.ExitCode | Should -Not -Be 1
        $R1.ExitCode | Should -Be 0
        $R1.Error | Should -BeNullOrEmpty
        @(script:Get-ShapeWarnings $R1) | Should -BeNullOrEmpty
        @($R1.Text | Where-Object { $_ -like 'ResumeFailedOnly: stopped*' }) | Should -BeNullOrEmpty
        $R1.Text | Should -Contain 'ResumeFailedOnly: filtered to 1 previously-failed subscription(s) (was 2).'
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'B')
    }

    It 'a wrong-shaped per-stream file that cannot be moved aside stops <Switch> with exit 1 before any work, the same on the next run; after the printed command the run ends clean' -ForEach @(
        @{ Switch = '-Resume'; Streams = 1 },
        @{ Switch = '-ResumeFailedOnly'; Streams = 2 }
    ) {
        if (-not (script:Test-ReadOnlyRefused)) { Set-ItResult -Skipped -Because 'a read-only folder can still be written here'; return }
        script:Set-Scenario -ReadOnlyRoot
        $Seeded = script:Write-StreamText -Text ('{"Completed": 5, "FailedAttempts": "' + $script:Marker + '"}')
        $StreamPath = Join-Path $script:Root $script:Stream0Name
        $Before = script:Get-RootSnapshot
        foreach ($N in 1, 2)
        {
            try { $R = script:Invoke-Wrapper -Arguments $Switch -Streams $Streams }
            finally { & chmod 755 $script:Root }
            # The read-only folder also refused the removal of this run's own lock,
            # and the run printed the command that removes it. The lock is never
            # taken over, so that command is run now that the folder can be written.
            $LockRemove = @(foreach ($Line in $R.Text) { if ($Line -match 'To remove it now: (Remove-Item -LiteralPath .+ -Force)$') { $Matches[1] } })
            $LockRemove.Count | Should -Be 1 -Because 'the run says it could not remove its run lock, with the command that does'
            & ([scriptblock]::Create($LockRemove[0]))
            $R.ExitCode | Should -Be 1
            script:Get-StopLines $R | Should -BeLike ('ERROR: The per-stream state file {0} is not the right shape (Completed is not a list), and it could not be moved aside: Access to the path *' -f $script:Stream0Name)
            $R.Text | Should -Contain $script:StopStart
            $R.Text | Should -Contain $script:LaterStream
            $R.Text | Should -Contain $(if ($Switch -eq '-ResumeFailedOnly') { $script:ThenResume } else { $script:ThenSame })
            script:Get-RemoveCommand $R | Should -Be @("Remove-Item -LiteralPath '{0}' -Force" -f $StreamPath)
            script:Get-Calls | Should -BeNullOrEmpty
            Get-Content -LiteralPath $StreamPath -Raw | Should -Be $Seeded
            script:Get-RootSnapshot | Should -Be $Before
            $R.Error | Should -BeNullOrEmpty
        }
        script:Set-Scenario
        & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command ("Remove-Item -LiteralPath '{0}' -Force" -f $StreamPath)
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams
        $R3.ExitCode | Should -Be 0
        $R3.Error | Should -BeNullOrEmpty
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        script:Get-MovedAside | Should -BeNullOrEmpty
    }

    It 'a per-stream file whose root is the number 5: <Switch> with <Streams> stream(s) calls it the wrong shape and moves it aside; the next identical run does not repeat it' -ForEach @(
        @{ Switch = '-Resume'; Streams = 1 },
        @{ Switch = '-Resume'; Streams = 2 },
        @{ Switch = '-ResumeFailedOnly'; Streams = 1 },
        @{ Switch = '-ResumeFailedOnly'; Streams = 2 }
    ) {
        script:Set-Scenario
        $Seeded = script:Write-StreamText -Text '5'
        $R1 = script:Invoke-Wrapper -Arguments $Switch -Streams $Streams
        $Moved = script:Assert-MovedAside -Run $R1 -FileName $script:Stream0Name -Field 'it is not a JSON object' -Content $Seeded
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        $R2 = script:Invoke-Wrapper -Arguments $Switch -Streams $Streams
        $R2.ExitCode | Should -Be 0
        $R2.Error | Should -BeNullOrEmpty
        @(script:Get-ShapeWarnings $R2) | Should -BeNullOrEmpty
        @(script:Get-MovedAside | ForEach-Object { $_.Name }) | Should -Be @($Moved.Name)
        if ($Switch -eq '-ResumeFailedOnly')
        {
            $R1.ExitCode | Should -Be 1
            $R1.Text | Should -Contain ('  {0}: moved aside to {1}; its records are not used.' -f $script:Stream0Name, $Moved.Name)
            $R2.Text | Should -Contain 'ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry.'
        }
        else
        {
            $R1.ExitCode | Should -Be 0
            script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C')
            script:Test-CleanLine $R2 | Should -BeTrue
        }
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
    }

    It '-ResumeFailedOnly with <Streams> stream(s) stops with exit 1; the advised -Resume ends clean' -ForEach @(@{ Streams = 1 }, @{ Streams = 2 }) {
        script:Set-Scenario
        $Seeded = script:Write-StreamText -Text ('{"Completed": 5, "FailedAttempts": "' + $script:Marker + '"}')

        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly' -Streams $Streams
        $R1.ExitCode | Should -Be 1
        $Moved = script:Assert-MovedAside -Run $R1 -FileName $script:Stream0Name -Field 'Completed is not a list' -Content $Seeded
        script:Get-Collected $R1 | Should -BeNullOrEmpty
        $R1.Text | Should -Contain ('  {0}: moved aside to {1}; its records are not used.' -f $script:Stream0Name, $Moved.Name)
        $R1.Text | Should -Contain '  Next: run the same command without -ResumeFailedOnly, with -Resume. It collects every subscription the remaining state does not list as completed.'

        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams $Streams
        script:Assert-NextRunClean -Run $R2 -Moved $Moved -Content $Seeded -Collected 'A', 'B', 'C'
    }

    It 'a wrong-shaped per-stream file of a stream a run without -Resume uses (<Label>) is moved aside before the streams start; the run is not a clean run, and the next one ends clean' -ForEach @(
        @{ Label = '-ParallelStreams 2'; Streams = 2 },
        @{ Label = 'no -ParallelStreams, two chosen for the host'; Streams = 0 }
    ) {
        script:Set-Scenario
        $Seeded = script:Write-StreamText -Text ('{"Completed": 5, "FailedAttempts": "' + $script:Marker + '"}')
        $R1 = script:Invoke-Wrapper -Streams $Streams -Environment $script:FourCpu
        if ((script:Get-StreamCount $R1) -ne 2) { Set-ItResult -Skipped -Because ('this host chose {0} stream(s), not 2' -f (script:Get-StreamCount $R1)); return }
        $R1.ExitCode | Should -Be 0
        $Moved = script:Assert-MovedAside -Run $R1 -FileName $script:Stream0Name -Field 'Completed is not a list' -Content $Seeded
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        $R1.Text | Should -Contain ('Resume state cleared, but not a clean run: the per-stream state file {0} was not the right shape and was moved aside to {1}; its records were not used.' -f $script:Stream0Name, $Moved.Name)
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        $R2 = script:Invoke-Wrapper -Streams $Streams -Environment $script:FourCpu
        script:Assert-NextRunClean -Run $R2 -Moved $Moved -Content $Seeded -Collected 'A', 'B', 'C'
    }

    It 'a stale wrong-shaped per-stream file found only by the end-of-run merge of a parallel run without -Resume is moved aside there, with nothing on stderr' {
        script:Set-Scenario
        $Seeded = script:Write-StreamText -Text ('{"Completed": ["sub-a"], "FailedAttempts": "' + $script:Marker + '"}') -StreamId 5
        $R1 = script:Invoke-Wrapper -Streams 2
        $R1.ExitCode | Should -Be 0
        $Moved = script:Assert-MovedAside -Run $R1 -FileName ('.resume-state-{0}-stream-5.json' -f $script:Tenant) -Field 'FailedAttempts is not a list' -Content $Seeded
        # The merge's clean-up does not try to remove the path it moved.
        $R1.Error | Should -BeNullOrEmpty
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        $R2 = script:Invoke-Wrapper -Streams 2
        script:Assert-NextRunClean -Run $R2 -Moved $Moved -Content $Seeded -Collected 'A', 'B', 'C'
    }
}

Describe 'Wrapper end to end: a wrong-shaped state file another program holds open' -Skip:$IsWindows {
    # The stand-in Rename-Item refuses to rename the listed file, as for a file
    # another program holds open; the run can read and write everything else.
    BeforeEach {
        script:New-Case
        $script:Stream5Name = '.resume-state-{0}-stream-5.json' -f $script:Tenant
    }

    It 'the resume state file, under -ResumeFailedOnly: the stop names -Resume as the next command, which collects Sub B from the retry list; the run after it ends clean' {
        script:Set-Scenario -RenameRefused $script:StateName
        # The completed list is a text, the retry list holds Sub B.
        $null = script:Write-MainState -FailedAttempts @((script:New-RetryEntry -Letter 'B'))
        $Raw = Get-Content -LiteralPath $script:State -Raw | ConvertFrom-Json
        $Raw.CompletedSubscriptionIds = $script:Subs['A'].Id
        $Raw | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:State -Encoding utf8
        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly'
        $R1.ExitCode | Should -Be 1
        script:Get-StopLines $R1 | Should -BeLike ('ERROR: The resume state file {0} is not the right shape (CompletedSubscriptionIds is not a list), and it could not be moved aside: The process cannot access the file *' -f $script:StateName)
        $R1.Text | Should -Contain $script:ThenResume
        $R1.Text | Should -Not -Contain $script:ThenSame
        script:Get-Calls | Should -BeNullOrEmpty

        # The cause gone; the printed command, then the command the stop names.
        script:Set-Scenario
        $Cmd = @(script:Get-RemoveCommand $R1)[0]
        & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command $Cmd
        Test-Path -LiteralPath $script:State | Should -BeFalse
        $R2 = script:Invoke-Wrapper -Arguments '-Resume'
        $R2.ExitCode | Should -Be 0
        script:Get-Collected $R2 | Should -Contain 'sub-b'
        script:Test-CleanLine $R2 | Should -BeTrue
        $R3 = script:Invoke-Wrapper -Arguments '-Resume'
        $R3.ExitCode | Should -Be 0
        @(script:Get-ShapeWarnings $R3) | Should -BeNullOrEmpty
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
    }

    It 'a per-stream file holding Sub C''s retry entry, under -ResumeFailedOnly: the -Resume the stop names collects Sub B and Sub C; the run after it ends clean' {
        # Run 0 writes the resume state as the tool does: A completed, B on the
        # retry list (C is not visible to it).
        script:Set-Scenario -Subs 'A', 'B' -Fail 'B'
        $null = script:Invoke-Wrapper
        script:Set-Scenario -RenameRefused $script:Stream0Name
        $StreamPath = Join-Path $script:Root $script:Stream0Name
        [pscustomobject]@{ Tenant = $script:Tenant; StreamId = '0'; Completed = 5; FailedAttempts = @((script:New-RetryEntry -Letter 'C')) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StreamPath -Encoding utf8
        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly'
        $R1.ExitCode | Should -Be 1
        script:Get-StopLines $R1 | Should -BeLike ('ERROR: The per-stream state file {0} is not the right shape (Completed is not a list), and it could not be moved aside: *' -f $script:Stream0Name)
        $R1.Text | Should -Contain $script:ThenResume

        script:Set-Scenario
        $Cmd = @(script:Get-RemoveCommand $R1)[0]
        & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command $Cmd
        Test-Path -LiteralPath $StreamPath | Should -BeFalse
        $R2 = script:Invoke-Wrapper -Arguments '-Resume'
        $R2.ExitCode | Should -Be 0
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B', 'C')
        $R2.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        script:Test-CleanLine $R2 | Should -BeTrue
        $R3 = script:Invoke-Wrapper -Arguments '-Resume'
        $R3.ExitCode | Should -Be 0
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
    }

    It 'the resume state file: while it cannot be moved aside, a later <Label> run stops the same way, collects nothing and leaves the file as it is' -ForEach @(
        @{ Label = '-Resume'; Arguments = @('-Resume'); Streams = 1 },
        @{ Label = '-ResumeFailedOnly'; Arguments = @('-ResumeFailedOnly'); Streams = 1 },
        @{ Label = 'one-stream'; Arguments = @(); Streams = 1 },
        @{ Label = 'two-stream'; Arguments = @(); Streams = 2 }
    ) {
        script:Set-Scenario -RenameRefused $script:StateName
        $Seeded = script:Write-MainState -FailedAttempts $script:Marker
        # The run that first stops, then the later run.
        $null = script:Invoke-Wrapper -Arguments '-Resume'
        $Before = script:Get-RootSnapshot
        $R = script:Invoke-Wrapper -Arguments $Arguments -Streams $Streams
        $R.ExitCode | Should -Be 1
        script:Get-StopLines $R | Should -BeLike ('ERROR: The resume state file {0} is not the right shape (FailedAttempts is not a list), and it could not be moved aside: *' -f $script:StateName)
        $R.Text | Should -Contain $script:StopStart
        $R.Text | Should -Contain $script:LaterMain
        script:Get-Calls | Should -BeNullOrEmpty
        Get-Content -LiteralPath $script:State -Raw | Should -Be $Seeded
        script:Get-RootSnapshot | Should -Be $Before
        $R.Error | Should -BeNullOrEmpty
    }

    It 'a per-stream file: while it cannot be moved aside, a later -Resume, a later two-stream -ResumeFailedOnly and a later run without either switch that runs two streams (<Label>) stop the same way at their start and keep the file; a one-stream run without either switch leaves it as it is' -ForEach @(
        @{ Label = '-ParallelStreams 2'; Streams = 2 },
        @{ Label = 'no -ParallelStreams, two chosen for the host'; Streams = 0 }
    ) {
        script:Set-Scenario -RenameRefused $script:Stream0Name
        $Seeded = script:Write-StreamText -Text ('{"Completed": 5, "FailedAttempts": "' + $script:Marker + '"}')
        $StreamPath = Join-Path $script:Root $script:Stream0Name
        $null = script:Invoke-Wrapper -Arguments '-Resume'
        foreach ($Later in @(@{ Arguments = @('-Resume'); Streams = 1 }, @{ Arguments = @('-ResumeFailedOnly'); Streams = 2 }, @{ Arguments = @(); Streams = $Streams }))
        {
            $R = script:Invoke-Wrapper -Arguments $Later.Arguments -Streams $Later.Streams -Environment $script:FourCpu
            if ($Later.Arguments.Count -eq 0 -and (script:Get-StreamCount $R) -ne 2) { Set-ItResult -Skipped -Because ('this host chose {0} stream(s), not 2' -f (script:Get-StreamCount $R)); return }
            $R.ExitCode | Should -Be 1
            script:Get-StopLines $R | Should -BeLike ('ERROR: The per-stream state file {0} is not the right shape (Completed is not a list), and it could not be moved aside: *' -f $script:Stream0Name)
            $R.Text | Should -Contain $script:StopStart
            $R.Text | Should -Contain $script:LaterStream
            $R.Text | Should -Not -Contain 'Resume state cleared (clean run).'
            script:Get-Calls | Should -BeNullOrEmpty
            Get-Content -LiteralPath $StreamPath -Raw | Should -Be $Seeded
            $R.Error | Should -BeNullOrEmpty
        }
        # One stream, no switch: the file is not read and stays as it is.
        $R4 = script:Invoke-Wrapper
        $R4.ExitCode | Should -Be 0
        @(script:Get-StopLines $R4) + @(script:Get-ShapeWarnings $R4) | Should -BeNullOrEmpty
        script:Get-Collected $R4 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        Get-Content -LiteralPath $StreamPath -Raw | Should -Be $Seeded
        # The cause gone; the printed command, then the same two-stream run.
        script:Set-Scenario
        & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command ("Remove-Item -LiteralPath '{0}' -Force" -f $StreamPath)
        $R5 = script:Invoke-Wrapper -Streams $Streams -Environment $script:FourCpu
        $R5.ExitCode | Should -Be 0
        script:Test-CleanLine $R5 | Should -BeTrue
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
    }

    It 'no -ParallelStreams, two streams chosen for the host: a stale per-stream file the end-of-run merge cannot move aside ends the run with exit 1 after its zip and keeps the file; after the printed command the same command ends clean' {
        script:Set-Scenario -RenameRefused $script:Stream5Name
        $Seeded = script:Write-StreamText -Text ('{"Completed": ["sub-a"], "FailedAttempts": "' + $script:Marker + '"}') -StreamId 5
        $Stale = Join-Path $script:Root $script:Stream5Name
        $R1 = script:Invoke-Wrapper -Streams 0 -Environment $script:FourCpu
        if ((script:Get-StreamCount $R1) -ne 2) { Set-ItResult -Skipped -Because ('this host chose {0} stream(s), not 2' -f (script:Get-StreamCount $R1)); return }
        $R1.ExitCode | Should -Be 1
        $R1.Text | Should -Contain $script:MergeNotice
        $R1.Text | Should -Contain $script:StopAfter
        $R1.Text | Should -Not -Contain 'Resume state cleared (clean run).'
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'AllSubscriptions_*.zip').Count | Should -Be 1
        Get-Content -LiteralPath $Stale -Raw | Should -Be $Seeded
        # The cause still there: the next run does the same.
        $R2 = script:Invoke-Wrapper -Streams 0 -Environment $script:FourCpu
        $R2.ExitCode | Should -Be 1
        $R2.Text | Should -Contain $script:StopAfter
        Get-Content -LiteralPath $Stale -Raw | Should -Be $Seeded
        script:Set-Scenario
        & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command (@(script:Get-RemoveCommand $R2)[0])
        $R3 = script:Invoke-Wrapper -Streams 0 -Environment $script:FourCpu
        $R3.ExitCode | Should -Be 0
        script:Test-CleanLine $R3 | Should -BeTrue
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
    }

    It 'a right-shaped per-stream file read before one that cannot be moved aside: -Resume stops with exit 1 and prints no other warning; the right-shaped file is kept and the -Resume after the printed command uses it' {
        # Stream 0 lists Sub A as completed; stream 1 cannot be moved aside.
        $Stream1Name = '.resume-state-{0}-stream-1.json' -f $script:Tenant
        script:Set-Scenario -RenameRefused $Stream1Name
        $Good = script:Write-StreamText -Text ('{"Tenant": "' + $script:Tenant + '", "StreamId": "0", "Completed": ["sub-a"], "FailedAttempts": []}')
        $null = script:Write-StreamText -Text '{"Completed": 5, "FailedAttempts": []}' -StreamId 1
        $R1 = script:Invoke-Wrapper -Arguments '-Resume'
        $R1.ExitCode | Should -Be 1
        $R1.Error | Should -BeNullOrEmpty
        script:Get-StopLines $R1 | Should -BeLike ('ERROR: The per-stream state file {0} is not the right shape (Completed is not a list), and it could not be moved aside: *' -f $Stream1Name)
        @($R1.Text | Where-Object { $_ -like 'WARNING:*' }) | Should -BeNullOrEmpty
        Get-Content -LiteralPath (Join-Path $script:Root $script:Stream0Name) -Raw | Should -Be $Good
        script:Get-Calls | Should -BeNullOrEmpty
        script:Set-Scenario
        & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command (@(script:Get-RemoveCommand $R1)[0])
        $R2 = script:Invoke-Wrapper -Arguments '-Resume'
        # The exit code is not checked beyond "not the stop": it also depends on
        # whether the report of a subscription skipped as completed can be put in
        # this run's zip.
        $R2.ExitCode | Should -Not -Be 1
        $R2.Error | Should -BeNullOrEmpty
        @(script:Get-StopLines $R2) + @(script:Get-ShapeWarnings $R2) | Should -BeNullOrEmpty
        $R2.Text | Should -Contain 'Skipping (already completed): Sub A (sub-a)'
        script:Get-Collected $R2 | Should -Be (script:Get-Ids 'B', 'C')
    }

    It 'a stale per-stream file found by the end-of-run merge (<Label>): the run builds its zip, main summary and end-of-run summary first, every collected report once in the zip, then ends with exit <ExitCode>; after the printed command the same command ends clean' -ForEach @(
        @{ Label = 'every subscription collected'; Fail = @(); InZip = @('A', 'B', 'C'); ExitCode = 1 },
        # A failed subscription is exit 2, which keeps its code over the stop.
        @{ Label = 'Sub B failing'; Fail = @('B'); InZip = @('A', 'C'); ExitCode = 2 }
    ) {
        script:Set-Scenario -RenameRefused $script:Stream5Name -Fail $Fail
        $Seeded = script:Write-StreamText -Text ('{"Completed": ["sub-a"], "FailedAttempts": "' + $script:Marker + '"}') -StreamId 5
        $Stale = Join-Path $script:Root $script:Stream5Name
        $R1 = script:Invoke-Wrapper -Streams 2
        $R1.ExitCode | Should -Be $ExitCode
        $R1.Error | Should -BeNullOrEmpty
        # At the merge: the notice; the file left alone.
        @(script:Get-StopLines $R1).Count | Should -Be 2
        script:Get-StopLines $R1 | Should -BeLike ('ERROR: The per-stream state file {0} is not the right shape (FailedAttempts is not a list), and it could not be moved aside: *' -f $script:Stream5Name)
        $R1.Text | Should -Contain $script:MergeNotice
        Get-Content -LiteralPath $Stale -Raw | Should -Be $Seeded
        script:Get-MovedAside | Should -BeNullOrEmpty
        # The rest of the run as usual: the consolidated zip with every collected
        # report once (nothing lost, nothing doubled) and the run's summary files,
        # the main summary, the end-of-run summary with its failure list.
        @(script:Get-Calls) | Should -Be (script:Get-Ids 'A', 'B', 'C')
        $Bundles = @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'AllSubscriptions_*.zip')
        $Bundles.Count | Should -Be 1
        $Entries = @(script:Get-ZipEntries | Where-Object { $_.Zip -eq $Bundles[0].Name })
        @($Entries | Where-Object { $_.Name -like 'ResourcesReport_*.zip' } | ForEach-Object { $_.Name -replace '^.*(sub-[a-z])\.zip$', '$1' } | Sort-Object) | Should -Be (script:Get-Ids $InZip)
        @($Entries | ForEach-Object { $_.Name }) | Should -Contain 'RunSummary.log'
        @($Entries | ForEach-Object { $_.Name }) | Should -Contain 'MainSummary.html'
        @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'MainSummary_*.html').Count | Should -Be 1
        $R1.Text | Should -Contain '================ Summary ================'
        if ($Fail.Count -gt 0)
        {
            @($R1.Text | Where-Object { $_ -like 'Subscriptions Failed:    1 (Sub B *' }).Count | Should -Be 1
            @($R1.Text | Where-Object { $_ -like 'Failure Diagnostics:     *' }).Count | Should -Be 1
        }
        $R1.Text | Should -Not -Contain 'Resume state cleared (clean run).'
        script:Assert-NotInAnyZip
        # The run's own per-stream files merged and removed as usual; at its end, the stop.
        @(script:Get-LiveStateFiles | Where-Object { $_ -like '*-stream-*' }) | Should -Be @($script:Stream5Name)
        $Last = @($R1.Text | Where-Object { $_ -match '\S' })
        $At = [array]::IndexOf($Last, $script:StopAfter)
        $At | Should -BeGreaterThan ([array]::IndexOf($Last, '================ Summary ================'))
        $Last[$At - 1] | Should -BeLike ('ERROR: The per-stream state file {0} *' -f $script:Stream5Name)
        @($Last[($At + 1)..($Last.Count - 1)]) | Should -Be @($script:LaterStream, $script:RemoveLead, ("  Remove-Item -LiteralPath '{0}' -Force" -f $Stale), $script:ThenSame)

        # The cause gone; the printed command, then the same command.
        script:Set-Scenario
        $Cmd = @(script:Get-RemoveCommand $R1)[0]
        & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command $Cmd
        Test-Path -LiteralPath $Stale | Should -BeFalse
        $R2 = script:Invoke-Wrapper -Streams 2
        $R2.ExitCode | Should -Be 0
        $R2.Error | Should -BeNullOrEmpty
        @(script:Get-StopLines $R2) + @(script:Get-ShapeWarnings $R2) | Should -BeNullOrEmpty
        script:Test-CleanLine $R2 | Should -BeTrue
        script:Get-LiveStateFiles | Should -BeNullOrEmpty
        $Newest = @(Get-ChildItem -LiteralPath $script:Root -Force -File -Filter 'AllSubscriptions_*.zip' | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)
        @(script:Get-ZipEntries | Where-Object { $_.Zip -eq $Newest[0].Name -and $_.Name -like 'ResourcesReport_*.zip' } | ForEach-Object { $_.Name -replace '^.*(sub-[a-z])\.zip$', '$1' } | Sort-Object) | Should -Be (script:Get-Ids 'A', 'B', 'C')
    }

    It 'the end-of-run stop keeps exit 2 when a report is missing; the next -Resume stops at its start with exit 1, and after the printed command the run ends clean' {
        script:Set-Scenario -NoZip 'B'
        $Control = script:Invoke-Wrapper -Streams 2
        $Control.ExitCode | Should -Be 2
        script:New-Case
        $StaleName = '.resume-state-{0}-stream-5.json' -f $script:Tenant
        script:Set-Scenario -NoZip 'B' -RenameRefused $StaleName
        $null = script:Write-StreamText -Text '{"Completed": ["sub-a"], "FailedAttempts": "garbage"}' -StreamId 5
        $Stale = Join-Path $script:Root $StaleName
        # Run 1: a report is missing, so exit 2 keeps its code; the stop still
        # names the file and the command that removes it.
        $R = script:Invoke-Wrapper -Streams 2
        $R.ExitCode | Should -Be 2
        $R.Text | Should -Contain $script:MergeNotice
        $R.Text | Should -Contain 'ERROR: Per-subscription output verification failed.'
        $R.Text | Should -Contain $script:StopAfter
        $R.Text | Should -Contain $script:ThenSame
        @(script:Get-RemoveCommand $R).Count | Should -Be 1
        Test-Path -LiteralPath $Stale | Should -BeTrue
        # Run 2: a -Resume reads the file at its start and stops there with exit 1,
        # before it collects anything.
        $CallsBefore = @(script:Get-Calls).Count
        $R2 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        $R2.ExitCode | Should -Be 1
        @(script:Get-StopLines $R2).Count | Should -Be 1
        @(script:Get-Calls).Count | Should -Be $CallsBefore
        # Run 3: the cause gone, the printed command, then the same -Resume: it
        # collects the subscription whose report was missing and ends clean.
        script:Set-Scenario
        & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command (@(script:Get-RemoveCommand $R2)[0])
        Test-Path -LiteralPath $Stale | Should -BeFalse
        $R3 = script:Invoke-Wrapper -Arguments '-Resume' -Streams 2
        $R3.ExitCode | Should -Be 0
        script:Test-CleanLine $R3 | Should -BeTrue
    }
}

# With the parallel -Resume change, every run without -Resume or
# -ResumeFailedOnly writes a run id into the resume state file, and a run that
# ends clean removes the per-stream files of other runs.
Describe 'Wrapper end to end: per-stream state files and run ids' -Skip:$IsWindows {
    BeforeEach {
        script:New-Case
        $script:Stream1Name = '.resume-state-{0}-stream-1.json' -f $script:Tenant
    }

    It 'a one-stream run without either switch leaves a wrong-shaped per-stream file (<Label>) as it is on two runs: not removed or named as another run''s; a -Resume then moves it aside' -ForEach @(
        @{ Label = 'without a run id'; RunIdPart = '' },
        @{ Label = 'with another run''s id'; RunIdPart = '"RunId": "run-earlier", ' }
    ) {
        script:Set-Scenario
        $Seeded = script:Write-StreamText -Text ('{"Tenant": "' + $script:Tenant + '", "StreamId": "0", ' + $RunIdPart + '"Completed": ["sub-a"], "FailedAttempts": "' + $script:Marker + '"}')
        $StreamPath = Join-Path $script:Root $script:Stream0Name
        $SeededBytes = [System.IO.File]::ReadAllBytes($StreamPath)
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper
            $R.ExitCode | Should -Be 0
            $R.Error | Should -BeNullOrEmpty
            @(script:Get-StopLines $R) + @(script:Get-ShapeWarnings $R) | Should -BeNullOrEmpty
            @($R.Text | Where-Object { $_ -like 'Removed the per-stream state files *' -or $_ -like '*were written by another run*' -or $_ -like 'WARNING: Could not remove the per-stream state file *' }) | Should -BeNullOrEmpty
            script:Get-Collected $R | Should -Be (script:Get-Ids 'A', 'B', 'C')
            # As on the change alone: this run does not use the file.
            script:Test-CleanLine $R | Should -BeTrue
            [System.IO.File]::ReadAllBytes($StreamPath) | Should -Be $SeededBytes
        }
        $R3 = script:Invoke-Wrapper -Arguments '-Resume'
        $null = script:Assert-MovedAside -Run $R3 -FileName $script:Stream0Name -Field 'FailedAttempts is not a list' -Content $Seeded
    }

    It 'a run without either switch that uses two streams (<Label>) stops for a per-stream file it cannot move aside before it writes any resume state, on two runs; after the printed command a -ResumeFailedOnly still uses the earlier run''s per-stream file' -ForEach @(
        @{ Label = '-ParallelStreams 2'; Streams = 2 },
        @{ Label = 'no -ParallelStreams, two chosen for the host'; Streams = 0 }
    ) {
        # An earlier interrupted run (id run-earlier): Sub A completed, and its
        # stream 1 holds Sub B completed and Sub C failed. Stream 0 is stuck.
        script:Set-Scenario -RenameRefused $script:Stream0Name
        $Now = (Get-Date).ToUniversalTime().ToString('o')
        script:Write-RawText -Path $script:State -Text ('{"TenantID": "' + $script:Tenant + '", "CompletedSubscriptionIds": ["sub-a"], "FailedAttempts": [], "RunId": "run-earlier", "LastUpdated": "' + $Now + '"}')
        $MainBytes = [System.IO.File]::ReadAllBytes($script:State)
        $Entry = script:New-RetryEntry -Letter 'C' | ConvertTo-Json -Compress
        $Stream1 = script:Write-StreamText -StreamId 1 -Text ('{"Tenant": "' + $script:Tenant + '", "StreamId": "1", "RunId": "run-earlier", "Completed": ["sub-b"], "FailedAttempts": [' + $Entry + ']}')
        $Stuck = script:Write-StreamText -Text ('{"Completed": 5, "FailedAttempts": "' + $script:Marker + '"}')
        $R = $null
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Streams $Streams -Environment $script:FourCpu
            if ($Streams -eq 0 -and (script:Get-StreamCount $R) -ne 2) { Set-ItResult -Skipped -Because ('this host chose {0} stream(s), not 2' -f (script:Get-StreamCount $R)); return }
            $R.ExitCode | Should -Be 1
            $R.Error | Should -BeNullOrEmpty
            script:Get-StopLines $R | Should -BeLike ('ERROR: The per-stream state file {0} is not the right shape (Completed is not a list), and it could not be moved aside: *' -f $script:Stream0Name)
            $R.Text | Should -Contain $script:StopStart
            [System.IO.File]::ReadAllBytes($script:State) | Should -Be $MainBytes
            Test-Path -LiteralPath ($script:State + '.tmp') | Should -BeFalse
            Get-Content -LiteralPath (Join-Path $script:Root $script:Stream1Name) -Raw | Should -Be $Stream1
            Get-Content -LiteralPath (Join-Path $script:Root $script:Stream0Name) -Raw | Should -Be $Stuck
            script:Get-Calls | Should -BeNullOrEmpty
        }
        script:Set-Scenario
        & $script:Pwsh -NoLogo -NoProfile -NonInteractive -Command (@(script:Get-RemoveCommand $R)[0])
        $R3 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly'
        $R3.Error | Should -BeNullOrEmpty
        $R3.Text | Should -Contain 'Recovered per-stream state from an interrupted parallel run: 1 completed, 1 failed subscription record(s).'
        @($R3.Text | Where-Object { $_ -like '*Nothing to retry*' }) | Should -BeNullOrEmpty
        script:Get-Collected $R3 | Should -Be (script:Get-Ids 'C')
    }

    It 'with no resume state file, a run without either switch that uses two streams and stops for a per-stream file it cannot move aside creates none, on two runs' {
        script:Set-Scenario -RenameRefused $script:Stream0Name
        $null = script:Write-StreamText -Text ('{"Completed": 5, "FailedAttempts": "' + $script:Marker + '"}')
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper -Streams 2
            $R.ExitCode | Should -Be 1
            $R.Text | Should -Contain $script:StopStart
            Test-Path -LiteralPath $script:State | Should -BeFalse
            script:Get-LiveStateFiles | Should -Be @($script:Stream0Name)
        }
    }

    # The line that names another run's per-stream state files, at the end of a
    # run that is not clean and at an early exit (Exit-Wrapper).
    It 'the other-run line names only the right-shaped file of another run, never a wrong-shaped one, once (<Label>)' -ForEach @(
        @{ Label = '-Resume stopped at its start'; Arguments = @('-Resume'); Streams = 1; Stuck = 0; MainRunId = 'run-earlier' },
        @{ Label = 'a two-stream run without either switch stopped before its streams start'; Arguments = @(); Streams = 2; Stuck = 0; MainRunId = 'run-earlier' },
        @{ Label = 'a two-stream run without either switch stopped at its end'; Arguments = @(); Streams = 2; Stuck = 5; MainRunId = '' }
    ) {
        $StuckName = '.resume-state-{0}-stream-{1}.json' -f $script:Tenant, $Stuck
        $OtherName = '.resume-state-{0}-stream-6.json' -f $script:Tenant
        script:Set-Scenario -RenameRefused $StuckName
        if ($MainRunId)
        {
            script:Write-RawText -Path $script:State -Text ('{"TenantID": "' + $script:Tenant + '", "CompletedSubscriptionIds": [], "FailedAttempts": [], "RunId": "' + $MainRunId + '"}')
        }
        $StuckText = script:Write-StreamText -StreamId $Stuck -Text ('{"Completed": 5, "FailedAttempts": "' + $script:Marker + '"}')
        $Other = script:Write-StreamText -StreamId 6 -Text ('{"Tenant": "' + $script:Tenant + '", "StreamId": "6", "RunId": "run-other", "Completed": [], "FailedAttempts": []}')
        $R = script:Invoke-Wrapper -Arguments $Arguments -Streams $Streams
        $R.ExitCode | Should -Be 1
        $R.Error | Should -BeNullOrEmpty
        script:Get-StopLines $R | Should -BeLike ('ERROR: The per-stream state file {0} is not the right shape (*' -f $StuckName)
        @($R.Text | Where-Object { $_ -like 'The per-stream state files * were written by another run*' }) | Should -Be @(
            ('The per-stream state files {0} were written by another run, so this run does not use them; they are left in place.' -f $OtherName)
        )
        @($R.Text | Where-Object { $_ -like 'Removed the per-stream state files *' }) | Should -BeNullOrEmpty
        Get-Content -LiteralPath (Join-Path $script:Root $StuckName) -Raw | Should -Be $StuckText
        Get-Content -LiteralPath (Join-Path $script:Root $OtherName) -Raw | Should -Be $Other
    }

    It 'a run stopped for a resume state file it cannot move aside (<Label>) names only the right-shaped file of another run, once; the per-stream file of the run that file belongs to is not named' -ForEach @(
        @{ Label = '-Resume'; Arguments = @('-Resume') },
        @{ Label = 'without either switch'; Arguments = @() }
    ) {
        script:Set-Scenario -RenameRefused $script:StateName
        script:Write-RawText -Path $script:State -Text ('{"TenantID": "' + $script:Tenant + '", "CompletedSubscriptionIds": 5, "FailedAttempts": [], "RunId": "run-earlier"}')
        $MainBytes = [System.IO.File]::ReadAllBytes($script:State)
        $Own = script:Write-StreamText -StreamId 1 -Text ('{"Tenant": "' + $script:Tenant + '", "StreamId": "1", "RunId": "run-earlier", "Completed": ["sub-b"], "FailedAttempts": []}')
        $OtherName = '.resume-state-{0}-stream-6.json' -f $script:Tenant
        $Other = script:Write-StreamText -StreamId 6 -Text ('{"Tenant": "' + $script:Tenant + '", "StreamId": "6", "RunId": "run-other", "Completed": [], "FailedAttempts": []}')
        $R = script:Invoke-Wrapper -Arguments $Arguments
        $R.ExitCode | Should -Be 1
        $R.Error | Should -BeNullOrEmpty
        script:Get-StopLines $R | Should -BeLike ('ERROR: The resume state file {0} is not the right shape (CompletedSubscriptionIds is not a list), and it could not be moved aside: *' -f $script:StateName)
        @($R.Text | Where-Object { $_ -like 'The per-stream state files * were written by another run*' }) | Should -Be @(
            ('The per-stream state files {0} were written by another run, so this run does not use them; they are left in place.' -f $OtherName)
        )
        [System.IO.File]::ReadAllBytes($script:State) | Should -Be $MainBytes
        Get-Content -LiteralPath (Join-Path $script:Root $script:Stream1Name) -Raw | Should -Be $Own
        Get-Content -LiteralPath (Join-Path $script:Root $OtherName) -Raw | Should -Be $Other
        script:Get-Calls | Should -BeNullOrEmpty
    }
}
