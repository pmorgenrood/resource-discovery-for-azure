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
        $script:Lines | Should -Contain '  - sub-two (id-2)'
        $script:Lines | Should -Not -Contain '  - sub-one (id-1)'
        $script:Lines | Should -Contain '  cmd'
    }
}

Describe 'Exit codes for incomplete metrics' {
    It 'a direct run exits 3 after its zip only when metrics are incomplete, and never under -RunAllSubs' {
        $Ast = Get-ScriptAst -File 'ResourceInventory.ps1'
        $Exits = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.ExitStatementAst] -and $N.Pipeline.Extent.Text -eq '3' }, $true))
        $Exits.Count | Should -Be 1
        $Guards = @()
        $Node = $Exits[0].Parent
        while ($null -ne $Node) { if ($Node -is [System.Management.Automation.Language.IfStatementAst]) { $Guards += $Node.Clauses[0].Item1.Extent.Text }; $Node = $Node.Parent }
        $Guards | Should -Contain '$MetricsIncomplete.Count -gt 0'
        $Guards | Should -Contain '-not $RunAllSubs.IsPresent'
        # After the report zip is written.
        $Zip = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Compress-Archive' }, $true))
        $Zip[-1].Extent.StartOffset | Should -BeLessThan $Exits[0].Extent.StartOffset
    }

    It 'the wrapper passes incomplete metrics to its exit code and leaves them out of the sign-in banner' {
        $Text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Run-AllSubscriptions.ps1') -Raw
        $Text | Should -Match ([regex]::Escape('-MetricsIncomplete ($MetricsIncompleteEntries.Count -gt 0)'))
        $Text | Should -Match ([regex]::Escape("if (@(@(`$Global:MetricsFailedSubs) | Where-Object { `$null -ne `$_ -and -not (Test-MetricsIncompleteEntry -Entry `$_) }).Count -gt 0) { `$AuthSkippedPhases += 'Metrics' }"))
        $Text | Should -Not -Match ([regex]::Escape("if (@(`$Global:MetricsFailedSubs).Count -gt 0) { `$AuthSkippedPhases += 'Metrics' }"))
    }
}
