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

    It 'leaves out the tenant when the run had none' {
        Get-MetricsRetryCommand -TenantID '' -SubscriptionId 'id-2' -RunParameters $null | Should -Be './ResourceInventory.ps1 -SubscriptionID id-2'
    }

    It 'keeps the data switches of the run, so a masked run is collected again masked' {
        $Run = @{ Obfuscate = [switch]::Present; SkipConsumption = $true; DeviceLogin = [switch]::Present; ConcurrencyLimit = 12; ObfuscationDictionary = "/data/it's here.json" }
        Get-MetricsRetryCommand -TenantID 'tenant-1' -SubscriptionId 'id-2' -RunParameters $Run | Should -Be "./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -Obfuscate -SkipConsumption -DeviceLogin -ConcurrencyLimit 12 -ObfuscationDictionary '/data/it''s here.json'"
    }

    It 'never writes a credential or a switch that was turned off' {
        $Run = @{ Obfuscate = [switch]$false; DeviceLogin = $false; Appid = 'app-1'; Secret = (ConvertTo-SecureString 'not-a-real-value' -AsPlainText -Force); SkipMetrics = $true; Debug = $true; ObfuscationDictionary = '/data/d.json' }
        $Command = Get-MetricsRetryCommand -TenantID 'tenant-1' -SubscriptionId 'id-2' -RunParameters $Run
        $Command | Should -Be './ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2'
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
            param([hashtable]$Arguments, [switch]$NoZip)
            # The report zip of the run, or none when it could not be written.
            $Global:ZipOutputFile = Join-Path $TestDrive ('ResourcesReport_{0}.zip' -f [guid]::NewGuid())
            if (-not $NoZip) { Set-Content -LiteralPath $Global:ZipOutputFile -Value 'zip' }
            $global:LASTEXITCODE = 0
            $Lines = @(& $script:DirectRun @Arguments 6>&1 | ForEach-Object { [string]$_ })
            [pscustomobject]@{ ExitCode = $global:LASTEXITCODE; Lines = $Lines }
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

    It 'prints the command with the run''s switches and exits 3' {
        $Global:MetricsFailedSubs = @($script:SignIn, $script:Incomplete)
        $Secret = ConvertTo-SecureString 'not-a-real-value' -AsPlainText -Force
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1'; Obfuscate = $true; ConcurrencyLimit = 9; ObfuscationDictionary = '/data/d.json'; Appid = 'app-1'; Secret = $Secret }

        $Result.ExitCode | Should -Be 3
        $Result.Lines | Should -Contain '=================== FAILED (metrics) ==================='
        $Result.Lines | Should -Contain "  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -Obfuscate -ConcurrencyLimit 9 -ObfuscationDictionary '/data/d.json'"
        ($Result.Lines -join "`n") | Should -Not -Match 'Secret|app-1'
    }

    It 'still prints the command but exits 2, not 3, when its zip could not be written' {
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1' } -NoZip

        $Result.ExitCode | Should -Be 2
        $Result.Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2'
    }

    It 'exits 2 when its zip could not be written and the metrics are complete' {
        $Global:MetricsFailedSubs = @()
        (Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1' } -NoZip).ExitCode | Should -Be 2
    }

    It 'exits 0 and prints nothing when the metrics are complete' {
        $Global:MetricsFailedSubs = @($script:SignIn)
        $Result = Invoke-DirectRunEnd -Arguments @{ TenantID = 'tenant-1' }

        $Result.ExitCode | Should -Be 0
        $Result.Lines | Should -Not -Contain '=================== FAILED (metrics) ==================='
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
                '$CompressionOutput = @{ Path = @(''x''); CompressionLevel = ''Fastest''; DestinationPath = $Global:ZipOutputFile }'
                '$Runtime = ''0:01''; $ReportingRunTime = ''0:01'''
                @($Top[$From..($Top.Count - 1)] | ForEach-Object { $_.Extent.Text })
            ) -join "`n")

        function script:Invoke-ZipEnd
        {
            param([hashtable]$Arguments, [switch]$Fail)
            $Global:ZipOutputFile = Join-Path $TestDrive ('ResourcesReport_{0}.zip' -f [guid]::NewGuid())
            $env:RDA_TEST_ZIP_FAIL = $(if ($Fail) { '1' } else { '' })
            try
            {
                $global:LASTEXITCODE = 0
                $Lines = @(& $script:ZipEnd @Arguments *>&1 | ForEach-Object { [string]$_ })
                [pscustomobject]@{ ExitCode = $global:LASTEXITCODE; Lines = $Lines; ZipLeft = (Test-Path -LiteralPath $Global:ZipOutputFile) }
            }
            finally
            {
                Remove-Item -Path 'Env:RDA_TEST_ZIP_FAIL' -ErrorAction SilentlyContinue
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

    It 'removes a partial zip under -RunAllSubs and leaves the exit to the wrapper' {
        $Global:MetricsFailedSubs = @()
        $Result = Invoke-ZipEnd -Arguments @{ TenantID = 'tenant-1'; RunAllSubs = $true } -Fail

        $Result.ExitCode | Should -Be 0
        $Result.ZipLeft | Should -BeFalse
        @($Result.Lines | Where-Object { $_ -like '*Reporting Data File:*' }).Count | Should -Be 0
        @($Result.Lines | Where-Object { $_ -like '*No report was written*' }).Count | Should -Be 1
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
            param([hashtable]$InventoryPassthrough, [object[]]$CollectorFailures = @())
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

    It 'exits 5 with a collector failure too' {
        $Global:MetricsFailedSubs = @($script:Incomplete)
        $Result = Invoke-WrapperEnd -InventoryPassthrough @{ ConcurrencyLimit = 6 } -CollectorFailures @([pscustomobject]@{ Id = 'id-2'; Module = 'Compute'; Message = 'failed' })

        $Result.ExitCode | Should -Be 5
        $Result.Lines | Should -Contain '  ./ResourceInventory.ps1 -TenantID tenant-1 -SubscriptionID id-2 -ConcurrencyLimit 6'
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
