param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $SQLSERVERMI = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedInstances' }
    $SQLSERVERMIDB = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedinstances/databases' }

    if ($SQLSERVERMI)
    {
        $Tmp = @()

        # Count each instance's databases once up front instead of scanning every
        # database for every instance. A database belongs to an instance when its
        # id starts with "<instance id>/databases/", so each place '/databases/'
        # appears in a database id gives one candidate parent. Every id takes this
        # one path. Letter case is ignored by an ordinal rule, which is the same on
        # every host culture, and wildcard characters are plain characters.
        $DbCountByParent = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($Db in $SQLSERVERMIDB)
        {
            if ($null -eq $Db.Id) { continue }
            $DbId = "$($Db.Id)"
            $At = $DbId.IndexOf('/databases/', [System.StringComparison]::OrdinalIgnoreCase)
            while ($At -ge 0)
            {
                $Parent = $DbId.Substring(0, $At)
                $Seen = 0
                [void]$DbCountByParent.TryGetValue($Parent, [ref]$Seen)
                $DbCountByParent[$Parent] = $Seen + 1
                $At = $DbId.IndexOf('/databases/', $At + 1, [System.StringComparison]::OrdinalIgnoreCase)
            }
        }

        foreach ($1 in $SQLSERVERMI)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $DbCount = 0
            [void]$DbCountByParent.TryGetValue("$($1.Id)", [ref]$DbCount)

            $Obj = @{
                'ID'                            = $1.id;
                'Subscription'                  = $Sub1.Name;
                'ResourceGroup'                 = $1.RESOURCEGROUP;
                'Name'                          = $1.NAME;
                'Location'                      = $1.LOCATION;
                'SkuName'                       = $1.sku.Name;
                'SkuCapacity'                   = $1.sku.capacity;
                'SkuTier'                       = $1.sku.tier;
                'SkuFamily'                     = $1.sku.family;
                'InstancePoolName'              = if (![string]::IsNullOrEmpty($Data.instancePoolId) -and $null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($Data.instancePoolId)) { $ResourceIdDictionary[$Data.instancePoolId] } else { 'obfuscated' } } else { $Data.instancePoolId };
                'vCores'                        = $Data.vCores;
                'StorageGB'                     = $Data.storageSizeInGB;
                'StorageAccountType'            = $Data.storageAccountType;
                'LicenseType'                   = $Data.licenseType;
                'State'                         = $Data.state;
                'ManagedInstanceCreateMode'     = $Data.managedInstanceCreateMode;
                'ZoneRedundant'                 = $Data.zoneRedundant;
                'Databases'                     = if ($DbCount -gt 0) { $DbCount } else { '0' }
            }

            $Tmp += $Obj
        }

        $Tmp
    }
}
