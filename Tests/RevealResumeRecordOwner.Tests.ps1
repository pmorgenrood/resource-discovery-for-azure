# Reveal -Resume keeps a staging record only for an output Reveal makes for a report pair
# Run with: Invoke-Pester ./Tests/RevealResumeRecordOwner.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The staging mark's records were checked for shape only, so a record for any
# plain file name (for example notes.txt) with matching hashes and some source
# text was kept, and a clean -Resume -RemoveStaging then deleted notes.txt,
# though Reveal promises to keep anything in staging it did not put there. A
# record is now kept only when its name is one Reveal assigns to the report
# pair it names (the report zip's name, or it with a copy number in front),
# and, when that pair is under the root, it names the pair's dictionary. Any
# other record is dropped, and its file is kept. (A record of a pair moved
# away from the root is kept, so a clean -RemoveStaging still removes that
# older output; RevealStagingReuse.Tests.ps1 covers that.)
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealResumeRecordOwner_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force
    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'
    $script:SubToken = 'prod_22222222-3333-4444-5555-666666666666'

    function New-Case
    {
        param([string]$Name)
        $Dir = Join-Path $script:WorkDir $Name
        $Sub = Join-Path $Dir 'root/good'
        $null = New-Item -ItemType Directory -Path $Sub -Force
        $Zip = Join-Path $Sub 'ResourcesReport_good.zip'
        $Archive = [System.IO.Compression.ZipFile]::Open($Zip, 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_r.json').Open())
            try { $Writer.Write('{"VirtualMachines":[{"ResourceGroup":"' + $script:Token + '","Subscription":"' + $script:SubToken + '"}]}') } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        $DictPath = Join-Path $Sub 'ObfuscationDictionary_good.json'
        $Dict = '{"ResourceGroupMap":{"' + $script:Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg"},"SubscriptionMap":{"' + $script:SubToken + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg/providers/Microsoft.Compute/virtualMachines/vm1"},"SubscriptionNameMap":{"' + $script:SubToken + '":"real-sub"},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText($DictPath, $Dict)
        return [pscustomobject]@{
            Dir = $Dir; Root = (Join-Path $Dir 'root'); Staging = (Join-Path $Dir 'staging'); Source = $Zip; Dict = $DictPath
            Marker = (Join-Path $Dir 'staging/.reveal-staging.json'); Staged = (Join-Path $Dir 'staging/ResourcesReport_good.zip')
        }
    }

    # Add a record for $Name (a file already in staging) to the mark, with the
    # good pair's source fields and the file's own SHA-256.
    function Add-Record
    {
        param($Case, [string]$Name, [string]$SourceFolder = 'good', [string]$DictionaryName = 'ObfuscationDictionary_good.json')
        $Mark = Get-Content -LiteralPath $Case.Marker -Raw | ConvertFrom-Json -AsHashtable
        $Mark['Outputs'][$Name] = [ordered]@{
            Sha256           = (Get-FileHash -LiteralPath (Join-Path $Case.Staging $Name) -Algorithm SHA256).Hash
            SourceFolder     = $SourceFolder
            SourceName       = 'ResourcesReport_good.zip'
            SourceSha256     = (Get-FileHash -LiteralPath $Case.Source -Algorithm SHA256).Hash
            DictionaryName   = $DictionaryName
            DictionarySha256 = (Get-FileHash -LiteralPath $Case.Dict -Algorithm SHA256).Hash
        }
        [System.IO.File]::WriteAllText($Case.Marker, ($Mark | ConvertTo-Json -Depth 5))
    }

    function Invoke-Reveal
    {
        param([string]$Root, [string]$Staging, [string]$Bundle, [string[]]$Extra = @())
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $Root -StagingDirectory $Staging -OutputZip $Bundle -FolderTimeoutMinutes 5 @Extra 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($Console -join "`n") }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 -Resume -RemoveStaging and a record Reveal does not make' -Skip:$IsWindows {
    It 'drops a record of <Name> and keeps its file' -ForEach @(
        @{ Name = 'notes.txt'; File = 'notes.txt'; SourceFolder = 'good'; DictionaryName = 'ObfuscationDictionary_good.json' }
        @{ Name = 'a report name that is not its own source'; File = 'ResourcesReport_other.zip'; SourceFolder = 'elsewhere'; DictionaryName = 'ObfuscationDictionary_good.json' }
        @{ Name = 'a name with a bad copy number'; File = '1_ResourcesReport_good.zip'; SourceFolder = 'good'; DictionaryName = 'ObfuscationDictionary_good.json' }
        @{ Name = 'a pair under the root with another dictionary'; File = '2_ResourcesReport_good.zip'; SourceFolder = 'good'; DictionaryName = 'ObfuscationDictionary_other.json' }
    ) {
        $Case = New-Case -Name ('drop-' + ($Name -replace '\W', ''))
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        $Kept = Join-Path $Case.Staging $File
        [System.IO.File]::WriteAllText($Kept, 'not Reveal''s')
        Add-Record -Case $Case -Name $File -SourceFolder $SourceFolder -DictionaryName $DictionaryName

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip') -Extra @('-Resume', '-RemoveStaging')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match ("dropped the staging mark's record of " + [regex]::Escape($File))
        Test-Path -LiteralPath $Kept | Should -BeTrue
        [System.IO.File]::ReadAllText($Kept) | Should -Be 'not Reveal''s'
        ($Run.Text -replace '\s+', ' ') | Should -Match 'kept the folder: it holds 1 item\(s\) Reveal did not put there'
    }

    It 'keeps a record of a copy-numbered output of a pair, and removes it when clean' {
        $Case = New-Case -Name 'copy'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        $Copy = Join-Path $Case.Staging '2_ResourcesReport_good.zip'
        Copy-Item -LiteralPath $Case.Staged -Destination $Copy
        Add-Record -Case $Case -Name '2_ResourcesReport_good.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip') -Extra @('-Resume', '-RemoveStaging')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Not -Match "dropped the staging mark's record"
        Test-Path -LiteralPath $Case.Staging | Should -BeFalse
    }
}
