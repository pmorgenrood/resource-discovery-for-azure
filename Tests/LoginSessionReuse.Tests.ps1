# =============================================================================
# LoginSessionReuse.Tests.ps1
#
# Offline tests for the sign-in step of a direct run of ResourceInventory.ps1
# (LoginSession, nested inside RunInventorySetup).
#
# WHY THIS TEST EXISTS
# --------------------
# A direct run must reuse an Azure sign-in that already works instead of
# prompting again. az CLI and Az PowerShell keep separate sign-ins, so each
# side is checked on its own: it is reused when it is signed in to the target
# tenant AND can still acquire a token silently, and only a side that fails
# that check is signed in again. A cached az account whose token can no
# longer be acquired (expired, or gated by Conditional Access / MFA) must not
# count as signed in, or the run collects nothing.
#
# HOW
# ---
# LoginSession is lifted out of ResourceInventory.ps1 with the PowerShell
# parser (the script runs setup when invoked). az is replaced by a local
# function that simulates the az CLI sign-in state and records every call;
# Get-AzContext, Get-AzAccessToken, Connect-AzAccount and Get-AzSubscription
# are shims driven by the same simulated state, with Pester mocks on
# Connect-AzAccount so its parameters can be asserted. No live Azure.
#
# Tenant ids are generated at runtime.
#
# Run with: Invoke-Pester ./Tests/LoginSessionReuse.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:CommonFunctions = Join-Path $script:RepoRoot 'Functions/Common.Functions.ps1'
    $script:InventoryScript = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    foreach ($Required in @($script:CommonFunctions, $script:InventoryScript))
    {
        if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Required file not found: $Required" }
    }

    # ResourceInventory.ps1 dot-sources Common.Functions.ps1 at the top, so the
    # sign-in helpers it uses must come from there.
    . $script:CommonFunctions

    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:InventoryScript, [ref]$Tokens, [ref]$ParseErrors)
    if (@($ParseErrors).Count -gt 0) { throw ("ResourceInventory.ps1 does not parse: {0}" -f $ParseErrors[0].Message) }
    $LoginFn = $Ast.FindAll({
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'LoginSession'
        }, $true) | Select-Object -First 1
    if ($null -eq $LoginFn) { throw 'LoginSession was not found in ResourceInventory.ps1. Has it been renamed or removed?' }
    $script:LoginFunctionText = $LoginFn.Extent.Text

    $script:TenantA = [guid]::NewGuid().ToString()
    $script:TenantB = [guid]::NewGuid().ToString()

    $script:HadSubscriptions = $null -ne (Get-Variable -Scope Global -Name Subscriptions -ErrorAction SilentlyContinue)
    $script:SavedSubscriptions = $Global:Subscriptions
    $script:HadInitialized = $null -ne (Get-Variable -Scope Global -Name RdaSessionInitialized -ErrorAction SilentlyContinue)
    $script:SavedInitialized = $Global:RdaSessionInitialized
    $script:SavedExitCode = $global:LASTEXITCODE
}

AfterAll {
    if ($script:HadSubscriptions) { $Global:Subscriptions = $script:SavedSubscriptions }
    else { Remove-Variable -Scope Global -Name Subscriptions -ErrorAction SilentlyContinue }
    if ($script:HadInitialized) { $Global:RdaSessionInitialized = $script:SavedInitialized }
    else { Remove-Variable -Scope Global -Name RdaSessionInitialized -ErrorAction SilentlyContinue }
    $global:LASTEXITCODE = $script:SavedExitCode
}

Describe 'LoginSession on a direct run' {

    BeforeAll {
        . ([scriptblock]::Create($script:LoginFunctionText))

        # Simulated az CLI. Records each call as one space-joined string and
        # sets $LASTEXITCODE the way the real executable would.
        function az
        {
            $Line = ($args | ForEach-Object { [string]$_ }) -join ' '
            $script:AzCalls.Add($Line)
            $global:LASTEXITCODE = 0
            $Sim = $script:Sim
            switch -Regex ($Line)
            {
                '^cloud list' { return '[{"name":"AzureCloud","isActive":true}]' }
                '^account show'
                {
                    if ($Sim.CliTenant) { return (@{ tenantId = $Sim.CliTenant; user = @{ name = 'user@example.com' } } | ConvertTo-Json) }
                    $global:LASTEXITCODE = 1
                    return
                }
                '^account get-access-token'
                {
                    $Asked = $args[[array]::IndexOf($args, '--tenant') + 1]
                    if (-not ($Sim.CliTenant -and $Sim.CliTokenOk -and $Asked -eq $Sim.CliTenant)) { $global:LASTEXITCODE = 1 }
                    return
                }
                '^account clear' { $Sim.CliTenant = $null; $Sim.CliTokenOk = $false; return }
                '^account list'
                {
                    if (-not $Sim.CliTenant) { return '[]' }
                    return (ConvertTo-Json -InputObject @(@{ id = 'sub-1'; name = 'sub-1'; tenantId = $Sim.CliTenant }))
                }
                '^login'
                {
                    $TIndex = [array]::IndexOf($args, '-t')
                    if ($TIndex -lt 0) { $TIndex = [array]::IndexOf($args, '--tenant') }
                    $Sim.CliTenant = if ($TIndex -ge 0) { $args[$TIndex + 1] } else { $Sim.HomeTenant }
                    $Sim.CliTokenOk = $true
                    return
                }
            }
        }

        function Get-AzContext
        {
            [CmdletBinding()] param()
            if (-not $script:Sim.PsTenant) { return $null }
            [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'user@example.com' }; Tenant = [pscustomobject]@{ Id = $script:Sim.PsTenant } }
        }

        function Get-AzAccessToken
        {
            [CmdletBinding()] param([string]$TenantId, [string]$ResourceUrl)
            if ($script:Sim.PsTenant -and $script:Sim.PsTokenOk -and $TenantId -eq $script:Sim.PsTenant) { return [pscustomobject]@{ Token = 'token' } }
            throw 'Unable to acquire token for tenant. User interaction is required.'
        }

        function Connect-AzAccount
        {
            [CmdletBinding()]
            param([string]$Tenant, [switch]$UseDeviceAuthentication, [switch]$Identity, [switch]$ServicePrincipal, [pscredential]$Credential)
            $script:Sim.PsTenant = if ($Tenant) { $Tenant } else { $script:Sim.HomeTenant }
            $script:Sim.PsTokenOk = $true
        }

        function Get-AzSubscription
        {
            [CmdletBinding()] param()
            [pscustomobject]@{ HomeTenantId = $script:Sim.HomeTenant }
        }

        function Set-SignInState
        {
            param([string]$CliTenant, [bool]$CliTokenOk = $true, [string]$PsTenant, [bool]$PsTokenOk = $true, [string]$HomeTenant = $script:TenantA)
            $script:Sim = @{ CliTenant = $CliTenant; CliTokenOk = $CliTokenOk; PsTenant = $PsTenant; PsTokenOk = $PsTokenOk; HomeTenant = $HomeTenant }
        }

        function Get-AzLogins { @($script:AzCalls | Where-Object { $_ -match '^login' }) }
        function Get-AzClears { @($script:AzCalls | Where-Object { $_ -match '^account clear' }) }
    }

    BeforeEach {
        $script:AzCalls = [System.Collections.Generic.List[string]]::new()
        $script:LogLines = [System.Collections.Generic.List[string]]::new()
        $Global:RdaSessionInitialized = $true
        $Global:Subscriptions = @()
        Mock -CommandName Write-Log -MockWith { $script:LogLines.Add(('{0}: {1}' -f $Severity, $Message)) }
        Mock -CommandName Connect-AzAccount -MockWith {
            $script:Sim.PsTenant = if ($Tenant) { $Tenant } else { $script:Sim.HomeTenant }
            $script:Sim.PsTokenOk = $true
        }

        # Script parameters LoginSession reads from its caller's scope.
        $TenantID = $null
        $Appid = $null
        $Secret = $null
        $DeviceLogin = [switch]$false
        $RunAllSubs = [switch]$false
        $UseManagedIdentity = [switch]$false
        $null = $TenantID, $Appid, $Secret, $DeviceLogin, $RunAllSubs, $UseManagedIdentity
    }

    It 'signs in az CLI only, without clearing it, when only Az PowerShell has a usable session' {
        Set-SignInState -PsTenant $script:TenantA

        LoginSession 6>$null

        @(Get-AzClears).Count | Should -Be 0 -Because 'Az PowerShell is usable, so the az account cache is not wiped'
        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
        @(Get-AzLogins).Count | Should -Be 1
        @(Get-AzLogins)[0] | Should -Match ([regex]::Escape($script:TenantA)) -Because 'az signs in to the tenant Az PowerShell is on'
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 'connects Az PowerShell only, to the az CLI tenant, when only az CLI has a usable session' {
        Set-SignInState -CliTenant $script:TenantA

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 0
        @(Get-AzClears).Count | Should -Be 0
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Tenant -eq $script:TenantA }
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 'signs in nothing when both sides have a usable session on the same tenant' {
        Set-SignInState -CliTenant $script:TenantA -PsTenant $script:TenantA

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 0
        @(Get-AzClears).Count | Should -Be 0
        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 'signs in az CLI again when its cached account cannot acquire a token' {
        Set-SignInState -CliTenant $script:TenantA -CliTokenOk $false -PsTenant $script:TenantA

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 1 -Because 'a cached az account whose token cannot be acquired is not a usable session'
        @(Get-AzLogins)[0] | Should -Match ([regex]::Escape($script:TenantA))
        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
    }

    It 'signs in Az PowerShell again when its context cannot acquire a token' {
        Set-SignInState -CliTenant $script:TenantA -PsTenant $script:TenantA -PsTokenOk $false

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 0
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Tenant -eq $script:TenantA }
    }

    It 'signs in with the managed identity on both sides with -UseManagedIdentity' {
        $UseManagedIdentity = [switch]$true
        $TenantID = $script:TenantA
        $null = $UseManagedIdentity, $TenantID
        Set-SignInState

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 1
        @(Get-AzLogins)[0] | Should -Match '--identity'
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Identity.IsPresent -and $Tenant -eq $script:TenantA }
        @(Get-AzClears).Count | Should -Be 0
    }

    It 'signs in with the managed identity without a tenant when -TenantID is not given' {
        $UseManagedIdentity = [switch]$true
        $null = $UseManagedIdentity
        Set-SignInState

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 1
        @(Get-AzLogins)[0] | Should -Match '--identity'
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Identity.IsPresent -and -not $Tenant }
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 're-authenticates only az CLI when it is on a different tenant than -TenantID' {
        $TenantID = $script:TenantB
        $null = $TenantID
        Set-SignInState -CliTenant $script:TenantA -PsTenant $script:TenantB

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 1
        @(Get-AzLogins)[0] | Should -Match ([regex]::Escape($script:TenantB))
        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
        @($Global:Subscriptions | Where-Object { $_.tenantId -eq $script:TenantB }).Count | Should -Be 1
    }

    It 're-authenticates only Az PowerShell when it is on a different tenant than -TenantID' {
        $TenantID = $script:TenantB
        $null = $TenantID
        Set-SignInState -CliTenant $script:TenantB -PsTenant $script:TenantA

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 0
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Tenant -eq $script:TenantB }
    }

    It 'uses the az CLI tenant and warns when the two sides are on different tenants and no -TenantID is given' {
        Set-SignInState -CliTenant $script:TenantA -PsTenant $script:TenantB

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 0
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $Tenant -eq $script:TenantA }
        @($script:LogLines | Where-Object { $_ -match '^Warning:' -and $_ -match [regex]::Escape($script:TenantA) -and $_ -match [regex]::Escape($script:TenantB) }).Count | Should -BeGreaterThan 0
    }

    It 'uses device code sign-in for the side it signs in when -DeviceLogin is given' {
        $DeviceLogin = [switch]$true
        $null = $DeviceLogin
        Set-SignInState -PsTenant $script:TenantA

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 1
        @(Get-AzLogins)[0] | Should -Match '--use-device-code'
        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
    }

    It 'clears az and signs in both sides when nothing is signed in (single tenant)' {
        Set-SignInState

        LoginSession 6>$null

        @(Get-AzClears).Count | Should -Be 1
        @(Get-AzLogins).Count | Should -Be 1
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly
        @($Global:Subscriptions).Count | Should -Be 1
    }

    It 'signs in both sides with the service principal when -Appid, -Secret and -TenantID are given' {
        $TenantID = $script:TenantA
        $Appid = [guid]::NewGuid().ToString()
        $Secret = ConvertTo-SecureString -String 'not-a-real-secret' -AsPlainText -Force
        $null = $TenantID, $Appid, $Secret
        Set-SignInState

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 1
        @(Get-AzLogins)[0] | Should -Match '--service-principal'
        Should -Invoke -CommandName Connect-AzAccount -Times 1 -Exactly -ParameterFilter { $ServicePrincipal.IsPresent -and $Tenant -eq $script:TenantA }
    }

    It 'signs in nothing under -RunAllSubs' {
        $RunAllSubs = [switch]$true
        $TenantID = $script:TenantA
        $null = $RunAllSubs, $TenantID
        Set-SignInState -CliTenant $script:TenantA -PsTenant $script:TenantA

        LoginSession 6>$null

        @(Get-AzLogins).Count | Should -Be 0
        @(Get-AzClears).Count | Should -Be 0
        Should -Invoke -CommandName Connect-AzAccount -Times 0 -Exactly
        @($Global:Subscriptions).Count | Should -Be 1
    }
}

# A side whose token probe still fails after its one sign-in attempt must stop
# the run (exit 1) instead of prompting again. The stop is a real `exit`, so
# these cases run LoginSession in a child pwsh process with file-logged fakes.
Describe 'LoginSession when a sign-in does not give a usable token' {

    BeforeAll {
        $script:Harness = Join-Path $TestDrive 'login-harness.ps1'
        @'
param([string]$Root, [string]$CallLog, [string]$Scenario, [string]$Tenant)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $Root 'Functions/Common.Functions.ps1')
$Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'ResourceInventory.ps1'), [ref]$null, [ref]$null)
$Fn = $Ast.FindAll({ param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -eq 'LoginSession' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($Fn.Extent.Text))

# Simulated sign-in state. A sign-in "succeeds" but never yields a token for
# the failing side, so its probe fails again afterwards.
$Global:Sim = switch ($Scenario)
{
    'az-token-fails' { @{ CliTenant = $Tenant; CliToken = $false; PsTenant = $Tenant; PsToken = $true } }
    'ps-token-fails' { @{ CliTenant = $Tenant; CliToken = $true; PsTenant = $Tenant; PsToken = $false } }
    'mi-token-fails' { @{ CliTenant = $null; CliToken = $false; PsTenant = $null; PsToken = $false } }
}
function global:Write-Log { param($Message, $Severity) Write-Output ('{0}: {1}' -f $Severity, $Message) }
function global:az
{
    $Line = ($args | ForEach-Object { [string]$_ }) -join ' '
    Add-Content -Path $CallLog -Value ('az ' + $Line)
    $global:LASTEXITCODE = 0
    if ($Line -like 'cloud list*') { return '[{"name":"AzureCloud","isActive":true}]' }
    if ($Line -like 'account show*') { if ($Global:Sim.CliTenant) { return ('{{"tenantId":"{0}"}}' -f $Global:Sim.CliTenant) }; $global:LASTEXITCODE = 1; return }
    if ($Line -like 'account get-access-token*') { if (-not $Global:Sim.CliToken) { $global:LASTEXITCODE = 1 }; return }
    if ($Line -like 'account list*') { return ('[{{"id":"sub-1","tenantId":"{0}"}}]' -f $Global:Sim.CliTenant) }
    if ($Line -like 'login*') { $Global:Sim.CliTenant = $Tenant; return }
}
function global:Get-AzContext { [CmdletBinding()] param() if ($Global:Sim.PsTenant) { [pscustomobject]@{ Account = 'user'; Tenant = [pscustomobject]@{ Id = $Global:Sim.PsTenant } } } }
function global:Get-AzAccessToken { [CmdletBinding()] param($TenantId) if ($Global:Sim.PsToken) { [pscustomobject]@{ Token = 'token' } } else { throw 'User interaction is required.' } }
function global:Connect-AzAccount
{
    [CmdletBinding()] param([string]$Tenant, [switch]$Identity, [switch]$UseDeviceAuthentication)
    Add-Content -Path $CallLog -Value ('Connect-AzAccount' + $(if ($Identity) { ' -Identity' }) + $(if ($Tenant) { ' -Tenant ' + $Tenant }))
    $Global:Sim.PsTenant = $Tenant
}

$Global:RdaSessionInitialized = $true
$TenantID = if ($Scenario -eq 'mi-token-fails') { $Tenant } else { $null }
$UseManagedIdentity = [switch]($Scenario -eq 'mi-token-fails')
$Appid = $null; $DeviceLogin = [switch]$false; $RunAllSubs = [switch]$false
LoginSession
Add-Content -Path $CallLog -Value 'returned'
exit 0
'@ | Set-Content -Path $script:Harness -Encoding utf8

        function Invoke-LoginHarness
        {
            param([string]$Scenario)
            $CallLog = Join-Path $TestDrive ('calls-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
            $Output = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $script:Harness -Root $script:RepoRoot -CallLog $CallLog -Scenario $Scenario -Tenant $script:TenantA 2>&1 | Out-String
            $Code = $LASTEXITCODE
            $Calls = if (Test-Path -LiteralPath $CallLog) { @(Get-Content -LiteralPath $CallLog) } else { @() }
            [pscustomobject]@{
                ExitCode = $Code
                Output   = $Output
                Calls    = $Calls
                AzLogins = @($Calls | Where-Object { $_ -like 'az login*' })
                Connects = @($Calls | Where-Object { $_ -like 'Connect-AzAccount*' })
            }
        }
    }

    It 'signs in az CLI once and stops with exit 1 when its token probe still fails' {
        $Run = Invoke-LoginHarness -Scenario 'az-token-fails'

        $Run.ExitCode | Should -Be 1
        $Run.AzLogins.Count | Should -Be 1 -Because 'one sign-in attempt per side, never a second prompt'
        $Run.Connects.Count | Should -Be 0
        $Run.Calls | Should -Not -Contain 'returned'
        $Run.Calls | Should -Not -Contain 'az account list --output json --only-show-errors'
        $Run.Output | Should -Match 'az CLI: sign-in to tenant .* did not give a usable token'
    }

    It 'connects Az PowerShell once and stops with exit 1 when its token probe still fails' {
        $Run = Invoke-LoginHarness -Scenario 'ps-token-fails'

        $Run.ExitCode | Should -Be 1
        $Run.Connects.Count | Should -Be 1 -Because 'one sign-in attempt per side, never a second prompt'
        $Run.AzLogins.Count | Should -Be 0
        $Run.Calls | Should -Not -Contain 'returned'
        $Run.Output | Should -Match 'Az PowerShell: sign-in to tenant .* did not give a usable token'
    }

    It 'signs in with the managed identity once and stops with exit 1 when no token can be acquired' {
        $Run = Invoke-LoginHarness -Scenario 'mi-token-fails'

        $Run.ExitCode | Should -Be 1
        $Run.AzLogins.Count | Should -Be 1
        $Run.AzLogins[0] | Should -Match '--identity'
        $Run.Connects.Count | Should -Be 1
        $Run.Calls | Should -Not -Contain 'returned'
    }
}
