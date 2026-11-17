# Run-AllSubscriptions.ps1: the consolidated zip
#
# The wrapper ends by putting every per-subscription report zip of the run into
# AllSubscriptions_ResourcesReport_<timestamp>.zip, then adds RunSummary.log and
# MainSummary.html to it. When either write fails (a full disk, or a report zip
# another process holds open), Compress-Archive removes the zip. These tests check
# that the run then says so, does not print the zip's path as written, and ends
# with exit code 2, and that the path is printed only after the last check.
#
# The report zip check, the bundling block, the fold block, the check after it,
# the banner and the exit-code statements are taken from the wrapper's parsed source and run as written. The wrapper itself
# cannot run here (it needs a signed-in Azure session). Compress-Archive is real,
# except where a test says it is mocked.
#
# Run with: Invoke-Pester ./Tests/ConsolidatedZipBuild.Tests.ps1 -Output Detailed

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:FunctionsPath = Join-Path $RepoRoot 'Functions/RunAllSubscriptions.Functions.ps1'
    # Get-RunSummaryLogContent, which the fold block calls, uses the metrics
    # helpers of Functions/Common.Functions.ps1; the wrapper loads both files.
    . (Join-Path $RepoRoot 'Functions/Common.Functions.ps1')
    . $script:FunctionsPath
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $Tokens = $null
    $ParseErrors = $null
    $script:WrapperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'Run-AllSubscriptions.ps1'), [ref]$Tokens, [ref]$ParseErrors)

    # The operands of a condition joined by -or, read from its syntax tree, each as its
    # text: 'a -or b -or c' gives a, b, c; a condition with no -or gives itself.
    function script:Get-OrOperandText
    {
        param($Ast)
        if ($Ast -is [System.Management.Automation.Language.PipelineAst] -and $Ast.PipelineElements.Count -eq 1 -and $Ast.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst])
        {
            $Ast = $Ast.PipelineElements[0].Expression
        }
        if ($Ast -is [System.Management.Automation.Language.BinaryExpressionAst] -and $Ast.Operator -eq [System.Management.Automation.Language.TokenKind]::Or)
        {
            @(script:Get-OrOperandText $Ast.Left) + @(script:Get-OrOperandText $Ast.Right)
        }
        else { $Ast.Extent.Text }
    }

    # The one top-level 'if (<Condition>)' statement of the wrapper whose text contains $Contains.
    # The condition is compared by its syntax tree: its -or operands, in order, are those of
    # $Condition, so a condition with more or fewer operands is a different statement.
    function script:Find-WrapperIf
    {
        param([string]$Condition, [string]$Contains)
        $Want = @(script:Get-OrOperandText ([System.Management.Automation.Language.Parser]::ParseInput($Condition, [ref]$null, [ref]$null).EndBlock.Statements[0])) -join "`n"
        $Found = @($script:WrapperAst.EndBlock.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.IfStatementAst] -and
                (@(script:Get-OrOperandText $_.Clauses[0].Item1) -join "`n") -eq $Want -and
                $_.Extent.Text.Contains($Contains)
            })
        if ($Found.Count -ne 1)
        {
            throw ("expected exactly one top-level 'if ({0})' containing '{1}' in Run-AllSubscriptions.ps1, found {2}" -f $Condition, $Contains, $Found.Count)
        }
        $Found[0]
    }

    # One per-subscription report folder with its zip, the way ResourceInventory.ps1 leaves it.
    function script:New-SubReport
    {
        param([string]$Root, [string]$Stamp)
        $Dir = Join-Path $Root ('ResourcesReport' + $Stamp)
        $null = New-Item -ItemType Directory -Path $Dir -Force
        $Json = Join-Path $Dir ('Inventory_ResourcesReport_' + $Stamp + '.json')
        Set-Content -LiteralPath $Json -Value '{"resources":[]}'
        $Zip = Join-Path $Dir ('ResourcesReport_' + $Stamp + '.zip')
        Compress-Archive -LiteralPath $Json -DestinationPath $Zip -Force
        $Zip
    }

    function script:Get-ZipEntryNames
    {
        param([string]$Path)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { @($Archive.Entries | ForEach-Object { $_.FullName }) } finally { $Archive.Dispose() }
    }

    function script:ConvertTo-Lines
    {
        process { if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }
    }
}

Describe 'Get-ConsolidatedZipProblem' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'check'
        $null = New-Item -ItemType Directory -Path $script:Root -Force
        $script:SubA = New-SubReport -Root $script:Root -Stamp 'A1'
        $script:SubB = New-SubReport -Root $script:Root -Stamp 'B1'
        $script:Both = Join-Path $script:Root 'both.zip'
        Compress-Archive -LiteralPath $script:SubA, $script:SubB -DestinationPath $script:Both -Force
        $script:OnlyA = Join-Path $script:Root 'only-a.zip'
        Compress-Archive -LiteralPath $script:SubA -DestinationPath $script:OnlyA -Force
        $script:Names = @((Split-Path $script:SubA -Leaf), (Split-Path $script:SubB -Leaf))
    }

    It 'returns nothing for a zip that holds every per-subscription zip' {
        Get-ConsolidatedZipProblem -Path $script:Both -SubZipNames $script:Names | Should -BeNullOrEmpty
    }

    It 'says the zip is not on disk when it is missing' {
        Get-ConsolidatedZipProblem -Path (Join-Path $script:Root 'gone.zip') -SubZipNames $script:Names | Should -Be 'the zip is not on disk.'
        Get-ConsolidatedZipProblem -Path '' -SubZipNames $script:Names | Should -Be 'the zip is not on disk.'
    }

    It 'says the zip cannot be read when the file is not a zip' {
        $NotZip = Join-Path $script:Root 'truncated.zip'
        Set-Content -LiteralPath $NotZip -Value 'PK not a zip'
        Get-ConsolidatedZipProblem -Path $NotZip -SubZipNames $script:Names | Should -BeLike 'the zip cannot be read: *'
    }

    It 'counts the per-subscription zips that are not in it' {
        Get-ConsolidatedZipProblem -Path $script:OnlyA -SubZipNames $script:Names | Should -Be '1 of the 2 per-subscription zip(s) are not in it.'
    }
}

Describe 'Run-AllSubscriptions.ps1: building the consolidated zip' {
    BeforeAll {
        $script:BundleBlock = [scriptblock]::Create((Find-WrapperIf -Condition 'Test-Path -LiteralPath $InventoryRoot -PathType Container' -Contains 'AllSubscriptions_ResourcesReport_').Extent.Text)

        # Runs the lifted bundling block over $Root with the variables it reads.
        $script:LastCheckBlock = [scriptblock]::Create((Find-WrapperIf -Condition '$null -ne $OuterZipFile' -Contains 'was lost while the run summary was added').Extent.Text)
        function script:Invoke-BundleBlock
        {
            param([string]$Root, [switch]$NoLastCheck)
            # Set-Variable: these are read only by the lifted block.
            Set-Variable -Name InventoryRoot -Value $Root
            Set-Variable -Name RunStartTime -Value ((Get-Date).AddMinutes(-5))
            # This run's own report records: every report zip the test wrote.
            Set-Variable -Name RunReports -Value @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'ResourcesReport_*.zip' -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Id = $_.BaseName; Name = $_.BaseName; Zip = [System.IO.Path]::GetRelativePath($Root, $_.FullName); Obfuscated = $false } })
            # This run's success rows: one per report zip the test wrote, with its
            # path, as the output check reads them (#66 builds only those).
            Set-Variable -Name SubResourceCounts -Value @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'ResourcesReport_*.zip' -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Id = $_.BaseName; Name = $_.BaseName; Count = 1; Zip = $_.FullName } })
            Set-Variable -Name UnreadableStreamSummaries -Value @()
            $OuterZipFile = $null
            $BundleBuildError = $null
            $Printed = @(. $script:BundleBlock 6>&1 | ConvertTo-Lines)
            $Built = $OuterZipFile
            # The last check, where the zip takes the name a run ships.
            if (-not $NoLastCheck) { $Printed += @(. $script:LastCheckBlock 6>&1 | ConvertTo-Lines) }
            [pscustomobject]@{ OuterZipFile = $OuterZipFile; Built = $Built; BundleBuildError = $BundleBuildError; Printed = $Printed; SubZips = $SubZips }
        }
    }

    It 'a consolidated zip of another run with the same second''s name is never written over: this run takes the next free name' {
        $Root = Join-Path $TestDrive 'same-second'
        $null = New-SubReport -Root $Root -Stamp 'X1'
        # What Get-Date -Format returns: the formatted text.
        Mock Get-Date { '2026-11-02_15-04-05' } -ParameterFilter { $Format -eq 'yyyy-MM-dd_HH-mm-ss' }
        $Other = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-11-02_15-04-05.zip'
        Set-Content -LiteralPath $Other -Value 'another run' -NoNewline
        $R = Invoke-BundleBlock -Root $Root
        $R.BundleBuildError | Should -BeNullOrEmpty
        $R.OuterZipFile | Should -Be (Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-11-02_15-04-05-2.zip')
        Get-Content -LiteralPath $Other -Raw | Should -Be 'another run'
        (Get-ZipEntryNames -Path $R.OuterZipFile) | Should -Be @('ResourcesReport_X1.zip')
    }

    It 'nothing is under the name a run ships while the zip is built: the zip is written under a name of its own in the folder, then moved to it, and that file is not left' {
        $Root = Join-Path $TestDrive 'reserved-kept'
        $null = New-SubReport -Root $Root -Stamp 'R1'
        $null = New-SubReport -Root $Root -Stamp 'R2'
        Mock Get-Date { '2026-11-02_15-04-05' } -ParameterFilter { $Format -eq 'yyyy-MM-dd_HH-mm-ss' }
        $script:ReservedName = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-11-02_15-04-05.zip'
        $script:Builds = @()
        # Notes where it writes and whether the name taken is still there, then
        # writes a zip of every report given to a new file there.
        Mock Compress-Archive -ParameterFilter { -not $Update } {
            $script:Builds += [pscustomobject]@{ Destination = $DestinationPath; ReservedThere = (Test-Path -LiteralPath $script:ReservedName -PathType Leaf) }
            $Zip = [System.IO.Compression.ZipFile]::Open($DestinationPath, 'Create')
            try { foreach ($Report in @($Path) + @($LiteralPath) | Where-Object { $_ }) { $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Zip, $Report, (Split-Path $Report -Leaf)) } } finally { $Zip.Dispose() }
        }
        $R = Invoke-BundleBlock -Root $Root

        $script:Builds.Count | Should -Be 1
        # A run stopped here leaves nothing under the shipped name.
        $script:Builds[0].ReservedThere | Should -BeFalse
        $script:Builds[0].Destination | Should -Not -Be $script:ReservedName
        Split-Path $script:Builds[0].Destination -Parent | Should -Be $Root
        Split-Path $script:Builds[0].Destination -Leaf | Should -Not -BeLike '*.zip'
        $R.BundleBuildError | Should -BeNullOrEmpty
        $R.OuterZipFile | Should -Be $script:ReservedName
        (Get-ZipEntryNames -Path $R.OuterZipFile | Sort-Object) | Should -Be @('ResourcesReport_R1.zip', 'ResourcesReport_R2.zip')
        @(Get-ChildItem -LiteralPath $Root -File -Force | ForEach-Object { $_.Name }) | Should -Be @('AllSubscriptions_ResourcesReport_2026-11-02_15-04-05.zip')
    }

    It 'a build that fails part-way leaves no file in the folder: neither the part written nor a file under the shipped name' {
        $Root = Join-Path $TestDrive 'part-written'
        $null = New-SubReport -Root $Root -Stamp 'P1'
        Mock Compress-Archive -ParameterFilter { -not $Update } {
            Set-Content -LiteralPath $DestinationPath -Value 'PK part' -NoNewline
            throw [System.IO.IOException]::new('No space left on device')
        }
        $R = Invoke-BundleBlock -Root $Root

        $R.BundleBuildError | Should -BeLike '*: No space left on device'
        $R.OuterZipFile | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $Root -File -Force | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }

    It 'a report zip the output check found that is gone by the build means no consolidated zip and exit 2, not a zip without it' {
        $Root = Join-Path $TestDrive 'gone-between'
        $Kept = New-SubReport -Root $Root -Stamp 'G1'
        $Gone = New-SubReport -Root $Root -Stamp 'G2'
        # What the output check found: both zips. One is quarantined before the build.
        $ActualSubZips = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.zip' -File)
        $ActualSubZips.Count | Should -Be 2
        $null = $ActualSubZips, $Kept
        Remove-Item -LiteralPath $Gone -Force
        $R = Invoke-BundleBlock -Root $Root
        $R.BundleBuildError | Should -BeLike ('*1 report zip(s) found by the output check are gone now: {0}*' -f $Gone)
        # A -Resume run skips the subscriptions this run completed, so it would not collect them.
        $R.BundleBuildError | Should -BeLike '*Run again without -Resume or -ResumeFailedOnly*'
        $R.OuterZipFile | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object { $_.Name -like 'AllSubscriptions_*' -or $_.Name -like 'rda-build-*' }) | Should -BeNullOrEmpty
        # Every zip gone: no consolidated zip, and the run says so with exit 2 too.
        Remove-Item -LiteralPath $Kept -Force
        $R2 = Invoke-BundleBlock -Root $Root
        $R2.BundleBuildError | Should -BeLike '*report zip(s) found by the output check are all gone now*'
        $R2.BundleBuildError | Should -BeLike '*Run again without -Resume or -ResumeFailedOnly*'
    }

    It 'the list of zips the output check found is set before that check, so the build can read it when the check does not run' {
        $CheckIf = Find-WrapperIf -Condition '$ExpectedZipCount -gt 0' -Contains '$ActualSubZips'
        $Init = @($script:WrapperAst.EndBlock.Statements | Where-Object { $_.Extent.Text -eq '$ActualSubZips = @()' })
        $Init.Count | Should -Be 1
        $Init[0].Extent.StartOffset | Should -BeLessThan $CheckIf.Extent.StartOffset
    }

    It 'a build that fails part-way and whose part cannot be removed names it: delete it, do not share it' {
        $Root = Join-Path $TestDrive 'part-kept'
        $null = New-SubReport -Root $Root -Stamp 'K1'
        Mock Compress-Archive -ParameterFilter { -not $Update } {
            Set-Content -LiteralPath $DestinationPath -Value 'PK part' -NoNewline
            throw [System.IO.IOException]::new('No space left on device')
        }
        Mock Remove-Item -ParameterFilter { $LiteralPath -like '*rda-build-*.partial' } { }
        $R = Invoke-BundleBlock -Root $Root

        $Left = @(Get-ChildItem -LiteralPath $Root -File -Force -Filter 'rda-build-*.partial')
        $Left.Count | Should -Be 1
        $R.BundleBuildError | Should -BeLike ('*: No space left on device {0} could not be removed: delete it, do not share it.' -f $Left[0].FullName)
        $R.OuterZipFile | Should -BeNullOrEmpty
    }

    It 'a written zip that cannot be read fails the check before it takes its name: no file is left under the name or the name it was written to' {
        $Root = Join-Path $TestDrive 'unreadable'
        $null = New-SubReport -Root $Root -Stamp 'U1'
        # Writes bytes that are not a zip, without an error.
        Mock Compress-Archive -ParameterFilter { -not $Update } { Set-Content -LiteralPath $DestinationPath -Value 'not a zip' -NoNewline }
        $R = Invoke-BundleBlock -Root $Root

        $R.BundleBuildError | Should -BeLike '*: the zip cannot be read: *'
        $R.OuterZipFile | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' }).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object { $_.Name -like 'AllSubscriptions_*.zip' -or $_.Name -like 'rda-build-*.partial' }) | Should -BeNullOrEmpty
    }

    It 'a consolidated zip that cannot be built leaves no file under the shipped name' {
        $Root = Join-Path $TestDrive 'reserved-failed'
        $null = New-SubReport -Root $Root -Stamp 'F9'
        Mock Compress-Archive { throw [System.IO.IOException]::new('No space left on device') } -ParameterFilter { -not $Update }
        $R = Invoke-BundleBlock -Root $Root
        $R.BundleBuildError | Should -Not -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $Root -Filter 'AllSubscriptions_ResourcesReport_*.zip' -File) | Should -BeNullOrEmpty
    }

    It 'a consolidated zip of another run with the same second''s name is never written over: this run takes the next free name' {
        $Root = Join-Path $TestDrive 'same-second-carry'
        $null = New-SubReport -Root $Root -Stamp 'X1'
        # What Get-Date -Format returns: the formatted text.
        Mock Get-Date { '2026-11-02_15-04-05' } -ParameterFilter { $Format -eq 'yyyy-MM-dd_HH-mm-ss' }
        $Other = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-11-02_15-04-05.zip'
        Set-Content -LiteralPath $Other -Value 'another run' -NoNewline
        $R = Invoke-BundleBlock -Root $Root
        $R.BundleBuildError | Should -BeNullOrEmpty
        $R.OuterZipFile | Should -Be (Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-11-02_15-04-05-2.zip')
        Get-Content -LiteralPath $Other -Raw | Should -Be 'another run'
        (Get-ZipEntryNames -Path $R.OuterZipFile) | Should -Be @('ResourcesReport_X1.zip')
    }

    It 'a build that fails part-way leaves no file in the folder: neither the part written nor the name it took' {
        $Root = Join-Path $TestDrive 'part-written'
        $null = New-SubReport -Root $Root -Stamp 'P1'
        Mock Compress-Archive -ParameterFilter { -not $Update } {
            Set-Content -LiteralPath $DestinationPath -Value 'PK part' -NoNewline
            throw [System.IO.IOException]::new('No space left on device')
        }
        $R = Invoke-BundleBlock -Root $Root

        $R.BundleBuildError | Should -BeLike '*: No space left on device'
        $R.OuterZipFile | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $Root -File -Force | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }

    It 'a consolidated zip that cannot be built leaves no empty file under the name it took' {
        $Root = Join-Path $TestDrive 'reserved-failed'
        $null = New-SubReport -Root $Root -Stamp 'F9'
        Mock Compress-Archive { throw [System.IO.IOException]::new('No space left on device') } -ParameterFilter { -not $Update }
        $R = Invoke-BundleBlock -Root $Root
        $R.BundleBuildError | Should -Not -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $Root -Filter 'AllSubscriptions_ResourcesReport_*.zip' -File) | Should -BeNullOrEmpty
    }

    It 'a report zip held open by another process: the error names it, no zip is reported as written' {
        $Root = Join-Path $TestDrive 'locked'
        $null = New-SubReport -Root $Root -Stamp 'L1'
        $Held = New-SubReport -Root $Root -Stamp 'L2'
        $Lock = [System.IO.File]::Open($Held, 'Open', 'ReadWrite', 'None')
        try { $R = Invoke-BundleBlock -Root $Root } finally { $Lock.Dispose() }

        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' }).Count | Should -Be 0
        @($R.Printed | Where-Object { $_ -like 'ERROR: Could not build the consolidated zip in *: *' }).Count | Should -Be 1
        $R.BundleBuildError | Should -BeLike ('*{0}*' -f (Split-Path $Held -Leaf))
        $R.OuterZipFile | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $Root -Filter 'AllSubscriptions_ResourcesReport_*.zip').Count | Should -Be 0
    }

    It 'a write that finishes without error but leaves a report out is a failure too' {
        $Root = Join-Path $TestDrive 'short'
        $null = New-SubReport -Root $Root -Stamp 'X1'
        $null = New-SubReport -Root $Root -Stamp 'X2'
        # Writes a real zip that holds only the first report.
        Mock Compress-Archive {
            $Zip = [System.IO.Compression.ZipFile]::Open($DestinationPath, 'Create')
            try { $null = $Zip.CreateEntry((Split-Path @(@($Path) + @($LiteralPath) | Where-Object { $_ })[0] -Leaf)) } finally { $Zip.Dispose() }
        }
        $R = Invoke-BundleBlock -Root $Root

        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' }).Count | Should -Be 0
        $R.BundleBuildError | Should -BeLike '*: 1 of the 2 per-subscription zip(s) are not in it.'
        $R.OuterZipFile | Should -BeNullOrEmpty
        # Neither the zip that failed the check nor the file it was written to is left.
        @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object { $_.Name -like 'AllSubscriptions_*.zip' -or $_.Name -like 'rda-build-*.partial' }) | Should -BeNullOrEmpty
    }

    It 'names a consolidated zip a stopped run left under its private name, and leaves it in place' {
        # The README says when: on the next run that builds a consolidated zip.
        (Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'README.md') -Raw).Contains('The next run in the folder that builds a consolidated zip names each one it finds in a warning') | Should -BeTrue
        $Root = Join-Path $TestDrive 'left-by-a-stop'
        $null = New-SubReport -Root $Root -Stamp 'S1'
        $Left = Join-Path $Root 'rda-build-0123456789abcdef0123456789abcdef.partial'
        Set-Content -LiteralPath $Left -Value 'PK' -NoNewline
        (Get-Item -LiteralPath $Left).LastWriteTime = (Get-Date).AddHours(-1)
        $R = Invoke-BundleBlock -Root $Root

        @($R.Printed | Where-Object { $_ -eq ('WARNING: {0} is a consolidated zip an earlier run did not finish. It may be incomplete or unchecked, and it holds copies of that run''s reports (with real names unless that run used -Obfuscate). Delete it; do not share it. Only if that run said it kept this file after its checks, rename it to a .zip name to use it.' -f $Left) }).Count | Should -Be 1
        Test-Path -LiteralPath $Left | Should -BeTrue
        $R.BundleBuildError | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'WARNING: *rda-build-*' }).Count | Should -Be 1 -Because 'this run''s own private zip is not named'
    }

    It 'a zip that is built holds every report, and its path and its name wait for the last check' {
        $Root = Join-Path $TestDrive 'good'
        $null = New-SubReport -Root $Root -Stamp 'K1'
        $null = New-SubReport -Root $Root -Stamp 'K2'
        $R = Invoke-BundleBlock -Root $Root -NoLastCheck

        $R.BundleBuildError | Should -BeNullOrEmpty
        # Still under its private name: nothing under the shipped name yet.
        $R.OuterZipFile | Should -BeLike (Join-Path $Root 'rda-build-*.partial')
        @(Get-ChildItem -LiteralPath $Root -Filter 'AllSubscriptions_ResourcesReport_*.zip' -File) | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' -or $_ -like 'Consolidated Report:*' }).Count | Should -Be 0
        (Get-ZipEntryNames -Path $R.OuterZipFile | Sort-Object) | Should -Be (@($R.SubZips.Name) | Sort-Object)
    }
}

Describe 'Run-AllSubscriptions.ps1: adding the run summary to the consolidated zip' {
    BeforeAll {
        $script:FoldBlock = [scriptblock]::Create((Find-WrapperIf -Condition '$null -ne $OuterZipFile -and (Test-Path -LiteralPath $OuterZipFile)' -Contains 'Bundle finalized').Extent.Text)
        $script:FinalCheckIf = Find-WrapperIf -Condition '$null -ne $OuterZipFile' -Contains 'was lost while the run summary was added'
        $script:FinalCheckBlock = [scriptblock]::Create($script:FinalCheckIf.Extent.Text)

        # A built consolidated zip in $Root, then the lifted fold block and the check after it.
        function script:Invoke-FoldBlock
        {
            param([string]$Root, [switch]$GoneBeforeFold)
            $SubZips = @((New-SubReport -Root $Root -Stamp 'F1'), (New-SubReport -Root $Root -Stamp 'F2') | ForEach-Object { Get-Item -LiteralPath $_ })
            $OuterZipFile = Join-Path $Root 'rda-build-fold.partial'
            Microsoft.PowerShell.Archive\Compress-Archive -LiteralPath $SubZips.FullName -DestinationPath $OuterZipFile -Force
            Set-Variable -Name OuterZipStem -Value 'AllSubscriptions_ResourcesReport_2026-01-01_00-00-00'
            if ($GoneBeforeFold) { Remove-Item -LiteralPath $OuterZipFile -Force }
            # Set-Variable: these are read only by the lifted blocks.
            Set-Variable -Name InventoryRoot -Value $Root
            Set-Variable -Name RunStartTime -Value ((Get-Date).AddMinutes(-5))
            Set-Variable -Name MainSummaryFile -Value $null
            Set-Variable -Name FailedSubscriptions -Value @()
            $BundleBuildError = $null
            $Printed = @(. { . $script:FoldBlock; . $script:FinalCheckBlock } 6>&1 | ConvertTo-Lines)
            # Path: the name the zip ships under after the last check (a failed check sets OuterZipFile back to $null).
            [pscustomobject]@{ Path = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-01_00-00-00.zip'; OuterZipFile = $OuterZipFile; BundleBuildError = $BundleBuildError; Printed = $Printed }
        }

        function script:Get-PathLines
        {
            param($R)
            @($R.Printed | Where-Object { $_ -eq ('Reporting Data File: {0}' -f $R.Path) -or $_ -eq ('Consolidated Report:     {0}' -f $R.Path) })
        }

        # The consolidated zips and the files they are written to, left in $Root.
        function script:Get-BundleFiles
        {
            param([string]$Root)
            @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object { $_.Name -like 'AllSubscriptions_*.zip' -or $_.Name -like 'rda-build-*.partial' } | ForEach-Object { $_.Name })
        }
    }

    It 'a fold that fails leaves no staging folder behind' {
        Mock Add-ItemsToZipArchive { throw [System.IO.IOException]::new('No space left on device') }
        $Root = Join-Path $TestDrive 'fold-stage'
        $null = Invoke-FoldBlock -Root $Root
        @(Get-ChildItem -LiteralPath $Root -Directory -Force -Filter '.rda-bundle-*') | Should -BeNullOrEmpty
    }

    It 'a fold that removes the zip (what a full disk does) makes the run report the zip as lost' {
        # What a write to the zip does when it hits a full disk: it removes the zip and fails.
        Mock Add-ItemsToZipArchive {
            Remove-Item -LiteralPath $ZipPath -Force
            throw [System.IO.IOException]::new('No space left on device')
        }
        $R = Invoke-FoldBlock -Root (Join-Path $TestDrive 'fold-lost')

        $R.BundleBuildError | Should -Be 'The consolidated zip was lost while the run summary was added to it: the zip is not on disk.'
        $R.OuterZipFile | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'Bundle finalized*' }).Count | Should -Be 0
        @($R.Printed | Where-Object { $_ -eq ('ERROR: {0}' -f $R.BundleBuildError) }).Count | Should -Be 1
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' -or $_ -like 'Consolidated Report:*' }).Count | Should -Be 0
    }

    It 'a zip that is gone before the run summary is added is reported as lost too' {
        $R = Invoke-FoldBlock -Root (Join-Path $TestDrive 'gone-before') -GoneBeforeFold

        $R.BundleBuildError | Should -Be 'The consolidated zip was lost while the run summary was added to it: the zip is not on disk.'
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' -or $_ -like 'Consolidated Report:*' }).Count | Should -Be 0
        Test-Path -LiteralPath $R.Path | Should -BeFalse
    }

    It 'a fold that leaves a report out of the zip without an error: the zip is reported as lost and is not left under its name' {
        # Rewrites the zip with the staged extras only, and does not fail.
        Mock Add-ItemsToZipArchive {
            Remove-Item -LiteralPath $ZipPath -Force
            $Zip = [System.IO.Compression.ZipFile]::Open($ZipPath, 'Create')
            try { foreach ($Item in @($Items)) { if (Test-Path -LiteralPath $Item -PathType Leaf) { $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Zip, $Item, (Split-Path $Item -Leaf)) } } } finally { $Zip.Dispose() }
        }
        $Root = Join-Path $TestDrive 'fold-short'
        $R = Invoke-FoldBlock -Root $Root

        $R.BundleBuildError | Should -Be 'The consolidated zip was lost while the run summary was added to it: 2 of the 2 per-subscription zip(s) are not in it.'
        $R.OuterZipFile | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' -or $_ -like 'Consolidated Report:*' }).Count | Should -Be 0
        script:Get-BundleFiles -Root $Root | Should -BeNullOrEmpty
    }

    It 'a zip that fails the check after the fold and cannot be removed: the error says to delete it and not share it' {
        Mock Add-ItemsToZipArchive {
            [System.IO.File]::Delete($ZipPath)
            $Zip = [System.IO.Compression.ZipFile]::Open($ZipPath, 'Create')
            try { $null = $Zip.CreateEntry('RunSummary.log') } finally { $Zip.Dispose() }
        }
        # The removal fails without an error, as on a locked file with SilentlyContinue.
        Mock Remove-Item { } -ParameterFilter { $LiteralPath -like '*rda-*.partial' }
        $R = Invoke-FoldBlock -Root (Join-Path $TestDrive 'fold-stuck')

        $R.BundleBuildError | Should -BeLike ('The consolidated zip was lost while the run summary was added to it: *. {0} could not be removed: delete it, do not share it.' -f (Join-Path $TestDrive 'fold-stuck/rda-build-fold.partial'))
        @($R.Printed | Where-Object { $_ -eq ('ERROR: {0}' -f $R.BundleBuildError) }).Count | Should -Be 1
        $R.OuterZipFile | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' -or $_ -like 'Consolidated Report:*' }).Count | Should -Be 0
    }

    It 'a zip that passed its last check but finds every name taken is kept under its private name, which the error gives' {
        $Root = Join-Path $TestDrive 'names-taken'
        $null = New-Item -ItemType Directory -Path $Root -Force
        $Stem = 'AllSubscriptions_ResourcesReport_2026-01-01_00-00-00'
        $null = New-Item -ItemType File -Path (Join-Path $Root ($Stem + '.zip'))
        foreach ($N in 2..100) { $null = New-Item -ItemType File -Path (Join-Path $Root ('{0}-{1}.zip' -f $Stem, $N)) }
        $R = Invoke-FoldBlock -Root $Root
        $Kept = Join-Path $Root 'rda-build-fold.partial'
        $R.BundleBuildError | Should -Be ('The consolidated zip passed its check but could not take its name (every name from {0}.zip to {0}-100.zip is taken). It is kept as {1}: rename it to a .zip name to use it.' -f $Stem, $Kept)
        Test-Path -LiteralPath $Kept | Should -BeTrue
        $R.OuterZipFile | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'Reporting Data File:*' -or $_ -like 'Consolidated Report:*' }).Count | Should -Be 0
    }

    It 'a zip that goes away as it takes its name is reported as lost, not as kept' {
        Mock Move-RunOutputFile { [System.IO.File]::Delete($Source); throw [System.IO.FileNotFoundException]::new('gone') }
        $R = Invoke-FoldBlock -Root (Join-Path $TestDrive 'gone-at-move')
        $R.BundleBuildError | Should -Be 'The consolidated zip was lost while the run summary was added to it: the zip is not on disk.'
        $R.OuterZipFile | Should -BeNullOrEmpty
    }

    It 'a fold that fails but leaves every report in the zip is only a warning' {
        Mock Add-ItemsToZipArchive { throw [System.IO.IOException]::new('No space left on device') }
        $R = Invoke-FoldBlock -Root (Join-Path $TestDrive 'fold-kept')

        $R.BundleBuildError | Should -BeNullOrEmpty
        @($R.Printed | Where-Object { $_ -like 'WARNING: Could not fold run-summary*No space left on device*' }).Count | Should -Be 1
        @($R.Printed | Where-Object { $_ -like 'ERROR:*' }).Count | Should -Be 0
        (Get-PathLines $R).Count | Should -Be 2
    }

    It 'a fold that works keeps every report and adds the run summary, then prints the path' {
        $R = Invoke-FoldBlock -Root (Join-Path $TestDrive 'fold-good')

        $R.BundleBuildError | Should -BeNullOrEmpty
        $Names = Get-ZipEntryNames -Path $R.OuterZipFile
        $Names | Should -Contain 'RunSummary.log'
        @($Names | Where-Object { $_ -like 'ResourcesReport_F*.zip' }).Count | Should -Be 2
        (Get-PathLines $R).Count | Should -Be 2
        # After the fold's own line, not before it.
        $Finalized = [array]::IndexOf($R.Printed, @($R.Printed | Where-Object { $_ -like 'Bundle finalized*' })[0])
        $Finalized | Should -BeGreaterOrEqual 0
        [array]::IndexOf($R.Printed, (Get-PathLines $R)[0]) | Should -BeGreaterThan $Finalized
    }

    It 'the wrapper prints the path of the consolidated zip only after that last check' {
        $PathWrites = @($script:WrapperAst.FindAll({
                    $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                    $args[0].GetCommandName() -eq 'Write-Host' -and
                    ($args[0].Extent.Text.Contains('Reporting Data File:') -or $args[0].Extent.Text.Contains('Consolidated Report:'))
                }, $true))
        $PathWrites.Count | Should -Be 2
        foreach ($W in $PathWrites)
        {
            $W.Extent.StartOffset | Should -BeGreaterThan $script:FinalCheckIf.Extent.StartOffset
            $W.Extent.EndOffset | Should -BeLessThan $script:FinalCheckIf.Extent.EndOffset
        }
    }
}

Describe 'Run-AllSubscriptions.ps1: the end of a run without a consolidated zip' {
    BeforeAll {
        $script:BannerBlock = [scriptblock]::Create((Find-WrapperIf -Condition '$null -ne $BundleBuildError' -Contains 'FAILED (consolidated zip)').Extent.Text)
        $ExitIf = Find-WrapperIf -Condition '$null -ne $BundleBuildError -or $InventoryFolderGone' -Contains 'exit 2'
        # The exit code is worked out before the bundle fold (#66): those
        # statements, then from the exit-2 check to the end of the wrapper, as they run.
        $ExitCodeStatements = @($script:WrapperAst.EndBlock.Statements | Where-Object { $_.Extent.Text -match '^\$(AuthSkipped|CollectorsFailed|SubscriptionsFailed|ExitTwoReasons|ConsumptionIncomplete|MetricsIncompleteRun|WrapperExitCode) = ' -or ($_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match '\$ExitTwoReasons \+= ') } | ForEach-Object { $_.Extent.Text })
        $script:TailText = ($ExitCodeStatements -join "`n") + "`n" + $script:WrapperAst.Extent.Text.Substring($ExitIf.Extent.StartOffset - $script:WrapperAst.Extent.StartOffset)
        $script:Pwsh = (Get-Process -Id $PID).Path

        # Any other variable the tail reads but does not assign is a list the wrapper
        # fills during the run; in these runs it is empty.
        $TailAst = [System.Management.Automation.Language.Parser]::ParseInput($script:TailText, [ref]$null, [ref]$null)
        $Assigned = @($TailAst.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath })
        $Given = @('null', 'true', 'false', 'BundleBuildError', 'AuthSkippedPhases', 'Global:CollectorFailures')
        $script:EmptyLists = @($TailAst.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
                ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique | Where-Object { $Assigned -notcontains $_ -and $Given -notcontains $_ })

        # The end of a run as the wrapper has it, from the expected report zip count
        # through the report zip check and the bundling block, for a run that
        # completed $RunCount subscriptions and carried $CarriedCount reports, with
        # its inventory folder at $Root.
        $ExpectedAssignment = @($script:WrapperAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$ExpectedZipCount' })
        if ($ExpectedAssignment.Count -ne 1) { throw ('expected exactly one top-level $ExpectedZipCount assignment in Run-AllSubscriptions.ps1, found {0}' -f $ExpectedAssignment.Count) }
        $script:CheckText = (Find-WrapperIf -Condition '$ExpectedZipCount -gt 0' -Contains 'Per-subscription output verification').Extent.Text
        $script:BuildText = @(
            '$OuterZipFile = $null'
            '$BundleBuildError = $null'
            (Find-WrapperIf -Condition 'Test-Path -LiteralPath $InventoryRoot -PathType Container' -Contains 'AllSubscriptions_ResourcesReport_').Extent.Text
        ) -join "`n"
        $script:EndOfRunText = @(
            # The wrapper sets the rows of a stream with no readable summary before the
            # expected count; this end of a run has none.
            '$GoneRecordRows = @()'
            $ExpectedAssignment[0].Extent.Text
            '$MissingReports = @()'
            '$MissingReportCount = 0'
            '$InventoryFolderGone = $false'
            # The check's stop reads these; the wrapper sets them before it.
            '$AuthSkipped = $false'
            '$CollectorsFailed = $false'
            '{Check}'
            $script:BuildText
        ) -join "`n"
        # -AfterCheck: the inventory folder went after the report zip check
        # passed, so only the bundling block sees it gone (the check stops a run
        # whose folder is gone by then, with exit 2).
        function script:Get-EndOfRunText
        {
            param([string]$Root, [int]$RunCount, [int]$CarriedCount, [switch]$AfterCheck)
            @(
                ('$InventoryRoot = ''{0}''' -f $Root.Replace("'", "''"))
                # -First: 1..0 counts down to 0, so it is not an empty range.
                ('$SubResourceCounts = @(1..{0} | Select-Object -First {0} | ForEach-Object {{ [pscustomobject]@{{ Name = ''sub-'' + $_; Id = ''sub-'' + $_; Count = 1 }} }})' -f $RunCount)
                ('$CarriedReports = @(1..{0} | Select-Object -First {0} | ForEach-Object {{ [pscustomobject]@{{ Name = ''carried-'' + $_; Id = ''carried-'' + $_ }} }})' -f $CarriedCount)
                '$RunReports = @()'
                $script:EndOfRunText.Replace('{Check}', $(if ($AfterCheck) { '' } else { $script:CheckText }))
            ) -join "`n"
        }

        # Runs the wrapper's tail in a child pwsh, since it ends with 'exit'. Returns
        # the exit code. -Before is wrapper text run ahead of the tail.
        function script:Invoke-Tail
        {
            param([string]$BundleBuildError, [string[]]$AuthSkippedPhases = @(), [int]$CollectorFailureCount = 0, [string]$Before = '')
            $Script = Join-Path $TestDrive ('tail-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
            $Preamble = @(
                ('. ''{0}''' -f $script:FunctionsPath.Replace("'", "''"))
                $(if ($BundleBuildError) { '$BundleBuildError = ''{0}''' -f $BundleBuildError.Replace("'", "''") } else { '$BundleBuildError = $null' })
                ('$AuthSkippedPhases = @({0})' -f ((@($AuthSkippedPhases) | ForEach-Object { "'$_'" }) -join ','))
                $(if ($CollectorFailureCount -gt 0) { '$Global:CollectorFailures = @(1..{0} | ForEach-Object {{ [pscustomobject]@{{ Id = ''sub'' }} }})' -f $CollectorFailureCount } else { '$Global:CollectorFailures = @()' })
            ) + @($script:EmptyLists | ForEach-Object { '${0} = @()' -f $_ }) + @($Before)
            Set-Content -LiteralPath $Script -Value (($Preamble -join "`n") + "`n" + $script:TailText)
            & $script:Pwsh -NoProfile -NonInteractive -File $Script *> $null
            $LASTEXITCODE
        }
    }

    It 'the banner names the zip, the cause and where the reports are' {
        $InventoryRoot = Join-Path $TestDrive 'inv'
        New-Item -ItemType Directory -Path $InventoryRoot -Force | Out-Null
        $BundleBuildError = 'Could not build /x/AllSubscriptions_ResourcesReport_1.zip: No space left on device'
        $Printed = @(. $script:BannerBlock 6>&1 | ConvertTo-Lines)

        $Printed | Should -Contain '================ FAILED (consolidated zip) ================'
        $Printed | Should -Contain $BundleBuildError
        $Printed | Should -Contain ('The per-subscription report zips of this run are still on disk under {0}.' -f $InventoryRoot)
    }

    It 'the banner says to run the same command again (without -Fresh), or with -Resume, while the resume state is kept, and only to run again without one' {
        $InventoryRoot = Join-Path $TestDrive 'inv'
        $BundleBuildError = 'x was lost while the run summary was added to it: the zip is not on disk.'
        $ResumeStateFile = Join-Path $TestDrive '.resume-state-e3b98a4da31a.json'
        Set-Content -LiteralPath $ResumeStateFile -Value '{}'
        $Kept = @(. $script:BannerBlock 6>&1 | ConvertTo-Lines)
        $Kept | Should -Contain 'Fix the cause (for example, free up disk space), then run the same command again (without -Fresh), or with -Resume: it puts these reports into a new consolidated zip without collecting them again.'
        Remove-Item -LiteralPath $ResumeStateFile -Force
        $None = @(. $script:BannerBlock 6>&1 | ConvertTo-Lines)
        $None | Should -Contain 'Fix the cause (for example, free up disk space), then run again.'
        $None | Should -Not -Contain 'Fix the cause (for example, free up disk space), then run the same command again (without -Fresh), or with -Resume: it puts these reports into a new consolidated zip without collecting them again.'
    }

    It 'the banner says how many report zips are gone when the output check found some that are gone by then' {
        $InventoryRoot = Join-Path $TestDrive 'inv-some-gone'
        New-Item -ItemType Directory -Path $InventoryRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $InventoryRoot 'kept.zip') -Value 'x'
        # Set-Variable: these are read only by the lifted block.
        Set-Variable -Name ActualSubZips -Value @([pscustomobject]@{ FullName = (Join-Path $InventoryRoot 'kept.zip') }, [pscustomobject]@{ FullName = (Join-Path $InventoryRoot 'gone.zip') })
        Set-Variable -Name BundleBuildError -Value 'x'
        $Printed = @(. $script:BannerBlock 6>&1 | ConvertTo-Lines)
        $Printed | Should -Not -Contain ('The per-subscription report zips of this run are still on disk under {0}.' -f $InventoryRoot)
        $Printed | Should -Contain ('1 per-subscription report zip(s) of this run are gone; the others are still on disk under {0}.' -f $InventoryRoot)
        # Every one gone: no line says others are left.
        Remove-Item -LiteralPath (Join-Path $InventoryRoot 'kept.zip') -Force
        $Printed = @(. $script:BannerBlock 6>&1 | ConvertTo-Lines)
        @($Printed | Where-Object { $_ -like '*still on disk*' }) | Should -BeNullOrEmpty
        $Printed | Should -Contain ('All 2 per-subscription report zip(s) of this run are gone from {0}.' -f $InventoryRoot)
    }

    It 'the banner says the reports went with the folder when the inventory folder is gone by then' {
        # Set-Variable: these are read only by the lifted block.
        Set-Variable -Name InventoryRoot -Value (Join-Path $TestDrive 'inv-gone')
        Set-Variable -Name BundleBuildError -Value 'The consolidated zip was lost while the run summary was added to it: the zip is not on disk.'
        $Printed = @(. $script:BannerBlock 6>&1 | ConvertTo-Lines)
        $Printed | Should -Not -Contain ('The per-subscription report zips of this run are still on disk under {0}.' -f $InventoryRoot)
        $Printed | Should -Contain ('The inventory folder {0} is gone, with the report zips and the resume state that were in it. The next run collects every subscription again.' -f $InventoryRoot)
    }

    It 'the banner says to rename a kept zip, not to run again, when the zip could not take its name' {
        # Set-Variable: these are read only by the lifted block.
        Set-Variable -Name InventoryRoot -Value (Join-Path $TestDrive 'inv')
        Set-Variable -Name BundleBuildError -Value 'The consolidated zip passed its check but could not take its name (x). It is kept as /x/rda-build-1.partial: rename it to a .zip name to use it.'
        Set-Variable -Name ZipKeptAs -Value '/x/rda-build-1.partial'
        $Printed = @(. $script:BannerBlock 6>&1 | ConvertTo-Lines)
        @($Printed | Where-Object { $_ -like 'The zip itself is complete: rename /x/rda-build-1.partial to a .zip name*' }).Count | Should -Be 1
        $Printed | Should -Not -Contain 'Fix the cause (for example, free up disk space), then run again.'
    }

    It 'no banner when the zip was built' {
        Set-Variable -Name InventoryRoot -Value (Join-Path $TestDrive 'inv')
        Set-Variable -Name BundleBuildError -Value $null
        @(. $script:BannerBlock 6>&1 | ConvertTo-Lines).Count | Should -Be 0
    }

    It 'exit code 2 when the zip is missing, also over 3-5' {
        Invoke-Tail -BundleBuildError 'Could not build x: y' | Should -Be 2
        Invoke-Tail -BundleBuildError 'Could not build x: y' -AuthSkippedPhases 'Metrics' -CollectorFailureCount 1 | Should -Be 2
    }

    It 'the inventory folder gone at the end of a run that expected report zips: every one of them counts as missing, exit code 2' {
        # The folder goes after the report zip check passed (a folder gone by
        # the check stops the run there with exit 2).
        $Gone = Join-Path $TestDrive 'folder-gone'
        $Printed = @(. ([scriptblock]::Create((Get-EndOfRunText -Root $Gone -RunCount 1 -CarriedCount 1 -AfterCheck))) 6>&1 | ConvertTo-Lines)
        $Printed | Should -Contain ('Inventory root not found at {0}. Nothing to consolidate.' -f $Gone)
        $MissingReportCount | Should -Be 2
        $OuterZipFile | Should -BeNullOrEmpty
        Invoke-Tail -BundleBuildError $null -Before (Get-EndOfRunText -Root $Gone -RunCount 1 -CarriedCount 0 -AfterCheck) | Should -Be 2
        # A run that expected no report zip keeps its exit code.
        Invoke-Tail -BundleBuildError $null -Before (Get-EndOfRunText -Root $Gone -RunCount 0 -CarriedCount 0 -AfterCheck) | Should -Be 0
    }

    It 'the inventory folder gone at the end: one line says the folder, its reports and the resume state are gone and the next run starts a new run, in place of the report-missing banner' {
        $Gone = Join-Path $TestDrive 'folder-gone-text'
        $BannerCall = @($script:WrapperAst.EndBlock.Statements | Where-Object { $_.Extent.Text.StartsWith('Write-MissingReportBanner ') })
        $BannerCall.Count | Should -Be 1
        # Set-Variable: read only by the lifted call.
        Set-Variable -Name RetryLimited -Value @()
        Set-Variable -Name TenantID -Value '12345678-1234-1234-1234-123456789012'
        Set-Variable -Name RetryCommandSettings -Value (Get-RetryCommandSettings -Settings (Get-RunDataSettings) -DeviceLogin $false)
        # The folder goes after the report zip check passed.
        $Lines = @(. ([scriptblock]::Create((Get-EndOfRunText -Root $Gone -RunCount 1 -CarriedCount 1 -AfterCheck) + "`n" + $BannerCall[0].Extent.Text)) 6>&1 | ConvertTo-Lines)
        $Text = @($Lines | Where-Object { $_ -and $_ -ne ('Inventory root not found at {0}. Nothing to consolidate.' -f $Gone) })
        $Text | Should -Be @(('FAILED (report missing): the inventory folder {0} is gone, with the report zips and the resume state that were in it, so no consolidated zip was built. The next run starts a new run and collects every subscription again.' -f $Gone))
        ($Lines -join "`n") | Should -Not -Match 'resume state is kept|could not be named|=== FAILED'
    }

    It 'the report-missing banner is unchanged while the inventory folder is there' {
        $Lines = @(Write-MissingReportBanner -MissingReports @([pscustomobject]@{ Name = 'sub-a'; Id = 'sub-a' }) -MissingReportCount 1 -ZipBuilt $true -TenantID 't' 6>&1 | ConvertTo-Lines)
        $Lines | Should -Contain '================== FAILED (report missing) =================='
        $Lines | Should -Contain 'The resume state is kept. Run the same command again (without -Fresh), or with -Resume: it collects these subscriptions again and carries the other reports into a new consolidated zip.'
    }

    It 'the other exit codes are unchanged when the zip was built' {
        Invoke-Tail -BundleBuildError $null | Should -Be 0
        Invoke-Tail -BundleBuildError $null -AuthSkippedPhases 'Metrics' | Should -Be 3
        Invoke-Tail -BundleBuildError $null -CollectorFailureCount 1 | Should -Be 4
        Invoke-Tail -BundleBuildError $null -AuthSkippedPhases 'Metrics' -CollectorFailureCount 1 | Should -Be 5
    }
}

Describe 'New-RunOutputFile: a new file, never one that is there' {
    It 'creates the name given when it is free' {
        $Path = New-RunOutputFile -Directory $TestDrive -Stem 'MainSummary_2026-11-02_15-04-05' -Extension '.html'
        $Path | Should -Be (Join-Path $TestDrive 'MainSummary_2026-11-02_15-04-05.html')
        (Get-Item -LiteralPath $Path).Length | Should -Be 0
    }

    It 'takes -2, then -3, when the names before are there, and leaves those files as they were' {
        $Dir = Join-Path $TestDrive 'taken'
        $null = New-Item -ItemType Directory -Path $Dir
        Set-Content -LiteralPath (Join-Path $Dir 'RunAllSubscriptions_transcript_x.txt') -Value 'first' -NoNewline
        (New-RunOutputFile -Directory $Dir -Stem 'RunAllSubscriptions_transcript_x' -Extension '.txt') | Should -Be (Join-Path $Dir 'RunAllSubscriptions_transcript_x-2.txt')
        (New-RunOutputFile -Directory $Dir -Stem 'RunAllSubscriptions_transcript_x' -Extension '.txt') | Should -Be (Join-Path $Dir 'RunAllSubscriptions_transcript_x-3.txt')
        Get-Content -LiteralPath (Join-Path $Dir 'RunAllSubscriptions_transcript_x.txt') -Raw | Should -Be 'first'
    }

    It 'says so when every name up to -100 is taken, and creates nothing' {
        $Dir = Join-Path $TestDrive 'full'
        $null = New-Item -ItemType Directory -Path $Dir
        $null = New-Item -ItemType File -Path (Join-Path $Dir 'z.zip')
        foreach ($N in 2..100) { $null = New-Item -ItemType File -Path (Join-Path $Dir ('z-{0}.zip' -f $N)) }
        { New-RunOutputFile -Directory $Dir -Stem 'z' -Extension '.zip' } | Should -Throw 'every name from z.zip to z-100.zip is taken'
        @(Get-ChildItem -LiteralPath $Dir -File).Count | Should -Be 100
    }

    # File.Exists counts such a link as there on every PowerShell 7 runtime: .NET Core
    # 3.1 and .NET 5 fall back to lstat when stat fails, and .NET 6 and later lstat first.
    It 'takes -2 when a link whose target is gone holds the name, and leaves the link as it was' -Skip:($IsWindows) {
        $Dir = Join-Path $TestDrive 'dangling-new'
        $null = New-Item -ItemType Directory -Path $Dir
        $Link = Join-Path $Dir 'z.txt'
        $null = New-Item -ItemType SymbolicLink -Path $Link -Target (Join-Path $Dir 'gone')
        (New-RunOutputFile -Directory $Dir -Stem 'z' -Extension '.txt') | Should -Be (Join-Path $Dir 'z-2.txt')
        (Get-Item -LiteralPath $Link -Force).LinkType | Should -Be 'SymbolicLink'
        Test-Path -LiteralPath (Join-Path $Dir 'gone') | Should -BeFalse
    }
}

Describe 'Run-AllSubscriptions.ps1: the transcript and the main summary of the same second' {
    It 'the wrapper transcript takes its name from New-RunOutputFile, so it never writes over another run''s transcript' {
        $Try = @($script:WrapperAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text.Contains('Start-Transcript -LiteralPath $WrapperTranscriptFile') })
        $Try.Count | Should -Be 1
        $Root = Join-Path $TestDrive 'transcript'
        $null = New-Item -ItemType Directory -Path $Root
        Mock Get-Date { '2026-11-02_15-04-05' } -ParameterFilter { $Format -eq 'yyyy-MM-dd_HH-mm-ss' }
        Set-Content -LiteralPath (Join-Path $Root 'RunAllSubscriptions_transcript_2026-11-02_15-04-05.txt') -Value 'another run' -NoNewline
        Mock Start-Transcript { }
        Set-Variable -Name InventoryRoot -Value $Root
        $WrapperTranscriptFile = $null
        $Stem = @($script:WrapperAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$WrapperTranscriptStem' })
        $Stem.Count | Should -Be 1
        $null = @(. ([scriptblock]::Create($Stem[0].Extent.Text + "`n" + $Try[0].Extent.Text)) 6>&1)
        $WrapperTranscriptFile | Should -Be (Join-Path $Root 'RunAllSubscriptions_transcript_2026-11-02_15-04-05-2.txt')
        Get-Content -LiteralPath (Join-Path $Root 'RunAllSubscriptions_transcript_2026-11-02_15-04-05.txt') -Raw | Should -Be 'another run'
    }

    It 'a transcript that cannot start leaves no file under the name it took' {
        $Try = @($script:WrapperAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text.Contains('Start-Transcript -LiteralPath $WrapperTranscriptFile') })
        $Before = @($script:WrapperAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and @('$WrapperTranscriptStem', '$WrapperTranscriptFile', '$WrapperTranscriptReserved') -contains $_.Left.Extent.Text } | Where-Object { $_.Extent.EndOffset -lt $Try[0].Extent.StartOffset })
        $Root = Join-Path $TestDrive 'transcript-failed'
        $null = New-Item -ItemType Directory -Path $Root
        Mock Start-Transcript { throw 'Transcription has already been started' }
        Set-Variable -Name InventoryRoot -Value $Root
        $null = @(. ([scriptblock]::Create(((@($Before | ForEach-Object { $_.Extent.Text }) + $Try[0].Extent.Text) -join "`n"))) 6>&1)
        @(Get-ChildItem -LiteralPath $Root -File) | Should -BeNullOrEmpty
    }

    It 'the version of the main summary and the bundle falls back to the loaded one when Version.json cannot be read, with no error printed' -ForEach @(@{ Var = 'MainVer'; Obj = 'VerObj' }, @{ Var = 'BundleVer'; Obj = 'BundleVerObj' }) {
        $Try = @($script:WrapperAst.FindAll({ $args[0] -is [System.Management.Automation.Language.TryStatementAst] -and $args[0].Body.Extent.Text -match ('^\{\s*\$' + $Obj + ' = Get-Content') }, $true))
        $Try.Count | Should -Be 1
        $Code = $Try[0].Extent.Text.Replace('$PSScriptRoot', '$NoVersionRoot')
        $NoVersionRoot = Join-Path $TestDrive 'no-version'
        New-Item -ItemType Directory -Path $NoVersionRoot -Force | Out-Null
        $Before = $Global:Version
        try
        {
            $Global:Version = '9.9.9'
            Set-Variable -Name $Var -Value '9.9.9'
            $Err = @(. ([scriptblock]::Create($Code)) 2>&1)
            (Get-Variable -Name $Var -ValueOnly) | Should -Be '9.9.9'
            $Err | Should -BeNullOrEmpty
            $null = $NoVersionRoot
        }
        finally { $Global:Version = $Before }
    }

    It 'a main summary that cannot be built leaves no file under the name it took, empty or partial, and is not added to the zip' {
        $SummaryIf = Find-WrapperIf -Condition '$null -ne $OuterZipFile' -Contains 'New-RdaAllSubHtmlSummary'
        # The block loads the summary functions from the wrapper's folder; here a
        # stand-in folder whose builder fails.
        $Fake = Join-Path $TestDrive 'fake-root'
        $null = New-Item -ItemType Directory -Path (Join-Path $Fake 'Functions') -Force
        # It writes part of the file, then fails, as a full disk does.
        Set-Content -LiteralPath (Join-Path $Fake 'Functions/AllSubHtmlSummary.Functions.ps1') -Value 'function New-RdaAllSubHtmlSummary { param($HtmlFile) Set-Content -LiteralPath $HtmlFile -Value "<html>part"; throw "disk full" }'
        $Text = $SummaryIf.Extent.Text.Replace('$PSScriptRoot', ('''{0}''' -f $Fake.Replace("'", "''")))
        $Root = Join-Path $TestDrive 'summary-failed'
        $null = New-Item -ItemType Directory -Path $Root
        Set-Variable -Name InventoryRoot -Value $Root
        Set-Variable -Name OuterZipFile -Value (Join-Path $Root 'AllSubscriptions_ResourcesReport_x.zip')
        Set-Variable -Name RunStartTime -Value (Get-Date)
        $MainSummaryFile = $null
        $Printed = @(. ([scriptblock]::Create($Text)) 6>&1 | ConvertTo-Lines)
        @($Printed | Where-Object { $_ -like 'WARNING: Could not build the main summary: disk full' }).Count | Should -Be 1
        $MainSummaryFile | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $Root -Filter 'MainSummary_*.html' -File) | Should -BeNullOrEmpty
    }
}

Describe 'Run-AllSubscriptions.ps1: the inventory folder gone at the end of the run' {
    BeforeAll {
        $Expected = @($script:WrapperAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$ExpectedZipCount' })
        if ($Expected.Count -ne 1) { throw ('expected exactly one top-level $ExpectedZipCount assignment in Run-AllSubscriptions.ps1, found {0}' -f $Expected.Count) }
        # From the expected report zip count through the bundling block, as the
        # wrapper has them, then exit 0 if nothing exited. The folder goes after
        # the report zip check passed, so the check is left out (a folder gone
        # by the check stops the run there with exit 2).
        $script:EndOfRunText = @(
            $Expected[0].Extent.Text
            '$MissingReports = @()'
            '$MissingReportCount = 0'
            '$InventoryFolderGone = $false'
            '$OuterZipFile = $null'
            '$BundleBuildError = $null'
            '$InventoryFolderGone = $false'
            (Find-WrapperIf -Condition 'Test-Path -LiteralPath $InventoryRoot -PathType Container' -Contains 'AllSubscriptions_ResourcesReport_').Extent.Text
            # The report-missing banner call of the wrapper, which says the folder is gone.
            '$RetryLimited = @()'
            '$TenantID = ''t'''
            @($script:WrapperAst.EndBlock.Statements | Where-Object { $_.Extent.Text.StartsWith('Write-MissingReportBanner ') })[0].Extent.Text
            (Find-WrapperIf -Condition '$null -ne $BundleBuildError -or $InventoryFolderGone' -Contains 'exit 2').Extent.Text
            'exit 0'
        ) -join "`n"
        $script:Pwsh = (Get-Process -Id $PID).Path

        # Runs that end of a run in a child pwsh (Exit-Wrapper ends with 'exit')
        # for a run that completed $RunCount subscriptions, with its inventory
        # folder at $Root. Returns the exit code and the lines printed.
        function script:Invoke-EndOfRun
        {
            param([string]$Root, [int]$RunCount)
            $Script = Join-Path $TestDrive ('end-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
            @(
                ('. ''{0}''' -f $script:FunctionsPath.Replace("'", "''"))
                '$WrapperTranscriptStarted = $false'
                ('$InventoryRoot = ''{0}''' -f $Root.Replace("'", "''"))
                ('$ResumeStateFile = Join-Path $InventoryRoot ''.resume-state-t.json''')
                '$RunStartTime = (Get-Date).AddMinutes(-5)'
                # -First: 1..0 counts down to 0, so it is not an empty range.
                ('$SubResourceCounts = @(1..{0} | Select-Object -First {0} | ForEach-Object {{ [pscustomobject]@{{ Name = ''sub-'' + $_; Id = ''sub-'' + $_; Count = 1 }} }})' -f $RunCount)
                $script:EndOfRunText
            ) -join "`n" | Set-Content -LiteralPath $Script
            $Lines = @(& $script:Pwsh -NoProfile -NonInteractive -File $Script 6>&1 2>&1 | ForEach-Object { [string]$_ })
            [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $Lines }
        }
    }

    It 'a run that expected report zips: one line says the folder, its reports and the resume state are gone, and the run exits 2' {
        $Gone = Join-Path $TestDrive 'folder-gone'
        $R = Invoke-EndOfRun -Root $Gone -RunCount 2
        $R.Code | Should -Be 2
        # Nothing to check or consolidate: the banner says the folder, its reports and the resume state are gone.
        $R.Lines | Should -Contain ('FAILED (report missing): the inventory folder {0} is gone, with the report zips and the resume state that were in it, so no consolidated zip was built. The next run starts a new run and collects every subscription again.' -f $Gone)
    }

    It 'a run that expected no report zip keeps its exit code' {
        $R = Invoke-EndOfRun -Root (Join-Path $TestDrive 'folder-gone-none') -RunCount 0
        $R.Code | Should -Be 0
        @($R.Lines | Where-Object { $_ -like 'FAILED*' }) | Should -BeNullOrEmpty
    }
}
Describe 'Move-RunOutputFile: moves a file to a free name, never over one that is there' {
    It 'moves to the name given when it is free' {
        $Dir = Join-Path $TestDrive 'move-free'
        $null = New-Item -ItemType Directory -Path $Dir
        $Src = Join-Path $Dir '.rda-x.partial'
        Set-Content -LiteralPath $Src -Value 'zip' -NoNewline
        Move-RunOutputFile -Source $Src -Directory $Dir -Stem 'z' -Extension '.zip' | Should -Be (Join-Path $Dir 'z.zip')
        Test-Path -LiteralPath $Src | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $Dir 'z.zip') -Raw | Should -Be 'zip'
    }

    It 'takes -2 when the name is there, and leaves that file as it was' {
        $Dir = Join-Path $TestDrive 'move-taken'
        $null = New-Item -ItemType Directory -Path $Dir
        Set-Content -LiteralPath (Join-Path $Dir 'z.zip') -Value 'another run' -NoNewline
        $Src = Join-Path $Dir '.rda-y.partial'
        Set-Content -LiteralPath $Src -Value 'mine' -NoNewline
        Move-RunOutputFile -Source $Src -Directory $Dir -Stem 'z' -Extension '.zip' | Should -Be (Join-Path $Dir 'z-2.zip')
        Get-Content -LiteralPath (Join-Path $Dir 'z.zip') -Raw | Should -Be 'another run'
        Get-Content -LiteralPath (Join-Path $Dir 'z-2.zip') -Raw | Should -Be 'mine'
    }

    It 'says so when every name up to -100 is taken, and leaves the file where it was' {
        $Dir = Join-Path $TestDrive 'move-full'
        $null = New-Item -ItemType Directory -Path $Dir
        $null = New-Item -ItemType File -Path (Join-Path $Dir 'z.zip')
        foreach ($N in 2..100) { $null = New-Item -ItemType File -Path (Join-Path $Dir ('z-{0}.zip' -f $N)) }
        $Src = Join-Path $Dir '.rda-z.partial'
        Set-Content -LiteralPath $Src -Value 'mine' -NoNewline
        { Move-RunOutputFile -Source $Src -Directory $Dir -Stem 'z' -Extension '.zip' } | Should -Throw 'every name from z.zip to z-100.zip is taken'
        Test-Path -LiteralPath $Src | Should -BeTrue
    }

    It 'takes -2 when a link whose target is gone holds the name, and does not follow it' -Skip:($IsWindows) {
        $Dir = Join-Path $TestDrive 'move-dangling'
        $null = New-Item -ItemType Directory -Path $Dir
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $Dir 'z.zip') -Target (Join-Path $Dir 'gone')
        $Src = Join-Path $Dir '.rda-l.partial'
        Set-Content -LiteralPath $Src -Value 'mine' -NoNewline
        Move-RunOutputFile -Source $Src -Directory $Dir -Stem 'z' -Extension '.zip' | Should -Be (Join-Path $Dir 'z-2.zip')
        Get-Content -LiteralPath (Join-Path $Dir 'z-2.zip') -Raw | Should -Be 'mine'
        Test-Path -LiteralPath (Join-Path $Dir 'gone') | Should -BeFalse
    }
}

Describe 'Run-AllSubscriptions.ps1: an inventory folder whose path holds a wildcard character' {
    It 'stops at the start with exit 1, naming the folder, before anything is written' {
        $Block = [scriptblock]::Create((Find-WrapperIf -Condition "`$InventoryRoot.IndexOfAny([char[]]'[]*?') -ge 0" -Contains 'has [ ] * or ? in its path').Extent.Text)
        # The real Exit-Wrapper, under strict mode, in a pwsh of its own: exit 1.
        $Script = Join-Path $TestDrive 'bracket-stop.ps1'
        @(
            ('. ''{0}''' -f $script:FunctionsPath.Replace("'", "''"))
            'Set-StrictMode -Version Latest'
            # What the wrapper sets before its first exit, which Exit-Wrapper reads.
            '$TenantID = ''t'''
            '$WrapperTranscriptStarted = $false'
            '$FoldedStreamFiles = @()'
            '$FoldedRecordIds = @()'
            '$OtherRunLineReady = $false'
            ('$InventoryRoot = ''{0}''' -f (Join-Path $TestDrive 'strict[1]/InventoryReports').Replace("'", "''"))
            $Block.ToString()
            'exit 0'
        ) -join "`n" | Set-Content -LiteralPath $Script
        $Out = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $Script *>&1 | ForEach-Object { [string]$_ })
        $LASTEXITCODE | Should -Be 1
        # A strict-mode error also ends a script with 1: the stop must be the reason.
        @($Out | Where-Object { $_ -like '*cannot be retrieved*' -or $_ -like '*has not been set*' }) | Should -BeNullOrEmpty
        function Exit-Wrapper { param($Code) $script:StopCode = $Code }
        $script:StopCode = $null
        # * and ? are allowed in folder names on Linux and macOS (only the path text is read here).
        foreach ($Odd in 'inv[1]', 'inv*1', 'inv?1')
        {
            $script:StopCode = $null
            $InventoryRoot = Join-Path $TestDrive ($Odd + '/InventoryReports')
            $Printed = @(. $Block 6>&1 | ConvertTo-Lines)
            $script:StopCode | Should -Be 1 -Because $Odd
            $Printed | Should -Contain ('ERROR: The inventory folder {0} has [ ] * or ? in its path, which this script cannot use. Set HOME to a folder without them and run again.' -f $InventoryRoot)
        }
        $InventoryRoot = Join-Path $TestDrive 'plain/InventoryReports'
        $script:StopCode = $null
        @(. $Block 6>&1 | ConvertTo-Lines).Count | Should -Be 0
        $script:StopCode | Should -BeNullOrEmpty
    }
}
