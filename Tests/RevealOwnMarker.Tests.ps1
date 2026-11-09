# Reveal takes a staging mark as its own only when the whole mark has the shape it writes
# Run with: Invoke-Pester ./Tests/RevealOwnMarker.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A mark was taken as Reveal's own from its Purpose and InventoryRoot alone on
# a fresh run, and the old-staging check under the inventory root looked only
# at the top of the mark, not at each output record in it. So:
#  - a fresh run into an unrelated -StagingDirectory holding a two-field
#    look-alike mark and a .reveal-tmp folder changed the folder's permissions,
#    rewrote the mark and deleted .reveal-tmp with everything in it;
#  - a report folder whose mark had one malformed output record was skipped
#    as old staging, so its report was left out of a bundle that exited 0.
# A mark now counts as Reveal's only when the top level AND every output
# record have the shape Reveal writes and its InventoryRoot is this root.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealOwnMarker_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    # One report pair in $Folder with its own subscription (number $N).
    function Add-Report
    {
        param([string]$Folder, [string]$Stamp, [int]$N)
        $null = New-Item -ItemType Directory -Path $Folder -Force
        $Rg = 'prod_1111111{0}-2222-3333-4444-555555555555' -f $N
        $SubToken = 'prod_2222222{0}-3333-4444-5555-666666666666' -f $N
        $SubId = '0000000{0}-0000-0000-0000-000000000000' -f $N
        $Zip = Join-Path $Folder ('ResourcesReport_{0}.zip' -f $Stamp)
        $Archive = [System.IO.Compression.ZipFile]::Open($Zip, 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_r.json').Open())
            try { $Writer.Write('{"VirtualMachines":[{"ResourceGroup":"' + $Rg + '","Subscription":"' + $SubToken + '"}]}') } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        $Dict = '{"ResourceGroupMap":{"' + $Rg + '":"/subscriptions/' + $SubId + '/resourceGroups/real-rg-' + $N + '"},"SubscriptionMap":{"' + $SubToken + '":"/subscriptions/' + $SubId + '"},"SubscriptionNameMap":{"' + $SubToken + '":"real-sub-' + $N + '"},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText((Join-Path $Folder ('ObfuscationDictionary_ResourcesReport_{0}.json' -f $Stamp)), $Dict)
    }

    function Get-ZipNames
    {
        param([string]$Path)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return @($Archive.Entries | ForEach-Object { $_.FullName } | Sort-Object) } finally { $Archive.Dispose() }
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

    $script:Sha = 'A' * 64
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 and a selected staging folder with a mark that is not the whole Reveal shape' -Skip:$IsWindows {
    It 'refuses a fresh run into it with <Name>, and changes nothing' -ForEach @(
        @{ Name = 'a two-field look-alike mark'; Mark = 'two' }
        @{ Name = 'a mark whose one output record is malformed'; Mark = 'badrecord' }
    ) {
        $Dir = Join-Path $script:WorkDir ('fresh-' + $Mark)
        $Root = Join-Path $Dir 'root'
        Add-Report -Folder (Join-Path $Root 'good') -Stamp '20260101000000000aaaa' -N 1
        $Root = (Resolve-Path -LiteralPath $Root).Path
        # An unrelated folder anyone may read, with a .reveal-tmp of its own.
        $Other = Join-Path $Dir 'other'
        $null = New-Item -ItemType Directory -Path (Join-Path $Other '.reveal-tmp') -Force
        [System.IO.File]::WriteAllText((Join-Path $Other '.reveal-tmp/keep'), 'mine')
        & chmod 755 $Other
        $MarkData = if ($Mark -eq 'two') { [ordered]@{ Purpose = 'Reveal staging folder'; InventoryRoot = $Root } }
        else
        {
            $BadOutputs = @{ 'ResourcesReport_x_revealed.zip' = [ordered]@{ Sha256 = 'not a hash' } }
            [ordered]@{ Purpose = 'Reveal staging folder'; InventoryRoot = $Root; Fields = @('ResourceGroup', 'Subscription'); All = $false; Outputs = $BadOutputs }
        }
        [System.IO.File]::WriteAllText((Join-Path $Other '.reveal-staging.json'), ($MarkData | ConvertTo-Json -Depth 5))
        $Before = Get-State $Other
        $Bundle = Join-Path $Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Root -Staging $Other -Bundle $Bundle

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match 'is not a Reveal staging folder for'
        Get-State $Other | Should -Be $Before
        Test-Path -LiteralPath (Join-Path $Other '.reveal-tmp/keep') | Should -BeTrue
        Test-Path -LiteralPath $Bundle | Should -BeFalse
    }

    It 'still runs fresh into a staging folder Reveal marked and that holds nothing else' {
        $Dir = Join-Path $script:WorkDir 'fresh-own'
        $Root = Join-Path $Dir 'root'
        Add-Report -Folder (Join-Path $Root 'good') -Stamp '20260101000000000aaaa' -N 1
        $Root = (Resolve-Path -LiteralPath $Root).Path
        $Staging = Join-Path $Dir 'staging'
        $null = New-Item -ItemType Directory -Path (Join-Path $Staging '.reveal-tmp') -Force
        $MarkData = [ordered]@{ Purpose = 'Reveal staging folder'; InventoryRoot = $Root; Fields = @('ResourceGroup', 'Subscription'); All = $false; Outputs = @{} }
        [System.IO.File]::WriteAllText((Join-Path $Staging '.reveal-staging.json'), ($MarkData | ConvertTo-Json -Depth 5))

        $Run = Invoke-Reveal -Root $Root -Staging $Staging -Bundle (Join-Path $Dir 'bundle.zip')

        $Run.Exit | Should -Be 0 -Because $Run.Text
    }
}

Describe 'Reveal.ps1 and a report folder whose mark has a malformed output record' -Skip:$IsWindows {
    It 'reads the folder as a report folder and ships its report' {
        $Root = Join-Path $script:WorkDir 'badrecordfolder'
        Add-Report -Folder (Join-Path $Root 'good') -Stamp '20260101000000000aaaa' -N 1
        Add-Report -Folder (Join-Path $Root 'marked') -Stamp '20260101000000001bbbb' -N 2
        $Record = [ordered]@{ Sha256 = $script:Sha; SourceFolder = 'good'; SourceName = 'ResourcesReport_x.zip'; SourceSha256 = 'short'; DictionaryName = 'd.json'; DictionarySha256 = $script:Sha }
        $Mark = [ordered]@{ Purpose = 'Reveal staging folder'; InventoryRoot = (Resolve-Path -LiteralPath $Root).Path; Fields = @('ResourceGroup', 'Subscription'); All = $false; Outputs = @{ 'ResourcesReport_x_revealed.zip' = $Record } }
        [System.IO.File]::WriteAllText((Join-Path $Root 'marked/.reveal-staging.json'), ($Mark | ConvertTo-Json -Depth 5))
        $Staging = Join-Path $script:WorkDir 'badrecordfolder_staging'
        $Bundle = Join-Path $script:WorkDir 'badrecordfolder_bundle.zip'

        $Run = Invoke-Reveal -Root $Root -Staging $Staging -Bundle $Bundle

        $Run.Exit | Should -Be 0 -Because $Run.Text
        Get-ZipNames $Bundle | Should -Be @(
            'ResourcesReport_20260101000000000aaaa.zip'
            'ResourcesReport_20260101000000001bbbb.zip')
        $Run.Text | Should -Not -Match 'SKIP: marked'
    }

    It 'still skips a folder whose mark has the whole Reveal shape' {
        $Root = Join-Path $script:WorkDir 'goodrecordfolder'
        Add-Report -Folder (Join-Path $Root 'good') -Stamp '20260101000000000aaaa' -N 1
        $Old = Join-Path $Root 'old'
        $null = New-Item -ItemType Directory -Path $Old -Force
        $Record = [ordered]@{ Sha256 = $script:Sha; SourceFolder = 'good'; SourceName = 'ResourcesReport_x.zip'; SourceSha256 = $script:Sha; DictionaryName = 'd.json'; DictionarySha256 = $script:Sha }
        $Mark = [ordered]@{ Purpose = 'Reveal staging folder'; InventoryRoot = (Resolve-Path -LiteralPath $Root).Path; Fields = @('ResourceGroup', 'Subscription'); All = $false; Outputs = @{ 'ResourcesReport_x_revealed.zip' = $Record } }
        [System.IO.File]::WriteAllText((Join-Path $Old '.reveal-staging.json'), ($Mark | ConvertTo-Json -Depth 5))

        $Run = Invoke-Reveal -Root $Root -Staging (Join-Path $script:WorkDir 'goodrecordfolder_staging') -Bundle (Join-Path $script:WorkDir 'goodrecordfolder_bundle.zip')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'SKIP: old - a staging folder of an earlier reveal'
    }
}
