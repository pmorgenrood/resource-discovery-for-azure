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

# Tells an obfuscated run from a plain one by one of its inventory IDs. Only
# the start of a masked ID is checked, and a flat prod_/nonprod_ token also
# counts, so an ID with a leak or the wrong shape still marks the run as
# obfuscated and turns the leak scans on: a masked subscription
# (/subscriptions/prod_...), a flat token, or a tenant-scope id
# (/providers/...) with a token as a name segment.
function Get-ObfuscatedRunIdPattern
{
    return '^((/subscriptions/)?(prod|nonprod)_|/providers/[^/]+(/[^/]+/[^/]+)*/[^/]+/(prod|nonprod)_[0-9a-f]{8}-)'
}
