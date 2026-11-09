# Reveal over an inventory root that holds more than one run
# Run with: Invoke-Pester ./Tests/RevealNewestRunPerSubscription.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Run-AllSubscriptions.ps1 writes a new folder ResourcesReport<stamp> per
# subscription on every run, all under the same inventory root. Reveal.ps1
# took every folder, and in each one the first report zip and the first
# dictionary it found. So after a second wrapper run both runs' reports were
# revealed and shipped in one bundle; their masked ids differ, so downstream
# kept both copies and counted the resources and costs twice. In a folder
# holding two stamps, a report could also be paired with the other stamp's
# dictionary.
# Reveal now pairs each report only with the dictionary of the same stamp,
# reveals only the newest report of each subscription, and lists the older
# ones it left out.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealNewestRun_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    $script:SubA = '00000000-0000-0000-0000-00000000000a'
    $script:SubB = '00000000-0000-0000-0000-00000000000b'

    # One report as an inventory run writes it: ResourcesReport_<stamp>.zip and
    # ObfuscationDictionary_ResourcesReport_<stamp>.json in $Folder, the
    # report's resource group masked as $Token, real name $RgName.
    function Add-Report
    {
        param([string]$Folder, [string]$Stamp, [string]$Token, [string]$SubId, [string]$RgName, [switch]$NoDictionary)
        $null = New-Item -ItemType Directory -Path $Folder -Force
        $Archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Folder ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_ResourcesReport_' + $Stamp + '.json').Open())
            try { $Writer.Write('{"VirtualMachines":[{"ResourceGroup":"' + $Token + '"}]}') } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        if (-not $NoDictionary)
        {
            $SubToken = 'prod_' + [guid]::NewGuid().ToString()
            $Dict = '{"ResourceGroupMap":{"' + $Token + '":"/subscriptions/' + $SubId + '/resourceGroups/' + $RgName + '"},"SubscriptionMap":{"' + $SubToken + '":"/subscriptions/' + $SubId + '/resourceGroups/' + $RgName + '/providers/Microsoft.Compute/virtualMachines/vm1"},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
            [System.IO.File]::WriteAllText((Join-Path $Folder ('ObfuscationDictionary_ResourcesReport_' + $Stamp + '.json')), $Dict)
        }
    }

    function New-Token { return 'prod_' + [guid]::NewGuid().ToString() }

    function Invoke-Reveal
    {
        param([string]$Root, [string]$Name)
        $Staging = Join-Path $script:WorkDir ($Name + '_staging')
        $Bundle = Join-Path $script:WorkDir ($Name + '_bundle.zip')
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $Root -StagingDirectory $Staging -OutputZip $Bundle -FolderTimeoutMinutes 5 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($Console -join "`n"); Bundle = $Bundle; Staging = $Staging }
    }

    function Get-ZipNames
    {
        param([string]$Path)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return @($Archive.Entries | ForEach-Object FullName | Sort-Object) } finally { $Archive.Dispose() }
    }

    function Get-InnerText
    {
        param([string]$Path)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try
        {
            $Reader = [System.IO.StreamReader]::new($Archive.Entries[0].Open())
            try { return $Reader.ReadToEnd() } finally { $Reader.Dispose() }
        }
        finally { $Archive.Dispose() }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 over a root with two wrapper runs' {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'tworuns'
        # Run 1, then run 2, of the same two subscriptions, each in its own
        # folder as Run-AllSubscriptions.ps1 lays them out.
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000000aaaa') -Stamp '20260101000000000aaaa' -Token (New-Token) -SubId $script:SubA -RgName 'rg-a-old'
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000001bbbb') -Stamp '20260101000000001bbbb' -Token (New-Token) -SubId $script:SubB -RgName 'rg-b-old'
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260202000000000cccc') -Stamp '20260202000000000cccc' -Token (New-Token) -SubId $script:SubA -RgName 'rg-a-new'
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260202000000001dddd') -Stamp '20260202000000001dddd' -Token (New-Token) -SubId $script:SubB -RgName 'rg-b-new'
        $script:Run = Invoke-Reveal -Root $script:Root -Name 'tworuns'
    }

    It 'ends with exit 0' {
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Text
    }

    It 'puts one report per subscription in the bundle, the newest' {
        Get-ZipNames $script:Run.Bundle | Should -Be @('ResourcesReport_20260202000000000cccc.zip', 'ResourcesReport_20260202000000001dddd.zip')
        Get-InnerText (Join-Path $script:Run.Staging 'ResourcesReport_20260202000000000cccc.zip') | Should -Match 'rg-a-new'
        Get-InnerText (Join-Path $script:Run.Staging 'ResourcesReport_20260202000000001dddd.zip') | Should -Match 'rg-b-new'
    }

    It 'says which older reports were left out' {
        $script:Run.Text | Should -Match 'Left out \(older, same sub\)\s+: 2'
        $script:Run.Text | Should -Match 'OLDER: ResourcesReport20260101000000000aaaa/ResourcesReport_20260101000000000aaaa\.zip'
        $script:Run.Text | Should -Match 'OLDER: ResourcesReport20260101000000001bbbb/ResourcesReport_20260101000000001bbbb\.zip'
    }
}

Describe 'Reveal.ps1 with two stamps in one folder' {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'onefolder'
        $Folder = Join-Path $script:Root 'reused'
        # The older stamp's dictionary is missing; the newer stamp has its own.
        Add-Report -Folder $Folder -Stamp '20260101000000000eeee' -Token (New-Token) -SubId $script:SubA -RgName 'rg-old' -NoDictionary
        Add-Report -Folder $Folder -Stamp '20260202000000000ffff' -Token (New-Token) -SubId $script:SubA -RgName 'rg-new'
        $script:Run = Invoke-Reveal -Root $script:Root -Name 'onefolder'
    }

    It 'never pairs a report with another stamp''s dictionary' {
        $script:Run.Text | Should -Match 'SKIP: reused/ResourcesReport_20260101000000000eeee\.zip - no dictionary with the same stamp'
        $script:Run.Text | Should -Not -Match 'FAIL: '
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Text
    }

    It 'reveals the report that has its own dictionary' {
        Get-ZipNames $script:Run.Bundle | Should -Be @('ResourcesReport_20260202000000000ffff.zip')
        Get-InnerText (Join-Path $script:Run.Staging 'ResourcesReport_20260202000000000ffff.zip') | Should -Match 'rg-new'
    }
}
