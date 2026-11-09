# -OutputDirectory with [ or ] in its name
# Run with: Invoke-Pester ./Tests/OutputDirectoryBrackets.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Resolve-Path, Test-Path, Get-ChildItem and the file writers read -Path as a
# wildcard pattern, where [ab] means "a or b". An -OutputDirectory such as
# 'out[1]' then matched nothing: Resolve-Path gave no path, so the report
# folder became '' + '/' (the drive root) and the pre-flight write probe
# stopped the run with 'cannot write to :'. When a folder the pattern matches
# exists ('out1' for 'out[1]'), the run's files went to that folder instead.
# The script now passes these paths with -LiteralPath.
#
# The test copies the scripts to a temp folder and runs the REAL
# ResourceInventory.ps1 in a child pwsh (Tests/Helpers/InnerRunHarness.ps1)
# against offline stand-ins: with an output folder named 'out[1]' next to a
# folder 'out1' the pattern would match, 'out[a]' next to 'outa', 'out[b]'
# with nothing the pattern matches, and with the scripts themselves in a
# folder named 'tree[2]', each under en-US and tr-TR. A plain folder name is
# the control. Placeholder ids only; no live
# Azure.
#
# Not run on Windows: the harness's stand-ins are written for the Unix paths.

BeforeDiscovery {
    $script:Cases = @(
        foreach ($Culture in @('en-US', 'tr-TR'))
        {
            @{ Culture = $Culture; Folder = 'out-plain'; TreeName = 'tree'; Decoy = $false }
            @{ Culture = $Culture; Folder = 'out[1]'; TreeName = 'tree'; Decoy = $true }
            @{ Culture = $Culture; Folder = 'out[a]'; TreeName = 'tree'; Decoy = $true }
            @{ Culture = $Culture; Folder = 'out[b]'; TreeName = 'tree'; Decoy = $false }
            @{ Culture = $Culture; Folder = 'out[3]'; TreeName = 'tree[2]'; Decoy = $true }
        }
    )
}

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Harness = Join-Path $PSScriptRoot 'Helpers/InnerRunHarness.ps1'
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('OutputDirectoryBrackets_' + [guid]::NewGuid().ToString('N'))
    foreach ($TreeName in @('tree', 'tree[2]'))
    {
        $Tree = Join-Path $script:WorkDir $TreeName
        $null = New-Item -ItemType Directory -Path $Tree -Force
        foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
        {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $Tree -Recurse -Force
        }
    }

    # One direct run into <case folder>/<Folder>, with a folder the wildcard
    # pattern would match beside it. Returns the exit code, the console text
    # and the names of the files in both folders.
    function Invoke-BracketRun
    {
        param([string]$Culture, [string]$Folder, [string]$TreeName, [bool]$Decoy)
        $Case = Join-Path $script:WorkDir ('case_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Out = Join-Path $Case $Folder
        $DecoyPath = Join-Path $Case ($Folder -replace '[\[\]]', '')
        $null = New-Item -ItemType Directory -Path $Out -Force
        if ($Decoy) { $null = New-Item -ItemType Directory -Path $DecoyPath -Force }
        # The paths go in the environment: pwsh on Unix would expand out[1] in an
        # argument to out1, the folder beside it.
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Culture', $Culture)
        $env:RDA_INNER_HARNESS_TREE = Join-Path $script:WorkDir $TreeName
        $env:RDA_INNER_HARNESS_OUT = $Out
        try
        {
            $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
            $Exit = $LASTEXITCODE
        }
        finally
        {
            Remove-Item -LiteralPath 'env:RDA_INNER_HARNESS_TREE', 'env:RDA_INNER_HARNESS_OUT' -ErrorAction SilentlyContinue
        }
        $Zip = @(Get-ChildItem -LiteralPath $Out -Filter 'ResourcesReport_*.zip' -File)[0]
        $ZipEntries = @()
        if ($null -ne $Zip)
        {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $Archive = [System.IO.Compression.ZipFile]::OpenRead($Zip.FullName)
            try { $ZipEntries = @($Archive.Entries | ForEach-Object Name) } finally { $Archive.Dispose() }
        }
        return [pscustomobject]@{
            ZipEntries = $ZipEntries
            Exit       = $Exit
            Console    = ($Console -join "`n")
            OutFiles   = @(Get-ChildItem -LiteralPath $Out -File | ForEach-Object Name)
            DecoyFiles = $(if ($DecoyPath -ne $Out -and (Test-Path -LiteralPath $DecoyPath)) { @(Get-ChildItem -LiteralPath $DecoyPath -Force | ForEach-Object Name) } else { @() })
        }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Direct run under <Culture> into ''<Folder>'', scripts in ''<TreeName>''' -ForEach $script:Cases -Skip:$IsWindows {
    BeforeAll {
        $script:Run = Invoke-BracketRun -Culture $Culture -Folder $Folder -TreeName $TreeName -Decoy $Decoy
    }

    It 'finishes with exit 0' {
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Console
    }

    It 'writes the report, the zip and the data files into the named folder' {
        foreach ($Pattern in @('ResourcesReport_*.html', 'ResourcesReport_*.zip', 'Inventory_ResourcesReport_*.json', 'Metrics_ResourcesReport_*.json', 'Consumption_ResourcesReport_*.csv', 'Transcript_Log_ResourcesReport_*.txt'))
        {
            @($script:Run.OutFiles | Where-Object { $_ -like $Pattern }).Count | Should -Be 1 -Because ("{0} in {1}: [{2}]`n{3}" -f $Pattern, $Folder, ($script:Run.OutFiles -join ', '), $script:Run.Console)
        }
    }

    It 'puts the report, the consumption sheet, the inventory and the diagnostics log in the zip' {
        foreach ($Pattern in @('ResourcesReport_*.html', 'Consumption_ResourcesReport_*.csv', 'Inventory_ResourcesReport_*.json', 'Diagnostics_ResourcesReport_*.log'))
        {
            @($script:Run.ZipEntries | Where-Object { $_ -like $Pattern }).Count | Should -Be 1 -Because ("{0} in the zip: [{1}]" -f $Pattern, ($script:Run.ZipEntries -join ', '))
        }
    }

    It 'writes nothing into the folder the name would match as a pattern' {
        $script:Run.DecoyFiles | Should -BeNullOrEmpty
    }

    It 'names the folder in its log lines' {
        $script:Run.Console | Should -Match ([regex]::Escape('/' + $Folder + '/ResourcesReport_'))
    }
}
