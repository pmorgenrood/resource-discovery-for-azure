#Requires -Version 7.2
# Pester 5 tests for the preflight of Invoke-RdaBeforeAfter.ps1: PowerShell version,
# Az modules (offer to install), Azure CLI (never installed, offer to sign in),
# Reader check, and -PreflightOnly. Install-Module, az and the Azure calls are mocked:
# nothing is installed, no sign-in happens, and no real az is needed.
# Run: pwsh -NoProfile -NonInteractive -Command "Invoke-Pester -Path ./Tests/Invoke-RdaPreflight.Tests.ps1 -Output Detailed"

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Customer = Join-Path $Root 'Invoke-RdaBeforeAfter.ps1'
    $script:T = '22222222-2222-2222-2222-222222222222'
    $script:S = '33333333-3333-3333-3333-333333333333'

    # Stand-ins so Pester can mock Az.Resources cmdlets on a host without that module.
    if (-not (Get-Command Get-AzRoleAssignment -ErrorAction SilentlyContinue))
    {
        function global:Get-AzRoleAssignment { param($Scope, $ObjectId) $null = $Scope, $ObjectId }
        $script:MadeRoleStub = $true
    }
    if (-not (Get-Command Get-AzRoleDefinition -ErrorAction SilentlyContinue))
    {
        function global:Get-AzRoleDefinition { param($Id, $Scope) $null = $Id, $Scope }
        $script:MadeDefStub = $true
    }

    . $script:Customer

    # Runs a block; returns its objects and the host text it printed.
    function Invoke-Captured([scriptblock]$Block)
    {
        $All = @(& $Block 6>&1)
        $Text = (@($All | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }) | ForEach-Object { [string]$_.MessageData }) -join "`n"
        $Objs = @($All | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        return [pscustomobject]@{ Result = $(if ($Objs.Count -eq 1) { $Objs[0] } else { $Objs }); Text = $Text }
    }

    # Fake module table: name -> installed version (or absent); loaded versions apart.
    function Use-FakeModule([hashtable]$Installed, [hashtable]$Loaded = @{})
    {
        $script:FakeInstalled = $Installed.Clone()
        $script:FakeLoaded = $Loaded.Clone()
    }
    function Get-FakeJwt([string]$Oid)
    {
        $Enc = { param($O) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($O | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        return ('{0}.{1}.sig' -f (& $Enc @{ alg = 'none' }), (& $Enc @{ oid = $Oid; tid = $script:T }))
    }
    $script:AllOk = @{ 'Az.Accounts' = '5.5.4'; 'Az.Compute' = '9.0.0'; 'Az.Monitor' = '6.0.0'; 'Az.Billing' = '2.1.0' }
}

AfterAll {
    if ($script:MadeRoleStub) { Remove-Item function:global:Get-AzRoleAssignment -ErrorAction SilentlyContinue }
    if ($script:MadeDefStub) { Remove-Item function:global:Get-AzRoleDefinition -ErrorAction SilentlyContinue }
}

Describe 'PowerShell version' {
    It 'says nothing for PowerShell 7.2 and newer' {
        @(Get-RdaPowerShellAdvice -Version '7.2' -Os 'Linux').Count | Should -Be 0
        @(Get-RdaPowerShellAdvice -Version '7.4' -Os 'Windows').Count | Should -Be 0
    }
    It 'gives the winget command and the Windows link for Windows PowerShell 5.1' {
        $T = (Get-RdaPowerShellAdvice -Version '5.1' -Os 'Windows') -join "`n"
        $T | Should -Match 'needs PowerShell 7\.2 or newer\. This is PowerShell 5\.1'
        $T | Should -Match 'Windows PowerShell 5\.1 is too old'
        $T | Should -Match 'winget install --id Microsoft\.PowerShell --source winget'
        $T | Should -Match 'installing-powershell-on-windows'
    }
    It 'gives brew for macOS and the Linux link for Linux, for 7.1' {
        ((Get-RdaPowerShellAdvice -Version '7.1' -Os 'macOS') -join "`n") | Should -Match 'brew install --cask powershell'
        $L = (Get-RdaPowerShellAdvice -Version '7.1' -Os 'Linux') -join "`n"
        $L | Should -Match 'installing-powershell-on-linux'
        $L | Should -Not -Match 'winget|brew'
    }
    It 'checks the version in the script before strict mode, with no #Requires line' {
        $Text = Get-Content -LiteralPath $script:Customer -Raw
        $Text | Should -Not -Match '(?m)^#Requires'
        $Text.IndexOf('if ($script:ThisPowerShell -lt $script:MinimumPowerShell)') | Should -BeGreaterThan 0
        $Text.IndexOf('if ($script:ThisPowerShell -lt $script:MinimumPowerShell)') | Should -BeLessThan $Text.IndexOf('Set-StrictMode -Version 3.0')
    }
}

Describe 'Questions' {
    It 'is not interactive in a -NonInteractive host (this test host)' {
        Test-RdaInteractiveHost | Should -BeFalse
    }
    It 'takes Y after unclear answers, and stops at No after 3 unclear answers' {
        $script:Answers = [System.Collections.Generic.Queue[string]]::new([string[]]@('maybe', ' y '))
        Mock Read-Host { $script:Answers.Dequeue() }
        (Invoke-Captured { Read-RdaYesNo -Question 'Q?' }).Result | Should -BeTrue
        $script:Answers = [System.Collections.Generic.Queue[string]]::new([string[]]@('a', 'b', 'c', 'y'))
        (Invoke-Captured { Read-RdaYesNo -Question 'Q?' }).Result | Should -BeFalse
        Should -Invoke Read-Host -Times 5 -Exactly
    }
}

Describe 'Az modules' {
    BeforeEach {
        # Install-Module is mocked before Get-Module: Pester finds a command to mock
        # through Get-Module, so the Get-Module mock must come last.
        # A good install puts the asked-for version in the fake table.
        Mock Install-Module { $V = if ($MinimumVersion) { [string]$MinimumVersion } else { '1.0.0' }; $script:FakeInstalled[@($Name)[0]] = $V }
        Mock Get-Module -ParameterFilter { $ListAvailable } {
            $N = @($Name)[0]
            if ($script:FakeInstalled.ContainsKey($N)) { [pscustomobject]@{ Name = $N; Version = [version]$script:FakeInstalled[$N] } }
        }
        Mock Get-Module -ParameterFilter { -not $ListAvailable } {
            $N = @($Name)[0]
            if ($script:FakeLoaded.ContainsKey($N)) { [pscustomobject]@{ Name = $N; Version = [version]$script:FakeLoaded[$N] } }
        }
        Mock Test-RdaInteractiveHost { $true }
    }

    It 'passes with every module present, and installs nothing' {
        Use-FakeModule $script:AllOk
        $R = Invoke-Captured { Invoke-RdaAzModuleCheck }
        $R.Result.Ok | Should -BeTrue
        Should -Invoke Install-Module -Times 0 -Exactly
    }

    It 'asks, and on Y installs a missing module for this user only, then checks again' {
        $M = $script:AllOk.Clone(); $M.Remove('Az.Monitor'); Use-FakeModule $M
        Mock Read-RdaYesNo { $true }
        $R = Invoke-Captured { Invoke-RdaAzModuleCheck }
        $R.Result.Ok | Should -BeTrue
        Should -Invoke Read-RdaYesNo -Times 1 -Exactly -ParameterFilter { $Question -eq 'Install/update them now for your user only?' }
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Az.Monitor' -and $Scope -eq 'CurrentUser' -and $Repository -eq 'PSGallery' -and -not $Force -and -not $MinimumVersion }
        $R.Text | Should -Match 'Az\.Monitor is not installed'
        $R.Text | Should -Match 'No admin rights are needed'
    }

    It 'on N installs nothing and stops with the exact command' {
        $M = $script:AllOk.Clone(); $M.Remove('Az.Billing'); Use-FakeModule $M
        Mock Read-RdaYesNo { $false }
        $R = Invoke-Captured { Invoke-RdaAzModuleCheck }
        $R.Result.Ok | Should -BeFalse
        Should -Invoke Install-Module -Times 0 -Exactly
        $R.Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Billing -Scope CurrentUser -Repository PSGallery'))
    }

    It 'never asks in a non-interactive host: stops with the command' {
        $M = $script:AllOk.Clone(); $M.Remove('Az.Compute'); Use-FakeModule $M
        Mock Test-RdaInteractiveHost { $false }
        Mock Read-RdaYesNo { throw 'must not ask' }
        Mock Read-Host { throw 'must not ask' }
        $R = Invoke-Captured { Invoke-RdaAzModuleCheck }
        $R.Result.Ok | Should -BeFalse
        Should -Invoke Read-RdaYesNo -Times 0 -Exactly
        Should -Invoke Install-Module -Times 0 -Exactly
        $R.Text | Should -Match 'non-interactive'
        $R.Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Compute -Scope CurrentUser -Repository PSGallery'))
    }

    It 'updates a too-old Az.Accounts with -MinimumVersion and -Force (side by side), Accounts first' {
        $M = $script:AllOk.Clone(); $M['Az.Accounts'] = '5.1.0'; $M.Remove('Az.Monitor'); Use-FakeModule $M
        $script:Order = [System.Collections.Generic.List[string]]::new()
        Mock Install-Module { $script:Order.Add(@($Name)[0]); $script:FakeInstalled[@($Name)[0]] = $(if ($MinimumVersion) { [string]$MinimumVersion } else { '1.0.0' }) }
        Mock Read-RdaYesNo { $true }
        $R = Invoke-Captured { Invoke-RdaAzModuleCheck }
        $R.Result.Ok | Should -BeTrue
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Az.Accounts' -and $MinimumVersion -eq [version]'5.5.4' -and $Force -and $Scope -eq 'CurrentUser' }
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Az.Monitor' -and -not $Force }
        $script:Order[0] | Should -Be 'Az.Accounts'
        $R.Text | Should -Match 'Az\.Accounts 5\.1\.0 is too old'
    }

    It 'never touches a newer Az.Accounts, and never uses AllUsers' {
        $M = $script:AllOk.Clone(); $M['Az.Accounts'] = '6.0.1'; $M.Remove('Az.Billing'); Use-FakeModule $M
        Mock Read-RdaYesNo { $true }
        $null = Invoke-Captured { Invoke-RdaAzModuleCheck }
        Should -Invoke Install-Module -Times 0 -Exactly -ParameterFilter { $Name -eq 'Az.Accounts' }
        Should -Invoke Install-Module -Times 0 -Exactly -ParameterFilter { $Scope -ne 'CurrentUser' }
        Should -Invoke Install-Module -Times 0 -Exactly -ParameterFilter { $Force }
    }

    It 'stops with the command when the install fails' {
        $M = $script:AllOk.Clone(); $M.Remove('Az.Monitor'); Use-FakeModule $M
        Mock Read-RdaYesNo { $true }
        Mock Install-Module { throw 'No match was found' }
        $R = Invoke-Captured { Invoke-RdaAzModuleCheck }
        $R.Result.Ok | Should -BeFalse
        $R.Text | Should -Match 'Installing Az\.Monitor failed: No match was found'
        $R.Text | Should -Match ([regex]::Escape('Install-Module -Name Az.Monitor -Scope CurrentUser -Repository PSGallery'))
    }

    It 'stops when the check after the install still finds an old module' {
        $M = $script:AllOk.Clone(); $M['Az.Accounts'] = '5.1.0'; Use-FakeModule $M
        Mock Read-RdaYesNo { $true }
        Mock Install-Module { }   # PowerShellGet only warned and added nothing
        $R = Invoke-Captured { Invoke-RdaAzModuleCheck }
        $R.Result.Ok | Should -BeFalse
        $R.Text | Should -Match 'Az\.Accounts is still too old after the install'
    }

    It 'tells the user to open a new window when an old Az.Accounts is loaded' {
        Use-FakeModule $script:AllOk @{ 'Az.Accounts' = '4.0.2' }
        $R = Invoke-Captured { Invoke-RdaAzModuleCheck }
        $R.Result.Ok | Should -BeFalse
        Should -Invoke Install-Module -Times 0 -Exactly
        $R.Text | Should -Match 'Az\.Accounts 4\.0\.2 is already loaded in this PowerShell window'
        $R.Text | Should -Match 'Open a new PowerShell window'
    }

    It 'prints commands with no -Force for a missing module' {
        Get-RdaAzInstallCommand -Row ([pscustomobject]@{ Name = 'Az.Accounts'; Minimum = [version]'5.5.4'; State = 'missing' }) |
            Should -Be 'Install-Module -Name Az.Accounts -Scope CurrentUser -Repository PSGallery -MinimumVersion 5.5.4'
        Get-RdaAzInstallCommand -Row ([pscustomobject]@{ Name = 'Az.Accounts'; Minimum = [version]'5.5.4'; State = 'old' }) |
            Should -Be 'Install-Module -Name Az.Accounts -Scope CurrentUser -Repository PSGallery -MinimumVersion 5.5.4 -Force'
    }
}

Describe 'Azure CLI' {
    BeforeEach {
        Mock Test-RdaCloudShell { $false }
        Mock Test-RdaInteractiveHost { $true }
        Mock Invoke-RdaAz { $script:AzLoginDone = $true; 0 }
        $script:AzLoginDone = $false
    }

    It 'when az is missing, prints the install command for <Os> and installs nothing' -TestCases @(
        @{ Os = 'Windows'; Want = 'winget install --exact --id Microsoft.AzureCLI' }
        @{ Os = 'macOS'; Want = 'brew update && brew install azure-cli' }
        @{ Os = 'Linux'; Want = 'https://learn.microsoft.com/cli/azure/install-azure-cli-linux' }
    ) {
        param($Os, $Want)
        $null = $Os  # used inside the mock below
        Mock Get-RdaOsName { $Os }
        Mock Test-RdaAzCliSignIn { 'missing' }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Side 'Before' }
        $R.Result | Should -BeFalse
        $R.Text | Should -Match 'not installed\. This script does not install it'
        $R.Text | Should -Match ([regex]::Escape($Want))
        Should -Invoke Invoke-RdaAz -Times 0 -Exactly
    }

    It 'when az is not signed in, asks, and on Y runs az login --tenant, then checks again' {
        Mock Test-RdaAzCliSignIn { if ($script:AzLoginDone) { 'ok' } else { 'not-signed-in' } }
        Mock Read-RdaYesNo { $true }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Side 'Before' }
        $R.Result | Should -BeTrue
        Should -Invoke Read-RdaYesNo -Times 1 -Exactly -ParameterFilter { $Question -eq 'Sign in to the Azure CLI now?' }
        Should -Invoke Invoke-RdaAz -Times 1 -Exactly -ParameterFilter { ($Arguments -join ' ') -eq "login --tenant $($script:T) --output none" }
        $R.Text | Should -Match 'Azure CLI is signed in to this tenant'
    }

    It 'adds --use-device-code to az login with -DeviceLogin' {
        Mock Test-RdaAzCliSignIn { if ($script:AzLoginDone) { 'ok' } else { 'not-signed-in' } }
        Mock Read-RdaYesNo { $true }
        $null = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Side 'Before' -UseDeviceCode }
        Should -Invoke Invoke-RdaAz -Times 1 -Exactly -ParameterFilter { $Arguments -contains '--use-device-code' -and $Arguments -contains $script:T }
    }

    It 'on N signs nothing in and stops with the command' {
        Mock Test-RdaAzCliSignIn { 'not-signed-in' }
        Mock Read-RdaYesNo { $false }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Side 'Before' }
        $R.Result | Should -BeFalse
        Should -Invoke Invoke-RdaAz -Times 0 -Exactly
        $R.Text | Should -Match ([regex]::Escape("Run: az login --tenant $($script:T)"))
    }

    It 'never asks in a non-interactive host' {
        Mock Test-RdaAzCliSignIn { 'not-signed-in' }
        Mock Test-RdaInteractiveHost { $false }
        Mock Read-RdaYesNo { throw 'must not ask' }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Side 'Before' }
        $R.Result | Should -BeFalse
        Should -Invoke Read-RdaYesNo -Times 0 -Exactly
        Should -Invoke Invoke-RdaAz -Times 0 -Exactly
        $R.Text | Should -Match 'non-interactive'
    }

    It 'stops when az login did not work' {
        Mock Test-RdaAzCliSignIn { 'not-signed-in' }
        Mock Read-RdaYesNo { $true }
        Mock Invoke-RdaAz { 1 }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Side 'Before' }
        $R.Result | Should -BeFalse
        $R.Text | Should -Match 'still not signed in'
    }

    It 'still checks the active account and the subscription list in Azure Cloud Shell (<State>)' -TestCases @(
        @{ State = 'ok'; Want = $true }
        @{ State = 'no-subscription'; Want = $false }
        @{ State = 'other-tenant'; Want = $false }
    ) {
        param($State, $Want)
        $script:CsState = $State
        Mock Test-RdaCloudShell { $true }
        Mock Test-RdaInteractiveHost { $true }
        Mock Read-RdaYesNo { $false }
        Mock Invoke-RdaAz { 0 }
        Mock Test-RdaAzCliSignIn { $script:CsState }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Subscription $script:S -Side 'Before' }
        $R.Result | Should -Be $Want
        Should -Invoke Test-RdaAzCliSignIn -Times 1 -Exactly -ParameterFilter { $Subscription -eq $script:S }
        $R.Text | Should -Match 'Cloud Shell'
    }
}

Describe 'Azure CLI with a fake az on PATH' -Skip:($IsWindows) {
    BeforeAll {
        $script:Bin = Join-Path $TestDrive 'fakeaz'; New-Item -ItemType Directory $script:Bin -Force | Out-Null
        $script:Log = Join-Path $TestDrive 'az-args.log'; $script:Flag = Join-Path $TestDrive 'az-signed-in'
        $Sh = "#!/bin/sh`necho `"`$*`" >> '$($script:Log)'`ncase `"`$1`" in`n  login) touch '$($script:Flag)'; exit 0 ;;`n  account) [ -f '$($script:Flag)' ] || exit 1; [ `"`$2`" = show ] && echo '$($script:T)'; exit 0 ;;`nesac`nexit 2`n"
        [IO.File]::WriteAllText((Join-Path $script:Bin 'az'), $Sh)
        & chmod +x (Join-Path $script:Bin 'az')
        $script:OldPath = $env:PATH
        $env:PATH = $script:Bin + [IO.Path]::PathSeparator + $script:OldPath
    }
    AfterAll { $env:PATH = $script:OldPath }

    It 'signs the fake az in on Y and finds it signed in after' {
        Mock Test-RdaCloudShell { $false }
        Mock Test-RdaInteractiveHost { $true }
        Mock Read-RdaYesNo { $true }
        Test-RdaAzCliSignIn -Tenant $script:T | Should -Be 'not-signed-in'
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Side 'Before' -UseDeviceCode }
        $R.Result | Should -BeTrue
        $Lines = @(Get-Content -LiteralPath $script:Log)
        $Lines | Should -Contain "account get-access-token --tenant $($script:T) --output none"
        $Lines | Should -Contain "login --tenant $($script:T) --output none --use-device-code"
        Test-RdaAzCliSignIn -Tenant $script:T | Should -Be 'ok'
    }
}

Describe 'Reader check' {
    It 'reads <Case>' -TestCases @(
        @{ Case = 'Owner (*)'; Perm = @(@{ actions = @('*'); notActions = @() }); Want = 'ok' }
        @{ Case = 'Reader (*/read)'; Perm = @(@{ actions = @('*/read'); notActions = @() }); Want = 'ok' }
        @{ Case = 'a role that blocks */read'; Perm = @(@{ actions = @('*'); notActions = @('*/read') }); Want = 'missing' }
        @{ Case = 'all reads but one provider''s'; Perm = @(@{ actions = @('*/read'); notActions = @('Microsoft.Compute/*/read') }); Want = 'partial' }
        @{ Case = 'everything but one provider'; Perm = @(@{ actions = @('*'); notActions = @('Microsoft.Sql/*') }); Want = 'partial' }
        @{ Case = 'one role blocks a provider, another reads all'; Perm = @(@{ actions = @('*'); notActions = @('Microsoft.Sql/*') }, @{ actions = @('*/read'); notActions = @() }); Want = 'ok' }
        @{ Case = 'everything but a write'; Perm = @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/write') }); Want = 'ok' }
        @{ Case = 'only some reads'; Perm = @(@{ actions = @('Microsoft.Compute/*/read'); notActions = @() }); Want = 'partial' }
        @{ Case = 'no reads'; Perm = @(@{ actions = @('Microsoft.Support/*'); notActions = @() }); Want = 'partial' }
        @{ Case = 'nothing'; Perm = @(); Want = 'missing' }
        @{ Case = 'two roles, one full'; Perm = @(@{ actions = @('Microsoft.Compute/*/read') }, @{ actions = @('*/read') }); Want = 'ok' }
    ) {
        param($Case, $Perm, $Want)
        $null = $Case
        $Objs = @($Perm | ForEach-Object { [pscustomobject]$_ })
        Get-RdaReadVerdict -Permission $Objs | Should -Be $Want
    }

    It 'finds Reader from the permissions call' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"actions":["*/read"],"notActions":[]}]}' } }
        (Test-RdaReaderAccess -Subscription $script:S).State | Should -Be 'ok'
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Path -like "/subscriptions/$($script:S)/providers/Microsoft.Authorization/permissions?api-version=*" }
    }

    It 'finds read access clearly missing from the permissions call' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }
        (Test-RdaReaderAccess -Subscription $script:S).State | Should -Be 'missing'
    }

    It 'falls back to Get-AzRoleAssignment and finds Reader' {
        Mock Invoke-AzRestMethod { throw 'network' }
        Mock Get-RdaSignedInObjectId { '44444444-4444-4444-4444-444444444444' }
        Mock Get-AzRoleAssignment { [pscustomobject]@{ RoleDefinitionId = '/subscriptions/x/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7'; RoleDefinitionName = 'Reader' } }
        Mock Get-AzRoleDefinition { [pscustomobject]@{ Name = 'Reader'; Actions = @('*/read'); NotActions = @() } }
        (Test-RdaReaderAccess -Subscription $script:S).State | Should -Be 'ok'
        Should -Invoke Get-AzRoleAssignment -Times 1 -Exactly -ParameterFilter { $Scope -eq "/subscriptions/$($script:S)" -and $ObjectId -eq '44444444-4444-4444-4444-444444444444' }
        Should -Invoke Get-AzRoleDefinition -Times 1 -Exactly -ParameterFilter { $Id -eq 'acdd72a7-3385-48ef-bd42-f606fba81ae7' }
    }

    It 'reads a refused role-assignment read as Reader missing' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 500; Content = '' } }
        Mock Get-RdaSignedInObjectId { '44444444-4444-4444-4444-444444444444' }
        Mock Get-AzRoleAssignment { throw "The client does not have authorization to perform action 'Microsoft.Authorization/roleAssignments/read'" }
        (Test-RdaReaderAccess -Subscription $script:S).State | Should -Be 'missing'
    }

    It 'calls it unknown when no own role is found (it may come from a group)' {
        Mock Invoke-AzRestMethod { throw 'network' }
        Mock Get-RdaSignedInObjectId { '44444444-4444-4444-4444-444444444444' }
        Mock Get-AzRoleAssignment { }
        (Test-RdaReaderAccess -Subscription $script:S).State | Should -Be 'unknown'
    }

    It 'calls it unknown when it cannot be read at all' {
        Mock Invoke-AzRestMethod { throw 'network' }
        Mock Get-Command -ParameterFilter { $Name -eq 'Get-AzRoleAssignment' } { $null }
        (Test-RdaReaderAccess -Subscription $script:S).State | Should -Be 'unknown'
    }

    It 'stops on missing, warns and carries on for <State>' -TestCases @(
        @{ State = 'missing'; Want = $false; Text = 'give you the Reader role' }
        @{ State = 'unknown'; Want = $true; Text = 'could not check your role' }
        @{ State = 'partial'; Want = $true; Text = 'only some kinds of resources' }
        @{ State = 'ok'; Want = $true; Text = 'Reader or higher' }
    ) {
        param($State, $Want, $Text)
        $null = $State  # used inside the mock below
        Mock Test-RdaReaderAccess { [pscustomobject]@{ State = $State; How = 'test' } }
        $R = Invoke-Captured { Invoke-RdaReaderCheck -Subscription $script:S }
        $R.Result | Should -Be $Want
        $R.Text | Should -Match $Text
    }

    It 'reads the object id from a string or a SecureString token' {
        $Jwt = Get-FakeJwt '55555555-5555-5555-5555-555555555555'
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = $Jwt } }
        Get-RdaSignedInObjectId | Should -Be '55555555-5555-5555-5555-555555555555'
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = ([Net.NetworkCredential]::new('', $Jwt).SecurePassword) } }
        Get-RdaSignedInObjectId | Should -Be '55555555-5555-5555-5555-555555555555'
    }
}

Describe 'PreflightOnly, run from inside a clone' {
    BeforeEach {
        # Two local code trees: Before still calls az, After does not.
        $script:Bt = Join-Path $TestDrive ('bt-' + [guid]::NewGuid()); New-Item -ItemType Directory $script:Bt | Out-Null
        Set-Content (Join-Path $script:Bt 'ResourceInventory.ps1') '$x = az account show --output json'
        $script:At = Join-Path $TestDrive ('at-' + [guid]::NewGuid()); New-Item -ItemType Directory $script:At | Out-Null
        Set-Content (Join-Path $script:At 'ResourceInventory.ps1') '# no az here'
        # A clone folder to start from, with its own ResourceInventory.ps1 that must not be used.
        $script:Clone = Join-Path $TestDrive ('clone-' + [guid]::NewGuid()); New-Item -ItemType Directory $script:Clone | Out-Null
        Set-Content (Join-Path $script:Clone 'ResourceInventory.ps1') 'throw "the clone code must not run"'
        Mock Invoke-RdaAzModuleCheck { [pscustomobject]@{ Ok = $true; Modules = @() } }
        Mock Import-Module { }
        Mock Invoke-RdaAzCliCheck { $true }
        Mock Connect-RdaOnce { $true }
        Mock Get-AzSubscription { [pscustomobject]@{ State = 'Enabled' } }
        Mock Invoke-RdaReaderCheck { $true }
        Mock Invoke-RdaAzCliReaderCheck { $true }
        Mock Test-RdaChildSeesSignIn { $true }
        Mock Invoke-RdaSide { throw 'a run must not start' }
    }

    It 'passes every check, starts no run, and leaves no folder in the clone' {
        Push-Location $script:Clone
        try
        {
            $R = Invoke-Captured { Invoke-RdaBeforeAfter -TenantID $script:T -SubscriptionID $script:S -AfterBranch 'x' -BeforeCodePath $script:Bt -AfterCodePath $script:At -PreflightOnly }
        }
        finally { Pop-Location }
        $R.Result | Should -Be 0
        Should -Invoke Invoke-RdaSide -Times 0 -Exactly
        Should -Invoke Invoke-RdaAzCliCheck -Times 1 -Exactly -ParameterFilter { $Side -eq 'Before' }
        Should -Invoke Invoke-RdaReaderCheck -Times 1 -Exactly
        Should -Invoke Invoke-RdaAzCliReaderCheck -Times 1 -Exactly -ParameterFilter { $Side -eq 'Before' -and $Subscription -eq $script:S }
        $R.Text | Should -Match 'Every check passed'
        @(Get-ChildItem -LiteralPath $script:Clone -Directory).Count | Should -Be 0
    }

    It 'stops with the Set-AzContext command when the CLI side would see another default tenant' {
        Mock Test-RdaChildSeesSignIn { -not $DefaultTenant }
        Push-Location $script:Clone
        try
        {
            $R = Invoke-Captured { Invoke-RdaBeforeAfter -TenantID $script:T -SubscriptionID $script:S -AfterBranch 'x' -BeforeCodePath $script:Bt -AfterCodePath $script:At -PreflightOnly }
        }
        finally { Pop-Location }
        $R.Result | Should -Be 1
        $R.Text | Should -Match ([regex]::Escape("Set-AzContext -Tenant $($script:T) -Subscription $($script:S)"))
        $R.Text | Should -Match 'Before uses your default Az PowerShell sign-in'
        Should -Invoke Test-RdaChildSeesSignIn -Times 1 -Exactly -ParameterFilter { $DefaultTenant }
        Should -Invoke Invoke-RdaSide -Times 0 -Exactly
    }

    It 'passes the subscription to the Azure CLI check' {
        Push-Location $script:Clone
        try { $null = Invoke-Captured { Invoke-RdaBeforeAfter -TenantID $script:T -SubscriptionID $script:S -AfterBranch 'x' -BeforeCodePath $script:Bt -AfterCodePath $script:At -PreflightOnly } }
        finally { Pop-Location }
        Should -Invoke Invoke-RdaAzCliCheck -Times 1 -Exactly -ParameterFilter { $Subscription -eq $script:S }
    }

    It 'stops before the runs when Reader is missing' {
        Mock Invoke-RdaReaderCheck { $false }
        $Out = Join-Path $TestDrive ('o-' + [guid]::NewGuid())
        $R = Invoke-Captured { Invoke-RdaBeforeAfter -TenantID $script:T -SubscriptionID $script:S -AfterBranch 'x' -OutputDirectory $Out -BeforeCodePath $script:Bt -AfterCodePath $script:At }
        $R.Result | Should -Be 1
        Should -Invoke Invoke-RdaSide -Times 0 -Exactly
        Should -Invoke Test-RdaChildSeesSignIn -Times 0 -Exactly
    }

    It 'stops before the code download when a module check fails' {
        Mock Invoke-RdaAzModuleCheck { [pscustomobject]@{ Ok = $false; Modules = @() } }
        Mock Get-RdaCode { throw 'must not download' }
        $Out = Join-Path $TestDrive ('o-' + [guid]::NewGuid())
        $R = Invoke-Captured { Invoke-RdaBeforeAfter -TenantID $script:T -SubscriptionID $script:S -AfterBranch 'x' -OutputDirectory $Out }
        $R.Result | Should -Be 1
        Should -Invoke Get-RdaCode -Times 0 -Exactly
        Test-Path -LiteralPath $Out | Should -BeFalse
    }
}

Describe 'Sign-in stays in this process' {
    BeforeAll {
        $script:Other = '44444444-4444-4444-4444-444444444444'
        $script:Acct = [pscustomobject]@{ Id = 'user' }
    }

    It 'switches tenant and subscription for this process only, never the saved default' {
        Mock Get-AzContext { [pscustomobject]@{ Account = $script:Acct; Tenant = [pscustomobject]@{ Id = $script:Other }; Subscription = [pscustomobject]@{ Id = $script:Other } } }
        Mock Set-AzContext { }
        Mock Get-AzAccessToken { 'token' }
        Mock Get-AzSubscription { [pscustomobject]@{ Id = $script:S; State = 'Enabled' } }
        Test-RdaAzSignIn -Tenant $script:T -Subscription $script:S | Should -BeTrue
        Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $Scope -eq 'Process' -and $Tenant -eq $script:T -and $Subscription -eq $script:S }
        Should -Invoke Set-AzContext -Times 0 -Exactly -ParameterFilter { $Scope -ne 'Process' }
    }

    It 'lets a new process use a saved sign-in whose default tenant is another one' {
        Mock Get-AzContext { [pscustomobject]@{ Account = $script:Acct; Tenant = [pscustomobject]@{ Id = $script:Other } } }
        Mock Get-AzAccessToken { 'token' }
        $Check = [scriptblock]::Create((Get-RdaChildSignInCheck -Tenant $script:T))
        & $Check | Should -BeTrue
        Should -Invoke Get-AzAccessToken -Times 1 -Exactly -ParameterFilter { $TenantId -eq $script:T }
    }

    It 'says no when the saved sign-in cannot get a token for the tenant' {
        Mock Get-AzContext { [pscustomobject]@{ Account = $script:Acct; Tenant = [pscustomobject]@{ Id = $script:Other } } }
        Mock Get-AzAccessToken { throw 'no token' }
        & ([scriptblock]::Create((Get-RdaChildSignInCheck -Tenant $script:T))) | Should -BeFalse
    }

    It 'says no when there is no saved sign-in' {
        Mock Get-AzContext { $null }
        Mock Get-AzAccessToken { 'token' }
        & ([scriptblock]::Create((Get-RdaChildSignInCheck -Tenant $script:T))) | Should -BeFalse
        Should -Invoke Get-AzAccessToken -Times 0 -Exactly
    }

    It 'takes only a GUID as the tenant, so nothing else lands in the command' {
        { Get-RdaChildSignInCheck -Tenant "x'; Remove-Item ~ -Recurse; '" } | Should -Throw '*GUID*'
    }
}

Describe 'A side that still uses the Azure CLI, with another tenant active' {
    BeforeAll {
        $script:Other = '44444444-4444-4444-4444-444444444444'
        $script:Acct = [pscustomobject]@{ Id = 'user' }
    }

    It 'sees a CLI that has a token for the tenant but another active tenant' {
        Mock Get-Command { [pscustomobject]@{ Name = 'az' } } -ParameterFilter { $Name -eq 'az' }
        Mock Invoke-RdaAz { 0 }
        Mock Get-RdaAzCliTenant { $script:Other }
        Test-RdaAzCliSignIn -Tenant $script:T | Should -Be 'other-tenant'
        Mock Get-RdaAzCliTenant { $script:T }
        Test-RdaAzCliSignIn -Tenant $script:T | Should -Be 'ok'
    }

    It 'asks, and on Y switches the CLI to the subscription with az account set' {
        Mock Test-RdaCloudShell { $false }
        Mock Test-RdaInteractiveHost { $true }
        Mock Read-RdaYesNo { $true }
        $script:Switched = $false
        Mock Invoke-RdaAz { $script:Switched = $true; 0 }
        Mock Test-RdaAzCliSignIn { if ($script:Switched) { 'ok' } else { 'other-tenant' } }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Subscription $script:S -Side 'Before' }
        $R.Result | Should -BeTrue
        $R.Text | Should -Match 'az account clear'
        Should -Invoke Invoke-RdaAz -Times 1 -Exactly -ParameterFilter { ($Arguments -join ' ') -eq "account set --subscription $($script:S) --output none" }
    }

    It 'on N, or when it cannot ask, stops with the command and runs nothing' {
        Mock Test-RdaCloudShell { $false }
        Mock Test-RdaAzCliSignIn { 'other-tenant' }
        Mock Invoke-RdaAz { 0 }
        Mock Test-RdaInteractiveHost { $true }
        Mock Read-RdaYesNo { $false }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Subscription $script:S -Side 'Before' }
        $R.Result | Should -BeFalse
        $R.Text | Should -Match ([regex]::Escape("Run: az account set --subscription $($script:S)"))
        Mock Test-RdaInteractiveHost { $false }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Subscription $script:S -Side 'Before' }
        $R.Result | Should -BeFalse
        $R.Text | Should -Match 'non-interactive'
        Should -Invoke Invoke-RdaAz -Times 0 -Exactly
        Should -Invoke Read-RdaYesNo -Times 1 -Exactly
    }

    It 'with -DefaultTenant, says no when the saved default is another tenant' {
        Mock Get-AzContext { [pscustomobject]@{ Account = $script:Acct; Tenant = [pscustomobject]@{ Id = $script:Other } } }
        Mock Get-AzAccessToken { 'token' }
        & ([scriptblock]::Create((Get-RdaChildSignInCheck -Tenant $script:T -DefaultTenant))) | Should -BeFalse
        & ([scriptblock]::Create((Get-RdaChildSignInCheck -Tenant $script:T))) | Should -BeTrue
        Mock Get-AzContext { [pscustomobject]@{ Account = $script:Acct; Tenant = [pscustomobject]@{ Id = $script:T } } }
        & ([scriptblock]::Create((Get-RdaChildSignInCheck -Tenant $script:T -DefaultTenant))) | Should -BeTrue
    }
}

Describe 'A side that still uses the Azure CLI, without the subscription in its list' {
    It 'sees a CLI whose list of subscriptions does not hold the test subscription' {
        Mock Get-Command { [pscustomobject]@{ Name = 'az' } } -ParameterFilter { $Name -eq 'az' }
        Mock Invoke-RdaAz { 0 }
        Mock Get-RdaAzCliTenant { if ($Subscription) { $null } else { $script:T } }
        Test-RdaAzCliSignIn -Tenant $script:T -Subscription $script:S | Should -Be 'no-subscription'
        Test-RdaAzCliSignIn -Tenant $script:T | Should -Be 'ok' -Because 'without -Subscription the list is not read'
    }

    It 'offers az login for it, and stops with az login advice on N' {
        Mock Test-RdaCloudShell { $false }
        Mock Test-RdaInteractiveHost { $true }
        Mock Read-RdaYesNo { $false }
        Mock Invoke-RdaAz { 0 }
        Mock Test-RdaAzCliSignIn { 'no-subscription' }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Subscription $script:S -Side 'Before' }
        $R.Result | Should -BeFalse
        $R.Text | Should -Match 'not there yet'
        $R.Text | Should -Match ([regex]::Escape("Run: az login --tenant $($script:T)"))
        Should -Invoke Invoke-RdaAz -Times 0 -Exactly
    }

    It 'names az login, not az account set again, when the switch fails' {
        Mock Test-RdaCloudShell { $false }
        Mock Test-RdaInteractiveHost { $true }
        Mock Read-RdaYesNo { $true }
        Mock Invoke-RdaAz { 1 }
        Mock Test-RdaAzCliSignIn { 'other-tenant' }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Subscription $script:S -Side 'Before' }
        $R.Result | Should -BeFalse
        $Last = @($R.Text -split "`n" | Where-Object { $_ -match 'Run: ' })[-1]
        $Last | Should -Match ([regex]::Escape("Run: az login --tenant $($script:T)"))
    }

    It 'says up front that Before will add the resource-graph extension when it is missing' {
        Mock Invoke-RdaAz { 1 } -ParameterFilter { $Arguments -contains 'extension' }
        $R = Invoke-Captured { Write-RdaAzCliExtensionNote -Side 'Before' }
        $R.Text | Should -Match 'az extension add --name resource-graph'
        Mock Invoke-RdaAz { 0 } -ParameterFilter { $Arguments -contains 'extension' }
        (Invoke-Captured { Write-RdaAzCliExtensionNote -Side 'Before' }).Text | Should -BeNullOrEmpty
    }

    It 'does not claim in its help that it never changes the saved Az PowerShell default' {
        $Text = Get-Content -LiteralPath $script:Customer -Raw
        $Text | Should -Not -Match 'never changes your saved Az PowerShell default'
        $Text | Should -Match 'that sign-in becomes your saved\s+default'
    }
}

Describe 'Read access of the Azure CLI sign-in' {
    AfterEach { Remove-Item function:global:az -ErrorAction SilentlyContinue }

    It 'reads <Want> from the permissions the Azure CLI gets back' -TestCases @(
        @{ Json = '{"value":[{"actions":["*/read"],"notActions":[]}]}'; Rc = 0; Want = 'ok' }
        @{ Json = '{"value":[{"actions":["Microsoft.Compute/*/read"],"notActions":[]}]}'; Rc = 0; Want = 'partial' }
        @{ Json = '{"value":[]}'; Rc = 0; Want = 'missing' }
        @{ Json = 'not json'; Rc = 0; Want = 'unknown' }
        @{ Json = ''; Rc = 1; Want = 'unknown' }
    ) {
        param($Json, $Rc, $Want)
        $script:FakeAzJson = $Json; $script:FakeAzRc = $Rc; $script:FakeAzCalls = [System.Collections.Generic.List[string]]::new()
        function global:az { $script:FakeAzCalls.Add(($args -join ' ')); $global:LASTEXITCODE = $script:FakeAzRc; $script:FakeAzJson }
        Get-RdaAzCliReadState -Subscription $script:S | Should -Be $Want
        $script:FakeAzCalls[0] | Should -Match ([regex]::Escape("rest --method get --url /subscriptions/$($script:S)/providers/Microsoft.Authorization/permissions"))
    }

    It 'stops only when the Azure CLI sign-in clearly cannot read, and warns otherwise' {
        Mock Get-RdaAzCliReadState { 'missing' }
        $R = Invoke-Captured { Invoke-RdaAzCliReaderCheck -Subscription $script:S -Side 'Before' }
        $R.Result | Should -BeFalse
        $R.Text | Should -Match 'Reader role'
        Mock Get-RdaAzCliReadState { 'partial' }
        (Invoke-Captured { Invoke-RdaAzCliReaderCheck -Subscription $script:S -Side 'Before' }).Result | Should -BeTrue
        Mock Get-RdaAzCliReadState { 'unknown' }
        (Invoke-Captured { Invoke-RdaAzCliReaderCheck -Subscription $script:S -Side 'Before' }).Result | Should -BeTrue
    }

    It 'resolves a relative -OutputDirectory from the PowerShell location' {
        Mock Invoke-RdaAzModuleCheck { [pscustomobject]@{ Ok = $false; Modules = @() } }
        $Here = Join-Path $TestDrive ('loc-' + [guid]::NewGuid()); New-Item -ItemType Directory $Here | Out-Null
        Push-Location $Here
        try { $R = Invoke-Captured { Invoke-RdaBeforeAfter -TenantID $script:T -SubscriptionID $script:S -AfterBranch 'x' -OutputDirectory 'rel-out' } }
        finally { Pop-Location }
        $R.Result | Should -Be 1
        $R.Text | Should -Match ([regex]::Escape('Output folder: ' + (Join-Path $Here 'rel-out')))
    }
}

Describe 'Round 3: resource-group Reader, paged replies, a subscription of another tenant' {
    AfterEach { Remove-Item function:global:az -ErrorAction SilentlyContinue }

    It 'warns, not stops, when only a resource group can be read (Az PowerShell)' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } } -ParameterFilter { $Path -like '*Microsoft.Authorization/permissions*' }
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"name":"rg1"}]}' } } -ParameterFilter { $Path -like '*/resourcegroups?*' }
        (Test-RdaReaderAccess -Subscription $script:S).State | Should -Be 'partial'
    }

    It 'reads every page of the permissions reply (Az PowerShell), at most 10' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"actions":["Microsoft.Support/*"]}],"nextLink":"https://example.invalid/p2"}' } } -ParameterFilter { $Path }
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"actions":["*/read"],"notActions":[]}]}' } } -ParameterFilter { $Uri -eq 'https://example.invalid/p2' }
        (Test-RdaReaderAccess -Subscription $script:S).State | Should -Be 'ok'
    }

    It 'stops reading pages after 10 and says it cannot tell' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[],"nextLink":"https://example.invalid/again"}' } }
        (Test-RdaReaderAccess -Subscription $script:S).State | Should -Be 'unknown'
        Should -Invoke Invoke-AzRestMethod -Times 10 -Exactly
    }

    It 'warns, not stops, when only a resource group can be read, and reads pages (Azure CLI)' {
        $script:Replies = @{
            perm1 = '{"value":[],"nextLink":"https://example.invalid/p2"}'
            perm2 = '{"value":[]}'
            rg = '{"value":[{"name":"rg1"}]}'
        }
        function global:az
        {
            $global:LASTEXITCODE = 0
            $U = $args[$args.IndexOf('--url') + 1]
            if ($U -like '*/resourcegroups?*') { $script:Replies.rg } elseif ($U -eq 'https://example.invalid/p2') { $script:Replies.perm2 } else { $script:Replies.perm1 }
        }
        Get-RdaAzCliReadState -Subscription $script:S | Should -Be 'partial'
        $script:Replies.perm2 = '{"value":[{"actions":["*/read"],"notActions":[]}]}'
        Get-RdaAzCliReadState -Subscription $script:S | Should -Be 'ok'
    }

    It 'sees a subscription the Azure CLI lists under another tenant' {
        Mock Get-Command { [pscustomobject]@{ Name = 'az' } } -ParameterFilter { $Name -eq 'az' }
        Mock Invoke-RdaAz { 0 }
        Mock Get-RdaAzCliTenant { if ($Subscription) { '44444444-4444-4444-4444-444444444444' } else { $script:T } }
        Test-RdaAzCliSignIn -Tenant $script:T -Subscription $script:S | Should -Be 'subscription-other-tenant'
    }

    It 'for that, stops with a -TenantID hint and offers nothing' {
        Mock Invoke-RdaAz { 0 }
        Mock Test-RdaCloudShell { $false }
        Mock Read-RdaYesNo { $true }
        Mock Test-RdaAzCliSignIn { 'subscription-other-tenant' }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Subscription $script:S -Side 'Before' }
        $R.Result | Should -BeFalse
        $R.Text | Should -Match 'another tenant than -TenantID'
        Should -Invoke Read-RdaYesNo -Times 0 -Exactly
        Should -Invoke Invoke-RdaAz -Times 0 -Exactly
    }

    It 'gives the resource-graph note after a successful switch too' {
        Mock Test-RdaCloudShell { $false }
        Mock Test-RdaInteractiveHost { $true }
        Mock Read-RdaYesNo { $true }
        $script:Switched = $false
        Mock Invoke-RdaAz { $script:Switched = $true; 0 } -ParameterFilter { $Arguments -contains 'set' }
        Mock Invoke-RdaAz { 1 } -ParameterFilter { $Arguments -contains 'extension' }
        Mock Test-RdaAzCliSignIn { if ($script:Switched) { 'ok' } else { 'other-tenant' } }
        $R = Invoke-Captured { Invoke-RdaAzCliCheck -Tenant $script:T -Subscription $script:S -Side 'Before' }
        $R.Result | Should -BeTrue
        $R.Text | Should -Match 'az extension add --name resource-graph'
    }
}
