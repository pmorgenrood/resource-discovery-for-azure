# Get-ObfuscatedResourceId tests
# Run with: Invoke-Pester ./Tests/ObfuscatedResourceId.Tests.ps1 -Output Detailed
#
# Get-ObfuscatedResourceId (ResourceInventory.ps1) builds the masked id that
# -Obfuscate writes for a resource. Every name segment must be masked,
# including a parent's name inside a child's id (SQL databases and elastic
# pools, managed instance databases, automation runbooks, NetApp capacity pools
# and volumes), and a parent segment must carry the parent's own token so ids
# still join. The functions are taken from ResourceInventory.ps1 with the
# PowerShell AST and run against the run's dictionaries set up here. Generic
# names and the documentation placeholder subscription id only.

BeforeAll {
    $Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
    foreach ($Name in @('Get-ObfuscationPrefix', 'New-ObfuscatedNameToken', 'Get-ObfuscationSubscriptionIndex', 'Test-RdaTenantScopeIdMaskable', 'Get-ObfuscatedResourceId', 'Add-RdaObfuscationToken', 'Get-RdaObfuscationDictionary'))
    {
        $Fn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq $Name }, $false))
        if ($Fn.Count -ne 1) { throw "$Name was not found in ResourceInventory.ps1." }
        . ([scriptblock]::Create($Fn[0].Extent.Text))
    }
    # The seeded dictionary build calls it; a missing one fails those tests only.
    $ShapeFn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Test-ObfuscatedIdShape' }, $false))
    if ($ShapeFn.Count -eq 1) { . ([scriptblock]::Create($ShapeFn[0].Extent.Text)) }

    $script:Sub = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $script:Base = "/subscriptions/$script:Sub/resourcegroups/rg-demo/providers"
    # A token the product writes: lower case (matched letter for letter even
    # under case-blind -match), with at most the hint of a name token.
    $script:Token = '(?-i:(?:prod|nonprod)_(?:databricks_|aks_|vmss_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'

    # A masked id with each prod_/nonprod_ token taken out, so a leak check on
    # a short real name ('aa-a') is not set off by a token's random GUID. Only
    # whole path segments that are a token of a form the product writes go
    # (only its own hints): a real subscription GUID, a real name that holds a
    # token-like part, or a real word put in as a hint is still seen, and
    # nothing is put in their place that a real name could match.
    function Get-TextOutsideTokenGuid
    {
        param([string]$Text)
        return ($Text -replace ('(?<=^|/)' + $script:Token + '(?=/|$)'), '')
    }

    function Reset-ObfuscationState
    {
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ResourceIdDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceNameDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceSubscriptionDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ResourceResourceGroupDictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $Global:ObfuscationSubscriptionTokens = @{}
        $Global:ObfuscationResourceGroupTokens = @{}
    }
}

AfterAll {
    foreach ($Name in @('Subscriptions', 'ResourceIdDictionary', 'ResourceNameDictionary', 'ResourceSubscriptionDictionary', 'ResourceResourceGroupDictionary', 'ObfuscationSubscriptionTokens', 'ObfuscationResourceGroupTokens', 'ObfuscationSubscriptionIndex', 'Resources'))
    {
        Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Get-ObfuscatedResourceId' {
    BeforeEach { Reset-ObfuscationState }

    It 'masks every name segment of a <Label> id and keeps its shape' -ForEach @(
        @{ Label = 'SQL database'; Id = '/microsoft.sql/servers/srv-a/databases/db-a'; Names = @('srv-a', 'db-a') }
        @{ Label = 'SQL elastic pool'; Id = '/microsoft.sql/servers/srv-a/elasticpools/pool-a'; Names = @('srv-a', 'pool-a') }
        @{ Label = 'managed instance database'; Id = '/microsoft.sql/managedinstances/mi-a/databases/midb-a'; Names = @('mi-a', 'midb-a') }
        @{ Label = 'automation runbook'; Id = '/microsoft.automation/automationaccounts/aa-a/runbooks/rb-a'; Names = @('aa-a', 'rb-a') }
        @{ Label = 'NetApp volume'; Id = '/microsoft.netapp/netappaccounts/na-a/capacitypools/cp-a/volumes/vol-a'; Names = @('na-a', 'cp-a', 'vol-a') }
        @{ Label = 'extension resource'; Id = '/microsoft.compute/virtualmachines/vm-a/providers/microsoft.insights/diagnosticsettings/ds-a'; Names = @('vm-a', 'ds-a') }
        @{ Label = 'resource whose real name looks like a token'; Id = '/microsoft.compute/virtualmachines/prod_11111111-2222-4333-8444-555555555555'; Names = @('prod_11111111-2222-4333-8444-555555555555') }
        @{ Label = 'resource whose real name looks like a token in upper case'; Id = '/microsoft.compute/virtualmachines/PROD_11111111-2222-4333-8444-555555555555'; Names = @('PROD_11111111-2222-4333-8444-555555555555') }
    ) {
        $Real = $script:Base + $Id
        $Masked = Get-ObfuscatedResourceId -ResourceId $Real
        foreach ($N in @($Names + @('rg-demo', $script:Sub))) { Get-TextOutsideTokenGuid $Masked | Should -Not -Match ([regex]::Escape($N)) }
        $RealParts = $Real -split '/'
        $MaskedParts = $Masked -split '/'
        $MaskedParts.Count | Should -Be $RealParts.Count
        for ($i = 0; $i -lt $RealParts.Count; $i++)
        {
            if ($RealParts[$i] -in @($Names + @('rg-demo', $script:Sub)))
            {
                $MaskedParts[$i] | Should -Match ('^' + $script:Token + '$')
                $MaskedParts[$i] | Should -Not -Be $RealParts[$i] -Because 'a real part is never kept, even one shaped like a token, letter case aside'
            }
            else { $MaskedParts[$i] | Should -BeExactly $RealParts[$i] }
        }
    }

    It 'the leak check is not set off by a token GUID that holds a short real name' {
        $Masked = '/subscriptions/prod_0000aaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/resourcegroups/prod_11111111-1111-4111-8111-111111111111/providers/microsoft.automation/automationaccounts/prod_123456aa-aaaa-4bbb-8ccc-dddddddddddd'
        Get-TextOutsideTokenGuid $Masked | Should -Not -Match ([regex]::Escape('aa-a'))
        Get-TextOutsideTokenGuid ($Masked + '/runbooks/aa-a') | Should -Match ([regex]::Escape('aa-a')) -Because 'a real name outside a token is still caught'
        Get-TextOutsideTokenGuid "/subscriptions/$script:Sub/resourcegroups/prod_11111111-1111-4111-8111-111111111111" | Should -Match ([regex]::Escape($script:Sub)) -Because 'a real subscription GUID is not a token, so it is still caught'
        Get-TextOutsideTokenGuid $Masked | Should -Not -Match 'token' -Because 'nothing a real name such as token could match is left where a token was'
        Get-TextOutsideTokenGuid ($Masked + '/runbooks/prod_vm1_11111111-1111-4111-8111-111111111111') | Should -Match 'vm1' -Because 'a real word in place of a hint is not a token the product writes'
        Get-TextOutsideTokenGuid ($Masked + '/runbooks/rb-prod_11111111-1111-4111-8111-111111111111') | Should -Match ([regex]::Escape('rb-prod_11111111-1111-4111-8111-111111111111')) -Because 'a real segment that only holds a token-like part is not taken out'
    }

    It 'uses the parent resource''s own name token for the parent segment' {
        $Server = "$script:Base/microsoft.sql/servers/srv-a"
        $Global:ResourceNameDictionary[$Server] = 'prod_' + [guid]::NewGuid().ToString()
        $Masked = Get-ObfuscatedResourceId -ResourceId "$Server/databases/db-a"
        ($Masked -split '/')[8] | Should -BeExactly $Global:ResourceNameDictionary[$Server]
        (Get-ObfuscatedResourceId -ResourceId $Server) | Should -BeExactly ($Masked -replace '/databases/[^/]+$', '')
    }

    It 'gives two children of one parent that is not in the inventory the same parent token, and records it for the dictionary' {
        $A = Get-ObfuscatedResourceId -ResourceId "$script:Base/microsoft.sql/servers/srv-gone/databases/db-1"
        $B = Get-ObfuscatedResourceId -ResourceId "$script:Base/microsoft.sql/servers/srv-gone/databases/db-2"
        ($A -split '/')[8] | Should -BeExactly ($B -split '/')[8]
        $Global:ResourceNameDictionary["$script:Base/microsoft.sql/servers/srv-gone"] | Should -BeExactly ($A -split '/')[8]
        $Global:ResourceNameDictionary["$script:Base/microsoft.sql/servers/srv-gone/databases/db-1"] | Should -BeExactly ($A -split '/')[10]
    }

    It 'uses the inventory''s subscription and resource group tokens, and records them for an id outside the inventory' {
        $Global:ObfuscationSubscriptionTokens[$script:Sub] = 'prod_' + [guid]::NewGuid().ToString()
        $Global:ObfuscationResourceGroupTokens['rg-demo'] = 'prod_' + [guid]::NewGuid().ToString()
        $Id = "$script:Base/microsoft.compute/disks/disk-gone"
        $Masked = Get-ObfuscatedResourceId -ResourceId $Id
        ($Masked -split '/')[2] | Should -BeExactly $Global:ObfuscationSubscriptionTokens[$script:Sub]
        ($Masked -split '/')[4] | Should -BeExactly $Global:ObfuscationResourceGroupTokens['rg-demo']
        $Global:ResourceSubscriptionDictionary[$Id] | Should -BeExactly $Global:ObfuscationSubscriptionTokens[$script:Sub]
        $Global:ResourceResourceGroupDictionary[$Id] | Should -BeExactly $Global:ObfuscationResourceGroupTokens['rg-demo']
    }

    It 'masks a subscription-level id, gives the name ''$system'' a token, and gives an AKS-managed resource the aks_ hint' {
        $SubLevel = Get-ObfuscatedResourceId -ResourceId "/subscriptions/$script:Sub/providers/microsoft.insights/components/ai-a"
        $SubLevel | Should -Match ('^/subscriptions/' + $script:Token + '/providers/microsoft.insights/components/' + $script:Token + '$')
        $System = Get-ObfuscatedResourceId -ResourceId "$script:Base/microsoft.servicebus/namespaces/sb-a/topics/`$system"
        ($System -split '/')[-1] | Should -Match ('^' + $script:Token + '$') -Because 'the contract leaves no name part as written, $system included'
        $Aks = Get-ObfuscatedResourceId -ResourceId "/subscriptions/$script:Sub/resourcegroups/mc_rg_aks_eastus/providers/microsoft.compute/disks/osdisk-a"
        ($Aks -split '/')[-1] | Should -Match '^(prod|nonprod)_aks_'
    }

    It 'keeps the path of a tenant-scope id (no subscription), masks each name, and gives a parent one token' {
        $Order = '/providers/Microsoft.Capacity/reservationOrders/ro-a'
        $Masked = Get-ObfuscatedResourceId -ResourceId "$Order/reservations/res-a"
        $Masked | Should -Match ('^/providers/Microsoft\.Capacity/reservationOrders/' + $script:Token + '/reservations/' + $script:Token + '$')
        $Masked | Should -Not -Match 'ro-a|res-a'
        $Second = Get-ObfuscatedResourceId -ResourceId "$Order/reservations/res-b"
        ($Second -split '/')[4] | Should -BeExactly ($Masked -split '/')[4] -Because 'one reservation order keeps one token'
        (Get-ObfuscatedResourceId -ResourceId '/providers/Microsoft.Management/managementGroups/mg-a') | Should -Match ('^/providers/Microsoft\.Management/managementGroups/' + $script:Token + '$')
        $Global:ResourceNameDictionary.ContainsKey("$Order/reservations/res-a") | Should -BeTrue -Because 'the dictionary can reverse every segment'
    }

    It 'gives a /providers/ id that cannot be fully masked one flat token, never a path with a real part: <Label>' -ForEach @(
        @{ Label = 'a type with no name'; Id = '/providers/Microsoft.Capacity/reservationOrders' }
        @{ Label = 'an empty segment'; Id = '/providers/Microsoft.Capacity/reservationOrders//reservations/res-a' }
        @{ Label = 'a $system name'; Id = '/providers/Microsoft.Capacity/reservationOrders/$system' }
        @{ Label = 'a trailing slash'; Id = '/providers/Microsoft.Capacity/reservationOrders/ro-a/' }
    ) {
        $Masked = Get-ObfuscatedResourceId -ResourceId $Id
        $Masked | Should -Match ('^' + $script:Token + '$')
    }

    It 'returns ''obfuscated'' for an empty id and one token for an id that is not subscription-scoped' {
        Get-ObfuscatedResourceId -ResourceId '' | Should -BeExactly 'obfuscated'
        Get-ObfuscatedResourceId -ResourceId 'not-an-arm-id' | Should -Match ('^' + $script:Token + '$')
    }
}

Describe 'The dictionary build writes the name token New-ObfuscatedNameToken writes' {
    BeforeAll {
        # The -Obfuscate dictionary build of RunInventorySetup, run as a function. Its
        # per-resource loop builds the name token inline.
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$(Global:Resources|TokenLoopRows)\)|Add-RdaObfuscationToken -Rows \$TokenLoopRows' }, $true))
        if ($Build.Count -ne 1) { throw 'The -Obfuscate dictionary build was not found in RunInventorySetup.' }
        . ([scriptblock]::Create("function Invoke-DictionaryBuild { `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$null; $($Build[0].Extent.Text) }"))

        $script:Cases = @(
            @{ Id = "$script:Base/microsoft.compute/virtualmachines/vm-a"; Name = 'vm-a' }
            @{ Id = "$script:Base/microsoft.compute/virtualmachines/vm-dev-a"; Name = 'vm-dev-a' }
            @{ Id = "$script:Base/microsoft.compute/virtualmachines/VM-TEST-B"; Name = 'VM-TEST-B' }
            @{ Id = "$script:Base/microsoft.web/sites/t-web"; Name = 't-web' }
            @{ Id = "$script:Base/microsoft.compute/disks/disk-noname"; Name = $null }
            @{ Id = "$script:Base/microsoft.databricks/workspaces/dbw-a"; Name = 'dbw-a' }
            @{ Id = "$script:Base/microsoft.databricks/workspaces/dbw-dev"; Name = 'dbw-dev' }
            @{ Id = "/subscriptions/$script:Sub/resourcegroups/mc_rg_aks/providers/microsoft.compute/disks/osdisk-b"; Name = 'osdisk-b' }
            @{ Id = "$script:Base/microsoft.compute/virtualmachinescalesets/vmss-a"; Name = 'vmss-a' }
        )
        Reset-ObfuscationState
        $Global:Resources = @(foreach ($C in $script:Cases) { [pscustomobject]@{ id = $C.Id; name = $C.Name; subscriptionId = $script:Sub; resourceGroup = ($C.Id -split '/')[4] } })
        Invoke-DictionaryBuild
    }

    It 'gives <Id> the prefix and hint New-ObfuscatedNameToken gives it' -ForEach @(
        @{ Id = 'vm-a' }, @{ Id = 'vm-dev-a' }, @{ Id = 'VM-TEST-B' }, @{ Id = 't-web' }, @{ Id = 'disk-noname' }, @{ Id = 'dbw-a' }, @{ Id = 'dbw-dev' }, @{ Id = 'osdisk-b' }, @{ Id = 'vmss-a' }
    ) {
        $Case = @($script:Cases | Where-Object { $_.Id.EndsWith('/' + $Id) })[0]
        $Expected = (New-ObfuscatedNameToken -ResourceId $Case.Id -Name $Case.Name) -replace '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', '<guid>'
        $Written = $Global:ResourceNameDictionary[$Case.Id]
        $Written | Should -Match ('^' + $script:Token + '$')
        ($Written -replace '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', '<guid>') | Should -BeExactly $Expected
    }
}

Describe 'The run''s resource dictionaries ignore the case of an id' {
    BeforeAll {
        # Variables (ResourceInventory.ps1) builds the run's dictionaries; the
        # -Obfuscate dictionary build of RunInventorySetup fills them.
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Vars = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Variables' }, $false)
        . ([scriptblock]::Create("function Invoke-RunVariables { `$Obfuscate = [switch]`$true; $($Vars.Body.Extent.Text.Substring(1, $Vars.Body.Extent.Text.Length - 2)) }"))
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$(Global:Resources|TokenLoopRows)\)|Add-RdaObfuscationToken -Rows \$TokenLoopRows' }, $true))
        . ([scriptblock]::Create("function Invoke-DictionaryBuild2 { `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$null; $($Build[0].Extent.Text) }"))
        function GetLocalVersion { '0.0.0-test' }
    }

    AfterAll {
        Remove-Variable -Scope Global -Name TagValueDictionary, FreeTextDictionary, ResourceCount, ResourceContainers, ReportName, Version, RawRepo, TableStyle -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Invoke-RunVariables
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ObfuscationSubscriptionIndex = $null
    }

    It 'finds the id Resource Graph gave in lower case when consumption gives it in other casing' {
        $Lower = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $Global:Resources = @([pscustomobject]@{ id = $Lower; name = 'vm-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' })
        Invoke-DictionaryBuild2
        $Mixed = "/subscriptions/$script:Sub/resourceGroups/RG-Demo/providers/Microsoft.Compute/virtualMachines/VM-A"
        foreach ($D in @($Global:ResourceIdDictionary, $Global:ResourceNameDictionary, $Global:ResourceSubscriptionDictionary, $Global:ResourceResourceGroupDictionary))
        {
            $D.ContainsKey($Mixed) | Should -BeTrue
        }
        $Global:ResourceIdDictionary[$Mixed] | Should -BeExactly $Global:ResourceIdDictionary[$Lower]
    }

    It 'gives the subscription one token when it is listed twice, the one its ids hold' {
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' }, [pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ObfuscationSubscriptionIndex = $null
        $Global:Resources = @(
            [pscustomobject]@{ id = "$script:Base/microsoft.compute/virtualmachines/vm-a"; name = 'vm-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
            [pscustomobject]@{ id = "$script:Base/microsoft.compute/virtualmachines/vm-b"; name = 'vm-b'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
        )
        Invoke-DictionaryBuild2
        foreach ($Id in @($Global:ResourceIdDictionary.Keys))
        {
            $Global:ResourceSubscriptionDictionary[$Id] | Should -BeExactly ($Global:ResourceIdDictionary[$Id] -split '/')[2]
        }
    }

    It 'masks a resource listed twice in different casing once, with one id' {
        $Global:Resources = @(
            [pscustomobject]@{ id = "$script:Base/microsoft.compute/virtualmachines/vm-a"; name = 'vm-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
            [pscustomobject]@{ id = "$script:Base/Microsoft.Compute/virtualMachines/VM-A"; name = 'VM-A'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
        )
        Invoke-DictionaryBuild2
        @($Global:ResourceIdDictionary.Keys).Count | Should -Be 1
    }
}

Describe 'A run seeded with an obfuscation dictionary' {
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Vars = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Variables' }, $false)
        . ([scriptblock]::Create("function Invoke-RunVariables3 { `$Obfuscate = [switch]`$true; $($Vars.Body.Extent.Text.Substring(1, $Vars.Body.Extent.Text.Length - 2)) }"))
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$(Global:Resources|TokenLoopRows)\)|Add-RdaObfuscationToken -Rows \$TokenLoopRows' }, $true))
        . ([scriptblock]::Create("function Invoke-SeededBuild { param(`$Seed) `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$Seed; function Write-Log { }; $($Build[0].Extent.Text) }"))
        function GetLocalVersion { '0.0.0-test' }
        $script:SeedDir = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-seed-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:SeedDir -Force | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SeedDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Global -Name TagValueDictionary, FreeTextDictionary, ResourceCount, ResourceContainers, ReportName, Version, RawRepo, TableStyle -ErrorAction SilentlyContinue
    }

    It 'gives each seeded resource the subscription, resource group and name tokens of its own seeded id' {
        # A first run's tokens, written as its dictionary file is.
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $SubTok = 'prod_' + [guid]::NewGuid().ToString()
        $RgTok = 'prod_' + [guid]::NewGuid().ToString()
        $NameTok = 'prod_' + [guid]::NewGuid().ToString()
        $Masked = "/subscriptions/$SubTok/resourcegroups/$RgTok/providers/microsoft.compute/virtualmachines/$NameTok"
        $Seed = Join-Path $script:SeedDir 'seed.json'
        @{
            ResourceIdMap       = @{ $Masked = $Vm }
            ResourceNameMap     = @{ $NameTok = $Vm }
            SubscriptionNameMap = @{ $SubTok = 'Demo Subscription' }
            ResourceGroupMap    = @{ $RgTok = $Vm }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Seed -Encoding utf8

        Invoke-RunVariables3
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ObfuscationSubscriptionIndex = $null
        $Global:Resources = @(
            [pscustomobject]@{ id = $Vm; name = 'vm-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
            [pscustomobject]@{ id = "$script:Base/microsoft.compute/disks/disk-a"; name = 'disk-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
        )
        Invoke-SeededBuild -Seed $Seed

        $Global:ResourceIdDictionary[$Vm] | Should -BeExactly $Masked
        $Global:ResourceSubscriptionDictionary[$Vm] | Should -BeExactly $SubTok
        $Global:ResourceResourceGroupDictionary[$Vm] | Should -BeExactly $RgTok
        $Global:ResourceNameDictionary[$Vm] | Should -BeExactly $NameTok
        # The unseeded disk of the same group gets the same seeded tokens.
        $Disk = "$script:Base/microsoft.compute/disks/disk-a"
        ($Global:ResourceIdDictionary[$Disk] -split '/')[2] | Should -BeExactly $SubTok
        ($Global:ResourceIdDictionary[$Disk] -split '/')[4] | Should -BeExactly $RgTok
        foreach ($D in @($Global:ResourceSubscriptionDictionary, $Global:ResourceResourceGroupDictionary, $Global:ResourceNameDictionary))
        {
            @($D.Values | Where-Object { [string]::IsNullOrEmpty($_) }) | Should -BeNullOrEmpty
        }
    }

    It 'masks again a seeded id of another shape: <Label>' -ForEach @(
        @{ Label = 'an older dictionary''s child id that kept its parent''s real name'; Flat = $false }
        @{ Label = 'a flat seeded token'; Flat = $true }
    ) {
        $Db = "$script:Base/microsoft.sql/servers/srv-a/databases/db-a"
        $SubTok = 'prod_' + [guid]::NewGuid().ToString()
        $RgTok = 'prod_' + [guid]::NewGuid().ToString()
        $NameTok = 'prod_' + [guid]::NewGuid().ToString()
        $Seeded = if ($Flat) { 'prod_' + [guid]::NewGuid().ToString() } else { "/subscriptions/$SubTok/resourcegroups/$RgTok/providers/microsoft.sql/servers/srv-a/databases/$NameTok" }
        $Seed = Join-Path $script:SeedDir ('seed-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
        @{
            ResourceIdMap       = @{ $Seeded = $Db }
            SubscriptionNameMap = @{ $SubTok = 'Demo Subscription' }
            ResourceGroupMap    = @{ $RgTok = $Db }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Seed -Encoding utf8
        Invoke-RunVariables3
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ObfuscationSubscriptionIndex = $null
        $Global:Resources = @([pscustomobject]@{ id = $Db; name = 'db-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' })
        Invoke-SeededBuild -Seed $Seed

        $Masked = $Global:ResourceIdDictionary[$Db]
        $Masked | Should -Not -BeExactly $Seeded
        $Masked | Should -Not -Match 'srv-a'
        Test-ObfuscatedIdShape -RealId $Db -MaskedId $Masked | Should -BeTrue
        # The subscription token comes from good seeded ids only (none here),
        # never from the name map; the group token still comes from the map.
        ($Masked -split '/')[2] | Should -Not -BeExactly $SubTok -Because 'the name map is not read for subscription tokens'
        ($Masked -split '/')[4] | Should -BeExactly $RgTok
        $Global:ResourceSubscriptionDictionary[$Db] | Should -BeExactly ($Masked -split '/')[2]
        $Global:ResourceResourceGroupDictionary[$Db] | Should -BeExactly ($Masked -split '/')[4]
    }

    It 'gives a new resource the subscription and group tokens of the seeded ids when the seed has no map entry for them' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $SubTok = 'prod_' + [guid]::NewGuid().ToString()
        $RgTok = 'prod_' + [guid]::NewGuid().ToString()
        $NameTok = 'prod_' + [guid]::NewGuid().ToString()
        $Seed = Join-Path $script:SeedDir 'seed-nomaps.json'
        @{ ResourceIdMap = @{ "/subscriptions/$SubTok/resourcegroups/$RgTok/providers/microsoft.compute/virtualmachines/$NameTok" = $Vm } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Seed -Encoding utf8
        Invoke-RunVariables3
        $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
        $Global:ObfuscationSubscriptionIndex = $null
        $Disk = "$script:Base/microsoft.compute/disks/disk-a"
        $Global:Resources = @(
            [pscustomobject]@{ id = $Vm; name = 'vm-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
            [pscustomobject]@{ id = $Disk; name = 'disk-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
        )
        Invoke-SeededBuild -Seed $Seed
        $Global:ResourceSubscriptionDictionary[$Disk] | Should -BeExactly $SubTok
        $Global:ResourceResourceGroupDictionary[$Disk] | Should -BeExactly $RgTok
        ($Global:ResourceIdDictionary[$Disk] -split '/')[2] | Should -BeExactly $SubTok
    }
}

Describe 'The seed is checked when it is read' {
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Vars = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Variables' }, $false)
        . ([scriptblock]::Create("function Invoke-RunVariables4 { `$Obfuscate = [switch]`$true; $($Vars.Body.Extent.Text.Substring(1, $Vars.Body.Extent.Text.Length - 2)) }"))
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$(Global:Resources|TokenLoopRows)\)|Add-RdaObfuscationToken -Rows \$TokenLoopRows' }, $true))
        . ([scriptblock]::Create("function Invoke-SeededBuild4 { param(`$Seed) `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$Seed; function Write-Log { param(`$Message, `$Severity) if (`$Severity -eq 'Warning') { `$script:SeedWarnings.Add([string]`$Message) } }; $($Build[0].Extent.Text) }"))
        $script:SeedWarnings = [System.Collections.Generic.List[string]]::new()
        function GetLocalVersion { '0.0.0-test' }
        $script:SeedDir4 = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-seed4-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:SeedDir4 -Force | Out-Null
        $script:SeedDirW = $script:SeedDir4
        function New-Tok { param([string]$Hint = '') 'prod_' + $Hint + [guid]::NewGuid().ToString() }
        # One run: seed file in, the run's dictionaries out.
        function Invoke-SeededRun
        {
            param([hashtable]$SeedMaps, [object[]]$Rows)
            $Path = Join-Path $script:SeedDir4 ('seed-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
            $SeedMaps | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
            Invoke-RunVariables4
            $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
            $Global:ObfuscationSubscriptionIndex = $null
            $Global:Resources = @($Rows)
            Invoke-SeededBuild4 -Seed $Path
        }
        # The run's dictionary file, written by ResourceInventory.ps1's own
        # writer, read back as the next run's seed.
        $Writer = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Clauses[0].Item2.Extent.Text -match '\$Global:DictionaryFile = ' }, $false))
        if ($Writer.Count -ne 1) { throw 'The dictionary writer was not found in ResourceInventory.ps1.' }
        . ([scriptblock]::Create("function Invoke-DictionaryWriter { param(`$DefaultPath) `$Obfuscate = [switch]`$true; `$CurrentDateTime = 'test'; function Write-Log { }; $($Writer[0].Extent.Text) }"))
        function Get-RunDictionaryMaps
        {
            $Dir = Join-Path $script:SeedDirW ([guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $Global:ReportName = 'ResourcesReport'
            Invoke-DictionaryWriter -DefaultPath ($Dir + [System.IO.Path]::DirectorySeparatorChar)
            Get-Content -LiteralPath (Get-ChildItem -LiteralPath $Dir -Filter 'ObfuscationDictionary_*.json').FullName -Raw | ConvertFrom-Json -AsHashtable
        }
        function New-Res { param([string]$Id) [pscustomobject]@{ id = $Id; name = ($Id -split '/')[-1]; subscriptionId = $script:Sub; resourceGroup = ($Id -split '/')[4] } }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SeedDir4 -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Global -Name TagValueDictionary, FreeTextDictionary, ResourceCount, ResourceContainers, ReportName, Version, RawRepo, TableStyle -ErrorAction SilentlyContinue
    }

    It 'does not keep a seeded id of another shape for a resource this run does not see: <Label>' -ForEach @(
        @{ Label = 'a flat token'; Masked = 'prod_{0}' }
        @{ Label = 'a real parent name'; Masked = '/subscriptions/prod_{0}/resourcegroups/prod_{0}/providers/microsoft.sql/servers/srv-gone/databases/prod_{0}' }
        @{ Label = 'the metric step''s old sub_/rg_ tokens'; Masked = '/subscriptions/prod_sub_{0}/resourcegroups/prod_rg_{0}/providers/microsoft.sql/servers/prod_{0}/databases/prod_{0}' }
    ) {
        $Gone = "$script:Base/microsoft.sql/servers/srv-gone/databases/db-gone"
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ ($Masked -f [guid]::NewGuid().ToString()) = $Gone } } -Rows @()
        $Global:ResourceIdDictionary.ContainsKey($Gone) | Should -BeFalse -Because 'consumption or metrics that meet it mask it again'
    }

    It 'warns when the seed gives one resource two masked ids by case, and keeps the one of the right shape' {
        $script:SeedWarnings.Clear()
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $M = { "/subscriptions/$(New-Tok)/resourcegroups/$(New-Tok)/providers/microsoft.compute/virtualmachines/$(New-Tok)" }
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ (& $M) = $Vm; (& $M) = $Vm.ToUpperInvariant() } } -Rows @()
        ($script:SeedWarnings -join "`n") | Should -Match 'gives 1 resource\(s\) two masked ids \(by another casing, shape or token; an older build''s file, or one merged from runs not seeded from each other\).*only one can be kept.*collect the gap bundle on this build'
        # One good and one flat variant, in both orders: the good one is kept.
        foreach ($Order in 1, 2)
        {
            $Good = & $M; $Flat = New-Tok
            $Map = [ordered]@{}
            if ($Order -eq 1) { $Map[$Good] = $Vm; $Map[$Flat] = $Vm.ToUpperInvariant() } else { $Map[$Flat] = $Vm.ToUpperInvariant(); $Map[$Good] = $Vm }
            Invoke-SeededRun -SeedMaps @{ ResourceIdMap = $Map } -Rows @()
            $Global:ResourceIdDictionary[$Vm] | Should -BeExactly $Good -Because "order $Order"
        }
    }

    It 'warns, naming shape as well as case, when the seed gives one resource two masked ids of two shapes in one case, and keeps the one of the right shape' {
        # A merged dictionary of an older build's bundle and a new one gives one real
        # id, in one case, a flat or partly masked id and a good one.
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-b"
        foreach ($Order in 1, 2)
        {
            $script:SeedWarnings.Clear()
            $Good = "/subscriptions/$(New-Tok)/resourcegroups/$(New-Tok)/providers/microsoft.compute/virtualmachines/$(New-Tok)"; $Flat = New-Tok
            $Map = [ordered]@{}
            if ($Order -eq 1) { $Map[$Good] = $Vm; $Map[$Flat] = $Vm } else { $Map[$Flat] = $Vm; $Map[$Good] = $Vm }
            Invoke-SeededRun -SeedMaps @{ ResourceIdMap = $Map } -Rows @()
            ($script:SeedWarnings -join "`n") | Should -Match 'gives 1 resource\(s\) two masked ids \(by another casing, shape or token; an older build''s file, or one merged from runs not seeded from each other\).*only one can be kept' -Because "order $Order"
            (Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly)[$Vm] | Should -BeExactly $Good -Because "order $Order"
        }
    }

    It 'warns, naming another token, when the seed gives one resource two masked ids of the right shape in one case (a dictionary merged from runs not seeded from each other)' {
        $script:SeedWarnings.Clear()
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-c"
        $M = { "/subscriptions/$(New-Tok)/resourcegroups/$(New-Tok)/providers/microsoft.compute/virtualmachines/$(New-Tok)" }
        $First = & $M; $Second = & $M
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = [ordered]@{ $First = $Vm; $Second = $Vm } } -Rows @()
        ($script:SeedWarnings -join "`n") | Should -Match 'gives 1 resource\(s\) two masked ids \(by another casing, shape or token; an older build''s file, or one merged from runs not seeded from each other\).*only one can be kept.*collect the gap bundle on this build'
        (Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly)[$Vm] | Should -BeIn @($First, $Second) -Because 'one of the two ids is kept'
    }

    # The seed check drops a tag or free-text entry whose token is not of the run's form, equals
    # its value, or is one the seed also uses in a path or for another value; the run then gives
    # that value a new token. The 'preloaded' line counts the entries before that, so the run
    # says how many it did not keep, as it does for seeded ids (a flat id among them).
    It 'warns with the count of seeded tag and free-text entries it does not keep, and counts a flat id it does not keep among the seeded ids it does not keep' {
        $script:SeedWarnings.Clear()
        $SubTok = New-Tok; $RgTok = New-Tok; $NameTok = New-Tok; $Same = New-Tok
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-w"
        $Seed = @{
            ResourceIdMap   = @{
                "/subscriptions/$SubTok/resourcegroups/$RgTok/providers/microsoft.compute/virtualmachines/$NameTok" = $Vm
                # A flat id whose token is not of the run's form, and one whose token is the group's.
                'not-a-token' = 'flat-id-form'
                $RgTok        = 'flat-id-shared'
            }
            ResourceNameMap = @{ $NameTok = $Vm }
            # Kept: one each. Not kept: a token not of the form (tag and free text), one equal to
            # its value (tag), and one the seed also uses in a path (the name's, the group's).
            TagMap          = @{ (New-Tok) = 'tag-good'; ('prod_sub_' + [guid]::NewGuid().ToString()) = 'tag-form'; $Same = $Same; $NameTok = 'tag-shared' }
            FreeTextMap     = @{ (New-Tok) = 'text good'; 'plain-text-token' = 'text form'; $RgTok = 'text shared' }
        }
        Invoke-SeededRun -SeedMaps $Seed -Rows @()
        $Warn = $script:SeedWarnings -join "`n"
        $Warn | Should -Match '\b3 seeded tag and 2 free-text mapping\(s\) were not kept\b'
        $Warn | Should -Match 'those values get new tokens this run'
        $Warn | Should -Match '\b2 seeded id\(s\) of another shape, or holding a subscription, resource group or parent with two tokens, or a token two subscriptions, groups or resources share, were not kept' -Because 'the two flat ids are counted among the seeded ids not kept'
        foreach ($Real in 'tag-good', 'tag-form', 'tag-shared', 'text good', 'text form', 'text shared', 'flat-id-form', 'flat-id-shared', 'vm-w') { $Warn | Should -Not -Match ([regex]::Escape($Real)) -Because 'a warning holds no real value' }
        @((Get-Variable -Scope Global -Name TagValueDictionary -ValueOnly).Keys) | Should -Be @('tag-good')
        @((Get-Variable -Scope Global -Name FreeTextDictionary -ValueOnly).Keys) | Should -Be @('text good')
    }

    It 'writes no warning about tag or free-text entries when the seed''s are all kept' {
        $script:SeedWarnings.Clear()
        Invoke-SeededRun -SeedMaps @{ TagMap = @{ (New-Tok) = 'tag-good' }; FreeTextMap = @{ (New-Tok) = 'text good' } } -Rows @()
        ($script:SeedWarnings -join "`n") | Should -Not -Match 'free-text mapping'
        @((Get-Variable -Scope Global -Name TagValueDictionary -ValueOnly).Keys) | Should -Be @('tag-good')
        @((Get-Variable -Scope Global -Name FreeTextDictionary -ValueOnly).Keys) | Should -Be @('text good')
    }

    It 'keeps a good seeded id for a resource this run does not see' {
        $Gone = "$script:Base/microsoft.compute/virtualmachines/vm-gone"
        $Masked = "/subscriptions/$(New-Tok)/resourcegroups/$(New-Tok)/providers/microsoft.compute/virtualmachines/$(New-Tok)"
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ $Masked = $Gone } } -Rows @()
        $Global:ResourceIdDictionary[$Gone] | Should -BeExactly $Masked
    }

    It 'records the subscription and group tokens of a kept seeded id that the token loop does not see, for the rows and metrics that reuse it' {
        $Gone = "$script:Base/microsoft.compute/virtualmachines/vm-gone"
        $Masked = "/subscriptions/$(New-Tok)/resourcegroups/$(New-Tok)/providers/microsoft.compute/virtualmachines/$(New-Tok)"
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ $Masked = $Gone } } -Rows @()
        $Global:ResourceSubscriptionDictionary[$Gone] | Should -BeExactly ($Masked -split '/')[2]
        $Global:ResourceResourceGroupDictionary[$Gone] | Should -BeExactly ($Masked -split '/')[4]
        $Global:ResourceNameDictionary[$Gone] | Should -BeExactly ($Masked -split '/')[-1]
    }

    It 'keeps the seeded flat token of a real id that is not an ARM path, so it stays the same across seeded runs' {
        $Flat = New-Tok
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ $Flat = 'not-an-arm-id' } } -Rows @()
        $Global:ResourceIdDictionary['not-an-arm-id'] | Should -BeExactly $Flat
    }

    It 'keeps the seeded flat token of a real id that is not an ARM path for a resource this run sees too' {
        $Flat = New-Tok
        $Odd = [pscustomobject]@{ id = 'not-an-arm-id'; name = 'odd-a'; subscriptionId = $script:Sub; resourceGroup = 'rg-demo' }
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ $Flat = 'not-an-arm-id' } } -Rows @($Odd)
        $Global:ResourceIdDictionary['not-an-arm-id'] | Should -BeExactly $Flat
    }

    It 'keeps the seeded flat token of a /providers/ id this run writes flat too' {
        $Flat = New-Tok
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ $Flat = '/providers/Microsoft.Capacity/reservationOrders' } } -Rows @()
        $Global:ResourceIdDictionary['/providers/Microsoft.Capacity/reservationOrders'] | Should -BeExactly $Flat
    }

    It 'does not keep a seeded flat value that is not a flat token (plain text)' {
        # (An empty key is not valid seed JSON: the pre-flight refuses the file.)
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{ 'not-a-token' = 'not-an-arm-id' } } -Rows @()
        $Global:ResourceIdDictionary.ContainsKey('not-an-arm-id') | Should -BeFalse
    }

    It 'masks a resource from an old metric-fallback dictionary to the contract shape, and the next two seeded runs keep it' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $G = { [guid]::NewGuid().ToString() }
        $OldSub = 'prod_sub_' + (& $G); $OldRg = 'prod_rg_' + (& $G); $OldName = 'prod_' + (& $G)
        $Seed = @{
            ResourceIdMap       = @{ "/subscriptions/$OldSub/resourcegroups/$OldRg/providers/microsoft.compute/virtualmachines/$OldName" = $Vm }
            ResourceNameMap     = @{ $OldName = $Vm }
            SubscriptionNameMap = @{ $OldSub = 'Demo Subscription' }
            ResourceGroupMap    = @{ $OldRg = $Vm }
        }
        $First = $null
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun -SeedMaps $Seed -Rows @(New-Res $Vm)
            $Id = $Global:ResourceIdDictionary[$Vm]
            Test-ObfuscatedIdShape -RealId $Vm -MaskedId $Id | Should -BeTrue -Because "run $Run writes the contract shape"
            $Id | Should -Not -Match '_sub_|_rg_'
            if ($Run -eq 1) { $First = $Id } else { $Id | Should -BeExactly $First -Because "run $Run keeps run 1's id" }
            $Seed = Get-RunDictionaryMaps
        }
    }

    It 'masks again a seeded Service Bus id that kept the name ''$system'', with the seed''s group token, and the next two seeded runs keep it' {
        $Sys = "$script:Base/microsoft.servicebus/namespaces/`$system"
        $RgTok = New-Tok
        $Seed = @{
            ResourceIdMap    = @{ "/subscriptions/$(New-Tok)/resourcegroups/$RgTok/providers/microsoft.servicebus/namespaces/`$system" = $Sys }
            ResourceGroupMap = @{ $RgTok = $Sys }
        }
        $First = $null
        Invoke-SeededRun -SeedMaps $Seed -Rows @()
        (Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly).ContainsKey($Sys) | Should -BeFalse -Because 'a run that does not see the resource does not carry the old id on'
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun -SeedMaps $Seed -Rows @(New-Res $Sys)
            $Id = (Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly)[$Sys]
            $Id | Should -Not -Match ([regex]::Escape('$system')) -Because "run $Run leaves no name part as written"
            Test-ObfuscatedIdShape -RealId $Sys -MaskedId $Id | Should -BeTrue -Because "run $Run writes the contract shape"
            ($Id -split '/')[-1] | Should -BeExactly (Get-Variable -Scope Global -Name ResourceNameDictionary -ValueOnly)[$Sys] -Because 'the name token is recorded, so the dictionary reverses it'
            if ($Run -eq 1)
            {
                ($Id -split '/')[4] | Should -BeExactly $RgTok -Because 'the seed''s group token is kept'
                $First = $Id
            }
            else { $Id | Should -BeExactly $First -Because "run $Run keeps run 1's id, letter for letter" }
            $Seed = Get-RunDictionaryMaps
        }
    }

    It 'masks again a seeded id whose group or name slot kept a real part that looks like a token (<Case>), and the next two seeded runs keep it' -ForEach @(
        @{ Case = 'the same case'; Upper = $false }
        @{ Case = 'the real parts in upper case'; Upper = $true }
    ) {
        # A damaged or hand-combined seed whose masked id holds the real group and
        # name as they are: each real part is shaped like a token, so only the
        # check that a slot differs from its real part finds it.
        $G = { [guid]::NewGuid().ToString() }
        $RgReal = 'prod_' + (& $G); $NameReal = 'prod_' + (& $G)
        $Vm = "/subscriptions/$script:Sub/resourcegroups/$RgReal/providers/microsoft.compute/virtualmachines/$NameReal"
        $Kept = "/subscriptions/$(New-Tok)/resourcegroups/$RgReal/providers/microsoft.compute/virtualmachines/$NameReal"
        if ($Upper) { $Vm = $Vm -replace [regex]::Escape($RgReal), $RgReal.ToUpperInvariant() -replace [regex]::Escape($NameReal), $NameReal.ToUpperInvariant() }
        $Seed = @{
            ResourceIdMap    = @{ $Kept = $Vm }
            ResourceNameMap  = @{ $NameReal = $Vm }
            ResourceGroupMap = @{ $RgReal = "/subscriptions/$script:Sub/resourcegroups/$(($Vm -split '/')[4])" }
        }
        $First = $null
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun -SeedMaps $Seed -Rows @(New-Res $Vm)
            $Id = (Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly)[$Vm]
            $Parts = $Id -split '/'
            $Parts[4] | Should -Not -Be ($Vm -split '/')[4] -Because "run $Run masks the real group, letter case aside"
            $Parts[-1] | Should -Not -Be ($Vm -split '/')[-1] -Because "run $Run masks the real name, letter case aside"
            Test-ObfuscatedIdShape -RealId $Vm -MaskedId $Id | Should -BeTrue -Because "run $Run writes the contract shape"
            if ($Run -eq 1) { $First = $Id } else { $Id | Should -BeExactly $First -Because "run $Run keeps run 1's id, letter for letter" }
            $Seed = Get-RunDictionaryMaps
        }
    }

    # A damaged or hand-combined seed can give a tag or free-text value a token that is not
    # the run's '<prefix>_<guid>', or the value itself (which may look like a token). Such an
    # entry is not kept, so the run masks the value again; a good entry keeps its token.
    It 'masks again a <Map> value whose seeded token <Case>, keeps a good seeded token, and the next two seeded runs keep the new token' -ForEach @(
        @{ Map = 'TagMap'; Case = 'is not of token form'; Kind = 'form' }
        @{ Map = 'TagMap'; Case = 'equals the value'; Kind = 'same' }
        @{ Map = 'TagMap'; Case = 'equals the value in another case'; Kind = 'upper' }
        @{ Map = 'FreeTextMap'; Case = 'is not of token form'; Kind = 'form' }
        @{ Map = 'FreeTextMap'; Case = 'equals the value'; Kind = 'same' }
        @{ Map = 'FreeTextMap'; Case = 'equals the value in another case'; Kind = 'upper' }
    ) {
        # The run's own maskers: the collector row masking (tags) and the free-text one.
        $RowFn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Protect-RdaCollectorRow' }, $false))
        $RowFn.Count | Should -Be 1
        . ([scriptblock]::Create($RowFn[0].Extent.Text))
        $FnAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'), [ref]$null, [ref]$null)
        $FreeFn = @($FnAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Global:Protect-FreeTextValue' }, $false))
        $FreeFn.Count | Should -Be 1
        . ([scriptblock]::Create($FreeFn[0].Extent.Text))
        try
        {
            $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
            $Tok = New-Tok
            $Real = switch ($Kind) { 'form' { 'payments-01' } 'same' { $Tok } 'upper' { $Tok.ToUpperInvariant() } }
            $BadTok = if ($Kind -eq 'form') { 'tag_payments-01' } else { $Tok }
            $GoodTok = New-Tok
            $Seed = @{ $Map = @{ $BadTok = $Real; $GoodTok = 'finance-01' } }
            $First = $null
            foreach ($Run in 1, 2, 3)
            {
                Invoke-SeededRun -SeedMaps $Seed -Rows @(New-Res $Vm)
                if ($Map -eq 'TagMap')
                {
                    $Row = @{ ID = $Vm; Name = 'vm-a'; Subscription = 'Demo Subscription'; ResourceGroup = 'rg-demo'; Tags = @([pscustomobject]@{ Name = 'app'; Value = $Real }, [pscustomobject]@{ Name = 'team'; Value = 'finance-01' }) }
                    Protect-RdaCollectorRow -Rows @($Row) -Collector 'VirtualMachines'
                    $Masked = [string]$Row.Tags[0].Value
                    $Good = [string]$Row.Tags[1].Value
                }
                else
                {
                    $Masked = Protect-FreeTextValue $Real
                    $Good = Protect-FreeTextValue 'finance-01'
                }
                $Masked | Should -Not -Be $Real -Because "run $Run masks the value, letter case aside"
                $Masked | Should -MatchExactly '^(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -Because "run $Run writes the run's token form"
                $Good | Should -BeExactly $GoodTok -Because "run $Run keeps a good seeded token"
                if ($Run -eq 1) { $First = $Masked } else { $Masked | Should -BeExactly $First -Because "run $Run keeps run 1's token, letter for letter" }
                $Seed = Get-RunDictionaryMaps
            }
        }
        finally { Remove-Item -LiteralPath Function:\Protect-FreeTextValue -ErrorAction SilentlyContinue }
    }

    # A real id that is not an ARM path has one flat token. A seed that gives it itself (a
    # real id that looks like a token) as its token is not kept, so the run masks it again.
    It 'masks again a flat seeded id whose token equals its real id (<Case>), keeps a good flat seeded token, and the next two seeded runs keep the new token' -ForEach @(
        @{ Case = 'the same case'; Upper = $false }
        @{ Case = 'the real id in upper case'; Upper = $true }
    ) {
        $Tok = New-Tok
        $Flat = if ($Upper) { $Tok.ToUpperInvariant() } else { $Tok }
        $GoodFlat = 'marketplace-charge-01'
        $GoodTok = New-Tok
        $Seed = @{ ResourceIdMap = @{ $Tok = $Flat; $GoodTok = $GoodFlat } }
        $First = $null
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun -SeedMaps $Seed -Rows @((New-Res $Flat), (New-Res $GoodFlat))
            $Ids = Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly
            $Ids[$Flat] | Should -Not -Be $Flat -Because "run $Run masks the real id, letter case aside"
            $Ids[$Flat] | Should -MatchExactly '^(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -Because "run $Run writes one flat token"
            $Ids[$GoodFlat] | Should -BeExactly $GoodTok -Because "run $Run keeps a good flat seeded token"
            if ($Run -eq 1) { $First = $Ids[$Flat] } else { $Ids[$Flat] | Should -BeExactly $First -Because "run $Run keeps run 1's token, letter for letter" }
            $Seed = Get-RunDictionaryMaps
        }
    }

    # A damaged or hand-merged seed can give a tag or free-text value a token the seed also
    # uses for a subscription, a group, a name or a flat id, or for a value of the other map.
    # Reveal replaces a token wherever it stands, so revealing one meaning would rewrite the
    # other. The path token is kept (ids join on it); the tag or free-text value gets a new
    # token, and the next two seeded runs keep it. Reveal then gives each field its own value.
    It 'gives a <Map> value whose seeded token is also <Case> a new token, keeps the path tokens, the next two seeded runs keep it, and Reveal of tags alone and of all fields gives each field its own value' -ForEach @(
        @{ Map = 'TagMap'; Case = 'a name token'; Slot = 'name' }
        @{ Map = 'TagMap'; Case = 'a group token'; Slot = 'rg' }
        @{ Map = 'TagMap'; Case = 'a subscription token'; Slot = 'sub' }
        @{ Map = 'TagMap'; Case = 'a flat id token'; Slot = 'flat' }
        @{ Map = 'TagMap'; Case = 'a free-text token'; Slot = 'text' }
        @{ Map = 'FreeTextMap'; Case = 'a name token'; Slot = 'name' }
        @{ Map = 'FreeTextMap'; Case = 'a group token'; Slot = 'rg' }
    ) {
        # The run's own maskers: the collector row masking (tags) and the free-text one.
        $RowFn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Protect-RdaCollectorRow' }, $false))
        $RowFn.Count | Should -Be 1
        . ([scriptblock]::Create($RowFn[0].Extent.Text))
        $FnAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'), [ref]$null, [ref]$null)
        $FreeFn = @($FnAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Global:Protect-FreeTextValue' }, $false))
        $FreeFn.Count | Should -Be 1
        . ([scriptblock]::Create($FreeFn[0].Extent.Text))
        try
        {
            $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
            $FlatReal = 'marketplace-charge-01'
            $SubTok = New-Tok; $RgTok = New-Tok; $NameTok = New-Tok; $FlatTok = New-Tok; $TagTok = New-Tok; $TextTok = New-Tok
            $Shared = switch ($Slot) { 'name' { $NameTok } 'rg' { $RgTok } 'sub' { $SubTok } 'flat' { $FlatTok } 'text' { $TextTok } }
            if ($Map -eq 'TagMap') { $TagTok = $Shared } else { $TextTok = $Shared }
            $NewTag = $Map -eq 'TagMap'
            $NewText = $Map -eq 'FreeTextMap' -or $Slot -eq 'text'
            $VmMasked = "/subscriptions/$SubTok/resourcegroups/$RgTok/providers/microsoft.compute/virtualmachines/$NameTok"
            $Seed = @{
                ResourceIdMap    = @{ $VmMasked = $Vm; $FlatTok = $FlatReal }
                ResourceNameMap  = @{ $NameTok = $Vm }
                ResourceGroupMap = @{ $RgTok = "/subscriptions/$script:Sub/resourcegroups/rg-demo" }
                TagMap           = @{ $TagTok = 'payments-01' }
                FreeTextMap      = @{ $TextTok = 'team notes 01' }
            }
            $Runs = [System.Collections.Generic.List[object]]::new()
            foreach ($Run in 1, 2, 3)
            {
                Invoke-SeededRun -SeedMaps $Seed -Rows @((New-Res $Vm), (New-Res $FlatReal))
                $Row = @{ ID = $Vm; Name = 'vm-a'; Subscription = 'Demo Subscription'; ResourceGroup = 'rg-demo'; Tags = @([pscustomobject]@{ Name = 'app'; Value = 'payments-01' }) }
                $FlatRow = @{ ID = $FlatReal; Name = 'charge-01'; Subscription = 'Demo Subscription'; ResourceGroup = 'rg-demo' }
                Protect-RdaCollectorRow -Rows @($Row, $FlatRow) -Collector 'VirtualMachines'
                $Row['Description'] = Protect-FreeTextValue 'team notes 01'
                $Runs.Add([pscustomobject]@{ Run = $Run; Row = $Row; FlatRow = $FlatRow })
                $Seed = Get-RunDictionaryMaps
            }

            # The third run's rows in a report, revealed with the third run's dictionary.
            $Last = $Runs[2]
            $Dir = Join-Path $script:SeedDir4 ('reveal-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            $Stage = Join-Path $Dir 'stage'
            New-Item -ItemType Directory -Path $Stage -Force | Out-Null
            @{ VirtualMachines = @($Last.Row, $Last.FlatRow) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Stage 'Inventory_Test.json') -Encoding utf8
            $Zip = Join-Path $Dir 'ResourcesReport_Test.zip'
            Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip
            $DictPath = Join-Path $Dir 'ObfuscationDictionary_Test.json'
            $Seed | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $DictPath -Encoding utf8
            $RevealScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Reveal.ps1'
            $Reveal = {
                param([hashtable]$With)
                $Name = [guid]::NewGuid().ToString('N').Substring(0, 6)
                $Out = Join-Path $Dir ('out-' + $Name + '.zip')
                & $RevealScript -InputZip $Zip -DictionaryPath $DictPath -OutputZip $Out @With *>&1 | Out-Null
                $Ex = Join-Path $Dir ('ex-' + $Name)
                Expand-Archive -LiteralPath $Out -DestinationPath $Ex
                @((Get-Content -LiteralPath (Join-Path $Ex 'Inventory_Test.json') -Raw | ConvertFrom-Json).VirtualMachines)
            }

            $Tagged = & $Reveal @{ Fields = @('Tag') }
            $Tagged[0].Tags[0].Value | Should -BeExactly 'payments-01' -Because 'Reveal of tags gives the tag its value'
            $Tagged[0].Name | Should -BeExactly $NameTok -Because 'Reveal of tags leaves the name masked'
            $Tagged[0].ResourceGroup | Should -BeExactly $RgTok -Because 'Reveal of tags leaves the group masked'
            $Tagged[0].Subscription | Should -BeExactly $SubTok -Because 'Reveal of tags leaves the subscription masked'
            $Tagged[0].ID | Should -BeExactly $VmMasked -Because 'Reveal of tags leaves the id masked'
            $Tagged[0].Description | Should -BeExactly $Last.Row['Description'] -Because 'Reveal of tags leaves the free text masked'
            $Tagged[1].ID | Should -BeExactly $FlatTok -Because 'Reveal of tags leaves the flat id masked'
            $Full = & $Reveal @{ All = $true }
            $Full[0].Tags[0].Value | Should -BeExactly 'payments-01' -Because 'Reveal of all fields gives the tag its own value'
            $Full[0].Name | Should -BeExactly 'vm-a' -Because 'Reveal of all fields gives the name its own value'
            $Full[0].ResourceGroup | Should -BeExactly 'rg-demo' -Because 'Reveal of all fields gives the group its own value'
            $Full[0].Subscription | Should -BeExactly 'Demo Subscription' -Because 'Reveal of all fields gives the subscription its own value'
            $Full[0].ID | Should -BeExactly $Vm -Because 'Reveal of all fields gives the id its own value'
            $Full[0].Description | Should -BeExactly 'team notes 01' -Because 'Reveal of all fields gives the free text its own value'
            $Full[1].ID | Should -BeExactly $FlatReal -Because 'Reveal of all fields gives the flat id its own value'

            $TokenForm = '^(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            foreach ($R in $Runs)
            {
                $R.Row['ID'] | Should -BeExactly $VmMasked -Because "run $($R.Run) keeps the seeded id"
                $R.Row['Name'] | Should -BeExactly $NameTok -Because "run $($R.Run) keeps the name token"
                $R.Row['ResourceGroup'] | Should -BeExactly $RgTok -Because "run $($R.Run) keeps the group token"
                $R.Row['Subscription'] | Should -BeExactly $SubTok -Because "run $($R.Run) keeps the subscription token"
                $R.FlatRow['ID'] | Should -BeExactly $FlatTok -Because "run $($R.Run) keeps the flat id token"
                foreach ($Check in @(
                        [pscustomobject]@{ What = 'tag'; Now = [string]$R.Row['Tags'][0].Value; New = $NewTag; Seeded = $TagTok; First = [string]$Runs[0].Row['Tags'][0].Value }
                        [pscustomobject]@{ What = 'free-text value'; Now = [string]$R.Row['Description']; New = $NewText; Seeded = $TextTok; First = [string]$Runs[0].Row['Description'] }
                    ))
                {
                    if ($Check.New)
                    {
                        $Check.Now | Should -Not -Be $Shared -Because "run $($R.Run) gives the $($Check.What) a token of its own"
                        $Check.Now | Should -MatchExactly $TokenForm -Because "run $($R.Run) writes the run's token form for the $($Check.What)"
                        $Check.Now | Should -BeExactly $Check.First -Because "run $($R.Run) keeps run 1's $($Check.What) token, letter for letter"
                    }
                    else { $Check.Now | Should -BeExactly $Check.Seeded -Because "run $($R.Run) keeps the $($Check.What)'s good seeded token" }
                }
            }
        }
        finally { Remove-Item -LiteralPath Function:\Protect-FreeTextValue -ErrorAction SilentlyContinue }
    }

    # A damaged or hand-merged seed can give a flat id (a real id that is not an ARM path) the
    # token it also gives a subscription, a group or a name, in an id's slot or in a map. Reveal
    # puts a token's value wherever the token stands, and stops on a dictionary that holds one
    # token in two maps, so the run must not write one. The path token is kept (ids join on it);
    # the flat id gets a new token, and the next two seeded runs keep it. A tag or free-text value
    # that shares a flat id's token is the one that gets a new token (the check before it), so the
    # flat id keeps its token there. Reveal then gives each field its own value.
    It 'gives <Who> a new token when the seed gives a flat id and <Case> one token, keeps the path tokens, the next two seeded runs keep it, and Reveal of ids alone and of all fields gives each field its own value' -ForEach @(
        @{ Case = 'a resource''s name'; Slot = 'name'; Who = 'the flat id' }
        @{ Case = 'a resource group'; Slot = 'rg'; Who = 'the flat id' }
        @{ Case = 'a subscription'; Slot = 'sub'; Who = 'the flat id' }
        @{ Case = 'a name in the name map only'; Slot = 'namemap'; Who = 'the flat id' }
        @{ Case = 'a tag value'; Slot = 'tag'; Who = 'the tag value' }
        @{ Case = 'a free-text value'; Slot = 'text'; Who = 'the free-text value' }
    ) {
        # The run's own maskers: the collector row masking (tags) and the free-text one.
        $RowFn = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Protect-RdaCollectorRow' }, $false))
        $RowFn.Count | Should -Be 1
        . ([scriptblock]::Create($RowFn[0].Extent.Text))
        $FnAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'), [ref]$null, [ref]$null)
        $FreeFn = @($FnAst.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Global:Protect-FreeTextValue' }, $false))
        $FreeFn.Count | Should -Be 1
        . ([scriptblock]::Create($FreeFn[0].Extent.Text))
        try
        {
            $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
            $Other = "$script:Base/microsoft.compute/virtualmachines/vm-other"
            $FlatReal = 'marketplace-charge-01'
            $SubTok = New-Tok; $RgTok = New-Tok; $NameTok = New-Tok; $OtherTok = New-Tok; $TagTok = New-Tok; $TextTok = New-Tok
            $FlatTok = switch ($Slot) { 'name' { $NameTok } 'rg' { $RgTok } 'sub' { $SubTok } 'namemap' { $OtherTok } 'tag' { $TagTok } 'text' { $TextTok } }
            $NewFlat = $Slot -in @('name', 'rg', 'sub', 'namemap')
            $VmMasked = "/subscriptions/$SubTok/resourcegroups/$RgTok/providers/microsoft.compute/virtualmachines/$NameTok"
            $Seed = @{
                ResourceIdMap    = @{ $VmMasked = $Vm; $FlatTok = $FlatReal }
                ResourceNameMap  = @{ $NameTok = $Vm; $OtherTok = $Other }
                ResourceGroupMap = @{ $RgTok = "/subscriptions/$script:Sub/resourcegroups/rg-demo" }
                TagMap           = @{ $TagTok = 'payments-01' }
                FreeTextMap      = @{ $TextTok = 'team notes 01' }
            }
            $Runs = [System.Collections.Generic.List[object]]::new()
            foreach ($Run in 1, 2, 3)
            {
                Invoke-SeededRun -SeedMaps $Seed -Rows @((New-Res $Vm), (New-Res $FlatReal))
                $Row = @{ ID = $Vm; Name = 'vm-a'; Subscription = 'Demo Subscription'; ResourceGroup = 'rg-demo'; Tags = @([pscustomobject]@{ Name = 'app'; Value = 'payments-01' }) }
                $FlatRow = @{ ID = $FlatReal; Name = 'charge-01'; Subscription = 'Demo Subscription'; ResourceGroup = 'rg-demo' }
                Protect-RdaCollectorRow -Rows @($Row, $FlatRow) -Collector 'VirtualMachines'
                $Row['Description'] = Protect-FreeTextValue 'team notes 01'
                $OtherNow = (Get-Variable -Scope Global -Name ResourceNameDictionary -ValueOnly)[$Other]
                $Runs.Add([pscustomobject]@{ Run = $Run; Row = $Row; FlatRow = $FlatRow; Other = $OtherNow })
                $Seed = Get-RunDictionaryMaps
            }

            # The third run's rows in a report, revealed with the third run's dictionary.
            $Last = $Runs[2]
            $Dir = Join-Path $script:SeedDir4 ('reveal-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            $Stage = Join-Path $Dir 'stage'
            New-Item -ItemType Directory -Path $Stage -Force | Out-Null
            @{ VirtualMachines = @($Last.Row, $Last.FlatRow) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Stage 'Inventory_Test.json') -Encoding utf8
            $Zip = Join-Path $Dir 'ResourcesReport_Test.zip'
            Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Zip
            $DictPath = Join-Path $Dir 'ObfuscationDictionary_Test.json'
            $Seed | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $DictPath -Encoding utf8
            $RevealScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Reveal.ps1'
            $Reveal = {
                param([hashtable]$With)
                $Name = [guid]::NewGuid().ToString('N').Substring(0, 6)
                $Out = Join-Path $Dir ('out-' + $Name + '.zip')
                & $RevealScript -InputZip $Zip -DictionaryPath $DictPath -OutputZip $Out @With *>&1 | Out-Null
                $Ex = Join-Path $Dir ('ex-' + $Name)
                Expand-Archive -LiteralPath $Out -DestinationPath $Ex
                @((Get-Content -LiteralPath (Join-Path $Ex 'Inventory_Test.json') -Raw | ConvertFrom-Json).VirtualMachines)
            }

            $Ids = & $Reveal @{ Fields = @('ResourceId') }
            $Ids[0].ID | Should -BeExactly $Vm -Because 'Reveal of ids gives the id its value'
            $Ids[1].ID | Should -BeExactly $FlatReal -Because 'Reveal of ids gives the flat id its value'
            $Ids[0].Name | Should -BeExactly $NameTok -Because 'Reveal of ids leaves the name masked'
            $Ids[0].ResourceGroup | Should -BeExactly $RgTok -Because 'Reveal of ids leaves the group masked'
            $Ids[0].Subscription | Should -BeExactly $SubTok -Because 'Reveal of ids leaves the subscription masked'
            $Ids[0].Tags[0].Value | Should -BeExactly ([string]$Last.Row['Tags'][0].Value) -Because 'Reveal of ids leaves the tag masked'
            $Ids[0].Description | Should -BeExactly $Last.Row['Description'] -Because 'Reveal of ids leaves the free text masked'
            $Full = & $Reveal @{ All = $true }
            $Full[0].ID | Should -BeExactly $Vm -Because 'Reveal of all fields gives the id its own value'
            $Full[1].ID | Should -BeExactly $FlatReal -Because 'Reveal of all fields gives the flat id its own value'
            $Full[0].Name | Should -BeExactly 'vm-a' -Because 'Reveal of all fields gives the name its own value'
            $Full[0].ResourceGroup | Should -BeExactly 'rg-demo' -Because 'Reveal of all fields gives the group its own value'
            $Full[0].Subscription | Should -BeExactly 'Demo Subscription' -Because 'Reveal of all fields gives the subscription its own value'
            $Full[0].Tags[0].Value | Should -BeExactly 'payments-01' -Because 'Reveal of all fields gives the tag its own value'
            $Full[0].Description | Should -BeExactly 'team notes 01' -Because 'Reveal of all fields gives the free text its own value'

            $TokenForm = '^(prod|nonprod)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            foreach ($R in $Runs)
            {
                $R.Row['ID'] | Should -BeExactly $VmMasked -Because "run $($R.Run) keeps the seeded id"
                $R.Row['Name'] | Should -BeExactly $NameTok -Because "run $($R.Run) keeps the name token"
                $R.Row['ResourceGroup'] | Should -BeExactly $RgTok -Because "run $($R.Run) keeps the group token"
                $R.Row['Subscription'] | Should -BeExactly $SubTok -Because "run $($R.Run) keeps the subscription token"
                $R.Other | Should -BeExactly $OtherTok -Because "run $($R.Run) keeps the name map token of a resource it does not see"
                foreach ($Check in @(
                        [pscustomobject]@{ What = 'flat id'; Now = [string]$R.FlatRow['ID']; New = $NewFlat; Seeded = $FlatTok; First = [string]$Runs[0].FlatRow['ID'] }
                        [pscustomobject]@{ What = 'tag'; Now = [string]$R.Row['Tags'][0].Value; New = $Slot -eq 'tag'; Seeded = $TagTok; First = [string]$Runs[0].Row['Tags'][0].Value }
                        [pscustomobject]@{ What = 'free-text value'; Now = [string]$R.Row['Description']; New = $Slot -eq 'text'; Seeded = $TextTok; First = [string]$Runs[0].Row['Description'] }
                    ))
                {
                    if ($Check.New)
                    {
                        $Check.Now | Should -Not -Be $FlatTok -Because "run $($R.Run) gives the $($Check.What) a token of its own"
                        $Check.Now | Should -MatchExactly $TokenForm -Because "run $($R.Run) writes the run's token form for the $($Check.What)"
                        $Check.Now | Should -BeExactly $Check.First -Because "run $($R.Run) keeps run 1's $($Check.What) token, letter for letter"
                    }
                    else { $Check.Now | Should -BeExactly $Check.Seeded -Because "run $($R.Run) keeps the $($Check.What)'s good seeded token" }
                }
            }
        }
        finally { Remove-Item -LiteralPath Function:\Protect-FreeTextValue -ErrorAction SilentlyContinue }
    }

    It 'gives a $system parent that the seeded ids give two tokens one new token, in its own id and its child''s, and the next two seeded runs keep both' {
        # The namespace's own seeded id and its topic's give the one real
        # '.../namespaces/$system' two tokens (a seed written before the slot
        # check read a $system slot): both ids are dropped and masked again.
        $Ns = "$script:Base/microsoft.servicebus/namespaces/`$system"
        $Topic = "$Ns/topics/topic-a"
        $P = "/subscriptions/$(New-Tok)/resourcegroups/$(New-Tok)/providers/microsoft.servicebus/namespaces"
        $T1 = New-Tok; $T2 = New-Tok
        $Seed = @{ ResourceIdMap = @{ "$P/$T1" = $Ns; "$P/$T2/topics/$(New-Tok)" = $Topic } }
        $Parent = $null
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun -SeedMaps $Seed -Rows @((New-Res $Ns), (New-Res $Topic))
            $Ids = Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly
            $NsId = $Ids[$Ns]; $TopicId = $Ids[$Topic]
            foreach ($Pair in @(@($Ns, $NsId), @($Topic, $TopicId)))
            {
                $Pair[1] | Should -Not -Match ([regex]::Escape('$system')) -Because "run $Run leaves no name part as written"
                Test-ObfuscatedIdShape -RealId $Pair[0] -MaskedId $Pair[1] | Should -BeTrue -Because "run $Run writes the contract shape"
            }
            ($TopicId -split '/')[8] | Should -BeExactly ($NsId -split '/')[-1] -Because "run $Run gives the namespace one token, in its own id and its topic's"
            if ($Run -eq 1)
            {
                ($NsId -split '/')[-1] | Should -Not -BeIn @($T1, $T2) -Because 'a parent the seed gives two tokens starts again with a new one'
                $Parent = ($NsId -split '/')[-1]
            }
            else { ($NsId -split '/')[-1] | Should -BeExactly $Parent -Because "run $Run keeps run 1's namespace token" }
            $Seed = Get-RunDictionaryMaps
        }
    }

    It 'takes the subscription and group tokens of the seeded ids over a map entry that disagrees' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $Sub = New-Tok; $Rg = New-Tok
        Invoke-SeededRun -SeedMaps @{
            ResourceIdMap       = @{ "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/$(New-Tok)" = $Vm }
            SubscriptionNameMap = @{ (New-Tok) = 'Demo Subscription' }
            ResourceGroupMap    = @{ (New-Tok) = $Vm }
        } -Rows @((New-Res $Vm), (New-Res "$script:Base/microsoft.compute/disks/disk-a"))
        ($Global:ResourceIdDictionary["$script:Base/microsoft.compute/disks/disk-a"] -split '/')[2] | Should -BeExactly $Sub
        ($Global:ResourceIdDictionary["$script:Base/microsoft.compute/disks/disk-a"] -split '/')[4] | Should -BeExactly $Rg
    }

    It 'gives a subscription whose seeded ids hold two tokens one token again, and the next seeded run keeps every id' {
        $A = "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $B = "$script:Base/microsoft.compute/virtualmachines/vm-b"
        $Rg = New-Tok
        $SeedIds = @{}
        $SeedIds["/subscriptions/$(New-Tok)/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/$(New-Tok)"] = $A
        $SeedIds["/subscriptions/$(New-Tok)/resourcegroups/$Rg/providers/microsoft.compute/virtualmachines/$(New-Tok)"] = $B
        $Seed1 = @{ ResourceIdMap = $SeedIds }
        Invoke-SeededRun -SeedMaps $Seed1 -Rows @((New-Res $A), (New-Res $B))
        $Run1 = @{ A = $Global:ResourceIdDictionary[$A]; B = $Global:ResourceIdDictionary[$B] }
        ($Run1.A -split '/')[2] | Should -BeExactly ($Run1.B -split '/')[2] -Because 'one subscription, one token'
        $Seed2 = Get-RunDictionaryMaps
        # Run 2 and run 3, each seeded from the run before: every id kept.
        foreach ($Run in 2, 3)
        {
            Invoke-SeededRun -SeedMaps $Seed2 -Rows @((New-Res $A), (New-Res $B))
            $Global:ResourceIdDictionary[$A] | Should -BeExactly $Run1.A -Because "run $Run keeps run 1's id"
            $Global:ResourceIdDictionary[$B] | Should -BeExactly $Run1.B
            $Seed2 = Get-RunDictionaryMaps
        }
    }

    # A tenant-scope id ('/providers/...') has no resource group: a segment 3
    # 'resourceGroups' in it is a type word, as Test-ObfuscatedIdShape and the seed
    # check read it, so the name after it gets a name token. Given the group token
    # of a real group of that name, the seed check would see one token for two real
    # values and drop it, and the id would change on every seeded run.
    It 'gives the name after a type word resourceGroups in a tenant-scope id a name token, not a real group''s token, and the next two seeded runs keep it' {
        $Vm = "/subscriptions/$script:Sub/resourcegroups/grp-a/providers/microsoft.compute/virtualmachines/vm-a"
        # One held by an inventory row (no group, as Resource Graph gives a tenant-scope row), one by a usage row only.
        $TenInv = '/providers/Microsoft.Example/resourceGroups/grp-a'
        $TenUse = '/providers/Microsoft.Other/resourceGroups/grp-a'
        $Rows = @((New-Res $Vm), [pscustomobject]@{ id = $TenInv; name = 'grp-a'; subscriptionId = ''; resourceGroup = '' })
        $Seed = @{ ResourceIdMap = @{} }
        $First = $null
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun -SeedMaps $Seed -Rows $Rows
            $Ids = Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly
            # The usage row's id, as Protect-RdaUsageRow masks one: the seeded id, else a new one.
            if (-not $Ids.ContainsKey($TenUse)) { $Ids[$TenUse] = Get-ObfuscatedResourceId -ResourceId $TenUse }
            $Now = @{ Vm = $Ids[$Vm]; Inv = $Ids[$TenInv]; Use = $Ids[$TenUse] }
            $GroupToken = ($Now.Vm -split '/')[4]
            foreach ($Pair in @(@($TenInv, $Now.Inv), @($TenUse, $Now.Use)))
            {
                $Parts = $Pair[1] -split '/'
                $Parts.Count | Should -Be 5 -Because "run $Run keeps the id's shape"
                ($Parts[0..3] -join '/') | Should -BeExactly (($Pair[0] -split '/')[0..3] -join '/') -Because 'the provider and type words are kept as written'
                $Parts[4] | Should -Match ('^' + $script:Token + '$')
                $Parts[4] | Should -Not -BeExactly $GroupToken -Because "run $Run gives the name its own token, not the token of the real group grp-a"
                $Parts[4] | Should -BeExactly (Get-Variable -Scope Global -Name ResourceNameDictionary -ValueOnly)[$Pair[0]] -Because 'the name token is recorded, so the dictionary reverses it'
                Test-ObfuscatedIdShape -RealId $Pair[0] -MaskedId $Pair[1] | Should -BeTrue -Because "run $Run writes the shape the seed check keeps"
            }
            # The tenant-scope row has no group: its group field never takes its name token.
            $Groups = Get-Variable -Scope Global -Name ResourceResourceGroupDictionary -ValueOnly
            $Groups[$TenInv] | Should -Not -BeExactly ($Now.Inv -split '/')[4] -Because "run $Run reads a group token only from a subscription id's group slot"
            $Groups[$TenInv] | Should -Not -BeExactly $GroupToken
            if ($Run -eq 1) { $First = $Now }
            else
            {
                foreach ($K in 'Vm', 'Inv', 'Use') { $Now[$K] | Should -BeExactly $First[$K] -Because "run $Run keeps run 1's id ($K), letter for letter" }
            }
            $Seed = Get-RunDictionaryMaps
        }
    }

    # An older build read a segment 3 'resourceGroups' in a tenant-scope id as a
    # group slot, so its dictionary gives '/providers/<ns>/resourceGroups/grp-a'
    # the token of the real group grp-a. That token then has two real values, a
    # group and a tenant-scope name: only the tenant-scope id is dropped (its name
    # gets a new token), and every seeded id of the group keeps its tokens, in the
    # first seeded run and the next.
    It 'keeps the group token an older dictionary also gave the name after a type word resourceGroups in a tenant-scope id, drops only that id, and the next seeded run keeps both' {
        $Vm = "/subscriptions/$script:Sub/resourcegroups/grp-a/providers/microsoft.compute/virtualmachines/vm-a"
        $Disk = "/subscriptions/$script:Sub/resourcegroups/grp-a/providers/microsoft.compute/disks/disk-a"
        $Ten = '/providers/Microsoft.Example/resourceGroups/grp-a'
        $SubTok = New-Tok; $Grp = New-Tok; $VmTok = New-Tok; $DiskTok = New-Tok
        $Older = @{
            Vm   = "/subscriptions/$SubTok/resourcegroups/$Grp/providers/microsoft.compute/virtualmachines/$VmTok"
            Disk = "/subscriptions/$SubTok/resourcegroups/$Grp/providers/microsoft.compute/disks/$DiskTok"
            Ten  = "/providers/Microsoft.Example/resourceGroups/$Grp"
        }
        $Seed = @{
            ResourceIdMap    = @{ $Older.Vm = $Vm; $Older.Disk = $Disk; $Older.Ten = $Ten }
            ResourceNameMap  = @{ $VmTok = $Vm; $DiskTok = $Disk; $Grp = $Ten }
            ResourceGroupMap = @{ $Grp = $Vm }
            SubscriptionMap  = @{ $SubTok = $Vm }
        }
        # The run meets the VM and the tenant-scope row; the disk is a seeded id it does not see.
        $Rows = @((New-Res $Vm), [pscustomobject]@{ id = $Ten; name = 'grp-a'; subscriptionId = ''; resourceGroup = '' })
        $First = $null
        foreach ($Run in 1, 2)
        {
            Invoke-SeededRun -SeedMaps $Seed -Rows $Rows
            $Ids = Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly
            $Now = @{ Vm = $Ids[$Vm]; Disk = $Ids[$Disk]; Ten = $Ids[$Ten] }
            $Now.Vm | Should -BeExactly $Older.Vm -Because "run $Run keeps the VM's seeded id, its group token included"
            $Now.Disk | Should -BeExactly $Older.Disk -Because "run $Run keeps every seeded id of the group"
            $TenParts = $Now.Ten -split '/'
            $TenParts.Count | Should -Be 5 -Because "run $Run keeps the tenant-scope id's shape"
            ($TenParts[0..3] -join '/') | Should -BeExactly '/providers/Microsoft.Example/resourceGroups'
            $TenParts[4] | Should -Match ('^' + $script:Token + '$')
            $TenParts[4] | Should -Not -BeExactly $Grp -Because "run $Run gives the tenant-scope name its own token, not the group's"
            if ($Run -eq 1) { $First = $Now }
            else
            {
                foreach ($K in 'Vm', 'Disk', 'Ten') { $Now[$K] | Should -BeExactly $First[$K] -Because "run 2 keeps run 1's id ($K), letter for letter" }
            }
            $Seed = Get-RunDictionaryMaps
        }
    }

    # The seed's ResourceGroupMap maps each group token to one id. A run gives a
    # tenant-scope row ('/providers/...') a group token of its own, mapped to
    # its id, and a 'resourceGroups' segment there is a type word: only a
    # subscription id's group slot names a group, as Get-ObfuscatedResourceId
    # and the seed check read it. So a group that is new in the seeded run gets
    # its own token, not that row's.
    It 'gives a new group in a seeded run its own token when the seed''s ResourceGroupMap names it only as <Case>' -ForEach @(
        @{ Case = 'the name after a type word resourceGroups in a tenant-scope id'; Value = '/providers/Microsoft.Example/resourceGroups/grp-a'; Reused = $false }
        @{ Case = 'a subscription id''s group (the seed''s token is kept)'; Value = "/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/grp-a/providers/microsoft.compute/virtualmachines/vm-old"; Reused = $true }
    ) {
        $Vm = "/subscriptions/$script:Sub/resourcegroups/grp-a/providers/microsoft.compute/virtualmachines/vm-new"
        $Tok = New-Tok
        Invoke-SeededRun -SeedMaps @{ ResourceIdMap = @{}; ResourceGroupMap = @{ $Tok = $Value } } -Rows @(New-Res $Vm)
        $Group = ((Get-Variable -Scope Global -Name ResourceIdDictionary -ValueOnly)[$Vm] -split '/')[4]
        $Group | Should -Match ('^' + $script:Token + '$')
        if ($Reused) { $Group | Should -BeExactly $Tok -Because 'the seed names the real group grp-a' }
        else { $Group | Should -Not -BeExactly $Tok -Because 'the seed names no group grp-a, only a tenant-scope id''s type word and name' }
    }
}

Describe 'The seed''s parent tokens' {
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Vars = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Variables' }, $false)
        . ([scriptblock]::Create("function Invoke-RunVariables5 { `$Obfuscate = [switch]`$true; $($Vars.Body.Extent.Text.Substring(1, $Vars.Body.Extent.Text.Length - 2)) }"))
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        $Build = @($Setup.Body.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Extent.Text -match 'foreach \(\$resourceItem in \$(Global:Resources|TokenLoopRows)\)|Add-RdaObfuscationToken -Rows \$TokenLoopRows' }, $true))
        . ([scriptblock]::Create("function Invoke-SeededBuild5 { param(`$Seed) `$Obfuscate = [switch]`$true; `$ObfuscationDictionary = `$Seed; function Write-Log { }; $($Build[0].Extent.Text) }"))
        function GetLocalVersion { '0.0.0-test' }
        $script:SeedDir5 = Join-Path ([System.IO.Path]::GetTempPath()) ('rda-seed5-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:SeedDir5 -Force | Out-Null
        function New-Tok5 { 'prod_' + [guid]::NewGuid().ToString() }
        function Invoke-SeededRun5
        {
            param([hashtable]$SeedMaps, [object[]]$Rows)
            $Path = Join-Path $script:SeedDir5 ('seed-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
            $SeedMaps | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
            Invoke-RunVariables5
            $Global:Subscriptions = @([pscustomobject]@{ id = $script:Sub; name = 'Demo Subscription' })
            $Global:ObfuscationSubscriptionIndex = $null
            $Global:Resources = @($Rows)
            Invoke-SeededBuild5 -Seed $Path
        }
        $Writer = @($Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.IfStatementAst] -and $N.Clauses[0].Item1.Extent.Text -eq '$Obfuscate.IsPresent' -and $N.Clauses[0].Item2.Extent.Text -match '\$Global:DictionaryFile = ' }, $false))
        . ([scriptblock]::Create("function Invoke-DictionaryWriter5 { param(`$DefaultPath) `$Obfuscate = [switch]`$true; `$CurrentDateTime = 'test'; function Write-Log { }; $($Writer[0].Extent.Text) }"))
        function Get-RunMaps5
        {
            $Dir = Join-Path $script:SeedDir5 ([guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $Global:ReportName = 'ResourcesReport'
            Invoke-DictionaryWriter5 -DefaultPath ($Dir + [System.IO.Path]::DirectorySeparatorChar)
            Get-Content -LiteralPath (Get-ChildItem -LiteralPath $Dir -Filter 'ObfuscationDictionary_*.json').FullName -Raw | ConvertFrom-Json -AsHashtable
        }
        function New-Res5 { param([string]$Id) [pscustomobject]@{ id = $Id; name = ($Id -split '/')[-1]; subscriptionId = $script:Sub; resourceGroup = ($Id -split '/')[4] } }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SeedDir5 -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Global -Name TagValueDictionary, FreeTextDictionary, ResourceCount, ResourceContainers, ReportName, Version, RawRepo, TableStyle -ErrorAction SilentlyContinue
    }

    It 'gives a parent that the seeded ids give two tokens one token, and keeps it for the next two seeded runs' {
        $Srv = "$script:Base/microsoft.sql/servers/srv-a"
        $Db1 = "$Srv/databases/db-1"; $Db2 = "$Srv/databases/db-2"; $Db3 = "$Srv/databases/db-3"
        $Sub = New-Tok5; $Rg = New-Tok5; $SrvTok = New-Tok5
        $P = "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers"
        $Seed = @{
            ResourceIdMap   = @{ "$P/$SrvTok" = $Srv; "$P/$SrvTok/databases/$(New-Tok5)" = $Db1; "$P/$(New-Tok5)/databases/$(New-Tok5)" = $Db2 }
            ResourceNameMap = @{ (New-Tok5) = $Srv }
        }
        $Rows = @((New-Res5 $Srv), (New-Res5 $Db1), (New-Res5 $Db2), (New-Res5 $Db3))
        $Parent = $null
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun5 -SeedMaps $Seed -Rows $Rows
            $Tokens = @($Srv, $Db1, $Db2, $Db3 | ForEach-Object { ($Global:ResourceIdDictionary[$_] -split '/')[8] } | Select-Object -Unique)
            $Tokens.Count | Should -Be 1 -Because "run $Run gives the server one token in every id"
            ($Global:ResourceIdDictionary[$Srv] -split '/')[-1] | Should -BeExactly $Tokens[0]
            if ($Run -eq 1) { $Parent = $Tokens[0] } else { $Tokens[0] | Should -BeExactly $Parent -Because "run $Run keeps run 1's server token" }
            $Seed = Get-RunMaps5
        }
    }

    It 'gives a new child the parent token of the seeded ids, over a name map entry that disagrees' {
        $Srv = "$script:Base/microsoft.sql/servers/srv-b"
        $Sub = New-Tok5; $Rg = New-Tok5; $SrvTok = New-Tok5
        Invoke-SeededRun5 -SeedMaps @{
            ResourceIdMap   = @{ "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers/$SrvTok" = $Srv }
            ResourceNameMap = @{ (New-Tok5) = $Srv }
        } -Rows @((New-Res5 $Srv), (New-Res5 "$Srv/databases/db-new"))
        ($Global:ResourceIdDictionary["$Srv/databases/db-new"] -split '/')[8] | Should -BeExactly $SrvTok
    }

    It 'gives a parent with no seeded id of its own the token its kept child holds, in its own id and every id under it' {
        $Srv = "$script:Base/microsoft.sql/servers/srv-c"
        $Db = "$Srv/databases/db-a"; $Pool = "$Srv/elasticpools/pool-a"
        $Sub = New-Tok5; $Rg = New-Tok5; $SrvTok = New-Tok5
        Invoke-SeededRun5 -SeedMaps @{
            ResourceIdMap = @{ "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers/$SrvTok/databases/$(New-Tok5)" = $Db }
        } -Rows @((New-Res5 $Srv), (New-Res5 $Db), (New-Res5 $Pool))
        ($Global:ResourceIdDictionary[$Db] -split '/')[8] | Should -BeExactly $SrvTok -Because 'the seeded child id is kept'
        ($Global:ResourceIdDictionary[$Srv] -split '/')[-1] | Should -BeExactly $SrvTok -Because 'the server takes the token its child already holds'
        $Global:ResourceNameDictionary[$Srv] | Should -BeExactly $SrvTok
        ($Global:ResourceIdDictionary[$Pool] -split '/')[8] | Should -BeExactly $SrvTok -Because 'one server path has one masked form'
    }

    It 'gives two parents that the seed gives one token two tokens, and keeps them apart for the next two seeded runs' {
        $SrvA = "$script:Base/microsoft.sql/servers/srv-x"; $SrvB = "$script:Base/microsoft.sql/servers/srv-y"
        $DbA = "$SrvA/databases/db-1"; $DbB = "$SrvB/databases/db-1"
        $Sub = New-Tok5; $Rg = New-Tok5; $Shared = New-Tok5
        $P = "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers/$Shared/databases"
        $Seed = @{ ResourceIdMap = @{ "$P/$(New-Tok5)" = $DbA; "$P/$(New-Tok5)" = $DbB } }
        $Rows = @((New-Res5 $SrvA), (New-Res5 $SrvB), (New-Res5 $DbA), (New-Res5 $DbB))
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun5 -SeedMaps $Seed -Rows $Rows
            $Global:ResourceIdDictionary[$SrvA] | Should -Not -BeExactly $Global:ResourceIdDictionary[$SrvB] -Because "run $Run keeps the two servers apart"
            ($Global:ResourceIdDictionary[$DbA] -split '/')[8] | Should -BeExactly ($Global:ResourceIdDictionary[$SrvA] -split '/')[-1]
            ($Global:ResourceIdDictionary[$DbB] -split '/')[8] | Should -BeExactly ($Global:ResourceIdDictionary[$SrvB] -split '/')[-1]
            @($Global:ResourceIdDictionary.Values | Select-Object -Unique).Count | Should -Be @($Global:ResourceIdDictionary.Keys).Count -Because "run $Run gives no two resources one masked id"
            $Seed = Get-RunMaps5
        }
    }

    It 'does not give a name map token to a resource when a seeded id holds that token for another parent' {
        $SrvA = "$script:Base/microsoft.sql/servers/srv-p"; $SrvB = "$script:Base/microsoft.sql/servers/srv-q"
        $Sub = New-Tok5; $Rg = New-Tok5; $Shared = New-Tok5
        Invoke-SeededRun5 -SeedMaps @{
            ResourceIdMap   = @{ "/subscriptions/$Sub/resourcegroups/$Rg/providers/microsoft.sql/servers/$Shared/databases/$(New-Tok5)" = "$SrvA/databases/db-1" }
            ResourceNameMap = @{ $Shared = $SrvB }
        } -Rows @((New-Res5 $SrvA), (New-Res5 $SrvB), (New-Res5 "$SrvA/databases/db-1"))
        $Global:ResourceIdDictionary[$SrvA] | Should -Not -BeExactly $Global:ResourceIdDictionary[$SrvB]
        $Global:ResourceNameDictionary[$SrvA] | Should -Not -BeExactly $Global:ResourceNameDictionary[$SrvB]
    }

    It 'does not keep a token the seed gives both a subscription and a resource group, for the next two seeded runs' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-t"
        $T = New-Tok5
        $Seed = @{ ResourceIdMap = @{ "/subscriptions/$T/resourcegroups/$T/providers/microsoft.compute/virtualmachines/$(New-Tok5)" = $Vm } }
        foreach ($Run in 1, 2, 3)
        {
            Invoke-SeededRun5 -SeedMaps $Seed -Rows @((New-Res5 $Vm))
            $Parts = $Global:ResourceIdDictionary[$Vm] -split '/'
            $Parts[2] | Should -Not -BeExactly $Parts[4] -Because "run $Run gives the subscription and the group their own tokens"
            $Seed = Get-RunMaps5
        }
    }

    It 'keeps the one name token a SQL VM and its VM share (their ids differ only in the provider)' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-sql"
        $SqlVm = "$script:Base/microsoft.sqlvirtualmachine/sqlvirtualmachines/vm-sql"
        $Sub = New-Tok5; $Rg = New-Tok5; $Name = New-Tok5
        $P = "/subscriptions/$Sub/resourcegroups/$Rg/providers"
        Invoke-SeededRun5 -SeedMaps @{ ResourceIdMap = @{ "$P/microsoft.compute/virtualmachines/$Name" = $Vm; "$P/microsoft.sqlvirtualmachine/sqlvirtualmachines/$Name" = $SqlVm } } -Rows @((New-Res5 $Vm), (New-Res5 $SqlVm))
        $Global:ResourceIdDictionary[$Vm] | Should -BeExactly "$P/microsoft.compute/virtualmachines/$Name"
        $Global:ResourceIdDictionary[$SqlVm] | Should -BeExactly "$P/microsoft.sqlvirtualmachine/sqlvirtualmachines/$Name"
    }

    It 'keeps a seeded name map token for a resource whose seeded id is not kept' {
        $Vm = "$script:Base/microsoft.compute/virtualmachines/vm-n"
        $NameTok = New-Tok5
        Invoke-SeededRun5 -SeedMaps @{ ResourceIdMap = @{ (New-Tok5) = $Vm }; ResourceNameMap = @{ $NameTok = $Vm } } -Rows @((New-Res5 $Vm))
        $Global:ResourceNameDictionary[$Vm] | Should -BeExactly $NameTok
        ($Global:ResourceIdDictionary[$Vm] -split '/')[-1] | Should -BeExactly $NameTok
    }
}

Describe 'The seed check frees what it built' {
    It 'sets <_> to null in the seeded branch, after it is last read and before the token loop' -ForEach @('SeedSlotsOf', 'SeedSlotTokens', 'SeedDictionary', 'SeedFlatIds') {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Setup = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'RunInventorySetup' }, $true)
        # The token loop: inline, or the call of Add-RdaObfuscationToken that runs it.
        $Loop = $Setup.Find({ param($N) ($N -is [System.Management.Automation.Language.ForEachStatementAst] -and $N.Condition.Extent.Text -match '^\$(TokenLoopRows|Global:Resources)$' -and $N.Body.Extent.Text -match 'IdsToMask\.Contains\(\$resourceItem\.ID\)') -or ($N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Add-RdaObfuscationToken') }, $true)
        $Loop | Should -Not -BeNullOrEmpty
        $Name = $_
        $Nulls = @($Setup.FindAll({ param($N) $N -is [System.Management.Automation.Language.AssignmentStatementAst] -and $N.Left.Extent.Text -eq ('$' + $Name) -and $N.Right.Extent.Text -eq '$null' }, $true))
        $Nulls.Count | Should -Be 1
        $Null0 = $Nulls[0]
        # Inside an 'if' on the seed, as a statement that runs (not a comment).
        $If = $Null0.Parent
        while ($null -ne $If -and -not ($If -is [System.Management.Automation.Language.IfStatementAst] -and $If.Clauses[0].Item1.Extent.Text -match 'ObfuscationDictionary')) { $If = $If.Parent }
        $If | Should -Not -BeNullOrEmpty
        $Null0.Extent.StartOffset | Should -BeLessThan $Loop.Extent.StartOffset
        $Reads = @($Setup.FindAll({ param($N) $N -is [System.Management.Automation.Language.VariableExpressionAst] -and $N.VariablePath.UserPath -eq $Name -and $N.Extent.StartOffset -gt $Null0.Extent.EndOffset }, $true))
        $Reads | Should -BeNullOrEmpty -Because "$Name is not read after it is freed"
    }
}

Describe 'Test-ObfuscatedIdShape' {
    BeforeAll {
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
        $Fn = $Ast.Find({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'Test-ObfuscatedIdShape' }, $false)
        if ($null -ne $Fn) { . ([scriptblock]::Create($Fn.Extent.Text)) }
        $script:T = 'prod_0f0e0d0c-0b0a-4908-8706-050403020100'
    }

    It 'takes what Get-ObfuscatedResourceId writes, a $system name masked and a tenant-scope id' {
        Reset-ObfuscationState
        $Real = "$script:Base/microsoft.sql/servers/srv-a/databases/db-a"
        Test-ObfuscatedIdShape -RealId $Real -MaskedId (Get-ObfuscatedResourceId -ResourceId $Real) | Should -BeTrue
        Test-ObfuscatedIdShape -RealId "$script:Base/microsoft.servicebus/namespaces/`$system" -MaskedId "/subscriptions/$script:T/resourcegroups/$script:T/providers/microsoft.servicebus/namespaces/$script:T" | Should -BeTrue
        Test-ObfuscatedIdShape -RealId "$script:Base/microsoft.servicebus/namespaces/`$system" -MaskedId "/subscriptions/$script:T/resourcegroups/$script:T/providers/microsoft.servicebus/namespaces/`$system" | Should -BeFalse -Because 'a kept $system is a name part left as written'
        Test-ObfuscatedIdShape -RealId '/providers/Microsoft.Capacity/reservationOrders/ro-a' -MaskedId "/providers/Microsoft.Capacity/reservationOrders/$script:T" | Should -BeTrue
    }

    It 'refuses <Label>' -ForEach @(
        @{ Label = 'a real parent name left'; Masked = '/subscriptions/{0}/resourcegroups/{0}/providers/microsoft.sql/servers/srv-a/databases/{0}' }
        @{ Label = 'a flat token'; Masked = '{0}' }
        @{ Label = 'another type'; Masked = '/subscriptions/{0}/resourcegroups/{0}/providers/microsoft.sql/servers/{0}/elasticpools/{0}' }
        @{ Label = 'a real resource group'; Masked = '/subscriptions/{0}/resourcegroups/rg-demo/providers/microsoft.sql/servers/{0}/databases/{0}' }
        @{ Label = 'the metric step''s old sub_ and rg_ tokens'; Masked = '/subscriptions/prod_sub_0f0e0d0c-0b0a-4908-8706-050403020100/resourcegroups/prod_rg_0f0e0d0c-0b0a-4908-8706-050403020100/providers/microsoft.sql/servers/{0}/databases/{0}' }
        @{ Label = 'a word in a name token'; Masked = '/subscriptions/{0}/resourcegroups/{0}/providers/microsoft.sql/servers/prod_secret_0f0e0d0c-0b0a-4908-8706-050403020100/databases/{0}' }
    ) {
        Test-ObfuscatedIdShape -RealId "$script:Base/microsoft.sql/servers/srv-a/databases/db-a" -MaskedId ($Masked -f $script:T) | Should -BeFalse
    }

    It 'refuses a <Slot> slot that holds its real part, which looks like a token (<Case>)' -ForEach @(
        @{ Slot = 'subscription'; Case = 'same case'; Index = 2; Upper = $false }
        @{ Slot = 'resource group'; Case = 'same case'; Index = 4; Upper = $false }
        @{ Slot = 'parent name'; Case = 'same case'; Index = 8; Upper = $false }
        @{ Slot = 'name'; Case = 'same case'; Index = 10; Upper = $false }
        @{ Slot = 'resource group'; Case = 'the real part in upper case'; Index = 4; Upper = $true }
        @{ Slot = 'name'; Case = 'the real part in upper case'; Index = 10; Upper = $true }
    ) {
        $Tok = { 'prod_' + [guid]::NewGuid().ToString() }
        $Masked = @('', 'subscriptions', (& $Tok), 'resourcegroups', (& $Tok), 'providers', 'microsoft.sql', 'servers', (& $Tok), 'databases', (& $Tok))
        $Real = @('', 'subscriptions', $script:Sub, 'resourcegroups', 'rg-demo', 'providers', 'microsoft.sql', 'servers', 'srv-a', 'databases', 'db-a')
        $Real[$Index] = if ($Upper) { $Masked[$Index].ToUpperInvariant() } else { $Masked[$Index] }
        Test-ObfuscatedIdShape -RealId ($Real -join '/') -MaskedId ($Masked -join '/') | Should -BeFalse -Because 'a masked slot never keeps its real part'
        $Real[$Index] = & $Tok
        Test-ObfuscatedIdShape -RealId ($Real -join '/') -MaskedId ($Masked -join '/') | Should -BeTrue -Because 'a real part that only looks like a token is masked by another one'
    }

    It 'refuses a tenant-scope name slot that holds its real part' {
        $Tok = 'prod_' + [guid]::NewGuid().ToString()
        Test-ObfuscatedIdShape -RealId "/providers/Microsoft.Capacity/reservationOrders/$Tok" -MaskedId "/providers/Microsoft.Capacity/reservationOrders/$Tok" | Should -BeFalse
    }
}

Describe 'A tenant-scope id keeps its shape (it has no subscription)' {
    BeforeEach { Reset-ObfuscationState }

    It 'masks a <Label> id to its own path with a token as the name' -ForEach @(
        @{ Label = 'reservation order'; Id = '/providers/Microsoft.Capacity/reservationOrders/ro-a'; Prefix = '/providers/Microsoft.Capacity/reservationOrders/' }
        @{ Label = 'management group'; Id = '/providers/Microsoft.Management/managementGroups/mg-a'; Prefix = '/providers/Microsoft.Management/managementGroups/' }
    ) {
        $Masked = Get-ObfuscatedResourceId -ResourceId $Id
        $Masked | Should -Match ('^' + [regex]::Escape($Prefix) + $script:Token + '$')
        $Masked | Should -Not -Match '/subscriptions/'
        $Masked | Should -Not -Match 'ro-a|mg-a'
    }

    It 'gives every name of a tenant-scope reservation id a token and keeps its types' {
        $Masked = Get-ObfuscatedResourceId -ResourceId '/providers/Microsoft.Capacity/reservationOrders/ro-a/reservations/res-a'
        $Parts = $Masked -split '/'
        $Parts.Count | Should -Be 7
        $Parts[1] | Should -BeExactly 'providers'
        $Parts[2] | Should -BeExactly 'Microsoft.Capacity'
        $Parts[3] | Should -BeExactly 'reservationOrders'
        $Parts[4] | Should -Match ('^' + $script:Token + '$')
        $Parts[5] | Should -BeExactly 'reservations'
        $Parts[6] | Should -Match ('^' + $script:Token + '$')
        # Reservation rows are found by their path segments: the order part of the
        # reservation's masked id is the masked id of the order itself.
        $Order = Get-ObfuscatedResourceId -ResourceId '/providers/Microsoft.Capacity/reservationOrders/ro-a'
        (($Parts[0..4]) -join '/') | Should -BeExactly $Order
    }

    It 'gives the same masked id to the same tenant-scope id on a second call' {
        $Id = '/providers/Microsoft.Capacity/reservationOrders/ro-a'
        $First = Get-ObfuscatedResourceId -ResourceId $Id
        $Second = Get-ObfuscatedResourceId -ResourceId $Id
        $Second | Should -BeExactly $First
    }

    It 'keeps the /subscriptions/ start on an id that has a subscription' {
        $Masked = Get-ObfuscatedResourceId -ResourceId "$script:Base/microsoft.compute/virtualmachines/vm-a"
        $Masked | Should -Match '^/subscriptions/'
    }
}
