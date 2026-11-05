# The billing phase's GetResorceConsumption as it was before its row loop was
# built from object literals: copied unchanged from ResourceInventory.ps1 at fork
# all-fixes-optimized 361c765 (the same function as at fe84096), only renamed
# GetResorceConsumptionBase. ConsumptionRowLoop.Tests.ps1 runs it and the
# current function on the same pages and compares the CSV bytes, so the test
# does not rest on stored hashes alone. Do not edit it: it is the reference.

function GetResorceConsumptionBase([int]$MaxPages = 10000)
{
    $DebugPreference = "SilentlyContinue"

    [System.Threading.Thread]::CurrentThread.CurrentUICulture = "en-US";
    [System.Threading.Thread]::CurrentThread.CurrentCulture = "en-US";

    # UsageStartTime / UsageEndTime are written in this format with the
    # invariant culture, so the text is the same on every host. The en-US
    # culture's own time pattern comes from the host's culture data: with
    # ICU (on Linux, for example) it can have U+202F, not a space, before AM/PM.
    $UsageDateFormat = 'M/d/yyyy h:mm:ss tt'
    $InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

    # The run's window (RunInventorySetup): the one the up-front
    # consumption data check queried, or under -RunAllSubs the wrapper's.
    $ReportedStartTime = $script:ConsumptionWindow.Start
    $ReportedEndTime = $script:ConsumptionWindow.End

    # Name of the report folder this run writes to, recorded on a consumption
    # failure (and on the sign-in skip below) so the wrapper's main summary can
    # mark that report's row.
    $ConsumptionReportFolder = if ($Global:DefaultPath) { Split-Path -Path ($Global:DefaultPath.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')) -Leaf } else { $null }

    if (-not (Test-DataPlaneAuthReady -Phase 'Consumption'))
    {
        Write-Log -Message ('Consumption: SKIPPED - could not establish a usable Azure context/token after one reconnect attempt. Consumption was requested (no -SkipConsumption) but cannot be collected. Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run. The rest of the inventory will continue.') -Severity 'Error'

        if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
        if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
        $Global:ConsumptionFailedSubs += [pscustomobject]@{
            Name         = '(all subscriptions)'
            Id           = '(auth)'
            Message      = 'Consumption phase skipped: no usable Azure context/token after one reconnect attempt.'
            ReportFolder = $ConsumptionReportFolder
        }
        return
    }

    # A -SubscriptionID run passes over every other subscription in the list:
    # one line in the local debug log, never one console line for each.
    if (![string]::IsNullOrEmpty($SubscriptionID))
    {
        $PassedOverCount = @($Global:Subscriptions | Where-Object { $_.Id -ne $SubscriptionID }).Count
        if ($PassedOverCount -gt 0)
        {
            Write-Log -Message ("Consumption: {0} other subscription(s) in this run's subscription list not collected; the run is limited to -SubscriptionID." -f $PassedOverCount) -Severity 'Info' -NoConsole -ToDebugLog
        }
    }

    foreach ($sub in $Global:Subscriptions)
    {
        if (![string]::IsNullOrEmpty($SubscriptionID) -and $SubscriptionID -ne $sub.Id)
        {
            continue
        }

        $ContextOk = $false
        $ContextSwitchError = $null
        try
        {
            # For this run only: -Scope Process keeps the switch out of the user's saved default subscription.
            $null = Set-AzContext -Subscription $sub.id -Scope Process -ErrorAction Stop
            $ContextOk = ((Get-AzContext).Subscription.Id -eq $sub.id)
        }
        catch
        {
            $ContextSwitchError = $_.Exception.Message
        }

        if (-not $ContextOk)
        {
            $SkipMessage = ("Consumption SKIPPED: could not switch the Azure context to this subscription{0}. The signed-in identity likely lacks access to it. Skipped to avoid attributing another subscription's billing data to this one." -f $(if ($ContextSwitchError) { " ($ContextSwitchError)" } else { ' (context did not match the target after Set-AzContext)' }))
            Write-Log -Message ("Consumption: {0} - {1}" -f $sub.Name, $SkipMessage) -Severity 'Error'

            if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
            if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
            $Global:ConsumptionFailedSubs += [pscustomobject]@{
                Name             = $sub.Name
                Id               = $sub.Id
                Message          = $SkipMessage
                Complete         = $false
                PageAtFailure    = 0
                RecordsCollected = 0
                ReportFolder     = $ConsumptionReportFolder
            }

            continue
        }

        Write-Log -Message ("Gathering Consumption for: {0}" -f $sub.Name) -Severity 'Info'

        $ConsumptionRecordsThisSub = 0
        $ConsumptionFailedThisSub = $false
        $ConsumptionFailureMessage = $null
        $ConsumptionPageIndex = 0

        # $UsageData is the last page read, and the next page's token comes
        # from it. A subscription whose pull failed part-way leaves its token
        # there, so each subscription starts with none.
        $UsageData = $null

        try
        {
            do
            {
                $ConsumptionPageIndex++
                $Params = @{
                    ReportedStartTime      = $ReportedStartTime
                    ReportedEndTime        = $ReportedEndTime
                    AggregationGranularity = 'Daily'
                    ShowDetails            = $true
                }

                $Params.ContinuationToken = if ($null -ne $UsageData) { $UsageData.ContinuationToken } else { $null }

                $ConsumptionMaxRetries = 3
                $ConsumptionAttempt = 0
                while ($true)
                {
                    try
                    {
                        $UsageData = Get-UsageAggregates @Params -ErrorAction Stop
                        break
                    }
                    catch
                    {
                        $ConsumptionAttempt++
                        # Retried unless a retry cannot change the outcome, as the up-front
                        # check retries (Invoke-ConsumptionCallWithRetry): a refusal (401, 403,
                        # access denied), a sign-in that cannot be used, a bad request (400) or
                        # not found (404) fails the same way again. Any other failure, including one not recognised, is retried.
                        if ($ConsumptionAttempt -gt $ConsumptionMaxRetries -or (Get-ConsumptionErrorKind -Exception $_.Exception) -ne 'Transient') { throw }
                        $ConsumptionBackoffSeconds = [int][math]::Pow(2, $ConsumptionAttempt)
                        Write-Log -Message ("Consumption page query failed for {0} (attempt {1}/{2}): {3}. Retrying in {4}s..." -f $sub.Name, $ConsumptionAttempt, $ConsumptionMaxRetries, $_.Exception.Message, $ConsumptionBackoffSeconds) -Severity 'Warning'
                        Start-Sleep -Seconds $ConsumptionBackoffSeconds
                    }
                }
                $UsageDataExport = $UsageData.UsageAggregations.Properties | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime

                Write-Log -Message ("Records found: $($UsageDataExport.Count)...") -Severity 'Info'

                $NewUsageDataExport = [System.Collections.ArrayList]::new()

                for ($Item = 0; $Item -lt $UsageDataExport.Count; $Item++)
                {
                    # A row whose InstanceData is missing, not JSON, or JSON without
                    # 'Microsoft.Resources' keeps its cost with blank resource fields, as
                    # the up-front check reads such a row (Get-ConsumptionRowResourceUri);
                    # it does not stop the subscription. The blank fields are empty text,
                    # not null, so each field keeps the type it has in every other row.
                    $InstanceInfo = $null
                    $InstanceText = [string]$UsageDataExport[$Item].InstanceData
                    if (-not [string]::IsNullOrWhiteSpace($InstanceText))
                    {
                        try { $InstanceInfo = ($InstanceText.tolower() | ConvertFrom-Json -ErrorAction Stop) }
                        catch { $InstanceInfo = $null }
                    }
                    if ($null -eq $InstanceInfo -or $null -eq $InstanceInfo.'microsoft.resources')
                    {
                        $InstanceInfo = [pscustomobject]@{ 'microsoft.resources' = [pscustomobject]@{ resourceuri = ''; location = ''; additionalinfo = [pscustomobject]@{} } }
                    }

                    if (![string]::IsNullOrEmpty($ResourceGroup))
                    {
                        # Same test the up-front consumption data check counts rows by.
                        if (-not (Test-ConsumptionResourceUriInResourceGroup -ResourceUri $InstanceInfo.'Microsoft.Resources'.resourceUri -ResourceGroup $ResourceGroup))
                        {
                            continue;
                        }
                    }

                    # The clock value as Get-UsageAggregates returned it, no time-zone conversion.
                    foreach ($DateField in @('UsageStartTime', 'UsageEndTime'))
                    {
                        $DateValue = $UsageDataExport[$Item].$DateField
                        if ($DateValue -is [datetime]) { $UsageDataExport[$Item].$DateField = $DateValue.ToString($UsageDateFormat, $InvariantCulture) }
                    }

                    $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ResourceId -Value NotSet
                    $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ResourceLocation -Value NotSet

                    $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ConsumptionMeter -Value NotSet
                    $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ReservationId -Value NotSet
                    $UsageDataExport[$Item] | Add-Member -MemberType NoteProperty -Name ReservationOrderId -Value NotSet

                    $UsageDataExport[$Item].ResourceId = $InstanceInfo.'Microsoft.Resources'.resourceUri
                    $UsageDataExport[$Item].ResourceLocation = $InstanceInfo.'Microsoft.Resources'.location
                    $UsageDataExport[$Item].ConsumptionMeter = $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter
                    $UsageDataExport[$Item].ReservationId = $InstanceInfo.'Microsoft.Resources'.additionalInfo.ReservationId
                    $UsageDataExport[$Item].ReservationOrderId = $InstanceInfo.'Microsoft.Resources'.additionalInfo.ReservationOrderId

                    $InstanceObject = [PSCustomObject]@{}

                    $AdditionalInfoInstance = [PSCustomObject]@{
                        ResourceUri = $InstanceInfo.'Microsoft.Resources'.resourceUri
                        Location = $InstanceInfo.'Microsoft.Resources'.location
                        additionalInfo = [PSCustomObject]@{
                            ConsumptionMeter = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ConsumptionMeter }
                            ImageType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ImageType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ImageType }
                            AHB = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.AHB) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.AHB }
                            vCores = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.vCores) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.vCores }
                            VCPUs = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.VCPUs) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.VCPUs }
                            ServiceType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServiceType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServiceType }
                            ResourceCategory = ""
                            Edition = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.Edition) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.Edition }
                            LicenseType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.LicenseType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.LicenseType }
                            HostLicenseType = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.HostLicenseType) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.HostLicenseType }
                            OS = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.OS) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.OS }
                            IsVM = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsVM) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsVM }
                            NumberOfCores = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfCores) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfCores }
                            NumberOfLogicalProcessors = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfLogicalProcessors) { 0 } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.NumberOfLogicalProcessors }
                            SLO = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.SLO) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.SLO }
                            ServerSku = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerSku) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerSku }
                            ServerEdition = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerEdition) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.ServerEdition }
                            IsHAEnabled = if ($null -eq $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsHAEnabled) { "" } else { $InstanceInfo.'Microsoft.Resources'.additionalInfo.IsHAEnabled }
                        }
                    }

                    $InstanceObject | Add-Member -MemberType NoteProperty -Name "Microsoft.Resources" -Value $AdditionalInfoInstance

                    if ($Obfuscate.IsPresent)
                    {
                        $RawUri = $InstanceObject.'Microsoft.Resources'.resourceUri

                        if (![string]::IsNullOrEmpty($RawUri) -and $ResourceIdDictionary.ContainsKey($RawUri))
                        {
                            $ObfuscatedUri = $ResourceIdDictionary[$RawUri]
                        }
                        else
                        {
                            # A resource that is not in the inventory: its segments reuse the
                            # inventory's tokens where they exist (subscription, resource
                            # group, parent resource), and new ones go into the dictionary.
                            $ObfuscatedUri = Get-ObfuscatedResourceId -ResourceId $RawUri

                            if (![string]::IsNullOrEmpty($RawUri))
                            {
                                $ResourceIdDictionary[$RawUri] = $ObfuscatedUri
                            }
                        }

                        $UsageDataExport[$Item].ResourceId = $ObfuscatedUri
                        $InstanceObject.'Microsoft.Resources'.resourceUri = $ObfuscatedUri

                        if (![string]::IsNullOrEmpty($UsageDataExport[$Item].ReservationId))
                        {
                            $UsageDataExport[$Item].ReservationId = 'obfuscated'
                        }
                        if (![string]::IsNullOrEmpty($UsageDataExport[$Item].ReservationOrderId))
                        {
                            $UsageDataExport[$Item].ReservationOrderId = 'obfuscated'
                        }
                    }

                    $UsageDataExport[$Item].InstanceData = $InstanceObject | ConvertTo-Json -Compress

                    $NewUsageDataExport.Add($UsageDataExport[$Item]) | Out-Null
                }

                $NewUsageDataExport | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime, ResourceId, ResourceLocation, ConsumptionMeter, ReservationId, ReservationOrderId | Export-Csv -LiteralPath $Global:ConsumptionFileCsv -Encoding utf8 -Append -NoTypeInformation
                # Rows written to the consumption file: a -ResourceGroup run leaves out the
                # other resource groups' rows, and a page that fails part-way writes none.
                $ConsumptionRecordsThisSub += $NewUsageDataExport.Count

                $MorePages = ('ContinuationToken' -in $UsageData.psobject.properties.name -and $UsageData.ContinuationToken)
                if ($MorePages -and $ConsumptionPageIndex -ge $MaxPages)
                {
                    $ConsumptionPageIndex++
                    throw ("Read the limit of {0:N0} usage pages for one subscription; the usage API offered more, which were not read" -f $MaxPages)
                }
            } while ($MorePages)
        }
        catch
        {
            $ConsumptionFailedThisSub = $true
            $ConsumptionFailureMessage = ("{0} (stopped at consumption page {1}, after {2} record(s); this subscription's consumption is INCOMPLETE)" -f $_.Exception.Message, $ConsumptionPageIndex, $ConsumptionRecordsThisSub)
            Write-Log -Message ("Consumption query failed for {0}: {1}" -f $sub.Name, $ConsumptionFailureMessage) -Severity 'Warning'
        }

        if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
        if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
        $Global:ConsumptionRecordCount += $ConsumptionRecordsThisSub
        if ($ConsumptionFailedThisSub)
        {
            $Global:ConsumptionFailedSubs += [pscustomobject]@{
                Name             = $sub.Name
                Id               = $sub.Id
                Message          = $ConsumptionFailureMessage
                Complete         = $false
                PageAtFailure    = $ConsumptionPageIndex
                RecordsCollected = $ConsumptionRecordsThisSub
                ReportFolder     = $ConsumptionReportFolder
            }
        }
    }

    $DebugPreference = "Continue"
}
