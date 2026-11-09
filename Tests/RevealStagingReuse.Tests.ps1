# Reveal into its own staging folder again: a clear outcome that ends
# Run with: Invoke-Pester ./Tests/RevealStagingReuse.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A second run into Reveal's own staging folder without -Resume was accepted.
# Its name clashed with the first run's zip, so the report went into the
# bundle under a changed name ('<folder>_ResourcesReport_...zip'), and
# -RemoveStaging then deleted the mark but kept the first run's zip, saying
# the folder held an item 'Reveal did not put there'. A third run with -Resume
# was then refused, because without the mark the folder looked foreign: the
# folder could no longer be resumed or reused.
# A run without -Resume into Reveal's own folder that still holds its files is
# now refused with a message to pass -Resume or use a new folder, and
# -RemoveStaging also removes the other finished outputs the mark records, so
# what it keeps is only what Reveal did not write. The runs below are traced
# to their end.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealStagingReuse_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    # One report of subscription $SubId in folder $Folder, stamp $Stamp.
    function Add-Report
    {
        param([string]$Folder, [string]$Stamp, [string]$SubId)
        $Token = 'prod_' + [guid]::NewGuid().ToString()
        $SubToken = 'prod_' + [guid]::NewGuid().ToString()
        $null = New-Item -ItemType Directory -Path $Folder -Force
        $Archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Folder ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_r.json').Open())
            try { $Writer.Write('{"VirtualMachines":[{"ResourceGroup":"' + $Token + '","Subscription":"' + $SubToken + '"}]}') } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        $Dict = '{"ResourceGroupMap":{"' + $Token + '":"/subscriptions/' + $SubId + '/resourceGroups/real-rg"},"SubscriptionMap":{"' + $SubToken + '":"/subscriptions/' + $SubId + '/resourceGroups/real-rg/providers/Microsoft.Compute/virtualMachines/vm1"},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText((Join-Path $Folder ('ObfuscationDictionary_ResourcesReport_' + $Stamp + '.json')), $Dict)
    }

    function Invoke-Reveal
    {
        param([string]$Root, [string]$Staging, [string]$Bundle, [string[]]$Extra = @())
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $Root -StagingDirectory $Staging -OutputZip $Bundle -FolderTimeoutMinutes 5 @Extra 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($Console -join "`n"); Flat = (($Console -join ' ') -replace '\s+', ' ') }
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

Describe 'Reveal.ps1 run again into its own staging folder' {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'root'
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000000aaaa') -Stamp '20260101000000000aaaa' -SubId '00000000-0000-0000-0000-00000000000a'
        $script:Staging = Join-Path $script:WorkDir 'staging'
        $script:Run1 = Invoke-Reveal -Root $script:Root -Staging $script:Staging -Bundle (Join-Path $script:WorkDir 'bundle1.zip')
        $script:AfterRun1 = Get-FolderNames $script:Staging
        $script:Run2 = Invoke-Reveal -Root $script:Root -Staging $script:Staging -Bundle (Join-Path $script:WorkDir 'bundle2.zip') -Extra @('-RemoveStaging')
        $script:AfterRun2 = Get-FolderNames $script:Staging
        $script:Run3 = Invoke-Reveal -Root $script:Root -Staging $script:Staging -Bundle (Join-Path $script:WorkDir 'bundle3.zip') -Extra @('-Resume', '-RemoveStaging')
        $script:StagingAfterRun3 = Test-Path -LiteralPath $script:Staging
        $script:Run4 = Invoke-Reveal -Root $script:Root -Staging $script:Staging -Bundle (Join-Path $script:WorkDir 'bundle4.zip')
    }

    It 'run 1 reveals into the folder' {
        $script:Run1.Exit | Should -Be 0 -Because $script:Run1.Text
    }

    It 'run 2 without -Resume is refused, says to pass -Resume or use a new folder, and changes nothing' {
        $script:Run2.Exit | Should -Not -Be 0 -Because $script:Run2.Text
        $script:Run2.Flat | Should -Match 'from an earlier reveal'
        $script:Run2.Flat | Should -Match 'Pass -Resume'
        $script:Run2.Flat | Should -Match 'new or empty folder'
        $script:AfterRun2 | Should -Be $script:AfterRun1
        Test-Path -LiteralPath (Join-Path $script:WorkDir 'bundle2.zip') | Should -BeFalse
    }

    It 'run 3 with -Resume ships the report under its own name and removes the folder' {
        $script:Run3.Exit | Should -Be 0 -Because $script:Run3.Text
        Get-ZipNames (Join-Path $script:WorkDir 'bundle3.zip') | Should -Be @('ResourcesReport_20260101000000000aaaa.zip')
        $script:Run3.Text | Should -Match 'Removed staging directory'
        $script:StagingAfterRun3 | Should -BeFalse
    }

    It 'run 4 starts afresh in the same place' {
        $script:Run4.Exit | Should -Be 0 -Because $script:Run4.Text
        Get-ZipNames (Join-Path $script:WorkDir 'bundle4.zip') | Should -Be @('ResourcesReport_20260101000000000aaaa.zip')
    }
}

Describe 'Reveal.ps1 -Resume -RemoveStaging with an older output the mark records' {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'root2'
        $script:Staging = Join-Path $script:WorkDir 'staging2'
        $Sub = '00000000-0000-0000-0000-00000000000b'
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000000bbbb') -Stamp '20260101000000000bbbb' -SubId $Sub
        $script:Run1 = Invoke-Reveal -Root $script:Root -Staging $script:Staging -Bundle (Join-Path $script:WorkDir 'old.zip')
        # A newer run of the same subscription arrives, and the older report
        # is moved away (Reveal leaves out every report of a subscription
        # that is in more than one report); the resumed reveal takes the newer
        # one, and the mark still records the older output.
        Move-Item -LiteralPath (Join-Path $script:Root 'ResourcesReport20260101000000000bbbb') -Destination (Join-Path $script:WorkDir 'moved-away-bbbb')
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260202000000000cccc') -Stamp '20260202000000000cccc' -SubId $Sub
        $script:Run2 = Invoke-Reveal -Root $script:Root -Staging $script:Staging -Bundle (Join-Path $script:WorkDir 'new.zip') -Extra @('-Resume', '-RemoveStaging')
        $script:StagingAfterRun2 = Test-Path -LiteralPath $script:Staging
        $script:Run3 = Invoke-Reveal -Root $script:Root -Staging $script:Staging -Bundle (Join-Path $script:WorkDir 'again.zip') -Extra @('-Resume')
    }

    It 'ships only the newer report' {
        $script:Run1.Exit | Should -Be 0 -Because $script:Run1.Text
        $script:Run2.Exit | Should -Be 0 -Because $script:Run2.Text
        Get-ZipNames (Join-Path $script:WorkDir 'new.zip') | Should -Be @('ResourcesReport_20260202000000000cccc.zip')
    }

    It 'removes the older output Reveal wrote too, and the folder' {
        $script:Run2.Text | Should -Not -Match 'Reveal did not put there'
        $script:Run2.Text | Should -Match 'Removed staging directory'
        $script:StagingAfterRun2 | Should -BeFalse
    }

    It 'a later -Resume into the same place is not refused' {
        $script:Run3.Exit | Should -Be 0 -Because $script:Run3.Text
        Get-ZipNames (Join-Path $script:WorkDir 'again.zip') | Should -Be @('ResourcesReport_20260202000000000cccc.zip')
    }
}
