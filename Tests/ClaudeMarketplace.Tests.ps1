#Requires -Version 7.0
<#
    ClaudeMarketplace.Tests.ps1

    Tests for ClaudeMarketPlace_<report>_<stamp>.json (Functions/ClaudeMarketplace.Functions.ps1):
    which Marketplace rows and which token series go in, the AlsoInConsumption field, the number and
    date forms, masking, error records, and the file itself.

    Fully offline. Get-AzMetric is a stand-in; results are built in the shape Az.Monitor returns
    (Name.Value, Timeseries with Metadatavalues and Data points).
    Run with: Invoke-Pester ./Tests/ClaudeMarketplace.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:InvPath = Join-Path $script:Repo 'ResourceInventory.ps1'
    . (Join-Path $script:Repo 'Functions/ResourceInventory.Functions.ps1')
    . (Join-Path $script:Repo 'Functions/Common.Functions.ps1')
    . (Join-Path $script:Repo 'Functions/ClaudeMarketplace.Functions.ps1')

    function script:Import-FunctionFromScript([string]$Path, [string[]]$Name)
    {
        $Tokens = $null; $ParseErrors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors)
        $Found = $Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -in $Name }, $true)
        @($Found).Count | Should -Be @($Name).Count
        return [scriptblock]::Create((($Found | ForEach-Object { $_.Extent.Text }) -join "`n"))
    }
    . (script:Import-FunctionFromScript -Path $script:InvPath -Name 'Resolve-ObfuscationToken', 'Build-ObfuscatedResourceUri')

    $script:Logged = [System.Collections.Generic.List[string]]::new()
    Mock Write-Log { $script:Logged.Add("$Severity|$Message") }

    # Stand-in so Pester can mock it with no Az.Monitor loaded.
    function Global:Get-AzMetric
    {
        param($ResourceId, [string[]]$MetricName, $StartTime, $EndTime, $TimeGrain, $AggregationType, $MetricFilter, $Top)
        $null = $ResourceId, $MetricName, $StartTime, $EndTime, $TimeGrain, $AggregationType, $MetricFilter, $Top
        throw 'Get-AzMetric stand-in was called without a mock'
    }

    function Global:New-TestSeries([string]$Model, [object[]]$Totals)
    {
        $Meta = @()
        if ($null -ne $Model) { $Meta = @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'modelname' }; Value = $Model }) }
        [pscustomobject]@{ Metadatavalues = $Meta; Data = @($Totals | ForEach-Object { [pscustomobject]@{ Total = $_ } }) }
    }
    function Global:New-TestMetric([string]$Name, [object[]]$Series)
    {
        [pscustomobject]@{ Name = [pscustomobject]@{ Value = $Name }; Timeseries = @($Series) }
    }

    $script:SubId = '11111111-2222-3333-4444-555555555555'
    $script:AcctId = "/subscriptions/$($script:SubId)/resourceGroups/rg-ai-app/providers/Microsoft.CognitiveServices/accounts/acct-foundry-1"
    $script:Account = [pscustomobject]@{ id = $script:AcctId; name = 'acct-foundry-1'; resourceGroup = 'rg-ai-app'; subscriptionId = $script:SubId; location = 'eastus2'; kind = 'AIServices' }
    $script:Subs = @([pscustomobject]@{ id = $script:SubId; Name = 'Contoso Production' })
    $script:Now = [datetime]::new(2026, 11, 13, 15, 30, 0, [System.DateTimeKind]::Utc)

    # The three rows a live account returned: two per-CCU day rows and a monthly row of 0.
    function script:New-RealShapeRows
    {
        $Common = @{
            PublisherName    = 'Anthropic'
            PlanName         = 'claude-ccu-anthropic-hosted-plan'
            ConsumedService  = 'Microsoft.SaaS'
            Currency         = 'USD'
            IsEstimated      = $false
            OrderNumber      = 'ORD-1'
            SubscriptionGuid = '11111111-2222-3333-4444-555555555555'
            SubscriptionName = 'Contoso Production'
            ResourceGroup    = 'rg-ai-app'
            InstanceId       = 'subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-ai-app/providers/Microsoft.SaaS/resources/claude-1'
            InstanceName     = 'claude-1'
        }
        @(
            [pscustomobject]($Common + @{ OfferName = 'Claude in Microsoft Foundry (Anthropic hosted)'; UnitOfMeasure = '1 ccu'; ConsumedQuantity = 1114.676; PretaxCost = 11.147; MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStart = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); UsageEnd = [datetime]::new(2026, 11, 21, 23, 59, 59, [System.DateTimeKind]::Utc) })
            [pscustomobject]($Common + @{ OfferName = 'Claude in Microsoft Foundry (Anthropic hosted)'; UnitOfMeasure = '1 ccu'; ConsumedQuantity = 868.081; PretaxCost = 8.681; MeterId = 'aaaaaaaa-0000-0000-0000-000000000002'; UsageStart = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); UsageEnd = [datetime]::new(2026, 11, 21, 23, 59, 59, [System.DateTimeKind]::Utc) })
            [pscustomobject]($Common + @{ OfferName = 'Claude in Microsoft Foundry (Anthropic hosted) claude-ccu-anthropic-hosted-plan'; UnitOfMeasure = 'Monthly'; ConsumedQuantity = 1; PretaxCost = 0; MeterId = ''; UsageStart = [datetime]::new(2026, 11, 1, 0, 0, 0, [System.DateTimeKind]::Utc); UsageEnd = [datetime]::new(2026, 11, 1, 23, 59, 59, [System.DateTimeKind]::Utc) })
        )
    }
}

Describe 'Test-RdaClaudeMarketplaceRow' {
    It 'keeps the offer a live account billed' {
        Test-RdaClaudeMarketplaceRow -Row @(script:New-RealShapeRows)[0] | Should -BeTrue
    }
    It 'keeps a row by publisher alone, whatever the case and the culture' {
        Test-RdaClaudeMarketplaceRow -Row ([pscustomobject]@{ PublisherName = 'ANTHROPIC, PBC'; OfferName = 'x'; PlanName = 'y' }) | Should -BeTrue
        $Old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            Test-RdaClaudeMarketplaceRow -Row ([pscustomobject]@{ PublisherName = 'ANTHROPIC, PBC'; OfferName = 'x'; PlanName = 'y' }) | Should -BeTrue
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $Old }
    }
    It 'decides by offer or plan only when the row has no publisher' {
        Test-RdaClaudeMarketplaceRow -Row ([pscustomobject]@{ PublisherName = ''; OfferName = 'Claude in Foundry'; PlanName = 'p' }) | Should -BeTrue
        Test-RdaClaudeMarketplaceRow -Row ([pscustomobject]@{ PublisherName = $null; OfferName = 'o'; PlanName = 'anthropic-hosted' }) | Should -BeTrue
    }
    It 'leaves out another publisher whose offer is called Claude' {
        Test-RdaClaudeMarketplaceRow -Row ([pscustomobject]@{ PublisherName = 'Reseller'; OfferName = 'Claude in Foundry'; PlanName = 'anthropic-hosted' }) | Should -BeFalse
    }
    It 'leaves out another publisher, and a word that only contains claude' {
        Test-RdaClaudeMarketplaceRow -Row ([pscustomobject]@{ PublisherName = 'contoso'; OfferName = 'contoso-assistant'; PlanName = 'payg' }) | Should -BeFalse
        Test-RdaClaudeMarketplaceRow -Row ([pscustomobject]@{ PublisherName = 'x'; OfferName = 'claudette suite'; PlanName = 'p' }) | Should -BeFalse
        Test-RdaClaudeMarketplaceRow -Row $null | Should -BeFalse
    }
}

Describe 'Test-RdaClaudeModelName' {
    It 'is true for Claude names, ignoring case' -ForEach @(
        @{ Name = 'claude-sonnet-4-5' }, @{ Name = 'Claude-Opus' }, @{ Name = 'CLAUDE' }
    ) { Test-RdaClaudeModelName -ModelName $Name | Should -BeTrue }
    It 'is false for other models and for an empty name' -ForEach @(
        @{ Name = 'gpt-4o' }, @{ Name = 'o3-mini' }, @{ Name = '' }, @{ Name = $null }
    ) { Test-RdaClaudeModelName -ModelName $Name | Should -BeFalse }
}

Describe 'Claude tokens only' {
    BeforeEach {
        $script:Window = Get-RdaClaudeTokenWindow -LookbackDays 3 -Now $script:Now
        $script:Info = [pscustomobject]@{ Id = $script:AcctId; SubscriptionName = 'Contoso Production'; ResourceGroup = 'rg-ai-app'; Name = 'acct-foundry-1'; Location = 'eastus2' }
    }

    It 'keeps the Claude model and drops the GPT model of one account, and counts what it dropped' {
        $Results = @(
            (New-TestMetric 'InputTokens' @((New-TestSeries 'claude-sonnet-4-5' @(100, 200, 300)), (New-TestSeries 'gpt-4o' @(5000, 6000, 7000)))),
            (New-TestMetric 'OutputTokens' @((New-TestSeries 'claude-sonnet-4-5' @(10, 20, 30)), (New-TestSeries 'gpt-4o' @(500, 600, 700))))
        )
        $Skipped = @{}
        $Records = ConvertFrom-RdaClaudeTokenMetric -MetricResults $Results -Account $script:Info -Window $script:Window -Skipped $Skipped
        $Records.Count | Should -Be 2
        @($Records | ForEach-Object { $_.ModelName } | Select-Object -Unique) | Should -Be @('claude-sonnet-4-5')
        ($Records | Where-Object Metric -eq 'InputTokens').Total | Should -Be 600
        ($Records | Where-Object Metric -eq 'OutputTokens').Total | Should -Be 60
        ($Records | ConvertTo-Json -Depth 4) | Should -Not -Match '(?i)gpt'
        $Skipped['NonClaudeSeries'] | Should -Be 2
    }

    It 'writes no token of a non-Claude model into the file, through the whole collection' {
        Mock Get-AzMetric {
            @(
                (New-TestMetric 'InputTokens' @((New-TestSeries 'claude-opus-4' @(1, 2, 3)), (New-TestSeries 'gpt-4o' @(9, 9, 9)))),
                (New-TestMetric 'cacheReadInputTokens' @((New-TestSeries 'claude-opus-4' @(0, 4, 0)), (New-TestSeries 'gpt-4o' @(7, 7, 7))))
            )
        }
        $Result = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account) -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        $Result.Records.Count | Should -Be 2
        $Result.NonClaudeSeries | Should -Be 2
        ($Result.Records | ConvertTo-Json -Depth 4) | Should -Not -Match '(?i)gpt'
        @($Result.Records | ForEach-Object { $_.Metric }) | Should -Be @('InputTokens', 'cacheReadInputTokens')
    }

    It 'asks Azure Monitor for the five counts split by ModelName, daily, as totals' {
        Mock Get-AzMetric { @() }
        $null = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account) -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        Should -Invoke Get-AzMetric -Times 1 -Exactly -ParameterFilter {
            $ResourceId -eq $script:AcctId -and ($MetricName -join ',') -eq 'InputTokens,OutputTokens,cacheReadInputTokens,ephemeral5mInputTokens,ephemeral1hInputTokens' -and
            $TimeGrain -eq '1.00:00:00' -and $AggregationType -eq 'Total' -and $MetricFilter -eq "ModelName eq '*'"
        }
    }

    It 'gives whole-number totals and daily values, and a 0 for a missing day' {
        $Results = @(New-TestMetric 'InputTokens' @((New-TestSeries 'claude-sonnet-4-5' @(10.4, $null, 5))))
        $Rec = (ConvertFrom-RdaClaudeTokenMetric -MetricResults $Results -Account $script:Info -Window $script:Window)[0]
        $Rec.Total | Should -BeOfType [long]
        $Rec.Total | Should -Be 15
        $Rec.DailySeries | Should -Be @(10, 0, 5)
        $Rec.StartTime | Should -Be '2026-11-10T00:00:00Z'
        $Rec.EndTime | Should -Be '2026-11-13T00:00:00Z'
    }

    It 'gives no record for a Claude model with no tokens in the window' {
        $Results = @(New-TestMetric 'InputTokens' @((New-TestSeries 'claude-sonnet-4-5' @(0, 0, 0))))
        (ConvertFrom-RdaClaudeTokenMetric -MetricResults $Results -Account $script:Info -Window $script:Window).Count | Should -Be 0
    }

    It 'splits one account into one record per model and metric' {
        $Results = @(
            (New-TestMetric 'InputTokens' @((New-TestSeries 'claude-sonnet-4-5' @(1, 1, 1)), (New-TestSeries 'claude-haiku-4-5' @(2, 2, 2)))),
            (New-TestMetric 'ephemeral5mInputTokens' @((New-TestSeries 'claude-sonnet-4-5' @(3, 0, 0))))
        )
        $Records = ConvertFrom-RdaClaudeTokenMetric -MetricResults $Results -Account $script:Info -Window $script:Window
        $Records.Count | Should -Be 3
        ($Records | Where-Object { $_.ModelName -eq 'claude-haiku-4-5' }).Total | Should -Be 6
    }

    It 'collects nothing and makes no call when there is no Foundry account' {
        Mock Get-AzMetric { @() }
        $Result = Invoke-RdaClaudeTokenCollection -Accounts @() -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now
        $Result.Accounts | Should -Be 0
        $Result.Records.Count | Should -Be 0
        Should -Invoke Get-AzMetric -Times 0 -Exactly
    }
}

Describe 'Errors are written, never silent' {
    It 'gives an account that Azure refuses one error record, and goes on to the next account' {
        $Second = [pscustomobject]@{ id = $script:AcctId.Replace('acct-foundry-1', 'acct-foundry-2'); name = 'acct-foundry-2'; resourceGroup = 'rg-ai-app'; subscriptionId = $script:SubId; location = 'eastus2'; kind = 'AIServices' }
        $script:Calls = 0
        Mock Get-AzMetric {
            $script:Calls++
            if ($script:Calls -eq 1) { throw 'BadRequest (400): metric not supported' }
            @(New-TestMetric 'InputTokens' @((New-TestSeries 'claude-sonnet-4-5' @(1, 2, 3))))
        }
        $Result = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account, $Second) -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        $Result.Failed | Should -Be 1
        $Result.Errors.Count | Should -Be 1
        $Result.Errors[0].Source | Should -Be 'AzureMonitor'
        $Result.Errors[0].Scope | Should -Be $script:AcctId
        $Result.Errors[0].Message | Should -Match 'BadRequest'
        $Result.Records.Count | Should -Be 1
    }

    It 'retries a throttled call three times' {
        Mock Get-AzMetric { throw 'TooManyRequests' }
        $null = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account) -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        Should -Invoke Get-AzMetric -Times 4 -Exactly
    }

    It 'does not retry a bad request' {
        Mock Get-AzMetric { throw 'NotFound (404)' }
        $null = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account) -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        Should -Invoke Get-AzMetric -Times 1 -Exactly
    }

    It 'writes a fixed sentence under -Obfuscate, so no real name reaches the file' {
        $E = New-RdaClaudeMarketplaceError -Source Marketplace -Scope 'prod_sub_x' -Message 'failed for rg-secret-group' -Obfuscate $true
        $E.Message | Should -Not -Match 'rg-secret-group'
        $E.Message | Should -Match 'could not be read'
        (New-RdaClaudeMarketplaceError -Source Marketplace -Scope 's' -Message "first line`nsecond line").Message | Should -Be 'first line'
    }
}

Describe 'Masking the token records' {
    BeforeEach {
        $script:Ids = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $script:Names = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $script:SubsD = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $script:Rgs = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $script:Ids[$script:AcctId] = '/subscriptions/prod-0a1b/resourcegroups/prod-2c3d/providers/microsoft.cognitiveservices/accounts/4e5f'
        $script:Names[$script:AcctId] = '4e5f'
        $script:SubsD[$script:AcctId] = 'prod-0a1b'
        $script:Rgs[$script:AcctId] = 'prod-2c3d'
        Mock Get-AzMetric { @(New-TestMetric 'InputTokens' @((New-TestSeries 'claude-sonnet-4-5' @(1, 2, 3)))) }
    }

    It 'gives the record the tokens the inventory gave the account, and keeps the model name and region' {
        $Result = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account) -Subscriptions $script:Subs -Obfuscate $true -ResourceIdDictionary $script:Ids -ResourceNameDictionary $script:Names -ResourceSubDictionary $script:SubsD -ResourceGroupDictionary $script:Rgs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        $Rec = $Result.Records[0]
        $Rec.ID | Should -Be $script:Ids[$script:AcctId]
        $Rec.Name | Should -Be '4e5f'
        $Rec.Subscription | Should -Be 'prod-0a1b'
        $Rec.ResourceGroup | Should -Be 'prod-2c3d'
        $Rec.ModelName | Should -Be 'claude-sonnet-4-5'
        $Rec.Location | Should -Be 'eastus2'
        ($Rec | ConvertTo-Json) | Should -Not -Match '(?i)acct-foundry|rg-ai-app|Contoso|11111111-2222'
    }

    It 'masks an account the inventory did not hold as an ARM path, and records it so Reveal can undo it' {
        $Other = [pscustomobject]@{ id = $script:AcctId.Replace('acct-foundry-1', 'acct-other'); name = 'acct-other'; resourceGroup = 'rg-ai-app'; subscriptionId = $script:SubId; location = 'eastus2'; kind = 'AIServices' }
        $Result = Invoke-RdaClaudeTokenCollection -Accounts @($Other) -Subscriptions $script:Subs -Obfuscate $true -ResourceIdDictionary $script:Ids -ResourceNameDictionary $script:Names -ResourceSubDictionary $script:SubsD -ResourceGroupDictionary $script:Rgs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        $Rec = $Result.Records[0]
        $Rec.ID | Should -Match '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/[^/]+/[^/]+/[^/]+$'
        $Rec.ID | Should -Not -Match 'acct-other'
        $script:Ids[$Other.id] | Should -Be $Rec.ID
    }

    It 'gives an error record the masked account id' {
        Mock Get-AzMetric { throw 'BadRequest (400)' }
        $Result = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account) -Subscriptions $script:Subs -Obfuscate $true -ResourceIdDictionary $script:Ids -ResourceNameDictionary $script:Names -ResourceSubDictionary $script:SubsD -ResourceGroupDictionary $script:Rgs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        $Result.Errors[0].Scope | Should -Be $script:Ids[$script:AcctId]
        ($Result.Errors | ConvertTo-Json) | Should -Not -Match '(?i)acct-foundry|rg-ai-app'
    }
}

Describe 'AlsoInConsumption' {
    BeforeEach {
        $script:Csv = Join-Path ([System.IO.Path]::GetTempPath()) ("Consumption_{0}.csv" -f [guid]::NewGuid())
        $script:Recs = @(script:New-RealShapeRows | ForEach-Object { ConvertTo-RdaClaudeMarketplaceRecord -ExportRow (ConvertTo-RdaMarketplaceRow -Row $_) })
        # The Consumption phase writes under the en-US thread culture, so the test does too.
        function script:Write-ConsumptionCsv([object[]]$Rows)
        {
            $Old = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try
            {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
                $Rows | Select-Object MeterId, UsageStartTime, Quantity, ResourceId | Export-Csv -LiteralPath $script:Csv -Encoding utf8 -NoTypeInformation
            }
            finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $Old }
        }
    }
    AfterEach { Remove-Item -LiteralPath $script:Csv -ErrorAction SilentlyContinue }

    It 'is false, with match None, when no Consumption row has the charge' {
        script:Write-ConsumptionCsv @([pscustomobject]@{ MeterId = 'zzzz'; UsageStartTime = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 5; ResourceId = '/subscriptions/x/resourcegroups/y/providers/microsoft.compute/virtualmachines/vm1' })
        $Read = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs
        $Read | Should -Be 1
        $script:Recs[0].AlsoInConsumption | Should -BeFalse
        $script:Recs[0].AlsoInConsumptionMatch | Should -Be 'None'
    }

    It 'is true when a Consumption row has the same meter id, day and quantity, and only for that row' {
        script:Write-ConsumptionCsv @([pscustomobject]@{ MeterId = 'AAAAAAAA-0000-0000-0000-000000000001'; UsageStartTime = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 1114.676; ResourceId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/y/providers/microsoft.other/things/t' })
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs
        $script:Recs[0].AlsoInConsumption | Should -BeTrue
        $script:Recs[0].AlsoInConsumptionMatch | Should -Be 'MeterDayQuantity'
        $script:Recs[1].AlsoInConsumption | Should -BeFalse
    }

    It 'is false when the meter and day match but the quantity does not, or the day does not' {
        script:Write-ConsumptionCsv @(
            [pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 3; ResourceId = '' },
            [pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000002'; UsageStartTime = [datetime]::new(2026, 11, 20, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 868.081; ResourceId = '' }
        )
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs
        $script:Recs[0].AlsoInConsumption | Should -BeFalse
        $script:Recs[1].AlsoInConsumption | Should -BeFalse
    }

    It 'only hints, and never says true, when a Consumption row names the same resource' {
        script:Write-ConsumptionCsv @([pscustomobject]@{ MeterId = 'other-meter'; UsageStartTime = [datetime]::new(2026, 11, 3, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 9; ResourceId = '/SUBSCRIPTIONS/11111111-2222-3333-4444-555555555555/RESOURCEGROUPS/RG-AI-APP/PROVIDERS/MICROSOFT.SAAS/RESOURCES/CLAUDE-1' })
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs
        foreach ($R in $script:Recs)
        {
            $R.ResourceInConsumption | Should -BeTrue
            $R.AlsoInConsumption | Should -BeFalse
            $R.AlsoInConsumptionMatch | Should -Be 'None'
        }
    }

    It 'never matches an empty meter id on the meter test' {
        script:Write-ConsumptionCsv @([pscustomobject]@{ MeterId = ''; UsageStartTime = [datetime]::new(2026, 11, 1, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 1; ResourceId = '' })
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs
        $script:Recs[2].AlsoInConsumption | Should -BeFalse
    }

    It 'reads the file the Consumption phase writes, whatever the culture, one row at a time' {
        $Old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
            script:Write-ConsumptionCsv @([pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = [decimal]1114.676; ResourceId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/y/providers/microsoft.other/things/t' })
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs
            $script:Recs[0].AlsoInConsumption | Should -BeTrue
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $Old }
    }

    It 'counts the rows it read, and reads a missing file as 0 rows' {
        script:Write-ConsumptionCsv @([pscustomobject]@{ MeterId = ''; UsageStartTime = $null; Quantity = 1; ResourceId = '' }, [pscustomobject]@{ MeterId = 'm'; UsageStartTime = [datetime]::new(2026, 11, 1, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 1; ResourceId = 'r' })
        (Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs) | Should -Be 2
        (Set-RdaConsumptionMatch -CsvPath ($script:Csv + '.missing') -Records $script:Recs) | Should -Be 0
    }

    It 'does not match a Consumption row of another subscription' {
        script:Write-ConsumptionCsv @([pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 1114.676; ResourceId = '/subscriptions/99999999-9999-9999-9999-999999999999/resourcegroups/y/providers/microsoft.other/things/t' })
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs
        $script:Recs[0].AlsoInConsumption | Should -BeFalse
    }

    It 'lets one Consumption row mark one Marketplace row, and needs the exact quantity' {
        $Twin = ConvertTo-RdaClaudeMarketplaceRecord -ExportRow (ConvertTo-RdaMarketplaceRow -Row @(script:New-RealShapeRows)[0])
        $Near = ConvertTo-RdaClaudeMarketplaceRecord -ExportRow (ConvertTo-RdaMarketplaceRow -Row @(script:New-RealShapeRows)[0])
        $Near.ConsumedQuantity = [decimal]1114.6761
        script:Write-ConsumptionCsv @([pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 1114.676; ResourceId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/y/providers/microsoft.other/things/t' })
        $Pair = @($script:Recs[0], $Twin, $Near)
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $Pair
        @($Pair | Where-Object AlsoInConsumption).Count | Should -Be 1
        $Near.AlsoInConsumption | Should -BeFalse
    }

    It 'marks nothing when the Consumption row has no subscription in its resource id' {
        script:Write-ConsumptionCsv @(
            [pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 1114.676; ResourceId = '' },
            [pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 1114.676; ResourceId = 'not-an-id' }
        )
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs
        $script:Recs[0].AlsoInConsumption | Should -BeFalse
    }

    It 'finds the UTC day of a usage row written in the local time of a machine west or east of UTC' -ForEach @(
        @{ Zone = 'America/New_York'; Written = '2026-11-20T19:00:00'; Day = '2026-11-21' }
        @{ Zone = 'Asia/Tokyo'; Written = '2026-11-21T09:00:00'; Day = '2026-11-21' }
        @{ Zone = 'UTC'; Written = '2026-11-21T00:00:00'; Day = '2026-11-21' }
    ) {
        $Zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($Zone)
        Get-RdaConsumptionUtcDay -Written ([datetime]::Parse($Written, [System.Globalization.CultureInfo]::InvariantCulture)) -Zone $Zone | Should -Be $Day
    }

    It 'gives no day to a time that is midnight in neither reading' {
        Get-RdaConsumptionUtcDay -Written ([datetime]::new(2026, 11, 21, 7, 30, 0)) -Zone ([System.TimeZoneInfo]::FindSystemTimeZoneById('America/New_York')) | Should -Be ''
    }

    It 'matches in a masked run through the real subscription behind each token' {
        $Masked = @{ 'prod_sub_consumption' = '11111111-2222-3333-4444-555555555555' }
        script:Write-ConsumptionCsv @([pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 1114.676; ResourceId = '/subscriptions/prod_sub_consumption/resourcegroups/y/providers/microsoft.other/things/t' })
        $Recs = @(script:New-RealShapeRows | ForEach-Object { ConvertTo-RdaClaudeMarketplaceRecord -ExportRow (ConvertTo-RdaMarketplaceRow -Row $_ -Obfuscate:$true -SubCache @{} -RgCache @{} -NameCache @{}) })
        $Real = @('11111111-2222-3333-4444-555555555555', '11111111-2222-3333-4444-555555555555', '11111111-2222-3333-4444-555555555555')
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $Recs -RecordSubscriptions $Real -TokenToSubscription $Masked
        $Recs[0].AlsoInConsumption | Should -BeTrue
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records @($Recs[1]) -RecordSubscriptions @('99999999-9999-9999-9999-999999999999') -TokenToSubscription $Masked
        $Recs[1].AlsoInConsumption | Should -BeFalse
    }

    It 'marks nothing in a masked run when the token is not known to belong to a subscription' {
        script:Write-ConsumptionCsv @([pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = [datetime]::new(2026, 11, 21, 0, 0, 0, [System.DateTimeKind]::Utc); Quantity = 1114.676; ResourceId = '/subscriptions/prod_sub_unknown/resourcegroups/y/providers/microsoft.other/things/t' })
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs -TokenToSubscription @{}
        $script:Recs[0].AlsoInConsumption | Should -BeFalse
    }

    It 'reads no file when there is no Marketplace row' {
        (Set-RdaConsumptionMatch -CsvPath ($script:Csv + '.missing') -Records @()) | Should -Be 0
    }
}

Describe 'ConvertTo-RdaClaudeMarketplaceRecord' {
    It 'writes numbers as numbers and dates as UTC text, for the three rows of a real bill' {
        $Out = @(script:New-RealShapeRows | ForEach-Object { ConvertTo-RdaClaudeMarketplaceRecord -ExportRow (ConvertTo-RdaMarketplaceRow -Row $_) })
        $Out.Count | Should -Be 3
        $Out[0].ConsumedQuantity | Should -Be 1114.676
        $Out[0].PretaxCost | Should -Be 11.147
        $Out[0].UnitOfMeasure | Should -Be '1 ccu'
        $Out[0].UsageStart | Should -Be '2026-11-21T00:00:00Z'
        $Out[0].UsageEnd | Should -Be '2026-11-21T23:59:59Z'
        $Out[2].UnitOfMeasure | Should -Be 'Monthly'
        $Out[2].PretaxCost | Should -Be 0
        $Out[2].MeterId | Should -Be ''
        $Out[2].InstanceId | Should -Match '^/subscriptions/'
        $Sum = [decimal]0; foreach ($R in $Out) { $Sum += $R.PretaxCost }
        $Sum | Should -Be 19.828
        $Json = $Out | ConvertTo-Json -Depth 4
        $Json | Should -Match '"ConsumedQuantity": 1114\.676'
        $Json | Should -Match '"PretaxCost": 0\.0,'
        $Json | Should -Not -Match 'null'
    }

    It 'reads a missing quantity or amount as 0, never null' {
        $Row = ConvertTo-RdaMarketplaceRow -Row ([pscustomobject]@{ PublisherName = 'Anthropic'; ConsumedQuantity = $null; PretaxCost = $null; UsageStart = $null; UsageEnd = $null })
        $Out = ConvertTo-RdaClaudeMarketplaceRecord -ExportRow $Row
        $Out.ConsumedQuantity | Should -Be 0
        $Out.PretaxCost | Should -Be 0
        $Out.UsageStart | Should -Be ''
    }

    It 'writes the same text under tr-TR as under en-US' {
        $Old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $Out = ConvertTo-RdaClaudeMarketplaceRecord -ExportRow (ConvertTo-RdaMarketplaceRow -Row @(script:New-RealShapeRows)[0])
            $Out.UsageStart | Should -Be '2026-11-21T00:00:00Z'
            ($Out | ConvertTo-Json) | Should -Match '"ConsumedQuantity": 1114\.676'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $Old }
    }

    It 'reads a date with no kind as UTC, and a local date as the same instant in UTC' {
        Format-RdaClaudeUtc ([datetime]::new(2026, 5, 1, 0, 0, 0, [System.DateTimeKind]::Unspecified)) | Should -Be '2026-05-01T00:00:00Z'
        Format-RdaClaudeUtc ([datetime]::new(2026, 5, 1, 2, 0, 0, [System.DateTimeKind]::Utc)) | Should -Be '2026-05-01T02:00:00Z'
        Format-RdaClaudeUtc '2026-05-01T02:00:00+02:00' | Should -Be '2026-05-01T00:00:00Z'
        Format-RdaClaudeUtc $null | Should -Be ''
    }
}

Describe 'Write-RdaClaudeMarketplaceFile' {
    BeforeEach { $script:File = Join-Path ([System.IO.Path]::GetTempPath()) ("ClaudeMarketPlace_{0}.json" -f [guid]::NewGuid()) }
    AfterEach { Remove-Item -LiteralPath $script:File, ($script:File + '.tmp') -ErrorAction SilentlyContinue }

    It 'writes empty lists and a reason when nothing was found' {
        Write-RdaClaudeMarketplaceFile -FilePath $script:File -Rows @() -TokenUsage @() -Errors @()
        $Doc = Get-Content -LiteralPath $script:File -Raw | ConvertFrom-Json
        $Doc.SchemaVersion | Should -Be 1
        @($Doc.Rows).Count | Should -Be 0
        @($Doc.TokenUsage).Count | Should -Be 0
        @($Doc.Errors).Count | Should -Be 0
        $Doc.Reason | Should -Match 'does not show that no Claude charge exists'
        (Get-Content -LiteralPath $script:File -Raw) | Should -Match '"Rows": \[\]'
    }

    It 'says why it is empty when it was skipped' {
        Write-RdaClaudeMarketplaceFile -FilePath $script:File -Rows @() -TokenUsage @() -Errors @() -NotCollected '-SkipMarketplace was given.'
        (Get-Content -LiteralPath $script:File -Raw | ConvertFrom-Json).Reason | Should -Be 'Not collected: -SkipMarketplace was given.'
    }

    It 'keeps a one-row list a list, and writes counts, rows, tokens and errors' {
        $Row = ConvertTo-RdaClaudeMarketplaceRecord -ExportRow (ConvertTo-RdaMarketplaceRow -Row @(script:New-RealShapeRows)[0])
        $Tok = [ordered]@{ ID = 'x'; ModelName = 'claude-sonnet-4-5'; Metric = 'InputTokens'; Total = [long]6; DailySeries = [long[]]@(1, 2, 3) }
        $Err = New-RdaClaudeMarketplaceError -Source Marketplace -Scope 's' -Message 'boom'
        Write-RdaClaudeMarketplaceFile -FilePath $script:File -Rows @($Row) -TokenUsage @($Tok) -Errors @($Err) -OtherMarketplaceRowsSkipped 4 -NonClaudeTokenSeriesSkipped 2 -ConsumptionRowsCompared 77 -RowsWindowStart ([datetime]::new(2026, 10, 1)) -RowsWindowEnd ([datetime]::new(2026, 11, 1)) -TokenWindowStart ([datetime]::new(2026, 10, 1)) -TokenWindowEnd ([datetime]::new(2026, 11, 1))
        $Text = Get-Content -LiteralPath $script:File -Raw
        $Doc = $Text | ConvertFrom-Json
        @($Doc.Rows).Count | Should -Be 1
        $Text | Should -Match '"Rows": \['
        $Doc.TokenUsage[0].DailySeries | Should -Be @(1, 2, 3)
        $Doc.Errors[0].Source | Should -Be 'Marketplace'
        $Doc.OtherMarketplaceRowsSkipped | Should -Be 4
        $Doc.NonClaudeTokenSeriesSkipped | Should -Be 2
        $Doc.ConsumptionRowsCompared | Should -Be 77
        $Text | Should -Match '"RowsWindowStart": "2026-10-01T00:00:00Z"'
        $Doc.Reason | Should -Match '1 Claude Marketplace row\(s\) and 1 Claude token record\(s\)'
        $Doc.Reason | Should -Match '1 read\(s\) failed'
    }

    It 'leaves no temporary file, and no half file, when the write fails' {
        Mock Move-Item { throw 'disk full' }
        { Write-RdaClaudeMarketplaceFile -FilePath $script:File -Rows @() -TokenUsage @() -Errors @() } | Should -Throw '*disk full*'
        Test-Path -LiteralPath $script:File | Should -BeFalse
        Test-Path -LiteralPath ($script:File + '.tmp') | Should -BeFalse
    }
}

Describe 'Existing outputs are unchanged' {
    BeforeAll {
        function Test-DataPlaneAuthReady { param([string]$Phase) $true }
        function Set-AzContext { param($Subscription, $ErrorAction) $null = $Subscription, $ErrorAction }
        function Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' } } }
        function Get-UsageAggregates { param($ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken, $ErrorAction) $null = $ReportedStartTime, $ReportedEndTime, $AggregationGranularity, $ShowDetails, $ContinuationToken, $ErrorAction }
        Mock Write-Log { }
        . (script:Import-FunctionFromScript -Path $script:InvPath -Name 'GetResorceConsumption')
    }

    It 'writes the Consumption file exactly as before' {
        $Global:Subscriptions = @([pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name = 'S' })
        $script:Obfuscate = [pscustomobject]@{ IsPresent = $false }
        $script:SubscriptionID = $null
        $script:ResourceGroup = $null
        $Global:ConsumptionRecordCount = 0
        $Global:ConsumptionFailedSubs = @()
        $Global:ConsumptionFileCsv = Join-Path ([System.IO.Path]::GetTempPath()) ("Consumption_{0}.csv" -f [guid]::NewGuid())
        $Info = '{"Microsoft.Resources":{"resourceUri":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1","location":"eastus","additionalInfo":{"ConsumptionMeter":"m-1"}}}'
        $Usage = [pscustomobject]@{ InstanceData = $Info; MeterCategory = 'Virtual Machines'; MeterId = 'M-1'; MeterName = 'D2'; MeterRegion = 'US East'; MeterSubCategory = 'D Series'; Quantity = [decimal]2.5; Unit = '1 Hour'; UsageStartTime = [datetime]::new(2026, 11, 3, 0, 0, 0, [System.DateTimeKind]::Utc); UsageEndTime = [datetime]::new(2026, 11, 4, 0, 0, 0, [System.DateTimeKind]::Utc) }
        Mock Get-UsageAggregates { [pscustomobject]@{ UsageAggregations = [pscustomobject]@{ Properties = @($Usage) } } }
        try
        {
            GetResorceConsumption
            $Lines = @(Get-Content -LiteralPath $Global:ConsumptionFileCsv)
            $Lines[0] | Should -Be '"InstanceData","MeterCategory","MeterId","MeterName","MeterRegion","MeterSubCategory","Quantity","Unit","UsageStartTime","UsageEndTime","ResourceId","ResourceLocation","ConsumptionMeter","ReservationId","ReservationOrderId"'
            $Lines.Count | Should -Be 2
            $Lines[1] | Should -Match '^".*","Virtual Machines","M-1","D2","US East","D Series","2\.5","1 Hour",'
            $Lines[1] | Should -Match ',"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft\.Compute/virtualMachines/vm1","eastus","m-1",'
        }
        finally { Remove-Item -LiteralPath $Global:ConsumptionFileCsv -ErrorAction SilentlyContinue }
    }
}

Describe 'Token collection edge cases' {
    BeforeEach {
        $script:Logged.Clear()
        $script:Window = Get-RdaClaudeTokenWindow -LookbackDays 3 -Now $script:Now
        $script:Info = [pscustomobject]@{ Id = $script:AcctId; SubscriptionName = 'Contoso Production'; ResourceGroup = 'rg-ai-app'; Name = 'acct-foundry-1'; Location = 'eastus2' }
    }

    It 'asks for up to 1000 series, because Azure returns 10 by default when a filter is given' {
        Mock Get-AzMetric { @() }
        $null = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account) -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        Should -Invoke Get-AzMetric -Times 1 -Exactly -ParameterFilter { $Top -eq 1000 }
    }

    It 'does not retry a refused sign-in: <Text>' -ForEach @(
        @{ Text = '401'; Message = 'Response status code does not indicate success: 401 (Unauthorized).' }
        @{ Text = '403'; Message = 'AuthorizationFailed: the client does not have authorization' }
        @{ Text = 'Forbidden'; Message = 'Forbidden' }
    ) {
        Mock Get-AzMetric { throw $Message }
        $Result = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account) -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        Should -Invoke Get-AzMetric -Times 1 -Exactly
        $Result.Errors.Count | Should -Be 1
    }

    It 'writes an error record, and keeps the Claude series, when a series has no ModelName' {
        Mock Get-AzMetric {
            @(New-TestMetric 'InputTokens' @((New-TestSeries $null @(10, 0, 0)), (New-TestSeries 'claude-sonnet-4-5' @(1, 2, 3))))
        }
        $Result = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account) -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        $Result.Records.Count | Should -Be 1
        $Result.Errors.Count | Should -Be 1
        $Result.Errors[0].Message | Should -Match 'not split by model'
    }

    It 'asks only Foundry accounts, not an account with no kind' {
        Mock Get-AzMetric { @() }
        $Mk = { param($Name, $Kind) [pscustomobject]@{ id = $script:AcctId.Replace('acct-foundry-1', $Name); name = $Name; resourceGroup = 'rg-ai-app'; subscriptionId = $script:SubId; location = 'eastus2'; kind = $Kind } }
        $Accts = @((& $Mk 'a1' 'AIServices'), (& $Mk 'a2' 'OpenAI'), (& $Mk 'a3' 'SpeechServices'), (& $Mk 'a4' 'FormRecognizer'), (& $Mk 'a5' ''))
        $Result = Invoke-RdaClaudeTokenCollection -Accounts $Accts -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        $Result.Accounts | Should -Be 1
        Should -Invoke Get-AzMetric -Times 1 -Exactly
    }

    It 'puts a day Azure left out at its own place, and does not move the days after it' {
        $Mk = { param($Day, $Total) [pscustomobject]@{ TimeStamp = [datetime]::new(2026, 11, $Day, 0, 0, 0, [System.DateTimeKind]::Utc); Total = $Total } }
        $Series = [pscustomobject]@{ Metadatavalues = @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'modelname' }; Value = 'claude-sonnet-4-5' }); Data = @((& $Mk 10 5), (& $Mk 12 7)) }
        $Rec = (ConvertFrom-RdaClaudeTokenMetric -MetricResults @(New-TestMetric 'InputTokens' @($Series)) -Account $script:Info -Window $script:Window)[0]
        $Rec.DailySeries | Should -Be @(5, 0, 7)
        $Rec.Total | Should -Be 12
    }

    It 'writes Azure''s own error text to the private log, and a fixed sentence to a masked file' {
        Mock Get-AzMetric { throw 'BadRequest (400): secret-account-name is bad' }
        $Ids = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $Ids[$script:AcctId] = '/subscriptions/a/resourcegroups/b/providers/microsoft.cognitiveservices/accounts/c'
        $Nm = New-Object 'System.Collections.Generic.Dictionary[string,string]'; $Nm[$script:AcctId] = 'c'
        $Sb = New-Object 'System.Collections.Generic.Dictionary[string,string]'; $Sb[$script:AcctId] = 'a'
        $Rg = New-Object 'System.Collections.Generic.Dictionary[string,string]'; $Rg[$script:AcctId] = 'b'
        $Result = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account) -Subscriptions $script:Subs -Obfuscate $true -ResourceIdDictionary $Ids -ResourceNameDictionary $Nm -ResourceSubDictionary $Sb -ResourceGroupDictionary $Rg -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        ($script:Logged -join "`n") | Should -Match 'secret-account-name'
        ($Result.Errors | ConvertTo-Json) | Should -Not -Match 'secret-account-name'
    }

    It 'does not write the order number or the subscription name of a row' {
        $Rec = ConvertTo-RdaClaudeMarketplaceRecord -ExportRow (ConvertTo-RdaMarketplaceRow -Row @(script:New-RealShapeRows)[0])
        @($Rec.Keys) | Should -Not -Contain 'OrderNumber'
        @($Rec.Keys) | Should -Not -Contain 'SubscriptionName'
        (@($Rec.Keys) -join ',') | Should -Be 'PublisherName,OfferName,PlanName,ConsumedService,ConsumedQuantity,UnitOfMeasure,PretaxCost,Currency,IsEstimated,MeterId,UsageStart,UsageEnd,SubscriptionGuid,ResourceGroup,InstanceId,InstanceName,AlsoInConsumption,AlsoInConsumptionMatch,ResourceInConsumption'
    }

    It 'says in the reason that nothing was available to compare with' {
        (Get-RdaClaudeMarketplaceReason -RowCount 2 -TokenRecordCount 1 -ConsumptionRowsCompared 0) | Should -Match 'No Consumption row was available'
        (Get-RdaClaudeMarketplaceReason -RowCount 2 -TokenRecordCount 1 -ConsumptionRowsCompared 5) | Should -Not -Match 'No Consumption row'
    }
}

Describe 'Masked errors and tokens' {
    It 'gives each source its own fixed sentence under -Obfuscate' {
        $Texts = foreach ($Source in 'Marketplace', 'AzureMonitor', 'Consumption', 'File') { (New-RdaClaudeMarketplaceError -Source $Source -Scope 'x' -Message 'real text' -Obfuscate $true).Message }
        @($Texts | Select-Object -Unique).Count | Should -Be 4
        ($Texts -join ' ') | Should -Not -Match 'real text'
        (New-RdaClaudeMarketplaceError -Source Consumption -Message 'm' -Obfuscate $true).Message | Should -Not -Match 'Azure Monitor'
        (New-RdaClaudeMarketplaceError -Source AzureMonitor -Scope '(all accounts)' -Message 'm' -Obfuscate $true).Message | Should -Match 'any account'
    }

    It 'adds two points that fall on one day instead of keeping the last' {
        $Mk = { param($Hour, $Total) [pscustomobject]@{ TimeStamp = [datetime]::new(2026, 11, 10, $Hour, 0, 0, [System.DateTimeKind]::Utc); Total = $Total } }
        $Series = [pscustomobject]@{ Metadatavalues = @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'modelname' }; Value = 'claude-sonnet-4-5' }); Data = @((& $Mk 0 5), (& $Mk 12 7)) }
        $Window = Get-RdaClaudeTokenWindow -LookbackDays 3 -Now $script:Now
        $Info = [pscustomobject]@{ Id = $script:AcctId; SubscriptionName = 's'; ResourceGroup = 'g'; Name = 'n'; Location = 'l' }
        (ConvertFrom-RdaClaudeTokenMetric -MetricResults @(New-TestMetric 'InputTokens' @($Series)) -Account $Info -Window $Window)[0].DailySeries | Should -Be @(12, 0, 0)
    }

    It 'gives the row the same subscription and group tokens in the id path and in its columns, whichever map made them' {
        $InvSub = 'prod_sub_inventory'; $InvRg = 'prod_rg_inventory'
        $Caches = @{ Sub = @{ '11111111-1111-1111-1111-111111111111' = 'prod_sub_consumption' }; Rg = @{ 'rg-ai-prod' = 'prod_rg_consumption' } }
        $Row = [pscustomobject]@{ PublisherName = 'Anthropic'; OfferName = 'o'; PlanName = 'p'; ConsumedService = 's'; ConsumedQuantity = 1; UnitOfMeasure = 'u'; PretaxCost = 1; Currency = 'USD'; IsEstimated = $false; MeterId = 'm'; UsageStart = [datetime]::new(2026, 5, 1); UsageEnd = [datetime]::new(2026, 5, 2); SubscriptionGuid = '11111111-1111-1111-1111-111111111111'; SubscriptionName = 'S'; ResourceGroup = 'rg-ai-prod'; InstanceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ai-prod/providers/Microsoft.SaaS/resources/x'; InstanceName = 'x' }
        $Out = ConvertTo-RdaMarketplaceRow -Row $Row -Obfuscate:$true -IdLookup @{} -SubGuidTokenMap @{ '11111111-1111-1111-1111-111111111111' = $InvSub } -RgTokenMap @{ 'rg-ai-prod' = $InvRg } -SubCache $Caches.Sub -RgCache $Caches.Rg -NameCache @{}
        $Out.InstanceId | Should -Match ('^/subscriptions/{0}/resourcegroups/{1}/' -f $InvSub, $InvRg)
        $Out.SubscriptionGuid | Should -Be $InvSub
        $Out.ResourceGroup | Should -Be $InvRg
    }
}

Describe 'Comparison with the Consumption file: edge cases' {
    BeforeEach {
        $script:Csv = Join-Path ([System.IO.Path]::GetTempPath()) ("Consumption_{0}.csv" -f [guid]::NewGuid())
        $script:Recs = @(script:New-RealShapeRows | ForEach-Object { ConvertTo-RdaClaudeMarketplaceRecord -ExportRow (ConvertTo-RdaMarketplaceRow -Row $_) })
    }
    AfterEach { Remove-Item -LiteralPath $script:Csv -ErrorAction SilentlyContinue }

    It 'counts a Consumption row with a Marketplace meter that cannot be compared, and reads the others' {
        @(
            [pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = 'not a date'; Quantity = '1114.676'; ResourceId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/y/providers/a/b/c' },
            [pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = '11/21/2026 12:00:00 AM'; Quantity = 'many'; ResourceId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/y/providers/a/b/c' },
            [pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = '11/21/2026 12:00:00 AM'; Quantity = '1114.676'; ResourceId = 'no-subscription' },
            [pscustomobject]@{ MeterId = 'unrelated-meter'; UsageStartTime = 'not a date'; Quantity = 'x'; ResourceId = '' }
        ) | Export-Csv -LiteralPath $script:Csv -Encoding utf8 -NoTypeInformation
        $Stats = @{}
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs -Stats $Stats
        $Stats['Unreadable'] | Should -Be 3
        $script:Recs[0].AlsoInConsumption | Should -BeFalse
    }

    It 'throws when the Consumption file lacks a needed column' {
        @([pscustomobject]@{ MeterId = 'm'; Quantity = 1 }) | Export-Csv -LiteralPath $script:Csv -Encoding utf8 -NoTypeInformation
        { Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs } | Should -Throw '*no UsageStartTime column*'
    }

    It 'reads a usage day on a zone whose daylight saving starts at midnight' {
        $Zone = [System.TimeZoneInfo]::FindSystemTimeZoneById('America/Santiago')
        { Get-RdaConsumptionUtcDay -Written ([datetime]::new(2026, 9, 6, 0, 0, 0)) -Zone $Zone } | Should -Not -Throw
        Get-RdaConsumptionUtcDay -Written ([datetime]::new(2026, 9, 6, 0, 0, 0)) -Zone $Zone | Should -Be '2026-09-06'
    }

    It 'marks nothing when one masked token stands for two subscriptions, and counts the row' {
        @([pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = '11/21/2026 12:00:00 AM'; Quantity = '1114.676'; ResourceId = '/subscriptions/prod_sub_same/resourcegroups/y/providers/a/b/c' }) | Export-Csv -LiteralPath $script:Csv -Encoding utf8 -NoTypeInformation
        $Map = @{ 'prod_sub_same' = [System.Collections.Generic.List[string]]@('99999999-9999-9999-9999-999999999999', '11111111-2222-3333-4444-555555555555') }
        $Stats = @{}
        $null = Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs -RecordSubscriptions @('11111111-2222-3333-4444-555555555555', '1', '2') -TokenToSubscription $Map -Zone ([System.TimeZoneInfo]::Utc) -Stats $Stats
        $script:Recs[0].AlsoInConsumption | Should -BeFalse
        $Stats['Unreadable'] | Should -Be 1
    }

    It 'throws for a header-only or cut-short file without the needed columns, and reads a zero-byte file as 0 rows' {
        Set-Content -LiteralPath $script:Csv -Value 'MeterId,Quantity' -Encoding utf8
        { Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs } | Should -Throw '*no UsageStartTime column*'
        Set-Content -LiteralPath $script:Csv -Value '' -NoNewline
        (Set-RdaConsumptionMatch -CsvPath $script:Csv -Records $script:Recs) | Should -Be 0
    }

    It 'says in the reason that a failed read is not an empty answer' {
        (Get-RdaClaudeMarketplaceReason -RowCount 0 -TokenRecordCount 0 -ErrorCount 1) | Should -Match 'at least one read failed'
        (Get-RdaClaudeMarketplaceReason -RowCount 0 -TokenRecordCount 0 -ErrorCount 0) | Should -Match 'came back for the window'
    }
}

Describe 'Azure ids under another culture' {
    It 'reads an upper-case id under tr-TR as an Azure id, and masks it as a path' {
        $Old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try
        {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $Row = [pscustomobject]@{ InstanceId = 'SUBSCRIPTIONS/11111111-1111-1111-1111-111111111111/RESOURCEGROUPS/RG/PROVIDERS/MICROSOFT.SAAS/RESOURCES/X' }
            Get-RdaMarketplaceCanonicalId -Row $Row | Should -Be '/SUBSCRIPTIONS/11111111-1111-1111-1111-111111111111/RESOURCEGROUPS/RG/PROVIDERS/MICROSOFT.SAAS/RESOURCES/X'
            (Get-RdaArmIdParts -Id '/SUBSCRIPTIONS/abc/RESOURCEGROUPS/Rg/providers/x').Subscription | Should -Be 'abc'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $Old }
    }

    It 'reads a subscription-scope id as an Azure id' {
        Get-RdaMarketplaceCanonicalId -Row ([pscustomobject]@{ InstanceId = 'subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.SaaS/resources/x' }) | Should -Be '/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.SaaS/resources/x'
        (Get-RdaArmIdParts -Id '/subscriptions/abc/providers/x/y/z').ResourceGroup | Should -Be ''
    }
}

Describe 'Token windows and kinds' {
    It 'asks only Foundry accounts, not an account with no kind' {
        Mock Get-AzMetric { @() }
        $Mk = { param($Name, $Kind) [pscustomobject]@{ id = $script:AcctId.Replace('acct-foundry-1', $Name); name = $Name; resourceGroup = 'rg-ai-app'; subscriptionId = $script:SubId; location = 'eastus2'; kind = $Kind } }
        $Result = Invoke-RdaClaudeTokenCollection -Accounts @((& $Mk 'a1' 'AIServices'), (& $Mk 'a2' 'OpenAI'), (& $Mk 'a3' '')) -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        $Result.Accounts | Should -Be 1
    }

    It 'writes an error when Azure returns a count outside the window' {
        Mock Get-AzMetric {
            $Series = [pscustomobject]@{ Metadatavalues = @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'modelname' }; Value = 'claude-sonnet-4-5' }); Data = @([pscustomobject]@{ TimeStamp = [datetime]::new(2026, 11, 13, 0, 0, 0, [System.DateTimeKind]::Utc); Total = 40 }, [pscustomobject]@{ TimeStamp = [datetime]::new(2026, 11, 11, 0, 0, 0, [System.DateTimeKind]::Utc); Total = 2 }) }
            @(New-TestMetric 'InputTokens' @($Series))
        }
        $Result = Invoke-RdaClaudeTokenCollection -Accounts @($script:Account) -Subscriptions $script:Subs -LookbackDays 3 -Now $script:Now -RetryDelaySeconds 0
        $Result.Errors.Count | Should -Be 1
        $Result.Errors[0].Message | Should -Match 'outside the window'
        $Result.Records[0].Total | Should -Be 2
    }

    It 'gives an empty date, not Azure''s text, for a date it cannot read' {
        Format-RdaClaudeUtc 'not-a-date' | Should -Be ''
    }
}

Describe 'Match prefers the same resource' {
    It 'marks the record of the resource that is in the Consumption file, not the first one with the same quantity' {
        $Csv = Join-Path ([System.IO.Path]::GetTempPath()) ("Consumption_{0}.csv" -f [guid]::NewGuid())
        try
        {
            $Mk = { param($Res) $R = ConvertTo-RdaClaudeMarketplaceRecord -ExportRow (ConvertTo-RdaMarketplaceRow -Row @(script:New-RealShapeRows)[0]); $R.InstanceId = $Res; $R }
            $A = & $Mk '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/y/providers/microsoft.saas/resources/a'
            $B = & $Mk '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/y/providers/microsoft.saas/resources/b'
            @([pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = '11/21/2026 12:00:00 AM'; Quantity = '1114.676'; ResourceId = $B.InstanceId }) | Export-Csv -LiteralPath $Csv -Encoding utf8 -NoTypeInformation
            $null = Set-RdaConsumptionMatch -CsvPath $Csv -Records @($A, $B) -Zone ([System.TimeZoneInfo]::Utc)
            $B.AlsoInConsumption | Should -BeTrue
            $A.AlsoInConsumption | Should -BeFalse
        }
        finally { Remove-Item -LiteralPath $Csv -ErrorAction SilentlyContinue }
    }
}

Describe 'Daylight saving end and near misses' {
    It 'finds the UTC day when the zone repeats the hour after midnight UTC' {
        $Zone = [System.TimeZoneInfo]::FindSystemTimeZoneById('Europe/London')
        # 2026-10-25 01:00 UTC is written as 01:00 local, an hour that happens twice.
        Get-RdaConsumptionUtcDay -Written ([datetime]::new(2026, 10, 25, 1, 0, 0)) -Zone $Zone | Should -Be '2026-10-25'
    }

    It 'counts a Consumption row with the same meter, day and subscription and another quantity' {
        $Csv = Join-Path ([System.IO.Path]::GetTempPath()) ("Consumption_{0}.csv" -f [guid]::NewGuid())
        try
        {
            $Recs = @(script:New-RealShapeRows | ForEach-Object { ConvertTo-RdaClaudeMarketplaceRecord -ExportRow (ConvertTo-RdaMarketplaceRow -Row $_) })
            @([pscustomobject]@{ MeterId = 'aaaaaaaa-0000-0000-0000-000000000001'; UsageStartTime = '11/21/2026 12:00:00 AM'; Quantity = '1114.68'; ResourceId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourcegroups/y/providers/a/b/c' }) | Export-Csv -LiteralPath $Csv -Encoding utf8 -NoTypeInformation
            $Stats = @{}
            $null = Set-RdaConsumptionMatch -CsvPath $Csv -Records $Recs -Zone ([System.TimeZoneInfo]::Utc) -Stats $Stats
            $Stats['NearMiss'] | Should -Be 1
            $Recs[0].AlsoInConsumption | Should -BeFalse
        }
        finally { Remove-Item -LiteralPath $Csv -ErrorAction SilentlyContinue }
    }
}
