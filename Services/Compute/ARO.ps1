param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $ARO = $Resources | Where-Object { $_.TYPE -eq 'microsoft.redhatopenshift/openshiftclusters' }

    if ($ARO)
    {
        $Tmp = [System.Collections.Generic.List[object]]::new()
        foreach ($1 in $ARO)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            # Each worker profile is a pool with its own node count, so the total
            # is the sum of the pools' 'count' values, not the number of pools.
            # No pools is 0. A pool whose count is missing or not a whole number
            # makes the total unknown (empty) rather than a number that is too low.
            $WorkerNodes = 0
            foreach ($Pool in @($Data.workerProfiles | Where-Object { $null -ne $_ }))
            {
                # Read the property itself: on an object without one, .count is
                # PowerShell's own item count (1), not a node count.
                $PoolCount = $Pool.PSObject.Properties['count'].Value
                if ($PoolCount -is [string] -and $PoolCount -match '^\s*\d+\s*$') { $PoolCount = [long]$PoolCount.Trim() }
                if (($PoolCount -is [int] -or $PoolCount -is [long]) -and $PoolCount -ge 0)
                {
                    $WorkerNodes += $PoolCount
                }
                else
                {
                    $WorkerNodes = $null
                    break
                }
            }

            $Obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $Sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Clusters'             = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { 'obfuscated' } else { $1.NAME };
                'Location'             = $1.LOCATION;
                'AROVersion'           = $Data.clusterProfile.version;
                'OutboundType'         = $Data.networkProfile.outboundType;
                'APIServerType'        = $Data.apiserverProfile.visibility;
                'MasterSKU'            = $Data.masterProfile.vmSize;
                'WorkerSKU'            = $Data.workerProfiles.vmSize | Select-Object -Unique;
                'WorkerDiskSize'       = $Data.workerProfiles.diskSizeGB | Select-Object -Unique;
                'TotalWorkerNodes'     = $WorkerNodes;
            }

            [void]$Tmp.Add($Obj)
        }

        $Tmp
    }
}
