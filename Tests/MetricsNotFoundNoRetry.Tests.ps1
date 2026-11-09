# Requires -Modules Pester
# Offline coverage for Get-MetricFailure in Extension/Metrics.ps1: a Get-AzMetric 404 (NotFound)
# is permanent, so the retry loop gives it one attempt instead of four. Extracted by AST like
# MetricsThrottleRetryAfter.Tests.ps1 does, so no other part of the script runs.
# The end-to-end attempt counts are in MetricsGrouping.Tests.ps1 and MetricsBatch.Tests.ps1.

BeforeAll {
    $Repo = Split-Path $PSScriptRoot -Parent
    $script:MetricsSrc = Get-Content -LiteralPath (Join-Path $Repo 'Extension/Metrics.ps1') -Raw
    $Tokens = $null; $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseInput($script:MetricsSrc, [ref]$Tokens, [ref]$Errors)
    foreach ($Name in 'Get-MetricExceptionChain', 'Get-MetricExceptionStatus', 'Get-MetricFailure')
    {
        $FnAst = $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $Name }, $true) | Select-Object -First 1
        if (-not $FnAst) { throw "$Name was not found in Extension/Metrics.ps1" }
        . ([scriptblock]::Create($FnAst.Extent.Text))
    }

    # The yes/no question the retry loop asks of Get-MetricFailure for a 404 and a 400.
    function Test-MetricNotFound([System.Exception]$Exception) { (Get-MetricFailure -Exception $Exception).Kind -eq 'NotFound' }
    function Test-MetricBadRequest([System.Exception]$Exception) { (Get-MetricFailure -Exception $Exception).Kind -eq 'BadRequest' }
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

    It 'reads a 404 anywhere in the chain: a 500 that wraps a 404 is permanent' {
        $Inner = [System.Net.Http.HttpRequestException]::new('gone', $null, [System.Net.HttpStatusCode]::NotFound)
        Test-MetricNotFound -Exception ([System.Net.Http.HttpRequestException]::new('The server failed.', $Inner, [System.Net.HttpStatusCode]::InternalServerError)) | Should -BeTrue
    }

    It 'reads a 404 under a wrapper that carries no status, below a 5xx' {
        $Inner = [System.Net.Http.HttpRequestException]::new('gone', $null, [System.Net.HttpStatusCode]::NotFound)
        $Middle = [System.Exception]::new('The request failed.', $Inner)
        Test-MetricNotFound -Exception ([System.Net.Http.HttpRequestException]::new('The server failed.', $Middle, [System.Net.HttpStatusCode]::BadGateway)) | Should -BeTrue
    }

    It 'does not match a chain whose statuses are all 5xx, even when a message quotes a 404' {
        $Inner = [System.Net.Http.HttpRequestException]::new("Operation returned an invalid status code 'NotFound'", $null, [System.Net.HttpStatusCode]::ServiceUnavailable)
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

    It 'lets a status code decide over BadRequest text: a 503 that names BadRequest is not a BadRequest' {
        Test-MetricBadRequest -Exception ([System.Net.Http.HttpRequestException]::new("upstream said: Operation returned an invalid status code 'BadRequest'", $null, [System.Net.HttpStatusCode]::ServiceUnavailable)) | Should -BeFalse
        $Inner = [System.Exception]::new("Operation returned an invalid status code 'BadRequest'")
        Test-MetricBadRequest -Exception ([System.Net.Http.HttpRequestException]::new('The server failed.', $Inner, [System.Net.HttpStatusCode]::InternalServerError)) | Should -BeFalse
    }

    It 'reads the BadRequest text when no exception in the chain carries a status' {
        Test-MetricBadRequest -Exception ([System.Exception]::new("Operation returned an invalid status code 'BadRequest'")) | Should -BeTrue
        $Inner = [System.Exception]::new("Operation returned an invalid status code 'BadRequest'")
        Test-MetricBadRequest -Exception ([System.Exception]::new('The request failed.', $Inner)) | Should -BeTrue
    }

    It 'reads the BadRequest text Az writes, quoted or not (<Label>)' -ForEach @(
        @{ Label = 'quoted, as Az.Monitor 8 writes it'; Message = "Microsoft.Azure.Management.Monitor.Models.ErrorResponseException: Operation returned an invalid status code 'BadRequest'" }
        @{ Label = 'unquoted'; Message = 'Operation returned an invalid status code BadRequest' }
        @{ Label = 'wrapped in the ErrorActionPreference text'; Message = "The running command stopped because the preference variable `"ErrorActionPreference`" or common parameter is set to Stop: Exception type: ErrorResponseException, Message: Operation returned an invalid status code 'BadRequest', Code: Null" }
    ) {
        Test-MetricBadRequest -Exception ([System.Exception]::new($Message)) | Should -BeTrue
    }

    It 'does not take a status-less message for a BadRequest when only a name holds the word (<Label>)' -ForEach @(
        @{ Label = 'a 5xx for a resource named after it'; Message = "Operation returned an invalid status code 'InternalServerError' for vm-BadRequest-01" }
        @{ Label = 'a timeout in a group named after it'; Message = 'Timed out after 120s on rg-badrequest-test' }
    ) {
        Test-MetricBadRequest -Exception ([System.Exception]::new($Message)) | Should -BeFalse
        Test-MetricBadRequest -Exception ([System.Exception]::new('The request failed.', ([System.Exception]::new($Message)))) | Should -BeFalse
    }
}

Describe 'Get-MetricFailure decides in one order for the whole chain' {
    BeforeAll {
        function New-Chain([string[]]$Codes)
        {
            # Outermost first; each code wraps the next one.
            $Ex = $null
            for ($i = $Codes.Count - 1; $i -ge 0; $i--)
            {
                $Ex = [System.Net.Http.HttpRequestException]::new(('status ' + $Codes[$i]), $Ex, [System.Net.HttpStatusCode]$Codes[$i])
            }
            return $Ex
        }
    }

    It 'reads <Chain> as <Kind> with status <Status>' -ForEach @(
        @{ Chain = 'TooManyRequests>BadRequest'; Kind = 'BadRequest'; Status = 400 }
        @{ Chain = 'Forbidden>TooManyRequests'; Kind = 'Refused'; Status = 403 }
        @{ Chain = 'Unauthorized>TooManyRequests'; Kind = 'Refused'; Status = 401 }
        @{ Chain = 'InternalServerError>NotFound'; Kind = 'NotFound'; Status = 404 }
        @{ Chain = 'TooManyRequests>NotFound'; Kind = 'NotFound'; Status = 404 }
        @{ Chain = 'BadGateway>Conflict'; Kind = 'Refused'; Status = 409 }
        @{ Chain = 'BadRequest>NotFound'; Kind = 'BadRequest'; Status = 400 }
        @{ Chain = 'InternalServerError>TooManyRequests'; Kind = 'Throttled'; Status = 429 }
        @{ Chain = 'RequestTimeout>TooManyRequests'; Kind = 'Throttled'; Status = 429 }
        @{ Chain = 'RequestTimeout'; Kind = 'Other'; Status = 408 }
        @{ Chain = 'InternalServerError>ServiceUnavailable'; Kind = 'Other'; Status = 500 }
    ) {
        $Failure = Get-MetricFailure -Exception (New-Chain ($Chain -split '>'))
        $Failure.Kind | Should -Be $Kind
        $Failure.Status | Should -Be $Status
    }

    It 'reads Az''s status text the same way when no exception carries a status (<Label>)' -ForEach @(
        @{ Label = 'a throttled message that wraps a 400'; Outer = "Operation returned an invalid status code 'TooManyRequests'"; Inner = "Operation returned an invalid status code 'BadRequest'"; Kind = 'BadRequest' }
        @{ Label = 'a 403 message that wraps a throttled one'; Outer = "Operation returned an invalid status code 'Forbidden'"; Inner = 'The request is being throttled.'; Kind = 'Refused' }
        @{ Label = 'a 500 message that wraps a 404'; Outer = "Operation returned an invalid status code 'InternalServerError'"; Inner = "Operation returned an invalid status code 'NotFound'"; Kind = 'NotFound' }
        @{ Label = 'a 500 message that wraps a throttled one'; Outer = "Operation returned an invalid status code 'InternalServerError'"; Inner = 'The request is being throttled.'; Kind = 'Throttled' }
        @{ Label = 'a status name .NET does not know'; Outer = "Operation returned an invalid status code 'Teapot'"; Inner = 'The request failed.'; Kind = 'Other' }
    ) {
        $Ex = [System.Exception]::new($Outer, [System.Exception]::new($Inner))
        (Get-MetricFailure -Exception $Ex).Kind | Should -Be $Kind
    }

    It 'reads the Status number an Azure.Core RequestFailedException carries (<Status>)' -ForEach @(
        @{ Status = 404; Kind = 'NotFound' }
        @{ Status = 400; Kind = 'BadRequest' }
        @{ Status = 403; Kind = 'Refused' }
        @{ Status = 429; Kind = 'Throttled' }
        @{ Status = 503; Kind = 'Other' }
    ) {
        # A stand-in with the same shape: an int Status and a message that names no status.
        $Ex = [System.Exception]::new('Service request failed.')
        $Ex | Add-Member -NotePropertyName Status -NotePropertyValue ([int]$Status)
        $Failure = Get-MetricFailure -Exception $Ex
        $Failure.Kind | Should -Be $Kind
        $Failure.Status | Should -Be $Status
        # Wrapped, it is read the same way.
        (Get-MetricFailure -Exception ([System.Exception]::new('The request failed.', $Ex))).Kind | Should -Be $Kind
    }

    It 'lets a Status number decide over the text, as any status does' {
        $Ex = [System.Exception]::new("upstream: Operation returned an invalid status code 'NotFound'")
        $Ex | Add-Member -NotePropertyName Status -NotePropertyValue 503
        (Get-MetricFailure -Exception $Ex).Kind | Should -Be 'Other'
    }

    It 'does not take a Status that is not an HTTP status number for one (<Label>)' -ForEach @(
        @{ Label = 'a WebException status'; Value = [System.Net.WebExceptionStatus]::ProtocolError }
        @{ Label = 'a text'; Value = 'Failed' }
        @{ Label = 'a number out of range'; Value = 7 }
    ) {
        $Ex = [System.Exception]::new("Operation returned an invalid status code 'NotFound'")
        $Ex | Add-Member -NotePropertyName Status -NotePropertyValue $Value
        # No status, so Az's text decides.
        (Get-MetricFailure -Exception $Ex).Kind | Should -Be 'NotFound'
    }

    It 'counts an exception reached twice only once: four wrappers whose inner exception and error record are the same still reach a 404' {
        # Each wrapper holds the next one both as its InnerException and as its error record's
        # exception, so a walk that does not skip what it has seen fills its 10 places with copies.
        $Ex = [System.Net.Http.HttpRequestException]::new('gone', $null, [System.Net.HttpStatusCode]::NotFound)
        $All = @($Ex)
        for ($i = 1; $i -le 4; $i++)
        {
            $Wrapper = [System.Exception]::new(('wrapper ' + $i), $Ex)
            $Wrapper | Add-Member -NotePropertyName ErrorRecord -NotePropertyValue ([System.Management.Automation.ErrorRecord]::new($Ex, 'Metric', 'NotSpecified', $null))
            $Ex = $Wrapper
            $All += $Ex
        }
        $Chain = Get-MetricExceptionChain -Exception $Ex
        $Chain.Count | Should -Be 5
        foreach ($Item in $All) { @($Chain | Where-Object { [object]::ReferenceEquals($_, $Item) }).Count | Should -Be 1 }
        $Failure = Get-MetricFailure -Exception $Ex
        $Failure.Kind | Should -Be 'NotFound'
        $Failure.Status | Should -Be 404
    }

    It 'gives no status for an error with none, and Other' {
        $Failure = Get-MetricFailure -Exception ([System.Exception]::new('Timed out after 120s'))
        $Failure.Kind | Should -Be 'Other'
        $Failure.Status | Should -BeNullOrEmpty
    }
}

Describe 'The status-less status text must end where the status name ends' {
    It 'does not read <Message> as a BadRequest' -ForEach @(
        @{ Message = 'Operation returned an invalid status code BadRequestButTransient' }
        @{ Message = "Operation returned an invalid status code 'BadRequestButTransient'" }
        @{ Message = 'Operation returned an invalid status code BadRequest-ish' }
    ) {
        Test-MetricBadRequest -Exception ([System.Exception]::new($Message)) | Should -BeFalse
    }

    It 'does not read <Message> as a NotFound' -ForEach @(
        @{ Message = 'Operation returned an invalid status code NotFoundButTransient' }
        @{ Message = "Operation returned an invalid status code 'NotFoundButTransient'" }
        @{ Message = 'Operation returned an invalid status code NotFound-ish' }
    ) {
        Test-MetricNotFound -Exception ([System.Exception]::new($Message)) | Should -BeFalse
    }

    It 'still reads the whole status name, quoted, unquoted or at the end of a sentence (<Message>)' -ForEach @(
        @{ Message = "Operation returned an invalid status code 'BadRequest'"; Want = 'BadRequest' }
        @{ Message = 'Operation returned an invalid status code BadRequest.'; Want = 'BadRequest' }
        @{ Message = "Operation returned an invalid status code 'NotFound', Code: Null"; Want = 'NotFound' }
        @{ Message = 'Operation returned an invalid status code NotFound'; Want = 'NotFound' }
    ) {
        $Ex = [System.Exception]::new($Message)
        Test-MetricBadRequest -Exception $Ex | Should -Be ($Want -eq 'BadRequest')
        Test-MetricNotFound -Exception $Ex | Should -Be ($Want -eq 'NotFound')
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
