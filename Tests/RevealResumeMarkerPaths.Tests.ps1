# Reveal -Resume: refuse a staging mark whose output records Reveal did not write
# Run with: Invoke-Pester ./Tests/RevealResumeMarkerPaths.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# -Resume read every key of the mark's Outputs as a staged output's file name
# without checking it. A clean -Resume -RemoveStaging run then joined that name
# to the staging folder and deleted the file when its SHA-256 matched the
# record, so a key such as '../victim.txt' deleted a file outside staging.
# Reveal now checks each record before using any: the name is a plain file
# name directly in staging, and each field has the type Reveal writes, with
# each SHA-256 as 64 hex characters. One bad record refuses the mark, and
# nothing is written or deleted.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealResumeMarkerPaths_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force
    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'
    $script:SubToken = 'prod_22222222-3333-4444-5555-666666666666'

    # One revealed subscription folder, staged by a first clean run, and a
    # file beside staging that is not Reveal's.
    function New-StagedCase
    {
        param([string]$Name)
        $Dir = Join-Path $script:WorkDir $Name
        $Sub = Join-Path $Dir 'root/good'
        $null = New-Item -ItemType Directory -Path $Sub -Force
        $Archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Sub 'ResourcesReport_good.zip'), 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_r.json').Open())
            try { $Writer.Write('{"VirtualMachines":[{"ResourceGroup":"' + $script:Token + '","Subscription":"' + $script:SubToken + '"}]}') } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        $Dict = '{"ResourceGroupMap":{"' + $script:Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg"},"SubscriptionMap":{"' + $script:SubToken + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg/providers/Microsoft.Compute/virtualMachines/vm1"},"SubscriptionNameMap":{"' + $script:SubToken + '":"real-sub"},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText((Join-Path $Sub 'ObfuscationDictionary_good.json'), $Dict)
        $Case = [pscustomobject]@{
            Dir = $Dir; Root = (Join-Path $Dir 'root'); Staging = (Join-Path $Dir 'staging')
            Staged = (Join-Path $Dir 'staging/ResourcesReport_good.zip'); Marker = (Join-Path $Dir 'staging/.reveal-staging.json')
            Victim = (Join-Path $Dir 'victim.txt'); Bundle = (Join-Path $Dir 'bundle.zip')
        }
        $First = Invoke-Reveal -Case $Case -Bundle (Join-Path $Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        [System.IO.File]::WriteAllText($Case.Victim, 'not a Reveal file')
        return $Case
    }

    function Invoke-Reveal
    {
        param($Case, [string]$Bundle, [string[]]$Extra = @())
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $Case.Root -StagingDirectory $Case.Staging -OutputZip $Bundle -FolderTimeoutMinutes 5 @Extra 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($Console -join "`n") }
    }

    # Add one output record to the mark, with every SHA-256 set to $Hash.
    function Add-MarkerRecord
    {
        param($Case, [string]$Key, [string]$Hash)
        $Mark = Get-Content -LiteralPath $Case.Marker -Raw | ConvertFrom-Json -AsHashtable
        $Mark['Outputs'][$Key] = [ordered]@{
            Sha256 = $Hash; SourceFolder = 'good'; SourceName = 'ResourcesReport_good.zip'; SourceSha256 = $Hash
            DictionaryName = 'ObfuscationDictionary_good.json'; DictionarySha256 = $Hash
        }
        [System.IO.File]::WriteAllText($Case.Marker, ($Mark | ConvertTo-Json -Depth 5))
    }

    # Resume with -RemoveStaging and check that the mark was refused and that
    # nothing was deleted or written.
    function Test-Refused
    {
        param($Case, [string]$Protected)
        $MarkBefore = (Get-FileHash -LiteralPath $Case.Marker).Hash
        $StagedBefore = (Get-FileHash -LiteralPath $Case.Staged).Hash
        $Run = Invoke-Reveal -Case $Case -Bundle $Case.Bundle -Extra @('-Resume', '-RemoveStaging')
        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match 'has a record of a finished output that Reveal did not write'
        Test-Path -LiteralPath $Protected -PathType Leaf | Should -BeTrue -Because $Run.Text
        Test-Path -LiteralPath $Case.Victim -PathType Leaf | Should -BeTrue -Because $Run.Text
        (Get-FileHash -LiteralPath $Case.Staged).Hash | Should -Be $StagedBefore
        (Get-FileHash -LiteralPath $Case.Marker).Hash | Should -Be $MarkBefore
        Test-Path -LiteralPath $Case.Bundle | Should -BeFalse
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 -Resume with a mark whose output records Reveal did not write' {
    It 'refuses a record named ../victim.txt and keeps the file outside staging' {
        $Case = New-StagedCase -Name 'parent'
        Add-MarkerRecord -Case $Case -Key '../victim.txt' -Hash (Get-FileHash -LiteralPath $Case.Victim -Algorithm SHA256).Hash
        Test-Refused -Case $Case -Protected $Case.Victim
    }

    It 'refuses a record named by an absolute path' {
        $Case = New-StagedCase -Name 'absolute'
        Add-MarkerRecord -Case $Case -Key $Case.Victim -Hash (Get-FileHash -LiteralPath $Case.Victim -Algorithm SHA256).Hash
        Test-Refused -Case $Case -Protected $Case.Victim
    }

    It 'refuses a record whose name has a folder part' {
        $Case = New-StagedCase -Name 'separator'
        $Nested = Join-Path $Case.Staging 'sub/victim.txt'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $Nested -Parent) -Force
        [System.IO.File]::WriteAllText($Nested, 'not a Reveal file')
        Add-MarkerRecord -Case $Case -Key 'sub/victim.txt' -Hash (Get-FileHash -LiteralPath $Nested -Algorithm SHA256).Hash
        Test-Refused -Case $Case -Protected $Nested
    }

    It 'refuses a record whose SHA-256 is not 64 hex characters' {
        $Case = New-StagedCase -Name 'badhash'
        Add-MarkerRecord -Case $Case -Key 'ResourcesReport_good.zip' -Hash 'abc'
        Test-Refused -Case $Case -Protected $Case.Staged
    }

    It 'still resumes from a mark whose records Reveal wrote' {
        $Case = New-StagedCase -Name 'clean'
        $Run = Invoke-Reveal -Case $Case -Bundle $Case.Bundle -Extra @('-Resume', '-RemoveStaging')
        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Skipped \(already revealed-resume\): 1'
        Test-Path -LiteralPath $Case.Bundle | Should -BeTrue
        Test-Path -LiteralPath $Case.Victim | Should -BeTrue
    }
}
