# Run dictionary lookup tests
# Run with: Invoke-Pester ./Tests/RunDictionaryPath.Tests.ps1 -Output Detailed
#
# The zip-backed tests find the obfuscation dictionary of the run that made the
# test zip with Get-RunDictionaryPath (Helpers/RunDictionaryPath.ps1). These
# tests pin it on empty files in a temp folder: no zip content and no Azure.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/RunDictionaryPath.ps1')
    $script:SavedZip = $env:TEST_ZIP_PATH
    $script:SavedDict = $env:TEST_DICT_PATH
}

AfterAll {
    $env:TEST_ZIP_PATH = $script:SavedZip
    $env:TEST_DICT_PATH = $script:SavedDict
}

Describe 'Get-RunDictionaryPath' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('rundict-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        # Two runs in one folder; the second one is newer.
        foreach ($Run in @('ResourcesReport_20261101000000000a', 'ResourcesReport_20261102000000000b'))
        {
            New-Item -ItemType File -Path (Join-Path $script:Dir "$Run.zip") | Out-Null
            New-Item -ItemType File -Path (Join-Path $script:Dir "ObfuscationDictionary_$Run.json") | Out-Null
        }
        $Old = (Get-Date).AddHours(-1)
        foreach ($F in Get-ChildItem $script:Dir -Filter '*000a*') { $F.LastWriteTime = $Old }
        $env:TEST_DICT_PATH = $null
    }

    AfterEach {
        if ($script:Dir -and (Test-Path $script:Dir)) { Remove-Item -Recurse -Force $script:Dir }
    }

    It 'takes the dictionary of the given zip, not the newest one in its folder' {
        $env:TEST_ZIP_PATH = Join-Path $script:Dir 'ResourcesReport_20261101000000000a.zip'
        Get-RunDictionaryPath -TestsRoot $script:Dir | Should -Be (Join-Path $script:Dir 'ObfuscationDictionary_ResourcesReport_20261101000000000a.json')
    }

    It 'takes the dictionary of the newest zip when no zip is given' {
        $env:TEST_ZIP_PATH = $null
        Get-RunDictionaryPath -TestsRoot $script:Dir | Should -Be (Join-Path $script:Dir 'ObfuscationDictionary_ResourcesReport_20261102000000000b.json')
    }

    It 'gives no dictionary when the given zip has none of its own' {
        Remove-Item (Join-Path $script:Dir 'ObfuscationDictionary_ResourcesReport_20261101000000000a.json')
        $env:TEST_ZIP_PATH = Join-Path $script:Dir 'ResourcesReport_20261101000000000a.zip'
        Get-RunDictionaryPath -TestsRoot $script:Dir | Should -BeNullOrEmpty
    }

    It 'takes TEST_DICT_PATH when it is set' {
        $env:TEST_ZIP_PATH = Join-Path $script:Dir 'ResourcesReport_20261101000000000a.zip'
        $env:TEST_DICT_PATH = Join-Path $script:Dir 'ObfuscationDictionary_ResourcesReport_20261102000000000b.json'
        Get-RunDictionaryPath -TestsRoot $script:Dir | Should -Be $env:TEST_DICT_PATH
    }
}
