# Reveal staging folder: owner-only before anything is written
# Run with: Invoke-Pester ./Tests/RevealStagingPermissions.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The all-subscriptions reveal writes the revealed reports, which hold real
# names and ids, into a staging folder that is kept by default. The folder was
# made (or reused) with the default permissions, so with the common 022 umask
# any other user of the machine could list it and read the revealed zips.
# Reveal now makes the staging folder owner-only (0700 on Unix; an owner-only
# protected ACL on Windows) before it writes anything, for a new folder, an
# existing empty one and a marked one it resumes, and stops if it cannot.
# These checks are for Unix; the Windows code is not run here.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealStagingPermissions_' + [guid]::NewGuid().ToString('N'))
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

    # Runs Reveal.ps1 under umask 022, as on a common multi-user host.
    function Invoke-Reveal
    {
        param([string]$Root, [string]$Staging, [string]$Bundle, [string[]]$Extra = @())
        $Console = @(& sh -c 'umask 022; exec "$@"' sh pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $Root -StagingDirectory $Staging -OutputZip $Bundle -FolderTimeoutMinutes 5 @Extra 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($Console -join "`n") }
    }

    function Get-Mode
    {
        param([string]$Path)
        return [Convert]::ToString(([int][System.IO.File]::GetUnixFileMode($Path)) -band 0x1FF, 8)
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 staging folder permissions' -Skip:$IsWindows {
    It 'makes a new staging folder owner-only' {
        $Case = New-Case -Name 'new'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        Get-Mode $Case.Staging | Should -Be '700'
    }

    It 'makes an existing empty staging folder owner-only' {
        $Case = New-Case -Name 'empty'
        $null = New-Item -ItemType Directory -Path $Case.Staging -Force
        [System.IO.File]::SetUnixFileMode($Case.Staging, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute')

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        Get-Mode $Case.Staging | Should -Be '700'
    }

    It 'makes a marked staging folder owner-only again on -Resume' {
        $Case = New-Case -Name 'resume'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        [System.IO.File]::SetUnixFileMode($Case.Staging, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute')

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip') -Extra @('-Resume')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        Get-Mode $Case.Staging | Should -Be '700'
    }
}
