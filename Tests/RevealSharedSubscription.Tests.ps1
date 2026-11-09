# Reveal over an inventory root where one subscription is in more than one report
# Run with: Invoke-Pester ./Tests/RevealSharedSubscription.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Run-AllSubscriptions.ps1 writes a new folder ResourcesReport<stamp> per
# subscription on every run, all under the same inventory root, and the
# recovery recipe (a seeded ResourceInventory.ps1 run of one service, with no
# consumption) writes one more folder there. Reveal.ps1 used to reveal every
# report, which counted resources twice, and then only the newest report of
# each subscription, which shipped the one-service recovery report and dropped
# the full run's consumption with exit 0. Its key was also the whole set of
# subscriptions of a report, so a report of A and B and a later report of A
# were both shipped.
# Reveal now never guesses: any report that shares a subscription id (read
# from its dictionary) or its stamp with another report is left out, each
# such subscription is named by its masked token with the reports that hold
# it, the run exits non-zero, and every subscription with exactly one report
# still ships. Each report is paired only with the dictionary of its own
# stamp.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealSharedSub_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    $script:SubA = '00000000-0000-0000-0000-00000000000a'
    $script:SubB = '00000000-0000-0000-0000-00000000000b'
    $script:SubC = '00000000-0000-0000-0000-00000000000c'

    function New-Token { return 'prod_' + [guid]::NewGuid().ToString() }

    # One report as an inventory run writes it: ResourcesReport_<stamp>.zip and
    # ObfuscationDictionary_ResourcesReport_<stamp>.json in $Folder. Each entry
    # of $Subs is @{ Id; RgName; RgToken; SubToken }; -Consumption adds a
    # Consumption member, as a full run has and a recovery run does not.
    # -NoDictionary leaves the dictionary out; -Empty writes a report with no
    # resources and an empty dictionary.
    function Add-Report
    {
        param([string]$Folder, [string]$Stamp, [object[]]$Subs = @(), [switch]$Consumption, [switch]$NoDictionary, [switch]$Empty)
        $null = New-Item -ItemType Directory -Path $Folder -Force
        $Archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Folder ('ResourcesReport_' + $Stamp + '.zip')), 'Create')
        try
        {
            $Rows = if ($Empty) { '' } else { (@($Subs | ForEach-Object { '{"ResourceGroup":"' + $_.RgToken + '","Subscription":"' + $_.SubToken + '"}' }) -join ',') }
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_ResourcesReport_' + $Stamp + '.json').Open())
            try { $Writer.Write('{"VirtualMachines":[' + $Rows + ']}') } finally { $Writer.Dispose() }
            if ($Consumption)
            {
                $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Consumption_ResourcesReport_' + $Stamp + '.csv').Open())
                try { $Writer.Write("ResourceGroup,Cost`n" + $Subs[0].RgToken + ",1.5`n") } finally { $Writer.Dispose() }
            }
        }
        finally { $Archive.Dispose() }
        if ($NoDictionary) { return }
        $RgMap = @(); $SubMap = @(); $NameMap = @()
        if (-not $Empty)
        {
            foreach ($S in $Subs)
            {
                $Id = '/subscriptions/' + $S.Id + '/resourceGroups/' + $S.RgName + '/providers/Microsoft.Compute/virtualMachines/vm1'
                $RgMap += '"' + $S.RgToken + '":"' + $Id + '"'
                $SubMap += '"' + $S.SubToken + '":"' + $Id + '"'
                $NameMap += '"Sub ' + $S.Id.Substring(35) + '"'
            }
        }
        $SubNameMap = @(for ($i = 0; $i -lt $SubMap.Count; $i++) { '"' + $Subs[$i].SubToken + '":' + $NameMap[$i] })
        $Dict = '{"ResourceGroupMap":{' + ($RgMap -join ',') + '},"SubscriptionMap":{' + ($SubMap -join ',') + '},"SubscriptionNameMap":{' + ($SubNameMap -join ',') + '},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText((Join-Path $Folder ('ObfuscationDictionary_ResourcesReport_' + $Stamp + '.json')), $Dict)
    }

    function New-Sub
    {
        param([string]$Id, [string]$RgName)
        return @{ Id = $Id; RgName = $RgName; RgToken = (New-Token); SubToken = (New-Token) }
    }

    function Invoke-Reveal
    {
        param([string]$Root, [string]$Name)
        $Staging = Join-Path $script:WorkDir ($Name + '_staging')
        $Bundle = Join-Path $script:WorkDir ($Name + '_bundle.zip')
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $Root -StagingDirectory $Staging -OutputZip $Bundle -FolderTimeoutMinutes 5 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($Console -join "`n"); Lines = $Console; Bundle = $Bundle; Staging = $Staging }
    }

    function Get-ZipNames
    {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
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

    # The one FAIL line that names this masked subscription token.
    function Get-FailLine
    {
        param($Run, [string]$Token)
        return @($Run.Lines | Where-Object { $_ -like '  FAIL: *' -and $_.Contains($Token) })
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 with a full run and a newer scoped recovery run of one subscription' {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'recovery'
        # The full run of A (with consumption) and of B, then a newer seeded
        # recovery run of A with one service and no consumption.
        $script:AFull = New-Sub -Id $script:SubA -RgName 'rg-a-full'
        $script:BFull = New-Sub -Id $script:SubB -RgName 'rg-b-full'
        $script:ARecovery = New-Sub -Id $script:SubA -RgName 'rg-a-recovery'
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000000aaaa') -Stamp '20260101000000000aaaa' -Subs @($script:AFull) -Consumption
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000001bbbb') -Stamp '20260101000000001bbbb' -Subs @($script:BFull) -Consumption
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260303000000000cccc') -Stamp '20260303000000000cccc' -Subs @($script:ARecovery)
        $script:Run = Invoke-Reveal -Root $script:Root -Name 'recovery'
    }

    It 'ends with a non-zero exit' {
        $script:Run.Exit | Should -Not -Be 0 -Because $script:Run.Text
    }

    It 'fails the subscription and names both reports that hold it' {
        $Line = @(Get-FailLine $script:Run $script:AFull.SubToken)
        $Line.Count | Should -Be 1 -Because $script:Run.Text
        $Line[0] | Should -Match ([regex]::Escape($script:ARecovery.SubToken))
        $Line[0] | Should -Match 'ResourcesReport20260101000000000aaaa/ResourcesReport_20260101000000000aaaa\.zip'
        $Line[0] | Should -Match 'ResourcesReport20260303000000000cccc/ResourcesReport_20260303000000000cccc\.zip'
        $Line[0] | Should -Match '-InventoryRoot pointing at one run''s folders, or move the extra report away'
    }

    It 'leaves both reports of that subscription out and says so' {
        $script:Run.Text | Should -Match 'Left out \(sub in >1 report\)\s+: 2'
        $script:Run.Text | Should -Match 'LEFT OUT: ResourcesReport20260101000000000aaaa/ResourcesReport_20260101000000000aaaa\.zip'
        $script:Run.Text | Should -Match 'LEFT OUT: ResourcesReport20260303000000000cccc/ResourcesReport_20260303000000000cccc\.zip'
    }

    It 'still reveals and ships the subscription that has one report' {
        Get-ZipNames $script:Run.Bundle | Should -Be @('ResourcesReport_20260101000000001bbbb.zip')
        Get-InnerText (Join-Path $script:Run.Staging 'ResourcesReport_20260101000000001bbbb.zip') | Should -Match 'rg-b-full'
    }

    It 'never prints a real subscription id' {
        $script:Run.Text | Should -Not -Match $script:SubA
        $script:Run.Text | Should -Not -Match $script:SubB
    }
}

Describe 'Reveal.ps1 with a run over A and B and a later run of A' {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'overlap'
        $script:A1 = New-Sub -Id $script:SubA -RgName 'rg-a-1'
        $script:B1 = New-Sub -Id $script:SubB -RgName 'rg-b-1'
        $script:A2 = New-Sub -Id $script:SubA -RgName 'rg-a-2'
        $script:C1 = New-Sub -Id $script:SubC -RgName 'rg-c-1'
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000000abab') -Stamp '20260101000000000abab' -Subs @($script:A1, $script:B1) -Consumption
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260202000000000aaaa') -Stamp '20260202000000000aaaa' -Subs @($script:A2) -Consumption
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260202000000001cccc') -Stamp '20260202000000001cccc' -Subs @($script:C1) -Consumption
        $script:Run = Invoke-Reveal -Root $script:Root -Name 'overlap'
    }

    It 'ends with a non-zero exit' {
        $script:Run.Exit | Should -Not -Be 0 -Because $script:Run.Text
    }

    It 'fails A, naming both reports that hold it' {
        $Line = @(Get-FailLine $script:Run $script:A1.SubToken)
        $Line.Count | Should -Be 1 -Because $script:Run.Text
        $Line[0] | Should -Match ([regex]::Escape($script:A2.SubToken))
        $Line[0] | Should -Match 'ResourcesReport_20260101000000000abab\.zip'
        $Line[0] | Should -Match 'ResourcesReport_20260202000000000aaaa\.zip'
    }

    It 'leaves out both reports that hold A, and names B as left out with the A and B report' {
        $script:Run.Text | Should -Match 'Left out \(sub in >1 report\)\s+: 2'
        $Ab = @($script:Run.Lines | Where-Object { $_ -like '  LEFT OUT: ResourcesReport20260101000000000abab/*' })
        $Ab.Count | Should -Be 1 -Because $script:Run.Text
        $Ab[0] | Should -Match ([regex]::Escape($script:A1.SubToken))
        $Ab[0] | Should -Match ([regex]::Escape($script:B1.SubToken))
        $script:Run.Text | Should -Match 'LEFT OUT: ResourcesReport20260202000000000aaaa/'
    }

    It 'still ships C, which is in one report' {
        Get-ZipNames $script:Run.Bundle | Should -Be @('ResourcesReport_20260202000000001cccc.zip')
    }
}

Describe 'Reveal.ps1 with two reports of the same stamp' {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'samestamp'
        # A copied folder: the same stamp in two folders, here with different
        # subscriptions so only the stamp is shared.
        $script:S1 = New-Sub -Id $script:SubA -RgName 'rg-a'
        $script:S2 = New-Sub -Id $script:SubB -RgName 'rg-b'
        $script:S3 = New-Sub -Id $script:SubC -RgName 'rg-c'
        Add-Report -Folder (Join-Path $script:Root 'first') -Stamp '20260101000000000dddd' -Subs @($script:S1)
        Add-Report -Folder (Join-Path $script:Root 'second') -Stamp '20260101000000000dddd' -Subs @($script:S2)
        Add-Report -Folder (Join-Path $script:Root 'third') -Stamp '20260101000000001eeee' -Subs @($script:S3)
        $script:Run = Invoke-Reveal -Root $script:Root -Name 'samestamp'
    }

    It 'names both reports, leaves them out and exits non-zero' {
        $script:Run.Exit | Should -Not -Be 0 -Because $script:Run.Text
        $Line = @($script:Run.Lines | Where-Object { $_ -like '  FAIL: reports with the same stamp 20260101000000000dddd*' })
        $Line.Count | Should -Be 1 -Because $script:Run.Text
        $Line[0] | Should -Match 'first/ResourcesReport_20260101000000000dddd\.zip'
        $Line[0] | Should -Match 'second/ResourcesReport_20260101000000000dddd\.zip'
        $script:Run.Text | Should -Match 'LEFT OUT: first/ResourcesReport_20260101000000000dddd\.zip'
        $script:Run.Text | Should -Match 'LEFT OUT: second/ResourcesReport_20260101000000000dddd\.zip'
    }

    It 'still ships the report with its own stamp' {
        Get-ZipNames $script:Run.Bundle | Should -Be @('ResourcesReport_20260101000000001eeee.zip')
    }
}

Describe 'Reveal.ps1 with one report per subscription' {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'clean'
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000000aaaa') -Stamp '20260101000000000aaaa' -Subs @(New-Sub -Id $script:SubA -RgName 'rg-a') -Consumption
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000001bbbb') -Stamp '20260101000000001bbbb' -Subs @(New-Sub -Id $script:SubB -RgName 'rg-b') -Consumption
        # A subscription with no resources: an empty dictionary names no
        # subscription, so this report is revealed on its own.
        Add-Report -Folder (Join-Path $script:Root 'ResourcesReport20260101000000002cccc') -Stamp '20260101000000002cccc' -Empty
        $script:Run = Invoke-Reveal -Root $script:Root -Name 'clean'
    }

    It 'ships every report and exits 0' {
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Text
        Get-ZipNames $script:Run.Bundle | Should -Be @('ResourcesReport_20260101000000000aaaa.zip', 'ResourcesReport_20260101000000001bbbb.zip', 'ResourcesReport_20260101000000002cccc.zip')
        $script:Run.Text | Should -Match 'Left out \(sub in >1 report\)\s+: 0'
    }
}

Describe 'Reveal.ps1 with two stamps in one folder' {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'onefolder'
        $Folder = Join-Path $script:Root 'reused'
        # The older stamp's dictionary is missing; the newer stamp has its own.
        Add-Report -Folder $Folder -Stamp '20260101000000000eeee' -Subs @(New-Sub -Id $script:SubA -RgName 'rg-old') -NoDictionary
        Add-Report -Folder $Folder -Stamp '20260202000000000ffff' -Subs @(New-Sub -Id $script:SubA -RgName 'rg-new')
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
