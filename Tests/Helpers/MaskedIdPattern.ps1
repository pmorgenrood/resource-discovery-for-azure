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
# - Namespace and type segments stay as written.
function Get-MaskedIdPattern
{
    $Guid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    $Scope = '(/subscriptions/(prod|nonprod)_(sub_)?' + $Guid + '(/resourcegroups/(prod|nonprod)_(rg_)?(mc_)?' + $Guid + ')?)?'
    $Block = '(/providers/[a-z][a-z0-9.]*(/[a-z][a-z0-9.]*/((prod|nonprod)_(databricks_|aks_|vmss_)?' + $Guid + '|\$system))+)+'
    return '^' + $Scope + $Block + '$'
}
