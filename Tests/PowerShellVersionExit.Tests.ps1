# Exit code when the script runs on PowerShell older than 7
# Run with: Invoke-Pester ./Tests/PowerShellVersionExit.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# CheckPowerShell stops the run when the PowerShell version is below 7, but
# it stopped with a bare 'Exit', which ends the process with exit code 0. A
# scheduled task or a wrapper then saw a success with no report. It now ends
# with exit 1. This test proves only that CheckPowerShell ends with exit 1
# when the version is below 7; on real Windows PowerShell 5.1 the files the
# script loads carry #Requires -Version 7.0, so the run may stop before
# CheckPowerShell is reached.
#
# PowerShell 5.1 is not available to the test, and $PSVersionTable cannot be
# replaced, so the test lifts the REAL CheckPowerShell function from
# ResourceInventory.ps1's parsed source, reads the version from a stand-in
# table in its place, and runs it in a child pwsh: as Windows PowerShell 5.1
# (Desktop, 5.1), as PowerShell 7.4 on Windows, and as PowerShell 7 on Unix,
# under en-US and tr-TR. It checks the process exit code and the message.

BeforeDiscovery {
    $script:Cases = @(
        foreach ($Culture in @('en-US', 'tr-TR'))
        {
            @{ Culture = $Culture; Platform = 'Win32NT'; Version = '5.1'; Exit = 1; Stops = $true }
            @{ Culture = $Culture; Platform = 'Win32NT'; Version = '7.4'; Exit = 0; Stops = $false }
            @{ Culture = $Culture; Platform = 'Unix'; Version = '7.4'; Exit = 0; Stops = $false }
        }
    )
}

BeforeAll {
    $Source = Join-Path $PSScriptRoot '..' 'ResourceInventory.ps1'
    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$Tokens, [ref]$ParseErrors)
    $Found = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'CheckPowerShell' }, $true))
    if ($Found.Count -ne 1) { throw ("expected one CheckPowerShell in ResourceInventory.ps1, found {0}" -f $Found.Count) }
    $script:FunctionText = $Found[0].Extent.Text -replace '\$PSVersionTable\b', '$StandInVersionTable'
    if ($script:FunctionText -notmatch 'StandInVersionTable') { throw 'CheckPowerShell no longer reads $PSVersionTable' }
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('PowerShellVersionExit_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force

    function Invoke-VersionCheck
    {
        param([string]$Culture, [string]$Platform, [string]$Version)
        $File = Join-Path $script:WorkDir ('check_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        $Lines = @(
            ('[System.Globalization.CultureInfo]::CurrentCulture = ''{0}''' -f $Culture),
            ('$StandInVersionTable = @{{ Platform = ''{0}''; PSVersion = [version]''{1}'' }}' -f $Platform, $Version),
            '$Global:RdaSessionInitialized = $false',
            '$Global:ReportName = ''ResourcesReport''',
            'function Write-Log { param($Message, $Severity) Write-Host ("{0}: {1}" -f $Severity, $Message) }',
            'function Get-CloudDrive { throw ''not Cloud Shell'' }',
            'function LoginSession { }',
            $script:FunctionText,
            'CheckPowerShell',
            'Write-Host ''check passed''',
            'exit 0'
        )
        Set-Content -LiteralPath $File -Value $Lines -Encoding utf8
        $Console = @(& pwsh -NoProfile -NonInteractive -File $File 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Console = $Console }
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'CheckPowerShell as PowerShell <Version> on <Platform> under <Culture>' -ForEach $script:Cases {
    BeforeAll {
        $script:Run = Invoke-VersionCheck -Culture $Culture -Platform $Platform -Version $Version
    }

    It 'ends with exit <Exit>' {
        $script:Run.Exit | Should -Be $Exit -Because ($script:Run.Console -join "`n")
    }

    It 'says PowerShell 7 is needed only when it stops' {
        @($script:Run.Console | Where-Object { $_ -like '*You must use Powershell 7 to run the inventory script.*' }).Count | Should -Be $(if ($Stops) { 1 } else { 0 })
        @($script:Run.Console | Where-Object { $_ -eq 'check passed' }).Count | Should -Be $(if ($Stops) { 0 } else { 1 })
    }
}
