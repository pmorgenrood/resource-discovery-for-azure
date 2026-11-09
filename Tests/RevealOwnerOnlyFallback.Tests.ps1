# Owner-only staging folder on PowerShell without the .NET Unix mode calls
# Run with: Invoke-Pester ./Tests/RevealOwnerOnlyFallback.Tests.ps1 -Output Detailed
#
# WHY THIS TEST EXISTS
# --------------------
# Set-RevealOwnerOnlyDirectory makes Reveal's staging folder mode 0700. On
# PowerShell 7.0 and 7.1 (.NET before 7) there is no File.SetUnixFileMode, so
# it falls back to chmod and stat. That fallback used GNU 'stat -c %a', which
# macOS's BSD stat rejects, so Reveal stopped before writing anything on a
# supported setup. It then passed '--' before the path to chmod and stat,
# which macOS chmod and stat take as a file name, so they failed there too.
# The fallback now runs 'chmod 700 <full path>' and reads the mode with
# 'stat -f %Lp <full path>' on macOS and 'stat -c %a <full path>' on Linux.
#
# This host has the .NET calls, so the test forces the fallback, and stands in
# chmod and stat with small scripts that log how they were called (the macOS
# stand-ins behave as BSD chmod and stat do: they take '--' as a file name,
# and stat refuses -c).

BeforeAll {
    $script:RepoRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' | Resolve-Path | Select-Object -ExpandProperty Path
    . (Join-Path $script:RepoRoot 'Functions/RevealObfuscation.Functions.ps1')
    # So Mock has a command to replace when the functions file has none.
    if (-not (Get-Command Test-RevealUnixModeApi -ErrorAction SilentlyContinue)) { function Test-RevealUnixModeApi { $true } }
    if (-not (Get-Command Test-RevealIsMacOS -ErrorAction SilentlyContinue)) { function Test-RevealIsMacOS { [bool]$IsMacOS } }

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('RevealOwnerOnlyFallback_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:WorkDir -Force
    $script:Log = Join-Path $script:WorkDir 'calls.log'
    $script:RealChmod = (Get-Command chmod -CommandType Application | Select-Object -First 1).Source
    $script:RealStat = (Get-Command stat -CommandType Application | Select-Object -First 1).Source

    # A folder of stand-ins put first on PATH. $Kind 'gnu' passes chmod and
    # stat through. 'bsd' behaves as macOS does: chmod takes a '--' operand as
    # a file name and fails, and stat answers only '-f %Lp <path>', refusing
    # '-c' and taking '--' as a file name.
    function New-StandIns
    {
        param([string]$Kind)
        $Bin = Join-Path $script:WorkDir ('bin-' + $Kind)
        $null = New-Item -ItemType Directory -Path $Bin -Force
        if ($Kind -eq 'bsd')
        {
            $Chmod = "#!/bin/sh`necho ""chmod `$*"" >> '$($script:Log)'`nfor a in ""`$@""; do if [ ""`$a"" = ""--"" ]; then echo ""chmod: --: No such file or directory"" >&2; exit 1; fi; done`nexec '$($script:RealChmod)' ""`$@""`n"
            $Stat = "#!/bin/sh`necho ""stat `$*"" >> '$($script:Log)'`nif [ ""`$#"" = ""3"" ] && [ ""`$1"" = ""-f"" ] && [ ""`$2"" = ""%Lp"" ] && [ ""`$3"" != ""--"" ]; then exec '$($script:RealStat)' -c '%a' -- ""`$3""; fi`nif [ ""`$1"" = ""-c"" ]; then echo ""stat: illegal option -- c"" >&2; else echo ""stat: --: stat: No such file or directory"" >&2; fi`nexit 1`n"
        }
        else
        {
            $Chmod = "#!/bin/sh`necho ""chmod `$*"" >> '$($script:Log)'`nexec '$($script:RealChmod)' ""`$@""`n"
            $Stat = "#!/bin/sh`necho ""stat `$*"" >> '$($script:Log)'`nexec '$($script:RealStat)' ""`$@""`n"
        }
        [System.IO.File]::WriteAllText((Join-Path $Bin 'chmod'), $Chmod)
        [System.IO.File]::WriteAllText((Join-Path $Bin 'stat'), $Stat)
        & $script:RealChmod 755 -- (Join-Path $Bin 'chmod') (Join-Path $Bin 'stat')
        return $Bin
    }

    function New-OpenFolder
    {
        param([string]$Name)
        $Dir = Join-Path $script:WorkDir $Name
        $null = New-Item -ItemType Directory -Path $Dir -Force
        & $script:RealChmod 755 -- $Dir
        return $Dir
    }

    function Get-Mode
    {
        param([string]$Path)
        return (& $script:RealStat -c '%a' -- $Path)
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir))
    {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Set-RevealOwnerOnlyDirectory without the .NET Unix mode calls' -Skip:$IsWindows {
    BeforeEach {
        $script:SavedPath = $env:PATH
        Remove-Item -LiteralPath $script:Log -Force -ErrorAction SilentlyContinue
        Mock Test-RevealUnixModeApi { $false }
    }
    AfterEach {
        $env:PATH = $script:SavedPath
    }

    It 'uses chmod 700 and GNU stat on Linux' {
        Mock Test-RevealIsMacOS { $false }
        $env:PATH = (New-StandIns -Kind 'gnu') + [System.IO.Path]::PathSeparator + $script:SavedPath
        $Dir = New-OpenFolder -Name 'linux'

        { Set-RevealOwnerOnlyDirectory -Path $Dir } | Should -Not -Throw

        Get-Mode $Dir | Should -Be '700'
        $Calls = @(Get-Content -LiteralPath $script:Log -ErrorAction SilentlyContinue)
        $Calls | Should -Be @("chmod 700 $Dir", "stat -c %a $Dir")
    }

    It 'uses chmod 700 and BSD stat on macOS, with no -- operand' {
        Mock Test-RevealIsMacOS { $true }
        $env:PATH = (New-StandIns -Kind 'bsd') + [System.IO.Path]::PathSeparator + $script:SavedPath
        $Dir = New-OpenFolder -Name 'macos'

        { Set-RevealOwnerOnlyDirectory -Path $Dir } | Should -Not -Throw

        Get-Mode $Dir | Should -Be '700'
        $Calls = @(Get-Content -LiteralPath $script:Log -ErrorAction SilentlyContinue)
        $Calls | Should -Be @("chmod 700 $Dir", "stat -f %Lp $Dir")
    }

    It 'still stops when the folder does not read back as owner-only' {
        Mock Test-RevealIsMacOS { $false }
        $Bin = Join-Path $script:WorkDir 'bin-nochange'
        $null = New-Item -ItemType Directory -Path $Bin -Force
        # A chmod that reports success but changes nothing.
        [System.IO.File]::WriteAllText((Join-Path $Bin 'chmod'), "#!/bin/sh`nexit 0`n")
        & $script:RealChmod 755 -- (Join-Path $Bin 'chmod')
        $env:PATH = $Bin + [System.IO.Path]::PathSeparator + $script:SavedPath
        $Dir = New-OpenFolder -Name 'nochange'

        { Set-RevealOwnerOnlyDirectory -Path $Dir } | Should -Throw '*its mode is 755*'
    }
}
