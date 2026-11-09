# SQL managed instance database count tests
# Run with: Invoke-Pester ./Tests/SQLMIDatabaseCount.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# The SQLMI collector counts each managed instance's databases. It used to scan
# every database row for every instance with
#     $_.Id -like "<instance id>/databases/*"
# and now counts the databases once, by parent id, before the loop. These tests
# run the REAL collector with synthetic rows and pin what it emits:
#
#   - the count is an int when the instance has databases, and the STRING '0'
#     when it has none;
#   - parent ids are matched without regard to letter case;
#   - databases of several instances can arrive in any order;
#   - odd ids give what the old '-like' match gave: an id that holds
#     '/databases/' twice, a database id with nothing after '/databases/', and
#     null ids;
#   - letter case is ignored the same way on every host culture, for ASCII and
#     non-ASCII letters, and look-alike letters such as the Kelvin sign stay
#     apart from 'k';
#   - wildcard characters (* ? [ ] and backtick) in an instance id are plain
#     characters, so the instance counts its own databases and an unclosed
#     bracket does not throw;
#   - on a tr-TR host, ids that differ only in I and i still count, which the
#     old scan got wrong, so this test fails if the old scan comes back.
#
# '-like' follows the host culture, so the tests pin the invariant culture and
# put the host's culture back at the end.
#
# No live Azure. All GUIDs are the Azure documentation placeholder.

BeforeAll {
    # '-like' follows the host culture, so pin it for the '-like' oracle below.
    # Tests that need another culture set it themselves and put this one back.
    $script:SavedCulture = [System.Globalization.CultureInfo]::CurrentCulture
    $script:SavedUICulture = [System.Globalization.CultureInfo]::CurrentUICulture
    [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
    [System.Globalization.CultureInfo]::CurrentUICulture = [System.Globalization.CultureInfo]::InvariantCulture

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
        param($Resources, $Subs = $script:Subs)
        & $script:Collector -Sub $Subs -Resources $Resources -Task 'Processing' -ResourceIdDictionary $null
    }

    function New-TestInstance
    {
        # No [string] on $Id: it would turn $null into ''.
        param([AllowNull()]$Id, [string]$Name = 'mi')
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
        param([AllowNull()]$Id)
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
        # Wildcard characters in an instance id are plain characters, so escape them.
        $LikeId = "$($Instance.Id)" -replace '([*?\[\]`])', '`$1'
        $Match = $Dbs | Where-Object { $_.Id -like "$LikeId/databases/*" }
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
        $NullDb = New-TestDatabase -Id $null
        $Rows = @($Mi, $NullMi, $NullDb, (New-TestDatabase -Id "$($Mi.id)/databases/db1"), (New-TestDatabase -Id '/databases/odd'))
        # The rows must hold a real $null, not '', or the null-id branch never runs.
        $null -eq $NullDb.id | Should -BeTrue
        $null -eq $NullMi.id | Should -BeTrue

        $Recs = @(Assert-SameAsLike -Resources $Rows)

        $Recs[0]['Databases'] | Should -Be 1
        $Recs[1]['Databases'] | Should -Be 1 -Because "a null id makes the pattern '/databases/*'"
    }

    It 'reads wildcard characters in an instance id as plain characters' {
        $Bracket = New-TestInstance -Id (Get-MiId 'mi[ab]')
        $Star = New-TestInstance -Id (Get-MiId 'mi*')
        $Query = New-TestInstance -Id (Get-MiId 'mi?')
        $Tick = New-TestInstance -Id (Get-MiId 'mi`x')
        $Rows = @(
            $Bracket, $Star, $Query, $Tick,
            (New-TestDatabase -Id "$(Get-MiId 'mi[ab]')/databases/db1"),
            (New-TestDatabase -Id "$(Get-MiId 'mi[ab]')/databases/db2"),
            (New-TestDatabase -Id "$(Get-MiId 'mi*')/databases/db1"),
            (New-TestDatabase -Id "$(Get-MiId 'mi`x')/databases/db1"),
            (New-TestDatabase -Id "$(Get-MiId 'mia')/databases/db1"),
            (New-TestDatabase -Id "$(Get-MiId 'mix')/databases/db1")
        )

        $Recs = @(Assert-SameAsLike -Resources $Rows)

        $Recs[0]['Databases'] | Should -Be 2 -Because "'mi[ab]' counts its own databases, not those of 'mia'"
        $Recs[1]['Databases'] | Should -Be 1 -Because "'mi*' counts only its own database"
        $Recs[2]['Databases'] | Should -BeExactly '0' -Because "'mi?' has no databases"
        $Recs[3]['Databases'] | Should -Be 1 -Because "'mi``x' counts its own database, not that of 'mix'"
    }

    It 'counts the databases of an instance id with an unclosed bracket, without throwing' {
        $Mi = New-TestInstance -Id (Get-MiId 'mi[')
        $Rec = Invoke-TestCollector -Resources @($Mi, (New-TestDatabase -Id "$($Mi.id)/databases/db1"))
        $Rec['Databases'] | Should -Be 1
        $Rec['Databases'] | Should -BeOfType ([int])
    }

    It 'reads wildcard characters as plain characters in an instance id with non-ASCII letters' {
        $Name = 'mi-' + [char]0x00E4 + '['
        $Mi = New-TestInstance -Id (Get-MiId $Name)
        $Other = New-TestInstance -Id (Get-MiId ('mi-' + [char]0x00E4 + '*'))
        $Rows = @($Mi, $Other, (New-TestDatabase -Id "$(Get-MiId $Name)/databases/db1"))

        $Recs = @(Invoke-TestCollector -Resources $Rows)

        $Recs[0]['Databases'] | Should -Be 1
        $Recs[1]['Databases'] | Should -BeExactly '0' -Because "'*' is a plain character, so it does not match '['"
    }

    It 'ignores the case of non-ASCII letters in an id, and keeps look-alike letters apart' {
        $Lower = 'mi-' + [char]0x00E4
        $Upper = 'MI-' + [char]0x00C4
        $Mi = New-TestInstance -Id (Get-MiId $Lower)
        $MiK = New-TestInstance -Id (Get-MiId 'mi-k')
        # U+212A KELVIN SIGN is its own letter, not 'k'.
        $KelvinMi = New-TestInstance -Id ("$(Get-MiId 'mi-')" + [char]0x212A)
        $Rows = @(
            $Mi, $MiK, $KelvinMi,
            (New-TestDatabase -Id "$(Get-MiId $Upper)/databases/db1"),
            (New-TestDatabase -Id "$(Get-MiId $Lower)/databases/db2"),
            (New-TestDatabase -Id ("$(Get-MiId 'mi-')" + [char]0x212A + '/databases/db1')),
            (New-TestDatabase -Id "$($MiK.id)/databases/db2")
        )

        $Recs = @(Invoke-TestCollector -Resources $Rows)

        $Recs[0]['Databases'] | Should -Be 2
        $Recs[1]['Databases'] | Should -Be 1
        $Recs[2]['Databases'] | Should -Be 1
    }

    It 'gives the true count on a tr-TR host for an id with non-ASCII letters that differs only in I and i' {
        $Mi = New-TestInstance -Id (Get-MiId ('mi-' + [char]0x00E4))
        $Db = New-TestDatabase -Id ("$($Mi.id)/databases/db1".ToLowerInvariant())
        $Saved = [System.Globalization.CultureInfo]::CurrentCulture
        try
        {
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::new('tr-TR')
            $Rec = Invoke-TestCollector -Resources @($Mi, $Db)
        }
        finally
        {
            [System.Globalization.CultureInfo]::CurrentCulture = $Saved
        }

        $Rec['Databases'] | Should -Be 1
        $Rec['Databases'] | Should -BeOfType ([int])
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

    It 'gives the true count on a tr-TR host when ids differ only in I and i' {
        # Under tr-TR, 'I' lower-cases to a dotless i, so a culture-aware match
        # misses 'managedInstances' against 'managedinstances'. The per-instance
        # '-like' scan wrote '0' here.
        $Mi = New-TestInstance -Id (Get-MiId 'mi-tr')
        $Db1 = New-TestDatabase -Id ("$($Mi.id)/databases/db1".ToLowerInvariant())
        $Db2 = New-TestDatabase -Id ("$($Mi.id)/DATABASES/DB2".ToUpperInvariant())
        $Saved = [System.Globalization.CultureInfo]::CurrentCulture
        try
        {
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::new('tr-TR')
            $Rec = Invoke-TestCollector -Resources @($Mi, $Db1, $Db2)
        }
        finally
        {
            [System.Globalization.CultureInfo]::CurrentCulture = $Saved
        }

        $Rec['Databases'] | Should -Be 2
        $Rec['Databases'] | Should -BeOfType ([int])
    }
}

Describe 'SQLMI subscription name' {

    BeforeAll {
        # What the old per-instance '-eq' scan gave for the same rows.
        function Get-ScanSubscription
        {
            param($Subs, $Instance)
            $Found = $Subs | Where-Object { $_.id -eq $Instance.subscriptionId }
            $Found.Name
        }

        function Assert-SameAsScan
        {
            param($Subs, $Instances)
            $Recs = @(Invoke-TestCollector -Resources $Instances -Subs $Subs)
            $Recs.Count | Should -Be @($Instances).Count
            for ($i = 0; $i -lt $Recs.Count; $i++)
            {
                $Want = Get-ScanSubscription -Subs $Subs -Instance @($Instances)[$i]
                $Got = $Recs[$i]['Subscription']
                if ($null -eq $Want)
                {
                    $null -eq $Got | Should -BeTrue -Because "instance $i has no subscription"
                }
                else
                {
                    $Got.GetType() | Should -Be $Want.GetType() -Because "instance $i keeps the value type"
                    @($Got) | Should -Be @($Want) -Because "instance $i"
                }
            }
            $Recs
        }

        function New-SubInstance
        {
            param($SubscriptionId, [string]$Name)
            $Mi = New-TestInstance -Id (Get-MiId $Name) -Name $Name
            $Mi.subscriptionId = $SubscriptionId
            $Mi
        }
    }

    It 'finds the subscription by id, ignoring letter case, as the scan did' {
        $Upper = 'ABCDEF00-1234-1234-1234-123456789012'
        $Subs = @(
            [pscustomobject]@{ id = $Upper.ToLowerInvariant(); Name = 'sub-a' },
            [pscustomobject]@{ id = $script:DocGuid; Name = 'sub-b' }
        )
        $Rows = @(
            (New-SubInstance -SubscriptionId $Upper -Name 'mi-1'),
            (New-SubInstance -SubscriptionId $script:DocGuid -Name 'mi-2'),
            (New-SubInstance -SubscriptionId 'not-a-sub' -Name 'mi-3')
        )

        $Recs = @(Assert-SameAsScan -Subs $Subs -Instances $Rows)

        $Recs[0]['Subscription'] | Should -BeExactly 'sub-a'
        $Recs[1]['Subscription'] | Should -BeExactly 'sub-b'
        $null -eq $Recs[2]['Subscription'] | Should -BeTrue
    }

    It 'gives what the scan gave when two subscriptions share an id' {
        $Subs = @(
            [pscustomobject]@{ id = $script:DocGuid; Name = 'first' },
            [pscustomobject]@{ id = 'other'; Name = 'other' },
            [pscustomobject]@{ id = $script:DocGuid.ToUpperInvariant(); Name = 'second' }
        )
        $null = Assert-SameAsScan -Subs $Subs -Instances @((New-SubInstance -SubscriptionId $script:DocGuid -Name 'mi-dup'))
    }

    It 'gives what the scan gave for null and non-string ids' {
        $Subs = @(
            [pscustomobject]@{ id = $script:DocGuid; Name = 'sub-a' },
            [pscustomobject]@{ id = $null; Name = 'sub-null' },
            [pscustomobject]@{ id = 42; Name = 'sub-int' }
        )
        $Rows = @(
            (New-SubInstance -SubscriptionId $script:DocGuid -Name 'mi-1'),
            (New-SubInstance -SubscriptionId $null -Name 'mi-2'),
            (New-SubInstance -SubscriptionId '42' -Name 'mi-3'),
            (New-SubInstance -SubscriptionId 42 -Name 'mi-4')
        )
        $null = Assert-SameAsScan -Subs $Subs -Instances $Rows
        $null = Assert-SameAsScan -Subs @($Subs[0]) -Instances $Rows
    }

    It 'gives what the scan gave for non-ASCII ids, on the invariant and the tr-TR culture' {
        $Subs = @(
            [pscustomobject]@{ id = 'sub-' + [char]0x00E4 + '-i'; Name = 'sub-a' },
            [pscustomobject]@{ id = 'sub-k'; Name = 'sub-k' }
        )
        $Rows = @(
            (New-SubInstance -SubscriptionId ('SUB-' + [char]0x00C4 + '-I') -Name 'mi-1'),
            (New-SubInstance -SubscriptionId ('sub-' + [char]0x212A) -Name 'mi-2')
        )
        $null = Assert-SameAsScan -Subs $Subs -Instances $Rows
        $Saved = [System.Globalization.CultureInfo]::CurrentCulture
        try
        {
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::new('tr-TR')
            $null = Assert-SameAsScan -Subs $Subs -Instances $Rows
        }
        finally
        {
            [System.Globalization.CultureInfo]::CurrentCulture = $Saved
        }
    }

    It 'gives no subscription name when there are no subscriptions' {
        $Recs = @(Invoke-TestCollector -Resources @((New-SubInstance -SubscriptionId $script:DocGuid -Name 'mi-1')) -Subs $null)
        $null -eq $Recs[0]['Subscription'] | Should -BeTrue
    }
}

AfterAll {
    [System.Globalization.CultureInfo]::CurrentCulture = $script:SavedCulture
    [System.Globalization.CultureInfo]::CurrentUICulture = $script:SavedUICulture
}

# The speed change itself: each database id and each subscription id is read
# a fixed number of times, not once per instance. A counting property stands in
# for the field, so a scan per instance shows up as instances x rows reads.
Describe 'SQLMI lookups read each row once' {
    BeforeAll {
        function New-CountedValue
        {
            param($Target, [string]$Name, $Value, [hashtable]$Count)
            $Target | Add-Member -MemberType ScriptProperty -Name $Name -Value { $Count.Reads++; $Value }.GetNewClosure() -Force
            $Target
        }
    }

    It 'reads each database id a fixed number of times, not once per instance' {
        $Count = @{ Reads = 0 }
        $Instances = @(1..20 | ForEach-Object { New-TestInstance -Id (Get-MiId -Name "mi-r$_") -Name "mi-r$_" })
        $Dbs = @(1..20 | ForEach-Object {
                $D = New-TestDatabase -Id $null
                New-CountedValue -Target $D -Name 'id' -Value "$(Get-MiId -Name "mi-r$_")/databases/db-r$_" -Count $Count
            })
        $Recs = @(Invoke-TestCollector -Resources ($Instances + $Dbs))
        $Recs.Count | Should -Be 20
        foreach ($R in $Recs) { $R['Databases'] | Should -Be 1 }
        $Count.Reads | Should -BeLessOrEqual 60 -Because 'a scan per instance reads 20 x 20 = 400 database ids'
    }

    It 'reads each subscription id a fixed number of times, not once per instance' {
        $Count = @{ Reads = 0 }
        $Subs = @(1..20 | ForEach-Object {
                $S = [pscustomobject]@{ Name = "sub-r$_" }
                New-CountedValue -Target $S -Name 'id' -Value ('{0:d8}-1234-1234-1234-123456789012' -f $_) -Count $Count
            })
        $Instances = @(1..20 | ForEach-Object {
                $I = New-TestInstance -Id (Get-MiId -Name "mi-q$_") -Name "mi-q$_"
                $I.subscriptionId = '{0:d8}-1234-1234-1234-123456789012' -f $_
                $I
            })
        $Recs = @(Invoke-TestCollector -Resources $Instances -Subs $Subs)
        for ($i = 0; $i -lt 20; $i++) { $Recs[$i]['Subscription'] | Should -Be "sub-r$($i + 1)" }
        $Count.Reads | Should -BeLessOrEqual 100 -Because 'a scan per instance reads 20 x 20 = 400 ids'
    }
}
