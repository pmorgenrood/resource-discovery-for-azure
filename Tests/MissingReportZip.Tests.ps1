# Run-AllSubscriptions.ps1: a subscription whose report zip is missing
#
# A subscription can be collected and still leave no report zip: the collector
# circuit breaker stops ResourceInventory.ps1 under -RunAllSubs with exit 0 and
# no zip (Tests/NoReportExitCode.Tests.ps1), and a zip that was written can be
# gone before the wrapper builds the consolidated zip (an antivirus quarantine,
# for example). The run then builds AllSubscriptions_ResourcesReport_<stamp>.zip
# from the reports that exist, names the missing ones on the console and in
# RunSummary.log, keeps the resume state with them on the retry list and exits
# 2. The next run continues that run: it collects the missing ones again,
# carries the others and ends clean.
#
# Every run is the real Run-AllSubscriptions.ps1 (and its stream worker),
# started as its own pwsh process with -File (stdin closed) from a copy of the
# tool whose ResourceInventory.ps1 is a stand-in that writes one report folder
# and zip per call, writes the folder but no zip for a subscription the scenario
# names, can record a subscription's metrics as incomplete, and can remove
# another subscription's zip. Azure is a set of stand-in
# Az modules first on the module path. The process's home is a scratch folder,
# so the run writes its inventory root under it. On Windows the wrapper writes
# to C:\InventoryReports instead, so these tests do not run there. Placeholder
# ids only. No live Azure.
#
# Run with: Invoke-Pester ./Tests/MissingReportZip.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('MissingReportZip_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
    $script:Tenant = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @('a', 'b', 'c' | ForEach-Object { [pscustomobject]@{ Id = [guid]::new(('0' * 31) + $_).ToString(); Name = ('Sub ' + $_.ToUpperInvariant()) } })

    $script:ToolRoot = Join-Path $script:TestBase 'tool'
    New-Item -ItemType Directory -Path $script:ToolRoot -Force | Out-Null
    foreach ($Item in @('Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1', 'Version.json', 'Functions', 'Extension'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:ToolRoot -Recurse -Force
    }
    $script:Wrapper = Join-Path $script:ToolRoot 'Run-AllSubscriptions.ps1'
    @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
$Scenario = Get-Content -LiteralPath $env:RDA_STANDIN_AZURE -Raw | ConvertFrom-Json
$Root = Join-Path $HOME 'InventoryReports'
# The folder name ends with the subscription id, so a scenario can find it.
$Stamp = (Get-Date -Format 'yyyyMMddHHmmssfff') + '-' + $SubscriptionID
$Folder = Join-Path $Root ('ResourcesReport' + $Stamp)
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
Set-Content -LiteralPath (Join-Path $Folder ('Inventory_ResourcesReport_{0}.json' -f $Stamp)) -Value ('{"VirtualMachines":[{"Name":"vm","Subscription":"' + $SubscriptionID + '"}]}') -Encoding utf8
Set-Content -LiteralPath (Join-Path $Folder ('ResourcesReport_{0}.html' -f $Stamp)) -Value '<html></html>' -Encoding utf8
$Global:Resources = @(1)
$Global:ResourceCount = 1
# Metrics left incomplete, recorded the way Extension/Metrics.ps1 records them.
if (@($Scenario.Incomplete) -contains $SubscriptionID)
{
    if ($null -eq $Global:MetricsFailedSubs) { $Global:MetricsFailedSubs = @() }
    $Global:MetricsFailedSubs += [pscustomobject]@{ Name = [string](@($Scenario.Subscriptions | Where-Object { $_.Id -eq $SubscriptionID })[0].Name); Id = $SubscriptionID; Message = 'stand-in: a grouped Azure Monitor request still failed after its retries.'; ReportFolder = $Folder; Complete = $false }
}
# A zip written earlier in this run, removed now (as by an antivirus quarantine).
if ([string]$Scenario.GoneBy -eq $SubscriptionID)
{
    Get-ChildItem -LiteralPath $Root -Directory -Filter ('ResourcesReport*-' + [string]$Scenario.GoneSub) | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.zip' -File | Remove-Item -Force }
}
if (@($Scenario.NoZip) -contains $SubscriptionID) { $Global:ZipOutputFile = $null; return }
$Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
Compress-Archive -Path (Join-Path $Folder '*.json') -DestinationPath $Zip -Force
$Global:ZipOutputFile = $Zip
'@ | Set-Content -LiteralPath (Join-Path $script:ToolRoot 'ResourceInventory.ps1') -Encoding utf8

    # Stand-in Az.Accounts: sign-in, context, token and subscription calls, the
    # up-front role checks and the per-subscription resource count.
    $Accounts = @'
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
function Get-AzContext { [CmdletBinding()] param([switch]$ListAvailable) Get-RdaStandInContext }
function Set-AzContext { [CmdletBinding()] param($Subscription, $Tenant, $Context, $Scope) if ($Subscription) { $script:ContextSub = [string]$Subscription }; Get-RdaStandInContext }
function Import-AzContext { [CmdletBinding()] param($Path) Get-RdaStandInContext }
function Save-AzContext { [CmdletBinding()] param($Path, [switch]$Force) Set-Content -LiteralPath $Path -Value '{}' }
function Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function Get-AzContextAutosaveSetting { [CmdletBinding()] param($Scope) [pscustomobject]@{ Mode = 'Process'; ContextFile = 'None'; CacheFile = 'None' } }
function Connect-AzAccount { [CmdletBinding()] param($Tenant, [switch]$UseDeviceAuthentication) throw 'stand-in: no sign-in expected' }
function Get-AzAccessToken
{
    [CmdletBinding()] param($TenantId, $ResourceUrl, [switch]$AsSecureString, $ResourceTypeName)
    $Claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"stand-in-caller"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $Tenant = if ($TenantId) { [string]$TenantId } else { (Get-RdaStandInScenario).Tenant }
    [pscustomobject]@{ Token = ('e30.{0}.c2ln' -f $Claims); Type = 'Bearer'; ExpiresOn = (Get-Date).AddHours(1); TenantId = $Tenant }
}
function Get-AzSubscription
{
    [CmdletBinding()] param($TenantId, $SubscriptionId, $SubscriptionName)
    $Scenario = Get-RdaStandInScenario
    @($Scenario.Subscriptions | Where-Object { -not $SubscriptionId -or $_.Id -eq $SubscriptionId } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; SubscriptionId = $_.Id; Name = $_.Name; State = 'Enabled'; TenantId = $Scenario.Tenant; HomeTenantId = $Scenario.Tenant } })
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
        if (@((Get-RdaStandInScenario).NoRole) -contains $Id) { return & $Answer 200 @{ value = @() } }
        return & $Answer 200 @{ value = @(@{ properties = @{ scope = "/subscriptions/$Id"; principalId = 'stand-in-caller'; roleDefinitionId = "/subscriptions/$Id/providers/Microsoft.Authorization/roleDefinitions/stand-in-reader" } }) }
    }
    if ($Path -match '/providers/Microsoft\.Authorization/roleDefinitions/[^/?]+\?') { return & $Answer 200 @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } } }
    if ($Path -match '/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/permissions\?' -and @((Get-RdaStandInScenario).NoRole) -contains $Matches[1]) { return & $Answer 200 @{ value = @() } }
    if ($Path -match '/subscriptions/([^/?]+)/providers/Microsoft\.Authorization/permissions\?') { return & $Answer 200 @{ value = @(@{ actions = @('*/read'); notActions = @() }) } }
    if ($Path -like '*Microsoft.ResourceGraph/resources*')
    {
        $Ids = @(($Payload | ConvertFrom-Json).subscriptions | ForEach-Object { [string]$_ })
        return & $Answer 200 @{ data = @($Ids | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 1 } }) }
    }
    return & $Answer 404 @{ error = @{ code = 'NotFound'; message = 'stand-in: no answer for this path' } }
}
'@
    $script:Modules = Join-Path $script:TestBase 'modules'
    foreach ($Module in @(@{ Name = 'Az.Accounts'; Body = $Accounts }, @{ Name = 'Az.Compute'; Body = '' }, @{ Name = 'Az.Monitor'; Body = '' }, @{ Name = 'Az.Billing'; Body = '' }))
    {
        $Dir = Join-Path $script:Modules (Join-Path $Module.Name '99.0.0')
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psm1')) -Value $Module.Body -Encoding utf8
        Set-Content -LiteralPath (Join-Path $Dir ($Module.Name + '.psd1')) -Value ("@{{ ModuleVersion = '99.0.0'; RootModule = '{0}.psm1'; FunctionsToExport = '*' }}" -f $Module.Name) -Encoding utf8
    }

    # A fresh home for each case; the scenario file can be rewritten between runs.
    function script:New-Case
    {
        $script:CaseHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseHome -Force | Out-Null
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        $script:Scenario = Join-Path $script:CaseHome 'scenario.json'
        $script:StateFile = Join-Path $script:Root ('.resume-state-{0}.json' -f ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes(([string]$script:Tenant).Trim().ToLowerInvariant()))).Substring(0, 12).ToLowerInvariant()))
    }
    function script:Set-Scenario
    {
        param([string[]]$NoZip = @(), [string]$GoneSub = '', [string]$GoneBy = '', [string[]]$NoRole = @(), [string[]]$Incomplete = @())
        [pscustomobject]@{ Tenant = $script:Tenant; Subscriptions = $script:Subs; NoZip = @($NoZip); GoneSub = $GoneSub; GoneBy = $GoneBy; NoRole = @($NoRole); Incomplete = @($Incomplete) } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One run of the wrapper as its own process, stdin closed: its exit code, its
    # lines, and the consolidated zip it wrote (the inner zips' subscription ids
    # and its RunSummary.log), or $null when it wrote none.
    function script:Invoke-Wrapper
    {
        # -Tool: another copy of the tool to run (the default is the one above).
        param([int]$Streams = 1, [switch]$Obfuscate, [switch]$Fresh, [switch]$ResumeFailedOnly, [switch]$Resume, [string]$Tool = $script:ToolRoot)
        $Before = @(if (Test-Path -LiteralPath $script:Root) { Get-ChildItem -LiteralPath $script:Root -Filter 'AllSubscriptions_*.zip' -File | ForEach-Object { $_.FullName } })
        $Info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
        foreach ($Arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $Tool 'Run-AllSubscriptions.ps1'), '-TenantID', $script:Tenant, '-SkipMetrics', '-SkipConsumption', '-ParallelStreams', [string]$Streams) + @(if ($Obfuscate) { '-Obfuscate' }) + @(if ($Fresh) { '-Fresh' }) + @(if ($ResumeFailedOnly) { '-ResumeFailedOnly' }) + @(if ($Resume) { '-Resume' })) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.WorkingDirectory = $Tool
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['RDA_STANDIN_AZURE'] = $script:Scenario
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
        $Text = @((([string]$Out.Result + [string]$Err.Result) -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        $New = @(Get-ChildItem -LiteralPath $script:Root -Filter 'AllSubscriptions_*.zip' -File -ErrorAction SilentlyContinue | Where-Object { $Before -notcontains $_.FullName })
        $Zip = $null
        if ($New.Count -eq 1)
        {
            $Archive = [System.IO.Compression.ZipFile]::OpenRead($New[0].FullName)
            try
            {
                $Ids = @($Archive.Entries | Where-Object { $_.FullName -like 'ResourcesReport_*.zip' } | ForEach-Object { $_.FullName -replace '^ResourcesReport_.*-([0-9a-f-]{36})\.zip$', '$1' } | Sort-Object)
                $Log = $Archive.Entries | Where-Object { $_.FullName -eq 'RunSummary.log' } | Select-Object -First 1
                $LogLines = @()
                if ($null -ne $Log)
                {
                    $Reader = [System.IO.StreamReader]::new($Log.Open())
                    try { $LogLines = @($Reader.ReadToEnd() -split "`r?`n") } finally { $Reader.Dispose() }
                }
                $Main = $Archive.Entries | Where-Object { $_.FullName -eq 'MainSummary.html' } | Select-Object -First 1
                $MainText = ''
                if ($null -ne $Main)
                {
                    $Reader = [System.IO.StreamReader]::new($Main.Open())
                    try { $MainText = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
                }
                $HtmlCopies = @($Archive.Entries | Where-Object { $_.FullName -like 'HTML*/*.html' } | ForEach-Object { ($_.FullName -split '/')[0] } | Sort-Object -Unique)
                $Zip = [pscustomobject]@{ Ids = $Ids; RunSummary = $LogLines; MainSummary = $MainText; HtmlCopies = $HtmlCopies }
            }
            finally { $Archive.Dispose() }
        }
        $State = if (Test-Path -LiteralPath $script:StateFile) { Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ ExitCode = $Proc.ExitCode; Text = $Text; NewZips = $New.Count; Zip = $Zip; State = $State }
    }

    # Every line of the FAILED (report missing) banner, up to its closing line.
    function script:Get-FullBanner
    {
        param($Run)
        $At = [array]::IndexOf($Run.Text, '================== FAILED (report missing) ==================')
        if ($At -lt 0) { return @() }
        $End = [array]::IndexOf($Run.Text, '=============================================================', $At + 1)
        @($Run.Text[($At + 1)..($End - 1)])
    }
    function script:Get-Ids { param([string[]]$Letters) @($Letters | ForEach-Object { $L = $_; ($script:Subs | Where-Object { $_.Name -eq ('Sub ' + $L) }).Id } | Sort-Object) }
    function script:Get-Banner
    {
        param($Run)
        $At = [array]::IndexOf($Run.Text, '================== FAILED (report missing) ==================')
        if ($At -lt 0) { return @() }
        @($Run.Text[($At + 1)..($Run.Text.Count - 1)] | Select-Object -First 3)
    }
}

AfterAll {
    if ($script:TestBase -and (Test-Path -LiteralPath $script:TestBase)) { Remove-Item -LiteralPath $script:TestBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'A subscription whose report zip is missing' -Skip:$IsWindows {
    It '<Case>: the consolidated zip holds the reports that exist, the missing one is named, and the next run completes it' -ForEach @(
        @{ Case = 'sequential, no zip written'; Streams = 1; NoZip = 'B'; Gone = ''; GoneBy = ''; Missing = 'B'; Kept = @('A', 'C') }
        @{ Case = 'two streams, no zip written'; Streams = 2; NoZip = 'B'; Gone = ''; GoneBy = ''; Missing = 'B'; Kept = @('A', 'C') }
        @{ Case = 'sequential, a written zip gone before the consolidated zip'; Streams = 1; NoZip = ''; Gone = 'A'; GoneBy = 'C'; Missing = 'A'; Kept = @('B', 'C') }
    ) {
        script:New-Case
        $MissingSub = $script:Subs | Where-Object { $_.Name -eq ('Sub ' + $Missing) }
        $GoneId = if ($Gone) { ($script:Subs | Where-Object { $_.Name -eq ('Sub ' + $Gone) }).Id } else { '' }
        $GoneById = if ($GoneBy) { ($script:Subs | Where-Object { $_.Name -eq ('Sub ' + $GoneBy) }).Id } else { '' }
        script:Set-Scenario -NoZip @(if ($NoZip) { ($script:Subs | Where-Object { $_.Name -eq ('Sub ' + $NoZip) }).Id }) -GoneSub $GoneId -GoneBy $GoneById

        $R1 = script:Invoke-Wrapper -Streams $Streams
        $R1.ExitCode | Should -Be 2
        $R1.Text | Should -Contain 'ERROR: Per-subscription output verification failed.'
        $R1.NewZips | Should -Be 1 -Because ($R1.Text -join "`n")
        $R1.Zip.Ids | Should -Be (script:Get-Ids $Kept)
        script:Get-Banner $R1 | Should -Be @(
            '1 subscription(s) completed collection this run, but their report zip is missing, so they are NOT in the consolidated zip:'
            ('  - {0} ({1})' -f $MissingSub.Name, $MissingSub.Id)
            'The resume state is kept. Run the same command again (without -Fresh), or with -Resume: it collects these subscriptions again and carries the other reports into a new consolidated zip.'
        )
        $R1.Zip.RunSummary | Should -Contain '  Report missing      : 1 (completed, but their report zip is not in this zip; the next run collects them)'
        $R1.Zip.RunSummary | Should -Contain ('  - {0} ({1})' -f $MissingSub.Name, $MissingSub.Id)
        $R1.Text | Should -Not -Contain 'Resume state cleared (clean run).'
        $R1.State | Should -Not -BeNullOrEmpty
        @($R1.State.CompletedSubscriptionIds | Sort-Object) | Should -Be (script:Get-Ids $Kept)
        @($R1.State.FailedAttempts | ForEach-Object { [string]$_.Id }) | Should -Be @($MissingSub.Id)
        Test-Path -LiteralPath (Join-Path $script:Root ('.run-lock-{0}.json' -f ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes(([string]$script:Tenant).Trim().ToLowerInvariant()))).Substring(0, 12).ToLowerInvariant()))) | Should -BeFalse

        # The next run, the same command: it continues the unfinished run.
        script:Set-Scenario
        $R2 = script:Invoke-Wrapper -Streams $Streams
        $R2.ExitCode | Should -Be 0 -Because ($R2.Text -join "`n")
        $R2.Text | Should -Contain 'Resume: carrying 2 report(s) of subscription(s) completed by an earlier run into the consolidated zip.'
        $R2.NewZips | Should -Be 1
        $R2.Zip.Ids | Should -Be (script:Get-Ids 'A', 'B', 'C')
        $R2.Text | Should -Contain 'Resume state cleared (clean run).'
        $R2.State | Should -BeNullOrEmpty
    }

    It 'a written zip gone before the consolidated zip, of a subscription whose metrics were left incomplete: it is named, its retry-list entry stays as it was, and the next run completes it' {
        script:New-Case
        $B = $script:Subs | Where-Object { $_.Name -eq 'Sub B' }
        $C = $script:Subs | Where-Object { $_.Name -eq 'Sub C' }
        script:Set-Scenario -Incomplete @($B.Id) -GoneSub $B.Id -GoneBy $C.Id

        $R1 = script:Invoke-Wrapper
        $R1.ExitCode | Should -Be 2 -Because ($R1.Text -join "`n")
        $R1.Zip.Ids | Should -Be (script:Get-Ids 'A', 'C')
        script:Get-Banner $R1 | Should -Be @(
            '1 subscription(s) completed collection this run, but their report zip is missing, so they are NOT in the consolidated zip:'
            ('  - {0} ({1})' -f $B.Name, $B.Id)
            'The resume state is kept. Run again with -Resume: it collects these subscriptions again and carries the other reports into a new consolidated zip.'
        )
        @($R1.State.CompletedSubscriptionIds | Sort-Object) | Should -Be (script:Get-Ids 'A', 'C')
        $Entries = @($R1.State.FailedAttempts)
        @($Entries | ForEach-Object { [string]$_.Id }) | Should -Be @($B.Id)
        $Entries[0].Reason | Should -Be 'Metrics incomplete: stand-in: a grouped Azure Monitor request still failed after its retries.'
        $Entries[0].Attempts | Should -Be 1

        script:Set-Scenario
        $R2 = script:Invoke-Wrapper
        $R2.ExitCode | Should -Be 0 -Because ($R2.Text -join "`n")
        $R2.Zip.Ids | Should -Be (script:Get-Ids 'A', 'B', 'C')
        $R2.Text | Should -Contain 'Resume state cleared (clean run).'
        $R2.State | Should -BeNullOrEmpty
    }

    It 'the found count says what it counts: this run''s report records, plus the reports carried from an earlier run' {
        script:New-Case
        $B = $script:Subs | Where-Object { $_.Name -eq 'Sub B' }
        script:Set-Scenario -NoZip @($B.Id)

        $R1 = script:Invoke-Wrapper
        $R1.ExitCode | Should -Be 2 -Because ($R1.Text -join "`n")
        $R1.Text | Should -Contain "  Found zips:    2 (this run's report records)"

        # The next run carries the reports of A and C and collects B, which again writes no zip.
        $R2 = script:Invoke-Wrapper
        $R2.ExitCode | Should -Be 2 -Because ($R2.Text -join "`n")
        $R2.Text | Should -Contain "  Found zips:    2 (this run's report records, plus 2 carried from an earlier run)"
    }
}

Describe 'The summaries of a consolidated zip that lacks some reports' -Skip:$IsWindows {
    It 'one report missing: both numbers, and the missing subscription named with its reason, in MainSummary.html and RunSummary.log' {
        script:New-Case
        $B = $script:Subs | Where-Object { $_.Name -eq 'Sub B' }
        script:Set-Scenario -NoZip @($B.Id)
        $R = script:Invoke-Wrapper
        $R.ExitCode | Should -Be 2 -Because ($R.Text -join "`n")
        $R.Zip.Ids | Should -Be (script:Get-Ids 'A', 'C')
        $Reason = 'report missing (collected, but its report zip was not written or is gone; the next run collects it)'
        $R.Zip.MainSummary | Should -Match ([regex]::Escape('<b>3 subscription(s) in this run (3 visible to the tenant), 2 report(s) in this zip.</b>'))
        $R.Zip.MainSummary | Should -Match ([regex]::Escape(('<b>1 subscription(s) without a report in this zip:</b><ul><li>Sub B ({0}): {1}</li></ul>' -f $B.Id, $Reason)))
        # Only the reports in the zip are listed and copied.
        ([regex]::Matches($R.Zip.MainSummary, '<tr><td>')).Count | Should -Be 2
        $R.Zip.MainSummary | Should -Not -Match ([regex]::Escape(('<tr><td>{0}</td>' -f $B.Id)))
        $R.Zip.HtmlCopies.Count | Should -Be 2
        $R.Zip.RunSummary | Should -Contain '  3 subscription(s) in this run (3 visible to the tenant), 2 report(s) in this zip.'
        $R.Zip.RunSummary | Should -Contain '  1 subscription(s) without a report in this zip:'
        $R.Zip.RunSummary | Should -Contain ('    - Sub B ({0}): {1}' -f $B.Id, $Reason)
    }

    It 'one report missing and one subscription skipped by the role check: each named with its own reason, the not-readable one without its id' {
        script:New-Case
        $B = $script:Subs | Where-Object { $_.Name -eq 'Sub B' }
        $C = $script:Subs | Where-Object { $_.Name -eq 'Sub C' }
        script:Set-Scenario -NoZip @($B.Id) -NoRole @($C.Id)
        $R = script:Invoke-Wrapper
        $R.ExitCode | Should -Be 2 -Because ($R.Text -join "`n")
        $R.Zip.Ids | Should -Be (script:Get-Ids 'A')
        $R.Zip.MainSummary | Should -Match ([regex]::Escape('<b>3 subscription(s) in this run (3 visible to the tenant), 1 report(s) in this zip.</b>'))
        $R.Zip.MainSummary | Should -Match ([regex]::Escape(('<b>2 subscription(s) without a report in this zip:</b><ul><li>Sub B ({0}): report missing (collected, but its report zip was not written or is gone; the next run collects it)</li><li>Sub C: skipped by the up-front role check (not readable)</li></ul>' -f $B.Id)))
        $R.Zip.HtmlCopies.Count | Should -Be 1
        $R.Zip.RunSummary | Should -Contain '    - Sub C: skipped by the up-front role check (not readable)'
        # No zip a run leaves holds the id of a not-readable subscription.
        $R.Zip.MainSummary | Should -Not -Match ([regex]::Escape($C.Id))
        ($R.Zip.RunSummary -join "`n") | Should -Not -Match ([regex]::Escape($C.Id))
    }

    It 'under -Obfuscate: the numbers and a count for each reason, with no subscription name or id' {
        script:New-Case
        $B = $script:Subs | Where-Object { $_.Name -eq 'Sub B' }
        $C = $script:Subs | Where-Object { $_.Name -eq 'Sub C' }
        script:Set-Scenario -NoZip @($B.Id) -NoRole @($C.Id)
        $R = script:Invoke-Wrapper -Obfuscate
        $R.ExitCode | Should -Be 2 -Because ($R.Text -join "`n")
        $R.Zip.MainSummary | Should -Match ([regex]::Escape('<b>2 subscription(s) without a report in this zip:</b><ul><li>1 report missing</li><li>1 skipped by the role check</li></ul>'))
        $R.Zip.RunSummary | Should -Contain '    - 1 report missing'
        $R.Zip.RunSummary | Should -Contain '    - 1 skipped by the role check'
        foreach ($Sub in @($B, $C))
        {
            $R.Zip.MainSummary | Should -Not -Match ([regex]::Escape($Sub.Id))
            $R.Zip.MainSummary | Should -Not -Match ([regex]::Escape($Sub.Name))
            ($R.Zip.RunSummary -join "`n") | Should -Not -Match ([regex]::Escape($Sub.Id))
        }
    }
}

Describe 'File names in the inventory folder hold no tenant id' -Skip:$IsWindows {
    BeforeAll {
        $script:Key = 'a3a8ee437933'
        function script:Get-TenantNamedFiles
        {
            @(Get-ChildItem -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '12345678-1234-1234-1234-12345678901[0-9]' -or $_.Name -match '12345678' } | ForEach-Object { $_.Name })
        }
    }

    It 'a run interrupted with its resume state under the old name (the tenant id) is continued by the next run, which moves it once; the run after that ends clean and leaves no old-name file' {
        script:New-Case
        $B = $script:Subs | Where-Object { $_.Name -eq 'Sub B' }
        script:Set-Scenario -NoZip @($B.Id)
        $R1 = script:Invoke-Wrapper
        $R1.ExitCode | Should -Be 2 -Because ($R1.Text -join "`n")
        $New = Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Key)
        Test-Path -LiteralPath $New | Should -BeTrue
        # The state as an earlier version of this tool names it.
        $Old = Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Tenant)
        Move-Item -LiteralPath $New -Destination $Old

        script:Set-Scenario
        $R2 = script:Invoke-Wrapper
        $R2.ExitCode | Should -Be 0 -Because ($R2.Text -join "`n")
        @($R2.Text | Where-Object { $_ -like 'Renamed a resume state file*' }) | Should -Be @(('Renamed a resume state file of an earlier version of this tool to .resume-state-{0}.json: file names no longer hold the tenant id.' -f $script:Key))
        $R2.Text | Should -Contain 'Resume: carrying 2 report(s) of subscription(s) completed by an earlier run into the consolidated zip.'
        $R2.Zip.Ids | Should -Be (script:Get-Ids 'A', 'B', 'C')
        $R2.Text | Should -Contain 'Resume state cleared (clean run).'
        script:Get-TenantNamedFiles | Should -BeNullOrEmpty

        $R3 = script:Invoke-Wrapper
        $R3.ExitCode | Should -Be 0 -Because ($R3.Text -join "`n")
        @($R3.Text | Where-Object { $_ -like 'Renamed a resume state file*' }) | Should -BeNullOrEmpty
        $R3.Text | Should -Contain 'Starting a new run.'
        script:Get-TenantNamedFiles | Should -BeNullOrEmpty
    }

    It 'files an earlier version left under the tenant id next to an unfinished run under the tenant key: the next run moves each aside with one line and continues the tenant-key run; the run after prints nothing about them; after each run no file name holds the tenant id' {
        script:New-Case
        $B = $script:Subs | Where-Object { $_.Name -eq 'Sub B' }
        script:Set-Scenario -NoZip @($B.Id)
        $R1 = script:Invoke-Wrapper
        $R1.ExitCode | Should -Be 2 -Because ($R1.Text -join "`n")
        $New = Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Key)
        Test-Path -LiteralPath $New | Should -BeTrue
        # What an earlier version of this tool leaves under the tenant id: its
        # resume state (whose tenant-key name is taken now), a temporary state
        # file, a state file set aside as unreadable and a run lock temporary file.
        Copy-Item -LiteralPath $New -Destination (Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Tenant))
        Set-Content -LiteralPath (Join-Path $script:Root ('.resume-state-{0}.json.tmp' -f $script:Tenant)) -Value '{' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:Root ('.resume-state-{0}-stream-1.json.unreadable-20261101-101010' -f $script:Tenant)) -Value '{' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:Root ('.run-lock-{0}.json.0a1b2c3d.tmp' -f $script:Tenant)) -Value '{}' -Encoding utf8

        script:Set-Scenario
        $R2 = script:Invoke-Wrapper
        $R2.ExitCode | Should -Be 0 -Because ($R2.Text -join "`n")
        @($R2.Text | Where-Object { $_ -like '*of an earlier version of this tool*' } | Sort-Object) | Should -Be @(@(
                ('WARNING: A resume state file of an earlier version of this tool, named with the tenant id, is not used, because .resume-state-{0}.json is there: it was moved aside to .resume-state-{0}.json.earlier-version, which no run reads.' -f $script:Key)
                ('Moved a temporary resume state file of an earlier version of this tool, named with the tenant id, aside to .resume-state-{0}.json.tmp.earlier-version, which no run reads.' -f $script:Key)
                ('Moved a resume state file set aside as unreadable of an earlier version of this tool, named with the tenant id, aside to .resume-state-{0}-stream-1.json.unreadable-20261101-101010.earlier-version, which no run reads.' -f $script:Key)
                ('Moved a temporary run lock file of an earlier version of this tool, named with the tenant id, aside to .run-lock-{0}.json.0a1b2c3d.tmp.earlier-version, which no run reads.' -f $script:Key)
            ) | Sort-Object)
        $R2.Text | Should -Contain 'Resume: carrying 2 report(s) of subscription(s) completed by an earlier run into the consolidated zip.'
        $R2.Zip.Ids | Should -Be (script:Get-Ids 'A', 'B', 'C')
        $R2.Text | Should -Contain 'Resume state cleared (clean run).'
        script:Get-TenantNamedFiles | Should -BeNullOrEmpty
        ($R2.Text -join "`n") | Should -Not -Match '12345678-1234-1234-1234-123456789012\.json|\.resume-state-12345678|\.run-lock-12345678'

        $R3 = script:Invoke-Wrapper
        $R3.ExitCode | Should -Be 0 -Because ($R3.Text -join "`n")
        @($R3.Text | Where-Object { $_ -like '*earlier version of this tool*' }) | Should -BeNullOrEmpty
        $R3.Text | Should -Contain 'Starting a new run.'
        script:Get-TenantNamedFiles | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:Root -Force -Filter '*.earlier-version' | ForEach-Object { $_.Name }).Count | Should -Be 4
    }

    It 'a run lock under the old name is never moved or taken over: the run stops with exit 1 and its remove command; after it the next two runs proceed and name no file with the tenant id' {
        script:New-Case
        script:Set-Scenario
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $OldLock = Join-Path $script:Root ('.run-lock-{0}.json' -f $script:Tenant)
        $Stamp = [datetime]::UtcNow.AddHours(-3).ToString('o')
        Set-Content -LiteralPath $OldLock -Value ('{{"MachineName":"build.other.example","ProcessId":4242,"ProcessStartTimeUtc":"{0}","RunStartTimeUtc":"{0}","HeartbeatUtc":"{0}"}}' -f $Stamp) -Encoding utf8
        $R1 = script:Invoke-Wrapper
        $R1.ExitCode | Should -Be 1
        $R1.Text | Should -Contain ('  Lock file:    {0}' -f $OldLock)
        $Remove = @($R1.Text | Where-Object { $_ -match '^    Remove-Item -LiteralPath ' })
        $Remove | Should -Be @(("    Remove-Item -LiteralPath '{0}' -Force" -f $OldLock))
        Test-Path -LiteralPath $OldLock | Should -BeTrue
        & ([scriptblock]::Create($Remove[0].Trim()))
        foreach ($N in 1, 2)
        {
            $R = script:Invoke-Wrapper
            $R.ExitCode | Should -Be 0 -Because ($R.Text -join "`n")
            script:Get-TenantNamedFiles | Should -BeNullOrEmpty
        }
    }
}

Describe 'The tenant key that names the files in the inventory folder' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    }

    It 'is <Key> for <Case>' -ForEach @(
        @{ Case = 'the placeholder tenant id'; Id = '12345678-1234-1234-1234-123456789012'; Key = 'a3a8ee437933' }
        @{ Case = 'the placeholder tenant id with spaces around it'; Id = '  12345678-1234-1234-1234-123456789012 '; Key = 'a3a8ee437933' }
        @{ Case = 'a tenant in small letters'; Id = 'tenant-b'; Key = 'df6b6a5f230e' }
        @{ Case = 'the same tenant in capitals with spaces around it'; Id = ' TENANT-B  '; Key = 'df6b6a5f230e' }
    ) {
        Get-TenantFileKey -Tenant $Id | Should -BeExactly $Key
    }

    It 'calls neither SHA256.HashData nor Convert.ToHexString, which need .NET 5 (PowerShell 7.1), while the scripts accept PowerShell 7.0' {
        $Ast = (Get-Command -Name Get-TenantFileKey -CommandType Function).ScriptBlock.Ast
        $Members = @($Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.MemberExpressionAst] }, $true) | ForEach-Object { [string]$_.Member })
        $Members | Should -Contain 'ComputeHash'
        $Members | Should -Not -Contain 'HashData'
        $Members | Should -Not -Contain 'ToHexString'
    }
}

Describe 'A tenant key the run cannot work out' -Skip:$IsWindows {
    BeforeAll {
        # A copy of the tool whose Get-TenantFileKey is replaced by Body: the
        # wrapper dot-sources the functions file, so the last definition wins.
        function script:New-BadKeyTool
        {
            param([string]$Body)
            $Dir = Join-Path $script:TestBase ('badkey-' + [guid]::NewGuid().ToString().Substring(0, 8))
            Copy-Item -LiteralPath $script:ToolRoot -Destination $Dir -Recurse
            Add-Content -LiteralPath (Join-Path $Dir 'Functions/RunAllSubscriptions.Functions.ps1') -Value ("`nfunction Get-TenantFileKey {{ param([string]`$Tenant) {0} }}" -f $Body) -Encoding utf8
            return $Dir
        }
        # Every name, write time and content under Path, and the folder's own
        # write time (a file created and removed again changes it).
        function script:Get-FolderSnapshot
        {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) { return @('absent') }
            @(('folder|{0}' -f (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc.Ticks)) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object -Property FullName | ForEach-Object {
                    $Hash = if ($_.PSIsContainer) { '' } else { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
                    '{0}|{1}|{2}' -f $_.FullName.Substring($Path.Length), $_.LastWriteTimeUtc.Ticks, $Hash
                })
        }
        $script:KeyLine = "ERROR: Could not work out the tenant key that names this tenant's files in the inventory folder on PowerShell {0}: {1}. The run stopped before creating or writing any file."
    }

    It '<Case>: exit 1 with one line, and the inventory folder and every file in it are left exactly as they were' -ForEach @(
        @{ Case = 'an empty key'; Body = "return ''"; Problem = 'it came out empty' }
        @{ Case = 'no key at all'; Body = 'return'; Problem = 'it came out empty' }
        @{ Case = 'a key that is not 12 hex characters'; Body = "return 'not-a-key'"; Problem = 'it is not 12 hex characters' }
        @{ Case = 'a key that cannot be computed'; Body = "throw 'stand-in: no hash on this PowerShell'"; Problem = 'stand-in: no hash on this PowerShell' }
    ) {
        script:New-Case
        script:Set-Scenario
        $Tool = script:New-BadKeyTool -Body $Body
        # What a run would read, move or remove: a resume state under the
        # tenant key, one under the tenant id an earlier version used, and a
        # run lock temporary file.
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root '.resume-state-a3a8ee437933.json') -Value '{"CompletedSubscriptionIds":[]}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Tenant)) -Value '{"CompletedSubscriptionIds":[]}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:Root '.run-lock-a3a8ee437933.json.0a1b2c3d.tmp') -Value '{}' -Encoding utf8
        (Get-Item -LiteralPath $script:Root).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-5)
        $Before = script:Get-FolderSnapshot -Path $script:Root

        $R = script:Invoke-Wrapper -Tool $Tool
        $R.ExitCode | Should -Be 1 -Because ($R.Text -join "`n")
        @($R.Text | Where-Object { $_ -like 'ERROR: Could not work out the tenant key*' }) | Should -Be @(($script:KeyLine -f $PSVersionTable.PSVersion, $Problem))
        script:Get-FolderSnapshot -Path $script:Root | Should -Be $Before
    }

    It 'no inventory folder yet: exit 1 with the line, and no folder is created' {
        script:New-Case
        script:Set-Scenario
        $Tool = script:New-BadKeyTool -Body "return ''"
        $R = script:Invoke-Wrapper -Tool $Tool
        $R.ExitCode | Should -Be 1 -Because ($R.Text -join "`n")
        $R.Text | Should -Contain ($script:KeyLine -f $PSVersionTable.PSVersion, 'it came out empty')
        Test-Path -LiteralPath $script:Root | Should -BeFalse
    }
}

Describe 'Move-LegacyResumeStateFiles: files an earlier version named with the tenant id' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
        $script:Key = 'a3a8ee437933'
        function script:New-Folder
        {
            $Dir = Join-Path $script:TestBase ('legacy-' + [guid]::NewGuid().ToString().Substring(0, 8))
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            return $Dir
        }
        function script:New-File { param([string]$Dir, [string]$Name, [string]$Text = 'x') Set-Content -LiteralPath (Join-Path $Dir $Name) -Value $Text -Encoding utf8 -NoNewline }
        function script:Get-Names { param([string]$Dir) @(Get-ChildItem -LiteralPath $Dir -Force | ForEach-Object { $_.Name } | Sort-Object) }
        # The lines the move prints, and the number it returns last.
        function script:Invoke-Move
        {
            param([string]$Dir)
            $Out = @(Move-LegacyResumeStateFiles -InventoryRoot $Dir -Tenant $script:Tenant 6>&1)
            [pscustomobject]@{
                Lines = @($Out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_ })
                Moved = $Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -Last 1
            }
        }
    }

    It 'a resume state file (<Case>) whose tenant-key name is taken is moved aside under the tenant key with one line; the tenant-key file is left as it is' -ForEach @(
        @{ Case = 'the run''s'; Rest = '.json' }
        @{ Case = 'a stream''s'; Rest = '-stream-2.json' }
    ) {
        $Dir = script:New-Folder
        script:New-File -Dir $Dir -Name ('.resume-state-{0}{1}' -f $script:Key, $Rest) -Text 'new'
        script:New-File -Dir $Dir -Name ('.resume-state-{0}{1}' -f $script:Tenant, $Rest) -Text 'old'
        $R = script:Invoke-Move $Dir
        $R.Lines | Should -Be @(('WARNING: A resume state file of an earlier version of this tool, named with the tenant id, is not used, because .resume-state-{0}{1} is there: it was moved aside to .resume-state-{0}{1}.earlier-version, which no run reads.' -f $script:Key, $Rest))
        $R.Moved | Should -Be 0
        script:Get-Names $Dir | Should -Be @(('.resume-state-{0}{1}' -f $script:Key, $Rest), ('.resume-state-{0}{1}.earlier-version' -f $script:Key, $Rest))
        Get-Content -LiteralPath (Join-Path $Dir ('.resume-state-{0}{1}' -f $script:Key, $Rest)) -Raw | Should -BeExactly 'new'
        Get-Content -LiteralPath (Join-Path $Dir ('.resume-state-{0}{1}.earlier-version' -f $script:Key, $Rest)) -Raw | Should -BeExactly 'old'
    }

    It 'the temporary and set-aside files of that version are moved aside under the tenant key, one line each; its run lock and another tenant''s files are not touched' {
        $Dir = script:New-Folder
        $Old = @(
            ('.resume-state-{0}.json.tmp' -f $script:Tenant)
            ('.resume-state-{0}-stream-2.json.tmp' -f $script:Tenant)
            ('.resume-state-{0}.json.unreadable-20261101-101010' -f $script:Tenant)
            ('.resume-state-{0}-stream-1.json.unreadable-20261101-101010-3' -f $script:Tenant)
            ('.run-lock-{0}.json.0a1b2c3d.tmp' -f $script:Tenant)
        )
        $Kept = @(
            ('.run-lock-{0}.json' -f $script:Tenant)
            '.resume-state-tenant-b.json', '.resume-state-tenant-b.json.tmp', '.resume-state-tenant-b.json.unreadable-20261101-101010', '.run-lock-tenant-b.json', '.run-lock-tenant-b.json.0a1b2c3d.tmp'
            ('.resume-state-{0}.json' -f (Get-TenantFileKey -Tenant 'tenant-b'))
        )
        foreach ($Name in $Old + $Kept) { script:New-File -Dir $Dir -Name $Name -Text $Name }
        $R = script:Invoke-Move $Dir
        $R.Moved | Should -Be 0
        @($R.Lines | Sort-Object) | Should -Be @(@(
                ('Moved a temporary resume state file of an earlier version of this tool, named with the tenant id, aside to .resume-state-{0}.json.tmp.earlier-version, which no run reads.' -f $script:Key)
                ('Moved a temporary resume state file of an earlier version of this tool, named with the tenant id, aside to .resume-state-{0}-stream-2.json.tmp.earlier-version, which no run reads.' -f $script:Key)
                ('Moved a resume state file set aside as unreadable of an earlier version of this tool, named with the tenant id, aside to .resume-state-{0}.json.unreadable-20261101-101010.earlier-version, which no run reads.' -f $script:Key)
                ('Moved a resume state file set aside as unreadable of an earlier version of this tool, named with the tenant id, aside to .resume-state-{0}-stream-1.json.unreadable-20261101-101010-3.earlier-version, which no run reads.' -f $script:Key)
                ('Moved a temporary run lock file of an earlier version of this tool, named with the tenant id, aside to .run-lock-{0}.json.0a1b2c3d.tmp.earlier-version, which no run reads.' -f $script:Key)
            ) | Sort-Object)
        $Aside = @(
            ('.resume-state-{0}.json.tmp.earlier-version' -f $script:Key)
            ('.resume-state-{0}-stream-2.json.tmp.earlier-version' -f $script:Key)
            ('.resume-state-{0}.json.unreadable-20261101-101010.earlier-version' -f $script:Key)
            ('.resume-state-{0}-stream-1.json.unreadable-20261101-101010-3.earlier-version' -f $script:Key)
            ('.run-lock-{0}.json.0a1b2c3d.tmp.earlier-version' -f $script:Key)
        )
        script:Get-Names $Dir | Should -Be @($Aside + $Kept | Sort-Object)
        for ($I = 0; $I -lt $Old.Count; $I++) { Get-Content -LiteralPath (Join-Path $Dir $Aside[$I]) -Raw | Should -BeExactly $Old[$I] }
        foreach ($Name in $Kept) { Get-Content -LiteralPath (Join-Path $Dir $Name) -Raw | Should -BeExactly $Name }
    }

    It 'no run reads, moves, merges or removes a file moved aside: the next move prints nothing, and the stream state list, the lock temporary file clean-up and the tenant-key names leave them alone' {
        $Dir = script:New-Folder
        script:New-File -Dir $Dir -Name ('.resume-state-{0}.json' -f $script:Key) -Text 'new'
        script:New-File -Dir $Dir -Name ('.resume-state-{0}-stream-1.json' -f $script:Key) -Text 'new'
        foreach ($Name in @(('.resume-state-{0}.json' -f $script:Tenant), ('.resume-state-{0}-stream-1.json' -f $script:Tenant), ('.resume-state-{0}-stream-1.json.tmp' -f $script:Tenant), ('.resume-state-{0}.json.unreadable-20261101-101010' -f $script:Tenant), ('.run-lock-{0}.json.0a1b2c3d.tmp' -f $script:Tenant)))
        {
            script:New-File -Dir $Dir -Name $Name -Text 'old'
        }
        (script:Invoke-Move $Dir).Lines.Count | Should -Be 5
        $After = script:Get-Names $Dir
        @($After | Where-Object { $_ -like '*.earlier-version' }).Count | Should -Be 5

        $R = script:Invoke-Move $Dir
        $R.Lines | Should -BeNullOrEmpty
        $R.Moved | Should -Be 0
        @(Get-StreamResumeStateFiles -InventoryRoot $Dir -Tenant $script:Tenant | ForEach-Object { $_.Name }) | Should -Be @(('.resume-state-{0}-stream-1.json' -f $script:Key))
        $LockLines = @(Remove-RunLockTemp -Path (Get-RunLockPath -InventoryRoot $Dir -Tenant $script:Tenant) 6>&1 | ForEach-Object { [string]$_ })
        $LockLines | Should -BeNullOrEmpty
        foreach ($Path in @((Get-ResumeStatePath -InventoryRoot $Dir -Tenant $script:Tenant), (Get-ResumeStatePath -InventoryRoot $Dir -Tenant $script:Tenant -Stream '1'), (Get-RunLockPath -InventoryRoot $Dir -Tenant $script:Tenant), (Get-RunLockLegacyPath -InventoryRoot $Dir -Tenant $script:Tenant)))
        {
            @($After | Where-Object { $_ -like '*.earlier-version' }) | Should -Not -Contain (Split-Path -Path $Path -Leaf)
        }
        script:Get-Names $Dir | Should -Be $After
    }

    It 'the name moved aside to is taken: <Taken> name(s) taken, it is moved to the next free one, -2 up to -100' -ForEach @(
        @{ Taken = 1; Expected = '.earlier-version-2' }
        @{ Taken = 99; Expected = '.earlier-version-100' }
    ) {
        $Dir = script:New-Folder
        $Base = '.resume-state-{0}.json.tmp.earlier-version' -f $script:Key
        for ($N = 1; $N -le $Taken; $N++) { script:New-File -Dir $Dir -Name $(if ($N -eq 1) { $Base } else { '{0}-{1}' -f $Base, $N }) -Text 'taken' }
        script:New-File -Dir $Dir -Name ('.resume-state-{0}.json.tmp' -f $script:Tenant) -Text 'old'
        $R = script:Invoke-Move $Dir
        $R.Lines | Should -Be @(('Moved a temporary resume state file of an earlier version of this tool, named with the tenant id, aside to .resume-state-{0}.json.tmp{1}, which no run reads.' -f $script:Key, $Expected))
        Get-Content -LiteralPath (Join-Path $Dir ('.resume-state-{0}.json.tmp{1}' -f $script:Key, $Expected)) -Raw | Should -BeExactly 'old'
        @(Get-ChildItem -LiteralPath $Dir -Force | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -eq 'taken' }).Count | Should -Be $Taken
    }

    It 'all 100 names taken: the file is left where it is, with one warning that holds no tenant id' {
        $Dir = script:New-Folder
        $Base = '.resume-state-{0}.json.earlier-version' -f $script:Key
        for ($N = 1; $N -le 100; $N++) { script:New-File -Dir $Dir -Name $(if ($N -eq 1) { $Base } else { '{0}-{1}' -f $Base, $N }) -Text 'taken' }
        script:New-File -Dir $Dir -Name ('.resume-state-{0}.json' -f $script:Key) -Text 'new'
        $Old = '.resume-state-{0}.json' -f $script:Tenant
        script:New-File -Dir $Dir -Name $Old -Text 'old'
        $R = script:Invoke-Move $Dir
        $R.Lines | Should -Be @(('WARNING: Could not move a resume state file of an earlier version of this tool, named with the tenant id, aside: every name from {0} to {0}-100 is taken. It is left where it is.' -f $Base))
        Get-Content -LiteralPath (Join-Path $Dir $Old) -Raw | Should -BeExactly 'old'
        Get-Content -LiteralPath (Join-Path $Dir ('.resume-state-{0}.json' -f $script:Key)) -Raw | Should -BeExactly 'new'
    }

    It 'a move that fails (a read-only folder): one warning that holds no tenant id, and the file is left where it is' -Skip:$IsWindows {
        $Dir = script:New-Folder
        script:New-File -Dir $Dir -Name ('.resume-state-{0}.json' -f $script:Key) -Text 'new'
        foreach ($Name in @(('.resume-state-{0}.json' -f $script:Tenant), ('.resume-state-{0}.json.tmp' -f $script:Tenant))) { script:New-File -Dir $Dir -Name $Name -Text 'old' }
        $Before = script:Get-Names $Dir
        & chmod 555 $Dir
        try { $R = script:Invoke-Move $Dir }
        finally { & chmod 755 $Dir }
        $R.Lines.Count | Should -Be 2
        foreach ($Line in $R.Lines)
        {
            $Line | Should -BeLike 'WARNING: Could not move a * of an earlier version of this tool, named with the tenant id, aside to .resume-state-a3a8ee437933.json*.earlier-version: *. It is left where it is.'
            $Line | Should -Not -Match '12345678'
        }
        script:Get-Names $Dir | Should -Be $Before
    }

    It 'no line names the tenant id in any of these cases' {
        $Dir = script:New-Folder
        script:New-File -Dir $Dir -Name ('.resume-state-{0}.json' -f $script:Key) -Text 'new'
        foreach ($Name in @(('.resume-state-{0}.json' -f $script:Tenant), ('.resume-state-{0}-stream-3.json' -f $script:Tenant), ('.resume-state-{0}.json.tmp' -f $script:Tenant), ('.resume-state-{0}.json.unreadable-20261101-101010' -f $script:Tenant), ('.run-lock-{0}.json.0a1b2c3d.tmp' -f $script:Tenant)))
        {
            script:New-File -Dir $Dir -Name $Name -Text 'old'
        }
        $R = script:Invoke-Move $Dir
        $R.Moved | Should -Be 1
        $R.Lines.Count | Should -Be 5
        ($R.Lines -join "`n") | Should -Not -Match '12345678'
        @(script:Get-Names $Dir | Where-Object { $_ -match '12345678' }) | Should -BeNullOrEmpty
    }
}

Describe 'The FAILED (report missing) banner' -Skip:$IsWindows {
    It 'after a -Fresh run, says to run the same command again without -Fresh, or with -Resume' {
        script:New-Case
        $B = $script:Subs | Where-Object { $_.Name -eq 'Sub B' }
        script:Set-Scenario -NoZip @($B.Id)
        $R = script:Invoke-Wrapper -Fresh
        $R.ExitCode | Should -Be 2 -Because ($R.Text -join "`n")
        script:Get-FullBanner $R | Should -Contain 'The resume state is kept. Run the same command again (without -Fresh), or with -Resume: it collects these subscriptions again and carries the other reports into a new consolidated zip.'
        (script:Get-FullBanner $R) -join "`n" | Should -Not -Match 'Run again with -Resume'
    }

    It 'when every report is missing, says that no consolidated zip was built, and none is' {
        script:New-Case
        script:Set-Scenario -NoZip @($script:Subs | ForEach-Object { $_.Id })
        $R = script:Invoke-Wrapper
        $R.ExitCode | Should -Be 2 -Because ($R.Text -join "`n")
        $R.NewZips | Should -Be 0
        $Banner = script:Get-FullBanner $R
        $Banner[0] | Should -Be '3 subscription(s) completed collection this run, but their report zip is missing, and no consolidated zip was built:'
        $Banner | Should -Contain 'The resume state is kept. Run the same command again (without -Fresh), or with -Resume: it collects these subscriptions again and builds the consolidated zip.'
        ($Banner -join "`n") | Should -Not -Match 'NOT in the consolidated zip'
    }

    It 'on the run whose missing report takes a subscription to the retry limit, names it apart with the -Fresh command, in the banner, MainSummary.html and RunSummary.log' {
        script:New-Case
        $B = $script:Subs | Where-Object { $_.Name -eq 'Sub B' }
        script:Set-Scenario -NoZip @($B.Id)
        $null = script:Invoke-Wrapper
        $null = script:Invoke-Wrapper
        $R3 = script:Invoke-Wrapper
        $R3.ExitCode | Should -Be 2 -Because ($R3.Text -join "`n")
        @($R3.State.FailedAttempts | ForEach-Object { [int]$_.Attempts }) | Should -Be @(3)
        $Fresh = '  ./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh -SkipMetrics -SkipConsumption' -f $script:Tenant
        script:Get-FullBanner $R3 | Should -Be @(
            '1 subscription(s) completed collection this run, but their report zip is missing, so they are NOT in the consolidated zip:'
            ('  - {0} ({1})' -f $B.Name, $B.Id)
            'Sub B failed 3 runs in a row (Retry Limit Reached), so a run that continues this one does not collect it again; to try again, start a new run with -Fresh:'
            $Fresh
        )
        # The retry-limit summary of the same run gives the same command.
        $R3.Text | Should -Contain ('  ' + $Fresh)
        $Reason = 'retry limit reached (failed 3 runs in a row; to try it again, start a new run with -Fresh)'
        $R3.Zip.RunSummary | Should -Contain ('    - Sub B ({0}): {1}' -f $B.Id, $Reason)
        $R3.Zip.MainSummary | Should -Match ([regex]::Escape(('<li>Sub B ({0}): {1}</li>' -f $B.Id, $Reason)))
        $R3.Zip.RunSummary | Should -Contain '  Report missing, retry limit reached : 1 (not in this zip; a run that continues this one does not collect these; to try them again, start a new run with -Fresh)'
        ($R3.Zip.RunSummary -join "`n") | Should -Not -Match 'the next run collects'
    }
}

Describe '-ResumeFailedOnly after a run with reports of other subscriptions' -Skip:$IsWindows {
    It 'exits 2 and keeps the state while its consolidated zip lacks them, and names the run that carries them; that run ends clean with every report' {
        script:New-Case
        $B = $script:Subs | Where-Object { $_.Name -eq 'Sub B' }
        script:Set-Scenario -NoZip @($B.Id)
        $R1 = script:Invoke-Wrapper
        $R1.ExitCode | Should -Be 2 -Because ($R1.Text -join "`n")

        # The retry list only: Sub B writes its report now.
        script:Set-Scenario
        $R2 = script:Invoke-Wrapper -ResumeFailedOnly
        $R2.ExitCode | Should -Be 2 -Because ($R2.Text -join "`n")
        $R2.Zip.Ids | Should -Be (script:Get-Ids 'B')
        $R2.Text | Should -Not -Contain 'Resume state cleared (clean run).'
        $R2.State | Should -Not -BeNullOrEmpty
        $R2.Text | Should -Contain 'Not finished: -ResumeFailedOnly puts only the reports it collected into its consolidated zip, so the reports of 2 subscription(s) completed earlier in this run are not in it, and the resume state is kept. To put every report of the run into a new consolidated zip, continue the run:'
        $R2.Text | Should -Contain ('  ./Run-AllSubscriptions.ps1 -TenantID {0} -Resume -SkipMetrics -SkipConsumption' -f $script:Tenant)
        $Reason = 'completed earlier in the run; -ResumeFailedOnly does not carry its report, so a run that continues this one puts it into a new consolidated zip'
        foreach ($L in 'A', 'C')
        {
            $Sub = $script:Subs | Where-Object { $_.Name -eq ('Sub ' + $L) }
            $R2.Zip.RunSummary | Should -Contain ('    - {0} ({1}): {2}' -f $Sub.Name, $Sub.Id, $Reason)
            $R2.Zip.MainSummary | Should -Match ([regex]::Escape(('<li>{0} ({1}): {2}</li>' -f $Sub.Name, $Sub.Id, $Reason)))
        }

        # The command it names: it collects nothing again and carries every report.
        $R3 = script:Invoke-Wrapper -Resume
        $R3.ExitCode | Should -Be 0 -Because ($R3.Text -join "`n")
        $R3.Zip.Ids | Should -Be (script:Get-Ids 'A', 'B', 'C')
        $R3.Text | Should -Contain 'Resume state cleared (clean run).'
        $R3.State | Should -BeNullOrEmpty
    }
}
