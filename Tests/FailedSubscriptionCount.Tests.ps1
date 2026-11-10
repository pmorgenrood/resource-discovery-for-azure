# Run-AllSubscriptions.ps1: how many subscriptions the end-of-run failure list
# stands for. A 'stream-N (no summary)' or 'stream-N (corrupt summary)' entry
# is a whole stream, so it counts the subscriptions of that stream's slice; the
# console line "Subscriptions Failed" and RunSummary.log both use that count.
#
# Offline; placeholder names only.
#
# Run with: Invoke-Pester ./Tests/FailedSubscriptionCount.Tests.ps1 -Output Detailed

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1')
    $script:WrapperText = Get-Content -LiteralPath (Join-Path $RepoRoot 'Run-AllSubscriptions.ps1') -Raw
    $script:Streams = @(
        [pscustomobject]@{ StreamId = 0; SummaryPath = 'x'; FailuresPath = 'y'; SubCount = 3 },
        [pscustomobject]@{ StreamId = 1; SummaryPath = 'x'; FailuresPath = 'y'; SubCount = 2 })
}

Describe 'Get-FailedSubscriptionCount' {
    It 'counts a stream with no summary, or a corrupt one, as the subscriptions of its slice' {
        Get-FailedSubscriptionCount -FailedSubscriptions @('stream-0 (no summary)') -StreamSummaries $script:Streams | Should -Be 3
        Get-FailedSubscriptionCount -FailedSubscriptions @('stream-1 (corrupt summary)') -StreamSummaries $script:Streams | Should -Be 2
    }

    It 'counts every other entry as one subscription' {
        $Failed = @('Sub A (sub-a)', 'Sub B (sub-b) (stream-1: stand-in)', 'stream-0 (no summary)', [pscustomobject]@{ Name = 'Sub C'; Id = 'sub-c' })
        Get-FailedSubscriptionCount -FailedSubscriptions $Failed -StreamSummaries $script:Streams | Should -Be 6
    }

    It 'counts a stream marker as one when its stream is not known (a sequential run has none)' {
        Get-FailedSubscriptionCount -FailedSubscriptions @('stream-7 (no summary)') -StreamSummaries $null | Should -Be 1
        Get-FailedSubscriptionCount -FailedSubscriptions @() -StreamSummaries $script:Streams | Should -Be 0
    }
}

Describe 'RunSummary.log and the console line count subscriptions, not entries' {
    It 'RunSummary.log takes the count given, with the entries still named' {
        $Lines = @(Get-RunSummaryLogContent -Visible 5 -Eligible 5 -Processed 5 -FailedSubscriptions @('stream-0 (no summary)') -FailedSubscriptionCount 3)
        $Lines | Should -Contain '  Failed    : 3'
        $Lines | Should -Contain '  Failed subscriptions          : 3'
        $Lines | Should -Contain '  - stream-0 (no summary)'
    }

    It 'RunSummary.log counts one per entry when no count is given' {
        $Lines = @(Get-RunSummaryLogContent -Visible 2 -Eligible 2 -Processed 2 -FailedSubscriptions @('Sub A (sub-a)', 'Sub B (sub-b)'))
        $Lines | Should -Contain '  Failed    : 2'
    }

    It 'the wrapper passes the count to RunSummary.log and prints it on the console line' {
        $script:WrapperText | Should -Match ([regex]::Escape('-FailedSubscriptionCount (Get-FailedSubscriptionCount -FailedSubscriptions $FailedSubscriptions -StreamSummaries $StreamSummaries)'))
        $script:WrapperText | Should -Match ([regex]::Escape('Write-Host ("Subscriptions Failed:    {0} ({1})" -f (Get-FailedSubscriptionCount -FailedSubscriptions $FailedSubscriptions -StreamSummaries $StreamSummaries)'))
    }
}
