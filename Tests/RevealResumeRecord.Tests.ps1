# Reveal -Resume: take a staged zip only when the record says it is finished
# Run with: Invoke-Pester ./Tests/RevealResumeRecord.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Reveal -Resume skipped a report whenever a zip with the report's name sat in
# staging, without opening or checking it, and put that zip in the bundle. A
# stale, corrupt or replaced zip with the right name went into the upload, and
# a run resumed with other -Fields (or without -All) shipped one bundle whose
# reports were revealed for different fields.
# The staging mark now records the fields, and for each finished output its
# file name and SHA-256 and the report and dictionary (name and SHA-256) it
# came from, written again after each output. -Resume refuses a mark with
# other fields, or one with no fields recorded, and reveals again an output
# whose zip is missing, does not match the record, or whose report changed.
#
# The zips and dictionaries are built here with placeholder values; no live
# Azure and no inventory run.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Reveal = Join-Path $script:RepoRoot 'Reveal.ps1'
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealResumeRecord_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force
    $script:Token = 'prod_11111111-2222-3333-4444-555555555555'
    $script:SubToken = 'prod_22222222-3333-4444-5555-666666666666'

    function Write-TestZip
    {
        param([string]$Path, [string]$Text)
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        $Archive = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
        try
        {
            $Writer = [System.IO.StreamWriter]::new($Archive.CreateEntry('Inventory_r.json').Open())
            try { $Writer.Write($Text) } finally { $Writer.Dispose() }
        }
        finally { $Archive.Dispose() }
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

    function Get-BundleInnerText
    {
        param([string]$Bundle)
        $Out = Join-Path $script:WorkDir ('inner_' + [guid]::NewGuid().ToString('N') + '.zip')
        $Archive = [System.IO.Compression.ZipFile]::OpenRead($Bundle)
        try { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Archive.Entries[0], $Out) } finally { $Archive.Dispose() }
        return Get-InnerText $Out
    }

    # One subscription folder; the report's resource group is $script:Token.
    function New-Case
    {
        param([string]$Name)
        $Dir = Join-Path $script:WorkDir $Name
        $Sub = Join-Path $Dir 'root/good'
        $null = New-Item -ItemType Directory -Path $Sub -Force
        Write-TestZip -Path (Join-Path $Sub 'ResourcesReport_good.zip') -Text ('{"VirtualMachines":[{"ResourceGroup":"' + $script:Token + '","Subscription":"' + $script:SubToken + '"}]}')
        $Dict = '{"ResourceGroupMap":{"' + $script:Token + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg"},"SubscriptionMap":{"' + $script:SubToken + '":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/real-rg/providers/Microsoft.Compute/virtualMachines/vm1"},"SubscriptionNameMap":{"' + $script:SubToken + '":"real-sub"},"TagMap":{},"ResourceIdMap":{},"ResourceNameMap":{},"FreeTextMap":{}}'
        [System.IO.File]::WriteAllText((Join-Path $Sub 'ObfuscationDictionary_good.json'), $Dict)
        return [pscustomobject]@{
            Root = (Join-Path $Dir 'root'); Source = (Join-Path $Sub 'ResourcesReport_good.zip'); Staging = (Join-Path $Dir 'staging'); Dir = $Dir
            Staged = (Join-Path $Dir 'staging/ResourcesReport_good.zip'); Marker = (Join-Path $Dir 'staging/.reveal-staging.json')
        }
    }

    function Invoke-Reveal
    {
        param([string]$Root, [string]$Staging, [string]$Bundle, [string[]]$Extra = @())
        $Console = @(& pwsh -NoProfile -NonInteractive -File $script:Reveal -InventoryRoot $Root -StagingDirectory $Staging -OutputZip $Bundle -FolderTimeoutMinutes 5 @Extra 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($Console -join "`n") }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Reveal.ps1 staging mark records' {
    It 'records the fields and each finished output with its source' {
        $Case = New-Case -Name 'record'
        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip')
        $Run.Exit | Should -Be 0 -Because $Run.Text

        $Mark = Get-Content -LiteralPath $Case.Marker -Raw | ConvertFrom-Json -AsHashtable
        @($Mark['Fields']) | Should -Be @('ResourceGroup', 'Subscription')
        $Mark['All'] | Should -BeFalse
        $Out = $Mark['Outputs']['ResourcesReport_good.zip']
        $Out['Sha256'] | Should -Be (Get-FileHash -LiteralPath $Case.Staged -Algorithm SHA256).Hash
        $Out['SourceName'] | Should -Be 'ResourcesReport_good.zip'
        $Out['SourceSha256'] | Should -Be (Get-FileHash -LiteralPath $Case.Source -Algorithm SHA256).Hash
        Test-Path -LiteralPath ($Case.Marker + '.tmp') | Should -BeFalse
    }
}

Describe 'Reveal.ps1 -Resume checks the record' {
    It 'refuses to resume with other fields, and changes nothing' {
        $Case = New-Case -Name 'fields'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        $Before = (Get-FileHash -LiteralPath $Case.Staged).Hash
        $Bundle = Join-Path $Case.Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle -Extra @('-Resume', '-All')

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match 'used the fields \[ResourceGroup, Subscription\], but this run asks for \['
        Test-Path -LiteralPath $Bundle | Should -BeFalse
        (Get-FileHash -LiteralPath $Case.Staged).Hash | Should -Be $Before
    }

    It 'refuses to resume from a mark that records no fields' {
        $Case = New-Case -Name 'nofields'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        $Root = (Get-Content -LiteralPath $Case.Marker -Raw | ConvertFrom-Json).InventoryRoot
        [System.IO.File]::WriteAllText($Case.Marker, (@{ Purpose = 'Reveal staging folder'; InventoryRoot = $Root } | ConvertTo-Json -Compress))
        $Bundle = Join-Path $Case.Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle -Extra @('-Resume')

        $Run.Exit | Should -Not -Be 0 -Because $Run.Text
        ($Run.Text -replace '\s+', ' ') | Should -Match 'is not one Reveal wrote \(its Fields is not a list of field names\)'
        ($Run.Text -replace '\s+', ' ') | Should -Not -Match 'older Reveal'
        Test-Path -LiteralPath $Bundle | Should -BeFalse
    }

    It 'reveals again a staged zip that was replaced with other bytes' {
        $Case = New-Case -Name 'replaced'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        Write-TestZip -Path $Case.Staged -Text '{"VirtualMachines":[{"ResourceGroup":"stale"}]}'
        $Bundle = Join-Path $Case.Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle -Extra @('-Resume')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Skipped \(already revealed-resume\): 0'
        $Run.Text | Should -Match 'Revealed successfully\s+: 1'
        Get-BundleInnerText $Bundle | Should -Match 'real-rg'
        Get-BundleInnerText $Bundle | Should -Not -Match 'stale'
    }

    It 'reveals again a staged zip that is missing' {
        $Case = New-Case -Name 'missing'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        Remove-Item -LiteralPath $Case.Staged -Force
        $Bundle = Join-Path $Case.Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle -Extra @('-Resume')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Revealed successfully\s+: 1'
        Get-BundleInnerText $Bundle | Should -Match 'real-rg'
    }

    It 'reveals again when the source report changed' {
        $Case = New-Case -Name 'source'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text
        Write-TestZip -Path $Case.Source -Text ('{"VirtualMachines":[{"ResourceGroup":"' + $script:Token + '","Subscription":"' + $script:SubToken + '","Name":"changed"}]}')
        $Bundle = Join-Path $Case.Dir 'bundle.zip'

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle $Bundle -Extra @('-Resume')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Revealed successfully\s+: 1'
        Get-BundleInnerText $Bundle | Should -Match '"Name":"changed"'
    }

    It 'still skips a staged zip that matches its record' {
        $Case = New-Case -Name 'match'
        $First = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'first.zip')
        $First.Exit | Should -Be 0 -Because $First.Text

        $Run = Invoke-Reveal -Root $Case.Root -Staging $Case.Staging -Bundle (Join-Path $Case.Dir 'bundle.zip') -Extra @('-Resume')

        $Run.Exit | Should -Be 0 -Because $Run.Text
        $Run.Text | Should -Match 'Skipped \(already revealed-resume\): 1'
        $Run.Text | Should -Match 'Revealed successfully\s+: 0'
    }
}
