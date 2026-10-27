#Requires -Version 7.0
# =============================================================================
# ConsumptionDataCheck.Tests.ps1
#
# The up-front consumption data check (Functions/Common.Functions.ps1): when
# consumption is requested, a run must not start unless every in-scope
# subscription returns at least one usage row with a quantity above zero for
# the billing phase's window. Get-UsageAggregates returns no error and zero rows
# for an identity without Microsoft.Commerce/UsageAggregates/read, so the check
# must prove values came back rather than trust "no error".
#
# The Az cmdlets are replaced by local stub functions and Pester mocks, so the
# tests run offline and without the Az modules installed.
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    foreach ($Fn in @('Get-ConsumptionWindow', 'Get-ConsumptionCheckVerdict', 'Invoke-ConsumptionValueProbe', 'Invoke-ConsumptionDataCheck', 'Write-ConsumptionDataCheckReport'))
    {
        if (-not (Get-Command $Fn -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function '$Fn' to be defined by Functions/Common.Functions.ps1."
        }
    }

    # Stubs so the mocks below have a command to replace when Az is absent.
    function Get-UsageAggregates { param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken) }
    function Set-AzContext { param($Subscription, $Context, $Scope) }
    function Get-AzContext { param() }
    function Invoke-AzRestMethod { param($Method, $Path, $Payload) }

    function New-UsagePage
    {
        param([object[]]$Quantities = @(), [string]$Token = $null)
        [pscustomobject]@{
            UsageAggregations = @($Quantities | ForEach-Object { [pscustomobject]@{ Properties = [pscustomobject]@{ Quantity = $_ } } })
            ContinuationToken = $Token
        }
    }

    function New-ResourceCountResponse
    {
        param([hashtable]$Counts)
        $Rows = @($Counts.GetEnumerator() | Where-Object { $_.Value -gt 0 } | ForEach-Object { @{ subscriptionId = $_.Key; ResourceCount = $_.Value } })
        [pscustomobject]@{ StatusCode = 200; Content = (@{ data = $Rows } | ConvertTo-Json -Depth 4) }
    }

    function New-StatusException
    {
        param([string]$Message, [System.Net.HttpStatusCode]$Status)
        [System.Net.Http.HttpRequestException]::new($Message, $null, $Status)
    }

    # Shaped like Hyak.Common.CloudException: status under .Response.StatusCode.
    function New-CloudShapedException
    {
        param([string]$Message, [System.Net.HttpStatusCode]$Status)
        $Ex = [System.Exception]::new($Message)
        $Ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status })
        $Ex
    }

    $script:Window = Get-ConsumptionWindow -Now ([datetime]'2026-10-26T10:00:00')
}

Describe 'Get-ConsumptionWindow' {
    It 'is the billing phase window: local midnight 31 days ago to local midnight yesterday' {
        $W = Get-ConsumptionWindow -Now ([datetime]'2026-10-26T15:30:00')
        $W.Start | Should -Be ([datetime]'2026-09-25T00:00:00')
        $W.End | Should -Be ([datetime]'2026-10-25T00:00:00')
    }

    It 'returns Kind=Unspecified, equal to what the earlier .DateTime strings converted to' {
        $Now = [datetime]::SpecifyKind([datetime]'2026-10-26T15:30:00', [System.DateTimeKind]::Local)
        $W = Get-ConsumptionWindow -Now $Now
        $W.Start.Kind | Should -Be ([System.DateTimeKind]::Unspecified)
        $W.End.Kind | Should -Be ([System.DateTimeKind]::Unspecified)

        $EnUs = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
        $Old = $Now.AddDays(-31).Date.ToString('F', $EnUs)
        $Converted = [System.Management.Automation.LanguagePrimitives]::ConvertTo($Old, [datetime], $EnUs)
        $W.Start.Ticks | Should -Be $Converted.Ticks
        $W.Start.Kind | Should -Be $Converted.Kind
    }

    It 'is the window the billing phase uses (ResourceInventory.ps1 calls Get-ConsumptionWindow)' {
        $Text = Get-Content -Path (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw
        $Text | Should -Match '\$ConsumptionWindow = Get-ConsumptionWindow'
        $Text | Should -Not -Match 'AddDays\(-31\)\.Date'
    }
}

Describe 'Test-ConsumptionRowsHavePositiveQuantity' {
    It 'is false for no rows, zero, negative and non-numeric quantities' {
        Test-ConsumptionRowsHavePositiveQuantity -Rows @() | Should -BeFalse
        Test-ConsumptionRowsHavePositiveQuantity -Rows @([pscustomobject]@{ Quantity = 0 }, [pscustomobject]@{ Quantity = [decimal]0 }) | Should -BeFalse
        Test-ConsumptionRowsHavePositiveQuantity -Rows @([pscustomobject]@{ Quantity = -1 }) | Should -BeFalse
        Test-ConsumptionRowsHavePositiveQuantity -Rows @([pscustomobject]@{ Quantity = 'n/a' }, [pscustomobject]@{ Quantity = $null }, [pscustomobject]@{ Quantity = $true }) | Should -BeFalse
    }

    It 'is true when any row has a quantity above zero' {
        Test-ConsumptionRowsHavePositiveQuantity -Rows @([pscustomobject]@{ Quantity = 0 }, [pscustomobject]@{ Quantity = [decimal]0.0001 }) | Should -BeTrue
        Test-ConsumptionRowsHavePositiveQuantity -Rows @([pscustomobject]@{ Quantity = '4.5' }) | Should -BeTrue
    }
}

Describe 'Invoke-ConsumptionValueProbe and Get-ConsumptionCheckVerdict' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } }
    }

    It 'refuses an empty result (no error, zero rows)' {
        Mock Get-UsageAggregates { New-UsagePage }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5
        $Verdict.Outcome | Should -Be 'NoRows'
        $Verdict.Passed | Should -BeFalse
    }

    It 'refuses when rows come back but every quantity is 0' {
        Mock Get-UsageAggregates { New-UsagePage -Quantities @(0, 0, 0) }
        $Verdict = Get-ConsumptionCheckVerdict -Probe (Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window) -ResourceCount 5
        $Verdict.Outcome | Should -Be 'NoPositiveQuantity'
        $Verdict.Passed | Should -BeFalse
    }

    It 'passes on one positive row and queries the billing phase window with the same options' {
        Mock Get-UsageAggregates { New-UsagePage -Quantities @(0, 2.5) }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        (Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5).Outcome | Should -Be 'Pass'
        Should -Invoke Get-UsageAggregates -Times 1 -Exactly -ParameterFilter {
            $ReportedStartTime -eq $script:Window.Start -and $ReportedEndTime -eq $script:Window.End -and
            $AggregationGranularity -eq 'Daily' -and $ShowDetails -eq $true
        }
        Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $Subscription -eq 'sub-a' -and $Scope -eq 'Process' }
    }

    It 'passes when the only positive row is on page 2, and stops paging there' {
        Mock Get-UsageAggregates { New-UsagePage -Quantities @(0, 0) -Token 'page2' } -ParameterFilter { [string]::IsNullOrEmpty($ContinuationToken) }
        Mock Get-UsageAggregates { New-UsagePage -Quantities @(0, 7) -Token 'page3' } -ParameterFilter { $ContinuationToken -eq 'page2' }
        Mock Get-UsageAggregates { New-UsagePage -Quantities @(9) } -ParameterFilter { $ContinuationToken -eq 'page3' }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        (Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5).Outcome | Should -Be 'Pass'
        $Probe.PagesRead | Should -Be 2
        Should -Invoke Get-UsageAggregates -Times 0 -Exactly -ParameterFilter { $ContinuationToken -eq 'page3' }
    }

    It 'refuses a permission error without retrying it' {
        Mock Get-UsageAggregates { throw (New-StatusException -Message "The client does not have authorization to perform action 'Microsoft.Commerce/UsageAggregates/read'" -Status Forbidden) }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5
        $Verdict.Outcome | Should -Be 'Denied'
        $Verdict.Passed | Should -BeFalse
        Should -Invoke Get-UsageAggregates -Times 1 -Exactly
    }

    It 'passes when a transient failure is followed by success' {
        $script:Calls = 0
        Mock Get-UsageAggregates {
            $script:Calls++
            if ($script:Calls -le 2) { throw (New-StatusException -Message 'Too many requests' -Status TooManyRequests) }
            New-UsagePage -Quantities @(1)
        }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        (Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5).Outcome | Should -Be 'Pass'
        Should -Invoke Get-UsageAggregates -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'refuses a transient failure that persists after the bounded retries' {
        Mock Get-UsageAggregates { throw (New-StatusException -Message 'Service unavailable' -Status ServiceUnavailable) }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window -MaxRetries 3
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5
        $Verdict.Outcome | Should -Be 'Error'
        $Verdict.Passed | Should -BeFalse
        Should -Invoke Get-UsageAggregates -Times 4 -Exactly
    }

    It 'refuses a 400 without retrying it' {
        Mock Get-UsageAggregates { throw (New-CloudShapedException -Message 'InvalidInput: The reportedstarttime must have the time set to midnight (0:00:00Z).' -Status BadRequest) }
        $Probe = Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window
        $Verdict = Get-ConsumptionCheckVerdict -Probe $Probe -ResourceCount 5
        $Verdict.Outcome | Should -Be 'Error'
        $Verdict.Detail | Should -Match 'HTTP 400'
        Should -Invoke Get-UsageAggregates -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'refuses when the context cannot be switched to the subscription, without querying usage' {
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'some-other-sub' } } }
        Mock Get-UsageAggregates { New-UsagePage -Quantities @(1) }
        $Verdict = Get-ConsumptionCheckVerdict -Probe (Invoke-ConsumptionValueProbe -SubscriptionId 'sub-a' -Window $script:Window) -ResourceCount 5
        $Verdict.Passed | Should -BeFalse
        Should -Invoke Get-UsageAggregates -Times 0 -Exactly
    }
}

Describe 'Get-ConsumptionErrorKind' {
    It 'treats throttling, timeouts and 5xx as transient' {
        Get-ConsumptionErrorKind -Exception (New-StatusException -Message 'x' -Status TooManyRequests) | Should -Be 'Transient'
        Get-ConsumptionErrorKind -Exception (New-StatusException -Message 'x' -Status BadGateway) | Should -Be 'Transient'
        Get-ConsumptionErrorKind -Exception (New-CloudShapedException -Message 'x' -Status InternalServerError) | Should -Be 'Transient'
        Get-ConsumptionErrorKind -Exception ([System.TimeoutException]::new('The operation has timed out.')) | Should -Be 'Transient'
    }

    It 'treats 400, 401, 403 and unclassified errors as permanent' {
        Get-ConsumptionErrorKind -Exception (New-CloudShapedException -Message 'InvalidInput' -Status BadRequest) | Should -Be 'Permanent'
        Get-ConsumptionErrorKind -Exception (New-StatusException -Message 'x' -Status Unauthorized) | Should -Be 'Permanent'
        Get-ConsumptionErrorKind -Exception (New-StatusException -Message 'x' -Status Forbidden) | Should -Be 'Permanent'
        Get-ConsumptionErrorKind -Exception ([System.Exception]::new('Subscription not found')) | Should -Be 'Permanent'
    }
}

Describe 'Invoke-ConsumptionDataCheck across subscriptions' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Write-Host { }
        Mock Get-AzContext { [pscustomobject]@{ Name = 'original'; Subscription = [pscustomobject]@{ Id = 'original-sub' } } }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } } -ParameterFilter { $null -ne $Subscription }
        Mock Set-AzContext { $Context } -ParameterFilter { $null -ne $Context }
        $script:Subs = @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie' }
        )
    }

    It 'checks every subscription and lists all failures, not just the first' {
        Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 3; 'sub-b' = 4; 'sub-c' = 5 } }
        $script:LastSub = $null
        Mock Get-UsageAggregates { if ($script:LastSub -eq 'sub-b') { New-UsagePage -Quantities @(2) } else { New-UsagePage } }
        Mock Set-AzContext { $script:LastSub = $Subscription; [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } } -ParameterFilter { $null -ne $Subscription }

        $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:Subs -Window $script:Window
        $Result.ShouldBlock | Should -BeTrue
        @($Result.Results).Count | Should -Be 3
        @($Result.Failed | ForEach-Object { $_.Name }) | Should -Be @('Alpha', 'Charlie')
        Should -Invoke Get-UsageAggregates -Times 3 -Exactly

        $script:Printed = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Printed.Add([string]$Object) }
        Write-ConsumptionDataCheckReport -Result $Result
        $Text = $script:Printed -join "`n"
        $Text | Should -Match 'Alpha \(sub-a\): NoRows'
        $Text | Should -Match 'Charlie \(sub-c\): NoRows'
        $Text | Should -Not -Match 'Bravo \(sub-b\)'
        $Text | Should -Match '2026-09-25 to 2026-10-25'
        $Text | Should -Match 'Microsoft\.Commerce/UsageAggregates/read'
        $Text | Should -Match 'Cost Management Reader does NOT'
        $Text | Should -Match 'CSP'
        $Text | Should -Match '-SkipConsumption'
    }

    It 'exempts a subscription with zero resources without querying its usage' {
        Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 3; 'sub-b' = 0; 'sub-c' = 5 } }
        Mock Get-UsageAggregates { New-UsagePage -Quantities @(1) }
        $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:Subs -Window $script:Window
        $Result.ShouldBlock | Should -BeFalse
        @($Result.Exempt | ForEach-Object { $_.Id }) | Should -Be @('sub-b')
        Should -Invoke Set-AzContext -Times 0 -Exactly -ParameterFilter { $Subscription -eq 'sub-b' }
        Should -Invoke Get-UsageAggregates -Times 2 -Exactly
    }

    It 'checks every subscription when the resource count query fails (no exemption on unknown counts)' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 403; Content = '{}' } }
        Mock Get-UsageAggregates { New-UsagePage -Quantities @(1) }
        $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:Subs -Window $script:Window
        $Result.Exempt.Count | Should -Be 0
        Should -Invoke Get-UsageAggregates -Times 3 -Exactly
    }

    It 'passes when every subscription returns a positive quantity, and restores the original process context' {
        Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 1; 'sub-b' = 1; 'sub-c' = 1 } }
        Mock Get-UsageAggregates { New-UsagePage -Quantities @(0.5) }
        $Result = Invoke-ConsumptionDataCheck -Subscriptions $script:Subs -Window $script:Window
        $Result.ShouldBlock | Should -BeFalse
        Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $null -ne $Context -and $Context.Name -eq 'original' -and $Scope -eq 'Process' }
        Should -Invoke Set-AzContext -Times 0 -Exactly -ParameterFilter { $Scope -ne 'Process' }
    }
}

Describe 'Run-AllSubscriptions.ps1 consumption data check block' {
    BeforeAll {
        $WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
        $Tokens = $null
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($WrapperPath, [ref]$Tokens, [ref]$Errors)
        $Top = @($Ast.EndBlock.Statements)
        $script:ScopeIndex = -1
        for ($I = 0; $I -lt $Top.Count; $I++)
        {
            if ($Top[$I].Extent.Text -match '^\$ConsumptionCheckScope\s*=') { $script:ScopeIndex = $I; break }
        }
        if ($script:ScopeIndex -lt 0) { throw 'The consumption data check block was not found in Run-AllSubscriptions.ps1.' }
        $script:CheckBlock = [scriptblock]::Create(($Top[$script:ScopeIndex].Extent.Text + "`n" + $Top[$script:ScopeIndex + 1].Extent.Text))

        $script:FirstInventoryIndex = -1
        for ($I = 0; $I -lt $Top.Count; $I++)
        {
            if ($Top[$I].Extent.Text -match "ResourceInventory\.ps1'|Run-AllSubscriptions\.Stream\.ps1|Get-RecommendedParallelism") { $script:FirstInventoryIndex = $I; break }
        }
        $script:OldGateRemoved = ((Get-Content -Path $WrapperPath -Raw) -notmatch 'Test-ConsumptionAccess|ConsumptionProbeSub')

        # The wrapper defines Exit-Wrapper in RunAllSubscriptions.Functions.ps1;
        # a stub is enough for the mock to replace.
        function Exit-Wrapper { param([int]$Code = 0) }
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Exit-Wrapper { throw ('EXIT {0}' -f $Code) }
        Mock Invoke-AzRestMethod { New-ResourceCountResponse -Counts @{ 'sub-a' = 2; 'sub-b' = 2 } }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } }
        Mock Get-AzContext { $null }
        # The wrapper's variables the check block reads, in script scope so the
        # dot-sourced block resolves them.
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' })
        $script:CompletedIds = @()
        $script:Resume = $false
        $script:SkipConsumption = $false
    }

    AfterAll {
        Remove-Variable -Name Subscriptions, CompletedIds, Resume, SkipConsumption -Scope Script -ErrorAction SilentlyContinue
    }

    It 'runs before parallelism tuning and before any inventory invocation, and replaces the first-subscription gate' {
        $script:FirstInventoryIndex | Should -BeGreaterThan $script:ScopeIndex
        $script:OldGateRemoved | Should -BeTrue
    }

    It 'exits 1 (before inventory starts) when consumption returns no values' {
        Mock Get-UsageAggregates { New-UsagePage }
        { . $script:CheckBlock } | Should -Throw 'EXIT 1'
        Should -Invoke Get-UsageAggregates -Times 2 -Exactly
    }

    It 'continues when every subscription returns values' {
        Mock Get-UsageAggregates { New-UsagePage -Quantities @(3) }
        { . $script:CheckBlock } | Should -Not -Throw
        Should -Invoke Exit-Wrapper -Times 0 -Exactly
    }

    It 'skips the check entirely under -SkipConsumption' {
        $script:SkipConsumption = $true
        Mock Get-UsageAggregates { New-UsagePage }
        { . $script:CheckBlock } | Should -Not -Throw
        Should -Invoke Get-UsageAggregates -Times 0 -Exactly
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
    }

    It 'on -Resume checks only the subscriptions this run will process' {
        $script:Resume = $true
        $script:CompletedIds = @('sub-a')
        Mock Get-UsageAggregates { New-UsagePage -Quantities @(3) }
        { . $script:CheckBlock } | Should -Not -Throw
        Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $Subscription -eq 'sub-b' }
        Should -Invoke Set-AzContext -Times 0 -Exactly -ParameterFilter { $Subscription -eq 'sub-a' }
    }
}

Describe 'ResourceInventory.ps1 direct run' {
    BeforeAll {
        # Runs the real script in a child pwsh with Azure replaced by stubs. The
        # stubbed 'az graph' call is the first inventory step after setup; it
        # writes a marker and exits 3, so reaching inventory is observable and
        # nothing past it runs.
        $script:Harness = Join-Path $TestDrive 'harness.ps1'
        @'
param([string]$Root, [string]$Out, [string]$Mode, [switch]$SkipConsumption)
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
$TestSub = '12345678-1234-1234-1234-123456789012'
function global:az
{
    $Joined = $args -join ' '
    if ($Joined -like 'account show*') { return ('{{"user":{{"name":"tester"}},"tenantId":"{0}"}}' -f $TestSub) }
    if ($Joined -like 'account list*') { return ('[{{"id":"{0}","name":"Placeholder subscription","tenantId":"{0}"}}]' -f $TestSub) }
    if ($Joined -like 'graph*') { Set-Content -Path $env:RDA_TEST_INVENTORY_MARKER -Value 'inventory started'; exit 3 }
    return $null
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $TestSub }; Subscription = [pscustomobject]@{ Id = $TestSub } } }
function global:Set-AzContext { param($Subscription, $Context, $Scope) [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $(if ($Subscription) { $Subscription } else { $TestSub }) } } }
# The up-front role check sees Reader at the subscription, so these runs reach
# the consumption check.
function global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    if ($Path -match '/roleAssignments\?') { return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(@{ properties = @{ roleDefinitionId = "/subscriptions/$TestSub/providers/Microsoft.Authorization/roleDefinitions/reader"; scope = "/subscriptions/$TestSub"; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) } | ConvertTo-Json -Depth 10) } }
    if ($Path -match '/roleDefinitions/') { return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } } | ConvertTo-Json -Depth 10) } }
    if ($Path -match '/providers/Microsoft\.Authorization/permissions\?') { return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(@{ actions = @('*/read'); notActions = @() }) } | ConvertTo-Json -Depth 10) } }
    [pscustomobject]@{ StatusCode = 200; Content = ('{{"data":[{{"subscriptionId":"{0}","ResourceCount":4}}]}}' -f $TestSub) }
}
function global:Get-UsageAggregates
{
    param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken)
    Add-Content -Path $env:RDA_TEST_USAGE_MARKER -Value 'usage queried'
    $Rows = if ($env:RDA_TEST_MODE -eq 'values') { @([pscustomobject]@{ Properties = [pscustomobject]@{ Quantity = 2 } }) } else { @() }
    [pscustomobject]@{ UsageAggregations = $Rows; ContinuationToken = $null }
}
$env:RDA_TEST_MODE = $Mode
$Extra = @{}
if ($SkipConsumption) { $Extra.SkipConsumption = $true }
& (Join-Path $Root 'ResourceInventory.ps1') -SubscriptionID $TestSub -OutputDirectory $Out @Extra
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

        function Invoke-DirectRun
        {
            param([string]$Mode, [switch]$SkipConsumption)
            $Out = Join-Path $TestDrive ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $Out -Force | Out-Null
            $env:RDA_TEST_INVENTORY_MARKER = Join-Path $Out 'inventory.marker'
            $env:RDA_TEST_USAGE_MARKER = Join-Path $Out 'usage.marker'
            $PwshArgs = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Root', $script:RepoRoot, '-Out', $Out, '-Mode', $Mode)
            if ($SkipConsumption) { $PwshArgs += '-SkipConsumption' }
            $Output = & (Join-Path $PSHOME 'pwsh') @PwshArgs 2>&1 | Out-String
            [pscustomobject]@{
                ExitCode          = $LASTEXITCODE
                Output            = $Output
                InventoryReached  = (Test-Path -Path $env:RDA_TEST_INVENTORY_MARKER)
                UsageQueried      = (Test-Path -Path $env:RDA_TEST_USAGE_MARKER)
            }
        }
    }

    AfterAll {
        Remove-Item Env:\RDA_TEST_INVENTORY_MARKER, Env:\RDA_TEST_USAGE_MARKER -ErrorAction SilentlyContinue
    }

    It 'exits 1 before any inventory or collector work when consumption returns no values' {
        $Run = Invoke-DirectRun -Mode 'empty'
        $Run.ExitCode | Should -Be 1
        $Run.UsageQueried | Should -BeTrue
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match 'Placeholder subscription \(12345678-1234-1234-1234-123456789012\): NoRows'
    }

    It 'continues into inventory when consumption returns values' {
        $Run = Invoke-DirectRun -Mode 'values'
        $Run.InventoryReached | Should -BeTrue
        $Run.ExitCode | Should -Be 3
        $Run.Output | Should -Match 'Consumption data confirmed'
    }

    It 'does not check consumption under -SkipConsumption' {
        $Run = Invoke-DirectRun -Mode 'empty' -SkipConsumption
        $Run.UsageQueried | Should -BeFalse
        $Run.InventoryReached | Should -BeTrue
    }
}
