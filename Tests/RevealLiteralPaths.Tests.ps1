# Reveal with '[' and ']' in file and folder names
# Run with: Invoke-Pester ./Tests/RevealLiteralPaths.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Invoke-RdaReveal passed exact paths to -Path, which reads '[1]' as a
# wildcard that matches '1'. So with a dictionary, report member, output zip,
# search folder or temp folder named with '[1]' next to one named with '1':
#   - the dictionary next door was read instead of the one asked for,
#   - an extracted member was read from, and written over, its neighbour,
#   - a neighbour's stale .partial.zip was deleted,
#   - the temp folder was not listed or removed.
# Every exact path is now passed to -LiteralPath.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    . (Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealLiteralPaths_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'

    # A dictionary mapping $script:Token to the resource group $RgName.
    function Write-TestDictionary
    {
        param([string]$Folder, [string]$Name, [string]$RgName)
        $null = New-Item -ItemType Directory -Path $Folder -Force
        $Path = Join-Path $Folder $Name
        $Json = '{"ResourceGroupMap":{"' + $script:Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/' + $RgName + '"},"SubscriptionMap":{},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText($Path, $Json)
        return $Path
    }

    # The members of the report: each one with '[1]' holds the token, its
    # neighbour with '1' holds none.
    $script:Members = [ordered]@{
        'Inventory_[1].json'        = '{"ResourceGroup":"' + $script:Token + '"}'
        'Inventory_1.json'          = '{"ResourceGroup":"decoy"}'
        'Consumption_[1].csv'       = "`"ResourceGroup`",`"Cost`"`n`"$($script:Token)`",`"1.5`"`n"
        'Consumption_1.csv'         = "`"ResourceGroup`",`"Cost`"`n`"decoy`",`"2.5`"`n"
        'ResourcesReport_[1].html'  = '<td>' + $script:Token + '</td>'
        'ResourcesReport_1.html'    = '<td>decoy</td>'
    }

    function Write-TestReportZip
    {
        param([string]$Path)
        $Archive = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
        try
        {
            foreach ($Key in $script:Members.Keys)
            {
                $Entry = $Archive.CreateEntry($Key)
                $Writer = [System.IO.StreamWriter]::new($Entry.Open())
                try { $Writer.Write([string]$script:Members[$Key]) } finally { $Writer.Dispose() }
            }
        }
        finally { $Archive.Dispose() }
    }

    function Get-ZipText
    {
        param([string]$Path)
        $Result = @{}
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try
        {
            foreach ($Entry in $Archive.Entries)
            {
                $Reader = [System.IO.StreamReader]::new($Entry.Open())
                try { $Result[$Entry.FullName] = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
            }
        }
        finally { $Archive.Dispose() }
        return $Result
    }

    # Checks the revealed zip: every '[1]' member shows the real group, every
    # neighbour is unchanged.
    function Assert-Revealed
    {
        param([string]$OutZip, [string]$RgName)
        $Text = Get-ZipText $OutZip
        @($Text.Keys).Count | Should -Be 6
        $Text['Inventory_[1].json'] | Should -BeLike "*`"ResourceGroup`":`"$RgName`"*"
        $Text['Consumption_[1].csv'] | Should -BeLike "*$RgName*"
        $Text['ResourcesReport_[1].html'] | Should -Be "<td>$RgName</td>"
        foreach ($Key in @('Inventory_1.json', 'Consumption_1.csv', 'ResourcesReport_1.html'))
        {
            $Text[$Key] | Should -Be $script:Members[$Key] -Because "$Key is the neighbour and has no token"
        }
        foreach ($Key in @('Inventory_[1].json', 'Consumption_[1].csv', 'ResourcesReport_[1].html'))
        {
            $Text[$Key] | Should -Not -BeLike "*$($script:Token)*" -Because "$Key holds the token"
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-RdaReveal with [1] in names next to a neighbour named with 1' {
    It 'reads the named dictionary and rewrites the named members, not their neighbours' {
        $Case = Join-Path $script:WorkDir 'dict'
        $Dict = Write-TestDictionary -Folder (Join-Path $Case 'd[1]') -Name 'ObfuscationDictionary_r[1].json' -RgName 'real-rg'
        $Decoy = Write-TestDictionary -Folder (Join-Path $Case 'd1') -Name 'ObfuscationDictionary_r1.json' -RgName 'decoy-rg'
        $DecoyBefore = [System.IO.File]::ReadAllText($Decoy)
        $InZip = Join-Path $Case 'report[1].zip'
        Write-TestReportZip -Path $InZip
        $OutZip = Join-Path $Case 'out[1].zip'

        Invoke-RdaReveal -InputZip $InZip -DictionaryPath $Dict -OutputZip $OutZip 6>$null

        Assert-Revealed -OutZip $OutZip -RgName 'real-rg'
        [System.IO.File]::ReadAllText($Decoy) | Should -Be $DecoyBefore
    }

    It 'finds the dictionary in a search folder named with [1], not in its neighbour' {
        $Case = Join-Path $script:WorkDir 'search'
        $null = Write-TestDictionary -Folder (Join-Path $Case 's[1]') -Name 'ObfuscationDictionary_a.json' -RgName 'real-rg'
        $null = Write-TestDictionary -Folder (Join-Path $Case 's1') -Name 'ObfuscationDictionary_b.json' -RgName 'decoy-rg'
        $InZip = Join-Path $Case 'report.zip'
        Write-TestReportZip -Path $InZip
        $OutZip = Join-Path $Case 'out.zip'

        Invoke-RdaReveal -InputZip $InZip -SearchDirectory (Join-Path $Case 's[1]') -OutputZip $OutZip 6>$null

        Assert-Revealed -OutZip $OutZip -RgName 'real-rg'
    }

    It 'leaves the neighbour''s .partial.zip alone' {
        $Case = Join-Path $script:WorkDir 'partial'
        $Dict = Write-TestDictionary -Folder $Case -Name 'ObfuscationDictionary_p.json' -RgName 'real-rg'
        $InZip = Join-Path $Case 'report.zip'
        Write-TestReportZip -Path $InZip
        $Decoy = Join-Path $Case 'out1.partial.zip'
        [System.IO.File]::WriteAllText($Decoy, 'neighbour')
        $OutZip = Join-Path $Case 'out[1].zip'

        Invoke-RdaReveal -InputZip $InZip -DictionaryPath $Dict -OutputZip $OutZip 6>$null

        Assert-Revealed -OutZip $OutZip -RgName 'real-rg'
        Test-Path -LiteralPath $Decoy | Should -BeTrue
        [System.IO.File]::ReadAllText($Decoy) | Should -Be 'neighbour'
        Test-Path -LiteralPath (Join-Path $Case 'out[1].partial.zip') | Should -BeFalse
    }

    It 'lists and removes its temp folder under a temp root named with [1]' -Skip:$IsWindows {
        $Case = Join-Path $script:WorkDir 'temp'
        $Dict = Write-TestDictionary -Folder $Case -Name 'ObfuscationDictionary_t.json' -RgName 'real-rg'
        $InZip = Join-Path $Case 'report.zip'
        Write-TestReportZip -Path $InZip
        $OutZip = Join-Path $Case 'out.zip'
        $TempRoot = Join-Path $Case 't[1]'
        $null = New-Item -ItemType Directory -Path $TempRoot -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $Case 't1') -Force

        $Saved = $env:TMPDIR
        try
        {
            $env:TMPDIR = $TempRoot + '/'
            [System.IO.Path]::GetTempPath() | Should -Be ($TempRoot + '/')
            Invoke-RdaReveal -InputZip $InZip -DictionaryPath $Dict -OutputZip $OutZip 6>$null
        }
        finally { $env:TMPDIR = $Saved }

        Assert-Revealed -OutZip $OutZip -RgName 'real-rg'
        @(Get-ChildItem -LiteralPath $TempRoot -Force).Count | Should -Be 0
    }
}
