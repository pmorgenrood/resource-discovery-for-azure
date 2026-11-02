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
# names, and can remove another subscription's zip. Azure is a set of stand-in
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
        $script:StateFile = Join-Path $script:Root ('.resume-state-{0}.json' -f $script:Tenant)
    }
    function script:Set-Scenario
    {
        param([string[]]$NoZip = @(), [string]$GoneSub = '', [string]$GoneBy = '', [string[]]$NoRole = @())
        [pscustomobject]@{ Tenant = $script:Tenant; Subscriptions = $script:Subs; NoZip = @($NoZip); GoneSub = $GoneSub; GoneBy = $GoneBy; NoRole = @($NoRole) } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Scenario -Encoding utf8
    }

    # One run of the wrapper as its own process, stdin closed: its exit code, its
    # lines, and the consolidated zip it wrote (the inner zips' subscription ids
    # and its RunSummary.log), or $null when it wrote none.
    function script:Invoke-Wrapper
    {
        param([int]$Streams = 1, [switch]$Obfuscate)
        $Before = @(if (Test-Path -LiteralPath $script:Root) { Get-ChildItem -LiteralPath $script:Root -Filter 'AllSubscriptions_*.zip' -File | ForEach-Object { $_.FullName } })
        $Info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
        foreach ($Arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper, '-TenantID', $script:Tenant, '-SkipMetrics', '-SkipConsumption', '-ParallelStreams', [string]$Streams) + @(if ($Obfuscate) { '-Obfuscate' })) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.WorkingDirectory = $script:ToolRoot
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
            'The resume state is kept. Run again with -Resume: it collects these subscriptions again and carries the other reports into a new consolidated zip.'
        )
        $R1.Zip.RunSummary | Should -Contain '  Report missing      : 1 (completed, but their report zip is not in this zip; the next run collects them)'
        $R1.Zip.RunSummary | Should -Contain ('  - {0} ({1})' -f $MissingSub.Name, $MissingSub.Id)
        $R1.Text | Should -Not -Contain 'Resume state cleared (clean run).'
        $R1.State | Should -Not -BeNullOrEmpty
        @($R1.State.CompletedSubscriptionIds | Sort-Object) | Should -Be (script:Get-Ids $Kept)
        @($R1.State.FailedAttempts | ForEach-Object { [string]$_.Id }) | Should -Be @($MissingSub.Id)
        Test-Path -LiteralPath (Join-Path $script:Root ('.run-lock-{0}.json' -f $script:Tenant)) | Should -BeFalse

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
