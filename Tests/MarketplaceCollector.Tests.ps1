#Requires -Version 7.0
<#
    MarketplaceCollector.Tests.ps1

    Tests for the Azure Marketplace collector: the row mapping in ConvertTo-RdaMarketplaceRow
    (Functions/ResourceInventory.Functions.ps1), the collector GetMarketplaceConsumption and the
    -SkipMarketplace wiring in ResourceInventory.ps1 and the wrapper scripts. The file this collector feeds is
    tested in ClaudeMarketplace.Tests.ps1.

    Get-AzConsumptionMarketplace returns rows shaped like PSMarketplace. The property names are the
    documented ones:
      https://learn.microsoft.com/en-us/powershell/module/az.billing/get-azconsumptionmarketplace
      https://learn.microsoft.com/en-us/rest/api/consumption/marketplaces/list

    Fully offline. No Azure calls: the cmdlets are replaced by mocks.
    Run with: Invoke-Pester ./Tests/MarketplaceCollector.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:InvPath = Join-Path $script:Repo 'ResourceInventory.ps1'
    . (Join-Path $script:Repo 'Functions/ResourceInventory.Functions.ps1')
    . (Join-Path $script:Repo 'Functions/Common.Functions.ps1')
    . (Join-Path $script:Repo 'Functions/ClaudeMarketplace.Functions.ps1')
    $script:InvSrc = Get-Content -LiteralPath $script:InvPath -Raw

    # Pulls one function out of a script by name, so the test runs the shipped code and not a copy.
    function script:Import-FunctionFromScript([string]$Path, [string[]]$Name)
    {
        $Tokens = $null; $ParseErrors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors)
        $Found = $Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -in $Name }, $true)
        @($Found).Count | Should -Be @($Name).Count
        $Text = ($Found | ForEach-Object { $_.Extent.Text }) -join "`n"
        return [scriptblock]::Create($Text)
    }

    . (script:Import-FunctionFromScript -Path $script:InvPath -Name 'Resolve-ObfuscationToken', 'Build-ObfuscatedResourceUri')

    function script:New-FakeClaudeRow
    {
        param([string]$Offer = 'Claude in Microsoft Foundry (Anthropic hosted)', [string]$InstanceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/contoso-saas-01')
        script:New-FakeMarketplaceRow -Publisher 'Anthropic' -Offer $Offer -Plan 'claude-ccu-anthropic-hosted-plan' -InstanceId $InstanceId
    }

    function script:New-FakeMarketplaceRow
    {
        param(
            [string]$Publisher = 'contoso',
            [string]$Offer = 'contoso-assistant-in-foundry',
            [string]$Plan = 'pay-as-you-go',
            [string]$InstanceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/contoso-saas-01',
            [string]$InstanceName = 'contoso-saas-01',
            [string]$ResourceGroup = 'rg-ai-prod',
            [string]$SubscriptionName = 'AI Production',
            [string]$SubscriptionGuid = '11111111-1111-1111-1111-111111111111'
        )
        [pscustomobject]@{
            PublisherName    = $Publisher
            OfferName        = $Offer
            PlanName         = $Plan
            OrderNumber      = 'ORD-4242'
            ConsumedService  = 'Microsoft.SaaS'
            ConsumedQuantity = 12.5
            UnitOfMeasure    = '1M Tokens'
            PretaxCost       = 87.33
            Currency         = 'USD'
            IsEstimated      = $false
            MeterId          = 'mtr-abcdef01'
            UsageStart       = ([datetime]'2026-08-01T00:00:00Z')
            UsageEnd         = ([datetime]'2026-08-31T23:59:59Z')
            SubscriptionGuid = $SubscriptionGuid
            SubscriptionName = $SubscriptionName
            ResourceGroup    = $ResourceGroup
            InstanceId       = $InstanceId
            InstanceName     = $InstanceName
        }
    }
}

Describe 'ConvertTo-RdaMarketplaceRow: field mapping without -Obfuscate' {

    It 'copies every field of the row' {
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$false

        $Out.PublisherName    | Should -Be 'contoso'
        $Out.OfferName        | Should -Be 'contoso-assistant-in-foundry'
        $Out.PlanName         | Should -Be 'pay-as-you-go'
        $Out.ConsumedService  | Should -Be 'Microsoft.SaaS'
        $Out.ConsumedQuantity | Should -Be 12.5
        $Out.UnitOfMeasure    | Should -Be '1M Tokens'
        $Out.PretaxCost       | Should -Be 87.33
        $Out.Currency         | Should -Be 'USD'
        $Out.IsEstimated      | Should -Be $false
        $Out.MeterId          | Should -Be 'mtr-abcdef01'
        $Out.UsageStart       | Should -Be ([datetime]'2026-08-01T00:00:00Z')
        $Out.UsageEnd         | Should -Be ([datetime]'2026-08-31T23:59:59Z')
        $Out.SubscriptionGuid | Should -Be '11111111-1111-1111-1111-111111111111'
        $Out.SubscriptionName | Should -Be 'AI Production'
        $Out.ResourceGroup    | Should -Be 'rg-ai-prod'
        $Out.InstanceId       | Should -Be '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/contoso-saas-01'
        $Out.InstanceName     | Should -Be 'contoso-saas-01'
    }

    It 'returns exactly the 17 columns, in order, with no order number' {
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$false
        $Expected = 'PublisherName,OfferName,PlanName,ConsumedService,ConsumedQuantity,UnitOfMeasure,PretaxCost,Currency,IsEstimated,MeterId,UsageStart,UsageEnd,SubscriptionGuid,SubscriptionName,ResourceGroup,InstanceId,InstanceName'
        (@($Out.PSObject.Properties.Name) -join ',') | Should -Be $Expected
    }
}

Describe 'ConvertTo-RdaMarketplaceRow: -Obfuscate' {

    BeforeEach {
        $script:Sub = @{}
        $script:Rg = @{}
        $script:Nm = @{}
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $script:SharedSubToken = 'prod_sub_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $script:SharedRgToken = 'prod_rg_bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $script:SubGuidTokenMap = @{ '11111111-1111-1111-1111-111111111111' = $script:SharedSubToken }
        $script:RgTokenMap = @{ 'rg-ai-prod' = $script:SharedRgToken }
    }

    AfterAll { $Global:FreeTextDictionary = $null }

    It 'leaves the product fields readable' {
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -SubGuidTokenMap $script:SubGuidTokenMap -RgTokenMap $script:RgTokenMap -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.PublisherName | Should -Be 'contoso'
        $Out.OfferName     | Should -Be 'contoso-assistant-in-foundry'
        $Out.PlanName      | Should -Be 'pay-as-you-go'
    }

    It 'gives the subscription guid and the subscription name the token the other files use' {
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -SubGuidTokenMap $script:SubGuidTokenMap -RgTokenMap $script:RgTokenMap -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.SubscriptionGuid | Should -Be $script:SharedSubToken
        $Out.SubscriptionName | Should -Be $script:SharedSubToken
    }

    It 'gives the resource group the token the other files use' {
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -SubGuidTokenMap $script:SubGuidTokenMap -RgTokenMap $script:RgTokenMap -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.ResourceGroup | Should -Be $script:SharedRgToken
    }

    It 'mints one local token for a subscription that no other file holds, and keeps it for the next row' {
        $Row = script:New-FakeMarketplaceRow -SubscriptionGuid '99999999-9999-9999-9999-999999999999'
        $A = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -SubGuidTokenMap @{} -RgTokenMap @{} -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $B = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -SubGuidTokenMap @{} -RgTokenMap @{} -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $A.SubscriptionGuid | Should -Not -Match '9999'
        $A.SubscriptionGuid | Should -Match '^prod_sub_'
        $A.SubscriptionGuid | Should -Be $B.SubscriptionGuid
        $A.SubscriptionName | Should -Be $A.SubscriptionGuid
    }

    It 'writes the instance id as an ARM path with no real part left' {
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -IdLookup @{} -SubGuidTokenMap $script:SubGuidTokenMap -RgTokenMap $script:RgTokenMap -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.InstanceId | Should -Match '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/'
        $Out.InstanceId | Should -Not -Match '(?i)11111111|rg-ai-prod|contoso-saas-01'
    }

    It 'uses the same subscription and group tokens in the instance id as in the subscription and group columns' {
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -IdLookup @{} -SubGuidTokenMap $script:SubGuidTokenMap -RgTokenMap $script:RgTokenMap -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.InstanceId | Should -BeLike ('/subscriptions/{0}/resourcegroups/{1}/providers/*' -f $script:SharedSubToken, $script:SharedRgToken)
        $Out.SubscriptionGuid | Should -Be $script:SharedSubToken
        $Out.ResourceGroup | Should -Be $script:SharedRgToken
    }

    It 'keeps the token of an id that was already masked, ignoring case, and does not nest it' {
        $Known = '/subscriptions/prod_sub_known/resourcegroups/prod_rg_known/providers/microsoft.saas/resources/prod_name_known'
        $Lookup = @{ '/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/RG-AI-PROD/providers/microsoft.saas/resources/CONTOSO-SAAS-01' = $Known }
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -IdLookup $Lookup -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.InstanceId | Should -BeExactly $Known
    }

    It 'keeps the plain file as Azure wrote it, with the leading slash Azure leaves out added' {
        $Row = script:New-FakeMarketplaceRow -InstanceId 'subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/RG-AI-PROD/providers/Microsoft.SaaS/resources/Contoso-01'
        (ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$false).InstanceId | Should -BeExactly '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/RG-AI-PROD/providers/Microsoft.SaaS/resources/Contoso-01'
    }

    It 'masks an instance id that is not an Azure id as free text, so the dictionary can undo it, and its name too' {
        $Row = script:New-FakeMarketplaceRow -InstanceId 'vault-name-only' -InstanceName 'vault-name-only'
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -IdLookup @{} -SubGuidTokenMap $script:SubGuidTokenMap -RgTokenMap $script:RgTokenMap -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.InstanceId | Should -Not -Match 'vault-name-only'
        $Out.InstanceName | Should -Not -Match 'vault-name-only'
        $Global:FreeTextDictionary['vault-name-only'] | Should -Be $Out.InstanceId
        $Out.InstanceName | Should -Be $Out.InstanceId
    }

    It 'has no canonical id for an empty or non-Azure instance id, and masks the name of an empty-id row as free text' {
        Get-RdaMarketplaceCanonicalId -Row (script:New-FakeMarketplaceRow -InstanceId '/providers/Microsoft.SaaS/resources/abc') | Should -BeNullOrEmpty
        Get-RdaMarketplaceCanonicalId -Row (script:New-FakeMarketplaceRow -InstanceId '') | Should -BeNullOrEmpty
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow -InstanceId '' -InstanceName 'real-instance') -Obfuscate:$true -IdLookup @{} -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.InstanceId | Should -BeNullOrEmpty
        $Out.InstanceName | Should -Not -Match 'real-instance'
        $Global:FreeTextDictionary['real-instance'] | Should -Be $Out.InstanceName
    }

    It 'gives the subscription and group columns the tokens of an id that Consumption already masked and the inventory did not hold' {
        $Masked = '/subscriptions/prod_sub_consumption/resourcegroups/prod_rg_consumption/providers/microsoft.saas/resources/prod_name_c'
        $Lookup = @{ '/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-ai-prod/providers/microsoft.saas/resources/contoso-saas-01' = $Masked }
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -IdLookup $Lookup -SubCache @{} -RgCache @{} -NameCache @{}
        $Out.InstanceId | Should -Be $Masked
        $Out.SubscriptionGuid | Should -Be 'prod_sub_consumption'
        $Out.ResourceGroup | Should -Be 'prod_rg_consumption'
    }

    It 'gives the same canonical id to the same row whatever the case or the leading slash' {
        $A = Get-RdaMarketplaceCanonicalId -Row (script:New-FakeMarketplaceRow -InstanceId 'subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.SaaS/resources/x')
        $B = Get-RdaMarketplaceCanonicalId -Row (script:New-FakeMarketplaceRow -InstanceId '/SUBSCRIPTIONS/11111111-1111-1111-1111-111111111111/RESOURCEGROUPS/RG/providers/microsoft.saas/resources/X')
        $A | Should -BeExactly '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.SaaS/resources/x'
        $A | Should -BeLike $B
    }

    It 'masks the provider in lower case, as a usage row does' {
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -IdLookup @{} -SubGuidTokenMap $script:SubGuidTokenMap -RgTokenMap $script:RgTokenMap -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.InstanceId | Should -Match '/providers/microsoft\.saas/resources/'
    }

    It 'gives the instance name the name token of an id that was already masked' {
        $Known = '/subscriptions/prod_sub_known/resourcegroups/prod_rg_known/providers/microsoft.saas/resources/prod_name_known'
        $Lookup = @{ '/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-ai-prod/providers/microsoft.saas/resources/contoso-saas-01' = $Known }
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -IdLookup $Lookup -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.InstanceName | Should -BeExactly 'prod_name_known'
    }

    It 'keeps the instance name token of the first row for later rows of the same instance' {
        $Lookup = @{}
        $A = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -IdLookup $Lookup -SubGuidTokenMap $script:SubGuidTokenMap -RgTokenMap $script:RgTokenMap -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Lookup[(Get-RdaMarketplaceResourceId -InstanceId (script:New-FakeMarketplaceRow).InstanceId)] = $A.InstanceId
        $B = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -IdLookup $Lookup -SubGuidTokenMap $script:SubGuidTokenMap -RgTokenMap $script:RgTokenMap -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $B.InstanceName | Should -BeExactly $A.InstanceName
        ($A.InstanceId -split '/')[-1] | Should -BeExactly $A.InstanceName
    }

    It 'masks an id that Azure writes without its leading slash as an ARM path' {
        $Row = script:New-FakeMarketplaceRow -InstanceId 'subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/contoso-saas-01'
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -IdLookup @{} -SubGuidTokenMap $script:SubGuidTokenMap -RgTokenMap $script:RgTokenMap -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.InstanceId | Should -BeLike ('/subscriptions/{0}/resourcegroups/{1}/providers/*' -f $script:SharedSubToken, $script:SharedRgToken)
    }

    It 'uses the name token of the inventory resource when the id is in the name dictionary' {
        $Names = @{ '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/contoso-saas-01' = 'prod_name_inventory' }
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -IdLookup @{} -NameDictionary $Names -SubGuidTokenMap $script:SubGuidTokenMap -RgTokenMap $script:RgTokenMap -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.InstanceId | Should -BeLike '*/resources/prod_name_inventory'
    }

    It 'masks the instance name, and the same name gets the same token' {
        $Row = script:New-FakeMarketplaceRow
        $A = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $B = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $A.InstanceName | Should -Not -Be 'contoso-saas-01'
        $A.InstanceName | Should -Be $B.InstanceName
    }

    It 'does not write the order number, and adds nothing to the free-text dictionary' {
        $Out = ConvertTo-RdaMarketplaceRow -Row (script:New-FakeMarketplaceRow) -Obfuscate:$true -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        @($Out.PSObject.Properties.Name) | Should -Not -Contain 'OrderNumber'
        $Global:FreeTextDictionary.Count | Should -Be 0
    }

    It 'marks a dev instance nonprod_' {
        $Row = script:New-FakeMarketplaceRow -InstanceName 'contoso-dev-01' -ResourceGroup 'rg-dev'
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.InstanceName | Should -Match '^nonprod_'
    }

    It 'masks an empty field to an empty field' {
        $Row = script:New-FakeMarketplaceRow -InstanceId '' -InstanceName '' -ResourceGroup ''
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -SubCache $script:Sub -RgCache $script:Rg -NameCache $script:Nm
        $Out.InstanceId | Should -BeNullOrEmpty
        $Out.InstanceName | Should -BeNullOrEmpty
        $Out.ResourceGroup | Should -BeNullOrEmpty
    }
}

Describe 'GetMarketplaceConsumption' {

    BeforeAll {
        # Stand-ins so the collector runs offline. Pester can mock a command only when it exists.
        function Test-DataPlaneAuthReady { param([string]$Phase) $true }
        function Set-AzContext { param($Subscription, $ErrorAction) $script:CurrentSub = $Subscription }
        function Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $script:CurrentSub } } }
        function Get-AzConsumptionMarketplace { param($StartDate, $EndDate, $ResourceGroup, $ErrorAction) }
        function Get-UsageAggregates { param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken, $ErrorAction) }
        Mock Start-Sleep { }
        $script:Logged = [System.Collections.Generic.List[string]]::new()
        Mock Write-Log { $script:Logged.Add("$Severity|$Message") }

        . (script:Import-FunctionFromScript -Path $script:InvPath -Name 'GetMarketplaceConsumption', 'Add-MarketplaceDictionaryEntries', 'Add-ClaudeMarketplaceError', 'GetResorceConsumption')
    }

    BeforeEach {
        $script:Logged.Clear()
        $script:CurrentSub = $null
        $Global:MarketplaceRecordCount = 0
        $Global:MarketplaceFailedSubs = @()
        $script:ClaudeRows = $null
        $script:ClaudeErrors = $null
        $Global:Subscriptions = @(
            [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name = 'AI Production' },
            [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222'; Name = 'Other' }
        )
        $Global:ResourceIdDictionary = $null
        $Global:ResourceSubscriptionDictionary = $null
        $Global:ResourceResourceGroupDictionary = $null
        $script:Obfuscate = [pscustomobject]@{ IsPresent = $false }
        $script:SubscriptionID = $null
        $script:ResourceGroup = $null
        $script:ConsumptionWindowStart = $null
        $script:ConsumptionWindowEnd = $null
        $script:MarketplaceIdLookup = $null
        $script:MarketplaceSubCache = $null
        $script:MarketplaceRgCache = $null
        $script:MarketplaceNameCache = $null
        $Global:ResourceNameDictionary = $null
    }

    It 'keeps one record per Claude row, counts them, and leaves out other publishers' {
        Mock Get-AzConsumptionMarketplace { @((script:New-FakeClaudeRow), (script:New-FakeClaudeRow -Offer 'second-offer'), (script:New-FakeMarketplaceRow)) } -ParameterFilter { $true }
        $script:SubscriptionID = '11111111-1111-1111-1111-111111111111'
        GetMarketplaceConsumption
        $Rows = @($script:ClaudeRows)
        $Rows.Count | Should -Be 2
        $Rows[0].OfferName | Should -Be 'Claude in Microsoft Foundry (Anthropic hosted)'
        $Rows[1].OfferName | Should -Be 'second-offer'
        $script:ClaudeOtherRowsSkipped | Should -Be 1
        $Global:MarketplaceRecordCount | Should -Be 2
        @($Global:MarketplaceFailedSubs).Count | Should -Be 0
    }

    It 'asks for the window the consumption phase read, as UTC dates, and passes no -Top' {
        $script:SubscriptionID = '11111111-1111-1111-1111-111111111111'
        $script:ConsumptionWindowStart = [datetime]'2026-05-01T00:00:00'
        $script:ConsumptionWindowEnd = [datetime]'2026-05-31T00:00:00'
        Mock Get-AzConsumptionMarketplace { @() }
        GetMarketplaceConsumption
        Should -Invoke Get-AzConsumptionMarketplace -Times 1 -Exactly -ParameterFilter { $StartDate -eq [datetime]'2026-05-01' -and $StartDate.Kind -eq 'Utc' -and $EndDate -eq [datetime]'2026-06-01' -and $EndDate.Kind -eq 'Utc' -and -not $PSBoundParameters.ContainsKey('Top') -and -not $PSBoundParameters.ContainsKey('ResourceGroup') }
    }

    It 'asks for real dates when the window comes from the consumption phase itself, not from a test value' {
        $script:SubscriptionID = '11111111-1111-1111-1111-111111111111'
        Mock Get-UsageAggregates { [pscustomobject]@{ UsageAggregations = [pscustomobject]@{ Properties = @() } } }
        Mock Get-AzConsumptionMarketplace { @() }
        $Global:ConsumptionFileCsv = Join-Path ([System.IO.Path]::GetTempPath()) ("Consumption_{0}.csv" -f [guid]::NewGuid())
        $Global:ConsumptionRecordCount = 0
        $Global:ConsumptionFailedSubs = @()
        GetResorceConsumption
        GetMarketplaceConsumption
        Should -Invoke Get-AzConsumptionMarketplace -Times 1 -Exactly -ParameterFilter { $StartDate -is [datetime] -and $EndDate -is [datetime] -and $StartDate -eq (Get-Date).AddDays(-31).Date -and $EndDate -eq [datetime]::new([math]::Min((Get-Date).Date.Ticks, [datetime]::UtcNow.Date.Ticks)) }
        $script:ConsumptionWindowStart | Should -BeOfType [datetime]
        $script:ConsumptionWindowEnd | Should -BeOfType [datetime]
        Remove-Item -LiteralPath $Global:ConsumptionFileCsv -ErrorAction SilentlyContinue
    }

    It 'falls back to the 31 days that end yesterday when the consumption phase did not run' {
        $script:SubscriptionID = '11111111-1111-1111-1111-111111111111'
        Mock Get-AzConsumptionMarketplace { @() }
        GetMarketplaceConsumption
        Should -Invoke Get-AzConsumptionMarketplace -Times 1 -Exactly -ParameterFilter { $StartDate -eq (Get-Date).AddDays(-31).Date -and $EndDate -eq [datetime]::new([math]::Min((Get-Date).Date.Ticks, [datetime]::UtcNow.Date.Ticks)) }
    }

    It 'asks for one resource group when -ResourceGroup is set' {
        $script:SubscriptionID = '11111111-1111-1111-1111-111111111111'
        $script:ResourceGroup = 'rg-ai-prod'
        Mock Get-AzConsumptionMarketplace { @() }
        GetMarketplaceConsumption
        Should -Invoke Get-AzConsumptionMarketplace -Times 1 -Exactly -ParameterFilter { $ResourceGroup -eq 'rg-ai-prod' }
    }

    It 'visits every subscription when no -SubscriptionID is given' {
        Mock Get-AzConsumptionMarketplace { @() }
        GetMarketplaceConsumption
        Should -Invoke Get-AzConsumptionMarketplace -Times 2 -Exactly
    }

    It 'says only that the endpoint returned no rows when no subscription failed and no row came back' {
        Mock Get-AzConsumptionMarketplace { @() }
        GetMarketplaceConsumption
        ($script:Logged -join "`n") | Should -Match 'returned no Anthropic/Claude rows'
        ($script:Logged -join "`n") | Should -Match 'does not show that no Marketplace charge exists'
        ($script:Logged -join "`n") | Should -Not -Match '(?i)confirmed zero'
        @($script:ClaudeRows).Count | Should -Be 0
        @($script:ClaudeErrors).Count | Should -Be 0
    }

    It 'records a subscription that keeps failing after the retries, and does not report it as an empty answer' {
        Mock Get-AzConsumptionMarketplace { throw 'TooManyRequests' }
        $script:SubscriptionID = '11111111-1111-1111-1111-111111111111'
        GetMarketplaceConsumption
        @($Global:MarketplaceFailedSubs).Count | Should -Be 1
        $Global:MarketplaceFailedSubs[0].Id | Should -Be '11111111-1111-1111-1111-111111111111'
        $Global:MarketplaceFailedSubs[0].Message | Should -Match 'INCOMPLETE'
        @($script:ClaudeErrors).Count | Should -Be 1
        $script:ClaudeErrors[0].Source | Should -Be 'Marketplace'
        $script:ClaudeErrors[0].Scope | Should -Be '11111111-1111-1111-1111-111111111111'
        Should -Invoke Get-AzConsumptionMarketplace -Times 4 -Exactly
        Should -Invoke Start-Sleep -Times 3 -Exactly
        ($script:Logged -join "`n") | Should -Not -Match 'returned no rows'
    }

    It 'records no masked id for a row that has no instance id' {
        $Row = script:New-FakeMarketplaceRow -InstanceId ''
        $script:MarketplaceIdLookup = @{}
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -IdLookup $script:MarketplaceIdLookup -SubCache @{} -RgCache @{} -NameCache @{}
        Add-MarketplaceDictionaryEntries -Row $Row -ExportRow $Out -SubscriptionId '11111111-1111-1111-1111-111111111111'
        $Global:ResourceIdDictionary.Count | Should -Be 0
        $script:MarketplaceIdLookup.Count | Should -Be 0
        @($Global:ResourceIdDictionary.Values) | Should -Not -Contain ''
        $Global:FreeTextDictionary = $null
    }

    It 'masks an instance id that is not an Azure id as free text' {
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Row = script:New-FakeMarketplaceRow -InstanceId 'vault-name-only'
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -IdLookup @{} -SubCache @{} -RgCache @{} -NameCache @{}
        $Out.InstanceId | Should -Not -Match 'vault-name-only'
        $Global:FreeTextDictionary = $null
    }

    It 'says that an agreement type the endpoint does not serve is not available, and does not repeat the call' {
        Mock Get-AzConsumptionMarketplace { throw 'BadRequest: Cost Management supports only Enterprise Agreement, Web direct and Microsoft Customer Agreement offer types' }
        $script:SubscriptionID = '11111111-1111-1111-1111-111111111111'
        GetMarketplaceConsumption
        Should -Invoke Get-AzConsumptionMarketplace -Times 1 -Exactly
        $Global:MarketplaceFailedSubs[0].Message | Should -Match "not available for this subscription's agreement type, so none were collected"
    }

    It 'does not repeat a call that fails with <Text>' -ForEach @(
        @{ Text = 'a 403'; Message = 'Response status code does not indicate success: 403 (Forbidden).' }
        @{ Text = 'a 400'; Message = 'BadRequest: Cost Management supports only Enterprise Agreement, Web direct and Microsoft Customer Agreement offer types' }
        @{ Text = 'a 401'; Message = 'Unauthorized' }
        @{ Text = 'a 404'; Message = 'NotFound' }
    ) {
        Mock Get-AzConsumptionMarketplace { throw $Message }
        $script:SubscriptionID = '11111111-1111-1111-1111-111111111111'
        GetMarketplaceConsumption
        Should -Invoke Get-AzConsumptionMarketplace -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
        @($Global:MarketplaceFailedSubs).Count | Should -Be 1
    }

    It 'keeps the rows of a subscription that worked when the next one fails' {
        $script:Calls = 0
        Mock Get-AzConsumptionMarketplace { $script:Calls++; if ($script:Calls -eq 1) { @(script:New-FakeClaudeRow) } else { throw 'Forbidden' } }
        GetMarketplaceConsumption
        $Global:MarketplaceRecordCount | Should -Be 1
        @($script:ClaudeRows).Count | Should -Be 1
        @($Global:MarketplaceFailedSubs).Count | Should -Be 1
        $Global:MarketplaceFailedSubs[0].Id | Should -Be '22222222-2222-2222-2222-222222222222'
    }

    It 'records a -SubscriptionID that is not in the list as a failure' {
        $script:SubscriptionID = '33333333-3333-3333-3333-333333333333'
        Mock Get-AzConsumptionMarketplace { @() }
        GetMarketplaceConsumption
        $script:ClaudeErrors[0].Scope | Should -Be '33333333-3333-3333-3333-333333333333'
        $script:ClaudeErrors[0].Source | Should -Be 'Marketplace'
    }

    It 'records the same failure in the global list' {
        $script:SubscriptionID = '33333333-3333-3333-3333-333333333333'
        Mock Get-AzConsumptionMarketplace { @() }
        GetMarketplaceConsumption
        Should -Invoke Get-AzConsumptionMarketplace -Times 0 -Exactly
        @($Global:MarketplaceFailedSubs).Count | Should -Be 1
        ($script:Logged -join "`n") | Should -Not -Match 'returned no rows'
    }

    It 'skips a subscription it cannot switch to, and does not read another subscription in its place' {
        Mock Get-AzConsumptionMarketplace { @(script:New-FakeClaudeRow) }
        Mock Set-AzContext { throw 'no access' }
        $script:SubscriptionID = '11111111-1111-1111-1111-111111111111'
        GetMarketplaceConsumption
        Should -Invoke Get-AzConsumptionMarketplace -Times 0 -Exactly
        @($Global:MarketplaceFailedSubs).Count | Should -Be 1
        $Global:MarketplaceRecordCount | Should -Be 0
    }

    Context 'masked ids across rows and files' {
        BeforeEach {
            $script:Obfuscate = [pscustomobject]@{ IsPresent = $true }
            $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
            $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
            $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
            $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
            $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
            $script:SubscriptionID = '11111111-1111-1111-1111-111111111111'
        }
        AfterEach { $Global:FreeTextDictionary = $null }

        It 'gives every daily row of one instance the same masked id, a clean ARM path' {
            Mock Get-AzConsumptionMarketplace { @((script:New-FakeClaudeRow), (script:New-FakeClaudeRow), (script:New-FakeClaudeRow)) }
            GetMarketplaceConsumption
            $Ids = @(@($script:ClaudeRows) | ForEach-Object { $_.InstanceId } | Select-Object -Unique)
            $Ids.Count | Should -Be 1
            $Ids[0] | Should -Match '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.saas/resources/[^/]+$|^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/Microsoft\.SaaS/resources/[^/]+$'
            $Ids[0] | Should -Not -Match '//'
            $Global:ResourceIdDictionary['/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/contoso-saas-01'] | Should -Be $Ids[0]
        }

        It 'writes the inventory token for an id the inventory holds, even when the billing id differs in case' {
            $InvToken = '/subscriptions/prod_sub_inv/resourcegroups/prod_rg_inv/providers/microsoft.saas/resources/prod_name_inv'
            $Global:ResourceIdDictionary['/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-ai-prod/providers/microsoft.saas/resources/contoso-saas-01'] = $InvToken
            Mock Get-AzConsumptionMarketplace { @(script:New-FakeClaudeRow) }
            GetMarketplaceConsumption
            @($script:ClaudeRows)[0].InstanceId | Should -BeExactly $InvToken
        }

        It 'makes an ARM path of an id Azure writes without its leading slash' {
            Mock Get-AzConsumptionMarketplace { @(script:New-FakeClaudeRow -InstanceId 'subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/contoso-saas-01') }
            GetMarketplaceConsumption
            @($script:ClaudeRows)[0].InstanceId | Should -Match '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/'
        }

        It 'adds every token the inventory did not make to the dictionaries, so each one can be revealed' {
            Mock Get-AzConsumptionMarketplace { @(script:New-FakeClaudeRow) }
            GetMarketplaceConsumption
            $Row = @($script:ClaudeRows)[0]
            $Global:ResourceSubscriptionDictionary['/subscriptions/11111111-1111-1111-1111-111111111111'] | Should -Be $Row.SubscriptionGuid
            $Global:ResourceResourceGroupDictionary['/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-ai-prod'] | Should -Be $Row.ResourceGroup
            @($Global:ResourceNameDictionary.Values) | Should -Contain $Row.InstanceName
            @($Global:ResourceIdDictionary.Values) | Should -Contain $Row.InstanceId
            $Global:FreeTextDictionary.Count | Should -Be 0
        }
    }

    It 'masks the written rows under -Obfuscate' {
        $script:Obfuscate = [pscustomobject]@{ IsPresent = $true }
        $Global:FreeTextDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceIdDictionary = @{}
        $Global:ResourceSubscriptionDictionary = @{ '/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-ai-prod/providers/x/y/z' = 'prod_sub_tok' }
        $Global:ResourceResourceGroupDictionary = @{ '/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-ai-prod/providers/x/y/z' = 'prod_rg_tok' }
        Mock Get-AzConsumptionMarketplace { @(script:New-FakeClaudeRow) }
        $script:SubscriptionID = '11111111-1111-1111-1111-111111111111'
        GetMarketplaceConsumption
        $Text = $script:ClaudeRows | ConvertTo-Json -Depth 4
        $Text | Should -Not -Match '(?i)11111111|rg-ai-prod|contoso-saas-01|AI Production|ORD-4242'
        $Text | Should -Match 'prod_sub_tok'
        $Text | Should -Match 'prod_rg_tok'
        $Text | Should -Match 'Claude in Microsoft Foundry'
        $Global:ResourceIdDictionary['/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/contoso-saas-01'] | Should -Match '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/'
        $Global:FreeTextDictionary = $null
    }
}

Describe 'Marketplace wiring' {

    It 'ResourceInventory.ps1 takes -SkipMarketplace as a switch' {
        $Tokens = $null; $ParseErrors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InvPath, [ref]$Tokens, [ref]$ParseErrors)
        $Param = $Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SkipMarketplace' }
        $Param | Should -Not -BeNullOrEmpty
        $Param.StaticType.Name | Should -Be 'SwitchParameter'
    }

    It 'runs the collector only when neither -SkipConsumption nor -SkipMarketplace was passed' {
        $script:InvSrc | Should -Match '(?s)if \(!\$SkipConsumption\.IsPresent\)\s*\{.*?GetResorceConsumption.*?if \(!\$SkipMarketplace\.IsPresent\)\s*\{.*?GetMarketplaceConsumption'
    }

    It 'names the Claude Marketplace file so no reader of another file takes it' {
        $script:InvSrc.Contains('$Global:ClaudeMarketplaceFile = ($DefaultPath + "ClaudeMarketPlace_" + ([regex]::Replace($Global:ReportName, ''inventory'', ''Inv'', ''IgnoreCase, CultureInvariant'')) + "_" + $CurrentDateTime + ".json")') | Should -BeTrue
        # A report name that holds the word Inventory does not put it in the file name.
        $Old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            [regex]::Replace('MYINVENTORY', 'inventory', 'Inv', 'IgnoreCase, CultureInvariant') | Should -Be 'MYInv'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $Old }
        $Name = 'ClaudeMarketPlace_ResourcesReport_20260101_000000.json'
        $Name | Should -Not -BeLike '*Inventory*'
        $Name | Should -Not -BeLike 'Metrics*'
        $Name | Should -Not -BeLike 'Consumption*'
        $Name | Should -BeLike '*.json'
    }

    It 'takes the file into the zip with the other JSON files, with and without -Obfuscate' {
        $script:InvSrc | Should -Not -Match 'ClaudeMarketplaceFile\s*[,)]\s*\+|\$Global:ConsumptionFileCsv, \$Global:ClaudeMarketplaceFile'
        ([regex]::Matches($script:InvSrc, '\$JsonWildCard = \$DefaultPath \+ "\*\.json"')).Count | Should -Be 1
        $script:InvSrc | Should -Match '\$Global:ConsumptionFileCsv, \$JsonWildCard\)'
        $script:InvSrc.Contains('$_.Name -notlike "ObfuscationDictionary_*"') | Should -BeTrue
    }

    It 'writes the file with empty lists and a reason when it was skipped or not written' {
        $script:InvSrc | Should -Match '(?s)\$SkipConsumption\.IsPresent -or \$SkipMarketplace\.IsPresent -or !\(Test-Path -LiteralPath \$Global:ClaudeMarketplaceFile\).*?Write-RdaClaudeMarketplaceFile .*?-Rows @\(\) -TokenUsage @\(\) -Errors \$ClaudeFallbackErrors -NotCollected'
    }

    It 'leaves the consumption writer as main wrote it' {
        $script:InvSrc.Contains('$NewUsageDataExport | Select-Object InstanceData, MeterCategory, MeterId, MeterName, MeterRegion, MeterSubCategory, Quantity, Unit, UsageStartTime, UsageEndTime, ResourceId, ResourceLocation, ConsumptionMeter, ReservationId, ReservationOrderId | Export-Csv $Global:ConsumptionFileCsv -Encoding utf8 -Append -NoTypeInformation') | Should -BeTrue
    }

    It 'adds a dictionary entry only for a token no entry holds, so the inventory entries stay as they are' {
        . (script:Import-FunctionFromScript -Path $script:InvPath -Name 'Add-MarketplaceDictionaryEntries')
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary['/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-ai-prod/providers/x/y/z'] = 'prod_sub_known'
        $Global:ResourceResourceGroupDictionary['/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-ai-prod/providers/x/y/z'] = 'prod_rg_known'
        $script:MarketplaceIdLookup = @{}
        try
        {
            $Row = script:New-FakeClaudeRow
            $Out = [pscustomobject]@{ SubscriptionGuid = 'prod_sub_known'; ResourceGroup = 'prod_rg_known'; InstanceId = '/subscriptions/prod_sub_known/resourcegroups/prod_rg_known/providers/microsoft.saas/resources/tok'; InstanceName = 'tok' }
            Add-MarketplaceDictionaryEntries -Row $Row -ExportRow $Out
            $Global:ResourceSubscriptionDictionary.Count | Should -Be 1
            $Global:ResourceResourceGroupDictionary.Count | Should -Be 1
            $Out2 = [pscustomobject]@{ SubscriptionGuid = 'prod_sub_new'; ResourceGroup = 'prod_rg_new'; InstanceId = '/subscriptions/prod_sub_new/resourcegroups/prod_rg_new/providers/microsoft.saas/resources/tok2'; InstanceName = 'tok2' }
            Add-MarketplaceDictionaryEntries -Row $Row -ExportRow $Out2
            $Global:ResourceSubscriptionDictionary.Count | Should -Be 2
        }
        finally { $Global:ResourceIdDictionary = $null; $Global:ResourceNameDictionary = $null; $Global:ResourceSubscriptionDictionary = $null; $Global:ResourceResourceGroupDictionary = $null }
    }

    It 'counts only the consumption failures of this call, and takes the consumption caches into the Marketplace caches' {
        $script:InvSrc | Should -Match '(?s)\$script:ConsumptionFailuresBefore = .*?GetResorceConsumption'
        $script:InvSrc | Should -Match 'Select-Object -Skip \(\[int\]\$script:ConsumptionFailuresBefore\)'
        $script:InvSrc | Should -Match '@\(\$script:ConsumptionSubCache, \$script:MarketplaceSubCache\)'
    }

    It 'writes no Azure text and no name of a Marketplace failure into an obfuscated diagnostics log' {
        $Dir = (Join-Path ([System.IO.Path]::GetTempPath()) ('MpDiag_' + [guid]::NewGuid().ToString('N'))) + [System.IO.Path]::DirectorySeparatorChar
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary['/subscriptions/11111111-1111-1111-1111-111111111111'] = 'prod_sub_tok'
        $Global:ResourceResourceGroupDictionary['/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg-secret-group'] = 'prod_rg_tok'
        $Global:MarketplaceFailedSubs = @([pscustomobject]@{ Name = 'x'; Id = '(x)'; Message = 'request for group rg-secret-group failed' })
        try
        {
            $Log = Write-RdaShareableDiagnosticsLog -DefaultPath $Dir -ReportName 'T' -RunDateTime '20260101_000000' -Version '1.0.0' -PhaseTimings ([ordered]@{}) -Obfuscated 6>$null
            $Text = Get-Content -LiteralPath $Log -Raw
            $Text | Should -Not -Match 'rg-secret-group'
            $Text | Should -Match 'could not be read for this subscription'
        }
        finally
        {
            $Global:MarketplaceFailedSubs = @(); $Global:ResourceIdDictionary = $null; $Global:ResourceNameDictionary = $null; $Global:ResourceSubscriptionDictionary = $null; $Global:ResourceResourceGroupDictionary = $null
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'lists only the failures of this call in the diagnostics log' {
        $Dir = (Join-Path ([System.IO.Path]::GetTempPath()) ('MpDiag_' + [guid]::NewGuid().ToString('N'))) + [System.IO.Path]::DirectorySeparatorChar
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Global:MarketplaceFailedSubs = @([pscustomobject]@{ Name = 'a'; Id = 'earlier-call'; Message = 'from an earlier call' }, [pscustomobject]@{ Name = 'b'; Id = 'this-call'; Message = 'from this call' })
        $script:MarketplaceFailuresBefore = 1
        try
        {
            $Log = Write-RdaShareableDiagnosticsLog -DefaultPath $Dir -ReportName 'T' -RunDateTime '20260101_000000' -Version '1.0.0' -PhaseTimings ([ordered]@{}) 6>$null
            $Text = Get-Content -LiteralPath $Log -Raw
            $Text | Should -Match 'Marketplace failed/incomplete subscriptions: 1'
            $Text | Should -Match 'from this call'
            $Text | Should -Not -Match 'from an earlier call'
        }
        finally { $Global:MarketplaceFailedSubs = @(); $script:MarketplaceFailuresBefore = 0; Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'shows a Marketplace sign-in skip as a warning and leaves it out of the exit code' {
        $Wrapper = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.ps1') -Raw
        $Wrapper | Should -Match 'MarketplaceAuthSkipped.count -gt 0|\$MarketplaceAuthSkipped\.Count -gt 0'
        $Wrapper | Should -Not -Match "AuthSkippedPhases \+= 'Marketplace'"
        # Only the metrics and consumption skips and the collector failures reach the exit code.
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        Get-WrapperExitCode -AuthSkipped $false -CollectorsFailed $false | Should -Be 0
        $Wrapper | Should -Match '-MarketplaceFailedSubs \$Global:MarketplaceFailedSubs `\s+-MetricsFailedSubs'
    }

    It 'starts every wrapper run with zero Marketplace totals' {
        $Wrapper = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.ps1') -Raw
        $Wrapper | Should -Match '(?s)\$Global:MarketplaceRecordCount = 0\s+\$Global:MarketplaceFailedSubs = @\(\)'
    }

    It 'keeps every distinct failure of a stream in its summary' {
        $Stream = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.Stream.ps1') -Raw
        $Stream | Should -Match 'MarketplaceFailedSubs\s+=\s+@\(\$MarketplaceFailedSubs \| Sort-Object -Property Id, Message -Unique\)'
        $Stream | Should -Match 'ConsumptionFailedSubs\s+=\s+@\(\$ConsumptionFailedSubs \| Sort-Object -Property Id, Message -Unique\)'
        $Two = @([pscustomobject]@{ Name = 'a'; Id = '1'; Message = 'x' }, [pscustomobject]@{ Name = 'b'; Id = '2'; Message = 'y' }, [pscustomobject]@{ Name = 'a'; Id = '1'; Message = 'x' })
        @($Two | Sort-Object -Property Id, Message -Unique).Count | Should -Be 2
    }

    It 'lists the Marketplace failures in the shareable diagnostics log' {
        $Dir = (Join-Path ([System.IO.Path]::GetTempPath()) ('MpDiag_' + [guid]::NewGuid().ToString('N'))) + [System.IO.Path]::DirectorySeparatorChar
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Global:MarketplaceFailedSubs = @([pscustomobject]@{ Name = 'x'; Id = '11111111-1111-1111-1111-111111111111'; Message = 'Marketplace query failed (this subscription''s Marketplace data is INCOMPLETE)' })
        try
        {
            $Log = Write-RdaShareableDiagnosticsLog -DefaultPath $Dir -ReportName 'T' -RunDateTime '20260101_000000' -Version '1.0.0' -PhaseTimings ([ordered]@{}) 6>$null
            $Text = Get-Content -LiteralPath $Log -Raw
            $Text | Should -Match 'Marketplace failed/incomplete subscriptions: 1'
            $Text | Should -Match 'INCOMPLETE'
        }
        finally { $Global:MarketplaceFailedSubs = @(); Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'forwards -SkipMarketplace from the wrapper to the sequential run, the worker jobs and the stream script' {
        $Wrapper = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.ps1') -Raw
        $Stream = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.Stream.ps1') -Raw
        $Wrapper | Should -Match '\[switch\]\$SkipMarketplace'
        $Wrapper | Should -Match "\`$InventoryPassthrough\['SkipMarketplace'\] = \`$true"
        $Wrapper | Should -Match '\$WorkerArgs\.SkipMarketplace = \$true'
        $Stream | Should -Match '\[switch\] \$SkipMarketplace'
        $Stream | Should -Match "\`$InventoryPassthrough\['SkipMarketplace'\] = \`$true"
    }

    It 'carries the Marketplace totals from each stream summary into the run totals' {
        $Wrapper = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.ps1') -Raw
        $Stream = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.Stream.ps1') -Raw
        $Stream | Should -Match 'MarketplaceRecords\s+=\s+\$MarketplaceTotal'
        $Stream | Should -Match 'MarketplaceFailedSubs\s+=\s+@\(\$MarketplaceFailedSubs \| Sort-Object -Property Id, Message -Unique\)'
        $Wrapper | Should -Match '\$StreamSummary\.MarketplaceRecords'
        $Wrapper | Should -Match '\$StreamSummary\.MarketplaceFailedSubs'
    }

    It 'prints the Marketplace counts in the run summary lines' {
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        $Lines = Get-RunSummaryLogContent -InvocationParameters @{} -Version '1.0.0' -StartTime (Get-Date).AddMinutes(-1) -EndTime (Get-Date) -Visible 1 -Excluded 0 -Eligible 1 -Processed 1 -Skipped 0 `
            -MarketplaceRecordCount 7 -MarketplaceFailedSubs @([pscustomobject]@{ Name = 'Sub A'; Id = 'a'; Message = 'boom' })
        ($Lines -join "`n") | Should -Match 'Claude Marketplace rows\s+: 7'
        ($Lines -join "`n") | Should -Match 'Marketplace failed subs\s+: 1'
        ($Lines -join "`n") | Should -Match 'Sub A \(a\): boom'
    }
}

Describe 'Marketplace window and run summary' {
    It 'does not ask for a UTC day that is still running' {
        $script:InvSrc | Should -Match '\$MarketplaceEndDate -gt \[datetime\]::UtcNow\.Date'
    }

    It 'leaves the Claude file failure out of the run summary count and detail' {
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        $Lines = Get-RunSummaryLogContent -InvocationParameters @{} -Version '1.0.0' -StartTime (Get-Date).AddMinutes(-1) -EndTime (Get-Date) -Visible 1 -Excluded 0 -Eligible 1 -Processed 1 -Skipped 0 `
            -MarketplaceFailedSubs @([pscustomobject]@{ Name = '(claude file)'; Id = '(claude file)'; Message = 'not written' })
        ($Lines -join "`n") | Should -Match 'Marketplace failed subs\s+: 0'
    }
}

Describe 'Dictionary names and run summary' {
    It 'adds the name entry of an id that is already known, when its name token has none' {
        . (script:Import-FunctionFromScript -Path $script:InvPath -Name 'Add-MarketplaceDictionaryEntries')
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Global:ResourceSubscriptionDictionary = $null
        $Global:ResourceResourceGroupDictionary = $null
        $Row = script:New-FakeClaudeRow
        $Raw = Get-RdaMarketplaceCanonicalId -Row $Row
        $script:MarketplaceIdLookup = @{ $Raw = '/subscriptions/a/resourcegroups/b/providers/microsoft.saas/resources/tok' }
        try
        {
            Add-MarketplaceDictionaryEntries -Row $Row -ExportRow ([pscustomobject]@{ SubscriptionGuid = 'a'; ResourceGroup = 'b'; InstanceId = '/subscriptions/a/resourcegroups/b/providers/microsoft.saas/resources/tok'; InstanceName = 'tok' })
            $Global:ResourceNameDictionary[$Raw] | Should -Be 'tok'
        }
        finally { $Global:ResourceIdDictionary = $null; $Global:ResourceNameDictionary = $null }
    }

    It 'shows a Marketplace sign-in skip as its own line, not as a subscription' {
        . (Join-Path $script:Repo 'Functions/RunAllSubscriptions.Functions.ps1')
        $Lines = Get-RunSummaryLogContent -InvocationParameters @{} -Version '1.0.0' -StartTime (Get-Date).AddMinutes(-1) -EndTime (Get-Date) -Visible 1 -Excluded 0 -Eligible 1 -Processed 1 -Skipped 0 `
            -MarketplaceFailedSubs @([pscustomobject]@{ Name = '(all subscriptions)'; Id = '(auth)'; Message = 'no token' })
        ($Lines -join "`n") | Should -Match 'Marketplace failed subs\s+: 0'
        ($Lines -join "`n") | Should -Match 'Marketplace phase skipped\s+: no usable Azure sign-in'
    }

    It 'builds the copies of the run dictionaries only when an Anthropic row is found, and drops them after' {
        $script:InvSrc | Should -Match '(?s)\$script:MarketplaceLookupsBuilt = \$false.*?Test-RdaClaudeMarketplaceRow.*?-not \$script:MarketplaceLookupsBuilt'
        $script:InvSrc | Should -Match '(?s)finally\s*\{[^}]*\$script:MarketplaceIdLookup = \$null'
    }
}

Describe 'Claude file: failure isolation and console' {
    It 'keeps the Marketplace rows when the token step fails, and keeps a row with no date' {
        $script:InvSrc | Should -Match '(?s)Its own try: a failure in the token step.*?Invoke-RdaClaudeTokenCollection.*?catch.*?\(all accounts\)'
        $script:InvSrc | Should -Match 'A Marketplace row had no usable usage date\. It is in the file with an empty date\.'
    }

    It 'prints the failure block only for subscriptions, labels the rows as Claude rows, and lists same-name subscriptions apart' {
        $Wrapper = Get-Content -LiteralPath (Join-Path $script:Repo 'Run-AllSubscriptions.ps1') -Raw
        $Wrapper | Should -Match 'if \(\$MarketplaceSubFailures\.Count -gt 0\)'
        $Wrapper | Should -Match 'Claude Marketplace Rows:'
        $Wrapper | Should -Match 'MarketplaceSubFailures \| Sort-Object -Property Id, Message -Unique'
    }
}

Describe 'Marketplace phase isolation and retries' {
    It 'does not let a failure in the Marketplace phase stop the run' {
        $script:InvSrc | Should -Match '(?s)The file is an extra: nothing that goes wrong in this phase.*?try\s*\{\s*GetMarketplaceConsumption\s*\}\s*catch'
    }

    It 'retries a throttle even when its text holds a 4xx word' {
        Test-RdaClaudeThrottle -ErrorMessage 'TooManyRequests: retry later (earlier 404 NotFound)' | Should -BeTrue
        Test-RdaClaudeThrottle -ErrorMessage 'Forbidden' | Should -BeFalse
        $script:InvSrc | Should -Match 'Test-RdaClaudeThrottle -ErrorMessage \$_\.Exception\.Message\) -and'
    }
}
