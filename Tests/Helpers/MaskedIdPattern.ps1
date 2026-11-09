# The masked resource id shape that -Obfuscate writes, as one regular
# expression for the zip-backed tests. A masked id is an ARM-shaped path, never
# a flat token:
#   [/subscriptions/<sub token>[/resourcegroups/<rg token>]]/providers/<namespace>(/<type>/<name token>)+
#     [/providers/<namespace>(/<type>/<name token>)+ ...]
# - The subscription part is left out only for a tenant-scope id, such as a
#   reservation order (/providers/microsoft.capacity/reservationorders/...).
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
    $Guid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    # Tokens are written in lower case, so the token parts match letter for
    # letter ((?-i:...)) even under PowerShell's case-blind -match; Azure's
    # keywords, namespaces and types keep any case.
    $Scope = '(/subscriptions/(?-i:(prod|nonprod)_(sub_)?' + $Guid + ')(/resourcegroups/(?-i:(prod|nonprod)_(rg_)?(mc_)?' + $Guid + '))?)?'
    $Name = '((?-i:(prod|nonprod)_(databricks_|aks_|vmss_)?' + $Guid + ')|\$system)'
    $Block = '(/providers/[a-z][a-z0-9.]*(/[a-z][a-z0-9.]*/' + $Name + ')*(/[a-z][a-z0-9.]*)?)+'
    return '^' + $Scope + $Block + '/?$'
}
