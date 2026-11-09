# Reveal counts a report pair as paired once its zip and dictionary make one pair
# Run with: Invoke-Pester ./Tests/RevealPairedCount.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# 'Paired (zip + dictionary)' says it counts every whole pair, but it was
# counted only after the dictionary was read, so a report zip with exactly one
# dictionary of its stamp that could not be read was reported as failed and
# not as paired. It is now counted once the one-to-one file pair is found.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealPairedCount_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 Paired count' {
    It 'counts a pair whose dictionary cannot be read' {
        $Sub = Join-Path $script:WorkDir 'root/broken'
        $null = New-Item -ItemType Directory -Path $Sub -Force
        $Archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Sub 'ResourcesReport_x.zip'), 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_r.json').Open())
            try { $Writer.Write('{"VirtualMachines":[]}') } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        [System.IO.File]::WriteAllText((Join-Path $Sub 'ObfuscationDictionary_ResourcesReport_x.json'), '{ not json')

        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot (Join-Path $script:WorkDir 'root') -StagingDirectory (Join-Path $script:WorkDir 'staging') -OutputZip (Join-Path $script:WorkDir 'bundle.zip') -FolderTimeoutMinutes 5 2>&1 | ForEach-Object { [string]$_ })
        $Text = $Console -join "`n"

        $LASTEXITCODE | Should -Not -Be 0 -Because $Text
        $Text | Should -Match 'FAIL: broken - the dictionary ObfuscationDictionary_ResourcesReport_x\.json could not be read'
        $Text | Should -Match 'Paired \(zip \+ dictionary\)\s+: 1'
    }
}
