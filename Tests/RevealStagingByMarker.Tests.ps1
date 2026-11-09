# Reveal takes a folder under the inventory root as an earlier staging folder only by its Reveal mark
# Run with: Invoke-Pester ./Tests/RevealStagingByMarker.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Any folder under the inventory root whose name starts RevealedStaging_, or
# that held a file named .reveal-staging.json, was taken as a staging folder of
# an earlier reveal, even when it held a whole report pair and no Reveal mark.
# Reveal then left that report out with only a SKIP line, built a bundle
# without it and exited 0. A folder is now taken as staging only when it holds
# a Reveal mark for this inventory root; a name is not ownership evidence.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealStagingByMarker_' + [guid]::NewGuid().ToString('N'))
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

    function Invoke-Reveal
    {
        param([string]$Root, [string]$Name)
        $Staging = Join-Path $script:WorkDir ($Name + '_staging')
        $Bundle = Join-Path $script:WorkDir ($Name + '_bundle.zip')
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $Root -StagingDirectory $Staging -OutputZip $Bundle -FolderTimeoutMinutes 5 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($Console -join "`n"); Bundle = $Bundle }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 reads a report folder that only looks like staging' -Skip:$IsWindows {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'root'
        Add-Report -Folder (Join-Path $script:Root 'good') -Stamp '20260101000000000aaaa' -N 1
        # A report folder with a staging-like name and no mark.
        Add-Report -Folder (Join-Path $script:Root 'RevealedStaging_2026-01-01_00-00-00') -Stamp '20260101000000001bbbb' -N 2
        # A report folder holding a file of the mark's name that is not a mark.
        Add-Report -Folder (Join-Path $script:Root 'lookalike') -Stamp '20260101000000002cccc' -N 3
        [System.IO.File]::WriteAllText((Join-Path $script:Root 'lookalike/.reveal-staging.json'), '{}')
        # A report folder holding a Reveal mark of another inventory root.
        Add-Report -Folder (Join-Path $script:Root 'otherroot') -Stamp '20260101000000003dddd' -N 4
        $Mark = [ordered]@{ Purpose = 'Reveal staging folder'; InventoryRoot = (Join-Path $script:WorkDir 'elsewhere'); Fields = @('ResourceGroup', 'Subscription'); All = $false; Outputs = @{} }
        [System.IO.File]::WriteAllText((Join-Path $script:Root 'otherroot/.reveal-staging.json'), ($Mark | ConvertTo-Json -Depth 5))
        # A real staging folder of an earlier reveal of this root.
        $Old = Join-Path $script:Root 'old'
        $null = New-Item -ItemType Directory -Path $Old -Force
        Copy-Item -LiteralPath (Join-Path $script:Root 'good/ResourcesReport_20260101000000000aaaa.zip') -Destination $Old
        $OwnMark = [ordered]@{ Purpose = 'Reveal staging folder'; InventoryRoot = (Resolve-Path -LiteralPath $script:Root).Path; Fields = @('ResourceGroup', 'Subscription'); All = $false; Outputs = @{} }
        [System.IO.File]::WriteAllText((Join-Path $Old '.reveal-staging.json'), ($OwnMark | ConvertTo-Json -Depth 5))

        $script:Run = Invoke-Reveal -Root $script:Root -Name 'looks'
    }

    It 'reveals and ships every report pair, whatever its folder is named' {
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Text
        Get-ZipNames $script:Run.Bundle | Should -Be @(
            'ResourcesReport_20260101000000000aaaa.zip'
            'ResourcesReport_20260101000000001bbbb.zip'
            'ResourcesReport_20260101000000002cccc.zip'
            'ResourcesReport_20260101000000003dddd.zip')
        $script:Run.Text | Should -Match 'Paired \(zip \+ dictionary\)\s+: 4'
    }

    It 'skips only the folder that holds a Reveal mark for this root' {
        $script:Run.Text | Should -Match 'Skipped \(not a report folder\)\s+: 1'
        $script:Run.Text | Should -Match 'SKIP: old - a staging folder of an earlier reveal'
        $script:Run.Text | Should -Not -Match 'SKIP: RevealedStaging_'
        $script:Run.Text | Should -Not -Match 'SKIP: lookalike'
        $script:Run.Text | Should -Not -Match 'SKIP: otherroot'
    }
}

Describe 'Reveal.ps1 and an unmarked old staging folder' -Skip:$IsWindows {
    It 'fails it as a report zip with no dictionary, and says to move it away' {
        $Root = Join-Path $script:WorkDir 'unmarked'
        Add-Report -Folder (Join-Path $Root 'good') -Stamp '20260101000000000aaaa' -N 1
        $Old = Join-Path $Root 'RevealedStaging_2025-01-01_00-00-00'
        $null = New-Item -ItemType Directory -Path $Old -Force
        Copy-Item -LiteralPath (Join-Path $Root 'good/ResourcesReport_20260101000000000aaaa.zip') -Destination $Old

        $Run = Invoke-Reveal -Root $Root -Name 'unmarked'

        $Run.Exit | Should -Be 4 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match 'FAIL: RevealedStaging_2025-01-01_00-00-00 - an obfuscated report zip but no obfuscation dictionary in folder.*If this is a staging folder of an earlier reveal \(it holds no Reveal mark for this inventory root\), move it out of the inventory root'
    }
}

Describe 'Reveal.ps1 and a partial look-alike mark in a report folder' -Skip:$IsWindows {
    # A mark with this root's Purpose and InventoryRoot but without the rest
    # of the shape Reveal writes (Fields, All, Outputs) is not Reveal's, so it
    # is no evidence that the folder is an old staging folder.
    It 'reads the folder as a report folder and ships its report' {
        $Root = Join-Path $script:WorkDir 'partialmark'
        Add-Report -Folder (Join-Path $Root 'good') -Stamp '20260101000000000aaaa' -N 1
        Add-Report -Folder (Join-Path $Root 'partial') -Stamp '20260101000000001bbbb' -N 2
        $Mark = [ordered]@{ Purpose = 'Reveal staging folder'; InventoryRoot = (Resolve-Path -LiteralPath $Root).Path }
        [System.IO.File]::WriteAllText((Join-Path $Root 'partial/.reveal-staging.json'), ($Mark | ConvertTo-Json -Depth 5))

        $Run = Invoke-Reveal -Root $Root -Name 'partialmark'

        $Run.Exit | Should -Be 0 -Because $Run.Text
        Get-ZipNames $Run.Bundle | Should -Be @(
            'ResourcesReport_20260101000000000aaaa.zip'
            'ResourcesReport_20260101000000001bbbb.zip')
        $Run.Text | Should -Not -Match 'SKIP: partial'
    }
}
