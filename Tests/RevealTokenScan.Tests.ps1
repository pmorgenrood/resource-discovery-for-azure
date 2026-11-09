# Reveal with an empty dictionary: the scan for masked values
# Run with: Invoke-Pester ./Tests/RevealTokenScan.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# When the dictionary gives nothing to reveal, Invoke-RdaReveal looks inside
# the report for any masked value. It read each zip entry whole with
# ReadToEnd(), so a large entry was held in memory as one string, and an entry
# longer than the largest string .NET can hold failed with an out-of-memory
# error instead of the 'Nothing to reveal' message. Reading line by line did
# not fix that: the tool writes Inventory_*.json and Metrics_*.json on one
# line, so a line can be the whole entry. It now reads fixed-size chunks, with
# the end of the previous chunk carried over so a token split across two
# chunks is still found, and stops at the first masked value.
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

    # 1 MiB of one-line JSON text with no masked value and no line break.
    $script:LineBlock = ('{"Name":"' + ('a' * 1012) + '"},') * 1024

    # The reveal scan's chunk length, in characters.
    $script:ChunkLength = 65536
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

    It 'finds a masked value near the end of a large one-line entry and still fails' {
        $Zip = Build-TestZip -Name 'oneline_late.zip' -Write {
            param($W)
            $W.Write('[')
            for ($i = 0; $i -lt 16; $i++) { $W.Write($script:LineBlock) }
            $W.Write('{"ID":"' + $script:Token + '"}]')
        }
        $Out = Join-Path $script:WorkDir 'oneline_late_out.zip'
        { Invoke-RdaReveal -InputZip $Zip -DictionaryPath $script:EmptyDict -OutputZip $Out 6>$null } |
            Should -Throw '*Nothing to reveal: the selected field*'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'finds a masked value split across two chunks' {
        # The token starts 20 characters before the end of the first chunk, so
        # neither chunk holds it whole.
        $Zip = Build-TestZip -Name 'straddle.zip' -Write {
            param($W)
            $W.Write('a' * ($script:ChunkLength - 20))
            $W.Write($script:Token)
            $W.Write('a' * $script:ChunkLength)
        }
        $Out = Join-Path $script:WorkDir 'straddle_out.zip'
        { Invoke-RdaReveal -InputZip $Zip -DictionaryPath $script:EmptyDict -OutputZip $Out 6>$null } |
            Should -Throw '*Nothing to reveal: the selected field*'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'stops at the first masked value of a one-line entry too long to hold as one string' {
        # 1,100 MiB on one line: longer than the largest .NET string, so reading
        # the line whole fails. The masked value is near the start.
        $Zip = Build-TestZip -Name 'oneline_huge.zip' -Write {
            param($W)
            $W.Write('[{"ID":"' + $script:Token + '"},')
            for ($i = 0; $i -lt 1100; $i++) { $W.Write($script:LineBlock) }
            $W.Write('{}]')
        }
        $Out = Join-Path $script:WorkDir 'oneline_huge_out.zip'
        { Invoke-RdaReveal -InputZip $Zip -DictionaryPath $script:EmptyDict -OutputZip $Out 6>$null } |
            Should -Throw '*Nothing to reveal: the selected field*'
        Test-Path -LiteralPath $Out | Should -BeFalse
    }

    It 'copies a large one-line entry with no masked value unchanged' {
        $Zip = Build-TestZip -Name 'oneline_clean.zip' -Write {
            param($W)
            $W.Write('[')
            for ($i = 0; $i -lt 16; $i++) { $W.Write($script:LineBlock) }
            $W.Write('{"ID":"prod_not-a-token"}]')
        }
        $Out = Join-Path $script:WorkDir 'oneline_clean_out.zip'
        Invoke-RdaReveal -InputZip $Zip -DictionaryPath $script:EmptyDict -OutputZip $Out 6>$null
        (Get-FileHash -LiteralPath $Out).Hash | Should -Be (Get-FileHash -LiteralPath $Zip).Hash
        Test-Path -LiteralPath (Join-Path $script:WorkDir 'oneline_clean_out.partial.zip') | Should -BeFalse
    }
}

# -Obfuscate writes 'obfuscated' or 'obfuscated_<guid>' for an id or name it
# could not mask, with no dictionary entry. The scan only knew prod_/nonprod_
# tokens, so a report whose only masked values were such sentinels was copied
# as having no masked values. The sentinel now counts too, but only as a whole
# value in a data file: a JSON string value equal to it in a .json member, or
# a CSV cell equal to it in a .csv member. The bare word in other text (the
# HTML report's privacy banner, a longer string, a key, part of a quoted cell)
# does not count.
Describe 'Invoke-RdaReveal with a dictionary that maps nothing: the obfuscated sentinel' {
    BeforeAll {
        $script:SentinelGuid = 'obfuscated_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

        # Writes a zip with the given entries (an ordered name -> text map).
        function Build-EntriesZip
        {
            param([string]$Name, [System.Collections.Specialized.OrderedDictionary]$Entries)
            $Path = Join-Path $script:WorkDir $Name
            $Archive = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
            try
            {
                foreach ($Key in $Entries.Keys)
                {
                    $Entry = $Archive.CreateEntry($Key, [System.IO.Compression.CompressionLevel]::Fastest)
                    $Writer = [System.IO.StreamWriter]::new($Entry.Open())
                    try { $Writer.Write([string]$Entries[$Key]) } finally { $Writer.Dispose() }
                }
            }
            finally { $Archive.Dispose() }
            return $Path
        }

        function Assert-Fails([string]$Zip)
        {
            $Out = $Zip -replace '\.zip$', '_out.zip'
            { Invoke-RdaReveal -InputZip $Zip -DictionaryPath $script:EmptyDict -OutputZip $Out 6>$null } |
                Should -Throw '*Nothing to reveal: the selected field*'
            Test-Path -LiteralPath $Out | Should -BeFalse
        }

        function Assert-CopiedUnchanged([string]$Zip)
        {
            $Out = $Zip -replace '\.zip$', '_out.zip'
            Invoke-RdaReveal -InputZip $Zip -DictionaryPath $script:EmptyDict -OutputZip $Out 6>$null
            (Get-FileHash -LiteralPath $Out).Hash | Should -Be (Get-FileHash -LiteralPath $Zip).Hash
        }
    }

    It 'fails on a JSON value that is exactly "obfuscated"' {
        Assert-Fails (Build-EntriesZip -Name 's_json_word.zip' -Entries ([ordered]@{
                    'Inventory_test.json' = '{"VMDisk":[{"Name":"disk","AssociatedResource":"obfuscated"}]}'
                }))
    }

    It 'fails on a JSON value that is exactly "obfuscated_<guid>", pretty printed' {
        Assert-Fails (Build-EntriesZip -Name 's_json_guid.zip' -Entries ([ordered]@{
                    'Inventory_test.json' = "{`n  `"Resources`": [`n    {`n      `"ID`": `"$($script:SentinelGuid)`"`n    }`n  ]`n}"
                }))
    }

    It 'fails on a CSV cell that is exactly obfuscated, unquoted and quoted' {
        Assert-Fails (Build-EntriesZip -Name 's_csv_bare.zip' -Entries ([ordered]@{
                    'Consumption_test.csv' = "ResourceId,ReservationId,Cost`n/x,obfuscated,1.5`n"
                }))
        Assert-Fails (Build-EntriesZip -Name 's_csv_quoted.zip' -Entries ([ordered]@{
                    'Consumption_test.csv' = "`"ResourceId`",`"ReservationId`",`"Cost`"`n`"/x`",`"$($script:SentinelGuid)`",`"1.5`""
                }))
    }

    It 'fails on a JSON sentinel value split across two chunks' {
        $Pad = '{"Name":"' + ('a' * ($script:ChunkLength - 20)) + '","ID":"'
        Assert-Fails (Build-EntriesZip -Name 's_json_straddle.zip' -Entries ([ordered]@{
                    'Inventory_test.json' = $Pad + $script:SentinelGuid + '"}'
                }))
    }

    It 'fails on a CSV that ends with a sentinel cell exactly on a chunk boundary' {
        $Head = "ResourceId,ReservationId`n/" + ('a' * $script:ChunkLength) + ','
        $Text = $Head + $script:SentinelGuid
        $Text = $Text.Substring($Text.Length % $script:ChunkLength)
        $Text.Length % $script:ChunkLength | Should -Be 0
        $Text | Should -Match ',obfuscated_[0-9a-f-]{36}$'
        Assert-Fails (Build-EntriesZip -Name 's_csv_boundary.zip' -Entries ([ordered]@{ 'Consumption_test.csv' = $Text }))
    }

    It 'copies a report whose only "obfuscated" is ordinary text unchanged' {
        Assert-CopiedUnchanged (Build-EntriesZip -Name 's_text.zip' -Entries ([ordered]@{
                    'ResourcesReport_test.html' = '<p class="banner">This report is obfuscated. Names show as "obfuscated" where they could not be masked.</p><td>obfuscated</td>'
                    'Inventory_test.json'       = '{"Note":"this report is obfuscated","obfuscated":1,"Quote":"say \"obfuscated\", then","Tail":"obfuscated_"}'
                    'Consumption_test.csv'      = "A,B,C`n`"a,obfuscated,b`",not obfuscated,`"{`"`"ResourceUri`"`":`"`"obfuscated`"`"}`"`nobfuscatedx,xobfuscated,`"`"`"obfuscated`"`"`"`n"
                    'Readme.txt'                = 'obfuscated'
                }))
    }

    It 'copies a CSV whose quoted cell spans a chunk boundary and holds ,obfuscated, unchanged' {
        $Text = "A,B`n`"" + ('a' * $script:ChunkLength) + ',obfuscated,' + 'b",c' + "`n"
        Assert-CopiedUnchanged (Build-EntriesZip -Name 's_csv_span.zip' -Entries ([ordered]@{ 'Consumption_test.csv' = $Text }))
    }
}
