#Requires -Version 7.0
# =============================================================================
# CsvHeader.Functions.ps1
#
# The one reader of a consumption file's header line: ConvertFrom-RdaCsvHeaderLine.
# Dot-sourced by Functions/RecoveryMerge.Functions.ps1 (the merge's consumption
# check) and by Protect-RdaReport.ps1 (the offline mask's column check), so both
# read a header the same way.
# Definitions only - no top-level code, so loading it defines this function and
# changes nothing else in the caller's session.
# =============================================================================

# The names a CSV header line holds, read as CSV is written (RFC 4180): a cell is plain, with
# no '"' in it, or quoted, with each '"' in it written twice and nothing between its closing
# quote and the next comma. So '"Meter""Category"' is the name Meter"Category, as Import-Csv
# reads it, not MeterCategory. $null for a line that is not CSV so written (a quote in a plain
# cell, text after a closing quote, a quote left open): readers take such a line in different
# ways (Import-Csv reads '"Meter"Category' as MeterCategory), so what downstream finds in it is
# not known. A run writes its header plain (a file with no rows) or with every name quoted
# (Export-Csv), and both are read.
function ConvertFrom-RdaCsvHeaderLine([string]$Line)
{
    $Match = [regex]::Match($Line, '^(?<Cell>"(?:[^"]|"")*"|[^",]*)(?:,(?<Cell>"(?:[^"]|"")*"|[^",]*))*\z')
    if (-not $Match.Success) { return $null }
    return , [string[]]@(foreach ($Cell in $Match.Groups['Cell'].Captures) { if ($Cell.Value.StartsWith('"')) { $Cell.Value.Substring(1, $Cell.Value.Length - 2).Replace('""', '"') } else { $Cell.Value } })
}
