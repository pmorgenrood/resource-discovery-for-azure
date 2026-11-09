#
# Metrics left incomplete because Azure Monitor kept failing (entries with
# Complete = $false, written by Extension/Metrics.ps1) are counted and listed
# apart from metrics skipped because the sign-in could not be refreshed (entries
# without Complete), in each place a run reports them:
#   - the wrapper's end-of-run console summary (Run-AllSubscriptions.ps1);
#   - RunSummary.log (Get-RunSummaryLogContent);
#   - each report's Diagnostics log (Write-RdaShareableDiagnosticsLog);
#   - the main summary (New-RdaAllSubHtmlSummary).
#
# The wrapper needs Azure to run end to end, so its metrics blocks are lifted
# from its AST and run as written, as Tests/FailureListSameName.Tests.ps1 does.
#
# Run with: Invoke-Pester ./Tests/MetricsIncompleteLabels.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1')
    . (Join-Path $script:RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')

    $ParseErrors = $null
    $WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$null, [ref]$ParseErrors)
    if ($ParseErrors) { throw ('Run-AllSubscriptions.ps1 does not parse: ' + (($ParseErrors | ForEach-Object { $_.Message }) -join '; ')) }
    $script:Top = @($WrapperAst.EndBlock.Statements)

    # The top-level statements from the first that matches $From up to, and not
    # including, the first after it that matches $Before.
    function script:Get-TopTextBefore
    {
        param([string]$From, [string]$Before)
        $F = -1; $B = -1
        for ($i = 0; $i -lt $script:Top.Count; $i++)
        {
            if ($F -lt 0 -and $script:Top[$i].Extent.Text -match $From) { $F = $i; continue }
            if ($F -ge 0 -and $script:Top[$i].Extent.Text -match $Before) { $B = $i; break }
        }
        if ($F -lt 0 -or $B -le $F) { throw "Top-level statements not found in Run-AllSubscriptions.ps1: $From .. $Before" }
        return (@($script:Top[$F..($B - 1)] | ForEach-Object { $_.Extent.Text }) -join "`n")
    }

    # Every metrics statement of the console summary: from the sign-in block to
    # the collector failures that follow it.
    $script:ConsoleText = Get-TopTextBefore '^\$MetricsFailures = ' '^\$CollectorFailuresList = '

    # The run-wide globals the code under test reads; this session's values go back in AfterAll.
    $script:TotalNames = @('MetricsFailedSubs', 'CollectorFailures', 'ConsumptionFailedSubs')
    $script:SessionValues = @{}
    foreach ($Name in $script:TotalNames)
    {
        $Existing = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
        $script:SessionValues[$Name] = if ($Existing) { @{ Value = $Existing.Value } } else { $null }
    }

    function script:Invoke-Block
    {
        param([string]$Text)
        @(. ([scriptblock]::Create($Text)) 6>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } })
    }

    $script:AuthMessage = 'Metrics phase skipped: no usable Azure context/token after one reconnect attempt.'
    $script:IncompleteTwo = 'Azure Monitor requests for 2 resource(s) still failed after their retries (throttling, timeout or server error); their metrics are recorded as errors.'
    $script:IncompleteOne = 'Azure Monitor requests for 1 resource(s) still failed after their retries (throttling, timeout or server error); their metrics are recorded as errors.'
    # One subscription skipped for the sign-in, two with incomplete metrics.
    $script:Mixed = @(
        [pscustomobject]@{ Name = 'sub-a'; Id = 'sub-a'; Message = $script:AuthMessage; ReportFolder = 'ResourcesReport_a' }
        [pscustomobject]@{ Name = 'sub-c'; Id = 'sub-c'; Message = $script:IncompleteOne; ReportFolder = 'ResourcesReport_c'; Complete = $false }
        [pscustomobject]@{ Name = 'sub-b'; Id = 'sub-b'; Message = $script:IncompleteTwo; ReportFolder = 'ResourcesReport_b'; Complete = $false }
    )
}

AfterAll {
    foreach ($Name in $script:TotalNames)
    {
        if ($null -ne $script:SessionValues[$Name]) { Set-Variable -Name $Name -Scope Global -Value $script:SessionValues[$Name].Value }
        else { Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue }
    }
}

Describe 'Run-AllSubscriptions.ps1 console summary: metrics incomplete apart from metrics auth-skipped' {

    It 'counts and lists the subscriptions with incomplete metrics apart from those skipped for the sign-in' {
        $Global:MetricsFailedSubs = $script:Mixed
        $Lines = Invoke-Block $script:ConsoleText
        $Text = $Lines -join "`n"

        $Text | Should -Match 'Metrics Auth Failures:\s+1 subscription\(s\)'
        $Text | Should -Match 'Metrics Incomplete:\s+2 subscription\(s\)'
        @($Lines | Where-Object { $_ -like '  - sub-a (sub-a)*' }) | Should -Be @('  - sub-a (sub-a)')
        @($Lines | Where-Object { $_ -like '  - sub-b (sub-b)*' -or $_ -like '  - sub-c (sub-c)*' }) | Should -Be @("  - sub-b (sub-b): $script:IncompleteTwo", "  - sub-c (sub-c): $script:IncompleteOne")
    }

    It 'prints only the incomplete count when no subscription was skipped for the sign-in' {
        $Global:MetricsFailedSubs = @($script:Mixed | Where-Object { $_.Id -ne 'sub-a' })
        $Lines = Invoke-Block $script:ConsoleText

        @($Lines | Where-Object { $_ -like 'Metrics Auth Failures*' }).Count | Should -Be 0
        @($Lines | Where-Object { $_ -match '^Metrics Incomplete:\s+2 subscription\(s\)$' }).Count | Should -Be 1
    }

    It 'prints no incomplete count when every entry is a sign-in skip' {
        $Global:MetricsFailedSubs = @($script:Mixed | Where-Object { $_.Id -eq 'sub-a' })
        $Lines = Invoke-Block $script:ConsoleText

        @($Lines | Where-Object { $_ -like 'Metrics Incomplete*' }).Count | Should -Be 0
        @($Lines | Where-Object { $_ -match '^Metrics Auth Failures:\s+1 subscription\(s\)' }).Count | Should -Be 1
    }
}

Describe 'RunSummary.log: metrics incomplete apart from metrics auth-skipped' {

    It 'gives each its own count and detail section' {
        $Lines = @(Get-RunSummaryLogContent -Visible 3 -Excluded 0 -Eligible 3 -Processed 3 -Skipped 0 -MetricsFailedSubs $script:Mixed)
        $Text = $Lines -join "`n"

        $Text | Should -Match '(?m)^  Metrics auth-skipped subs\s+:\s+1\s*$'
        $Text | Should -Match '(?m)^  Metrics incomplete subs\s+:\s+2\s*$'

        $AuthAt = [array]::IndexOf($Lines, 'Metrics auth-skipped subscriptions (detail):')
        $AuthAt | Should -BeGreaterOrEqual 0
        $Lines[$AuthAt + 1] | Should -Be "  - sub-a (sub-a): $script:AuthMessage"
        $Lines[$AuthAt + 2] | Should -Be ''

        $IncompleteAt = [array]::IndexOf($Lines, 'Metrics incomplete subscriptions (detail):')
        $IncompleteAt | Should -BeGreaterOrEqual 0
        @($Lines[($IncompleteAt + 1)..($IncompleteAt + 2)]) | Should -Be @("  - sub-b (sub-b): $script:IncompleteTwo", "  - sub-c (sub-c): $script:IncompleteOne")
    }

    It 'gives each its own count, without names, in an obfuscated run' {
        $Text = @(Get-RunSummaryLogContent -Obfuscated -Visible 3 -Excluded 0 -Eligible 3 -Processed 3 -Skipped 0 -MetricsFailedSubs $script:Mixed) -join "`n"

        $Text | Should -Match '(?m)^  Metrics auth-skipped subs\s+:\s+1\s*$'
        $Text | Should -Match '(?m)^  Metrics incomplete subs\s+:\s+2\s*$'
        $Text | Should -Not -Match 'sub-[abc]'
    }
}

Describe 'Diagnostics log: metrics incomplete apart from metrics auth-skipped' {

    It 'gives each its own count and lines' {
        $Global:MetricsFailedSubs = $script:Mixed
        $Global:CollectorFailures = @()
        $Global:ConsumptionFailedSubs = @()
        $DiagDir = Join-Path $TestDrive 'diagnostics'
        New-Item -ItemType Directory -Path $DiagDir -Force | Out-Null

        $DiagFile = Write-RdaShareableDiagnosticsLog -DefaultPath ($DiagDir + [IO.Path]::DirectorySeparatorChar) -ReportName 'ResourcesReport' -RunDateTime '20261102000000000' -Version '0.0.0' -PhaseTimings $null 6>$null
        $DiagFile | Should -Not -BeNullOrEmpty
        $Lines = @(Get-Content -LiteralPath $DiagFile)

        $AuthAt = [array]::IndexOf($Lines, 'Metrics auth-skipped subscriptions: 1')
        $AuthAt | Should -BeGreaterOrEqual 0
        $Lines[$AuthAt + 1] | Should -Be "  [sub sub-a] $script:AuthMessage"
        $Lines[$AuthAt + 2] | Should -Be ''

        $IncompleteAt = [array]::IndexOf($Lines, 'Metrics incomplete subscriptions: 2')
        $IncompleteAt | Should -BeGreaterOrEqual 0
        @($Lines[($IncompleteAt + 1)..($IncompleteAt + 2)]) | Should -Be @("  [sub sub-b] $script:IncompleteTwo", "  [sub sub-c] $script:IncompleteOne")
    }

    It 'counts only the entries of its own subscription when the run''s earlier subscriptions left theirs' {
        # Under -RunAllSubs each subscription's report is written in the same
        # session, after the earlier subscriptions added their entries.
        $Global:MetricsFailedSubs = @($script:Mixed) + @([pscustomobject]@{ Name = 'sub-b'; Id = 'SUB-B'; Message = $script:AuthMessage })
        $Global:CollectorFailures = @()
        $Global:ConsumptionFailedSubs = @()
        $DiagDir = Join-Path $TestDrive 'diagnostics-one-sub'
        New-Item -ItemType Directory -Path $DiagDir -Force | Out-Null

        $DiagFile = Write-RdaShareableDiagnosticsLog -DefaultPath ($DiagDir + [IO.Path]::DirectorySeparatorChar) -ReportName 'ResourcesReport' -RunDateTime '20261109000000000' -Version '0.0.0' -PhaseTimings $null -SubscriptionID 'sub-b' 6>$null
        $DiagFile | Should -Not -BeNullOrEmpty
        $Lines = @(Get-Content -LiteralPath $DiagFile)

        $AuthAt = [array]::IndexOf($Lines, 'Metrics auth-skipped subscriptions: 1')
        $AuthAt | Should -BeGreaterOrEqual 0
        $Lines[$AuthAt + 1] | Should -Be "  [sub SUB-B] $script:AuthMessage"
        $IncompleteAt = [array]::IndexOf($Lines, 'Metrics incomplete subscriptions: 1')
        $IncompleteAt | Should -BeGreaterOrEqual 0
        $Lines[$IncompleteAt + 1] | Should -Be "  [sub sub-b] $script:IncompleteTwo"
        $Lines[$IncompleteAt + 2] | Should -Be ''
    }

    It 'is given the subscription of the report by both calls in ResourceInventory.ps1' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Calls = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Write-RdaShareableDiagnosticsLog' }, $true))
        $Calls.Count | Should -Be 2
        foreach ($Call in $Calls) { $Call.Extent.Text | Should -Match '-SubscriptionID \$SubscriptionID(\s|$)' }
    }
}

Describe 'Main summary: metrics incomplete apart from metrics auth-skipped' {

    It 'shows each with its own banner, count and subscriptions' {
        $Run = Join-Path $TestDrive 'main-summary'
        New-Item -ItemType Directory -Path $Run -Force | Out-Null
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out -MetricsFailedSubs $script:Mixed | Out-Null
        $Html = Get-Content -LiteralPath $Out -Raw

        $Html | Should -Match '<b>Metrics auth-skipped: 1 subscription\(s\)\.</b>[^<]*: sub-a</div>'
        $Html | Should -Match '<b>Metrics incomplete: 2 subscription\(s\)\.</b>[^<]*: sub-b, sub-c</div>'
    }

    It 'shows each with its own banner and count, without names, under -Obfuscated' {
        $Run = Join-Path $TestDrive 'main-summary-obfuscated'
        New-Item -ItemType Directory -Path $Run -Force | Out-Null
        $Out = Join-Path $Run 'main.html'

        New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile $Out -Obfuscated -MetricsFailedSubs $script:Mixed | Out-Null
        $Html = Get-Content -LiteralPath $Out -Raw

        $Html | Should -Match '<b>Metrics auth-skipped: 1 subscription\(s\)\.</b>'
        $Html | Should -Match '<b>Metrics incomplete: 2 subscription\(s\)\.</b>'
        $Html | Should -Not -Match 'sub-[abc]'
    }
}
