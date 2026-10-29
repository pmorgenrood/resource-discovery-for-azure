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
#     that cannot be moved aside is not used either. Empty state files are
#     handled as before. The moved-aside file is in no zip, with and without
#     -Obfuscate.
#
# The end-to-end runs start Run-AllSubscriptions.ps1 itself as its own pwsh
# process from a copy of the tool whose ResourceInventory.ps1 is a stand-in.
# Azure is a set of stand-in Az modules and an az command, found first on the
# module path and PATH of that process, which answer from a scenario file: the
# subscriptions, the ones that fail, and whether the inventory root becomes
# read-only once the subscriptions are listed. The process's home is a scratch folder,
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
if (@($Scenario.FailIds) -contains $SubscriptionID) { throw 'stand-in failure for this subscription' }
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
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context) Get-RdaStandInContext }
function Import-AzContext { [CmdletBinding()] param($Path) Get-RdaStandInContext }
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
        param([string[]]$Subs = @('A', 'B', 'C'), [string[]]$Fail = @(), [switch]$ReadOnlyRoot)
        [pscustomobject]@{
            Tenant        = $script:Tenant
            Subscriptions = @($Subs | ForEach-Object { [pscustomobject]@{ Id = $script:Subs[$_].Id; Name = $script:Subs[$_].Name; State = 'Enabled' } })
            FailIds       = @($Fail | ForEach-Object { $script:Subs[$_].Id })
            ReadOnlyRoot  = [bool]$ReadOnlyRoot
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One run of the wrapper as its own process, stdin closed. A run that has
    # not ended after $TimeoutSeconds is stopped and the test fails.
    function script:Invoke-Wrapper
    {
        param([string[]]$Arguments = @(), [int]$Streams = 1, [int]$TimeoutSeconds = 300)
        $All = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper, '-TenantID', $script:Tenant, '-ParallelStreams', [string]$Streams)
        $Info = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($Arg in @($All) + @($Arguments)) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['PATH'] = $script:Bin + [IO.Path]::PathSeparator + $env:PATH
        $Info.Environment['RDA_STANDIN_AZURE'] = $script:Scenario
        $Info.Environment['NO_COLOR'] = '1'
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
        param([object]$FailedAttempts, [string[]]$Completed = @('A'))
        [pscustomobject]@{
            TenantID                 = $script:Tenant
            CompletedSubscriptionIds = @($Completed | ForEach-Object { $script:Subs[$_].Id })
            FailedAttempts           = $FailedAttempts
            LastUpdated              = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:State -Encoding utf8
        return (Get-Content -LiteralPath $script:State -Raw)
    }
    function script:Write-StreamText
    {
        param([string]$Text, [int]$StreamId = 0)
        $Path = Join-Path $script:Root ('.resume-state-{0}-stream-{1}.json' -f $script:Tenant, $StreamId)
        Set-Content -LiteralPath $Path -Value $Text -Encoding utf8
        return (Get-Content -LiteralPath $Path -Raw)
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
        @{ Kind = 'Main'; Label = 'with an empty id in CompletedSubscriptionIds'; Json = '{"TenantID":"t","CompletedSubscriptionIds":["sub-a",""]}'; Expected = 'CompletedSubscriptionIds holds an empty id' },
        @{ Kind = 'Main'; Label = 'with a whitespace-only id in CompletedSubscriptionIds, after a null'; Json = '{"TenantID":"t","CompletedSubscriptionIds":[null,"   "]}'; Expected = 'CompletedSubscriptionIds holds an empty id' },
        @{ Kind = 'Stream'; Label = 'with an empty id in Completed'; Json = '{"Completed":[""],"FailedAttempts":[]}'; Expected = 'Completed holds an empty id' },
        @{ Kind = 'Stream'; Label = 'with a whitespace-only id in Completed'; Json = '{"Completed":["sub-a"," \t "],"FailedAttempts":[]}'; Expected = 'Completed holds an empty id' },
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

    It 'with -Resume also says what this run does: <Kind>' -TestCases @(
        @{ Kind = 'Main'; Name = '.resume-state-t.json'; Json = '{"TenantID":"t","CompletedSubscriptionIds":"x"}'; Then = "  Starting fresh: this run does not use that file's completed list or retry list." },
        @{ Kind = 'Stream'; Name = '.resume-state-t-stream-1.json'; Json = '{"Completed":5}'; Then = '  This run does not count the subscriptions it lists as completed.' }
    ) {
        $Path = Join-Path $script:Dir $Name
        Set-Content -LiteralPath $Path -Value $Json
        $Lines = @(Move-WrongShapeResumeStateFile -Path $Path -Kind $Kind -Resume -Now $script:Now 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $Lines.Count | Should -Be 2
        $Lines[0] | Should -BeLike ('WARNING: The *state file {0} is not the right shape*' -f $Name)
        $Lines[1] | Should -Be $Then
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

    It 'when the name and -2 to -100 are all taken, says it could not be moved aside and leaves the file' {
        $Path = Join-Path $script:Dir '.resume-state-t.json'
        $Base = '.resume-state-t.json.unreadable-20260102-030405'
        New-Item -ItemType File -Path (Join-Path $script:Dir $Base) | Out-Null
        foreach ($N in 2..100) { New-Item -ItemType File -Path (Join-Path $script:Dir ('{0}-{1}' -f $Base, $N)) | Out-Null }
        Set-Content -LiteralPath $Path -Value '{"TenantID":"t","CompletedSubscriptionIds":5}'
        $Out = @(Move-WrongShapeResumeStateFile -Path $Path -Kind Main -Now $script:Now 6>&1)
        $Result = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        $Lines = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $Result[0].MovedTo | Should -BeNullOrEmpty
        $Lines[0] | Should -Be ('WARNING: The resume state file .resume-state-t.json is not the right shape (CompletedSubscriptionIds is not a list), so its records are not used. It could not be moved aside (every name from {0} to {0}-100 is taken), so a later run finds it again.' -f $Base)
        Test-Path -LiteralPath $Path | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:Dir -Force).Count | Should -Be 101
    }

    It 'Write-WrongShapeStateSummary names each file and never says clean run' {
        $Files = @(
            [pscustomobject]@{ Kind = 'Main'; Name = '.resume-state-t.json'; MovedTo = '.resume-state-t.json.unreadable-20260102-030405' },
            [pscustomobject]@{ Kind = 'Stream'; Name = '.resume-state-t-stream-1.json'; MovedTo = $null }
        )
        $Lines = @(Write-WrongShapeStateSummary -Files $Files -StateKept $false 6>&1 | ForEach-Object { [string]$_.MessageData })
        $Lines | Should -Be @(
            'Resume state cleared, but not a clean run: the resume state file .resume-state-t.json was not the right shape and was moved aside to .resume-state-t.json.unreadable-20260102-030405; its records were not used.',
            'Resume state cleared, but not a clean run: the per-stream state file .resume-state-t-stream-1.json was not the right shape and could not be moved aside; its records were not used.'
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
        $R1.Text | Should -Contain "  Starting fresh: this run does not use that file's completed list or retry list."
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

    It 'beside a right-shaped per-stream file, -Resume says only that it does not use the moved file, and still skips what the stream file lists' {
        # The moved file lists B as completed; the per-stream file lists A.
        script:Set-Scenario
        $Seeded = script:Write-MainState -FailedAttempts $script:Marker -Completed 'B'
        $null = script:Write-StreamText -Text ('{"Tenant": "' + $script:Tenant + '", "StreamId": "0", "Completed": ["sub-a"], "FailedAttempts": []}')
        $R1 = script:Invoke-Wrapper -Arguments '-Resume'
        # The exit code is not checked: it also depends on whether the report of
        # a subscription skipped as completed can be put in this run's zip.
        $null = script:Assert-MovedAside -Run $R1 -FileName $script:StateName -Field 'FailedAttempts is not a list' -Content $Seeded
        $Lines = @($R1.Text | Where-Object { $_ -like '  Starting fresh*' -or $_ -like 'Recovered per-stream state*' -or $_ -like 'Resume mode:*' -or $_ -like 'Skipping (already completed):*' })
        $Lines | Should -Be @(
            "  Starting fresh: this run does not use that file's completed list or retry list.",
            'Recovered per-stream state from an interrupted parallel run: 1 completed, 0 failed subscription record(s).',
            'Resume mode: 1 previously completed subscription(s) will be skipped.',
            'Skipping (already completed): Sub A (sub-a)'
        )
        # B, listed as completed only in the moved file, is collected.
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'B', 'C')
    }

    It 'a <Label> resume state file is handled as before: -ResumeFailedOnly has nothing to retry and exits 0, nothing is moved' -TestCases @(
        @{ Label = '0-byte'; Text = '' },
        @{ Label = 'whitespace-only'; Text = "  `n`t`n " }
    ) {
        script:Set-Scenario
        script:Write-RawText -Path $script:State -Text $Text
        $R1 = script:Invoke-Wrapper -Arguments '-ResumeFailedOnly'
        $R1.ExitCode | Should -Be 0
        $R1.Error | Should -BeNullOrEmpty
        @(script:Get-ShapeWarnings $R1) | Should -BeNullOrEmpty
        script:Get-MovedAside | Should -BeNullOrEmpty
        $R1.Text | Should -Contain 'ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry.'
        @($R1.Text | Where-Object { $_ -like 'ResumeFailedOnly: stopped*' }) | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllText($script:State) | Should -Be $Text
    }

    It 'a wrong-shaped resume state file that cannot be moved aside is not used either' {
        # The inventory root becomes read-only after the run's write probe, so the
        # rename fails. Skipped where a read-only folder can still be written (root).
        $Probe = Join-Path $script:CaseHome 'ro-probe'
        New-Item -ItemType Directory -Path $Probe | Out-Null
        & chmod 555 $Probe
        $Refused = try { Set-Content -LiteralPath (Join-Path $Probe 'x') -Value 'x' -ErrorAction Stop; $false } catch { $true }
        & chmod 755 $Probe
        if (-not $Refused) { Set-ItResult -Skipped -Because 'a read-only folder can still be written here'; return }

        script:Set-Scenario -ReadOnlyRoot
        $Seeded = script:Write-MainState -FailedAttempts $script:Marker -Completed 'A'
        try { $R1 = script:Invoke-Wrapper -Arguments '-Resume' }
        finally { & chmod 755 $script:Root }
        @(script:Get-ShapeWarnings $R1) | Should -BeLike ('WARNING: The resume state file {0} is not the right shape (FailedAttempts is not a list), so its records are not used. It could not be moved aside (*), so a later run finds it again.' -f $script:StateName)
        # A, listed as completed in the file, is not skipped.
        $R1.Text | Should -Contain 'Resume mode: no previous state found; processing all subscriptions.'
        @($R1.Text | Where-Object { $_ -like 'Skipping (already completed):*' }) | Should -BeNullOrEmpty
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'A', 'B', 'C')
        $R1.Text | Should -Not -Contain 'Resume state cleared (clean run).'
        $R1.Error | Should -Not -Match 'Cannot convert'
        Get-Content -LiteralPath $script:State -Raw | Should -Be $Seeded
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
        $R1.ExitCode | Should -Be 0
        $R1.Error | Should -BeNullOrEmpty
        @(script:Get-ShapeWarnings $R1) | Should -BeNullOrEmpty
        @($R1.Text | Where-Object { $_ -like 'ResumeFailedOnly: stopped*' }) | Should -BeNullOrEmpty
        $R1.Text | Should -Contain 'ResumeFailedOnly: filtered to 1 previously-failed subscription(s) (was 2).'
        script:Get-Collected $R1 | Should -Be (script:Get-Ids 'B')
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
