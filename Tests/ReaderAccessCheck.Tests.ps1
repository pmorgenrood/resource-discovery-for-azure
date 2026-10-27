# =============================================================================
# ReaderAccessCheck.Tests.ps1
#
# The up-front role check (Functions/Common.Functions.ps1). Resource Graph
# returns 0 rows rather than an error for a subscription the identity cannot
# read, so Run-AllSubscriptions.ps1 and direct runs of ResourceInventory.ps1
# decide read access per subscription from two answers - the identity's own
# role assignments (with their role definitions) and Azure's caller-permissions
# answer - and skip every subscription the combination does not show as
# readable, stopping with exit code 1 only when none is readable.
#
# The Az cmdlets are replaced by local stub functions and Pester mocks, so the
# tests run offline and without the Az modules installed.
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    # These tests replace Azure with Pester mocks, which exist only in this
    # runspace, so the up-front checks run one subscription at a time here.
    # UpFrontChecksParallel.Tests.ps1 covers the parallel path.
    $script:PSDefaultParameterValues = @{
        'Test-SubscriptionRoleAccessAll:ThrottleLimit' = 1
        'Invoke-ConsumptionDataCheck:ThrottleLimit'    = 1
    }

    # Stubs so the mocks below have a command to replace when Az is absent.
    function Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) }
    function Get-AzAccessToken { param($ResourceUrl) }
    function Get-AzContext { param() }
    function Exit-Wrapper { param([int]$Code = 0) }

    $script:BuiltIn = @{
        'Owner'          = @{ Actions = @('*'); NotActions = @() }
        'Contributor'    = @{ Actions = @('*'); NotActions = @('Microsoft.Authorization/*/Delete', 'Microsoft.Authorization/*/Write', 'Microsoft.Authorization/elevateAccess/Action', 'Microsoft.Blueprint/blueprintAssignments/write', 'Microsoft.Blueprint/blueprintAssignments/delete', 'Microsoft.Compute/galleries/share/action', 'Microsoft.Purview/consents/write', 'Microsoft.Purview/consents/delete', 'Microsoft.Resources/deploymentStacks/manageDenySetting/action', 'Microsoft.Subscription/cancel/action', 'Microsoft.Subscription/enable/action') }
        'Reader'         = @{ Actions = @('*/read'); NotActions = @() }
        'Billing Reader' = @{ Actions = @('Microsoft.Authorization/*/read', 'Microsoft.Billing/*/read', 'Microsoft.Commerce/*/read', 'Microsoft.Consumption/*/read', 'Microsoft.Management/managementGroups/read', 'Microsoft.CostManagement/*/read', 'Microsoft.Support/*'); NotActions = @() }
        'SubRead'        = @{ Actions = @('Microsoft.Resources/subscriptions/read'); NotActions = @() }
        'NoCommerce'     = @{ Actions = @('*/read'); NotActions = @('Microsoft.Commerce/*') }
        'NoAuthorization' = @{ Actions = @('*/read'); NotActions = @('Microsoft.Authorization/*') }
        'NoComputeRead'   = @{ Actions = @('*/read'); NotActions = @('Microsoft.Compute/*/read') }
    }
    $script:RoleNames = @{ 'SubRead' = 'Subscription read only'; 'NoCommerce' = 'Reader without Commerce'; 'NoAuthorization' = 'Reader without Authorization'; 'NoComputeRead' = 'Reader without Compute' }

    function New-Grant
    {
        param([string]$Role, [string]$Label = $Role)
        [pscustomobject]@{ Label = $Label; Actions = $script:BuiltIn[$Role].Actions; NotActions = $script:BuiltIn[$Role].NotActions }
    }

    function Test-Allows
    {
        param([object[]]$Grants, [ValidateSet('Resources', 'Usage')][string]$Kind)
        @(Get-RoleGrantsAllowing -Grants $Grants -Action (Get-RoleCheckAction -Kind $Kind)).Count -gt 0
    }

    function New-Response
    {
        param([int]$Status, $Body = @{})
        [pscustomobject]@{ StatusCode = $Status; Content = ($Body | ConvertTo-Json -Depth 10) }
    }

    # Azure, as the tests see it. Assignments: list of @{ Role; Scope; Group }.
    # Permissions: scope path (lower case) -> @{ Status; Roles } or a list of
    # statuses to return in turn. Unlisted scopes answer 200 with no entries.
    function Set-RoleScenario
    {
        param(
            [object[]]$Assignments = @(),
            $ListStatus = 200,
            [hashtable]$Permissions = @{},
            $DefinitionStatus = 200
        )
        $script:Scenario = @{ Assignments = $Assignments; ListStatus = @($ListStatus); Permissions = $Permissions; DefinitionStatus = @($DefinitionStatus); DefinitionCalls = 0; ListCalls = 0; PermCalls = @{} }
        $script:Calls = [System.Collections.Generic.List[string]]::new()
    }

    function Get-ScenarioResponse
    {
        param([string]$Target)
        $S = $script:Scenario
        if ($Target -match '^/subscriptions/([^/]+)/providers/Microsoft\.Authorization/roleAssignments\?')
        {
            $Sub = $Matches[1]
            $script:Calls.Add('roles ' + $Sub)
            $Status = $S.ListStatus[[math]::Min($S.ListCalls, $S.ListStatus.Count - 1)]
            $S.ListCalls++
            if ($Status -ne 200) { return (New-Response -Status $Status -Body @{ error = @{ code = 'x' } }) }
            $Items = @($S.Assignments | Where-Object { $_.Scope -eq '/' -or $_.Scope -like '/providers/*' -or $_.Scope -like "/subscriptions/$Sub*" } | ForEach-Object {
                    @{ properties = @{
                            roleDefinitionId = "/subscriptions/$Sub/providers/Microsoft.Authorization/roleDefinitions/$($_.Role)"
                            scope            = $_.Scope
                            principalId      = $(if ($_.Group) { 'group-1' } else { 'caller-oid' })
                            principalType    = $(if ($_.Group) { 'Group' } else { 'ServicePrincipal' })
                        }
                    }
                })
            return (New-Response -Status 200 -Body @{ value = $Items })
        }
        if ($Target -match '/roleDefinitions/([^?]+)\?')
        {
            $Role = $Matches[1]
            $script:Calls.Add('definition ' + $Role)
            $Status = $S.DefinitionStatus[[math]::Min($S.DefinitionCalls, $S.DefinitionStatus.Count - 1)]
            $S.DefinitionCalls++
            if ($Status -ne 200) { return (New-Response -Status $Status) }
            $Name = if ($script:RoleNames.ContainsKey($Role)) { $script:RoleNames[$Role] } else { $Role }
            $Type = if ($script:RoleNames.ContainsKey($Role)) { 'CustomRole' } else { 'BuiltInRole' }
            return (New-Response -Status 200 -Body @{ properties = @{ roleName = $Name; type = $Type; permissions = @(@{ actions = $script:BuiltIn[$Role].Actions; notActions = $script:BuiltIn[$Role].NotActions }) } })
        }
        if ($Target -match '^(.*)/providers/Microsoft\.Authorization/permissions\?')
        {
            $Scope = $Matches[1].ToLowerInvariant()
            $script:Calls.Add('permissions ' + $Scope)
            $Entry = $S.Permissions[$Scope]
            if ($null -eq $Entry) { return (New-Response -Status 200 -Body @{ value = @() }) }
            $N = if ($S.PermCalls.ContainsKey($Scope)) { $S.PermCalls[$Scope] } else { 0 }
            $S.PermCalls[$Scope] = $N + 1
            $Status = @($Entry.Status)[[math]::Min($N, @($Entry.Status).Count - 1)]
            if ($Status -ne 200) { return (New-Response -Status $Status -Body @{ error = @{ code = 'x' } }) }
            return (New-Response -Status 200 -Body @{ value = @(@($Entry.Roles) | ForEach-Object { @{ actions = $script:BuiltIn[$_].Actions; notActions = $script:BuiltIn[$_].NotActions } }) })
        }
        throw "unexpected request $Target"
    }

    $script:SubA = [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }
}

Describe 'Role action evaluation' {
    It '<Role>: resources <Res>, usage <Use>' -TestCases @(
        @{ Role = 'Owner'; Res = $true; Use = $true }
        @{ Role = 'Contributor'; Res = $true; Use = $true }
        @{ Role = 'Reader'; Res = $true; Use = $true }
        @{ Role = 'Billing Reader'; Res = $false; Use = $true }
        @{ Role = 'SubRead'; Res = $false; Use = $false }
        @{ Role = 'NoCommerce'; Res = $true; Use = $false }
        @{ Role = 'NoAuthorization'; Res = $true; Use = $true }
        @{ Role = 'NoComputeRead'; Res = $false; Use = $true }
    ) {
        param($Role, $Res, $Use)
        Test-Allows -Grants @(New-Grant $Role) -Kind Resources | Should -Be $Res
        Test-Allows -Grants @(New-Grant $Role) -Kind Usage | Should -Be $Use
    }

    It 'notActions only subtract from their own role' {
        $Grants = @((New-Grant 'NoCommerce'), (New-Grant 'Billing Reader'))
        Get-RoleGrantsAllowing -Grants $Grants -Action (Get-RoleCheckAction -Kind Usage) | Should -Be @('Billing Reader')
    }

    It 'matches case-insensitively in actions and notActions' {
        Test-RoleActionAllowed -Actions @('MICROSOFT.COMMERCE/*/READ') -NotActions @() -Action 'Microsoft.Commerce/UsageAggregates/read' | Should -BeTrue
        Test-RoleActionAllowed -Actions @('*') -NotActions @('microsoft.commerce/*') -Action 'Microsoft.Commerce/UsageAggregates/read' | Should -BeFalse
    }

    It 'a wildcard matches any characters; a literal matches only itself' {
        Test-RoleActionPatternMatch -Pattern 'Microsoft.Commerce/*/read' -Action 'Microsoft.Commerce/UsageAggregates/read' | Should -BeTrue
        Test-RoleActionPatternMatch -Pattern 'Microsoft.Commerce/*/read' -Action 'Microsoft.Compute/virtualMachines/read' | Should -BeFalse
        Test-RoleActionPatternMatch -Pattern 'Microsoft.Resources/subscriptions/read' -Action 'Microsoft.Resources/subscriptions/resourceGroups/read' | Should -BeFalse
        Test-RoleActionPatternMatch -Pattern 'Microsoft.Resources/subscriptions.read' -Action 'Microsoft.Resources/subscriptionsXread' | Should -BeFalse
    }
}

Describe 'Read access that leaves out some resource types' {
    It 'a notAction <Pattern> next to <Actions> removes read access' -TestCases @(
        @{ Actions = '*/read'; Pattern = 'Microsoft.Compute/*' }
        @{ Actions = '*/read'; Pattern = 'Microsoft.Compute/*/read' }
        @{ Actions = '*/read'; Pattern = 'Microsoft.Compute/virtualMachines/read' }
        @{ Actions = '*/read'; Pattern = 'MICROSOFT.COMPUTE/VIRTUALMACHINES/READ' }
        @{ Actions = '*'; Pattern = 'Microsoft.Storage/storageAccounts/*' }
        @{ Actions = '*'; Pattern = 'Microsoft.Network/*/Read' }
    ) {
        param($Actions, $Pattern)
        Test-Allows -Grants @([pscustomobject]@{ Label = 'custom'; Actions = @($Actions); NotActions = @($Pattern) }) -Kind Resources | Should -BeFalse
        Get-RoleReadExclusion -NotActions @('Microsoft.Compute/virtualMachines/write', $Pattern) | Should -Be $Pattern
    }

    It 'a wildcard notAction <Pattern> that can match a read action (such as <Example>) removes read access' -TestCases @(
        @{ Pattern = 'Microsoft.Comp*'; Example = 'Microsoft.Compute/virtualMachines/read' }
        @{ Pattern = 'Microsoft.Compute/*/r*'; Example = 'Microsoft.Compute/disks/read' }
        @{ Pattern = 'Microsoft.Compute/virtualMachines/re*d'; Example = 'Microsoft.Compute/virtualMachines/read' }
        @{ Pattern = 'Microsoft.Compute*read'; Example = 'Microsoft.Compute/virtualMachines/read' }
        @{ Pattern = '*ad'; Example = 'Microsoft.Storage/storageAccounts/read' }
        @{ Pattern = 'Microsoft.Auth*'; Example = 'Microsoft.AuthExample/items/read' }
    ) {
        param($Pattern, $Example)
        Test-RoleActionPatternMatch -Pattern $Pattern -Action $Example | Should -BeTrue
        Get-RoleReadExclusion -NotActions @('Microsoft.Compute/virtualMachines/write', $Pattern) | Should -Be $Pattern
        Test-Allows -Grants @([pscustomobject]@{ Label = 'custom'; Actions = @('*/read'); NotActions = @($Pattern) }) -Kind Resources | Should -BeFalse
    }

    It 'a notAction confined to <Pattern> keeps read access' -TestCases @(
        @{ Pattern = 'Microsoft.Authorization/*' }
        @{ Pattern = 'microsoft.authorization/roleAssignments/read' }
        @{ Pattern = 'Microsoft.Commerce/*' }
        @{ Pattern = 'Microsoft.Consumption/*/read' }
        @{ Pattern = 'Microsoft.Billing/*' }
    ) {
        param($Pattern)
        Get-RoleReadExclusion -NotActions @($Pattern) | Should -BeNullOrEmpty
        Test-Allows -Grants @([pscustomobject]@{ Label = 'custom'; Actions = @('*/read'); NotActions = @($Pattern) }) -Kind Resources | Should -BeTrue
    }

    It 'a notAction that is not a read (<Pattern>) keeps read access' -TestCases @(
        @{ Pattern = 'Microsoft.Compute/virtualMachines/write' }
        @{ Pattern = 'Microsoft.Compute/*/delete' }
        @{ Pattern = '*/action' }
        @{ Pattern = '*/write' }
        @{ Pattern = 'Microsoft.Compute/*rea' }
        @{ Pattern = 'Microsoft.Authorization/*/Delete' }
        @{ Pattern = 'Microsoft.Authorization/*/Write' }
        @{ Pattern = 'Microsoft.Authorization/elevateAccess/Action' }
    ) {
        param($Pattern)
        Get-RoleReadExclusion -NotActions @($Pattern) | Should -BeNullOrEmpty
        Test-Allows -Grants @([pscustomobject]@{ Label = 'custom'; Actions = @('*'); NotActions = @($Pattern) }) -Kind Resources | Should -BeTrue
    }

    It 'Contributor''s notActions keep read access' {
        Get-RoleReadExclusion -NotActions $script:BuiltIn['Contributor'].NotActions | Should -BeNullOrEmpty
    }

    It 'Reader beside a role that leaves out some types still reads everything (each role counts on its own)' {
        Test-Allows -Grants @((New-Grant 'NoComputeRead'), (New-Grant 'Reader')) -Kind Resources | Should -BeTrue
        Test-Allows -Grants @(New-Grant 'NoComputeRead') -Kind Usage | Should -BeTrue
    }

    It 'lists the excluding pattern per role that would otherwise read everything' {
        $Found = @(Get-RoleReadExclusions -Grants @((New-Grant 'NoComputeRead' -Label 'one'), (New-Grant 'Billing Reader' -Label 'two'), (New-Grant 'Reader' -Label 'three')))
        $Found.Count | Should -Be 1
        $Found[0].Grant.Label | Should -Be 'one'
        $Found[0].Pattern | Should -Be 'Microsoft.Compute/*/read'
    }
}

Describe 'Get-RoleAssignmentScopeKind' {
    It '<Scope> with resource group "<Rg>" is <Kind>' -TestCases @(
        @{ Scope = '/'; Rg = ''; Kind = 'tenant root' }
        @{ Scope = '/providers/Microsoft.Management/managementGroups/mg-1'; Rg = ''; Kind = 'management group' }
        @{ Scope = '/subscriptions/SUB-A'; Rg = ''; Kind = 'subscription' }
        @{ Scope = '/subscriptions/sub-a/resourceGroups/RG-One'; Rg = 'rg-one'; Kind = 'target resource group' }
        @{ Scope = '/subscriptions/sub-a/resourceGroups/rg-one'; Rg = ''; Kind = 'resource group' }
        @{ Scope = '/subscriptions/sub-a/resourceGroups/rg-two'; Rg = 'rg-one'; Kind = 'resource group' }
        @{ Scope = '/subscriptions/sub-a/resourceGroups/rg-one/providers/Microsoft.Storage/storageAccounts/sa'; Rg = 'rg-one'; Kind = 'resource' }
        @{ Scope = '/subscriptions/sub-b'; Rg = ''; Kind = 'other' }
    ) {
        param($Scope, $Rg, $Kind)
        Get-RoleAssignmentScopeKind -Scope $Scope -SubscriptionId 'sub-a' -ResourceGroup $Rg | Should -Be $Kind
    }
}

Describe 'Get-RoleAssignmentAccess (role assignments)' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Invoke-AzRestMethod { Get-ScenarioResponse -Target $(if ($Path) { $Path } else { $Uri }) }
    }

    It 'Reader at <Scope> gives resources and usage' -TestCases @(
        @{ Scope = '/' }
        @{ Scope = '/providers/Microsoft.Management/managementGroups/mg-1' }
        @{ Scope = '/subscriptions/sub-a' }
    ) {
        param($Scope)
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = $Scope })
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $A.Resources | Should -Be 'Yes'
        $A.Usage | Should -Be 'Yes'
    }

    It 'lists assignedTo for the caller, which includes group grants' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a'; Group = $true })
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $A.Resources | Should -Be 'Yes'
        $A.ResourcesGrantedBy | Should -Be @('Reader at subscription through a group')
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Path -eq "/subscriptions/sub-a/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('caller-oid')" }
    }

    It 'a resource group grant gives resources only to a -ResourceGroup run on that resource group, and never usage' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a/resourceGroups/rg-one' })
        $OnRg = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -ResourceGroup 'rg-one' -CallerObjectId 'caller-oid'
        $OnRg.Resources | Should -Be 'Yes'
        $OnRg.Usage | Should -Be 'No'
        $OnRg.ResourcesGrantedBy | Should -Be @("Reader at resource group 'rg-one'")

        $WholeSub = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $WholeSub.Resources | Should -Be 'No'
        $WholeSub.Usage | Should -Be 'No'
        $WholeSub.VisibleRoles | Should -Be @('Reader at a resource group')

        $OtherRg = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -ResourceGroup 'rg-two' -CallerObjectId 'caller-oid'
        $OtherRg.Resources | Should -Be 'No'
    }

    It 'labels custom roles' {
        Set-RoleScenario -Assignments @(@{ Role = 'NoCommerce'; Scope = '/subscriptions/sub-a' })
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $A.Resources | Should -Be 'Yes'
        $A.Usage | Should -Be 'No'
        $A.ResourcesGrantedBy | Should -Be @('Reader without Commerce (custom role) at subscription')
    }

    It 'is NotVisible when the list comes back empty or refused (HTTP <Status>)' -TestCases @(@{ Status = 200 }, @{ Status = 403 }, @{ Status = 401 }) {
        param($Status)
        Set-RoleScenario -Assignments @() -ListStatus $Status
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $A.Resources | Should -Be 'NotVisible'
        $A.Usage | Should -Be 'NotVisible'
    }

    It 'is Unknown when the caller object id is missing, without calling Azure' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' })
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId ''
        $A.Resources | Should -Be 'Unknown'
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
    }

    It 'is Unknown when a counted role definition cannot be read' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }) -DefinitionStatus 403
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid').Resources | Should -Be 'Unknown'
    }

    It 'retries a throttled list, then uses the answer' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }) -ListStatus @(429, 200)
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid').Resources | Should -Be 'Yes'
        $script:Scenario.ListCalls | Should -Be 2
    }

    It 'is Unknown when throttling persists after the retries, and does not retry a 400' {
        Set-RoleScenario -Assignments @() -ListStatus 503
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid' -MaxRetries 3).Resources | Should -Be 'Unknown'
        $script:Scenario.ListCalls | Should -Be 4
        Set-RoleScenario -Assignments @() -ListStatus 400
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid').Resources | Should -Be 'Unknown'
        $script:Scenario.ListCalls | Should -Be 1
    }

    It 'reads each role definition once across subscriptions' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }, @{ Role = 'Reader'; Scope = '/subscriptions/sub-b' })
        $Cache = @{}
        $null = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid' -DefinitionCache $Cache
        $null = Get-RoleAssignmentAccess -SubscriptionId 'sub-b' -CallerObjectId 'caller-oid' -DefinitionCache $Cache
        @($script:Calls | Where-Object { $_ -like 'definition *' }).Count | Should -Be 1
    }

    It 'does not read a refused role definition again (HTTP <Status>), and the verdict stays Unknown' -TestCases @(@{ Status = 401 }, @{ Status = 403 }, @{ Status = 404 }) {
        param($Status)
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }, @{ Role = 'Reader'; Scope = '/subscriptions/sub-b' }, @{ Role = 'Reader'; Scope = '/subscriptions/sub-c' }) -DefinitionStatus $Status
        $Cache = @{}
        $Verdicts = foreach ($Sub in @('sub-a', 'sub-b', 'sub-c')) { (Get-RoleAssignmentAccess -SubscriptionId $Sub -CallerObjectId 'caller-oid' -DefinitionCache $Cache).Resources }
        @($Verdicts) | Should -Be @('Unknown', 'Unknown', 'Unknown')
        @($script:Calls | Where-Object { $_ -like 'definition *' }).Count | Should -Be 1
    }

    It 'reads a role definition again after a server error, so a later subscription can pass' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }, @{ Role = 'Reader'; Scope = '/subscriptions/sub-b' }) -DefinitionStatus @(503, 503, 503, 503, 200)
        $Cache = @{}
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid' -DefinitionCache $Cache -MaxRetries 3).Resources | Should -Be 'Unknown'
        (Get-RoleAssignmentAccess -SubscriptionId 'sub-b' -CallerObjectId 'caller-oid' -DefinitionCache $Cache -MaxRetries 3).Resources | Should -Be 'Yes'
        @($script:Calls | Where-Object { $_ -like 'definition *' }).Count | Should -Be 5
    }

    It 'names the role and the excluded pattern when a role reads all but some resource types' {
        Set-RoleScenario -Assignments @(@{ Role = 'NoComputeRead'; Scope = '/subscriptions/sub-a'; Group = $true })
        $A = Get-RoleAssignmentAccess -SubscriptionId 'sub-a' -CallerObjectId 'caller-oid'
        $A.Resources | Should -Be 'No'
        $A.Usage | Should -Be 'Yes'
        $A.ResourcesExcluded | Should -Be @("role 'Reader without Compute' at subscription through a group excludes 'Microsoft.Compute/*/read'")
    }
}

Describe 'Get-CallerPermissionsAccess (Azure''s answer)' {
    BeforeEach {
        Mock Start-Sleep { }
        Mock Invoke-AzRestMethod { Get-ScenarioResponse -Target $(if ($Path) { $Path } else { $Uri }) }
    }

    It '<Role> gives resources <Res> and usage <Use>' -TestCases @(
        @{ Role = 'Reader'; Res = 'Yes'; Use = 'Yes' }
        @{ Role = 'Billing Reader'; Res = 'No'; Use = 'Yes' }
        @{ Role = 'SubRead'; Res = 'No'; Use = 'No' }
        @{ Role = 'NoCommerce'; Res = 'Yes'; Use = 'No' }
    ) {
        param($Role, $Res, $Use)
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = 200; Roles = @($Role) } }
        $B = Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a'
        $B.Resources | Should -Be $Res
        $B.Usage | Should -Be $Use
    }

    It 'maps 403 to No, 404 to No for a subscription and NotFound for a resource group, and 400 to Unknown without retrying' {
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = 403 } }
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a').Resources | Should -Be 'No'
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = 404 }; '/subscriptions/sub-a/resourcegroups/rg-one' = @{ Status = 404 } }
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a').Resources | Should -Be 'No'
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a/resourceGroups/rg-one' -ResourceGroupTarget).Resources | Should -Be 'NotFound'
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = 400 } }
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a').Resources | Should -Be 'Unknown'
        $script:Scenario.PermCalls['/subscriptions/sub-a'] | Should -Be 1
    }

    It 'retries 429 and accepts the 200 that follows; stays Unknown after four 429s' {
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = @(429, 200); Roles = @('Reader') } }
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a').Resources | Should -Be 'Yes'
        $script:Scenario.PermCalls['/subscriptions/sub-a'] | Should -Be 2
        Set-RoleScenario -Permissions @{ '/subscriptions/sub-a' = @{ Status = 429 } }
        (Get-CallerPermissionsAccess -ScopePath '/subscriptions/sub-a' -MaxRetries 3).Resources | Should -Be 'Unknown'
        $script:Scenario.PermCalls['/subscriptions/sub-a'] | Should -Be 4
    }
}

Describe 'Resolve-RoleCheckVerdict (every combination)' {
    It 'role assignments <A> + caller permissions <B> -> <Expected>' -TestCases @(
        @{ A = 'Yes'; B = 'Yes'; Expected = 'Yes' }
        @{ A = 'No'; B = 'No'; Expected = 'No' }
        @{ A = 'NotVisible'; B = 'Yes'; Expected = 'YesPermissionsOnly' }
        @{ A = 'NotVisible'; B = 'No'; Expected = 'NoNotVisible' }
        @{ A = 'Yes'; B = 'No'; Expected = 'Disagree' }
        @{ A = 'No'; B = 'Yes'; Expected = 'Disagree' }
        @{ A = 'Unknown'; B = 'Yes'; Expected = 'Unknown' }
        @{ A = 'Yes'; B = 'Unknown'; Expected = 'Unknown' }
        @{ A = 'NotVisible'; B = 'Unknown'; Expected = 'Unknown' }
        @{ A = 'Yes'; B = 'NotFound'; Expected = 'NotFound' }
        @{ A = 'No'; B = 'NotFound'; Expected = 'NotFound' }
        @{ A = ''; B = 'Yes'; Expected = 'Disagree' }
    ) {
        param($A, $B, $Expected)
        Resolve-RoleCheckVerdict -Assignments $A -Permissions $B | Should -Be $Expected
    }
}

Describe 'Test-SubscriptionRoleAccessAll' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        Mock Start-Sleep { }
        Mock Get-RoleCheckCallerObjectId { 'caller-oid' }
        Mock Invoke-AzRestMethod { Get-ScenarioResponse -Target $(if ($Path) { $Path } else { $Uri }) }
    }

    It '<Case>: state <State>' -TestCases @(
        @{ Case = 'Reader at the subscription'; Assign = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }); Perm = 'Reader'; State = 'Readable'; Reason = 'Read access: Reader at subscription' }
        @{ Case = 'Reader through a group'; Assign = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a'; Group = $true }); Perm = 'Reader'; State = 'Readable'; Reason = 'Read access: Reader at subscription through a group' }
        @{ Case = 'roles not visible, Azure reports read'; Assign = @(); Perm = 'NoAuthorization'; State = 'Readable'; Reason = 'role assignments are not visible to this identity; Azure reports read access' }
        @{ Case = 'roles not visible, no read'; Assign = @(); Perm = 'SubRead'; State = 'NoAccess'; Reason = 'no read access (role assignments not visible to this identity)' }
        @{ Case = 'Reader on a resource group only'; Assign = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a/resourceGroups/rg-one' }); Perm = $null; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: Reader at a resource group)' }
        @{ Case = 'Billing Reader only'; Assign = @(@{ Role = 'Billing Reader'; Scope = '/subscriptions/sub-a' }); Perm = 'Billing Reader'; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: Billing Reader at subscription)' }
    ) {
        param($Case, $Assign, $Perm, $State, $Reason)
        $Permissions = @{}
        if ($Perm) { $Permissions['/subscriptions/sub-a'] = @{ Status = 200; Roles = @($Perm) } }
        Set-RoleScenario -Assignments $Assign -Permissions $Permissions
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA))
        $R.Count | Should -Be 1
        $R[0].State | Should -Be $State
        $R[0].Reason | Should -Be $Reason
        $Tag = if ($State -eq 'Readable') { 'Pass' } else { $State }
        $script:Lines[0] | Should -BeLike ([WildcardPattern]::Escape(('  [{0}] Alpha - {1} (' -f $Tag, $Reason)) + '*s)')
    }

    It 'stops on a disagreement (<Case>) and says to wait and re-run' -TestCases @(
        @{ Case = 'roles say yes, Azure says no'; Assign = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }); Perm = $null }
        @{ Case = 'roles say no, Azure says yes'; Assign = @(@{ Role = 'SubRead'; Scope = '/subscriptions/sub-a' }); Perm = 'Reader' }
    ) {
        param($Case, $Assign, $Perm)
        $Permissions = @{}
        if ($Perm) { $Permissions['/subscriptions/sub-a'] = @{ Status = 200; Roles = @($Perm) } }
        Set-RoleScenario -Assignments $Assign -Permissions $Permissions
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA))
        $R[0].State | Should -Be 'Disagree'
        $R[0].Reason | Should -Match 'if roles changed in the last few minutes, wait 5 minutes and re-run$'
        (Resolve-AccessPreflight -Probed $R).ShouldBlock | Should -BeTrue
    }

    It 'stops as inconclusive when an answer stays throttled' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }) -Permissions @{ '/subscriptions/sub-a' = @{ Status = 429 } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA))
        $R[0].State | Should -Be 'Unknown'
        $R[0].Reason | Should -BeLike 'role check inconclusive after retries (*'
    }

    It 'for a -ResourceGroup run checks that resource group, and the subscription only for usage' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a/resourceGroups/rg-one' }) -Permissions @{ '/subscriptions/sub-a/resourcegroups/rg-one' = @{ Status = 200; Roles = @('Reader') } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA) -ResourceGroup 'rg-one' -IncludeUsage)
        $R[0].State | Should -Be 'Readable'
        $R[0].Reason | Should -Be "Read access: Reader at resource group 'rg-one'"
        $R[0].UsageVerdict | Should -Be 'No'
        $script:Calls | Should -Contain 'permissions /subscriptions/sub-a/resourcegroups/rg-one'
        $script:Calls | Should -Contain 'permissions /subscriptions/sub-a'
        $script:Lines[1] | Should -Be '      usage permission (Microsoft.Commerce/UsageAggregates/read): no - the roles on this subscription do not include it'
    }

    It 'for a -ResourceGroup run without consumption asks Azure about the resource group only' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }) -Permissions @{ '/subscriptions/sub-a/resourcegroups/rg-one' = @{ Status = 200; Roles = @('Reader') } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA) -ResourceGroup 'rg-one')
        $R[0].State | Should -Be 'Readable'
        @($script:Calls | Where-Object { $_ -like 'permissions *' }) | Should -Be @('permissions /subscriptions/sub-a/resourcegroups/rg-one')
        $R[0].UsageVerdict | Should -BeNullOrEmpty
        $script:Lines.Count | Should -Be 1
    }

    It 'stops when the -ResourceGroup target does not exist' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }) -Permissions @{ '/subscriptions/sub-a/resourcegroups/rg-typo' = @{ Status = 404 } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA) -ResourceGroup 'rg-typo')
        $R[0].State | Should -Be 'NoAccess'
        $R[0].Reason | Should -Be "resource group 'rg-typo' not found or not readable"
    }

    It 'prints the usage verdict with -IncludeUsage, also when reading resources fails' {
        Set-RoleScenario -Assignments @(@{ Role = 'Billing Reader'; Scope = '/subscriptions/sub-a' }) -Permissions @{ '/subscriptions/sub-a' = @{ Status = 200; Roles = @('Billing Reader') } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA) -IncludeUsage)
        $R[0].State | Should -Be 'NoAccess'
        $R[0].UsageVerdict | Should -Be 'Yes'
        $script:Lines[1] | Should -Be '      usage permission (Microsoft.Commerce/UsageAggregates/read): yes - Billing Reader at subscription'
    }

    It 'stops a role that reads all but some resource types, naming the role and the pattern (<Case>)' -TestCases @(
        @{ Case = 'both answers'; Assign = @(@{ Role = 'NoComputeRead'; Scope = '/subscriptions/sub-a' }); Reason = "role 'Reader without Compute' at subscription excludes 'Microsoft.Compute/*/read'; the inventory would miss those resources" }
        @{ Case = 'role assignments not visible'; Assign = @(); Reason = "Azure reports read access that excludes 'Microsoft.Compute/*/read' (role assignments not visible to this identity); the inventory would miss those resources" }
    ) {
        param($Case, $Assign, $Reason)
        Set-RoleScenario -Assignments $Assign -Permissions @{ '/subscriptions/sub-a' = @{ Status = 200; Roles = @('NoComputeRead') } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA))
        $R[0].State | Should -Be 'NoAccess'
        $R[0].Reason | Should -Be $Reason
        (Resolve-AccessPreflight -Probed $R).ShouldBlock | Should -BeTrue
    }

    It 'passes Reader beside a role that reads all but some resource types' {
        Set-RoleScenario -Assignments @(@{ Role = 'NoComputeRead'; Scope = '/subscriptions/sub-a' }, @{ Role = 'Reader'; Scope = '/providers/Microsoft.Management/managementGroups/mg-1' }) -Permissions @{ '/subscriptions/sub-a' = @{ Status = 200; Roles = @('NoComputeRead', 'Reader') } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA))
        $R[0].State | Should -Be 'Readable'
        $R[0].Reason | Should -Be 'Read access: Reader at management group'
    }

    It 'reads a refused role definition once for the whole run, with the same verdicts' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/providers/Microsoft.Management/managementGroups/mg-1' }) -DefinitionStatus 403 -Permissions @{
            '/subscriptions/sub-a' = @{ Status = 200; Roles = @('Reader') }
            '/subscriptions/sub-b' = @{ Status = 200; Roles = @('Reader') }
            '/subscriptions/sub-c' = @{ Status = 200; Roles = @('Reader') }
        }
        $Subs = @('sub-a', 'sub-b', 'sub-c') | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $_ } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions $Subs)
        @($R | ForEach-Object { $_.State }) | Should -Be @('Unknown', 'Unknown', 'Unknown')
        @($R | ForEach-Object { $_.Reason }) | Should -Be @(1..3 | ForEach-Object { 'role check inconclusive after retries (a role definition could not be read)' })
        @($script:Calls | Where-Object { $_ -like 'definition *' }).Count | Should -Be 1
    }

    It 'reads a role definition again after a server error on the first subscription' {
        Set-RoleScenario -Assignments @(@{ Role = 'Reader'; Scope = '/providers/Microsoft.Management/managementGroups/mg-1' }) -DefinitionStatus @(503, 503, 503, 503, 200) -Permissions @{
            '/subscriptions/sub-a' = @{ Status = 200; Roles = @('Reader') }
            '/subscriptions/sub-b' = @{ Status = 200; Roles = @('Reader') }
        }
        $Subs = @('sub-a', 'sub-b') | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $_ } }
        $R = @(Test-SubscriptionRoleAccessAll -Subscriptions $Subs)
        @($R | ForEach-Object { $_.State }) | Should -Be @('Unknown', 'Readable')
    }
}

Describe 'Invoke-RoleCheckGet page cap' {
    BeforeEach {
        Mock Start-Sleep { }
        # A list answer of $script:PageCount pages joined by nextLink.
        Mock Invoke-AzRestMethod {
            $N = if ($Uri -match 'page=(\d+)$') { [int]$Matches[1] } else { 1 }
            $Body = @{ value = @(@{ id = $N }) }
            if ($N -lt $script:PageCount) { $Body.nextLink = 'https://management.example.test/list?page={0}' -f ($N + 1) }
            New-Response -Status 200 -Body $Body
        }
    }

    It 'follows more than 50 pages by default' {
        $script:PageCount = 60
        $Answer = Invoke-RoleCheckGet -Path '/subscriptions/sub-a/list'
        $Answer.Error | Should -BeNullOrEmpty
        @($Answer.Items).Count | Should -Be 60
    }

    It 'still stops after 1000 pages by default, as an error' {
        $script:PageCount = 1001
        $Answer = Invoke-RoleCheckGet -Path '/subscriptions/sub-a/list'
        $Answer.Error | Should -Be 'more than 1000 pages'
        $Answer.Status | Should -BeNullOrEmpty
        Should -Invoke Invoke-AzRestMethod -Times 1000 -Exactly
    }
}

Describe 'Get-RoleCheckCallerObjectId' {
    It 'reads the oid claim from the Resource Manager token of the current context' {
        $Payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('{"oid":"caller-oid","tid":"t"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        Mock Get-AzContext { [pscustomobject]@{ Environment = [pscustomobject]@{ ResourceManagerUrl = 'https://management.example.test/' } } }
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = (ConvertTo-SecureString ('e30.' + $Payload + '.sig') -AsPlainText -Force) } }
        Get-RoleCheckCallerObjectId | Should -Be 'caller-oid'
        Should -Invoke Get-AzAccessToken -Times 1 -Exactly -ParameterFilter { $ResourceUrl -eq 'https://management.example.test/' }
    }

    It 'returns $null when no token can be had' {
        Mock Get-AzContext { $null }
        Mock Get-AzAccessToken { throw 'no context' }
        Get-RoleCheckCallerObjectId | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-AccessPreflight' {
    It 'treats every state other than Readable as not readable, and blocks only when none is readable' {
        $Probed = @(
            [pscustomobject]@{ Id = 's1'; State = 'Readable' }
            [pscustomobject]@{ Id = 's2'; State = 'Disagree' }
            [pscustomobject]@{ Id = 's3'; State = 'SomethingNew' }
        )
        $D = Resolve-AccessPreflight -Probed $Probed
        $D.ShouldBlock | Should -BeFalse
        $D.InaccessibleIds | Should -Be @('s2', 's3')
        $D.ReadableCount | Should -Be 1
        (Resolve-AccessPreflight -Probed @($Probed[1], $Probed[2])).ShouldBlock | Should -BeTrue
    }
}

Describe 'Write-AccessPreflightReport' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        $script:Blocked = [pscustomobject]@{
            Inaccessible    = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: Reader at a resource group)' })
            InaccessibleIds = @('sub-b')
            ShouldBlock     = $true
        }
    }

    It 'stops when no subscription is readable, and offers no switch' {
        Write-AccessPreflightReport -Decision $script:Blocked -ScopeCount 1
        @($script:Lines) | Should -Be @(
            '  1 subscription(s) are NOT readable by the signed-in identity:'
            '    - Bravo (sub-b) - no role grants read access (roles visible: Reader at a resource group)'
            '  No subscription is readable. Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.'
        )
    }

    It 'skips the subscriptions that are not readable and says how to include them' {
        $Decision = [pscustomobject]@{ Inaccessible = $script:Blocked.Inaccessible; InaccessibleIds = @('sub-b'); ReadableCount = 2; ShouldBlock = $false }
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 3
        @($script:Lines) | Should -Be @(
            '  1 subscription(s) are NOT readable by the signed-in identity:'
            '    - Bravo (sub-b) - no role grants read access (roles visible: Reader at a resource group)'
            '  Skipping them and continuing with the 2 readable subscription(s). To include them: Grant the identity Reader on these subscriptions, then re-run.'
        )
    }

    It 'words a resource group run' {
        Write-AccessPreflightReport -Decision $script:Blocked -ScopeCount 1 -ResourceGroup 'rg-one'
        $script:Lines[0] | Should -Be "  Resource group 'rg-one' is NOT readable by the signed-in identity in 1 subscription(s):"
        ($script:Lines -join "`n") | Should -Not -Match 'AllowPartialAccess'
    }

    It 'gives the fix for why the check failed: <Verdict>' -TestCases @(
        @{ State = 'NoAccess'; Verdict = 'No'; Rg = ''; Fix = '  Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.' }
        @{ State = 'NoAccess'; Verdict = 'NoNotVisible'; Rg = ''; Fix = '  Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.' }
        @{ State = 'NoAccess'; Verdict = 'NotFound'; Rg = 'rg-one'; Fix = '  Stopping before any work. Check the resource group name, or grant the identity Reader on the resource group or its subscription, then re-run.' }
        @{ State = 'Unknown'; Verdict = 'Unknown'; Rg = ''; Fix = '  Stopping before any work. The role check could not finish (the reason above says why); re-run.' }
        @{ State = 'Disagree'; Verdict = 'Disagree'; Rg = ''; Fix = '  Stopping before any work. The role assignments and Azure disagree, which usually means roles changed in the last few minutes; wait 5 minutes, then re-run.' }
    ) {
        param($State, $Verdict, $Rg, $Fix)
        $Decision = [pscustomobject]@{
            Inaccessible    = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = $State; Verdict = $Verdict; Reason = 'reason' })
            InaccessibleIds = @('sub-b')
            ShouldBlock     = $true
        }
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 1 -ResourceGroup $Rg
        $script:Lines[2] | Should -Be ('  No subscription is readable. ' + $Fix.TrimStart())
        $script:Lines.Count | Should -Be 3
    }

    It 'gives one fix per cause, naming the subscriptions, when the causes differ' {
        $Decision = [pscustomobject]@{
            Inaccessible    = @(
                [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = 'Unknown'; Verdict = 'Unknown'; Reason = 'role check inconclusive after retries (role assignment list: more than 1000 pages)' }
                [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie'; State = 'NoAccess'; Verdict = 'No'; Reason = 'no role grants read access (roles visible: none)' }
                [pscustomobject]@{ Id = 'sub-d'; Name = 'Delta'; State = 'Unknown'; Verdict = 'Unknown'; Reason = 'role check inconclusive after retries (caller permissions: HTTP 429)' }
            )
            InaccessibleIds = @('sub-b', 'sub-c', 'sub-d')
            ReadableCount   = 1
            ShouldBlock     = $false
        }
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 4
        @($script:Lines | Select-Object -Skip 4) | Should -Be @(
            '  Skipping them and continuing with the 1 readable subscription(s). To include them:'
            '    Charlie: Grant the identity Reader on these subscriptions, then re-run.'
            '    Bravo, Delta: The role check could not finish (the reason above says why); re-run.'
        )
        $script:Lines.Clear()
        $Decision.ShouldBlock = $true
        $Decision.ReadableCount = 0
        Write-AccessPreflightReport -Decision $Decision -ScopeCount 3
        $script:Lines[4] | Should -Be '  No subscription is readable. Stopping before any work.'
    }
}

Describe 'Write-UsageRoleReport' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        $script:Refused = [pscustomobject]@{ ShouldBlock = $true; Failed = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }) }
    }

    It 'gives the fix when the roles do not include the usage permission' {
        Write-UsageRoleReport -ConsumptionResult $script:Refused -RoleCheck @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; UsageVerdict = 'No'; UsageText = 'no' })
        @($script:Lines) | Should -Be @(
            'Usage permission found by the role check:'
            '  - Alpha: the roles on this subscription do not include Microsoft.Commerce/UsageAggregates/read: add Reader or Billing Reader at the subscription'
        )
    }

    It 'says the roles are not the problem when they include it' {
        Write-UsageRoleReport -ConsumptionResult $script:Refused -RoleCheck @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; UsageVerdict = 'Yes'; UsageText = 'yes' })
        $script:Lines[1] | Should -BeLike '  - Alpha: the roles include Microsoft.Commerce/UsageAggregates/read, so the missing values are not a role problem*'
    }

    It 'prints nothing when the consumption check passed or there are no role records' {
        Write-UsageRoleReport -ConsumptionResult ([pscustomobject]@{ ShouldBlock = $false; Failed = @() }) -RoleCheck @([pscustomobject]@{ Id = 'sub-a'; UsageVerdict = 'No' })
        Write-UsageRoleReport -ConsumptionResult $script:Refused -RoleCheck @()
        $script:Lines.Count | Should -Be 0
    }
}

Describe 'Role check records feed the consumption data check' {
    BeforeAll {
        function Set-AzContext { param($Subscription, $Context, $Scope) }
        function Get-UsageAggregates { param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken) }
        $script:UsageWindow = Get-ConsumptionWindow -Now ([datetime]'2026-10-26T10:00:00')
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Start-Sleep { }
        Mock Get-RoleCheckCallerObjectId { 'caller-oid' }
        Mock Get-AzContext { $null }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $Subscription } } }
        # The subscription holds resources and returns no usage rows.
        Mock Invoke-AzRestMethod {
            $Target = if ($Path) { $Path } else { $Uri }
            if ($Target -like '/providers/Microsoft.ResourceGraph/*') { return (New-Response -Status 200 -Body @{ data = @(@{ subscriptionId = 'sub-a'; ResourceCount = 1 }) }) }
            Get-ScenarioResponse -Target $Target
        }
        Mock Get-UsageAggregatesPage { [pscustomobject]@{ UsageAggregations = @(); ContinuationToken = $null } }
    }

    It '<Case>: outcome <Expected>' -TestCases @(
        @{ Case = 'Reader at the subscription in both answers'; Assignments = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }); Granted = @('Reader'); Expected = 'NoUsage' }
        @{ Case = 'Reader through a group at a management group'; Assignments = @(@{ Role = 'Reader'; Scope = '/providers/Microsoft.Management/managementGroups/mg-1'; Group = $true }); Granted = @('Reader'); Expected = 'NoUsage' }
        @{ Case = 'roles include it, Azure does not'; Assignments = @(@{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }); Granted = @('NoCommerce'); Expected = 'NoRows' }
        @{ Case = 'Azure includes it, the roles do not'; Assignments = @(@{ Role = 'NoCommerce'; Scope = '/subscriptions/sub-a' }); Granted = @('Reader'); Expected = 'NoRows' }
        @{ Case = 'role assignments not visible'; Assignments = @(); Granted = @('Reader'); Expected = 'NoRows' }
        @{ Case = 'usage only granted at a resource group'; Assignments = @(@{ Role = 'NoCommerce'; Scope = '/subscriptions/sub-a' }, @{ Role = 'Billing Reader'; Scope = '/subscriptions/sub-a/resourceGroups/rg-one' }); Granted = @('Reader'); Expected = 'NoRows' }
    ) {
        param($Case, $Assignments, $Granted, $Expected)
        Set-RoleScenario -Assignments $Assignments -Permissions @{ '/subscriptions/sub-a' = @{ Status = 200; Roles = $Granted } }
        $Records = @(Test-SubscriptionRoleAccessAll -Subscriptions @($script:SubA) -IncludeUsage)
        $Result = Invoke-ConsumptionDataCheck -Subscriptions @($script:SubA) -Window $script:UsageWindow -RoleCheck $Records
        $Result.Results[0].Outcome | Should -Be $Expected
        $Result.ShouldBlock | Should -Be ($Expected -ne 'NoUsage')
        if ($Expected -eq 'NoUsage') { $Result.Results[0].Detail | Should -Match 'Reader at (subscription|management group through a group)' }
    }
}

Describe 'Run-AllSubscriptions.ps1 up-front role check' {
    BeforeAll {
        # Runs the wrapper's own statements from '$ScopeForProbe =' to the end
        # of the following if-block with Azure mocked, and records what they
        # print, so the expected lines below pin the wrapper's wording.
        $script:WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
        $Tokens = $null
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$Tokens, [ref]$Errors)
        $script:Top = @($Ast.EndBlock.Statements)
        $Index = -1
        for ($I = 0; $I -lt $script:Top.Count; $I++)
        {
            if ($script:Top[$I].Extent.Text -match '^\$ScopeForProbe\s*=') { $Index = $I; break }
        }
        if ($Index -lt 0) { throw 'The role check was not found in Run-AllSubscriptions.ps1.' }
        $script:GateIndex = $Index
        $script:GateBlock = [scriptblock]::Create(($script:Top[$Index].Extent.Text + "`n" + $script:Top[$Index + 1].Extent.Text))
    }

    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        Mock Start-Sleep { }
        Mock Exit-Wrapper { throw ('EXIT {0}' -f $Code) }
        Mock Get-RoleCheckCallerObjectId { 'caller-oid' }
        Mock Invoke-AzRestMethod { Get-ScenarioResponse -Target $(if ($Path) { $Path } else { $Uri }) }
        # sub-a readable, sub-b Reader on a resource group only, sub-c throttled.
        Set-RoleScenario -Assignments @(
            @{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }
            @{ Role = 'Reader'; Scope = '/subscriptions/sub-b/resourceGroups/rg-one' }
            @{ Role = 'Reader'; Scope = '/subscriptions/sub-c' }
        ) -Permissions @{
            '/subscriptions/sub-a' = @{ Status = 200; Roles = @('Reader') }
            '/subscriptions/sub-c' = @{ Status = 429 }
        }
        $script:Subscriptions = @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie' }
        )
        $script:CompletedIds = @()
        $script:Resume = $false
        $script:AllowPartialAccess = $false
        $script:SkipConsumption = $true
    }

    AfterAll {
        Remove-Variable -Name Subscriptions, CompletedIds, Resume, AllowPartialAccess, SkipConsumption -Scope Script -ErrorAction SilentlyContinue
    }

    It 'runs before the consumption data check and keeps the records for the end-of-run labels' {
        $ConsumptionIndex = -1
        for ($I = 0; $I -lt $script:Top.Count; $I++)
        {
            if ($script:Top[$I].Extent.Text -match '^\$ConsumptionCheckScope\s*=') { $ConsumptionIndex = $I; break }
        }
        $ConsumptionIndex | Should -BeGreaterThan $script:GateIndex
        $script:Top[$ConsumptionIndex + 1].Extent.Text | Should -Match 'Write-UsageRoleReport -ConsumptionResult \$ConsumptionCheck -RoleCheck \$AccessProbed'
        $Text = Get-Content -Path $script:WrapperPath -Raw
        $Text | Should -Not -Match 'Get-SubscriptionAccessState|Test-SubscriptionAccessAll'
        Get-Command Get-SubscriptionAccessState -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'skips the subscriptions that are not readable, with the fix for each cause, and continues' {
        . $script:GateBlock
        Should -Invoke Exit-Wrapper -Times 0 -Exactly
        $Summary = @($script:Lines | Where-Object { $_ -notlike '  `[*' })
        $Summary | Should -Be @(
            'Verifying subscription access up front for 3 subscription(s)...'
            '  2 subscription(s) are NOT readable by the signed-in identity:'
            '    - Bravo (sub-b) - no role grants read access (roles visible: Reader at a resource group)'
            '    - Charlie (sub-c) - role check inconclusive after retries (caller permissions: HTTP 429)'
            '  Skipping them and continuing with the 1 readable subscription(s). To include them:'
            '    Bravo: Grant the identity Reader on these subscriptions, then re-run.'
            '    Charlie: The role check could not finish (the reason above says why); re-run.'
        )
        $script:Lines[1] | Should -BeLike '  `[Pass`] Alpha - Read access: Reader at subscription (*s)'
        @($Subscriptions | ForEach-Object { $_.Id }) | Should -Be @('sub-a')
        @($AccessDecision.InaccessibleIds) | Should -Be @('sub-b', 'sub-c')
    }

    It 'skips a role that reads all but some resource types, with or without -AllowPartialAccess' {
        Set-RoleScenario -Assignments @(
            @{ Role = 'Reader'; Scope = '/subscriptions/sub-a' }
            @{ Role = 'NoComputeRead'; Scope = '/subscriptions/sub-b' }
        ) -Permissions @{
            '/subscriptions/sub-a' = @{ Status = 200; Roles = @('Reader') }
            '/subscriptions/sub-b' = @{ Status = 200; Roles = @('NoComputeRead') }
        }
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' })
        . $script:GateBlock
        $script:Lines | Should -Contain "    - Bravo (sub-b) - role 'Reader without Compute' at subscription excludes 'Microsoft.Compute/*/read'; the inventory would miss those resources"
        @($Subscriptions | ForEach-Object { $_.Id }) | Should -Be @('sub-a')

        $script:Lines.Clear()
        $script:AllowPartialAccess = $true
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' })
        . $script:GateBlock
        @($Subscriptions | ForEach-Object { $_.Id }) | Should -Be @('sub-a')
    }

    It 'skips the failing subscriptions the same way under -AllowPartialAccess' {
        $script:AllowPartialAccess = $true
        . $script:GateBlock
        Should -Invoke Exit-Wrapper -Times 0 -Exactly
        $script:Lines[-1] | Should -Be '    Charlie: The role check could not finish (the reason above says why); re-run.'
        @($Subscriptions | ForEach-Object { $_.Id }) | Should -Be @('sub-a')
        @($AccessProbed).Count | Should -Be 3
    }

    It 'stops with exit 1 when no subscription is readable (<Case>)' -TestCases @(@{ Case = 'default'; Allow = $false }, @{ Case = '-AllowPartialAccess'; Allow = $true }) {
        param($Case, $Allow)
        $script:AllowPartialAccess = $Allow
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo' }, [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie' })
        { . $script:GateBlock } | Should -Throw 'EXIT 1'
        $script:Lines | Should -Contain '  No subscription is readable. Stopping before any work.'
    }

    It 'confirms when every subscription is readable, with the usage verdict when consumption is requested' {
        $script:SkipConsumption = $false
        $script:Subscriptions = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha' })
        { . $script:GateBlock } | Should -Not -Throw
        $script:Lines[0] | Should -Be 'Verifying subscription access up front for 1 subscription(s)...'
        $script:Lines[2] | Should -Be '      usage permission (Microsoft.Commerce/UsageAggregates/read): yes - Reader at subscription'
        $script:Lines[3] | Should -Be '  Access verified: all 1 in-scope subscription(s) are readable.'
    }

    It 'on -Resume checks only the subscriptions this run will process' {
        $script:Resume = $true
        $script:CompletedIds = @('sub-b', 'sub-c')
        { . $script:GateBlock } | Should -Not -Throw
        @($script:Calls | Where-Object { $_ -like 'roles *' }) | Should -Be @('roles sub-a')
    }
}

Describe 'Run-AllSubscriptions.ps1 end-of-run 0-resource labels' {
    BeforeAll {
        $WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
        $Tokens = $null
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($WrapperPath, [ref]$Tokens, [ref]$Errors)
        $Block = @($Ast.EndBlock.Statements | Where-Object { $_.Extent.Text -match '^if \(\$EmptySubs\.Count -gt 0\)' })
        if ($Block.Count -ne 1) { throw 'The 0-resource block was not found in Run-AllSubscriptions.ps1.' }
        $script:EmptyBlock = [scriptblock]::Create($Block[0].Extent.Text)
    }

    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
        Mock Invoke-AzRestMethod { throw 'no Azure call expected' }
        $script:DiagFile = Join-Path $TestDrive ('diag-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.log')
        $script:InventoryRoot = $TestDrive
        $script:EmptySubs = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; Count = 0 }, [pscustomobject]@{ Id = 'sub-z'; Name = 'Zulu'; Count = 0 })
        $script:AccessProbed = @([pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; State = 'Readable' })
    }

    It 'labels a subscription that passed the role check genuinely empty, one it did not cover undetermined, without probing Azure' {
        . $script:EmptyBlock
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
        @($GenuinelyEmptySubs | ForEach-Object { $_.Id }) | Should -Be @('sub-a')
        @($UnknownSubs | ForEach-Object { $_.Id }) | Should -Be @('sub-z')
        $script:Lines | Should -Contain '  GENUINELY EMPTY (1) - the up-front role check found read access; the subscription has no resources:'
        $script:Lines | Should -Contain "  UNDETERMINED (1) - not covered by this run's up-front role check:"
        ($script:Lines -join "`n") | Should -Not -Match 'access confirmed|NO ACCESS'
        $Diag = Get-Content -Path $script:DiagFile -Raw
        $Diag | Should -Match 'EMPTY Alpha \(sub-a\) - read access found by the up-front role check, no resources; no action needed'
        $Diag | Should -Match "UNDETERMINED   Zulu \(sub-z\) - not covered by this run's up-front role check"
        $Diag | Should -Not -Match 'access confirmed'
    }
}

Describe 'ResourceInventory.ps1 direct run' {
    BeforeAll {
        # Runs the real script in a child pwsh with Azure replaced by stubs. Every
        # role check request, resource count query and usage query appends a line
        # to a call log, so the order of the up-front checks is observable. The
        # stubbed 'az graph' call is the first inventory step after setup; it
        # writes a marker and exits 3, so reaching inventory is observable and
        # nothing past it runs.
        $script:Harness = Join-Path $TestDrive 'harness.ps1'
        @'
param([string]$Root, [string]$Out, [string]$Roles = 'reader', [string]$PermSub = 'read', [string]$PermRg = 'read', [string]$Usage = 'values', [string]$ResourceGroup, [switch]$SkipConsumption, [switch]$RunAllSubs, [switch]$NoSubscriptionId, [string]$WindowStart, [string]$WindowEnd, [int]$SubCount = 1, [string]$Unreadable = '', [switch]$GraphData)
$Global:RdaSessionInitialized = $true
$Global:AzPowerShellLoaded = $true
$Global:PlatformOS = 'PowerShell Unix'
# The stand-ins below are functions of this runspace, so the up-front checks
# run one subscription at a time here (parallel runspaces would not see them).
$Global:PSDefaultParameterValues = @{ 'Test-SubscriptionRoleAccessAll:ThrottleLimit' = 1; 'Invoke-ConsumptionDataCheck:ThrottleLimit' = 1 }
$TestSub = '12345678-1234-1234-1234-123456789012'
# Subscription N (from 1): ...1234567890<11+N>, so subscription 1 is $TestSub.
$Global:TestSubs = @(1..$SubCount | ForEach-Object { [pscustomobject]@{ id = ('12345678-1234-1234-1234-1234567890{0:d2}' -f (11 + $_)); name = $(if ($SubCount -eq 1) { 'Placeholder subscription' } else { 'Placeholder subscription {0}' -f $_ }); tenantId = $TestSub } })
$Global:UnreadableIds = @(($Unreadable -split ',') | Where-Object { $_ } | ForEach-Object { $Global:TestSubs[[int]$_ - 1].id })
function global:az
{
    $Joined = $args -join ' '
    if ($Joined -like 'account show*') { return ('{{"user":{{"name":"tester"}},"tenantId":"{0}"}}' -f $TestSub) }
    if ($Joined -like 'account list*') { return (ConvertTo-Json -InputObject @($Global:TestSubs) -Compress) }
    if ($Joined -like 'graph*' -and -not $env:RDA_TEST_GRAPH_DATA) { Set-Content -Path $env:RDA_TEST_INVENTORY_MARKER -Value 'inventory started'; exit 3 }
    if ($Joined -like 'graph*')
    {
        # One resource in each visible subscription; no AVD resources.
        Set-Content -Path $env:RDA_TEST_INVENTORY_MARKER -Value 'inventory started'
        $global:LASTEXITCODE = 0
        if ($Joined -match 'desktopvirtualizationresources') { return '{"data":[{"count_":0}],"count":1}' }
        if ($Joined -match 'summarize count\(\)') { return ('{{"data":[{{"count_":{0}}}],"count":1}}' -f $Global:TestSubs.Count) }
        $Rows = @($Global:TestSubs | ForEach-Object { @{ id = ('/subscriptions/{0}/resourcegroups/rg-1/providers/microsoft.network/networksecuritygroups/nsg-1' -f $_.id); name = 'nsg-1'; type = 'microsoft.network/networksecuritygroups'; subscriptionId = $_.id; resourceGroup = 'rg-1' } })
        return (@{ data = $Rows; count = $Rows.Count } | ConvertTo-Json -Depth 5 -Compress)
    }
    return $null
}
# Reached right after the setup phase (inventory collected): records what was
# collected, then stops the run.
function global:Start-Transcript
{
    param($Path, [switch]$UseMinimalHeader)
    @{ ResourceSubscriptions = @($Global:Resources | ForEach-Object { [string]$_.subscriptionId } | Sort-Object -Unique); Subscriptions = @($Global:Subscriptions | ForEach-Object { [string]$_.id }) } |
        ConvertTo-Json -Compress | Set-Content -Path $env:RDA_TEST_COLLECTED
    exit 4
}
function global:Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $TestSub }; Subscription = [pscustomobject]@{ Id = $TestSub } } }
function global:Set-AzContext { param($Subscription, $Context, $Scope) [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $(if ($Subscription) { $Subscription } else { $TestSub }) } } }
function global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = ('e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"oid":"test-oid"}')).TrimEnd('=') + '.sig') } }
function global:Invoke-AzRestMethod
{
    param($Method, $Path, $Payload, $Uri)
    $Target = if ($Path) { $Path } else { $Uri }
    $Json = { param($Obj) [pscustomobject]@{ StatusCode = 200; Content = ($Obj | ConvertTo-Json -Depth 10) } }
    $CallSub = if ($Target -match '^/subscriptions/([^/?]+)') { $Matches[1] } else { $TestSub }
    $Unreadable = $Global:UnreadableIds -contains $CallSub
    if ($Target -match '/roleAssignments\?')
    {
        Add-Content -Path $env:RDA_TEST_CALL_LOG -Value 'roles'
        $Scope = switch ($(if ($Unreadable) { 'none' } else { $env:RDA_TEST_ROLES })) { 'reader' { "/subscriptions/$CallSub" } 'nocompute' { "/subscriptions/$CallSub" } 'rg' { "/subscriptions/$CallSub/resourceGroups/rg-one" } default { $null } }
        $Definition = if ($env:RDA_TEST_ROLES -eq 'nocompute') { 'nocompute' } else { 'reader' }
        $Items = if ($Scope) { @(@{ properties = @{ roleDefinitionId = "/subscriptions/$TestSub/providers/Microsoft.Authorization/roleDefinitions/$Definition"; scope = $Scope; principalId = 'test-oid'; principalType = 'ServicePrincipal' } }) } else { @() }
        return (& $Json @{ value = $Items })
    }
    if ($Target -match '/roleDefinitions/nocompute')
    {
        return (& $Json @{ properties = @{ roleName = 'Reader without Compute'; type = 'CustomRole'; permissions = @(@{ actions = @('*/read'); notActions = @('Microsoft.Compute/*/read') }) } })
    }
    if ($Target -match '/roleDefinitions/')
    {
        return (& $Json @{ properties = @{ roleName = 'Reader'; type = 'BuiltInRole'; permissions = @(@{ actions = @('*/read'); notActions = @() }) } })
    }
    if ($Target -match '/providers/Microsoft\.Authorization/permissions\?')
    {
        $OnRg = $Target -match '/resourceGroups/'
        Add-Content -Path $env:RDA_TEST_CALL_LOG -Value ('permissions ' + $(if ($OnRg) { 'rg' } else { 'sub' }))
        $Mode = if ($Unreadable) { 'none' } elseif ($OnRg) { $env:RDA_TEST_PERM_RG } else { $env:RDA_TEST_PERM_SUB }
        if ($Mode -eq '404') { return [pscustomobject]@{ StatusCode = 404; Content = '{}' } }
        $Entries = switch ($Mode) { 'read' { @(@{ actions = @('*/read'); notActions = @() }) } 'nocompute' { @(@{ actions = @('*/read'); notActions = @('Microsoft.Compute/*/read') }) } default { @() } }
        return (& $Json @{ value = $Entries })
    }
    if ($Target -match '/providers/Microsoft\.Commerce/UsageAggregates\?')
    {
        Add-Content -Path $env:RDA_TEST_CALL_LOG -Value 'usage'
        Add-Content -Path ($env:RDA_TEST_CALL_LOG + '.usage-subs') -Value $CallSub
        $Query = [System.Web.HttpUtility]::ParseQueryString(([uri]('https://management.example.test' + $Target)).Query)
        Add-Content -Path $env:RDA_TEST_USAGE_WINDOW -Value ('{0} {1}' -f $Query['reportedStartTime'].Substring(0, 10), $Query['reportedEndTime'].Substring(0, 10))
        # 'in-rg' and 'other-rg' rows carry a resource in resource group RG-ONE or rg-two.
        $Uri = switch ($env:RDA_TEST_USAGE) { 'in-rg' { "/subscriptions/$TestSub/resourceGroups/RG-ONE/providers/Microsoft.Network/networkSecurityGroups/nsg-1" } 'other-rg' { "/subscriptions/$TestSub/resourceGroups/rg-two/providers/Microsoft.Network/networkSecurityGroups/nsg-2" } default { $null } }
        $Rows = if ($env:RDA_TEST_USAGE -eq 'values') { @(@{ properties = @{ quantity = 2 } }) }
        elseif ($Uri) { @(@{ properties = @{ quantity = 2; instanceData = (@{ 'Microsoft.Resources' = @{ resourceUri = $Uri } } | ConvertTo-Json -Compress) } }) }
        else { @() }
        return (& $Json @{ value = $Rows })
    }
    Add-Content -Path $env:RDA_TEST_CALL_LOG -Value 'resource counts'
    & $Json @{ data = @(@(($Payload | ConvertFrom-Json).subscriptions) | ForEach-Object { @{ subscriptionId = $_; ResourceCount = 4 } }) }
}
$env:RDA_TEST_ROLES = $Roles
$env:RDA_TEST_PERM_SUB = $PermSub
$env:RDA_TEST_PERM_RG = $PermRg
$env:RDA_TEST_USAGE = $Usage
$Extra = @{}
if (-not $NoSubscriptionId) { $Extra.SubscriptionID = $TestSub }
if ($ResourceGroup) { $Extra.ResourceGroup = $ResourceGroup }
if ($SkipConsumption) { $Extra.SkipConsumption = $true }
if ($RunAllSubs) { $Extra.RunAllSubs = $true }
if ($WindowStart) { $Extra.ConsumptionWindowStart = $WindowStart }
if ($WindowEnd) { $Extra.ConsumptionWindowEnd = $WindowEnd }
if ($GraphData) { $env:RDA_TEST_GRAPH_DATA = '1' }
& (Join-Path $Root 'ResourceInventory.ps1') -OutputDirectory $Out @Extra
exit $LASTEXITCODE
'@ | Set-Content -Path $script:Harness -Encoding utf8

        function Invoke-DirectRun
        {
            param([string]$Roles = 'reader', [string]$PermSub = 'read', [string]$PermRg = 'read', [string]$Usage = 'values', [string]$ResourceGroup, [switch]$SkipConsumption, [switch]$RunAllSubs, [switch]$NoSubscriptionId, [string]$WindowStart, [string]$WindowEnd, [int]$SubCount = 1, [string]$Unreadable = '', [switch]$GraphData)
            $Out = Join-Path $TestDrive ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $Out -Force | Out-Null
            $env:RDA_TEST_INVENTORY_MARKER = Join-Path $Out 'inventory.marker'
            $env:RDA_TEST_CALL_LOG = Join-Path $Out 'calls.log'
            $env:RDA_TEST_USAGE_WINDOW = Join-Path $Out 'usage-window.log'
            $env:RDA_TEST_COLLECTED = Join-Path $Out 'collected.json'
            $PwshArgs = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Root', $script:RepoRoot, '-Out', $Out, '-Roles', $Roles, '-PermSub', $PermSub, '-PermRg', $PermRg, '-Usage', $Usage)
            if ($ResourceGroup) { $PwshArgs += @('-ResourceGroup', $ResourceGroup) }
            if ($SkipConsumption) { $PwshArgs += '-SkipConsumption' }
            if ($RunAllSubs) { $PwshArgs += '-RunAllSubs' }
            if ($NoSubscriptionId) { $PwshArgs += '-NoSubscriptionId' }
            if ($WindowStart) { $PwshArgs += @('-WindowStart', $WindowStart) }
            if ($WindowEnd) { $PwshArgs += @('-WindowEnd', $WindowEnd) }
            $PwshArgs += @('-SubCount', $SubCount, '-Unreadable', $Unreadable)
            if ($GraphData) { $PwshArgs += '-GraphData' }
            Push-Location $script:RepoRoot
            try { $Output = & (Join-Path $PSHOME 'pwsh') @PwshArgs 2>&1 | Out-String }
            finally { Pop-Location }
            $Calls = if (Test-Path -Path $env:RDA_TEST_CALL_LOG) { @(Get-Content -Path $env:RDA_TEST_CALL_LOG) } else { @() }
            [pscustomobject]@{
                ExitCode         = $LASTEXITCODE
                Output           = $Output
                InventoryReached = (Test-Path -Path $env:RDA_TEST_INVENTORY_MARKER)
                Calls            = $Calls
                RoleCalls        = @($Calls | Where-Object { $_ -eq 'roles' -or $_ -like 'permissions *' })
                UsageWindows     = $(if (Test-Path -Path $env:RDA_TEST_USAGE_WINDOW) { @(Get-Content -Path $env:RDA_TEST_USAGE_WINDOW) } else { @() })
                UsageSubs        = $(if (Test-Path -Path ($env:RDA_TEST_CALL_LOG + '.usage-subs')) { @(Get-Content -Path ($env:RDA_TEST_CALL_LOG + '.usage-subs')) } else { @() })
                Collected        = $(if (Test-Path -Path $env:RDA_TEST_COLLECTED) { Get-Content -Path $env:RDA_TEST_COLLECTED -Raw | ConvertFrom-Json } else { $null })
            }
        }
    }

    AfterAll {
        Remove-Item Env:\RDA_TEST_INVENTORY_MARKER, Env:\RDA_TEST_CALL_LOG, Env:\RDA_TEST_USAGE_WINDOW, Env:\RDA_TEST_COLLECTED -ErrorAction SilentlyContinue
    }

    It 'checks the roles before the consumption check, then continues into inventory' {
        $Run = Invoke-DirectRun
        $Run.Calls[0] | Should -Be 'roles'
        $Run.Calls[1] | Should -Be 'permissions sub'
        $Run.Calls | Should -Contain 'usage'
        $Run.InventoryReached | Should -BeTrue
        $Run.ExitCode | Should -Be 3
        $Run.Output | Should -Match '\[Pass\] Placeholder subscription - Read access: Reader at subscription'
        $Run.Output | Should -Match 'usage permission \(Microsoft\.Commerce/UsageAggregates/read\): yes - Reader at subscription'
    }

    It 'exits 1 before the consumption check and before inventory for an identity that can read nothing' {
        $Run = Invoke-DirectRun -Roles 'none' -PermSub 'none'
        $Run.ExitCode | Should -Be 1
        $Run.Calls | Should -Not -Contain 'usage'
        $Run.Calls | Should -Not -Contain 'resource counts'
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match 'Placeholder subscription \(12345678-1234-1234-1234-123456789012\) - no read access \(role assignments not visible to this identity\)'
        $Run.Output | Should -Not -Match 'AllowPartialAccess'
    }

    It 'checks the roles under -SkipConsumption too, without a usage verdict' {
        $Run = Invoke-DirectRun -Roles 'none' -PermSub 'none' -SkipConsumption
        $Run.ExitCode | Should -Be 1
        $Run.RoleCalls.Count | Should -Be 2
        $Run.Output | Should -Not -Match 'usage permission'
        $Run.InventoryReached | Should -BeFalse
    }

    It 'does not run the role or usage check under -RunAllSubs (the wrapper already did)' {
        $Run = Invoke-DirectRun -Roles 'none' -PermSub 'none' -RunAllSubs
        $Run.RoleCalls.Count | Should -Be 0
        $Run.Calls | Should -Not -Contain 'usage'
        $Run.Calls | Should -Not -Contain 'resource counts'
        $Run.InventoryReached | Should -BeTrue
    }

    It 'stops a whole-subscription run for Reader on one resource group only' {
        $Run = Invoke-DirectRun -Roles 'rg' -PermSub 'none' -SkipConsumption
        $Run.ExitCode | Should -Be 1
        $Run.Output | Should -Match 'no role grants read access \(roles visible: Reader at a resource group\)'
    }

    It 'passes a -ResourceGroup run for Reader on that resource group' {
        $Run = Invoke-DirectRun -Roles 'rg' -PermSub 'none' -PermRg 'read' -ResourceGroup 'rg-one' -SkipConsumption
        $Run.RoleCalls | Should -Be @('roles', 'permissions rg')
        $Run.InventoryReached | Should -BeTrue
        $Run.Output | Should -Match "Access verified: resource group 'rg-one' is readable"
    }

    It 'stops a -ResourceGroup run when the resource group does not exist' {
        $Run = Invoke-DirectRun -Roles 'reader' -PermRg '404' -ResourceGroup 'rg-one' -SkipConsumption
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match "resource group 'rg-one' not found or not readable"
    }

    It 'with -ResourceGroup but no -SubscriptionID skips the check (ResourceInventoryLoop refuses that combination)' {
        $Run = Invoke-DirectRun -Roles 'none' -PermSub 'none' -ResourceGroup 'rg-one' -SkipConsumption -NoSubscriptionId
        $Run.RoleCalls.Count | Should -Be 0
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match 'If using ResourceGroup parameter you must also put SubscriptionId'
    }

    It 'on a consumption refusal prints the usage fix for a resource group grant' {
        $Run = Invoke-DirectRun -Roles 'rg' -PermSub 'none' -PermRg 'read' -ResourceGroup 'rg-one' -Usage 'empty'
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match 'usage permission \(Microsoft\.Commerce/UsageAggregates/read\): no - the roles on this subscription do not include it'
        $Run.Output | Should -Match 'Placeholder subscription: the roles on this subscription do not include Microsoft\.Commerce/UsageAggregates/read: add Reader or Billing Reader at the subscription'
    }

    It 'exits 1 before the consumption check for a role that reads all but some resource types' {
        $Run = Invoke-DirectRun -Roles 'nocompute' -PermSub 'nocompute'
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.Calls | Should -Not -Contain 'usage'
        $Run.Output | Should -Match ([regex]::Escape("Placeholder subscription (12345678-1234-1234-1234-123456789012) - role 'Reader without Compute' at subscription excludes 'Microsoft.Compute/*/read'; the inventory would miss those resources"))
        $Run.Output | Should -Match 'Grant the identity Reader on these subscriptions, then re-run\.'
    }

    It 'checks a -ResourceGroup run against usage rows of that resource group only (rows elsewhere -> stop)' {
        $Run = Invoke-DirectRun -Roles 'rg' -PermSub 'none' -PermRg 'read' -ResourceGroup 'rg-one' -Usage 'other-rg'
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.Output | Should -Match "Placeholder subscription \(12345678-1234-1234-1234-123456789012\): NoRows - the query succeeded but returned no usage rows for resource group 'rg-one'"
    }

    It 'passes a -ResourceGroup run on a usage row of that resource group, matched without case' {
        $Run = Invoke-DirectRun -Roles 'rg' -PermSub 'none' -PermRg 'read' -ResourceGroup 'rg-one' -Usage 'in-rg'
        $Run.InventoryReached | Should -BeTrue
        $Run.ExitCode | Should -Be 3
        $Run.Output | Should -Match "\[Pass\] Placeholder subscription - usage values found for resource group 'rg-one'"
        $Run.Output | Should -Match "Consumption data confirmed: 1 subscription\(s\) returned usage values for resource group 'rg-one'"
    }

    It 'passes a -ResourceGroup run with no usage in it, with a warning, when the usage permission is confirmed' {
        $Run = Invoke-DirectRun -Roles 'reader' -PermSub 'read' -PermRg 'read' -ResourceGroup 'rg-one' -Usage 'other-rg'
        $Run.InventoryReached | Should -BeTrue
        $Run.Output | Should -Match "\[NoUsage\] Placeholder subscription - the query succeeded but returned no usage rows for resource group 'rg-one'; the usage permission is confirmed"
        $Run.Output | Should -Match "WARNING: no usage above zero in resource group 'rg-one' for "
        $Run.Output | Should -Match "the consumption sheet for resource group 'rg-one' will be empty"
    }

    It 'checks the consumption window passed in (one window per wrapper run)' {
        $Run = Invoke-DirectRun -WindowStart '2026-01-01' -WindowEnd '2026-01-31'
        $Run.InventoryReached | Should -BeTrue
        $Run.UsageWindows | Should -Be @('2026-01-01 2026-01-31')
        $Run.Output | Should -Match 'usage values for 2026-01-01 to 2026-01-31'
    }

    It 'ignores a consumption window that is not valid (<Start> / <End>), with a warning, and uses its own' -TestCases @(
        @{ Start = '2026-02-30'; End = '2026-03-02' }
        @{ Start = '2026-03-02'; End = '2026-02-01' }
        @{ Start = '2026-01-01'; End = '' }
    ) {
        param($Start, $End)
        $Run = Invoke-DirectRun -WindowStart $Start -WindowEnd $End
        $Run.InventoryReached | Should -BeTrue
        $Own = Format-ConsumptionWindow -Window (Get-ConsumptionWindow)
        $Run.UsageWindows | Should -Be @($Own -replace ' to ', ' ')
        $Run.Output | Should -Match 'Ignoring -ConsumptionWindowStart'
    }

    It 'skips an unreadable subscription in a run over every visible subscription, checks usage for the others, and continues' {
        # The harness's subscription N.
        $SubId = { param($N) '12345678-1234-1234-1234-1234567890{0:d2}' -f (11 + $N) }
        $Run = Invoke-DirectRun -NoSubscriptionId -SubCount 3 -Unreadable '2'
        $Run.InventoryReached | Should -BeTrue
        $Run.ExitCode | Should -Be 3
        $Run.Output | Should -Match ([regex]::Escape('1 subscription(s) are NOT readable by the signed-in identity:'))
        $Run.Output | Should -Match ([regex]::Escape(('- Placeholder subscription 2 ({0}) - no read access (role assignments not visible to this identity)' -f (& $SubId 2))))
        $Run.Output | Should -Match ([regex]::Escape('Skipping them and continuing with the 2 readable subscription(s). To include them: Grant the identity Reader on these subscriptions, then re-run.'))
        $Run.UsageSubs | Should -Be @((& $SubId 1), (& $SubId 3))
        $Run.Output | Should -Match ([regex]::Escape('Verifying consumption data (usage values for'))
        $Run.Output | Should -Match ([regex]::Escape(') for 2 subscription(s)...'))
    }

    It 'leaves a skipped subscription out of the subscriptions and the collected resources' {
        $SubId = { param($N) '12345678-1234-1234-1234-1234567890{0:d2}' -f (11 + $N) }
        $Run = Invoke-DirectRun -NoSubscriptionId -SubCount 3 -Unreadable '2' -GraphData -SkipConsumption
        $Run.ExitCode | Should -Be 4
        @($Run.Collected.Subscriptions) | Should -Be @((& $SubId 1), (& $SubId 3))
        @($Run.Collected.ResourceSubscriptions) | Should -Be @((& $SubId 1), (& $SubId 3))
    }

    It 'collects every subscription when all are readable' {
        $Run = Invoke-DirectRun -NoSubscriptionId -SubCount 3 -GraphData -SkipConsumption
        $Run.ExitCode | Should -Be 4
        @($Run.Collected.ResourceSubscriptions).Count | Should -Be 3
        $Run.Output | Should -Match ([regex]::Escape('Access verified: all 3 in-scope subscription(s) are readable.'))
    }

    It 'stops with exit 1 before inventory when no visible subscription is readable' {
        $Run = Invoke-DirectRun -NoSubscriptionId -SubCount 2 -Unreadable '1,2'
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.Calls | Should -Not -Contain 'usage'
        $Run.Output | Should -Match ([regex]::Escape('No subscription is readable. Stopping before any work. Grant the identity Reader on these subscriptions, then re-run.'))
    }

    It 'stops with exit 1 for an unreadable -SubscriptionID even when other subscriptions are readable' {
        $Run = Invoke-DirectRun -SubCount 3 -Unreadable '1'
        $Run.ExitCode | Should -Be 1
        $Run.InventoryReached | Should -BeFalse
        $Run.RoleCalls | Should -Be @('roles', 'permissions sub')
        $Run.Output | Should -Match ([regex]::Escape('No subscription is readable. Stopping before any work.'))
    }
}

Describe 'Write-SkippedSubscriptionSummary (end-of-run list)' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
    }

    It 'lists every skipped subscription with its reason' {
        $Decision = Resolve-AccessPreflight -Probed @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'Alpha'; State = 'Readable' }
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Bravo'; State = 'NoAccess'; Reason = 'no role grants read access (roles visible: none)' }
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Charlie'; State = 'Unknown'; Reason = 'role check inconclusive after retries (caller permissions: HTTP 429)' }
        )
        Write-SkippedSubscriptionSummary -Decision $Decision
        @($script:Lines) | Should -Be @(
            ''
            'Subscriptions skipped (not readable by the signed-in identity): 2 - they are not in this report:'
            '  - Bravo (sub-b) - no role grants read access (roles visible: none)'
            '  - Charlie (sub-c) - role check inconclusive after retries (caller permissions: HTTP 429)'
            '  To include them, fix the access as the start of the run says, then re-run.'
        )
    }

    It 'prints nothing when none was skipped or there was no check' {
        Write-SkippedSubscriptionSummary -Decision (Resolve-AccessPreflight -Probed @([pscustomobject]@{ Id = 'sub-a'; State = 'Readable' }))
        Write-SkippedSubscriptionSummary -Decision $null
        $script:Lines.Count | Should -Be 0
    }

    It 'is called at the end of both scripts with the role check decision, after the counts in the wrapper' {
        $Wrapper = Get-Content -Path (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Wrapper | Should -Match ([regex]::Escape('Write-Host ("Subscriptions Processed: {0}" -f ($Subscriptions.Count - $SkippedCount)) -ForegroundColor Green') + '\s*\r?\n(#[^\n]*\n)*Write-SkippedSubscriptionSummary -Decision \$AccessDecision')
        $Direct = Get-Content -Path (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw
        $Direct.TrimEnd() | Should -Match 'Write-SkippedSubscriptionSummary -Decision \$script:AccessSkipped$'
    }
}
