param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $Runbook = $Resources | Where-Object { $_.TYPE -eq 'microsoft.automation/automationaccounts/runbooks' }
    $Autacc = $Resources | Where-Object { $_.TYPE -eq 'microsoft.automation/automationaccounts' }

    if ($Autacc)
    {
        $Tmp = [System.Collections.Generic.List[object]]::new()

        # A runbook belongs to the account whose id is the runbook id without its
        # last '/runbooks/<name>' part. Matching on that id, not on the account
        # name, keeps runbooks under their own account when two accounts share a
        # name in different resource groups or subscriptions. Ids are compared
        # without regard to case: Azure does not keep one case for them.
        $RunbooksByAccount = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Rb in $Runbook)
        {
            $RbId = $Rb.id
            if ($RbId -isnot [string]) { continue }
            $Cut = $RbId.LastIndexOf('/runbooks/', [System.StringComparison]::OrdinalIgnoreCase)
            if ($Cut -le 0) { continue }
            $ParentId = $RbId.Substring(0, $Cut)
            if (-not $RunbooksByAccount.ContainsKey($ParentId)) { $RunbooksByAccount[$ParentId] = [System.Collections.Generic.List[object]]::new() }
            $RunbooksByAccount[$ParentId].Add($Rb)
        }

        foreach ($0 in $Autacc)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $0.subscriptionId }
            $Rbs = if ($0.id -is [string] -and $RunbooksByAccount.ContainsKey($0.id)) { $RunbooksByAccount[$0.id] } else { $null }

            $Data0 = $0.properties
            $Timecreated = $Data0.creationTime
            # A missing value, or one that does not convert to a date, is 'Unknown'
            # rather than an exception that fails the whole collector.
            # A valid value is written in UTC on every host; one with no zone is taken as UTC.
            $Timecreated = try { if ($null -ne $Timecreated) { [datetime]::Parse($Timecreated, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal').ToString("yyyy-MM-dd HH:mm") } else { 'Unknown' } } catch { 'Unknown' }

            if ($null -ne $Rbs)
            {
                foreach ($1 in $Rbs)
                {
                    $Data = $1.PROPERTIES

                    $Obj = @{
                        'ID'                            = $1.id;
                        'Subscription'                  = $Sub1.Name;
                        'ResourceGroup'                 = $0.RESOURCEGROUP;
                        'AutomationAccountName'         = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $0.NAME } else { $0.NAME };
                        'AutomationAccountState'        = $0.properties.State;
                        'AutomationAccountSKU'          = $0.properties.sku.name;
                        'AutomationAccountCreatedTime'  = $Timecreated;
                        'Location'                      = $0.LOCATION;
                        'RunbookName'                   = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $1.Name } else { $1.Name };
                        'LastModifiedTime'              = try { if ($null -ne $Data.lastModifiedTime) { ([datetime]::Parse($Data.lastModifiedTime, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal')).ToString("yyyy-MM-dd HH:mm") } else { 'Unknown' } } catch { 'Unknown' } ;
                        'RunbookState'                  = $Data.state;
                        'RunbookType'                   = $Data.runbookType;
                        'RunbookDescription'            = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $Data.description } else { $Data.description };
                    }

                    [void]$Tmp.Add($Obj)
                }
            }
            else
            {
                $Obj = @{
                    'ID'                            = $0.id;
                    'Subscription'                  = $Sub1.name;
                    'ResourceGroup'                 = $0.RESOURCEGROUP;
                    'AutomationAccountName'         = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $0.NAME } else { $0.NAME };
                    'AutomationAccountState'        = $0.properties.State;
                    'AutomationAccountSKU'          = $0.properties.sku.name;
                    'AutomationAccountCreatedTime'  = $Timecreated;
                    'Location'                      = $0.LOCATION;
                    'RunbookName'                   = $null;
                    'LastModifiedTime'              = $null;
                    'RunbookState'                  = $null;
                    'RunbookType'                   = $null;
                    'RunbookDescription'            = $null;
                }

                [void]$Tmp.Add($Obj)
            }
        }

        $Tmp
    }
}
