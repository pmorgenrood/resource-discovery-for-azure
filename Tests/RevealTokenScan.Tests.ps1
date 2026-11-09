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

    # Reveal holds every zip to the ingestion server's limits, one of which is
    # at most 100 to 1 compression. The long runs of one character these tests
    # write compress far more than that, so each zip also gets a stored entry
    # of random bytes, which keeps the whole zip within the limit. It is not
    # a .json or .csv member, and random bytes hold no masked value.
    function Add-Padding
    {
        param([System.IO.Compression.ZipArchive]$Archive, [long]$Bytes)
        $Entry = $Archive.CreateEntry('Padding.bin', [System.IO.Compression.CompressionLevel]::NoCompression)
        $Stream = $Entry.Open()
        try
        {
            $Buffer = [byte[]]::new(1MB)
            for ($Left = $Bytes; $Left -gt 0; $Left -= $Buffer.Length)
            {
                [System.Security.Cryptography.RandomNumberGenerator]::Fill($Buffer)
                $Stream.Write($Buffer, 0, [int][Math]::Min($Left, $Buffer.Length))
            }
        }
        finally { $Stream.Dispose() }
    }

    # Writes a zip with one entry; the script block writes the entry's text.
    # The entries here are at most about 1.1 GiB, so 16 MiB of padding keeps
    # the zip within 100 to 1.
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
            Add-Padding -Archive $Archive -Bytes 16MB
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
# does not count. A JSON sentinel string whose closing ',' ']' or '}' came
# after white space past the end of the scan window was missed: no one window
# held both. The scan now remembers such a string and checks the first other
# character after it in the next window.
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
                $Total = [long]0
                foreach ($Key in $Entries.Keys)
                {
                    $Entry = $Archive.CreateEntry($Key, [System.IO.Compression.CompressionLevel]::Fastest)
                    $Writer = [System.IO.StreamWriter]::new($Entry.Open())
                    try { $Writer.Write([string]$Entries[$Key]) } finally { $Writer.Dispose() }
                    $Total += [System.Text.Encoding]::UTF8.GetByteCount([string]$Entries[$Key])
                }
                # Keeps the zip within 100 to 1 (see Add-Padding).
                Add-Padding -Archive $Archive -Bytes ([long][Math]::Ceiling($Total / 50) + 1)
            }
            finally { $Archive.Dispose() }
            return $Path
        }

        function Assert-RevealFailure([string]$Zip)
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
        Assert-RevealFailure (Build-EntriesZip -Name 's_json_word.zip' -Entries ([ordered]@{
                    'Inventory_test.json' = '{"VMDisk":[{"Name":"disk","AssociatedResource":"obfuscated"}]}'
                }))
    }

    It 'fails on a JSON value that is exactly "obfuscated_<guid>", pretty printed' {
        Assert-RevealFailure (Build-EntriesZip -Name 's_json_guid.zip' -Entries ([ordered]@{
                    'Inventory_test.json' = "{`n  `"Resources`": [`n    {`n      `"ID`": `"$($script:SentinelGuid)`"`n    }`n  ]`n}"
                }))
    }

    It 'fails on a CSV cell that is exactly obfuscated, unquoted and quoted' {
        Assert-RevealFailure (Build-EntriesZip -Name 's_csv_bare.zip' -Entries ([ordered]@{
                    'Consumption_test.csv' = "ResourceId,ReservationId,Cost`n/x,obfuscated,1.5`n"
                }))
        Assert-RevealFailure (Build-EntriesZip -Name 's_csv_quoted.zip' -Entries ([ordered]@{
                    'Consumption_test.csv' = "`"ResourceId`",`"ReservationId`",`"Cost`"`n`"/x`",`"$($script:SentinelGuid)`",`"1.5`""
                }))
    }

    It 'fails on a JSON sentinel value split across two chunks' {
        $Pad = '{"Name":"' + ('a' * ($script:ChunkLength - 20)) + '","ID":"'
        Assert-RevealFailure (Build-EntriesZip -Name 's_json_straddle.zip' -Entries ([ordered]@{
                    'Inventory_test.json' = $Pad + $script:SentinelGuid + '"}'
                }))
    }

    It 'fails on a CSV that ends with a sentinel cell exactly on a chunk boundary' {
        $Head = "ResourceId,ReservationId`n/" + ('a' * $script:ChunkLength) + ','
        $Text = $Head + $script:SentinelGuid
        $Text = $Text.Substring($Text.Length % $script:ChunkLength)
        $Text.Length % $script:ChunkLength | Should -Be 0
        $Text | Should -Match ',obfuscated_[0-9a-f-]{36}$'
        Assert-RevealFailure (Build-EntriesZip -Name 's_csv_boundary.zip' -Entries ([ordered]@{ 'Consumption_test.csv' = $Text }))
    }

    # The scan carries the last 127 characters of each window into the next,
    # so the carry of the first window starts at ($ChunkLength - 127). A
    # sentinel that starts there is at the start of the next window, where a
    # match is skipped as having no context. These place a sentinel's opening
    # quote (JSON) or its cell start (CSV) exactly there.
    It 'fails on a JSON sentinel value whose opening quote is the first character of the carry' {
        $Pre = '{"N":"' + ('a' * ($script:ChunkLength - 127 - 12)) + '","I":'
        $Pre.Length | Should -Be ($script:ChunkLength - 127)
        Assert-RevealFailure (Build-EntriesZip -Name 's_json_carry.zip' -Entries ([ordered]@{
                    'Inventory_test.json' = $Pre + '"' + $script:SentinelGuid + '"}'
                }))
    }

    It 'fails on a JSON sentinel value at the carry start whose closing brace comes after a long run of white space' {
        # The white space is longer than the carry, so no one window holds both
        # the sentinel string and the '}' that makes it a value.
        $Pre = '{"N":"' + ('a' * ($script:ChunkLength - 127 - 12)) + '","I":'
        Assert-RevealFailure (Build-EntriesZip -Name 's_json_carry_ws.zip' -Entries ([ordered]@{
                    'Inventory_test.json' = $Pre + '"' + $script:SentinelGuid + '"' + (' ' * 200) + '}'
                }))
        Assert-RevealFailure (Build-EntriesZip -Name 's_json_carry_ws_word.zip' -Entries ([ordered]@{
                    'Inventory_test.json' = $Pre + '"obfuscated"' + "`n" + (' ' * 150) + "`n}"
                }))
    }

    It 'fails on a JSON sentinel value followed by white space that runs past a whole window' {
        $Pre = '{"N":"' + ('a' * ($script:ChunkLength - 400)) + '","I":'
        Assert-RevealFailure (Build-EntriesZip -Name 's_json_long_ws.zip' -Entries ([ordered]@{
                    'Inventory_test.json' = $Pre + '"obfuscated"' + (' ' * ($script:ChunkLength + 500)) + ']}'
                }))
    }

    It 'copies a JSON key "obfuscated" followed by a long run of white space unchanged' {
        $Pre = '{"N":"' + ('a' * ($script:ChunkLength - 127 - 12)) + '",'
        Assert-CopiedUnchanged (Build-EntriesZip -Name 's_json_key_ws.zip' -Entries ([ordered]@{
                    'Inventory_test.json' = $Pre + ' "obfuscated"' + (' ' * 300) + ':1}'
                }))
    }

    It 'fails on a CSV sentinel cell that starts at the first character of the carry' {
        $Pre = "A,B`n/" + ('a' * ($script:ChunkLength - 127 - 6)) + ','
        $Pre.Length | Should -Be ($script:ChunkLength - 127)
        Assert-RevealFailure (Build-EntriesZip -Name 's_csv_carry_bare.zip' -Entries ([ordered]@{
                    'Consumption_test.csv' = $Pre + 'obfuscated,1' + "`n"
                }))
        Assert-RevealFailure (Build-EntriesZip -Name 's_csv_carry_quoted.zip' -Entries ([ordered]@{
                    'Consumption_test.csv' = $Pre + '"' + $script:SentinelGuid + '",1' + "`n"
                }))
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
