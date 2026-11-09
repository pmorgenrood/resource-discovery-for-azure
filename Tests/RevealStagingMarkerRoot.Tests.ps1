# Reveal -Resume: the staging mark's inventory root, compared as a path
# Run with: Invoke-Pester ./Tests/RevealStagingMarkerRoot.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Reveal marks each staging folder with the inventory root it was used for,
# and compared that root with the current one as raw text. A run given
# -InventoryRoot 'root/' wrote 'root/' into the mark, so a later -Resume given
# 'root' was refused as 'not a Reveal staging folder', and the message said
# only to use a new or empty folder. Both roots are now made full paths with
# no trailing separator before they are compared, and a refused -Resume names
# the mark and says what to do.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealStagingMarkerRoot_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force
    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'

    function New-Case
    {
        param([string]$Name)
        $Dir = Join-Path $script:WorkDir $Name
        $Sub = Join-Path $Dir 'root/good'
        $null = New-Item -ItemType Directory -Path $Sub -Force
        $Archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Sub 'ResourcesReport_good.zip'), 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_r.json').Open())
            try { $Writer.Write('{"VirtualMachines":[{"ResourceGroup":"' + $script:Token + '"}]}') } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        $Dict = '{"ResourceGroupMap":{"' + $script:Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg"},"SubscriptionMap":{},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText((Join-Path $Sub 'ObfuscationDictionary_good.json'), $Dict)
        return [pscustomobject]@{ Root = (Join-Path $Dir 'root'); Staging = (Join-Path $Dir 'staging'); Dir = $Dir }
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

Describe 'Reveal.ps1 -Resume and the staging mark''s root' {
    It 'resumes a run given the root with a trailing separator when the root is given without one' {
        $Case = New-Case -Name 'trailing'
        $First = Invoke-Reveal -Root ($Case.Root + [System.IO.Path]::DirectorySeparatorChar) -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip') -Extra @('-Resume')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Skipped \(already revealed-resume\): 1'
    }

    It 'resumes a run given the root without a trailing separator when the root is given with one' {
        $Case = New-Case -Name 'plain'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text

        $Run = Invoke-Reveal -Root ($Case.Root + [System.IO.Path]::DirectorySeparatorChar) -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip') -Extra @('-Resume')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Skipped \(already revealed-resume\): 1'
    }

    It 'under -Resume, a refusal names the mark and says what to do' {
        $Case = New-Case -Name 'unmarked'
        $null = New-Item -ItemType Directory -Path $Case.Staging -Force
        Set-Content -LiteralPath (Join-Path $Case.Staging 'ResourcesReport_good.zip') -Value 'from an older reveal'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip') -Extra @('-Resume')

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        $Flat = $Run.Text -replace '\s+', ' '
        $Flat | Should -Match 'not a Reveal staging folder'
        $Flat | Should -Match ([regex]::Escape('.reveal-staging.json'))
        $Flat | Should -Match 'run without -Resume'
    }
}
