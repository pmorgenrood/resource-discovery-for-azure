# The masked resource id shape that -Obfuscate writes, as one regular
# expression for the zip-backed tests. A masked id is an ARM-shaped path, never
# a flat token:
#   [/subscriptions/<sub token>[/resourcegroups/<rg token>]]/providers/<namespace>(/<type>/<name token>)+
#     [/providers/<namespace>(/<type>/<name token>)+ ...]
# - The subscription part is left out only for a tenant-scope id, such as a
#   reservation order (/providers/microsoft.capacity/reservationorders/...).
# - A subscription or a group itself, with no provider block, is a masked id
#   only with -AllowScopeOnly: a consumption row (and its dictionary key) can be
#   billed at that scope, but an inventory, metric or link id names a resource,
#   so one cut back to its scope fails.
# - An extension resource adds a second /providers/<namespace> block.
# - Every subscription, resource group and name segment is a prod_/nonprod_
#   token. Consumption-only tokens carry sub_, rg_ or rg_mc_; a name token may
#   carry a databricks_, aks_ or vmss_ hint; a '$system' name stays as written.
# - Namespace and type segments stay as written. A path Azure wrote oddly
#   keeps its shape: a type with no name after it at the end, or a trailing
#   '/', hold no real name, so they pass. An empty segment inside the path
#   fails: there a type cannot be told from a name.
function Get-MaskedIdPattern
{
    param([switch]$AllowScopeOnly)
    $Guid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    # Tokens are written in lower case, so the token parts match letter for
    # letter ((?-i:...)) even under PowerShell's case-blind -match; Azure's
    # keywords, namespaces and types keep any case.
    $Scope = '/subscriptions/(?-i:(prod|nonprod)_(sub_)?' + $Guid + ')(/resourcegroups/(?-i:(prod|nonprod)_(rg_)?(mc_)?' + $Guid + '))?'
    $Name = '((?-i:(prod|nonprod)_(databricks_|aks_|vmss_)?' + $Guid + ')|\$system)'
    $Block = '(/providers/[a-z][a-z0-9.]*(/[a-z][a-z0-9.]*/' + $Name + ')*(/[a-z][a-z0-9.]*)?)'
    # A subscription or group scope with one or more provider blocks (none,
    # with -AllowScopeOnly: a charge billed to the subscription or the group
    # itself), or a tenant-scope id of provider blocks only.
    $ScopeBlocks = if ($AllowScopeOnly) { '*' } else { '+' }
    return '^(' + $Scope + $Block + $ScopeBlocks + '|' + $Block + '+)/?$'
}

# Tells an obfuscated run from a plain one. Only the start of a masked ID is
# checked, and a flat prod_/nonprod_ token also counts, so an ID with a leak
# or the wrong shape still marks the run as obfuscated and turns the leak
# scans on. A tenant-scope id (/providers/...) has no subscription to tell by,
# and one real name there can look like a token, so a run whose IDs are all
# tenant-scope is told by its dictionary (only an -Obfuscate run writes one),
# or, with no dictionary at hand (it is never in the shared zip), when every
# name of every one of its IDs is a full prod_/nonprod_<guid> token.
function Test-ObfuscatedRun
{
    param([string[]]$Ids, [string]$DictionaryPath)
    foreach ($Id in $Ids) { if ($Id -match '^(/subscriptions/)?(prod|nonprod)_') { return $true } }
    if (-not [string]::IsNullOrEmpty($DictionaryPath) -and (Test-Path -LiteralPath $DictionaryPath)) { return $true }
    $Ids = @($Ids | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($Ids.Count -eq 0) { return $false }
    $Token = '^(?-i:(prod|nonprod)_(databricks_|aks_|vmss_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
    foreach ($Id in $Ids)
    {
        # /providers/<namespace>/<type>/<name>[/<type>/<name> ...]
        $Parts = $Id.TrimEnd('/').Split('/')
        if ($Parts.Count -lt 5 -or $Parts[1] -ne 'providers' -or $Parts.Count % 2 -eq 0) { return $false }
        for ($i = 4; $i -lt $Parts.Count; $i += 2) { if ($Parts[$i] -notmatch $Token) { return $false } }
    }
    return $true
}
