# Needs PowerShell 7.2 or newer. The check is in the script (not a #Requires line),
# so an older PowerShell gets a clear message and the install link.
<#
.SYNOPSIS
    Runs Resource Discovery for Azure twice on one test subscription: once with the
    current awslabs release (Before) and once with the new fixes (After). It makes
    two report zips and one summary file for you to send back.

.DESCRIPTION
    Steps:
      1. Checks PowerShell and the Az PowerShell modules. If a module is missing or
         too old, it asks to install it for your user only (no admin needed).
         For Before, it checks the Azure CLI and offers to sign it in. After the Az
         sign-in, it checks that you can read the subscription (Reader or higher).
      2. Downloads both code versions from GitHub as zip files (no git needed) and
         records the exact commit of each.
      3. Uses your current Az PowerShell sign-in, or signs you in once.
      4. Runs each version's ResourceInventory.ps1 on the one subscription, with the
         same switches, each into its own folder.
      5. Copies each run's report zip into the "share" folder with a clear name, and
         writes ab-summary.json (counts and timings only: no ids, no names).
      6. Deletes the downloaded code (unless -KeepCode).

    Nothing is sent anywhere. You send the files in the "share" folder by hand.
    Both runs only read from Azure. They change nothing in your subscription.
    If this script signs you in to Az PowerShell, that sign-in becomes your saved
    default; switching tenant for its own checks stays in this window only. It may
    switch the Azure CLI's active subscription, only if you say yes when it asks.
    The current release (Before) may set your default Az PowerShell subscription to
    the test subscription, and may add the Azure CLI resource-graph extension.

.PARAMETER TenantID
    Your Microsoft Entra tenant id.
.PARAMETER SubscriptionID
    The one test subscription to scan.
.PARAMETER Obfuscate
    Mask names and ids in both report zips. The current release (Before) can still
    leave the real name of an Azure SQL server inside its databases' masked ids, so
    check the Before zip before you send it. Each run keeps its own dictionary (the
    key that turns masks back into real names) in the "private" folder. Keep the
    dictionaries; do not send them.
.PARAMETER OutputDirectory
    Where to put everything. Default: a new folder rda-before-after-<UTC time> in the
    current folder.
.PARAMETER AfterBranch
    Branch of github.com/pmorgenrood/resource-discovery-for-azure to test as After.
    Default: all-fixes-optimized.
.PARAMETER DeviceLogin
    Sign in with a device code (a code you type into a browser on any device),
    when a sign-in is needed. Used by itself on Linux with no desktop.
.PARAMETER KeepCode
    Keep the downloaded code in <OutputDirectory>/code after the runs.
.PARAMETER BeforeCodePath
    Optional. Use this code (a folder, or a zip made by GitHub or git archive) for
    Before, instead of downloading awslabs main. Most people do not need this.
.PARAMETER AfterCodePath
    Optional. Same as BeforeCodePath, for After.
.PARAMETER PreflightOnly
    Do every check (and any install or sign-in you say yes to), then stop before
    the two runs. Exit 0 means the real run is ready to go.

.EXAMPLE
    ./Invoke-RdaBeforeAfter.ps1 -TenantID <tenant id> -SubscriptionID <subscription id>

.EXAMPLE
    ./Invoke-RdaBeforeAfter.ps1 -TenantID <tenant id> -SubscriptionID <subscription id> -Obfuscate

.EXAMPLE
    ./Invoke-RdaBeforeAfter.ps1 -TenantID <tenant id> -SubscriptionID <subscription id> -PreflightOnly

.OUTPUTS
    Exit code 0: both runs wrote their report zip (run exit 0, or 3, 4 or 5, which
    the new version uses for a report with some data missing), every file in both
    zips could be read and passed a quick format check, and both zips are in the
    share folder. The full check of the files is made by us, on the files you send.
    Exit code 1: a check failed, or a run failed. The message says what to do.
#>
# The console messages are this script's user interface, so they go to the host.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console messages for the person running the script')]
[CmdletBinding()]
param(
    [string]$TenantID,
    [string]$SubscriptionID,
    [switch]$Obfuscate,
    [string]$OutputDirectory,
    [string]$AfterBranch = 'all-fixes-optimized',
    [switch]$DeviceLogin,
    [switch]$KeepCode,
    [string]$BeforeCodePath,
    [string]$AfterCodePath,
    [switch]$PreflightOnly
)

# ---------------------------------------------------------------------------
# PowerShell version. This part runs first and uses only syntax that Windows
# PowerShell 5.1 can read, so an old PowerShell gets this message, not a crash.
# ---------------------------------------------------------------------------
$script:MinimumPowerShell = [version]'7.2'

function Get-RdaOsName
{
    if ($PSVersionTable.PSVersion.Major -le 5) { return 'Windows' }  # Windows PowerShell runs only on Windows
    if ($IsWindows) { return 'Windows' }
    if ($IsMacOS) { return 'macOS' }
    return 'Linux'
}

# The lines to print when this PowerShell is too old. Empty when it is new enough.
# It never installs PowerShell: it only says how.
function Get-RdaPowerShellAdvice
{
    param([Parameter(Mandatory = $true)][version]$Version, [Parameter(Mandatory = $true)][string]$Os)
    if ($Version -ge $script:MinimumPowerShell) { return @() }
    $Lines = @(('This script needs PowerShell {0} or newer. This is PowerShell {1}.' -f $script:MinimumPowerShell, $Version))
    if ($Version.Major -le 5) { $Lines += 'Windows PowerShell 5.1 is too old. PowerShell 7 installs next to it and does not replace it.' }
    switch ($Os)
    {
        'Windows'
        {
            $Lines += 'Install it with:  winget install --id Microsoft.PowerShell --source winget'
            $Lines += 'Or see: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows'
        }
        'macOS'
        {
            $Lines += 'Install it with:  brew install --cask powershell'
            $Lines += 'Or see: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos'
        }
        default
        {
            $Lines += 'See how to install it on your Linux: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux'
        }
    }
    $Lines += 'Then open PowerShell 7 (the command is pwsh) and run this script again.'
    return $Lines
}

$script:ThisPowerShell = [version]('{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor)
if ($script:ThisPowerShell -lt $script:MinimumPowerShell)
{
    foreach ($Line in (Get-RdaPowerShellAdvice -Version $script:ThisPowerShell -Os (Get-RdaOsName))) { Write-Host $Line -ForegroundColor Red }
    exit 1
}

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName Microsoft.VisualBasic

$script:SummaryVersion = 1
$script:GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:BeforeRepo = 'awslabs/resource-discovery-for-azure'
$script:BeforeBranch = 'main'
$script:AfterRepo = 'pmorgenrood/resource-discovery-for-azure'
$script:PushedAfterBranch = 'all-fixes-2026-11-02'
$script:RequiredAzModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor', 'Az.Billing')
$script:AfterAzAccountsMinimum = [version]'5.5.4'
# Lowest version each module may have (none listed: any version). Both sides need
# the same four modules; only the After side needs a minimum Az.Accounts.
$script:AzModuleMinimum = @{ 'Az.Accounts' = $script:AfterAzAccountsMinimum }
$script:UserAgent = 'rda-before-after'

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$Text) { Write-Host ''; Write-Host ("== {0}" -f $Text) -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host ("   OK   {0}" -f $Text) -ForegroundColor Green }
function Write-Bad([string]$Text) { Write-Host ("   STOP {0}" -f $Text) -ForegroundColor Red }
function Write-Note([string]$Text) { Write-Host ("        {0}" -f $Text) -ForegroundColor Yellow }

function Get-UtcText([datetime]$When) { return $When.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture) }

# True when the tree's own scripts still call the Azure CLI (az) as a command.
# Comment lines and messages are not counted: only lines that start with an az call,
# an assignment from one, or a pipe into one.
function Test-RdaTreeNeedsAzCli
{
    param([Parameter(Mandatory)][string]$TreePath)
    $Files = @('ResourceInventory.ps1', 'Run-AllSubscriptions.ps1', 'Run-AllSubscriptions.Stream.ps1' |
            ForEach-Object { Join-Path $TreePath $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    $FuncDir = Join-Path $TreePath 'Functions'
    if (Test-Path -LiteralPath $FuncDir -PathType Container)
    {
        $Files += @(Get-ChildItem -LiteralPath $FuncDir -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
    }
    $Pattern = '^\s*(\$[\w:]+\s*=\s*)?(@\(\s*)?([^#|]*\|\s*)?az\s+(login|account|graph|extension)\b'
    foreach ($F in $Files)
    {
        foreach ($Line in [IO.File]::ReadLines($F))
        {
            if ($Line -match $Pattern) { return $true }
        }
    }
    return $false
}

# Reads the comment of a zip file. GitHub and git archive put the commit id there.
function Get-RdaZipComment
{
    param([Parameter(Mandatory)][string]$Path)
    $Fs = [IO.File]::OpenRead($Path)
    try
    {
        $Len = [int][math]::Min($Fs.Length, 65557)
        if ($Len -lt 22) { return '' }
        $Buf = [byte[]]::new($Len)
        [void]$Fs.Seek(-$Len, [IO.SeekOrigin]::End)
        $Read = 0
        while ($Read -lt $Len) { $N = $Fs.Read($Buf, $Read, $Len - $Read); if ($N -le 0) { break }; $Read += $N }
        for ($i = $Len - 22; $i -ge 0; $i--)
        {
            if ($Buf[$i] -eq 0x50 -and $Buf[$i + 1] -eq 0x4b -and $Buf[$i + 2] -eq 0x05 -and $Buf[$i + 3] -eq 0x06)
            {
                $Clen = [BitConverter]::ToUInt16($Buf, $i + 20)
                if ($i + 22 + $Clen -gt $Len) { return '' }
                return [Text.Encoding]::ASCII.GetString($Buf, $i + 22, $Clen).Trim()
            }
        }
        return ''
    }
    finally { $Fs.Dispose() }
}

# Finds the folder that holds ResourceInventory.ps1 (the zip's single top folder).
function Find-RdaTreeRoot
{
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath (Join-Path $Path 'ResourceInventory.ps1') -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).ProviderPath }
    $Hit = @(Get-ChildItem -LiteralPath $Path -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'ResourceInventory.ps1') -PathType Leaf })
    if ($Hit.Count -eq 1) { return $Hit[0].FullName }
    return $null
}

function Get-RdaToolVersion
{
    param([Parameter(Mandatory)][string]$TreePath)
    $Vf = Join-Path $TreePath 'Version.json'
    if (-not (Test-Path -LiteralPath $Vf -PathType Leaf)) { return 'unknown' }
    try
    {
        $V = Get-Content -LiteralPath $Vf -Raw | ConvertFrom-Json
        return ('{0}.{1}.{2}' -f $V.MajorVersion, $V.MinorVersion, $V.BuildVersion)
    }
    catch { return 'unknown' }
}

# Asks GitHub for the commit a branch points at. Returns $null when it cannot.
function Get-RdaBranchCommit
{
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Branch)
    try
    {
        $R = Invoke-WebRequest -Uri ("https://api.github.com/repos/{0}/commits/{1}" -f $Repo, $Branch) -Headers @{ Accept = 'application/vnd.github.sha'; 'User-Agent' = $script:UserAgent } -ErrorAction Stop
        $C = $R.Content
        $Text = if ($C -is [byte[]]) { [Text.Encoding]::UTF8.GetString($C) } else { [string]$C }
        $Text = $Text.Trim()
        if ($Text -match '^[0-9a-f]{40}$') { return $Text }
    }
    catch
    {
        $Code = $null
        try { $Code = [int]$_.Exception.Response.StatusCode } catch { $Code = $null }
        if ($Code -eq 404 -or $Code -eq 422) { throw ("Branch '{0}' was not found on github.com/{1}." -f $Branch, $Repo) }
    }
    return $null
}

# Downloads one branch as a zip and unpacks it. Returns @{ Tree; Commit; Source }.
function Get-RdaCode
{
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Side,
        [Parameter(Mandatory)][string]$CodeRoot,
        [string]$LocalPath
    )
    $Dest = Join-Path $CodeRoot $Side
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $Commit = $null
    $Source = ''
    if ($LocalPath)
    {
        if (-not (Test-Path -LiteralPath $LocalPath)) { throw ("{0} code path not found: {1}" -f $Side, $LocalPath) }
        $Item = Get-Item -LiteralPath $LocalPath
        if ($Item.PSIsContainer)
        {
            $Tree = Find-RdaTreeRoot -Path $Item.FullName
            if (-not $Tree) { throw ("No ResourceInventory.ps1 in {0}" -f $LocalPath) }
            $Cf = Join-Path $Tree 'COMMIT'
            if (Test-Path -LiteralPath $Cf -PathType Leaf) { $Commit = (Get-Content -LiteralPath $Cf -Raw).Trim() }
            return [pscustomobject]@{ Tree = $Tree; Commit = $(if ($Commit -match '^[0-9a-f]{40}$') { $Commit } else { 'unknown' }); Source = 'local folder'; Owned = $false }
        }
        $Zip = $Item.FullName
        $Source = 'local zip'
    }
    else
    {
        $Commit = Get-RdaBranchCommit -Repo $Repo -Branch $Branch
        $Ref = if ($Commit) { $Commit } else { "refs/heads/$Branch" }
        $Zip = Join-Path $CodeRoot ("{0}.zip" -f $Side)
        $Url = "https://codeload.github.com/{0}/zip/{1}" -f $Repo, $Ref
        try { Invoke-WebRequest -Uri $Url -OutFile $Zip -Headers @{ 'User-Agent' = $script:UserAgent } -ErrorAction Stop }
        catch
        {
            $Code = $null
            try { $Code = [int]$_.Exception.Response.StatusCode } catch { $Code = $null }
            if ($Code -eq 404) { throw ("Branch '{0}' was not found on github.com/{1}." -f $Branch, $Repo) }
            throw ("Could not download {0}: {1}" -f $Url, $_.Exception.Message)
        }
        $Source = 'github.com/{0} {1}' -f $Repo, $Branch
    }
    $Zc = Get-RdaZipComment -Path $Zip
    if ($Zc -match '^[0-9a-f]{40}$')
    {
        if ($Commit -and $Commit -ne $Zc) { throw ("{0}: the zip holds commit {1}, not {2}." -f $Side, $Zc, $Commit) }
        $Commit = $Zc
    }
    Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force
    $Tree = Find-RdaTreeRoot -Path $Dest
    if (-not $Tree) { throw ("{0}: the code zip holds no ResourceInventory.ps1." -f $Side) }
    if ($IsWindows) { Get-ChildItem -LiteralPath $Tree -Recurse -File | Unblock-File }
    return [pscustomobject]@{ Tree = $Tree; Commit = $(if ($Commit) { $Commit } else { 'unknown' }); Source = $Source; Owned = $true }
}

# Counts what a report zip holds. Counts only: no id, name or value leaves here.
# Streams every file: a big report is never read into memory whole.
function Get-RdaZipCount
{
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Out = [ordered]@{
        reports = 0; inventoryRows = 0; inventoryBySection = [ordered]@{}
        consumptionRows = 0; consumptionDroppedRows = 0; metricsRows = 0; metricsErrorRows = 0; problems = [System.Collections.Generic.List[string]]::new()
    }
    $Outer = [IO.Compression.ZipFile]::OpenRead($Path)
    $Archives = [System.Collections.Generic.List[object]]::new()
    $TempFiles = [System.Collections.Generic.List[string]]::new()
    try
    {
        $Inner = @($Outer.Entries | Where-Object { $_.Name -like '*.zip' })
        if ($Inner.Count -eq 0) { $Archives.Add($Outer) }
        else
        {
            foreach ($E in $Inner)
            {
                # Each inner zip goes to a temp file, not to memory.
                $Tmp = Join-Path ([IO.Path]::GetTempPath()) ('rda-ab-{0}.zip' -f [guid]::NewGuid().ToString('N'))
                $TempFiles.Add($Tmp)
                try
                {
                    $St = $E.Open(); $Fs = [IO.File]::Create($Tmp)
                    try { $St.CopyTo($Fs) } finally { $Fs.Dispose(); $St.Dispose() }
                    $Archives.Add([IO.Compression.ZipFile]::OpenRead($Tmp))
                }
                catch { $Out.problems.Add('an inner report zip could not be read') }
            }
        }
        foreach ($A in $Archives)
        {
            $Out.reports++
            $Entries = @($A.Entries | Where-Object { $_.Name })
            # The same picks as the reader of these files: the inventory file name starts
            # with Inventory, and only the first Consumption*.csv is read.
            $Inv = @($Entries | Where-Object { $_.Name -like 'Inventory*' -and $_.Name -like '*.json' }) | Select-Object -First 1
            $Con = @($Entries | Where-Object { $_.Name -like 'Consumption*' -and $_.Name -like '*.csv' }) | Select-Object -First 1
            $Met = @($Entries | Where-Object { $_.Name -like 'Metrics*' -and $_.Name -like '*.json' })
            if ($Inv)
            {
                try
                {
                    $InvResult = Measure-RdaInventoryEntry -Entry $Inv
                    foreach ($Pb in $InvResult.Problems) { if (-not $Out.problems.Contains($Pb)) { $Out.problems.Add($Pb) } }
                    $Sections = $InvResult.Sections
                    foreach ($K in $Sections.Keys)
                    {
                        $Out.inventoryRows += $Sections[$K]
                        if (-not $Out.inventoryBySection.Contains($K)) { $Out.inventoryBySection[$K] = 0 }
                        $Out.inventoryBySection[$K] += $Sections[$K]
                    }
                }
                catch { $Out.problems.Add('inventory file could not be read') }
            }
            else { $Out.problems.Add('no inventory file') }
            # Both releases always write a Consumption file (headers at least) and a
            # Metrics file, so a report without one is broken.
            if (-not $Con) { $Out.problems.Add('no consumption file') }
            if ($Met.Count -eq 0) { $Out.problems.Add('no metrics file') }
            if ($Con)
            {
                try
                {
                    $Cr = Measure-RdaCsvEntry -Entry $Con
                    $Out.consumptionRows += $Cr.Rows
                    $Out.consumptionDroppedRows += $Cr.Dropped
                    foreach ($Pb in $Cr.Problems) { if (-not $Out.problems.Contains($Pb)) { $Out.problems.Add($Pb) } }
                }
                catch { $Out.problems.Add('consumption file could not be read') }
            }
            foreach ($M in $Met)
            {
                try
                {
                    $Mc = Measure-RdaMetricsEntry -Entry $M
                    $Out.metricsRows += $Mc.Rows; $Out.metricsErrorRows += $Mc.Errors
                    foreach ($Pb in $Mc.Problems) { if (-not $Out.problems.Contains($Pb)) { $Out.problems.Add($Pb) } }
                }
                catch { $Out.problems.Add('a metrics file could not be read') }
            }
        }
    }
    finally
    {
        foreach ($A in $Archives) { if ($A -ne $Outer) { $A.Dispose() } }
        $Outer.Dispose()
        foreach ($T in $TempFiles) { Remove-Item -LiteralPath $T -Force -ErrorAction SilentlyContinue }
    }
    $Out.problems = @($Out.problems)
    return $Out
}

function New-RdaJsonReader($Entry)
{
    $Sr = [IO.StreamReader]::new($Entry.Open(), [Text.Encoding]::UTF8, $true)
    $Jr = [Newtonsoft.Json.JsonTextReader]::new($Sr)
    $Jr.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
    $Jr.CloseInput = $true
    return $Jr
}

# Rows per inventory section: each top-level list counts its items. Also checks the
# shape the reader of this file needs: each section a list (Version may be a string),
# and the ID, Name and SKU of a record a string or null, never a number.
function Measure-RdaInventoryEntry($Entry)
{
    $Counts = [ordered]@{}
    $Problems = [System.Collections.Generic.List[string]]::new()
    $Jr = New-RdaJsonReader $Entry
    try
    {
        if (-not $Jr.Read() -or $Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::StartObject) { throw 'not a JSON object' }
        while ($Jr.Read() -and $Jr.TokenType -eq [Newtonsoft.Json.JsonToken]::PropertyName)
        {
            $Name = [string]$Jr.Value
            if (-not $Jr.Read()) { throw 'cut-off JSON' }
            if ($Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::StartArray)
            {
                $Ok = $Jr.TokenType -eq [Newtonsoft.Json.JsonToken]::Null -or ($Name -eq 'Version' -and $Jr.TokenType -eq [Newtonsoft.Json.JsonToken]::String)
                if (-not $Ok -and -not $Problems.Contains('inventory section not a list')) { $Problems.Add('inventory section not a list') }
                $Jr.Skip(); continue
            }
            $N = 0
            while ($Jr.Read() -and $Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::EndArray)
            {
                $N++
                if ($Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::StartObject)
                {
                    if (-not $Problems.Contains('inventory record not an object')) { $Problems.Add('inventory record not an object') }
                    $Jr.Skip(); continue
                }
                $Rec = [Newtonsoft.Json.Linq.JObject]::Load($Jr)
                foreach ($F in 'ID', 'Name', 'SKU')
                {
                    $V = $Rec[$F]
                    if ($null -ne $V -and $V.Type -notin [Newtonsoft.Json.Linq.JTokenType]::String, [Newtonsoft.Json.Linq.JTokenType]::Null -and -not $Problems.Contains('inventory ID, Name or SKU not a string'))
                    {
                        $Problems.Add('inventory ID, Name or SKU not a string')
                    }
                }
            }
            if ($Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::EndArray) { throw 'cut-off JSON' }
            if (-not $Counts.Contains($Name)) { $Counts[$Name] = 0 }
            $Counts[$Name] += $N
        }
        if ($Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::EndObject) { throw 'cut-off JSON' }
    }
    finally { $Jr.Close() }
    return [pscustomobject]@{ Sections = $Counts; Problems = @($Problems) }
}

# Rows of a metrics file's Metrics list, and how many have MetricError true. Also checks
# the shape the reader needs: an object with a Metrics list, MetricCount, MetricValue and
# MetricPercentile numbers (not null), MetricError true or false.
function Measure-RdaMetricsEntry($Entry)
{
    $Rows = 0; $Errors = 0; $HasList = $false
    $Problems = [System.Collections.Generic.List[string]]::new()
    $Num = @([Newtonsoft.Json.Linq.JTokenType]::Integer, [Newtonsoft.Json.Linq.JTokenType]::Float)
    $Jr = New-RdaJsonReader $Entry
    try
    {
        if (-not $Jr.Read() -or $Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::StartObject) { throw 'not a JSON object' }
        while ($Jr.Read() -and $Jr.TokenType -eq [Newtonsoft.Json.JsonToken]::PropertyName)
        {
            $Name = [string]$Jr.Value
            if (-not $Jr.Read()) { throw 'cut-off JSON' }
            if ($Name -ne 'Metrics' -or $Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::StartArray) { $Jr.Skip(); continue }
            $HasList = $true
            while ($Jr.Read() -and $Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::EndArray)
            {
                if ($Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::StartObject)
                {
                    # A null, a number or a text in the list is not a metric record.
                    if (-not $Problems.Contains('metrics record not an object')) { $Problems.Add('metrics record not an object') }
                    $Jr.Skip(); continue
                }
                $Rows++
                # One record at a time: a record is small.
                $Rec = [Newtonsoft.Json.Linq.JObject]::Load($Jr)
                $Err = $Rec['MetricError']
                if ($null -ne $Err -and $Err.Type -eq [Newtonsoft.Json.Linq.JTokenType]::Boolean -and [bool]$Err) { $Errors++ }
                $Bad = ($null -eq $Err -or $Err.Type -ne [Newtonsoft.Json.Linq.JTokenType]::Boolean)
                foreach ($F in 'MetricCount', 'MetricValue', 'MetricPercentile') { $V = $Rec[$F]; if ($null -eq $V -or $V.Type -notin $Num) { $Bad = $true } }
                # MetricSeries: one number, or a list of numbers only. Both releases write a
                # null series on a record whose call failed (MetricError true); that one is
                # left to the full check on our side, so a failed call alone does not end 1.
                $Ser = $Rec['MetricSeries']
                $ErrTrue = $null -ne $Err -and $Err.Type -eq [Newtonsoft.Json.Linq.JTokenType]::Boolean -and [bool]$Err
                if ($null -eq $Ser -or $Ser.Type -eq [Newtonsoft.Json.Linq.JTokenType]::Null) { if (-not $ErrTrue) { $Bad = $true } }
                elseif ($Ser.Type -eq [Newtonsoft.Json.Linq.JTokenType]::Array) { foreach ($X in $Ser) { if ($X.Type -notin $Num) { $Bad = $true; break } } }
                elseif ($Ser.Type -notin $Num) { $Bad = $true }
                if ($Bad -and -not $Problems.Contains('metrics value or series not a number, or MetricError not true or false')) { $Problems.Add('metrics value or series not a number, or MetricError not true or false') }
            }
            if ($Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::EndArray) { throw 'cut-off JSON' }
        }
        if ($Jr.TokenType -ne [Newtonsoft.Json.JsonToken]::EndObject) { throw 'cut-off JSON' }
    }
    finally { $Jr.Close() }
    if (-not $HasList) { $Problems.Add('metrics file has no Metrics list') }
    return [pscustomobject]@{ Rows = $Rows; Errors = $Errors; Problems = @($Problems) }
}

# Data rows of a consumption file, read as a stream.
function Measure-RdaCsvEntry($Entry)
{
    $Sr = [IO.StreamReader]::new($Entry.Open(), [Text.Encoding]::UTF8, $true)
    try { return (Measure-RdaConsumptionCsv -Reader $Sr) } finally { $Sr.Dispose() }
}

# Rows of a consumption CSV, with the checks its reader makes:
# - the needed headers are there (else rows are lost);
# - every Quantity, UsageStartTime and UsageEndTime, and Cost or UnitPrice when
#   written, parses with a dot and a culture-free date (else the whole file is dropped);
# - Dropped: rows with an empty ResourceId or MeterId, or a negative Quantity
#   (the reader drops those rows one by one). Counted, not a problem.
function Measure-RdaConsumptionCsv
{
    param([Parameter(Mandatory)][IO.TextReader]$Reader)
    $Problems = [System.Collections.Generic.List[string]]::new()
    $P = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($Reader)
    $Rows = 0; $Dropped = 0
    $Inv = [Globalization.CultureInfo]::InvariantCulture
    try
    {
        $P.SetDelimiters(','); $P.HasFieldsEnclosedInQuotes = $true
        # An empty file has no headers, so the reader finds none of its columns.
        if ($P.EndOfData) { return [pscustomobject]@{ Rows = 0; Dropped = 0; Problems = @('consumption header missing') } }
        $Head = @($P.ReadFields())
        $Ix = @{}
        for ($I = 0; $I -lt $Head.Count; $I++) { $Ix[$Head[$I].Trim().Trim([char]0xFEFF)] = $I }
        foreach ($H in 'ResourceId', 'MeterCategory', 'MeterSubCategory', 'MeterName', 'MeterId', 'Quantity', 'UsageStartTime', 'UsageEndTime')
        {
            if (-not $Ix.ContainsKey($H)) { $Problems.Add('consumption header missing'); break }
        }
        # Column numbers once, -1 when the column is not there.
        $Col = @{}
        foreach ($H in 'Quantity', 'UsageStartTime', 'UsageEndTime', 'Cost', 'UnitPrice', 'ResourceId', 'MeterId') { $Col[$H] = $(if ($Ix.ContainsKey($H)) { [int]$Ix[$H] } else { -1 }) }
        $CQ = $Col.Quantity; $CS = $Col.UsageStartTime; $CE = $Col.UsageEndTime; $CC = $Col.Cost; $CU = $Col.UnitPrice; $CR = $Col.ResourceId; $CM = $Col.MeterId
        $Float = [Globalization.NumberStyles]::Float; $Round = [Globalization.DateTimeStyles]::RoundtripKind
        $BadCell = $false; $Qv = 0.0; $Dt = [datetime]::MinValue; $Cn = 0.0
        while (-not $P.EndOfData)
        {
            $F = $P.ReadFields()
            if ($null -eq $F) { continue }
            $Rows++; $Fc = $F.Count; $Qv = 0.0
            # A row cut short (fewer cells than headers) does not parse either.
            if ($Fc -lt $Head.Count) { $BadCell = $true }
            if ($CQ -ge 0 -and $CQ -lt $Fc -and -not [double]::TryParse($F[$CQ], $Float, $Inv, [ref]$Qv)) { $BadCell = $true }
            if ($CS -ge 0 -and $CS -lt $Fc -and -not [datetime]::TryParse($F[$CS], $Inv, $Round, [ref]$Dt)) { $BadCell = $true }
            if ($CE -ge 0 -and $CE -lt $Fc -and -not [datetime]::TryParse($F[$CE], $Inv, $Round, [ref]$Dt)) { $BadCell = $true }
            if ($CC -ge 0 -and $CC -lt $Fc -and $F[$CC] -ne '' -and -not [double]::TryParse($F[$CC], $Float, $Inv, [ref]$Cn)) { $BadCell = $true }
            if ($CU -ge 0 -and $CU -lt $Fc -and $F[$CU] -ne '' -and -not [double]::TryParse($F[$CU], $Float, $Inv, [ref]$Cn)) { $BadCell = $true }
            $NoRid = $CR -lt 0 -or $CR -ge $Fc -or [string]::IsNullOrWhiteSpace($F[$CR])
            $NoMid = $CM -lt 0 -or $CM -ge $Fc -or [string]::IsNullOrWhiteSpace($F[$CM])
            if ($NoRid -or $NoMid -or $Qv -lt 0) { $Dropped++ }
        }
        if ($BadCell) { $Problems.Add('consumption number or date that does not parse') }
    }
    finally { $P.Dispose() }
    return [pscustomobject]@{ Rows = $Rows; Dropped = $Dropped; Problems = @($Problems) }
}

# Data rows of a CSV text (quoted fields may hold commas, quotes and line breaks).
function Measure-RdaCsvRow
{
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    return (Measure-RdaConsumptionCsv -Reader ([IO.StringReader]::new($Text))).Rows
}

# All processes under (and including) a root process id.
function Get-RdaProcessTree
{
    param([Parameter(Mandatory)][int]$RootId)
    $All = @(Get-Process -ErrorAction SilentlyContinue)
    $Kids = @{}
    foreach ($P in $All)
    {
        $Pp = $null
        try { $Pp = $P.Parent } catch { $Pp = $null }
        if ($Pp) { if (-not $Kids.ContainsKey($Pp.Id)) { $Kids[$Pp.Id] = [System.Collections.Generic.List[object]]::new() }; $Kids[$Pp.Id].Add($P) }
    }
    $Tree = [System.Collections.Generic.List[object]]::new()
    $Root = $All | Where-Object { $_.Id -eq $RootId } | Select-Object -First 1
    if (-not $Root) { return @() }
    $Queue = [System.Collections.Generic.Queue[object]]::new()
    $Queue.Enqueue($Root)
    while ($Queue.Count -gt 0)
    {
        $x = $Queue.Dequeue(); $Tree.Add($x)
        if ($Kids.ContainsKey($x.Id)) { foreach ($k in $Kids[$x.Id]) { $Queue.Enqueue($k) } }
    }
    return @($Tree)
}

# The child's arguments, one list item each (never one command string).
function Get-RdaSideArgument
{
    param([string]$Tree, [string]$ReportDir, [string]$Tenant, [string]$Subscription, [switch]$Mask, [switch]$UseDeviceCode)
    $L = [System.Collections.Generic.List[string]]::new()
    foreach ($A in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Tree 'ResourceInventory.ps1'),
            '-TenantID', $Tenant, '-SubscriptionID', $Subscription, '-OutputDirectory', $ReportDir)) { $L.Add($A) }
    if ($Mask) { $L.Add('-Obfuscate') }
    # A run that has to sign in again uses the same way as this script.
    if ($UseDeviceCode) { $L.Add('-DeviceLogin') }
    return $L.ToArray()
}

# Counts a shared zip; a zip that cannot be read gives a fixed problem, never a stop.
function Get-RdaZipCountSafe
{
    param([Parameter(Mandatory)][string]$Path)
    try { return (Get-RdaZipCount -Path $Path) }
    catch
    {
        return [ordered]@{
            reports = 0; inventoryRows = 0; inventoryBySection = [ordered]@{}
            consumptionRows = 0; consumptionDroppedRows = 0; metricsRows = 0; metricsErrorRows = 0; problems = @('report zip could not be read')
        }
    }
}

# Notes printed at the end, for what the current release (Before) is known to do.
function Get-RdaEndNote
{
    param([object[]]$Sides, [switch]$Obfuscate)
    $L = [System.Collections.Generic.List[string]]::new()
    if (@($Sides | Where-Object { $_.side -eq 'before' -and $_.usesAzureCli }).Count -gt 0)
    {
        $L.Add('Note: the current release (Before) also reads Azure Virtual Desktop resources from other subscriptions')
        $L.Add('its Azure CLI sign-in can see. The new fixes read only this subscription. See docs/BEFORE-AFTER-TEST.md.')
    }
    if ($Obfuscate)
    {
        $L.Add('Before you send the Before zip, check it: the current release can leave the real name of an')
        $L.Add('Azure SQL server inside the masked ids of its databases. If that name is private, send only')
        $L.Add('the After zip and ab-summary.json, and tell us.')
    }
    return $L.ToArray()
}

# True when both runs wrote a report zip whose every file could be read (an inventory
# file in each report, no problem noted). The files are kept either way, to look at.
# Exits 3, 4 and 5 of the new version still write the report (with some data missing,
# as its README says).
function Test-RdaRunsComparable
{
    param([object[]]$Sides)
    $Good = @($Sides | Where-Object {
            $_.exitCode -in 0, 3, 4, 5 -and $_.zip -and $_.counts -and $_.counts.reports -gt 0 -and @($_.counts.problems).Count -eq 0
        })
    return ($Good.Count -eq 2)
}

# Runs one side's ResourceInventory.ps1 as a child process and samples its memory.
function Invoke-RdaSide
{
    param(
        [Parameter(Mandatory)][string]$Tree,
        [Parameter(Mandatory)][string]$ReportDir,
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$Subscription,
        [switch]$Mask,
        [switch]$UseDeviceCode
    )
    New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
    $PwshPath = (Get-Process -Id $PID).Path
    $Psi = [System.Diagnostics.ProcessStartInfo]::new($PwshPath)
    foreach ($A in (Get-RdaSideArgument -Tree $Tree -ReportDir $ReportDir -Tenant $Tenant -Subscription $Subscription -Mask:$Mask -UseDeviceCode:$UseDeviceCode))
    {
        $Psi.ArgumentList.Add($A)
    }
    $Psi.UseShellExecute = $false
    $Psi.WorkingDirectory = $Tree
    $Start = [datetime]::UtcNow
    $Proc = [System.Diagnostics.Process]::Start($Psi)
    $null = $Proc.Handle  # keeps the exit code readable on Windows
    $PeakOne = 0L; $PeakAll = 0L; $Samples = 0
    while (-not $Proc.HasExited)
    {
        $Sum = 0L
        foreach ($P in (Get-RdaProcessTree -RootId $Proc.Id))
        {
            try
            {
                $P.Refresh()
                $Sum += $P.WorkingSet64
                $Pk = [math]::Max($P.PeakWorkingSet64, $P.WorkingSet64)
                if ($Pk -gt $PeakOne) { $PeakOne = $Pk }
            }
            catch { Write-Verbose 'a process ended while it was sampled' }
        }
        if ($Sum -gt $PeakAll) { $PeakAll = $Sum }
        $Samples++
        [void]$Proc.WaitForExit(3000)
    }
    $Proc.WaitForExit()
    $End = [datetime]::UtcNow
    $Rc = $Proc.ExitCode
    $Proc.Dispose()
    $Zips = @(Get-ChildItem -LiteralPath $ReportDir -Recurse -File -Filter '*.zip' | Sort-Object LastWriteTimeUtc -Descending)
    return [pscustomobject]@{
        ExitCode = $Rc; Start = $Start; End = $End
        WallSeconds = [math]::Round(($End - $Start).TotalSeconds, 1)
        PeakProcessMB = [math]::Round($PeakOne / 1MB, 1); PeakTreeMB = [math]::Round($PeakAll / 1MB, 1); Samples = $Samples
        Zip = $(if ($Zips.Count -gt 0) { $Zips[0].FullName } else { $null }); ZipCount = $Zips.Count
    }
}

# ---------------------------------------------------------------------------
# Questions. Only asked in a PowerShell that can answer them.
# ---------------------------------------------------------------------------

# False when nobody can type an answer: started with -NonInteractive, input piped
# in, or no user session. Then the script stops with the command instead of asking.
function Test-RdaInteractiveHost
{
    if (-not [Environment]::UserInteractive) { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
    foreach ($A in [Environment]::GetCommandLineArgs()) { if ($A -match '^(-|--|/)noni') { return $false } }
    return $true
}

# Asks a yes or no question. Three unclear answers count as No, so it never loops.
function Read-RdaYesNo
{
    param([Parameter(Mandatory)][string]$Question)
    for ($i = 0; $i -lt 3; $i++)
    {
        $Answer = [string](Read-Host ('{0} [Y/N]' -f $Question))
        if ($Answer -match '^\s*(y|yes)\s*$') { return $true }
        if ($Answer -match '^\s*(n|no)\s*$') { return $false }
        Write-Note 'Please type Y or N.'
    }
    return $false
}

function Test-RdaCloudShell
{
    return [bool]($env:ACC_CLOUD -or $env:AZUREPS_HOST_ENVIRONMENT -like 'cloud-shell*')
}

# ---------------------------------------------------------------------------
# Az PowerShell modules: check, and install for this user only when asked.
# ---------------------------------------------------------------------------

# One row per needed module. State: ok, missing, or old (below its minimum).
# Loaded is the lowest version already loaded in this window, if any.
function Get-RdaAzModuleState
{
    $Rows = foreach ($M in $script:RequiredAzModules)
    {
        $Inst = @(Get-Module -Name $M -ListAvailable -ErrorAction SilentlyContinue | Where-Object { $_.Version } |
                ForEach-Object { [version]$_.Version } | Sort-Object -Descending) | Select-Object -First 1
        $Loaded = @(Get-Module -Name $M -ErrorAction SilentlyContinue | Where-Object { $_.Version } |
                ForEach-Object { [version]$_.Version } | Sort-Object) | Select-Object -First 1
        $Min = $script:AzModuleMinimum[$M]
        $State = if (-not $Inst) { 'missing' } elseif ($Min -and $Inst -lt $Min) { 'old' } else { 'ok' }
        [pscustomobject]@{ Name = $M; Version = $Inst; Minimum = $Min; Loaded = $Loaded; State = $State }
    }
    return @($Rows)
}

# The exact command that fixes one module row, for the user's own scope.
# -Force only for an older copy: without it Install-Module refuses to add the new
# version. It installs the new version next to the old one, and deletes nothing.
function Get-RdaAzInstallCommand
{
    param([Parameter(Mandatory)]$Row)
    $C = 'Install-Module -Name {0} -Scope CurrentUser -Repository PSGallery' -f $Row.Name
    if ($Row.Minimum) { $C += (' -MinimumVersion {0}' -f $Row.Minimum) }
    if ($Row.State -eq 'old') { $C += ' -Force' }
    return $C
}

function Install-RdaAzModule
{
    param([Parameter(Mandatory)]$Row)
    $P = @{ Name = $Row.Name; Scope = 'CurrentUser'; Repository = 'PSGallery'; ErrorAction = 'Stop' }
    if ($Row.Minimum) { $P.MinimumVersion = $Row.Minimum }
    if ($Row.State -eq 'old') { $P.Force = $true }
    Install-Module @P
}

function Write-RdaAzInstallCommand
{
    param([Parameter(Mandatory)][object[]]$Rows)
    Write-Note 'To install them yourself, run:'
    foreach ($R in $Rows) { Write-Note ('  ' + (Get-RdaAzInstallCommand -Row $R)) }
    Write-Note 'Then open a new PowerShell window and run this script again.'
}

# Checks the Az modules, offers to install what is missing or too old, and checks
# again. Returns @{ Ok; Modules }. Installs only on a Yes, and only for this user.
function Invoke-RdaAzModuleCheck
{
    $Mods = Get-RdaAzModuleState
    foreach ($M in $Mods)
    {
        switch ($M.State)
        {
            'ok' { Write-Ok ('{0} {1}' -f $M.Name, $M.Version) }
            'missing' { Write-Bad ('{0} is not installed.' -f $M.Name) }
            'old' { Write-Bad ('{0} {1} is too old. The After run needs {2} or newer.' -f $M.Name, $M.Version, $M.Minimum) }
        }
    }
    $Need = @($Mods | Where-Object { $_.State -ne 'ok' })
    if ($Need.Count -gt 0)
    {
        if (-not (Test-RdaInteractiveHost))
        {
            Write-Note 'This PowerShell cannot ask questions (it is non-interactive), so nothing was installed.'
            Write-RdaAzInstallCommand -Rows $Need
            return [pscustomobject]@{ Ok = $false; Modules = $Mods }
        }
        Write-Host ''
        Write-Host 'These Az PowerShell modules need to be installed or updated:'
        foreach ($M in $Need) { Write-Host ('  {0}' -f (Get-RdaAzInstallCommand -Row $M)) }
        Write-Host 'They go in your own user folder. No admin rights are needed, and other users are not changed.'
        if (-not (Read-RdaYesNo -Question 'Install/update them now for your user only?'))
        {
            Write-RdaAzInstallCommand -Rows $Need
            return [pscustomobject]@{ Ok = $false; Modules = $Mods }
        }
        foreach ($M in $Need)
        {
            Write-Note ('Installing {0} from the PowerShell Gallery ...' -f $M.Name)
            try { Install-RdaAzModule -Row $M }
            catch
            {
                Write-Bad ('Installing {0} failed: {1}' -f $M.Name, $_.Exception.Message)
                Write-RdaAzInstallCommand -Rows $Need
                return [pscustomobject]@{ Ok = $false; Modules = $Mods }
            }
        }
        $Mods = Get-RdaAzModuleState
        $Still = @($Mods | Where-Object { $_.State -ne 'ok' })
        if ($Still.Count -gt 0)
        {
            foreach ($M in $Still) { Write-Bad ('{0} is still {1} after the install.' -f $M.Name, $(if ($M.State -eq 'old') { 'too old' } else { 'missing' })) }
            Write-RdaAzInstallCommand -Rows $Still
            return [pscustomobject]@{ Ok = $false; Modules = $Mods }
        }
        foreach ($M in $Mods) { Write-Ok ('{0} {1}' -f $M.Name, $M.Version) }
    }
    # An older copy already loaded in this window cannot be swapped for the new one.
    $Stale = @($Mods | Where-Object { $_.Loaded -and $_.Minimum -and $_.Loaded -lt $_.Minimum })
    if ($Stale.Count -gt 0)
    {
        foreach ($M in $Stale) { Write-Bad ('{0} {1} is already loaded in this PowerShell window. It needs {2} or newer.' -f $M.Name, $M.Loaded, $M.Minimum) }
        Write-Note 'A module that is already loaded cannot be replaced in a running window.'
        Write-Note 'Open a new PowerShell window and run this script again.'
        Write-Note 'If your PowerShell profile loads Az, start the new window with: pwsh -NoProfile'
        return [pscustomobject]@{ Ok = $false; Modules = $Mods }
    }
    return [pscustomobject]@{ Ok = $true; Modules = $Mods }
}

# ---------------------------------------------------------------------------
# Azure CLI (only for a side whose code still calls it). Never installed here.
# ---------------------------------------------------------------------------

# The one place this script runs the Azure CLI. -Quiet hides its output.
function Invoke-RdaAz
{
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Quiet)
    if ($Quiet) { & az @Arguments *> $null } else { & az @Arguments | Out-Host }
    return $LASTEXITCODE
}

function Get-RdaAzCliInstallAdvice
{
    param([Parameter(Mandatory)][string]$Os)
    switch ($Os)
    {
        'Windows'
        {
            return @('Install it with:  winget install --exact --id Microsoft.AzureCLI',
                'Or see: https://learn.microsoft.com/cli/azure/install-azure-cli-windows')
        }
        'macOS'
        {
            return @('Install it with:  brew update && brew install azure-cli',
                'Or see: https://learn.microsoft.com/cli/azure/install-azure-cli-macos')
        }
        default
        {
            return @('See how to install it on your Linux: https://learn.microsoft.com/cli/azure/install-azure-cli-linux',
                'On Debian or Ubuntu, Microsoft''s script is:  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash')
        }
    }
}

# The Azure CLI is signed in, but its active account is in another tenant. Offers
# 'az account set --subscription <id>', which only picks the active account. When the
# subscription is not in the CLI's list either, only 'az login' helps, so that is named.
function Invoke-RdaAzCliSwitch
{
    param([Parameter(Mandatory)][string]$Tenant, [string]$Subscription, [Parameter(Mandatory)][string]$Side, [Parameter(Mandatory)][string]$LoginText)
    $SetText = if ($Subscription) { 'az account set --subscription {0}' -f $Subscription } else { $LoginText }
    Write-Bad ('{0} needs the Azure CLI''s active account in this tenant, and it is in another one.' -f $Side)
    Write-Note ('Left like this, {0} would sign the Azure CLI out of every account (az account clear) and ask you to sign in again.' -f $Side)
    if (-not $Subscription -or -not (Test-RdaInteractiveHost) -or -not (Read-RdaYesNo -Question 'Switch the Azure CLI to this subscription now?'))
    {
        if (-not (Test-RdaInteractiveHost)) { Write-Note 'This PowerShell cannot ask questions (it is non-interactive).' }
        Write-Note ('Run: {0}' -f $SetText)
        Write-Note ('If that says the subscription is not found, run: {0}' -f $LoginText)
        Write-Note 'Then run this script again.'
        return $false
    }
    $Rc = Invoke-RdaAz -Arguments @('account', 'set', '--subscription', $Subscription, '--output', 'none')
    if ($Rc -eq 0 -and (Test-RdaAzCliSignIn -Tenant $Tenant -Subscription $Subscription) -eq 'ok')
    {
        Write-Ok 'The Azure CLI now uses this subscription.'
        Write-RdaAzCliExtensionNote -Side $Side
        return $true
    }
    # 'az account set' fails when the subscription is not in the CLI's list, which
    # only 'az login' refreshes. Naming 'az account set' again would loop.
    Write-Bad 'The Azure CLI could not switch to this subscription: it is not in the CLI''s list of subscriptions.'
    Write-Note ('Run: {0}' -f $LoginText)
    Write-Note 'Then run this script again.'
    return $false
}

# Signing in or switching cannot fix this: the ids do not belong together.
function Write-RdaSubscriptionTenantStop
{
    Write-Bad 'The Azure CLI lists this subscription under another tenant than -TenantID.'
    Write-Note 'Check -TenantID and -SubscriptionID: the subscription must belong to that tenant.'
}

# Checks the Azure CLI for one side. Offers to sign it in; never installs it.
function Invoke-RdaAzCliCheck
{
    param([Parameter(Mandatory)][string]$Tenant, [Parameter(Mandatory)][string]$Side, [string]$Subscription, [switch]$UseDeviceCode)
    # Cloud Shell has the Azure CLI installed and signed in, but its active account and
    # list of subscriptions are checked there too: the Before release reads them the same way.
    if (Test-RdaCloudShell) { Write-Ok 'Azure Cloud Shell: the Azure CLI is installed.' }
    $LoginArgs = @('login', '--tenant', $Tenant, '--output', 'none')
    if ($UseDeviceCode) { $LoginArgs += '--use-device-code' }
    $LoginText = 'az ' + (($LoginArgs | Where-Object { $_ -notin '--output', 'none' }) -join ' ')
    $State = Test-RdaAzCliSignIn -Tenant $Tenant -Subscription $Subscription
    switch ($State)
    {
        'ok'
        {
            Write-Ok 'Azure CLI is installed and signed in to this tenant.'
            Write-RdaAzCliExtensionNote -Side $Side
            return $true
        }
        'missing'
        {
            Write-Bad ('{0} needs the Azure CLI (az), and it is not installed. This script does not install it.' -f $Side)
            foreach ($L in (Get-RdaAzCliInstallAdvice -Os (Get-RdaOsName))) { Write-Note $L }
            Write-Note 'Then open a new PowerShell window, and run this script again.'
            return $false
        }
        'other-tenant'
        {
            return (Invoke-RdaAzCliSwitch -Tenant $Tenant -Subscription $Subscription -Side $Side -LoginText $LoginText)
        }
        'subscription-other-tenant' { Write-RdaSubscriptionTenantStop; return $false }
    }
    if ($State -eq 'no-subscription')
    {
        # The CLI's list of subscriptions is refreshed only at 'az login'. The Before
        # release collects billing only for subscriptions in that list.
        Write-Bad ('{0} needs this subscription in the Azure CLI''s list of subscriptions, and it is not there yet.' -f $Side)
        Write-Note 'The Azure CLI refreshes that list when you sign in again.'
    }
    else { Write-Bad ('{0} needs the Azure CLI signed in to this tenant, and it is not.' -f $Side) }
    if (-not (Test-RdaInteractiveHost))
    {
        Write-Note 'This PowerShell cannot ask questions (it is non-interactive).'
        Write-Note ('Run: {0}' -f $LoginText)
        Write-Note 'Then run this script again.'
        return $false
    }
    if (-not (Read-RdaYesNo -Question 'Sign in to the Azure CLI now?'))
    {
        Write-Note ('Run: {0}' -f $LoginText)
        Write-Note 'Then run this script again.'
        return $false
    }
    $null = Invoke-RdaAz -Arguments $LoginArgs
    $After = Test-RdaAzCliSignIn -Tenant $Tenant -Subscription $Subscription
    if ($After -eq 'ok')
    {
        Write-Ok 'Azure CLI is signed in to this tenant.'
        Write-RdaAzCliExtensionNote -Side $Side
        return $true
    }
    if ($After -eq 'subscription-other-tenant') { Write-RdaSubscriptionTenantStop; return $false }
    Write-Bad 'The Azure CLI is still not signed in to this tenant with this subscription.'
    Write-Note ('Run: {0}' -f $LoginText)
    Write-Note 'If the subscription is still missing after you sign in, this account cannot see it: ask for the Reader role on it.'
    Write-Note 'Then run this script again.'
    return $false
}

# The Before release adds the Azure CLI 'resource-graph' extension itself when it is
# missing, without asking. Said up front, since that needs internet access.
function Write-RdaAzCliExtensionNote
{
    param([Parameter(Mandatory)][string]$Side)
    if ((Invoke-RdaAz -Arguments @('extension', 'show', '--name', 'resource-graph', '--output', 'none') -Quiet) -eq 0) { return }
    Write-Note ('The Azure CLI extension resource-graph is not installed. {0} installs it by itself (az extension add --name resource-graph),' -f $Side)
    Write-Note 'which needs internet access. To add it now yourself, run: az extension add --name resource-graph'
}

# ---------------------------------------------------------------------------
# Reader check: can the signed-in identity read the whole subscription?
# Never grants a role. Returns @{ State = ok|partial|missing|unknown; How }.
# ---------------------------------------------------------------------------

function Get-RdaJsonList($Object, [string]$Name)
{
    if ($null -eq $Object) { return @() }
    $P = $Object.PSObject.Properties[$Name]
    if (-not $P -or $null -eq $P.Value) { return @() }
    return @($P.Value)
}

# Reads a list of permission entries (actions and notActions). Reader is "*/read".
function Get-RdaReadVerdict
{
    param([object[]]$Permission)
    $Full = $false; $Some = $false
    foreach ($P in @($Permission))
    {
        if ($null -eq $P) { continue }
        # Property names are matched without regard to case (REST: actions, Az: Actions).
        $Acts = @(Get-RdaJsonList $P 'actions')
        $Nots = @(Get-RdaJsonList $P 'notActions')
        $ReadAll = ($Acts -contains '*') -or ($Acts -contains '*/read')
        # Any excluded read (all reads, or one provider's, e.g. Microsoft.Compute/*/read or
        # Microsoft.Compute/*) means this role does not read the whole subscription.
        $Blocked = ($Nots -contains '*') -or ($Nots -contains '*/read')
        $SomeBlocked = @($Nots | Where-Object { $_ -like '*/read' -or $_ -like '*/`*' }).Count -gt 0
        if ($ReadAll -and -not $Blocked -and -not $SomeBlocked) { $Full = $true }
        elseif ($ReadAll -and -not $Blocked) { $Some = $true }
        elseif (@($Acts | Where-Object { $_ -like '*/read' -or $_ -like '*/`*' }).Count -gt 0) { $Some = $true }
    }
    if ($Full) { return 'ok' }
    if ($Some) { return 'partial' }
    return 'missing'
}

# The object id of the signed-in identity, from its access token. $null when unknown.
function Get-RdaSignedInObjectId
{
    try
    {
        $T = (Get-AzAccessToken -ErrorAction Stop -WarningAction SilentlyContinue).Token
        if ($T -is [securestring]) { $T = [Net.NetworkCredential]::new('', $T).Password }
        $Part = ([string]$T).Split('.')[1].Replace('-', '+').Replace('_', '/')
        $Part = $Part.PadRight($Part.Length + (4 - $Part.Length % 4) % 4, '=')
        $Claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Part)) | ConvertFrom-Json
        return [string]$Claims.oid
    }
    catch { return $null }
}

function Test-RdaReaderAccess
{
    param([Parameter(Mandatory)][string]$Subscription)
    # 1. Ask Azure what this caller may do on the subscription. Anyone may ask this
    #    about themselves, and it counts roles given through groups too.
    #    The reply can come in pages (nextLink): at most 10 are read, so this always ends.
    try
    {
        $R = Invoke-AzRestMethod -Method GET -Path ('/subscriptions/{0}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01' -f $Subscription) -ErrorAction Stop
        if ([int]$R.StatusCode -eq 200)
        {
            $Value = [System.Collections.Generic.List[object]]::new()
            $Page = 1
            while ($true)
            {
                $J = $R.Content | ConvertFrom-Json
                foreach ($V in @(Get-RdaJsonList $J 'value')) { $Value.Add($V) }
                $Next = if ($J.PSObject.Properties['nextLink']) { [string]$J.nextLink } else { '' }
                if (-not $Next) { break }
                if ($Page -ge 10) { return [pscustomobject]@{ State = 'unknown'; How = 'permissions' } }
                $R = Invoke-AzRestMethod -Method GET -Uri $Next -ErrorAction Stop
                if ([int]$R.StatusCode -ne 200) { return [pscustomobject]@{ State = 'unknown'; How = 'permissions' } }
                $Page++
            }
            $State = Get-RdaReadVerdict -Permission @($Value)
            # Roles given only on resource groups or single resources are not in the
            # subscription's reply. If any can be read, some resources can: warn, do not stop.
            # Missing only when both lists were read and both are empty; a list that
            # could not be read leaves it unknown (warn).
            if ($State -eq 'missing')
            {
                foreach ($Child in 'resourcegroups', 'resources')
                {
                    $Seen = $null
                    try
                    {
                        $G = Invoke-AzRestMethod -Method GET -Path ('/subscriptions/{0}/{1}?api-version=2021-04-01&$top=1' -f $Subscription, $Child) -ErrorAction Stop
                        if ([int]$G.StatusCode -eq 200)
                        {
                            $Gj = $G.Content | ConvertFrom-Json -ErrorAction Stop
                            if ($Gj.PSObject.Properties['value']) { $Seen = @($Gj.value).Count }
                        }
                    }
                    catch { Write-Verbose ('The {0} list could not be read.' -f $Child) }
                    if ($null -eq $Seen) { $State = 'unknown'; break }
                    if ($Seen -gt 0) { $State = 'partial'; break }
                }
            }
            return [pscustomobject]@{ State = $State; How = 'permissions' }
        }
    }
    catch { Write-Verbose ('Permissions check failed: {0}' -f $_.Exception.Message) }

    # 2. Else look at the role assignments, when Az.Resources is installed. Only
    #    roles given to this identity itself are seen, not those given to a group,
    #    so "none found" is not proof that Reader is missing.
    if (-not (Get-Command Get-AzRoleAssignment -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ State = 'unknown'; How = 'none' } }
    $Oid = Get-RdaSignedInObjectId
    if (-not $Oid) { return [pscustomobject]@{ State = 'unknown'; How = 'roleAssignments' } }
    try
    {
        $Ras = @(Get-AzRoleAssignment -Scope ('/subscriptions/{0}' -f $Subscription) -ObjectId $Oid -ErrorAction Stop -WarningAction SilentlyContinue)
    }
    catch
    {
        # A refusal shows there is no Reader on the whole subscription, but a role on a
        # resource group or a resource can still be there: unknown (warn), not missing.
        return [pscustomobject]@{ State = 'unknown'; How = 'roleAssignments' }
    }
    $Defs = foreach ($Ra in $Ras)
    {
        try { Get-AzRoleDefinition -Id ([string]$Ra.RoleDefinitionId).Split('/')[-1] -Scope ('/subscriptions/{0}' -f $Subscription) -ErrorAction Stop -WarningAction SilentlyContinue }
        catch { Write-Verbose 'A role definition could not be read.' }
    }
    if ((Get-RdaReadVerdict -Permission @($Defs)) -eq 'ok') { return [pscustomobject]@{ State = 'ok'; How = 'roleAssignments' } }
    return [pscustomobject]@{ State = 'unknown'; How = 'roleAssignments' }
}

# Prints the result of the Reader check. False only when read access is clearly missing.
function Invoke-RdaReaderCheck
{
    param([Parameter(Mandatory)][string]$Subscription)
    $R = Test-RdaReaderAccess -Subscription $Subscription
    switch ($R.State)
    {
        'ok' { Write-Ok 'You can read the whole subscription (Reader or higher).'; return $true }
        'partial'
        {
            Write-Note 'Warning: you can read only some kinds of resources in this subscription.'
            Write-Note 'The reports may miss resources. For full reports, ask for the Reader role on it.'
            return $true
        }
        'missing'
        {
            Write-Bad 'This sign-in cannot read the resources in this subscription.'
            Write-Note 'Ask an owner of the subscription to give you the Reader role on it.'
            Write-Note 'This script never gives or changes roles. Then run this script again.'
            return $false
        }
        default
        {
            Write-Note 'Warning: could not check your role on this subscription. Carrying on.'
            Write-Note 'If the reports miss resources, ask for the Reader role on it.'
            return $true
        }
    }
}

# The Azure CLI's own read access on the subscription: the Before release reads
# resources with the CLI's sign-in, which can be another identity than Az PowerShell's.
# ok | partial | missing | unknown, the same verdict as the Az PowerShell check.
function Get-RdaAzCliReadState
{
    param([Parameter(Mandatory)][string]$Subscription)
    if ($Subscription -notmatch $script:GuidPattern) { return 'unknown' }
    $J = Invoke-RdaAzRest -Path ('/subscriptions/{0}/providers/Microsoft.Authorization/permissions' -f $Subscription) -Parameter @('api-version=2022-04-01')
    if ($null -eq $J -or -not $J.PSObject.Properties['value']) { return 'unknown' }
    # A next page is not read here: its link holds '&', which cmd.exe (az.cmd on
    # Windows) would cut. Without the rest of the reply the answer is unknown (warn).
    if ($J.PSObject.Properties['nextLink'] -and $J.nextLink) { return 'unknown' }
    $State = Get-RdaReadVerdict -Permission @($J.value)
    # Roles given only on resource groups or on single resources are not in the
    # subscription's reply. If any can be read, some resources can: warn, do not stop.
    # Missing only when both lists were read and both are empty.
    if ($State -eq 'missing')
    {
        foreach ($Child in 'resourcegroups', 'resources')
        {
            $G = Invoke-RdaAzRest -Path ('/subscriptions/{0}/{1}' -f $Subscription, $Child) -Parameter @('api-version=2021-04-01', '$top=1')
            if ($null -eq $G -or -not $G.PSObject.Properties['value']) { return 'unknown' }
            if (@($G.value).Count -gt 0) { return 'partial' }
        }
    }
    return $State
}

# One read-only 'az rest' GET; the parsed JSON, or $null. The query goes in
# --url-parameters, one item each, so no argument holds '&' (cmd.exe would cut it).
function Invoke-RdaAzRest
{
    param([Parameter(Mandatory)][string]$Path, [string[]]$Parameter = @())
    $A = @('rest', '--method', 'get', '--url', $Path)
    if ($Parameter.Count -gt 0) { $A += '--url-parameters'; $A += $Parameter }
    $A += @('--output', 'json', '--only-show-errors')
    try { $Text = & az @A 2> $null } catch { return $null }
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return ((@($Text) -join "`n") | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Invoke-RdaAzCliReaderCheck
{
    param([Parameter(Mandatory)][string]$Subscription, [Parameter(Mandatory)][string]$Side)
    switch (Get-RdaAzCliReadState -Subscription $Subscription)
    {
        'ok' { Write-Ok ('The Azure CLI sign-in ({0}) can read the whole subscription.' -f $Side); return $true }
        'partial'
        {
            Write-Note ('Warning: the Azure CLI sign-in ({0}) can read only some kinds of resources in this subscription.' -f $Side)
            Write-Note ('{0} may then miss resources that are not a real difference. Sign the Azure CLI in with an account that has Reader.' -f $Side)
            return $true
        }
        'missing'
        {
            Write-Bad ('The Azure CLI sign-in ({0}) cannot read the resources in this subscription.' -f $Side)
            Write-Note 'Sign the Azure CLI in with an account that has the Reader role on it (az login --tenant <tenant id>).'
            Write-Note 'This script never gives or changes roles. Then run this script again.'
            return $false
        }
        default
        {
            Write-Note ('Warning: could not check the Azure CLI sign-in''s role on this subscription ({0}). Carrying on.' -f $Side)
            return $true
        }
    }
}

# ---------------------------------------------------------------------------
# Sign-in: reuse a working Az PowerShell sign-in, or sign in once. Never twice.
# ---------------------------------------------------------------------------
function Test-RdaAzSignIn
{
    param([string]$Tenant, [string]$Subscription)
    $Ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $Ctx -or -not $Ctx.Tenant -or $Ctx.Tenant.Id -ne $Tenant -or -not $Ctx.Subscription -or $Ctx.Subscription.Id -ne $Subscription)
    {
        # Pick the tenant and subscription from the cached sign-in, if it has them. No prompt.
        # -Scope Process: never change the user's saved default tenant or subscription.
        try { $null = Set-AzContext -Tenant $Tenant -Subscription $Subscription -Scope Process -ErrorAction Stop -WarningAction SilentlyContinue }
        catch { return $false }
    }
    try
    {
        $null = Get-AzAccessToken -TenantId $Tenant -ErrorAction Stop -WarningAction SilentlyContinue
        $null = Get-AzSubscription -SubscriptionId $Subscription -TenantId $Tenant -ErrorAction Stop -WarningAction SilentlyContinue
        return $true
    }
    catch { return $false }
}

function Connect-RdaOnce
{
    param([string]$Tenant, [string]$Subscription, [switch]$UseDeviceCode)
    if (Test-RdaAzSignIn -Tenant $Tenant -Subscription $Subscription)
    {
        Write-Ok 'Using your current Az PowerShell sign-in.'
        return $true
    }
    Write-Note 'No working Az PowerShell sign-in for this tenant and subscription. Signing in once.'
    try
    {
        $P = @{ Tenant = $Tenant; Subscription = $Subscription; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
        if ($UseDeviceCode) { $P.UseDeviceAuthentication = $true }
        $null = Connect-AzAccount @P
    }
    catch
    {
        Write-Bad ('Sign-in failed: {0}' -f $_.Exception.Message)
        return $false
    }
    if (Test-RdaAzSignIn -Tenant $Tenant -Subscription $Subscription)
    {
        Write-Ok 'Signed in.'
        return $true
    }
    Write-Bad 'Signed in, but this account cannot read the subscription in this tenant.'
    return $false
}

# The check a new PowerShell process runs: is there a saved sign-in that can get a
# token for this tenant? Its default context may be another tenant, because this
# script switches tenant for its own process only; each run switches the same way.
# -DefaultTenant: the default context itself must be in the tenant. The Before release
# (it still uses the Azure CLI) signs in to Az PowerShell again when it is not.
function Get-RdaChildSignInCheck
{
    param([Parameter(Mandatory)][string]$Tenant, [switch]$DefaultTenant)
    if ($Tenant -notmatch $script:GuidPattern) { throw 'The tenant id must be a GUID.' }
    $TenantTest = if ($DefaultTenant) { " -or -not `$c.Tenant -or `$c.Tenant.Id -ne '$Tenant'" } else { '' }
    return "`$c = Get-AzContext -ErrorAction SilentlyContinue; if (-not `$c -or -not `$c.Account$TenantTest) { return `$false }; try { `$null = Get-AzAccessToken -TenantId '$Tenant' -ErrorAction Stop -WarningAction SilentlyContinue; return `$true } catch { return `$false }"
}

# A new PowerShell process must see the same sign-in, or each run would ask again.
function Test-RdaChildSeesSignIn
{
    param([string]$Tenant, [switch]$DefaultTenant)
    $PwshPath = (Get-Process -Id $PID).Path
    $Cmd = "if (& { $(Get-RdaChildSignInCheck -Tenant $Tenant -DefaultTenant:$DefaultTenant) }) { exit 0 }; exit 3"
    & $PwshPath -NoProfile -NonInteractive -Command $Cmd *> $null
    return ($LASTEXITCODE -eq 0)
}

# The tenant of the Azure CLI's active account, or $null. The Before release reads this
# one (az account show), not a token for the tenant asked for.
function Get-RdaAzCliTenant
{
    param([string]$Subscription)
    $A = @('account', 'show', '--query', 'tenantId', '--output', 'tsv', '--only-show-errors')
    if ($Subscription) { $A += @('--subscription', $Subscription) }
    $Text = & az @A 2> $null
    if ($LASTEXITCODE -ne 0) { return $null }
    $Id = ("$(@($Text) | Select-Object -First 1)").Trim()
    if ($Id -match $script:GuidPattern) { return $Id }
    return $null
}

# ok | missing | not-signed-in | no-subscription | subscription-other-tenant |
# other-tenant (signed in, but the active account is
# in another tenant: the Before release would then run 'az account clear', which signs
# the Azure CLI out of every account, and ask to sign in again).
# With -Subscription: no-subscription when the CLI's list of subscriptions (refreshed
# only at 'az login') does not hold it. The Before release builds its subscription
# list from there, so it would collect no billing for it.
function Test-RdaAzCliSignIn
{
    param([string]$Tenant, [string]$Subscription)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return 'missing' }
    $Rc = Invoke-RdaAz -Arguments @('account', 'get-access-token', '--tenant', $Tenant, '--output', 'none') -Quiet
    if ($Rc -ne 0) { return 'not-signed-in' }
    if ($Subscription)
    {
        $SubTenant = Get-RdaAzCliTenant -Subscription $Subscription
        if (-not $SubTenant) { return 'no-subscription' }
        if ($SubTenant -ne $Tenant) { return 'subscription-other-tenant' }
    }
    if ((Get-RdaAzCliTenant) -ne $Tenant) { return 'other-tenant' }
    return 'ok'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-RdaBeforeAfter
{
    param(
        [string]$TenantID, [string]$SubscriptionID, [switch]$Obfuscate, [string]$OutputDirectory,
        [string]$AfterBranch, [switch]$DeviceLogin, [switch]$KeepCode, [string]$BeforeCodePath, [string]$AfterCodePath,
        [switch]$PreflightOnly
    )
    if (-not $TenantID -or $TenantID -notmatch $script:GuidPattern) { Write-Bad '-TenantID is needed, as a GUID.'; return 1 }
    if (-not $SubscriptionID -or $SubscriptionID -notmatch $script:GuidPattern) { Write-Bad '-SubscriptionID is needed, as a GUID.'; return 1 }
    if ($AfterBranch -notmatch '^[A-Za-z0-9._/-]{1,100}$') { Write-Bad '-AfterBranch holds characters a branch name cannot have.'; return 1 }

    $RunStart = [datetime]::UtcNow
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Get-Location).ProviderPath ('rda-before-after-' + $RunStart.ToString('yyyyMMdd-HHmmss')) }
    # PowerShell's own location, not the process folder: Set-Location does not move that.
    $OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if ((Test-Path -LiteralPath $OutputDirectory) -and @(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0)
    {
        Write-Bad ('The output folder is not empty: {0}. Pick a new folder.' -f $OutputDirectory); return 1
    }
    $ShareDir = Join-Path $OutputDirectory 'share'
    $PrivateDir = Join-Path $OutputDirectory 'private'
    $CodeDir = Join-Path $OutputDirectory 'code'
    $MadeOutput = -not (Test-Path -LiteralPath $OutputDirectory)
    New-Item -ItemType Directory -Force -Path $ShareDir, $PrivateDir, $CodeDir | Out-Null

    Write-Host 'Resource Discovery for Azure: Before and After test on one subscription' -ForegroundColor Cyan
    Write-Host ('Output folder: {0}' -f $OutputDirectory)
    if ($PreflightOnly) { Write-Host 'Checks only (-PreflightOnly): the two runs are not started.' }

    $Exit = 1
    $Sides = @()
    try
    {
        # 1. Checks that need no download. PowerShell itself was checked at the top.
        Write-Step 'Checks'
        Write-Ok ('PowerShell {0} on {1}' -f $PSVersionTable.PSVersion, [Runtime.InteropServices.RuntimeInformation]::OSDescription)
        $ModCheck = Invoke-RdaAzModuleCheck
        $Mods = $ModCheck.Modules
        if (-not $ModCheck.Ok) { return 1 }
        try { Import-Module Az.Accounts -MinimumVersion $script:AfterAzAccountsMinimum -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null }
        catch
        {
            Write-Bad ('Az.Accounts {0} or newer could not be loaded: {1}' -f $script:AfterAzAccountsMinimum, $_.Exception.Message)
            Write-Note 'Open a new PowerShell window and run this script again.'
            return 1
        }

        # 2. Code.
        Write-Step 'Getting the code'
        try
        {
            $Before = Get-RdaCode -Repo $script:BeforeRepo -Branch $script:BeforeBranch -Side 'before' -CodeRoot $CodeDir -LocalPath $BeforeCodePath
            Write-Ok ('Before: {0}, commit {1}' -f $Before.Source, $Before.Commit)
            $After = Get-RdaCode -Repo $script:AfterRepo -Branch $AfterBranch -Side 'after' -CodeRoot $CodeDir -LocalPath $AfterCodePath
            Write-Ok ('After:  {0}, commit {1}' -f $After.Source, $After.Commit)
        }
        catch
        {
            Write-Bad $_.Exception.Message
            if (-not $AfterCodePath -and $_.Exception.Message -like "*'$AfterBranch'*")
            {
                Write-Note ("Try -AfterBranch {0}" -f $script:PushedAfterBranch)
            }
            return 1
        }

        # 3. Azure CLI, only for a side whose code still calls it. Checked once.
        Write-Step 'Azure CLI'
        $UseDevice = $DeviceLogin -or ($IsLinux -and -not $env:DISPLAY -and -not $env:WAYLAND_DISPLAY)
        $CliChecked = $false
        foreach ($S in @(@{ Name = 'Before'; Code = $Before }, @{ Name = 'After'; Code = $After }))
        {
            if (-not (Test-RdaTreeNeedsAzCli -TreePath $S.Code.Tree)) { Write-Ok ('{0} does not use the Azure CLI.' -f $S.Name); continue }
            Write-Note ('{0} still uses the Azure CLI (az) for sign-in and Resource Graph.' -f $S.Name)
            if ($CliChecked) { continue }
            if (-not (Invoke-RdaAzCliCheck -Tenant $TenantID -Subscription $SubscriptionID -Side $S.Name -UseDeviceCode:$UseDevice)) { return 1 }
            $CliChecked = $true
        }

        # 4. Az PowerShell sign-in, once.
        Write-Step 'Az PowerShell sign-in'
        if (-not (Connect-RdaOnce -Tenant $TenantID -Subscription $SubscriptionID -UseDeviceCode:$UseDevice)) { return 1 }
        $Sub = Get-AzSubscription -SubscriptionId $SubscriptionID -TenantId $TenantID -WarningAction SilentlyContinue
        if ([string]$Sub.State -ne 'Enabled') { Write-Bad ('The subscription is {0}, not Enabled.' -f $Sub.State); return 1 }

        # 5. Read access on the subscription. Never grants a role.
        Write-Step 'Access to the subscription'
        if (-not (Invoke-RdaReaderCheck -Subscription $SubscriptionID)) { return 1 }
        $CliSide = @(@(@{ Name = 'Before'; Code = $Before }, @{ Name = 'After'; Code = $After }) | Where-Object { Test-RdaTreeNeedsAzCli -TreePath $_.Code.Tree }) | Select-Object -First 1
        if ($CliSide -and -not (Invoke-RdaAzCliReaderCheck -Subscription $SubscriptionID -Side $CliSide.Name)) { return 1 }

        Write-Step 'Sign-in for the runs'
        if (-not (Test-RdaChildSeesSignIn -Tenant $TenantID))
        {
            Write-Bad 'A new PowerShell window does not see this sign-in, so each run would ask you to sign in again.'
            Write-Note 'Run: Enable-AzContextAutosave -Scope CurrentUser'
            Write-Note 'Then run this script again.'
            return 1
        }
        if ($CliSide -and -not (Test-RdaChildSeesSignIn -Tenant $TenantID -DefaultTenant))
        {
            # Set-AzContext here stays -Scope Process: the saved default is the user's to change.
            Write-Bad ('{0} uses your default Az PowerShell sign-in, and that is in another tenant, so {0} would ask you to sign in again.' -f $CliSide.Name)
            Write-Note ('To make this tenant and subscription your default, run: Set-AzContext -Tenant {0} -Subscription {1}' -f $TenantID, $SubscriptionID)
            Write-Note 'Then run this script again.'
            return 1
        }
        Write-Ok 'The runs will use this sign-in.'

        if ($PreflightOnly)
        {
            Write-Step 'Checks done'
            Write-Ok 'Every check passed. Run the same command without -PreflightOnly to do the two runs.'
            $Exit = 0
            return $Exit
        }

        # 6. The two runs, one after the other.
        foreach ($S in @(@{ Name = 'before'; Code = $Before; Repo = $script:BeforeRepo; Branch = $script:BeforeBranch },
                @{ Name = 'after'; Code = $After; Repo = $script:AfterRepo; Branch = $AfterBranch }))
        {
            $FromGitHub = $S.Code.Source -like 'github.com*'
            if (-not $FromGitHub) { $S.Repo = 'local'; $S.Branch = 'local' }
            Write-Step ('{0} run: {1} {2}, commit {3}' -f $S.Name, $S.Repo, $S.Branch, $S.Code.Commit)
            $ReportDir = Join-Path (Join-Path $PrivateDir $S.Name) 'report'
            $R = Invoke-RdaSide -Tree $S.Code.Tree -ReportDir $ReportDir -Tenant $TenantID -Subscription $SubscriptionID -Mask:$Obfuscate -UseDeviceCode:$UseDevice
            $Label = if ($S.Name -eq 'before') { 'Before_' + $(if ($FromGitHub) { 'awslabs-main' } else { 'local' }) } else { 'After_' + ($S.Branch -replace '[^A-Za-z0-9._-]', '-') }
            $C7 = if ($S.Code.Commit -match '^[0-9a-f]{40}$') { $S.Code.Commit.Substring(0, 7) } else { 'unknown' }
            $ShareName = 'RDA-{0}_{1}{2}.zip' -f $Label, $C7, $(if ($Obfuscate) { '_masked' } else { '' })
            $Counts = $null; $Hash = $null; $Bytes = 0
            if ($R.Zip)
            {
                $Dst = Join-Path $ShareDir $ShareName
                Copy-Item -LiteralPath $R.Zip -Destination $Dst
                $Hash = (Get-FileHash -LiteralPath $Dst -Algorithm SHA256).Hash.ToLowerInvariant()
                $Bytes = (Get-Item -LiteralPath $Dst).Length
                # A zip that cannot be read (cut off, or a bad file in it) is noted, and the next run still goes.
                $Counts = Get-RdaZipCountSafe -Path $Dst
            }
            Write-Host ('   exit {0}, {1} s, peak memory {2} MB' -f $R.ExitCode, $R.WallSeconds, $R.PeakTreeMB)
            if ($Counts -and $Counts.reports -gt 0) { Write-Host ('   inventory rows {0}, consumption rows {1}, metrics rows {2}' -f $Counts.inventoryRows, $Counts.consumptionRows, $Counts.metricsRows) }
            elseif ($Counts) { Write-Bad 'The report zip of this run could not be read.' }
            else { Write-Bad 'This run made no report zip.' }
            if ($Counts -and @($Counts.problems).Count -gt 0) { Write-Note ('Problems: {0}' -f (@($Counts.problems) -join '; ')) }
            $Sides += [ordered]@{
                side = $S.Name; repo = $S.Repo; branch = $S.Branch; commit = $S.Code.Commit; codeSource = $(if ($FromGitHub) { 'github' } else { 'local' })
                toolVersion = (Get-RdaToolVersion -TreePath $S.Code.Tree); usesAzureCli = (Test-RdaTreeNeedsAzCli -TreePath $S.Code.Tree)
                exitCode = $R.ExitCode; startUtc = (Get-UtcText $R.Start); endUtc = (Get-UtcText $R.End); wallSeconds = $R.WallSeconds
                peakProcessMB = $R.PeakProcessMB; peakTreeMB = $R.PeakTreeMB; memorySamples = $R.Samples
                zip = $(if ($R.Zip) { $ShareName } else { $null }); zipBytes = $Bytes; zipSha256 = $Hash; zipsMade = $R.ZipCount
                counts = $Counts
            }
        }

        # 7. Summary (no ids, no names).
        $Summary = [ordered]@{
            summaryVersion = $script:SummaryVersion
            madeUtc = (Get-UtcText ([datetime]::UtcNow))
            obfuscate = [bool]$Obfuscate
            host = [ordered]@{
                os = $(if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } elseif (Test-RdaCloudShell) { 'Cloud Shell' } else { 'Linux' })
                pwsh = $PSVersionTable.PSVersion.ToString()
                azModules = [ordered]@{}
                cpuCount = [Environment]::ProcessorCount
            }
            sides = $Sides
        }
        foreach ($M in $Mods) { $Summary.host.azModules[$M.Name] = [string]$M.Version }
        $Summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ShareDir 'ab-summary.json') -Encoding utf8

        $AllOk = Test-RdaRunsComparable -Sides $Sides
        Write-Step 'Done'
        $ShareFiles = @(Get-ChildItem -LiteralPath $ShareDir -File)
        Write-Host ('Please send back the {0} file(s) in this folder:' -f $ShareFiles.Count) -ForegroundColor Green
        Write-Host ('  {0}' -f $ShareDir)
        $ShareFiles | ForEach-Object { Write-Host ('    {0}' -f $_.Name) }
        foreach ($L in (Get-RdaEndNote -Sides $Sides -Obfuscate:$Obfuscate)) { Write-Note $L }
        foreach ($Sd in $Sides) { if ($Sd.exitCode -ne 0) { Write-Note ('The {0} run ended with exit {1}.' -f $Sd.side, $Sd.exitCode) } }
        Write-Host ''
        Write-Host ('Keep this folder to yourself: {0}' -f $PrivateDir) -ForegroundColor Yellow
        Write-Host '  It holds the full run logs and, with -Obfuscate, each run''s dictionary.'
        if (-not $Obfuscate) { Write-Host '  Without -Obfuscate the shared zips hold your real resource names and ids, as the tool''s normal report does.' }
        if (-not $AllOk) { Write-Bad 'A run did not end cleanly, or a file in its report could not be read or failed a quick format check (see Problems above). Send the files anyway: they show what went wrong.' }
        $Exit = $(if ($AllOk) { 0 } else { 1 })
    }
    finally
    {
        if (-not $KeepCode -and (Test-Path -LiteralPath $CodeDir)) { Remove-Item -LiteralPath $CodeDir -Recurse -Force -ErrorAction SilentlyContinue }
        # No run made anything (a check stopped, or -PreflightOnly): leave no empty folders.
        foreach ($D in @($ShareDir, $PrivateDir))
        {
            if ((Test-Path -LiteralPath $D) -and @(Get-ChildItem -LiteralPath $D -Force).Count -eq 0) { Remove-Item -LiteralPath $D -Force -ErrorAction SilentlyContinue }
        }
        if ($MadeOutput -and (Test-Path -LiteralPath $OutputDirectory) -and @(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -eq 0)
        {
            Remove-Item -LiteralPath $OutputDirectory -Force -ErrorAction SilentlyContinue
        }
    }
    return $Exit
}

# Dot-sourcing loads the functions only (used by the tests).
if ($MyInvocation.InvocationName -ne '.')
{
    $Code = Invoke-RdaBeforeAfter -TenantID $TenantID -SubscriptionID $SubscriptionID -Obfuscate:$Obfuscate -OutputDirectory $OutputDirectory `
        -AfterBranch $AfterBranch -DeviceLogin:$DeviceLogin -KeepCode:$KeepCode -BeforeCodePath $BeforeCodePath -AfterCodePath $AfterCodePath `
        -PreflightOnly:$PreflightOnly
    exit $Code
}
