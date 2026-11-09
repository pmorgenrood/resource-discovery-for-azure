# Reveal tells two existing folders apart by their identity, not their names
# Run with: Invoke-Pester ./Tests/RevealPathIdentity.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Reveal took "Windows" to mean that paths are case-insensitive, and compared
# folders by name everywhere it asked "is this the same folder". A Windows
# folder can be made case-sensitive, so a report folder 'Sub-A' beside a
# staging folder 'sub-a' was taken for staging and silently left out. A name
# compare also cannot see a link: staging reached through a link was read as a
# report folder, and an inventory root reached through a link was taken for
# another root, so -Resume refused its own staging folder.
# Existing folders are now compared by identity (device and inode on Unix,
# volume serial number and file id on Windows), links followed; names are
# compared, as the platform does, only for a path that does not exist yet.
# These tests run on Linux, where the identity comes from stat; the Windows
# branch uses the file id from the system and is not run here.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    . (Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealPathIdentity_' + [guid]::NewGuid().ToString('N'))
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
        $Dict = '{"ResourceGroupMap":{"' + $script:Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg"},"SubscriptionMap":{"' + $script:SubToken + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg/providers/Microsoft.Compute/virtualMachines/vm1"},"SubscriptionNameMap":{"' + $script:SubToken + '":"real-sub"},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText((Join-Path $Sub 'ObfuscationDictionary_good.json'), $Dict)
        return [pscustomobject]@{ Dir = $Dir; Root = (Join-Path $Dir 'root') }
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

Describe 'Test-RevealSamePath' -Skip:$IsWindows {
    It 'finds one folder under two names through a link' {
        $Real = Join-Path $script:WorkDir 'same-real'
        $Link = Join-Path $script:WorkDir 'same-link'
        $null = New-Item -ItemType Directory -Path $Real -Force
        $null = New-Item -ItemType SymbolicLink -Path $Link -Target $Real
        Test-RevealSamePath -Left $Real -Right $Link | Should -BeTrue
        (Get-RevealPathIdentity $Real) | Should -Be (Get-RevealPathIdentity $Link)
    }

    It 'tells apart two folders whose names differ only by case' {
        $Upper = Join-Path $script:WorkDir 'case/Sub-A'
        $Lower = Join-Path $script:WorkDir 'case/sub-a'
        $null = New-Item -ItemType Directory -Path $Upper, $Lower -Force
        Test-RevealSamePath -Left $Upper -Right $Lower -PathComparison ([System.StringComparison]::OrdinalIgnoreCase) | Should -BeFalse
    }

    It 'compares a path that does not exist by name, as told' {
        $Gone = Join-Path $script:WorkDir 'gone/Sub-A'
        Test-RevealSamePath -Left $Gone -Right ($Gone.ToLowerInvariant()) -PathComparison ([System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        Test-RevealSamePath -Left $Gone -Right ($Gone.ToLowerInvariant()) -PathComparison ([System.StringComparison]::Ordinal) | Should -BeFalse
    }
}

Describe 'Reveal.ps1 compares existing folders by identity' -Skip:$IsWindows {
    It 'resumes its own staging when the inventory root was named through a link' {
        $Case = New-Case -Name 'rootlink'
        $Link = Join-Path $Case.Dir 'rootlink'
        $null = New-Item -ItemType SymbolicLink -Path $Link -Target $Case.Root
        $Staging = Join-Path $Case.Dir 'staging'
        $First = Invoke-Reveal -Root $Link -Staging $Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Staging -Bundle (Join-Path $Case.Dir 'bundle.zip') -Extra @('-Resume')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Skipped \(already revealed-resume\): 1'
    }

    It 'leaves out staging named through a link, and reads no report folder as staging' {
        $Case = New-Case -Name 'staginglink'
        $Real = Join-Path $Case.Root 'stg'
        $null = New-Item -ItemType Directory -Path $Real -Force
        $Link = Join-Path $Case.Dir 'stglink'
        $null = New-Item -ItemType SymbolicLink -Path $Link -Target $Real

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Link -Bundle (Join-Path $Case.Dir 'bundle.zip')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Per-subscription folders scanned : 1'
        $Run.Text | Should -Match 'Skipped \(not a report folder\)\s+: 0'
        $Run.Text | Should -Not -Match 'SKIP: stg'
    }
}
