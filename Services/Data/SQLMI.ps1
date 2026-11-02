param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $SQLSERVERMI = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedInstances' }
    $SQLSERVERMIDB = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedinstances/databases' }

    if ($SQLSERVERMI)
    {
        $Tmp = [System.Collections.Generic.List[object]]::new()

        foreach ($1 in $SQLSERVERMI)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Databases = $SQLSERVERMIDB | Where-Object { $_.Id -like "$($1.Id)/databases/*" }
            # Backup storage redundancy: older API shapes name it storageAccountType,
            # current ones report currentBackupStorageRedundancy (in effect) and
            # requestedBackupStorageRedundancy (asked for). Take the first that is a
            # non-empty string.
            $BackupStorage = $null
            foreach ($Candidate in @($Data.storageAccountType, $Data.currentBackupStorageRedundancy, $Data.requestedBackupStorageRedundancy))
            {
                if ($Candidate -is [string] -and $Candidate -ne '') { $BackupStorage = $Candidate; break }
            }

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
                'StorageAccountType'            = $BackupStorage;
                'LicenseType'                   = $Data.licenseType;
                'State'                         = $Data.state;
                'ManagedInstanceCreateMode'     = $Data.managedInstanceCreateMode;
                'ZoneRedundant'                 = $Data.zoneRedundant;
                'Databases'                     = if ($null -ne $Databases) { $Databases.Count } else { '0' }
            }

            [void]$Tmp.Add($Obj)
        }

        $Tmp
    }
}
