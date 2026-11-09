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
#     hyphen) matches too; skipped on a host that compares strings ordinally
#     (.NET invariant globalization mode), where -eq does not ignore it
#   - zero plans emit nothing
#   - targets that are not one string (missing, an array, a number) and a
#     plan id that is an array give the same answer as the -eq check
#   - a resource that is not an autoscale setting does not count
#   - a plan with no id (null, empty or not a string) is $false, even when a
#     setting has a missing or empty target
#
# The Subscription column is found with a lookup by subscription id instead of
# a scan per plan. Those tests pin the -eq answer: letter case is ignored, a
# missing id gives nothing, two subscriptions with one id give both names, and
# a subscription id that is not a string keeps the scan.
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
        param($Resources, $Subs = $script:Subs)
        & $script:Collector -Sub $Subs -Resources $Resources -Task 'Processing' -ResourceIdDictionary $null
    }

    # The rule the subscription lookup must keep: the -eq scan over every subscription.
    function Get-ExpectedSubscription
    {
        param($Plan, $Subs)
        ($Subs | Where-Object { $_.id -eq $Plan.subscriptionId }).Name
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
        $Enabled = $Settings | Where-Object { $_.TYPE -eq 'microsoft.insights/autoscalesettings' -and $_.Properties.enabled -eq 'true' }
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
        # In .NET invariant globalization mode the invariant culture compares
        # ordinally, so -eq does not ignore the soft hyphen there.
        if ([cultureinfo]::InvariantCulture.CompareInfo.Compare("a$([char]0xAD)b", 'ab', [System.Globalization.CompareOptions]::IgnoreCase) -ne 0)
        {
            Set-ItResult -Skipped -Because 'this host compares strings ordinally (invariant globalization mode), so -eq does not ignore a soft hyphen'
            return
        }
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

    It 'gives the -eq answer for a target that is a number' {
        $Plan = New-TestPlan -Name 'plan-k'
        $Other = New-TestPlan -Name 'plan-k2' -Id '42'
        $Settings = @((New-TestAutoscale -Name 'as-k' -Target 42))
        $Rows = @(Invoke-TestCollector -Resources (@($Plan, $Other) + $Settings))
        $Rows[0].AutoscaleEnabled | Should -Be (Get-ExpectedAutoscale -Plan $Plan -Settings $Settings)
        $Rows[0].AutoscaleEnabled | Should -BeFalse
        # -eq converts the plan id '42' to the number, so the number target matches it.
        $Rows[1].AutoscaleEnabled | Should -Be (Get-ExpectedAutoscale -Plan $Other -Settings $Settings)
        $Rows[1].AutoscaleEnabled | Should -BeTrue
    }

    It 'gives the oracle answer for a plan whose id is an array' {
        $Id = Get-TestPlanId -Name 'plan-l'
        $Plan = New-TestPlan -Name 'plan-l' -Id @($Id, 'other')
        $Settings = @((New-TestAutoscale -Name 'as-l1' -Target $Id), (New-TestAutoscale -Name 'as-l2' -Target $null))
        $Rows = @(Invoke-TestCollector -Resources (@($Plan) + $Settings))
        $Rows.Count | Should -Be 1
        $Rows[0].AutoscaleEnabled | Should -Be (Get-ExpectedAutoscale -Plan $Plan -Settings $Settings)
        $Rows[0].AutoscaleEnabled | Should -BeFalse
    }

    It 'does not count a resource that is not an autoscale setting' {
        $Plan = New-TestPlan -Name 'plan-t'
        $NotAutoscale = New-TestAutoscale -Name 'not-as' -Target $Plan.id
        $NotAutoscale.TYPE = 'microsoft.web/sites'
        $Settings = @($NotAutoscale)
        $Rows = @(Invoke-TestCollector -Resources (@($Plan) + $Settings))
        $Rows[0].AutoscaleEnabled | Should -Be (Get-ExpectedAutoscale -Plan $Plan -Settings $Settings)
        $Rows[0].AutoscaleEnabled | Should -BeFalse
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

Describe 'AppServicePlan Subscription' {
    BeforeAll {
        $script:GuidB = 'fedcba98-7654-3210-fedc-ba9876543210'
        $script:GuidC = 'abcdefab-cdef-abcd-efab-cdefabcdefab'
    }

    It 'gives the -eq answer for each plan' {
        $Subs = @(
            [pscustomobject]@{ id = $script:DocGuid; Name = 'sub-a' }
            [pscustomobject]@{ id = $script:GuidB.ToUpperInvariant(); Name = 'sub-b' }
            [pscustomobject]@{ id = $script:GuidC; Name = 'sub-c1' }
            [pscustomobject]@{ id = $script:GuidC; Name = 'sub-c2' }
        )
        $Plans = @(
            New-TestPlan -Name 'plan-s1'
            New-TestPlan -Name 'plan-s2'
            New-TestPlan -Name 'plan-s3'
            New-TestPlan -Name 'plan-s4'
            New-TestPlan -Name 'plan-s5'
        )
        $Plans[1].subscriptionId = $script:GuidB
        $Plans[2].subscriptionId = $script:GuidC
        $Plans[3].subscriptionId = '00000000-0000-0000-0000-000000000000'
        $Plans[4].subscriptionId = $null
        $Rows = @(Invoke-TestCollector -Resources $Plans -Subs $Subs)
        $Rows.Count | Should -Be 5
        for ($i = 0; $i -lt 5; $i++)
        {
            $Rows[$i].Subscription | Should -Be (Get-ExpectedSubscription -Plan $Plans[$i] -Subs $Subs) -Because $Plans[$i].NAME
        }
        $Rows[0].Subscription | Should -Be 'sub-a'
        $Rows[0].Subscription | Should -BeOfType [string]
        $Rows[1].Subscription | Should -Be 'sub-b'
        $Rows[3].Subscription | Should -BeNullOrEmpty
        $Rows[4].Subscription | Should -BeNullOrEmpty
    }

    It 'gives the -eq answer when a subscription id is not a string' {
        $Subs = @(
            [pscustomobject]@{ id = 42; Name = 'sub-num' }
            [pscustomobject]@{ id = $script:DocGuid; Name = 'sub-a' }
        )
        $PlanA = New-TestPlan -Name 'plan-s6'
        $PlanB = New-TestPlan -Name 'plan-s7'
        $PlanB.subscriptionId = '42'
        $Rows = @(Invoke-TestCollector -Resources @($PlanA, $PlanB) -Subs $Subs)
        $Rows[0].Subscription | Should -Be (Get-ExpectedSubscription -Plan $PlanA -Subs $Subs)
        $Rows[0].Subscription | Should -Be 'sub-a'
        $Rows[1].Subscription | Should -Be (Get-ExpectedSubscription -Plan $PlanB -Subs $Subs)
        $Rows[1].Subscription | Should -Be 'sub-num'
    }

    It 'gives the -eq answer when there are no subscriptions' {
        $Plan = New-TestPlan -Name 'plan-s8'
        $Rows = @(Invoke-TestCollector -Resources @($Plan) -Subs $null)
        $Rows.Count | Should -Be 1
        $Rows[0].Subscription | Should -BeNullOrEmpty
    }
}

# The speed change itself: each autoscale target and each subscription id is
# read a fixed number of times, not once per plan. A counting property stands
# in for the field, so a scan per plan shows up as plans x rows reads.
Describe 'AppServicePlan lookups read each row once' {
    BeforeAll {
        function New-CountedValue
        {
            param($Target, [string]$Name, $Value, [hashtable]$Count)
            $Target | Add-Member -MemberType ScriptProperty -Name $Name -Value { $Count.Reads++; $Value }.GetNewClosure() -Force
            $Target
        }
    }

    It 'reads each autoscale target a fixed number of times, not once per plan' {
        $Count = @{ Reads = 0 }
        $Plans = @(1..20 | ForEach-Object { New-TestPlan -Name "plan-r$_" })
        $Settings = @(1..20 | ForEach-Object {
                $S = New-TestAutoscale -Name "as-r$_" -Target $null
                $Target = $Plans[$_ - 1].id
                [void](New-CountedValue -Target $S.Properties -Name 'targetResourceUri' -Value $Target -Count $Count)
                $S
            })
        $Rows = @(Invoke-TestCollector -Resources ($Plans + $Settings))
        $Rows.Count | Should -Be 20
        @($Rows | Where-Object { $_.AutoscaleEnabled -eq $true }).Count | Should -Be 20
        $Count.Reads | Should -BeLessOrEqual 40 -Because 'a scan per plan reads 20 x 20 = 400 targets'
    }

    It 'reads each subscription id a fixed number of times, not once per plan' {
        $Count = @{ Reads = 0 }
        $Subs = @(1..20 | ForEach-Object {
                $S = [pscustomobject]@{ Name = "sub-r$_" }
                New-CountedValue -Target $S -Name 'id' -Value ('{0:d8}-1234-1234-1234-123456789012' -f $_) -Count $Count
            })
        $Plans = @(1..20 | ForEach-Object {
                $P = New-TestPlan -Name "plan-q$_"
                $P.subscriptionId = '{0:d8}-1234-1234-1234-123456789012' -f $_
                $P
            })
        $Rows = @(Invoke-TestCollector -Resources $Plans -Subs $Subs)
        for ($i = 0; $i -lt 20; $i++) { $Rows[$i].Subscription | Should -Be "sub-r$($i + 1)" }
        $Count.Reads | Should -BeLessOrEqual 100 -Because 'a scan per plan reads 20 x 20 = 400 ids'
    }
}
