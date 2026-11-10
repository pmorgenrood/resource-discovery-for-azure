# Reveal: members are revealed as streams, with the same bytes as before
# Run with: Invoke-Pester ./Tests/RevealStreamedMembers.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A real reveal loaded the whole consumption CSV as objects (@(Import-Csv))
# and every JSON or HTML member as whole strings (Get-Content -Raw, then the
# revealed copy), so a large report well inside the zip limits could run the
# job out of memory, and -Resume then failed the same way every time.
# Each member is now revealed as a stream: CSV rows go through Import-Csv |
# ForEach-Object | Export-Csv, and text is revealed in 64 KB chunks with the
# end of each chunk carried into the next so no token is split, both into an
# owner-only sibling copied over the member after the pass.
#
# The first part checks the bytes: each revealed member must equal what the
# earlier whole-file code (copied below as the reference) wrote for the same
# input, for tokens across chunk edges, multi-byte text, a byte order mark,
# CSV quoting and HTML and JSON escaping. The second part reveals a large
# consumption member and a large one-line JSON member in a child process and
# checks that its peak working set grows by much less than the member.
#
# The reports and dictionaries are built here with placeholder values; no
# live Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Functions = Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1'
    . $script:Functions
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealStreamed_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    $script:SubGuid = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $script:TokRg = 'nonprod_' + [guid]::NewGuid().ToString()
    $script:TokSub = 'prod_' + [guid]::NewGuid().ToString()
    $script:TokHinted = 'prod_databricks_' + [guid]::NewGuid().ToString()
    $script:TokUnknown = 'prod_' + [guid]::NewGuid().ToString()   # in no map: stays masked
    # Non-ASCII text is built from code points, so this file stays ASCII.
    $script:E = [string][char]0xE9
    $script:Smile = [char]::ConvertFromUtf32(0x1F600)
    $script:RealSubName = 'Contoso, "Q" & Co <' + $script:E + '> ' + [char]0x2713 + ' ' + $script:Smile
    $script:RealRg = 'rg-app'
    $script:RealName = 'dbw-01'

    $script:Dict = [ordered]@{
        ResourceGroupMap    = [ordered]@{ $script:TokRg = "/subscriptions/$($script:SubGuid)/resourceGroups/$($script:RealRg)" }
        SubscriptionMap     = [ordered]@{ $script:TokSub = "/subscriptions/$($script:SubGuid)/resourceGroups/$($script:RealRg)/providers/Microsoft.Compute/virtualMachines/vm1" }
        SubscriptionNameMap = [ordered]@{ $script:TokSub = $script:RealSubName }
        TagMap              = [ordered]@{}
        ResourceIdMap       = [ordered]@{}
        ResourceNameMap     = [ordered]@{ $script:TokHinted = "/subscriptions/$($script:SubGuid)/resourceGroups/$($script:RealRg)/providers/Microsoft.Databricks/workspaces/$($script:RealName)" }
        FreeTextMap         = [ordered]@{}
    }
    $script:Replacements = @{ $script:TokRg = $script:RealRg; $script:TokSub = $script:RealSubName; $script:TokHinted = $script:RealName }

    # The earlier whole-file reveal of one member, as Invoke-RdaReveal did it
    # before members were streamed. Returns the member's bytes afterwards.
    function Get-ReferenceRevealedBytes
    {
        param([string] $Name, [byte[]] $Bytes)
        $Dir = Join-Path $script:WorkDir ('ref_' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $Dir
        $File = Join-Path $Dir $Name
        [System.IO.File]::WriteAllBytes($File, $Bytes)
        $Replacements = $script:Replacements
        $TokenPattern = Get-RevealTokenPattern
        $null = $Replacements, $TokenPattern
        $script:FileHits = 0
        $Ext = [System.IO.Path]::GetExtension($File).ToLowerInvariant()
        if ($Ext -eq '.csv')
        {
            $Rows = @(Import-Csv -LiteralPath $File)
            if ($Rows.Count -gt 0)
            {
                foreach ($row in $Rows)
                {
                    foreach ($prop in $row.PSObject.Properties)
                    {
                        if ($null -ne $prop.Value -and $prop.Value -is [string] -and $prop.Value.Length -gt 0)
                        {
                            $prop.Value = Convert-RevealString -Text $prop.Value -EscapeMode 'None'
                        }
                    }
                }
                if ($script:FileHits -gt 0) { $Rows | Export-Csv -LiteralPath $File -NoTypeInformation -Encoding utf8 }
            }
        }
        else
        {
            $Content = Get-Content -LiteralPath $File -Raw
            if (-not [string]::IsNullOrEmpty($Content))
            {
                $EscapeMode = switch ($Ext) { '.json' { 'Json' } '.html' { 'Html' } '.htm' { 'Html' } default { 'None' } }
                $NewContent = Convert-RevealString -Text $Content -EscapeMode $EscapeMode
                if ($script:FileHits -gt 0) { Set-Content -LiteralPath $File -Value $NewContent -Encoding utf8 -NoNewline }
            }
        }
        return , [System.IO.File]::ReadAllBytes($File)
    }

    function Write-TestReport
    {
        param([string] $Path, [System.Collections.IDictionary] $Members)
        $Archive = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
        try
        {
            foreach ($Name in $Members.Keys)
            {
                $Stream = $Archive.CreateEntry($Name).Open()
                try { $Stream.Write($Members[$Name], 0, $Members[$Name].Length) } finally { $Stream.Dispose() }
            }
        }
        finally { $Archive.Dispose() }
    }

    function Get-ZipMemberBytes
    {
        param([string] $Path)
        $Result = [ordered]@{}
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try
        {
            foreach ($Entry in $Archive.Entries)
            {
                $Memory = [System.IO.MemoryStream]::new()
                $Stream = $Entry.Open()
                try { $Stream.CopyTo($Memory) } finally { $Stream.Dispose() }
                $Result[$Entry.FullName] = $Memory.ToArray()
            }
        }
        finally { $Archive.Dispose() }
        return $Result
    }

    $Utf8 = [System.Text.UTF8Encoding]::new($false)

    # A one-line JSON member of about 400 000 characters with the tokens at
    # many offsets, so tokens cross every chunk edge in turn, and multi-byte
    # characters (a surrogate pair among them) next to them.
    $Json = [System.Text.StringBuilder]::new()
    $null = $Json.Append('{"VirtualMachines":[')
    $Tokens = @($script:TokRg, $script:TokSub, $script:TokHinted, $script:TokUnknown)
    $i = 0
    while ($Json.Length -lt 400000)
    {
        $Pad = 'x' * (($i * 37) % 211)
        $null = $Json.Append('{"N":"' + $Pad + $script:E + $script:Smile + '","T":"' + $Tokens[$i % 4] + '","P":"/subscriptions/' + $script:TokSub + '/resourceGroups/' + $script:TokRg + '"},')
        $i++
    }
    $null = $Json.Append('{"Set":"obfuscated"}]}')
    $JsonText = $Json.ToString()

    $Csv = [System.Text.StringBuilder]::new()
    $null = $Csv.Append('"ResourceId","SubscriptionName","Cost","Note"' + "`r`n")
    for ($CsvRow = 0; $CsvRow -lt 300; $CsvRow++)
    {
        $null = $Csv.Append('"/subscriptions/' + $script:TokSub + '/resourceGroups/' + $script:TokRg + '/providers/x/y/' + $script:TokHinted + '","' + $script:TokSub + '","' + $CsvRow + '.5","a ""quoted"", ' + $script:E + ', ' + $script:TokUnknown + '"' + "`r`n")
    }
    $null = $Csv.Append('"","","",""' + "`r`n")

    $script:Members = [ordered]@{
        'Inventory_Test.json'      = $Utf8.GetBytes($JsonText)
        'Metrics_Bom.json'         = [byte[]](@(0xEF, 0xBB, 0xBF) + $Utf8.GetBytes('{"Metrics":[{"ResourceGroup":"' + $script:TokRg + '","Name":"' + $script:E + '"}]}'))
        'Consumption_Test.csv'     = $Utf8.GetBytes($Csv.ToString())
        'ResourcesReport_Test.html' = $Utf8.GetBytes("<html><body><td>$($script:TokSub)</td><td>$($script:TokRg)</td>`n<p>$($script:E)</p></body></html>`n")
        'Notes.txt'                = $Utf8.GetBytes("sub $($script:TokSub)`nrg $($script:TokRg)`n")
        'Untouched.json'           = $Utf8.GetBytes('{"Nothing":"here ' + $script:TokUnknown + '"}')
        'Empty.json'               = [byte[]]@()
    }
    $script:DictPath = Join-Path $script:WorkDir 'ObfuscationDictionary_Test.json'
    [System.IO.File]::WriteAllText($script:DictPath, ($script:Dict | ConvertTo-Json -Depth 5))
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-RdaReveal writes the same member bytes as the whole-file reveal' {
    BeforeAll {
        $script:InZip = Join-Path $script:WorkDir 'ResourcesReport_Test.zip'
        Write-TestReport -Path $script:InZip -Members $script:Members
        $script:OutZip = Join-Path $script:WorkDir 'revealed.zip'
        $null = Invoke-RdaReveal -InputZip $script:InZip -DictionaryPath $script:DictPath -Fields @('ResourceGroup', 'Subscription', 'ResourceName') -OutputZip $script:OutZip 6>$null
        $script:Out = Get-ZipMemberBytes -Path $script:OutZip
    }

    It 'keeps every member and leaves no sibling file in the zip' {
        @($script:Out.Keys | Sort-Object) | Should -Be @($script:Members.Keys | Sort-Object)
    }

    It 'reveals <_> to the same bytes' -ForEach @('Inventory_Test.json', 'Metrics_Bom.json', 'Consumption_Test.csv', 'ResourcesReport_Test.html', 'Notes.txt', 'Untouched.json', 'Empty.json') {
        $Expected = Get-ReferenceRevealedBytes -Name $_ -Bytes $script:Members[$_]
        $Actual = $script:Out[$_]
        $Actual.Length | Should -Be $Expected.Length
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$Actual, [byte[]]$Expected) | Should -BeTrue
    }

    It 'revealed every selected token in the one-line JSON and kept the unknown one' {
        $Text = [System.Text.Encoding]::UTF8.GetString($script:Out['Inventory_Test.json'])
        $Text | Should -Not -Match ([regex]::Escape($script:TokRg))
        $Text | Should -Not -Match ([regex]::Escape($script:TokSub))
        $Text | Should -Not -Match ([regex]::Escape($script:TokHinted))
        $Text | Should -Match ([regex]::Escape($script:TokUnknown))
        $null = $Text | ConvertFrom-Json
    }
}

Describe 'Invoke-RdaReveal holds a large member as a stream' {
    BeforeAll {
        $Rng = [System.Random]::new(7)
        # About 96 MB of one-line JSON. Random hex keeps it near 2 to 1 in the
        # zip, inside the 100 to 1 limit.
        $script:BigJsonZip = Join-Path $script:WorkDir 'ResourcesReport_BigJson.zip'
        $Archive = [System.IO.Compression.ZipFile]::Open($script:BigJsonZip, 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_Big.json').Open(), [System.Text.UTF8Encoding]::new($false))
            try
            {
                $Block = [System.Text.StringBuilder]::new()
                while ($Block.Length -lt 1MB)
                {
                    $Hex = [byte[]]::new(48); $Rng.NextBytes($Hex)
                    $null = $Block.Append('{"R":"' + [Convert]::ToHexString($Hex) + '","G":"' + $script:TokRg + '"},')
                }
                $Text = $Block.ToString()
                $Writer.Write('{"VirtualMachines":[')
                for ($Repeat = 0; $Repeat -lt 96; $Repeat++) { $Writer.Write($Text) }
                $Writer.Write('{"S":"' + $script:TokSub + '"}]}')
            }
            finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }

        # About 96 MB of consumption CSV, in rows of about 1.7 KB (a row
        # with its InstanceData is of that order).
        $script:BigCsvZip = Join-Path $script:WorkDir 'ResourcesReport_BigCsv.zip'
        $Archive = [System.IO.Compression.ZipFile]::Open($script:BigCsvZip, 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Consumption_Big.csv').Open(), [System.Text.UTF8Encoding]::new($false))
            try
            {
                $Writer.Write('"ResourceId","MeterId","Quantity","Cost"' + "`r`n")
                $Bytes = 0
                while ($Bytes -lt 96MB)
                {
                    $Hex = [byte[]]::new(800); $Rng.NextBytes($Hex)
                    $Line = '"/subscriptions/' + $script:TokSub + '/resourcegroups/' + $script:TokRg + '/providers/microsoft.compute/virtualmachines/' + [Convert]::ToHexString($Hex) + '","' + [guid]::NewGuid().ToString() + '","1.5","2.25"' + "`r`n"
                    $Writer.Write($Line)
                    $Bytes += $Line.Length
                }
            }
            finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }

        $script:SmallZip = Join-Path $script:WorkDir 'ResourcesReport_Small.zip'
        Write-TestReport -Path $script:SmallZip -Members ([ordered]@{
                'Inventory_S.json'   = [System.Text.Encoding]::UTF8.GetBytes('{"VirtualMachines":[{"G":"' + $script:TokRg + '"}]}')
                'Consumption_S.csv' = [System.Text.Encoding]::UTF8.GetBytes('"ResourceId","Cost"' + "`r`n" + '"' + $script:TokRg + '","1"' + "`r`n")
            })

        # The child warms up on a small report first, so the peak it reports
        # before the large one already holds the loaded code.
        $script:Child = Join-Path $script:WorkDir 'measure.ps1'
        [System.IO.File]::WriteAllText($script:Child, @'
param([string] $Functions, [string] $Small, [string] $Big, [string] $Dict, [string] $Out)
$ErrorActionPreference = 'Stop'
. $Functions
$null = Invoke-RdaReveal -InputZip $Small -DictionaryPath $Dict -Fields @('ResourceGroup', 'Subscription') -OutputZip ($Out + '.small.zip') 6>$null
[GC]::Collect()
$P = [System.Diagnostics.Process]::GetCurrentProcess(); $P.Refresh()
$Before = $P.PeakWorkingSet64
$null = Invoke-RdaReveal -InputZip $Big -DictionaryPath $Dict -Fields @('ResourceGroup', 'Subscription') -OutputZip $Out 6>$null
$P.Refresh()
'GROWTH=' + ($P.PeakWorkingSet64 - $Before)
'@)
    }

    It 'reveals a <Kind> member of about <Size> MB with peak memory growth well below its size' -ForEach @(
        @{ Kind = 'one-line JSON'; Size = 96; Zip = 'BigJson'; Member = 'Inventory_Big.json' }
        @{ Kind = 'consumption CSV'; Size = 96; Zip = 'BigCsv'; Member = 'Consumption_Big.csv' }
    ) {
        $In = if ($Zip -eq 'BigJson') { $script:BigJsonZip } else { $script:BigCsvZip }
        $Out = Join-Path $script:WorkDir ($Zip + '_revealed.zip')
        # A small first-generation budget makes the collector run often, so the
        # peak measures what the reveal holds, not garbage it has not yet
        # collected (by default that slack alone is tens of MB on a many-core
        # host, whatever the member size).
        $OldGen0 = $env:DOTNET_GCgen0size
        $env:DOTNET_GCgen0size = '0x1000000'
        try { $Lines = @(& pwsh -NoProfile -NonInteractive -File $script:Child -Functions $script:Functions -Small $script:SmallZip -Big $In -Dict $script:DictPath -Out $Out 2>&1 | ForEach-Object { [string]$_ }) }
        finally { $env:DOTNET_GCgen0size = $OldGen0 }
        $LASTEXITCODE | Should -Be 0 -Because ($Lines -join "`n")
        $Growth = [long](($Lines | Where-Object { $_ -like 'GROWTH=*' } | Select-Object -Last 1) -replace '^GROWTH=', '')
        # The member as one UTF-16 string alone is twice its size (the
        # whole-file reveal grew by more than ten times it); streamed, the
        # growth is a fixed overhead well below the member.
        $Growth | Should -BeLessThan ($Size * 1MB / 2) -Because ('peak working set grew by {0:0.0} MB for a {1} MB member' -f ($Growth / 1MB), $Size)

        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Out)
        try
        {
            $Reader = [System.IO.StreamReader]::new($Archive.GetEntry($Member).Open())
            try
            {
                $Head = [char[]]::new(4096)
                $null = $Reader.ReadBlock($Head, 0, 4096)
                $HeadText = [string]::new($Head)
                $HeadText | Should -Match ([regex]::Escape($script:RealRg))
                $HeadText | Should -Not -Match ([regex]::Escape($script:TokRg))
            }
            finally { $Reader.Dispose() }
        }
        finally { $Archive.Dispose() }
    }
}
