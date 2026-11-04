# App Service plan autoscale lookup tests
# Run with: Invoke-Pester ./Tests/AppServicePlanAutoscale.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The AppServicePlan collector sets AutoscaleEnabled when an enabled autoscale
# setting targets the plan. It finds the targets through a set built once,
# instead of scanning every setting for every plan. That is a speed change
# that must not change what the collector emits. These tests invoke the REAL
# collector with synthetic resource rows and pin AutoscaleEnabled:
#
#   - a plan with an enabled setting is $true, a plan without one is $false,
#     and a disabled setting does not count
#   - two settings for one plan still give one row with $true
#   - a target that differs from the plan id only in letter case matches, as
#     the -eq it replaces did (Azure resource ids are case-insensitive)
#   - a target that -eq treats as equal under invariant culture rules (a soft
#     hyphen) matches too
#   - zero plans emit nothing
#   - targets that are not one string (missing, an array) give the same
#     answer as the -eq check
#   - a plan with no id (null, empty or not a string) is $false, even when a
#     setting has a missing or empty target
#
# No live Azure. All GUIDs are the Azure documentation placeholder, not real
# identifiers.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Compute', 'AppServicePlan.ps1' | Resolve-Path | Select-Object -ExpandProperty Path

    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:DocGuid; Name = 'sub-plan' })
    $script:RgPath = "/subscriptions/$($script:DocGuid)/resourceGroups/rg-plan/providers"

    function Invoke-TestCollector
    {
        param($Resources)
        & $script:Collector -Sub $script:Subs -Resources $Resources -Task 'Processing' -ResourceIdDictionary $null
    }

    function Get-TestPlanId
    {
        param([string]$Name)
        "$($script:RgPath)/Microsoft.Web/serverfarms/$Name"
    }

    function New-TestPlan
    {
        param([string]$Name, $Id = (Get-TestPlanId -Name $Name))
        [pscustomobject]@{
            TYPE           = 'microsoft.web/serverfarms'
            id             = $Id
            NAME           = $Name
            RESOURCEGROUP  = 'rg-plan'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
            SKU            = [pscustomobject]@{ name = 'P1v3'; tier = 'PremiumV3' }
            PROPERTIES     = [pscustomobject]@{
                currentNumberOfWorkers = 1
                computeMode            = 'Dedicated'
                currentWorkerSize      = 'Small'
                isSpot                 = $false
                maximumNumberOfWorkers = 10
                reserved               = 'true'
                kind                   = 'linux'
                numberOfSites          = 2
                zoneRedundant          = $false
            }
        }
    }

    function New-TestAutoscale
    {
        param([string]$Name, $Target, [string]$Enabled = 'true')
        [pscustomobject]@{
            TYPE           = 'microsoft.insights/autoscalesettings'
            id             = "$($script:RgPath)/microsoft.insights/autoscalesettings/$Name"
            NAME           = $Name
            RESOURCEGROUP  = 'rg-plan'
            subscriptionId = $script:DocGuid
            Properties     = [pscustomobject]@{ enabled = $Enabled; targetResourceUri = $Target }
        }
    }

    # The rule the collector must keep: a plan with no id is $false, and any
    # other plan gets the -eq scan over every enabled setting.
    function Get-ExpectedAutoscale
    {
        param($Plan, $Settings)
        if ($Plan.id -isnot [string] -or $Plan.id.Length -eq 0) { return $false }
        $Enabled = $Settings | Where-Object { $_.Properties.enabled -eq 'true' }
        $Hit = ($Enabled | Where-Object { $_.Properties.targetResourceUri -eq $Plan.id })
        -not [string]::IsNullOrEmpty($Hit)
    }
}

Describe 'AppServicePlan AutoscaleEnabled' {
    It 'is $true for a plan with an enabled autoscale setting' {
        $Plan = New-TestPlan -Name 'plan-a'
        $Rows = @(Invoke-TestCollector -Resources @($Plan, (New-TestAutoscale -Name 'as-a' -Target $Plan.id)))
        $Rows.Count | Should -Be 1
        $Rows[0].AutoscaleEnabled | Should -BeOfType [bool]
        $Rows[0].AutoscaleEnabled | Should -BeTrue
    }

    It 'is $false for a plan without an autoscale setting' {
        $Plan = New-TestPlan -Name 'plan-b'
        $Other = New-TestAutoscale -Name 'as-other' -Target (Get-TestPlanId -Name 'plan-other')
        $Rows = @(Invoke-TestCollector -Resources @($Plan, $Other))
        $Rows.Count | Should -Be 1
        $Rows[0].AutoscaleEnabled | Should -BeOfType [bool]
        $Rows[0].AutoscaleEnabled | Should -BeFalse
    }

    It 'is $false when the only setting for the plan is disabled' {
        $Plan = New-TestPlan -Name 'plan-off'
        $Rows = @(Invoke-TestCollector -Resources @($Plan, (New-TestAutoscale -Name 'as-off' -Target $Plan.id -Enabled 'false')))
        $Rows[0].AutoscaleEnabled | Should -BeFalse
    }

    It 'gives one row with $true when two settings target one plan' {
        $Plan = New-TestPlan -Name 'plan-c'
        $Rows = @(Invoke-TestCollector -Resources @($Plan, (New-TestAutoscale -Name 'as-c1' -Target $Plan.id), (New-TestAutoscale -Name 'as-c2' -Target $Plan.id)))
        $Rows.Count | Should -Be 1
        $Rows[0].AutoscaleEnabled | Should -BeTrue
    }

    It 'matches a target that differs from the plan id only in letter case' {
        $Plan = New-TestPlan -Name 'plan-d'
        $Rows = @(Invoke-TestCollector -Resources @($Plan, (New-TestAutoscale -Name 'as-d' -Target $Plan.id.ToUpperInvariant())))
        $Rows[0].AutoscaleEnabled | Should -BeTrue
    }

    It 'matches a target that -eq treats as equal under invariant culture rules' {
        $Plan = New-TestPlan -Name 'plan-e'
        # A soft hyphen is ignored by the -eq comparison, so this target matches.
        $Target = $Plan.id.Replace('plan-e', "plan-$([char]0xAD)e")
        Get-ExpectedAutoscale -Plan $Plan -Settings @((New-TestAutoscale -Name 'as-e' -Target $Target)) | Should -BeTrue
        $Rows = @(Invoke-TestCollector -Resources @($Plan, (New-TestAutoscale -Name 'as-e' -Target $Target)))
        $Rows[0].AutoscaleEnabled | Should -BeTrue
    }

    It 'emits nothing when there are no plans' {
        $Rows = @(Invoke-TestCollector -Resources @((New-TestAutoscale -Name 'as-lonely' -Target (Get-TestPlanId -Name 'gone'))))
        $Rows.Count | Should -Be 0
    }

    It 'keeps each plan in input order with its own value' {
        $PlanA = New-TestPlan -Name 'plan-f1'
        $PlanB = New-TestPlan -Name 'plan-f2'
        $PlanC = New-TestPlan -Name 'plan-f3'
        $Rows = @(Invoke-TestCollector -Resources @($PlanA, $PlanB, $PlanC, (New-TestAutoscale -Name 'as-f2' -Target $PlanB.id)))
        ($Rows | ForEach-Object { $_.Name }) | Should -Be @('plan-f1', 'plan-f2', 'plan-f3')
        ($Rows | ForEach-Object { $_.AutoscaleEnabled }) | Should -Be @($false, $true, $false)
    }

    It 'gives the -eq answer for a setting with no target' {
        $Plan = New-TestPlan -Name 'plan-g'
        $Settings = @((New-TestAutoscale -Name 'as-g' -Target $null))
        $Rows = @(Invoke-TestCollector -Resources (@($Plan) + $Settings))
        $Rows[0].AutoscaleEnabled | Should -Be (Get-ExpectedAutoscale -Plan $Plan -Settings $Settings)
        $Rows[0].AutoscaleEnabled | Should -BeFalse
    }

    It 'gives the -eq answer for a target that is an array holding the plan id' {
        $Plan = New-TestPlan -Name 'plan-h'
        $Settings = @((New-TestAutoscale -Name 'as-h' -Target @($Plan.id.ToUpperInvariant(), 'other')))
        $Rows = @(Invoke-TestCollector -Resources (@($Plan) + $Settings))
        $Rows[0].AutoscaleEnabled | Should -Be (Get-ExpectedAutoscale -Plan $Plan -Settings $Settings)
        $Rows[0].AutoscaleEnabled | Should -BeTrue
    }

    It 'is $false for a plan with no id, even when a setting has no target' {
        $Plan = New-TestPlan -Name 'plan-i' -Id $null
        $Settings = @((New-TestAutoscale -Name 'as-i1' -Target $null), (New-TestAutoscale -Name 'as-i2' -Target ''))
        $Rows = @(Invoke-TestCollector -Resources (@($Plan) + $Settings))
        $Rows[0].AutoscaleEnabled | Should -Be (Get-ExpectedAutoscale -Plan $Plan -Settings $Settings)
        $Rows[0].AutoscaleEnabled | Should -BeOfType [bool]
        $Rows[0].AutoscaleEnabled | Should -BeFalse
    }

    It 'is $false for a plan with an empty id, even when a setting has an empty target' {
        $Plan = New-TestPlan -Name 'plan-i2' -Id ''
        $Settings = @((New-TestAutoscale -Name 'as-i3' -Target ''))
        $Rows = @(Invoke-TestCollector -Resources (@($Plan) + $Settings))
        $Rows[0].AutoscaleEnabled | Should -Be (Get-ExpectedAutoscale -Plan $Plan -Settings $Settings)
        $Rows[0].AutoscaleEnabled | Should -BeFalse
    }

    It 'is $false for a plan whose id is not a string' {
        $Plan = New-TestPlan -Name 'plan-i3' -Id 0
        $Settings = @((New-TestAutoscale -Name 'as-i4' -Target $null), (New-TestAutoscale -Name 'as-i5' -Target '0'))
        $Rows = @(Invoke-TestCollector -Resources (@($Plan) + $Settings))
        $Rows[0].AutoscaleEnabled | Should -Be (Get-ExpectedAutoscale -Plan $Plan -Settings $Settings)
        $Rows[0].AutoscaleEnabled | Should -BeFalse
    }

    It 'is $false for a plan with an empty id and only a missing target' {
        $Plan = New-TestPlan -Name 'plan-j' -Id ''
        $Settings = @((New-TestAutoscale -Name 'as-j' -Target $null))
        $Rows = @(Invoke-TestCollector -Resources (@($Plan) + $Settings))
        $Rows[0].AutoscaleEnabled | Should -Be (Get-ExpectedAutoscale -Plan $Plan -Settings $Settings)
        $Rows[0].AutoscaleEnabled | Should -BeFalse
    }

    It 'matches the -eq scan on a mixed set of plans and settings' {
        $Plans = @(1..30 | ForEach-Object { New-TestPlan -Name "plan-m$_" })
        $Settings = @(
            1..30 | Where-Object { $_ % 3 -eq 0 } | ForEach-Object { New-TestAutoscale -Name "as-m$_" -Target $Plans[$_ - 1].id.ToUpperInvariant() }
            1..30 | Where-Object { $_ % 5 -eq 0 } | ForEach-Object { New-TestAutoscale -Name "as-n$_" -Target $Plans[$_ - 1].id -Enabled 'false' }
            New-TestAutoscale -Name 'as-null' -Target $null
            New-TestAutoscale -Name 'as-arr' -Target @($Plans[0].id, $Plans[1].id)
        )
        $Rows = @(Invoke-TestCollector -Resources ($Plans + $Settings))
        $Rows.Count | Should -Be 30
        for ($i = 0; $i -lt 30; $i++)
        {
            $Rows[$i].AutoscaleEnabled | Should -Be (Get-ExpectedAutoscale -Plan $Plans[$i] -Settings $Settings) -Because $Plans[$i].NAME
        }
    }
}
