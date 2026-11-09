# Reveal -Resume takes a staging folder only when its mark has the whole shape Reveal writes
# Run with: Invoke-Pester ./Tests/RevealStagingMarkerShape.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Reveal took a staging mark as its own from InventoryRoot, Fields and Outputs
# alone and never checked its Purpose. Under -Resume an unrelated folder
# holding a look-alike mark was accepted: Reveal made it owner-only, removed
# any .reveal-tmp in it and replaced the mark. A mark is now Reveal's only
# when it has the whole shape Reveal writes (the Purpose Reveal writes,
# InventoryRoot, Fields, All and Outputs); any other is refused and the
# folder is left as it was.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealStagingMarkerShape_' + [guid]::NewGuid().ToString('N'))
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
        $Root = (Resolve-Path -LiteralPath (Join-Path $Dir 'root')).Path
        # An unrelated folder that anyone may read, with a file of its own
        # and a .reveal-tmp folder of its own.
        $Other = Join-Path $Dir 'other'
        $null = New-Item -ItemType Directory -Path (Join-Path $Other '.reveal-tmp') -Force
        [System.IO.File]::WriteAllText((Join-Path $Other 'keep.txt'), 'mine')
        [System.IO.File]::WriteAllText((Join-Path $Other '.reveal-tmp/keep.txt'), 'mine too')
        if (-not $IsWindows) { & chmod 755 $Other }
        return [pscustomobject]@{ Dir = $Dir; Root = $Root; Other = $Other; Marker = (Join-Path $Other '.reveal-staging.json') }
    }

    function Get-State
    {
        param([string]$Folder)
        $Items = @(Get-ChildItem -LiteralPath $Folder -Force -Recurse | ForEach-Object { $_.FullName.Substring($Folder.Length) + '=' + $(if ($_ -is [System.IO.FileInfo]) { (Get-FileHash -LiteralPath $_.FullName).Hash } else { 'dir' }) } | Sort-Object)
        $Mode = if ($IsWindows) { '' } else { [string](& stat -c '%a' $Folder) }
        return ($Mode + '|' + ($Items -join ';'))
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

Describe 'Reveal.ps1 -Resume and a staging mark that is not the whole Reveal shape' -Skip:$IsWindows {
    It 'refuses a mark <Name>, and leaves the folder as it was' -ForEach @(
        @{ Name = 'with no Purpose'; Drop = 'Purpose'; Set = @{}; Text = 'not a Reveal staging folder for' }
        @{ Name = 'with another Purpose'; Drop = ''; Set = @{ Purpose = 'Some other tool' }; Text = 'not a Reveal staging folder for' }
        @{ Name = 'with no All'; Drop = 'All'; Set = @{}; Text = 'is not one Reveal wrote \(its All is not true or false\)' }
        @{ Name = 'with All as text'; Drop = ''; Set = @{ All = 'no' }; Text = 'is not one Reveal wrote \(its All is not true or false\)' }
        @{ Name = 'with no Outputs'; Drop = 'Outputs'; Set = @{}; Text = 'is not one Reveal wrote \(its Outputs is not a set of named records\)' }
        @{ Name = 'with Fields as text'; Drop = ''; Set = @{ Fields = 'ResourceGroup, Subscription' }; Text = 'is not one Reveal wrote \(its Fields is not a list of field names\)' }
    ) {
        $Case = New-Case -Name ('shape-' + ($Name -replace '\W', ''))
        $Mark = [ordered]@{ Purpose = 'Reveal staging folder'; InventoryRoot = $Case.Root; Fields = @('ResourceGroup', 'Subscription'); All = $false; Outputs = @{} }
        if ($Drop) { $Mark.Remove($Drop) }
        foreach ($Key in $Set.Keys) { $Mark[$Key] = $Set[$Key] }
        [System.IO.File]::WriteAllText($Case.Marker, ($Mark | ConvertTo-Json -Depth 5))
        $Before = Get-State $Case.Other
        $Bundle = Join-Path $Case.Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Other -Bundle $Bundle -Extra @('-Resume')

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match $Text
        Get-State $Case.Other | Should -Be $Before
        Test-Path -LiteralPath $Bundle | Should -BeFalse
    }

    It 'still resumes from a mark Reveal wrote' {
        $Case = New-Case -Name 'own'
        $Staging = Join-Path $Case.Dir 'staging'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Staging -Bundle (Join-Path $Case.Dir 'bundle.zip') -Extra @('-Resume')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Skipped \(already revealed-resume\): 1'
    }
}
