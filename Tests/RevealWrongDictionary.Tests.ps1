# Reveal with a dictionary that has entries, but none for this report
# Run with: Invoke-Pester ./Tests/RevealWrongDictionary.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The check for masked values that no dictionary entry covers ran only when
# the dictionary gave nothing to reveal. With a dictionary that does have
# entries, but for another report (a wrong dictionary passed in, or the newest
# one in the folder picked up), the rewrite found no token, and Reveal said
# 'Done. Revealed 0 token occurrence(s)' and wrote the still masked report as
# if it were revealed. In the all-subscriptions run that masked copy went into
# the bundle as a revealed report.
# Reveal now fails such a report with 'Nothing to reveal' and writes no zip.
# A report with no masked value is still copied, and the right dictionary
# still reveals.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    . (Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealWrongDictionary_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    # The token in the report, and the token of another report's dictionary.
    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'
    $script:OtherToken = 'prod_99999999-8888-7777-6666-555555555555'

    # A dictionary mapping $Token to the resource group $RgName.
    function Write-TestDictionary
    {
        param([string]$Path, [string]$Token, [string]$RgName)
        $Json = '{"ResourceGroupMap":{"' + $Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/' + $RgName + '"},"SubscriptionMap":{},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText($Path, $Json)
    }

    # A report zip with one Inventory member whose ResourceGroup is $Value.
    function Write-TestReportZip
    {
        param([string]$Path, [string]$Value)
        $Archive = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
        try
        {
            $Entry = $Archive.CreateEntry('Inventory_r.json')
            $Writer = [System.IO.StreamWriter]::new($Entry.Open())
            try { $Writer.Write('{"VirtualMachines":[{"ResourceGroup":"' + $Value + '"}]}') } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
    }

    function Get-ZipText
    {
        param([string]$Path)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try
        {
            $Reader = [System.IO.StreamReader]::new($Archive.GetEntry('Inventory_r.json').Open())
            try { return $Reader.ReadToEnd() } finally { $Reader.Dispose() }
        }
        finally { $Archive.Dispose() }
    }

    # One case folder: a report with $Value, a dictionary for $DictToken.
    function New-Case
    {
        param([string]$Name, [string]$Value, [string]$DictToken)
        $Dir = Join-Path $script:WorkDir $Name
        $null = New-Item -ItemType Directory -Path $Dir -Force
        $InZip = Join-Path $Dir 'ResourcesReport_r.zip'
        Write-TestReportZip -Path $InZip -Value $Value
        $Dict = Join-Path $Dir 'ObfuscationDictionary_r.json'
        Write-TestDictionary -Path $Dict -Token $DictToken -RgName 'real-rg'
        return [pscustomobject]@{ Dir = $Dir; InZip = $InZip; Dict = $Dict; OutZip = (Join-Path $Dir 'out.zip') }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-RdaReveal with a non-empty dictionary' {
    It 'fails a masked report when no dictionary entry is in it, and writes no zip' {
        $Case = New-Case -Name 'wrong' -Value $script:Token -DictToken $script:OtherToken

        { Invoke-RdaReveal -InputZip $Case.InZip -DictionaryPath $Case.Dict -OutputZip $Case.OutZip 6>$null } |
            Should -Throw -ExpectedMessage '*Nothing to reveal*no mapping in this dictionary*'

        Test-Path -LiteralPath $Case.OutZip | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Case.Dir 'out.partial.zip') | Should -BeFalse
    }

    It 'fails a report whose only masked value is the obfuscated sentinel' {
        $Case = New-Case -Name 'sentinel' -Value 'obfuscated' -DictToken $script:OtherToken

        { Invoke-RdaReveal -InputZip $Case.InZip -DictionaryPath $Case.Dict -OutputZip $Case.OutZip 6>$null } |
            Should -Throw -ExpectedMessage '*Nothing to reveal*no mapping in this dictionary*'

        Test-Path -LiteralPath $Case.OutZip | Should -BeFalse
    }

    It 'still reveals with the right dictionary' {
        $Case = New-Case -Name 'right' -Value $script:Token -DictToken $script:Token

        Invoke-RdaReveal -InputZip $Case.InZip -DictionaryPath $Case.Dict -OutputZip $Case.OutZip 6>$null

        Get-ZipText $Case.OutZip | Should -Be '{"VirtualMachines":[{"ResourceGroup":"real-rg"}]}'
    }

    It 'still writes a report with no masked value unchanged' {
        $Case = New-Case -Name 'plain' -Value 'plain-rg' -DictToken $script:OtherToken

        Invoke-RdaReveal -InputZip $Case.InZip -DictionaryPath $Case.Dict -OutputZip $Case.OutZip 6>$null

        Get-ZipText $Case.OutZip | Should -Be '{"VirtualMachines":[{"ResourceGroup":"plain-rg"}]}'
        Test-Path -LiteralPath (Join-Path $Case.Dir 'out.partial.zip') | Should -BeFalse
    }
}

Describe 'Reveal.ps1 over every folder, one folder with the wrong dictionary' {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'root'
        foreach ($Sub in @(@{ Name = 'good'; DictToken = $script:Token }, @{ Name = 'bad'; DictToken = $script:OtherToken }))
        {
            $Dir = Join-Path $script:Root $Sub.Name
            $null = New-Item -ItemType Directory -Path $Dir -Force
            Write-TestReportZip -Path (Join-Path $Dir ('ResourcesReport_' + $Sub.Name + '.zip')) -Value $script:Token
            Write-TestDictionary -Path (Join-Path $Dir ('ObfuscationDictionary_' + $Sub.Name + '.json')) -Token $Sub.DictToken -RgName 'real-rg'
        }
        $script:Staging = Join-Path $script:WorkDir 'staging'
        $script:Bundle = Join-Path $script:WorkDir 'bundle.zip'
        $Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
        $script:Console = @(& pwsh -NoProfile -NonInteractive -File $Reveal -InventoryRoot $script:Root -StagingDirectory $script:Staging -OutputZip $script:Bundle -FolderTimeoutMinutes 5 2>&1 | ForEach-Object { [string]$_ })
        $script:Exit = $LASTEXITCODE
        $script:Text = $script:Console -join "`n"
    }

    It 'reports the folder as failed and ends with exit 4' {
        $script:Exit | Should -Be 4 -Because $script:Text
        $script:Text | Should -Match 'FAIL: bad - Nothing to reveal'
        $script:Text | Should -Match 'Revealed successfully\s+: 1'
    }

    It 'leaves the failed folder out of staging and the bundle' {
        @(Get-ChildItem -LiteralPath $script:Staging -File | ForEach-Object Name) | Should -Be @('ResourcesReport_good.zip')
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($script:Bundle)
        try { @($Archive.Entries | ForEach-Object FullName) | Should -Be @('ResourcesReport_good.zip') } finally { $Archive.Dispose() }
    }
}
