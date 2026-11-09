# Reveal -StagingDirectory: only a folder Reveal owns is used, shipped or removed
# Run with: Invoke-Pester ./Tests/RevealStagingOwnership.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Reveal.ps1 -StagingDirectory could name a folder that already held files
# that were not this reveal's. The outer zip then took every *.zip in it, so
# stale or unrelated reports went into the upload (and downstream could count
# their resources twice), and a clean -RemoveStaging run deleted the whole
# folder, unrelated files included.
# Reveal now marks each staging folder it uses with a hidden file naming the
# inventory root, refuses a folder that holds files but has no such mark (or a
# mark for another root), puts only this run's revealed zips in the outer zip,
# and with -RemoveStaging removes only its own files, keeping the folder when
# anything else is left in it.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealStagingOwnership_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'

    function Write-TestZip
    {
        param([string]$Path, [string]$Member, [string]$Text)
        $Archive = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
        try
        {
            $Entry = $Archive.CreateEntry($Member)
            $Writer = [System.IO.StreamWriter]::new($Entry.Open())
            try { $Writer.Write($Text) } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
    }

    # A case folder: an inventory root with one subscription folder holding a
    # masked report and its dictionary, plus paths for staging and the bundle.
    function New-Case
    {
        param([string]$Name)
        $Dir = Join-Path $script:WorkDir $Name
        $Root = Join-Path $Dir 'root'
        $Sub = Join-Path $Root 'good'
        $null = New-Item -ItemType Directory -Path $Sub -Force
        Write-TestZip -Path (Join-Path $Sub 'ResourcesReport_good.zip') -Member 'Inventory_r.json' -Text ('{"VirtualMachines":[{"ResourceGroup":"' + $script:Token + '"}]}')
        $Dict = '{"ResourceGroupMap":{"' + $script:Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg"},"SubscriptionMap":{},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText((Join-Path $Sub 'ObfuscationDictionary_good.json'), $Dict)
        return [pscustomobject]@{ Root = $Root; Staging = (Join-Path $Dir 'staging'); Dir = $Dir }
    }

    function Invoke-Reveal
    {
        param([string]$Root, [string]$Staging, [string]$Bundle, [string[]]$Extra = @())
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $Root -StagingDirectory $Staging -OutputZip $Bundle -FolderTimeoutMinutes 5 @Extra 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($Console -join "`n") }
    }

    function Get-ZipNames
    {
        param([string]$Path)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return @($Archive.Entries | ForEach-Object FullName | Sort-Object) } finally { $Archive.Dispose() }
    }

    function Get-FolderNames
    {
        param([string]$Path)
        return @(Get-ChildItem -LiteralPath $Path -Force | ForEach-Object Name | Sort-Object)
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 -StagingDirectory ownership' {
    It 'refuses a folder that holds files and has no Reveal mark, and leaves it untouched' {
        $Case = New-Case -Name 'unmarked'
        $null = New-Item -ItemType Directory -Path $Case.Staging -Force
        Write-TestZip -Path (Join-Path $Case.Staging 'ResourcesReport_stale.zip') -Member 'Inventory_stale.json' -Text '{}'
        Set-Content -LiteralPath (Join-Path $Case.Staging 'notes.txt') -Value 'not a report'
        $Bundle = Join-Path $Case.Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'not a Reveal staging folder'
        $Run.Text | Should -Match 'Use a new or empty folder'
        Get-FolderNames $Case.Staging | Should -Be @('notes.txt', 'ResourcesReport_stale.zip')
        Test-Path -LiteralPath $Bundle | Should -BeFalse
    }

    It 'refuses a folder marked for another inventory root' {
        $Case = New-Case -Name 'otherroot'
        $Other = New-Case -Name 'otherroot-first'
        $First = Invoke-Reveal -Root $Other.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        $Before = Get-FolderNames $Case.Staging

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip') -Extra @('-Resume')

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'not a Reveal staging folder'
        Get-FolderNames $Case.Staging | Should -Be $Before
        Test-Path -LiteralPath (Join-Path $Case.Dir 'bundle.zip') | Should -BeFalse
    }

    It 'uses an existing empty folder and removes it on a clean -RemoveStaging run' {
        $Case = New-Case -Name 'empty'
        $null = New-Item -ItemType Directory -Path $Case.Staging -Force
        $Bundle = Join-Path $Case.Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle -Extra @('-RemoveStaging')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        Get-ZipNames $Bundle | Should -Be @('ResourcesReport_good.zip')
        Test-Path -LiteralPath $Case.Staging | Should -BeFalse
    }

    It 'does not ship a stray zip from a marked folder on -Resume' {
        $Case = New-Case -Name 'stray'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        Write-TestZip -Path (Join-Path $Case.Staging 'ResourcesReport_stray.zip') -Member 'Inventory_stray.json' -Text '{}'
        $Bundle = Join-Path $Case.Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle -Extra @('-Resume')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Skipped \(already revealed-resume\): 1'
        Get-ZipNames $Bundle | Should -Be @('ResourcesReport_good.zip')
    }

    It 'with -RemoveStaging removes only its own files, keeps an unrelated file and the folder, and says so' {
        $Case = New-Case -Name 'keep'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        Set-Content -LiteralPath (Join-Path $Case.Staging 'notes.txt') -Value 'not a report'
        $Bundle = Join-Path $Case.Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle -Extra @('-Resume', '-RemoveStaging')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        Get-ZipNames $Bundle | Should -Be @('ResourcesReport_good.zip')
        Get-FolderNames $Case.Staging | Should -Be @('notes.txt')
        $Run.Text | Should -Match 'kept the folder'
        $Run.Text | Should -Not -Match 'Removed staging directory'
    }
}
