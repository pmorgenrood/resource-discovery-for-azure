param($Sub, $Resources, $Task, $ResourceIdDictionary)

if ($Task -eq 'Processing')
{
    $PublicIP = $Resources | Where-Object { $_.TYPE -eq 'microsoft.network/publicipaddresses' }

    if ($PublicIP)
    {
        $Tmp = @()

        # Azure resource ids ignore letter case, but the run's dictionary is keyed
        # as Resource Graph wrote each id. An id that misses is looked up again,
        # ignoring case, in a copy of the dictionary made on the first miss. No
        # token is found: 'obfuscated'.
        $IgnoreCase = @{ Map = $null }
        $GetLinkToken = {
            param([string]$Id)
            if ($ResourceIdDictionary.ContainsKey($Id)) { return $ResourceIdDictionary[$Id] }
            if ($null -eq $IgnoreCase.Map)
            {
                $IgnoreCase.Map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($Key in $ResourceIdDictionary.Keys) { if (-not $IgnoreCase.Map.ContainsKey($Key)) { $IgnoreCase.Map[$Key] = $ResourceIdDictionary[$Key] } }
            }
            if ($IgnoreCase.Map.ContainsKey($Id)) { return $IgnoreCase.Map[$Id] }
            return 'obfuscated'
        }

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
                $AssociatedResource = if ([string]::IsNullOrEmpty($AssocId)) { $null } elseif ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { & $GetLinkToken $AssocId } else { $AssocId.split('/')[8] }
                $AssociatedResourceType = if ([string]::IsNullOrEmpty($AssocId)) { $null } else { $AssocId.split('/')[7] }
            }
            elseif (-not [string]::IsNullOrEmpty([string]$Data.natGateway.id))
            {
                # Obfuscated the same way as an ipConfiguration id: the NAT gateway's
                # own token when the dictionary has it (letter case aside), else
                # 'obfuscated'.
                $AssocId = [string]$Data.natGateway.id
                $AssociatedResource = if ($null -ne $ResourceIdDictionary -and $ResourceIdDictionary.Count -gt 0) { & $GetLinkToken $AssocId } else { $AssocId.split('/')[8] }
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

            $Tmp += $Obj
        }

        $Tmp
    }
}
