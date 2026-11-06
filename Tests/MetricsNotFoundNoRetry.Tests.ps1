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
    foreach ($Name in 'Get-MetricExceptionChain', 'Get-MetricExceptionStatus', 'Test-MetricNotFound', 'Test-MetricBadRequest')
    {
        $FnAst = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $Name }, $true) | Select-Object -First 1
        if (-not $FnAst) { throw "$Name was not found in Extension/Metrics.ps1" }
        . ([scriptblock]::Create($FnAst.Extent.Text))
    }
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

    It 'lets a status code decide over 404 text: a 503 that quotes a 404 is not permanent' {
        Test-MetricNotFound -Exception ([System.Net.Http.HttpRequestException]::new("upstream said: Operation returned an invalid status code 'NotFound'", $null, [System.Net.HttpStatusCode]::ServiceUnavailable)) | Should -BeFalse
    }

    It 'reads the outermost status: a 500 that wraps a 404 is not permanent' {
        $Inner = [System.Net.Http.HttpRequestException]::new('gone', $null, [System.Net.HttpStatusCode]::NotFound)
        Test-MetricNotFound -Exception ([System.Net.Http.HttpRequestException]::new('The server failed.', $Inner, [System.Net.HttpStatusCode]::InternalServerError)) | Should -BeFalse
    }

    It 'reads the status of a wrapped exception when the outer one carries none' {
        $Inner = [System.Net.Http.HttpRequestException]::new('gone', $null, [System.Net.HttpStatusCode]::NotFound)
        Test-MetricNotFound -Exception ([System.Exception]::new('The request failed.', $Inner)) | Should -BeTrue
    }

    It 'reads the status of the response an SDK exception carries (<Code>)' -ForEach @(@{ Code = 'NotFound'; Want = $true }, @{ Code = 'ServiceUnavailable'; Want = $false }) {
        $Ex = [System.Exception]::new("Operation returned an invalid status code 'NotFound'")
        $Ex | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{ StatusCode = [System.Net.HttpStatusCode]$Code })
        Test-MetricNotFound -Exception $Ex | Should -Be $Want
    }

    It 'reads the exception''s own status when its response has no status value (<Code>)' -ForEach @(@{ Code = 'NotFound'; Message = 'The request failed.'; Want = $true }, @{ Code = 'ServiceUnavailable'; Message = "upstream: Operation returned an invalid status code 'NotFound'"; Want = $false }) {
        $Ex = [System.Net.Http.HttpRequestException]::new($Message, $null, [System.Net.HttpStatusCode]$Code)
        $Ex | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{ StatusCode = $null })
        Test-MetricNotFound -Exception $Ex | Should -Be $Want
    }

    It 'follows a wrapped error record whose exception holds the 404, under a neutral outer message' {
        $Inner = [System.Exception]::new("Operation returned an invalid status code 'NotFound'")
        $Outer = [System.Exception]::new('The running command stopped.')
        $Outer | Add-Member -NotePropertyName ErrorRecord -NotePropertyValue ([System.Management.Automation.ErrorRecord]::new($Inner, 'Metric', 'NotSpecified', $null))
        Test-MetricNotFound -Exception $Outer | Should -BeTrue
    }

    It 'matches the newer SDK form of a 404 (<Label>)' -ForEach @(@{ Label = 'error code in the body'; Body = $true }, @{ Label = 'error code in the message'; Body = $false }) {
        if ($Body)
        {
            $Ex = [System.Exception]::new('The resource was not found.')
            $Ex | Add-Member -NotePropertyName Body -NotePropertyValue ([PSCustomObject]@{ Code = 'ResourceNotFound' })
        }
        else
        {
            $Ex = [System.Exception]::new("[ResourceNotFound] : The Resource 'x' was not found.")
        }
        Test-MetricNotFound -Exception $Ex | Should -BeTrue
    }

    It 'reads the newer SDK form only when no exception carries a status: a 503 with it keeps its retries (<Label>)' -ForEach @(@{ Label = 'error code in the body'; Body = $true }, @{ Label = 'error code in the message'; Body = $false }) {
        if ($Body)
        {
            $Ex = [System.Net.Http.HttpRequestException]::new('busy', $null, [System.Net.HttpStatusCode]::ServiceUnavailable)
            $Ex | Add-Member -NotePropertyName Body -NotePropertyValue ([PSCustomObject]@{ Code = 'ResourceNotFound' })
        }
        else
        {
            $Ex = [System.Net.Http.HttpRequestException]::new("[ResourceNotFound] : The Resource 'x' was not found.", $null, [System.Net.HttpStatusCode]::ServiceUnavailable)
        }
        Test-MetricNotFound -Exception $Ex | Should -BeFalse
    }
}

Describe 'Test-MetricBadRequest on the shared status helper' {
    It 'reads the exception''s own status when its response has no status value (<Code>)' -ForEach @(@{ Code = 'BadRequest'; Want = $true }, @{ Code = 'ServiceUnavailable'; Want = $false }) {
        $Ex = [System.Net.Http.HttpRequestException]::new('The request failed.', $null, [System.Net.HttpStatusCode]$Code)
        $Ex | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{ StatusCode = $null })
        Test-MetricBadRequest -Exception $Ex | Should -Be $Want
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
            [PSCustomObject]@{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Sql/servers/sv/databases/db-1'; properties = [PSCustomObject]@{ status = 'dropping' } }
        )
    }

    It 'maps only the asked ids whose state says they are being deleted, ignoring case' {
        $Ids = @($script:Rows.Id.ToUpperInvariant())
        $Found = Get-MetricDeletingState -Resources $script:Rows -Ids $Ids
        $Found.Count | Should -Be 3
        $Found[$script:Rows[0].Id] | Should -Be 'Dropping'
        $Found[$script:Rows[2].Id] | Should -Be 'Deleting'
        $Found[$script:Rows[4].Id] | Should -Be 'dropping'
    }

    It 'reads nothing for an id that was not asked' {
        (Get-MetricDeletingState -Resources $script:Rows -Ids @($script:Rows[1].Id)).Count | Should -Be 0
        (Get-MetricDeletingState -Resources $script:Rows -Ids @()).Count | Should -Be 0
    }
}
