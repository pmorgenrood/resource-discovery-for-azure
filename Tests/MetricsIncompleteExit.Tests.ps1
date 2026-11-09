#Requires -Modules Pester
# Metrics incomplete because Azure Monitor kept failing (an entry in
# $Global:MetricsFailedSubs with Complete = $false) is told apart from metrics
# skipped for the sign-in (no Complete field): its own FAILED (metrics) lines,
# no FAILED (auth) for it, and exit 3 from the wrapper and from a direct run.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')

    function Get-ScriptAst
    {
        param([string]$File)
        [System.Management.Automation.Language.Parser]::ParseInput((Get-Content -LiteralPath (Join-Path $script:RepoRoot $File) -Raw), [ref]$null, [ref]$null)
    }

    $script:SignIn = [pscustomobject]@{ Name = 'sub-one'; Id = 'id-1'; Message = 'no usable Azure context' }
    $script:Incomplete = [pscustomobject]@{ Name = 'sub-two'; Id = 'id-2'; Message = 'still failed'; ReportFolder = 'ResourcesReport_x'; Complete = $false }
}

Describe 'Get-MetricsIncompleteEntries' {
    It 'keeps only the entries recorded as incomplete, once each' {
        $List = @(Get-MetricsIncompleteEntries -Entries @($script:SignIn, $script:Incomplete, $script:Incomplete))
        $List.Count | Should -Be 1
        $List[0].Id | Should -Be 'id-2'
    }

    It 'returns nothing for no entries' {
        @(Get-MetricsIncompleteEntries -Entries $null).Count | Should -Be 0
    }
}

Describe 'Write-MetricsIncompleteBanner' {
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
    }

    It 'prints nothing when no entry is incomplete' {
        Write-MetricsIncompleteBanner -Entries @($script:SignIn) -Advice @('run this')
        $script:Lines.Count | Should -Be 0
    }

    It 'names each incomplete subscription and the advice' {
        Write-MetricsIncompleteBanner -Entries @($script:SignIn, $script:Incomplete) -Advice @('To collect one again, run:', '  cmd')
        $script:Lines | Should -Contain '=================== FAILED (metrics) ==================='
        $script:Lines | Should -Contain 'Metrics are incomplete for 1 subscription(s): Azure Monitor requests still failed after their retries (throttling, a timeout, a server error or an error with no status):'
        $script:Lines | Should -Contain '  - sub-two (id-2)'
        $script:Lines | Should -Not -Contain '  - sub-one (id-1)'
        $script:Lines | Should -Contain '  cmd'
    }
}

Describe 'Get-MetricsRetryCommand' {
    It 'names the tenant and the subscription' {
        Get-MetricsRetryCommand -TenantID 'tenant-1' -SubscriptionId 'id-2' -RunParameters @{} | Should -Be './ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2'
    }

    It 'gives the run''s own command over every subscription when no subscription is given' {
        Get-MetricsRetryCommand -TenantID 'tenant-1' -SubscriptionId '' -RunParameters @{ ConcurrencyLimit = 6 } | Should -Be './ResourceInventory.ps1 -TenantID tenant-1 -ConcurrencyLimit 6'
    }

    It 'leaves out the tenant when the run had none' {
        Get-MetricsRetryCommand -TenantID '' -SubscriptionId 'id-2' -RunParameters $null | Should -Be './ResourceInventory.ps1 -SubscriptionID id-2'
    }

    It 'keeps the data switches of the run, so a masked run is collected again masked' {
        $Run = @{ Obfuscate = [switch]::Present; SkipConsumption = $true; DeviceLogin = [switch]::Present; ConcurrencyLimit = 12; ObfuscationDictionary = "/data/it's here.json" }
        Get-MetricsRetryCommand -TenantID 'tenant-1' -SubscriptionId 'id-2' -RunParameters $Run | Should -Be "./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -Obfuscate -SkipConsumption -DeviceLogin -ConcurrencyLimit 12 -ObfuscationDictionary '/data/it''s here.json'"
    }

    It 'keeps the lookback, resource group, services, report name and output folder the run set' {
        $Run = @{ MetricsLookbackDays = 14; ResourceGroup = 'rg-one'; Service = @('Compute', "It's"); ReportName = 'Report_A'; OutputDirectory = "/data/out's" }
        Get-MetricsRetryCommand -TenantID 'tenant-1' -SubscriptionId 'id-2' -RunParameters $Run | Should -Be "./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -MetricsLookbackDays 14 -ResourceGroup 'rg-one' -Service 'Compute','It''s' -ReportName 'Report_A' -OutputDirectory '/data/out''s'"
    }

    It 'writes the whole number of days the run used for a lookback of <Given>' -ForEach @(
        @{ Given = 7.5; Used = 8 }
        @{ Given = '7.5'; Used = 8 }
        @{ Given = 6.5; Used = 6 }
        @{ Given = ' 14 '; Used = 14 }
    ) {
        # Metrics.ps1 reads the lookback as [int], so the new run asks for the
        # same days.
        [int]$Given | Should -Be $Used
        Get-MetricsRetryCommand -TenantID 'tenant-1' -SubscriptionId 'id-2' -RunParameters @{ MetricsLookbackDays = $Given } | Should -Be ('./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -MetricsLookbackDays {0}' -f $Used)
    }

    It 'leaves out a lookback that is not a whole number and empty values' {
        $Run = @{ MetricsLookbackDays = '14; Remove-Item x'; ResourceGroup = ''; Service = @(); ReportName = $null }
        Get-MetricsRetryCommand -TenantID 'tenant-1' -SubscriptionId 'id-2' -RunParameters $Run | Should -Be './ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2'
    }

    It 'seeds a masked run from that run''s own dictionary, over the one it was seeded with' {
        $Run = @{ Obfuscate = $true; ObfuscationDictionary = '/data/seed.json' }
        Get-MetricsRetryCommand -TenantID 'tenant-1' -SubscriptionId 'id-2' -RunParameters $Run -DictionaryFile "/r/it's/ObfuscationDictionary_x.json" | Should -Be "./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -Obfuscate -ObfuscationDictionary '/r/it''s/ObfuscationDictionary_x.json'"
    }

    It 'gives no dictionary to a run that was not masked' {
        Get-MetricsRetryCommand -TenantID 'tenant-1' -SubscriptionId 'id-2' -RunParameters @{} -DictionaryFile '/r/ObfuscationDictionary_x.json' | Should -Be './ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2'
    }

    It 'never writes a credential or a switch that was turned off' {
        $Run = @{ Obfuscate = [switch]$false; DeviceLogin = $false; Appid = 'app-1'; Secret = (ConvertTo-SecureString 'not-a-real-value' -AsPlainText -Force); SkipMetrics = $true; Debug = $true; ObfuscationDictionary = '/data/d.json' }
        $Command = Get-MetricsRetryCommand -TenantID 'tenant-1' -SubscriptionId 'id-2' -RunParameters $Run
        $Command | Should -Be './ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2'
    }
}

Describe 'Write-MetricsIncompleteRunEnd after a masked run' {
    BeforeAll {
        # A report root with one subscription folder that holds its dictionary
        # and one that does not.
        $script:ReportRoot = Join-Path $TestDrive 'reports'
        $script:WithDict = Join-Path $script:ReportRoot 'ResourcesReport_with'
        New-Item -ItemType Directory -Path $script:WithDict, (Join-Path $script:ReportRoot 'ResourcesReport_without') -Force | Out-Null
        $script:DictFile = Join-Path $script:WithDict 'ObfuscationDictionary_ResourcesReport_with.json'
        Set-Content -LiteralPath $script:DictFile -Value '{}'
        $script:Replace = "  Each new zip replaces that subscription's zip in the upload: upload it instead of the first one, not as well, or its resources are counted twice."
        $script:WrapperReplace = "  Each new zip replaces that subscription's inner zip in the AllSubscriptions_ResourcesReport_*.zip: swap it in for the first one, do not add it next to it, or its resources are counted twice."
    }
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
    }

    It 'seeds each command from the dictionary in that subscription''s report folder' {
        $Entry = [pscustomobject]@{ Name = 'sub-two'; Id = 'id-2'; Message = 'still failed'; ReportFolder = 'ResourcesReport_with'; Complete = $false }
        Write-MetricsIncompleteRunEnd -Entries @($Entry) -TenantID 'tenant-1' -RunParameters @{ Obfuscate = $true } -ReportRoot $script:ReportRoot | Should -BeTrue

        $script:Lines | Should -Contain ("  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -Obfuscate -ObfuscationDictionary '{0}'" -f $script:DictFile.Replace("'", "''"))
        $script:Lines | Should -Contain $script:WrapperReplace
    }

    It 'says so when that subscription''s dictionary cannot be found' {
        $Entry = [pscustomobject]@{ Name = 'sub-three'; Id = 'id-3'; Message = 'still failed'; ReportFolder = 'ResourcesReport_without'; Complete = $false }
        $null = Write-MetricsIncompleteRunEnd -Entries @($Entry) -TenantID 'tenant-1' -RunParameters @{ Obfuscate = $true } -ReportRoot $script:ReportRoot

        $script:Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-3 -Obfuscate'
        $script:Lines | Should -Contain "  The dictionary of the first run was not found for sub-three (id-3): pass that run's ObfuscationDictionary_*.json as -ObfuscationDictionary, or the new zip gets new masked ids."
        $script:Lines | Should -Contain $script:WrapperReplace
    }

    It 'uses the dictionary file it is given for a direct run' {
        $null = Write-MetricsIncompleteRunEnd -Entries @($script:Incomplete) -TenantID 'tenant-1' -RunParameters @{ Obfuscate = $true; SubscriptionID = 'id-2' } -DictionaryFile $script:DictFile

        $script:Lines | Should -Contain ("  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -Obfuscate -ObfuscationDictionary '{0}'" -f $script:DictFile.Replace("'", "''"))
    }

    It 'adds no dictionary after a run that was not masked' {
        $null = Write-MetricsIncompleteRunEnd -Entries @($script:Incomplete) -TenantID 'tenant-1' -RunParameters @{} -DictionaryFile $script:DictFile -ReportRoot $script:ReportRoot

        $script:Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2'
        @($script:Lines | Where-Object { $_ -like '*dictionary*' }).Count | Should -Be 0
    }
}

Describe 'Write-MetricsIncompleteRunEnd: which command and which zip' {
    BeforeAll {
        $script:Dict = Join-Path $TestDrive 'ObfuscationDictionary_direct-all.json'
        Set-Content -LiteralPath $script:Dict -Value '{}'
        $script:Third = [pscustomobject]@{ Name = 'sub-three'; Id = 'id-3'; Message = 'still failed'; ReportFolder = 'ResourcesReport_x'; Complete = $false }
        $script:WholeZip = '  The new zip replaces the whole first zip in the upload: upload it instead of the first one, not as well, or every resource is counted twice.'
        $script:SubZip = "  Each new zip replaces that subscription's zip in the upload: upload it instead of the first one, not as well, or its resources are counted twice."
        $script:InnerZip = "  Each new zip replaces that subscription's inner zip in the AllSubscriptions_ResourcesReport_*.zip: swap it in for the first one, do not add it next to it, or its resources are counted twice."
        $script:FolderZip = "  Each new zip replaces that subscription's zip in its report folder (no AllSubscriptions_ResourcesReport_*.zip was made): put it there in place of the first one, do not keep both, or its resources are counted twice."
        $script:SignInLine = '  The first run signed in with -Appid: add -Appid <id> -Secret <secret> to sign in the same way.'
    }
    BeforeEach {
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add([string]$Object) }
    }

    It 'gives a direct run without -SubscriptionID its own command, once, and says the new zip replaces the whole first zip' {
        $Run = @{ ConcurrencyLimit = 9; Service = @('Compute'); MetricsLookbackDays = 7; OutputDirectory = '/data/out' }
        Write-MetricsIncompleteRunEnd -Entries @($script:Incomplete, $script:Third) -TenantID 'tenant-1' -RunParameters $Run | Should -BeTrue

        $script:Lines | Should -Contain '  - sub-two (id-2)'
        $script:Lines | Should -Contain '  - sub-three (id-3)'
        $script:Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -ConcurrencyLimit 9 -MetricsLookbackDays 7 -Service ''Compute'' -OutputDirectory ''/data/out'''
        @($script:Lines | Where-Object { $_ -like '*./ResourceInventory.ps1*' }).Count | Should -Be 1
        @($script:Lines | Where-Object { $_ -like '*-SubscriptionID*' }).Count | Should -Be 0
        $script:Lines | Should -Contain $script:WholeZip
        $script:Lines | Should -Not -Contain $script:SubZip
    }

    It 'seeds that command of a masked run from the dictionary it saved, or says it was not found' {
        $null = Write-MetricsIncompleteRunEnd -Entries @($script:Incomplete, $script:Third) -TenantID 'tenant-1' -RunParameters @{ Obfuscate = $true } -DictionaryFile $script:Dict
        $script:Lines | Should -Contain ("  ./ResourceInventory.ps1 -TenantID tenant-1 -Obfuscate -ObfuscationDictionary '{0}'" -f $script:Dict.Replace("'", "''"))
        $script:Lines | Should -Contain $script:WholeZip

        $script:Lines.Clear()
        $null = Write-MetricsIncompleteRunEnd -Entries @($script:Incomplete) -TenantID 'tenant-1' -RunParameters @{ Obfuscate = $true } -DictionaryFile (Join-Path $TestDrive 'gone.json')
        $script:Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -Obfuscate'
        $script:Lines | Should -Contain "  The dictionary of the first run was not found: pass that run's ObfuscationDictionary_*.json as -ObfuscationDictionary, or the new zip gets new masked ids."
    }

    It 'says the new zip replaces that subscription''s zip after a plain direct run with -SubscriptionID' {
        $null = Write-MetricsIncompleteRunEnd -Entries @($script:Incomplete) -TenantID 'tenant-1' -RunParameters @{ SubscriptionID = 'id-2' }

        $script:Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2'
        $script:Lines | Should -Contain $script:SubZip
    }

    It 'names the outer zip and its inner zip under the wrapper, after a plain run too' {
        $null = Write-MetricsIncompleteRunEnd -Entries @($script:Incomplete, $script:Third) -TenantID 'tenant-1' -RunParameters @{ ConcurrencyLimit = 6 } -ReportRoot (Join-Path $TestDrive 'no-reports')

        $script:Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -ConcurrencyLimit 6'
        $script:Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-3 -ConcurrencyLimit 6'
        $script:Lines | Should -Contain $script:InnerZip
        $script:Lines | Should -Not -Contain $script:SubZip
        $script:Lines | Should -Not -Contain $script:FolderZip
    }

    It 'says the new zip replaces that subscription''s zip in its report folder when the wrapper made no outer zip' {
        $null = Write-MetricsIncompleteRunEnd -Entries @($script:Incomplete) -TenantID 'tenant-1' -RunParameters @{ ConcurrencyLimit = 6 } -ReportRoot (Join-Path $TestDrive 'no-reports') -NoAllSubscriptionsZip

        $script:Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -ConcurrencyLimit 6'
        $script:Lines | Should -Contain $script:FolderZip
        $script:Lines | Should -Not -Contain $script:InnerZip
    }

    It 'says to add -Appid and -Secret, with neither value, after a run that signed in with them (<Kind>)' -ForEach @(
        @{ Kind = 'one command'; Run = @{} },
        @{ Kind = 'one command per subscription'; Run = @{ SubscriptionID = 'id-2' } }
    ) {
        $Secret = ConvertTo-SecureString 'not-a-real-value' -AsPlainText -Force
        $Given = @{ Appid = 'app-1'; Secret = $Secret } + $Run
        $null = Write-MetricsIncompleteRunEnd -Entries @($script:Incomplete) -TenantID 'tenant-1' -RunParameters $Given

        $script:Lines | Should -Contain $script:SignInLine
        @($script:Lines | Where-Object { $_ -like '*./ResourceInventory.ps1*' -and $_ -match 'Appid|Secret' }).Count | Should -Be 0
        ($script:Lines -join "`n") | Should -Not -Match 'app-1|not-a-real-value'
    }

    It 'adds no sign-in line after a run that did not sign in with -Appid' {
        $null = Write-MetricsIncompleteRunEnd -Entries @($script:Incomplete) -TenantID 'tenant-1' -RunParameters @{ SubscriptionID = 'id-2' }
        $script:Lines | Should -Not -Contain $script:SignInLine
    }
}

Describe 'A direct ResourceInventory.ps1 run with incomplete metrics' {
    BeforeAll {
        # The run's own param block and its last statement (the end of a direct
        # run), as written, with Common.Functions.ps1 loaded: the rest of the run
        # needs Azure.
        $Ast = Get-ScriptAst -File 'ResourceInventory.ps1'
        $End = @($Ast.EndBlock.Statements)[-1]
        $script:DirectRun = Join-Path $TestDrive 'direct-run-end.ps1'
        Set-Content -LiteralPath $script:DirectRun -Encoding utf8 -Value (@(
                $Ast.ParamBlock.Extent.Text
                ". '{0}'" -f ((Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1') -replace "'", "''")
                $End.Extent.Text
            ) -join "`n")

        function script:Invoke-DirectRunEnd
        {
            param([hashtable]$Arguments, [switch]$NoZip, [string]$DictionaryFile)
            # The dictionary a masked run saves, set as the run sets it.
            $Global:DictionaryFile = $DictionaryFile
            # The report zip of the run, or none when it could not be written.
            $Global:ZipOutputFile = Join-Path $TestDrive ('ResourcesReport_{0}.zip' -f [guid]::NewGuid())
            if (-not $NoZip) { Set-Content -LiteralPath $Global:ZipOutputFile -Value 'zip' }
            # Whether the run wrote its zip, as Write-RdaReportZip returns it;
            # read by the run's last statement.
            Set-Variable -Name ZipWritten -Value (-not $NoZip)
            $global:LASTEXITCODE = 0
            $Lines = @(& $script:DirectRun @Arguments 6>&1 | ForEach-Object { [string]$_ })
            [pscustomobject]@{ ExitCode = $global:LASTEXITCODE; Lines = $Lines }
        }

        $script:SessionMetrics = Get-Variable -Name MetricsFailedSubs -Scope Global -ErrorAction SilentlyContinue
        $script:SessionZip = Get-Variable -Name ZipOutputFile -Scope Global -ErrorAction SilentlyContinue
        $script:SessionDict = Get-Variable -Name DictionaryFile -Scope Global -ErrorAction SilentlyContinue
    }
    AfterAll {
        if ($script:SessionMetrics) { $Global:MetricsFailedSubs = $script:SessionMetrics.Value }
        else { Remove-Variable -Name MetricsFailedSubs -Scope Global -ErrorAction SilentlyContinue }
        if ($script:SessionZip) { $Global:ZipOutputFile = $script:SessionZip.Value }
        else { Remove-Variable -Name ZipOutputFile -Scope Global -ErrorAction SilentlyContinue }
        if ($script:SessionDict) { $Global:DictionaryFile = $script:SessionDict.Value }
        else { Remove-Variable -Name DictionaryFile -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'seeds the command of a masked run from the dictionary it saved' {
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Dict = Join-Path $TestDrive 'ObfuscationDictionary_direct.json'
        Set-Content -LiteralPath $Dict -Value '{}'
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1'; Obfuscate = $true; ObfuscationDictionary = '/data/seed.json' } -DictionaryFile $Dict

        $Result.ExitCode | Should -Be 3
        $Result.Lines | Should -Contain ("  ./ResourceInventory.ps1 -TenantID tenant-1 -Obfuscate -ObfuscationDictionary '{0}'" -f $Dict.Replace("'", "''"))
        $Result.Lines | Should -Contain '  The new zip replaces the whole first zip in the upload: upload it instead of the first one, not as well, or every resource is counted twice.'
    }

    It 'prints the command for its one subscription when it ran with -SubscriptionID' {
        $Sub = '00000000-0000-0000-0000-0000000000a2'
        $Global:MetricsFailedSubs = @([pscustomobject]@{ Name = 'sub-two'; Id = $Sub; Message = 'still failed'; ReportFolder = 'ResourcesReport_x'; Complete = $false })
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1'; SubscriptionID = $Sub; ConcurrencyLimit = 9 }

        $Result.ExitCode | Should -Be 3
        $Result.Lines | Should -Contain ('  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID {0} -ConcurrencyLimit 9' -f $Sub)
        $Result.Lines | Should -Contain "  Each new zip replaces that subscription's zip in the upload: upload it instead of the first one, not as well, or its resources are counted twice."
    }

    It 'prints the command with the run''s switches and exits 3' {
        $Global:MetricsFailedSubs = @($script:SignIn, $script:Incomplete)
        $Secret = ConvertTo-SecureString 'not-a-real-value' -AsPlainText -Force
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1'; Obfuscate = $true; ConcurrencyLimit = 9; ObfuscationDictionary = '/data/d.json'; Appid = 'app-1'; Secret = $Secret }

        $Result.ExitCode | Should -Be 3
        $Result.Lines | Should -Contain '=================== FAILED (metrics) ==================='
        $Result.Lines | Should -Contain "  ./ResourceInventory.ps1 -TenantID tenant-1 -Obfuscate -ConcurrencyLimit 9 -ObfuscationDictionary '/data/d.json'"
        # It says how to sign in the same way, with neither value.
        $Result.Lines | Should -Contain '  The first run signed in with -Appid: add -Appid <id> -Secret <secret> to sign in the same way.'
        ($Result.Lines -join "`n") | Should -Not -Match 'not-a-real-value|app-1'
        @($Result.Lines | Where-Object { $_ -like '*./ResourceInventory.ps1*' -and $_ -match 'Appid|Secret' }).Count | Should -Be 0
        @($Result.Lines | Where-Object { $_ -match 'Secret' -and $_ -ne '  The first run signed in with -Appid: add -Appid <id> -Secret <secret> to sign in the same way.' }).Count | Should -Be 0
    }

    It 'prints the command with the run''s lookback, resource group, services, report name and output folder' {
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1'; MetricsLookbackDays = 7; ResourceGroup = 'rg-one'; Service = @('Compute', 'Network'); ReportName = 'Report_A'; OutputDirectory = '/data/out' }

        $Result.ExitCode | Should -Be 3
        $Result.Lines | Should -Contain "  ./ResourceInventory.ps1 -TenantID tenant-1 -MetricsLookbackDays 7 -ResourceGroup 'rg-one' -Service 'Compute','Network' -ReportName 'Report_A' -OutputDirectory '/data/out'"
    }

    It 'still prints the command but exits 2, not 3, when its zip could not be written' {
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1' } -NoZip

        $Result.ExitCode | Should -Be 2
        $Result.Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1'
    }

    It 'exits 2 when its zip could not be written and the metrics are complete' {
        $Global:MetricsFailedSubs = @()
        (Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1' } -NoZip).ExitCode | Should -Be 2
    }

    It 'exits 0 and prints nothing when the metrics are complete' {
        $Global:MetricsFailedSubs = @()
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1' }

        $Result.ExitCode | Should -Be 0
        $Result.Lines | Should -Not -Contain '=================== FAILED (metrics) ==================='
        $Result.Lines | Should -Not -Contain '===================== FAILED (auth) ====================='
    }

    It 'prints a FAILED (auth) line and exits 3 when its metrics were skipped for the sign-in' {
        $Global:MetricsFailedSubs = @($script:SignIn)
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1' }

        $Result.ExitCode | Should -Be 3
        $Result.Lines | Should -Contain '===================== FAILED (auth) ====================='
        $Result.Lines | Should -Contain 'Could not collect: Metrics for 1 subscription(s). Reason: no usable Azure context/token (even after one reconnect attempt).'
        $Result.Lines | Should -Not -Contain '=================== FAILED (metrics) ==================='
    }

    It 'still exits 2 when its metrics were skipped for the sign-in and its zip could not be written' {
        $Global:MetricsFailedSubs = @($script:SignIn)
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1' } -NoZip

        $Result.ExitCode | Should -Be 2
        $Result.Lines | Should -Contain '===================== FAILED (auth) ====================='
    }

    It 'leaves the end of the run to the wrapper under -RunAllSubs' {
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1'; RunAllSubs = $true }

        $Result.ExitCode | Should -Be 0
        $Result.Lines.Count | Should -Be 0
    }
}

Describe 'The report zip at the end of a ResourceInventory.ps1 run' {
    BeforeAll {
        # The run's param block and its top-level statements from the one that
        # makes the zip to the end, as written, with both function files loaded.
        # A stand-in Compress-Archive writes a partial zip and fails when asked.
        $Ast = Get-ScriptAst -File 'ResourceInventory.ps1'
        $Top = @($Ast.EndBlock.Statements)
        $From = @(0..($Top.Count - 1) | Where-Object { $Top[$_].Extent.Text -match 'Compress-Archive|Write-RdaReportZip' })[0]
        $script:ZipEnd = Join-Path $TestDrive 'zip-end.ps1'
        Set-Content -LiteralPath $script:ZipEnd -Encoding utf8 -Value (@(
                $Ast.ParamBlock.Extent.Text
                ". '{0}'" -f ((Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1') -replace "'", "''")
                ". '{0}'" -f ((Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1') -replace "'", "''")
                'function Compress-Archive { [CmdletBinding()] param($Path, $CompressionLevel, $DestinationPath) Set-Content -LiteralPath $DestinationPath -Value ''part''; if ($env:RDA_TEST_ZIP_FAIL) { throw ''The disk is full.'' } }'
                # A stand-in Remove-Item that fails as the real one does (an
                # error, not a throw) when asked.
                'function Remove-Item { [CmdletBinding()] param([string]$LiteralPath, [string]$Path, [switch]$Force) if ($env:RDA_TEST_REMOVE_FAIL) { Write-Error ''Access to the path is denied.'' } else { Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters } }'
                '$CompressionOutput = @{ Path = @(''x''); CompressionLevel = ''Fastest''; DestinationPath = $Global:ZipOutputFile }'
                '$Runtime = ''0:01''; $ReportingRunTime = ''0:01'''
                @($Top[$From..($Top.Count - 1)] | ForEach-Object { $_.Extent.Text })
            ) -join "`n")

        function script:Invoke-ZipEnd
        {
            param([hashtable]$Arguments, [switch]$Fail, [switch]$RemoveFails)
            $Global:ZipOutputFile = Join-Path $TestDrive ('ResourcesReport_{0}.zip' -f [guid]::NewGuid())
            $env:RDA_TEST_ZIP_FAIL = $(if ($Fail) { '1' } else { '' })
            $env:RDA_TEST_REMOVE_FAIL = $(if ($RemoveFails) { '1' } else { '' })
            try
            {
                $global:LASTEXITCODE = 0
                $Lines = @(& $script:ZipEnd @Arguments *>&1 | ForEach-Object { [string]$_ })
                [pscustomobject]@{ ExitCode = $global:LASTEXITCODE; Lines = $Lines; ZipLeft = (Test-Path -LiteralPath $Global:ZipOutputFile) }
            }
            finally
            {
                Remove-Item -Path 'Env:RDA_TEST_ZIP_FAIL' -ErrorAction SilentlyContinue
                Remove-Item -Path 'Env:RDA_TEST_REMOVE_FAIL' -ErrorAction SilentlyContinue
            }
        }

        $script:SessionMetrics = Get-Variable -Name MetricsFailedSubs -Scope Global -ErrorAction SilentlyContinue
        $script:SessionZip = Get-Variable -Name ZipOutputFile -Scope Global -ErrorAction SilentlyContinue
        $script:SessionUnwritten = Get-Variable -Name RdaUnwrittenReportZips -Scope Global -ErrorAction SilentlyContinue
    }
    AfterAll {
        if ($script:SessionMetrics) { $Global:MetricsFailedSubs = $script:SessionMetrics.Value }
        else { Remove-Variable -Name MetricsFailedSubs -Scope Global -ErrorAction SilentlyContinue }
        if ($script:SessionZip) { $Global:ZipOutputFile = $script:SessionZip.Value }
        else { Remove-Variable -Name ZipOutputFile -Scope Global -ErrorAction SilentlyContinue }
        if ($script:SessionUnwritten) { $Global:RdaUnwrittenReportZips = $script:SessionUnwritten.Value }
        else { Remove-Variable -Name RdaUnwrittenReportZips -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'names the zip and exits 0 when it was written' {
        $Global:MetricsFailedSubs = @()
        $Result = Invoke-ZipEnd -Arguments @{ TenantID = 'tenant-1' }

        $Result.ExitCode | Should -Be 0
        $Result.ZipLeft | Should -BeTrue
        @($Result.Lines | Where-Object { $_ -like '*Reporting Data File:*' }).Count | Should -Be 1
        @($Result.Lines | Where-Object { $_ -like '*No report was written*' }).Count | Should -Be 0
    }

    It 'removes a partial zip, says no report was written and exits 2 when the zip fails' {
        $Global:MetricsFailedSubs = @()
        $Result = Invoke-ZipEnd -Arguments @{ TenantID = 'tenant-1' } -Fail

        $Result.ExitCode | Should -Be 2
        $Result.ZipLeft | Should -BeFalse
        @($Result.Lines | Where-Object { $_ -like '*Reporting Data File:*' }).Count | Should -Be 0
        @($Result.Lines | Where-Object { $_ -like '*No report was written*' }).Count | Should -Be 1
    }

    It 'exits 2, not 3, when the zip fails and the metrics are incomplete' {
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Result = Invoke-ZipEnd -Arguments @{ TenantID = 'tenant-1' } -Fail

        $Result.ExitCode | Should -Be 2
        $Result.Lines | Should -Contain '=================== FAILED (metrics) ==================='
    }

    It 'removes a partial zip under -RunAllSubs and exits 2, so the wrapper counts that subscription as failed' {
        $Global:MetricsFailedSubs = @()
        $Global:RdaUnwrittenReportZips = @()
        $Result = Invoke-ZipEnd -Arguments @{ TenantID = 'tenant-1'; RunAllSubs = $true } -Fail

        $Result.ExitCode | Should -Be 2
        $Result.ZipLeft | Should -BeFalse
        @($Result.Lines | Where-Object { $_ -like '*Reporting Data File:*' }).Count | Should -Be 0
        @($Result.Lines | Where-Object { $_ -like '*No report was written*' }).Count | Should -Be 1
        $Global:RdaUnwrittenReportZips | Should -Be @($Global:ZipOutputFile)
    }

    It 'exits 2 and names the partial zip when the zip fails and the partial zip cannot be removed' {
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Result = Invoke-ZipEnd -Arguments @{ TenantID = 'tenant-1' } -Fail -RemoveFails

        $Result.ExitCode | Should -Be 2
        $Result.ZipLeft | Should -BeTrue
        @($Result.Lines | Where-Object { $_ -like '*Reporting Data File:*' }).Count | Should -Be 0
        @($Result.Lines | Where-Object { $_ -like '*No report was written*' }).Count | Should -Be 1
        @($Result.Lines | Where-Object { $_ -like ('*The partial zip could not be removed: {0}.*' -f $Global:ZipOutputFile) }).Count | Should -Be 1
    }

    It 'exits 2 under -RunAllSubs and adds the zip for the wrapper when the partial zip cannot be removed' {
        $Global:MetricsFailedSubs = @()
        $Global:RdaUnwrittenReportZips = @('/earlier/ResourcesReport_a.zip')
        $Result = Invoke-ZipEnd -Arguments @{ TenantID = 'tenant-1'; RunAllSubs = $true } -Fail -RemoveFails

        $Result.ExitCode | Should -Be 2
        $Result.ZipLeft | Should -BeTrue
        $Global:RdaUnwrittenReportZips | Should -Be @('/earlier/ResourcesReport_a.zip', $Global:ZipOutputFile)
    }
}

Describe 'A ResourceInventory.ps1 run whose metrics output was not written' {
    BeforeAll {
        # The run's param block and its top-level statements from the one that
        # writes the empty Metrics file to the end, as written, with both
        # function files loaded and the real Compress-Archive. A stand-in
        # Out-File fails for a Metrics file when asked, as a full disk does.
        $Ast = Get-ScriptAst -File 'ResourceInventory.ps1'
        $Top = @($Ast.EndBlock.Statements)
        $From = @(0..($Top.Count - 1) | Where-Object { $Top[$_].Extent.Text -match '^if \(\$SkipMetrics\.IsPresent\)' })[-1]
        $script:MetricsEnd = Join-Path $TestDrive 'metrics-end.ps1'
        Set-Content -LiteralPath $script:MetricsEnd -Encoding utf8 -Value (@(
                $Ast.ParamBlock.Extent.Text
                ". '{0}'" -f ((Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1') -replace "'", "''")
                ". '{0}'" -f ((Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1') -replace "'", "''")
                'function Out-File { [CmdletBinding()] param([Parameter(Position = 0)][string]$FilePath, [string]$Encoding, [switch]$Append, [Parameter(ValueFromPipeline = $true)]$InputObject) begin { $Items = [System.Collections.Generic.List[object]]::new() } process { $Items.Add($InputObject) } end { if ($env:RDA_TEST_METRICS_WRITE_FAIL -and (Split-Path -Path $FilePath -Leaf) -like ''Metrics_*'') { Write-Error ''There is not enough space on the disk.'' } else { $Items | Microsoft.PowerShell.Utility\Out-File -FilePath $FilePath -Encoding utf8 -Append:$Append } } }'
                '$Runtime = ''0:01''; $ReportingRunTime = ''0:01'''
                @($Top[$From..($Top.Count - 1)] | ForEach-Object { $_.Extent.Text })
            ) -join "`n")

        # Writes the other files of a run, sets the names the run sets, runs
        # the lifted statements and returns the exit code, the lines and the zip.
        function script:Invoke-MetricsEnd
        {
            param([hashtable]$Arguments, [switch]$WriteFails, [string]$MetricsContent)
            $Stamp = '20261109130000000' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
            $Folder = Join-Path $TestDrive ('run-' + $Stamp)
            New-Item -ItemType Directory -Path $Folder -Force | Out-Null
            $Global:DefaultPath = $Folder.TrimEnd('/') + '/'
            $Global:ReportName = 'ResourcesReport'
            $Global:CurrentDateTime = $Stamp
            $Global:HtmlFile = $Global:DefaultPath + 'ResourcesReport_' + $Stamp + '.html'
            $Global:ConsumptionFileCsv = $Global:DefaultPath + 'Consumption_ResourcesReport_' + $Stamp + '.csv'
            $Global:ZipOutputFile = $Global:DefaultPath + 'ResourcesReport_' + $Stamp + '.zip'
            $Global:MetricsJsonFile = $Global:DefaultPath + 'Metrics_ResourcesReport_' + $Stamp + '.json'
            $Global:MetricsFailedSubs = @()
            Set-Content -LiteralPath $Global:HtmlFile -Value 'html'
            Set-Content -LiteralPath $Global:ConsumptionFileCsv -Value 'InstanceData,MeterCategory'
            Set-Content -LiteralPath ($Global:DefaultPath + 'Inventory_ResourcesReport_' + $Stamp + '.json') -Value '{}'
            if ($PSBoundParameters.ContainsKey('MetricsContent')) { Set-Content -LiteralPath ($Global:DefaultPath + 'Metrics_ResourcesReport_' + $Stamp + '_1.json') -Value $MetricsContent }
            $env:RDA_TEST_METRICS_WRITE_FAIL = $(if ($WriteFails) { '1' } else { '' })
            try
            {
                $global:LASTEXITCODE = 0
                $Lines = @(& $script:MetricsEnd @Arguments *>&1 | ForEach-Object { [string]$_ })
                $Entries = @()
                if (Test-Path -LiteralPath $Global:ZipOutputFile)
                {
                    $Zip = [System.IO.Compression.ZipFile]::OpenRead($Global:ZipOutputFile)
                    try { $Entries = @($Zip.Entries | ForEach-Object { $_.FullName }) } finally { $Zip.Dispose() }
                }
                [pscustomobject]@{ ExitCode = $global:LASTEXITCODE; Lines = $Lines; ZipLeft = (Test-Path -LiteralPath $Global:ZipOutputFile); Entries = $Entries }
            }
            finally
            {
                Remove-Item -Path 'Env:RDA_TEST_METRICS_WRITE_FAIL' -ErrorAction SilentlyContinue
            }
        }

        $script:SessionValues = @{}
        foreach ($Name in @('DefaultPath', 'ReportName', 'CurrentDateTime', 'HtmlFile', 'ConsumptionFileCsv', 'ZipOutputFile', 'MetricsJsonFile', 'MetricsFailedSubs', 'RdaUnwrittenReportZips'))
        {
            $script:SessionValues[$Name] = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
        }
    }
    AfterAll {
        foreach ($Name in $script:SessionValues.Keys)
        {
            if ($script:SessionValues[$Name]) { Set-Variable -Name $Name -Scope Global -Value $script:SessionValues[$Name].Value }
            else { Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue }
        }
    }

    It 'makes no zip and exits 2 when the Metrics file could not be written and the other files are fine' {
        $Result = Invoke-MetricsEnd -Arguments @{ TenantID = 'tenant-1' } -WriteFails

        $Result.ExitCode | Should -Be 2
        $Result.ZipLeft | Should -BeFalse
        @($Result.Lines | Where-Object { $_ -like '*No report was written: the metrics output was not written*' }).Count | Should -Be 1
        @($Result.Lines | Where-Object { $_ -like '*Reporting Data File:*' }).Count | Should -Be 0
    }

    It 'exits 2 under -RunAllSubs and adds the zip for the wrapper, so that subscription counts as failed' {
        $Global:RdaUnwrittenReportZips = @()
        $Result = Invoke-MetricsEnd -Arguments @{ TenantID = 'tenant-1'; RunAllSubs = $true } -WriteFails

        $Result.ExitCode | Should -Be 2
        $Result.ZipLeft | Should -BeFalse
        $Global:RdaUnwrittenReportZips | Should -Be @($Global:ZipOutputFile)
    }

    It 'makes no zip and exits 2 when the only Metrics file of the run cannot be read (<Kind>)' -ForEach @(
        @{ Kind = 'cut short'; Content = '{"Metrics":[{"ID":"a"' }
        @{ Kind = 'no Metrics list'; Content = '{"Other":[]}' }
        @{ Kind = 'a list, not an object'; Content = '[]' }
    ) {
        $Result = Invoke-MetricsEnd -Arguments @{ TenantID = 'tenant-1' } -MetricsContent $Content

        $Result.ExitCode | Should -Be 2
        $Result.ZipLeft | Should -BeFalse
    }

    It 'zips the empty Metrics file and exits 0 when the run collected no metrics' {
        $Result = Invoke-MetricsEnd -Arguments @{ TenantID = 'tenant-1' }

        $Result.ExitCode | Should -Be 0
        @($Result.Entries | Where-Object { $_ -eq (Split-Path -Path $Global:MetricsJsonFile -Leaf) }).Count | Should -Be 1
    }

    It 'zips the run''s Metrics file and exits 0 when it holds metrics' {
        $Result = Invoke-MetricsEnd -Arguments @{ TenantID = 'tenant-1' } -MetricsContent '{"Metrics":[{"ID":"a","MetricSeries":[1]}]}'

        $Result.ExitCode | Should -Be 0
        @($Result.Entries | Where-Object { $_ -like 'Metrics_*_1.json' }).Count | Should -Be 1
    }

    It 'still makes the zip and exits 0 after -SkipMetrics' {
        $Result = Invoke-MetricsEnd -Arguments @{ TenantID = 'tenant-1'; SkipMetrics = $true } -WriteFails

        $Result.ExitCode | Should -Be 0
        $Result.ZipLeft | Should -BeTrue
    }
}

Describe 'The wrapper''s next ResourceInventory.ps1 run after one that exited 2' {
    BeforeAll {
        # Each block that runs ResourceInventory.ps1 for one subscription, from
        # its first statement to the exit code check, as written. A stand-in
        # ResourceInventory.ps1 in the same folder ends without calling exit,
        # as a run whose zip was written does.
        function script:Get-InventoryCallBlocks
        {
            param([string]$File)
            $Ast = Get-ScriptAst -File $File
            $Calls = @($Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] -and $Node.InvocationOperator -eq 'Ampersand' -and $Node.Extent.Text -match 'ResourceInventory\.ps1' }, $true))
            foreach ($Call in $Calls)
            {
                $Block = $Call.Parent.Parent
                $Statements = @($Block.Statements)
                $Check = @(0..($Statements.Count - 1) | Where-Object { $Statements[$_].Extent.Text -match '^if \(\$null -ne \$LASTEXITCODE' })[0]
                [pscustomobject]@{ File = $File; Line = $Call.Extent.StartLineNumber; Text = (@($Statements[0..$Check] | ForEach-Object { $_.Extent.Text }) -join "`n") }
            }
        }
        $script:CallBlocks = @(
            Get-InventoryCallBlocks -File 'Run-AllSubscriptions.ps1'
            Get-InventoryCallBlocks -File 'Run-AllSubscriptions.Stream.ps1'
        )
        $script:CallFolder = Join-Path $TestDrive 'inventory-call'
        New-Item -ItemType Directory -Path $script:CallFolder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:CallFolder 'ResourceInventory.ps1') -Value '$null = $args'
        $script:SessionExit = $global:LASTEXITCODE
    }
    AfterAll {
        $global:LASTEXITCODE = $script:SessionExit
    }

    It 'finds the three blocks that run ResourceInventory.ps1' {
        $script:CallBlocks.Count | Should -Be 3
    }

    It 'does not read the earlier run''s exit code 2 as a failure of the next run (block <Index>)' -ForEach @(
        @{ Index = 0 }, @{ Index = 1 }, @{ Index = 2 }
    ) {
        $Block = $script:CallBlocks[$Index]
        $Lifted = Join-Path $script:CallFolder ('block-{0}.ps1' -f $Index)
        Set-Content -LiteralPath $Lifted -Encoding utf8 -Value (@(
                '$ScriptRoot = $PSScriptRoot; $InventoryPassthrough = @{}; $TenantID = ''tenant-1''; $SubId = ''id-1''; $Sub = [pscustomobject]@{ Id = ''id-1''; Name = ''sub-one'' }'
                'try {'
                $Block.Text
                '''ok'' } catch { ''failed: '' + $_.Exception.Message }'
            ) -join "`n")

        $global:LASTEXITCODE = 2
        & $Lifted | Should -Be 'ok' -Because ('{0} line {1}' -f $Block.File, $Block.Line)
    }
}

Describe 'The files a ResourceInventory.ps1 run puts in its zip' {
    BeforeAll {
        # The run's param block and its top-level statements from the one that
        # picks the zip's files up to the one that writes the zip, as written,
        # with both function files loaded and the real Compress-Archive.
        $Ast = Get-ScriptAst -File 'ResourceInventory.ps1'
        $Top = @($Ast.EndBlock.Statements)
        $From = @(0..($Top.Count - 1) | Where-Object { $Top[$_].Extent.Text -match '^\$JsonWildCard =|^\$JsonFiles = Get-RdaReportJsonFiles|Write-RdaShareableDiagnosticsLog' })[0]
        $To = @(0..($Top.Count - 1) | Where-Object { $Top[$_].Extent.Text -match '^\$ZipWritten = ' -and $Top[$_].Extent.Text -match 'Write-RdaReportZip' })[0]
        $script:ZipFiles = Join-Path $TestDrive 'zip-files.ps1'
        Set-Content -LiteralPath $script:ZipFiles -Encoding utf8 -Value (@(
                $Ast.ParamBlock.Extent.Text
                ". '{0}'" -f ((Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1') -replace "'", "''")
                ". '{0}'" -f ((Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1') -replace "'", "''")
                @($Top[$From..$To] | ForEach-Object { $_.Extent.Text })
            ) -join "`n")

        # Writes the files a run leaves in its report folder, sets the names
        # the run sets, runs the lifted statements and returns the zip's entries.
        function script:Invoke-ZipFiles
        {
            param([string]$Folder, [string]$Stamp, [switch]$Obfuscate)
            New-Item -ItemType Directory -Path $Folder -Force | Out-Null
            $Global:DefaultPath = $Folder.TrimEnd('/') + '/'
            $Global:ReportName = 'ResourcesReport'
            $Global:CurrentDateTime = $Stamp
            $Global:HtmlFile = $Global:DefaultPath + 'ResourcesReport_' + $Stamp + '.html'
            $Global:ConsumptionFileCsv = $Global:DefaultPath + 'Consumption_ResourcesReport_' + $Stamp + '.csv'
            $Global:ZipOutputFile = $Global:DefaultPath + 'ResourcesReport_' + $Stamp + '.zip'
            $Global:MetricsFailedSubs = @()
            foreach ($Name in @(
                    ('ResourcesReport_{0}.html' -f $Stamp)
                    ('Consumption_ResourcesReport_{0}.csv' -f $Stamp)
                    ('Inventory_ResourcesReport_{0}.json' -f $Stamp)
                    ('Metrics_ResourcesReport_{0}_1.json' -f $Stamp)
                    ('Metrics_ResourcesReport_{0}_2.json' -f $Stamp)
                    ('Transcript_Log_ResourcesReport_{0}.txt' -f $Stamp)))
            {
                # A Metrics file holds a Metrics list, as the run writes it.
                $Content = if ($Name -like 'Metrics_*') { '{"Metrics":[]}' } else { $Name }
                Set-Content -LiteralPath ($Global:DefaultPath + $Name) -Value $Content
            }
            if ($Obfuscate) { Set-Content -LiteralPath ($Global:DefaultPath + ('ObfuscationDictionary_ResourcesReport_{0}.json' -f $Stamp)) -Value '{}' }
            $Arguments = @{ TenantID = 'tenant-1' }
            if ($Obfuscate) { $Arguments['Obfuscate'] = $true }
            $null = & $script:ZipFiles @Arguments *>&1
            $Zip = [System.IO.Compression.ZipFile]::OpenRead($Global:ZipOutputFile)
            try { return @($Zip.Entries | ForEach-Object { $_.FullName } | Sort-Object) }
            finally { $Zip.Dispose() }
        }

        # What a clean run's zip holds.
        function script:Get-CleanZipEntries
        {
            param([string]$Stamp)
            @(
                ('Consumption_ResourcesReport_{0}.csv' -f $Stamp)
                ('Diagnostics_ResourcesReport_{0}.log' -f $Stamp)
                ('Inventory_ResourcesReport_{0}.json' -f $Stamp)
                ('Metrics_ResourcesReport_{0}_1.json' -f $Stamp)
                ('Metrics_ResourcesReport_{0}_2.json' -f $Stamp)
                ('ResourcesReport_{0}.html' -f $Stamp)
            ) | Sort-Object
        }

        # The files an earlier run, or someone else, left in a shared folder.
        function script:Add-OtherRunFiles
        {
            param([string]$Folder)
            New-Item -ItemType Directory -Path $Folder -Force | Out-Null
            foreach ($Name in @('Inventory_ResourcesReport_20260101000000000aaaa.json', 'Metrics_ResourcesReport_20260101000000000aaaa_1.json', 'ObfuscationDictionary_ResourcesReport_20260101000000000aaaa.json', 'notes.json'))
            {
                Set-Content -LiteralPath (Join-Path $Folder $Name) -Value $Name
            }
        }

        $script:SessionValues = @{}
        foreach ($Name in @('DefaultPath', 'ReportName', 'CurrentDateTime', 'HtmlFile', 'ConsumptionFileCsv', 'ZipOutputFile', 'MetricsFailedSubs'))
        {
            $script:SessionValues[$Name] = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
        }
    }
    AfterAll {
        foreach ($Name in $script:SessionValues.Keys)
        {
            if ($script:SessionValues[$Name]) { Set-Variable -Name $Name -Scope Global -Value $script:SessionValues[$Name].Value }
            else { Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue }
        }
    }

    It 'holds the same files as before for a clean folder (<Mode>)' -ForEach @(@{ Mode = 'plain' }, @{ Mode = 'masked' }) {
        $Stamp = '20261109120000000' + $(if ($Mode -eq 'plain') { 'b001' } else { 'b002' })
        $Entries = Invoke-ZipFiles -Folder (Join-Path $TestDrive ('clean-' + $Mode)) -Stamp $Stamp -Obfuscate:($Mode -eq 'masked')

        $Entries | Should -Be (Get-CleanZipEntries -Stamp $Stamp)
    }

    It 'leaves out the files of another run and other JSON files in a shared folder (<Mode>)' -ForEach @(@{ Mode = 'plain' }, @{ Mode = 'masked' }) {
        $Folder = Join-Path $TestDrive ('shared-' + $Mode)
        Add-OtherRunFiles -Folder $Folder
        $Stamp = '20261109120000000' + $(if ($Mode -eq 'plain') { 'c001' } else { 'c002' })
        $Entries = Invoke-ZipFiles -Folder $Folder -Stamp $Stamp -Obfuscate:($Mode -eq 'masked')

        $Entries | Should -Be (Get-CleanZipEntries -Stamp $Stamp)
    }
}

Describe 'Two direct ResourceInventory.ps1 runs in one PowerShell session' {
    BeforeAll {
        # The run's param block, the top-level statement that clears the metrics
        # entries at its start, and its last statement, as written. In between, a
        # stand-in for the collection adds an incomplete entry when asked.
        $Ast = Get-ScriptAst -File 'ResourceInventory.ps1'
        $Top = @($Ast.EndBlock.Statements)
        $Start = @($Top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match '^if \(-not \$RunAllSubs\.IsPresent\)' -and $_.Extent.Text -match '\$Global:MetricsFailedSubs = @\(\)' })
        $script:StartCount = $Start.Count
        $script:TwoRuns = Join-Path $TestDrive 'two-direct-runs.ps1'
        Set-Content -LiteralPath $script:TwoRuns -Encoding utf8 -Value (@(
                $Ast.ParamBlock.Extent.Text
                ". '{0}'" -f ((Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1') -replace "'", "''")
                @($Start | ForEach-Object { $_.Extent.Text })
                'if ($env:RDA_TEST_METRICS_GAP) { if ($null -eq $Global:MetricsFailedSubs) { $Global:MetricsFailedSubs = @() }; $Global:MetricsFailedSubs += [pscustomobject]@{ Name = ''sub-two''; Id = ''id-2''; Message = ''still failed''; ReportFolder = ''ResourcesReport_x''; Complete = $false } }'
                $Top[-1].Extent.Text
            ) -join "`n")

        function script:Invoke-TwoRunsScript
        {
            param([hashtable]$Arguments, [switch]$Gap)
            $Global:ZipOutputFile = Join-Path $TestDrive ('ResourcesReport_{0}.zip' -f [guid]::NewGuid())
            Set-Content -LiteralPath $Global:ZipOutputFile -Value 'zip'
            # The zip was written, as Write-RdaReportZip returns it; read by the
            # run's last statement.
            Set-Variable -Name ZipWritten -Value $true
            $env:RDA_TEST_METRICS_GAP = $(if ($Gap) { '1' } else { '' })
            try
            {
                $global:LASTEXITCODE = 0
                $null = & $script:TwoRuns @Arguments 6>&1
                return $global:LASTEXITCODE
            }
            finally
            {
                Remove-Item -Path 'Env:RDA_TEST_METRICS_GAP' -ErrorAction SilentlyContinue
            }
        }

        $script:SessionMetrics = Get-Variable -Name MetricsFailedSubs -Scope Global -ErrorAction SilentlyContinue
        $script:SessionZip = Get-Variable -Name ZipOutputFile -Scope Global -ErrorAction SilentlyContinue
    }
    AfterAll {
        if ($script:SessionMetrics) { $Global:MetricsFailedSubs = $script:SessionMetrics.Value }
        else { Remove-Variable -Name MetricsFailedSubs -Scope Global -ErrorAction SilentlyContinue }
        if ($script:SessionZip) { $Global:ZipOutputFile = $script:SessionZip.Value }
        else { Remove-Variable -Name ZipOutputFile -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'clears the metrics entries once at the start of the run' {
        $script:StartCount | Should -Be 1
    }

    It 'exits 0 from a clean run after a run with incomplete metrics' {
        $Global:MetricsFailedSubs = @()
        Invoke-TwoRunsScript -Arguments @{ TenantID = 'tenant-1' } -Gap | Should -Be 3
        Invoke-TwoRunsScript -Arguments @{ TenantID = 'tenant-1' } | Should -Be 0
    }

    It 'keeps the entries of the earlier subscriptions under -RunAllSubs, where the wrapper owns them' {
        $Global:MetricsFailedSubs = @($script:Incomplete)
        Invoke-TwoRunsScript -Arguments @{ TenantID = 'tenant-1'; RunAllSubs = $true } | Should -Be 0
        @($Global:MetricsFailedSubs).Count | Should -Be 1
    }
}

Describe 'The end of a Run-AllSubscriptions.ps1 run with incomplete metrics' {
    BeforeAll {
        # The wrapper's last statements, from its FAILED (auth) lines to its exit
        # code, as written: the rest of the run needs Azure.
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
        $Top = @((Get-ScriptAst -File 'Run-AllSubscriptions.ps1').EndBlock.Statements)
        $From = @(0..($Top.Count - 1) | Where-Object { $Top[$_].Extent.Text -match '^\$AuthSkippedPhases = @\(\)' })[0]
        $To = @(0..($Top.Count - 1) | Where-Object { $Top[$_].Extent.Text -match '^if \(\$WrapperExitCode -ne 0\)' })[-1]
        $script:WrapperEnd = (@($Top[$From..($To - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n'EXIT=' + `$WrapperExitCode"

        function script:Invoke-WrapperEnd
        {
            param([hashtable]$InventoryPassthrough, [object[]]$CollectorFailures = @(), [string]$InventoryRoot = (Join-Path $TestDrive 'no-reports'))
            # Read by the lifted statements, which run in this scope.
            Set-Variable -Name TenantID -Value 'tenant-1'
            Set-Variable -Name WrapperTranscriptStarted -Value $false
            $Global:CollectorFailures = $CollectorFailures
            $Global:ConsumptionFailedSubs = @()
            $Lines = @(. ([scriptblock]::Create($script:WrapperEnd)) 6>&1 | ForEach-Object { [string]$_ })
            [pscustomobject]@{ ExitCode = [int](($Lines | Where-Object { $_ -like 'EXIT=*' } | Select-Object -Last 1) -replace '^EXIT=', ''); Lines = $Lines }
        }

        $script:SessionValues = @{}
        foreach ($Name in @('MetricsFailedSubs', 'CollectorFailures', 'ConsumptionFailedSubs'))
        {
            $script:SessionValues[$Name] = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
        }
    }
    AfterAll {
        foreach ($Name in $script:SessionValues.Keys)
        {
            if ($script:SessionValues[$Name]) { Set-Variable -Name $Name -Scope Global -Value $script:SessionValues[$Name].Value }
            else { Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue }
        }
    }

    It 'prints the command with the switches it forwards and exits 3, with no FAILED (auth) for it' {
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Result = Invoke-WrapperEnd -InventoryPassthrough @{ Obfuscate = $true; SkipConsumption = $true; ConcurrencyLimit = 12; Debug = $true }

        $Result.ExitCode | Should -Be 3
        $Result.Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -Obfuscate -SkipConsumption -ConcurrencyLimit 12'
        $Result.Lines | Should -Not -Contain '===================== FAILED (auth) ====================='
    }

    It 'seeds the command of a masked run from the dictionary in the subscription''s report folder' {
        $Root = Join-Path $TestDrive 'wrapper-reports'
        $Folder = Join-Path $Root 'ResourcesReport_x'
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        $Dict = Join-Path $Folder 'ObfuscationDictionary_ResourcesReport_x.json'
        Set-Content -LiteralPath $Dict -Value '{}'
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Result = Invoke-WrapperEnd -InventoryPassthrough @{ Obfuscate = $true; ConcurrencyLimit = 6 } -InventoryRoot $Root

        $Result.ExitCode | Should -Be 3
        $Result.Lines | Should -Contain ("  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -Obfuscate -ConcurrencyLimit 6 -ObfuscationDictionary '{0}'" -f $Dict.Replace("'", "''"))
        $Result.Lines | Should -Contain "  Each new zip replaces that subscription's inner zip in the AllSubscriptions_ResourcesReport_*.zip: swap it in for the first one, do not add it next to it, or its resources are counted twice."
    }

    It 'still reads an entry as incomplete and exits 3 after it went through a stream summary file' {
        # A parallel stream writes its entries to a JSON summary file and the
        # wrapper reads it back with ConvertFrom-Json. The statements that do
        # that are run as written.
        $StreamTop = @((Get-ScriptAst -File 'Run-AllSubscriptions.Stream.ps1').EndBlock.Statements)
        $Write = @($StreamTop | Where-Object { $_.Extent.Text -match '^\$MetricsFailedSubs = ' -or $_.Extent.Text -match '^\$Summary = \[pscustomobject\]' -or ($_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Extent.Text -match '\$Summary \| ConvertTo-Json') })
        $Write.Count | Should -Be 3
        $WrapperAst = Get-ScriptAst -File 'Run-AllSubscriptions.ps1'
        $Read = @($WrapperAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Extent.Text -match '^\$StreamSummary = Get-Content' }, $true))
        $Merge = @($WrapperAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Extent.Text -match '^if \(\$StreamSummary\.MetricsFailedSubs' }, $true))
        $Read.Count | Should -Be 1
        $Merge.Count | Should -Be 1

        # The entry as Extension/Metrics.ps1 records it.
        $Global:MetricsFailedSubs = @([pscustomobject]@{ Name = 'sub-two'; Id = 'id-2'; Message = 'still failed'; ReportFolder = 'ResourcesReport_x'; Complete = $false })
        $StreamSummaryPath = Join-Path $TestDrive 'stream-1-summary.json'
        . ([scriptblock]::Create((@($Write | ForEach-Object { $_.Extent.Text }) -join "`n")))
        Test-Path -LiteralPath $StreamSummaryPath | Should -BeTrue

        $S = [pscustomobject]@{ SummaryPath = $StreamSummaryPath }
        $Global:MetricsFailedSubs = @()
        . ([scriptblock]::Create($Read[0].Extent.Text + "`n" + $Merge[0].Extent.Text))
        $StreamSummary | Should -Not -BeNullOrEmpty -Because $S.SummaryPath

        @(Get-MetricsIncompleteEntries -Entries $Global:MetricsFailedSubs).Count | Should -Be 1
        $Result = Invoke-WrapperEnd -InventoryPassthrough @{ ConcurrencyLimit = 6 }
        $Result.ExitCode | Should -Be 3
        $Result.Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -ConcurrencyLimit 6'
        $Result.Lines | Should -Not -Contain '===================== FAILED (auth) ====================='
    }

    It 'exits 5 with a collector failure too' {
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Result = Invoke-WrapperEnd -InventoryPassthrough @{ ConcurrencyLimit = 6 } -CollectorFailures @([pscustomobject]@{ Id = 'id-2'; Module = 'Compute'; Message = 'failed' })

        $Result.ExitCode | Should -Be 5
        $Result.Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -ConcurrencyLimit 6'
        # A plain run is told which zip the new one replaces too.
        $Result.Lines | Should -Contain "  Each new zip replaces that subscription's inner zip in the AllSubscriptions_ResourcesReport_*.zip: swap it in for the first one, do not add it next to it, or its resources are counted twice."
    }

    It 'exits 3 with only FAILED (auth) for a sign-in skip' {
        $Global:MetricsFailedSubs = @($script:SignIn)
        $Result = Invoke-WrapperEnd -InventoryPassthrough @{ ConcurrencyLimit = 6 }

        $Result.ExitCode | Should -Be 3
        $Result.Lines | Should -Contain '===================== FAILED (auth) ====================='
        $Result.Lines | Should -Not -Contain '=================== FAILED (metrics) ==================='
    }

    It 'exits 0 when nothing failed' {
        $Global:MetricsFailedSubs = @()
        (Invoke-WrapperEnd -InventoryPassthrough @{ ConcurrencyLimit = 6 }).ExitCode | Should -Be 0
    }
}

Describe 'The per-subscription output check of a Run-AllSubscriptions.ps1 run' {
    BeforeAll {
        # The wrapper's statements that count the zips and exit 2 when one is
        # missing, as written, with a stand-in Exit-Wrapper that records its code.
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
        $Top = @((Get-ScriptAst -File 'Run-AllSubscriptions.ps1').EndBlock.Statements)
        $From = @(0..($Top.Count - 1) | Where-Object { $Top[$_].Extent.Text -match '^\$ExpectedZipCount = ' })[0]
        $script:OutputCheck = (@($Top[$From..($From + 1)] | ForEach-Object { $_.Extent.Text }) -join "`n")

        function script:Invoke-OutputCheck
        {
            param([hashtable]$InventoryPassthrough, [string]$InventoryRoot = (Join-Path $TestDrive 'check-reports'), [object[]]$Completed = @([pscustomobject]@{ Name = 'sub-two'; Id = 'id-2'; Count = 3 }))
            # Read by the lifted statements, which run in this scope.
            New-Item -ItemType Directory -Path (Join-Path $InventoryRoot 'ResourcesReport_x') -Force | Out-Null
            Set-Variable -Name TenantID -Value 'tenant-1'
            Set-Variable -Name WrapperTranscriptStarted -Value $false
            Set-Variable -Name ResumeStateFile -Value (Join-Path $InventoryRoot '.resume-state.json')
            Set-Variable -Name RunStartTime -Value (Get-Date).AddMinutes(-5)
            Set-Variable -Name SubResourceCounts -Value @($Completed)
            function Exit-Wrapper { param([int]$Code) Write-Output ('EXIT=' + $Code); throw 'wrapper exited' }
            $Lines = [System.Collections.Generic.List[string]]::new()
            try { . ([scriptblock]::Create($script:OutputCheck)) 6>&1 | ForEach-Object { $Lines.Add([string]$_) } }
            catch { if ($_.Exception.Message -ne 'wrapper exited') { throw } }
            return @($Lines)
        }

        $script:SessionMetrics = Get-Variable -Name MetricsFailedSubs -Scope Global -ErrorAction SilentlyContinue
        $script:SessionUnwritten = Get-Variable -Name RdaUnwrittenReportZips -Scope Global -ErrorAction SilentlyContinue
    }
    AfterAll {
        if ($script:SessionMetrics) { $Global:MetricsFailedSubs = $script:SessionMetrics.Value }
        else { Remove-Variable -Name MetricsFailedSubs -Scope Global -ErrorAction SilentlyContinue }
        if ($script:SessionUnwritten) { $Global:RdaUnwrittenReportZips = $script:SessionUnwritten.Value }
        else { Remove-Variable -Name RdaUnwrittenReportZips -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'prints the FAILED (metrics) lines before it exits 2 for a missing zip' {
        $Global:RdaUnwrittenReportZips = @()
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Lines = Invoke-OutputCheck -InventoryPassthrough @{ ConcurrencyLimit = 6 }

        $Lines | Should -Contain 'EXIT=2'
        $Lines | Should -Contain '=================== FAILED (metrics) ==================='
        $Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -ConcurrencyLimit 6'
        [array]::IndexOf($Lines, '=================== FAILED (metrics) ===================') | Should -BeLessThan ([array]::IndexOf($Lines, 'EXIT=2'))
        # No AllSubscriptions zip is made on this exit, so it is not named as one to change.
        $Lines | Should -Contain "  Each new zip replaces that subscription's zip in its report folder (no AllSubscriptions_ResourcesReport_*.zip was made): put it there in place of the first one, do not keep both, or its resources are counted twice."
        @($Lines | Where-Object { $_ -like "*inner zip in the AllSubscriptions_ResourcesReport_*" }).Count | Should -Be 0
    }

    It 'prints no FAILED (metrics) lines when the metrics are complete' {
        $Global:RdaUnwrittenReportZips = @()
        $Global:MetricsFailedSubs = @()
        $Lines = Invoke-OutputCheck -InventoryPassthrough @{ ConcurrencyLimit = 6 }

        $Lines | Should -Contain 'EXIT=2'
        $Lines | Should -Not -Contain '=================== FAILED (metrics) ==================='
    }

    It 'does not count a partial zip left by a failed compression, names it and exits 2 for the missing zip' {
        # One subscription ran to completion but its zip is gone; another one's
        # compression failed and its partial zip could not be removed.
        $Global:MetricsFailedSubs = @()
        $Root = Join-Path $TestDrive 'check-partial'
        $Partial = Join-Path (Join-Path $Root 'ResourcesReport_y') 'ResourcesReport_y.zip'
        New-Item -ItemType Directory -Path (Split-Path -Parent $Partial) -Force | Out-Null
        Set-Content -LiteralPath $Partial -Value 'part'
        $Global:RdaUnwrittenReportZips = @($Partial)
        $Lines = Invoke-OutputCheck -InventoryPassthrough @{ ConcurrencyLimit = 6 } -InventoryRoot $Root

        $Lines | Should -Contain 'EXIT=2'
        $Lines | Should -Contain ('Not consolidated: {0} is a partial zip from a failed compression, not a report; delete it.' -f $Partial)
    }

    It 'exits 2 when its one subscription''s zip could not be written, also when it was not counted as completed' {
        $Global:MetricsFailedSubs = @()
        $Root = Join-Path $TestDrive 'check-only-unwritten'
        $Global:RdaUnwrittenReportZips = @((Join-Path (Join-Path $Root 'ResourcesReport_y') 'ResourcesReport_y.zip'))
        $Lines = Invoke-OutputCheck -InventoryPassthrough @{ ConcurrencyLimit = 6 } -InventoryRoot $Root -Completed @()

        $Lines | Should -Contain 'EXIT=2'
        $Lines | Should -Contain '  - The report zip of 1 subscription(s) could not be written (see its "No report was written" line); it is listed as failed.'
    }

    It 'counts the zip of a subscription that wrote one, but not the partial zip of another, and exits 2 for that one' {
        $Global:MetricsFailedSubs = @()
        $Root = Join-Path $TestDrive 'check-good-and-partial'
        $Good = Join-Path (Join-Path $Root 'ResourcesReport_x') 'ResourcesReport_x.zip'
        $Partial = Join-Path (Join-Path $Root 'ResourcesReport_y') 'ResourcesReport_y.zip'
        foreach ($Zip in @($Good, $Partial))
        {
            New-Item -ItemType Directory -Path (Split-Path -Parent $Zip) -Force | Out-Null
            Set-Content -LiteralPath $Zip -Value 'zip'
        }
        $Global:RdaUnwrittenReportZips = @($Partial)
        $Lines = Invoke-OutputCheck -InventoryPassthrough @{ ConcurrencyLimit = 6 } -InventoryRoot $Root

        $Lines | Should -Contain 'EXIT=2'
        $Lines | Should -Contain '  Expected zips: 2 (one per subscription that ran to completion this run)'
        @($Lines | Where-Object { $_ -like '  Found zips:    1 *' }).Count | Should -Be 1
        $Lines | Should -Contain ('Not consolidated: {0} is a partial zip from a failed compression, not a report; delete it.' -f $Partial)
    }

    It 'passes when every subscription wrote its zip' {
        $Global:MetricsFailedSubs = @()
        $Global:RdaUnwrittenReportZips = @()
        $Root = Join-Path $TestDrive 'check-good'
        $Good = Join-Path (Join-Path $Root 'ResourcesReport_x') 'ResourcesReport_x.zip'
        New-Item -ItemType Directory -Path (Split-Path -Parent $Good) -Force | Out-Null
        Set-Content -LiteralPath $Good -Value 'zip'
        $Lines = Invoke-OutputCheck -InventoryPassthrough @{ ConcurrencyLimit = 6 } -InventoryRoot $Root

        $Lines | Should -Not -Contain 'EXIT=2'
        $Lines | Should -Contain 'Per-subscription output verification: OK (1 zip(s) match 1 successful sub(s))'
    }
}

Describe 'The consolidation of a Run-AllSubscriptions.ps1 run' {
    BeforeAll {
        # The wrapper's statements that put the per-subscription zips into the
        # AllSubscriptions zip, as written, with a stand-in Compress-Archive
        # that records what it was given.
        . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
        $Top = @((Get-ScriptAst -File 'Run-AllSubscriptions.ps1').EndBlock.Statements)
        $From = @(0..($Top.Count - 1) | Where-Object { $Top[$_].Extent.Text -match '^\$OuterZipFile = \$null' })[0]
        $script:Consolidate = (@($Top[$From..($From + 1)] | ForEach-Object { $_.Extent.Text }) -join "`n")
        $script:SessionUnwritten = Get-Variable -Name RdaUnwrittenReportZips -Scope Global -ErrorAction SilentlyContinue
    }
    AfterAll {
        if ($script:SessionUnwritten) { $Global:RdaUnwrittenReportZips = $script:SessionUnwritten.Value }
        else { Remove-Variable -Name RdaUnwrittenReportZips -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'leaves out a partial zip left by a failed compression and names it' {
        $InventoryRoot = Join-Path $TestDrive 'consolidate'
        $Good = Join-Path (Join-Path $InventoryRoot 'ResourcesReport_x') 'ResourcesReport_x.zip'
        $Partial = Join-Path (Join-Path $InventoryRoot 'ResourcesReport_y') 'ResourcesReport_y.zip'
        foreach ($Zip in @($Good, $Partial))
        {
            New-Item -ItemType Directory -Path (Split-Path -Parent $Zip) -Force | Out-Null
            Set-Content -LiteralPath $Zip -Value 'zip'
        }
        $Global:RdaUnwrittenReportZips = @($Partial)
        Set-Variable -Name RunStartTime -Value (Get-Date).AddMinutes(-5)
        $script:Packed = @()
        Mock Compress-Archive { $script:Packed = @($Path) }
        $Lines = @(. ([scriptblock]::Create($script:Consolidate)) 6>&1 | ForEach-Object { [string]$_ })

        $script:Packed | Should -Be @($Good)
        $Lines | Should -Contain ('Not consolidated: {0} is a partial zip from a failed compression, not a report; delete it.' -f $Partial)
    }

    It 'takes every zip of the run when no compression failed' {
        $InventoryRoot = Join-Path $TestDrive 'consolidate-clean'
        $Zips = @('ResourcesReport_x', 'ResourcesReport_y') | ForEach-Object { Join-Path (Join-Path $InventoryRoot $_) ($_ + '.zip') }
        foreach ($Zip in $Zips)
        {
            New-Item -ItemType Directory -Path (Split-Path -Parent $Zip) -Force | Out-Null
            Set-Content -LiteralPath $Zip -Value 'zip'
        }
        $Global:RdaUnwrittenReportZips = @()
        Set-Variable -Name RunStartTime -Value (Get-Date).AddMinutes(-5)
        $script:Packed = @()
        Mock Compress-Archive { $script:Packed = @($Path) }
        $Lines = @(. ([scriptblock]::Create($script:Consolidate)) 6>&1 | ForEach-Object { [string]$_ })

        @($script:Packed | Sort-Object) | Should -Be @($Zips | Sort-Object)
        @($Lines | Where-Object { $_ -like 'Not consolidated:*' }).Count | Should -Be 0
    }

    It 'gets the partial zips of a parallel run from its stream summary files' {
        # The stream's summary statements and the wrapper's merge statement,
        # as written.
        $StreamTop = @((Get-ScriptAst -File 'Run-AllSubscriptions.Stream.ps1').EndBlock.Statements)
        $Write = @($StreamTop | Where-Object { $_.Extent.Text -match '^\$UnwrittenReportZips = ' -or $_.Extent.Text -match '^\$Summary = \[pscustomobject\]' -or ($_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Extent.Text -match '\$Summary \| ConvertTo-Json') })
        $Write.Count | Should -Be 3
        $WrapperAst = Get-ScriptAst -File 'Run-AllSubscriptions.ps1'
        $Read = @($WrapperAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Extent.Text -match '^\$StreamSummary = Get-Content' }, $true))
        $Merge = @($WrapperAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Extent.Text -match '^if \(\$StreamSummary\.UnwrittenReportZips' }, $true))
        $Merge.Count | Should -Be 1

        $Global:RdaUnwrittenReportZips = @('/reports/ResourcesReport_y/ResourcesReport_y.zip')
        $StreamSummaryPath = Join-Path $TestDrive 'stream-unwritten-summary.json'
        . ([scriptblock]::Create((@($Write | ForEach-Object { $_.Extent.Text }) -join "`n")))

        Set-Variable -Name S -Value ([pscustomobject]@{ SummaryPath = $StreamSummaryPath })
        $Global:RdaUnwrittenReportZips = @()
        . ([scriptblock]::Create($Read[0].Extent.Text + "`n" + $Merge[0].Extent.Text))
        @($Global:RdaUnwrittenReportZips) | Should -Be @('/reports/ResourcesReport_y/ResourcesReport_y.zip')
    }
}
