# Reveal refuses an -OutputZip anywhere inside staging
# Run with: Invoke-Pester ./Tests/RevealOutputInsideStaging.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The -OutputZip guard checked only whether the output's own folder was the
# staging folder, though it says no output may be inside staging. So
# <staging>/saved/bundle.zip was accepted, and a clean -RemoveStaging run then
# kept staging, saying 'saved' was an item Reveal did not put there. A folder
# reached through a link to staging was also accepted. The guard now refuses
# an output anywhere under staging, compared by identity with links followed.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    . (Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealOutputInsideStaging_' + [guid]::NewGuid().ToString('N'))
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

Describe 'Test-RevealPathInside' -Skip:$IsWindows {
    It 'finds a path at any depth under a folder, also one that does not exist yet' {
        $Folder = Join-Path $script:WorkDir 'inside/stage'
        $null = New-Item -ItemType Directory -Path (Join-Path $Folder 'a/b') -Force
        Test-RevealPathInside -Path (Join-Path $Folder 'x.zip') -Folder $Folder | Should -BeTrue
        Test-RevealPathInside -Path (Join-Path $Folder 'a/b/x.zip') -Folder $Folder | Should -BeTrue
        Test-RevealPathInside -Path (Join-Path $Folder 'new/deeper/x.zip') -Folder $Folder | Should -BeTrue
        Test-RevealPathInside -Path (Join-Path $script:WorkDir 'inside/x.zip') -Folder $Folder | Should -BeFalse
        Test-RevealPathInside -Path (Join-Path $script:WorkDir 'inside/stage2/x.zip') -Folder $Folder | Should -BeFalse
    }

    It 'follows a link into the folder' {
        $Folder = Join-Path $script:WorkDir 'linked/stage'
        $null = New-Item -ItemType Directory -Path (Join-Path $Folder 'saved') -Force
        $Link = Join-Path $script:WorkDir 'linked/elsewhere'
        $null = New-Item -ItemType SymbolicLink -Path $Link -Target (Join-Path $Folder 'saved')
        Test-RevealPathInside -Path (Join-Path $Link 'x.zip') -Folder $Folder | Should -BeTrue
    }
}

Describe 'Reveal.ps1 -OutputZip inside staging' -Skip:$IsWindows {
    It 'refuses an output in a folder under staging, and writes no bundle' {
        $Case = New-Case -Name 'descendant'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        $Saved = Join-Path $Case.Staging 'saved'
        $null = New-Item -ItemType Directory -Path $Saved -Force
        $Bundle = Join-Path $Saved 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle -Extra @('-Resume', '-RemoveStaging')

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match '-OutputZip must not be inside the staging directory'
        Test-Path -LiteralPath $Bundle | Should -BeFalse
    }

    It 'refuses an output in a folder under staging that does not exist yet' {
        $Case = New-Case -Name 'newdescendant'
        $Bundle = Join-Path $Case.Staging 'later/bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match '-OutputZip must not be inside the staging directory'
    }

    It 'refuses an output in a folder linked to staging' {
        $Case = New-Case -Name 'linked'
        $null = New-Item -ItemType Directory -Path $Case.Staging -Force
        $Link = Join-Path $Case.Dir 'out'
        $null = New-Item -ItemType SymbolicLink -Path $Link -Target $Case.Staging
        $Bundle = Join-Path $Link 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match '-OutputZip must not be inside the staging directory'
        Test-Path -LiteralPath (Join-Path $Case.Staging 'bundle.zip') | Should -BeFalse
    }

    It 'still takes an output beside staging' {
        $Case = New-Case -Name 'beside'
        $Bundle = Join-Path $Case.Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle -Extra @('-RemoveStaging')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        Test-Path -LiteralPath $Bundle | Should -BeTrue
        Test-Path -LiteralPath $Case.Staging | Should -BeFalse
    }
}
