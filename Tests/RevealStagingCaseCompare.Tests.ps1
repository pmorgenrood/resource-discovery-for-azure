# Reveal with a staging folder whose name differs from a report folder only by case
# Run with: Invoke-Pester ./Tests/RevealStagingCaseCompare.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Reveal.ps1 leaves its own staging folder out of the report folders it reads,
# and refuses an -OutputZip inside staging. Both compared the paths with
# PowerShell's -ne and -eq, which ignore case on every platform. On Linux,
# where 'ResourcesReportX' and 'resourcesreportx' are two folders, a report
# folder whose name differed from staging only by case was dropped with no
# SKIP or FAIL line, so the run could exit 0 with that subscription missing,
# and an -OutputZip in such a folder was refused. Both now compare as the file
# system does: case-sensitive except on Windows.
#
# Linux only: it needs a case-sensitive file system. Placeholder values; no
# live Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealStagingCase_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    # One report as an inventory run writes it, for one subscription.
    function Add-Report
    {
        param([string]$Folder, [string]$Stamp, [string]$SubId, [string]$RgName)
        $null = New-Item -ItemType Directory -Path $Folder -Force
        $RgToken = 'prod_' + [guid]::NewGuid().ToString()
        $SubToken = 'prod_' + [guid]::NewGuid().ToString()
        $Archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Folder ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_ResourcesReport_' + $Stamp + '.json').Open())
            try { $Writer.Write('{"VirtualMachines":[{"ResourceGroup":"' + $RgToken + '","Subscription":"' + $SubToken + '"}]}') } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        $Id = '/subscriptions/' + $SubId + '/resourceGroups/' + $RgName + '/providers/Microsoft.Compute/virtualMachines/vm1'
        $Dict = '{"ResourceGroupMap":{"' + $RgToken + '":"' + $Id + '"},"SubscriptionMap":{"' + $SubToken + '":"' + $Id + '"},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText((Join-Path $Folder ('ObfuscationDictionary_ResourcesReport_' + $Stamp + '.json')), $Dict)
    }

    function Get-ZipNames
    {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return @($Archive.Entries | ForEach-Object FullName | Sort-Object) } finally { $Archive.Dispose() }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 with staging named as a report folder in another case' -Skip:($IsWindows -or $IsMacOS) {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'root'
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000000aaaa') -Stamp '20260101000000000aaaa' -SubId '00000000-0000-0000-0000-00000000000a' -RgName 'rg-a'
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000001bbbb') -Stamp '20260101000000001bbbb' -SubId '00000000-0000-0000-0000-00000000000b' -RgName 'rg-b'
        # Staging in the root, named as the first report folder in lower case.
        $script:Staging = Join-Path $script:Root 'resourcesreport20260101000000000aaaa'
        $script:Bundle = Join-Path $script:WorkDir 'bundle.zip'
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $script:Root -StagingDirectory $script:Staging -OutputZip $script:Bundle -FolderTimeoutMinutes 5 2>&1 | ForEach-Object { [string]$_ })
        $script:Exit = $LASTEXITCODE
        $script:Text = $Console -join "`n"
    }

    It 'reads the report folder that differs from staging only by case, and ships both reports' {
        $script:Exit | Should -Be 0 -Because $script:Text
        Get-ZipNames $script:Bundle | Should -Be @('ResourcesReport_20260101000000000aaaa.zip', 'ResourcesReport_20260101000000001bbbb.zip')
    }
}

Describe 'Reveal.ps1 with -OutputZip in a folder named as staging in another case' -Skip:($IsWindows -or $IsMacOS) {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'root2'
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000000aaaa') -Stamp '20260101000000000aaaa' -SubId '00000000-0000-0000-0000-00000000000a' -RgName 'rg-a'
        $script:Staging = Join-Path $script:WorkDir 'staging'
        $script:OutDir = Join-Path $script:WorkDir 'STAGING'
        $null = New-Item -ItemType Directory -Path $script:OutDir -Force
        $script:Bundle = Join-Path $script:OutDir 'bundle.zip'
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $script:Root -StagingDirectory $script:Staging -OutputZip $script:Bundle -FolderTimeoutMinutes 5 2>&1 | ForEach-Object { [string]$_ })
        $script:Exit = $LASTEXITCODE
        $script:Text = $Console -join "`n"
    }

    It 'accepts it and writes the bundle there' {
        $script:Text | Should -Not -Match '-OutputZip must not be inside the staging directory'
        $script:Exit | Should -Be 0 -Because $script:Text
        Get-ZipNames $script:Bundle | Should -Be @('ResourcesReport_20260101000000000aaaa.zip')
    }
}
