# Two Reveal runs never share a staging folder or an outer zip
# Run with: Invoke-Pester ./Tests/RevealStagingLock.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The default staging folder and outer zip were named by the time to the
# second, and nothing stopped two runs from using one staging folder. Two runs
# started in the same second picked the same staging folder and outer zip, and
# two runs in one folder could erase each other's expanded copies or records,
# or replace a bundle another run had already reported. The default names now
# carry the milliseconds and a short random part, and a run takes an exclusive
# lock file in staging before it reads or writes the mark or any file there; a
# second run then stops with a plain message.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealStagingLock_' + [guid]::NewGuid().ToString('N'))
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
        return [pscustomobject]@{ Dir = $Dir; Root = (Join-Path $Dir 'root'); Staging = (Join-Path $Dir 'staging') }
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

Describe 'Reveal.ps1 default names' -Skip:$IsWindows {
    It 'gives two runs started at the same clock time their own staging folder and outer zip' {
        $Case = New-Case -Name 'samesecond'
        # Both runs read the same clock time, whatever format they ask for.
        Mock Get-Date -ParameterFilter { $Format -like 'yyyy-MM-dd_HH-mm-ss*' } { '2026-01-01_00-00-00' + $(if ($Format -like '*fff') { '-000' } else { '' }) }

        $First = (& $script:Reveal -InventoryRoot $Case.Root -FolderTimeoutMinutes 5 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        $FirstExit = $LASTEXITCODE
        $Second = (& $script:Reveal -InventoryRoot $Case.Root -FolderTimeoutMinutes 5 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        $SecondExit = $LASTEXITCODE

        $FirstExit | Should -Be 0 -Because $First
        $SecondExit | Should -Be 0 -Because $Second
        $Staging = @(Get-ChildItem -LiteralPath $Case.Root -Directory -Filter 'RevealedStaging_*')
        $Staging.Count | Should -Be 2
        $Staging.Name | ForEach-Object { $_ | Should -Match '\ARevealedStaging_2026-01-01_00-00-00-000_[0-9a-f]{6}\z' }
        $Zips = @(Get-ChildItem -LiteralPath $Case.Root -File -Filter 'AllSubscriptions_Revealed_*.zip')
        $Zips.Count | Should -Be 2
        $Zips.Name | ForEach-Object { $_ | Should -Match '\AAllSubscriptions_Revealed_2026-01-01_00-00-00-000_[0-9a-f]{6}\.zip\z' }
    }
}

Describe 'Reveal.ps1 staging lock' -Skip:$IsWindows {
    It 'stops a run whose staging folder another run holds, and changes nothing there' {
        $Case = New-Case -Name 'held'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        $Marker = Join-Path $Case.Staging '.reveal-staging.json'
        $Before = (Get-FileHash -LiteralPath $Marker).Hash
        $Bundle = Join-Path $Case.Dir 'bundle.zip'
        # Hold the lock as a running Reveal does.
        $Held = [System.IO.FileStream]::new((Join-Path $Case.Staging '.reveal-lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try
        {
            $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle -Extra @('-Resume')
        }
        finally { $Held.Dispose() }

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match 'is in use by another Reveal run'
        (Get-FileHash -LiteralPath $Marker).Hash | Should -Be $Before
        Test-Path -LiteralPath $Bundle | Should -BeFalse
    }

    It 'takes over a lock file no run holds, and removes it with staging' {
        $Case = New-Case -Name 'stale'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        Test-Path -LiteralPath (Join-Path $Case.Staging '.reveal-lock') | Should -BeTrue

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip') -Extra @('-Resume', '-RemoveStaging')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        Test-Path -LiteralPath $Case.Staging | Should -BeFalse
    }

    It 'leaves no lock file in a folder it refuses' {
        $Case = New-Case -Name 'refused'
        $Other = Join-Path $Case.Dir 'other'
        $null = New-Item -ItemType Directory -Path $Other -Force
        [System.IO.File]::WriteAllText((Join-Path $Other 'keep.txt'), 'mine')

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Other -Bundle (Join-Path $Case.Dir 'bundle.zip')

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        @(Get-ChildItem -LiteralPath $Other -Force).Name | Should -Be @('keep.txt')
    }
}
