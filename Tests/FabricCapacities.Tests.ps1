# Fabric capacity collector tests
# Runs Services/Analytics/FabricCapacities.ps1 on fake Resource Graph rows with the Fabric REST API and the
# activity log mocked. No Azure sign-in is needed.
# Run with: Invoke-Pester ./Tests/FabricCapacities.Tests.ps1 -Output Detailed
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'A Pester mock body does not share this file''s script scope, so the fake API state is global and removed in AfterAll.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins for Az and the tool''s Write-Log only need the parameter names the collector passes.')]
param()

BeforeAll {
    $script:Collector = Join-Path $PSScriptRoot '../Services/Analytics/FabricCapacities.ps1'
    if (-not (Get-Command -Name Invoke-AzRestMethod -ErrorAction SilentlyContinue))
    {
        function global:Invoke-AzRestMethod { param($Uri, $ResourceId, $Path, $Method) }
    }
    if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue))
    {
        function global:Write-Log { param([string]$Message, [string]$Severity, [switch]$NoConsole, [switch]$ToDebugLog) }
    }

    $script:SubId = '00000000-1111-2222-3333-444444444444'
    $script:Subs = @([pscustomobject]@{ id = $script:SubId; Name = 'sub-data-dev' })
    $script:CapGuid = 'aaaaaaaa-0000-0000-0000-000000000001'
    $script:WsGuid = 'bbbbbbbb-0000-0000-0000-000000000001'
    $script:WsEmptyGuid = 'bbbbbbbb-0000-0000-0000-000000000002'
    $script:JobA = 'cccccccc-0000-0000-0000-00000000000a'
    $script:JobB = 'cccccccc-0000-0000-0000-00000000000b'
    $script:JobC = 'cccccccc-0000-0000-0000-00000000000c'

    function Get-TestCapacityRow([string]$Name = 'capdatadev01', [string]$State = 'Active', [string]$Location = 'northeurope')
    {
        [pscustomobject]@{
            id             = "/subscriptions/$script:SubId/resourceGroups/rg-data-dev/providers/Microsoft.Fabric/capacities/$Name"
            NAME           = $Name
            TYPE           = 'microsoft.fabric/capacities'
            LOCATION       = $Location
            RESOURCEGROUP  = 'rg-data-dev'
            subscriptionId = $script:SubId
            SKU            = [pscustomobject]@{ name = 'F64'; tier = 'Fabric' }
            PROPERTIES     = [pscustomobject]@{ state = $State; administration = [pscustomobject]@{ members = @('admin@example.com') } }
        }
    }

    function Get-TestResponse([int]$Code, $Body = $null, $Headers = $null)
    {
        [pscustomobject]@{
            StatusCode = $Code
            Content    = if ($null -eq $Body) { '' } else { $Body | ConvertTo-Json -Depth 10 -Compress }
            Headers    = $Headers
        }
    }

    # Route table: first matching regex wins. A value is a response, or a list of responses served in turn.
    function Use-TestRoute([System.Collections.Specialized.OrderedDictionary]$Routes)
    {
        # Global, because a mock body does not share this file's script scope.
        $global:FabricCapacitiesTest = @{ Routes = $Routes; Hits = @{}; Calls = [System.Collections.Generic.List[string]]::new() }
    }

    function Get-TestDefaultRoute
    {
        $Routes = [ordered]@{}
        $Routes['/v1/capacities$'] = Get-TestResponse 200 @{ value = @(@{ id = $script:CapGuid; displayName = 'capdatadev01'; sku = 'F64'; region = 'North Europe'; state = 'Active' }) }
        $Routes['/v1/workspaces$'] = Get-TestResponse 200 @{ value = @(
                @{ id = $script:WsGuid; displayName = 'Sales secret workspace'; capacityId = $script:CapGuid },
                @{ id = $script:WsEmptyGuid; displayName = 'Empty workspace'; capacityId = $script:CapGuid },
                @{ id = 'dddddddd-0000-0000-0000-000000000009'; displayName = 'Other capacity'; capacityId = 'eeeeeeee-0000-0000-0000-000000000009' }
            )
        }
        $Routes["/v1/workspaces/$script:WsGuid/apacheAirflowJobs$"] = Get-TestResponse 200 @{ value = @(@{ id = $script:JobA; displayName = 'nightly-load' }, @{ id = $script:JobB; displayName = 'hourly-sync' }, @{ id = $script:JobC; displayName = 'autoscale-job' }) }
        $Routes["/v1/workspaces/$script:WsEmptyGuid/apacheAirflowJobs$"] = Get-TestResponse 200 @{ value = @() }
        $Routes["apacheAirflowJobs/$script:JobA/environment/compute\?beta=true$"] = Get-TestResponse 200 @{ nodeSize = 'Large'; shutdownPolicy = 'AlwaysOn'; poolTemplateName = 'Secret template'; computeScalability = @{ minNodeCount = 5; maxNodeCount = 5 } }
        $Routes["apacheAirflowJobs/$script:JobB/environment/compute\?beta=true$"] = Get-TestResponse 200 @{ nodeSize = 'Small'; shutdownPolicy = 'OneHourInactivity'; computeScalability = @{ minNodeCount = 5; maxNodeCount = 5 } }
        $Routes["apacheAirflowJobs/$script:JobC/environment/compute\?beta=true$"] = Get-TestResponse 200 @{ nodeSize = 'Large'; shutdownPolicy = 'AlwaysOn'; computeScalability = @{ minNodeCount = 5; maxNodeCount = 8 } }
        $Routes['eventtypes/management/values'] = Get-TestResponse 200 @{ value = @() }
        $Routes['/resources\?api-version=2021-04-01&\$expand=createdTime'] = Get-TestResponse 200 @{ value = @(@{ id = "/subscriptions/$script:SubId/resourceGroups/rg-data-dev/providers/Microsoft.Fabric/capacities/capdatadev01"; createdTime = '2025-01-01T00:00:00Z' }) }
        $Routes
    }

    # Row to bill link check, shared by the zip test and its negative controls. A row whose ID is billed must match
    # it string for string (case included) and take Name, ResourceGroup and Subscription from it. A row whose ID is
    # not billed while a billed id has the same name and group parts is a broken join (wrong token), never a deleted
    # capacity. A billed id with no row at all is a capacity deleted inside the window: counted, not a problem.
    function Test-FabricCapacityLink($Rows, [string[]]$BilledIds)
    {
        $Problems = [System.Collections.Generic.List[string]]::new()
        $Matched = 0
        foreach ($Row in @($Rows))
        {
            $Same = @($BilledIds | Where-Object { $_ -ieq $Row.ID })
            if ($Same.Count -gt 0)
            {
                $Matched++
                if (@($BilledIds | Where-Object { $_ -ceq $Row.ID }).Count -eq 0) { $Problems.Add("case: $($Row.ID)") }
                $Parts = $Row.ID -split '/'
                if ($Row.Name -ne $Parts[-1]) { $Problems.Add("name: $($Row.ID)") }
                if ($Row.ResourceGroup -ne $Parts[4]) { $Problems.Add("group: $($Row.ID)") }
                if ($Row.ID -match '^/subscriptions/(?:prod|nonprod)[-_]' -and $Row.Subscription -ne $Parts[2]) { $Problems.Add("subscription: $($Row.ID)") }
                continue
            }
            $Look = @($BilledIds | Where-Object { $P = $_ -split '/'; $P[-1] -ieq [string]$Row.Name -and $P[4] -ieq [string]$Row.ResourceGroup })
            if ($Look.Count -gt 0) { $Problems.Add("id differs from the billed id with the same name and group: $($Row.ID)") }
        }
        $RowIds = @(@($Rows) | ForEach-Object { [string]$_.ID })
        $BilledNoRow = @($BilledIds | Where-Object { $B = $_; @($RowIds | Where-Object { $_ -ieq $B }).Count -eq 0 }).Count
        $RowNoBill = @($RowIds | Where-Object { $R = $_; @($BilledIds | Where-Object { $_ -ieq $R }).Count -eq 0 }).Count
        [pscustomobject]@{ Matched = $Matched; BilledNoRow = $BilledNoRow; RowNoBill = $RowNoBill; Problems = @($Problems) }
    }

    # Section shape check, shared by the zip test and its negative controls: one problem line per field that breaks
    # the output contract (whole numbers stay whole JSON numbers, words come from the fixed lists).
    function Test-FabricCapacityShape($Rows)
    {
        $Problems = [System.Collections.Generic.List[string]]::new()
        $IsCount = { param($V, [switch]$Nullable) if ($null -eq $V) { return [bool]$Nullable } ($V -is [long] -or $V -is [int]) -and $V -ge 0 }
        foreach ($Row in @($Rows))
        {
            if ($Row.ID -isnot [string]) { $Problems.Add('ID not a string') }
            if ($Row.AirflowStatus -notin @('Collected', 'NoAirflowJobs', 'NoFabricAccess', 'CapacityNotLinked', 'ApiUnavailable', 'Throttled', 'Partial')) { $Problems.Add('AirflowStatus word') }
            if ($Row.ActiveHoursSource -notin @('ActivityLog', 'Unavailable')) { $Problems.Add('ActiveHoursSource word') }
            if (-not (& $IsCount $Row.WindowHours)) { $Problems.Add('WindowHours not a whole number') }
            # ConvertFrom-Json turns ISO date text into [datetime]; the file holds the text either way.
            foreach ($W in @('WindowStart', 'WindowEnd'))
            {
                if ($null -eq $Row.PSObject.Properties[$W]) { continue }
                $V = $Row.$W
                $Ok = if ($V -is [datetime]) { $V.TimeOfDay -eq [timespan]::Zero } else { [string]$V -match '^\d{4}-\d{2}-\d{2}T00:00:00Z$' }
                if (-not $Ok) { $Problems.Add("$W not a UTC ISO 8601 midnight") }
            }
            if (-not (& $IsCount $Row.ActiveHours -Nullable)) { $Problems.Add('ActiveHours not null or a whole number') }
            foreach ($Job in @($Row.AirflowJobs))
            {
                if ((@($Job.PSObject.Properties.Name) -join ',') -ne 'NodeSize,ShutdownPolicy,MinNodeCount,MaxNodeCount') { $Problems.Add('AirflowJobs keys') }
                if ($null -ne $Job.NodeSize -and $Job.NodeSize -cnotin @('Small', 'Large')) { $Problems.Add('NodeSize word') }
                if ($null -ne $Job.ShutdownPolicy -and $Job.ShutdownPolicy -cnotin @('AlwaysOn', 'OneHourInactivity')) { $Problems.Add('ShutdownPolicy word') }
                if (-not (& $IsCount $Job.MinNodeCount -Nullable)) { $Problems.Add('MinNodeCount not null or a whole number') }
                if (-not (& $IsCount $Job.MaxNodeCount -Nullable)) { $Problems.Add('MaxNodeCount not null or a whole number') }
            }
        }
        @($Problems)
    }

    function Invoke-Collector($Resources)
    {
        & $script:Collector -Sub $script:Subs -Resources $Resources -Task 'Processing' -ResourceIdDictionary $null
    }
}

AfterAll {
    Remove-Variable -Name FabricCapacitiesTest -Scope Global -ErrorAction SilentlyContinue
}

Describe 'FabricCapacities collector' {
    BeforeEach {
        Use-TestRoute (Get-TestDefaultRoute)
        Mock Start-Sleep { }
        Mock Invoke-AzRestMethod {
            $Target = if ($Uri) { [string]$Uri } else { [string]$Path }
            $State = $global:FabricCapacitiesTest
            $State.Calls.Add($Target)
            foreach ($Key in $State.Routes.Keys)
            {
                if ($Target -match $Key)
                {
                    $Value = $State.Routes[$Key]
                    if ($Value -is [System.Collections.IList])
                    {
                        $N = [int]$State.Hits[$Key]
                        $State.Hits[$Key] = $N + 1
                        return $Value[[math]::Min($N, $Value.Count - 1)]
                    }
                    return $Value
                }
            }
            return Get-TestResponse 404
        }
    }

    AfterEach {
        @($global:FabricCapacitiesTest.Calls | Where-Object { ($_ -replace '\?.*$', '') -match '(?i)/settings/?$' }).Count | Should -Be 0 -Because 'the job settings call returns environment variables and must never be made'
    }

    It 'writes one row per capacity with each Airflow job as fixed words and whole numbers' {
        $Rows = @(Invoke-Collector @((Get-TestCapacityRow)))
        $Rows.Count | Should -Be 1
        $Row = $Rows[0]
        $Row.ID | Should -Be "/subscriptions/$script:SubId/resourceGroups/rg-data-dev/providers/Microsoft.Fabric/capacities/capdatadev01"
        $Row.Name | Should -Be 'capdatadev01'
        $Row.ResourceGroup | Should -Be 'rg-data-dev'
        $Row.Subscription | Should -Be 'sub-data-dev'
        $Row.Location | Should -Be 'northeurope'
        $Row.SKU | Should -Be 'F64'
        $Row.State | Should -Be 'Active'
        $Row.AirflowStatus | Should -Be 'Collected'
        $Jobs = @($Row.AirflowJobs)
        $Jobs.Count | Should -Be 3
        $Jobs[0].NodeSize | Should -Be 'Large'
        $Jobs[0].ShutdownPolicy | Should -Be 'AlwaysOn'
        $Jobs[0].MinNodeCount | Should -Be 5
        $Jobs[0].MinNodeCount | Should -BeOfType [int]
        $Jobs[1].NodeSize | Should -Be 'Small'
        $Jobs[1].ShutdownPolicy | Should -Be 'OneHourInactivity'
        $Jobs[2].MaxNodeCount | Should -Be 8
        @($Jobs[0].Keys) | Should -Be @('NodeSize', 'ShutdownPolicy', 'MinNodeCount', 'MaxNodeCount')
    }

    It 'writes no workspace, job or template name or id, and no admin e-mail' {
        $Json = @(Invoke-Collector @((Get-TestCapacityRow))) | ConvertTo-Json -Depth 10
        foreach ($Text in @('Sales secret workspace', 'nightly-load', 'Secret template', 'admin@example.com', $script:WsGuid, $script:JobA, $script:CapGuid, 'poolTemplateName', 'displayName'))
        {
            $Json | Should -Not -Match ([regex]::Escape($Text))
        }
    }

    It 'gives NoAirflowJobs for a linked capacity whose workspaces hold no Airflow job' {
        $Routes = Get-TestDefaultRoute
        $Routes["/v1/workspaces/$script:WsGuid/apacheAirflowJobs$"] = Get-TestResponse 200 @{ value = @() }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'NoAirflowJobs'
        @($Row.AirflowJobs).Count | Should -Be 0
    }

    It 'links only the Fabric capacity of the same SKU when a Power BI capacity has the same name and region (<Case>)' -TestCases @(
        @{ Case = 'P alone'; Both = $false; Expect = 'CapacityNotLinked' }, @{ Case = 'P and F'; Both = $true; Expect = 'Collected' }
    ) {
        $PGuid = 'aaaaaaaa-0000-0000-0000-0000000000ff'
        $Caps = @(@{ id = $PGuid; displayName = 'capdatadev01'; sku = 'P1'; region = 'North Europe'; state = 'Active' })
        if ($Both) { $Caps += @{ id = $script:CapGuid; displayName = 'capdatadev01'; sku = 'F64'; region = 'North Europe'; state = 'Active' } }
        $Routes = Get-TestDefaultRoute
        $Routes['/v1/capacities$'] = Get-TestResponse 200 @{ value = $Caps }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be $Expect
        if ($Both) { @($Row.AirflowJobs).Count | Should -Be 3 }
    }

    It 'gives CapacityNotLinked when no Fabric capacity has the same name and region' {
        $Row = @(Invoke-Collector @((Get-TestCapacityRow -Location 'westeurope')))[0]
        $Row.AirflowStatus | Should -Be 'CapacityNotLinked'
        @($Row.AirflowJobs).Count | Should -Be 0
    }

    It 'gives <Word> when the Fabric capacity list answers <Code>' -TestCases @(
        @{ Code = 401; Word = 'NoFabricAccess' },
        @{ Code = 403; Word = 'NoFabricAccess' },
        @{ Code = 404; Word = 'ApiUnavailable' },
        @{ Code = 500; Word = 'ApiUnavailable' }
    ) {
        $Routes = Get-TestDefaultRoute
        $Routes['/v1/capacities$'] = Get-TestResponse $Code
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be $Word
        @($Row.AirflowJobs).Count | Should -Be 0
        @($global:FabricCapacitiesTest.Calls | Where-Object { $_ -match '/v1/workspaces' }).Count | Should -Be 0
    }

    It 'gives NoFabricAccess when no Fabric token can be had' {
        Mock Invoke-AzRestMethod { throw 'Failed to acquire token: AADSTS65001' } -ParameterFilter { [string]$Uri -match 'api.fabric' }
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'NoFabricAccess'
    }

    It 'waits for Retry-After on 429 and then reads the list' {
        $Routes = Get-TestDefaultRoute
        $Routes['/v1/capacities$'] = [System.Collections.ArrayList]@((Get-TestResponse -Code 429 -Headers @{ 'Retry-After' = '7' }), $Routes['/v1/capacities$'])
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'Collected'
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
    }

    It 'gives Throttled when every try answers 429' {
        $Routes = Get-TestDefaultRoute
        $Routes['/v1/capacities$'] = Get-TestResponse -Code 429 -Headers @{ 'Retry-After' = '30' }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'Throttled'
        Should -Invoke Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 30 }
    }

    It 'never fails the collector on a Retry-After date far from now (<When>)' -TestCases @(
        @{ When = 'year 9999'; Date = '9999-12-31T00:00:00Z' }, @{ When = 'year 1900'; Date = '1900-01-01T00:00:00Z' }
    ) {
        $Message = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
        $Message.Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([datetimeoffset]::Parse($Date, [System.Globalization.CultureInfo]::InvariantCulture))
        $Routes = Get-TestDefaultRoute
        $Routes['/v1/capacities$'] = [System.Collections.ArrayList]@((Get-TestResponse -Code 429 -Headers $Message.Headers), $Routes['/v1/capacities$'])
        Use-TestRoute $Routes
        { Invoke-Collector @((Get-TestCapacityRow)) } | Should -Not -Throw
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -BeIn @('Throttled', 'Collected')
    }

    It 'stops at once as Throttled, without calling early, when Retry-After asks for more than 60 seconds' {
        $Routes = Get-TestDefaultRoute
        $Routes['/v1/capacities$'] = Get-TestResponse -Code 429 -Headers @{ 'Retry-After' = '120' }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'Throttled'
        Should -Invoke Start-Sleep -Times 0 -Exactly
        @($global:FabricCapacitiesTest.Calls | Where-Object { $_ -match '/v1/capacities$' }).Count | Should -Be 1
    }

    It 'reads Retry-After from real HTTP response headers in the <Form> form' -TestCases @(
        @{ Form = 'delta'; Seconds = 9 },
        @{ Form = 'date'; Seconds = 20 }
    ) {
        $Message = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
        if ($Form -eq 'delta') { $Message.Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([TimeSpan]::FromSeconds($Seconds)) }
        else { $Message.Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([datetimeoffset]::UtcNow.AddSeconds($Seconds)) }
        $Routes = Get-TestDefaultRoute
        $Routes['/v1/capacities$'] = [System.Collections.ArrayList]@((Get-TestResponse -Code 429 -Headers $Message.Headers), $Routes['/v1/capacities$'])
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'Collected'
        $Low = $Seconds - 2
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -ge $Low -and $Seconds -le 20 }
    }

    It 'gives ApiUnavailable when the beta compute call is gone for every job' {
        $Routes = Get-TestDefaultRoute
        foreach ($Job in @($script:JobA, $script:JobB, $script:JobC)) { $Routes["apacheAirflowJobs/$Job/environment/compute\?beta=true$"] = Get-TestResponse 404 }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'ApiUnavailable'
        @($Row.AirflowJobs).Count | Should -Be 0
    }

    It 'gives Partial and keeps the jobs it read when some jobs cannot be read' {
        $Routes = Get-TestDefaultRoute
        $Routes["apacheAirflowJobs/$script:JobB/environment/compute\?beta=true$"] = Get-TestResponse 403
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'Partial'
        @($Row.AirflowJobs).Count | Should -Be 2
    }

    It 'writes null for a pool word that is not a plain Fabric word and for a count that is not a number' {
        $Routes = Get-TestDefaultRoute
        $Routes["apacheAirflowJobs/$script:JobA/environment/compute\?beta=true$"] = Get-TestResponse 200 @{ nodeSize = 'my secret size'; shutdownPolicy = 'AlwaysOn'; computeScalability = @{ minNodeCount = 'five'; maxNodeCount = 5 } }
        $Routes["apacheAirflowJobs/$script:JobB/environment/compute\?beta=true$"] = Get-TestResponse 200 @{ nodeSize = 'Medium'; shutdownPolicy = 'alwayson'; computeScalability = @{ minNodeCount = -1; maxNodeCount = 3.5 } }
        Use-TestRoute $Routes
        $Job = @(@(Invoke-Collector @((Get-TestCapacityRow)))[0].AirflowJobs)[0]
        $Job.NodeSize | Should -BeNullOrEmpty
        $Job.MinNodeCount | Should -BeNullOrEmpty
        $Job.MaxNodeCount | Should -Be 5
        $Other = @(@(Invoke-Collector @((Get-TestCapacityRow)))[0].AirflowJobs)[1]
        $Other.NodeSize | Should -BeNullOrEmpty -Because 'only the documented words Small and Large are kept'
        $Other.ShutdownPolicy | Should -BeNullOrEmpty -Because 'the words are matched exactly'
        $Other.MinNodeCount | Should -BeNullOrEmpty -Because 'a node count is 0 or more'
        $Other.MaxNodeCount | Should -BeNullOrEmpty -Because 'a node count is a whole number'
    }

    It 'counts a compute answer of 200 with no pool fields as a job not read (<Which>)' -TestCases @(
        @{ Which = 'empty object'; Content = '{}' }, @{ Which = 'empty body'; Content = '' }, @{ Which = 'error body'; Content = '{"error":"changed"}' }, @{ Which = 'a list'; Content = '[1,2]' }
    ) {
        $Routes = Get-TestDefaultRoute
        $Routes["apacheAirflowJobs/$script:JobB/environment/compute\?beta=true$"] = [pscustomobject]@{ StatusCode = 200; Content = $Content; Headers = $null }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'Partial'
        @($Row.AirflowJobs).Count | Should -Be 2
    }

    It 'gives NoFabricAccess when the linked capacity has no workspace the identity can see' {
        $Routes = Get-TestDefaultRoute
        $Routes['/v1/workspaces$'] = Get-TestResponse 200 @{ value = @(@{ id = 'dddddddd-0000-0000-0000-000000000009'; displayName = 'Other capacity'; capacityId = 'eeeeeeee-0000-0000-0000-000000000009' }) }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'NoFabricAccess'
    }

    It 'gives ApiUnavailable when a list answers 200 without a value list (<Which>)' -TestCases @(
        @{ Which = 'capacities'; Key = '/v1/capacities$' },
        @{ Which = 'workspaces'; Key = '/v1/workspaces$' },
        @{ Which = 'jobs'; Key = 'jobs' }
    ) {
        $Routes = Get-TestDefaultRoute
        if ($Key -eq 'jobs') { $Key = "/v1/workspaces/$script:WsGuid/apacheAirflowJobs$" }
        $Routes[$Key] = Get-TestResponse 200 @{ error = 'changed' }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'ApiUnavailable'
    }

    It 'gives ApiUnavailable when a list answers 200 with value null (<Which>)' -TestCases @(
        @{ Which = 'capacities' }, @{ Which = 'workspaces' }, @{ Which = 'jobs' }
    ) {
        $Routes = Get-TestDefaultRoute
        $Key = switch ($Which) { 'capacities' { '/v1/capacities$' } 'workspaces' { '/v1/workspaces$' } default { "/v1/workspaces/$script:WsGuid/apacheAirflowJobs$" } }
        $Routes[$Key] = [pscustomobject]@{ StatusCode = 200; Content = '{"value":null}'; Headers = $null }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'ApiUnavailable'
    }

    It 'makes no more Fabric calls once Fabric has answered Throttled' {
        $Routes = Get-TestDefaultRoute
        foreach ($Job in @($script:JobA, $script:JobB, $script:JobC)) { $Routes["apacheAirflowJobs/$Job/environment/compute\?beta=true$"] = Get-TestResponse -Code 429 -Headers @{ 'Retry-After' = '2' } }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'Throttled'
        @($global:FabricCapacitiesTest.Calls | Where-Object { $_ -match '/environment/compute' }).Count | Should -Be 4 -Because 'the first job call tries 4 times, the other two are not made'
        $Row.ActiveHoursSource | Should -Be 'ActivityLog' -Because 'the Azure calls are not Fabric calls'
    }

    It 'keeps the pages read before a later page answers <Code> (<Which>), and ends Partial' -TestCases @(
        @{ Which = 'capacities'; Code = 403 }, @{ Which = 'capacities'; Code = 500 },
        @{ Which = 'workspaces'; Code = 403 }, @{ Which = 'workspaces'; Code = 500 },
        @{ Which = 'jobs'; Code = 403 }, @{ Which = 'jobs'; Code = 0 }
    ) {
        $Routes = Get-TestDefaultRoute
        $Key = switch ($Which) { 'capacities' { '/v1/capacities$' } 'workspaces' { '/v1/workspaces$' } default { "/v1/workspaces/$script:WsGuid/apacheAirflowJobs$" } }
        $First = $Routes[$Key].Content | ConvertFrom-Json
        $Next = 'https://api.fabric.microsoft.com/v1/page2-' + $Which
        $Routes[$Key] = [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($First.value); continuationUri = $Next } | ConvertTo-Json -Depth 10 -Compress); Headers = $null }
        $Page2 = if ($Code -eq 0) { Get-TestResponse 200 @{ error = 'changed' } } elseif ($Code -eq 429) { Get-TestResponse -Code 429 -Headers @{ 'Retry-After' = '1' } } else { Get-TestResponse $Code }
        $Ordered = [ordered]@{ ('/v1/page2-' + $Which + '$') = $Page2 }
        foreach ($K in $Routes.Keys) { $Ordered[$K] = $Routes[$K] }
        Use-TestRoute $Ordered
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'Partial'
        @($Row.AirflowJobs).Count | Should -BeGreaterThan 0 -Because 'the jobs listed on the pages before the failed page are still read'
    }

    It 'stops all Fabric calls when a later capacity page answers Throttled, so the row is Throttled' {
        $Routes = Get-TestDefaultRoute
        $First = $Routes['/v1/capacities$'].Content | ConvertFrom-Json
        $Routes['/v1/capacities$'] = [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($First.value); continuationUri = 'https://api.fabric.microsoft.com/v1/page2-capacities' } | ConvertTo-Json -Depth 10 -Compress); Headers = $null }
        $Ordered = [ordered]@{ '/v1/page2-capacities$' = (Get-TestResponse -Code 429 -Headers @{ 'Retry-After' = '1' }) }
        foreach ($K in $Routes.Keys) { $Ordered[$K] = $Routes[$K] }
        Use-TestRoute $Ordered
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'Throttled'
        @($global:FabricCapacitiesTest.Calls | Where-Object { $_ -match '/v1/workspaces' }).Count | Should -Be 0
    }

    It 'prints no workspace or job id on the debug or verbose streams under -Debug' {
        Mock Invoke-AzRestMethod {
            $Target = if ($Uri) { [string]$Uri } else { [string]$Path }
            Write-Debug ('Az request ' + $Target)
            Write-Verbose ('Az request ' + $Target)
            $State = $global:FabricCapacitiesTest
            $State.Calls.Add($Target)
            foreach ($Key in $State.Routes.Keys) { if ($Target -match $Key) { return $State.Routes[$Key] } }
            return Get-TestResponse 404
        }
        $DebugPreference = 'Continue'
        $VerbosePreference = 'Continue'
        $All = @(& { Invoke-Collector @((Get-TestCapacityRow)) } *>&1 | ForEach-Object { [string]$_ })
        $DebugPreference = 'SilentlyContinue'
        $VerbosePreference = 'SilentlyContinue'
        ($All -join "`n") | Should -Not -Match ([regex]::Escape($script:WsGuid))
        ($All -join "`n") | Should -Not -Match ([regex]::Escape($script:JobA))
        @($global:FabricCapacitiesTest.Calls | Where-Object { $_ -match [regex]::Escape($script:JobA) }).Count | Should -Be 1 -Because 'the call itself is still made'
    }

    It 'link check: passes a masked row whose ID is its billed id' {
        $Id = '/subscriptions/prod_a/resourcegroups/nonprod_b/providers/microsoft.fabric/capacities/nonprod_c'
        $Check = Test-FabricCapacityLink -Rows @([pscustomobject]@{ ID = $Id; Name = 'nonprod_c'; ResourceGroup = 'nonprod_b'; Subscription = 'prod_a' }) -BilledIds @($Id)
        $Check.Matched | Should -Be 1
        $Check.Problems | Should -BeNullOrEmpty
    }

    It 'link check (negative control): fails a row whose ID holds a wrong token while its name and group match a billed id' {
        $Billed = '/subscriptions/prod_a/resourcegroups/nonprod_b/providers/microsoft.fabric/capacities/nonprod_c'
        $Wrong = '/subscriptions/prod_x/resourcegroups/nonprod_b/providers/microsoft.fabric/capacities/nonprod_c'
        $Check = Test-FabricCapacityLink -Rows @([pscustomobject]@{ ID = $Wrong; Name = 'nonprod_c'; ResourceGroup = 'nonprod_b'; Subscription = 'prod_x' }) -BilledIds @($Billed)
        @($Check.Problems).Count | Should -Be 1
    }

    It 'link check (negative control): fails a row whose ID differs from its billed id in case only' {
        $Billed = '/subscriptions/prod_a/resourcegroups/nonprod_b/providers/microsoft.fabric/capacities/nonprod_c'
        $Check = Test-FabricCapacityLink -Rows @([pscustomobject]@{ ID = $Billed.ToUpperInvariant(); Name = 'NONPROD_C'; ResourceGroup = 'NONPROD_B'; Subscription = 'PROD_A' }) -BilledIds @($Billed)
        @($Check.Problems) | Should -Contain ('case: ' + $Billed.ToUpperInvariant())
    }

    It 'link check: counts billed ids with no row and rows with no bill next to a matched pair' {
        $A = '/subscriptions/prod_a/resourcegroups/g/providers/microsoft.fabric/capacities/one'
        $Rows = @([pscustomobject]@{ ID = $A; Name = 'one'; ResourceGroup = 'g'; Subscription = 'prod_a' }, [pscustomobject]@{ ID = '/subscriptions/prod_a/resourcegroups/h/providers/microsoft.fabric/capacities/idle'; Name = 'idle'; ResourceGroup = 'h'; Subscription = 'prod_a' })
        $Check = Test-FabricCapacityLink -Rows $Rows -BilledIds @($A, '/subscriptions/prod_a/resourcegroups/g/providers/microsoft.fabric/capacities/gone')
        $Check.Matched | Should -Be 1
        $Check.BilledNoRow | Should -Be 1
        $Check.RowNoBill | Should -Be 1
        $Check.Problems | Should -BeNullOrEmpty
    }

    It 'link check: counts a whole side lost (no row for any bill, or no bill for any row)' {
        $A = '/subscriptions/prod_a/resourcegroups/g/providers/microsoft.fabric/capacities/one'
        $NoRows = Test-FabricCapacityLink -Rows @() -BilledIds @($A)
        $NoRows.BilledNoRow | Should -Be 1
        $NoBill = Test-FabricCapacityLink -Rows @([pscustomobject]@{ ID = $A; Name = 'one'; ResourceGroup = 'g'; Subscription = 'prod_a' }) -BilledIds @()
        $NoBill.RowNoBill | Should -Be 1
    }

    It 'shape check: passes the collector''s own rows' {
        $Json = @(Invoke-Collector @((Get-TestCapacityRow))) | ConvertTo-Json -Depth 20
        Test-FabricCapacityShape @($Json | ConvertFrom-Json) | Should -BeNullOrEmpty
    }

    It 'shape check (negative control): fails <Field> = <Shown>' -TestCases @(
        @{ Field = 'ActiveHours'; Shown = '"696"'; Json = '"696"' },
        @{ Field = 'ActiveHours'; Shown = '3.5'; Json = '3.5' },
        @{ Field = 'MaxNodeCount'; Shown = '"5"'; Json = '"5"' },
        @{ Field = 'MaxNodeCount'; Shown = '-1'; Json = '-1' },
        @{ Field = 'MinNodeCount'; Shown = '"5"'; Json = '"5"' },
        @{ Field = 'NodeSize'; Shown = 'Medium'; Json = '"Medium"' }
    ) {
        $Job = '{"NodeSize":"Large","ShutdownPolicy":"AlwaysOn","MinNodeCount":5,"MaxNodeCount":5}'
        $Row = '{"ID":"/subscriptions/s/resourcegroups/g/providers/microsoft.fabric/capacities/c","AirflowStatus":"Collected","ActiveHoursSource":"ActivityLog","WindowHours":720,"ActiveHours":696,"AirflowJobs":[@@JOB@@]}'
        if ($Field -eq 'ActiveHours') { $Row = $Row -replace '"ActiveHours":696', ('"ActiveHours":' + $Json) }
        else { $Job = $Job -replace ('"' + $Field + '":[^,}]+'), ('"' + $Field + '":' + $Json) }
        $Parsed = ($Row -creplace '@@JOB@@', $Job) | ConvertFrom-Json
        @(Test-FabricCapacityShape @($Parsed)).Count | Should -BeGreaterThan 0
    }

    It 'writes Gregorian dates with : in the activity-log filter whatever the host culture (<Culture>)' -TestCases @(
        @{ Culture = 'th-TH' }, @{ Culture = 'fi-FI' }, @{ Culture = 'da-DK' }
    ) {
        $Old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new($Culture)
            $null = Invoke-Collector @((Get-TestCapacityRow))
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $Old }
        $LogCall = [uri]::UnescapeDataString(@($global:FabricCapacitiesTest.Calls | Where-Object { $_ -match 'eventtypes' })[0])
        $Expect = (Get-Date).Date.AddDays(-31).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $LogCall | Should -Match ([regex]::Escape("eventTimestamp ge '$Expect" + 'T00:00:00Z'))
    }

    It 'link check: a billed id with no row (deleted in the window) is no problem' {
        $Check = Test-FabricCapacityLink -Rows @([pscustomobject]@{ ID = '/subscriptions/prod_a/resourcegroups/g/providers/microsoft.fabric/capacities/other'; Name = 'other'; ResourceGroup = 'g'; Subscription = 'prod_a' }) -BilledIds @('/subscriptions/prod_a/resourcegroups/g/providers/microsoft.fabric/capacities/gone')
        $Check.Matched | Should -Be 0
        $Check.Problems | Should -BeNullOrEmpty
    }

    It 'reads a capacity whose name holds the word settings' {
        $Routes = Get-TestDefaultRoute
        $Routes['/v1/capacities$'] = Get-TestResponse 200 @{ value = @(@{ id = $script:CapGuid; displayName = 'capsettings'; sku = 'F64'; region = 'North Europe' }) }
        $Routes['/resources\?api-version=2021-04-01&\$expand=createdTime'] = Get-TestResponse 200 @{ value = @(@{ id = "/subscriptions/$script:SubId/resourceGroups/rg-data-dev/providers/Microsoft.Fabric/capacities/capsettings"; createdTime = '2025-01-01T00:00:00Z' }) }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow -Name 'capsettings')))[0]
        $Row.AirflowStatus | Should -Be 'Collected'
        $Row.ActiveHoursSource | Should -Be 'ActivityLog'
    }

    It 'tells the person running the tool, by counts only, when Airflow settings were not read' {
        Mock Write-Log { }
        $Routes = Get-TestDefaultRoute
        $Routes['/v1/capacities$'] = Get-TestResponse 403
        Use-TestRoute $Routes
        $null = Invoke-Collector @((Get-TestCapacityRow))
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Severity -eq 'Warning' -and $Message -match 'NoFabricAccess 1' -and $Message -notmatch 'capdatadev01|rg-data-dev' }
    }

    It 'writes no warning line when every capacity was read' {
        Mock Write-Log { }
        $null = Invoke-Collector @((Get-TestCapacityRow))
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Severity -eq 'Warning' }
    }

    It 'says on every run that read a capacity that workspaces the identity cannot see are not counted' {
        Mock Write-Log { }
        $null = Invoke-Collector @((Get-TestCapacityRow))
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Severity -eq 'Info' -and $Message -match 'not counted' -and $Message -match 'Viewer on every workspace' -and $Message -notmatch 'capdatadev01|rg-data-dev' }
    }

    It 'writes no such note when no capacity was read' {
        Mock Write-Log { }
        $Routes = Get-TestDefaultRoute
        $Routes['/v1/capacities$'] = Get-TestResponse 403
        Use-TestRoute $Routes
        $null = Invoke-Collector @((Get-TestCapacityRow))
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Severity -eq 'Info' }
    }

    It 'makes no call at all when no Fabric capacity is in scope' {
        $Other = [pscustomobject]@{ id = "/subscriptions/$script:SubId/resourceGroups/rg/providers/Microsoft.Databricks/workspaces/dbw"; TYPE = 'microsoft.databricks/workspaces'; NAME = 'dbw' }
        $Rows = @(Invoke-Collector @($Other))
        $Rows.Count | Should -Be 0
        Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly
    }

    It 'counts every hour of the window for an Active capacity with no pause or resume' {
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.ActiveHoursSource | Should -Be 'ActivityLog'
        $Row.WindowHours | Should -BeOfType [int]
        $Row.WindowHours | Should -Be 720 -Because 'the window is 30 UTC days, whatever the host time zone'
        $Row.ActiveHours | Should -Be 720 -Because 'an Active capacity with no pause or resume ran every hour of the window'
    }

    It 'writes the window start and end on every row as UTC ISO 8601 text, 720 hours apart, whatever the host culture' {
        $Old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('th-TH')
            $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $Old }
        $Inv = [System.Globalization.CultureInfo]::InvariantCulture
        $Row.WindowStart | Should -BeOfType [string]
        $Row.WindowStart | Should -Be ((Get-Date).Date.AddDays(-31).ToString('yyyy-MM-dd', $Inv) + 'T00:00:00Z')
        $Row.WindowEnd | Should -Be ((Get-Date).Date.AddDays(-1).ToString('yyyy-MM-dd', $Inv) + 'T00:00:00Z')
        $Span = [datetimeoffset]::Parse($Row.WindowEnd, $Inv) - [datetimeoffset]::Parse($Row.WindowStart, $Inv)
        $Span.TotalHours | Should -Be $Row.WindowHours
    }

    It 'takes the window from the same local dates the consumption read sends, read as UTC days' {
        $null = Invoke-Collector @((Get-TestCapacityRow))
        $LogCall = @($global:FabricCapacitiesTest.Calls | Where-Object { $_ -match 'eventtypes' })[0]
        $Expect = (Get-Date).Date.AddDays(-31).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) + 'T00:00:00Z'
        [uri]::UnescapeDataString($LogCall) | Should -Match ([regex]::Escape("eventTimestamp ge '$Expect'"))
    }

    It 'counts 0 hours for a Paused capacity with no pause or resume' {
        $Row = @(Invoke-Collector @((Get-TestCapacityRow -State 'Paused')))[0]
        $Row.ActiveHours | Should -Be 0
        $Row.ActiveHoursSource | Should -Be 'ActivityLog'
    }

    It 'counts the hours between a resume and a suspend inside the window' {
        $Start = [datetime]::SpecifyKind((Get-Date).Date.AddDays(-31), [System.DateTimeKind]::Utc)
        $Routes = Get-TestDefaultRoute
        $Routes['eventtypes/management/values'] = Get-TestResponse 200 @{ value = @(
                @{ eventTimestamp = $Start.AddHours(10).ToString('o'); operationName = @{ value = 'Microsoft.Fabric/capacities/resume/action' }; status = @{ value = 'Started' } },
                @{ eventTimestamp = $Start.AddHours(10).ToString('o'); operationName = @{ value = 'Microsoft.Fabric/capacities/resume/action' }; status = @{ value = 'Succeeded' } },
                @{ eventTimestamp = $Start.AddHours(34).ToString('o'); operationName = @{ value = 'Microsoft.Fabric/capacities/suspend/action' }; status = @{ value = 'Succeeded' } },
                @{ eventTimestamp = $Start.AddHours(40).ToString('o'); operationName = @{ value = 'Microsoft.Fabric/capacities/write' }; status = @{ value = 'Succeeded' } }
            )
        }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow -State 'Paused')))[0]
        $Row.ActiveHours | Should -Be 24
        $Row.ActiveHoursSource | Should -Be 'ActivityLog'
        $LogCall = @($global:FabricCapacitiesTest.Calls | Where-Object { $_ -match 'eventtypes' })[0]
        $LogCall | Should -Match ('^/subscriptions/' + $script:SubId + '/providers/Microsoft.Insights/eventtypes/management/values\?')
        $LogCall | Should -Match ([regex]::Escape('$select=eventTimestamp,operationName,status'))
    }

    It 'counts a capacity suspended inside the window as active up to the suspend' {
        $Start = [datetime]::SpecifyKind((Get-Date).Date.AddDays(-31), [System.DateTimeKind]::Utc)
        $Routes = Get-TestDefaultRoute
        $Routes['eventtypes/management/values'] = Get-TestResponse 200 @{ value = @(
                @{ eventTimestamp = $Start.AddHours(48).ToString('o'); operationName = @{ value = 'Microsoft.Fabric/capacities/suspend/action' }; status = @{ value = 'Succeeded' } }
            )
        }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow -State 'Paused')))[0]
        $Row.ActiveHours | Should -Be 48
    }

    It 'gives ActiveHoursSource Unavailable and null hours when the activity log cannot be read' {
        $Routes = Get-TestDefaultRoute
        $Routes['eventtypes/management/values'] = Get-TestResponse 403
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.ActiveHoursSource | Should -Be 'Unavailable'
        $Row.ActiveHours | Should -BeNullOrEmpty
        $Row.AirflowStatus | Should -Be 'Collected'
    }

    It 'counts a capacity made inside the window from its creation time' {
        $Start = [datetime]::SpecifyKind((Get-Date).Date.AddDays(-31), [System.DateTimeKind]::Utc)
        $Routes = Get-TestDefaultRoute
        $Routes['/resources\?api-version=2021-04-01&\$expand=createdTime'] = Get-TestResponse 200 @{ value = @(@{ id = "/subscriptions/$script:SubId/resourceGroups/rg-data-dev/providers/Microsoft.Fabric/capacities/capdatadev01"; createdTime = $Start.AddHours(700).ToString('o') }) }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.ActiveHours | Should -Be ($Row.WindowHours - 700)
        $Row.ActiveHoursSource | Should -Be 'ActivityLog'
        $Call = @($global:FabricCapacitiesTest.Calls | Where-Object { $_ -match 'expand=createdTime' })[0]
        $Call | Should -Match ('^/subscriptions/' + $script:SubId + '/resourceGroups/rg-data-dev/resources\?')
    }

    It 'ignores the events of an earlier capacity with the same id, deleted and made again inside the window (<Old>)' -TestCases @(
        @{ Old = 'suspend'; Op = 'Microsoft.Fabric/capacities/suspend/action' }, @{ Old = 'resume'; Op = 'Microsoft.Fabric/capacities/resume/action' }
    ) {
        $Start = [datetime]::SpecifyKind((Get-Date).Date.AddDays(-31), [System.DateTimeKind]::Utc)
        $Routes = Get-TestDefaultRoute
        $Routes['/resources\?api-version=2021-04-01&\$expand=createdTime'] = Get-TestResponse 200 @{ value = @(@{ id = "/subscriptions/$script:SubId/resourceGroups/rg-data-dev/providers/Microsoft.Fabric/capacities/capdatadev01"; createdTime = $Start.AddHours(480).ToString('o') }) }
        $Routes['eventtypes/management/values'] = Get-TestResponse 200 @{ value = @(
                @{ eventTimestamp = $Start.AddHours(240).ToString('o'); operationName = @{ value = $Op }; status = @{ value = 'Succeeded' } }
            )
        }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.ActiveHours | Should -Be 240 -Because 'the new capacity ran from its creation at hour 480 to the window end at 720'
    }

    It 'counts 0 hours for a capacity made after the window' {
        $Routes = Get-TestDefaultRoute
        $Routes['/resources\?api-version=2021-04-01&\$expand=createdTime'] = Get-TestResponse 200 @{ value = @(@{ id = "/subscriptions/$script:SubId/resourceGroups/rg-data-dev/providers/Microsoft.Fabric/capacities/capdatadev01"; createdTime = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o') }) }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.ActiveHours | Should -Be 0
    }

    It 'gives ActiveHoursSource Unavailable when the creation time cannot be read' {
        $Routes = Get-TestDefaultRoute
        $Routes['/resources\?api-version=2021-04-01&\$expand=createdTime'] = Get-TestResponse 403
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.ActiveHoursSource | Should -Be 'Unavailable'
        $Row.ActiveHours | Should -BeNullOrEmpty
    }

    It 'gives ActiveHoursSource Unavailable for a state it cannot read and no events' {
        $Row = @(Invoke-Collector @((Get-TestCapacityRow -State 'Provisioning')))[0]
        $Row.ActiveHoursSource | Should -Be 'Unavailable'
        $Row.ActiveHours | Should -BeNullOrEmpty
    }

    It 'never throws on a Fabric error, so the collector is never counted as failed' {
        Mock Invoke-AzRestMethod { throw 'network is down' }
        { Invoke-Collector @((Get-TestCapacityRow)) } | Should -Not -Throw
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'ApiUnavailable'
        $Row.ActiveHoursSource | Should -Be 'Unavailable'
    }

    It 'follows a continuation page on the Fabric host only' {
        $Routes = [ordered]@{}
        $Routes['/v1/capacities\?continuationToken=p2$'] = Get-TestResponse 200 @{ value = @(@{ id = $script:CapGuid; displayName = 'capdatadev01'; sku = 'F64'; region = 'North Europe' }) }
        $Defaults = Get-TestDefaultRoute
        $Routes['/v1/capacities$'] = Get-TestResponse 200 @{ value = @(); continuationUri = 'https://api.fabric.microsoft.com/v1/capacities?continuationToken=p2' }
        $Routes['/v1/workspaces$'] = Get-TestResponse 200 @{ value = @(@{ id = $script:WsGuid; capacityId = $script:CapGuid }); continuationUri = 'https://evil.example.com/v1/workspaces?x=1' }
        foreach ($Key in $Defaults.Keys) { if (-not $Routes.Contains($Key)) { $Routes[$Key] = $Defaults[$Key] } }
        Use-TestRoute $Routes
        $Row = @(Invoke-Collector @((Get-TestCapacityRow)))[0]
        $Row.AirflowStatus | Should -Be 'Partial'
        @($Row.AirflowJobs).Count | Should -Be 3 -Because 'the jobs of the workspaces listed before the list stopped are still read'
        @($global:FabricCapacitiesTest.Calls | Where-Object { $_ -match 'capacities\?continuationToken=p2' }).Count | Should -Be 1
        @($global:FabricCapacitiesTest.Calls | Where-Object { $_ -match 'evil' }).Count | Should -Be 0
    }

    It 'writes a row that the inventory JSON writer keeps as JSON numbers, strings and lists' {
        $Json = @(Invoke-Collector @((Get-TestCapacityRow))) | ConvertTo-Json -Depth 99 -Compress
        $Json | Should -Match '"MinNodeCount":5'
        $Json | Should -Match '"WindowHours":\d+'
        $Json | Should -Match '"AirflowJobs":\['
        $Json | Should -Match '"SKU":"F64"'
    }
}

# The same section in a real report zip (plain or -Obfuscate), as the other zip-backed tests read one:
# $env:TEST_ZIP_PATH, else the newest ResourcesReport_*.zip in Tests/. Skipped when there is none, or when the zip
# holds no Fabric capacity.
Describe 'FabricCapacities in a report zip' {
    BeforeAll {
        $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
        {
            Get-ChildItem -Path $PSScriptRoot -Filter 'ResourcesReport_*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        $script:ZipRows = @()
        $script:ZipConsumption = @()
        $script:ZipSectionJson = ''
        if (-not [string]::IsNullOrEmpty($ZipPath) -and (Test-Path -LiteralPath $ZipPath))
        {
            $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
            $script:ZipExtract = Join-Path $TmpBase ('FabricZipTest_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            Expand-Archive -LiteralPath $ZipPath -DestinationPath $script:ZipExtract -Force
            foreach ($Inner in @(Get-ChildItem -Path $script:ZipExtract -Recurse -Filter '*.zip'))
            {
                Expand-Archive -LiteralPath $Inner.FullName -DestinationPath (Join-Path $script:ZipExtract ('inner_' + $Inner.BaseName)) -Force
            }
            foreach ($Inv in @(Get-ChildItem -Path $script:ZipExtract -Recurse -Filter 'Inventory_*.json'))
            {
                $Parsed = Get-Content -LiteralPath $Inv.FullName -Raw | ConvertFrom-Json
                if ($Parsed.PSObject.Properties.Name -contains 'FabricCapacities')
                {
                    $script:ZipRows += @($Parsed.FabricCapacities | Where-Object { $null -ne $_ })
                    $script:ZipSectionJson += ($Parsed.FabricCapacities | ConvertTo-Json -Depth 20 -Compress)
                }
            }
            foreach ($Csv in @(Get-ChildItem -Path $script:ZipExtract -Recurse -Filter 'Consumption_*.csv'))
            {
                $script:ZipConsumption += @(Import-Csv -LiteralPath $Csv.FullName | Select-Object -ExpandProperty ResourceId)
            }
        }
    }

    AfterAll {
        if ($script:ZipExtract -and (Test-Path -LiteralPath $script:ZipExtract)) { Remove-Item -LiteralPath $script:ZipExtract -Recurse -Force }
    }

    It 'keeps every row in the section shape, with only fixed words and whole numbers in AirflowJobs' {
        if ($script:ZipRows.Count -eq 0) { Set-ItResult -Skipped -Because 'no Fabric capacity in this zip'; return }
        Test-FabricCapacityShape $script:ZipRows | Should -BeNullOrEmpty
    }

    It 'holds no e-mail address in the section' {
        if ($script:ZipRows.Count -eq 0) { Set-ItResult -Skipped -Because 'no Fabric capacity in this zip'; return }
        $script:ZipSectionJson | Should -Not -Match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    }

    It 'gives each row that is billed the same id string as its consumption ResourceId, and Name, ResourceGroup and Subscription from that id' {
        $Billed = @($script:ZipConsumption | Where-Object { $_ -match '(?i)/providers/microsoft\.fabric/capacities/[^/]+$' } | Sort-Object -Unique)
        if ($script:ZipRows.Count -eq 0 -and $Billed.Count -eq 0) { Set-ItResult -Skipped -Because 'no Fabric capacity row and no Fabric bill in this zip'; return }
        $Check = Test-FabricCapacityLink -Rows $script:ZipRows -BilledIds $Billed
        $Check.Problems | Should -BeNullOrEmpty
        if ($Check.BilledNoRow -gt 0 -or $Check.RowNoBill -gt 0) { Set-ItResult -Inconclusive -Because ('{0} billed id(s) with no row (a capacity deleted in the window), {1} row(s) with no bill (not billed in the window); {2} matched. No row shares name and group with a billed id it does not match.' -f $Check.BilledNoRow, $Check.RowNoBill, $Check.Matched) }
    }
}
