# Reveal.ps1 over an inventory root named with '[' and ']'
# Run with: Invoke-Pester ./Tests/RevealBracketedOutputZip.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The all-subscriptions run builds the outer zip with Compress-Archive, whose
# -DestinationPath reads '[1]' as a wildcard that matches '1'. With an
# inventory root 'Reports[1]' next to a folder 'Reports1', the outer zip was
# written into 'Reports1', and the run then found no outer zip where it said
# it would be. The destination path is now escaped, so it is taken as written.
#
# The zip and dictionary are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealBracketedOutputZip_' + [guid]::NewGuid().ToString('N'))
    $script:Root = Join-Path $script:WorkDir 'Reports[1]'
    $script:Decoy = Join-Path $script:WorkDir 'Reports1'
    $null = New-Item -ItemType Directory -Path $script:Decoy -Force
    $Sub = Join-Path $script:Root 'sub'
    $null = New-Item -ItemType Directory -Path $Sub -Force

    $Token = 'prod_11111111-2222-3333-4444-555555555555'
    $Json = '{"ResourceGroupMap":{"' + $Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg"},"SubscriptionMap":{},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
    [System.IO.File]::WriteAllText((Join-Path $Sub 'ObfuscationDictionary_r.json'), $Json)
    $Archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Sub 'ResourcesReport_r.zip'), 'Create')
    try
    {
        $Entry = $Archive.CreateEntry('Inventory_r.json')
        $Writer = [System.IO.StreamWriter]::new($Entry.Open())
        try { $Writer.Write('{"VirtualMachines":[{"ResourceGroup":"' + $Token + '"}]}') } finally { $Writer.Dispose() }
    }
    finally { $Archive.Dispose() }

    # Default staging and default outer zip, both under the bracketed root.
    # The path is quoted: on Unix, pwsh expands a bare native argument as a
    # wildcard, which would hand Reveal.ps1 'Reports1' instead.
    $Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    $script:Console = @(& pwsh -NoProfile -NonInteractive -File "$Reveal" -InventoryRoot "$($script:Root)" -FolderTimeoutMinutes 5 2>&1 | ForEach-Object { [string]$_ })
    $script:Exit = $LASTEXITCODE
    $script:Text = $script:Console -join "`n"
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 with -InventoryRoot Reports[1] next to Reports1' {
    It 'ends with exit 0 and says where the outer zip is' {
        $script:Exit | Should -Be 0 -Because $script:Text
        $script:Text | Should -Match 'Consolidated 1 revealed report'
    }

    It 'writes the outer zip under Reports[1], holding the revealed report' {
        $Outer = @(Get-ChildItem -LiteralPath $script:Root -Filter 'AllSubscriptions_Revealed_*.zip' -File)
        $Outer.Count | Should -Be 1 -Because $script:Text
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Outer[0].FullName)
        try { @($Archive.Entries | ForEach-Object FullName) | Should -Be @('ResourcesReport_r.zip') } finally { $Archive.Dispose() }
    }

    It 'writes nothing into Reports1' {
        @(Get-ChildItem -LiteralPath $script:Decoy -Recurse -Force).Count | Should -Be 0
    }
}
