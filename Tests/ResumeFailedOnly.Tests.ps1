# -ResumeFailedOnly retries the subscriptions on the retry list (FailedAttempts in
# the resume state). After an interrupted run, a -ResumeFailedOnly run whose
# retries all succeeded deleted the resume state, although subscriptions the
# interrupted run never reached were still not collected. The next -Resume then
# collected every subscription again, and nothing named the ones still missing.
# With nothing on the retry list, it said only "Nothing to retry" and did not name
# them either.
#
# The wrapper code is lifted from its AST and run as written: the -ResumeFailedOnly
# filter, the sequential loop, the end-of-run resume-state cleanup and the summary's
# retry advice. A stand-in ResourceInventory.ps1 writes one report folder and zip
# per call, or throws for the ids in $Global:RdaRfoFailIds.
#
# Run with: Invoke-Pester ./Tests/ResumeFailedOnly.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')

    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('ResumeFailedOnlyTest_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null

    $script:FakeRoot = Join-Path $script:TestBase 'fake-tool'
    New-Item -ItemType Directory -Path $script:FakeRoot -Force | Out-Null
    $FakeInner = @'
param([string]$TenantID, [string]$SubscriptionID, [switch]$RunAllSubs, [switch]$Obfuscate, [switch]$SkipMetrics, [switch]$SkipConsumption, [switch]$DeviceLogin, [int]$ConcurrencyLimit)
if (@($Global:RdaRfoFailIds) -contains $SubscriptionID) { throw 'stand-in failure for this subscription' }
$Root = $Global:RdaRfoRoot
$Stamp = (Get-Date -Format 'yyyyMMddHHmmssfff') + $SubscriptionID
$Folder = Join-Path $Root ('ResourcesReport' + $Stamp)
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
$Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
$Html = Join-Path $Folder ('ResourcesReport_{0}.html' -f $Stamp)
Set-Content -LiteralPath $Html -Value '<html></html>' -Encoding utf8
Compress-Archive -Path $Html -DestinationPath $Zip -Force
$Global:ZipOutputFile = $Zip
$Global:Resources = @(1)
$Global:ResourceCount = 1
'@
    Set-Content -LiteralPath (Join-Path $script:FakeRoot 'ResourceInventory.ps1') -Value $FakeInner -Encoding utf8

    # --- Wrapper code lifted from its AST and run as written ------------------
    $Tokens = $null
    $ParseErrors = $null
    $script:WrapperPath = Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$Tokens, [ref]$ParseErrors)
    $Top = @($Ast.EndBlock.Statements)
    function script:Find-TopIndex
    {
        param([scriptblock]$Match, [int]$After = -1, [string]$What)
        for ($i = $After + 1; $i -lt $Top.Count; $i++) { if (& $Match $Top[$i]) { return $i } }
        throw "Expected $What in Run-AllSubscriptions.ps1."
    }
    function script:Join-Top { param([int]$From, [int]$To) (@($Top[$From..$To] | ForEach-Object { $_.Extent.Text }) -join "`n") }

    # The -ResumeFailedOnly filter.
    $FilterAt = script:Find-TopIndex -What "the 'if (`$ResumeFailedOnly)' filter" -Match { param($s) $s -is [System.Management.Automation.Language.IfStatementAst] -and $s.Clauses[0].Item1.Extent.Text -eq '$ResumeFailedOnly' -and $s.Extent.Text.Contains('Nothing to retry') }
    $FilterText = $Top[$FilterAt].Extent.Text

    # The sequential loop: the body of `if ($ParallelStreams -le 1)`. Its catch
    # resets $InventoryRoot to $HOME/InventoryReports (C:\InventoryReports on
    # Windows); both point at the test's home instead.
    $SeqIf = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and $args[0].Clauses[0].Item1.Extent.Text -eq '$ParallelStreams -le 1' }, $true))
    if ($SeqIf.Count -ne 1) { throw "Expected one 'if (`$ParallelStreams -le 1)' in the wrapper, found $($SeqIf.Count)." }
    $SeqText = (($SeqIf[0].Clauses[0].Item2.Extent.Text -replace '\$PSScriptRoot', '$FakeScriptRoot') -replace '\$HOME\b', '$Global:RdaRfoHome') -replace '"C:\\InventoryReports"', '"$Global:RdaRfoHome/InventoryReports"'

    # The resume-state cleanup: every statement after the main-summary build up to
    # and including the clean-run clear.
    $MainSummaryAt = script:Find-TopIndex -What 'the main-summary build' -Match { param($s) $s -is [System.Management.Automation.Language.IfStatementAst] -and $s.Extent.Text -match 'New-RdaAllSubHtmlSummary -RunOutputDirectory' }
    $ClearAt = script:Find-TopIndex -After $MainSummaryAt -What 'the clean-run resume-state clear' -Match { param($s) $s -is [System.Management.Automation.Language.IfStatementAst] -and $s.Extent.Text.Contains('Resume state cleared (clean run).') }
    $CleanupText = script:Join-Top -From ($MainSummaryAt + 1) -To $ClearAt

    # The summary's retry advice: from the failed-subscriptions block to the execution time.
    $AdviceAt = script:Find-TopIndex -After $ClearAt -What 'the failed-subscriptions summary' -Match { param($s) $s -is [System.Management.Automation.Language.IfStatementAst] -and $s.Clauses[0].Item1.Extent.Text -eq '$FailedSubscriptions.Count -gt 0' -and $s.Extent.Text.Contains('Subscriptions Failed:') }
    $TimeAt = script:Find-TopIndex -After $AdviceAt -What 'the execution-time line' -Match { param($s) $s.Extent.Text.StartsWith('Write-Host ("Execution Time:') }
    $AdviceText = script:Join-Top -From $AdviceAt -To $TimeAt

    # The startup reads of the resume state. The completed ids are read as an
    # array: a one-id list comes back from Get-CompletedSubscriptionIds as a bare
    # string, and `+=` would then join the next id onto it.
    $Prologue = "function Exit-Wrapper { param([int]`$Code) throw ('Exit-Wrapper ' + `$Code) }`n" +
    "`$Obfuscate = `$false; `$SkippedCount = 0; `$SkippedSubscriptions = @(); `$SubResourceCounts = @(); `$FailedSubscriptions = @(); `$DiagFile = `$null`n" +
    "`$InventoryPassthrough = @{ ConcurrencyLimit = 6 }; `$WrapperTranscriptStarted = `$false; `$Elapsed = [timespan]::Zero`n" +
    "`$CompletedIds = @(Get-CompletedSubscriptionIds -Path `$ResumeStateFile -Tenant `$TenantID | Where-Object { `$_ })`n" +
    "`$FailedAttempts = Get-FailedAttempts -Path `$ResumeStateFile -Tenant `$TenantID`n" +
    "`$CompletedReports = Get-CompletedReports -Path `$ResumeStateFile -Tenant `$TenantID`n"
    $Params = "param(`$FakeScriptRoot, `$Subscriptions, `$InventoryRoot, `$ResumeStateFile, `$TenantID, `$Resume, `$ResumeFailedOnly)`n"
    $Result = "`n[pscustomobject]@{ SkippedSubscriptions = @(`$SkippedSubscriptions); SubResourceCounts = @(`$SubResourceCounts) }"

    # A run that ends before the cleanup (the session ended): the loop only.
    $script:InterruptedRunBlock = [scriptblock]::Create($Params + $Prologue + ". " + $SeqText + $Result)
    # A sequential run from the filter to the summary's retry advice.
    $script:RunBlock = [scriptblock]::Create($Params + $Prologue + $FilterText + "`n. " + $SeqText + "`n" + $CleanupText + "`n" + $AdviceText + $Result)

    # Runs a block and returns its result object and the lines it printed. A
    # run that ends through Exit-Wrapper returns its exit code instead.
    function script:Invoke-Captured
    {
        param([scriptblock]$Block, [object[]]$Arguments)
        $Lines = [System.Collections.Generic.List[string]]::new()
        $Results = [System.Collections.Generic.List[object]]::new()
        $Code = $null
        try
        {
            & $Block @Arguments 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { $Lines.Add([string]$_.MessageData) }
                elseif ($_ -is [pscustomobject]) { $Results.Add($_) }
            }
        }
        catch
        {
            if ($_.Exception.Message -match '^Exit-Wrapper (\d+)$') { $Code = [int]$Matches[1] } else { throw }
        }
        return [pscustomobject]@{ Result = ($Results | Select-Object -Last 1); Text = @($Lines); ExitCode = $Code }
    }

    function script:Invoke-Run
    {
        param([object[]]$Subs, [switch]$Resume, [switch]$ResumeFailedOnly, [switch]$Interrupted)
        $Block = if ($Interrupted) { $script:InterruptedRunBlock } else { $script:RunBlock }
        return script:Invoke-Captured -Block $Block -Arguments @($script:FakeRoot, @($Subs), $script:Root, $script:State, 't', [bool]$Resume, [bool]$ResumeFailedOnly)
    }

    function script:Read-State
    {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        return [pscustomobject]@{
            Completed = @(Get-CompletedSubscriptionIds -Path $Path -Tenant 't' | Where-Object { $_ })
            Failed    = @(Get-FailedAttempts -Path $Path -Tenant 't' | Where-Object { $null -ne $_ })
            Reports   = @(Get-CompletedReports -Path $Path -Tenant 't' | Where-Object { $null -ne $_ })
        }
    }

    $script:A = [pscustomobject]@{ Id = 'sub-a'; Name = 'Sub A' }
    $script:B = [pscustomobject]@{ Id = 'sub-b'; Name = 'Sub B' }
    $script:C = [pscustomobject]@{ Id = 'sub-c'; Name = 'Sub C' }

    # A fresh home, inventory root and resume-state path for each test. The root is
    # <home>/InventoryReports, the path the wrapper's sequential catch also uses.
    function script:New-Case
    {
        $Global:RdaRfoHome = Join-Path $script:TestBase ([guid]::NewGuid().ToString().Substring(0, 8))
        $script:Root = Join-Path $Global:RdaRfoHome 'InventoryReports'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $Global:RdaRfoRoot = $script:Root
        $Global:RdaRfoFailIds = @()
        $global:LASTEXITCODE = 0
        $script:State = Join-Path $script:Root '.resume-state-t.json'
    }
}

AfterAll {
    Remove-Variable -Name RdaRfoRoot, RdaRfoFailIds, RdaRfoHome -Scope Global -ErrorAction SilentlyContinue
    if ($script:TestBase -and (Test-Path $script:TestBase)) { Remove-Item -Path $script:TestBase -Recurse -Force }
}

Describe '-ResumeFailedOnly after an interrupted run' {
    BeforeEach { script:New-Case }
    It 'keeps the resume state while a subscription the interrupted run never reached is not collected, and names it' {
        # Run 1: Sub A completes, Sub B fails, the session ends before Sub C.
        $Global:RdaRfoFailIds = @('sub-b')
        $null = script:Invoke-Run -Subs @($script:A, $script:B) -Interrupted
        # Run 2: -ResumeFailedOnly over the same three; Sub B works now.
        $Global:RdaRfoFailIds = @()
        $R = script:Invoke-Run -Subs @($script:A, $script:B, $script:C) -ResumeFailedOnly
        $S = script:Read-State -Path $script:State

        @($R.Result.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-b')
        $S | Should -Not -BeNullOrEmpty -Because 'Sub C is still not collected, so the next -Resume needs the completed list'
        @($S.Completed | Sort-Object) | Should -Be @('sub-a', 'sub-b')
        @($S.Failed) | Should -BeNullOrEmpty
        @($R.Text | Where-Object { $_ -like 'Resume state cleared*' }).Count | Should -Be 0
        @($R.Text | Where-Object { $_ -eq 'Not Collected:           1 (Sub C) - no run has completed these and -ResumeFailedOnly retries only the retry list' }).Count | Should -Be 1
        @($R.Text | Where-Object { $_ -eq 'Re-run with -Resume to collect them; it skips the subscriptions already completed.' }).Count | Should -Be 1
    }

    It 'the -Resume run after it skips the completed subscriptions, collects only the missing one, and clears the state' {
        $Global:RdaRfoFailIds = @('sub-b')
        $null = script:Invoke-Run -Subs @($script:A, $script:B) -Interrupted
        $Global:RdaRfoFailIds = @()
        $null = script:Invoke-Run -Subs @($script:A, $script:B, $script:C) -ResumeFailedOnly
        $R = script:Invoke-Run -Subs @($script:A, $script:B, $script:C) -Resume

        @($R.Result.SkippedSubscriptions | ForEach-Object Id) | Should -Be @('sub-a', 'sub-b')
        @($R.Result.SubResourceCounts | ForEach-Object Id) | Should -Be @('sub-c')
        @($R.Text | Where-Object { $_ -eq 'Resume state cleared (clean run).' }).Count | Should -Be 1
        Test-Path -LiteralPath $script:State | Should -BeFalse
    }

    It 'a subscription still on the retry list is reported as failed, not as not collected' {
        $Global:RdaRfoFailIds = @('sub-b')
        $null = script:Invoke-Run -Subs @($script:A, $script:B) -Interrupted
        $R = script:Invoke-Run -Subs @($script:A, $script:B, $script:C) -ResumeFailedOnly
        $S = script:Read-State -Path $script:State

        @($S.Failed | ForEach-Object Id) | Should -Be @('sub-b')
        @($R.Text | Where-Object { $_ -like 'Subscriptions Failed:*Sub B*' }).Count | Should -Be 1
        @($R.Text | Where-Object { $_ -eq 'Not Collected:           1 (Sub C) - no run has completed these and -ResumeFailedOnly retries only the retry list' }).Count | Should -Be 1
    }

    It 'clears the state as before once every subscription is completed' {
        # Run 1 reached every subscription; only Sub B failed.
        $Global:RdaRfoFailIds = @('sub-b')
        $null = script:Invoke-Run -Subs @($script:A, $script:B, $script:C) -Interrupted
        $Global:RdaRfoFailIds = @()
        $R = script:Invoke-Run -Subs @($script:A, $script:B, $script:C) -ResumeFailedOnly

        @($R.Text | Where-Object { $_ -eq 'Resume state cleared (clean run).' }).Count | Should -Be 1
        @($R.Text | Where-Object { $_ -like 'Not Collected:*' }).Count | Should -Be 0
        Test-Path -LiteralPath $script:State | Should -BeFalse
    }
}

Describe '-ResumeFailedOnly with nothing on the retry list' {
    BeforeEach { script:New-Case }
    It 'after an interrupted run with no failure, names the subscriptions it never reached and exits 0' {
        # Run 1: Sub A completes, the session ends before Sub B.
        $null = script:Invoke-Run -Subs @($script:A) -Interrupted
        $R = script:Invoke-Run -Subs @($script:A, $script:B, $script:C) -ResumeFailedOnly
        $S = script:Read-State -Path $script:State

        $R.ExitCode | Should -Be 0
        @($R.Text | Where-Object { $_ -eq 'ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry.' }).Count | Should -Be 1
        @($R.Text | Where-Object { $_ -eq 'Not Collected:           2 (Sub B, Sub C) - no run has completed these and -ResumeFailedOnly retries only the retry list' }).Count | Should -Be 1
        @($R.Text | Where-Object { $_ -eq ('Resume State:            {0} (kept)' -f $script:State) }).Count | Should -Be 1
        @($R.Text | Where-Object { $_ -eq 'Re-run with -Resume to collect them; it skips the subscriptions already completed.' }).Count | Should -Be 1
        @($S.Completed) | Should -Be @('sub-a')
    }

    It 'names nothing when there is no resume state' {
        # A clean run deletes the state, so there is nothing to compare with.
        $R = script:Invoke-Run -Subs @($script:A, $script:B, $script:C) -ResumeFailedOnly

        $R.ExitCode | Should -Be 0
        @($R.Text | Where-Object { $_ -eq 'ResumeFailedOnly: no failed subscriptions in resume state. Nothing to retry.' }).Count | Should -Be 1
        @($R.Text | Where-Object { $_ -like 'Not Collected:*' }).Count | Should -Be 0
        Test-Path -LiteralPath $script:State | Should -BeFalse
    }

    It 'names nothing when every eligible subscription is completed' {
        $null = script:Invoke-Run -Subs @($script:A, $script:B, $script:C) -Interrupted
        $R = script:Invoke-Run -Subs @($script:A, $script:B, $script:C) -ResumeFailedOnly

        $R.ExitCode | Should -Be 0
        @($R.Text | Where-Object { $_ -like 'Not Collected:*' }).Count | Should -Be 0
    }
}
