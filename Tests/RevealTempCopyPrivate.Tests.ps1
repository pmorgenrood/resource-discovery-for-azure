# Reveal's expanded copy of a report: owner-only, and removed after a timeout
# Run with: Invoke-Pester ./Tests/RevealTempCopyPrivate.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Each reveal expands the report into <system temp>/Reveal_<guid> and writes
# the real values there. The folder had the default permissions, so on Linux,
# where /tmp is shared, other users could read it while the reveal ran. When
# a folder of an all-subscriptions run timed out, its job was killed before it
# could remove that copy, so a full revealed copy stayed in /tmp.
# The folder is now made owner-only before anything is written into it, and
# in all-subscriptions mode it is made inside the owner-only staging folder,
# in a folder the parent removes when the job ends or is stopped.
# These checks are for Unix; the Windows code is not run here.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    . (Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealTempCopy_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force
    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'

    # A report whose Consumption member has $Rows rows that each hold the
    # masked resource group, and the dictionary for it.
    function New-Report
    {
        param([string]$Folder, [int]$Rows)
        $null = New-Item -ItemType Directory -Path $Folder -Force
        $Archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Folder 'ResourcesReport_20260101000000000aaaa.zip'), 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_r.json').Open())
            try { $Writer.Write('{"VirtualMachines":[{"ResourceGroup":"' + $script:Token + '"}]}') } finally { $Writer.Dispose() }
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Consumption_r.csv').Open())
            try
            {
                $Writer.Write("ResourceGroup,Cost`n")
                $Line = $script:Token + ",1.5`n"
                for ($i = 0; $i -lt $Rows; $i++) { $Writer.Write($Line) }
            }
            finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
        $Dict = '{"ResourceGroupMap":{"' + $script:Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg"},"SubscriptionMap":{},"SubscriptionNameMap":{},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText((Join-Path $Folder 'ObfuscationDictionary_ResourcesReport_20260101000000000aaaa.json'), $Dict)
        return (Join-Path $Folder 'ResourcesReport_20260101000000000aaaa.zip')
    }

    function Get-Mode
    {
        param([string]$Path)
        return [Convert]::ToString(([int][System.IO.File]::GetUnixFileMode($Path)) -band 0x1FF, 8)
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-RdaReveal expanded copy' -Skip:$IsWindows {
    BeforeAll {
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        # The engine lists the files of its expanded copy once; note the
        # folder and its mode at that moment, then list as usual.
        Mock Get-ChildItem -ParameterFilter { $LiteralPath -and ([System.IO.Path]::GetFileName([string]$LiteralPath[0])) -like 'Reveal_*' } -MockWith {
            $Dir = [string]$LiteralPath[0]
            $script:Seen.Add([pscustomobject]@{ Dir = $Dir; Parent = [System.IO.Path]::GetDirectoryName($Dir); Mode = (Get-Mode $Dir) })
            [System.IO.DirectoryInfo]::new($Dir).GetFiles('*', [System.IO.SearchOption]::AllDirectories)
        }
    }

    It 'is owner-only while the reveal writes into it' {
        # Under the usual 022 umask a new folder is not owner-only.
        $Probe = Join-Path $script:WorkDir 'probe'
        $null = New-Item -ItemType Directory -Path $Probe -Force
        Get-Mode $Probe | Should -Not -Be '700' -Because 'this check needs a umask that leaves new folders open to others'

        $script:Seen.Clear()
        $Zip = New-Report -Folder (Join-Path $script:WorkDir 'single') -Rows 1
        Invoke-RdaReveal -InputZip $Zip -DictionaryPath (Join-Path $script:WorkDir 'single/ObfuscationDictionary_ResourcesReport_20260101000000000aaaa.json') -OutputZip (Join-Path $script:WorkDir 'single-out.zip') 6>$null

        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Mode | Should -Be '700'
        Test-Path -LiteralPath $script:Seen[0].Dir | Should -BeFalse -Because 'the copy is removed when the reveal ends'
    }

    It 'is made inside -TempDirectory when one is given' {
        $script:Seen.Clear()
        $Temp = Join-Path $script:WorkDir 'given-temp'
        $null = New-Item -ItemType Directory -Path $Temp -Force
        $Zip = New-Report -Folder (Join-Path $script:WorkDir 'given') -Rows 1
        Invoke-RdaReveal -InputZip $Zip -DictionaryPath (Join-Path $script:WorkDir 'given/ObfuscationDictionary_ResourcesReport_20260101000000000aaaa.json') -OutputZip (Join-Path $script:WorkDir 'given-out.zip') -TempDirectory $Temp 6>$null

        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Parent | Should -Be $Temp
        $script:Seen[0].Mode | Should -Be '700'
    }
}

Describe 'Reveal.ps1 over every folder, one folder that times out' -Skip:$IsWindows {
    BeforeAll {
        $script:Root = Join-Path $script:WorkDir 'root'
        # Enough consumption rows that the reveal is still running when its
        # 6-second limit is reached.
        $null = New-Report -Folder (Join-Path $script:Root 'slow') -Rows 1500000
        $script:Staging = Join-Path $script:WorkDir 'staging'
        # A private system temp folder for the run, so a copy left there can
        # be seen.
        $script:SystemTemp = Join-Path $script:WorkDir 'systemtemp'
        $null = New-Item -ItemType Directory -Path $script:SystemTemp -Force
        $Saved = $env:TMPDIR
        try
        {
            $env:TMPDIR = $script:SystemTemp
            $Console = @(& sh -c 'umask 022; exec "$@"' sh pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $script:Root -StagingDirectory $script:Staging -OutputZip (Join-Path $script:WorkDir 'bundle.zip') -FolderTimeoutMinutes 0.1 2>&1 | ForEach-Object { [string]$_ })
            $script:Exit = $LASTEXITCODE
        }
        finally { $env:TMPDIR = $Saved }
        $script:Text = $Console -join "`n"
    }

    It 'times the folder out' {
        $script:Text | Should -Match 'FAIL: slow - timed out'
        $script:Exit | Should -Not -Be 0 -Because $script:Text
    }

    It 'leaves no expanded copy in the system temp folder' {
        @(Get-ChildItem -LiteralPath $script:SystemTemp -Filter 'Reveal_*' -Force | ForEach-Object Name) | Should -BeNullOrEmpty
    }

    It 'leaves no expanded copy in staging either' {
        @(Get-ChildItem -LiteralPath $script:Staging -Recurse -Force | Where-Object { $_.Name -like 'Reveal_*' -or $_.Name -eq '.reveal-tmp' } | ForEach-Object FullName) | Should -BeNullOrEmpty
    }
}

# Stop-Job waits for the job's own cleanup, so a timed-out job removes its copy
# itself. A run that is killed (the parent and its jobs, for example when the
# session ends) gets no cleanup at all; its copy must then be in the private
# staging folder, and the next run of that folder removes it.
Describe 'Reveal.ps1 over every folder, killed while a reveal runs' -Skip:(-not $IsLinux) {
    BeforeAll {
        $script:KRoot = Join-Path $script:WorkDir 'killroot'
        $null = New-Report -Folder (Join-Path $script:KRoot 'slow') -Rows 1500000
        $script:KStaging = Join-Path $script:WorkDir 'killstaging'
        $script:KSystemTemp = Join-Path $script:WorkDir 'killsystemtemp'
        $null = New-Item -ItemType Directory -Path $script:KSystemTemp -Force
        $Pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        # Start the run in its own process group, wait until an expanded copy
        # exists anywhere under the work folder, then kill the whole group.
        $Script = @'
setsid sh -c 'umask 022; exec "$@"' sh "$PWSH" -NoProfile -NonInteractive -File "$REVEAL" -InventoryRoot "$ROOT" -StagingDirectory "$STAGING" -OutputZip "$WORK/killbundle.zip" -FolderTimeoutMinutes 30 >/dev/null 2>&1 &
pid=$!
for i in $(seq 1 600); do
  if [ -n "$(find "$WORK" -name 'Reveal_*' -print -quit 2>/dev/null)" ]; then break; fi
  sleep 0.1
done
sleep 1
kill -9 -- -$pid 2>/dev/null
wait $pid 2>/dev/null
exit 0
'@
        $Env = @{ PWSH = $Pwsh; REVEAL = $script:Reveal; ROOT = $script:KRoot; STAGING = $script:KStaging; WORK = $script:WorkDir; TMPDIR = $script:KSystemTemp }
        $Saved = @{}
        foreach ($Name in $Env.Keys) { $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name); [Environment]::SetEnvironmentVariable($Name, $Env[$Name]) }
        try { & bash -c $Script }
        finally { foreach ($Name in $Saved.Keys) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name]) } }
        $script:CopiesAfterKill = @(Get-ChildItem -LiteralPath $script:WorkDir -Recurse -Directory -Force -Filter 'Reveal_*' -ErrorAction SilentlyContinue | ForEach-Object FullName)
    }

    It 'leaves the killed copy only inside the owner-only staging folder' {
        $script:CopiesAfterKill.Count | Should -BeGreaterThan 0 -Because 'the run is killed while a reveal has its expanded copy'
        @(Get-ChildItem -LiteralPath $script:KSystemTemp -Filter 'Reveal_*' -Force | ForEach-Object Name) | Should -BeNullOrEmpty
        foreach ($Copy in $script:CopiesAfterKill) { $Copy | Should -BeLike ((Join-Path $script:KStaging '.reveal-tmp') + '/*') }
        Get-Mode $script:KStaging | Should -Be '700'
    }

    It 'has the next run of that staging folder remove the copy' {
        # The slow report is moved away; -Resume continues with a small one.
        Move-Item -LiteralPath (Join-Path $script:KRoot 'slow') -Destination (Join-Path $script:WorkDir 'slow-moved')
        $null = New-Report -Folder (Join-Path $script:KRoot 'small') -Rows 1
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $script:KRoot -StagingDirectory $script:KStaging -OutputZip (Join-Path $script:WorkDir 'killbundle2.zip') -FolderTimeoutMinutes 5 -Resume 2>&1 | ForEach-Object { [string]$_ })
        $LASTEXITCODE | Should -Be 0 -Because ($Console -join "`n")
        @(Get-ChildItem -LiteralPath $script:KStaging -Recurse -Force | Where-Object { $_.Name -like 'Reveal_*' -or $_.Name -eq '.reveal-tmp' } | ForEach-Object FullName) | Should -BeNullOrEmpty
    }
}
