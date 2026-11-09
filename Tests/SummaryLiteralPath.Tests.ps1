# Extension/Summary.ps1 reads -JsonFile and writes -HtmlFile by their literal
# paths: a folder or file name may hold [ or ], which -Path reads as a wildcard
# (the report is refused, or another file is read or written).
#
# Offline; generic names only.
#
# Run with: Invoke-Pester ./Tests/SummaryLiteralPath.Tests.ps1 -Output Detailed

BeforeAll {
    $script:Script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Extension/Summary.ps1'
    $TmpBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { '/tmp' }
    $script:TestBase = Join-Path $TmpBase ('SummaryLiteralPath_' + [guid]::NewGuid().ToString().Substring(0, 8))
    New-Item -ItemType Directory -Path $script:TestBase -Force | Out-Null
}

AfterAll {
    if ($script:TestBase -and (Test-Path -LiteralPath $script:TestBase)) { Remove-Item -LiteralPath $script:TestBase -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'The per-report renderer with bracketed paths' {
    It 'reads <Json> and writes <Html> in a folder named <Folder>' -ForEach @(
        @{ Folder = 'rep[1]'; Json = 'Inventory.json'; Html = 'report.html' }
        @{ Folder = 'rep1'; Json = 'Inventory[1].json'; Html = 'report[1].html' }
    ) {
        $Dir = Join-Path $script:TestBase $Folder
        $null = New-Item -ItemType Directory -Path $Dir -Force
        $JsonPath = Join-Path $Dir $Json
        Set-Content -LiteralPath $JsonPath -Value '{"Version":"3.2.3","PublicIP":[{"Name":"pip-literal","Subscription":"Sub"}]}'
        # Files a wildcard read of the names would also match.
        Set-Content -LiteralPath (Join-Path $Dir 'Inventory1.json') -Value '{"Version":"3.2.3","PublicIP":[{"Name":"pip-other","Subscription":"Sub"}]}'
        Set-Content -LiteralPath (Join-Path $Dir 'report1.html') -Value 'not the report' -NoNewline
        $HtmlPath = Join-Path $Dir $Html
        & $script:Script -JsonFile $JsonPath -HtmlFile $HtmlPath -Title 'T' -Version 'test' -PlatOS 'Linux' *> $null
        Test-Path -LiteralPath $HtmlPath -PathType Leaf | Should -BeTrue
        Get-Content -LiteralPath $HtmlPath -Raw | Should -Match 'pip-literal'
        Get-Content -LiteralPath (Join-Path $Dir 'report1.html') -Raw | Should -Be 'not the report'
    }
}
