# The commands a run prints for collecting a subscription again, or for a new
# run, carry the run's settings.
# Run with: Invoke-Pester ./Tests/RetryCommandSettings.Tests.ps1 -Output Detailed
#
# A run that continues the unfinished run stops with exit 1 when its
# -Obfuscate, -SkipMetrics, -SkipConsumption or -IncludeDisabled differs, so a
# printed command without them (the FAILED (consumption) and FAILED (metrics)
# advice, the retry-limit summary, FAILED (report missing) and FAILED (earlier
# report not carried)) stopped when run as printed, and a new run started with
# it collected with other settings. A direct ResourceInventory.ps1 run printed
# its retry command without its -ResourceGroup and settings, so the command
# collected the whole subscription, with metrics and consumption.
#
# The advice under FAILED (consumption) named -ResumeFailedOnly, which collects
# only the retry list and carries no other report into its consolidated zip;
# it names the command that continues the run instead.
#
# Pure functions of Functions/Common.Functions.ps1 and
# Functions/RunAllSubscriptions.Functions.ps1, called as the scripts call them.

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')

    $script:Tenant = '12345678-1234-1234-1234-123456789012'
    function script:New-Settings
    {
        param([string[]]$On = @())
        Get-RunDataSettings -Obfuscate ($On -contains 'Obfuscate') -SkipMetrics ($On -contains 'SkipMetrics') -SkipConsumption ($On -contains 'SkipConsumption') -IncludeDisabled ($On -contains 'IncludeDisabled')
    }
    function script:Get-HostLines
    {
        param([scriptblock]$Block)
        @(& $Block 6>&1 | ForEach-Object { [string]$_.MessageData })
    }
    $script:Entry = [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; Message = 'stand-in: the usage service returned an error'; Complete = $false }
    $script:Attempt = { param([int]$Count) [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; Attempts = $Count; Reason = 'stand-in reason' } }
}

Describe 'The settings as command text' {
    It 'gives each switch that is on, in the order of the run settings' {
        Format-RunDataSwitches -Settings (script:New-Settings) | Should -Be ''
        Format-RunDataSwitches -Settings (script:New-Settings -On 'IncludeDisabled', 'Obfuscate') | Should -Be ' -Obfuscate -IncludeDisabled'
        Format-RunDataSwitches -Settings (script:New-Settings -On 'Obfuscate', 'SkipMetrics', 'SkipConsumption', 'IncludeDisabled') | Should -Be ' -Obfuscate -SkipMetrics -SkipConsumption -IncludeDisabled'
        Format-RunDataSwitches -Settings $null | Should -Be ''
    }

    It 'a wrapper command carries <Name>' -TestCases @(
        @{ Name = 'Obfuscate' }, @{ Name = 'SkipMetrics' }, @{ Name = 'SkipConsumption' }, @{ Name = 'IncludeDisabled' }
    ) {
        $S = script:New-Settings -On $Name
        Get-WrapperRunCommand -TenantID $script:Tenant -Mode '-Fresh' -Settings $S | Should -Be ('./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh -{1}' -f $script:Tenant, $Name)
        Get-WrapperRunCommand -TenantID $script:Tenant -Mode '-Resume' -Settings $S | Should -Be ('./Run-AllSubscriptions.ps1 -TenantID {0} -Resume -{1}' -f $script:Tenant, $Name)
        Get-WrapperRunCommand -TenantID $script:Tenant -Settings $S | Should -Be ('./Run-AllSubscriptions.ps1 -TenantID {0} -{1}' -f $script:Tenant, $Name)
    }
}

Describe 'The command that collects one subscription again with a direct run' {
    It 'carries <Name>' -TestCases @(
        @{ Name = 'Obfuscate' }, @{ Name = 'SkipMetrics' }, @{ Name = 'SkipConsumption' }
    ) {
        Get-DirectRunRetryCommand -TenantID $script:Tenant -SubscriptionID 'sub-a' -Settings (script:New-Settings -On $Name) | Should -Be ('./ResourceInventory.ps1 -TenantID {0} -SubscriptionID sub-a -{1}' -f $script:Tenant, $Name)
    }

    It 'leaves out -IncludeDisabled, which ResourceInventory.ps1 does not take' {
        Get-DirectRunRetryCommand -TenantID $script:Tenant -SubscriptionID 'sub-a' -Settings (script:New-Settings -On 'IncludeDisabled', 'SkipMetrics') | Should -Be ('./ResourceInventory.ps1 -TenantID {0} -SubscriptionID sub-a -SkipMetrics' -f $script:Tenant)
    }

    It 'carries the subscription and the resource group of the run, quoted' {
        Get-DirectRunRetryCommand -TenantID $script:Tenant -SubscriptionID 'sub-a' -ResourceGroup 'rg-demo' -Settings (script:New-Settings -On 'SkipConsumption') | Should -Be ("./ResourceInventory.ps1 -TenantID {0} -SubscriptionID sub-a -ResourceGroup 'rg-demo' -SkipConsumption" -f $script:Tenant)
        Get-DirectRunRetryCommand -SubscriptionID 'sub-a' -ResourceGroup "rg(it's)" | Should -Be "./ResourceInventory.ps1 -SubscriptionID sub-a -ResourceGroup 'rg(it''s)'"
        Get-DirectRunRetryCommand -SubscriptionID 'sub-a' | Should -Be './ResourceInventory.ps1 -SubscriptionID sub-a'
    }

    It 'is the command ResourceInventory.ps1 prints under FAILED (consumption) and FAILED (metrics), with the run''s resource group and settings' {
        $Inner = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw
        $Calls = [regex]::Matches($Inner, [regex]::Escape("'  ' + (Get-DirectRunRetryCommand -TenantID `$RetryTenant -SubscriptionID `$_.Id -ResourceGroup `$ResourceGroup -Settings `$RetrySettings)"))
        $Calls.Count | Should -Be 2
        $Inner | Should -Match ([regex]::Escape('$RetrySettings = [ordered]@{ Obfuscate = $Obfuscate.IsPresent; SkipMetrics = $SkipMetrics.IsPresent; SkipConsumption = $SkipConsumption.IsPresent }'))
    }
}

Describe 'The advice under FAILED (consumption) and FAILED (metrics)' {
    It 'names the command that continues the run and carries the other reports, with <Name>' -TestCases @(
        @{ Name = 'Obfuscate' }, @{ Name = 'SkipMetrics' }, @{ Name = 'SkipConsumption' }, @{ Name = 'IncludeDisabled' }
    ) {
        $Lines = @(Get-ConsumptionFailedAdvice -Entries @($script:Entry) -FailedAttempts @(& $script:Attempt 1) -TenantID $script:Tenant -Settings (script:New-Settings -On $Name))
        $Lines[0] | Should -Be 'On the retry list, so a run that continues this one collects Sub A again and carries the other reports into a new consolidated zip:'
        $Lines[1] | Should -Be ('  ./Run-AllSubscriptions.ps1 -TenantID {0} -Resume -{1}' -f $script:Tenant, $Name)
        ($Lines -join "`n") | Should -Not -Match 'ResumeFailedOnly'
    }

    It 'names one past the retry limit with the -Fresh command, with <Name>' -TestCases @(
        @{ Name = 'Obfuscate' }, @{ Name = 'SkipMetrics' }, @{ Name = 'SkipConsumption' }, @{ Name = 'IncludeDisabled' }
    ) {
        $Lines = @(Get-ConsumptionFailedAdvice -Entries @($script:Entry) -FailedAttempts @(& $script:Attempt 3) -TenantID $script:Tenant -Settings (script:New-Settings -On $Name))
        $Lines | Should -Contain ('  ./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh -{1}' -f $script:Tenant, $Name)
        ($Lines -join "`n") | Should -Not -Match '-Resume'
    }

    It 'gives the plain commands for a run with none of the settings' {
        $Lines = @(Get-ConsumptionFailedAdvice -Entries @($script:Entry) -FailedAttempts @(& $script:Attempt 1) -TenantID $script:Tenant -Settings (script:New-Settings))
        $Lines[1] | Should -Be ('  ./Run-AllSubscriptions.ps1 -TenantID {0} -Resume' -f $script:Tenant)
    }
}

Describe 'The commands of the retry-limit summary' {
    It 'every command carries <Name>' -TestCases @(
        @{ Name = 'Obfuscate' }, @{ Name = 'SkipMetrics' }, @{ Name = 'SkipConsumption' }, @{ Name = 'IncludeDisabled' }
    ) {
        $S = script:New-Settings -On $Name
        $Limited = @(
            [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A'; Attempts = 3; Reason = 'r' }
            [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B'; Attempts = 3; Reason = 'r' }
            [pscustomobject]@{ Id = 'sub-c'; Name = 'Sub C'; Attempts = 3; Reason = 'r' }
        )
        $Lines = script:Get-HostLines { Write-RetryLimitSummary -RetryLimited $Limited -TenantID $script:Tenant -NotListedIds @('sub-a') -NotReadableIds @('sub-b') -Settings $S }
        $Commands = @($Lines | Where-Object { $_ -match '^\s+\./Run-AllSubscriptions\.ps1 ' } | ForEach-Object { $_.Trim() })
        $Commands | Should -Be @(
            ('./Run-AllSubscriptions.ps1 -TenantID {0} -{1}' -f $script:Tenant, $Name)
            ('./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh -{1}' -f $script:Tenant, $Name)
            ('./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh -{1}' -f $script:Tenant, $Name)
        )
    }
}

Describe 'The -Fresh command under FAILED (report missing)' {
    It 'carries <Name> for a subscription whose missing report took it to the retry limit' -TestCases @(
        @{ Name = 'Obfuscate' }, @{ Name = 'SkipMetrics' }, @{ Name = 'SkipConsumption' }, @{ Name = 'IncludeDisabled' }
    ) {
        $Lines = script:Get-HostLines { Write-MissingReportBanner -MissingReports @([pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' }) -MissingReportCount 1 -RetryLimited @(& $script:Attempt 3) -TenantID $script:Tenant -Settings (script:New-Settings -On $Name) }
        $Lines | Should -Contain ('  ./Run-AllSubscriptions.ps1 -TenantID {0} -Fresh -{1}' -f $script:Tenant, $Name)
    }
}

Describe 'The commands under FAILED (earlier report not carried)' {
    It 'are the -Fresh run and the direct run, each with the run''s settings' {
        $Wrapper = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $At = $Wrapper.IndexOf('FAILED (earlier report not carried)')
        $At | Should -BeGreaterThan 0
        $Banner = $Wrapper.Substring($At, $Wrapper.IndexOf('=================================================================', $At + 40) - $At)
        $Banner | Should -Match ([regex]::Escape("Write-Host ('  ' + (Get-WrapperRunCommand -TenantID `$TenantID -Mode '-Fresh' -Settings `$RunDataSettings))"))
        $Banner | Should -Match ([regex]::Escape("Write-Host ('  ' + (Get-DirectRunRetryCommand -TenantID `$TenantID -SubscriptionID `$U.Id -Settings `$RunDataSettings))"))
        $Banner | Should -Not -Match ([regex]::Escape('./ResourceInventory.ps1 -TenantID {0}'))
    }
}
