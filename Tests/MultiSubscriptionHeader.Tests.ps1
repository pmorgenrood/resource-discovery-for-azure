# Report header of a direct run over several subscriptions
# Run with: Invoke-Pester ./Tests/MultiSubscriptionHeader.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# A direct run without -SubscriptionID inventories every subscription the
# sign-in lists into one report. Its header still read 'Subscription: <name>'
# with one subscription's name: Summary.ps1 took the name from the first
# record it found. The header now says how many subscriptions the report
# covers. A count says nothing that -Obfuscate would mask.
#
# The test copies the scripts to a temp folder and runs the REAL
# ResourceInventory.ps1 in a child pwsh (Tests/Helpers/InnerRunHarness.ps1)
# against offline stand-ins: two subscriptions without -SubscriptionID (with
# and without -Obfuscate), two subscriptions with -SubscriptionID, and one
# subscription without -SubscriptionID, under en-US and tr-TR. Each
# subscription holds one disk. Placeholder ids only; no live Azure.
#
# Not run on Windows: the harness's stand-ins are written for the Unix paths.

BeforeDiscovery {
    $Two = '12345678-1234-1234-1234-123456789012,placeholder-subscription-2'
    $One = '12345678-1234-1234-1234-123456789012'
    $script:Cases = @(
        foreach ($Culture in @('en-US', 'tr-TR'))
        {
            @{ Culture = $Culture; SubIds = $Two; AllSubs = $true; Obfuscate = $false; Header = '2 subscriptions (consolidated)'; Disks = 2; Name = 'two subscriptions, no -SubscriptionID' }
            @{ Culture = $Culture; SubIds = $Two; AllSubs = $true; Obfuscate = $true; Header = '2 subscriptions (consolidated)'; Disks = 2; Name = 'two subscriptions, no -SubscriptionID, -Obfuscate' }
            @{ Culture = $Culture; SubIds = $Two; AllSubs = $false; Obfuscate = $false; Header = 'Demo Subscription 1'; Disks = 1; Name = 'two subscriptions, -SubscriptionID' }
            @{ Culture = $Culture; SubIds = $One; AllSubs = $true; Obfuscate = $false; Header = 'Demo Subscription 1'; Disks = 1; Name = 'one subscription, no -SubscriptionID' }
        }
    )
}

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Harness = Join-Path $PSScriptRoot 'Helpers/InnerRunHarness.ps1'
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('MultiSubscriptionHeader_' + [guid]::NewGuid().ToString('N'))
    $script:Tree = Join-Path $script:WorkDir 'tree'
    $null = New-Item -ItemType Directory -Path $script:Tree -Force
    foreach ($Item in @('ResourceInventory.ps1', 'Version.json', 'Functions', 'Extension', 'Services'))
    {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $Item) -Destination $script:Tree -Recurse -Force
    }

    function Invoke-HeaderRun
    {
        param([string]$Culture, [string]$SubIds, [bool]$AllSubs, [bool]$Obfuscate)
        $Out = Join-Path $script:WorkDir ('out_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $Out -Force
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $script:Harness, '-Tree', $script:Tree, '-Out', $Out, '-Culture', $Culture, '-SubIds', $SubIds)
        if ($AllSubs) { $ArgList += '-AllSubs' }
        if ($Obfuscate) { $ArgList += '-Obfuscate' }
        $Console = @(& pwsh @ArgList 2>&1 | ForEach-Object { [string]$_ })
        $Exit = $LASTEXITCODE
        $Html = @(Get-ChildItem -LiteralPath $Out -Filter 'ResourcesReport_*.html' -File)[0]
        $Text = if ($null -ne $Html) { Get-Content -LiteralPath $Html.FullName -Raw } else { '' }
        $Json = @(Get-ChildItem -LiteralPath $Out -Filter 'Inventory_*.json' -File)[0]
        $Disks = if ($null -ne $Json) { @((Get-Content -LiteralPath $Json.FullName -Raw | ConvertFrom-Json).VMDisk) } else { @() }
        $Header = if ($Text -match '<div><b>Subscription:</b> ([^<]*)</div>') { $Matches[1] } else { '<no such line>' }
        return [pscustomobject]@{ Exit = $Exit; Console = ($Console -join "`n"); Header = $Header; Disks = $Disks; Html = $Text }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Direct run under <Culture>: <Name>' -ForEach $script:Cases -Skip:$IsWindows {
    BeforeAll {
        $script:Run = Invoke-HeaderRun -Culture $Culture -SubIds $SubIds -AllSubs $AllSubs -Obfuscate $Obfuscate
    }

    It 'finishes with exit 0' {
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Console
    }

    It 'lists the disk of every subscription it covers' {
        @($script:Run.Disks).Count | Should -Be $Disks
    }

    It 'names the subscription, or the number of subscriptions, in the header' {
        $script:Run.Header | Should -BeExactly $Header
    }

    It 'shows no subscription name under -Obfuscate' {
        if (-not $Obfuscate) { Set-ItResult -Skipped -Because 'this run is not obfuscated' }
        $script:Run.Html | Should -Not -Match 'Demo Subscription'
    }
}
