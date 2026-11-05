# Requires -Modules Pester
# Offline coverage for Test-MetricNotFound in Extension/Metrics.ps1: a Get-AzMetric 404 (NotFound)
# is permanent, so the retry loop gives it one attempt instead of four. Extracted by AST like
# MetricsThrottleRetryAfter.Tests.ps1 does, because the function lives inside the -Parallel block.
# The end-to-end attempt counts are in MetricsGrouping.Tests.ps1 and MetricsBatch.Tests.ps1.

BeforeAll {
    $Repo = Split-Path $PSScriptRoot -Parent
    $script:MetricsSrc = Get-Content -LiteralPath (Join-Path $Repo 'Extension/Metrics.ps1') -Raw
    $Tokens = $null; $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseInput($script:MetricsSrc, [ref]$Tokens, [ref]$Errors)
    $FnAst = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Test-MetricNotFound' }, $true) | Select-Object -First 1
    if (-not $FnAst) { throw 'Test-MetricNotFound was not found in Extension/Metrics.ps1' }
    . ([scriptblock]::Create($FnAst.Extent.Text))
}

Describe 'Test-MetricNotFound' {
    It 'matches the message Get-AzMetric gives for a 404 (<Label>)' -ForEach @(
        @{ Label = 'quoted, as Az.Monitor 8 writes it'; Message = "Microsoft.Azure.Management.Monitor.Models.ErrorResponseException: Operation returned an invalid status code 'NotFound'" }
        @{ Label = 'unquoted'; Message = 'Operation returned an invalid status code NotFound' }
        @{ Label = 'wrapped in the ErrorActionPreference text'; Message = "The running command stopped because the preference variable `"ErrorActionPreference`" or common parameter is set to Stop: Exception type: ErrorResponseException, Message: Operation returned an invalid status code 'NotFound', Code: Null" }
    ) {
        Test-MetricNotFound -Exception ([System.Exception]::new($Message)) | Should -BeTrue
    }

    It 'matches a 404 status code with no status in the message' {
        Test-MetricNotFound -Exception ([System.Net.Http.HttpRequestException]::new('gone', $null, [System.Net.HttpStatusCode]::NotFound)) | Should -BeTrue
    }

    It 'matches a 404 wrapped in another exception' {
        $Inner = [System.Exception]::new("Operation returned an invalid status code 'NotFound'")
        Test-MetricNotFound -Exception ([System.Exception]::new('The request failed.', $Inner)) | Should -BeTrue
    }

    It 'does not match a failure that a retry can fix or that is not a 404 (<Label>)' -ForEach @(
        @{ Label = 'throttled'; Message = "Operation returned an invalid status code 'TooManyRequests'" }
        @{ Label = 'server error'; Message = "Operation returned an invalid status code 'InternalServerError'" }
        @{ Label = 'unavailable'; Message = "Operation returned an invalid status code 'ServiceUnavailable'" }
        @{ Label = 'gateway timeout'; Message = "Operation returned an invalid status code 'GatewayTimeout'" }
        @{ Label = 'bad request'; Message = "Operation returned an invalid status code 'BadRequest'" }
        @{ Label = 'our own timeout'; Message = 'Timed out after 120s' }
        @{ Label = 'a resource name that holds the word'; Message = "Operation returned an invalid status code 'InternalServerError' for vm-NotFound-01" }
    ) {
        Test-MetricNotFound -Exception ([System.Exception]::new($Message)) | Should -BeFalse
    }

    It 'does not match a 5xx status code' {
        Test-MetricNotFound -Exception ([System.Net.Http.HttpRequestException]::new('busy', $null, [System.Net.HttpStatusCode]::ServiceUnavailable)) | Should -BeFalse
    }

    It 'the retry loop checks NotFound before the throttle match and passes it to the plan as permanent' {
        $script:MetricsSrc | Should -Match '(?s)if \(Test-MetricNotFound -Exception \$_\.Exception\)\s*\{\s*\$NotFound = \$true\s*\}\s*elseif \(\$LastError -match ''429\|throttl'
        $script:MetricsSrc | Should -Match 'Get-RdaMetricRetryPlan -Attempt \$Attempt .*-Permanent \$NotFound'
    }
}

Describe 'Get-MetricDeletingState' {
    BeforeAll {
        # With no -Task the script only defines its functions.
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Metrics.ps1')
        $script:Rows = @(
            [PSCustomObject]@{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/pg-1'; properties = [PSCustomObject]@{ state = 'Dropping' } }
            [PSCustomObject]@{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.DBforMySQL/flexibleServers/my-1'; properties = [PSCustomObject]@{ state = 'Ready' } }
            [PSCustomObject]@{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/d-1'; properties = [PSCustomObject]@{ provisioningState = 'Deleting' } }
            [PSCustomObject]@{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/d-2'; properties = $null }
        )
    }

    It 'maps only the asked ids whose state says they are being deleted, ignoring case' {
        $Ids = @($script:Rows.Id.ToUpperInvariant())
        $Found = Get-MetricDeletingState -Resources $script:Rows -Ids $Ids
        $Found.Count | Should -Be 2
        $Found[$script:Rows[0].Id] | Should -Be 'Dropping'
        $Found[$script:Rows[2].Id] | Should -Be 'Deleting'
    }

    It 'reads nothing for an id that was not asked' {
        (Get-MetricDeletingState -Resources $script:Rows -Ids @($script:Rows[1].Id)).Count | Should -Be 0
        (Get-MetricDeletingState -Resources $script:Rows -Ids @()).Count | Should -Be 0
    }
}
