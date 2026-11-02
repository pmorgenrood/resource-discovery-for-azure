# SQL managed instance backup storage tests
# Run with: Invoke-Pester ./Tests/SQLMIBackupStorage.Tests.ps1 -Output Detailed
#
# Services/Data/SQLMI.ps1 writes the instance's backup storage redundancy in
# the StorageAccountType column. Older API shapes carry it as
# properties.storageAccountType; current shapes have no such property and
# carry currentBackupStorageRedundancy and requestedBackupStorageRedundancy
# instead, so the column was empty for every current instance. The rule is
# the one Services/Data/SQLDB.ps1 uses: the first non-empty string of
# storageAccountType, currentBackupStorageRedundancy,
# requestedBackupStorageRedundancy, else empty. The REAL collector runs on
# synthetic records; no live Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # The Azure documentation placeholder; not a real subscription id.
    $script:Guid = '12345678-1234-1234-1234-123456789012'
    $script:Subs = @([pscustomobject]@{ id = $script:Guid; Name = 'sub-placeholder' })
    $script:Rg = "/subscriptions/$($script:Guid)/resourceGroups/rg-a/providers"

    function Invoke-Collector
    {
        param($Records)
        return , @(& (Join-Path $script:Root 'Services/Data/SQLMI.ps1') -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $null)
    }

    # -Backup maps a backup field name to its value; a field not named is absent.
    function New-Instance
    {
        param([hashtable]$Backup = @{})
        $Props = [ordered]@{
            vCores                    = 4
            storageSizeInGB           = 256
            licenseType               = 'LicenseIncluded'
            state                     = 'Ready'
            managedInstanceCreateMode = 'Default'
            zoneRedundant             = $false
        }
        foreach ($Key in $Backup.Keys) { $Props[$Key] = $Backup[$Key] }
        return [pscustomobject]@{
            TYPE           = 'microsoft.sql/managedInstances'
            id             = "$($script:Rg)/Microsoft.Sql/managedInstances/mi-a"
            NAME           = 'mi-a'
            RESOURCEGROUP  = 'rg-a'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            sku            = [pscustomobject]@{ name = 'GP_Gen5'; capacity = 4; tier = 'GeneralPurpose'; family = 'Gen5' }
            PROPERTIES     = [pscustomobject]$Props
        }
    }
}

Describe 'SQL managed instance StorageAccountType' {
    It 'writes <Expected> for <Case>' -ForEach @(
        @{ Case = 'the current shape'; Backup = @{ currentBackupStorageRedundancy = 'Geo'; requestedBackupStorageRedundancy = 'Geo' }; Expected = 'Geo' }
        @{ Case = 'current and requested differing'; Backup = @{ currentBackupStorageRedundancy = 'Local'; requestedBackupStorageRedundancy = 'Zone' }; Expected = 'Local' }
        @{ Case = 'only requested'; Backup = @{ requestedBackupStorageRedundancy = 'Zone' }; Expected = 'Zone' }
        @{ Case = 'the old shape'; Backup = @{ storageAccountType = 'GRS' }; Expected = 'GRS' }
        @{ Case = 'both shapes'; Backup = @{ storageAccountType = 'GRS'; currentBackupStorageRedundancy = 'Geo' }; Expected = 'GRS' }
        @{ Case = 'an empty current value'; Backup = @{ currentBackupStorageRedundancy = ''; requestedBackupStorageRedundancy = 'GeoZone' }; Expected = 'GeoZone' }
        @{ Case = 'a null old value'; Backup = @{ storageAccountType = $null; currentBackupStorageRedundancy = 'Geo' }; Expected = 'Geo' }
        @{ Case = 'a non-string current value'; Backup = @{ currentBackupStorageRedundancy = 3; requestedBackupStorageRedundancy = 'Local' }; Expected = 'Local' }
    ) {
        $Rows = Invoke-Collector @(New-Instance -Backup $Backup)
        $Rows.Count | Should -Be 1
        $Rows[0].StorageAccountType | Should -BeExactly $Expected
    }

    It 'writes an empty StorageAccountType when <Case>' -ForEach @(
        @{ Case = 'no backup field is present'; Backup = @{} }
        @{ Case = 'every backup field is null'; Backup = @{ storageAccountType = $null; currentBackupStorageRedundancy = $null; requestedBackupStorageRedundancy = $null } }
        @{ Case = 'every backup field is empty'; Backup = @{ currentBackupStorageRedundancy = ''; requestedBackupStorageRedundancy = '' } }
        @{ Case = 'the only value is not a string'; Backup = @{ currentBackupStorageRedundancy = [pscustomobject]@{ v = 'Geo' } } }
    ) {
        $Rows = Invoke-Collector @(New-Instance -Backup $Backup)
        $Rows.Count | Should -Be 1
        $Rows[0].StorageAccountType | Should -BeNullOrEmpty
        $Rows[0].State | Should -BeExactly 'Ready'
    }

    It 'leaves the other columns unchanged' {
        $Row = (Invoke-Collector @(New-Instance -Backup @{ currentBackupStorageRedundancy = 'Geo' }))[0]
        $Row.SkuName | Should -BeExactly 'GP_Gen5'
        $Row.SkuTier | Should -BeExactly 'GeneralPurpose'
        $Row.vCores | Should -Be 4
        $Row.StorageGB | Should -Be 256
        $Row.LicenseType | Should -BeExactly 'LicenseIncluded'
        $Row.ManagedInstanceCreateMode | Should -BeExactly 'Default'
        $Row.Databases | Should -Be '0'
        @($Row.Keys).Count | Should -Be 18
    }
}
