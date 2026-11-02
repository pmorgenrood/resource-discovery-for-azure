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
        $Calls = [regex]::Matches($Inner, [regex]::Escape("'  ' + (Get-DirectRunRetryCommand -TenantID `$RetryTenant -SubscriptionID `$_.Id @RetryArgs)"))
        $Calls.Count | Should -Be 2
        $Inner | Should -Match ([regex]::Escape('$RetrySettings = [ordered]@{ Obfuscate = $Obfuscate.IsPresent; SkipMetrics = $SkipMetrics.IsPresent; SkipConsumption = $SkipConsumption.IsPresent; DeviceLogin = $DeviceLogin.IsPresent; UseManagedIdentity = $UseManagedIdentity.IsPresent }'))
        $Inner | Should -Match ([regex]::Escape('$RetryArgs = @{ ResourceGroup = $ResourceGroup; Settings = $RetrySettings; Appid = [string]$Appid; Service = $Service; OutputDirectory = [string]$OutputDirectory; ObfuscationDictionary = $ObfuscationDictionary }'))
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
        $Banner | Should -Match ([regex]::Escape("Write-Host ('  ' + (Get-WrapperRunCommand -TenantID `$TenantID -Mode '-Fresh' -Settings `$RetryCommandSettings))"))
        $Banner | Should -Match ([regex]::Escape("Write-Host ('  ' + (Get-DirectRunRetryCommand -TenantID `$TenantID -SubscriptionID `$U.Id -Settings `$RetryCommandSettings))"))
        $Banner | Should -Not -Match ([regex]::Escape('./ResourceInventory.ps1 -TenantID {0}'))
    }
}

Describe 'The sign-in and output switches a printed command carries' {
    It 'a wrapper command carries -DeviceLogin when the run used it, after the run settings, and not otherwise' {
        $On = Get-RetryCommandSettings -Settings (script:New-Settings -On 'SkipMetrics') -DeviceLogin $true
        Get-WrapperRunCommand -TenantID $script:Tenant -Mode '-Resume' -Settings $On | Should -Be ('./Run-AllSubscriptions.ps1 -TenantID {0} -Resume -SkipMetrics -DeviceLogin' -f $script:Tenant)
        $Off = Get-RetryCommandSettings -Settings (script:New-Settings -On 'SkipMetrics') -DeviceLogin $false
        Get-WrapperRunCommand -TenantID $script:Tenant -Mode '-Resume' -Settings $Off | Should -Be ('./Run-AllSubscriptions.ps1 -TenantID {0} -Resume -SkipMetrics' -f $script:Tenant)
    }

    It 'leaves the run settings as they are, so the settings a continuing run must keep do not change' {
        $Settings = script:New-Settings -On 'Obfuscate'
        $null = Get-RetryCommandSettings -Settings $Settings -DeviceLogin $true
        @($Settings.Keys) | Should -Be @(Get-RunDataSettingNames)
        Format-RunDataSettings -Settings $Settings | Should -Be '-Obfuscate'
    }

    It 'the wrapper''s direct-run command carries -DeviceLogin and leaves out -IncludeDisabled' {
        $S = Get-RetryCommandSettings -Settings (script:New-Settings -On 'IncludeDisabled', 'Obfuscate') -DeviceLogin $true
        Get-DirectRunRetryCommand -TenantID $script:Tenant -SubscriptionID 'sub-a' -Settings $S | Should -Be ('./ResourceInventory.ps1 -TenantID {0} -SubscriptionID sub-a -Obfuscate -DeviceLogin' -f $script:Tenant)
    }

    It 'a direct-run command carries <Name> when the run was given it' -TestCases @(
        @{ Name = 'DeviceLogin' }, @{ Name = 'UseManagedIdentity' }
    ) {
        $S = [ordered]@{ Obfuscate = $false; SkipMetrics = $false; SkipConsumption = $false; DeviceLogin = ($Name -eq 'DeviceLogin'); UseManagedIdentity = ($Name -eq 'UseManagedIdentity') }
        Get-DirectRunRetryCommand -SubscriptionID 'sub-a' -Settings $S | Should -Be ('./ResourceInventory.ps1 -SubscriptionID sub-a -{0}' -f $Name)
    }

    It 'a direct-run command carries -Appid, -Service, -OutputDirectory and -ObfuscationDictionary, quoted, a path with a space and a quote as one value' {
        $Command = Get-DirectRunRetryCommand -SubscriptionID 'sub-a' -ResourceGroup 'rg-a' -Appid 'app-a' -Service 'Compute', 'Network' -OutputDirectory "/tmp/out dir/it's here" -ObfuscationDictionary '/tmp/dict a.json' -Settings ([ordered]@{ SkipMetrics = $true })
        $Command | Should -Be "./ResourceInventory.ps1 -TenantID (Read-Host -Prompt 'Tenant ID') -SubscriptionID sub-a -ResourceGroup 'rg-a' -Appid 'app-a' -Secret (Read-Host -AsSecureString) -Service 'Compute','Network' -OutputDirectory '/tmp/out dir/it''s here' -ObfuscationDictionary '/tmp/dict a.json' -SkipMetrics"
        # PowerShell reads the printed command back as these values.
        $Ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$null, [ref]$null)
        $Elements = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))[0].CommandElements
        $Values = @{}
        for ($i = 1; $i -lt $Elements.Count; $i++)
        {
            # A prompt such as (Read-Host -AsSecureString) is run, not read, so it has no value here.
            if ($Elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $i + 1 -lt $Elements.Count -and $Elements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst] -and $Elements[$i + 1] -isnot [System.Management.Automation.Language.ParenExpressionAst])
            {
                $Values[$Elements[$i].ParameterName] = $Elements[$i + 1].SafeGetValue()
            }
        }
        $Values['OutputDirectory'] | Should -Be "/tmp/out dir/it's here"
        $Values['ObfuscationDictionary'] | Should -Be '/tmp/dict a.json'
        @($Values['Service']) | Should -Be @('Compute', 'Network')
        $Values['Appid'] | Should -Be 'app-a'
    }

    It 'a service principal command parses, asks for the secret when it runs and holds none, and carries the tenant' {
        $Command = Get-DirectRunRetryCommand -TenantID $script:Tenant -SubscriptionID 'sub-a' -Appid 'app-a' -Settings ([ordered]@{ SkipMetrics = $true })
        $Command | Should -Be ("./ResourceInventory.ps1 -TenantID {0} -SubscriptionID sub-a -Appid 'app-a' -Secret (Read-Host -AsSecureString) -SkipMetrics" -f $script:Tenant)
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$null, [ref]$Errors)
        @($Errors) | Should -BeNullOrEmpty
        $Elements = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))[0].CommandElements
        $Names = @($Elements | ForEach-Object { if ($_ -is [System.Management.Automation.Language.CommandParameterAst]) { $_.ParameterName } else { '' } })
        $At = [array]::IndexOf($Names, 'Secret')
        $At | Should -BeGreaterThan 0
        # The value of -Secret is the prompt itself, not a value.
        $Elements[$At + 1].Extent.Text | Should -BeExactly '(Read-Host -AsSecureString)'
        $Names | Should -Contain 'TenantID'
        # The tenant id is the only GUID-shaped text, so no secret or token rides along.
        @([regex]::Matches($Command, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value }) | Should -Be @($script:Tenant)
        # Without a known tenant the command asks for it too, and still parses.
        $NoTenant = Get-DirectRunRetryCommand -SubscriptionID 'sub-a' -Appid 'app-a'
        $NoTenant | Should -BeLike "./ResourceInventory.ps1 -TenantID (Read-Host -Prompt 'Tenant ID') -SubscriptionID sub-a -Appid 'app-a' -Secret (Read-Host -AsSecureString)"
        $Errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($NoTenant, [ref]$null, [ref]$Errors)
        @($Errors) | Should -BeNullOrEmpty
    }

    It 'a command without -Appid names no -Secret' {
        Get-DirectRunRetryCommand -TenantID $script:Tenant -SubscriptionID 'sub-a' -Settings ([ordered]@{ DeviceLogin = $true }) | Should -Not -Match 'Secret'
        Get-DirectRunRetryCommand -SubscriptionID 'sub-a' -Settings ([ordered]@{ UseManagedIdentity = $true }) | Should -Be './ResourceInventory.ps1 -SubscriptionID sub-a -UseManagedIdentity'
    }

    It 'a path with a <Label> single quote gives a command that parses and passes the path back unchanged' -ForEach @(
        @{ Label = 'typographic'; Quote = [string][char]0x2019 }
        @{ Label = 'plain'; Quote = "'" }
    ) {
        $Path = '/tmp/it{0}s here/out' -f $Quote
        $Command = Get-DirectRunRetryCommand -SubscriptionID 'sub-a' -OutputDirectory $Path
        $Errors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$null, [ref]$Errors)
        @($Errors) | Should -BeNullOrEmpty
        $Elements = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))[0].CommandElements
        $At = [array]::IndexOf(@($Elements | ForEach-Object { if ($_ -is [System.Management.Automation.Language.CommandParameterAst]) { $_.ParameterName } else { '' } }), 'OutputDirectory')
        $At | Should -BeGreaterThan 0
        $Elements[$At + 1].SafeGetValue() | Should -BeExactly $Path
    }

    It 'a value not given is left out' {
        Get-DirectRunRetryCommand -SubscriptionID 'sub-a' -Appid '' -Service @() -OutputDirectory '' -ObfuscationDictionary '' | Should -Be './ResourceInventory.ps1 -SubscriptionID sub-a'
    }

    It 'never prints a secret: the builder takes no secret, certificate or token, and the direct run passes none to it' {
        @((Get-Command Get-DirectRunRetryCommand).Parameters.Keys | Where-Object { $_ -match 'Secret|Cert|Token|Password|Key' }) | Should -BeNullOrEmpty
        $Inner = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ResourceInventory.ps1') -Raw
        $At = $Inner.IndexOf('$RetryArgs = @{')
        $At | Should -BeGreaterThan 0
        $Inner.Substring($At, $Inner.IndexOf("`n", $At) - $At) | Should -Not -Match 'Secret'
    }

    It 'the wrapper prints its commands with the run settings and -DeviceLogin, and checks a continuing run against the run settings only' {
        $Wrapper = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Wrapper | Should -Match ([regex]::Escape('$RetryCommandSettings = Get-RetryCommandSettings -Settings $RunDataSettings -DeviceLogin ([bool]$DeviceLogin)'))
        $Wrapper | Should -Match ([regex]::Escape('Resolve-RunStart -Info $StoredRun -Resume ([bool]$Resume) -ResumeFailedOnly ([bool]$ResumeFailedOnly) -Fresh ([bool]$Fresh) -Settings $RunDataSettings'))
        @([regex]::Matches($Wrapper, '(Get-WrapperRunCommand|Get-DirectRunRetryCommand|Get-ConsumptionFailedAdvice|Write-RetryLimitSummary|Write-MissingReportBanner) [^\r\n]*-Settings \$RunDataSettings')) | Should -BeNullOrEmpty
    }
}
