# Claude Marketplace charges and Claude token counts -> ClaudeMarketPlace_<report>_<stamp>.json
#
# WHY THIS EXISTS. Claude models in Microsoft Foundry are sold through Azure Marketplace by Anthropic and
# billed in Claude Consumption Units (CCU). The usage call the tool reads for the Consumption file returns
# Azure's own meters; on the account checked the CCU charge was not in it, and on other agreement types it may be
# (each row says so). A CCU amount cannot be turned back into tokens.
# This file holds both sides of that charge:
#   Rows        the Anthropic / Claude rows of Get-AzConsumptionMarketplace (quantity, amount, unit, dates)
#   TokenUsage  the token counts Azure Monitor keeps per Claude model on each Foundry account
#               (Microsoft.CognitiveServices/accounts), daily and for the whole window
#   Errors      every subscription or account the tool could not read, so a gap is never silent
#
# WHAT IT DOES NOT TOUCH. The Inventory, Metrics and Consumption files are written exactly as before.
# This is a new file whose name does not start with Inventory, Metrics or Consumption, so a reader
# that does not know it skips it. The dictionary file gains a token only for something this file masks that the
# inventory did not hold.
#
# CLAUDE ONLY. Models Microsoft sells itself (GPT and the rest) are billed from their own Consumption
# meters, so their token counts are not written here: a reader that adds this file to the Consumption file
# would count them twice. A token series is kept only when its ModelName holds "claude".
#
# The token logic is the Foundry token collection (one Get-AzMetric call per account, five token counts,
# split by ModelName, daily totals), narrowed to Claude and with the records returned instead of written.
# The metric names and their ModelName dimension are from Microsoft's "Supported metrics -
# Microsoft.CognitiveServices/accounts" page (Models - Usage). ProcessedPromptTokens and GeneratedTokens are
# not used: they have no ModelName dimension.

function Global:Get-RdaClaudeTokenMetricName
{
    # The five token counts read per account, in the order they are requested.
    [OutputType([string[]])]
    param()
    return [string[]]@('InputTokens', 'OutputTokens', 'cacheReadInputTokens', 'ephemeral5mInputTokens', 'ephemeral1hInputTokens')
}

function Global:Test-RdaClaudeModelName
{
    # $true when a ModelName is a Claude model. Case is ignored. An empty name is not Claude.
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$ModelName)
    if ([string]::IsNullOrWhiteSpace($ModelName)) { return $false }
    return [regex]::IsMatch($ModelName, 'claude', 'IgnoreCase, CultureInvariant')
}

function Global:Test-RdaClaudeMarketplaceRow
{
    # $true when a Get-AzConsumptionMarketplace row is an Anthropic charge: the publisher starts with
    # Anthropic. Only when the row has no publisher at all do the offer and plan decide: they must hold the whole
    # word anthropic or claude. A row of another publisher is never kept, whatever its offer is called. Case is ignored.
    [OutputType([bool])]
    param([AllowNull()]$Row)
    if ($null -eq $Row) { return $false }
    $Publisher = [string]$Row.PublisherName
    if (-not [string]::IsNullOrWhiteSpace($Publisher)) { return [regex]::IsMatch($Publisher, '^\s*anthropic', 'IgnoreCase, CultureInvariant') }
    foreach ($Text in @([string]$Row.OfferName, [string]$Row.PlanName))
    {
        if ([regex]::IsMatch($Text, '\b(anthropic|claude)\b', 'IgnoreCase, CultureInvariant')) { return $true }
    }
    return $false
}

function Global:Test-RdaClaudeThrottle
{
    # $true when an error message is a throttle, a time-out or a short outage: the call is worth trying again.
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$ErrorMessage)
    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }
    return [bool]($ErrorMessage -match '(?i)(TooManyRequests|\b429\b|throttl|rate limit|timed? ?out|\b408\b|temporarily unavailable|\b503\b)')
}

function Global:Test-RdaClaudeMetricPermanentFailure
{
    # $true when a Get-AzMetric error will never succeed on retry (a bad request or a resource
    # that does not exist); $false for throttling, timeouts and anything unknown, which are retried.
    # A throttle is checked first, so a long message that also holds a 4xx word is still retried.
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$ErrorMessage)

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }
    if (Test-RdaClaudeThrottle -ErrorMessage $ErrorMessage) { return $false }
    return [bool]($ErrorMessage -match "(?i)(BadRequest|NotFound|Unauthorized|Forbidden|AuthorizationFailed|\(40[0134]\)|status code\D{0,40}\b40[0134]\b)")
}

function Global:Get-RdaClaudeTokenWindow
{
    # Whole UTC days: from 00:00 UTC LookbackDays days ago to 00:00 UTC today, so every daily
    # point is a full day and two runs on the same day ask for the same window.
    param(
        [int]$LookbackDays = 31,
        [datetime]$Now = [datetime]::UtcNow
    )

    $Days = [math]::Abs($LookbackDays)
    if ($Days -lt 1) { $Days = 1 }
    $End = [datetime]::SpecifyKind($Now.ToUniversalTime().Date, [System.DateTimeKind]::Utc)
    $Start = $End.AddDays(-1 * $Days)
    return [pscustomobject]@{ Start = $Start; End = $End }
}

function Global:Format-RdaClaudeUtc
{
    # A date as yyyy-MM-ddTHH:mm:ssZ in UTC, whatever the culture. A date with no kind is read as UTC, because
    # Azure billing dates are UTC. Empty or unreadable in, empty out.
    param([AllowNull()]$Value)
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { return '' }
    $Invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $Date = $null
    if ($Value -is [datetime]) { $Date = $Value }
    elseif ($Value -is [System.DateTimeOffset]) { $Date = $Value.UtcDateTime }
    else
    {
        $Parsed = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$Value, $Invariant, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$Parsed)) { return '' }
        $Date = $Parsed
    }
    if ($Date.Kind -eq [System.DateTimeKind]::Unspecified) { $Date = [datetime]::SpecifyKind($Date, [System.DateTimeKind]::Utc) }
    return $Date.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant)
}

function Global:ConvertFrom-RdaClaudeTokenMetric
{
    # Turns the Get-AzMetric results for ONE account (one result per metric, each split by
    # ModelName) into token records. A model with no tokens in the window gives no record.
    # Only Claude models give records: every other series is counted in $Skipped.NonClaudeSeries and dropped.
    # Totals and series values are whole numbers ([long]); a missing daily point is 0.
    param(
        [AllowNull()]$MetricResults,
        [Parameter(Mandatory = $true)]$Account,
        [Parameter(Mandatory = $true)]$Window,
        [hashtable]$Skipped = @{}
    )

    if (-not $Skipped.ContainsKey('NonClaudeSeries')) { $Skipped['NonClaudeSeries'] = 0 }
    if (-not $Skipped.ContainsKey('NoModelSeries')) { $Skipped['NoModelSeries'] = 0 }
    if (-not $Skipped.ContainsKey('OutOfWindowPoints')) { $Skipped['OutOfWindowPoints'] = 0 }
    $DayCount = [int][math]::Round(($Window.End - $Window.Start).TotalDays)
    $Records = [System.Collections.Generic.List[object]]::new()
    foreach ($Result in @($MetricResults))
    {
        if ($null -eq $Result) { continue }

        $MetricName = $Result.Name.Value
        if ([string]::IsNullOrEmpty($MetricName)) { $MetricName = [string]$Result.Name }

        foreach ($Series in @($Result.Timeseries))
        {
            if ($null -eq $Series) { continue }

            $Model = $null
            foreach ($Meta in @($Series.Metadatavalues))
            {
                if ($null -eq $Meta) { continue }
                $MetaName = $Meta.Name.Value
                if ([string]::IsNullOrEmpty($MetaName)) { $MetaName = [string]$Meta.Name }
                if ($MetaName -ieq 'modelname') { $Model = [string]$Meta.Value }
            }
            if ([string]::IsNullOrWhiteSpace($Model))
            {
                # A series that is not split by model cannot be told from a Claude one. It is counted, and the
                # caller writes an error record, so the gap is never silent.
                if (@($Series.Data | Where-Object { $null -ne $_ -and $null -ne $_.Total -and [double]$_.Total -gt 0 }).Count -gt 0) { $Skipped['NoModelSeries'] = [int]$Skipped['NoModelSeries'] + 1 }
                continue
            }
            if (-not (Test-RdaClaudeModelName -ModelName $Model))
            {
                $Skipped['NonClaudeSeries'] = [int]$Skipped['NonClaudeSeries'] + 1
                continue
            }

            $Daily = [System.Collections.Generic.List[long]]::new()
            $Points = @($Series.Data | Where-Object { $null -ne $_ })
            $HaveStamps = ($Points.Count -gt 0) -and (@($Points | Where-Object { $null -eq $_.TimeStamp }).Count -eq 0)
            if ($HaveStamps -and $DayCount -ge 1)
            {
                # One value per day of the window, by the point's own date: a day Azure left out is 0 and does
                # not move the days after it.
                $ByDay = @{}
                foreach ($Point in $Points)
                {
                    $Day = Format-RdaClaudeUtc $Point.TimeStamp
                    if ($Day.Length -ge 10)
                    {
                        $PointValue = if ($null -eq $Point.Total) { [long]0 } else { [long][math]::Round([double]$Point.Total) }
                        $DayKey = $Day.Substring(0, 10)
                        $ByDay[$DayKey] = $(if ($ByDay.ContainsKey($DayKey)) { [long]$ByDay[$DayKey] } else { [long]0 }) + $PointValue
                    }
                }
                $WindowKeys = @{}
                for ($i = 0; $i -lt $DayCount; $i++)
                {
                    $Key = (Format-RdaClaudeUtc $Window.Start.AddDays($i)).Substring(0, 10)
                    $WindowKeys[$Key] = $true
                    $Daily.Add($(if ($ByDay.ContainsKey($Key)) { [long]$ByDay[$Key] } else { [long]0 }))
                }
                # A day outside the window is not in the series or the total, so it is counted and the caller says so.
                foreach ($DayKey in $ByDay.Keys) { if (-not $WindowKeys.ContainsKey($DayKey) -and [long]$ByDay[$DayKey] -gt 0) { $Skipped['OutOfWindowPoints'] = [int]$Skipped['OutOfWindowPoints'] + 1 } }
            }
            else
            {
                foreach ($Point in $Points)
                {
                    $Value = if ($null -eq $Point.Total) { 0 } else { [long][math]::Round([double]$Point.Total) }
                    $Daily.Add($Value)
                }
            }

            $Total = [long]0
            foreach ($v in $Daily) { $Total += $v }
            if ($Total -le 0) { continue }

            $Records.Add([ordered]@{
                    ID            = [string]$Account.Id
                    Subscription  = [string]$Account.SubscriptionName
                    ResourceGroup = [string]$Account.ResourceGroup
                    Name          = [string]$Account.Name
                    Location      = [string]$Account.Location
                    ModelName     = $Model
                    Metric        = $MetricName
                    TimeGrain     = '1.00:00:00'
                    StartTime     = Format-RdaClaudeUtc $Window.Start
                    EndTime       = Format-RdaClaudeUtc $Window.End
                    Total         = $Total
                    DailySeries   = [long[]]$Daily.ToArray()
                })
        }
    }
    return , $Records
}

function Global:Protect-RdaClaudeTokenRecord
{
    # Under -Obfuscate: give the record's ID, Name, ResourceGroup and Subscription the SAME tokens
    # the run gave this account everywhere else (the shared dictionaries are filled for every
    # discovered resource before any phase writes, and the Consumption ResourceId of the account
    # reads the same ResourceIdDictionary entry). Location and ModelName stay real: a region code
    # and an Azure model name are not customer text.
    # An account missing from the dictionaries (not expected) gets an ARM-shaped path from
    # Build-ObfuscatedResourceUri, stored in the dictionaries so Reveal can map it back, and its
    # Name, ResourceGroup and Subscription are read from that path, so they always equal its parts.
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)]$ResourceIdDictionary,
        [Parameter(Mandatory = $true)]$ResourceNameDictionary,
        [Parameter(Mandatory = $true)]$ResourceSubDictionary,
        [Parameter(Mandatory = $true)]$ResourceGroupDictionary,
        [hashtable]$SubCache = @{},
        [hashtable]$RgCache = @{},
        [hashtable]$NameCache = @{}
    )

    $RealId = [string]$Record.ID
    if ([string]::IsNullOrEmpty($RealId)) { return $Record }

    if ($ResourceIdDictionary.ContainsKey($RealId) -and $ResourceNameDictionary.ContainsKey($RealId) -and
        $ResourceSubDictionary.ContainsKey($RealId) -and $ResourceGroupDictionary.ContainsKey($RealId))
    {
        $Record.ID = $ResourceIdDictionary[$RealId]
        $Record.Name = $ResourceNameDictionary[$RealId]
        $Record.Subscription = $ResourceSubDictionary[$RealId]
        $Record.ResourceGroup = $ResourceGroupDictionary[$RealId]
        return $Record
    }

    $Prefix = if ($RealId -match '\b(dev|test|qa|tst|development|non-prod|uat|nonprod)\b' -or $RealId -match '(^|/|-)([dts])-') { 'nonprod_' } else { 'prod_' }
    $MaskedId = if ($ResourceIdDictionary.ContainsKey($RealId)) { $ResourceIdDictionary[$RealId] }
    else
    {
        Build-ObfuscatedResourceUri -RawUri $RealId -Prefix $Prefix -SubscriptionDictionary $ResourceSubDictionary -ResourceGroupDictionary $ResourceGroupDictionary -NameDictionary $ResourceNameDictionary -SubCache $SubCache -RgCache $RgCache -NameCache $NameCache
    }
    $ResourceIdDictionary[$RealId] = $MaskedId

    if ($MaskedId -match '^/subscriptions/([^/]+)(/resourcegroups/([^/]+))?(/providers/.+/([^/]+))?$')
    {
        if (-not $ResourceSubDictionary.ContainsKey($RealId)) { $ResourceSubDictionary[$RealId] = $Matches[1] }
        if (-not [string]::IsNullOrEmpty($Matches[3]) -and -not $ResourceGroupDictionary.ContainsKey($RealId)) { $ResourceGroupDictionary[$RealId] = $Matches[3] }
        if (-not [string]::IsNullOrEmpty($Matches[5]) -and -not $ResourceNameDictionary.ContainsKey($RealId)) { $ResourceNameDictionary[$RealId] = $Matches[5] }
    }

    $Record.ID = $MaskedId
    $Record.Name = if ($ResourceNameDictionary.ContainsKey($RealId)) { $ResourceNameDictionary[$RealId] } else { 'obfuscated' }
    $Record.Subscription = if ($ResourceSubDictionary.ContainsKey($RealId)) { $ResourceSubDictionary[$RealId] } else { 'obfuscated' }
    $Record.ResourceGroup = if ($ResourceGroupDictionary.ContainsKey($RealId)) { $ResourceGroupDictionary[$RealId] } else { 'obfuscated' }
    return $Record
}

function Global:Get-RdaClaudeTokenMetricResult
{
    # One Get-AzMetric call per account for all five token counts, split by ModelName, daily totals.
    # Retries a transient failure up to MaxRetries times with a short backoff; a permanent failure
    # (bad request, not found, no access) is not retried. -Top is set because Get-AzMetric returns at most 10
    # series with a filter unless it is: https://learn.microsoft.com/powershell/module/az.monitor/get-azmetric Throws the last error when every attempt failed.
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)]$Window,
        [int]$MaxRetries = 3,
        [double]$BaseDelaySeconds = 2
    )

    $Attempt = 0
    while ($true)
    {
        try
        {
            return Get-AzMetric -ResourceId $ResourceId -MetricName (Get-RdaClaudeTokenMetricName) `
                -StartTime $Window.Start -EndTime $Window.End -TimeGrain '1.00:00:00' -AggregationType Total `
                -MetricFilter "ModelName eq '*'" -Top 1000 -ErrorAction Stop -WarningAction SilentlyContinue
        }
        catch
        {
            $Message = $_.Exception.Message
            if ((Test-RdaClaudeMetricPermanentFailure -ErrorMessage $Message) -or $Attempt -ge $MaxRetries) { throw }
            $Attempt++
            if ($BaseDelaySeconds -gt 0) { Start-Sleep -Milliseconds ([int](1000 * [math]::Min($BaseDelaySeconds * [math]::Pow(2, $Attempt - 1), 30))) }
        }
    }
}

function Global:New-RdaClaudeMarketplaceError
{
    # One error record: the file shows what could not be read instead of leaving a silent gap.
    # Source is Marketplace, AzureMonitor, Consumption (the comparison with the Consumption file) or File. Scope is the subscription (Marketplace) or the account id
    # (AzureMonitor), already masked by the caller under -Obfuscate. Under -Obfuscate the message is a fixed
    # sentence, because Azure's own text can hold real names; the full text stays in the run log.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Marketplace', 'AzureMonitor', 'Consumption', 'File')][string]$Source,
        [AllowEmptyString()][string]$Scope = '',
        [AllowEmptyString()][string]$Message = '',
        [bool]$Obfuscate = $false
    )

    $Text = if ($Obfuscate)
    {
        switch ($Source)
        {
            'Marketplace' { 'Azure Marketplace charges could not be read for this subscription. The rows for it may be missing or incomplete. The run log holds the cause.' }
            'AzureMonitor' { if ($Scope -eq '(all accounts)') { 'Azure Monitor token counts were not read for any account. The run log holds the cause.' } else { 'Azure Monitor token counts were read only in part or not at all for this account. The run log holds the cause.' } }
            'Consumption' { 'The Consumption file could not be compared with, so AlsoInConsumption false may be wrong. The run log holds the cause.' }
            'File' { 'The file could not be written by the collection. The run log holds the cause.' }
        }
    }
    else { (([string]$Message) -split "`r?`n")[0] }
    return [ordered]@{ Source = $Source; Scope = $Scope; Message = $Text }
}

function Global:Invoke-RdaClaudeTokenCollection
{
    # Reads the Claude token counts of every Foundry account in $Accounts. $Accounts are rows with
    # id, name, resourceGroup, subscriptionId and location (the discovery rows of type
    # microsoft.cognitiveservices/accounts). No account: no call. Every account that Azure refuses gets one
    # error record and the run goes on.
    # Returns Accounts, Records (token records, masked under -Obfuscate), Errors, Failed, NonClaudeSeries.
    param(
        [AllowNull()]$Accounts,
        [AllowNull()]$Subscriptions,
        [bool]$Obfuscate = $false,
        $ResourceIdDictionary,
        $ResourceNameDictionary,
        $ResourceSubDictionary,
        $ResourceGroupDictionary,
        [int]$LookbackDays = 31,
        [datetime]$Now = [datetime]::UtcNow,
        [double]$RetryDelaySeconds = 2
    )

    # Claude models run on Foundry (AIServices) accounts. OpenAI, Speech, Vision, the other Cognitive Services
    # kinds and a row with no kind are not asked.
    $AccountList = @($Accounts | Where-Object { $null -ne $_ -and [string]$_.kind -ieq 'AIServices' })
    $Window = Get-RdaClaudeTokenWindow -LookbackDays $LookbackDays -Now $Now
    $Result = [pscustomobject]@{
        Accounts        = $AccountList.Count
        Records         = [System.Collections.Generic.List[object]]::new()
        Errors          = [System.Collections.Generic.List[object]]::new()
        Failed          = 0
        NonClaudeSeries = 0
        Window          = $Window
    }
    if ($AccountList.Count -eq 0) { return $Result }

    $SubNames = @{}
    foreach ($Sub in @($Subscriptions)) { if ($null -ne $Sub -and $Sub.id) { $SubNames[[string]$Sub.id] = [string]$Sub.Name } }

    $Skipped = @{ NonClaudeSeries = 0; NoModelSeries = 0; OutOfWindowPoints = 0 }
    $SubCache = @{}; $RgCache = @{}; $NameCache = @{}

    foreach ($Acct in $AccountList)
    {
        $SubName = $SubNames[[string]$Acct.subscriptionId]
        if ([string]::IsNullOrEmpty($SubName)) { $SubName = [string]$Acct.subscriptionId }
        $Info = [pscustomobject]@{ Id = [string]$Acct.id; SubscriptionName = $SubName; ResourceGroup = [string]$Acct.resourceGroup; Name = [string]$Acct.name; Location = [string]$Acct.location }

        $Records = @()
        $FailureMessage = $null
        $NoModelBefore = [int]$Skipped['NoModelSeries']
        $OutOfWindowBefore = [int]$Skipped['OutOfWindowPoints']
        try
        {
            $MetricResult = Get-RdaClaudeTokenMetricResult -ResourceId $Info.Id -Window $Window -BaseDelaySeconds $RetryDelaySeconds
            $Records = ConvertFrom-RdaClaudeTokenMetric -MetricResults $MetricResult -Account $Info -Window $Window -Skipped $Skipped
        }
        catch
        {
            $FailureMessage = $_.Exception.Message
        }

        if ($null -eq $FailureMessage -and [int]$Skipped['NoModelSeries'] -gt $NoModelBefore)
        {
            $FailureMessage = 'Azure Monitor returned a token series that is not split by model, so it was left out.'
        }
        if ($null -eq $FailureMessage -and [int]$Skipped['OutOfWindowPoints'] -gt $OutOfWindowBefore)
        {
            $FailureMessage = 'Azure Monitor returned a token count outside the window, so it is not in the series or the total.'
        }

        $Scope = $Info.Id
        foreach ($Rec in $Records)
        {
            if ($Obfuscate)
            {
                $Rec = Protect-RdaClaudeTokenRecord -Record $Rec -ResourceIdDictionary $ResourceIdDictionary -ResourceNameDictionary $ResourceNameDictionary -ResourceSubDictionary $ResourceSubDictionary -ResourceGroupDictionary $ResourceGroupDictionary -SubCache $SubCache -RgCache $RgCache -NameCache $NameCache
            }
            $Result.Records.Add($Rec)
        }

        if ($null -ne $FailureMessage)
        {
            $Result.Failed++
            # Azure's own text can hold real names, so under -Obfuscate the file gets a fixed sentence. The private
            # run log keeps the full text.
            if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) { Write-Log -Message ('Claude token counts: account read failed: {0}' -f $FailureMessage) -Severity 'Warning' -NoConsole -ToDebugLog }
            if ($Obfuscate)
            {
                $Probe = Protect-RdaClaudeTokenRecord -Record ([ordered]@{ ID = $Info.Id; Name = ''; Subscription = ''; ResourceGroup = '' }) -ResourceIdDictionary $ResourceIdDictionary -ResourceNameDictionary $ResourceNameDictionary -ResourceSubDictionary $ResourceSubDictionary -ResourceGroupDictionary $ResourceGroupDictionary -SubCache $SubCache -RgCache $RgCache -NameCache $NameCache
                $Scope = [string]$Probe.ID
            }
            $Result.Errors.Add((New-RdaClaudeMarketplaceError -Source AzureMonitor -Scope $Scope -Message $FailureMessage -Obfuscate $Obfuscate))
        }
    }
    $Result.NonClaudeSeries = [int]$Skipped['NonClaudeSeries']
    return $Result
}

function Global:ConvertTo-RdaClaudeMarketplaceRecord
{
    # One Marketplace row (the flat object ConvertTo-RdaMarketplaceRow makes, masked or not) -> the record
    # written to the file. Numbers are JSON numbers and never null (no value reads as 0), dates are UTC text
    # in one fixed form. The order number and the subscription name are not written. AlsoInConsumption,
    # AlsoInConsumptionMatch and ResourceInConsumption start false/None and are set by Set-RdaConsumptionMatch.
    param([Parameter(Mandatory = $true)]$ExportRow)

    $Invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $Quantity = [decimal]0
    if ($null -ne $ExportRow.ConsumedQuantity -and -not [decimal]::TryParse([string]$ExportRow.ConsumedQuantity, [System.Globalization.NumberStyles]::Float, $Invariant, [ref]$Quantity))
    {
        if ($ExportRow.ConsumedQuantity -is [ValueType]) { $Quantity = [decimal]$ExportRow.ConsumedQuantity }
    }
    $Cost = [decimal]0
    if ($null -ne $ExportRow.PretaxCost -and -not [decimal]::TryParse([string]$ExportRow.PretaxCost, [System.Globalization.NumberStyles]::Float, $Invariant, [ref]$Cost))
    {
        if ($ExportRow.PretaxCost -is [ValueType]) { $Cost = [decimal]$ExportRow.PretaxCost }
    }

    return [ordered]@{
        PublisherName          = [string]$ExportRow.PublisherName
        OfferName              = [string]$ExportRow.OfferName
        PlanName               = [string]$ExportRow.PlanName
        ConsumedService        = [string]$ExportRow.ConsumedService
        ConsumedQuantity       = $Quantity
        UnitOfMeasure          = [string]$ExportRow.UnitOfMeasure
        PretaxCost             = $Cost
        Currency               = [string]$ExportRow.Currency
        IsEstimated            = [bool]$ExportRow.IsEstimated
        MeterId                = [string]$ExportRow.MeterId
        UsageStart             = (Format-RdaClaudeUtc $ExportRow.UsageStart)
        UsageEnd               = (Format-RdaClaudeUtc $ExportRow.UsageEnd)
        SubscriptionGuid       = [string]$ExportRow.SubscriptionGuid
        ResourceGroup          = [string]$ExportRow.ResourceGroup
        InstanceId             = [string]$ExportRow.InstanceId
        InstanceName           = [string]$ExportRow.InstanceName
        AlsoInConsumption      = $false
        AlsoInConsumptionMatch = 'None'
        ResourceInConsumption  = $false
    }
}

function Global:Get-RdaConsumptionUtcDay
{
    # The UTC calendar day (yyyy-MM-dd) of a usage time read from the Consumption CSV, or '' when it cannot be told.
    # The CSV text has no offset: it is the time as this machine wrote it. A usage day starts at 00:00 UTC, so the
    # text is read as local time first (and converted to UTC), and as UTC when that does not land on midnight. A time
    # that is midnight in neither reading is not a daily row and has no day.
    param(
        [Parameter(Mandatory = $true)][datetime]$Written,
        [System.TimeZoneInfo]$Zone = [System.TimeZoneInfo]::Local
    )
    $Invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $Unspecified = [datetime]::SpecifyKind($Written, [System.DateTimeKind]::Unspecified)
    # A local time that does not exist (the hour a zone skips when it starts daylight saving) has no UTC reading.
    if (-not $Zone.IsInvalidTime($Unspecified))
    {
        # An ambiguous local time (the hour a zone repeats when daylight saving ends) can be either of two UTC times.
        $Offsets = if ($Zone.IsAmbiguousTime($Unspecified)) { @($Zone.GetAmbiguousTimeOffsets($Unspecified)) } else { @($Zone.GetUtcOffset($Unspecified)) }
        foreach ($Offset in $Offsets)
        {
            $FromLocal = ($Unspecified - $Offset)
            if ($FromLocal.TimeOfDay.Ticks -eq 0) { return $FromLocal.ToString('yyyy-MM-dd', $Invariant) }
        }
    }
    if ($Written.TimeOfDay.Ticks -eq 0) { return $Written.ToString('yyyy-MM-dd', $Invariant) }
    return ''
}

function Global:Set-RdaConsumptionMatch
{
    # Reads the Consumption CSV of this run once, one row at a time, and marks each record:
    #   AlsoInConsumption = true, AlsoInConsumptionMatch = 'MeterDayQuantity' when a Consumption row has the same
    #     meter id, the same usage day (UTC), the same subscription and exactly the same quantity: the same charge.
    #     One Consumption row marks at most one record. A Consumption row whose resource id has no subscription
    #     cannot be tied to one, so it marks nothing.
    #   ResourceInConsumption = true when a Consumption row has the same resource id. This is only a hint: one
    #     resource can hold its own Azure usage and a Marketplace charge, so it never sets AlsoInConsumption.
    # $RecordSubscriptions holds the real subscription id of each record, in the order of $Records (the file does not
    # hold it under -Obfuscate). $TokenToSubscription maps a masked subscription token to the real id, or to a list
    # of real ids when two subscriptions share a token; it is $null when the run is not masked, and the ids in the CSV
    # are then real. A Consumption row that carries the meter of a Marketplace row but cannot be compared (its
    # resource id has no known subscription, or its date or quantity does not parse) is counted in Stats.Unreadable,
    # because a false then proves nothing. The file needs the MeterId, UsageStartTime, Quantity and ResourceId columns.
    # A record with no meter id cannot be matched on the meter test. The CSV is read after it is written, so the
    # Consumption phase does not change. Memory stays flat: only the Marketplace records are held.
    # Returns the number of Consumption rows read. A missing file reads as 0 rows: the Consumption phase writes
    # nothing when it finds no row. Throws when the file cannot be read.
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [AllowNull()]$Records,
        [AllowNull()][string[]]$RecordSubscriptions = $null,
        [AllowNull()]$TokenToSubscription = $null,
        [System.TimeZoneInfo]$Zone = [System.TimeZoneInfo]::Local,
        # Filled in: Unreadable = Consumption rows with the meter of a Marketplace row that could not be compared;
        # NearMiss = Consumption rows with the meter, day and subscription of a Marketplace row but another quantity.
        [hashtable]$Stats = @{}
    )

    $RecordList = @($Records | Where-Object { $null -ne $_ })
    if ($RecordList.Count -eq 0) { return [long]0 }
    if (-not (Test-Path -LiteralPath $CsvPath)) { return [long]0 }

    $Stats['Unreadable'] = [long]0
    $Stats['NearMiss'] = [long]0
    $Invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $UsCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
    $ByMeterDay = @{}
    $Meters = @{}
    $ByResource = @{}
    for ($i = 0; $i -lt $RecordList.Count; $i++)
    {
        $Rec = $RecordList[$i]
        $RealSub = if ($null -ne $RecordSubscriptions -and $i -lt $RecordSubscriptions.Count) { [string]$RecordSubscriptions[$i] } else { [string]$Rec['SubscriptionGuid'] }
        $Entry = [pscustomobject]@{ Record = $Rec; Subscription = $RealSub }
        $Meter = ([string]$Rec['MeterId']).Trim().ToLowerInvariant()
        if ($Meter.Length -gt 0 -and ([string]$Rec['UsageStart']).Length -ge 10)
        {
            $Meters[$Meter] = $true
            $Key = $Meter + '|' + ([string]$Rec['UsageStart']).Substring(0, 10)
            if (-not $ByMeterDay.ContainsKey($Key)) { $ByMeterDay[$Key] = [System.Collections.Generic.List[object]]::new() }
            $ByMeterDay[$Key].Add($Entry)
        }
        $Resource = [string]$Rec['InstanceId']
        if ($Resource.Length -gt 0)
        {
            if (-not $ByResource.ContainsKey($Resource)) { $ByResource[$Resource] = [System.Collections.Generic.List[object]]::new() }
            $ByResource[$Resource].Add($Rec)
        }
    }

    # The header is checked before any row is read, so a header-only or cut-short file is caught too.
    $HeaderLine = Get-Content -LiteralPath $CsvPath -TotalCount 1
    if ([string]::IsNullOrWhiteSpace($HeaderLine)) { return [long]0 }
    $HeaderNames = @($HeaderLine.Split(',') | ForEach-Object { $_.Trim().Trim('"') })
    foreach ($Column in 'MeterId', 'UsageStartTime', 'Quantity', 'ResourceId')
    {
        if ($HeaderNames -notcontains $Column) { throw ('the Consumption file has no {0} column' -f $Column) }
    }

    $RowsRead = [long]0
    Import-Csv -LiteralPath $CsvPath | ForEach-Object {
        $RowsRead++
        $Resource = [string]$_.ResourceId
        if ($Resource.Length -gt 0 -and $ByResource.ContainsKey($Resource))
        {
            foreach ($Rec in $ByResource[$Resource]) { $Rec['ResourceInConsumption'] = $true }
        }
        $Meter = ([string]$_.MeterId).Trim().ToLowerInvariant()
        if ($Meter.Length -eq 0 -or -not $Meters.ContainsKey($Meter)) { return }
        $Parts = Get-RdaArmIdParts -Id $Resource
        $RowSubs = @()
        if ($null -ne $Parts)
        {
            if ($null -eq $TokenToSubscription) { $RowSubs = @($Parts.Subscription) }
            elseif ($TokenToSubscription.ContainsKey($Parts.Subscription)) { $RowSubs = @($TokenToSubscription[$Parts.Subscription]) }
        }
        $Start = [datetime]::MinValue
        $Quantity = [decimal]0
        $Day = ''
        if ([datetime]::TryParse([string]$_.UsageStartTime, $UsCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Start) -or
            [datetime]::TryParse([string]$_.UsageStartTime, $Invariant, [System.Globalization.DateTimeStyles]::None, [ref]$Start))
        {
            $Day = Get-RdaConsumptionUtcDay -Written $Start -Zone $Zone
        }
        # A token that stands for more than one subscription cannot say which one the row is from.
        if ($RowSubs.Count -ne 1 -or $Day.Length -eq 0 -or -not [decimal]::TryParse([string]$_.Quantity, [System.Globalization.NumberStyles]::Float, $Invariant, [ref]$Quantity))
        {
            $Stats['Unreadable'] = [long]$Stats['Unreadable'] + 1
            return
        }
        $Key = $Meter + '|' + $Day
        if (-not $ByMeterDay.ContainsKey($Key)) { return }
        # Of the records that could be this charge, the one for the same resource comes first, so two resources with
        # one meter, day and quantity are not swapped.
        # The same meter, day and subscription with another quantity is counted: the two services may round one charge differently.
        $NearMiss = @($ByMeterDay[$Key] | Where-Object { -not $_.Record['AlsoInConsumption'] -and [decimal]$_.Record['ConsumedQuantity'] -ne $Quantity -and -not [string]::IsNullOrEmpty($_.Subscription) -and $RowSubs -contains $_.Subscription })
        if ($NearMiss.Count -gt 0) { $Stats['NearMiss'] = [long]$Stats['NearMiss'] + 1 }
        $Candidates = @($ByMeterDay[$Key] | Where-Object { -not $_.Record['AlsoInConsumption'] -and [decimal]$_.Record['ConsumedQuantity'] -eq $Quantity -and -not [string]::IsNullOrEmpty($_.Subscription) -and $RowSubs -contains $_.Subscription })
        if ($Candidates.Count -eq 0) { return }
        $Chosen = @($Candidates | Where-Object { [string]$_.Record['InstanceId'] -ieq $Resource }) | Select-Object -First 1
        if ($null -eq $Chosen) { $Chosen = $Candidates[0] }
        $Chosen.Record['AlsoInConsumption'] = $true
        $Chosen.Record['AlsoInConsumptionMatch'] = 'MeterDayQuantity'
    }
    return $RowsRead
}

function Global:Get-RdaClaudeMarketplaceReason
{
    # The sentence in the file that says why it holds what it holds. A file with no rows says which of the
    # reasons applies, so an empty list is never read as "no Claude charge exists".
    param(
        [AllowEmptyString()][string]$NotCollected = '',
        [int]$RowCount = 0,
        [int]$TokenRecordCount = 0,
        [int]$ErrorCount = 0,
        [long]$ConsumptionRowsCompared = 0
    )

    if (-not [string]::IsNullOrEmpty($NotCollected)) { return ('Not collected: {0}' -f $NotCollected) }
    $Parts = [System.Collections.Generic.List[string]]::new()
    $Parts.Add(('{0} Claude Marketplace row(s) and {1} Claude token record(s) collected.' -f $RowCount, $TokenRecordCount))
    if ($RowCount -eq 0 -and $ErrorCount -gt 0)
    {
        $Parts.Add('No Claude Marketplace row is in the file, and at least one read failed (see Errors), so this does not show that no Claude charge exists.')
    }
    elseif ($RowCount -eq 0)
    {
        $Parts.Add('No Claude Marketplace row came back for the window. The Marketplace endpoint serves only some agreement types and bills some charges late, so this does not show that no Claude charge exists.')
    }
    if ($RowCount -gt 0 -and $ConsumptionRowsCompared -eq 0)
    {
        $Parts.Add('No Consumption row was available to compare with, so AlsoInConsumption is false for every row without showing that the charge is absent from Consumption.')
    }
    if ($TokenRecordCount -eq 0)
    {
        $Parts.Add('No Claude token count was found: no Foundry account had Claude tokens in the window, or Azure Monitor could not be read (see Errors).')
    }
    if ($ErrorCount -gt 0)
    {
        $Parts.Add(('{0} read(s) failed, so the lists may be incomplete. See Errors.' -f $ErrorCount))
    }
    return ($Parts -join ' ')
}

function Global:Write-RdaClaudeMarketplaceFile
{
    # Writes ClaudeMarketPlace_<report>_<stamp>.json. The file is always written, with empty lists when there
    # is nothing, and Reason says why. The write goes to a temporary file first, so a failed write never
    # leaves half a file. Throws the write's own error.
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowNull()]$Rows,
        [AllowNull()]$TokenUsage,
        [AllowNull()]$Errors,
        [AllowEmptyString()][string]$NotCollected = '',
        [bool]$Obfuscated = $false,
        $RowsWindowStart = $null,
        $RowsWindowEnd = $null,
        $TokenWindowStart = $null,
        $TokenWindowEnd = $null,
        [long]$ConsumptionRowsCompared = 0,
        [int]$OtherMarketplaceRowsSkipped = 0,
        [int]$NonClaudeTokenSeriesSkipped = 0
    )

    $RowList = @($Rows | Where-Object { $null -ne $_ })
    $TokenList = @($TokenUsage | Where-Object { $null -ne $_ })
    $ErrorList = @($Errors | Where-Object { $null -ne $_ })

    $Document = [ordered]@{
        SchemaVersion               = 1
        Obfuscated                  = $Obfuscated
        Reason                      = (Get-RdaClaudeMarketplaceReason -NotCollected $NotCollected -RowCount $RowList.Count -TokenRecordCount $TokenList.Count -ErrorCount $ErrorList.Count -ConsumptionRowsCompared $ConsumptionRowsCompared)
        RowsWindowStart             = (Format-RdaClaudeUtc $RowsWindowStart)
        RowsWindowEnd               = (Format-RdaClaudeUtc $RowsWindowEnd)
        TokenWindowStart            = (Format-RdaClaudeUtc $TokenWindowStart)
        TokenWindowEnd              = (Format-RdaClaudeUtc $TokenWindowEnd)
        ConsumptionRowsCompared     = $ConsumptionRowsCompared
        OtherMarketplaceRowsSkipped = $OtherMarketplaceRowsSkipped
        NonClaudeTokenSeriesSkipped = $NonClaudeTokenSeriesSkipped
        Rows                        = [object[]]$RowList
        TokenUsage                  = [object[]]$TokenList
        Errors                      = [object[]]$ErrorList
    }

    $Json = $Document | ConvertTo-Json -Depth 6
    $Temp = $FilePath + '.tmp'
    try
    {
        $Json | Out-File -LiteralPath $Temp -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $Temp -Destination $FilePath -Force -ErrorAction Stop
    }
    catch
    {
        $WriteError = $_
        if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
        throw $WriteError
    }
}
