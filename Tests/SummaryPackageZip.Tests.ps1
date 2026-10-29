# =============================================================================
# Build-MainSummaryFromZip.ps1 -PackageZip contents.
#
# The portable bundle must hold only what this call reconstructed: the summary
# html and one ResourcesReport_<stamp>/ folder per per-subscription zip in the
# input. -OutputDirectory can be a folder that already holds other files, such
# as an earlier reconstruction, an obfuscation dictionary, a plain inventory,
# the wrapper's own per-subscription folders, or the wrapper's resume state
# file (.resume-state-<tenant>.json, which lists subscription ids). None of
# those may end up in the bundle. On Windows a leading dot does not hide a
# file, so a wildcard over the folder would pick up the resume state file too.
#
# Runs the real script against a stand-in consolidated zip in the shape the
# wrapper writes. Offline; generic names and the documentation placeholder id.
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:Script = Join-Path $script:RepoRoot 'Build-MainSummaryFromZip.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('SummaryPackageZip_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null
    $script:PlaceholderId = '12345678-1234-1234-1234-123456789012'

    # One per-subscription report as ResourceInventory.ps1 names its files.
    function New-SubReportFiles
    {
        param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Stamp, [string]$SubName = 'Demo Subscription')
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Base = 'ResourcesReport_' + $Stamp
        $Inv = [ordered]@{ Version = '3.2.3'; PublicIP = @([ordered]@{ Name = 'pip-demo'; Subscription = $SubName; Location = 'eastus'; ResourceGroup = 'rg-demo' }) }
        ($Inv | ConvertTo-Json -Depth 6) | Out-File -FilePath (Join-Path $Dir ('Inventory_' + $Base + '.json')) -Encoding utf8
        '<!DOCTYPE html><html><body>per-subscription report</body></html>' | Out-File -FilePath (Join-Path $Dir ($Base + '.html')) -Encoding utf8
        'MeterCategory,Quantity' | Out-File -FilePath (Join-Path $Dir ('Consumption_' + $Base + '.csv')) -Encoding utf8
        '{"Metrics":[]}' | Out-File -FilePath (Join-Path $Dir ('Metrics_' + $Base + '.json')) -Encoding utf8
    }

    # Consolidated zip in the wrapper's shape: one ResourcesReport_<stamp>.zip
    # per subscription (flat members) plus RunSummary.log, MainSummary.html and
    # HTML<stamp>/ copies at the root. Returns the zip path and the stamps.
    function New-ConsolidatedZip
    {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Stamps)
        $Stage = Join-Path $Root ('outer_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $Stage -Force | Out-Null
        foreach ($Stamp in $Stamps)
        {
            $Src = Join-Path $Root ('sub_' + $Stamp)
            New-SubReportFiles -Dir $Src -Stamp $Stamp
            Compress-Archive -Path (Join-Path $Src '*') -DestinationPath (Join-Path $Stage ('ResourcesReport_' + $Stamp + '.zip')) -Force
            $HtmlDir = Join-Path $Stage ('HTML' + $Stamp)
            New-Item -ItemType Directory -Path $HtmlDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $Src ('ResourcesReport_' + $Stamp + '.html')) -Destination $HtmlDir
        }
        'run summary' | Out-File -FilePath (Join-Path $Stage 'RunSummary.log') -Encoding utf8
        '<!DOCTYPE html><html><body>bundled summary</body></html>' | Out-File -FilePath (Join-Path $Stage 'MainSummary.html') -Encoding utf8
        $Zip = Join-Path $Root 'AllSubscriptions_ResourcesReport_2026-01-02_03-04-05.zip'
        Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip -Force
        return $Zip
    }

    # Entry names with '/' separators, file entries only.
    function Get-ZipEntryNames
    {
        param([Parameter(Mandatory)][string]$ZipPath)
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try
        {
            @($Archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') -and -not $_.FullName.EndsWith('\') } | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
        }
        finally { $Archive.Dispose() }
    }

    # What this call reconstructs from the input: the summary plus, per
    # subscription, the report html and the inventory json.
    function Get-ExpectedEntries
    {
        param([Parameter(Mandatory)][string[]]$Stamps)
        $Names = @('MainSummary.html')
        foreach ($Stamp in $Stamps)
        {
            $Base = 'ResourcesReport_' + $Stamp
            $Names += ('{0}/{0}.html' -f $Base)
            $Names += ('{0}/Inventory_{0}.json' -f $Base)
        }
        @($Names | Sort-Object)
    }

    $script:Stamps = @('20260102030405001', '20260102030405002')
    $script:InputZip = New-ConsolidatedZip -Root $script:TmpRoot -Stamps $script:Stamps
}

AfterAll {
    if ($script:TmpRoot -and (Test-Path -LiteralPath $script:TmpRoot)) { Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Build-MainSummaryFromZip -PackageZip into a folder that already holds other files' {

    BeforeAll {
        # The wrapper's inventory root after a run, plus an earlier reconstruction.
        $script:Reused = Join-Path $script:TmpRoot 'InventoryReports'
        New-Item -ItemType Directory -Path $script:Reused -Force | Out-Null

        $script:Earlier = Join-Path $script:Reused 'ResourcesReport_20251201000000001'
        New-Item -ItemType Directory -Path $script:Earlier -Force | Out-Null
        '{"Version":"3.2.3"}' | Out-File -FilePath (Join-Path $script:Earlier 'Inventory_ResourcesReport_20251201000000001.json') -Encoding utf8
        '<html><body>earlier report</body></html>' | Out-File -FilePath (Join-Path $script:Earlier 'ResourcesReport_20251201000000001.html') -Encoding utf8

        $script:WrapperSub = Join-Path $script:Reused 'ResourcesReport20251201000000002'
        New-SubReportFiles -Dir $script:WrapperSub -Stamp '20251201000000002'
        '{"ResourceIdMap":{}}' | Out-File -FilePath (Join-Path $script:WrapperSub 'ObfuscationDictionary_ResourcesReport_20251201000000002.json') -Encoding utf8
        '{"data":[]}' | Out-File -FilePath (Join-Path $script:WrapperSub 'Full_ResourcesReport_20251201000000002.json') -Encoding utf8

        $script:Unrelated = @(
            (Join-Path $script:Reused 'ObfuscationDictionary_ResourcesReport_20251201000000003.json'),
            (Join-Path $script:Reused 'Inventory_ResourcesReport_20251201000000003.json'),
            (Join-Path $script:Reused ('.resume-state-{0}.json' -f $script:PlaceholderId))
        )
        '{"ResourceIdMap":{}}' | Out-File -FilePath $script:Unrelated[0] -Encoding utf8
        '{"Version":"3.2.3","PublicIP":[{"Name":"pip-plain"}]}' | Out-File -FilePath $script:Unrelated[1] -Encoding utf8
        ([ordered]@{ TenantID = $script:PlaceholderId; CompletedSubscriptionIds = @($script:PlaceholderId); FailedAttempts = @() } | ConvertTo-Json) |
            Out-File -FilePath $script:Unrelated[2] -Encoding utf8

        & $script:Script -InputZip $script:InputZip -OutputDirectory $script:Reused -PackageZip 6>$null | Out-Null
        $script:Package = $script:Reused.TrimEnd([IO.Path]::DirectorySeparatorChar) + '.zip'
        $script:Entries = if (Test-Path -LiteralPath $script:Package) { Get-ZipEntryNames -ZipPath $script:Package } else { @() }
    }

    It 'writes the package next to the folder' {
        Test-Path -LiteralPath $script:Package | Should -BeTrue
    }

    It 'holds exactly the summary and the folders reconstructed from the input zip' {
        $script:Entries | Should -Be (Get-ExpectedEntries -Stamps $script:Stamps)
    }

    It 'leaves out the earlier reconstruction, the wrapper folder, the dictionary and the plain inventory' {
        @($script:Entries | Where-Object { $_ -like 'ResourcesReport_20251201000000001/*' }) | Should -BeNullOrEmpty
        @($script:Entries | Where-Object { $_ -like 'ResourcesReport20251201000000002/*' }) | Should -BeNullOrEmpty
        @($script:Entries | Where-Object { $_ -like '*ObfuscationDictionary_*' -or $_ -like '*Full_*' }) | Should -BeNullOrEmpty
        @($script:Entries | Where-Object { $_ -notlike '*/*' -and $_ -like 'Inventory_*' }) | Should -BeNullOrEmpty
    }

    It 'never includes the resume state file' {
        @($script:Entries | Where-Object { (Split-Path -Path $_ -Leaf) -like '.resume-state*' }) | Should -BeNullOrEmpty
    }

    It 'leaves the other files in the folder in place' {
        foreach ($File in $script:Unrelated) { Test-Path -LiteralPath $File | Should -BeTrue }
        Test-Path -LiteralPath $script:Earlier | Should -BeTrue
        Test-Path -LiteralPath $script:WrapperSub | Should -BeTrue
    }
}

Describe 'Build-MainSummaryFromZip -PackageZip into a new folder' {

    BeforeAll {
        $script:Fresh = Join-Path $script:TmpRoot 'fresh_MainSummary'
        & $script:Script -InputZip $script:InputZip -OutputDirectory $script:Fresh -PackageZip 6>$null | Out-Null
        $script:FreshPackage = $script:Fresh + '.zip'
    }

    It 'holds the summary and every reconstructed folder' {
        Get-ZipEntryNames -ZipPath $script:FreshPackage | Should -Be (Get-ExpectedEntries -Stamps $script:Stamps)
    }

    It 'keeps every summary link resolvable after extraction elsewhere' {
        $Extract = Join-Path $script:TmpRoot 'extracted'
        Expand-Archive -LiteralPath $script:FreshPackage -DestinationPath $Extract -Force
        $Html = Get-Content -LiteralPath (Join-Path $Extract 'MainSummary.html') -Raw
        $Links = @([regex]::Matches($Html, 'href="([^"]+\.html)"') | ForEach-Object { $_.Groups[1].Value })
        $Links.Count | Should -Be $script:Stamps.Count
        foreach ($Link in $Links) { Test-Path -LiteralPath (Join-Path $Extract $Link) | Should -BeTrue -Because "'$Link' is in the package" }
    }
}
