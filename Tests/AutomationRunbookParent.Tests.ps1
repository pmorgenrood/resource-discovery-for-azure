# Automation runbook to account matching tests
# Run with: Invoke-Pester ./Tests/AutomationRunbookParent.Tests.ps1 -Output Detailed
#
# Services/Infrastructure/AutomationAcc.ps1 matched a runbook to an account by
# the account NAME in the runbook id, so two accounts with the same name (in
# different resource groups or subscriptions) each listed both accounts'
# runbooks. A runbook now goes to the account whose id is the runbook id
# without its '/runbooks/<name>' part, compared without regard to case. The
# REAL collector runs on synthetic records; no live Azure.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # The Azure documentation placeholder and a plain label; not real
    # subscription ids. The collector compares the ids as text.
    $script:Guid = '12345678-1234-1234-1234-123456789012'
    $script:Guid2 = 'placeholder-subscription-2'
    $script:Subs = @(
        [pscustomobject]@{ id = $script:Guid; Name = 'sub-placeholder' }
        [pscustomobject]@{ id = $script:Guid2; Name = 'sub-placeholder-2' }
    )

    function Invoke-Collector
    {
        param($Records)
        return , @(& (Join-Path $script:Root 'Services/Infrastructure/AutomationAcc.ps1') -Sub $script:Subs -Resources @($Records) -Task 'Processing' -ResourceIdDictionary $null)
    }

    function Get-AccountId
    {
        param($Rg, $Name = 'aa-a', $Sub = $script:Guid)
        return "/subscriptions/$Sub/resourceGroups/$Rg/providers/Microsoft.Automation/automationAccounts/$Name"
    }

    function New-Account
    {
        param($Rg, $Name = 'aa-a', $Sub = $script:Guid, $Id)
        if (-not $PSBoundParameters.ContainsKey('Id')) { $Id = Get-AccountId -Rg $Rg -Name $Name -Sub $Sub }
        return [pscustomobject]@{
            TYPE           = 'microsoft.automation/automationaccounts'
            id             = $Id
            name           = $Name
            RESOURCEGROUP  = $Rg
            LOCATION       = 'eastus'
            subscriptionId = $Sub
            properties     = [pscustomobject]@{ creationTime = '2026-01-01T00:00:00'; State = 'Ok'; sku = [pscustomobject]@{ name = 'Basic' } }
        }
    }

    function New-Runbook
    {
        param($AccountId, $Name, $Id)
        if (-not $PSBoundParameters.ContainsKey('Id')) { $Id = "$AccountId/runbooks/$Name" }
        return [pscustomobject]@{
            TYPE           = 'microsoft.automation/automationaccounts/runbooks'
            id             = $Id
            name           = "aa-a/$Name"
            RESOURCEGROUP  = 'rg-x'
            LOCATION       = 'eastus'
            subscriptionId = $script:Guid
            PROPERTIES     = [pscustomobject]@{ lastModifiedTime = '2026-02-03T04:05:00'; state = 'Published'; runbookType = 'PowerShell'; description = "desc-$Name" }
        }
    }

    function Get-Pairs
    {
        param($Rows)
        return @($Rows | ForEach-Object { '{0}|{1}' -f $_.ResourceGroup, $_.RunbookName } | Sort-Object)
    }
}

Describe 'Automation runbooks matched to their own account' {
    It 'keeps runbooks under their own account when two accounts share a name in two resource groups' {
        $A = Get-AccountId -Rg 'rg-a'
        $B = Get-AccountId -Rg 'rg-b'
        $Rows = Invoke-Collector @((New-Account -Rg 'rg-a'), (New-Account -Rg 'rg-b'), (New-Runbook $A 'rb-a'), (New-Runbook $B 'rb-b'))
        $Rows.Count | Should -Be 2
        Get-Pairs $Rows | Should -Be @('rg-a|aa-a/rb-a', 'rg-b|aa-a/rb-b')
    }

    It 'keeps runbooks under their own account when two accounts share a name and group in two subscriptions' {
        $A = Get-AccountId -Rg 'rg-a'
        $B = Get-AccountId -Rg 'rg-a' -Sub $script:Guid2
        $Rows = Invoke-Collector @((New-Account -Rg 'rg-a'), (New-Account -Rg 'rg-a' -Sub $script:Guid2), (New-Runbook $A 'rb-a'), (New-Runbook $B 'rb-b'))
        $Rows.Count | Should -Be 2
        ($Rows | Where-Object { $_.Subscription -eq 'sub-placeholder' }).RunbookName | Should -BeExactly 'aa-a/rb-a'
        ($Rows | Where-Object { $_.Subscription -eq 'sub-placeholder-2' }).RunbookName | Should -BeExactly 'aa-a/rb-b'
    }

    It 'matches a runbook whose id differs in case from its account id' {
        $A = Get-AccountId -Rg 'rg-a'
        $Upper = ($A -replace 'automationAccounts', 'AUTOMATIONACCOUNTS' -replace 'rg-a', 'RG-A')
        $Rows = Invoke-Collector @((New-Account -Rg 'rg-a'), (New-Runbook -Id "$Upper/RUNBOOKS/rb-a" -Name 'rb-a'), (New-Runbook $A 'rb-b'))
        $Rows.Count | Should -Be 2
        Get-Pairs $Rows | Should -Be @('rg-a|aa-a/rb-a', 'rg-a|aa-a/rb-b')
    }

    It 'lists every runbook of an account with several, in input order' {
        $A = Get-AccountId -Rg 'rg-a'
        $Rows = Invoke-Collector @((New-Account -Rg 'rg-a'), (New-Runbook $A 'rb-3'), (New-Runbook $A 'rb-1'), (New-Runbook $A 'rb-2'))
        @($Rows | ForEach-Object { $_.RunbookName }) | Should -Be @('aa-a/rb-3', 'aa-a/rb-1', 'aa-a/rb-2')
    }

    It 'writes one empty runbook row for an account with no runbooks' {
        $A = Get-AccountId -Rg 'rg-a'
        $Rows = Invoke-Collector @((New-Account -Rg 'rg-a'), (New-Account -Rg 'rg-b'), (New-Runbook $A 'rb-a'))
        $Rows.Count | Should -Be 2
        $Empty = $Rows | Where-Object { $_.ResourceGroup -eq 'rg-b' }
        $Empty.ID | Should -BeExactly (Get-AccountId -Rg 'rg-b')
        $Empty.RunbookName | Should -BeNullOrEmpty
        $Empty.RunbookState | Should -BeNullOrEmpty
    }

    It 'does not attach a runbook of an account that is not in the input' {
        $Other = Get-AccountId -Rg 'rg-z'
        $Rows = Invoke-Collector @((New-Account -Rg 'rg-a'), (New-Runbook $Other 'rb-z'))
        $Rows.Count | Should -Be 1
        $Rows[0].RunbookName | Should -BeNullOrEmpty
    }

    It 'skips a runbook whose id is <Case>, and keeps the account' -ForEach @(
        @{ Case = 'null'; Id = $null }
        @{ Case = 'empty'; Id = '' }
        @{ Case = 'without a runbooks part'; Id = '/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/rg-a/providers/Microsoft.Automation/automationAccounts/aa-a' }
        @{ Case = 'not a string'; Id = 42 }
    ) {
        $Rows = Invoke-Collector @((New-Account -Rg 'rg-a'), (New-Runbook -Id $Id -Name 'rb-x'))
        $Rows.Count | Should -Be 1
        $Rows[0].ID | Should -BeExactly (Get-AccountId -Rg 'rg-a')
        $Rows[0].RunbookName | Should -BeNullOrEmpty
    }

    It 'writes an account with no id once, with no runbooks' {
        $A = Get-AccountId -Rg 'rg-a'
        $Rows = Invoke-Collector @((New-Account -Rg 'rg-a' -Id $null), (New-Runbook $A 'rb-a'))
        $Rows.Count | Should -Be 1
        $Rows[0].RunbookName | Should -BeNullOrEmpty
    }

    It 'leaves the other columns unchanged' {
        $A = Get-AccountId -Rg 'rg-a'
        $Row = (Invoke-Collector @((New-Account -Rg 'rg-a'), (New-Runbook $A 'rb-a')))[0]
        $Row.ID | Should -BeExactly "$A/runbooks/rb-a"
        $Row.Subscription | Should -BeExactly 'sub-placeholder'
        $Row.ResourceGroup | Should -BeExactly 'rg-a'
        $Row.AutomationAccountName | Should -BeExactly 'aa-a'
        $Row.AutomationAccountState | Should -BeExactly 'Ok'
        $Row.AutomationAccountSKU | Should -BeExactly 'Basic'
        $Row.AutomationAccountCreatedTime | Should -BeExactly '2026-01-01 00:00'
        $Row.Location | Should -BeExactly 'eastus'
        $Row.LastModifiedTime | Should -BeExactly '2026-02-03 04:05'
        $Row.RunbookState | Should -BeExactly 'Published'
        $Row.RunbookType | Should -BeExactly 'PowerShell'
        $Row.RunbookDescription | Should -BeExactly 'desc-rb-a'
        @($Row.Keys).Count | Should -Be 13
    }
}
