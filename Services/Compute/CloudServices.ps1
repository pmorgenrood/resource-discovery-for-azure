param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $CloudServices = $Resources | Where-Object { $_.TYPE -eq 'microsoft.compute/cloudservices' }

    if ($CloudServices)
    {
        $Tmp = [System.Collections.Generic.List[object]]::new()

        foreach ($1 in $CloudServices)
        {
            $Sub1 = $SUB | Where-Object { $_.id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            # roleProfile is an object; its 'roles' member holds the list of roles.
            # Only objects are roles: a string or number there has no name or SKU.
            $Roles = @($Data.roleProfile.roles | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -or $_ -is [System.Collections.IDictionary] })

            $Obj = @{
                'ID'                   = $1.id;
                'Subscription'         = $Sub1.Name;
                'ResourceGroup'        = $1.RESOURCEGROUP;
                'Name'                 = $1.name;
                'Location'             = $1.location;
            }

            # A plain key, so the roles are written with the row. A NoteProperty of
            # the same name would hide the key from the JSON writer.
            $Obj['Roles'] = [System.Collections.Generic.List[object]]::new()

            foreach ($roleProfile in $Roles)
            {
                $RoleProfileObj = @{
                    'RoleName'        = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { Protect-FreeTextValue $roleProfile.name } else { $roleProfile.name };
                    'SkuName'     = $roleProfile.sku.name;
                    'SkuTier'     = $roleProfile.sku.tier;
                    'SkuCapacity'     = $roleProfile.sku.capacity;
                }

                $Obj.Roles.Add($RoleProfileObj)
            }

            [void]$Tmp.Add($Obj)
        }

        $Tmp
    }
}
