# Order of the service collectors, and finding them in a folder with [ or ]
# Run with: Invoke-Pester ./Tests/CollectorOrder.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# CreateResourceJobs lists the collector scripts under Services/ and runs them
# in that order, which is also the order the inventory sections are written.
# awslabs main lists them with
#     Get-ChildItem -Path ($PSScriptRoot + '/Services/*.ps1') -Recurse
# Reading the scripts' own folder as written when it holds [ or ] must not
# change that order: a -LiteralPath ... -Filter '*.ps1' -Recurse form walks
# the folders in another order (Storage first, Analytics last).
#
# The test lifts the REAL Get-ChildItem lines from CreateResourceJobs in
# ResourceInventory.ps1's parsed source, runs the Unix line against copies of
# Services/ in 'tree' and 'tree[2]', and checks the names, in order, equal
# main's form for the plain folder. The Windows line must be the Unix line
# with '\' for '/'. No Azure.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $Source = Join-Path $script:RepoRoot 'ResourceInventory.ps1'
    $Tokens = $null
    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$Tokens, [ref]$ParseErrors)
    $Function = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'CreateResourceJobs' }, $true))
    if ($Function.Count -ne 1) { throw ("expected one CreateResourceJobs, found {0}" -f $Function.Count) }
    $Assignments = @($Function[0].FindAll({
                $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $args[0].Left.Extent.Text -eq '$Modules' -and
                $args[0].Right.Extent.Text -like 'Get-ChildItem*'
            }, $true))
    if ($Assignments.Count -ne 2) { throw ("expected two Get-ChildItem lines for `$Modules, found {0}" -f $Assignments.Count) }
    $script:WindowsLine = $Assignments[0].Right.Extent.Text
    $script:UnixLine = $Assignments[1].Right.Extent.Text

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('CollectorOrder_' + [guid]::NewGuid().ToString('N'))
    foreach ($TreeName in @('tree', 'tree[2]'))
    {
        $Tree = Join-Path $script:WorkDir $TreeName
        $null = New-Item -ItemType Directory -Path $Tree -Force
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Services') -Destination $Tree -Recurse -Force
    }

    function Get-CollectorList
    {
        param([string]$Line, [string]$Root)
        $Block = [scriptblock]::Create('param($StandInRoot) ' + ($Line -replace '\$PSScriptRoot\b', '$StandInRoot'))
        return @(& $Block $Root | ForEach-Object { $_.FullName.Substring($Root.Length) })
    }

    $script:PlainRoot = Join-Path $script:WorkDir 'tree'
    $script:BracketRoot = Join-Path $script:WorkDir 'tree[2]'
    # awslabs main's form, as the ruler.
    $script:MainOrder = @(Get-ChildItem -Path ($script:PlainRoot + '/Services/*.ps1') -Recurse | ForEach-Object { $_.FullName.Substring($script:PlainRoot.Length) })
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'CreateResourceJobs collector list' {
    It 'finds collectors with main''s form' {
        $script:MainOrder.Count | Should -BeGreaterThan 10
    }

    It 'lists the collectors in main''s order for a plain folder' {
        $List = Get-CollectorList -Line $script:UnixLine -Root $script:PlainRoot
        ($List -join "`n") | Should -Be ($script:MainOrder -join "`n")
    }

    It 'finds the same collectors, in the same order, in a folder named tree[2]' {
        $List = Get-CollectorList -Line $script:UnixLine -Root $script:BracketRoot
        ($List -join "`n") | Should -Be ($script:MainOrder -join "`n")
    }

    It 'uses the same form on Windows, with \ for /' {
        $script:WindowsLine | Should -Be ($script:UnixLine -replace '/', '\')
    }
}
