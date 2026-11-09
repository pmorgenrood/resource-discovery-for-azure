# Reveal -RemoveStaging: why the staging folder was kept
# Run with: Invoke-Pester ./Tests/RevealRemoveStagingMessage.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Reveal.ps1 -RemoveStaging keeps the staging folder when the run was not
# clean. When every folder was revealed and only the outer zip could not be
# built, it still said '-RemoveStaging skipped: 0 folder(s) failed or timed
# out. Staging kept so you can recover them with -Resume:'. It now names the
# outer zip as the cause, and keeps the folder wording for failed folders.
#
# The test runs the REAL ResourceInventory.ps1 with -Obfuscate in a child pwsh
# (Tests/Helpers/InnerRunHarness.ps1, offline stand-ins) to make one
# subscription's obfuscated report, then the REAL Reveal.ps1 -RemoveStaging
# over an inventory root: clean; with -OutputZip in a folder that does not
# exist (only the outer zip fails); with a second folder whose zip is not a
# zip (only that folder fails); and with both. Reveal runs under en-US and
# tr-TR. Placeholder ids only; no live Azure.
#
# Not run on Windows: the harness's stand-ins are written for the Unix paths.

BeforeDiscovery {
    $script:Cases = @(
        foreach ($Culture in @('en-US', 'tr-TR'))
        {
            @{ Culture = $Culture; Name = 'clean'; BadFolder = $false; BadZip = $false; Exit = 0 }
            @{ Culture = $Culture; Name = 'only the outer zip fails'; BadFolder = $false; BadZip = $true; Exit = 1 }
            @{ Culture = $Culture; Name = 'only a folder fails'; BadFolder = $true; BadZip = $false; Exit = 4 }
            @{ Culture = $Culture; Name = 'a folder and the outer zip fail'; BadFolder = $true; BadZip = $true; Exit = 1 }
        }
    )
}

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Harness = Join-Path $PSScriptRoot 'Helpers/InnerRunHarness.ps1'
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealRemoveStagingMessage_' + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    $null = New-Item -ItemType Directory -Path $script:Tree -Force
    foreach ($Item in @('ResourceInventory.ps1', 'Reveal.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    $script:Source = Join-Path $script:WorkDir 'source/disk'
    $null = New-Item -ItemType Directory -Path $script:Source -Force
    $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Harness -Tree $script:Tree -Out $script:Source -Obfuscate 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw ("the inventory run ended with {0}:`n{1}" -f $LASTEXITCODE, ($Console -join "`n")) }

    function Invoke-RemoveStagingRun
    {
        param([string]$Culture, [bool]$BadFolder, [bool]$BadZip)
        $Root = Join-Path $script:WorkDir ('root_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $Root -Force
        Copy-Item -LiteralPath $script:Source -Destination $Root -Recurse
        if ($BadFolder)
        {
            # A folder of a second subscription whose report zip cannot be
            # read, with a real dictionary beside it. The dictionary is the
            # first one with its subscription ids changed to another
            # placeholder: Reveal reveals only the newest report of each
            # subscription, so a copy for the same subscription would be left
            # out as an older run instead of failing.
            $Bad = Join-Path $Root 'broken'
            $null = New-Item -ItemType Directory -Path $Bad -Force
            Set-Content -LiteralPath (Join-Path $Bad 'ResourcesReport_20260101000000000abcd.zip') -Value 'not a zip' -Encoding utf8
            $DictText = [System.IO.File]::ReadAllText(@(Get-ChildItem -LiteralPath $script:Source -Filter 'ObfuscationDictionary_*.json' -File)[0].FullName)
            $DictText = [regex]::Replace($DictText, '(?i)(/subscriptions/)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '${1}ffffffff-ffff-ffff-ffff-ffffffffffff')
            [System.IO.File]::WriteAllText((Join-Path $Bad 'ObfuscationDictionary_ResourcesReport_20260101000000000abcd.json'), $DictText)
        }
        $OutZip = if ($BadZip) { Join-Path $Root 'no-such-folder/bundle.zip' } else { Join-Path $Root 'bundle.zip' }
        $Command = "[System.Globalization.CultureInfo]::CurrentCulture = '$Culture'; Set-Location -LiteralPath '$($script:Tree)'; & ./Reveal.ps1 -InventoryRoot '$Root' -OutputZip '$OutZip' -RemoveStaging -FolderTimeoutMinutes 2; exit `$LASTEXITCODE"
        $Console = @(& pwsh -NoProfile -NonInteractive -Command $Command 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{
            Exit    = $LASTEXITCODE
            Console = $Console
            Text    = ($Console -join "`n")
            Staging = @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'RevealedStaging_*')
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal -RemoveStaging under <Culture>: <Name>' -ForEach $script:Cases -Skip:$IsWindows {
    BeforeAll {
        $script:Run = Invoke-RemoveStagingRun -Culture $Culture -BadFolder $BadFolder -BadZip $BadZip
    }

    It 'ends with exit <Exit>' {
        $script:Run.Exit | Should -Be $Exit -Because $script:Run.Text
    }

    It 'removes staging only on a clean run' {
        @($script:Run.Staging).Count | Should -Be $(if ($BadFolder -or $BadZip) { 1 } else { 0 })
    }

    It 'blames failed folders only when a folder failed' {
        $Lines = @($script:Run.Console | Where-Object { $_ -like '-RemoveStaging skipped: * folder(s) failed or timed out.*' })
        if ($BadFolder) { $Lines | Should -Be @('-RemoveStaging skipped: 1 folder(s) failed or timed out. Staging kept so you can recover them with -Resume:') }
        else { $Lines.Count | Should -Be 0 -Because ($Lines -join "`n") }
    }

    It 'blames the outer zip only when it could not be built' {
        $Lines = @($script:Run.Console | Where-Object { $_ -like '-RemoveStaging skipped: the outer zip could not be built*' })
        $Lines.Count | Should -Be $(if ($BadZip) { 1 } else { 0 })
    }
}
