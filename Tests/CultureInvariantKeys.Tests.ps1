# Inventory on a host with a Turkish culture
# Run with: Invoke-Pester ./Tests/CultureInvariantKeys.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# String.ToLower() follows the culture of the host. Under tr-TR (and az-Latn)
# the capital I becomes a dotless i (U+0131), not 'i'. A -ResourceGroup run
# lowercased the group's name that way, so 'RG-INFRA' became 'rg-ınfra': the
# Resource Graph query (== is case-sensitive) matched no resource and the
# report came out empty. The Resource Graph rows are lowercased too; a key such
# as subscriptionId would turn into 'subscriptionıd' and the Subscription
# column would be lost the same way.
#
# The test copies the scripts to a temp folder and runs the REAL
# ResourceInventory.ps1 in a child pwsh (Tests/Helpers/InnerRunHarness.ps1)
# against offline stand-ins, under en-US and under tr-TR, with and without
# -ResourceGroup RG-INFRA. The one disk lives in RG-INFRA. Placeholder ids
# only; no live Azure.
#
# Not run on Windows: the harness's stand-ins are written for the Unix paths.

BeforeDiscovery {
    $script:Cases = @(
        foreach ($Culture in @('en-US', 'tr-TR'))
        {
            @{ Culture = $Culture; ResourceGroup = '' }
            @{ Culture = $Culture; ResourceGroup = 'RG-INFRA' }
        }
    )
}

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Harness = Join-Path $PSScriptRoot 'Helpers/InnerRunHarness.ps1'
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('CultureInvariantKeys_' + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -Path (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    # One direct run; returns its exit code, console text and the VMDisk rows of
    # the Inventory JSON in its output folder.
    function Invoke-CultureRun
    {
        param([string]$Culture, [string]$ResourceGroup)
        $Out = Join-Path $script:WorkDir ('out_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', $Out, '-Culture', $Culture)
        if ($ResourceGroup) { $ArgList += @('-ResourceGroup', $ResourceGroup) }
        $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        $Exit = $LASTEXITCODE
        $Json = @(Get-ChildItem -LiteralPath $Out -Filter 'Inventory_*.json' -File)[0]
        $Disks = if ($null -ne $Json) { @((Get-Content -LiteralPath $Json.FullName -Raw | ConvertFrom-Json).VMDisk) } else { $null }
        return [pscustomobject]@{ Exit = $Exit; Console = ($Console -join "`n"); Disks = $Disks }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Direct run under <Culture>, -ResourceGroup ''<ResourceGroup>''' -ForEach $script:Cases -Skip:$IsWindows {
    BeforeAll {
        $script:Run = Invoke-CultureRun -Culture $Culture -ResourceGroup $ResourceGroup
    }

    It 'finishes with exit 0' {
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Console
    }

    It 'lists the disk in resource group RG-INFRA' {
        @($script:Run.Disks).Count | Should -Be 1 -Because $script:Run.Console
        $script:Run.Disks[0].Name | Should -BeExactly 'disk-infra'
        $script:Run.Disks[0].ResourceGroup | Should -BeExactly 'rg-infra'
    }

    It 'keeps the Subscription column' {
        $script:Run.Disks[0].Subscription | Should -BeExactly 'Demo Subscription 1'
    }

    It 'logs the resource group in small letters with a dotted i' {
        if (-not $ResourceGroup) { Set-ItResult -Skipped -Because 'this run has no -ResourceGroup' }
        $script:Run.Console | Should -Match 'And from Resource Group: rg-infra'
        $script:Run.Console | Should -Not -Match ([string][char]0x0131)
    }
}
