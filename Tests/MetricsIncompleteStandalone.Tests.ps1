#Requires -Modules Pester
# Each function library that reports metrics entries tells an incomplete entry
# (Complete = $false) from a sign-in skip on its own, without the helpers of
# Functions/Common.Functions.ps1. Each library is loaded alone in a fresh pwsh
# process, so no function from another file or test can be in scope.
#
# Run with: Invoke-Pester ./Tests/MetricsIncompleteStandalone.Tests.ps1 -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:PwshPath = (Get-Process -Id $PID).Path

    # Runs $Body in a fresh pwsh process after loading only $Library, with one
    # sign-in skip and one incomplete entry in $Entries. Returns its output lines.
    function script:Invoke-Alone
    {
        param([string]$Library, [string]$Body)

        $Script = Join-Path $TestDrive ('alone-' + [guid]::NewGuid().ToString() + '.ps1')
        $Prelude = @'
$ErrorActionPreference = 'Stop'
. '{0}'
$Entries = @(
    [pscustomobject]@{{ Name = 'sub-auth'; Id = 'id-auth'; Message = 'sign-in skip' }}
    [pscustomobject]@{{ Name = 'sub-gap'; Id = 'id-gap'; Message = 'still failed'; ReportFolder = 'ResourcesReport_gap'; Complete = $false }}
)
'@ -f ((Join-Path $script:RepoRoot $Library) -replace "'", "''")
        Set-Content -LiteralPath $Script -Encoding utf8 -Value ($Prelude + "`n" + $Body)
        $Output = & $script:PwshPath -NoProfile -NonInteractive -File $Script 2>&1
        return @($Output | ForEach-Object { [string]$_ })
    }
}

Describe 'Libraries that report metrics entries need no other file' {

    It 'RunAllSubscriptions.Functions.ps1 counts an incomplete entry apart in RunSummary.log' {
        $Lines = Invoke-Alone -Library 'Functions/RunAllSubscriptions.Functions.ps1' -Body @'
Get-RunSummaryLogContent -Visible 2 -Excluded 0 -Eligible 2 -Processed 2 -Skipped 0 -MetricsFailedSubs $Entries
'@
        $Text = $Lines -join "`n"
        $Text | Should -Match '(?m)^  Metrics auth-skipped subs\s+:\s+1\s*$'
        $Text | Should -Match '(?m)^  Metrics incomplete subs\s+:\s+1\s*$'
    }

    It 'AllSubHtmlSummary.Functions.ps1 shows an incomplete entry in its own banner' {
        $Out = Join-Path $TestDrive 'alone-main.html'
        $Lines = Invoke-Alone -Library 'Functions/AllSubHtmlSummary.Functions.ps1' -Body (@'
$Run = Split-Path -Parent '{0}'
New-RdaAllSubHtmlSummary -RunOutputDirectory $Run -HtmlFile '{0}' -MetricsFailedSubs $Entries | Out-Null
'DONE'
'@ -f ($Out -replace "'", "''"))
        $Lines | Should -Contain 'DONE'
        $Html = Get-Content -LiteralPath $Out -Raw
        $Html | Should -Match '<b>Metrics auth-skipped: 1 subscription\(s\)\.</b>[^<]*: sub-auth</div>'
        $Html | Should -Match '<b>Metrics incomplete: 1 subscription\(s\)\.</b>[^<]*: sub-gap</div>'
    }

    It 'ResourceInventory.Functions.ps1 counts an incomplete entry apart in the Diagnostics log' {
        $Dir = Join-Path $TestDrive 'alone-diagnostics'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        # Write-Log is the run's logger in Common.Functions.ps1; the stand-in
        # keeps only its error lines, so a failure shows in the output.
        $Lines = Invoke-Alone -Library 'Functions/ResourceInventory.Functions.ps1' -Body (@'
$Global:LogLines = [System.Collections.Generic.List[string]]::new()
function Write-Log {{ param([string]$Message, [string]$Severity) if ($Severity -ne 'Info') {{ $Global:LogLines.Add('LOG: ' + $Message) }} }}
$Global:MetricsFailedSubs = $Entries
$Global:CollectorFailures = @()
$Global:ConsumptionFailedSubs = @()
$File = Write-RdaShareableDiagnosticsLog -DefaultPath '{0}' -ReportName 'ResourcesReport' -RunDateTime '20261109000000000' -Version '0.0.0' -PhaseTimings $null
$Global:LogLines
'FILE=' + $File
'@ -f (($Dir + [IO.Path]::DirectorySeparatorChar) -replace "'", "''"))
        @($Lines | Where-Object { $_ -like 'LOG: *' }) -join "`n" | Should -BeNullOrEmpty
        $File = (@($Lines | Where-Object { $_ -like 'FILE=*' }) | Select-Object -Last 1) -replace '^FILE=', ''
        $File | Should -Not -BeNullOrEmpty
        $Diag = @(Get-Content -LiteralPath $File)
        $Diag | Should -Contain 'Metrics auth-skipped subscriptions: 1'
        $Diag | Should -Contain 'Metrics incomplete subscriptions: 1'
    }
}
