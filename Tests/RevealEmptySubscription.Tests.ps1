# Reveal of a subscription with no resources
# Run with: Invoke-Pester ./Tests/RevealEmptySubscription.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# An obfuscated report of a subscription with no resources carries no masked
# values, and its dictionary is empty. Reveal.ps1 failed that folder with
# 'Nothing to reveal: the selected field(s) [...] produced no token mappings
# from this dictionary.', left it out of the revealed bundle and ended with
# exit 4. It now writes an unchanged copy of that report. A report that does
# carry masked values with no mapping for the selected fields still fails.
#
# The test runs the REAL ResourceInventory.ps1 with -Obfuscate in a child pwsh
# (Tests/Helpers/InnerRunHarness.ps1, offline stand-ins) for one subscription
# with no resources and one with a disk, each into its own folder under one
# inventory root, then the REAL Reveal.ps1: over the whole root (default
# fields and -All), on the empty report alone, and on the disk's report with
# the empty report's dictionary. Reveal runs under en-US and tr-TR.
# Placeholder ids only; no live Azure.
#
# Not run on Windows: the harness's stand-ins are written for the Unix paths.

BeforeDiscovery {
    $script:Cultures = @(@{ Culture = 'en-US' }, @{ Culture = 'tr-TR' })
}

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Harness = Join-Path $PSScriptRoot 'Helpers/InnerRunHarness.ps1'
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealEmptySubscription_' + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    $null = New-Item -ItemType Directory -Path $script:Tree -Force
    foreach ($Item in @('ResourceInventory.ps1', 'Reveal.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    # The obfuscated reports, made once: <Source>/empty and <Source>/disk.
    $script:Source = Join-Path $script:WorkDir 'source'
    foreach ($Case in @(@{ Name = 'empty'; Args = @('-NoResources') }, @{ Name = 'disk'; Args = @('-SubIds', '12345678-1234-1234-1234-123456789012') }))
    {
        $Out = Join-Path $script:Source $Case.Name
        $null = New-Item -ItemType Directory -Path $Out -Force
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Harness -Tree $script:Tree -Out $Out -Obfuscate @($Case.Args) 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) { throw ("the {0} inventory run ended with {1}:`n{2}" -f $Case.Name, $LASTEXITCODE, ($Console -join "`n")) }
    }

    # A fresh inventory root holding copies of the reports.
    function New-InventoryRoot
    {
        $Root = Join-Path $script:WorkDir ('root_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $Root -Force
        Copy-Item -LiteralPath (Join-Path $script:Source 'empty') -Destination $Root -Recurse
        Copy-Item -LiteralPath (Join-Path $script:Source 'disk') -Destination $Root -Recurse
        return $Root
    }

    # Reveal.ps1 in a child pwsh with the given culture; returns its exit code and console.
    function Invoke-Reveal
    {
        param([string]$Culture, [string[]]$RevealArgs)
        $Quoted = @($RevealArgs | ForEach-Object { if ($_ -like '-*') { $_ } else { "'" + ($_ -replace "'", "''") + "'" } }) -join ' '
        $Command = "[System.Globalization.CultureInfo]::CurrentCulture = '$Culture'; Set-Location -LiteralPath '$($script:Tree)'; & ./Reveal.ps1 $Quoted; exit `$LASTEXITCODE"
        $Console = @(& pwsh -NoProfile -NonInteractive -Command $Command 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Console = $Console; Text = ($Console -join "`n") }
    }

    function Get-ZipEntryNames([string]$Path)
    {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return @($Archive.Entries | ForEach-Object FullName) } finally { $Archive.Dispose() }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal under <Culture>' -ForEach $script:Cultures -Skip:$IsWindows {
    Context 'every folder of an inventory root, one subscription with no resources' {
        BeforeAll {
            $script:Root = New-InventoryRoot
            $script:OutZip = Join-Path $script:Root 'bundle.zip'
            $script:Run = Invoke-Reveal -Culture $Culture -RevealArgs @('-InventoryRoot', $script:Root, '-OutputZip', $script:OutZip)
        }

        It 'ends with exit 0 and no failed folder' {
            $script:Run.Exit | Should -Be 0 -Because $script:Run.Text
            $script:Run.Text | Should -Match 'Failed during reveal\s+: 0'
            $script:Run.Text | Should -Not -Match 'FAIL: '
        }

        It 'puts both subscriptions'' reports in the bundle' {
            $Entries = Get-ZipEntryNames $script:OutZip
            @($Entries).Count | Should -Be 2 -Because ($Entries -join ', ')
        }
    }

    Context 'every folder with -All' {
        BeforeAll {
            $script:Root = New-InventoryRoot
            $script:OutZip = Join-Path $script:Root 'bundle.zip'
            $script:Run = Invoke-Reveal -Culture $Culture -RevealArgs @('-InventoryRoot', $script:Root, '-OutputZip', $script:OutZip, '-All', '-RemoveStaging')
        }

        It 'ends with exit 0, both reports in the bundle, staging removed' {
            $script:Run.Exit | Should -Be 0 -Because $script:Run.Text
            @(Get-ZipEntryNames $script:OutZip).Count | Should -Be 2
            $script:Run.Text | Should -Match 'Removed staging directory'
        }
    }

    Context 'the empty report alone' {
        BeforeAll {
            $script:Dir = Join-Path (New-InventoryRoot) 'empty'
            $script:InZip = @(Get-ChildItem -LiteralPath $script:Dir -Filter 'ResourcesReport_*.zip' -File)[0].FullName
            $script:Dict = @(Get-ChildItem -LiteralPath $script:Dir -Filter 'ObfuscationDictionary_*.json' -File)[0].FullName
            $script:OutZip = Join-Path $script:Dir 'revealed.zip'
            $script:Run = Invoke-Reveal -Culture $Culture -RevealArgs @('-InputZip', $script:InZip, '-DictionaryPath', $script:Dict, '-OutputZip', $script:OutZip)
        }

        It 'ends with exit 0 and says it wrote an unchanged copy' {
            $script:Run.Exit | Should -Be 0 -Because $script:Run.Text
            $script:Run.Text | Should -Match 'Wrote an unchanged copy'
        }

        It 'writes a copy byte for byte, and no .partial.zip' {
            (Get-FileHash -LiteralPath $script:OutZip).Hash | Should -Be (Get-FileHash -LiteralPath $script:InZip).Hash
            Test-Path -LiteralPath (Join-Path $script:Dir 'revealed.partial.zip') | Should -BeFalse
        }
    }

    Context 'a report with masked values and the empty dictionary' {
        BeforeAll {
            $script:Root = New-InventoryRoot
            $script:InZip = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'disk') -Filter 'ResourcesReport_*.zip' -File)[0].FullName
            $script:Dict = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'empty') -Filter 'ObfuscationDictionary_*.json' -File)[0].FullName
            $script:OutZip = Join-Path $script:Root 'wrong.zip'
            $script:Run = Invoke-Reveal -Culture $Culture -RevealArgs @('-InputZip', $script:InZip, '-DictionaryPath', $script:Dict, '-OutputZip', $script:OutZip)
        }

        It 'still fails with Nothing to reveal and writes no zip' {
            $script:Run.Exit | Should -Not -Be 0
            $script:Run.Text | Should -Match 'Nothing to reveal: the selected field'
            Test-Path -LiteralPath $script:OutZip | Should -BeFalse
        }
    }
}
