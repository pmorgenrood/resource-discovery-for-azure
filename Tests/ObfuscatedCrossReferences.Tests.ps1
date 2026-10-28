# Obfuscated cross-reference tests: Front Door WAF policy and AVD session host name
# Run with: Invoke-Pester ./Tests/ObfuscatedCrossReferences.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Under -Obfuscate a cross-reference column must hold the token of the resource
# it points at, so it still joins to that resource's row and Reveal.ps1 can
# restore it:
#   - Frontdoor WebApplicationFirewall: a classic Front Door lists its WAF policy
#     link per frontend endpoint, so the property walk returns one id per linked
#     endpoint. Two or more linked endpoints (a default endpoint and a custom
#     domain, say) gave an array, which missed the dictionary lookup and wrote
#     'obfuscated'.
#   - AVD Hostname: in a plain run it is the backing VM's name, so under
#     -Obfuscate it must be the name token that VM's own row gets. It was a hash
#     of the VM id, which matched no row and no dictionary entry.
#
# The test invokes the REAL collectors with records shaped the way the
# inventory builds them (JSON text lowercased, then ConvertFrom-Json) and the
# id and name dictionaries keyed by real resource id, as RunInventorySetup in
# ResourceInventory.ps1 fills them before any collector runs. Tokens are made
# at run time; the subscription id is the documentation placeholder. No live
# Azure.

BeforeAll {
    $script:ServicesRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:SubId = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:SubId; Name = 'sub-demo' })

    function ConvertTo-InventoryRecord
    {
        param($Records)
        (ConvertTo-Json -InputObject @($Records) -Depth 20).ToLower() | ConvertFrom-Json
    }

    function New-Token { 'prod_' + [guid]::NewGuid().ToString() }

    # The masked id RunInventorySetup stores for a resource: the ARM shape with the
    # subscription, resource group and name segments replaced by tokens.
    function New-MaskedId
    {
        param([string]$RealId, [string]$NameToken)
        $Parts = $RealId.Split('/')
        $Parts[2] = New-Token
        $Parts[4] = New-Token
        $Parts[-1] = $NameToken
        $Parts -join '/'
    }

    function Invoke-Collector
    {
        param([string]$Path, $Records, $IdDictionary)
        @(& (Join-Path $script:ServicesRoot $Path) -Sub $script:Subs -Resources (ConvertTo-InventoryRecord $Records) -Task 'Processing' -ResourceIdDictionary $IdDictionary)
    }

    $Edge = "/subscriptions/$($script:SubId)/resourcegroups/rg-edge/providers"
    $script:WafA = "$Edge/microsoft.network/frontdoorwebapplicationfirewallpolicies/wafpolicya"
    $script:WafB = "$Edge/microsoft.network/frontdoorwebapplicationfirewallpolicies/wafpolicyb"

    function New-FrontDoor
    {
        # $Links: one entry per frontend endpoint; $null = no WAF link object,
        # '' = a link object with an empty id, else the linked policy id.
        param([string]$Name, [object[]]$Links)
        $i = 0
        $Endpoints = foreach ($Link in $Links)
        {
            $i++
            $Props = [ordered]@{ hostName = "$Name-$i.azurefd.net"; sessionAffinityEnabledState = 'Disabled' }
            if ($null -ne $Link) { $Props.webApplicationFirewallPolicyLink = @{ id = $Link } }
            [ordered]@{ name = "endpoint$i"; properties = $Props }
        }
        [ordered]@{
            id = "$Edge/microsoft.network/frontdoors/$Name"; name = $Name; type = 'microsoft.network/frontdoors'; location = 'global'
            subscriptionId = $script:SubId; resourceGroup = 'rg-edge'; properties = [ordered]@{ enabledState = 'Enabled'; frontendEndpoints = @($Endpoints) }
        }
    }

    function Get-WafColumn
    {
        param($FrontDoor, $IdDictionary)
        @(Invoke-Collector -Path 'Infrastructure/Frontdoor.ps1' -Records @($FrontDoor) -IdDictionary $IdDictionary)[0].WebApplicationFirewall
    }

    $script:WafDict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $script:WafATok = New-MaskedId $script:WafA (New-Token)
    $script:WafBTok = New-MaskedId $script:WafB (New-Token)
    $script:WafDict[$script:WafA] = $script:WafATok
    $script:WafDict[$script:WafB] = $script:WafBTok
}

Describe 'Front Door WAF policy column' {
    It 'holds the policy token when two endpoints link the same policy (obfuscated)' {
        Get-WafColumn (New-FrontDoor 'fd-two' @($script:WafA, $script:WafA)) $script:WafDict | Should -BeExactly $script:WafATok
    }

    It 'holds the policy token when one endpoint links it (obfuscated)' {
        Get-WafColumn (New-FrontDoor 'fd-one' @($script:WafA)) $script:WafDict | Should -BeExactly $script:WafATok
    }

    It 'holds the first linked policy when endpoints link different policies (obfuscated and plain)' {
        Get-WafColumn (New-FrontDoor 'fd-split' @($script:WafA, $script:WafB)) $script:WafDict | Should -BeExactly $script:WafATok
        Get-WafColumn (New-FrontDoor 'fd-split' @($script:WafA, $script:WafB)) $null | Should -BeExactly 'wafpolicya'
    }

    It 'skips an endpoint with no link or an empty link id' {
        Get-WafColumn (New-FrontDoor 'fd-mixed' @($null, '', $script:WafB)) $script:WafDict | Should -BeExactly $script:WafBTok
        Get-WafColumn (New-FrontDoor 'fd-mixed' @($null, '', $script:WafB)) $null | Should -BeExactly 'wafpolicyb'
    }

    It "writes 'False' when no endpoint has a link id" {
        Get-WafColumn (New-FrontDoor 'fd-none' @($null, '')) $script:WafDict | Should -BeExactly 'False'
        Get-WafColumn (New-FrontDoor 'fd-none' @($null)) $null | Should -BeExactly 'False'
    }

    It 'names the policy when two endpoints link it (plain)' {
        Get-WafColumn (New-FrontDoor 'fd-two' @($script:WafA, $script:WafA)) $null | Should -BeExactly 'wafpolicya'
    }

    It "writes 'obfuscated' for a policy that is not in the dictionary (obfuscated)" {
        $Other = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Other['/subscriptions/x/other'] = New-Token
        Get-WafColumn (New-FrontDoor 'fd-two' @($script:WafA, $script:WafA)) $Other | Should -BeExactly 'obfuscated'
    }
}

Describe 'AVD session host Hostname' {
    BeforeAll {
        $Avd = "/subscriptions/$($script:SubId)/resourcegroups/rg-avd/providers"
        $script:VmId = "$Avd/microsoft.compute/virtualmachines/avdhost-0"
        $script:AvdRecords = @(
            [ordered]@{
                id = "$Avd/microsoft.desktopvirtualization/hostpools/hp-demo"; name = 'hp-demo'; type = 'microsoft.desktopvirtualization/hostpools'; location = 'eastus'
                subscriptionId = $script:SubId; resourceGroup = 'rg-avd'; properties = [ordered]@{ hostPoolType = 'Pooled'; loadBalancerType = 'BreadthFirst'; maxSessionLimit = 10 }
            }
            [ordered]@{
                id = "$Avd/microsoft.desktopvirtualization/hostpools/hp-demo/sessionhosts/avdhost-0.contoso.example"; name = 'hp-demo/avdhost-0.contoso.example'
                type = 'microsoft.desktopvirtualization/hostpools/sessionhosts'; location = 'eastus'; subscriptionId = $script:SubId; resourceGroup = 'rg-avd'
                properties = [ordered]@{ resourceId = $script:VmId; agentVersion = '1.0.9'; status = 'Available' }
            }
            [ordered]@{
                id = $script:VmId; name = 'avdhost-0'; type = 'microsoft.compute/virtualmachines'; location = 'eastus'; subscriptionId = $script:SubId; resourceGroup = 'rg-avd'
                properties = [ordered]@{ hardwareProfile = @{ vmSize = 'Standard_D4s_v5' }; storageProfile = @{ osDisk = @{ osType = 'Windows'; managedDisk = @{ storageAccountType = 'Premium_LRS' } } } }
            }
        )
        $script:SavedNameDictionary = $Global:ResourceNameDictionary
    }

    AfterAll {
        $Global:ResourceNameDictionary = $script:SavedNameDictionary
    }

    BeforeEach {
        $script:VmName = New-Token
        $script:IdDict = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $script:IdDict[$script:VmId] = New-MaskedId $script:VmId $script:VmName
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary[$script:VmId] = $script:VmName
    }

    It "is the backing VM's name token, the Name that VM's row gets (obfuscated)" {
        $Row = @(Invoke-Collector -Path 'Compute/AVD.ps1' -Records $script:AvdRecords -IdDictionary $script:IdDict)[0]
        $Row.Hostname | Should -BeExactly $script:VmName
        $Row.HostId | Should -BeExactly $script:IdDict[$script:VmId]
    }

    It "is 'obfuscated' when the VM has no name token (obfuscated)" {
        $Global:ResourceNameDictionary.Clear()
        $Row = @(Invoke-Collector -Path 'Compute/AVD.ps1' -Records $script:AvdRecords -IdDictionary $script:IdDict)[0]
        $Row.Hostname | Should -BeExactly 'obfuscated'
        $Row.HostId | Should -BeExactly $script:IdDict[$script:VmId]
    }

    It "is 'obfuscated' when there is no name dictionary (obfuscated)" {
        $Global:ResourceNameDictionary = $null
        $Row = @(Invoke-Collector -Path 'Compute/AVD.ps1' -Records $script:AvdRecords -IdDictionary $script:IdDict)[0]
        $Row.Hostname | Should -BeExactly 'obfuscated'
    }

    It "is the VM's name, and HostId its id (plain)" {
        $Global:ResourceNameDictionary = $null
        $Row = @(Invoke-Collector -Path 'Compute/AVD.ps1' -Records $script:AvdRecords -IdDictionary $null)[0]
        $Row.Hostname | Should -BeExactly 'avdhost-0'
        $Row.HostId | Should -BeExactly $script:VmId
    }
}
