#Requires -Version 7.0
# =============================================================================
# IdText.Functions.ps1
#
# The rule of where a whole id ends inside a text: Get-RdaIdEndMark and
# Get-RdaIdBeforeCloseParen. The offline mask reads ids by it
# (Get-RdaFullIdPattern and Get-RdaFullIdInValue, OfflineObfuscation.Functions.ps1),
# and so does Reveal's whole-id pass (Convert-RevealString,
# RevealObfuscation.Functions.ps1), so the two read one id in a text alike.
# Dot-sourced by Protect-RdaReport.ps1 (with its other files) and by
# RevealObfuscation.Functions.ps1 (so Reveal.ps1 and each of its per-folder
# jobs have it).
# Definitions only - no top-level code, so loading it defines these functions
# and changes nothing else in the caller's session.
# =============================================================================

# The marks that end a full id inside a text: whitespace, a quote or a mark no id holds
# (<>,;|[]{}?#&=), as the body of a regex character class. Get-RdaFullIdPattern reads an id up
# to the first of them, and so does Reveal's whole-id pass, so the offline mask and Reveal read
# one id in a text alike.
function Get-RdaIdEndMark
{
    return '\s"''<>,;|\[\]{}?#&='
}

# $Id, a full id read from a text, with each ')' at its end that has no '(' of its own taken
# off: a group name may hold '(' and ')', so only such a ')' closes the text around the id.
function Get-RdaIdBeforeCloseParen([string]$Id)
{
    while ($Id.EndsWith(')') -and ($Id.Split('(').Count -lt $Id.Split(')').Count)) { $Id = $Id.Substring(0, $Id.Length - 1) }
    return $Id
}
