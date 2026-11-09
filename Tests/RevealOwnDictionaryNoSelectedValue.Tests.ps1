# Reveal of a report whose own dictionary has no value for the selected fields
# Run with: Invoke-Pester ./Tests/RevealOwnDictionaryNoSelectedValue.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Reveal fails a report that still holds masked values after the rewrite, so a
# report revealed with another report's dictionary is not shipped as revealed.
# That check also failed a report revealed with its OWN dictionary when the
# selected fields had no value in it, for example -Fields Tag for a
# subscription with no tags: the report's resource group tokens were taken as
# proof of a wrong dictionary. In the all-subscriptions run that ordinary
# subscription became a failed folder and the run ended with exit 4.
# A dictionary now belongs to a report when any masked value of the report is
# in any map of the dictionary. Such a report, with nothing selected to
# reveal, is written unchanged. A report whose masked values are in none of
# the dictionary's maps still fails.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    . (Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealOwnDictionary_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    # The resource group token in the report, a tag token not in the report,
    # and another report's resource group token.
    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'
    $script:TagToken = 'prod_22222222-3333-4444-5555-666666666666'
    $script:OtherToken = 'prod_99999999-8888-7777-6666-555555555555'
    $script:Text = '{"VirtualMachines":[{"ResourceGroup":"' + $script:Token + '"}]}'

    # A dictionary whose resource group map holds $RgToken of the placeholder
    # subscription $SubId, and whose TagMap holds $TagToken when one is given.
    # Folders of one inventory root get different subscriptions, as different
    # runs' reports do: Reveal leaves out every report of a subscription that
    # is in more than one report.
    function Write-TestDictionary
    {
        param([string]$Path, [string]$RgToken, [string]$TagToken, [string]$SubId = '00000000-0000-0000-0000-000000000000')
        $Tags = if ($TagToken) { '{"' + $TagToken + '":"real-tag"}' } else { '{}' }
        $Json = '{"ResourceGroupMap":{"' + $RgToken + '":"/subscriptions/' + $SubId + '/resourceGroups/real-rg"},"SubscriptionMap":{},"SubscriptionNameMap":{},"TagMap":' + $Tags + ',"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText($Path, $Json)
    }

    function Write-TestReportZip
    {
        param([string]$Path)
        $Archive = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
        try
        {
            $Entry = $Archive.CreateEntry('Inventory_r.json')
            $Writer = [System.IO.StreamWriter]::new($Entry.Open())
            try { $Writer.Write($script:Text) } finally { $Writer.Dispose() }
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

    function New-Case
    {
        param([string]$Name, [string]$RgToken, [string]$TagToken)
        $Dir = Join-Path $script:WorkDir $Name
        $null = New-Item -ItemType Directory -Path $Dir -Force
        $InZip = Join-Path $Dir 'ResourcesReport_r.zip'
        Write-TestReportZip -Path $InZip
        $Dict = Join-Path $Dir 'ObfuscationDictionary_r.json'
        Write-TestDictionary -Path $Dict -RgToken $RgToken -TagToken $TagToken
        return [pscustomobject]@{ Dir = $Dir; InZip = $InZip; Dict = $Dict; OutZip = (Join-Path $Dir 'out.zip') }
    }

    # An inventory root with one subscription folder per case; returns the
    # exit code, console, staging folder and bundle of a Reveal.ps1 run.
    function Invoke-RevealAll
    {
        param([string]$Name, [hashtable[]]$Folders, [string[]]$Extra = @())
        $Root = Join-Path $script:WorkDir ($Name + '_root')
        $Index = 0
        foreach ($Folder in $Folders)
        {
            $Dir = Join-Path $Root $Folder.Name
            $null = New-Item -ItemType Directory -Path $Dir -Force
            Write-TestReportZip -Path (Join-Path $Dir ('ResourcesReport_' + $Folder.Name + '.zip'))
            $SubId = '00000000-0000-0000-0000-{0:d12}' -f $Index
            $Index++
            Write-TestDictionary -Path (Join-Path $Dir ('ObfuscationDictionary_' + $Folder.Name + '.json')) -RgToken $Folder.RgToken -SubId $SubId
        }
        $Staging = Join-Path $script:WorkDir ($Name + '_staging')
        $Bundle = Join-Path $script:WorkDir ($Name + '_bundle.zip')
        $Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
        $Console = @(& pwsh -NoProfile -NonInteractive -File $Reveal -InventoryRoot $Root -StagingDirectory $Staging -OutputZip $Bundle -FolderTimeoutMinutes 5 @Extra 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($Console -join "`n"); Staging = $Staging; Bundle = $Bundle }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-RdaReveal when the selected field has entries, none of them in the report' {
    It 'writes the report unchanged when its masked values are in its own dictionary' {
        $Case = New-Case -Name 'own' -RgToken $script:Token -TagToken $script:TagToken

        Invoke-RdaReveal -InputZip $Case.InZip -DictionaryPath $Case.Dict -Fields Tag -OutputZip $Case.OutZip 6>$null

        Get-ZipText $Case.OutZip | Should -Be $script:Text
        Test-Path -LiteralPath (Join-Path $Case.Dir 'out.partial.zip') | Should -BeFalse
    }

    It 'still fails when none of the report''s masked values is in the dictionary' {
        $Case = New-Case -Name 'foreign' -RgToken $script:OtherToken -TagToken $script:TagToken

        { Invoke-RdaReveal -InputZip $Case.InZip -DictionaryPath $Case.Dict -Fields Tag -OutputZip $Case.OutZip 6>$null } |
            Should -Throw -ExpectedMessage '*Nothing to reveal*no mapping in this dictionary*'
        Test-Path -LiteralPath $Case.OutZip | Should -BeFalse
    }
}

Describe 'Reveal.ps1 -Fields Tag over every folder, a subscription with no tags' {
    It 'writes the report unchanged, with no failed folder and exit 0' {
        $Run = Invoke-RevealAll -Name 'notags' -Folders @(@{ Name = 'good'; RgToken = $script:Token }) -Extra @('-Fields', 'Tag')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Failed during reveal\s+: 0'
        $Run.Text | Should -Not -Match 'FAIL: '
        Get-ZipText (Join-Path $Run.Staging 'ResourcesReport_good.zip') | Should -Be $script:Text
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Run.Bundle)
        try { @($Archive.Entries | ForEach-Object FullName) | Should -Be @('ResourcesReport_good.zip') } finally { $Archive.Dispose() }
    }

    It 'still fails a folder whose dictionary has none of the report''s masked values' {
        $Run = Invoke-RevealAll -Name 'foreign' -Folders @(@{ Name = 'good'; RgToken = $script:Token }, @{ Name = 'bad'; RgToken = $script:OtherToken }) -Extra @('-Fields', 'Tag')

        $Run.Exit | Should -Be 4 -Because $Run.Text
        $Run.Text | Should -Match 'FAIL: bad - Nothing to reveal'
        $Run.Text | Should -Not -Match 'FAIL: good'
        Test-Path -LiteralPath (Join-Path $Run.Staging 'ResourcesReport_bad.zip') | Should -BeFalse
    }
}
