# The billing phase GetResorceConsumption as it was before its row loop was
# built from object literals: copied unchanged from ResourceInventory.ps1 of
# the change this one builds on (the up-front read access and usage checks),
# only renamed GetResorceConsumptionBase and moved out one indent level.
# ConsumptionRowLoop.Tests.ps1 runs it and the current function on the same
# pages and compares the CSV bytes, so the test does not rest on stored hashes
# alone. Do not edit it: it is the reference.

function GetResorceConsumptionBase()
{
    $DebugPreference = "SilentlyContinue"
    # A usage row leaves out the InstanceData parts Azure has no value for
    # (additionalInfo, or some of its keys), and the row loop reads them as
    # properties that may be absent. Strict mode is off for this phase only, so
    # a run started from a shell with Set-StrictMode -Version Latest writes such
    # a row with its empty defaults instead of stopping the subscription's pull.
    Set-StrictMode -Off

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

    if (-not (Test-DataPlaneAuthReady -Phase 'Consumption'))
    {
        Write-Log -Message ('Consumption: SKIPPED - could not establish a usable Azure context/token after one reconnect attempt. Consumption was requested (no -SkipConsumption) but cannot be collected. Re-authenticate (Connect-AzAccount) or pass -appid/-secret/-tenant, then re-run. The rest of the inventory will continue.') -Severity 'Error'

        if ($null -eq $Global:ConsumptionRecordCount) { $Global:ConsumptionRecordCount = 0 }
        if ($null -eq $Global:ConsumptionFailedSubs) { $Global:ConsumptionFailedSubs = @() }
        $Global:ConsumptionFailedSubs += [pscustomobject]@{
            Name    = '(all subscriptions)'
            Id      = '(auth)'
            Message = 'Consumption phase skipped: no usable Azure context/token after one reconnect attempt.'
        }
        return
    }

    foreach ($sub in $Global:Subscriptions)
    {
        if (![string]::IsNullOrEmpty($SubscriptionID))
        {
            if (![string]::IsNullOrEmpty($ResourceGroup))
            {
                Write-Log -Message ("Cannot filter consumption by resource group." -f $sub.Name) -Severity 'Info'
            }

            if ($SubscriptionID -ne $sub.Id)
            {
                Write-Log -Message ("Skipping: {0}" -f $sub.Name) -Severity 'Info'
                continue
            }
        }

        $ContextOk = $false
        $ContextSwitchError = $null
        try
        {
            $null = Set-AzContext -Subscription $sub.id -ErrorAction Stop
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
            }

            continue
        }

        Write-Log -Message ("Gathering Consumption for: {0}" -f $sub.Name) -Severity 'Info'

        $ConsumptionRecordsThisSub = 0
        $ConsumptionFailedThisSub = $false
        $ConsumptionFailureMessage = $null
        $ConsumptionPageIndex = 0

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

                $Params.ContinuationToken = $UsageData.ContinuationToken

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
                        if ($ConsumptionAttempt -gt $ConsumptionMaxRetries) { throw }
                        $ConsumptionBackoffSeconds = [int][math]::Pow(2, $ConsumptionAttempt)
                        Write-Log -Message ("Consumption page query failed for {0} (attempt {1}/{2}): {3}. Retrying in {4}s..." -f $sub.Name, $ConsumptionAttempt, $ConsumptionMaxRetries, $_.Exception.Message, $ConsumptionBackoffSeconds) -Severity 'Warning'
                        Start-Sleep -Seconds $ConsumptionBackoffSeconds
                    }
                }
                $UsageDataExport = $UsageData.UsageAggregations.Properties | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime

                Write-Log -Message ("Records found: $($UsageDataExport.Count)...") -Severity 'Info'
                $ConsumptionRecordsThisSub += $UsageDataExport.Count

                $NewUsageDataExport = [System.Collections.ArrayList]::new()

                for ($Item = 0; $Item -lt $UsageDataExport.Count; $Item++)
                {
                    $InstanceInfo = ($UsageDataExport[$Item].InstanceData.tolower() | ConvertFrom-Json)

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
                        $Prefix = if ($UsageDataExport[$Item].ResourceId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $UsageDataExport[$Item].ResourceId -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }

                        $RawUri = $InstanceObject.'Microsoft.Resources'.resourceUri

                        if (-not $script:ConsumptionSubCache) { $script:ConsumptionSubCache = @{} }
                        if (-not $script:ConsumptionRgCache) { $script:ConsumptionRgCache = @{} }
                        if (-not $script:ConsumptionNameCache) { $script:ConsumptionNameCache = @{} }


                        if (![string]::IsNullOrEmpty($RawUri) -and $ResourceIdDictionary.ContainsKey($RawUri))
                        {
                            $ObfuscatedUri = $ResourceIdDictionary[$RawUri]
                        }
                        else
                        {
                            $ObfuscatedUri = Build-ObfuscatedResourceUri -RawUri $RawUri -Prefix $Prefix -SubscriptionDictionary $ResourceSubscriptionDictionary -ResourceGroupDictionary $ResourceResourceGroupDictionary -NameDictionary $ResourceNameDictionary -SubCache $script:ConsumptionSubCache -RgCache $script:ConsumptionRgCache -NameCache $script:ConsumptionNameCache

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

                $NewUsageDataExport | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime, ResourceId, ResourceLocation, ConsumptionMeter, ReservationId, ReservationOrderId | Export-Csv $Global:ConsumptionFileCsv -Encoding utf8 -Append -NoTypeInformation

            } while ('ContinuationToken' -in $UsageData.psobject.properties.name -and $UsageData.ContinuationToken)
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
            }
        }
    }

    $DebugPreference = "Continue"
}
