# Revealed zips: owner-only from the start and at their final name
# Run with: Invoke-Pester ./Tests/RevealArchivePermissions.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A revealed zip holds the real names and ids Reveal was asked to show. The
# single-report output (and its .partial.zip while it was written) and the
# all-subscriptions outer zip were made with the default permissions, so with
# the common 022 umask they were mode 0644 and any other user of the machine
# could read them. An unchanged copy also took the mode of the report it
# copied. Reveal now makes each zip it writes owner-only (0600 on Unix; an
# owner-only protected ACL on Windows) before anything is written into it, and
# the move to the final name keeps that. These checks are for Unix; the
# Windows code is not run here.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    $script:Functions = Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealArchivePermissions_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force
    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'
    $script:OpenMode = [System.IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead'

    # A report zip (mode 0644) holding $Text, and its dictionary.
    function New-Report
    {
        param([string]$Folder, [string]$Stamp, [string]$Text, [string]$Dict)
        $null = New-Item -ItemType Directory -Path $Folder -Force
        $Zip = Join-Path $Folder ('ResourcesReport_' + $Stamp + '.zip')
        $Archive = [System.IO.Compression.ZipFile]::Open($Zip, 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_r.json').Open())
            try { $Writer.Write($Text) } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        [System.IO.File]::SetUnixFileMode($Zip, $script:OpenMode)
        $DictPath = Join-Path $Folder ('ObfuscationDictionary_ResourcesReport_' + $Stamp + '.json')
        [System.IO.File]::WriteAllText($DictPath, $Dict)
        return [pscustomobject]@{ Zip = $Zip; Dict = $DictPath }
    }

    $script:MaskedText = '{"VirtualMachines":[{"ResourceGroup":"' + $script:Token + '"}]}'
    $script:FullDict = '{"ResourceGroupMap":{"' + $script:Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg"},"SubscriptionMap":{},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
    $script:EmptyDict = '{"ResourceGroupMap":{},"SubscriptionMap":{},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'

    # Runs pwsh under umask 022, as on a common multi-user host.
    function Invoke-Umask022
    {
        param([string[]]$Arguments)
        $Console = @(& sh -c 'umask 022; exec "$@"' sh pwsh -NoProfile -NonInteractive @Arguments 2>&1 | ForEach-Object { [string]$_ })
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

Describe 'Reveal.ps1 zip permissions under umask 022' -Skip:$IsWindows {
    It 'writes a single-report revealed zip owner-only' {
        $Report = New-Report -Folder (Join-Path $script:WorkDir 'single') -Stamp 's1' -Text $script:MaskedText -Dict $script:FullDict
        $Out = Join-Path $script:WorkDir 'single/out.zip'

        $Run = Invoke-Umask022 -Arguments @('-File', $script:Reveal, '-InputZip', $Report.Zip, '-DictionaryPath', $Report.Dict, '-OutputZip', $Out)

        $Run.Exit | Should -Be 0 -Because $Run.Text
        Get-Mode $Out | Should -Be '600'
        Test-Path -LiteralPath (Join-Path $script:WorkDir 'single/out.partial.zip') | Should -BeFalse
    }

    It 'writes a single-report unchanged copy owner-only, not with the mode of the report' {
        $Report = New-Report -Folder (Join-Path $script:WorkDir 'copy') -Stamp 's2' -Text '{"VirtualMachines":[]}' -Dict $script:EmptyDict
        $Out = Join-Path $script:WorkDir 'copy/out.zip'

        $Run = Invoke-Umask022 -Arguments @('-File', $script:Reveal, '-InputZip', $Report.Zip, '-DictionaryPath', $Report.Dict, '-OutputZip', $Out)

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Wrote an unchanged copy'
        (Get-FileHash -LiteralPath $Out).Hash | Should -Be (Get-FileHash -LiteralPath $Report.Zip).Hash
        Get-Mode $Out | Should -Be '600'
    }

    It 'writes the all-subscriptions outer zip and the staged zip owner-only' {
        $Root = Join-Path $script:WorkDir 'all/root'
        $null = New-Report -Folder (Join-Path $Root 'ResourcesReport20260101000000000aaaa') -Stamp '20260101000000000aaaa' -Text $script:MaskedText -Dict $script:FullDict
        $Staging = Join-Path $script:WorkDir 'all/staging'
        $Bundle = Join-Path $script:WorkDir 'all/bundle.zip'

        $Run = Invoke-Umask022 -Arguments @('-File', $script:Reveal, '-InventoryRoot', $Root, '-StagingDirectory', $Staging, '-OutputZip', $Bundle, '-FolderTimeoutMinutes', '5')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        Get-Mode $Bundle | Should -Be '600'
        Get-Mode (Join-Path $Staging 'ResourcesReport_20260101000000000aaaa.zip') | Should -Be '600'
        Test-Path -LiteralPath (Join-Path $script:WorkDir 'all/bundle.partial.zip') | Should -BeFalse
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Bundle)
        try { @($Archive.Entries.FullName) | Should -Be @('ResourcesReport_20260101000000000aaaa.zip') } finally { $Archive.Dispose() }
    }

    It 'makes a new zip file owner-only before anything is written into it' {
        $Path = Join-Path $script:WorkDir 'new.partial.zip'
        $Probe = ". '{0}'; New-RevealOwnerOnlyFile -Path '{1}'; [Convert]::ToString(([int][System.IO.File]::GetUnixFileMode('{1}')) -band 0x1FF, 8); (Get-Item -LiteralPath '{1}').Length" -f $script:Functions, $Path

        $Run = Invoke-Umask022 -Arguments @('-Command', $Probe)

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Be "600`n0"
    }
}
