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
    . (Join-Path $RepoRoot 'Functions/AllSubHtmlSummary.Functions.ps1')
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

    It 'counts only the subscriptions of the slice that are not completed, when the slice is known, and at least one' {
        $Slices = @(
            [System.Collections.Generic.List[object]]@([pscustomobject]@{ Id = 'sub-a'; Name = 'A' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'B' }, [pscustomobject]@{ Id = 'sub-c'; Name = 'C' }),
            [System.Collections.Generic.List[object]]@([pscustomobject]@{ Id = 'sub-d'; Name = 'D' }))
        # Stream 0 finished A (its state file says so) and stopped before B and C.
        Get-FailedSubscriptionCount -FailedSubscriptions @('stream-0 (no summary)') -StreamSummaries $script:Streams -Slices $Slices -CompletedIds @('sub-a') | Should -Be 2
        Get-FailedSubscriptionCount -FailedSubscriptions @('stream-1 (corrupt summary)') -StreamSummaries $script:Streams -Slices $Slices -CompletedIds @('sub-d') | Should -Be 1
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
        $script:WrapperText | Should -Match ([regex]::Escape('-FailedSubscriptionCount (Get-FailedSubscriptionCount -FailedSubscriptions $FailedSubscriptions -StreamSummaries $StreamSummaries -Slices $Slices -CompletedIds $AllCompletedFromStreams)'))
        $script:WrapperText | Should -Match ([regex]::Escape('Write-Host ("Subscriptions Failed:    {0} ({1})" -f (Get-FailedSubscriptionCount -FailedSubscriptions $FailedSubscriptions -StreamSummaries $StreamSummaries -Slices $Slices -CompletedIds $AllCompletedFromStreams)'))
    }

    It 'the wrapper sets the stream lists before the sequential and parallel paths split, so a sequential run reads them under strict mode' {
        $Ast = [System.Management.Automation.Language.Parser]::ParseInput($script:WrapperText, [ref]$null, [ref]$null)
        $Top = @($Ast.EndBlock.Statements)
        $Split = @(0..($Top.Count - 1) | Where-Object { $Top[$_] -is [System.Management.Automation.Language.IfStatementAst] -and $Top[$_].Clauses[0].Item1.Extent.Text -eq '$ParallelStreams -le 1' })
        $Split.Count | Should -Be 1
        foreach ($Name in @('StreamSummaries', 'Slices', 'AllCompletedFromStreams'))
        {
            $Set = @(0..($Split[0] - 1) | Where-Object { $Top[$_].Extent.Text -eq ('${0} = @()' -f $Name) })
            $Set.Count | Should -Be 1 -Because ('${0} must be set before the split' -f $Name)
        }
    }
}

Describe 'MainSummary.html counts subscriptions, not entries' {
    It 'gets one entry per unfinished subscription of a dead stream, as many as Get-FailedSubscriptionCount counts' {
        $Slices = @(
            [System.Collections.Generic.List[object]]@([pscustomobject]@{ Id = 'sub-a'; Name = 'A' }, [pscustomobject]@{ Id = 'sub-b'; Name = 'B' }, [pscustomobject]@{ Id = 'sub-c'; Name = 'C' }),
            [System.Collections.Generic.List[object]]@([pscustomobject]@{ Id = 'sub-d'; Name = 'D' }))
        $Failed = @('stream-0 (no summary)', 'stream-1 (corrupt summary)', 'E (sub-e)')
        $Out = @(Expand-FailedSubscriptionEntries -FailedSubscriptions $Failed -Slices $Slices -CompletedIds @('sub-a', 'sub-d'))
        $Out | Should -Be @('B (sub-b) (stream-0 (no summary))', 'C (sub-c) (stream-0 (no summary))', 'stream-1 (corrupt summary)', 'E (sub-e)')
        $Out.Count | Should -Be (Get-FailedSubscriptionCount -FailedSubscriptions $Failed -Slices $Slices -CompletedIds @('sub-a', 'sub-d'))
        @(Expand-FailedSubscriptionEntries -FailedSubscriptions @('stream-0 (no summary)') -Slices @()) | Should -Be @('stream-0 (no summary)')
    }

    It 'the wrapper gives MainSummary.html that list, on the same completions' {
        $script:WrapperText | Should -Match ([regex]::Escape('-FailedSubscriptions @(Expand-FailedSubscriptionEntries -FailedSubscriptions $FailedSubscriptions -Slices $Slices -CompletedIds $AllCompletedFromStreams) `'))
    }
}

Describe 'RunSummary.log records retry entries left out of the run' {
    It 'counts them, names them in a plain run, and only counts them in an obfuscated one' {
        $Left = @([pscustomobject]@{ Id = 'sub-off'; Name = 'Sub Off'; Attempts = 1; Reason = 'stand-in' })
        $Plain = @(Get-RunSummaryLogContent -Visible 2 -Eligible 1 -Processed 1 -NotInRun $Left)
        $Plain | Should -Contain "  Not in this run     : 1 (on the retry list, but not in this run's subscription set; incomplete)"
        $Plain | Should -Contain '  - Sub Off (sub-off): failed 1 run(s); last reason: stand-in'
        $Masked = @(Get-RunSummaryLogContent -Visible 2 -Eligible 1 -Processed 1 -NotInRun $Left -Obfuscated)
        $Masked | Should -Contain "  Not in this run     : 1 (on the retry list, but not in this run's subscription set; incomplete)"
        @($Masked | Where-Object { $_ -like '*Sub Off*' -or $_ -like '*sub-off*' }) | Should -BeNullOrEmpty
    }

    It 'the wrapper passes the entries it names under Not In This Run' {
        $script:WrapperText | Should -Match ([regex]::Escape('-NotInRun $RetryOwedNotInRun `'))
    }
}
