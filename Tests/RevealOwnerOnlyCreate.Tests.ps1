# Reveal's zips: owner-only from the moment the file exists
# Run with: Invoke-Pester ./Tests/RevealOwnerOnlyCreate.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# New-RevealOwnerOnlyFile makes each zip Reveal writes (they hold real names
# and ids). It created the file under the umask and only then made it 0600, so
# under the common umask 022 the file was 0644 for a moment, and another user
# could open it then and keep it open while Reveal wrote the real values. It
# now creates the file 0600 on .NET 7 and later (FileStreamOptions
# .UnixCreateMode); otherwise it creates it inside a new owner-only folder
# beside the target, makes it owner-only there and then moves it into place.
#
# The check: Set-RevealOwnerOnlyFile is the first thing the helper calls on a
# file it has made. A stand-in for it records the file's mode and its folder's
# mode at that moment, then sets 0600 as the real one does. Each recorded file
# must have no group or other bits, or sit in an owner-only folder that is not
# the target's folder. Run under umask 022 in a child pwsh. Unix only; the
# Windows ACL create is not run here.

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Functions = Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1'
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealOwnerOnlyCreate_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force
    [System.IO.File]::SetUnixFileMode($script:WorkDir, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute')

    # Make one file with the helper in a child pwsh under umask 022. -NoCreateMode
    # takes the path for .NET without UnixCreateMode. Returns one line per
    # stand-in call: '<path>|<file mode>|<folder mode>', then 'FINAL|<mode>'.
    function Invoke-Create
    {
        param([string]$Name, [switch]$NoCreateMode)
        $Target = Join-Path $script:WorkDir $Name
        $Force = if ($NoCreateMode) { 'function Test-RevealUnixCreateModeApi { $false }' } else { '' }
        $Probe = @"
. '$($script:Functions)'
$Force
function Set-RevealOwnerOnlyFile {
    param([string]`$Path)
    `$Mode = [Convert]::ToString(([int][System.IO.File]::GetUnixFileMode(`$Path)) -band 0x1FF, 8)
    `$Dir = [System.IO.Path]::GetDirectoryName(`$Path)
    `$DirMode = [Convert]::ToString(([int][System.IO.File]::GetUnixFileMode(`$Dir)) -band 0x1FF, 8)
    '{0}|{1}|{2}' -f `$Path, `$Mode, `$DirMode | Write-Output
    [System.IO.File]::SetUnixFileMode(`$Path, [System.IO.UnixFileMode]'UserRead, UserWrite')
}
`$Calls = @(New-RevealOwnerOnlyFile -Path '$Target')
`$Calls
'FINAL|{0}' -f [Convert]::ToString(([int][System.IO.File]::GetUnixFileMode('$Target')) -band 0x1FF, 8)
"@
        $Lines = @(& sh -c 'umask 022; exec "$@"' sh pwsh -NoProfile -NonInteractive -Command $Probe 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Lines = $Lines; Target = $Target; Text = ($Lines -join "`n") }
    }

    # True when a recorded file could not be opened by another user: it has
    # no group or other bits, or its folder is owner-only and is not the
    # target's own folder.
    function Test-NeverOpen
    {
        param([string]$Line, [string]$Target)
        $Path, $Mode, $DirMode = $Line.Split('|')
        if (([Convert]::ToInt32($Mode, 8) -band 0x3F) -eq 0) { return $true }
        return ($DirMode -eq '700' -and [System.IO.Path]::GetDirectoryName($Path) -ne [System.IO.Path]::GetDirectoryName($Target))
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'New-RevealOwnerOnlyFile under umask 022 (<Case>)' -Skip:$IsWindows -ForEach @(
    @{ Case = 'with UnixCreateMode'; NoCreateMode = $false; Name = 'a.zip' }
    @{ Case = 'without UnixCreateMode'; NoCreateMode = $true; Name = 'b.zip' }
) {
    BeforeAll {
        $script:Run = Invoke-Create -Name $Name -NoCreateMode:$NoCreateMode
        $script:Calls = @($script:Run.Lines | Where-Object { $_ -notlike 'FINAL|*' -and $_ -like '*|*|*' })
        $script:Final = @($script:Run.Lines | Where-Object { $_ -like 'FINAL|*' })
    }

    It 'never lets the file exist where another user could open it' {
        $script:Run.Exit | Should -Be 0 -Because $script:Run.Text
        $script:Calls.Count | Should -BeGreaterThan 0 -Because $script:Run.Text
        foreach ($Call in $script:Calls)
        {
            Test-NeverOpen -Line $Call -Target $script:Run.Target | Should -BeTrue -Because $Call
        }
    }

    It 'leaves the file 0600 at its name, and nothing else beside it' {
        $script:Final.Count | Should -Be 1 -Because $script:Run.Text
        $script:Final[0].Split('|')[1] | Should -Be '600'
        # Only the files the earlier cases made, and this one: no private
        # folder left behind.
        @(Get-ChildItem -LiteralPath $script:WorkDir -Force -Directory).Count | Should -Be 0
        Test-Path -LiteralPath $script:Run.Target -PathType Leaf | Should -BeTrue
    }
}
