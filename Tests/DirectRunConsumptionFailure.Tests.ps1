# End of a direct run whose consumption could not be collected for a subscription
# Run with: Invoke-Pester ./Tests/DirectRunConsumptionFailure.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A direct ResourceInventory.ps1 run over several subscriptions records a
# subscription whose billing pull failed, and says so in a warning when the
# call fails and in the Diagnostics log. The end of the run said nothing, so a
# report missing that subscription's cost data ended like a complete one.
# Run-AllSubscriptions.ps1 prints a 'Consumption Failures' block at its end;
# a direct run now prints the same block after 'Reporting Time:', ahead of
# 'Reporting Data File:'.
#
# Such a run now ends with the FAILED (consumption) lines and exit 3, as
# Run-AllSubscriptions.ps1 does; a run with no failure still exits 0.
#
# The test copies the scripts to a temp folder and runs the REAL
# ResourceInventory.ps1 directly in a child pwsh with HOME pointed at a temp
# folder and offline stand-ins for the Az cmdlets: the up-front role and
# consumption checks pass for both subscriptions, and the first
# subscription's billing call fails on every attempt. The metrics phase is
# skipped (-SkipMetrics); retry waits are skipped by a Start-Sleep stand-in.
# Placeholder ids only; no live Azure.
#
# Not run on Windows, as the other child-process harnesses.

BeforeDiscovery {
    $script:SkipReason = $IsWindows
}

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('DirectRunConsumptionFailure_' + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    $script:Harness = Join-Path $script:WorkDir 'run.ps1'
    @'
param([string]$Tree, [string]$Out, [string]$FailIds = '')
$PSStyle.OutputRendering = 'PlainText'
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$Tenant = '12345678-1234-1234-1234-123456789012'
$Global:StandInSubs = @(
    [pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012'; Name = 'Sub A' },
    [pscustomobject]@{ Id = 'placeholder-subscription-b'; Name = 'Sub B' })
$Global:StandInFailIds = @($FailIds -split ',' | Where-Object { $_ })
$Global:StandInContextSub = $Global:StandInSubs[0].Id
# The stand-ins below are functions of this runspace, so the up-front checks
# run one subscription at a time here.
$Global:PSDefaultParameterValues['Test-SubscriptionRoleAccessAll:ThrottleLimit'] = 1
$Global:PSDefaultParameterValues['Invoke-ConsumptionDataCheck:ThrottleLimit'] = 1

function global:New-StandInUsageRow
{
    param([string]$Sub)
    $Uri = '/subscriptions/{0}/resourceGroups/rg-demo/providers/Microsoft.Network/publicIPAddresses/pip-demo' -f $Sub
    $Instance = @{ 'Microsoft.Resources' = @{ resourceUri = $Uri; location = 'eastus'; additionalInfo = @{} } } | ConvertTo-Json -Depth 5 -Compress
    [pscustomobject]@{ InstanceData = $Instance; MeterCategory = 'Virtual Network'; MeterId = 'meter-1'; MeterName = 'Static Public IP'; MeterRegion = 'US East'; MeterSubCategory = 'IP Addresses'; Quantity = 24; Unit = '1 Hour'; UsageStartTime = (Get-Date).AddDays(-2).Date; UsageEndTime = (Get-Date).AddDays(-1).Date }
}
function global:Invoke-StandInGraph
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'graph*')
    {
        $Subs = @()
        for ($i = 0; $i -lt $args.Count - 1; $i++) { if ([string]$args[$i] -eq '--subscriptions') { $j = $i + 1; while ($j -lt $args.Count -and [string]$args[$j] -notlike '--*') { $Subs += [string]$args[$j]; $j++ } } }
        if ($Joined -match 'desktopvirtualizationresources') { return '{"data":[{"count_":0}],"count":1}' }
        if ($Joined -match 'summarize count\(\)') { return ('{{"data":[{{"count_":{0}}}],"count":1}}' -f $Subs.Count) }
        if ($Joined -match '--skip [1-9]') { return '{"data":[],"count":0}' }
        $Rows = foreach ($Sub in $Subs)
        {
            @{ id = "/subscriptions/$Sub/resourceGroups/rg-demo/providers/Microsoft.Network/publicIPAddresses/pip-demo"; name = 'pip-demo'; type = 'microsoft.network/publicipaddresses'; location = 'eastus'; subscriptionId = $Sub; resourceGroup = 'rg-demo'
                sku = @{ name = 'Standard' }; properties = @{ publicIPAllocationMethod = 'Static'; publicIPAddressVersion = 'IPv4'; provisioningState = 'Succeeded' } }
        }
        return (@{ data = @($Rows); count = @($Rows).Count } | ConvertTo-Json -Depth 8 -Compress)
    }
    return $null
}
function global:Get-AzContext { [CmdletBinding()] param() [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = '12345678-1234-1234-1234-123456789012' }; Subscription = [pscustomobject]@{ Id = $Global:StandInContextSub; Name = 'stand-in' }; Account = [pscustomobject]@{ Id = 'tester' } } }
function global:Set-AzContext { [CmdletBinding()] param($Subscription, $Scope, $Context, $Tenant) if ($Subscription) { $Global:StandInContextSub = [string]$Subscription }; $null }
function global:Get-AzAccessToken { [CmdletBinding()] param($ResourceUrl, $TenantId) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
function global:Connect-AzAccount { throw 'no sign-in in this harness' }
function global:Import-AzContext { [CmdletBinding()] param($Path) }
function global:Disable-AzContextAutosave { [CmdletBinding()] param($Scope) }
function global:Get-AzContextAutosaveSetting { [CmdletBinding()] param($Scope) [pscustomobject]@{ Mode = 'Process'; ContextFile = 'None'; CacheFile = 'None' } }
# Up-front checks: Reader on each subscription, one usage row above zero, one resource each.
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Json = { param($Obj) [pscustomobject]@{ StatusCode = 200; Content = ($Obj | ConvertTo-Json -Depth 10) } }
    $Sub = if ($Target -match '^/subscriptions/([^/?]+)') { $Matches[1] } else { '' }
    if ($Target -match 'Microsoft\.ResourceGraph/resources') { return (& $Json @{ data = @(@(($Payload | ConvertFrom-Json).subscriptions) | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 1 } }) }) }
    if ($Target -match '/roleAssignments\?') { return (& $Json @{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$Sub/providers/Microsoft.Authorization/roleDefinitions/reader"; scope = "/subscriptions/$Sub"; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) }) }
    if ($Target -match '/roleDefinitions/') { return (& $Json @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } }) }
    if ($Target -match '/providers/Microsoft\.Authorization/permissions\?') { return (& $Json @{ value = @(@{ actions = @('*/read'); notActions = @() }) }) }
    if ($Target -match 'Microsoft\.Commerce/UsageAggregates')
    {
        $Row = New-StandInUsageRow -Sub $Sub
        return (& $Json @{ value = @(@{ properties = @{ instanceData = $Row.InstanceData; meterCategory = $Row.MeterCategory; quantity = 24 } }) })
    }
    throw ('no stand-in for {0} {1}' -f $Method, $Target)
}
# The billing phase: Get-UsageAggregates reads the subscription of the current
# context; it fails on every attempt for the subscriptions in -FailIds.
function global:Get-AzUsageAggregate
{
    [CmdletBinding()] param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken)
    if ($Global:StandInFailIds -contains $Global:StandInContextSub) { throw 'stand-in: the usage service returned an error for this page' }
    [pscustomobject]@{ UsageAggregations = @([pscustomobject]@{ Properties = (New-StandInUsageRow -Sub $Global:StandInContextSub) }); ContinuationToken = $null }
}
function global:Get-UsageAggregates { Get-AzUsageAggregate @args }
function global:Start-Sleep { param($Seconds, $Milliseconds) }

# The inventory and the sign-in go through the Azure CLI on this tool.
function global:az
{
    $Joined = $args -join ' '
    $global:LASTEXITCODE = 0
    if ($Joined -like 'account show*') { return '{"user":{"name":"tester"},"tenantId":"12345678-1234-1234-1234-123456789012"}' }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -InputObject @($Global:StandInSubs | ForEach-Object { @{ id = $_.Id; name = $_.Name; tenantId = '12345678-1234-1234-1234-123456789012' } }) -Compress) }
    if ($Joined -like 'extension list*') { return '[{"name":"resource-graph"}]' }
    Invoke-StandInGraph @args
}
Set-Location $Tree
$global:LASTEXITCODE = 0
& (Join-Path $Tree 'ResourceInventory.ps1') -TenantID $Tenant -SkipMetrics -OutputDirectory $Out -Service PublicIP
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

    function Invoke-DirectRun
    {
        param([string]$FailIds = '')
        $CaseHome = Join-Path $script:WorkDir ('home_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Out = Join-Path $CaseHome 'out'
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        $SavedHome = $env:HOME
        try
        {
            $env:HOME = $CaseHome
            $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Harness -Tree $script:Tree -Out $Out -FailIds $FailIds 2>&1 | ForEach-Object { [string]$_ })
            $ExitCode = $LASTEXITCODE
        }
        finally
        {
            $env:HOME = $SavedHome
        }
        $Text = $Console -join "`n"
        $At = $Text.IndexOf('Reporting Time:')
        return [pscustomobject]@{
            Console = $Text
            Exit    = $ExitCode
            End     = $(if ($At -ge 0) { $Text.Substring($At) } else { '' })
            Zip     = @(Get-ChildItem -Path $Out -Filter 'ResourcesReport_*.zip' -File)
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) { Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Direct run whose billing pull failed for one subscription' -Skip:$script:SkipReason {
    BeforeAll {
        $script:Failed = Invoke-DirectRun -FailIds '12345678-1234-1234-1234-123456789012'
    }

    It 'writes the report and its zip' {
        $script:Failed.Zip.Count | Should -Be 1 -Because $script:Failed.Console
    }

    It 'names the subscription and the reason at the end of the run' {
        $script:Failed.End | Should -Match 'Consumption Failures:\s+1 subscription\(s\)'
        $script:Failed.End | Should -Match '(?m)^  - Sub A \(12345678-1234-1234-1234-123456789012\)$'
        $script:Failed.End | Should -Match 'stand-in: the usage service returned an error for this page \(stopped at consumption page 1'
        $script:Failed.End | Should -Not -Match 'Sub B \('
    }

    It 'ends with FAILED (consumption), naming the subscription and the command that collects it again' {
        $Lines = @($script:Failed.Console -split "`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ })
        $At = [array]::LastIndexOf($Lines, '================= FAILED (consumption) =================')
        $At | Should -BeGreaterThan 0 -Because $script:Failed.Console
        $Lines[($At + 1)..($Lines.Count - 1)] | Should -Be @(
            'Consumption (billing) data is missing or incomplete for 1 subscription(s):'
            '  - Sub A (12345678-1234-1234-1234-123456789012)'
            'To collect one again, run:'
            '  ./ResourceInventory.ps1 -TenantID 12345678-1234-1234-1234-123456789012 -SubscriptionID 12345678-1234-1234-1234-123456789012'
            '========================================================'
        )
    }

    It 'exits 3' {
        $script:Failed.Exit | Should -Be 3
    }
}

Describe 'Direct run whose billing pull succeeded for every subscription' -Skip:$script:SkipReason {
    It 'prints no consumption failure block' {
        $Clean = Invoke-DirectRun
        $Clean.Zip.Count | Should -Be 1 -Because $Clean.Console
        $Clean.End | Should -Not -BeNullOrEmpty
        $Clean.End | Should -Not -Match 'Consumption Failures'
        $Clean.Console | Should -Not -Match 'FAILED \(consumption\)'
        $Clean.Exit | Should -Be 0
    }
}
