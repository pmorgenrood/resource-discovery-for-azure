param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $PublicIP = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/publicipaddresses' }

    if ($PublicIP)
    {
        $Tmp = [System.Collections.Generic.List[object]]::new()

        foreach ($1 in $PublicIP)
        {
            $Sub1 = $SUB | Where-Object { $_.Id -eq $1.subscriptionId }
            $Data = $1.PROPERTIES

            if (!($Data.ipConfiguration.id)) { $Use = 'UnderUtilized' } else { $Use = 'Utilized' }
            if (!($Data.natGateway.id) -and $Use -eq 'UnderUtilized') { $Use = 'UnderUtilized' } else { $Use = 'Utilized' }

            # A public IP is attached either through properties.ipConfiguration (a NIC,
            # a load balancer frontend and the like) or through properties.natGateway
            # (a NAT gateway). A NAT gateway IP has no ipConfiguration, so it needs its
            # own branch, or it is reported as attached to 'None'. Both ids keep the
            # provider type at segment 7 and the resource name at segment 8:
            #   .../providers/Microsoft.Network/networkInterfaces/<nic>/ipConfigurations/<cfg>
            #   .../providers/Microsoft.Network/natGateways/<nat>
            if ($null -ne $Data.ipConfiguration.id)
            {
                $AssocId = $Data.ipConfiguration.id
                $AssociatedResource = if ([string]::IsNullOrEmpty($AssocId)) { $null } elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($AssocId)) { $ResourceIdDictionary[$AssocId] } else { 'obfuscated' } } else { $AssocId.split('/')[8] }
                $AssociatedResourceType = if ([string]::IsNullOrEmpty($AssocId)) { $null } else { $AssocId.split('/')[7] }
            }
            elseif (-not [string]::IsNullOrEmpty([string]$Data.natGateway.id))
            {
                # Obfuscated the same way as an ipConfiguration id: the NAT gateway's
                # own token when the dictionary has it, else 'obfuscated'.
                $AssocId = [string]$Data.natGateway.id
                $AssociatedResource = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { if ($ResourceIdDictionary.ContainsKey($AssocId)) { $ResourceIdDictionary[$AssocId] } else { 'obfuscated' } } else { $AssocId.split('/')[8] }
                $AssociatedResourceType = $AssocId.split('/')[7]
            }
            else
            {
                $AssociatedResource = 'None'
                $AssociatedResourceType = 'None'
            }

            $Obj = @{
                'ID'                       = $1.id;
                'Subscription'             = $Sub1.Name;
                'ResourceGroup'            = $1.RESOURCEGROUP;
                'Name'                     = $1.NAME;
                'SKU'                      = $1.SKU.Name;
                'Location'                 = $1.LOCATION;
                'AllocationType'           = $Data.publicIPAllocationMethod;
                'Version'                  = $Data.publicIPAddressVersion;
                'ProvisioningState'        = $Data.provisioningState;
                'Use'                      = $Use;
                'AssociatedResource'       = $AssociatedResource;
                'AssociatedResourceType'   = $AssociatedResourceType;
            }

            [void]$Tmp.Add($Obj)
        }

        $Tmp
    }
}
