# The obfuscation dictionary of the run that made the test zip. A run writes
# <ReportName>_<time>.zip and ObfuscationDictionary_<ReportName>_<time>.json
# side by side, so the dictionary is found by the zip's own name, never by
# date: a folder can hold several runs.
# TEST_DICT_PATH wins. Else the zip is TEST_ZIP_PATH, or the newest
# ResourcesReport_*.zip in Tests/ when TEST_ZIP_PATH is not set. Returns $null
# when that zip has no dictionary next to it.
function Get-RunDictionaryPath
{
    param([string]$TestsRoot)
    if ($env:TEST_DICT_PATH) { return $env:TEST_DICT_PATH }
    $ZipPath = if ($env:TEST_ZIP_PATH) { $env:TEST_ZIP_PATH } else
    {
        Get-ChildItem -Path $TestsRoot -Filter 'ResourcesReport_*.zip' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrEmpty($ZipPath)) { return $null }
    $DictPath = Join-Path (Split-Path $ZipPath -Parent) ('ObfuscationDictionary_' + [System.IO.Path]::GetFileNameWithoutExtension($ZipPath) + '.json')
    if (Test-Path -LiteralPath $DictPath) { return $DictPath }
    return $null
}
