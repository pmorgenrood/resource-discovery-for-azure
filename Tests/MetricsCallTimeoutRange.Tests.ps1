# Requires -Modules Pester
# =============================================================================
# MetricsCallTimeoutRange.Tests.ps1
#
# -MetricsCallTimeoutSeconds in Extension/Metrics.ps1 is how long each Azure
# Monitor request may take. A value of 0 or less made every request time out
# at once, so the run wrote no metrics. The script must refuse a value outside
# 1 to 3600 seconds when its parameters are bound.
#
# The check binds a copy of the script's own parameter, as written, so none of
# the script body (Azure calls) ever runs.
#
# No live Azure. Run with:
#   Invoke-Pester ./Tests/MetricsCallTimeoutRange.Tests.ps1 -Output Detailed
# =============================================================================

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent

    # Builds a script block from the -MetricsCallTimeoutSeconds parameter of
    # Metrics.ps1 that returns the bound value.
    function Get-TimeoutBinder
    {
        $Path = Join-Path $script:RepoRoot 'Extension/Metrics.ps1'
        $Tokens = $null
        $ParseErrors = $null
        $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors)
        if ($ParseErrors.Count -gt 0) { throw 'Parse errors in Extension/Metrics.ps1' }
        $Param = @($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'MetricsCallTimeoutSeconds' })
        if ($Param.Count -ne 1) { throw 'No single -MetricsCallTimeoutSeconds parameter in Extension/Metrics.ps1' }
        return [scriptblock]::Create('param(' + $Param[0].Extent.Text + ') $MetricsCallTimeoutSeconds')
    }
}

Describe '-MetricsCallTimeoutSeconds is refused at binding when it is out of range' {

    It 'refuses <Value>' -TestCases @(
        @{ Value = 0 }
        @{ Value = -1 }
        @{ Value = 3601 }
    ) {
        param($Value)
        $Binder = Get-TimeoutBinder
        { & $Binder -MetricsCallTimeoutSeconds $Value } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It 'refuses a value that is not a number' {
        $Binder = Get-TimeoutBinder
        { & $Binder -MetricsCallTimeoutSeconds 'soon' } | Should -Throw
    }

    It 'still takes 1, 3600 and a number given as text' {
        $Binder = Get-TimeoutBinder
        & $Binder -MetricsCallTimeoutSeconds 1 | Should -Be 1
        & $Binder -MetricsCallTimeoutSeconds 3600 | Should -Be 3600
        & $Binder -MetricsCallTimeoutSeconds '30' | Should -Be 30
    }

    It 'keeps its default of 120' {
        $Binder = Get-TimeoutBinder
        & $Binder | Should -Be 120
    }
}
