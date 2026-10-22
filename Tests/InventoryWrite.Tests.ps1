# Inventory JSON write tests
# =============================================================================
# Offline tests for how ResourceInventory.ps1 writes Inventory_*.json.
#
# WHY THIS TEST EXISTS
# --------------------
# Serialising the whole inventory as one ConvertTo-Json string can run out of
# memory on a large estate. The inventory is now written one collector at a
# time (Write-InventoryJson), and the file is byte-for-byte what the previous
# ConvertTo-Json | Out-File pipeline wrote.
#
# HOW
# ---
# Write-InventoryJson is dot-sourced from Functions/ResourceInventory.Functions.ps1
# and tested directly. ProcessResourceResult is nested in ResourceInventory.ps1,
# which runs login and collection when invoked, so it is lifted out with the
# PowerShell parser. No live Azure, no output zip.
#
# Run with: Invoke-Pester ./Tests/InventoryWrite.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:InventoryScript = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    $script:CommonFunctions = Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1'
    $script:InventoryFunctions = Join-Path $script:RepoRoot 'Functions/ResourceInventory.Functions.ps1'
    foreach ($Required in @($script:InventoryScript, $script:CommonFunctions, $script:InventoryFunctions))
    {
        if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Required file not found: $Required" }
    }

    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InventoryScript, [ref]$Tokens, [ref]$ParseErrors)
    if (@($ParseErrors).Count -gt 0) { throw ("ResourceInventory.ps1 does not parse: {0}" -f $ParseErrors[0].Message) }

    function Get-FunctionText([string]$Name)
    {
        $Fn = $Ast.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name
            }, $true) | Select-Object -First 1
        if ($null -eq $Fn) { throw "$Name was not found in ResourceInventory.ps1. Has it been renamed or removed?" }
        return $Fn.Extent.Text
    }
    $script:ProcessResourceResultText = Get-FunctionText 'ProcessResourceResult'

    $script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('InventoryWriteTest_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null

    $script:DocsGuid = '12345678-1234-1234-1234-123456789012'

    # Inventory shaped the way CreateResourceJobs and ProcessResourceResult build
    # it: a PSObject with one NoteProperty per collector, each value an array
    # (@($Result)), and Version added last unless -WithoutVersion.
    function New-InventoryFixture
    {
        param([switch]$WithoutVersion)

        $Inv = New-Object PSObject
        $Vms = @(
            [ordered]@{
                ID            = ('/subscriptions/{0}/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm-01' -f $script:DocsGuid)
                Name          = 'vm-01'
                Location      = 'westeurope'
                Size          = 'Standard_D2s_v5'
                Zones         = @('1')
                Tags          = @([pscustomobject]@{ Name = 'owner'; Value = 'Zürich team' }, [pscustomobject]@{ Name = 'cost'; Value = '東京-42' })
                Disks         = @([ordered]@{ Lun = 0; SizeGB = 128; Caching = 'ReadOnly' }, [ordered]@{ Lun = 1; SizeGB = 1024; Caching = $null })
                Running       = $true
                Score         = 0.75
                Notes         = "line1`nline2`ttab ""quoted"" back\slash <tag> & ünïcödé ✓"
            },
            [pscustomobject]@{
                ID       = ('/subscriptions/{0}/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm-02' -f $script:DocsGuid)
                Name     = 'vm-02'
                Location = 'eastus'
                Size     = $null
                Zones    = @()
                Tags     = @()
                Running  = $false
                Created  = [datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc)
            }
        )
        $Inv | Add-Member -MemberType NoteProperty -Name 'VirtualMachines' -Value NotSet
        $Inv.VirtualMachines = @($Vms)
        $Inv | Add-Member -MemberType NoteProperty -Name 'Disks' -Value NotSet
        $Inv.Disks = @()
        $Inv | Add-Member -MemberType NoteProperty -Name 'StorageAccounts' -Value NotSet
        $Inv.StorageAccounts = @([ordered]@{ Name = 'stäccount01'; Kind = 'StorageV2'; Network = [ordered]@{ DefaultAction = 'Deny'; Rules = @([ordered]@{ Ip = '203.0.113.0/24' }) } })
        $Inv | Add-Member -MemberType NoteProperty -Name 'KeyVaults' -Value NotSet
        $Inv.KeyVaults = @(1..3 | ForEach-Object { [ordered]@{ Name = ('kv-{0:d2}' -f $_); SoftDelete = ($_ % 2 -eq 0) } })
        # Nested past the old -depth 100 limit, so the truncation point must match too.
        $Deep = 'leaf'
        for ($i = 0; $i -lt 101; $i++) { $Deep = [ordered]@{ Level = $Deep } }
        $Inv | Add-Member -MemberType NoteProperty -Name 'Deep' -Value NotSet
        $Inv.Deep = @(, $Deep)
        if (-not $WithoutVersion)
        {
            $Inv | Add-Member -MemberType NoteProperty -Name 'Version' -Value NotSet
            $Inv.Version = '1.2.3'
        }
        return $Inv
    }

    # The real cmdlet, for pass-through mocks and for building reference output while a
    # mock is active. Pester also mocks the module-qualified name, so it is called through
    # its CmdletInfo.
    $script:RealConvertToJson = Get-Command -Name 'ConvertTo-Json' -CommandType Cmdlet
    # Body for a pass-through mock. $PSBoundParameters is empty inside a Pester mock body,
    # so the parameters the product code uses are passed on by name.
    $script:PassThroughConvertToJson = {
        & $script:RealConvertToJson -InputObject $InputObject -Depth $Depth -Compress:$Compress
    }

    $script:SavedGlobals = @{}
    foreach ($Name in 'SmaResources', 'JsonFile', 'Version', 'ErrorLogFile')
    {
        $script:SavedGlobals[$Name] = Get-Variable -Scope Global -Name $Name -ValueOnly -ErrorAction SilentlyContinue
    }
}

AfterAll {
    foreach ($Name in $script:SavedGlobals.Keys)
    {
        Set-Variable -Scope Global -Name $Name -Value $script:SavedGlobals[$Name]
    }
    if ($script:TmpRoot -and (Test-Path -LiteralPath $script:TmpRoot))
    {
        Get-ChildItem -LiteralPath $script:TmpRoot -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:TmpRoot -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Write-InventoryJson' {

    BeforeAll {
        . $script:InventoryFunctions
        if (-not (Get-Command -Name 'Write-InventoryJson' -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Expected function 'Write-InventoryJson' to be defined by $script:InventoryFunctions, but it was not."
        }

        # An empty folder of its own, so a test can check every file the writer left behind.
        function New-WriterCaseDir
        {
            $Dir = Join-Path $script:TmpRoot ('writer_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            return $Dir
        }
        function Get-WriterCaseFiles([string]$Dir)
        {
            return @(Get-ChildItem -LiteralPath $Dir -Force | ForEach-Object { $_.Name } | Sort-Object)
        }
        # The bytes the previous ProcessResourceResult pipeline wrote for $Inventory.
        function Get-ReferenceBytes($Inventory)
        {
            $ReferenceFile = Join-Path $script:TmpRoot ('reference_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
            $Inventory | ConvertTo-Json -depth 100 -compress 3>$null | Out-File $ReferenceFile
            return [System.IO.File]::ReadAllBytes($ReferenceFile)
        }
        # Same as the fixture, with a collector after the first one whose value ConvertTo-Json
        # rejects (a dictionary key that is not a string), so the write fails part-way.
        function New-FailingInventoryFixture
        {
            $Inv = New-Object PSObject
            $Inv | Add-Member -MemberType NoteProperty -Name 'Disks' -Value @([ordered]@{ Name = 'disk-01'; SizeGB = 64 })
            $Inv | Add-Member -MemberType NoteProperty -Name 'Broken' -Value @(@{ 1 = 'not a string key' })
            $Inv | Add-Member -MemberType NoteProperty -Name 'Version' -Value '1.2.3'
            return $Inv
        }
    }

    It 'writes bytes identical to the whole-document ConvertTo-Json | Out-File output and leaves only that file' {
        $Inventory = New-InventoryFixture
        $Dir = New-WriterCaseDir
        $Path = Join-Path $Dir 'writer-new.json'
        Write-InventoryJson -InputObject $Inventory -Path $Path 3>$null

        $New = [System.IO.File]::ReadAllBytes($Path)
        $Reference = Get-ReferenceBytes $Inventory
        $New.Length | Should -BeGreaterThan 0
        [Convert]::ToBase64String($New) | Should -BeExactly ([Convert]::ToBase64String($Reference))
        Get-WriterCaseFiles $Dir | Should -Be @('writer-new.json') -Because 'no temporary file is left behind'

        $Parsed = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
        @($Parsed.PSObject.Properties.Name) | Should -Be @('VirtualMachines', 'Disks', 'StorageAccounts', 'KeyVaults', 'Deep', 'Version')
        $Parsed.Version | Should -Be '1.2.3'
    }

    It 'keeps a one-element collector as a JSON array and writes no BOM' {
        $Path = Join-Path $script:TmpRoot 'writer-shape.json'
        Write-InventoryJson -InputObject (New-InventoryFixture) -Path $Path 3>$null

        $Bytes = [System.IO.File]::ReadAllBytes($Path)
        $Bytes[0] | Should -Be ([byte][char]'{')
        $Text = [System.Text.Encoding]::UTF8.GetString($Bytes)
        $Text | Should -Match '"StorageAccounts":\[\{'
        $Text | Should -Match '"Disks":\[\],'
        $Text | Should -Match 'Zürich team'
        $Text.EndsWith('}' + [Environment]::NewLine) | Should -BeTrue
    }

    It 'never serialises the whole inventory in a single ConvertTo-Json call' {
        $script:MockInventory = New-InventoryFixture
        $Path = Join-Path $script:TmpRoot 'writer-percollector.json'

        # Pass-through mock, so calls can be inspected and the file is still written.
        Mock -CommandName ConvertTo-Json -MockWith $script:PassThroughConvertToJson

        Write-InventoryJson -InputObject $script:MockInventory -Path $Path 3>$null

        Should -Invoke -CommandName ConvertTo-Json -Times 1
        Should -Invoke -CommandName ConvertTo-Json -Times 0 -Exactly -ParameterFilter { [object]::ReferenceEquals($InputObject, $script:MockInventory) } -Because 'each collector is serialised separately so the whole document is never one in-memory string'
        (Get-Item -LiteralPath $Path).Length | Should -BeGreaterThan 0
    }

    It 'resolves a relative path against the PowerShell location, as Out-File does' {
        $LocationDir = Join-Path $script:TmpRoot 'location'
        New-Item -ItemType Directory -Path $LocationDir -Force | Out-Null
        $SavedProcessDir = [Environment]::CurrentDirectory
        try
        {
            [Environment]::CurrentDirectory = $script:TmpRoot
            Push-Location -LiteralPath $LocationDir
            Write-InventoryJson -InputObject (New-InventoryFixture) -Path 'relative.json' 3>$null
        }
        finally
        {
            Pop-Location
            [Environment]::CurrentDirectory = $SavedProcessDir
        }

        Test-Path -LiteralPath (Join-Path $LocationDir 'relative.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:TmpRoot 'relative.json') | Should -BeFalse
    }

    It 'throws when the file cannot be created' {
        $Path = Join-Path $script:TmpRoot 'no-such-dir/inventory.json'
        { Write-InventoryJson -InputObject (New-InventoryFixture) -Path $Path 3>$null } | Should -Throw
        Test-Path -LiteralPath $Path | Should -BeFalse
    }

    It 'leaves no inventory file and no temporary file when a collector fails to serialise (ErrorActionPreference <Preference>)' -ForEach @(
        @{ Preference = 'Continue' }
        @{ Preference = 'SilentlyContinue' }
    ) {
        # SilentlyContinue is what ResourceInventory.ps1 runs with outside -Debug.
        $Dir = New-WriterCaseDir
        $Path = Join-Path $Dir 'Inventory_test.json'
        $ErrorActionPreference = $Preference

        { Write-InventoryJson -InputObject (New-FailingInventoryFixture) -Path $Path 3>$null } | Should -Throw '*Keys must be strings*'

        $ErrorActionPreference = 'Continue'
        Get-WriterCaseFiles $Dir | Should -BeNullOrEmpty -Because 'a failed write must not leave a cut-off inventory or its temporary file'
        if (Test-Path -LiteralPath "/proc/$PID/fd")
        {
            @(Get-ChildItem -LiteralPath "/proc/$PID/fd" -ErrorAction SilentlyContinue | Where-Object { [string]$_.LinkTarget -like "$Dir*" }).Count | Should -Be 0 -Because 'the file is closed before it is removed'
        }
    }

    It 'leaves no temporary file when the finished file cannot be moved into place' {
        $Dir = New-WriterCaseDir
        $Path = Join-Path $Dir 'Inventory_test.json'
        New-Item -ItemType Directory -Path $Path | Out-Null

        { Write-InventoryJson -InputObject (New-InventoryFixture) -Path $Path 3>$null } | Should -Throw

        Get-WriterCaseFiles $Dir | Should -Be @('Inventory_test.json')
        Test-Path -LiteralPath $Path -PathType Container | Should -BeTrue -Because 'what was at the path is left as it was'
    }

    It 'replaces an existing file at the path' {
        $Inventory = New-InventoryFixture
        $Dir = New-WriterCaseDir
        $Path = Join-Path $Dir 'Inventory_test.json'
        # Longer than the new content, so a leftover tail would show.
        [System.IO.File]::WriteAllText($Path, ('old content ' * 1000))

        Write-InventoryJson -InputObject $Inventory -Path $Path 3>$null

        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) | Should -BeExactly ([Convert]::ToBase64String((Get-ReferenceBytes $Inventory)))
        Get-WriterCaseFiles $Dir | Should -Be @('Inventory_test.json')
    }
}

Describe 'ProcessResourceResult' {

    BeforeAll {
        . $script:CommonFunctions
        . $script:InventoryFunctions
        . ([scriptblock]::Create($script:ProcessResourceResultText))
        $Global:ErrorLogFile = $null
        $Global:Version = '1.2.3'
    }

    It 'writes the same bytes as before without serialising the whole inventory in one call' {
        $Global:SmaResources = New-InventoryFixture -WithoutVersion
        $Global:JsonFile = Join-Path $script:TmpRoot 'process-new.json'

        Mock -CommandName ConvertTo-Json -MockWith $script:PassThroughConvertToJson

        ProcessResourceResult 6>$null 3>$null

        Should -Invoke -CommandName ConvertTo-Json -Times 1
        Should -Invoke -CommandName ConvertTo-Json -Times 0 -Exactly -ParameterFilter { [object]::ReferenceEquals($InputObject, $Global:SmaResources) } -Because 'the inventory is written one collector at a time'

        # The previous pipeline on the same object, which ProcessResourceResult has given its Version.
        $ReferenceFile = Join-Path $script:TmpRoot 'process-reference.json'
        $Global:SmaResources | & $script:RealConvertToJson -Depth 100 -Compress 3>$null | Out-File $ReferenceFile
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Global:JsonFile)) | Should -BeExactly ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ReferenceFile)))
        $Global:SmaResources.Version | Should -Be '1.2.3'
    }
}
