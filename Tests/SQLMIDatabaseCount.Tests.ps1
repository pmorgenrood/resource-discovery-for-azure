# SQL managed instance database count tests
# Run with: Invoke-Pester ./Tests/SQLMIDatabaseCount.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The SQLMI collector counts each managed instance's databases. It used to scan
# every database row for every instance with
#     $_.Id -like "<instance id>/databases/*"
# and now counts the databases once, by parent id, before the loop. That is a
# speed change only, so these tests run the REAL collector with synthetic rows
# and pin what it emits:
#
#   - the count is an int when the instance has databases, and the STRING '0'
#     when it has none;
#   - parent ids are matched without regard to letter case;
#   - databases of several instances can arrive in any order;
#   - odd ids give exactly what the old '-like' match gave: an id that holds
#     '/databases/' twice, a database id with nothing after '/databases/', null
#     ids, wildcard characters ([ ] * ?) in an instance id, and non-ASCII
#     letters that '-like' folds to ASCII.
#
# No live Azure. All GUIDs are the Azure documentation placeholder.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Services', 'Data', 'SQLMI.ps1' | Resolve-Path | Select-Object -ExpandProperty Path

    $script:DocGuid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:DocGuid; Name = 'sub-sqlmi' })
    $script:RgPath = "/subscriptions/$($script:DocGuid)/resourceGroups/rg-sqlmi/providers"

    $script:ExpectedKeys = @(
        'ID', 'Subscription', 'ResourceGroup', 'Name', 'Location', 'SkuName', 'SkuCapacity', 'SkuTier', 'SkuFamily',
        'InstancePoolName', 'vCores', 'StorageGB', 'StorageAccountType', 'LicenseType', 'State',
        'ManagedInstanceCreateMode', 'ZoneRedundant', 'Databases'
    ) | Sort-Object

    function Invoke-TestCollector
    {
        param($Resources)
        & $script:Collector -Sub $script:Subs -Resources $Resources -Task 'Processing' -ResourceIdDictionary $null
    }

    function New-TestInstance
    {
        param([AllowNull()][string]$Id, [string]$Name = 'mi')
        [pscustomobject]@{
            TYPE           = 'microsoft.sql/managedInstances'
            id             = if ($null -eq $Id) { $null } else { $Id }
            NAME           = $Name
            RESOURCEGROUP  = 'rg-sqlmi'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
            sku            = [pscustomobject]@{ name = 'GP_Gen5'; capacity = 8; tier = 'GeneralPurpose'; family = 'Gen5' }
            PROPERTIES     = [pscustomobject]@{
                vCores = 8; storageSizeInGB = 256; storageAccountType = 'GRS'; licenseType = 'LicenseIncluded'
                state = 'Ready'; managedInstanceCreateMode = 'Default'; zoneRedundant = $false; instancePoolId = $null
            }
        }
    }

    function New-TestDatabase
    {
        param([AllowNull()][string]$Id)
        [pscustomobject]@{
            TYPE           = 'microsoft.sql/managedinstances/databases'
            id             = if ($null -eq $Id) { $null } else { $Id }
            NAME           = 'db'
            RESOURCEGROUP  = 'rg-sqlmi'
            LOCATION       = 'eastus'
            subscriptionId = $script:DocGuid
        }
    }

    function Get-MiId
    {
        param([string]$Name)
        "$($script:RgPath)/Microsoft.Sql/managedInstances/$Name"
    }

    # What the old per-instance scan gave, value and type, for the same rows.
    function Get-LikeCount
    {
        param($Resources, $Instance)
        $Dbs = $Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedinstances/databases' }
        $Match = $Dbs | Where-Object { $_.Id -like "$($Instance.Id)/databases/*" }
        if ($null -ne $Match) { $Match.Count } else { '0' }
    }

    function Assert-SameAsLike
    {
        param($Resources)
        $Instances = @($Resources | Where-Object { $_.TYPE -eq 'microsoft.sql/managedInstances' })
        $Recs = @(Invoke-TestCollector -Resources $Resources)
        $Recs.Count | Should -Be $Instances.Count
        for ($i = 0; $i -lt $Instances.Count; $i++)
        {
            $Want = Get-LikeCount -Resources $Resources -Instance $Instances[$i]
            $Recs[$i]['Databases'] | Should -Be $Want -Because "instance $i"
            $Recs[$i]['Databases'].GetType() | Should -Be $Want.GetType() -Because "instance $i keeps the value type"
        }
        $Recs
    }
}

Describe 'SQLMI database count' {

    It 'counts several databases as an int and keeps the other fields' {
        $Mi = New-TestInstance -Id (Get-MiId 'mi-a') -Name 'mi-a'
        $Rows = @($Mi) + @(1..3 | ForEach-Object { New-TestDatabase -Id "$($Mi.id)/databases/db$_" })

        $Rec = Invoke-TestCollector -Resources $Rows

        $Rec | Should -BeOfType ([hashtable])
        @($Rec.Keys | Sort-Object) | Should -Be $script:ExpectedKeys
        $Rec['Databases'] | Should -Be 3
        $Rec['Databases'] | Should -BeOfType ([int])
        $Rec['ID'] | Should -Be $Mi.id
        $Rec['Subscription'] | Should -Be 'sub-sqlmi'
        $Rec['vCores'] | Should -Be 8
    }

    It "writes the string '0' for an instance with no databases" {
        $Mi = New-TestInstance -Id (Get-MiId 'mi-empty')
        $Other = New-TestDatabase -Id "$(Get-MiId 'mi-other')/databases/db1"

        $Rec = Invoke-TestCollector -Resources @($Mi, $Other)

        $Rec['Databases'] | Should -BeOfType ([string])
        $Rec['Databases'] | Should -BeExactly '0'
    }

    It 'counts a single database as int 1' {
        $Mi = New-TestInstance -Id (Get-MiId 'mi-one')
        $Rec = Invoke-TestCollector -Resources @($Mi, (New-TestDatabase -Id "$($Mi.id)/databases/only"))
        $Rec['Databases'] | Should -Be 1
        $Rec['Databases'] | Should -BeOfType ([int])
    }

    It 'matches database ids whose parent part differs from the instance id only in letter case' {
        $Mi = New-TestInstance -Id (Get-MiId 'MI-Case')
        $Lower = New-TestDatabase -Id "/subscriptions/$($script:DocGuid)/resourcegroups/rg-sqlmi/providers/microsoft.sql/managedinstances/mi-case/databases/db1"
        $Upper = New-TestDatabase -Id ("$($Mi.id)/DATABASES/db2".ToUpperInvariant())

        $Rec = Invoke-TestCollector -Resources @($Mi, $Lower, $Upper)

        $Rec['Databases'] | Should -Be 2
    }

    It 'counts interleaved databases of two instances, and does not mix up an id that is a prefix of another' {
        $A = New-TestInstance -Id (Get-MiId 'mi1') -Name 'mi1'
        $B = New-TestInstance -Id (Get-MiId 'mi10') -Name 'mi10'
        $Rows = @(
            (New-TestDatabase -Id "$($B.id)/databases/x1"),
            $A,
            (New-TestDatabase -Id "$($A.id)/databases/y1"),
            (New-TestDatabase -Id "$($B.id)/databases/x2"),
            $B,
            (New-TestDatabase -Id "$($A.id)/databases/y2"),
            (New-TestDatabase -Id "$($B.id)/databases/x3")
        )

        $Recs = @(Invoke-TestCollector -Resources $Rows)

        $Recs.Count | Should -Be 2
        $Recs[0]['Name'] | Should -Be 'mi1'
        $Recs[0]['Databases'] | Should -Be 2
        $Recs[1]['Name'] | Should -Be 'mi10'
        $Recs[1]['Databases'] | Should -Be 3
    }

    It 'emits nothing when there are no managed instances' {
        $Result = Invoke-TestCollector -Resources @((New-TestDatabase -Id "$(Get-MiId 'gone')/databases/db1"))
        $null -eq $Result | Should -BeTrue
    }

    It "counts the right instance when its resource group is named 'databases'" {
        $Rg = "/subscriptions/$($script:DocGuid)/resourceGroups/databases/providers/Microsoft.Sql/managedInstances"
        $Mi = New-TestInstance -Id "$Rg/mi-rg"
        # This instance id ends where the database ids first hold '/databases/'.
        $Short = New-TestInstance -Id "/subscriptions/$($script:DocGuid)/resourceGroups"
        $Rows = @($Mi, $Short, (New-TestDatabase -Id "$Rg/mi-rg/databases/db1"), (New-TestDatabase -Id "$Rg/mi-rg/databases/databases"))

        $Recs = @(Assert-SameAsLike -Resources $Rows)

        $Recs[0]['Databases'] | Should -Be 2
        $Recs[1]['Databases'] | Should -Be 2 -Because "'-like' also counts them under the shorter id"
    }

    It "counts a database id with nothing after '/databases/', as '-like' does" {
        $Mi = New-TestInstance -Id (Get-MiId 'mi-tail')
        $Recs = @(Assert-SameAsLike -Resources @($Mi, (New-TestDatabase -Id "$($Mi.id)/databases/")))
        $Recs[0]['Databases'] | Should -Be 1
    }

    It 'skips database rows with no id, and gives a null-id instance what -like gives' {
        $Mi = New-TestInstance -Id (Get-MiId 'mi-null')
        $NullMi = New-TestInstance -Id $null
        $Rows = @($Mi, $NullMi, (New-TestDatabase -Id $null), (New-TestDatabase -Id "$($Mi.id)/databases/db1"), (New-TestDatabase -Id '/databases/odd'))

        $Recs = @(Assert-SameAsLike -Resources $Rows)

        $Recs[0]['Databases'] | Should -Be 1
        $Recs[1]['Databases'] | Should -Be 1 -Because "a null id makes the pattern '/databases/*'"
    }

    It 'keeps the -like result for wildcard characters in an instance id' {
        $Bracket = New-TestInstance -Id (Get-MiId 'mi[ab]')
        $Star = New-TestInstance -Id (Get-MiId 'mi*')
        $Query = New-TestInstance -Id (Get-MiId 'mi?')
        $Rows = @(
            $Bracket, $Star, $Query,
            (New-TestDatabase -Id "$(Get-MiId 'mi[ab]')/databases/db1"),
            (New-TestDatabase -Id "$(Get-MiId 'mia')/databases/db1"),
            (New-TestDatabase -Id "$(Get-MiId 'mix')/databases/db1")
        )

        $Recs = @(Assert-SameAsLike -Resources $Rows)

        $Recs[0]['Databases'] | Should -Be 1 -Because "'[ab]' is a character class, so only 'mia' matches"
        $Recs[1]['Databases'] | Should -Be 3
        $Recs[2]['Databases'] | Should -Be 2
    }

    It 'still throws, as -like does, for an instance id with an unclosed bracket' {
        $Mi = New-TestInstance -Id (Get-MiId 'mi[')
        { Invoke-TestCollector -Resources @($Mi, (New-TestDatabase -Id "$($Mi.id)/databases/db1")) } | Should -Throw -ExceptionType ([System.Management.Automation.WildcardPatternException])
    }

    It 'gives the -like result for non-ASCII letters in an id' {
        $Mi = New-TestInstance -Id (Get-MiId 'mi-k')
        # U+212A KELVIN SIGN folds to 'k' under -like but not under an ordinal compare.
        $Kelvin = New-TestDatabase -Id ("$(Get-MiId 'mi-')" + [char]0x212A + '/databases/db1')
        $KelvinMi = New-TestInstance -Id ("$(Get-MiId 'mi-')" + [char]0x212A)
        $Rows = @($Mi, $KelvinMi, $Kelvin, (New-TestDatabase -Id "$($Mi.id)/databases/db2"))

        $Recs = @(Assert-SameAsLike -Resources $Rows)

        $Recs[0]['Databases'] | Should -Be 2
        $Recs[1]['Databases'] | Should -Be 2
    }

    It 'matches the old per-instance scan for a mixed set of instances' {
        $Rows = [System.Collections.Generic.List[object]]::new()
        foreach ($i in 0..19)
        {
            $Mi = New-TestInstance -Id (Get-MiId "mi-$i") -Name "mi-$i"
            $Rows.Add($Mi)
            # Every fourth instance has no databases (1..0 would count down, so skip it).
            foreach ($d in @(if ($i % 4) { 1..($i % 4) }))
            {
                $DbId = "$($Mi.id)/databases/db$d"
                if ($d % 2) { $DbId = $DbId.ToLowerInvariant() }
                $Rows.Add((New-TestDatabase -Id $DbId))
            }
        }
        $Shuffled = @($Rows | Sort-Object { $_.id.Length % 7 }, { $_.id })

        $Recs = @(Assert-SameAsLike -Resources $Shuffled)
        $Recs.Count | Should -Be 20
    }
}
