[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ResourceIdDictionary', Justification = 'Every collector takes the same parameters; masking is done for this section by the shared loop in ResourceInventory.ps1.')]
param($Sub, $Resources, $Task, $ResourceIdDictionary)

# Microsoft Fabric capacities (microsoft.fabric/capacities): the capacity's SKU, how many hours it ran
# in the consumption window (from the Azure activity log), and each Apache Airflow job's pool settings
# (from the Fabric REST API), so the bill's Airflow CU-hours can be priced without a user guess.
#
# What is never read: capacity admin e-mails, environment variables (no .../settings call is ever made) and
# Airflow overrides. Workspace and job ids are used only to build the next Fabric call; workspace, job and pool
# template names come back in those answers and are ignored. None of them is written or logged.
# Each Airflow job is one list entry holding only fixed Fabric words and whole numbers.
#
# A Fabric error never fails the collector: it becomes one AirflowStatus word on the capacity row
# (Collected, NoAirflowJobs, NoFabricAccess, CapacityNotLinked, ApiUnavailable, Throttled, Partial).
# The Airflow compute call is a Fabric beta API. The caller needs Fabric capacity admin or contributor
# (to link the Azure capacity to its Fabric capacity) and Viewer on the workspaces that hold Airflow jobs.

if ($Task -eq 'Processing')
{
    $FabricCapacities = $Resources | Where-Object { $_.TYPE -eq 'microsoft.fabric/capacities' }

    if ($FabricCapacities)
    {
        $FabricApi = 'https://api.fabric.microsoft.com'
        $ArmHost = 'management.azure.com'
        $MaxRetries = 3
        $MaxWaitSeconds = 60
        $MaxPages = 100
        # Once Fabric has answered Throttled, no more Fabric calls are made in this run, so a throttled tenant
        # costs at most one call's waits, not one per workspace and job.
        $FabricState = @{ Throttled = $false }

        # One GET. Returns Status 'Ok' with the parsed body, or one status word. 401/403 -> NoFabricAccess,
        # 429 -> wait as Retry-After says (delta or date form) and try again, up to $MaxRetries times; a wait
        # over $MaxWaitSeconds is not cut short: the call stops at once as Throttled. Any other answer, or a
        # body that is not JSON, -> ApiUnavailable. A call whose path ends in /settings is refused before it is
        # made, so the Airflow job settings call (it returns environment variables) can never be reached.
        function Invoke-FabricCapacityGet([hashtable]$Request)
        {
            $IsFabric = $Request.ContainsKey('Uri')
            $Target = if ($IsFabric) { ([uri][string]$Request.Uri).AbsolutePath } else { ([string]$Request.Path -split '\?', 2)[0] }
            if ($Target -match '(?i)/settings/?$') { return [pscustomobject]@{ Status = 'ApiUnavailable'; Body = $null } }
            if ($IsFabric -and $FabricState.Throttled) { return [pscustomobject]@{ Status = 'Throttled'; Body = $null } }

            for ($Attempt = 0; $Attempt -le $MaxRetries; $Attempt++)
            {
                try
                {
                    # Debug and verbose off: under -Debug, Az would print the request URI, which holds workspace and job ids.
                    $Response = Invoke-AzRestMethod @Request -Method GET -ErrorAction Stop -Debug:$false -Verbose:$false 5>$null 4>$null
                }
                catch
                {
                    $Word = if ($_.Exception.Message -match '(?i)token|AADSTS|login|sign.?in|unauthori[sz]ed|forbidden|credential') { 'NoFabricAccess' } else { 'ApiUnavailable' }
                    return [pscustomobject]@{ Status = $Word; Body = $null }
                }

                $Code = [int]$Response.StatusCode
                if ($Code -ge 200 -and $Code -lt 300)
                {
                    try { $Body = $Response.Content | ConvertFrom-Json -ErrorAction Stop }
                    catch { return [pscustomobject]@{ Status = 'ApiUnavailable'; Body = $null } }
                    return [pscustomobject]@{ Status = 'Ok'; Body = $Body }
                }
                if ($Code -eq 401 -or $Code -eq 403) { return [pscustomobject]@{ Status = 'NoFabricAccess'; Body = $null } }
                if ($Code -ne 429 -or $Attempt -eq $MaxRetries) { break }

                $Wait = 5
                $Headers = $Response.Headers
                if ($null -ne $Headers)
                {
                    $RetryAfter = $null
                    try { $RetryAfter = $Headers.RetryAfter } catch { $RetryAfter = $null }
                    # Seconds are kept as a double, so a header far in the past or future cannot overflow a cast.
                    if ($null -ne $RetryAfter -and $null -ne $RetryAfter.Delta) { $Wait = [math]::Ceiling($RetryAfter.Delta.TotalSeconds) }
                    elseif ($null -ne $RetryAfter -and $null -ne $RetryAfter.Date) { $Wait = [math]::Ceiling(($RetryAfter.Date.UtcDateTime - (Get-Date).ToUniversalTime()).TotalSeconds) }
                    elseif ($Headers -is [System.Collections.IDictionary] -and $Headers.Contains('Retry-After'))
                    {
                        $Parsed = 0
                        if ([int]::TryParse((@($Headers['Retry-After']) | Select-Object -First 1), [ref]$Parsed)) { $Wait = $Parsed }
                    }
                }
                if ($Wait -gt $MaxWaitSeconds) { break }
                Start-Sleep -Seconds ([int][math]::Max([double]1, [double]$Wait))
            }
            $Final = if ($Code -eq 429) { 'Throttled' } else { 'ApiUnavailable' }
            if ($IsFabric -and $Final -eq 'Throttled') { $FabricState.Throttled = $true }
            return [pscustomobject]@{ Status = $Final; Body = $null }
        }

        # Every page of a list call. Fabric pages carry 'continuationUri', ARM pages 'nextLink'; a next page is
        # followed only on the same API host, at most $MaxPages pages. A page whose 'value' is not a list is
        # ApiUnavailable; more pages than that, or a next page on another host, is Partial.
        function Get-FabricCapacityList([string]$Uri, [string]$Path)
        {
            $Items = [System.Collections.Generic.List[object]]::new()
            $Next = if ($Uri) { $Uri } else { $Path }
            for ($Page = 0; $Page -lt $MaxPages -and -not [string]::IsNullOrEmpty($Next); $Page++)
            {
                $Request = if ($Uri) { @{ Uri = $Next; ResourceId = $FabricApi } } else { @{ Path = $Next } }
                $Result = Invoke-FabricCapacityGet $Request
                # A later page that cannot be read keeps the pages read before it: the list is then Partial.
                $Stop = if ($Items.Count -gt 0) { 'Partial' } else { $Result.Status }
                if ($Result.Status -ne 'Ok') { return [pscustomobject]@{ Status = $Stop; Items = $Items } }
                $Body = $Result.Body
                if ($null -eq $Body -or $Body.PSObject.Properties.Name -notcontains 'value' -or $Body.value -isnot [array])
                {
                    return [pscustomobject]@{ Status = $(if ($Items.Count -gt 0) { 'Partial' } else { 'ApiUnavailable' }); Items = $Items }
                }
                foreach ($Item in @($Body.value)) { if ($null -ne $Item) { $Items.Add($Item) } }
                if ($Uri)
                {
                    $Next = [string]$Body.continuationUri
                    if (-not [string]::IsNullOrEmpty($Next) -and -not $Next.StartsWith($FabricApi + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return [pscustomobject]@{ Status = 'Partial'; Items = $Items } }
                }
                else
                {
                    $Next = [string]$Body.nextLink
                    if (-not [string]::IsNullOrEmpty($Next))
                    {
                        $NextUri = [uri]$Next
                        if (-not $NextUri.IsAbsoluteUri -or $NextUri.Host -ne $ArmHost) { return [pscustomobject]@{ Status = 'Partial'; Items = $Items } }
                        $Next = $NextUri.PathAndQuery
                    }
                }
            }
            if (-not [string]::IsNullOrEmpty($Next)) { return [pscustomobject]@{ Status = 'Partial'; Items = $Items } }
            return [pscustomobject]@{ Status = 'Ok'; Items = $Items }
        }

        # Only the words Fabric documents for each pool field are kept; anything else is $null, so no user
        # text and no unknown value can pass.
        $NodeSizeWords = @('Small', 'Large')
        $ShutdownPolicyWords = @('AlwaysOn', 'OneHourInactivity')
        function Get-FabricCapacityWord($Value, [string[]]$Allowed)
        {
            $Text = [string]$Value
            foreach ($Word in $Allowed) { if ($Text -ceq $Word) { return $Word } }
            return $null
        }

        # A node count: a whole number 0 or more, else $null.
        function Get-FabricCapacityCount($Value)
        {
            $Parsed = 0
            if ($null -ne $Value -and [int]::TryParse([string]$Value, [System.Globalization.NumberStyles]::None, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Parsed)) { return $Parsed }
            return $null
        }

        $IdPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

        # The consumption window, the same days the bill read covers: GetResorceConsumption in ResourceInventory.ps1
        # builds day -31 and day -1 from the host's LOCAL calendar date, and Get-UsageAggregates sends them with no
        # zone, so the bill's UTC days are those local dates. The window is therefore those dates read as UTC
        # midnights (not today's UTC date, which differs from the local date for part of every day off UTC).
        # shortcut: the bill read builds its own dates later in the run, so a run that crosses local midnight between this
        # collector and the consumption read gets a window one day off the bill; the server's Inconsistent check (design
        # 5.4 step 5) is the guard. Upgrade: one window computed once per run in ResourceInventory.ps1 for both.
        $LocalToday = (Get-Date).Date
        $WindowStart = [datetime]::SpecifyKind($LocalToday.AddDays(-31), [System.DateTimeKind]::Utc)
        $WindowEnd = [datetime]::SpecifyKind($LocalToday.AddDays(-1), [System.DateTimeKind]::Utc)
        $WindowHours = [int][math]::Round(($WindowEnd - $WindowStart).TotalHours)
        # The window as written on every row: UTC, ISO 8601, invariant culture (for example 2026-10-17T00:00:00Z).
        $WindowStartText = $WindowStart.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        $WindowEndText = $WindowEnd.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)

        # Fabric side, read once per run: the caller's Fabric capacities and workspaces.
        # Fail-safe: any error in these reads is a status word on every row, never a collector failure.
        try { $FabricCapacityList = Get-FabricCapacityList -Uri ($FabricApi + '/v1/capacities') }
        catch { $FabricCapacityList = [pscustomobject]@{ Status = 'ApiUnavailable'; Items = @() } }
        try { $FabricWorkspaceList = if ($FabricCapacityList.Status -in @('Ok', 'Partial')) { Get-FabricCapacityList -Uri ($FabricApi + '/v1/workspaces') } else { $null } }
        catch { $FabricWorkspaceList = [pscustomobject]@{ Status = 'ApiUnavailable'; Items = @() } }

        $Tmp = @()

        foreach ($1 in $FabricCapacities)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            # Run hours in the window from the activity log: succeeded suspend and resume events only.
            # A capacity made inside the window counts from its creation time (ARM createdTime), as Active.
            # Otherwise the state at the window start is the opposite of the first event, or today's state when
            # there is none. Only time, operation and status are asked for, so no caller or claims are read.
            $ActiveHours = $null
            $ActiveHoursSource = 'Unavailable'
            try
            {
                $Now = (Get-Date).ToUniversalTime()
                $TypeFilter = "resourceType eq 'Microsoft.Fabric/capacities'"
                $CreatedPath = '/subscriptions/{0}/resourceGroups/{1}/resources?api-version=2021-04-01&$expand=createdTime&$filter={2}' -f $1.subscriptionId, [uri]::EscapeDataString([string]$1.RESOURCEGROUP), [uri]::EscapeDataString($TypeFilter)
                $CreatedList = Get-FabricCapacityList -Path $CreatedPath
                $Created = $null
                if ($CreatedList.Status -eq 'Ok')
                {
                    $Match = @($CreatedList.Items | Where-Object { [string]$_.id -ieq [string]$1.id })
                    if ($Match.Count -eq 1 -and -not [string]::IsNullOrEmpty([string]$Match[0].createdTime)) { $Created = ([datetimeoffset]$Match[0].createdTime).UtcDateTime }
                }

                $Filter = "eventTimestamp ge '{0}' and eventTimestamp le '{1}' and resourceUri eq '{2}'" -f $WindowStart.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture), $Now.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture), ([string]$1.id -replace "'", "''")
                $LogPath = '/subscriptions/{0}/providers/Microsoft.Insights/eventtypes/management/values?api-version=2015-04-01&$filter={1}&$select=eventTimestamp,operationName,status' -f $1.subscriptionId, [uri]::EscapeDataString($Filter)
                $LogList = Get-FabricCapacityList -Path $LogPath

                if ($LogList.Status -eq 'Ok' -and $null -ne $Created)
                {
                    $Events = [System.Collections.Generic.List[object]]::new()
                    foreach ($LogEvent in $LogList.Items)
                    {
                        if ([string]$LogEvent.status.value -ne 'Succeeded') { continue }
                        $Op = [string]$LogEvent.operationName.value
                        $Kind = if ($Op -ieq 'Microsoft.Fabric/capacities/suspend/action') { 'Suspend' } elseif ($Op -ieq 'Microsoft.Fabric/capacities/resume/action') { 'Resume' } else { $null }
                        if ($null -eq $Kind) { continue }
                        $Events.Add([pscustomobject]@{ Kind = $Kind; Time = ([datetimeoffset]$LogEvent.eventTimestamp).UtcDateTime })
                    }

                    $From = $WindowStart
                    $To = $WindowEnd
                    $Sorted = @($Events | Sort-Object -Property Time)
                    $State = [string]$Data.state
                    $Running = $null
                    if ($Created -ge $From)
                    {
                        # Made inside the window: events before its creation belong to an earlier capacity with the same
                        # id (deleted and made again), so they are dropped.
                        $From = $Created
                        $Running = $true
                        $Sorted = @($Sorted | Where-Object { $_.Time -ge $Created })
                    }
                    elseif ($Sorted.Count -gt 0) { $Running = ($Sorted[0].Kind -eq 'Suspend') }
                    elseif ($State -ieq 'Active') { $Running = $true }
                    elseif ($State -ieq 'Paused' -or $State -ieq 'Suspended') { $Running = $false }
                    if ($From -gt $To) { $From = $To }

                    if ($null -ne $Running)
                    {
                        $Seconds = 0.0
                        $Cursor = $From
                        foreach ($LogEvent in $Sorted)
                        {
                            $At = if ($LogEvent.Time -lt $From) { $From } elseif ($LogEvent.Time -gt $To) { $To } else { $LogEvent.Time }
                            if ($Running) { $Seconds += ($At - $Cursor).TotalSeconds }
                            $Cursor = $At
                            $Running = ($LogEvent.Kind -eq 'Resume')
                        }
                        if ($Running) { $Seconds += ($To - $Cursor).TotalSeconds }
                        $ActiveHours = [int][math]::Round($Seconds / 3600, [System.MidpointRounding]::AwayFromZero)
                        $ActiveHoursSource = 'ActivityLog'
                    }
                }
            }
            catch
            {
                $ActiveHours = $null
                $ActiveHoursSource = 'Unavailable'
            }

            # Airflow jobs on this capacity. The ARM capacity is linked to its Fabric capacity by name, region and
            # SKU (no documented field links the two ids; the SKU keeps a Power BI P or A capacity of the same name out). Fabric lists only the workspaces the caller has
            # a role on, so a linked capacity with no visible workspace is NoFabricAccess, never NoAirflowJobs.
            $AirflowJobs = @()
            $AirflowStatus = $null
            try
            {
                # A list that stopped part way (Partial) is still used for what it holds; the row then ends Partial.
                $ListPartial = ($FabricCapacityList.Status -eq 'Partial')
                if ($FabricCapacityList.Status -ne 'Ok' -and -not $ListPartial) { $AirflowStatus = $FabricCapacityList.Status }
                else
                {
                    $Region = ([string]$1.LOCATION -replace '\s', '').ToLowerInvariant()
                    $Linked = @($FabricCapacityList.Items | Where-Object {
                            [string]$_.displayName -ieq [string]$1.NAME -and (([string]$_.region -replace '\s', '').ToLowerInvariant()) -eq $Region -and [string]$_.sku -ieq [string]$1.SKU.name -and [string]$_.id -match $IdPattern
                        })
                    if ($Linked.Count -ne 1) { $AirflowStatus = if ($ListPartial) { 'Partial' } else { 'CapacityNotLinked' } }
                    elseif ($FabricWorkspaceList.Status -ne 'Ok' -and $FabricWorkspaceList.Status -ne 'Partial') { $AirflowStatus = $FabricWorkspaceList.Status }
                    else
                    {
                        if ($FabricWorkspaceList.Status -eq 'Partial') { $ListPartial = $true }
                        $Read = 0
                        $FailWord = $null
                        $Workspaces = @($FabricWorkspaceList.Items | Where-Object { [string]$_.capacityId -ieq [string]$Linked[0].id })
                        if ($Workspaces.Count -eq 0 -and -not $ListPartial) { $FailWord = 'NoFabricAccess' }
                        foreach ($Workspace in $Workspaces)
                        {
                            if ([string]$Workspace.id -notmatch $IdPattern) { $FailWord = 'ApiUnavailable'; continue }
                            $Jobs = Get-FabricCapacityList -Uri ('{0}/v1/workspaces/{1}/apacheAirflowJobs' -f $FabricApi, $Workspace.id)
                            if ($Jobs.Status -ne 'Ok') { $FailWord = $Jobs.Status }
                            foreach ($Job in $Jobs.Items)
                            {
                                if ([string]$Job.id -notmatch $IdPattern) { $FailWord = 'ApiUnavailable'; continue }
                                $Compute = Invoke-FabricCapacityGet @{ Uri = ('{0}/v1/workspaces/{1}/apacheAirflowJobs/{2}/environment/compute?beta=true' -f $FabricApi, $Workspace.id, $Job.id); ResourceId = $FabricApi }
                                if ($Compute.Status -ne 'Ok') { $FailWord = $Compute.Status; continue }
                                # A 200 that holds no pool settings (empty, not an object, an error body) is a job not read.
                                $Body = $Compute.Body
                                if ($Body -isnot [System.Management.Automation.PSCustomObject] -or -not (@($Body.PSObject.Properties.Name) | Where-Object { $_ -in @('nodeSize', 'shutdownPolicy', 'computeScalability') }))
                                {
                                    $FailWord = 'ApiUnavailable'
                                    continue
                                }
                                $AirflowJobs += [ordered]@{
                                    'NodeSize'       = Get-FabricCapacityWord $Compute.Body.nodeSize $NodeSizeWords;
                                    'ShutdownPolicy' = Get-FabricCapacityWord $Compute.Body.shutdownPolicy $ShutdownPolicyWords;
                                    'MinNodeCount'   = Get-FabricCapacityCount $Compute.Body.computeScalability.minNodeCount;
                                    'MaxNodeCount'   = Get-FabricCapacityCount $Compute.Body.computeScalability.maxNodeCount;
                                }
                                $Read++
                            }
                        }
                        $AirflowStatus = if ($ListPartial -or ($null -ne $FailWord -and $Read -gt 0)) { 'Partial' } elseif ($null -ne $FailWord) { $FailWord } elseif ($Read -gt 0) { 'Collected' } else { 'NoAirflowJobs' }
                    }
                }
            }
            catch
            {
                $AirflowStatus = if ($AirflowJobs.Count -gt 0) { 'Partial' } else { 'ApiUnavailable' }
            }

            $Obj = @{
                'ID'                = $1.id;
                'Subscription'      = $Sub1.Name;
                'ResourceGroup'     = $1.RESOURCEGROUP;
                'Name'              = $1.NAME;
                'Location'          = $1.LOCATION;
                'SKU'               = if ([string]::IsNullOrEmpty([string]$1.SKU.name)) { $null } else { [string]$1.SKU.name };
                'State'             = if ([string]::IsNullOrEmpty([string]$Data.state)) { $null } else { [string]$Data.state };
                'WindowStart'       = $WindowStartText;
                'WindowEnd'         = $WindowEndText;
                'WindowHours'       = $WindowHours;
                'ActiveHours'       = $ActiveHours;
                'ActiveHoursSource' = $ActiveHoursSource;
                'AirflowStatus'     = $AirflowStatus;
                'AirflowJobs'       = @($AirflowJobs);
            }

            $Tmp += $Obj
        }

        # One line for the person running the tool when Airflow settings could not be read (counts only, no names).
        $Missed = @($Tmp | Where-Object { $_.AirflowStatus -notin @('Collected', 'NoAirflowJobs') })
        if ($Missed.Count -gt 0 -and (Get-Command -Name Write-Log -ErrorAction SilentlyContinue))
        {
            $Words = ($Missed | Group-Object -Property { $_.AirflowStatus } | Sort-Object -Property Name | ForEach-Object { '{0} {1}' -f $_.Name, $_.Count }) -join ', '
            Write-Log -Message ("Fabric capacities: Airflow pool settings not fully read for {0} of {1} capacity(ies) ({2}). The inventory row says why in AirflowStatus. To read them, give the signed-in identity Fabric capacity admin or contributor on the capacity and Viewer on the Fabric workspaces that hold Airflow jobs (see README, Microsoft Fabric capacities)." -f $Missed.Count, $Tmp.Count, $Words) -Severity 'Warning'
        }

        # Fabric lists only the workspaces the signed-in identity has a role on, so a read row (Collected or
        # NoAirflowJobs) cannot show jobs in workspaces it cannot see. Say so on every run that read one.
        $Read = @($Tmp | Where-Object { $_.AirflowStatus -in @('Collected', 'NoAirflowJobs') })
        if ($Read.Count -gt 0 -and (Get-Command -Name Write-Log -ErrorAction SilentlyContinue))
        {
            Write-Log -Message ("Fabric capacities: Airflow pool settings read for {0} capacity(ies) from the workspaces the signed-in identity can see. Fabric does not list workspaces the identity has no role on, so Airflow jobs there are not counted. Give the identity Viewer on every workspace on the capacity (see README, Microsoft Fabric capacities)." -f $Read.Count) -Severity 'Info'
        }

        $Tmp
    }
}
