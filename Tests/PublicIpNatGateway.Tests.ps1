# Public IP association tests
# Run with: Invoke-Pester ./Tests/PublicIpNatGateway.Tests.ps1 -Output Detailed
#
# A public IP is attached through properties.ipConfiguration (a NIC, a load
# balancer frontend) or through properties.natGateway (a NAT gateway). A NAT
# gateway IP has no ipConfiguration, and Services/Networking/PublicIP.ps1 read
# only ipConfiguration, so it wrote such an IP as 'Utilized' but attached to
# 'None'. The NAT gateway is now read, and obfuscated the way an
# ipConfiguration id is. The REAL collector runs on synthetic records shaped as
# Resource Graph returns them; no live Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # The Azure documentation placeholder; not a real subscription id.
    $script:Guid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:Guid; Name = 'sub-placeholder' })
    $script:Rg = "/subscriptions/$($script:Guid)/resourceGroups/rg-a/providers"
    $script:NatId = "$($script:Rg)/Microsoft.Network/natGateways/nat-a"
    $script:NicCfgId = "$($script:Rg)/Microsoft.Network/networkInterfaces/nic-a/ipConfigurations/ipconfig1"

    function Invoke-Collector
    {
        param($Records, $Dictionary = $null)
        return , @(& (Join-Path $script:Root 'Services/Networking/PublicIP.ps1') -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $Dictionary)
    }

    # -IpConfiguration and -NatGateway are the property values; a switch -No*
    # leaves the property out, as Resource Graph does.
    function New-PublicIp
    {
        param($IpConfiguration, $NatGateway, [switch]$NoIpConfiguration, [switch]$NoNatGateway)
        $Props = [ordered]@{
            publicIPAllocationMethod = 'Static'
            publicIPAddressVersion   = 'IPv4'
            provisioningState        = 'Succeeded'
        }
        if (-not $NoIpConfiguration) { $Props['ipConfiguration'] = $IpConfiguration }
        if (-not $NoNatGateway) { $Props['natGateway'] = $NatGateway }
        return [pscustomobject]@{
            TYPE           = 'microsoft.network/publicipaddresses'
            id             = "$($script:Rg)/Microsoft.Network/publicIPAddresses/pip-a"
            NAME           = 'pip-a'
            RESOURCEGROUP  = 'rg-a'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            SKU            = [pscustomobject]@{ Name = 'Standard' }
            PROPERTIES     = [pscustomobject]$Props
        }
    }

    function New-Dictionary
    {
        param([hashtable]$Map = @{})
        $D = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        # A dictionary with an entry, as in an obfuscated run.
        $D["$($script:Rg)/Microsoft.Network/publicIPAddresses/pip-a"] = 'prod_pip-token'
        foreach ($K in $Map.Keys) { $D[$K] = $Map[$K] }
        return $D
    }
}

Describe 'Public IP on a NAT gateway' {
    It 'names the NAT gateway and its type' {
        $Rows = Invoke-Collector @(New-PublicIp -NoIpConfiguration -NatGateway ([pscustomobject]@{ id = $script:NatId }))
        $Rows.Count | Should -Be 1
        $Rows[0].Use | Should -BeExactly 'Utilized'
        $Rows[0].AssociatedResource | Should -BeExactly 'nat-a'
        $Rows[0].AssociatedResourceType | Should -BeExactly 'natGateways'
    }

    It 'writes the NAT gateway token when the dictionary has the NAT gateway id' {
        $Dict = New-Dictionary -Map @{ $script:NatId = 'prod_nat-token' }
        $Row = (Invoke-Collector @(New-PublicIp -NoIpConfiguration -NatGateway ([pscustomobject]@{ id = $script:NatId })) -Dictionary $Dict)[0]
        $Row.AssociatedResource | Should -BeExactly 'prod_nat-token'
        $Row.AssociatedResourceType | Should -BeExactly 'natGateways'
    }

    It 'writes obfuscated, never the name, when the dictionary lacks the NAT gateway id' {
        $Row = (Invoke-Collector @(New-PublicIp -NoIpConfiguration -NatGateway ([pscustomobject]@{ id = $script:NatId })) -Dictionary (New-Dictionary))[0]
        $Row.AssociatedResource | Should -BeExactly 'obfuscated'
        $Row.AssociatedResource | Should -Not -Match 'nat-a'
    }

    It 'finds the NAT gateway token when the id differs only in letter case' {
        $Dict = New-Dictionary -Map @{ $script:NatId = 'prod_nat-token' }
        $Row = (Invoke-Collector @(New-PublicIp -NoIpConfiguration -NatGateway ([pscustomobject]@{ id = $script:NatId.ToLowerInvariant() })) -Dictionary $Dict)[0]
        $Row.AssociatedResource | Should -BeExactly 'prod_nat-token'
    }

    It 'writes the NIC token for an ipConfiguration id whose NIC is in the dictionary' {
        $NicId = ($script:NicCfgId -split '/')[0..8] -join '/'
        $Dict = New-Dictionary -Map @{ $NicId = 'prod_nic-token' }
        $Row = (Invoke-Collector @(New-PublicIp -IpConfiguration ([pscustomobject]@{ id = $script:NicCfgId }) -NoNatGateway) -Dictionary $Dict)[0]
        $Row.AssociatedResource | Should -BeExactly 'prod_nic-token'
        $Row.AssociatedResourceType | Should -BeExactly 'networkInterfaces'
    }

    It 'finds the NIC token when the ipConfiguration id differs from the NIC key only in letter case' {
        $NicId = ($script:NicCfgId -split '/')[0..8] -join '/'
        $Dict = New-Dictionary -Map @{ $NicId = 'prod_nic-token' }
        $Row = (Invoke-Collector @(New-PublicIp -IpConfiguration ([pscustomobject]@{ id = $script:NicCfgId.ToUpperInvariant() }) -NoNatGateway) -Dictionary $Dict)[0]
        $Row.AssociatedResource | Should -BeExactly 'prod_nic-token'
    }

    It 'writes the load balancer token for a frontend ipConfiguration id' {
        $LbId = "$($script:Rg)/Microsoft.Network/loadBalancers/lb-a"
        $Dict = New-Dictionary -Map @{ $LbId = 'prod_lb-token' }
        $Row = (Invoke-Collector @(New-PublicIp -IpConfiguration ([pscustomobject]@{ id = "$LbId/frontendIPConfigurations/fe-a" }) -NoNatGateway) -Dictionary $Dict)[0]
        $Row.AssociatedResource | Should -BeExactly 'prod_lb-token'
        $Row.AssociatedResourceType | Should -BeExactly 'loadBalancers'
    }

    It 'names the NAT gateway when ipConfiguration is there with an empty id' {
        $Row = (Invoke-Collector @(New-PublicIp -IpConfiguration ([pscustomobject]@{ id = '' }) -NatGateway ([pscustomobject]@{ id = $script:NatId })))[0]
        $Row.AssociatedResource | Should -BeExactly 'nat-a'
        $Row.AssociatedResourceType | Should -BeExactly 'natGateways'
    }

    It 'leaves the link empty, as before, for an empty ipConfiguration id and no NAT gateway' {
        $Row = (Invoke-Collector @(New-PublicIp -IpConfiguration ([pscustomobject]@{ id = '' }) -NoNatGateway))[0]
        $Row.AssociatedResource | Should -BeNullOrEmpty
        $Row.AssociatedResourceType | Should -BeNullOrEmpty
    }

    It 'prefers ipConfiguration when both are set, as before' {
        $Row = (Invoke-Collector @(New-PublicIp -IpConfiguration ([pscustomobject]@{ id = $script:NicCfgId }) -NatGateway ([pscustomobject]@{ id = $script:NatId })))[0]
        $Row.AssociatedResource | Should -BeExactly 'nic-a'
        $Row.AssociatedResourceType | Should -BeExactly 'networkInterfaces'
    }

    It 'writes None when the NAT gateway is <Case>' -ForEach @(
        @{ Case = 'missing'; NoNat = $true; Nat = $null }
        @{ Case = 'null'; NoNat = $false; Nat = $null }
        @{ Case = 'an object with no id'; NoNat = $false; Nat = [pscustomobject]@{ name = 'nat-a' } }
        @{ Case = 'an empty id'; NoNat = $false; Nat = [pscustomobject]@{ id = '' } }
        @{ Case = 'a bare string'; NoNat = $false; Nat = 'nat-a' }
    ) {
        $Rows = Invoke-Collector @(New-PublicIp -NoIpConfiguration -NatGateway $Nat -NoNatGateway:$NoNat)
        $Rows.Count | Should -Be 1
        $Rows[0].Use | Should -BeExactly 'UnderUtilized'
        $Rows[0].AssociatedResource | Should -BeExactly 'None'
        $Rows[0].AssociatedResourceType | Should -BeExactly 'None'
    }

    It 'writes empty name and type for a NAT gateway id too short to hold them' {
        $Row = (Invoke-Collector @(New-PublicIp -NoIpConfiguration -NatGateway ([pscustomobject]@{ id = 'not-an-arm-id' })))[0]
        $Row.AssociatedResource | Should -BeNullOrEmpty
        $Row.AssociatedResourceType | Should -BeNullOrEmpty
    }
}

Describe 'Public IP rows that do not involve a NAT gateway' {
    It 'keeps a NIC-attached IP as before' {
        $Row = (Invoke-Collector @(New-PublicIp -IpConfiguration ([pscustomobject]@{ id = $script:NicCfgId }) -NoNatGateway))[0]
        $Row.Use | Should -BeExactly 'Utilized'
        $Row.AssociatedResource | Should -BeExactly 'nic-a'
        $Row.AssociatedResourceType | Should -BeExactly 'networkInterfaces'
    }

    It 'keeps obfuscated for a NIC ipConfiguration id not in the dictionary' {
        $Row = (Invoke-Collector @(New-PublicIp -IpConfiguration ([pscustomobject]@{ id = $script:NicCfgId }) -NoNatGateway) -Dictionary (New-Dictionary))[0]
        $Row.AssociatedResource | Should -BeExactly 'obfuscated'
    }

    It 'keeps empty name and type for an empty ipConfiguration id' {
        $Row = (Invoke-Collector @(New-PublicIp -IpConfiguration ([pscustomobject]@{ id = '' }) -NoNatGateway))[0]
        $Row.AssociatedResource | Should -BeNullOrEmpty
        $Row.AssociatedResourceType | Should -BeNullOrEmpty
    }

    It 'keeps None for an IP attached to nothing' {
        $Row = (Invoke-Collector @(New-PublicIp -NoIpConfiguration -NoNatGateway))[0]
        $Row.Use | Should -BeExactly 'UnderUtilized'
        $Row.AssociatedResource | Should -BeExactly 'None'
        $Row.AssociatedResourceType | Should -BeExactly 'None'
    }

    It 'leaves the other columns unchanged on a <Case> row' -ForEach @(
        @{ Case = 'NAT gateway'; Nic = $false; Nat = $true }
        @{ Case = 'NIC'; Nic = $true; Nat = $false }
        @{ Case = 'unattached'; Nic = $false; Nat = $false }
    ) {
        $Ip = if ($Nic) { New-PublicIp -IpConfiguration ([pscustomobject]@{ id = $script:NicCfgId }) -NoNatGateway }
        elseif ($Nat) { New-PublicIp -NoIpConfiguration -NatGateway ([pscustomobject]@{ id = $script:NatId }) }
        else { New-PublicIp -NoIpConfiguration -NoNatGateway }
        $Row = (Invoke-Collector @($Ip))[0]
        $Row.ID | Should -BeExactly "$($script:Rg)/Microsoft.Network/publicIPAddresses/pip-a"
        $Row.Subscription | Should -BeExactly 'sub-placeholder'
        $Row.ResourceGroup | Should -BeExactly 'rg-a'
        $Row.Name | Should -BeExactly 'pip-a'
        $Row.SKU | Should -BeExactly 'Standard'
        $Row.Location | Should -BeExactly 'eastus'
        $Row.AllocationType | Should -BeExactly 'Static'
        $Row.Version | Should -BeExactly 'IPv4'
        $Row.ProvisioningState | Should -BeExactly 'Succeeded'
        @($Row.Keys).Count | Should -Be 12
    }
}
