#Requires -Version 7.0
# =============================================================================
# DictionaryTimeText.Functions.ps1
#
# Restore-DictionaryTimeText, the one reader that gives back the text of a
# dictionary value ConvertFrom-Json read as a time. Dot-sourced by
# Functions/RecoveryMerge.Functions.ps1 (the merged dictionary) and by
# Functions/RevealObfuscation.Functions.ps1 (the values Reveal puts back).
# Definitions only - no top-level code, so loading it defines this one function
# and changes nothing else in the caller's session.
# =============================================================================

# ConvertFrom-Json reads a text that looks like a time (ISO 8601, or
# '/Date(...)/'; a tag or free-text value can be one) as a DateTime, and that
# DateTime turned back into text has another form: ConvertTo-Json writes
# '2023-05-01T10:00:00.123+02:00' as '2023-05-01T08:00:00.123+00:00' on a host
# at UTC, '.1230000Z' as '.123Z' and '/Date(1682935200000)/' as
# '2023-05-01T10:00:00Z', and a cast to text gives '05/01/2023 08:00:00'.
# $Text: the dictionary file's text, as ConvertFrom-Json was given it.
# $Times: each value ConvertFrom-Json read as a time, as
#   [pscustomobject]@{ Map = <name of its map>; Entry = <its PSPropertyInfo> }.
# $GeneratedAt (optional): the dictionary's GeneratedAt PSPropertyInfo.
# The same text is read again by the reader ConvertFrom-Json uses
# (Newtonsoft.Json, with its settings) with date handling off, so every key is
# the same, and each noted value, and a GeneratedAt read as a time, gets back
# the text the file holds. A caller reads the text again only for a dictionary
# with such a value. A root that is a list of one object is read as that object,
# as ConvertFrom-Json without -NoEnumerate gives it; when the root is not an
# object after that, nothing is changed.
function Restore-DictionaryTimeText([string]$Text, [System.Collections.Generic.List[object]]$Times, $GeneratedAt)
{
    $Settings = [Newtonsoft.Json.JsonSerializerSettings]::new()
    $Settings.TypeNameHandling = [Newtonsoft.Json.TypeNameHandling]::None
    $Settings.MetadataPropertyHandling = [Newtonsoft.Json.MetadataPropertyHandling]::Ignore
    $Settings.MaxDepth = 1024
    $Settings.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
    $Root = [Newtonsoft.Json.JsonConvert]::DeserializeObject($Text, $Settings)
    # Reveal reads a list of one object (no build writes one, and the merge
    # refuses one), which ConvertFrom-Json gives as that object, so its values
    # are looked up in that object.
    if ($Root -is [Newtonsoft.Json.Linq.JArray] -and $Root.Count -eq 1 -and $Root[0] -is [Newtonsoft.Json.Linq.JObject]) { $Root = $Root[0] }
    # A root that is not an object has no map to look up.
    if ($Root -isnot [Newtonsoft.Json.Linq.JObject]) { return }
    $Ordinal = [System.StringComparison]::Ordinal
    foreach ($Time in $Times) { $Time.Entry.Value = $Root.GetValue($Time.Map, $Ordinal).GetValue($Time.Entry.Name, $Ordinal).Value }
    if ($null -ne $GeneratedAt -and $GeneratedAt.Value -is [datetime]) { $GeneratedAt.Value = $Root.GetValue($GeneratedAt.Name, $Ordinal).Value }
}
