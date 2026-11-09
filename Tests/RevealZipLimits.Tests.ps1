# Reveal holds every zip it reads and writes to the ingestion server's zip limits
# Run with: Invoke-Pester ./Tests/RevealZipLimits.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The ingestion server refuses a zip with over 2000 files, over 100 to 1
# compression, a file over 16 GB, over 32 GB in all, or a rooted or '..'
# path. Reveal expanded each report zip without these limits, so a highly
# compressed report could fill the disk, and it wrote each revealed zip and
# the outer bundle without them, then said the bundle was ready to upload even
# when the server must refuse it. Reveal now checks the open archive before it
# scans or expands it, and checks each revealed zip and the outer zip before
# moving it into place.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run. The size limits are tested with small limit
# values passed to the check.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    . (Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealZipLimits_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force
    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'
    $script:SubToken = 'prod_22222222-3333-4444-5555-666666666666'
    $script:Inventory = '{"VirtualMachines":[{"ResourceGroup":"' + $script:Token + '","Subscription":"' + $script:SubToken + '"}]}'

    # A zip with the given entries (name -> text).
    function Write-TestZip
    {
        param([string]$Path, [System.Collections.IDictionary]$Entries)
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        $Archive = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
        try
        {
            foreach ($Name in $Entries.Keys)
            {
                $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry($Name).Open())
                try { $Writer.Write([string]$Entries[$Name]) } finally { $Writer.Dispose() }
            }
        }
        finally { $Archive.Dispose() }
    }

    function Get-Problem
    {
        param([string]$Path, [hashtable]$Limits = @{})
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return Get-RevealZipLimitProblem -Archive $Archive -CompressedLength ([System.IO.FileInfo]::new($Path).Length) @Limits }
        finally { $Archive.Dispose() }
    }

    # One subscription folder under a new root, whose report holds $Extra
    # entries besides its inventory.
    function New-Case
    {
        param([string]$Name, [System.Collections.IDictionary]$Extra = [ordered]@{})
        $Dir = Join-Path $script:WorkDir $Name
        $Sub = Join-Path $Dir 'root/good'
        $null = New-Item -ItemType Directory -Path $Sub -Force
        $Entries = [ordered]@{ 'Inventory_r.json' = $script:Inventory }
        foreach ($Key in $Extra.Keys) { $Entries[$Key] = $Extra[$Key] }
        Write-TestZip -Path (Join-Path $Sub 'ResourcesReport_good.zip') -Entries $Entries
        $Dict = '{"ResourceGroupMap":{"' + $script:Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg"},"SubscriptionMap":{"' + $script:SubToken + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg/providers/Microsoft.Compute/virtualMachines/vm1"},"SubscriptionNameMap":{"' + $script:SubToken + '":"real-sub"},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText((Join-Path $Sub 'ObfuscationDictionary_good.json'), $Dict)
        return [pscustomobject]@{
            Dir = $Dir; Root = (Join-Path $Dir 'root'); Staging = (Join-Path $Dir 'staging'); Bundle = (Join-Path $Dir 'bundle.zip')
            Source = (Join-Path $Sub 'ResourcesReport_good.zip'); Dict = (Join-Path $Sub 'ObfuscationDictionary_good.json')
        }
    }

    function Invoke-Reveal
    {
        param($Case, [string[]]$Extra = @())
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $Case.Root -StagingDirectory $Case.Staging -OutputZip $Case.Bundle -FolderTimeoutMinutes 5 @Extra 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($Console -join "`n") }
    }

    $script:Many = [ordered]@{}
    for ($i = 0; $i -lt 2001; $i++) { $script:Many[('f{0}.txt' -f $i)] = 'x' }
    $script:Packed = [ordered]@{ 'Padding.txt' = ('a' * 2MB) }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RevealZipLimitProblem' {
    It 'passes a small ordinary zip' {
        $Path = Join-Path $script:WorkDir 'ok.zip'
        Write-TestZip -Path $Path -Entries ([ordered]@{ 'Inventory_r.json' = $script:Inventory; 'sub/Metrics_r.json' = '{"Metrics":[]}' })
        Get-Problem $Path | Should -BeNullOrEmpty
    }

    It 'refuses more than 2000 files' {
        $Path = Join-Path $script:WorkDir 'many.zip'
        Write-TestZip -Path $Path -Entries $script:Many
        Get-Problem $Path | Should -Match 'holds 2001 files, more than the 2000 allowed'
    }

    It 'refuses more than 100 to 1 compression' {
        $Path = Join-Path $script:WorkDir 'packed.zip'
        Write-TestZip -Path $Path -Entries $script:Packed
        Get-Problem $Path | Should -Match 'times the size of the zip, more than the 100 to 1 allowed'
    }

    It 'refuses a path with a .. part' {
        $Path = Join-Path $script:WorkDir 'dotdot.zip'
        Write-TestZip -Path $Path -Entries ([ordered]@{ '../Inventory_r.json' = $script:Inventory })
        Get-Problem $Path | Should -Match "'\.\./Inventory_r\.json', whose path has a '\.\.' part"
    }

    It 'refuses a rooted path' {
        $Path = Join-Path $script:WorkDir 'rooted.zip'
        Write-TestZip -Path $Path -Entries ([ordered]@{ '/Inventory_r.json' = $script:Inventory })
        Get-Problem $Path | Should -Match 'whose path is rooted'
    }

    It 'refuses a file over the one-file limit' {
        $Path = Join-Path $script:WorkDir 'big.zip'
        Write-TestZip -Path $Path -Entries ([ordered]@{ 'a.json' = ('x' * 300); 'b.json' = 'y' })
        Get-Problem $Path -Limits @{ MaxEntryBytes = 200 } | Should -Match "'a\.json' of 300 bytes, more than the 200 bytes allowed for one file"
    }

    It 'refuses more than the total limit' {
        $Path = Join-Path $script:WorkDir 'total.zip'
        Write-TestZip -Path $Path -Entries ([ordered]@{ 'a.json' = ('x' * 150); 'b.json' = ('y' * 150) })
        Get-Problem $Path -Limits @{ MaxEntryBytes = 200; MaxTotalBytes = 250 } | Should -Match 'hold 300 bytes in all, more than the 250 bytes allowed'
    }

    It 'uses the limits of the ingestion server by default' {
        $Command = Get-Command Get-RevealZipLimitProblem
        $Command.Parameters['MaxEntries'].ParameterType | Should -Be ([int])
        $Ast = $Command.ScriptBlock.Ast
        $Text = $Ast.Extent.Text
        $Text | Should -Match '\[int\]\s+\$MaxEntries = 2000'
        $Text | Should -Match '\[double\]\s+\$MaxRatio = 100'
        $Text | Should -Match '\[long\]\s+\$MaxEntryBytes = 16GB'
        $Text | Should -Match '\[long\]\s+\$MaxTotalBytes = 32GB'
    }
}

Describe 'Reveal.ps1 refuses a report zip over the limits before expanding it' -Skip:$IsWindows {
    It 'fails a report of <Name>, names the limit and ships nothing of it' -ForEach @(
        @{ Name = 'over 2000 files'; Kind = 'many'; Text = 'holds 2002 files, more than the 2000 allowed' }
        @{ Name = 'over 100 to 1 compression'; Kind = 'packed'; Text = 'more than the 100 to 1 allowed' }
        @{ Name = 'a .. path'; Kind = 'dotdot'; Text = "whose path has a '\.\.' part" }
    ) {
        $Extra = switch ($Kind)
        {
            'many' { $script:Many }
            'packed' { $script:Packed }
            'dotdot' { [ordered]@{ '../outside.json' = $script:Inventory } }
        }
        $Case = New-Case -Name ('input-' + $Kind) -Extra $Extra

        $Run = Invoke-Reveal -Case $Case

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match ('FAIL: good - The report zip .* is over the zip limits the ingestion server holds every zip to: .*' + $Text)
        $Run.Text | Should -Not -Match 'Upload this single zip'
        Test-Path -LiteralPath $Case.Bundle | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Case.Staging 'ResourcesReport_good.zip') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Case.Dir 'root/outside.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Case.Dir 'outside.json') | Should -BeFalse
    }

    It 'refuses a single report over the limits' {
        $Case = New-Case -Name 'single' -Extra $script:Packed
        $Out = Join-Path $script:WorkDir 'single_out.zip'
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InputZip $Case.Source -DictionaryPath $Case.Dict -OutputZip $Out 2>&1 | ForEach-Object { [string]$_ })
        $LASTEXITCODE | Should -Not -Be 0
        (($Console -join ' ') -replace '\s+', ' ') | Should -Match 'is over the zip limits'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }
}

Describe 'Reveal holds each zip it writes to the limits' -Skip:$IsWindows {
    It 'does not move a revealed zip over the limits into place' {
        $Case = New-Case -Name 'written'
        $Out = Join-Path $Case.Dir 'revealed.zip'
        Mock Assert-RevealZipWithinLimits -ParameterFilter { $What -eq 'revealed zip' } { throw 'over the zip limits (test)' }

        { Invoke-RdaReveal -InputZip $Case.Source -DictionaryPath $Case.Dict -OutputZip $Out *> $null } | Should -Throw '*over the zip limits (test)*'

        Test-Path -LiteralPath $Out | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Case.Dir 'revealed.partial.zip') | Should -BeFalse
    }

    It 'does not move an unchanged copy over the limits into place' {
        $Case = New-Case -Name 'copied'
        $Out = Join-Path $Case.Dir 'copy.zip'
        Mock Assert-RevealZipWithinLimits -ParameterFilter { $What -eq 'revealed zip' } { throw 'over the zip limits (test)' }

        { Copy-RevealZipUnchanged -InputZip $Case.Source -OutputZip $Out } | Should -Throw '*over the zip limits (test)*'

        Test-Path -LiteralPath $Out | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Case.Dir 'copy.partial.zip') | Should -BeFalse
    }

    It 'does not write or announce an outer zip over the limits' {
        $Case = New-Case -Name 'bundle'
        Mock Assert-RevealZipWithinLimits -ParameterFilter { $What -eq 'outer zip' } { throw 'over the zip limits (test)' }

        $Text = (& $script:Reveal -InventoryRoot $Case.Root -StagingDirectory $Case.Staging -OutputZip $Case.Bundle -FolderTimeoutMinutes 5 6>&1 | ForEach-Object { [string]$_ }) -join "`n"

        $LASTEXITCODE | Should -Not -Be 0 -Because $Text
        $Text | Should -Match 'consolidating them into the outer zip FAILED'
        $Text | Should -Match 'over the zip limits \(test\)'
        $Text | Should -Not -Match 'Upload this single zip'
        Test-Path -LiteralPath $Case.Bundle | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Case.Dir 'bundle.partial.zip') | Should -BeFalse
        Should -Invoke Assert-RevealZipWithinLimits -ParameterFilter { $What -eq 'outer zip' } -Times 1 -Exactly
    }
}
