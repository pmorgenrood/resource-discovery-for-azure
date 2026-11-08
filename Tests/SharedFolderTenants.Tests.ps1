# Run-AllSubscriptions.ps1: runs for two tenants at the same time in one inventory folder
#
# The run lock is per tenant, so runs for two tenants can share one inventory
# folder at the same time. Each must keep to its own files: its stream
# summaries, and in its consolidated zip, main summary and HTML copies only
# the reports it collected or carries, never the other tenant's.
#
# The test starts the REAL Run-AllSubscriptions.ps1 twice as its own pwsh
# processes (-File, stdin closed, -ParallelStreams 2) in one home, from a copy
# of the tool whose ResourceInventory.ps1 is a stand-in that writes one report
# folder and zip per call and can wait at a subscription until the test
# releases it. Tenant A's second subscription is held, so A's first stream has
# written its summary when tenant B's run starts and ends; then A is released.
# Azure is a set of stand-in Az modules. Placeholder ids only. No live Azure.
# On Windows the wrapper writes to C:\InventoryReports, so this does not run there.
#
# Run with: Invoke-Pester ./Tests/SharedFolderTenants.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('SharedFolderTenants_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
    # Two tenants, two subscriptions each. Placeholder-style ids only.
    $script:TenantA = '12345678-1234-1234-1234-123456789012'
    $script:TenantB = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:SubsA = @('a1', 'a2' | ForEach-Object { [pscustomobject]@{ Id = [guid]::new(('0' * 30) + $_).ToString(); Name = ('Sub ' + $_.ToUpperInvariant()) } })
    $script:SubsB = @('b1', 'b2' | ForEach-Object { [pscustomobject]@{ Id = [guid]::new(('0' * 30) + $_).ToString(); Name = ('Sub ' + $_.ToUpperInvariant()) } })

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
# A subscription the scenario holds waits until the test writes release-<id>.
if (@($Scenario.Hold) -contains $SubscriptionID)
{
    Set-Content -LiteralPath (Join-Path $HOME ('held-' + $SubscriptionID)) -Value 'held'
    $Deadline = (Get-Date).AddSeconds(240)
    while (-not (Test-Path -LiteralPath (Join-Path $HOME ('release-' + $SubscriptionID))) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 200 }
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

    function script:Write-Scenario
    {
        param([string]$Path, [string]$Tenant, $Subs, [string[]]$Hold = @())
        [pscustomobject]@{ Tenant = $Tenant; Subscriptions = $Subs; NoZip = @(); Hold = @($Hold) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding utf8
    }

    # One wrapper run as its own process (stdin closed, -File), started and left running.
    function script:Start-Run
    {
        param([string]$Tenant, [string]$Scenario, [string[]]$Extra = @())
        $Info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
        foreach ($Arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Wrapper, '-TenantID', $Tenant, '-SkipMetrics', '-SkipConsumption', '-ParallelStreams', '2') + $Extra) { $Info.ArgumentList.Add($Arg) }
        $Info.UseShellExecute = $false
        $Info.RedirectStandardInput = $true
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError = $true
        $Info.WorkingDirectory = $script:ToolRoot
        $Info.Environment['HOME'] = $script:CaseHome
        $Info.Environment['PSModulePath'] = $script:Modules
        $Info.Environment['RDA_STANDIN_AZURE'] = $Scenario
        $Info.Environment['NO_COLOR'] = '1'
        $Info.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
        $Proc = [System.Diagnostics.Process]::Start($Info)
        $Proc.StandardInput.Close()
        return [pscustomobject]@{ Process = $Proc; Out = $Proc.StandardOutput.ReadToEndAsync(); Err = $Proc.StandardError.ReadToEndAsync() }
    }

    function script:Wait-Run
    {
        param($Run)
        if (-not $Run.Process.WaitForExit(300000)) { $Run.Process.Kill($true); throw 'A wrapper run did not end within 300 seconds.' }
        $Run.Process.WaitForExit()
        $Text = @((([string]$Run.Out.Result + [string]$Run.Err.Result) -replace "`e\[[0-9;]*m", '') -split "`r?`n")
        return [pscustomobject]@{ ExitCode = $Run.Process.ExitCode; Text = $Text }
    }

    # The subscription ids of the report zips in a consolidated zip, and its MainSummary.html.
    function script:Read-Bundle
    {
        param([string]$Path)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try
        {
            $Ids = @($Archive.Entries | Where-Object { $_.FullName -like 'ResourcesReport_*.zip' } | ForEach-Object { $_.FullName -replace '^ResourcesReport_.*-([0-9a-f-]{36})\.zip$', '$1' } | Sort-Object)
            $Main = $Archive.Entries | Where-Object { $_.FullName -eq 'MainSummary.html' } | Select-Object -First 1
            $MainText = ''
            if ($null -ne $Main) { $Reader = [System.IO.StreamReader]::new($Main.Open()); try { $MainText = $Reader.ReadToEnd() } finally { $Reader.Dispose() } }
            $Copies = @($Archive.Entries | Where-Object { $_.FullName -like 'HTML*/*.html' } | ForEach-Object { ($_.FullName -split '/')[0] } | Sort-Object -Unique)
            return [pscustomobject]@{ Ids = $Ids; MainSummary = $MainText; Copies = $Copies }
        }
        finally { $Archive.Dispose() }
    }

    function script:Wait-File
    {
        param([string]$Path, [int]$Seconds = 120)
        $Deadline = (Get-Date).AddSeconds($Seconds)
        while (-not (Test-Path -LiteralPath $Path) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 200 }
        Test-Path -LiteralPath $Path | Should -BeTrue -Because ('{0} should appear' -f $Path)
    }
}

AfterAll {
    if ($script:TestBase -and (Test-Path -LiteralPath $script:TestBase)) { Remove-Item -LiteralPath $script:TestBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Runs for two tenants at the same time in one inventory folder, two streams each' -Skip:$IsWindows {
    BeforeAll {
        $script:CaseHome = Join-Path $script:TestBase ('case-' + [guid]::NewGuid().ToString().Substring(0, 8))
        New-Item -ItemType Directory -Path $script:CaseHome -Force | Out-Null
        $script:Root = Join-Path $script:CaseHome 'InventoryReports'
        $ScenarioA = Join-Path $script:CaseHome 'scenario-a.json'
        $ScenarioB = Join-Path $script:CaseHome 'scenario-b.json'
        # Tenant A's second subscription is held: A's first stream ends and writes
        # its summary while A's run waits for its second stream. Tenant B's run
        # starts then and runs to its end. Then A is released.
        $Held = $script:SubsA[1].Id
        script:Write-Scenario -Path $ScenarioA -Tenant $script:TenantA -Subs $script:SubsA -Hold @($Held)
        script:Write-Scenario -Path $ScenarioB -Tenant $script:TenantB -Subs $script:SubsB
        $RunA = script:Start-Run -Tenant $script:TenantA -Scenario $ScenarioA
        script:Wait-File -Path (Join-Path $script:CaseHome ('held-' + $Held))
        # A's first stream has had time to write its summary.
        Start-Sleep -Seconds 4
        $Before = @(Get-ChildItem -LiteralPath $script:Root -Filter 'AllSubscriptions_*.zip' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        $script:B = script:Wait-Run -Run (script:Start-Run -Tenant $script:TenantB -Scenario $ScenarioB)
        $script:BundleB = @(Get-ChildItem -LiteralPath $script:Root -Filter 'AllSubscriptions_*.zip' -File | Where-Object { $Before -notcontains $_.FullName } | ForEach-Object { $_.FullName })
        Set-Content -LiteralPath (Join-Path $script:CaseHome ('release-' + $Held)) -Value 'go'
        $script:A = script:Wait-Run -Run $RunA
        $script:BundleA = @(Get-ChildItem -LiteralPath $script:Root -Filter 'AllSubscriptions_*.zip' -File | Where-Object { $Before -notcontains $_.FullName -and $script:BundleB -notcontains $_.FullName } | ForEach-Object { $_.FullName })
    }

    It 'each run ends with the exit code of a run on its own (0)' {
        $script:B.ExitCode | Should -Be 0 -Because ($script:B.Text -join "`n")
        $script:A.ExitCode | Should -Be 0 -Because ($script:A.Text -join "`n")
    }

    It 'no run loses a stream summary or fails a stream' {
        foreach ($Run in @($script:A, $script:B))
        {
            @($Run.Text | Where-Object { $_ -match 'no summary file' -or $_ -match 'could not parse summary file' }) | Should -BeNullOrEmpty
            @($Run.Text | Where-Object { $_ -match '^Subscriptions Failed:\s+[1-9]' }) | Should -BeNullOrEmpty
        }
    }

    It 'each consolidated zip, its main summary and its HTML copies hold only that tenant''s reports' {
        $script:BundleA.Count | Should -Be 1
        $script:BundleB.Count | Should -Be 1
        $A = script:Read-Bundle -Path $script:BundleA[0]
        $B = script:Read-Bundle -Path $script:BundleB[0]
        $A.Ids | Should -Be @($script:SubsA.Id | Sort-Object)
        $B.Ids | Should -Be @($script:SubsB.Id | Sort-Object)
        $A.Copies.Count | Should -Be 2
        $B.Copies.Count | Should -Be 2
        foreach ($Sub in $script:SubsB) { $A.MainSummary | Should -Not -Match ([regex]::Escape($Sub.Id)) }
        foreach ($Sub in $script:SubsA) { $B.MainSummary | Should -Not -Match ([regex]::Escape($Sub.Id)) }
        $A.MainSummary | Should -Match ([regex]::Escape('2 subscription(s) in this run (2 visible to the tenant), 2 report(s) in this zip.'))
    }
}
