# =============================================================================
# Shareable diagnostics log: no failure message text
# =============================================================================
# The shareable Diagnostics_*.log holds, per failure: the collector, the
# subscription's token and only closed-list facts read from the error OBJECT
# (exception type name, HTTP status number, an Azure error code on a fixed
# list). No message text is ever written, so no credential, home folder, host,
# email or resource name in an error can reach it. These tests assert that
# directly, without a live run. Synthetic values only; the GUID is the Azure
# docs placeholder.
# =============================================================================

BeforeAll {
    $FunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'
    if (-not (Test-Path $FunctionsFile)) { throw "ResourceInventory.Functions.ps1 not found at $FunctionsFile" }
    . $FunctionsFile
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/Common.Functions.ps1')
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/OfflineObfuscation.Functions.ps1')
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1')
    . $FunctionsFile

    $script:SubGuid = '12345678-1234-1234-1234-123456789012'
    $script:Secrets = @(
        'Password="hunter2x"', 'AccountKey=abc/def+ghi==', 'sig%3DSECRETVALUE', 'OAuthToken=zzz999',
        'C:\Users\Jane Doe\x', '/Users/alice/x', 'ops.admin@contoso-corp.com', 'appdatastore.blob.core.windows.net',
        'secretacct.privatelink.blob.core.windows.net', '10.20.30.40', '001A.2B3C.4D5E', 'rg-sensitive-demo', 'vm-app-demo'
    )

    function script:New-DiagnosticsText
    {
        param([object[]]$Collector = @(), [object[]]$Metrics = @(), [object[]]$Consumption = @(), [switch]$Obfuscated)
        $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaDiagText_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
        $Saved = @{ C = $Global:CollectorFailures; M = $Global:MetricsFailedSubs; U = $Global:ConsumptionFailedSubs; S = $Global:ResourceSubscriptionDictionary; I = $Global:ResourceIdDictionary }
        try
        {
            $Global:CollectorFailures = $Collector; $Global:MetricsFailedSubs = $Metrics; $Global:ConsumptionFailedSubs = $Consumption
            $Global:ResourceIdDictionary = $null; $Global:ResourceSubscriptionDictionary = $null
            $File = Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + [IO.Path]::DirectorySeparatorChar) -ReportName 'P' -RunDateTime '1' -Version '3.2.3' -PhaseTimings ([ordered]@{}) -Obfuscated:$Obfuscated 6>$null
            return (Get-Content -Raw -LiteralPath $File)
        }
        finally
        {
            $Global:CollectorFailures = $Saved.C; $Global:MetricsFailedSubs = $Saved.M; $Global:ConsumptionFailedSubs = $Saved.U
            $Global:ResourceSubscriptionDictionary = $Saved.S; $Global:ResourceIdDictionary = $Saved.I
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-RdaErrorFacts reads only closed-list facts from the error object' {
    It 'reads the exception type, the HTTP status and a listed Azure error code' {
        $Ex = [System.Net.WebException]::new('Password="hunter2x" at /Users/alice/x')
        $Obj = [pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]::Forbidden }; Body = [pscustomobject]@{ Code = 'AuthorizationFailed' } }
        Get-RdaErrorFacts $Ex | Should -Be 'exception=System.Net.WebException'
        Get-RdaErrorFacts $Obj | Should -Be 'status=403 code=AuthorizationFailed'
    }

    It 'drops an Azure error code that is not on the list, and a type from outside the closed prefixes' {
        $Obj = [pscustomobject]@{ StatusCode = 429; Code = 'Contoso-Secret-Code' }
        Get-RdaErrorFacts $Obj | Should -Be 'status=429'
        # A custom type name is not kept.
        Add-Type -TypeDefinition 'public class AcmeCustomerError : System.Exception { public AcmeCustomerError(string m) : base(m) {} }' -ErrorAction SilentlyContinue
        Get-RdaErrorFacts ([AcmeCustomerError]::new('x')) | Should -Be ''
    }

    It 'never reads the message text' {
        $Facts = Get-RdaErrorFacts ([System.InvalidOperationException]::new('status=403 code=AuthorizationFailed ops.admin@contoso-corp.com'))
        $Facts | Should -Be 'exception=System.InvalidOperationException'
    }

    It 'reads Status, Error.Code and ErrorCode shapes, and ignores a status outside 100-599 (so a non-HTTP enum such as WebExceptionStatus)' {
        Get-RdaErrorFacts ([pscustomobject]@{ Status = 404; ErrorCode = 'ResourceNotFound' }) | Should -Match 'status=404 code=ResourceNotFound$'
        Get-RdaErrorFacts ([pscustomobject]@{ Error = [pscustomobject]@{ Code = 'TooManyRequests' } }) | Should -Match 'code=TooManyRequests$'
        Get-RdaErrorFacts ([pscustomobject]@{ Status = [System.Net.WebExceptionStatus]::Timeout }) | Should -Not -Match 'status='
        Get-RdaErrorFacts ([pscustomobject]@{ StatusCode = 99; Code = 'Nope' }) | Should -Not -Match 'status=|code='
    }

    It 'never throws while a failure is being handled: a wide enum, a throwing getter, an odd object' {
        Add-Type -TypeDefinition 'public enum RdaWideStatus : ulong { Huge = 18446744073709551615 } public class RdaThrowingError : System.Exception { public override string StackTrace { get { throw new System.InvalidOperationException(); } } public int Status { get { throw new System.InvalidOperationException(); } } public RdaWideStatus Code2 { get { return RdaWideStatus.Huge; } } }' -ErrorAction SilentlyContinue
        { Get-RdaErrorFacts ([pscustomobject]@{ Status = [RdaWideStatus]::Huge }) } | Should -Not -Throw
        Get-RdaErrorFacts ([pscustomobject]@{ Status = [RdaWideStatus]::Huge }) | Should -Not -Match 'status='
        { Get-RdaErrorFacts ([RdaThrowingError]::new()) } | Should -Not -Throw
        { Get-RdaErrorFacts $null } | Should -Not -Throw
    }

    It 'rejects facts the writer never writes: spacing, order, repeats, leading zeros, a lone page or records' {
        foreach ($Bad in ' status=403', 'status=403 ', 'status=403  code=BadRequest', 'status=403code=BadRequest', 'code=BadRequest status=403', 'status=403 status=404', 'page=01 records=1', 'page=1', 'records=1', 'page=1 code=BadRequest records=2', 'status=99', 'status=600')
        {
            Test-RdaDiagnosticFacts $Bad | Should -BeFalse -Because "'$Bad'"
        }
        Test-RdaDiagnosticFacts 'exception=System.Net.WebException status=403 code=AuthorizationFailed page=0 records=0' | Should -BeTrue
    }

    It 'keeps an exception type only from the exact list, not any name under an allowed namespace' {
        Add-Type -TypeDefinition 'namespace Microsoft.ContosoSecret123 { public class Error : System.Exception { public Error(string m) : base(m) {} } }' -ErrorAction SilentlyContinue
        Get-RdaErrorFacts ([Microsoft.ContosoSecret123.Error]::new('x')) | Should -Be ''
        Get-RdaErrorFacts ([System.Net.WebException]::new('x')) | Should -Be 'exception=System.Net.WebException'
    }

    It 'writes each listed type to the log and reads it back' {
        $Sub = '11111111-2222-3333-4444-555555555555'
        $Entries = @($Global:RdaDiagnosticExceptionTypes | ForEach-Object { [pscustomobject]@{ Id = $Sub; Module = 'M'; Message = 'm'; Facts = ('exception=' + $_) } })
        $Text = New-DiagnosticsText -Collector $Entries
        $Back = ConvertFrom-RdaDiagnosticsText -Lines ($Text.TrimEnd() -split "`r?`n") -ReportFolder 'f'
        @($Back.CollectorFailures | ForEach-Object { $_.Facts }) | Should -Be @($Global:RdaDiagnosticExceptionTypes | ForEach-Object { 'exception=' + $_ })
    }

    It 'keeps a type on the list when it is the error object, and lists no type twice' {
        $Global:RdaDiagnosticExceptionTypes.Count | Should -Be @($Global:RdaDiagnosticExceptionTypes | Select-Object -Unique).Count
        Get-RdaErrorFacts ([System.Management.Automation.ActionPreferenceStopException]::new('x')) | Should -Be 'exception=System.Management.Automation.ActionPreferenceStopException'
        # A type that is a module's own and never loaded here is not listed (Az.ResourceGraph is not used).
        $Global:RdaDiagnosticExceptionTypes | Should -Not -Contain 'Microsoft.Azure.Management.ResourceGraph.Models.ErrorResponseException'
    }

    It 'returns no facts when reading the list itself throws (the outer guard)' {
        $Saved = $Global:RdaDiagnosticErrorCodes
        try
        {
            $Global:RdaDiagnosticErrorCodes = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { throw 'boom' } -PassThru
            { Get-RdaErrorFacts ([pscustomobject]@{ Code = 'BadRequest' }) } | Should -Not -Throw
        }
        finally { $Global:RdaDiagnosticErrorCodes = $Saved }
    }

    It 'accepts only the closed grammar when a log line is read back' {
        Test-RdaDiagnosticFacts '' | Should -BeTrue
        Test-RdaDiagnosticFacts 'exception=System.Net.WebException status=403 code=AuthorizationFailed' | Should -BeTrue
        Test-RdaDiagnosticFacts 'code=Contoso-Secret-Code' | Should -BeFalse
        Test-RdaDiagnosticFacts 'status=403 ops.admin@contoso-corp.com' | Should -BeFalse
        Test-RdaDiagnosticFacts 'exception=Contoso.Secret.Error' | Should -BeFalse
        Test-RdaDiagnosticFacts 'exception=Microsoft.ContosoSecret123.Error' | Should -BeFalse
        Test-RdaDiagnosticFacts 'exception=System.Net.WebException+Inner' | Should -BeFalse
    }
}

Describe 'The shareable diagnostics log writes no message text' {
    It 'writes a failure line with its collector, its subscription label and its facts only' {
        $Text = New-DiagnosticsText -Obfuscated -Collector @([pscustomobject]@{ Id = $script:SubGuid; Module = 'VMSS'; Message = ($script:Secrets -join ' '); Facts = 'status=403 code=AuthorizationFailed' })
        $Text | Should -Match '(?m)^  \[sub <guid>\] VMSS: \(message not kept: status=403 code=AuthorizationFailed\)\r?$'
        foreach ($Secret in $script:Secrets) { $Text.Contains($Secret) | Should -BeFalse -Because $Secret }
        $Text.Contains($script:SubGuid) | Should -BeFalse
    }

    It 'drops an unknown error code, and facts that are not in the closed grammar' {
        $Text = New-DiagnosticsText -Obfuscated -Collector @(
            [pscustomobject]@{ Id = $script:SubGuid; Module = 'A'; Message = 'm'; Facts = 'code=Contoso-Secret-Code' },
            [pscustomobject]@{ Id = $script:SubGuid; Module = 'B'; Message = 'm'; Facts = 'ops.admin@contoso-corp.com' })
        $Text | Should -Match '(?m)^  \[sub <guid>\] A: \(message not kept\)\r?$'
        $Text | Should -Match '(?m)^  \[sub <guid>\] B: \(message not kept\)\r?$'
        $Text | Should -Not -Match 'Contoso|contoso'
    }

    It 'writes the same for the metrics and consumption sections, and a default run' {
        $Metrics = @([pscustomobject]@{ Id = '(unknown)'; Name = 'n'; Message = 'AccountKey=abc/def+ghi== rg-sensitive-demo' })
        $Consumption = @([pscustomobject]@{ Id = '(auth)'; Name = 'n'; Message = 'C:\Users\Jane Doe\x'; Facts = 'status=401' })
        foreach ($Obf in $true, $false)
        {
            $Text = New-DiagnosticsText -Obfuscated:$Obf -Metrics $Metrics -Consumption $Consumption
            $Text | Should -Match '(?m)^  \[sub \(unknown\)\] \(message not kept\)\r?$'
            $Text | Should -Match '(?m)^  \[sub \(auth\)\] \(message not kept: status=401\)\r?$'
            $Text | Should -Not -Match 'AccountKey|Jane|rg-sensitive'
        }
    }

    It 'writes a subscription as its token when the run has one, else <guid>' {
        $Token = 'prod_' + [guid]::NewGuid().ToString()
        $Saved = @{ S = $Global:ResourceSubscriptionDictionary; I = $Global:ResourceIdDictionary }
        try
        {
            $Global:ResourceIdDictionary = @{ "/subscriptions/$($script:SubGuid)/resourceGroups/g/providers/Microsoft.Compute/virtualMachines/v" = 'x' }
            $Global:ResourceSubscriptionDictionary = @{ "/subscriptions/$($script:SubGuid)/resourceGroups/g/providers/Microsoft.Compute/virtualMachines/v" = $Token }
            $Dir = Join-Path ([IO.Path]::GetTempPath()) ('RdaDiagTok_' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $Dir | Out-Null
            $Global:CollectorFailures = @([pscustomobject]@{ Id = $script:SubGuid.ToUpperInvariant(); Module = 'M'; Message = 'm' }, [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Module = 'N'; Message = 'm' })
            $Global:MetricsFailedSubs = @(); $Global:ConsumptionFailedSubs = @()
            $File = Write-RdaShareableDiagnosticsLog -DefaultPath ($Dir + [IO.Path]::DirectorySeparatorChar) -ReportName 'P' -RunDateTime '1' -Version '3.2.3' -PhaseTimings ([ordered]@{}) -Obfuscated 6>$null
            $Text = Get-Content -Raw -LiteralPath $File
            $Text | Should -Match ('(?m)^  \[sub ' + [regex]::Escape($Token) + '\] M: ')
            $Text | Should -Match '(?m)^  \[sub <guid>\] N: '
            $Text.Contains($script:SubGuid) | Should -BeFalse
        }
        finally
        {
            $Global:ResourceSubscriptionDictionary = $Saved.S; $Global:ResourceIdDictionary = $Saved.I
            $Global:CollectorFailures = @(); $Global:MetricsFailedSubs = @(); $Global:ConsumptionFailedSubs = @()
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs under Set-StrictMode -Version Latest' {
        { Set-StrictMode -Version Latest; Get-RdaErrorFacts ([System.Exception]::new('x')); Get-RdaDiagnosticMessage ([pscustomobject]@{ Message = 'x' }) } | Should -Not -Throw
    }

    It 'has no free-text scrub left' {
        Get-Command Protect-DiagnosticText -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
