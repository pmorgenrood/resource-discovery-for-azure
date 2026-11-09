# Reveal with relative zip paths
# Run with: Invoke-Pester ./Tests/RevealRelativePaths.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Invoke-RdaReveal passed -InputZip and -OutputZip as given to the .NET zip
# and file calls, which resolve a relative path against the process folder,
# not the PowerShell location. After Set-Location, a relative input zip was
# not found (or the wrong one was read) and the output was written to the
# wrong folder; with no -OutputZip the default output path could not be built.
# Both paths are now resolved against the PowerShell location once, at the top.
#
# The zip and dictionary are built here with placeholder values; no live Azure.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    . (Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'

    function Build-RevealFolder
    {
        param([string]$DictJson)
        $Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealRelativePaths_' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $Dir 'reports') -Force
        Set-Content -LiteralPath (Join-Path $Dir 'reports/ObfuscationDictionary_test.json') -Encoding utf8 -Value $DictJson
        $Archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Dir 'reports/report.zip'), 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_test.json').Open())
            try { $Writer.Write('{"ResourceGroup": "' + $script:Token + '"}') } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        return $Dir
    }

    function Get-EntryText([string]$Path)
    {
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try
        {
            $Reader = [System.IO.StreamReader]::new($Archive.Entries[0].Open())
            try { return $Reader.ReadToEnd() } finally { $Reader.Dispose() }
        }
        finally { $Archive.Dispose() }
    }

    $script:MapJson = '{"ResourceGroupMap":{"' + $script:Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-placeholder"}}'
    $script:EmptyJson = '{"ResourceGroupMap":{}}'
}

Describe 'Invoke-RdaReveal with relative paths after Set-Location' {
    BeforeEach {
        $script:Before = Get-Location
        $script:ProcessDir = [System.Environment]::CurrentDirectory
    }

    AfterEach {
        Set-Location -LiteralPath $script:Before
        if ($script:Dir -and (Test-Path -LiteralPath $script:Dir)) { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reads the input and writes -OutputZip relative to the PowerShell location' {
        $script:Dir = Build-RevealFolder -DictJson $script:MapJson
        Set-Location -LiteralPath $script:Dir
        [System.Environment]::CurrentDirectory | Should -Not -Be $script:Dir -Because 'the process folder must differ from the PowerShell location for this test'

        Invoke-RdaReveal -InputZip 'reports/report.zip' -DictionaryPath 'reports/ObfuscationDictionary_test.json' -OutputZip 'reports/out.zip' 6>$null

        $Out = Join-Path $script:Dir 'reports/out.zip'
        Test-Path -LiteralPath $Out | Should -BeTrue
        Get-EntryText $Out | Should -Match 'rg-placeholder'
        Test-Path -LiteralPath (Join-Path $script:ProcessDir 'reports/out.zip') | Should -BeFalse
    }

    It 'writes the default output next to a relative input' {
        $script:Dir = Build-RevealFolder -DictJson $script:MapJson
        Set-Location -LiteralPath (Join-Path $script:Dir 'reports')

        Invoke-RdaReveal -InputZip 'report.zip' -DictionaryPath 'ObfuscationDictionary_test.json' 6>$null

        $Out = Join-Path $script:Dir 'reports/report_revealed.zip'
        Test-Path -LiteralPath $Out | Should -BeTrue
        Get-EntryText $Out | Should -Match 'rg-placeholder'
    }

    It 'writes the unchanged copy of a report with nothing to reveal relative to the PowerShell location' {
        $script:Dir = Build-RevealFolder -DictJson $script:EmptyJson
        $Zip = Join-Path $script:Dir 'reports/report.zip'
        # Remove the masked value, so the report has nothing to reveal.
        Remove-Item -LiteralPath $Zip
        $Archive = [System.IO.Compression.ZipFile]::Open($Zip, 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_test.json').Open())
            try { $Writer.Write('{"VirtualMachines": []}') } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        Set-Location -LiteralPath $script:Dir

        Invoke-RdaReveal -InputZip 'reports/report.zip' -DictionaryPath 'reports/ObfuscationDictionary_test.json' -OutputZip 'reports/out.zip' 6>$null

        $Out = Join-Path $script:Dir 'reports/out.zip'
        (Get-FileHash -LiteralPath $Out).Hash | Should -Be (Get-FileHash -LiteralPath $Zip).Hash
    }
}
