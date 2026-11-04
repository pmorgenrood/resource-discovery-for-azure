param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $APPSvcPlan = $Resources | Where-Object { $_.TYPE -eq 'microsoft.web/serverfarms' }
    $APPAutoScale = $Resources | Where-Object { $_.TYPE -eq "microsoft.insights/autoscalesettings" -and $_.Properties.enabled -eq 'true' }

    if ($APPSvcPlan)
    {
        # Collect the autoscale targets once so each plan checks them with a lookup
        # instead of scanning every autoscale setting. The comparer is the one the
        # -eq this replaces uses for two strings (invariant culture, ignore case).
        # A setting whose target is not a single string keeps the -eq check, so
        # every plan gets the same answer as before.
        $AutoScaleTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase)
        $AutoScaleOther = [System.Collections.Generic.List[object]]::new()
        foreach ($Setting in $APPAutoScale)
        {
            $Target = $Setting.Properties.targetResourceUri
            if ($Target -is [string]) { [void]$AutoScaleTargets.Add($Target) } else { $AutoScaleOther.Add($Setting) }
        }

        $Tmp = [System.Collections.Generic.List[object]]::new()

        foreach ($1 in $APPSvcPlan)
        {
            Remove-Variable AutoScale -ErrorAction SilentlyContinue

            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES
            $Sku = $1.SKU

            # A plan with no id (null, empty or not a string) cannot be the
            # target of a setting, so it is never autoscaled.
            if ($1.id -isnot [string] -or $1.id.Length -eq 0)
            {
                $AutoSc = $false
            }
            else
            {
                $AutoSc = $AutoScaleTargets.Contains($1.id)
                # The side list holds only settings whose target is not one
                # string. Real settings always have a string target, so it is
                # expected to be empty and this scan does not run.
                if (-not $AutoSc -and $AutoScaleOther.Count -gt 0)
                {
                    $AutoScale = ($AutoScaleOther | Where-Object { $_.Properties.targetResourceUri -eq $1.id })
                    $AutoSc = -not [string]::IsNullOrEmpty($AutoScale)
                }
            }

            $Obj = @{
                'ID'                    = $1.id;
                'Subscription'          = $Sub1.Name;
                'ResourceGroup'         = $1.RESOURCEGROUP;
                'Name'                  = $1.NAME;
                'Location'              = $1.LOCATION;
                'Tier'                  = $Sku.tier;
                'Size'                  = $Sku.name;
                'PricingTier'           = ($Sku.tier + '(' + $Sku.name + ': ' + $Data.currentNumberOfWorkers + ')');
                'ComputeMode'           = $Data.computeMode;
                'InstanceSize'          = $Data.currentWorkerSize;
                'CurrentInstances'      = $Data.currentNumberOfWorkers;
                'Spot'                  = $Data.isSpot
                'AutoscaleEnabled'      = $AutoSc;
                'MaxInstances'          = $Data.maximumNumberOfWorkers;
                'AppPlanOS'             = if ($Data.reserved -eq 'true') { 'Linux' } else { 'Windows' };
                'AppsType'              = $Data.kind;
                'Apps'                  = $Data.numberOfSites;
                'ZoneRedundant'         = $Data.zoneRedundant;
            }

            [void]$Tmp.Add($Obj)
        }

        $Tmp
    }
}
