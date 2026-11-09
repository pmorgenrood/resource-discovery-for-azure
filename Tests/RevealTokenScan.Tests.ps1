# Reveal with an empty dictionary: the scan for masked values
# Run with: Invoke-Pester ./Tests/RevealTokenScan.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# When the dictionary gives nothing to reveal, Invoke-RdaReveal looks inside
# the report for any masked value. It read each zip entry whole with
# ReadToEnd(), so a large entry was held in memory as one string, and an entry
# longer than the largest string .NET can hold failed with an out-of-memory
# error instead of the 'Nothing to reveal' message. It now reads line by line
# and stops at the first masked value.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    . (Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealTokenScan_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'

    # A dictionary with every map empty.
    $script:EmptyDict = Join-Path $script:WorkDir 'ObfuscationDictionary_empty.json'
    Set-Content -LiteralPath $script:EmptyDict -Encoding utf8 -Value '{"ResourceGroupMap":{},"SubscriptionMap":{},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'

    # Writes a zip with one entry; the script block writes the entry's text.
    function Build-TestZip
    {
        param([string]$Name, [scriptblock]$Write)
        $Path = Join-Path $script:WorkDir $Name
        $Archive = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
        try
        {
            $Entry = $Archive.CreateEntry('Inventory_test.json', [System.IO.Compression.CompressionLevel]::Fastest)
            $Writer = [System.IO.StreamWriter]::new($Entry.Open())
            try { & $Write $Writer } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        return $Path
    }

    # 1024 short lines with no masked value (1 MiB of text).
    $script:Block = (('"Name": "' + ('a' * 1012) + '",') + "`n") * 1024
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-RdaReveal with a dictionary that maps nothing' {
    It 'finds a masked value on a later line of a large entry and still fails' {
        $Zip = Build-TestZip -Name 'late.zip' -Write {
            param($W)
            for ($i = 0; $i -lt 32; $i++) { $W.Write($script:Block) }
            $W.WriteLine('"ID": "' + $script:Token + '"')
            $W.Write($script:Block)
        }
        $Out = Join-Path $script:WorkDir 'late_out.zip'
        { Invoke-RdaReveal -InputZip $Zip -DictionaryPath $script:EmptyDict -OutputZip $Out 6>$null } |
            Should -Throw '*Nothing to reveal: the selected field*'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'stops at the first masked value of an entry too long to hold as one string' {
        # 1,100 MiB of text: longer than the largest .NET string, so reading the
        # entry whole fails. The masked value is on the first line.
        $Zip = Build-TestZip -Name 'huge.zip' -Write {
            param($W)
            $W.WriteLine('"ID": "' + $script:Token + '"')
            for ($i = 0; $i -lt 1100; $i++) { $W.Write($script:Block) }
        }
        $Out = Join-Path $script:WorkDir 'huge_out.zip'
        { Invoke-RdaReveal -InputZip $Zip -DictionaryPath $script:EmptyDict -OutputZip $Out 6>$null } |
            Should -Throw '*Nothing to reveal: the selected field*'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'copies an entry with no masked value unchanged' {
        $Zip = Build-TestZip -Name 'clean.zip' -Write {
            param($W)
            for ($i = 0; $i -lt 8; $i++) { $W.Write($script:Block) }
            $W.Write('"ID": "prod_not-a-token"')
        }
        $Out = Join-Path $script:WorkDir 'clean_out.zip'
        Invoke-RdaReveal -InputZip $Zip -DictionaryPath $script:EmptyDict -OutputZip $Out 6>$null
        (Get-FileHash -LiteralPath $Out).Hash | Should -Be (Get-FileHash -LiteralPath $Zip).Hash
        Test-Path -LiteralPath (Join-Path $script:WorkDir 'clean_out.partial.zip') | Should -BeFalse
    }
}
